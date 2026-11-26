import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/fs_undo_journal.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// `fs.*` handlers (`ADR-0018`). Every handler re-classifies the real path
/// right before touching disk, so a symlink swapped after preflight cannot
/// redirect the access into a Hard-Deny location.
const List<HostToolHandler> defaultFsToolHandlers = <HostToolHandler>[
  FsListFilesTool(),
  FsReadFileTool(),
  FsGrepTool(),
  FsWriteFileTool(),
  FsPatchFileTool(),
];

const int _maxOutputBytes = 16384;
const int _maxReadBytes = 8 * 1024 * 1024;
const int _maxGrepFileBytes = 2 * 1024 * 1024;

XunaHostChannelException _fail(String code, [XtpStatus s = XtpStatus.failed]) =>
    XunaHostChannelException(status: s, errorCode: code);

/// Normalizes and re-checks [raw] for [access]; returns the normalized path.
String _guard(ToolExecutionContext context, String raw, FsAccessKind access) {
  final windows = Platform.isWindows;
  final home = context.execFsContext?.homeDirectory ?? hostHomeDirectory();
  final normalized = normalizeHostPath(
    raw,
    homeDirectory: home,
    windows: windows,
  );
  if (normalized == null) {
    throw _fail('path_not_absolute', XtpStatus.invalidArgs);
  }
  final decision = classifyFsPath(
    normalizedPath: normalized,
    resolvedPath: resolveHostRealPath(normalized),
    access: access,
    shellControl:
        context.policy?.shellControl ?? const ShellControlPolicy.disabled(),
    homeDirectory: home,
    windows: windows,
    caseInsensitive: Platform.isWindows || Platform.isMacOS,
    realPath: resolveHostRealPath,
  );
  if (decision.denied) {
    throw _fail(decision.errorCode!, XtpStatus.denied);
  }
  if (access == FsAccessKind.write &&
      decision.risk > context.evaluation.effectiveRisk) {
    // The target changed since the approval was evaluated (TOCTOU).
    throw _fail('approval_mismatch', XtpStatus.denied);
  }
  return normalized;
}

/// Whether [path] (normalized) may appear in a listing or grep walk.
bool _walkable(String path) =>
    hardDeniedPathReason(path) == null &&
    hardDeniedPathReason(resolveHostRealPath(path) ?? path) == null;

RegExp? _globToRegExp(String? glob) {
  if (glob == null) return null;
  final buffer = StringBuffer('^');
  for (final ch in glob.split('')) {
    buffer.write(switch (ch) {
      '*' => '[^/]*',
      '?' => '[^/]',
      _ => RegExp.escape(ch),
    });
  }
  buffer.write(r'$');
  return RegExp(buffer.toString(), caseSensitive: !Platform.isWindows);
}

String _relative(String root, String path) =>
    path.length > root.length ? path.substring(root.length + 1) : '.';

/// Breadth-first walk without following symlinks; skips Hard-Deny entries.
Iterable<(String, FileSystemEntity)> _walk(String root, int maxDepth) sync* {
  var level = <String>[root];
  for (var depth = 1; depth <= maxDepth && level.isNotEmpty; depth++) {
    final next = <String>[];
    for (final dir in level) {
      List<FileSystemEntity> children;
      try {
        children = Directory(dir).listSync(followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
      } on FileSystemException {
        continue;
      }
      for (final child in children) {
        final path = normalizeHostPath(child.path, windows: Platform.isWindows);
        if (path == null || !_walkable(path)) continue;
        yield (path, child);
        if (child is Directory) next.add(path);
      }
    }
    level = next;
  }
}

List<int> _readText(String path) {
  final file = File(path);
  if (!file.existsSync()) throw _fail('fs_not_found');
  final length = file.lengthSync();
  if (length > _maxReadBytes) throw _fail('fs_file_too_large');
  final bytes = file.readAsBytesSync();
  if (bytes.take(8192).contains(0)) throw _fail('fs_binary_file');
  return bytes;
}

Future<({int bytes, bool created, String sha})> _writeWithOptionalJournal({
  required ToolExecutionContext context,
  required String toolName,
  required String path,
  required List<int> bytes,
  required bool createParents,
  String? expectedPreSha256,
  bool expectNotExists = false,
}) async {
  final journal = context.fsUndoJournal;
  final shellControl = context.policy?.shellControl;
  final home = context.execFsContext?.homeDirectory ?? hostHomeDirectory();
  if (journal != null &&
      journal.canJournalSingleWrite(
        rawPath: path,
        newBytesLength: bytes.length,
        shellControl: shellControl,
        homeDirectory: home,
      )) {
    final tx = await journal.applyTransaction(
      toolName: toolName,
      changes: <FsPlannedChange>[
        FsPlannedChange(
          path: path,
          newBytes: bytes,
          createParents: createParents,
          expectedPreSha256: expectedPreSha256,
          expectNotExists: expectNotExists,
        ),
      ],
      shellControl: shellControl,
      homeDirectory: home,
      nowUtc: context.nowUtc,
    );
    final file = tx.files.single;
    return (
      bytes: file.bytesWritten,
      created: file.created,
      sha: file.sha256Hex!,
    );
  }
  // Ineligible for undo journaling (e.g. R3 write outside workspace roots,
  // R3 secret file, or file larger than the per-file backup cap): still
  // perform an OS-atomic write without snapshotting to the undo journal.
  final direct = await atomicWriteFileDirect(
    targetPath: path,
    bytes: bytes,
    createParents: createParents,
  );
  return (bytes: direct.bytes, created: direct.created, sha: direct.sha256Hex);
}

class FsListFilesTool extends HostToolHandler {
  const FsListFilesTool();

  @override
  String get name => 'fs.list_files';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final root = _guard(context, args['path']! as String, FsAccessKind.read);
    if (!Directory(root).existsSync()) throw _fail('fs_not_a_directory');
    final glob = _globToRegExp(args['glob'] as String?);
    final maxEntries = (args['maxEntries'] as int?) ?? 100;
    final entries = <Map<String, Object?>>[];
    var truncated = false;
    for (final (path, entity) in _walk(root, (args['maxDepth'] as int?) ?? 3)) {
      final isDir = entity is Directory;
      if (glob != null && !isDir && !glob.hasMatch(path.split('/').last)) {
        continue;
      }
      if (entries.length >= maxEntries) {
        truncated = true;
        break;
      }
      entries.add(<String, Object?>{
        'path': _relative(root, path),
        'kind': isDir ? 'dir' : 'file',
        if (entity is File) 'sizeBytes': entity.lengthSync(),
      });
    }
    return ToolHandlerOutput(
      text: 'fs.list_files ${entries.length} entries',
      structuredContent: <String, Object?>{
        'entries': entries,
        'truncated': truncated,
        'totalReturned': entries.length,
      },
    );
  }
}

class FsReadFileTool extends HostToolHandler {
  const FsReadFileTool();

  @override
  String get name => 'fs.read_file';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final path = _guard(context, args['path']! as String, FsAccessKind.read);
    if (FileSystemEntity.isDirectorySync(path)) throw _fail('fs_not_a_file');
    final lines = const LineSplitter().convert(
      utf8.decode(_readText(path), allowMalformed: true),
    );
    final start = (args['startLine'] as int?) ?? 1;
    if (start > max(lines.length, 1)) {
      throw _fail('line_out_of_range', XtpStatus.invalidArgs);
    }
    final end = min((args['endLine'] as int?) ?? start + 399, lines.length);
    final slice = lines.isEmpty ? '' : lines.sublist(start - 1, end).join('\n');
    final redacted = redactBrowserSnapshot(slice, maxBytes: _maxOutputBytes);
    return ToolHandlerOutput(
      text: 'fs.read_file lines $start-$end of ${lines.length}',
      structuredContent: <String, Object?>{
        'content': redacted.text,
        'startLine': start,
        'endLine': end,
        'totalLines': lines.length,
        'truncated': redacted.truncated,
      },
    );
  }
}

class FsGrepTool extends HostToolHandler {
  const FsGrepTool();

  @override
  String get name => 'fs.grep';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final root = _guard(context, args['path']! as String, FsAccessKind.read);
    final pattern = args['pattern']! as String;
    final RegExp matcher;
    try {
      matcher = args['isRegex'] == true
          ? RegExp(pattern)
          : RegExp(RegExp.escape(pattern));
    } on FormatException {
      throw _fail('pattern_invalid', XtpStatus.invalidArgs);
    }
    final glob = _globToRegExp(args['glob'] as String?);
    final maxMatches = (args['maxMatches'] as int?) ?? 50;
    final isDir = Directory(root).existsSync();
    if (!isDir && !File(root).existsSync()) throw _fail('fs_not_found');
    final files = isDir
        ? _walk(root, 6).where((e) => e.$2 is File).map((e) => e.$1)
        : <String>[root];
    final matches = <Map<String, Object?>>[];
    final clock = Stopwatch()..start();
    var bytes = 0;
    var truncated = false;
    var scanned = 0;
    outer:
    for (final path in files) {
      if (++scanned > 2000 || clock.elapsed > const Duration(seconds: 4)) {
        truncated = true;
        break;
      }
      if (isSecretFileName(path)) continue;
      if (glob != null && !glob.hasMatch(path.split('/').last)) continue;
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > _maxGrepFileBytes) continue;
      final List<int> raw;
      try {
        raw = file.readAsBytesSync();
      } on FileSystemException {
        continue;
      }
      if (raw.take(8192).contains(0)) continue;
      final lines = const LineSplitter().convert(
        utf8.decode(raw, allowMalformed: true),
      );
      for (var i = 0; i < lines.length; i++) {
        if (!matcher.hasMatch(lines[i])) continue;
        final text = redactSensitiveTokens(lines[i].trim(), maxChars: 400);
        final rel = isDir ? _relative(root, path) : path.split('/').last;
        bytes += utf8.encode(text).length + rel.length + 32;
        if (matches.length >= maxMatches || bytes > _maxOutputBytes) {
          truncated = true;
          break outer;
        }
        matches.add(<String, Object?>{
          'path': rel,
          'line': i + 1,
          'text': text,
        });
      }
    }
    return ToolHandlerOutput(
      text: 'fs.grep ${matches.length} matches',
      structuredContent: <String, Object?>{
        'matches': matches,
        'truncated': truncated,
        'totalReturned': matches.length,
      },
    );
  }
}

class FsWriteFileTool extends HostToolHandler {
  const FsWriteFileTool();

  @override
  String get name => 'fs.write_file';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final path = _guard(context, args['path']! as String, FsAccessKind.write);
    if (FileSystemEntity.isDirectorySync(path)) throw _fail('fs_not_a_file');
    if (args['overwrite'] == false && File(path).existsSync()) {
      throw _fail('fs_exists');
    }
    final result = await _writeWithOptionalJournal(
      context: context,
      toolName: name,
      path: path,
      bytes: utf8.encode(args['content']! as String),
      createParents: args['createParents'] != false,
      expectNotExists: args['overwrite'] == false,
    );
    return ToolHandlerOutput(
      text: 'fs.write_file ${result.bytes} bytes',
      structuredContent: <String, Object?>{
        'bytesWritten': result.bytes,
        'created': result.created,
        'sha256': result.sha,
      },
      toastBody: 'đã ghi tệp',
    );
  }
}

class FsPatchFileTool extends HostToolHandler {
  const FsPatchFileTool();

  @override
  String get name => 'fs.patch_file';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final args = context.arguments;
    final path = _guard(context, args['path']! as String, FsAccessKind.write);
    if (FileSystemEntity.isDirectorySync(path)) throw _fail('fs_not_a_file');
    final originalBytes = _readText(path);
    final original = utf8.decode(originalBytes);
    final preSha = sha256.convert(originalBytes).toString();
    final target = args['target']! as String;
    final count = target.allMatches(original).length;
    if (count == 0) throw _fail('patch_target_not_found');
    if (count > 1 && args['replaceAll'] != true) {
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'patch_target_ambiguous',
        message:
            'target occurs $count times; pass replaceAll or a longer target',
      );
    }
    final replacement = args['replacement']! as String;
    final updated = args['replaceAll'] == true
        ? original.replaceAll(target, replacement)
        : original.replaceFirst(target, replacement);
    final result = await _writeWithOptionalJournal(
      context: context,
      toolName: name,
      path: path,
      bytes: utf8.encode(updated),
      createParents: false,
      expectedPreSha256: preSha,
    );
    return ToolHandlerOutput(
      text: 'fs.patch_file $count replacement(s)',
      structuredContent: <String, Object?>{
        'replacements': count,
        'bytesWritten': result.bytes,
        'sha256': result.sha,
      },
      toastBody: 'đã sửa tệp',
    );
  }
}

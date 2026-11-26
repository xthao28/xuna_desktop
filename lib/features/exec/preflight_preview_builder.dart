import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

const int _maxPreviewSourceBytes = 2 * 1024 * 1024;
const int _maxGlobScanEntries = 500;
const Duration _maxGlobScanTime = Duration(milliseconds: 200);

const Set<String> _deleteCommandNames = <String>{
  'rm',
  'del',
  'erase',
  'unlink',
  'rmdir',
  'rd',
};

const Set<String> _transparentWrappers = <String>{
  'command',
  'builtin',
  'exec',
  'nohup',
  'time',
  'nice',
  'caffeinate',
};

/// Generates an optional, bounded, read-only `xuna/preflight` preview
/// (`XUNA_XTP_V1_CONTRACT.md` §4.2.8, `ADR-0019` §2 / `W4-M2`).
///
/// Strict invariants:
/// - Read-only: never writes, creates, or deletes any file.
/// - Never previews secret files (`.env*`, `*.pem`, `*.key`, etc.), Hard-Deny
///   paths, home dotfiles, system paths, binary files, or files > `2 MiB`.
/// - Diff snippets are redacted for sensitive tokens and bounded to `<= 2048`
///   UTF-8 bytes and `<= 40` lines (ending with `'…'` when truncated).
/// - Destructive command expansion runs only for single-segment file deletion
///   commands whose targets stay strictly inside configured `workspaceRoots`;
///   any escape, Hard-Deny, or secret match fails closed to `null` (M2-2 Option A).
XtpPreflightPreview? buildPreflightPreview({
  required String toolName,
  required Map<String, Object?> arguments,
  required ShellControlPolicy? shellControl,
  String? homeDirectory,
  bool? isWindowsOverride,
  String? Function(String normalizedPath)? resolveRealPath,
}) {
  final isWin = isWindowsOverride ?? Platform.isWindows;
  final caseInsensitive = isWin || Platform.isMacOS;
  final realPathFn = resolveRealPath ?? resolveHostRealPath;
  final home = homeDirectory ?? hostHomeDirectory();
  try {
    if (toolName == 'fs.patch_file') {
      return _buildFsPatchPreview(
        arguments: arguments,
        shellControl: shellControl,
        homeDirectory: home,
        windows: isWin,
        caseInsensitive: caseInsensitive,
        realPathFn: realPathFn,
      );
    }
    if (toolName == 'fs.write_file') {
      return _buildFsWritePreview(
        arguments: arguments,
        shellControl: shellControl,
        homeDirectory: home,
        windows: isWin,
        caseInsensitive: caseInsensitive,
        realPathFn: realPathFn,
      );
    }
    if (toolName == 'exec.run') {
      return _buildExecDeletePreview(
        arguments: arguments,
        shellControl: shellControl,
        homeDirectory: home,
        windows: isWin,
        caseInsensitive: caseInsensitive,
        realPathFn: realPathFn,
      );
    }
  } on Object {
    // Fail-closed: preview is strictly advisory and never breaks preflight.
    return null;
  }
  return null;
}

XtpPreflightPreview? _buildFsPatchPreview({
  required Map<String, Object?> arguments,
  required ShellControlPolicy? shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  final rawPath = arguments['path'];
  final target = arguments['target'];
  final replacement = arguments['replacement'];
  if (rawPath is! String ||
      target is! String ||
      target.isEmpty ||
      replacement is! String) {
    return null;
  }
  final checked = _validateFsPreviewTarget(
    rawPath: rawPath,
    shellControl: shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPathFn: realPathFn,
  );
  if (checked == null) return null;

  final original = _readUtf8TextOrNull(checked.normalizedPath);
  if (original == null) return null;

  final count = target.allMatches(original).length;
  final replaceAll = arguments['replaceAll'] == true;
  if (count == 0 || (count > 1 && !replaceAll)) return null;

  final updated = replaceAll
      ? original.replaceAll(target, replacement)
      : original.replaceFirst(target, replacement);
  final rawDiff = _buildCompactUnifiedDiff(
    displayName: checked.displayName,
    beforeText: original,
    afterText: updated,
    isCreate: false,
  );
  final summary = _safeSummary(
    '${checked.displayName}: $count replacement${count == 1 ? '' : 's'}',
  );
  return _finalizeDiffPreview(summary: summary, rawDiff: rawDiff);
}

XtpPreflightPreview? _buildFsWritePreview({
  required Map<String, Object?> arguments,
  required ShellControlPolicy? shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  final rawPath = arguments['path'];
  final content = arguments['content'];
  if (rawPath is! String || content is! String) return null;

  final checked = _validateFsPreviewTarget(
    rawPath: rawPath,
    shellControl: shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPathFn: realPathFn,
  );
  if (checked == null) return null;

  final file = File(checked.normalizedPath);
  if (FileSystemEntity.isDirectorySync(checked.normalizedPath)) return null;
  final existed = file.existsSync();
  if (arguments['overwrite'] == false && existed) return null;

  if (!existed) {
    final newLines = _splitLines(content);
    final rawDiff = _buildCompactUnifiedDiff(
      displayName: checked.displayName,
      beforeText: '',
      afterText: content,
      isCreate: true,
    );
    final summary = _safeSummary(
      '${checked.displayName}: create (${newLines.length} line${newLines.length == 1 ? '' : 's'})',
    );
    return _finalizeDiffPreview(summary: summary, rawDiff: rawDiff);
  }

  final original = _readUtf8TextOrNull(checked.normalizedPath);
  if (original == null) return null;
  final rawDiff = _buildCompactUnifiedDiff(
    displayName: checked.displayName,
    beforeText: original,
    afterText: content,
    isCreate: false,
  );
  final summary = _safeSummary('${checked.displayName}: overwrite');
  return _finalizeDiffPreview(summary: summary, rawDiff: rawDiff);
}

({String normalizedPath, String displayName})? _validateFsPreviewTarget({
  required String rawPath,
  required ShellControlPolicy? shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  final normalized = normalizeHostPath(
    rawPath,
    homeDirectory: homeDirectory,
    windows: windows,
  );
  if (normalized == null) return null;
  final resolved = realPathFn(normalized);
  if (hardDeniedPathReason(normalized) != null ||
      (resolved != null && hardDeniedPathReason(resolved) != null)) {
    return null;
  }
  if (isSecretFileName(normalized) ||
      (resolved != null && isSecretFileName(resolved))) {
    return null;
  }
  final effectivePolicy = shellControl ?? const ShellControlPolicy.disabled();
  final decision = classifyFsPath(
    normalizedPath: normalized,
    resolvedPath: resolved,
    access: FsAccessKind.write,
    shellControl: effectivePolicy,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPath: realPathFn,
  );
  if (decision.denied ||
      decision.reasonCode == 'secret_file' ||
      decision.reasonCode == 'dotfile_target' ||
      decision.reasonCode == 'system_target') {
    return null;
  }
  final display = _workspaceRelativeOrBasename(
    normalizedPath: normalized,
    shellControl: effectivePolicy,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPathFn: realPathFn,
  );
  return (normalizedPath: normalized, displayName: display);
}

String? _readUtf8TextOrNull(String path) {
  final file = File(path);
  if (!file.existsSync() || FileSystemEntity.isDirectorySync(path)) {
    return null;
  }
  if (file.lengthSync() > _maxPreviewSourceBytes) return null;
  final bytes = file.readAsBytesSync();
  if (bytes.take(8192).contains(0)) return null;
  return utf8.decode(bytes, allowMalformed: true);
}

List<String> _splitLines(String text) {
  final normalized = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  if (normalized.isEmpty) return const <String>[];
  final lines = normalized.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }
  return lines;
}

String _buildCompactUnifiedDiff({
  required String displayName,
  required String beforeText,
  required String afterText,
  required bool isCreate,
}) {
  final out = <String>[];
  if (isCreate) {
    out.add('--- /dev/null');
    out.add('+++ b/$displayName');
    final afterLines = _splitLines(afterText);
    if (afterLines.isEmpty) {
      out.add('@@ -0,0 +0,0 @@');
    } else {
      out.add('@@ -0,0 +1,${afterLines.length} @@');
      for (final line in afterLines) {
        out.add('+$line');
      }
    }
    return out.join('\n');
  }

  final before = _splitLines(beforeText);
  final after = _splitLines(afterText);
  out.add('--- a/$displayName');
  out.add('+++ b/$displayName');

  var prefix = 0;
  final minLen = min(before.length, after.length);
  while (prefix < minLen && before[prefix] == after[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < minLen - prefix &&
      before[before.length - 1 - suffix] == after[after.length - 1 - suffix]) {
    suffix++;
  }

  if (prefix == before.length && prefix == after.length) {
    out.add('@@ -0,0 +0,0 @@');
    out.add(' (no changes)');
    return out.join('\n');
  }

  const contextLines = 2;
  final oldStart = max(0, prefix - contextLines);
  final oldEnd = min(before.length, before.length - suffix + contextLines);
  final newStart = max(0, prefix - contextLines);
  final newEnd = min(after.length, after.length - suffix + contextLines);
  final oldCount = oldEnd - oldStart;
  final newCount = newEnd - newStart;
  out.add('@@ -${oldStart + 1},$oldCount +${newStart + 1},$newCount @@');

  for (var i = oldStart; i < prefix; i++) {
    out.add(' ${before[i]}');
  }
  for (var i = prefix; i < before.length - suffix; i++) {
    out.add('-${before[i]}');
  }
  for (var i = prefix; i < after.length - suffix; i++) {
    out.add('+${after[i]}');
  }
  final tailStartBefore = before.length - suffix;
  for (var i = tailStartBefore; i < oldEnd; i++) {
    out.add(' ${before[i]}');
  }
  return out.join('\n');
}

XtpPreflightPreview? _finalizeDiffPreview({
  required String summary,
  required String rawDiff,
}) {
  // Redact sensitive tokens before truncating so partial tokens are never cut
  // in half and leaked.
  final redacted = redactBrowserSnapshot(rawDiff, maxBytes: 65536).text;
  final cleaned = redacted
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .replaceAll(RegExp(r'[\u0000-\u0008\u000B-\u001F\u007F]'), ' ');
  if (cleaned.trim().isEmpty) return null;

  var lines = cleaned.split('\n');
  var truncated = false;
  if (lines.length > XtpPreflightPreview.maxSnippetLines) {
    lines = <String>[
      ...lines.take(XtpPreflightPreview.maxSnippetLines - 1),
      XtpPreflightPreview.truncationMarker,
    ];
    truncated = true;
  }
  var snippet = lines.join('\n');

  final encoded = utf8.encode(snippet);
  if (encoded.length > XtpPreflightPreview.maxSnippetBytes) {
    truncated = true;
    final markerBytes = utf8.encode(XtpPreflightPreview.truncationMarker);
    var limit = XtpPreflightPreview.maxSnippetBytes - markerBytes.length;
    while (limit > 0 && (encoded[limit - 1] & 0xC0) == 0x80) {
      limit--;
    }
    if (limit > 0 && (encoded[limit - 1] & 0x80) != 0) {
      limit--;
    }
    final prefix = utf8.decode(encoded.sublist(0, limit), allowMalformed: true);
    snippet = '$prefix${XtpPreflightPreview.truncationMarker}';
  } else if (truncated &&
      !snippet.endsWith(XtpPreflightPreview.truncationMarker)) {
    final markerBytes = utf8.encode(XtpPreflightPreview.truncationMarker);
    final available = XtpPreflightPreview.maxSnippetBytes - markerBytes.length;
    if (encoded.length <= available) {
      snippet = '$snippet${XtpPreflightPreview.truncationMarker}';
    } else {
      var limit = available;
      while (limit > 0 && (encoded[limit - 1] & 0xC0) == 0x80) {
        limit--;
      }
      if (limit > 0 && (encoded[limit - 1] & 0x80) != 0) {
        limit--;
      }
      snippet =
          '${utf8.decode(encoded.sublist(0, limit), allowMalformed: true)}${XtpPreflightPreview.truncationMarker}';
    }
  }

  return XtpPreflightPreview.diff(
    summary: summary,
    snippet: snippet,
    truncated: truncated,
  );
}

XtpPreflightPreview? _buildExecDeletePreview({
  required Map<String, Object?> arguments,
  required ShellControlPolicy? shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  if (shellControl == null ||
      !shellControl.enabled ||
      shellControl.workspaceRoots.isEmpty) {
    return null;
  }
  final command = arguments['command'];
  final rawCwd = arguments['cwd'];
  if (command is! String ||
      command.trim().isEmpty ||
      rawCwd is! String ||
      rawCwd.trim().isEmpty) {
    return null;
  }
  final cwd = normalizeHostPath(
    rawCwd,
    homeDirectory: homeDirectory,
    windows: windows,
  );
  if (cwd == null) return null;
  final realCwd = realPathFn(cwd);
  if (!_isStrictlyInsideWorkspace(
    cwd,
    realCwd,
    shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPathFn: realPathFn,
  )) {
    return null;
  }
  if (!Directory(cwd).existsSync()) return null;

  final lex = lexExecCommand(command, windows: windows);
  if (lex.malformed ||
      lex.hasHeredoc ||
      lex.substitutions.isNotEmpty ||
      lex.segments.length != 1) {
    return null;
  }
  final segment = lex.segments.single;
  if (segment.writeTargets.isNotEmpty || segment.readTargets.isNotEmpty) {
    return null;
  }
  final words = segment.words;
  var k = 0;
  while (k < words.length &&
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[k].text)) {
    k++;
  }
  while (k < words.length) {
    final name = _exeName(words[k].text, windows);
    if (_transparentWrappers.contains(name)) {
      k++;
      while (k < words.length && words[k].text.startsWith('-')) {
        k++;
      }
    } else if (name == 'env') {
      k++;
      while (k < words.length &&
          (words[k].text.startsWith('-') || words[k].text.contains('='))) {
        if (words[k].text == '-S' || words[k].text.startsWith('--split')) {
          return null;
        }
        k++;
      }
    } else {
      break;
    }
  }
  if (k >= words.length) return null;
  final exeWord = words[k];
  if (exeWord.hasExpansion) return null;
  final exe = _exeName(exeWord.text, windows);
  if (!_deleteCommandNames.contains(exe)) return null;

  final isWindowsSwitchExe =
      windows && const <String>{'del', 'erase', 'rd', 'rmdir'}.contains(exe);
  var recursive = false;
  var afterDoubleDash = false;
  final targetWords = <ExecWord>[];
  for (final w in words.skip(k + 1)) {
    final text = w.text;
    if (!afterDoubleDash && text == '--') {
      afterDoubleDash = true;
      continue;
    }
    if (!afterDoubleDash && text.startsWith('-') && text.length > 1) {
      if (text == '--recursive' || RegExp(r'^-[A-Za-z]*[rR]').hasMatch(text)) {
        recursive = true;
      }
      continue;
    }
    if (!afterDoubleDash &&
        isWindowsSwitchExe &&
        text.startsWith('/') &&
        text.length <= 4 &&
        !text.contains('*', 1)) {
      if (text.toLowerCase() == '/s') recursive = true;
      continue;
    }
    targetWords.add(w);
  }
  if (targetWords.isEmpty) return null;

  final clock = Stopwatch()..start();
  var scanned = 0;
  var hitScanLimit = false;
  final matchedRelPaths = <String>{};

  bool addMatch(String normalizedTarget) {
    final resolvedTarget = realPathFn(normalizedTarget);
    if (hardDeniedPathReason(normalizedTarget) != null ||
        (resolvedTarget != null &&
            hardDeniedPathReason(resolvedTarget) != null)) {
      return false; // Fail-closed on Hard-Deny hit.
    }
    if (isSecretFileName(normalizedTarget) ||
        (resolvedTarget != null && isSecretFileName(resolvedTarget))) {
      return false; // Fail-closed on secret file hit.
    }
    if (!_isStrictlyInsideWorkspace(
      normalizedTarget,
      resolvedTarget,
      shellControl,
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPathFn: realPathFn,
    )) {
      return false; // Fail-closed on workspace escape.
    }
    final rel = _workspaceRelativeOrNull(
      normalizedPath: normalizedTarget,
      shellControl: shellControl,
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPathFn: realPathFn,
    );
    if (rel == null ||
        rel.isEmpty ||
        rel.length > XtpPreflightPreview.maxPathChars) {
      return false;
    }
    matchedRelPaths.add(rel);
    return true;
  }

  for (final tw in targetWords) {
    if (tw.hasExpansion) return null;
    final rawTarget = tw.text.trim();
    if (rawTarget.isEmpty) return null;

    final slashTarget = windows ? rawTarget.replaceAll(r'\', '/') : rawTarget;
    final hasGlob = slashTarget.contains('*') || slashTarget.contains('?');
    if (!hasGlob) {
      final norm = normalizeHostPath(
        slashTarget,
        homeDirectory: homeDirectory,
        baseDirectory: cwd,
        windows: windows,
      );
      if (norm == null) return null;
      final resolved = realPathFn(norm);
      if (hardDeniedPathReason(norm) != null ||
          (resolved != null && hardDeniedPathReason(resolved) != null) ||
          isSecretFileName(norm) ||
          (resolved != null && isSecretFileName(resolved))) {
        return null;
      }
      if (!_isStrictlyInsideWorkspace(
        norm,
        resolved,
        shellControl,
        homeDirectory: homeDirectory,
        windows: windows,
        caseInsensitive: caseInsensitive,
        realPathFn: realPathFn,
      )) {
        return null;
      }
      final type = FileSystemEntity.typeSync(norm, followLinks: false);
      if (type == FileSystemEntityType.file) {
        if (!addMatch(norm)) return null;
      } else if (type == FileSystemEntityType.directory) {
        if (recursive) {
          final ok = _walkDirectoryForDelete(
            dirPath: norm,
            windows: windows,
            clock: clock,
            onEntry: (entryPath) {
              if (++scanned > _maxGlobScanEntries ||
                  clock.elapsed > _maxGlobScanTime) {
                hitScanLimit = true;
                return _WalkStep.stop;
              }
              return addMatch(entryPath) ? _WalkStep.cont : _WalkStep.abort;
            },
          );
          if (!ok) return null;
        } else {
          if (!addMatch(norm)) return null;
        }
      }
      continue;
    }

    // Split glob target into deterministic non-glob base directory + glob segments.
    final split = _splitGlobTarget(
      slashTarget: slashTarget,
      cwd: cwd,
      homeDirectory: homeDirectory,
      windows: windows,
    );
    if (split == null) return null;
    final realBase = realPathFn(split.baseDir);
    if (!_isStrictlyInsideWorkspace(
      split.baseDir,
      realBase,
      shellControl,
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPathFn: realPathFn,
    )) {
      return null;
    }
    if (!Directory(split.baseDir).existsSync()) continue;

    final globSegments =
        recursive &&
            isWindowsSwitchExe &&
            (exe == 'del' || exe == 'erase') &&
            split.globSegments.length == 1
        ? <String>['**', split.globSegments.single]
        : split.globSegments;

    final ok = _expandGlobSegments(
      currentDir: split.baseDir,
      segments: globSegments,
      segIndex: 0,
      windows: windows,
      caseInsensitive: caseInsensitive,
      recursiveDelete: recursive,
      clock: clock,
      checkLimit: () {
        if (++scanned > _maxGlobScanEntries ||
            clock.elapsed > _maxGlobScanTime) {
          hitScanLimit = true;
          return true;
        }
        return false;
      },
      onMatch: addMatch,
    );
    if (!ok) return null;
  }

  final sorted = matchedRelPaths.toList()..sort();
  final totalCount = sorted.length;
  final shown = sorted.take(XtpPreflightPreview.maxPaths).toList();
  final truncated = hitScanLimit || totalCount > shown.length;
  final summary = _safeSummary(
    '$totalCount matching file${totalCount == 1 ? '' : 's'} in workspace',
  );
  return XtpPreflightPreview.paths(
    summary: summary,
    paths: shown,
    totalCount: totalCount,
    truncated: truncated,
  );
}

enum _WalkStep { cont, stop, abort }

bool _walkDirectoryForDelete({
  required String dirPath,
  required bool windows,
  required Stopwatch clock,
  required _WalkStep Function(String normalizedPath) onEntry,
}) {
  final queue = <String>[dirPath];
  while (queue.isNotEmpty) {
    final current = queue.removeAt(0);
    List<FileSystemEntity> children;
    try {
      children = Directory(current).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      continue;
    }
    for (final child in children) {
      final norm = normalizeHostPath(child.path, windows: windows);
      if (norm == null) return false;
      if (child is Link) {
        final step = onEntry(norm);
        if (step == _WalkStep.abort) return false;
        if (step == _WalkStep.stop) return true;
        continue;
      }
      if (child is Directory) {
        if (hardDeniedPathReason(norm) != null) return false;
        queue.add(norm);
        continue;
      }
      final step = onEntry(norm);
      if (step == _WalkStep.abort) return false;
      if (step == _WalkStep.stop) return true;
    }
  }
  return true;
}

({String baseDir, List<String> globSegments})? _splitGlobTarget({
  required String slashTarget,
  required String cwd,
  required String? homeDirectory,
  required bool windows,
}) {
  final isAbs =
      slashTarget.startsWith('/') ||
      slashTarget.startsWith('~') ||
      (windows && RegExp(r'^[A-Za-z]:/').hasMatch(slashTarget));
  final joined = isAbs ? slashTarget : '$cwd/$slashTarget';
  final rawSegments = joined.split('/');
  final firstGlobIdx = rawSegments.indexWhere(
    (s) => s.contains('*') || s.contains('?'),
  );
  if (firstGlobIdx < 0) return null;
  final tail = rawSegments
      .sublist(firstGlobIdx)
      .where((s) => s.isNotEmpty)
      .toList();
  // Reject any `..` traversal anywhere after a glob segment.
  if (tail.isEmpty || tail.contains('..')) return null;
  final baseRaw = rawSegments.sublist(0, firstGlobIdx).join('/');
  final baseNorm = normalizeHostPath(
    baseRaw.isEmpty ? '/' : baseRaw,
    homeDirectory: homeDirectory,
    windows: windows,
  );
  if (baseNorm == null) return null;
  return (baseDir: baseNorm, globSegments: tail);
}

bool _expandGlobSegments({
  required String currentDir,
  required List<String> segments,
  required int segIndex,
  required bool windows,
  required bool caseInsensitive,
  required bool recursiveDelete,
  required Stopwatch clock,
  required bool Function() checkLimit,
  required bool Function(String normalizedPath) onMatch,
}) {
  if (segIndex >= segments.length) return true;
  final seg = segments[segIndex];
  final isLast = segIndex == segments.length - 1;

  if (seg == '**') {
    // Zero-segment match for `**`:
    if (!isLast) {
      final okZero = _expandGlobSegments(
        currentDir: currentDir,
        segments: segments,
        segIndex: segIndex + 1,
        windows: windows,
        caseInsensitive: caseInsensitive,
        recursiveDelete: recursiveDelete,
        clock: clock,
        checkLimit: checkLimit,
        onMatch: onMatch,
      );
      if (!okZero) return false;
    }
    List<FileSystemEntity> children;
    try {
      children = Directory(currentDir).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
    } on FileSystemException {
      return true;
    }
    for (final child in children) {
      if (checkLimit()) return true;
      final norm = normalizeHostPath(child.path, windows: windows);
      if (norm == null) return false;
      if (hardDeniedPathReason(norm) != null) return false;
      if (child is Directory) {
        final okSub = _expandGlobSegments(
          currentDir: norm,
          segments: segments,
          segIndex: segIndex,
          windows: windows,
          caseInsensitive: caseInsensitive,
          recursiveDelete: recursiveDelete,
          clock: clock,
          checkLimit: checkLimit,
          onMatch: onMatch,
        );
        if (!okSub) return false;
      } else if (isLast) {
        if (!onMatch(norm)) return false;
      }
    }
    return true;
  }

  final matcher = _globSegmentToRegExp(seg, caseInsensitive: caseInsensitive);
  List<FileSystemEntity> children;
  try {
    children = Directory(currentDir).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
  } on FileSystemException {
    return true;
  }
  for (final child in children) {
    if (checkLimit()) return true;
    final norm = normalizeHostPath(child.path, windows: windows);
    if (norm == null) return false;
    final name = norm.split('/').last;
    if (!matcher.hasMatch(name)) continue;

    if (isLast) {
      if (child is Directory && recursiveDelete) {
        if (hardDeniedPathReason(norm) != null) return false;
        final okWalk = _walkDirectoryForDelete(
          dirPath: norm,
          windows: windows,
          clock: clock,
          onEntry: (entryPath) {
            if (checkLimit()) return _WalkStep.stop;
            return onMatch(entryPath) ? _WalkStep.cont : _WalkStep.abort;
          },
        );
        if (!okWalk) return false;
      } else if (child is! Directory || recursiveDelete) {
        if (!onMatch(norm)) return false;
      }
    } else if (child is Directory) {
      if (hardDeniedPathReason(norm) != null) return false;
      final okNext = _expandGlobSegments(
        currentDir: norm,
        segments: segments,
        segIndex: segIndex + 1,
        windows: windows,
        caseInsensitive: caseInsensitive,
        recursiveDelete: recursiveDelete,
        clock: clock,
        checkLimit: checkLimit,
        onMatch: onMatch,
      );
      if (!okNext) return false;
    }
  }
  return true;
}

RegExp _globSegmentToRegExp(String pattern, {required bool caseInsensitive}) {
  final buf = StringBuffer('^');
  for (final ch in pattern.split('')) {
    buf.write(switch (ch) {
      '*' => '.*',
      '?' => '.',
      _ => RegExp.escape(ch),
    });
  }
  buf.write(r'$');
  return RegExp(buf.toString(), caseSensitive: !caseInsensitive);
}

bool _isStrictlyInsideWorkspace(
  String normalized,
  String? resolved,
  ShellControlPolicy shellControl, {
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  if (hardDeniedPathReason(normalized) != null) return false;
  if (resolved != null && hardDeniedPathReason(resolved) != null) return false;
  final insideNorm = isInsideWorkspaceRoots(
    normalized,
    shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPath: realPathFn,
  );
  if (!insideNorm) return false;
  if (resolved != null && resolved != normalized) {
    return isInsideWorkspaceRoots(
      resolved,
      shellControl,
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPath: realPathFn,
    );
  }
  return true;
}

String? _workspaceRelativeOrNull({
  required String normalizedPath,
  required ShellControlPolicy shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  final normCheck = caseInsensitive
      ? normalizedPath.toLowerCase()
      : normalizedPath;
  for (final rawRoot in shellControl.workspaceRoots) {
    final root = normalizeHostPath(
      rawRoot,
      homeDirectory: homeDirectory,
      windows: windows,
    );
    if (root == null) continue;
    final candidates = <String>[root];
    final realRoot = realPathFn(root);
    if (realRoot != null && realRoot != root) candidates.add(realRoot);
    for (final candidate in candidates) {
      var cleanRoot = candidate;
      if (cleanRoot.length > 1 && cleanRoot.endsWith('/')) {
        cleanRoot = cleanRoot.substring(0, cleanRoot.length - 1);
      }
      final rootCheck = caseInsensitive ? cleanRoot.toLowerCase() : cleanRoot;
      if (normCheck == rootCheck) return '.';
      if (normCheck.startsWith('$rootCheck/')) {
        return normalizedPath.substring(cleanRoot.length + 1);
      }
    }
  }
  return null;
}

String _workspaceRelativeOrBasename({
  required String normalizedPath,
  required ShellControlPolicy shellControl,
  required String? homeDirectory,
  required bool windows,
  required bool caseInsensitive,
  required String? Function(String) realPathFn,
}) {
  final rel = _workspaceRelativeOrNull(
    normalizedPath: normalizedPath,
    shellControl: shellControl,
    homeDirectory: homeDirectory,
    windows: windows,
    caseInsensitive: caseInsensitive,
    realPathFn: realPathFn,
  );
  if (rel != null && rel.isNotEmpty && rel != '.') return rel;
  final idx = normalizedPath.lastIndexOf('/');
  return idx >= 0 ? normalizedPath.substring(idx + 1) : normalizedPath;
}

String _exeName(String word, bool windows) {
  var name = word.replaceAll(r'\', '/').split('/').last.toLowerCase();
  if (windows) {
    name = name.replaceFirst(RegExp(r'\.(exe|cmd|bat|com)$'), '');
  }
  return name;
}

String _safeSummary(String raw) {
  final redacted = redactSensitiveTokens(
    raw,
    maxChars: XtpPreflightPreview.maxSummaryChars,
  ).replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ').trim();
  if (redacted.length <= XtpPreflightPreview.maxSummaryChars) return redacted;
  return '${redacted.substring(0, XtpPreflightPreview.maxSummaryChars - 1)}…';
}

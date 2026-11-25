import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Resolution outcome for spawning a local stdio MCP/ACP process.
class ResolvedStdioCommand {
  const ResolvedStdioCommand({
    required this.executable,
    required this.args,
    required this.usesCmdShell,
    this.rawCmdLine,
  });

  final String executable;
  final List<String> args;
  final bool usesCmdShell;

  /// When [usesCmdShell] is true (a custom `.cmd`/`.bat` file that is not an
  /// npm Node shim), the safe command string for `cmd.exe /d /s /c`.
  final String? rawCmdLine;
}

/// Live JSON-RPC stdio child handle shared by `AutoMcpBridge`,
/// `AcpHarnessAdapter` and `McpStdioClient`.
class SpawnedStdioProcess {
  const SpawnedStdioProcess({
    required this.stdoutLines,
    required this.writeStdinLine,
    required this.exitCode,
    required this.terminate,
  });

  final Stream<String> stdoutLines;
  final void Function(String line) writeStdinLine;
  final Future<int> exitCode;
  final Future<void> Function() terminate;
}

const List<String> _defaultWindowsPathExt = <String>[
  '.com',
  '.exe',
  '.bat',
  '.cmd',
];
const Set<String> _supportedWindowsExts = <String>{
  '.com',
  '.exe',
  '.bat',
  '.cmd',
};
const int _maxShimBytes = 8192;

final RegExp _npmShimScriptPattern = RegExp(
  r'"%(?:~)?dp0%\\([^"\r\n]+\.(?:c|m)?js)"',
  caseSensitive: false,
);

/// Resolves [executable] and [args] for launching without a shell.
///
/// On Windows, `Process.start(..., runInShell: false)` does not consult
/// `PATHEXT` for `.cmd`/`.bat` shims (such as global `npm` binaries). This
/// resolver looks up `PATHEXT` across `PATH`:
/// 1. `.exe`/`.com` run directly (`runInShell: false`).
/// 2. `.cmd`/`.bat` npm shims are unwrapped to `node.exe <entry.js>` when both
///    files exist (avoiding `cmd.exe`, BatBadBut injection and orphan PIDs).
/// 3. Non-shim `.cmd`/`.bat` files fall back to `cmd.exe /d /s /c` using
///    strictly escaped arguments (rejecting control characters).
ResolvedStdioCommand resolveStdioCommand(
  String executable,
  List<String> args, {
  bool? isWindows,
  Map<String, String>? environment,
  bool Function(String path)? fileExists,
  String? Function(String path)? readFile,
}) {
  final win = isWindows ?? Platform.isWindows;
  if (!win) {
    return ResolvedStdioCommand(
      executable: executable,
      args: args,
      usesCmdShell: false,
    );
  }
  final env = environment ?? Platform.environment;
  final exists = fileExists ?? _defaultFileExists;
  final read = readFile ?? _defaultReadSmallFile;
  final exts = _parsePathExt(env);

  final resolved = _locateWindowsExecutable(
    executable,
    env: env,
    exts: exts,
    fileExists: exists,
  );
  if (resolved == null) {
    return ResolvedStdioCommand(
      executable: executable,
      args: args,
      usesCmdShell: false,
    );
  }
  if (isForbiddenProtocolHarnessExecutable(resolved)) {
    throw ProcessException(
      resolved,
      args,
      'Resolved executable is forbidden by protocol harness policy',
    );
  }

  final lower = resolved.toLowerCase();
  if (!lower.endsWith('.cmd') && !lower.endsWith('.bat')) {
    return ResolvedStdioCommand(
      executable: resolved,
      args: args,
      usesCmdShell: false,
    );
  }

  // Prefer unwrapping standard npm/pnpm/yarn `.cmd` shims straight to node.exe.
  final unwrapped = _tryUnwrapNpmCmdShim(
    resolved,
    args,
    env: env,
    fileExists: exists,
    readFile: read,
  );
  if (unwrapped != null) return unwrapped;

  // Fallback for custom `.cmd`/`.bat`: escape every token strictly and launch
  // via native `CreateProcessW` `cmd.exe /d /s /c` (no Dart `\"` mangling).
  final comspec = resolveWindowsComspecPath('cmd.exe', environment: env);
  final cmdLine = buildSafeBatchCommandLine(resolved, args);
  return ResolvedStdioCommand(
    executable: comspec,
    args: <String>['/d', '/s', '/c', cmdLine],
    usesCmdShell: true,
    rawCmdLine: cmdLine,
  );
}

/// Builds a strictly escaped `cmd.exe` invocation for a `.cmd`/`.bat` file and
/// its [args], rejecting NUL / CR / LF and metacharacter injection.
String buildSafeBatchCommandLine(String batchPath, List<String> args) {
  for (final token in <String>[batchPath, ...args]) {
    if (token.contains('\x00') ||
        token.contains('\r') ||
        token.contains('\n')) {
      throw ProcessException(
        batchPath,
        args,
        'Batch arguments must not contain NUL, CR, or LF',
      );
    }
  }
  return <String>[
    _escapeBatchArg(batchPath, isExecutable: true),
    for (final a in args) _escapeBatchArg(a, isExecutable: false),
  ].join(' ');
}

String _escapeBatchArg(String arg, {required bool isExecutable}) {
  if (arg.isEmpty) return '""';
  // Prevent cmd.exe variable expansion and quote-breaking inside batch calls.
  if (arg.contains('%') || arg.contains('!')) {
    throw ProcessException(
      arg,
      const <String>[],
      'Batch argument contains forbidden expansion character',
    );
  }
  if (!isExecutable && arg.contains('"')) {
    throw ProcessException(
      arg,
      const <String>[],
      'Batch argument contains unsupported double quote',
    );
  }
  final needsQuotes =
      isExecutable || RegExp(r'[\s&|<>()^;,\x27=]').hasMatch(arg);
  if (!needsQuotes) return arg;
  final safe = arg.replaceAll('"', '');
  return '"$safe"';
}

/// Spawns a local stdio JSON-RPC child process with Windows `PATHEXT` + `.cmd`
/// shim handling and clean process-tree teardown.
Future<SpawnedStdioProcess> startStdioJsonRpcProcess(
  String executable,
  List<String> args, {
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final resolved = resolveStdioCommand(executable, args);
  if (resolved.usesCmdShell &&
      Platform.isWindows &&
      resolved.rawCmdLine != null) {
    final mergedEnv = <String, String>{
      if (includeParentEnvironment) ...Platform.environment,
      ...?environment,
    };
    final handle = startWindowsNativeCmdProcess(
      comspec: resolved.executable,
      command: resolved.rawCmdLine!,
      cwd: Directory.current.path,
      environment: mergedEnv,
    );
    return _wrapNativeExecHandle(handle);
  }

  final process = await Process.start(
    resolved.executable,
    resolved.args,
    environment: environment,
    includeParentEnvironment: includeParentEnvironment,
    runInShell: false,
  );
  final lines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  return SpawnedStdioProcess(
    stdoutLines: lines,
    writeStdinLine: (line) => process.stdin.writeln(line),
    exitCode: process.exitCode,
    terminate: () async {
      try {
        await process.stdin.close();
      } catch (_) {}
      if (Platform.isWindows) {
        try {
          await Process.run('taskkill', <String>[
            '/PID',
            '${process.pid}',
            '/T',
            '/F',
          ]);
        } catch (_) {
          try {
            process.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
        return;
      }
      try {
        process.kill(ProcessSignal.sigterm);
      } catch (_) {}
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } catch (_) {
        try {
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
      }
    },
  );
}

SpawnedStdioProcess _wrapNativeExecHandle(dynamic handle) {
  final byteController = StreamController<List<int>>();
  final exitCompleter = Completer<int>();
  var closed = false;

  unawaited(() async {
    while (!closed) {
      try {
        final poll = await handle.poll();
        if (poll.data.isNotEmpty && !byteController.isClosed) {
          byteController.add(poll.data as List<int>);
        }
        if (poll.exited == true) {
          if (!exitCompleter.isCompleted) {
            exitCompleter.complete((poll.exitCode as int?) ?? -1);
          }
          break;
        }
      } on Object {
        if (!exitCompleter.isCompleted) exitCompleter.complete(-1);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    if (!byteController.isClosed) await byteController.close();
    await handle.release();
  }());

  final lines = byteController.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter());

  return SpawnedStdioProcess(
    stdoutLines: lines,
    writeStdinLine: (line) {
      if (closed) return;
      unawaited(handle.writeStdin(utf8.encode('$line\n')));
    },
    exitCode: exitCompleter.future,
    terminate: () async {
      if (closed) return;
      closed = true;
      try {
        await handle.killGroup(force: true);
      } catch (_) {}
      await handle.release();
      if (!exitCompleter.isCompleted) exitCompleter.complete(-1);
      if (!byteController.isClosed) await byteController.close();
    },
  );
}

List<String> _parsePathExt(Map<String, String> env) {
  final raw = env['PATHEXT'] ?? env['pathext'];
  if (raw == null || raw.trim().isEmpty) return _defaultWindowsPathExt;
  final out = <String>[];
  for (final part in raw.split(';')) {
    final ext = part.trim().toLowerCase();
    if (_supportedWindowsExts.contains(ext) && !out.contains(ext)) {
      out.add(ext);
    }
  }
  return out.isEmpty ? _defaultWindowsPathExt : out;
}

String? _locateWindowsExecutable(
  String executable, {
  required Map<String, String> env,
  required List<String> exts,
  required bool Function(String path) fileExists,
}) {
  final trimmed = executable.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  final hasKnownExt = _supportedWindowsExts.any(lower.endsWith);
  final hasPathSep = trimmed.contains(r'\') || trimmed.contains('/');

  if (hasPathSep) {
    if (fileExists(trimmed)) return trimmed;
    if (!hasKnownExt) {
      for (final ext in exts) {
        final candidate = '$trimmed$ext';
        if (fileExists(candidate)) return candidate;
      }
    }
    return null;
  }

  final rawPath = env['PATH'] ?? env['Path'] ?? env['path'] ?? '';
  for (final rawDir in rawPath.split(';')) {
    var dir = rawDir.trim();
    if (dir.startsWith('"') && dir.endsWith('"') && dir.length >= 2) {
      dir = dir.substring(1, dir.length - 1);
    }
    if (dir.isEmpty) continue;
    final sep = dir.endsWith(r'\') || dir.endsWith('/') ? '' : r'\';
    if (hasKnownExt) {
      final candidate = '$dir$sep$trimmed';
      if (fileExists(candidate)) return candidate;
      continue;
    }
    for (final ext in exts) {
      final candidate = '$dir$sep$trimmed$ext';
      if (fileExists(candidate)) return candidate;
    }
  }
  return null;
}

ResolvedStdioCommand? _tryUnwrapNpmCmdShim(
  String shimPath,
  List<String> args, {
  required Map<String, String> env,
  required bool Function(String path) fileExists,
  required String? Function(String path) readFile,
}) {
  final body = readFile(shimPath);
  if (body == null || body.isEmpty) return null;
  final match = _npmShimScriptPattern.firstMatch(body);
  if (match == null) return null;
  final relScript = match.group(1);
  if (relScript == null ||
      relScript.isEmpty ||
      relScript.contains('%') ||
      relScript.contains('&') ||
      relScript.contains('|')) {
    return null;
  }
  final lastSep = shimPath.lastIndexOf(RegExp(r'[\\/]'));
  if (lastSep < 0) return null;
  final shimDir = shimPath.substring(0, lastSep);
  final scriptPath = '$shimDir\\$relScript';
  if (!fileExists(scriptPath)) return null;

  final localNode = '$shimDir\\node.exe';
  final nodeExe = fileExists(localNode)
      ? localNode
      : _locateWindowsExecutable(
          'node.exe',
          env: env,
          exts: const <String>['.exe'],
          fileExists: fileExists,
        );
  if (nodeExe == null) return null;
  return ResolvedStdioCommand(
    executable: nodeExe,
    args: <String>[scriptPath, ...args],
    usesCmdShell: false,
  );
}

bool _defaultFileExists(String path) {
  try {
    return File(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

String? _defaultReadSmallFile(String path) {
  try {
    final file = File(path);
    if (!file.existsSync() || file.lengthSync() > _maxShimBytes) return null;
    return file.readAsStringSync();
  } on Object {
    return null;
  }
}

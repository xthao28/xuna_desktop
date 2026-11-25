import 'dart:async';
import 'dart:io';

import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Home directory of the agent user, or null when the OS does not report it.
String? hostHomeDirectory() {
  final env = Platform.environment;
  final home = Platform.isWindows ? env['USERPROFILE'] : env['HOME'];
  return (home == null || home.isEmpty) ? null : home;
}

/// Resolves symlinks of a normalized absolute path with `dart:io`.
///
/// For a path that does not exist yet (a new file), the nearest existing
/// ancestor is resolved and the missing tail re-appended, so a write through a
/// symlinked directory is classified by its real target. Returns null when
/// nothing could be resolved.
String? resolveHostRealPath(String normalizedPath) {
  final windows = Platform.isWindows;
  final missing = <String>[];
  var current = normalizedPath;
  for (var i = 0; i < 64; i++) {
    try {
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final real = File(current).resolveSymbolicLinksSync();
        final joined = missing.isEmpty
            ? real
            : '$real/${missing.reversed.join('/')}';
        return normalizeHostPath(joined, windows: windows);
      }
    } on FileSystemException {
      return null;
    }
    final slash = current.lastIndexOf('/');
    if (slash <= 0 || (windows && slash <= 2)) return null;
    missing.add(current.substring(slash + 1));
    current = current.substring(0, slash);
  }
  return null;
}

/// Builds the classification context passed to `xuna/preflight` and to every
/// `tools/call` evaluation of `fs.*` / `exec.*`.
ExecFsHostContext buildExecFsHostContext(ExecProcessRegistry? registry) =>
    ExecFsHostContext(
      homeDirectory: hostHomeDirectory(),
      windows: Platform.isWindows,
      caseInsensitive: Platform.isWindows || Platform.isMacOS,
      realPath: resolveHostRealPath,
      execTaskRisk: registry?.riskOf,
    );

String? _cachedLoginPath;

/// The `PATH` an interactive login would see on macOS.
///
/// A login-item GUI app inherits only the system default `PATH`, so developer
/// toolchains (Homebrew, fvm, language managers set up in `.zprofile`) would
/// not resolve. The value is read once from `/bin/zsh -l -c` started with a
/// minimal environment; only `PATH` is kept. Tools configured only in
/// `.zshrc` (interactive shells) are not visible. Falls back to the sanitized
/// inherited `PATH` plus the standard Homebrew prefixes.
Future<String?> _macLoginPath(String? fallback) async {
  final cached = _cachedLoginPath;
  if (cached != null) return cached;
  final env = Platform.environment;
  var path = <String>[
    if (fallback != null && fallback.isNotEmpty) fallback,
    '/opt/homebrew/bin',
    '/usr/local/bin',
  ].join(':');
  try {
    final result = await Process.run(
      '/bin/zsh',
      const <String>['-l', '-c', r'printf %s "$PATH"'],
      environment: <String, String>{
        if (env['HOME'] != null) 'HOME': env['HOME']!,
        if (env['USER'] != null) 'USER': env['USER']!,
        if (env['LOGNAME'] != null) 'LOGNAME': env['LOGNAME']!,
      },
      includeParentEnvironment: false,
    ).timeout(const Duration(seconds: 5));
    final out = (result.stdout as String).trim();
    if (result.exitCode == 0 &&
        out.isNotEmpty &&
        !out.contains('\n') &&
        out.length < 8192) {
      path = out;
    }
  } on Object {
    // Keep the fallback PATH: the probe is an optional convenience.
  }
  return _cachedLoginPath = path;
}

/// Environment for one `exec.run` child: the allowlist from
/// `sanitizeExecEnvironment`, `PWD`, a `TERM` matching the stdio mode and, on
/// macOS, the login-shell `PATH`.
Future<Map<String, String>> buildExecEnvironment({
  required String cwd,
  required bool pty,
}) async {
  final windows = Platform.isWindows;
  final env = sanitizeExecEnvironment(Platform.environment, windows: windows);
  if (Platform.isMacOS) {
    final path = await _macLoginPath(env['PATH']);
    if (path != null) env['PATH'] = path;
  }
  if (!windows) {
    env['PWD'] = cwd;
    env['TERM'] = pty ? 'xterm-256color' : 'dumb';
  }
  return env;
}

import 'dart:async';
import 'dart:convert';
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

const String _pathMarkerStart = '__XUNA_PATH_START__';
const String _pathMarkerEnd = '__XUNA_PATH_END__';

String? _cachedLoginPath;

/// Extracts the `PATH` printed between XUNA's sentinel markers, ignoring any
/// banner or MOTD lines that `.zshrc` may write to stdout. Returns `null` when
/// missing, malformed, or oversized.
String? extractMarkedShellPath(String stdoutText) {
  final start = stdoutText.lastIndexOf(_pathMarkerStart);
  if (start < 0) return null;
  final bodyStart = start + _pathMarkerStart.length;
  final end = stdoutText.indexOf(_pathMarkerEnd, bodyStart);
  if (end < 0) return null;
  final path = stdoutText.substring(bodyStart, end).trim();
  if (path.isEmpty ||
      path.length >= 8192 ||
      path.contains('\n') ||
      path.contains('\r') ||
      path.contains('\x00')) {
    return null;
  }
  return path;
}

/// Merges existing local macOS developer toolchain directories (such as `nvm`,
/// `fvm`, `bun`, `cargo`, `go`, `pyenv`, Homebrew) into [basePath] without
/// duplicating entries or reordering directories already present in [basePath].
String mergeMacToolchainPaths(
  String basePath, {
  required String? homeDirectory,
  required bool Function(String dir) dirExists,
  List<String> Function(String dir)? listSubdirs,
}) {
  final entries = <String>[];
  final seen = <String>{};
  void add(String raw) {
    final p = raw.trim();
    if (p.isEmpty || seen.contains(p)) return;
    seen.add(p);
    entries.add(p);
  }

  for (final part in basePath.split(':')) {
    add(part);
  }

  final candidates = <String>[];
  if (homeDirectory != null && homeDirectory.isNotEmpty) {
    final home = homeDirectory.endsWith('/')
        ? homeDirectory.substring(0, homeDirectory.length - 1)
        : homeDirectory;
    final nvmVersions = '$home/.nvm/versions/node';
    if (dirExists(nvmVersions) && listSubdirs != null) {
      final versions = listSubdirs(nvmVersions).toList()
        ..sort(_compareSemverDesc);
      for (final ver in versions) {
        candidates.add('$nvmVersions/$ver/bin');
        break;
      }
    }
    candidates.addAll(<String>[
      '$home/fvm/default/bin',
      '$home/.bun/bin',
      '$home/.volta/bin',
      '$home/.asdf/shims',
      '$home/.pyenv/shims',
      '$home/.cargo/bin',
      '$home/go/bin',
      '$home/.pub-cache/bin',
      '$home/.local/bin',
    ]);
  }
  candidates.addAll(const <String>['/opt/homebrew/bin', '/usr/local/bin']);

  for (final dir in candidates) {
    if (!seen.contains(dir) && dirExists(dir)) {
      add(dir);
    }
  }
  return entries.join(':');
}

int _compareSemverDesc(String a, String b) {
  List<int> parse(String s) {
    final clean = s.startsWith('v') || s.startsWith('V') ? s.substring(1) : s;
    return clean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
  }

  final pa = parse(a);
  final pb = parse(b);
  final len = pa.length > pb.length ? pa.length : pb.length;
  for (var i = 0; i < len; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return vb.compareTo(va);
  }
  return b.compareTo(a);
}

Future<String?> _probeZshPath(
  List<String> flags,
  Map<String, String> probeEnv,
) async {
  Process? proc;
  try {
    proc = await Process.start(
      '/bin/zsh',
      <String>[
        ...flags,
        '-c',
        'printf "$_pathMarkerStart%s$_pathMarkerEnd" "\$PATH"',
      ],
      environment: probeEnv,
      includeParentEnvironment: false,
    );
    // Close stdin immediately so interactive prompts in `.zshrc` never block.
    await proc.stdin.close();
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    // Drain stderr concurrently so the child never blocks on a full pipe.
    final stderrFuture = proc.stderr.drain<void>();
    final exitCode = await proc.exitCode.timeout(const Duration(seconds: 5));
    await stderrFuture.timeout(const Duration(seconds: 1));
    final out = await stdoutFuture.timeout(const Duration(seconds: 1));
    if (exitCode != 0) return null;
    return extractMarkedShellPath(out);
  } on Object {
    proc?.kill(ProcessSignal.sigkill);
    return null;
  }
}

bool _defaultDirExists(String path) {
  try {
    return Directory(path).existsSync();
  } on FileSystemException {
    return false;
  }
}

List<String> _defaultListSubdirs(String path) {
  try {
    return Directory(path)
        .listSync(followLinks: false)
        .whereType<Directory>()
        .map((d) => d.path.split('/').last)
        .toList();
  } on FileSystemException {
    return const <String>[];
  }
}

/// The `PATH` an interactive login shell sees on macOS.
///
/// A login-item GUI app inherits only the system default `PATH`, so developer
/// toolchains configured in `.zprofile` or `.zshrc` (Homebrew, `nvm`, `fvm`,
/// `bun`, `cargo`, `pyenv`) would not resolve. The value is read once from
/// `/bin/zsh -i -l -c` (falling back to `/bin/zsh -l -c`) with a minimal
/// environment and closed stdin, keeping only `PATH` (never inheriting secrets)
/// and supplementing existing standard local toolchain directories if absent.
Future<String?> _macLoginPath(String? fallback) async {
  final cached = _cachedLoginPath;
  if (cached != null) return cached;
  final env = Platform.environment;
  final probeEnv = <String, String>{
    if (env['HOME'] != null) 'HOME': env['HOME']!,
    if (env['USER'] != null) 'USER': env['USER']!,
    if (env['LOGNAME'] != null) 'LOGNAME': env['LOGNAME']!,
    'TERM': 'dumb',
  };
  final probed =
      await _probeZshPath(const <String>['-i', '-l'], probeEnv) ??
      await _probeZshPath(const <String>['-l'], probeEnv) ??
      (fallback ?? '');
  final merged = mergeMacToolchainPaths(
    probed,
    homeDirectory: env['HOME'],
    dirExists: _defaultDirExists,
    listSubdirs: _defaultListSubdirs,
  );
  return _cachedLoginPath = merged;
}

/// Environment for one `exec.run` child: the allowlist from
/// `sanitizeExecEnvironment`, `PWD`, a `TERM` matching the stdio mode and, on
/// macOS, the interactive login-shell `PATH`.
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

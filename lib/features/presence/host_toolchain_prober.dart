import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/discovery/windows_stdio_launcher.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';
import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Definition of a curated developer runtime/tool probed on the desktop host.
class HostToolchainSpec {
  const HostToolchainSpec({
    required this.id,
    required this.binaryName,
    required this.versionArgs,
  });

  final String id;
  final String binaryName;
  final List<String> versionArgs;
}

/// Outcome of executing a resolved toolchain version command.
class ToolchainCommandOutput {
  const ToolchainCommandOutput({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
}

/// Injectable command execution callback for [HostToolchainProber].
typedef ToolchainProcessRunner =
    Future<ToolchainCommandOutput> Function(
      ResolvedStdioCommand command, {
      required Map<String, String> environment,
      required Duration timeout,
    });

/// Curated developer runtimes and tools probed by the desktop host adapter
/// (`XUNA_XTP_V1_CONTRACT.md` §4.2.11, P1.2 / U4).
const List<HostToolchainSpec> defaultCuratedToolchainSpecs =
    <HostToolchainSpec>[
      HostToolchainSpec(
        id: 'git',
        binaryName: 'git',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'node',
        binaryName: 'node',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'npm',
        binaryName: 'npm',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'python',
        binaryName: 'python',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'python3',
        binaryName: 'python3',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'dart',
        binaryName: 'dart',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'flutter',
        binaryName: 'flutter',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'go',
        binaryName: 'go',
        versionArgs: <String>['version'],
      ),
      HostToolchainSpec(
        id: 'cargo',
        binaryName: 'cargo',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'docker',
        binaryName: 'docker',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'gh',
        binaryName: 'gh',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'rg',
        binaryName: 'rg',
        versionArgs: <String>['--version'],
      ),
      HostToolchainSpec(
        id: 'ffmpeg',
        binaryName: 'ffmpeg',
        versionArgs: <String>['-version'],
      ),
      HostToolchainSpec(
        id: 'soffice',
        binaryName: 'soffice',
        versionArgs: <String>['--version'],
      ),
    ];

/// Probes a curated set of host developer toolchains directly via sanitized
/// `PATH` + `PATHEXT` without invoking a shell (`cmd /c` / `zsh -c`) and
/// emits strictly normalized, path-free [XtpToolchainEntry] records.
class HostToolchainProber {
  HostToolchainProber({
    List<HostToolchainSpec>? specs,
    this.perToolTimeout = const Duration(milliseconds: 1500),
    this.overallBudget = const Duration(milliseconds: 3000),
    this.maxConcurrency = 4,
    this.logger,
    bool? isWindows,
    bool? isMacOs,
    Map<String, String> Function()? environmentProvider,
    bool Function(String path)? fileExists,
    String? Function(String path)? readFile,
    bool Function(String dir)? dirExists,
    List<String> Function(String dir)? listSubdirs,
    ToolchainProcessRunner? processRunner,
  }) : specs = specs ?? defaultCuratedToolchainSpecs,
       _isWindows = isWindows,
       _isMacOs = isMacOs,
       _environmentProvider = environmentProvider,
       _fileExists = fileExists,
       _readFile = readFile,
       _dirExists = dirExists,
       _listSubdirs = listSubdirs,
       _processRunner = processRunner;

  final List<HostToolchainSpec> specs;
  final Duration perToolTimeout;
  final Duration overallBudget;
  final int maxConcurrency;
  final ContentFreeLogger? logger;
  final bool? _isWindows;
  final bool? _isMacOs;
  final Map<String, String> Function()? _environmentProvider;
  final bool Function(String path)? _fileExists;
  final String? Function(String path)? _readFile;
  final bool Function(String dir)? _dirExists;
  final List<String> Function(String dir)? _listSubdirs;
  final ToolchainProcessRunner? _processRunner;

  static const int _maxCapturedBytes = 16384;
  static final RegExp _ansiEscapeRe = RegExp(
    r'\x1B(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*\x07|[@-Z\\-_])',
  );
  static final RegExp _windowsForwardDrivePathRe = RegExp(
    r'''(?:^|[\s"'`(\[{=:,])[A-Za-z]:[/\\]''',
  );
  static final RegExp _versionTokenRe = RegExp(
    r'^\d+\.\d+(?:[._+-][a-zA-Z0-9._+-]+)?$',
  );
  static final RegExp _coreSemverRe = RegExp(r'^(\d+\.\d+(?:\.\d+)*)');
  static final RegExp _goVersionRe = RegExp(
    r'\bgo(\d+\.\d+(?:\.\d+)?(?:[a-zA-Z0-9._+-]*)?)',
  );
  static final RegExp _flutterVersionRe = RegExp(
    r'\bFlutter\s+(\d+\.\d+(?:\.\d+)*(?:[._+-][a-zA-Z0-9._+-]*)?)',
  );
  static final RegExp _dartVersionRe = RegExp(
    r'Dart\s+SDK\s+version:\s*(\d+\.\d+(?:\.\d+)*(?:[._+-][a-zA-Z0-9._+-]*)?)',
  );

  List<XtpToolchainEntry> _cachedToolchains = const <XtpToolchainEntry>[];
  Future<List<XtpToolchainEntry>>? _inFlightProbe;

  /// Latest cached toolchains in RAM (empty until the first probe finishes).
  List<XtpToolchainEntry> get cachedToolchains => _cachedToolchains;

  /// Probes curated toolchains concurrently (bounded by [maxConcurrency],
  /// [perToolTimeout], and [overallBudget]), caches sorted/deduplicated results
  /// capped at [XtpToolchainEntry.maxToolchains], and returns them.
  Future<List<XtpToolchainEntry>> probe({bool forceRefresh = false}) async {
    final active = _inFlightProbe;
    if (active != null) {
      if (!forceRefresh) return active;
      await active.catchError((Object _) => const <XtpToolchainEntry>[]);
    }
    if (!forceRefresh && _cachedToolchains.isNotEmpty) {
      return _cachedToolchains;
    }

    final future = _runProbe();
    _inFlightProbe = future;
    try {
      final result = await future;
      _cachedToolchains = result;
      return result;
    } finally {
      if (identical(_inFlightProbe, future)) {
        _inFlightProbe = null;
      }
    }
  }

  Future<List<XtpToolchainEntry>> _runProbe() async {
    final stopwatch = Stopwatch()..start();
    final isWin = _isWindows ?? Platform.isWindows;
    final isMac = _isMacOs ?? Platform.isMacOS;
    final rawEnv = _environmentProvider?.call() ?? Platform.environment;
    final sanitizedEnv = buildSanitizedProbeEnvironment(
      rawEnv,
      isWindows: isWin,
      isMacOs: isMac,
      dirExists: _dirExists ?? _defaultDirExists,
      listSubdirs: _listSubdirs ?? _defaultListSubdirs,
    );

    final runner = _processRunner ?? _defaultProcessRunner;
    final fileExists = _fileExists ?? _defaultFileExists;
    final readFile = _readFile ?? _defaultReadSmallFile;

    final queue = List<HostToolchainSpec>.of(specs);
    final results = <String, XtpToolchainEntry>{};
    final workerCount = maxConcurrency < 1
        ? 1
        : (queue.length < maxConcurrency ? queue.length : maxConcurrency);

    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) return;
        final remaining = overallBudget - stopwatch.elapsed;
        if (remaining <= Duration.zero) return;

        final spec = queue.removeAt(0);
        final resolved = resolveToolchainCommand(
          spec,
          environment: sanitizedEnv,
          isWindows: isWin,
          isMacOs: isMac,
          fileExists: fileExists,
          readFile: readFile,
          dirExists: _dirExists ?? _defaultDirExists,
          listSubdirs: _listSubdirs ?? _defaultListSubdirs,
        );
        if (resolved == null) {
          continue;
        }

        final toolTimeout = remaining < perToolTimeout
            ? remaining
            : perToolTimeout;
        if (toolTimeout <= Duration.zero) return;

        ToolchainCommandOutput output;
        try {
          output =
              await runner(
                resolved,
                environment: sanitizedEnv,
                timeout: toolTimeout,
              ).timeout(
                toolTimeout + const Duration(milliseconds: 50),
                onTimeout: () => const ToolchainCommandOutput(
                  exitCode: -1,
                  stdout: '',
                  stderr: '',
                  timedOut: true,
                ),
              );
        } on Object {
          continue;
        }

        if (output.timedOut ||
            output.exitCode != 0 ||
            stopwatch.elapsed > overallBudget) {
          continue;
        }

        final combined = output.stdout.trim().isNotEmpty
            ? '${output.stdout}\n${output.stderr}'
            : output.stderr;
        final version = normalizeToolchainVersion(combined, toolId: spec.id);
        if (version == null) {
          continue;
        }

        final validated = XtpToolchainEntry.tryFromJson(<String, Object?>{
          'id': spec.id,
          'version': version,
        });
        if (validated != null) {
          results.putIfAbsent(validated.id, () => validated);
        }
      }
    }

    if (workerCount > 0) {
      await Future.wait(<Future<void>>[
        for (var i = 0; i < workerCount; i++) worker(),
      ]);
    }

    final sorted = results.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final capped = sorted.length > XtpToolchainEntry.maxToolchains
        ? sorted.sublist(0, XtpToolchainEntry.maxToolchains)
        : sorted;

    stopwatch.stop();
    logger?.info('presence.toolchains_probed', <String, Object?>{
      'status': 'ok',
      'durationMs': stopwatch.elapsedMilliseconds,
    });
    return List<XtpToolchainEntry>.unmodifiable(capped);
  }

  /// Returns `true` when [path] points to a Windows Store `AppExecutionAlias`
  /// stub (`Microsoft\WindowsApps`).
  static bool isWindowsStoreAppAliasPath(String path) {
    final normalized = path.replaceAll('/', r'\').toLowerCase();
    return normalized.contains(r'\microsoft\windowsapps');
  }

  /// Builds a sanitized child environment (`includeParentEnvironment: false`)
  /// stripping secrets (`XUNA_*`, API keys) and Windows Store alias `PATH`
  /// entries, and supplementing macOS toolchain directories via
  /// [mergeMacToolchainPaths] without invoking `/bin/zsh -c`.
  static Map<String, String> buildSanitizedProbeEnvironment(
    Map<String, String> rawEnv, {
    required bool isWindows,
    required bool isMacOs,
    bool Function(String dir)? dirExists,
    List<String> Function(String dir)? listSubdirs,
  }) {
    final env = sanitizeExecEnvironment(rawEnv, windows: isWindows);
    if (isWindows) {
      final pathKey = env.keys.firstWhere(
        (k) => k.toLowerCase() == 'path',
        orElse: () => 'PATH',
      );
      final rawPath = env[pathKey] ?? rawEnv['PATH'] ?? rawEnv['Path'] ?? '';
      final filteredDirs = rawPath
          .split(';')
          .map((d) => d.trim())
          .where((d) => d.isNotEmpty && !isWindowsStoreAppAliasPath(d))
          .toList(growable: false);
      env[pathKey] = filteredDirs.join(';');
      if (pathKey != 'PATH') {
        env['PATH'] = env[pathKey]!;
      }
      return env;
    }

    final rawPath = env['PATH'] ?? '/usr/local/bin:/usr/bin:/bin';
    if (isMacOs) {
      env['PATH'] = mergeMacToolchainPaths(
        rawPath,
        homeDirectory: env['HOME'],
        dirExists: dirExists ?? _defaultDirExists,
        listSubdirs: listSubdirs ?? _defaultListSubdirs,
      );
    } else {
      env['PATH'] = rawPath;
    }
    return env;
  }

  /// Resolves [spec] directly via [environment] `PATH` + `PATHEXT` (no shell
  /// invocation). Returns `null` when absent, forbidden, or a Windows Store
  /// `AppExecutionAlias` stub.
  static ResolvedStdioCommand? resolveToolchainCommand(
    HostToolchainSpec spec, {
    required Map<String, String> environment,
    required bool isWindows,
    required bool isMacOs,
    bool Function(String path)? fileExists,
    String? Function(String path)? readFile,
    bool Function(String dir)? dirExists,
    List<String> Function(String dir)? listSubdirs,
  }) {
    final exists = fileExists ?? _defaultFileExists;
    final read = readFile ?? _defaultReadSmallFile;

    if (isWindows) {
      final resolved = resolveStdioCommand(
        spec.binaryName,
        spec.versionArgs,
        isWindows: true,
        environment: environment,
        fileExists: exists,
        readFile: read,
      );
      // `resolveStdioCommand` echoes the bare executable name when nothing on
      // PATH matched; fail closed unless a concrete file path was resolved.
      final hasPathSep =
          resolved.executable.contains(r'\') ||
          resolved.executable.contains('/');
      if (!hasPathSep || isWindowsStoreAppAliasPath(resolved.executable)) {
        return null;
      }

      if (resolved.usesCmdShell && resolved.rawCmdLine != null) {
        final batchPath = _extractQuotedBatchTarget(resolved.rawCmdLine!);
        if (batchPath == null || isWindowsStoreAppAliasPath(batchPath)) {
          return null;
        }
        // Unwrap Node's bundled `npm.cmd` straight to `node.exe` when present
        // so `npm --version` avoids spawning `cmd.exe`.
        final unwrappedNpm = _tryUnwrapBundledNpmCmd(
          batchPath,
          spec.versionArgs,
          fileExists: exists,
        );
        if (unwrappedNpm != null) {
          return unwrappedNpm;
        }
        return resolved;
      }

      if (!exists(resolved.executable)) {
        return null;
      }
      return resolved;
    }

    final rawPath = environment['PATH'] ?? '/usr/local/bin:/usr/bin:/bin';
    final effectivePath = isMacOs
        ? mergeMacToolchainPaths(
            rawPath,
            homeDirectory: environment['HOME'],
            dirExists: dirExists ?? _defaultDirExists,
            listSubdirs: listSubdirs ?? _defaultListSubdirs,
          )
        : rawPath;

    for (final rawDir in effectivePath.split(':')) {
      final dir = rawDir.trim();
      if (dir.isEmpty) continue;
      final candidate = dir.endsWith('/')
          ? '$dir${spec.binaryName}'
          : '$dir/${spec.binaryName}';
      if (!exists(candidate)) continue;
      if (isForbiddenProtocolHarnessExecutable(candidate)) continue;
      return ResolvedStdioCommand(
        executable: candidate,
        args: spec.versionArgs,
        usesCmdShell: false,
      );
    }
    return null;
  }

  static String? _extractQuotedBatchTarget(String rawCmdLine) {
    final trimmed = rawCmdLine.trim();
    if (!trimmed.startsWith('"')) return null;
    final closeIdx = trimmed.indexOf('"', 1);
    if (closeIdx <= 1) return null;
    return trimmed.substring(1, closeIdx);
  }

  static ResolvedStdioCommand? _tryUnwrapBundledNpmCmd(
    String batchPath,
    List<String> args, {
    required bool Function(String path) fileExists,
  }) {
    final lower = batchPath.toLowerCase();
    if (!lower.endsWith(r'\npm.cmd') && !lower.endsWith('/npm.cmd')) {
      return null;
    }
    final sepIdx = batchPath.lastIndexOf(RegExp(r'[\\/]'));
    if (sepIdx <= 0) return null;
    final dir = batchPath.substring(0, sepIdx);
    final nodeExe = '$dir\\node.exe';
    final npmCliJs = '$dir\\node_modules\\npm\\bin\\npm-cli.js';
    if (!fileExists(nodeExe) || !fileExists(npmCliJs)) {
      return null;
    }
    return ResolvedStdioCommand(
      executable: nodeExe,
      args: <String>[npmCliJs, ...args],
      usesCmdShell: false,
    );
  }

  /// Extracts a strict, path-free version string matching
  /// [XtpToolchainEntry.versionPattern] from [rawOutput], or returns `null`.
  static String? normalizeToolchainVersion(
    String rawOutput, {
    required String toolId,
  }) {
    if (rawOutput.trim().isEmpty) return null;
    final plain = rawOutput.replaceAll(_ansiEscapeRe, '');
    for (final rawLine in plain.split(RegExp(r'[\r\n]+'))) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Fail closed on any line carrying a filesystem path.
      if (redactFilesystemPaths(line) != line ||
          _windowsForwardDrivePathRe.hasMatch(line)) {
        continue;
      }

      final specialized = _extractSpecializedVersion(line, toolId: toolId);
      if (specialized != null) {
        return specialized;
      }

      for (final rawToken in line.split(RegExp(r'\s+'))) {
        final candidate = _normalizeToken(rawToken, toolId: toolId);
        if (candidate != null) {
          return candidate;
        }
      }
    }
    return null;
  }

  static String? _extractSpecializedVersion(
    String line, {
    required String toolId,
  }) {
    RegExp? pattern;
    switch (toolId) {
      case 'go':
        pattern = _goVersionRe;
      case 'flutter':
        pattern = _flutterVersionRe;
      case 'dart':
        pattern = _dartVersionRe;
    }
    if (pattern == null) return null;
    final match = pattern.firstMatch(line);
    if (match == null) return null;
    return _normalizeToken(match.group(1) ?? '', toolId: toolId);
  }

  static String? _normalizeToken(String rawToken, {required String toolId}) {
    var token = rawToken.trim();
    if (token.isEmpty) return null;
    token = token.replaceFirst(RegExp(r'^[\[\(]+'), '');
    token = token.replaceFirst(RegExp(r'[,;:\)\]\.]+$'), '');
    if (token.isEmpty ||
        token.contains('/') ||
        token.contains(r'\') ||
        token.contains('..') ||
        token.contains(':') ||
        token.contains('@')) {
      return null;
    }
    if ((token.startsWith('v') || token.startsWith('V')) &&
        token.length > 1 &&
        _isDigit(token.codeUnitAt(1))) {
      token = token.substring(1);
    } else if (toolId == 'go' &&
        token.startsWith('go') &&
        token.length > 2 &&
        _isDigit(token.codeUnitAt(2))) {
      token = token.substring(2);
    }

    if (token.length > 32) {
      final core = _coreSemverRe.firstMatch(token)?.group(1);
      if (core != null && core.length <= 32) {
        token = core;
      }
    }

    if (!_versionTokenRe.hasMatch(token)) {
      return null;
    }
    final entry = XtpToolchainEntry.tryFromJson(<String, Object?>{
      'id': toolId,
      'version': token,
    });
    return entry?.version;
  }

  static bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

  static Future<ToolchainCommandOutput> _defaultProcessRunner(
    ResolvedStdioCommand command, {
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    if (command.usesCmdShell &&
        Platform.isWindows &&
        command.rawCmdLine != null) {
      return _runWindowsNativeBatch(
        comspec: command.executable,
        rawCmdLine: command.rawCmdLine!,
        environment: environment,
        timeout: timeout,
      );
    }

    Process? process;
    try {
      process = await Process.start(
        command.executable,
        command.args,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      );
      unawaited(process.stdin.close().catchError((Object _) {}));

      final stdoutFuture = _readBoundedStream(process.stdout);
      final stderrFuture = _readBoundedStream(process.stderr);

      final result =
          await Future.wait<Object>(<Future<Object>>[
            process.exitCode,
            stdoutFuture,
            stderrFuture,
          ]).timeout(
            timeout,
            onTimeout: () {
              process?.kill(ProcessSignal.sigkill);
              return const <Object>[-1, '', '', true];
            },
          );

      if (result.length == 4) {
        return const ToolchainCommandOutput(
          exitCode: -1,
          stdout: '',
          stderr: '',
          timedOut: true,
        );
      }

      return ToolchainCommandOutput(
        exitCode: result[0] as int,
        stdout: result[1] as String,
        stderr: result[2] as String,
      );
    } on Object {
      process?.kill(ProcessSignal.sigkill);
      return const ToolchainCommandOutput(exitCode: -1, stdout: '', stderr: '');
    }
  }

  static Future<ToolchainCommandOutput> _runWindowsNativeBatch({
    required String comspec,
    required String rawCmdLine,
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    final cwd = Directory.systemTemp.path;
    final ExecProcessHandle handle;
    try {
      handle = startWindowsNativeCmdProcess(
        comspec: comspec,
        command: rawCmdLine,
        cwd: cwd,
        environment: environment,
      );
    } on Object {
      return const ToolchainCommandOutput(exitCode: -1, stdout: '', stderr: '');
    }

    final bytes = <int>[];
    final deadline = DateTime.now().add(timeout);
    try {
      while (DateTime.now().isBefore(deadline)) {
        final poll = await handle.poll();
        if (poll.data.isNotEmpty && bytes.length < _maxCapturedBytes) {
          final remaining = _maxCapturedBytes - bytes.length;
          bytes.addAll(
            poll.data.length <= remaining
                ? poll.data
                : poll.data.sublist(0, remaining),
          );
        }
        if (poll.exited) {
          return ToolchainCommandOutput(
            exitCode: poll.exitCode ?? -1,
            stdout: utf8.decode(bytes, allowMalformed: true),
            stderr: '',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await handle.killGroup(force: true);
      return const ToolchainCommandOutput(
        exitCode: -1,
        stdout: '',
        stderr: '',
        timedOut: true,
      );
    } on Object {
      await handle.killGroup(force: true).catchError((Object _) => false);
      return const ToolchainCommandOutput(exitCode: -1, stdout: '', stderr: '');
    } finally {
      await handle.release().catchError((Object _) {});
    }
  }

  static Future<String> _readBoundedStream(Stream<List<int>> stream) async {
    final bytes = <int>[];
    try {
      await for (final chunk in stream) {
        if (bytes.length < _maxCapturedBytes) {
          final remaining = _maxCapturedBytes - bytes.length;
          bytes.addAll(
            chunk.length <= remaining ? chunk : chunk.sublist(0, remaining),
          );
        }
      }
    } on Object {
      // Ignore stream decode/pipe errors on killed processes.
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static bool _defaultFileExists(String path) {
    try {
      return File(path).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  static String? _defaultReadSmallFile(String path) {
    try {
      final file = File(path);
      if (!file.existsSync() || file.lengthSync() > 8192) return null;
      return file.readAsStringSync();
    } on Object {
      return null;
    }
  }

  static bool _defaultDirExists(String path) {
    try {
      return Directory(path).existsSync();
    } on FileSystemException {
      return false;
    }
  }

  static List<String> _defaultListSubdirs(String path) {
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
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/capabilities/capability_manifest_loader.dart';
import 'package:xuna_desktop/features/exec/draft_workspace_manager.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_output_verifier.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Result of detecting one manifest's declared executable binary on this host.
class DetectedCapabilityBinary {
  const DetectedCapabilityBinary({
    required this.executablePath,
    required this.binarySha256,
    this.version,
  });

  final String executablePath;
  final String binarySha256;
  final String? version;
}

/// One approved, live-detected capability adapter ready for `capability.list`.
class DetectedCapabilityAdapter {
  const DetectedCapabilityAdapter({
    required this.manifest,
    required this.binary,
  });

  final CapabilityManifest manifest;
  final DetectedCapabilityBinary binary;

  Map<String, Object?> toListWireJson() {
    final inputsSummary = manifest.inputs
        .map((i) => '${i.name}:${i.type.wire}${i.required ? "" : "?"}')
        .join(', ');
    return <String, Object?>{
      'id': manifest.id,
      'capability': manifest.capability,
      'description': manifest.description,
      'risk': manifest.risk.wire,
      'provenance': manifest.provenance.kind.wire,
      'inputsSummary': inputsSummary.length <= 240
          ? inputsSummary
          : inputsSummary.substring(0, 240),
      if (binary.version != null && binary.version!.isNotEmpty)
        'binaryVersion': binary.version!.length <= 64
            ? binary.version!
            : binary.version!.substring(0, 64),
    };
  }
}

/// Preflight evaluation outcome for `capability.run`.
class CapabilityPreflightOutcome {
  const CapabilityPreflightOutcome({
    required this.allowed,
    required this.effectiveRisk,
    this.reasonCode,
    this.errorCode,
    this.remediation,
  });

  final bool allowed;
  final RiskTier effectiveRisk;
  final String? reasonCode;
  final String? errorCode;
  final XtpRemediation? remediation;
}

/// Execution outcome of `capability.run` (`ADR-0021` §1).
class CapabilityRunOutcome {
  const CapabilityRunOutcome({
    required this.adapterId,
    required this.status,
    required this.output,
    required this.truncated,
    required this.durationMs,
    this.exitCode,
    this.errorCode,
    this.artifacts = const <Map<String, Object?>>[],
    this.remediation,
  });

  final String adapterId;
  final String status;
  final int? exitCode;
  final String output;
  final bool truncated;
  final int durationMs;
  final String? errorCode;
  final List<Map<String, Object?>> artifacts;
  final XtpRemediation? remediation;

  bool get succeeded => status == 'completed';

  Map<String, Object?> toStructuredContent() => <String, Object?>{
    'adapterId': adapterId,
    'status': status,
    if (exitCode != null) 'exitCode': exitCode,
    'output': output,
    'truncated': truncated,
    'durationMs': durationMs,
    if (errorCode != null) 'errorCode': errorCode,
    if (artifacts.isNotEmpty) 'artifacts': artifacts,
    if (remediation != null) 'remediation': remediation!.toJson(),
  };
}

/// Resolves declared binaries from `PATH` without invoking any shell and
/// computes their SHA-256 digest and optional version banner (`ADR-0021` §1).
///
/// Contains zero hardcoded application or CLI names (Rule H5).
class CapabilityDetector {
  CapabilityDetector({
    Map<String, String>? environmentOverride,
    bool? isWindowsOverride,
    Duration probeTimeout = const Duration(milliseconds: 1500),
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      Map<String, String> environment,
    )?
    processRunner,
  }) : _environmentOverride = environmentOverride,
       _isWindowsOverride = isWindowsOverride,
       _probeTimeout = probeTimeout,
       _processRunner = processRunner;

  final Map<String, String>? _environmentOverride;
  final bool? _isWindowsOverride;
  final Duration _probeTimeout;
  final Future<ProcessResult> Function(
    String executable,
    List<String> args,
    Map<String, String> environment,
  )?
  _processRunner;

  static final RegExp _versionRe = RegExp(r'\b(\d+\.\d+(?:\.\d+)?)\b');

  /// Resolves [binaryName] directly on `PATH` (no shell), filtering out OS
  /// execution-alias stubs and computing its live SHA-256.
  String? resolveBinaryOnPath(String binaryName) {
    final isWin = _isWindowsOverride ?? Platform.isWindows;
    final env = _environmentOverride ?? Platform.environment;
    final rawPath = env['PATH'] ?? env['Path'] ?? '';
    if (rawPath.trim().isEmpty) return null;

    final sep = isWin ? ';' : ':';
    final pathExts = isWin
        ? (env['PATHEXT'] ?? '.EXE;.BAT;.CMD;.COM')
              .split(';')
              .map((e) => e.trim())
              .where((e) => e.isNotEmpty)
              .toList(growable: false)
        : const <String>[''];

    final lowerName = binaryName.toLowerCase();
    final hasExt = isWin && pathExts.any((e) => lowerName.endsWith(e.toLowerCase()));

    for (final rawDir in rawPath.split(sep)) {
      final dir = rawDir.trim().replaceAll('"', '');
      if (dir.isEmpty) continue;
      if (isWin && dir.toLowerCase().contains(r'\microsoft\windowsapps')) {
        continue;
      }
      final candidates = hasExt
          ? <String>[binaryName]
          : <String>[
              if (!isWin) binaryName,
              for (final ext in pathExts)
                if (ext.isNotEmpty) '$binaryName$ext',
            ];
      for (final cand in candidates) {
        final full = '$dir${Platform.pathSeparator}$cand';
        try {
          if (FileSystemEntity.typeSync(full) == FileSystemEntityType.file) {
            return File(full).resolveSymbolicLinksSync();
          }
        } on FileSystemException {
          continue;
        }
      }
    }
    return null;
  }

  /// Detects the binary declared by [spec] and verifies optional pinned
  /// [expectedBinarySha256]. Returns `null` when missing or hash-mismatched.
  Future<DetectedCapabilityBinary?> detect(
    CapabilityDetectSpec spec, {
    String? expectedBinarySha256,
  }) async {
    final resolved = resolveBinaryOnPath(spec.binary);
    if (resolved == null) return null;

    final String binaryHash;
    try {
      final file = File(resolved);
      if (!file.existsSync()) return null;
      binaryHash = (await sha256.bind(file.openRead()).first).toString();
    } on FileSystemException {
      return null;
    }

    if (expectedBinarySha256 != null && binaryHash != expectedBinarySha256) {
      return null;
    }

    String? version;
    if (spec.versionArgs.isNotEmpty) {
      try {
        final isWin = _isWindowsOverride ?? Platform.isWindows;
        final scrubbed = sanitizeExecEnvironment(
          _environmentOverride ?? Platform.environment,
          windows: isWin,
        );
        final res = _processRunner != null
            ? await _processRunner(resolved, spec.versionArgs, scrubbed)
            : await Process.run(
                resolved,
                spec.versionArgs,
                runInShell: false,
                includeParentEnvironment: false,
                environment: scrubbed,
              ).timeout(_probeTimeout);
        final banner = '${res.stdout}\n${res.stderr}';
        final match = _versionRe.firstMatch(banner);
        if (match != null) {
          version = match.group(1);
        }
      } on Object {
        // Presence & SHA-256 already verified; version banner is best-effort.
      }
    }

    return DetectedCapabilityBinary(
      executablePath: resolved,
      binarySha256: binaryHash,
      version: version,
    );
  }
}

/// Generic declarative Capability Adapter engine (`ADR-0021` §1 / P4.1).
///
/// Strictly generic (Rule H5): zero application or binary names appear in this
/// file. Every external capability comes purely from validated JSON manifests
/// loaded by [CapabilityManifestLoader], executes directly without a shell
/// (`runInShell: false`), verifies outputs via P1.1 [verifyExpectedFiles], and
/// logs zero paths or contents (`desktop/AGENTS.md` §3.6).
class CapabilityEngine {
  CapabilityEngine({
    required this.loader,
    CapabilityDetector? detector,
    this.draftWorkspaceManager,
    ContentFreeLogger? logger,
    bool? isWindowsOverride,
    String? homeDirectoryOverride,
    String? Function(String normalizedPath)? realPathOverride,
  }) : detector = detector ?? CapabilityDetector(),
       _logger = logger,
       _isWindowsOverride = isWindowsOverride,
       _homeDirectoryOverride = homeDirectoryOverride,
       _realPathOverride = realPathOverride;

  final CapabilityManifestLoader loader;
  final CapabilityDetector detector;
  final DraftWorkspaceManager? draftWorkspaceManager;
  final ContentFreeLogger? _logger;
  final bool? _isWindowsOverride;
  final String? _homeDirectoryOverride;
  final String? Function(String normalizedPath)? _realPathOverride;

  final Set<Process> _activeProcesses = <Process>{};
  static const int _maxOutputBytes = 16384;

  /// Cancels all running capability adapter subprocesses immediately (E-Stop).
  void cancelAll() {
    for (final proc in List<Process>.of(_activeProcesses)) {
      try {
        proc.kill(ProcessSignal.sigkill);
      } on Object {
        // Best-effort process kill.
      }
    }
    _activeProcesses.clear();
  }

  /// Lists only approved, valid manifests whose declared binary is currently
  /// detected and matches its pinned `binarySha256` (if any).
  Future<List<DetectedCapabilityAdapter>> listDetectedAdapters({
    String? capabilityFilter,
    String? formatFilter,
  }) async {
    final loaded = loader.loadAll(includeUnapproved: false);
    final results = <DetectedCapabilityAdapter>[];
    for (final manifest in loaded.manifests) {
      if (capabilityFilter != null && manifest.capability != capabilityFilter) {
        continue;
      }
      if (formatFilter != null) {
        final fmt = formatFilter.toLowerCase();
        if (!manifest.fromFormats.contains(fmt) &&
            !manifest.toFormats.contains(fmt)) {
          continue;
        }
      }
      final detected = await detector.detect(
        manifest.detect,
        expectedBinarySha256: manifest.provenance.binarySha256,
      );
      if (detected == null) continue;
      results.add(
        DetectedCapabilityAdapter(manifest: manifest, binary: detected),
      );
    }
    return List<DetectedCapabilityAdapter>.unmodifiable(results);
  }

  /// Evaluates `xuna/preflight` for `capability.run` fail-closed.
  Future<CapabilityPreflightOutcome> preflightRun({
    required String adapterId,
    required Map<String, Object?> rawInputs,
    required ShellControlPolicy shellControl,
    String? draftId,
    DateTime? nowUtc,
  }) async {
    if (!shellControl.enabled) {
      return const CapabilityPreflightOutcome(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: 'shell_not_enabled',
        reasonCode: 'policy',
      );
    }
    final manifest = _findApprovedManifest(adapterId);
    if (manifest == null) {
      return const CapabilityPreflightOutcome(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: 'capability_not_found',
        reasonCode: 'unknown_adapter',
      );
    }
    final detected = await detector.detect(
      manifest.detect,
      expectedBinarySha256: manifest.provenance.binarySha256,
    );
    if (detected == null) {
      return CapabilityPreflightOutcome(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: 'toolchain_missing',
        reasonCode: 'binary_not_detected',
        remediation: _buildManifestRemediation(manifest.detect),
      );
    }
    final compiled = _compileForHost(
      manifest: manifest,
      rawInputs: rawInputs,
      shellControl: shellControl,
      draftId: draftId,
      nowUtc: nowUtc,
    );
    if (!compiled.allowed) {
      return CapabilityPreflightOutcome(
        allowed: false,
        effectiveRisk: compiled.effectiveRisk,
        errorCode: compiled.errorCode ?? 'invalid_args',
        reasonCode: compiled.reasonCode,
      );
    }
    if (draftId != null && compiled.effectiveRisk >= RiskTier.r3) {
      return const CapabilityPreflightOutcome(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: 'draft_r3_forbidden',
        reasonCode: 'draft_r3_forbidden',
      );
    }
    return CapabilityPreflightOutcome(
      allowed: true,
      effectiveRisk: compiled.effectiveRisk,
      reasonCode: compiled.reasonCode ?? 'capability_manifest',
    );
  }

  /// Executes [adapterId] directly (no shell) with scrubbed environment,
  /// optional draft-workspace path mapping, timeout, and P1.1 output
  /// verification. When [candidateManifestOverride] is supplied (Foundry
  /// draft verification), executes that manifest inside the isolated draft
  /// without requiring disk installation yet.
  Future<CapabilityRunOutcome> runAdapter({
    required String adapterId,
    required Map<String, Object?> rawInputs,
    required ShellControlPolicy shellControl,
    String? draftId,
    CapabilityManifest? candidateManifestOverride,
    DateTime? nowUtc,
  }) async {
    final sw = Stopwatch()..start();
    if (!shellControl.enabled) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'shell_not_enabled',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'shell_not_enabled',
      );
    }

    final manifest =
        candidateManifestOverride ?? _findApprovedManifest(adapterId);
    if (manifest == null) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'capability_not_found',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'capability_not_found',
      );
    }
    if (!manifest.hasValidManifestPin) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'manifest_sha256_mismatch',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'manifest_sha256_mismatch',
      );
    }

    final detected = await detector.detect(
      manifest.detect,
      expectedBinarySha256: candidateManifestOverride != null
          ? null
          : manifest.provenance.binarySha256,
    );
    if (detected == null) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'toolchain_missing',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'toolchain_missing',
        remediation: _buildManifestRemediation(manifest.detect),
      );
    }

    final compiled = _compileForHost(
      manifest: manifest,
      rawInputs: rawInputs,
      shellControl: shellControl,
      draftId: draftId,
      nowUtc: nowUtc,
    );
    if (!compiled.allowed) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: compiled.errorCode ?? 'invalid_args',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: compiled.errorCode ?? 'invalid_args',
      );
    }
    if (draftId != null && compiled.effectiveRisk >= RiskTier.r3) {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'draft_r3_forbidden',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'draft_r3_forbidden',
      );
    }

    final isWin = _isWindowsOverride ?? Platform.isWindows;
    final home = _homeDirectoryOverride ?? hostHomeDirectory();
    final workDir = compiled.workingDirectory ?? home ?? Directory.current.path;
    final env = await buildExecEnvironment(cwd: workDir, pty: false);

    Process? proc;
    try {
      proc = await Process.start(
        detected.executablePath,
        compiled.argv,
        workingDirectory: Directory(workDir).existsSync() ? workDir : null,
        environment: env,
        includeParentEnvironment: false,
        runInShell: false,
      );
      _activeProcesses.add(proc);
      await proc.stdin.close();

      final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
      final stderrFuture = proc.stderr.transform(utf8.decoder).join();
      final exitCode = await proc.exitCode.timeout(
        Duration(milliseconds: manifest.invoke.timeoutMs),
      );
      final outStr = await stdoutFuture.timeout(const Duration(seconds: 2));
      final errStr = await stderrFuture.timeout(const Duration(seconds: 2));
      sw.stop();

      final combinedRaw = errStr.trim().isEmpty
          ? outStr
          : (outStr.trim().isEmpty ? errStr : '$outStr\n$errStr');
      final redacted = redactBrowserSnapshot(
        combinedRaw,
        maxBytes: _maxOutputBytes,
      );
      final outputTruncated =
          utf8.encode(combinedRaw).length > _maxOutputBytes ||
          redacted.truncated;

      if (exitCode != 0) {
        _logger?.info('capability.run_finished', <String, Object?>{
          'status': 'failed',
          'durationMs': sw.elapsedMilliseconds,
        });
        return CapabilityRunOutcome(
          adapterId: adapterId,
          status: 'failed',
          exitCode: exitCode,
          output: redacted.text,
          truncated: outputTruncated,
          durationMs: sw.elapsedMilliseconds,
          errorCode: 'capability_nonzero_exit',
        );
      }

      // Reuse P1.1 output verification when verifyFiles is declared.
      if (compiled.expectedFiles.isNotEmpty) {
        final check = await verifyExpectedFiles(
          compiled.expectedFiles,
          homeDirectory: home,
          windows: isWin,
          realPath: _realPathOverride ?? resolveHostRealPath,
        );
        if (check.errorCode != null) {
          _logger?.info('capability.run_finished', <String, Object?>{
            'status': 'failed',
            'errorCode': check.errorCode,
            'durationMs': sw.elapsedMilliseconds,
          });
          return CapabilityRunOutcome(
            adapterId: adapterId,
            status: 'failed',
            exitCode: 0,
            output: redacted.text,
            truncated: outputTruncated,
            durationMs: sw.elapsedMilliseconds,
            errorCode: check.errorCode,
            artifacts: check.artifacts,
          );
        }
        _logger?.info('capability.run_finished', <String, Object?>{
          'status': 'completed',
          'durationMs': sw.elapsedMilliseconds,
        });
        return CapabilityRunOutcome(
          adapterId: adapterId,
          status: 'completed',
          exitCode: 0,
          output: redacted.text,
          truncated: outputTruncated,
          durationMs: sw.elapsedMilliseconds,
          artifacts: check.artifacts,
        );
      }

      _logger?.info('capability.run_finished', <String, Object?>{
        'status': 'completed',
        'durationMs': sw.elapsedMilliseconds,
      });
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'completed',
        exitCode: 0,
        output: redacted.text,
        truncated: outputTruncated,
        durationMs: sw.elapsedMilliseconds,
      );
    } on TimeoutException {
      proc?.kill(ProcessSignal.sigkill);
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'timed_out',
        output: 'capability_timed_out',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'capability_timed_out',
      );
    } on Object {
      sw.stop();
      return CapabilityRunOutcome(
        adapterId: adapterId,
        status: 'failed',
        output: 'exec_spawn_failed',
        truncated: false,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'exec_spawn_failed',
        remediation: _buildManifestRemediation(manifest.detect),
      );
    } finally {
      if (proc != null) {
        _activeProcesses.remove(proc);
      }
    }
  }

  CapabilityManifest? _findApprovedManifest(String adapterId) {
    final loaded = loader.loadAll(includeUnapproved: false);
    for (final m in loaded.manifests) {
      if (m.id == adapterId) return m;
    }
    return null;
  }

  CompiledCapabilityInvocation _compileForHost({
    required CapabilityManifest manifest,
    required Map<String, Object?> rawInputs,
    required ShellControlPolicy shellControl,
    String? draftId,
    DateTime? nowUtc,
  }) {
    final isWin = _isWindowsOverride ?? Platform.isWindows;
    final home = _homeDirectoryOverride ?? hostHomeDirectory();
    final resolveReal = _realPathOverride ?? resolveHostRealPath;

    String Function(String)? mapDraft;
    if (draftId != null) {
      final mgr = draftWorkspaceManager;
      if (mgr == null) {
        return const CompiledCapabilityInvocation(
          allowed: false,
          effectiveRisk: RiskTier.r3,
          errorCode: 'draft_not_found',
        );
      }
      mapDraft = (String normPath) {
        final mapped = mgr.resolvePathInDraft(
          draftId: draftId,
          rawPath: normPath,
          homeDirectory: home,
          nowUtc: nowUtc,
        );
        return mapped;
      };
    }

    try {
      return compileCapabilityInvocation(
        manifest: manifest,
        rawInputs: rawInputs,
        shellControl: shellControl,
        homeDirectory: home,
        windows: isWin,
        caseInsensitive: isWin || Platform.isMacOS,
        realPath: resolveReal,
        mapPathForDraft: mapDraft,
      );
    } on Object {
      return const CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: 'draft_path_outside_workspace',
      );
    }
  }

  XtpRemediation? _buildManifestRemediation(CapabilityDetectSpec detect) {
    final summary = detect.remediationSummary;
    if (summary == null || summary.trim().isEmpty) return null;
    final isWin = _isWindowsOverride ?? Platform.isWindows;
    final String? command;
    if (isWin) {
      command = detect.remediationCommandWindows;
    } else if (Platform.isMacOS) {
      command = detect.remediationCommandMacos;
    } else {
      command = detect.remediationCommandLinux;
    }
    try {
      return XtpRemediation(
        summary: summary,
        command: command,
        kind: XtpRemediationKind.install,
      );
    } on FormatException {
      return null;
    }
  }
}

import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/capabilities/capability_engine.dart';
import 'package:xuna_desktop/features/exec/draft_workspace_manager.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Draft verification result for a candidate Foundry manifest (`ADR-0021` §4).
class FoundryDraftVerificationResult {
  const FoundryDraftVerificationResult({
    required this.passed,
    required this.candidate,
    required this.durationMs,
    this.observedBinarySha256,
    this.errorCode,
    this.artifacts = const <Map<String, Object?>>[],
  });

  final bool passed;
  final CapabilityManifest candidate;
  final int durationMs;
  final String? observedBinarySha256;
  final String? errorCode;
  final List<Map<String, Object?>> artifacts;
}

/// Manifest Foundry (`ADR-0021` §4 / Upgrade Plan P4.4 / F2, D7):
///
/// Synthesizes **declarative [CapabilityManifest] data only** (never arbitrary
/// executable scripts, COM, or AppleScript code), verifies every candidate
/// inside an isolated `W4-M3` [DraftWorkspaceManager] copy without modifying
/// the real workspace, and promotes a manifest into [installDir] ONLY when:
/// 1. Draft verification passed (exit 0 + all declared `verifyFiles` matched),
/// 2. Explicit owner approval is provided (`ownerApproved == true`),
/// 3. Both `manifestSha256` and live `binarySha256` are pinned into
///    `provenance`.
class CapabilityFoundryService {
  CapabilityFoundryService({
    required this.engine,
    required this.draftManager,
    required this.installDir,
    ContentFreeLogger? logger,
  }) : _logger = logger;

  final CapabilityEngine engine;
  final DraftWorkspaceManager draftManager;
  final Directory installDir;
  final ContentFreeLogger? _logger;

  /// Synthesizes an unapproved candidate [CapabilityManifest] (`provenance:
  /// foundry`, `approved: false`). Rejects any shell executable, inline eval
  /// flag, shell metacharacter, or untyped placeholder fail-closed.
  CapabilityManifest proposeManifest({
    required String id,
    required String capability,
    required String description,
    required String binary,
    required List<String> argvTemplate,
    required List<CapabilityInputSpec> inputs,
    List<String> fromFormats = const <String>[],
    List<String> toFormats = const <String>[],
    RiskTier risk = RiskTier.r2,
    List<String> versionArgs = const <String>['--version'],
    List<CapabilityVerifyFileSpec> verifyFiles =
        const <CapabilityVerifyFileSpec>[],
    int timeoutMs = 30000,
    String? remediationSummary,
  }) {
    final base = CapabilityManifest(
      id: id,
      capability: capability,
      description: description,
      fromFormats: fromFormats,
      toFormats: toFormats,
      risk: risk,
      inputs: inputs,
      detect: CapabilityDetectSpec(
        binary: binary,
        versionArgs: versionArgs,
        remediationSummary: remediationSummary,
      ),
      invoke: CapabilityInvokeSpec(
        argvTemplate: argvTemplate,
        timeoutMs: timeoutMs,
      ),
      verifyFiles: verifyFiles,
      provenance: CapabilityProvenance(
        kind: CapabilityProvenanceKind.foundry,
        approved: false,
      ),
    );
    return base.withProvenance(
      base.provenance.copyWith(manifestSha256: base.computeContentSha256()),
    );
  }

  /// Runs a golden verification test of [candidate] inside an isolated `W4-M3`
  /// draft workspace copy of [workspacePath], leaving the real workspace
  /// completely untouched, then discards the temporary draft copy.
  Future<FoundryDraftVerificationResult> verifyCandidateInDraft({
    required CapabilityManifest candidate,
    required String workspacePath,
    required Map<String, Object?> goldenInputs,
    required ShellControlPolicy shellControl,
    DateTime? nowUtc,
  }) async {
    final sw = Stopwatch()..start();
    if (!candidate.hasValidManifestPin) {
      sw.stop();
      return FoundryDraftVerificationResult(
        passed: false,
        candidate: candidate,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'manifest_sha256_mismatch',
      );
    }
    if (candidate.verifyFiles.isEmpty) {
      sw.stop();
      return FoundryDraftVerificationResult(
        passed: false,
        candidate: candidate,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'foundry_verify_files_required',
      );
    }

    final detected = await engine.detector.detect(candidate.detect);
    if (detected == null) {
      sw.stop();
      return FoundryDraftVerificationResult(
        passed: false,
        candidate: candidate,
        durationMs: sw.elapsedMilliseconds,
        errorCode: 'toolchain_missing',
      );
    }

    final session = await draftManager.createDraft(
      rawWorkspacePath: workspacePath,
      shellControl: shellControl,
      nowUtc: nowUtc,
    );
    try {
      final outcome = await engine.runAdapter(
        adapterId: candidate.id,
        rawInputs: goldenInputs,
        shellControl: shellControl,
        draftId: session.draftId,
        candidateManifestOverride: candidate,
        nowUtc: nowUtc,
      );
      sw.stop();
      _logger?.info('foundry.draft_verified', <String, Object?>{
        'status': outcome.succeeded ? 'ok' : 'failed',
        'durationMs': sw.elapsedMilliseconds,
      });
      return FoundryDraftVerificationResult(
        passed: outcome.succeeded,
        candidate: candidate,
        durationMs: sw.elapsedMilliseconds,
        observedBinarySha256: detected.binarySha256,
        errorCode: outcome.succeeded ? null : (outcome.errorCode ?? 'failed'),
        artifacts: outcome.artifacts,
      );
    } finally {
      draftManager.discardDraft(session.draftId);
    }
  }

  /// Promotes a draft-verified Foundry manifest to [installDir] ONLY when
  /// [verification.passed] is true AND [ownerApproved] is true. Pins both
  /// `manifestSha256` and `binarySha256` into `provenance`.
  Future<CapabilityManifest> approveAndInstall({
    required FoundryDraftVerificationResult verification,
    required bool ownerApproved,
    DateTime? nowUtc,
  }) async {
    if (!verification.passed || verification.observedBinarySha256 == null) {
      throw StateError('foundry_unverified');
    }
    if (!ownerApproved) {
      throw StateError('owner_approval_required');
    }
    final ts = (nowUtc ?? DateTime.now()).toUtc().toIso8601String();
    final pinned = verification.candidate.withProvenance(
      CapabilityProvenance(
        kind: CapabilityProvenanceKind.foundry,
        approved: true,
        manifestSha256: verification.candidate.computeContentSha256(),
        binarySha256: verification.observedBinarySha256,
        approvedAt: ts,
      ),
    );
    if (!await installDir.exists()) {
      await installDir.create(recursive: true);
    }
    final targetFile = File(
      '${installDir.path}${Platform.pathSeparator}${pinned.id}.json',
    );
    await targetFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(pinned.toJson())}\n',
      flush: true,
    );
    _logger?.info('foundry.manifest_installed', const <String, Object?>{
      'status': 'ok',
    });
    return pinned;
  }
}

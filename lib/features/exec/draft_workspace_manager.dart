import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/fs_undo_journal.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class DraftBaselineFile {
  const DraftBaselineFile({required this.sha256Hex, required this.sizeBytes});

  final String sha256Hex;
  final int sizeBytes;
}

/// Active isolated draft workspace copy (`ADR-0019` §3 / `W4-M3`).
class DraftWorkspaceSession {
  DraftWorkspaceSession({
    required this.draftId,
    required this.workspaceAlias,
    required this.sourceWorkspaceRoot,
    required this.draftDir,
    required this.createdAt,
    required this.expiresAt,
    required this.fileCount,
    required this.totalBytes,
    required Map<String, DraftBaselineFile> baseline,
  }) : _baseline = baseline;

  final String draftId;
  final String workspaceAlias;

  /// Normalized original workspace root path (host-local; never sent on wire).
  final String sourceWorkspaceRoot;

  /// Isolated local copy directory under `AgentPaths.draftsDir`.
  final Directory draftDir;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int fileCount;
  final int totalBytes;
  final Map<String, DraftBaselineFile> _baseline;

  int commandCount = 0;
  int failedCommandCount = 0;

  bool isExpiredAt(DateTime nowUtc) => !nowUtc.toUtc().isBefore(expiresAt);
}

/// Live computed `EffectManifest` + its canonical `effectSha256`.
class DraftManifestSnapshot {
  const DraftManifestSnapshot({
    required this.manifest,
    required this.effectSha256,
  });

  final EffectManifest manifest;
  final String effectSha256;
}

/// Result of a fail-closed `draft.apply` transaction (`ADR-0019` §4 / `W4-M4`).
class DraftApplyResult {
  const DraftApplyResult({
    required this.draftId,
    required this.effectSha256,
    required this.appliedCount,
    required this.createdCount,
    required this.modifiedCount,
    required this.deletedCount,
    required this.undoTxId,
    required this.undoAvailable,
  });

  final String draftId;
  final String effectSha256;
  final int appliedCount;
  final int createdCount;
  final int modifiedCount;
  final int deletedCount;
  final String undoTxId;
  final bool undoAvailable;
}

/// Manages bounded isolated workspace copies (`W4-M3`) and fail-closed
/// effect-bound apply transactions (`W4-M4`, `ADR-0019` §3–§4).
///
/// Security & privacy invariants:
/// - Filtered physical copy excludes heavy build/VCS caches and hard-skips
///   symlinks, Hard-Deny paths, and secret files (`.env*`, `*.pem`, `*.key`,
///   etc.). Original workspace stays `0` bytes altered until verified
///   `draft.apply`.
/// - Caps (owner-approved M3-1 Option A): `maxFiles = 2000`, `maxBytes = 100 MiB`
///   (`draft_workspace_too_large`), `maxConcurrentDrafts = 2`
///   (`draft_limit_reached`), `ttl = 30 min`.
/// - Sweeps all draft copies on startup and Emergency Stop.
/// - Never logs file paths or contents into [ContentFreeLogger] (`desktop/AGENTS.md` §3.6).
class DraftWorkspaceManager {
  DraftWorkspaceManager({
    required this.rootDir,
    this.logger,
    this.maxFiles = defaultMaxFiles,
    this.maxBytes = defaultMaxBytes,
    this.maxConcurrentDrafts = defaultMaxConcurrentDrafts,
    this.ttl = defaultTtl,
    this.maxReplayCacheEntries = 256,
    String? Function(String normalizedPath)? resolveRealPath,
    bool? isWindowsOverride,
  }) : _resolveRealPath = resolveRealPath ?? resolveHostRealPath,
       _isWindows = isWindowsOverride ?? Platform.isWindows;

  /// Approved M3-1 Option A limits (`ADR-0019` §3).
  static const int defaultMaxFiles = 2000;
  static const int defaultMaxBytes = 100 * 1024 * 1024;
  static const int defaultMaxConcurrentDrafts = 2;
  static const Duration defaultTtl = Duration(minutes: 30);

  /// Heavy cache/VCS directories skipped during filtered physical copy.
  static const Set<String> excludedDirectoryNames = <String>{
    '.git',
    'node_modules',
    '.venv',
    'build',
    '.dart_tool',
    'target',
    '__pycache__',
    '.gradle',
    '.next',
    'dist',
  };

  final Directory rootDir;
  final ContentFreeLogger? logger;
  final int maxFiles;
  final int maxBytes;
  final int maxConcurrentDrafts;
  final Duration ttl;
  final int maxReplayCacheEntries;
  final String? Function(String normalizedPath) _resolveRealPath;
  final bool _isWindows;

  final Map<String, DraftWorkspaceSession> _sessions =
      <String, DraftWorkspaceSession>{};
  final LinkedHashSet<String> _consumedApprovalIds = LinkedHashSet<String>();
  int _seq = 0;

  bool get _caseInsensitive => _isWindows || Platform.isMacOS;

  int get activeDraftCount => _sessions.length;

  /// Deletes all stale draft directories under [rootDir] on agent startup.
  Future<int> cleanupAllOnStartup() async {
    _sessions.clear();
    if (!await rootDir.exists()) return 0;
    var removed = 0;
    try {
      for (final entity in rootDir.listSync(followLinks: false)) {
        try {
          entity.deleteSync(recursive: true);
          removed++;
        } on FileSystemException {
          // Best-effort cleanup of stale temp directories.
        }
      }
    } on FileSystemException {
      return removed;
    }
    logger?.info('draft.startup_cleanup', <String, Object?>{
      'removedCount': removed,
    });
    return removed;
  }

  /// Discards all active drafts (invoked on Emergency Stop).
  void discardAll({String reason = 'estop'}) {
    final ids = _sessions.keys.toList(growable: false);
    for (final id in ids) {
      discardDraft(id);
    }
    if (ids.isNotEmpty) {
      logger?.info('draft.discard_all', <String, Object?>{
        'count': ids.length,
        'reason': reason,
      });
    }
  }

  /// Creates an isolated filtered copy of [rawWorkspacePath].
  Future<DraftWorkspaceSession> createDraft({
    required String rawWorkspacePath,
    String? requestedAlias,
    required ShellControlPolicy? shellControl,
    String? homeDirectory,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    _pruneExpired(now);
    if (_sessions.length >= maxConcurrentDrafts) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_limit_reached',
      );
    }

    final normalizedWs = normalizeHostPath(
      rawWorkspacePath,
      homeDirectory: homeDirectory,
      windows: _isWindows,
    );
    if (normalizedWs == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'path_not_absolute',
      );
    }
    final resolvedWs = _resolveRealPath(normalizedWs);
    if (hardDeniedPathReason(normalizedWs) != null ||
        (resolvedWs != null && hardDeniedPathReason(resolvedWs) != null)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'fs_path_forbidden',
      );
    }
    if (isSecretFileName(normalizedWs) ||
        (resolvedWs != null && isSecretFileName(resolvedWs))) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'fs_secret_file_forbidden',
      );
    }
    if (shellControl == null ||
        !_isInsideConfiguredRoots(
          normalizedWs,
          resolvedWs,
          shellControl,
          homeDirectory: homeDirectory,
        )) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'fs_outside_workspace',
      );
    }

    final srcDir = Directory(normalizedWs);
    if (!srcDir.existsSync()) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'fs_not_a_directory',
      );
    }

    final alias = _sanitizeAlias(requestedAlias ?? _basename(normalizedWs));
    await _ensureRootDir();
    final draftId = _nextDraftId(now);
    final draftDir = Directory(
      '${rootDir.path}${Platform.pathSeparator}$draftId',
    );
    await draftDir.create(recursive: true);

    final baseline = <String, DraftBaselineFile>{};
    var fileCount = 0;
    var totalBytes = 0;

    try {
      void copyDir(Directory currentSrc, String relPrefix) {
        final entries = currentSrc.listSync(followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final entity in entries) {
          // Never follow symlinks when populating an isolated draft copy.
          if (entity is Link) continue;
          final name = _basename(entity.path);
          if (name.isEmpty || name == '.' || name == '..') continue;
          final rel = relPrefix.isEmpty ? name : '$relPrefix/$name';
          final normSrc = normalizeHostPath(
            entity.path,
            homeDirectory: homeDirectory,
            windows: _isWindows,
          );
          if (normSrc == null) continue;
          final resolvedSrc = _resolveRealPath(normSrc);
          if (hardDeniedPathReason(normSrc) != null ||
              hardDeniedPathReason(rel) != null ||
              (resolvedSrc != null &&
                  hardDeniedPathReason(resolvedSrc) != null)) {
            continue;
          }
          if (entity is Directory) {
            if (excludedDirectoryNames.contains(name.toLowerCase())) continue;
            final dstSub = Directory(
              '${draftDir.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}',
            );
            dstSub.createSync(recursive: true);
            copyDir(entity, rel);
            continue;
          }
          if (entity is File) {
            if (isSecretFileName(normSrc) ||
                isSecretFileName(rel) ||
                (resolvedSrc != null && isSecretFileName(resolvedSrc))) {
              continue;
            }
            final int size;
            try {
              size = entity.lengthSync();
            } on FileSystemException {
              continue;
            }
            if (fileCount + 1 > maxFiles || totalBytes + size > maxBytes) {
              throw const XunaHostChannelException(
                status: XtpStatus.failed,
                errorCode: 'draft_workspace_too_large',
              );
            }
            final bytes = entity.readAsBytesSync();
            final dstFile = File(
              '${draftDir.path}${Platform.pathSeparator}${rel.replaceAll('/', Platform.pathSeparator)}',
            );
            dstFile.parent.createSync(recursive: true);
            dstFile.writeAsBytesSync(bytes, flush: false);
            baseline[rel] = DraftBaselineFile(
              sha256Hex: sha256.convert(bytes).toString(),
              sizeBytes: bytes.length,
            );
            fileCount++;
            totalBytes += bytes.length;
          }
        }
      }

      copyDir(srcDir, '');
    } on Object {
      _tryDeleteDir(draftDir);
      rethrow;
    }

    final session = DraftWorkspaceSession(
      draftId: draftId,
      workspaceAlias: alias,
      sourceWorkspaceRoot: normalizedWs,
      draftDir: draftDir,
      createdAt: now,
      expiresAt: now.add(ttl),
      fileCount: fileCount,
      totalBytes: totalBytes,
      baseline: baseline,
    );
    _sessions[draftId] = session;
    logger?.info('draft.created', <String, Object?>{
      'fileCount': fileCount,
      'totalBytes': totalBytes,
    });
    return session;
  }

  /// Looks up a live, unexpired draft session or throws `draft_not_found` /
  /// `draft_expired`.
  DraftWorkspaceSession requireSession(String draftId, {DateTime? nowUtc}) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    final session = _sessions[draftId];
    if (session == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_not_found',
      );
    }
    if (session.isExpiredAt(now)) {
      discardDraft(draftId);
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_expired',
      );
    }
    return session;
  }

  /// Resolves a workspace path [rawPath] into the isolated copy directory for
  /// [draftId]. Refuses any path outside the draft's workspace root, any
  /// symlink escaping the draft directory, or any Hard-Deny/secret path.
  String resolvePathInDraft({
    required String draftId,
    required String rawPath,
    String? homeDirectory,
    DateTime? nowUtc,
  }) {
    final session = requireSession(draftId, nowUtc: nowUtc);
    final normalized = normalizeHostPath(
      rawPath,
      homeDirectory: homeDirectory,
      windows: _isWindows,
    );
    if (normalized == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'path_not_absolute',
      );
    }
    if (hardDeniedPathReason(normalized) != null) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'fs_path_forbidden',
      );
    }
    if (isSecretFileName(normalized)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'fs_secret_file_forbidden',
      );
    }

    final draftRootNorm = normalizeHostPath(
      session.draftDir.path,
      homeDirectory: homeDirectory,
      windows: _isWindows,
    )!;

    String rel;
    if (isPathInsideRoot(
      normalized,
      session.sourceWorkspaceRoot,
      caseInsensitive: _caseInsensitive,
    )) {
      rel = _relativePath(session.sourceWorkspaceRoot, normalized);
    } else if (isPathInsideRoot(
      normalized,
      draftRootNorm,
      caseInsensitive: _caseInsensitive,
    )) {
      rel = _relativePath(draftRootNorm, normalized);
    } else {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'draft_path_outside_workspace',
      );
    }

    final mappedRaw = rel.isEmpty ? draftRootNorm : '$draftRootNorm/$rel';
    final mappedNorm = normalizeHostPath(
      mappedRaw,
      homeDirectory: homeDirectory,
      windows: _isWindows,
    );
    if (mappedNorm == null ||
        !isPathInsideRoot(
          mappedNorm,
          draftRootNorm,
          caseInsensitive: _caseInsensitive,
        )) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'draft_path_outside_workspace',
      );
    }
    final resolvedDraftRoot = _resolveRealPath(draftRootNorm) ?? draftRootNorm;
    final resolvedMapped = _resolveRealPath(mappedNorm);
    if (resolvedMapped != null) {
      if (!isPathInsideRoot(
        resolvedMapped,
        resolvedDraftRoot,
        caseInsensitive: _caseInsensitive,
      )) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'draft_path_outside_workspace',
        );
      }
      if (hardDeniedPathReason(resolvedMapped) != null) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_path_forbidden',
        );
      }
      if (isSecretFileName(resolvedMapped)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_secret_file_forbidden',
        );
      }
    }
    return mappedNorm;
  }

  /// Resolves the draft working directory for `exec.run(draftId: ...)`.
  String resolveCwdInDraft({
    required String draftId,
    String? rawCwd,
    String? homeDirectory,
    DateTime? nowUtc,
  }) {
    final session = requireSession(draftId, nowUtc: nowUtc);
    if (rawCwd == null || rawCwd.trim().isEmpty) {
      return normalizeHostPath(
        session.draftDir.path,
        homeDirectory: homeDirectory,
        windows: _isWindows,
      )!;
    }
    return resolvePathInDraft(
      draftId: draftId,
      rawPath: rawCwd,
      homeDirectory: homeDirectory,
      nowUtc: nowUtc,
    );
  }

  /// Records the outcome of an `R2` `exec.run` check inside [draftId].
  void recordExecCheckOutcome(String draftId, {required bool completed}) {
    final session = _sessions[draftId];
    if (session == null) return;
    session.commandCount++;
    if (!completed) {
      session.failedCommandCount++;
    }
  }

  /// Computes the live canonical [EffectManifest] and `effectSha256` for [draftId].
  DraftManifestSnapshot buildManifest(String draftId, {DateTime? nowUtc}) {
    final session = requireSession(draftId, nowUtc: nowUtc);
    if (!session.draftDir.existsSync()) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_not_found',
      );
    }

    final liveFiles = <String, DraftBaselineFile>{};
    final draftRootNorm = normalizeHostPath(
      session.draftDir.path,
      windows: _isWindows,
    )!;
    final resolvedDraftRoot = _resolveRealPath(draftRootNorm) ?? draftRootNorm;

    void scan(Directory dir, String relPrefix) {
      final entries = dir.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entity in entries) {
        if (entity is Link) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'draft_symlink_forbidden',
          );
        }
        final name = _basename(entity.path);
        if (name.isEmpty || name == '.' || name == '..') continue;
        final rel = relPrefix.isEmpty ? name : '$relPrefix/$name';
        if (entity is Directory) {
          if (excludedDirectoryNames.contains(name.toLowerCase())) continue;
          if (hardDeniedPathReason(rel) != null) {
            throw const XunaHostChannelException(
              status: XtpStatus.denied,
              errorCode: 'fs_path_forbidden',
            );
          }
          scan(entity, rel);
          continue;
        }
        if (entity is File) {
          if (hardDeniedPathReason(rel) != null) {
            throw const XunaHostChannelException(
              status: XtpStatus.denied,
              errorCode: 'fs_path_forbidden',
            );
          }
          if (isSecretFileName(rel)) {
            throw const XunaHostChannelException(
              status: XtpStatus.denied,
              errorCode: 'fs_secret_file_forbidden',
            );
          }
          final normEntity = normalizeHostPath(
            entity.path,
            windows: _isWindows,
          );
          final resolved = normEntity == null
              ? null
              : _resolveRealPath(normEntity);
          if (resolved != null &&
              !isPathInsideRoot(
                resolved,
                resolvedDraftRoot,
                caseInsensitive: _caseInsensitive,
              )) {
            throw const XunaHostChannelException(
              status: XtpStatus.denied,
              errorCode: 'draft_path_outside_workspace',
            );
          }
          final bytes = entity.readAsBytesSync();
          liveFiles[rel] = DraftBaselineFile(
            sha256Hex: sha256.convert(bytes).toString(),
            sizeBytes: bytes.length,
          );
        }
      }
    }

    scan(session.draftDir, '');

    final changes = <EffectManifestChange>[];
    for (final entry in liveFiles.entries) {
      final base = session._baseline[entry.key];
      if (base == null) {
        changes.add(
          EffectManifestChange(
            relPath: entry.key,
            op: EffectChangeOp.create,
            postSha256: entry.value.sha256Hex,
            sizeBytes: entry.value.sizeBytes,
          ),
        );
      } else if (base.sha256Hex != entry.value.sha256Hex) {
        changes.add(
          EffectManifestChange(
            relPath: entry.key,
            op: EffectChangeOp.modify,
            preSha256: base.sha256Hex,
            postSha256: entry.value.sha256Hex,
            sizeBytes: entry.value.sizeBytes,
          ),
        );
      }
    }
    for (final entry in session._baseline.entries) {
      if (!liveFiles.containsKey(entry.key)) {
        changes.add(
          EffectManifestChange(
            relPath: entry.key,
            op: EffectChangeOp.delete,
            preSha256: entry.value.sha256Hex,
          ),
        );
      }
    }

    final checks = session.commandCount > 0
        ? EffectManifestChecks(
            commandCount: session.commandCount,
            allCompleted: session.failedCommandCount == 0,
            failedCount: session.failedCommandCount,
          )
        : null;

    final manifest = EffectManifest(
      draftId: session.draftId,
      workspaceAlias: session.workspaceAlias,
      changes: changes,
      checks: checks,
      createdAt: session.createdAt.toUtc().toIso8601String(),
      expiresAt: session.expiresAt.toUtc().toIso8601String(),
    );
    return DraftManifestSnapshot(
      manifest: manifest,
      effectSha256: manifest.computeEffectSha256(),
    );
  }

  /// Builds a bounded `xuna/preflight` preview and live `effectSha256` for
  /// `draft.apply`. Refuses if the draft is missing/expired, empty, or does
  /// not match [requestedEffectSha256].
  ({String effectSha256, XtpPreflightPreview preview}) preflightApply({
    required String draftId,
    required String requestedEffectSha256,
    DateTime? nowUtc,
  }) {
    final snapshot = buildManifest(draftId, nowUtc: nowUtc);
    if (snapshot.manifest.changes.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_empty_manifest',
      );
    }
    if (snapshot.effectSha256 != requestedEffectSha256) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'effect_sha256_mismatch',
      );
    }
    final allPaths = snapshot.manifest.changes
        .map((c) => c.relPath)
        .toList(growable: false);
    final truncated = allPaths.length > XtpPreflightPreview.maxPaths;
    final shown = truncated
        ? allPaths.sublist(0, XtpPreflightPreview.maxPaths)
        : allPaths;
    final m = snapshot.manifest;
    final summary =
        'Áp dụng bản nháp ${m.workspaceAlias}: '
        '${m.changes.length} tệp (+${m.createdCount} ~${m.modifiedCount} -${m.deletedCount})';
    return (
      effectSha256: snapshot.effectSha256,
      preview: XtpPreflightPreview.paths(
        summary: summary.length <= XtpPreflightPreview.maxSummaryChars
            ? summary
            : summary.substring(0, XtpPreflightPreview.maxSummaryChars),
        paths: shown,
        totalCount: allPaths.length,
        truncated: truncated,
      ),
    );
  }

  /// Applies a draft workspace through all 6 ADR-0019 §4 fail-closed gates:
  /// 1. Verify P-256 `xuna.approval.v2` signature + single-use `approvalId` replay cache.
  /// 2. Recompute live `effectSha256(manifest) == requestedEffectSha256 == approval.effectSha256`.
  /// 3. Re-verify every target path inside `sourceWorkspaceRoot` & `workspaceRoots`.
  /// 4. TOCTOU check every target file against `preSha256` (and `create` non-existent).
  /// 5. Apply atomically via [FsUndoJournal.applyTransaction] (crash-safe WAL + rollback).
  /// 6. Keep committed WAL entry for one-step `action.undo` and discard draft copy.
  Future<DraftApplyResult> applyDraft({
    required String draftId,
    required String requestedEffectSha256,
    required ApprovalToken? approval,
    required Map<String, Object?> arguments,
    required String? hostId,
    required List<Uint8List> pinnedPhonePublicKeys,
    required FsUndoJournal undoJournal,
    required ShellControlPolicy? shellControl,
    String? homeDirectory,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();

    // Gate 1: Re-verify xuna.approval.v2 signature and single-use replay cache.
    final sigError = verifyPhoneSignedEffectApproval(
      approval: approval,
      arguments: arguments,
      expectedEffectSha256: requestedEffectSha256,
      nowUtc: now,
      hostId: hostId,
      pinnedPhonePublicKeys: pinnedPhonePublicKeys,
    );
    if (sigError != null) {
      throw XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: sigError,
      );
    }
    final token = approval!;
    if (_consumedApprovalIds.contains(token.approvalId)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'approval_replayed',
      );
    }

    // Gate 2: Recompute live manifest & verify exact effectSha256 binding.
    final session = requireSession(draftId, nowUtc: now);
    final snapshot = buildManifest(draftId, nowUtc: now);
    if (snapshot.manifest.changes.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'draft_empty_manifest',
      );
    }
    if (snapshot.effectSha256 != requestedEffectSha256 ||
        snapshot.effectSha256 != token.effectSha256) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'effect_sha256_mismatch',
      );
    }

    // Gate 3 & 4: Build planned changes with strict path guards + TOCTOU hashes.
    final plannedChanges = <FsPlannedChange>[];
    final resolvedWsRoot =
        _resolveRealPath(session.sourceWorkspaceRoot) ??
        session.sourceWorkspaceRoot;
    for (final change in snapshot.manifest.changes) {
      final targetPath = '${session.sourceWorkspaceRoot}/${change.relPath}';
      final normTarget = normalizeHostPath(
        targetPath,
        homeDirectory: homeDirectory,
        windows: _isWindows,
      );
      if (normTarget == null ||
          !isPathInsideRoot(
            normTarget,
            session.sourceWorkspaceRoot,
            caseInsensitive: _caseInsensitive,
          )) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'draft_path_outside_workspace',
        );
      }
      final resolvedTarget = _resolveRealPath(normTarget);
      if (resolvedTarget != null &&
          !isPathInsideRoot(
            resolvedTarget,
            resolvedWsRoot,
            caseInsensitive: _caseInsensitive,
          )) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'draft_path_outside_workspace',
        );
      }

      if (change.op == EffectChangeOp.delete) {
        plannedChanges.add(
          FsPlannedChange(
            path: normTarget,
            newBytes: null,
            expectedPreSha256: change.preSha256,
          ),
        );
      } else {
        final draftFile = File(
          '${session.draftDir.path}${Platform.pathSeparator}${change.relPath.replaceAll('/', Platform.pathSeparator)}',
        );
        if (!draftFile.existsSync()) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'effect_sha256_mismatch',
          );
        }
        final draftBytes = draftFile.readAsBytesSync();
        final liveDraftSha = sha256.convert(draftBytes).toString();
        if (liveDraftSha != change.postSha256) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'effect_sha256_mismatch',
          );
        }
        plannedChanges.add(
          FsPlannedChange(
            path: normTarget,
            newBytes: draftBytes,
            createParents: change.op == EffectChangeOp.create,
            expectedPreSha256: change.op == EffectChangeOp.modify
                ? change.preSha256
                : null,
            expectNotExists: change.op == EffectChangeOp.create,
            expectNotExistsErrorCode: 'toctou_mismatch',
          ),
        );
      }
    }

    // Gate 5: Apply via crash-safe W4-M1 WAL journal (TOCTOU + MoveFileExW + rollback).
    final txResult = await undoJournal.applyTransaction(
      toolName: 'draft.apply',
      changes: plannedChanges,
      shellControl: shellControl,
      homeDirectory: homeDirectory,
      nowUtc: now,
      requireInsideWorkspaceRoots: true,
    );

    // Gate 6: Mark approvalId single-use consumed and remove temporary draft copy.
    _markApprovalConsumed(token.approvalId);
    discardDraft(draftId);

    logger?.info('draft.applied', <String, Object?>{
      'appliedCount': snapshot.manifest.changes.length,
      'createdCount': snapshot.manifest.createdCount,
      'modifiedCount': snapshot.manifest.modifiedCount,
      'deletedCount': snapshot.manifest.deletedCount,
    });

    return DraftApplyResult(
      draftId: draftId,
      effectSha256: snapshot.effectSha256,
      appliedCount: snapshot.manifest.changes.length,
      createdCount: snapshot.manifest.createdCount,
      modifiedCount: snapshot.manifest.modifiedCount,
      deletedCount: snapshot.manifest.deletedCount,
      undoTxId: txResult.txId,
      undoAvailable: true,
    );
  }

  /// Discards [draftId] and deletes its temporary copy. Returns `true` if the
  /// draft existed.
  bool discardDraft(String draftId) {
    final removed = _sessions.remove(draftId);
    if (removed == null) return false;
    _tryDeleteDir(removed.draftDir);
    logger?.info('draft.discarded', const <String, Object?>{});
    return true;
  }

  void _markApprovalConsumed(String approvalId) {
    while (_consumedApprovalIds.length >= maxReplayCacheEntries) {
      _consumedApprovalIds.remove(_consumedApprovalIds.first);
    }
    _consumedApprovalIds.add(approvalId);
  }

  void _pruneExpired(DateTime nowUtc) {
    final expired = _sessions.values
        .where((s) => s.isExpiredAt(nowUtc))
        .map((s) => s.draftId)
        .toList(growable: false);
    for (final id in expired) {
      discardDraft(id);
    }
  }

  Future<void> _ensureRootDir() async {
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
      if (!_isWindows) {
        try {
          await Process.run('/bin/chmod', <String>['700', rootDir.path]);
        } on Object {
          // Best-effort owner-only permissions on POSIX.
        }
      }
    }
  }

  bool _isInsideConfiguredRoots(
    String normalizedPath,
    String? resolvedPath,
    ShellControlPolicy shellControl, {
    String? homeDirectory,
  }) {
    if (shellControl.workspaceRoots.isEmpty) return false;
    for (final rawRoot in shellControl.workspaceRoots) {
      final normRoot = normalizeHostPath(
        rawRoot,
        homeDirectory: homeDirectory,
        windows: _isWindows,
      );
      if (normRoot == null) continue;
      final resolvedRoot = _resolveRealPath(normRoot) ?? normRoot;
      final lexicalOk = isPathInsideRoot(
        normalizedPath,
        normRoot,
        caseInsensitive: _caseInsensitive,
      );
      final realOk =
          resolvedPath == null ||
          isPathInsideRoot(
            resolvedPath,
            resolvedRoot,
            caseInsensitive: _caseInsensitive,
          );
      if (lexicalOk && realOk) return true;
    }
    return false;
  }

  String _nextDraftId(DateTime nowUtc) {
    _seq++;
    final rand = Random.secure()
        .nextInt(1 << 24)
        .toRadixString(16)
        .padLeft(6, '0');
    return 'draft_${nowUtc.millisecondsSinceEpoch}_${_seq}_$rand';
  }

  static String _relativePath(String root, String path) {
    final r = root.endsWith('/') && root.length > 1
        ? root.substring(0, root.length - 1)
        : root;
    if (path.length <= r.length) return '';
    return path.substring(r.length + 1);
  }

  static String _basename(String path) {
    final clean = path.replaceAll(r'\', '/');
    final trimmed = clean.endsWith('/') && clean.length > 1
        ? clean.substring(0, clean.length - 1)
        : clean;
    final slash = trimmed.lastIndexOf('/');
    return slash == -1 ? trimmed : trimmed.substring(slash + 1);
  }

  static String _sanitizeAlias(String raw) {
    final cleaned = raw.trim().replaceAll(RegExp(r'[^a-zA-Z0-9_.-]+'), '_');
    if (cleaned.isEmpty ||
        cleaned == '.' ||
        cleaned == '..' ||
        cleaned.contains('..')) {
      return 'workspace';
    }
    return cleaned.length <= 64 ? cleaned : cleaned.substring(0, 64);
  }

  static void _tryDeleteDir(Directory dir) {
    try {
      if (dir.existsSync()) {
        dir.deleteSync(recursive: true);
      }
    } on FileSystemException {
      // Best-effort cleanup.
    }
  }
}

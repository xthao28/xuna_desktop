import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_desktop/features/exec/windows_kernel32_ffi.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Error thrown when an atomic file replace fails (including Win32 lock errors).
class AtomicReplaceException implements Exception {
  const AtomicReplaceException({
    required this.osErrorCode,
    required this.isLocked,
  });

  final int osErrorCode;
  final bool isLocked;

  @override
  String toString() =>
      'AtomicReplaceException(osErrorCode: $osErrorCode, isLocked: $isLocked)';
}

/// Replaces [targetPath] with sibling [tempPath] atomically.
typedef AtomicFileReplacer = void Function(String tempPath, String targetPath);

/// Default OS-native atomic file replace:
/// - Windows: Win32 `MoveFileExW(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)`
///   via `kernel32.dll` FFI so sharing/access lock errors (`5` / `32`) are
///   observed directly without external packages (`ADR-0019` Spike c).
/// - POSIX (macOS/Linux): atomic `rename(2)` via `dart:io`.
void defaultAtomicReplaceFile(String tempPath, String targetPath) {
  if (!Platform.isWindows) {
    try {
      File(tempPath).renameSync(targetPath);
    } on FileSystemException catch (e) {
      throw AtomicReplaceException(
        osErrorCode: e.osError?.errorCode ?? -1,
        isLocked: false,
      );
    }
    return;
  }
  final k32 = WinKernel32.instance;
  final srcNative = tempPath.replaceAll('/', r'\');
  final dstNative = targetPath.replaceAll('/', r'\');
  final srcPtr = k32.allocUtf16(encodeUtf16NullTerminated(srcNative));
  final dstPtr = k32.allocUtf16(encodeUtf16NullTerminated(dstNative));
  try {
    final ok = k32.moveFileExW(
      srcPtr,
      dstPtr,
      winMoveFileReplaceExisting | winMoveFileWriteThrough,
    );
    if (ok == 0) {
      // Read GetLastError immediately before HeapFree can alter thread state.
      final err = k32.getLastError();
      throw AtomicReplaceException(
        osErrorCode: err,
        isLocked:
            err == winErrorAccessDenied || err == winErrorSharingViolation,
      );
    }
  } finally {
    k32.free(srcPtr);
    k32.free(dstPtr);
  }
}

/// Writes [bytes] to a unique sibling temporary file with `flush: true` and
/// atomically replaces [targetPath] via [replaceFile].
///
/// Cleans up the temporary file on any failure and rethrows
/// [AtomicReplaceException] / [FileSystemException] without hiding the cause.
Future<({int bytes, bool created, String sha256Hex})> writeTempAndReplaceFile({
  required String targetPath,
  required List<int> bytes,
  required bool createParents,
  int? preserveMode,
  AtomicFileReplacer replaceFile = defaultAtomicReplaceFile,
}) async {
  final target = File(targetPath);
  final parent = target.parent;
  if (!parent.existsSync()) {
    if (!createParents) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'fs_parent_missing',
      );
    }
    parent.createSync(recursive: true);
  }
  final existed = target.existsSync();
  final mode =
      preserveMode ??
      (existed && !Platform.isWindows ? target.statSync().mode : null);
  final baseName = _basename(targetPath);
  final tmp = File(
    '${parent.path}${Platform.pathSeparator}.$baseName.xuna-'
    '${Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}.tmp',
  );
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    if (mode != null && !Platform.isWindows && (mode & 0x49) != 0) {
      await Process.run('/bin/chmod', <String>[
        (mode & 0x1FF).toRadixString(8),
        tmp.path,
      ]);
    }
    replaceFile(tmp.path, targetPath);
  } on Object {
    _tryDeleteFile(tmp);
    rethrow;
  }
  return (
    bytes: bytes.length,
    created: !existed,
    sha256Hex: sha256.convert(bytes).toString(),
  );
}

/// Direct atomic write without a WAL journal entry (used for allowed writes
/// ineligible for undo journaling, such as files exceeding the per-file backup
/// cap, R3 writes outside workspace roots, or R3 writes to secret files).
Future<({int bytes, bool created, String sha256Hex})> atomicWriteFileDirect({
  required String targetPath,
  required List<int> bytes,
  required bool createParents,
  AtomicFileReplacer replaceFile = defaultAtomicReplaceFile,
}) async {
  try {
    return await writeTempAndReplaceFile(
      targetPath: targetPath,
      bytes: bytes,
      createParents: createParents,
      replaceFile: replaceFile,
    );
  } on XunaHostChannelException {
    rethrow;
  } on AtomicReplaceException catch (e) {
    throw XunaHostChannelException(
      status: XtpStatus.failed,
      errorCode: e.isLocked ? 'fs_file_locked' : 'fs_write_failed',
    );
  } on FileSystemException {
    throw const XunaHostChannelException(
      status: XtpStatus.failed,
      errorCode: 'fs_write_failed',
    );
  }
}

/// Lifecycle state of a persisted local file journal (`ADR-0019` §1).
enum FsJournalState {
  preparing('preparing'),
  applying('applying'),
  committed('committed'),
  rolledBack('rolled_back');

  const FsJournalState(this.wire);
  final String wire;

  static FsJournalState? fromWire(String raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }
}

/// Planned operation on a single file in a transaction.
enum FsChangeOp {
  create('create'),
  modify('modify'),
  delete('delete');

  const FsChangeOp(this.wire);
  final String wire;

  static FsChangeOp? fromWire(String raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    return null;
  }
}

/// Planned single-file mutation submitted to [FsUndoJournal.applyTransaction].
class FsPlannedChange {
  const FsPlannedChange({
    required this.path,
    required this.newBytes,
    this.createParents = false,
    this.expectedPreSha256,
    this.expectNotExists = false,
    this.expectNotExistsErrorCode = 'fs_exists',
  });

  /// Target file path (absolute; normalized and re-checked before disk access).
  final String path;

  /// New file contents for `create` / `modify`, or `null` for `delete`.
  final List<int>? newBytes;

  /// Whether missing parent directories should be created on write.
  final bool createParents;

  /// Optional TOCTOU guard: if non-null, the live file on disk must exist and
  /// match this SHA-256 hex digest before any write begins.
  final String? expectedPreSha256;

  /// If `true`, refuses with [expectNotExistsErrorCode] when the target already
  /// exists on disk before apply.
  final bool expectNotExists;

  /// Stable error code returned when [expectNotExists] is violated.
  final String expectNotExistsErrorCode;
}

/// Persisted metadata for one file inside `journal.json`.
class FsJournalFileEntry {
  const FsJournalFileEntry({
    required this.path,
    required this.op,
    required this.existed,
    required this.preSha256,
    required this.postSha256,
    required this.backupFile,
    required this.backupBytes,
    this.mode,
  });

  factory FsJournalFileEntry.fromJson(Map<String, Object?> json) {
    final path = json['path'];
    final opRaw = json['op'];
    final existed = json['existed'];
    final preSha = json['preSha256'];
    final postSha = json['postSha256'];
    final backupFile = json['backupFile'];
    final backupBytes = json['backupBytes'];
    final mode = json['mode'];
    if (path is! String ||
        path.isEmpty ||
        opRaw is! String ||
        existed is! bool ||
        backupBytes is! int ||
        backupBytes < 0 ||
        (preSha != null && preSha is! String) ||
        (postSha != null && postSha is! String) ||
        (backupFile != null && backupFile is! String) ||
        (mode != null && mode is! int)) {
      throw const FormatException('Invalid FsJournalFileEntry JSON');
    }
    final op = FsChangeOp.fromWire(opRaw);
    if (op == null) {
      throw const FormatException('Invalid FsChangeOp');
    }
    if (existed && (preSha == null || backupFile == null)) {
      throw const FormatException('Existing entry missing backup metadata');
    }
    return FsJournalFileEntry(
      path: path,
      op: op,
      existed: existed,
      preSha256: preSha as String?,
      postSha256: postSha as String?,
      backupFile: backupFile as String?,
      backupBytes: backupBytes,
      mode: mode as int?,
    );
  }

  final String path;
  final FsChangeOp op;
  final bool existed;
  final String? preSha256;
  final String? postSha256;
  final String? backupFile;
  final int backupBytes;
  final int? mode;

  Map<String, Object?> toJson() => <String, Object?>{
    'path': path,
    'op': op.wire,
    'existed': existed,
    'preSha256': preSha256,
    'postSha256': postSha256,
    'backupFile': backupFile,
    'backupBytes': backupBytes,
    if (mode != null) 'mode': mode,
  };
}

/// Persisted WAL transaction record stored in `<txDir>/journal.json`.
class FsJournalRecord {
  const FsJournalRecord({
    required this.schemaVersion,
    required this.txId,
    required this.toolName,
    required this.state,
    required this.createdAt,
    required this.expiresAt,
    required this.totalBackupBytes,
    required this.entries,
  });

  factory FsJournalRecord.fromJson(Map<String, Object?> json) {
    final version = json['schemaVersion'];
    final txId = json['txId'];
    final toolName = json['toolName'];
    final stateRaw = json['state'];
    final createdRaw = json['createdAt'];
    final expiresRaw = json['expiresAt'];
    final totalBackupBytes = json['totalBackupBytes'];
    final rawEntries = json['entries'];
    if (version != 1 ||
        txId is! String ||
        txId.isEmpty ||
        toolName is! String ||
        toolName.isEmpty ||
        stateRaw is! String ||
        createdRaw is! String ||
        expiresRaw is! String ||
        totalBackupBytes is! int ||
        totalBackupBytes < 0 ||
        rawEntries is! List) {
      throw const FormatException('Invalid FsJournalRecord JSON');
    }
    final state = FsJournalState.fromWire(stateRaw);
    final createdAt = DateTime.tryParse(createdRaw)?.toUtc();
    final expiresAt = DateTime.tryParse(expiresRaw)?.toUtc();
    if (state == null || createdAt == null || expiresAt == null) {
      throw const FormatException(
        'Invalid FsJournalRecord state or timestamps',
      );
    }
    final entries = <FsJournalFileEntry>[];
    for (final raw in rawEntries) {
      if (raw is! Map) {
        throw const FormatException('Invalid journal entry');
      }
      entries.add(
        FsJournalFileEntry.fromJson(
          raw.map((k, v) => MapEntry(k.toString(), v)),
        ),
      );
    }
    return FsJournalRecord(
      schemaVersion: version as int,
      txId: txId,
      toolName: toolName,
      state: state,
      createdAt: createdAt,
      expiresAt: expiresAt,
      totalBackupBytes: totalBackupBytes,
      entries: List<FsJournalFileEntry>.unmodifiable(entries),
    );
  }

  final int schemaVersion;
  final String txId;
  final String toolName;
  final FsJournalState state;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int totalBackupBytes;
  final List<FsJournalFileEntry> entries;

  FsJournalRecord withState(FsJournalState nextState) => FsJournalRecord(
    schemaVersion: schemaVersion,
    txId: txId,
    toolName: toolName,
    state: nextState,
    createdAt: createdAt,
    expiresAt: expiresAt,
    totalBackupBytes: totalBackupBytes,
    entries: entries,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'txId': txId,
    'toolName': toolName,
    'state': state.wire,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    'totalBackupBytes': totalBackupBytes,
    'entries': entries.map((e) => e.toJson()).toList(),
  };
}

/// Content-free metadata summary of a committed transaction (contains zero
/// file paths or file contents).
class FsUndoJournalEntrySummary {
  const FsUndoJournalEntrySummary({
    required this.txId,
    required this.toolName,
    required this.createdAt,
    required this.expiresAt,
    required this.fileCount,
  });

  final String txId;
  final String toolName;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int fileCount;
}

/// Per-file outcome returned by [FsUndoJournal.applyTransaction].
class FsAppliedFileResult {
  const FsAppliedFileResult({
    required this.normalizedPath,
    required this.bytesWritten,
    required this.created,
    required this.sha256Hex,
  });

  final String normalizedPath;
  final int bytesWritten;
  final bool created;
  final String? sha256Hex;
}

/// Outcome of a committed [FsUndoJournal.applyTransaction].
class FsTransactionResult {
  const FsTransactionResult({required this.txId, required this.files});

  final String txId;
  final List<FsAppliedFileResult> files;
}

/// Content-free outcome of [FsUndoJournal.undoTransaction].
class FsUndoResult {
  const FsUndoResult({
    required this.txId,
    required this.toolName,
    required this.filesRestored,
    required this.filesDeleted,
  });

  final String txId;
  final String toolName;
  final int filesRestored;
  final int filesDeleted;

  int get totalAffected => filesRestored + filesDeleted;
}

/// Summary returned by [FsUndoJournal.recoverAndPruneOnStartup].
class FsUndoStartupReport {
  const FsUndoStartupReport({
    required this.recoveredCount,
    required this.failedRecoveryCount,
    required this.prunedCount,
    required this.activeCommittedCount,
  });

  final int recoveredCount;
  final int failedRecoveryCount;
  final int prunedCount;
  final int activeCommittedCount;
}

/// Crash-safe local WAL undo & apply journal for workspace file mutations
/// (`ADR-0019` §1, `W4-M1` / U1; reused by `draft.apply` in `W4-M3`/`W4-M4`).
///
/// Security & privacy invariants:
/// - Stored locally under owner-only app data (`%LOCALAPPDATA%\XUNA\undo\` on
///   Windows, `~/Library/Application Support/XUNA/undo/` mode `0700` on macOS).
/// - Never writes file paths or contents into `ContentFreeLogger` or audit
///   JSONL (`desktop/AGENTS.md` §3.6).
/// - Never snapshots Hard-Deny paths, secret files (`.env*`, `*.pem`, `*.key`,
///   etc.), or files outside configured `shellControl.workspaceRoots`.
/// - Enforces bounded storage (`32 MiB` total, `2 MiB` per file, `20`
///   transactions, `30 min` TTL by default — owner-approved M1-1 Option A).
/// - User undo fails closed with `undo_conflict_modified_externally` if any
///   file was modified externally after XUNA wrote it (owner-approved M1-2 Option A).
class FsUndoJournal {
  FsUndoJournal({
    required this.rootDir,
    this.logger,
    this.maxTotalBytes = defaultMaxTotalBytes,
    this.maxPerFileBytes = defaultMaxPerFileBytes,
    this.maxTransactions = defaultMaxTransactions,
    this.ttl = defaultTtl,
    AtomicFileReplacer? replaceFile,
    String? Function(String normalizedPath)? resolveRealPath,
    bool? isWindowsOverride,
  }) : _replaceFile = replaceFile ?? defaultAtomicReplaceFile,
       _resolveRealPath = resolveRealPath ?? resolveHostRealPath,
       _isWindows = isWindowsOverride ?? Platform.isWindows;

  /// Approved M1-1 Option A defaults (`ADR-0019` §1).
  static const int defaultMaxTotalBytes = 32 * 1024 * 1024;
  static const int defaultMaxPerFileBytes = 2 * 1024 * 1024;
  static const int defaultMaxTransactions = 20;
  static const Duration defaultTtl = Duration(minutes: 30);

  final Directory rootDir;
  final ContentFreeLogger? logger;
  final int maxTotalBytes;
  final int maxPerFileBytes;
  final int maxTransactions;
  final Duration ttl;
  final AtomicFileReplacer _replaceFile;
  final String? Function(String normalizedPath) _resolveRealPath;
  final bool _isWindows;

  int _txSequence = 0;

  bool get _caseInsensitive => _isWindows || Platform.isMacOS;

  /// Returns `true` iff a single-file write to [rawPath] is eligible for undo
  /// journaling (inside `workspaceRoots`, non-secret, non-Hard-Deny, within
  /// [maxPerFileBytes] and [maxTotalBytes]).
  bool canJournalSingleWrite({
    required String rawPath,
    required int newBytesLength,
    required ShellControlPolicy? shellControl,
    String? homeDirectory,
  }) {
    if (shellControl == null || shellControl.workspaceRoots.isEmpty) {
      return false;
    }
    if (newBytesLength < 0 ||
        newBytesLength > maxPerFileBytes ||
        newBytesLength > maxTotalBytes) {
      return false;
    }
    final normalized = normalizeHostPath(
      rawPath,
      homeDirectory: homeDirectory,
      windows: _isWindows,
    );
    if (normalized == null) return false;
    final resolved = _resolveRealPath(normalized);
    if (_isForbiddenOrSecret(normalized, resolved)) return false;
    if (!_isStrictlyInsideWorkspace(
      normalized,
      resolved,
      shellControl,
      homeDirectory: homeDirectory,
    )) {
      return false;
    }
    final existing = File(normalized);
    if (existing.existsSync()) {
      try {
        final len = existing.lengthSync();
        if (len > maxPerFileBytes || len > maxTotalBytes) {
          return false;
        }
      } on FileSystemException {
        return false;
      }
    }
    return true;
  }

  /// Applies one or more file changes through a crash-safe WAL journal.
  ///
  /// Refuses fail-closed before touching disk or writing any journal bytes if:
  /// - any path is Hard-Deny, secret, outside `workspaceRoots` (when required),
  /// - any TOCTOU guard (`expectedPreSha256` / `expectNotExists`) fails,
  /// - any file exceeds [maxPerFileBytes] or total backup exceeds [maxTotalBytes].
  ///
  /// If any file write fails mid-apply (including Windows file lock errors `5`
  /// or `32`), automatically rolls back all earlier files in reverse order
  /// (skipping untouched files whose live SHA-256 still equals `preSha256`).
  Future<FsTransactionResult> applyTransaction({
    required String toolName,
    required List<FsPlannedChange> changes,
    required ShellControlPolicy? shellControl,
    String? homeDirectory,
    DateTime? nowUtc,
    bool requireInsideWorkspaceRoots = true,
  }) async {
    if (changes.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'empty_transaction',
      );
    }

    final now = (nowUtc ?? DateTime.now()).toUtc();
    final seenPaths = <String>{};
    final prepared = <_PreparedEntry>[];
    var totalBackupBytes = 0;

    // Phase 1: Validate every target path and TOCTOU invariant before writing
    // a single byte to the journal or workspace.
    for (var i = 0; i < changes.length; i++) {
      final change = changes[i];
      final normalized = normalizeHostPath(
        change.path,
        homeDirectory: homeDirectory,
        windows: _isWindows,
      );
      if (normalized == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'path_not_absolute',
        );
      }
      final dedupeKey = _caseInsensitive
          ? normalized.toLowerCase()
          : normalized;
      if (!seenPaths.add(dedupeKey)) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'duplicate_target_path',
        );
      }

      final resolved = _resolveRealPath(normalized);
      if (hardDeniedPathReason(normalized) != null ||
          (resolved != null && hardDeniedPathReason(resolved) != null)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_path_forbidden',
        );
      }
      if (isSecretFileName(normalized) ||
          (resolved != null && isSecretFileName(resolved))) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_secret_file_forbidden',
        );
      }
      if (requireInsideWorkspaceRoots) {
        if (shellControl == null ||
            !_isStrictlyInsideWorkspace(
              normalized,
              resolved,
              shellControl,
              homeDirectory: homeDirectory,
            )) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'fs_outside_workspace',
          );
        }
      }

      if (FileSystemEntity.isDirectorySync(normalized)) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'fs_not_a_file',
        );
      }

      final target = File(normalized);
      final existed = target.existsSync();
      if (change.expectNotExists && existed) {
        throw XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: change.expectNotExistsErrorCode,
        );
      }
      if (change.newBytes == null && !existed) {
        throw XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: change.expectedPreSha256 != null
              ? 'toctou_mismatch'
              : 'fs_not_found',
        );
      }

      List<int>? originalBytes;
      String? preSha;
      int? mode;
      if (existed) {
        final len = target.lengthSync();
        if (len > maxPerFileBytes) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'fs_undo_file_too_large',
          );
        }
        originalBytes = target.readAsBytesSync();
        preSha = sha256.convert(originalBytes).toString();
        if (!_isWindows) {
          mode = target.statSync().mode;
        }
        if (change.expectedPreSha256 != null &&
            preSha != change.expectedPreSha256) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'toctou_mismatch',
          );
        }
        totalBackupBytes += originalBytes.length;
      } else if (change.expectedPreSha256 != null) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'toctou_mismatch',
        );
      }

      final newBytes = change.newBytes;
      String? postSha;
      final FsChangeOp op;
      if (newBytes == null) {
        op = FsChangeOp.delete;
      } else {
        if (newBytes.length > maxPerFileBytes) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'fs_undo_file_too_large',
          );
        }
        if (!target.parent.existsSync() && !change.createParents) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'fs_parent_missing',
          );
        }
        op = existed ? FsChangeOp.modify : FsChangeOp.create;
        postSha = sha256.convert(newBytes).toString();
      }

      prepared.add(
        _PreparedEntry(
          change: change,
          normalizedPath: normalized,
          op: op,
          existed: existed,
          originalBytes: originalBytes,
          preSha256: preSha,
          postSha256: postSha,
          backupFile: existed ? 'bak_$i.bin' : null,
          mode: mode,
        ),
      );
    }

    if (totalBackupBytes > maxTotalBytes) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'fs_undo_budget_exceeded',
      );
    }

    // Phase 2: Ensure undo store exists, prune expired entries, and make room.
    await _ensureRootDir();
    _pruneExpiredAndEnforceBudget(
      nowUtc: now,
      reserveBytes: totalBackupBytes,
      reserveSlots: 1,
    );

    final txId = _nextTxId(now);
    final txDir = Directory('${rootDir.path}${Platform.pathSeparator}$txId');
    await txDir.create(recursive: true);

    final recordEntries = prepared
        .map(
          (p) => FsJournalFileEntry(
            path: p.normalizedPath,
            op: p.op,
            existed: p.existed,
            preSha256: p.preSha256,
            postSha256: p.postSha256,
            backupFile: p.backupFile,
            backupBytes: p.originalBytes?.length ?? 0,
            mode: p.mode,
          ),
        )
        .toList(growable: false);

    var record = FsJournalRecord(
      schemaVersion: 1,
      txId: txId,
      toolName: toolName,
      state: FsJournalState.preparing,
      createdAt: now,
      expiresAt: now.add(ttl),
      totalBackupBytes: totalBackupBytes,
      entries: recordEntries,
    );

    // Phase 3: Persist backups and WAL (`preparing` → `applying`).
    try {
      for (final p in prepared) {
        if (p.existed && p.backupFile != null && p.originalBytes != null) {
          final bak = File(
            '${txDir.path}${Platform.pathSeparator}${p.backupFile}',
          );
          await bak.writeAsBytes(p.originalBytes!, flush: true);
        }
      }
      await _writeJournalRecord(txDir, record);
      record = record.withState(FsJournalState.applying);
      await _writeJournalRecord(txDir, record);
    } on Object {
      _tryDeleteDirectory(txDir);
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'fs_journal_write_failed',
      );
    }

    // Phase 4: Apply each file atomically; rollback cleanly on any failure.
    final applied = <FsAppliedFileResult>[];
    try {
      for (final p in prepared) {
        if (p.op == FsChangeOp.delete) {
          final target = File(p.normalizedPath);
          if (target.existsSync()) {
            target.deleteSync();
          }
          applied.add(
            FsAppliedFileResult(
              normalizedPath: p.normalizedPath,
              bytesWritten: 0,
              created: false,
              sha256Hex: null,
            ),
          );
        } else {
          final result = await writeTempAndReplaceFile(
            targetPath: p.normalizedPath,
            bytes: p.change.newBytes!,
            createParents: p.change.createParents,
            preserveMode: p.mode,
            replaceFile: _replaceFile,
          );
          applied.add(
            FsAppliedFileResult(
              normalizedPath: p.normalizedPath,
              bytesWritten: result.bytes,
              created: result.created,
              sha256Hex: result.sha256Hex,
            ),
          );
        }
      }
    } on Object catch (applyError) {
      final rollbackOk = await _rollbackApplyingRecord(record, txDir);
      if (rollbackOk) {
        try {
          await _writeJournalRecord(
            txDir,
            record.withState(FsJournalState.rolledBack),
          );
        } on Object {
          // Best-effort state transition before directory deletion.
        }
        _tryDeleteDirectory(txDir);
        logger?.warning('fs_undo.apply_rolled_back', <String, Object?>{
          'tool': toolName,
          'errorCode': _errorCodeForApplyError(applyError),
        });
      } else {
        // Leave `applying` journal on disk so next startup can retry recovery
        // (Rule H1: never discard unrecovered rollback state).
        logger?.error('fs_undo.rollback_failed', <String, Object?>{
          'tool': toolName,
          'errorCode': _errorCodeForApplyError(applyError),
        });
      }
      if (applyError is XunaHostChannelException) rethrow;
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: _errorCodeForApplyError(applyError),
      );
    }

    // Phase 5: Commit WAL and enforce total budget.
    record = record.withState(FsJournalState.committed);
    try {
      await _writeJournalRecord(txDir, record);
    } on Object {
      // The workspace mutation already succeeded on disk; fail closed on the
      // undo record by removing the uncommitted journal so we do not falsely
      // roll back a completed write on next boot.
      _tryDeleteDirectory(txDir);
      logger?.warning('fs_undo.commit_record_failed', <String, Object?>{
        'tool': toolName,
      });
      return FsTransactionResult(txId: txId, files: applied);
    }

    _pruneExpiredAndEnforceBudget(nowUtc: now, protectTxId: txId);
    logger?.info('fs_undo.committed', <String, Object?>{
      'tool': toolName,
      'status': 'ok',
    });
    return FsTransactionResult(txId: txId, files: applied);
  }

  /// Runs crash recovery for any journal left in `applying` state and prunes
  /// expired/corrupt/over-budget journals on agent startup (`ADR-0019` §1).
  Future<FsUndoStartupReport> recoverAndPruneOnStartup({
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    if (!rootDir.existsSync()) {
      return const FsUndoStartupReport(
        recoveredCount: 0,
        failedRecoveryCount: 0,
        prunedCount: 0,
        activeCommittedCount: 0,
      );
    }

    var recovered = 0;
    var failedRecovery = 0;
    var pruned = 0;
    final committed = <_StoredTx>[];

    for (final txDir in _listTxDirectories()) {
      final record = _readJournalRecord(txDir);
      if (record == null) {
        _tryDeleteDirectory(txDir);
        pruned++;
        continue;
      }
      switch (record.state) {
        case FsJournalState.preparing:
        case FsJournalState.rolledBack:
          _tryDeleteDirectory(txDir);
          pruned++;
        case FsJournalState.applying:
          final ok = await _rollbackApplyingRecord(record, txDir);
          if (ok) {
            _tryDeleteDirectory(txDir);
            recovered++;
            logger?.warning('fs_undo.crash_recovered', <String, Object?>{
              'tool': record.toolName,
              'status': 'ok',
            });
          } else {
            failedRecovery++;
            logger?.error('fs_undo.crash_recovery_failed', <String, Object?>{
              'tool': record.toolName,
              'errorCode': 'fs_recovery_failed',
            });
          }
        case FsJournalState.committed:
          if (now.isAfter(record.expiresAt)) {
            _tryDeleteDirectory(txDir);
            pruned++;
          } else {
            committed.add(_StoredTx(dir: txDir, record: record));
          }
      }
    }

    pruned += _evictOverBudget(committed);
    if (recovered > 0 || pruned > 0) {
      logger?.info('fs_undo.startup_sweep', <String, Object?>{'status': 'ok'});
    }
    return FsUndoStartupReport(
      recoveredCount: recovered,
      failedRecoveryCount: failedRecovery,
      prunedCount: pruned,
      activeCommittedCount: committed.length,
    );
  }

  /// Returns content-free metadata for the most recent unexpired committed
  /// transaction, or `null` if none exists.
  FsUndoJournalEntrySummary? peekLatestCommitted(DateTime nowUtc) {
    final now = nowUtc.toUtc();
    if (!rootDir.existsSync()) return null;
    final committed = _loadValidCommitted(now);
    if (committed.isEmpty) return null;
    final latest = committed.last.record;
    return FsUndoJournalEntrySummary(
      txId: latest.txId,
      toolName: latest.toolName,
      createdAt: latest.createdAt,
      expiresAt: latest.expiresAt,
      fileCount: latest.entries.length,
    );
  }

  /// Lists all unexpired committed transactions ordered oldest → newest
  /// (content-free summaries only).
  List<FsUndoJournalEntrySummary> listCommitted(DateTime nowUtc) {
    if (!rootDir.existsSync()) return const <FsUndoJournalEntrySummary>[];
    return _loadValidCommitted(nowUtc.toUtc())
        .map(
          (tx) => FsUndoJournalEntrySummary(
            txId: tx.record.txId,
            toolName: tx.record.toolName,
            createdAt: tx.record.createdAt,
            expiresAt: tx.record.expiresAt,
            fileCount: tx.record.entries.length,
          ),
        )
        .toList(growable: false);
  }

  /// Reverts a committed transaction (`txId`, or the most recent committed
  /// transaction when omitted).
  ///
  /// Fail-closed invariants (`ADR-0019` §1, M1-2 Option A):
  /// - Re-verifies every path against Hard-Deny, secret filenames, and
  ///   `workspaceRoots` before touching disk.
  /// - Verifies every file's live SHA-256 still matches `postSha256` (and
  ///   deleted files are still absent). Any external edit refuses the entire
  ///   undo with `undo_conflict_modified_externally` and `0` files modified.
  Future<FsUndoResult> undoTransaction({
    String? txId,
    required ShellControlPolicy? shellControl,
    String? homeDirectory,
    DateTime? nowUtc,
  }) async {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    if (!rootDir.existsSync()) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'nothing_to_undo',
      );
    }
    final committed = _loadValidCommitted(now);
    if (committed.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'nothing_to_undo',
      );
    }
    final _StoredTx targetTx;
    if (txId == null) {
      targetTx = committed.last;
    } else {
      final matches = committed.where((t) => t.record.txId == txId);
      if (matches.isEmpty) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'nothing_to_undo',
        );
      }
      targetTx = matches.first;
    }

    final record = targetTx.record;
    final txDir = targetTx.dir;

    // Pass 1: Read-only security + backup integrity + M1-2 external-edit check.
    final verifiedBackups = <int, List<int>>{};
    for (var i = 0; i < record.entries.length; i++) {
      final entry = record.entries[i];
      final normalized = normalizeHostPath(
        entry.path,
        homeDirectory: homeDirectory,
        windows: _isWindows,
      );
      if (normalized == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_path_forbidden',
        );
      }
      final resolved = _resolveRealPath(normalized);
      if (hardDeniedPathReason(normalized) != null ||
          (resolved != null && hardDeniedPathReason(resolved) != null)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_path_forbidden',
        );
      }
      if (isSecretFileName(normalized) ||
          (resolved != null && isSecretFileName(resolved))) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_secret_file_forbidden',
        );
      }
      if (shellControl == null ||
          !_isStrictlyInsideWorkspace(
            normalized,
            resolved,
            shellControl,
            homeDirectory: homeDirectory,
          )) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'fs_outside_workspace',
        );
      }

      final liveFile = File(normalized);
      switch (entry.op) {
        case FsChangeOp.create:
        case FsChangeOp.modify:
          if (!liveFile.existsSync()) {
            throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'undo_conflict_modified_externally',
            );
          }
          final liveBytes = liveFile.readAsBytesSync();
          final liveSha = sha256.convert(liveBytes).toString();
          if (entry.postSha256 == null || liveSha != entry.postSha256) {
            throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'undo_conflict_modified_externally',
            );
          }
        case FsChangeOp.delete:
          if (liveFile.existsSync()) {
            throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'undo_conflict_modified_externally',
            );
          }
      }

      if (entry.existed) {
        final bakName = entry.backupFile;
        if (bakName == null) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'undo_backup_corrupted',
          );
        }
        final bakFile = File('${txDir.path}${Platform.pathSeparator}$bakName');
        if (!bakFile.existsSync()) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'undo_backup_corrupted',
          );
        }
        final bakBytes = bakFile.readAsBytesSync();
        final bakSha = sha256.convert(bakBytes).toString();
        if (bakSha != entry.preSha256) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'undo_backup_corrupted',
          );
        }
        verifiedBackups[i] = bakBytes;
      }
    }

    // Pass 2: Restore in reverse order.
    var filesRestored = 0;
    var filesDeleted = 0;
    try {
      for (var i = record.entries.length - 1; i >= 0; i--) {
        final entry = record.entries[i];
        if (entry.existed) {
          await writeTempAndReplaceFile(
            targetPath: entry.path,
            bytes: verifiedBackups[i]!,
            createParents: true,
            preserveMode: entry.mode,
            replaceFile: _replaceFile,
          );
          filesRestored++;
        } else {
          final liveFile = File(entry.path);
          if (liveFile.existsSync()) {
            liveFile.deleteSync();
          }
          filesDeleted++;
        }
      }
    } on Object catch (err) {
      logger?.warning('fs_undo.revert_failed', <String, Object?>{
        'tool': record.toolName,
        'errorCode': _errorCodeForApplyError(err),
      });
      if (err is XunaHostChannelException) rethrow;
      throw XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: _errorCodeForApplyError(err),
      );
    }

    try {
      await _writeJournalRecord(
        txDir,
        record.withState(FsJournalState.rolledBack),
      );
    } on Object {
      // Best-effort marker before deletion.
    }
    _tryDeleteDirectory(txDir);

    logger?.info('fs_undo.reverted', <String, Object?>{
      'tool': record.toolName,
      'status': 'ok',
    });
    return FsUndoResult(
      txId: record.txId,
      toolName: record.toolName,
      filesRestored: filesRestored,
      filesDeleted: filesDeleted,
    );
  }

  /// Rolls back an `applying` transaction (mid-apply failure or startup crash
  /// recovery). Follows the Spike (c) C4 invariant: skips any existing file
  /// whose live SHA-256 already equals `preSha256`, avoiding Win32 error `5`/`32`
  /// failures on untouched locked files.
  Future<bool> _rollbackApplyingRecord(
    FsJournalRecord record,
    Directory txDir,
  ) async {
    var allSucceeded = true;
    for (var i = record.entries.length - 1; i >= 0; i--) {
      final entry = record.entries[i];
      try {
        final resolved = _resolveRealPath(entry.path);
        if (_isForbiddenOrSecret(entry.path, resolved)) {
          allSucceeded = false;
          continue;
        }
        _cleanMatchingTempFiles(entry.path);
        final target = File(entry.path);
        if (entry.existed) {
          if (target.existsSync()) {
            final liveSha = sha256.convert(target.readAsBytesSync()).toString();
            if (liveSha == entry.preSha256) {
              // Untouched file (may be read-locked on Windows): do not touch.
              continue;
            }
          }
          final bakName = entry.backupFile;
          if (bakName == null) {
            allSucceeded = false;
            continue;
          }
          final bakFile = File(
            '${txDir.path}${Platform.pathSeparator}$bakName',
          );
          if (!bakFile.existsSync()) {
            allSucceeded = false;
            continue;
          }
          final bakBytes = bakFile.readAsBytesSync();
          if (sha256.convert(bakBytes).toString() != entry.preSha256) {
            allSucceeded = false;
            continue;
          }
          await writeTempAndReplaceFile(
            targetPath: entry.path,
            bytes: bakBytes,
            createParents: true,
            preserveMode: entry.mode,
            replaceFile: _replaceFile,
          );
        } else {
          if (target.existsSync()) {
            target.deleteSync();
          }
        }
      } on Object {
        allSucceeded = false;
      }
    }
    return allSucceeded;
  }

  bool _isForbiddenOrSecret(String normalized, String? resolved) {
    if (hardDeniedPathReason(normalized) != null) return true;
    if (resolved != null && hardDeniedPathReason(resolved) != null) return true;
    if (isSecretFileName(normalized)) return true;
    if (resolved != null && isSecretFileName(resolved)) return true;
    return false;
  }

  bool _isStrictlyInsideWorkspace(
    String normalized,
    String? resolved,
    ShellControlPolicy shellControl, {
    String? homeDirectory,
  }) {
    final insideNorm = isInsideWorkspaceRoots(
      normalized,
      shellControl,
      homeDirectory: homeDirectory,
      windows: _isWindows,
      caseInsensitive: _caseInsensitive,
      realPath: _resolveRealPath,
    );
    if (!insideNorm) return false;
    if (resolved != null && resolved != normalized) {
      return isInsideWorkspaceRoots(
        resolved,
        shellControl,
        homeDirectory: homeDirectory,
        windows: _isWindows,
        caseInsensitive: _caseInsensitive,
        realPath: _resolveRealPath,
      );
    }
    return true;
  }

  Future<void> _ensureRootDir() async {
    if (!rootDir.existsSync()) {
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

  String _nextTxId(DateTime nowUtc) {
    final seq = (_txSequence++).toString().padLeft(6, '0');
    final rand = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    return 'tx-${nowUtc.millisecondsSinceEpoch}-$seq-$rand';
  }

  Future<void> _writeJournalRecord(
    Directory txDir,
    FsJournalRecord record,
  ) async {
    final journalPath = '${txDir.path}${Platform.pathSeparator}journal.json';
    final bytes = utf8.encode(jsonEncode(record.toJson()));
    await writeTempAndReplaceFile(
      targetPath: journalPath,
      bytes: bytes,
      createParents: false,
      replaceFile: _replaceFile,
    );
  }

  List<Directory> _listTxDirectories() {
    if (!rootDir.existsSync()) return const <Directory>[];
    final dirs = <Directory>[];
    try {
      for (final entity in rootDir.listSync(followLinks: false)) {
        if (entity is Directory && _basename(entity.path).startsWith('tx-')) {
          dirs.add(entity);
        }
      }
    } on FileSystemException {
      return const <Directory>[];
    }
    dirs.sort((a, b) => _basename(a.path).compareTo(_basename(b.path)));
    return dirs;
  }

  FsJournalRecord? _readJournalRecord(Directory txDir) {
    final file = File('${txDir.path}${Platform.pathSeparator}journal.json');
    if (!file.existsSync()) return null;
    try {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return null;
      return FsJournalRecord.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
    } on Object {
      return null;
    }
  }

  List<_StoredTx> _loadValidCommitted(DateTime nowUtc) {
    final committed = <_StoredTx>[];
    for (final txDir in _listTxDirectories()) {
      final record = _readJournalRecord(txDir);
      if (record == null) continue;
      if (record.state != FsJournalState.committed) continue;
      if (nowUtc.isAfter(record.expiresAt)) {
        _tryDeleteDirectory(txDir);
        continue;
      }
      committed.add(_StoredTx(dir: txDir, record: record));
    }
    committed.sort(_compareTxAsc);
    return committed;
  }

  void _pruneExpiredAndEnforceBudget({
    required DateTime nowUtc,
    int reserveBytes = 0,
    int reserveSlots = 0,
    String? protectTxId,
  }) {
    if (!rootDir.existsSync()) return;
    final committed = <_StoredTx>[];
    for (final txDir in _listTxDirectories()) {
      final record = _readJournalRecord(txDir);
      if (record == null) {
        _tryDeleteDirectory(txDir);
        continue;
      }
      if (record.state == FsJournalState.rolledBack) {
        _tryDeleteDirectory(txDir);
        continue;
      }
      if (record.state == FsJournalState.committed) {
        if (nowUtc.isAfter(record.expiresAt)) {
          _tryDeleteDirectory(txDir);
        } else {
          committed.add(_StoredTx(dir: txDir, record: record));
        }
      }
    }
    _evictOverBudget(
      committed,
      reserveBytes: reserveBytes,
      reserveSlots: reserveSlots,
      protectTxId: protectTxId,
    );
  }

  int _evictOverBudget(
    List<_StoredTx> committed, {
    int reserveBytes = 0,
    int reserveSlots = 0,
    String? protectTxId,
  }) {
    committed.sort(_compareTxAsc);
    var totalBytes = committed.fold<int>(
      0,
      (sum, tx) => sum + tx.record.totalBackupBytes,
    );
    var evicted = 0;
    var idx = 0;
    while (idx < committed.length &&
        (committed.length + reserveSlots > maxTransactions ||
            totalBytes + reserveBytes > maxTotalBytes)) {
      final candidate = committed[idx];
      if (protectTxId != null && candidate.record.txId == protectTxId) {
        idx++;
        continue;
      }
      _tryDeleteDirectory(candidate.dir);
      totalBytes -= candidate.record.totalBackupBytes;
      committed.removeAt(idx);
      evicted++;
    }
    return evicted;
  }

  void _cleanMatchingTempFiles(String targetPath) {
    final parent = File(targetPath).parent;
    if (!parent.existsSync()) return;
    final prefix = '.${_basename(targetPath)}.xuna-';
    try {
      for (final entity in parent.listSync(followLinks: false)) {
        if (entity is File) {
          final name = _basename(entity.path);
          if (name.startsWith(prefix) && name.endsWith('.tmp')) {
            _tryDeleteFile(entity);
          }
        }
      }
    } on FileSystemException {
      // Best-effort temp cleanup.
    }
  }

  static int _compareTxAsc(_StoredTx a, _StoredTx b) {
    final byTime = a.record.createdAt.compareTo(b.record.createdAt);
    if (byTime != 0) return byTime;
    return a.record.txId.compareTo(b.record.txId);
  }

  static String _errorCodeForApplyError(Object error) {
    if (error is XunaHostChannelException) return error.errorCode;
    if (error is AtomicReplaceException && error.isLocked) {
      return 'fs_file_locked';
    }
    return 'fs_write_failed';
  }
}

class _PreparedEntry {
  const _PreparedEntry({
    required this.change,
    required this.normalizedPath,
    required this.op,
    required this.existed,
    required this.originalBytes,
    required this.preSha256,
    required this.postSha256,
    required this.backupFile,
    required this.mode,
  });

  final FsPlannedChange change;
  final String normalizedPath;
  final FsChangeOp op;
  final bool existed;
  final List<int>? originalBytes;
  final String? preSha256;
  final String? postSha256;
  final String? backupFile;
  final int? mode;
}

class _StoredTx {
  const _StoredTx({required this.dir, required this.record});

  final Directory dir;
  final FsJournalRecord record;
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final idx = normalized.lastIndexOf('/');
  return idx >= 0 ? normalized.substring(idx + 1) : normalized;
}

void _tryDeleteFile(File file) {
  try {
    if (file.existsSync()) file.deleteSync();
  } on FileSystemException {
    // Best-effort cleanup.
  }
}

void _tryDeleteDirectory(Directory dir) {
  try {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Best-effort cleanup.
  }
}

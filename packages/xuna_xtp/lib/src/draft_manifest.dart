import 'dart:convert';

import 'canonical_json.dart';
import 'policy/fs_path_guard.dart' show hardDeniedPathReason, isSecretFileName;
import 'policy/security_redaction.dart' show hasBinaryOrInvalidSurrogates;

/// Pattern for draft workspace identifiers (`ADR-0019` §3 / `W4-M3`).
final RegExp draftIdPattern = RegExp(r'^draft_[a-zA-Z0-9_-]{1,48}$');

final RegExp _sha256LowerHexPattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _workspaceAliasPattern = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');
final RegExp _singleLineControlPattern = RegExp(r'[\u0000-\u001F\u007F]');
final RegExp _windowsDrivePattern = RegExp(r'^[A-Za-z]:');

/// Operation kind for one file entry in an [EffectManifest] (`ADR-0019` §3).
enum EffectChangeOp {
  create('create'),
  modify('modify'),
  delete('delete');

  const EffectChangeOp(this.wire);
  final String wire;

  static EffectChangeOp fromWire(String raw) {
    for (final value in values) {
      if (value.wire == raw) return value;
    }
    throw FormatException('Unknown EffectChangeOp: $raw');
  }
}

/// One workspace-relative file change recorded in an [EffectManifest].
///
/// Field conventions (`sizeBytes`, `sha256`, `magicOk`) align with P1.1
/// `exec.run` `artifacts`.
class EffectManifestChange {
  EffectManifestChange({
    required String relPath,
    required this.op,
    this.preSha256,
    this.postSha256,
    this.sizeBytes,
    this.magicOk,
  }) : relPath = validateEffectRelPath(relPath) {
    if (preSha256 != null && !_sha256LowerHexPattern.hasMatch(preSha256!)) {
      throw const FormatException('Invalid preSha256 in EffectManifestChange');
    }
    if (postSha256 != null && !_sha256LowerHexPattern.hasMatch(postSha256!)) {
      throw const FormatException('Invalid postSha256 in EffectManifestChange');
    }
    if (sizeBytes != null && sizeBytes! < 0) {
      throw const FormatException('sizeBytes must be >= 0');
    }
    switch (op) {
      case EffectChangeOp.create:
        if (preSha256 != null) {
          throw const FormatException('create change must not carry preSha256');
        }
        if (postSha256 == null || sizeBytes == null) {
          throw const FormatException(
            'create change requires postSha256 and sizeBytes',
          );
        }
      case EffectChangeOp.modify:
        if (preSha256 == null || postSha256 == null || sizeBytes == null) {
          throw const FormatException(
            'modify change requires preSha256, postSha256, and sizeBytes',
          );
        }
      case EffectChangeOp.delete:
        if (preSha256 == null) {
          throw const FormatException('delete change requires preSha256');
        }
        if (postSha256 != null || sizeBytes != null || magicOk != null) {
          throw const FormatException(
            'delete change must not carry postSha256, sizeBytes, or magicOk',
          );
        }
    }
  }

  factory EffectManifestChange.fromJson(Map<String, Object?> json) {
    const allowed = <String>{
      'relPath',
      'op',
      'preSha256',
      'postSha256',
      'sizeBytes',
      'magicOk',
    };
    for (final key in json.keys) {
      if (!allowed.contains(key)) {
        throw FormatException('Unexpected key "$key" in EffectManifestChange');
      }
    }
    final relPath = json['relPath'];
    final opRaw = json['op'];
    final preSha = json['preSha256'];
    final postSha = json['postSha256'];
    final sizeBytes = json['sizeBytes'];
    final magicOk = json['magicOk'];
    if (relPath is! String || opRaw is! String) {
      throw const FormatException(
        'EffectManifestChange requires relPath and op',
      );
    }
    if (preSha != null && preSha is! String) {
      throw const FormatException('preSha256 must be a string');
    }
    if (postSha != null && postSha is! String) {
      throw const FormatException('postSha256 must be a string');
    }
    if (sizeBytes != null && sizeBytes is! int) {
      throw const FormatException('sizeBytes must be an int');
    }
    if (magicOk != null && magicOk is! bool) {
      throw const FormatException('magicOk must be a bool');
    }
    return EffectManifestChange(
      relPath: relPath,
      op: EffectChangeOp.fromWire(opRaw),
      preSha256: preSha as String?,
      postSha256: postSha as String?,
      sizeBytes: sizeBytes as int?,
      magicOk: magicOk as bool?,
    );
  }

  static const int maxRelPathChars = 260;

  final String relPath;
  final EffectChangeOp op;
  final String? preSha256;
  final String? postSha256;
  final int? sizeBytes;
  final bool? magicOk;

  Map<String, Object?> toJson() => <String, Object?>{
        'relPath': relPath,
        'op': op.wire,
        if (preSha256 != null) 'preSha256': preSha256,
        if (postSha256 != null) 'postSha256': postSha256,
        if (sizeBytes != null) 'sizeBytes': sizeBytes,
        if (magicOk != null) 'magicOk': magicOk,
      };

  static String validateEffectRelPath(String raw) {
    if (raw.isEmpty ||
        raw.length > maxRelPathChars ||
        raw.trim() != raw ||
        _singleLineControlPattern.hasMatch(raw) ||
        hasBinaryOrInvalidSurrogates(raw)) {
      throw const FormatException('Invalid EffectManifestChange relPath');
    }
    if (raw.startsWith('/') ||
        raw.startsWith(r'\') ||
        raw.startsWith('~') ||
        _windowsDrivePattern.hasMatch(raw)) {
      throw const FormatException(
        'EffectManifestChange relPath must be workspace-relative',
      );
    }
    final normalized = raw.replaceAll(r'\', '/');
    final segments = normalized.split('/');
    if (segments.any((s) => s.isEmpty || s == '.' || s == '..')) {
      throw const FormatException(
        'EffectManifestChange relPath must not contain empty, . or .. segments',
      );
    }
    if (hardDeniedPathReason(normalized) != null ||
        isSecretFileName(normalized)) {
      throw const FormatException(
        'EffectManifestChange relPath must not reference secret or Hard-Deny paths',
      );
    }
    return normalized;
  }
}

/// Summary of `R2` `exec.run` verification commands executed inside a draft
/// workspace (`ADR-0019` §3).
class EffectManifestChecks {
  EffectManifestChecks({
    required this.commandCount,
    required this.allCompleted,
    required this.failedCount,
  }) {
    if (commandCount < 0 || failedCount < 0 || failedCount > commandCount) {
      throw const FormatException('Invalid EffectManifestChecks counts');
    }
    if (allCompleted && failedCount > 0) {
      throw const FormatException(
        'allCompleted cannot be true when failedCount > 0',
      );
    }
  }

  factory EffectManifestChecks.fromJson(Map<String, Object?> json) {
    const required = <String>{'commandCount', 'allCompleted', 'failedCount'};
    if (json.length != required.length ||
        !required.every((k) => json.containsKey(k))) {
      throw const FormatException('Invalid EffectManifestChecks keys');
    }
    final commandCount = json['commandCount'];
    final allCompleted = json['allCompleted'];
    final failedCount = json['failedCount'];
    if (commandCount is! int || allCompleted is! bool || failedCount is! int) {
      throw const FormatException('Invalid EffectManifestChecks field types');
    }
    return EffectManifestChecks(
      commandCount: commandCount,
      allCompleted: allCompleted,
      failedCount: failedCount,
    );
  }

  final int commandCount;
  final bool allCompleted;
  final int failedCount;

  Map<String, Object?> toJson() => <String, Object?>{
        'commandCount': commandCount,
        'allCompleted': allCompleted,
        'failedCount': failedCount,
      };
}

/// Canonical manifest of workspace file changes produced by a `DraftWorkspace`
/// session (`ADR-0019` §3 / `W4-M3`, bound by `xuna.approval.v2` in `W4-M4`).
///
/// Honest boundaries (Rule H6):
/// - `scope` is always `"workspace_files_only"`.
/// - `networkIsolated` is always `false` (no OS-level socket isolation claimed).
/// - Zero raw host filesystem paths are carried (`workspaceAlias` + relative paths only).
class EffectManifest {
  EffectManifest({
    this.schemaVersion = 1,
    required this.draftId,
    required this.workspaceAlias,
    this.scope = workspaceFilesOnlyScope,
    this.networkIsolated = false,
    required List<EffectManifestChange> changes,
    this.checks,
    required this.createdAt,
    required this.expiresAt,
  }) : changes = List<EffectManifestChange>.unmodifiable(
          _validateAndSortChanges(changes),
        ) {
    if (schemaVersion != 1) {
      throw FormatException(
        'Unsupported EffectManifest schemaVersion: $schemaVersion',
      );
    }
    if (!draftIdPattern.hasMatch(draftId)) {
      throw FormatException('Invalid EffectManifest draftId: $draftId');
    }
    if (!_workspaceAliasPattern.hasMatch(workspaceAlias) ||
        workspaceAlias == '.' ||
        workspaceAlias == '..' ||
        workspaceAlias.contains('..')) {
      throw FormatException(
        'Invalid EffectManifest workspaceAlias: $workspaceAlias',
      );
    }
    if (scope != workspaceFilesOnlyScope) {
      throw FormatException('Unsupported EffectManifest scope: $scope');
    }
    if (networkIsolated) {
      throw const FormatException(
        'EffectManifest networkIsolated must be false (ADR-0019 Rule H6)',
      );
    }
    if (DateTime.tryParse(createdAt) == null ||
        DateTime.tryParse(expiresAt) == null) {
      throw const FormatException(
        'EffectManifest createdAt and expiresAt must be ISO-8601 timestamps',
      );
    }
  }

  factory EffectManifest.fromJson(Map<String, Object?> json) {
    const required = <String>{
      'schemaVersion',
      'draftId',
      'workspaceAlias',
      'scope',
      'networkIsolated',
      'changes',
      'createdAt',
      'expiresAt',
    };
    const optional = <String>{'checks'};
    for (final req in required) {
      if (!json.containsKey(req)) {
        throw FormatException('Missing required key "$req" in EffectManifest');
      }
    }
    for (final key in json.keys) {
      if (!required.contains(key) && !optional.contains(key)) {
        throw FormatException('Unexpected key "$key" in EffectManifest');
      }
    }
    final schemaVersion = json['schemaVersion'];
    final draftId = json['draftId'];
    final workspaceAlias = json['workspaceAlias'];
    final scope = json['scope'];
    final networkIsolated = json['networkIsolated'];
    final rawChanges = json['changes'];
    final createdAt = json['createdAt'];
    final expiresAt = json['expiresAt'];
    if (schemaVersion is! int ||
        draftId is! String ||
        workspaceAlias is! String ||
        scope is! String ||
        networkIsolated is! bool ||
        rawChanges is! List ||
        createdAt is! String ||
        expiresAt is! String) {
      throw const FormatException('Invalid EffectManifest field types');
    }
    final parsedChanges = <EffectManifestChange>[];
    for (final item in rawChanges) {
      if (item is! Map) {
        throw const FormatException('EffectManifest changes must be objects');
      }
      parsedChanges.add(
        EffectManifestChange.fromJson(
          item.map((k, v) => MapEntry(k.toString(), v)),
        ),
      );
    }
    EffectManifestChecks? checks;
    if (json.containsKey('checks') && json['checks'] != null) {
      final rawChecks = json['checks'];
      if (rawChecks is! Map) {
        throw const FormatException('EffectManifest checks must be an object');
      }
      checks = EffectManifestChecks.fromJson(
        rawChecks.map((k, v) => MapEntry(k.toString(), v)),
      );
    }
    return EffectManifest(
      schemaVersion: schemaVersion,
      draftId: draftId,
      workspaceAlias: workspaceAlias,
      scope: scope,
      networkIsolated: networkIsolated,
      changes: parsedChanges,
      checks: checks,
      createdAt: createdAt,
      expiresAt: expiresAt,
    );
  }

  static const String workspaceFilesOnlyScope = 'workspace_files_only';
  static const int maxChanges = 2000;

  final int schemaVersion;
  final String draftId;
  final String workspaceAlias;
  final String scope;
  final bool networkIsolated;
  final List<EffectManifestChange> changes;
  final EffectManifestChecks? checks;
  final String createdAt;
  final String expiresAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'draftId': draftId,
        'workspaceAlias': workspaceAlias,
        'scope': scope,
        'networkIsolated': networkIsolated,
        'changes': changes.map((c) => c.toJson()).toList(growable: false),
        if (checks != null) 'checks': checks!.toJson(),
        'createdAt': createdAt,
        'expiresAt': expiresAt,
      };

  /// Computes `sha256(canonical_json(this))` using XTP RFC 8785 JCS rules.
  String computeEffectSha256() => argsSha256(toJson());

  String encodeCanonicalJson() => canonicalJson(toJson());

  int get createdCount =>
      changes.where((c) => c.op == EffectChangeOp.create).length;

  int get modifiedCount =>
      changes.where((c) => c.op == EffectChangeOp.modify).length;

  int get deletedCount =>
      changes.where((c) => c.op == EffectChangeOp.delete).length;

  static List<EffectManifestChange> _validateAndSortChanges(
    List<EffectManifestChange> raw,
  ) {
    if (raw.length > maxChanges) {
      throw const FormatException(
        'EffectManifest changes exceeds 2000 entries',
      );
    }
    final sorted = List<EffectManifestChange>.from(raw)
      ..sort((a, b) => a.relPath.compareTo(b.relPath));
    final seen = <String>{};
    for (final change in sorted) {
      final key = change.relPath.toLowerCase();
      if (!seen.add(key)) {
        throw FormatException(
          'Duplicate change relPath in EffectManifest: ${change.relPath}',
        );
      }
    }
    return sorted;
  }

  /// Parses an [EffectManifest] from a UTF-8 JSON string.
  static EffectManifest parseJsonString(String rawJson) {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map) {
      throw const FormatException('EffectManifest JSON must be an object');
    }
    return EffectManifest.fromJson(
      decoded.map((k, v) => MapEntry(k.toString(), v)),
    );
  }
}

/// Computes `sha256(canonical_json(manifest))` (`ADR-0019` §3).
String computeEffectSha256(EffectManifest manifest) =>
    manifest.computeEffectSha256();

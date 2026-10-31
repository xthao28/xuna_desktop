import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Persisted enrollment identity on the desktop (`host-state.json`).
class EnrolledHostState {
  EnrolledHostState({
    required this.hostId,
    required this.alias,
    required this.enrolledAt,
    this.pinnedPhonePublicKeys = const <String>[],
    this.lanEnabled = false,
  }) {
    if (!isValidUuid(hostId)) {
      throw FormatException('Invalid hostId UUID: $hostId');
    }
    if (alias.trim().isEmpty || alias.length > 24) {
      throw const FormatException('alias must be 1..24 characters');
    }
  }

  factory EnrolledHostState.fromJson(Map<String, Object?> json) {
    final hostId = json['hostId'];
    final alias = json['alias'];
    final enrolledAtRaw = json['enrolledAt'];
    if (hostId is! String || alias is! String || enrolledAtRaw is! String) {
      throw const FormatException('Invalid EnrolledHostState JSON');
    }
    final parsedDate = DateTime.tryParse(enrolledAtRaw);
    if (parsedDate == null) {
      throw const FormatException('Invalid EnrolledHostState enrolledAt');
    }
    final rawKeys = json['pinnedPhonePublicKeys'];
    final keys = <String>[];
    if (rawKeys is List) {
      for (final item in rawKeys) {
        if (item is String && item.isNotEmpty) {
          keys.add(item);
        }
      }
    }
    final lanEnabled = json['lanEnabled'] == true;
    return EnrolledHostState(
      hostId: hostId,
      alias: alias,
      enrolledAt: parsedDate.toUtc(),
      pinnedPhonePublicKeys: List<String>.unmodifiable(keys),
      lanEnabled: lanEnabled,
    );
  }

  final String hostId;
  final String alias;
  final DateTime enrolledAt;
  final List<String> pinnedPhonePublicKeys;
  final bool lanEnabled;

  /// Decodes valid 65-byte uncompressed P-256 phone public keys.
  List<Uint8List> get pinnedPhonePublicKeyBytes {
    final out = <Uint8List>[];
    for (final b64 in pinnedPhonePublicKeys) {
      try {
        final bytes = base64Decode(b64);
        validateP256PublicKey(bytes);
        out.add(bytes);
      } catch (_) {}
    }
    return out;
  }

  EnrolledHostState copyWith({
    String? hostId,
    String? alias,
    DateTime? enrolledAt,
    List<String>? pinnedPhonePublicKeys,
    bool? lanEnabled,
  }) {
    return EnrolledHostState(
      hostId: hostId ?? this.hostId,
      alias: alias ?? this.alias,
      enrolledAt: enrolledAt ?? this.enrolledAt,
      pinnedPhonePublicKeys:
          pinnedPhonePublicKeys ?? this.pinnedPhonePublicKeys,
      lanEnabled: lanEnabled ?? this.lanEnabled,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'hostId': hostId,
    'alias': alias,
    'enrolledAt': enrolledAt.toUtc().toIso8601String(),
    'pinnedPhonePublicKeys': pinnedPhonePublicKeys,
    'lanEnabled': lanEnabled,
  };
}

/// Manages local enrollment persistence (`host-state.json`).
///
/// When the backend rejects a reconnect with `unauthorized` or sends
/// `xuna/stop {reason: "revoked"}`, [clear] wipes the local state so the agent
/// returns to enrollment mode (`UDC-3` §5.1).
class EnrollmentStateStore {
  EnrollmentStateStore({required this.stateFile});

  final File stateFile;
  EnrolledHostState? _current;

  EnrolledHostState? get current => _current;
  bool get isEnrolled => _current != null;

  Future<EnrolledHostState?> load() async {
    try {
      if (!await stateFile.exists()) {
        _current = null;
        return null;
      }
      final raw = await stateFile.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _current = null;
        return null;
      }
      _current = EnrolledHostState.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
      return _current;
    } catch (_) {
      _current = null;
      return null;
    }
  }

  Future<EnrolledHostState> save({
    required String hostId,
    required String alias,
    DateTime? enrolledAt,
    List<String>? pinnedPhonePublicKeys,
    bool? lanEnabled,
  }) async {
    final prev = _current;
    final state = EnrolledHostState(
      hostId: hostId,
      alias: alias,
      enrolledAt: (enrolledAt ?? prev?.enrolledAt ?? DateTime.now()).toUtc(),
      pinnedPhonePublicKeys:
          pinnedPhonePublicKeys ?? prev?.pinnedPhonePublicKeys ?? const <String>[],
      lanEnabled: lanEnabled ?? prev?.lanEnabled ?? false,
    );
    await _writeState(state);
    return state;
  }

  Future<EnrolledHostState?> updatePhonePublicKeys(List<String> keys) async {
    final prev = _current ?? await load();
    if (prev == null) return null;
    final next = prev.copyWith(
      pinnedPhonePublicKeys: List<String>.unmodifiable(keys),
    );
    await _writeState(next);
    return next;
  }

  Future<EnrolledHostState?> updateLanEnabled(bool enabled) async {
    final prev = _current ?? await load();
    if (prev == null) return null;
    final next = prev.copyWith(lanEnabled: enabled);
    await _writeState(next);
    return next;
  }

  Future<void> _writeState(EnrolledHostState state) async {
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n',
      flush: true,
    );
    _current = state;
  }

  Future<void> clear() async {
    _current = null;
    try {
      if (await stateFile.exists()) {
        await stateFile.delete();
      }
    } on FileSystemException {
      // Ignore deletion errors.
    }
  }
}

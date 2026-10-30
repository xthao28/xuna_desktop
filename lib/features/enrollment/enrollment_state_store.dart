import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Persisted enrollment identity on the desktop (`host-state.json`).
class EnrolledHostState {
  EnrolledHostState({
    required this.hostId,
    required this.alias,
    required this.enrolledAt,
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
    return EnrolledHostState(
      hostId: hostId,
      alias: alias,
      enrolledAt: parsedDate.toUtc(),
    );
  }

  final String hostId;
  final String alias;
  final DateTime enrolledAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'hostId': hostId,
    'alias': alias,
    'enrolledAt': enrolledAt.toUtc().toIso8601String(),
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
  }) async {
    final state = EnrolledHostState(
      hostId: hostId,
      alias: alias,
      enrolledAt: (enrolledAt ?? DateTime.now()).toUtc(),
    );
    await stateFile.parent.create(recursive: true);
    await stateFile.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(state.toJson())}\n',
      flush: true,
    );
    _current = state;
    return state;
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

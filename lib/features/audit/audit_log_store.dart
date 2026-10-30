import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Single content-free line in the rotating local audit log (`UDC-3` §5.6.5):
/// `{ts, invocationId, tool, status, durationMs}`.
class AuditLogRecord {
  AuditLogRecord({
    required this.ts,
    required this.invocationId,
    required this.tool,
    required this.status,
    required this.durationMs,
  }) {
    if (!isValidUuid(invocationId)) {
      throw FormatException('Invalid invocationId UUID: $invocationId');
    }
    ToolDescriptor.validateToolName(tool);
    if (durationMs < 0) {
      throw const FormatException('durationMs must be non-negative');
    }
  }

  factory AuditLogRecord.fromJson(Map<String, Object?> json) {
    final tsRaw = json['ts'];
    final invocationId = json['invocationId'];
    final tool = json['tool'];
    final statusRaw = json['status'];
    final durationMs = json['durationMs'];
    if (tsRaw is! String ||
        invocationId is! String ||
        tool is! String ||
        statusRaw is! String ||
        durationMs is! int) {
      throw const FormatException('Invalid AuditLogRecord JSON');
    }
    final parsedTs = DateTime.tryParse(tsRaw);
    if (parsedTs == null) {
      throw const FormatException('Invalid AuditLogRecord ts');
    }
    return AuditLogRecord(
      ts: parsedTs.toUtc(),
      invocationId: invocationId,
      tool: tool,
      status: XtpStatus.fromWire(statusRaw),
      durationMs: durationMs,
    );
  }

  final DateTime ts;
  final String invocationId;
  final String tool;
  final XtpStatus status;
  final int durationMs;

  Map<String, Object?> toJson() => <String, Object?>{
    'ts': ts.toUtc().toIso8601String(),
    'invocationId': invocationId,
    'tool': tool,
    'status': status.wire,
    'durationMs': durationMs,
  };
}

/// Manages rotating daily JSONL audit files (`audit-YYYY-MM-DD.jsonl`) with a
/// 30-day retention window (`UDC-3` §5.6.1 & §5.6.5).
///
/// Never stores tool arguments, URLs, titles, or file paths.
class AuditLogStore {
  AuditLogStore({required this.auditDir, this.retentionDays = 30});

  final Directory auditDir;
  final int retentionDays;

  static final RegExp _filePattern = RegExp(
    r'^audit-(\d{4}-\d{2}-\d{2})\.jsonl$',
  );

  /// Appends [record] to the UTC date's JSONL file and prunes files older than
  /// [retentionDays] relative to `record.ts`.
  Future<void> append(AuditLogRecord record) async {
    await auditDir.create(recursive: true);
    final dateTag = _formatUtcDate(record.ts);
    final file = File(
      '${auditDir.path}${Platform.pathSeparator}audit-$dateTag.jsonl',
    );
    final line = '${jsonEncode(record.toJson())}\n';
    await file.writeAsString(line, mode: FileMode.append, flush: true);
    await pruneOldFiles(nowUtc: record.ts);
  }

  /// Deletes `audit-YYYY-MM-DD.jsonl` files older than [retentionDays].
  Future<int> pruneOldFiles({DateTime? nowUtc}) async {
    if (!await auditDir.exists()) return 0;
    final ref = (nowUtc ?? DateTime.now()).toUtc();
    final cutoffDay = DateTime.utc(
      ref.year,
      ref.month,
      ref.day,
    ).subtract(Duration(days: retentionDays));
    var deleted = 0;
    await for (final entity in auditDir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.isNotEmpty
          ? entity.uri.pathSegments.last
          : '';
      final match = _filePattern.firstMatch(name);
      if (match == null) continue;
      final fileDate = DateTime.tryParse('${match.group(1)!}T00:00:00Z');
      if (fileDate != null && fileDate.isBefore(cutoffDay)) {
        try {
          await entity.delete();
          deleted++;
        } on FileSystemException {
          // Ignore transient deletion errors.
        }
      }
    }
    return deleted;
  }

  /// Reads the most recent [limit] audit records across daily JSONL files
  /// (newest first) for the local audit viewer.
  Future<List<AuditLogRecord>> readRecent({int limit = 100}) async {
    if (!await auditDir.exists()) return const <AuditLogRecord>[];
    final files = <File>[];
    await for (final entity in auditDir.list()) {
      if (entity is File) {
        final name = entity.uri.pathSegments.isNotEmpty
            ? entity.uri.pathSegments.last
            : '';
        if (_filePattern.hasMatch(name)) {
          files.add(entity);
        }
      }
    }
    files.sort((a, b) => b.path.compareTo(a.path));

    final records = <AuditLogRecord>[];
    for (final file in files) {
      if (records.length >= limit) break;
      List<String> lines;
      try {
        lines = await file.readAsLines();
      } on FileSystemException {
        continue;
      }
      for (var i = lines.length - 1; i >= 0; i--) {
        if (records.length >= limit) break;
        final line = lines[i].trim();
        if (line.isEmpty) continue;
        try {
          final decoded = jsonDecode(line);
          if (decoded is Map) {
            records.add(
              AuditLogRecord.fromJson(
                decoded.map((k, v) => MapEntry(k.toString(), v)),
              ),
            );
          }
        } on FormatException {
          continue;
        }
      }
    }
    return records;
  }

  static String _formatUtcDate(DateTime dt) {
    final utc = dt.toUtc();
    final y = utc.year.toString().padLeft(4, '0');
    final m = utc.month.toString().padLeft(2, '0');
    final d = utc.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

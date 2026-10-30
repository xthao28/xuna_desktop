import 'dart:collection';

/// Level of a content-free structured log entry.
enum AgentLogLevel {
  info('INFO'),
  warning('WARN'),
  error('ERROR');

  const AgentLogLevel(this.wire);
  final String wire;
}

/// Immutable structured log entry that guarantees no sensitive tool arguments,
/// URLs, titles, or file paths are ever recorded (`UDC-3` §5.6.5 & §7).
class AgentLogEntry {
  const AgentLogEntry({
    required this.timestampUtc,
    required this.level,
    required this.event,
    this.fields = const <String, Object?>{},
  });

  final DateTime timestampUtc;
  final AgentLogLevel level;
  final String event;
  final Map<String, Object?> fields;
}

/// Content-free ring-buffer logger (`UDC-3` §3 rule 6).
///
/// Only allowlisted metadata keys (`hostId`, `invocationId`, `tool`, `status`,
/// `errorCode`, `durationMs`, `attempt`, `delayMs`, `closeCode`, `reason`,
/// `healthy`) may be recorded in [fields]. Keys such as `arguments`, `url`,
/// `title`, `body`, `target`, `path`, `artist` are stripped automatically.
class ContentFreeLogger {
  ContentFreeLogger({this.maxEntries = 200});

  static const Set<String> allowedFieldKeys = <String>{
    'hostId',
    'invocationId',
    'tool',
    'status',
    'errorCode',
    'durationMs',
    'attempt',
    'delayMs',
    'closeCode',
    'reason',
    'healthy',
    'purpose',
    'platform',
  };

  final int maxEntries;
  final Queue<AgentLogEntry> _entries = Queue<AgentLogEntry>();

  List<AgentLogEntry> get entries => List<AgentLogEntry>.unmodifiable(_entries);

  void info(
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {
    _record(AgentLogLevel.info, event, fields);
  }

  void warning(
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {
    _record(AgentLogLevel.warning, event, fields);
  }

  void error(
    String event, [
    Map<String, Object?> fields = const <String, Object?>{},
  ]) {
    _record(AgentLogLevel.error, event, fields);
  }

  void _record(
    AgentLogLevel level,
    String event,
    Map<String, Object?> rawFields,
  ) {
    final sanitized = <String, Object?>{};
    for (final entry in rawFields.entries) {
      if (allowedFieldKeys.contains(entry.key)) {
        sanitized[entry.key] = entry.value;
      }
    }
    while (_entries.length >= maxEntries) {
      _entries.removeFirst();
    }
    _entries.addLast(
      AgentLogEntry(
        timestampUtc: DateTime.now().toUtc(),
        level: level,
        event: event,
        fields: Map<String, Object?>.unmodifiable(sanitized),
      ),
    );
  }
}

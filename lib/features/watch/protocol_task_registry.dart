import 'dart:async';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

enum ProtocolTaskStatus {
  running('running'),
  completed('completed'),
  failed('failed'),
  cancelled('cancelled');

  const ProtocolTaskStatus(this.wire);
  final String wire;
}

enum ProtocolTaskEventKind {
  progress,
  completed,
  failed,
  cancelled,
  targetLost,
}

/// Content-free event emitted when a protocol task advances or terminates.
class ProtocolTaskEvent {
  const ProtocolTaskEvent({
    required this.taskId,
    required this.serverId,
    required this.kind,
    required this.progressCount,
    required this.occurredAt,
    this.progressPercent,
    this.errorCode,
  });

  final String taskId, serverId;
  final ProtocolTaskEventKind kind;
  final int progressCount;
  final int? progressPercent;
  final String? errorCode;
  final DateTime occurredAt;
}

class ProtocolTaskLimitException extends XunaHostChannelException {
  const ProtocolTaskLimitException()
    : super(status: XtpStatus.failed, errorCode: 'protocol_task_limit_reached');
}

class ProtocolTaskHandle {
  ProtocolTaskHandle({
    required this.taskId,
    required this.serverId,
    required this.protocol,
    required DateTime now,
    this.cancelCallback,
  }) : startedAt = now,
       updatedAt = now;

  final String taskId, serverId, protocol;
  final DateTime startedAt;
  DateTime updatedAt;
  DateTime? completedAt;
  ProtocolTaskStatus status = ProtocolTaskStatus.running;
  int progressCount = 0;
  int? progressPercent;
  String? redactedSummary, errorCode;
  bool targetLost = false;
  Future<void> Function()? cancelCallback;
}

/// RAM-only registry tracking detached MCP and ACP protocol tasks (`AW2-M2`).
class ProtocolTaskRegistry {
  ProtocolTaskRegistry({
    EmergencyStopController? stopController,
    DateTime Function()? clock,
  }) : _stopController = stopController,
       _clock = clock ?? _utcNow {
    _stopController?.addCancelListener(_onEmergencyStop);
  }

  static const int maxConcurrentTasks = 4;
  static const int maxCompletedRetained = 16;
  static const Duration completedRetentionTtl = Duration(minutes: 5);
  static const int maxSummaryBytes = 6144;
  static DateTime _utcNow() => DateTime.now().toUtc();

  final EmergencyStopController? _stopController;
  final DateTime Function() _clock;
  final Map<String, ProtocolTaskHandle> _activeTasks = {}, _completedTasks = {};
  final List<String> _completedOrder = [];
  final StreamController<ProtocolTaskEvent> _eventsController =
      StreamController<ProtocolTaskEvent>.broadcast();

  int _sequence = 0;
  bool _disposed = false;

  Stream<ProtocolTaskEvent> get events => _eventsController.stream;
  int get activeCount => _activeTasks.length;

  int get retainedCompletedCount {
    _pruneExpired();
    return _completedTasks.length;
  }

  static String redactSummary(String raw) => redactBrowserSnapshot(
    redactFilesystemPaths(raw),
    maxBytes: maxSummaryBytes,
  ).text;

  static Never _err(XtpStatus s, String code) =>
      throw XunaHostChannelException(status: s, errorCode: code);

  ProtocolTaskHandle registerTask({
    String? taskId,
    required String serverId,
    required String protocol,
    Future<void> Function()? cancelCallback,
  }) {
    if (_disposed) _err(XtpStatus.failed, 'registry_disposed');
    if (_stopController?.isStopped == true) _err(XtpStatus.denied, 'stopped');
    _pruneExpired();
    if (_activeTasks.length >= maxConcurrentTasks) {
      throw const ProtocolTaskLimitException();
    }
    final now = _clock().toUtc();
    final id = (taskId != null && taskId.isNotEmpty)
        ? taskId
        : 'pt_${++_sequence}_${now.millisecondsSinceEpoch}';
    if (_activeTasks.containsKey(id) || _completedTasks.containsKey(id)) {
      _err(XtpStatus.invalidArgs, 'invalid_args');
    }
    return _activeTasks[id] = ProtocolTaskHandle(
      taskId: id,
      serverId: serverId,
      protocol: protocol,
      now: now,
      cancelCallback: cancelCallback,
    );
  }

  ProtocolTaskHandle? lookup(String serverId, String taskId) {
    _pruneExpired();
    final h = _activeTasks[taskId] ?? _completedTasks[taskId];
    return (h == null || h.serverId != serverId) ? null : h;
  }

  void recordProgress(String taskId, {int? progressPercent}) {
    final h = _disposed ? null : _activeTasks[taskId];
    if (h == null) return;
    final now = _clock().toUtc();
    h.progressCount += 1;
    h.progressPercent = progressPercent?.clamp(0, 100) ?? h.progressPercent;
    h.updatedAt = now;
    _emit(h, ProtocolTaskEventKind.progress);
  }

  void completeTask(
    String taskId, {
    required String summary,
    int? progressPercent,
  }) => _end(
    taskId,
    ProtocolTaskEventKind.completed,
    null,
    summary,
    progressPercent,
  );

  void failTask(
    String taskId, {
    String errorCode = 'protocol_task_failed',
    String? summary,
    bool targetLost = false,
  }) => _end(
    taskId,
    targetLost
        ? ProtocolTaskEventKind.targetLost
        : ProtocolTaskEventKind.failed,
    targetLost && errorCode == 'protocol_task_failed'
        ? 'target_lost'
        : errorCode,
    summary,
  );

  void markLost(
    String taskId, {
    String errorCode = 'target_lost',
    String? summary,
  }) => failTask(
    taskId,
    errorCode: errorCode,
    summary: summary,
    targetLost: true,
  );

  Future<bool> cancelTask(
    String serverId,
    String taskId, {
    String reason = 'cancelled_by_caller',
  }) async {
    final h = _disposed ? null : _activeTasks[taskId];
    if (h == null || h.serverId != serverId) return false;
    final cb = _end(taskId, ProtocolTaskEventKind.cancelled, reason);
    if (cb != null) {
      try {
        await cb();
      } catch (_) {}
    }
    return true;
  }

  Future<void> Function()? _end(
    String taskId,
    ProtocolTaskEventKind kind, [
    String? errorCode,
    String? summary,
    int? progressPercent,
  ]) {
    final h = _disposed ? null : _activeTasks.remove(taskId);
    if (h == null) return null;
    final now = _clock().toUtc();
    final cb = h.cancelCallback;
    h
      ..cancelCallback = null
      ..status = kind == ProtocolTaskEventKind.completed
          ? ProtocolTaskStatus.completed
          : (kind == ProtocolTaskEventKind.cancelled
                ? ProtocolTaskStatus.cancelled
                : ProtocolTaskStatus.failed)
      ..errorCode = errorCode
      ..targetLost = kind == ProtocolTaskEventKind.targetLost
      ..redactedSummary = summary != null ? redactSummary(summary) : ''
      ..updatedAt = now
      ..completedAt = now
      ..progressPercent = progressPercent?.clamp(0, 100) ?? h.progressPercent;
    _completedTasks[h.taskId] = h;
    _completedOrder
      ..remove(h.taskId)
      ..add(h.taskId);
    _pruneExpired();
    _emit(h, kind, errorCode);
    return cb;
  }

  void _onEmergencyStop(StopReason reason) {
    if (_disposed || _activeTasks.isEmpty) return;
    for (final id in _activeTasks.keys.toList(growable: false)) {
      final cb = _end(id, ProtocolTaskEventKind.cancelled, 'stopped');
      if (cb != null) unawaited(cb().catchError((Object _) {}));
    }
  }

  void _pruneExpired() {
    final now = _clock().toUtc();
    _completedOrder.removeWhere((id) {
      final doneAt = _completedTasks[id]?.completedAt;
      final exp =
          doneAt == null || now.difference(doneAt) >= completedRetentionTtl;
      if (exp) _completedTasks.remove(id);
      return exp;
    });
    while (_completedOrder.length > maxCompletedRetained) {
      _completedTasks.remove(_completedOrder.removeAt(0));
    }
  }

  void _emit(ProtocolTaskHandle h, ProtocolTaskEventKind k, [String? err]) {
    if (_eventsController.isClosed) return;
    _eventsController.add(
      ProtocolTaskEvent(
        taskId: h.taskId,
        serverId: h.serverId,
        kind: k,
        progressCount: h.progressCount,
        progressPercent: h.progressPercent,
        errorCode: err,
        occurredAt: h.updatedAt,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopController?.removeCancelListener(_onEmergencyStop);
    for (final h in _activeTasks.values.toList(growable: false)) {
      final cb = h.cancelCallback;
      if (cb != null) unawaited(cb().catchError((Object _) {}));
    }
    _activeTasks.clear();
    _completedTasks.clear();
    _completedOrder.clear();
    await _eventsController.close();
  }
}

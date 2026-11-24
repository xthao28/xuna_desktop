import 'dart:async';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Event-driven [WatchSignalDriver] observing [WatchSignal.protocolAsync] via
/// [ProtocolTaskRegistry] (`AW2-M2`).
class ProtocolAsyncWatchDriver implements WatchSignalDriver {
  ProtocolAsyncWatchDriver({
    required ProtocolTaskRegistry taskRegistry,
    ContentFreeLogger? logger,
  }) : _taskRegistry = taskRegistry,
       _logger = logger;

  final ProtocolTaskRegistry _taskRegistry;
  final ContentFreeLogger? _logger;

  @override
  Set<WatchSignal> get supportedSignals => const <WatchSignal>{
    WatchSignal.protocolAsync,
  };

  static void _emitUpdate(
    void Function(WatchSignalUpdate) onUpdate,
    WatchSignalState state, {
    bool digestChanged = false,
    String? errorCode,
  }) => onUpdate(
    WatchSignalUpdate(
      signal: WatchSignal.protocolAsync,
      state: state,
      digestChanged: digestChanged,
      errorCode: errorCode,
    ),
  );

  @override
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  }) async {
    if (signal != WatchSignal.protocolAsync) {
      throw const WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Protocol driver supports only protocol_async.',
      );
    }
    final serverId = target.mcpServerId?.trim() ?? '';
    final taskId = target.protocolTaskId?.trim() ?? '';
    if (serverId.isEmpty || taskId.isEmpty) {
      throw const WatchDriverException(
        errorCode: 'target_not_found',
        message: 'protocol_async requires mcpServerId and protocolTaskId.',
      );
    }
    final handle = _taskRegistry.lookup(serverId, taskId);
    if (handle == null) {
      throw const WatchDriverException(
        errorCode: 'target_not_found',
        message: 'Protocol task not found or expired.',
      );
    }

    final sub = _ProtocolAsyncWatchSubscription(
      serverId: serverId,
      taskId: taskId,
      onUpdate: onUpdate,
    );
    switch (handle.status) {
      case ProtocolTaskStatus.completed:
        _emitUpdate(onUpdate, WatchSignalState.changed, digestChanged: true);
        _emitUpdate(onUpdate, WatchSignalState.settled);
      case ProtocolTaskStatus.failed:
        _emitUpdate(
          onUpdate,
          handle.targetLost ? WatchSignalState.lost : WatchSignalState.error,
          errorCode: handle.targetLost
              ? null
              : (handle.errorCode ?? 'protocol_task_failed'),
        );
      case ProtocolTaskStatus.cancelled:
        _emitUpdate(
          onUpdate,
          WatchSignalState.error,
          errorCode: handle.errorCode ?? 'cancelled_by_caller',
        );
      case ProtocolTaskStatus.running:
        // Keep _quietSince == null in WatchConvergence while running so slow
        // tasks never prematurely settle across quiescenceSeconds.
        _emitUpdate(onUpdate, WatchSignalState.active);
        sub.listen(_taskRegistry.events);
    }

    _logger?.info('watch.protocol_async_started', const <String, Object?>{
      'source': 'protocol_async',
      'status': 'started',
    });
    return sub;
  }
}

class _ProtocolAsyncWatchSubscription implements WatchSignalSubscription {
  _ProtocolAsyncWatchSubscription({
    required this.serverId,
    required this.taskId,
    required this.onUpdate,
  });

  final String serverId;
  final String taskId;
  final void Function(WatchSignalUpdate update) onUpdate;
  StreamSubscription<ProtocolTaskEvent>? _sub;
  bool _disposed = false;

  @override
  bool get eventDriven => true;
  @override
  bool get fallbackUsed => false;

  void listen(Stream<ProtocolTaskEvent> events) {
    _sub = events
        .where((e) => e.taskId == taskId && e.serverId == serverId)
        .listen(_handleEvent);
  }

  void _handleEvent(ProtocolTaskEvent event) {
    if (_disposed) return;
    switch (event.kind) {
      case ProtocolTaskEventKind.progress:
        ProtocolAsyncWatchDriver._emitUpdate(
          onUpdate,
          WatchSignalState.active,
          digestChanged: true,
        );
      case ProtocolTaskEventKind.completed:
        _closeSub();
        ProtocolAsyncWatchDriver._emitUpdate(
          onUpdate,
          WatchSignalState.changed,
          digestChanged: true,
        );
        if (!_disposed) {
          ProtocolAsyncWatchDriver._emitUpdate(
            onUpdate,
            WatchSignalState.settled,
          );
        }
      case ProtocolTaskEventKind.failed:
        _closeSub();
        ProtocolAsyncWatchDriver._emitUpdate(
          onUpdate,
          WatchSignalState.error,
          errorCode: event.errorCode ?? 'protocol_task_failed',
        );
      case ProtocolTaskEventKind.cancelled:
        _closeSub();
        ProtocolAsyncWatchDriver._emitUpdate(
          onUpdate,
          WatchSignalState.error,
          errorCode: event.errorCode ?? 'cancelled_by_caller',
        );
      case ProtocolTaskEventKind.targetLost:
        _closeSub();
        ProtocolAsyncWatchDriver._emitUpdate(onUpdate, WatchSignalState.lost);
    }
  }

  void _closeSub() {
    unawaited(_sub?.cancel());
    _sub = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
  }
}

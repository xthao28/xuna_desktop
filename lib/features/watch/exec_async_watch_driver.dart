import 'dart:async';

import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Event-driven [WatchSignalDriver] for [WatchSignal.execAsync] (`ADR-0018`).
///
/// Watches one detached `exec.run` task in [ExecProcessRegistry]. A task that
/// exits (any exit code) yields `changed` then `settled`; the waking model
/// must read the exit code with `exec.status` (Rule H1). A timeout or cancel
/// (including E-Stop) yields `error` with `exec_timed_out` /
/// `exec_cancelled`. Events carry no output, command or path (Consent U5).
class ExecAsyncWatchDriver implements WatchSignalDriver {
  ExecAsyncWatchDriver({required ExecProcessRegistry registry})
    : _registry = registry;

  final ExecProcessRegistry _registry;

  @override
  Set<WatchSignal> get supportedSignals => const <WatchSignal>{
    WatchSignal.execAsync,
  };

  @override
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  }) async {
    if (signal != WatchSignal.execAsync) {
      throw const WatchDriverException(
        errorCode: 'watch_unsupported',
        message: 'Exec driver supports only exec_async.',
      );
    }
    final taskId = target.execTaskId;
    final status = taskId == null ? null : _registry.statusOf(taskId);
    if (taskId == null || status == null) {
      throw const WatchDriverException(
        errorCode: 'target_not_found',
        message: 'exec_async requires a known execTaskId.',
      );
    }
    final sub = _ExecAsyncSubscription(taskId, onUpdate);
    if (status.isTerminal) {
      sub.emitTerminal(status);
    } else {
      onUpdate(
        const WatchSignalUpdate(
          signal: WatchSignal.execAsync,
          state: WatchSignalState.active,
        ),
      );
      sub.listen(_registry.events);
    }
    return sub;
  }
}

class _ExecAsyncSubscription implements WatchSignalSubscription {
  _ExecAsyncSubscription(this.taskId, this.onUpdate);

  final String taskId;
  final void Function(WatchSignalUpdate update) onUpdate;
  StreamSubscription<ExecTaskEvent>? _sub;
  bool _disposed = false;

  @override
  bool get eventDriven => true;

  @override
  bool get fallbackUsed => false;

  void listen(Stream<ExecTaskEvent> events) {
    _sub = events.where((e) => e.taskId == taskId).listen((event) {
      if (!event.status.isTerminal) return;
      unawaited(_sub?.cancel());
      _sub = null;
      emitTerminal(event.status);
    });
  }

  void emitTerminal(ExecTaskStatus status) {
    if (_disposed) return;
    switch (status) {
      case ExecTaskStatus.completed:
      case ExecTaskStatus.failed:
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.execAsync,
            state: WatchSignalState.changed,
            digestChanged: true,
          ),
        );
        if (!_disposed) {
          onUpdate(
            const WatchSignalUpdate(
              signal: WatchSignal.execAsync,
              state: WatchSignalState.settled,
            ),
          );
        }
      case ExecTaskStatus.timedOut:
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.execAsync,
            state: WatchSignalState.error,
            errorCode: 'exec_timed_out',
          ),
        );
      case ExecTaskStatus.cancelled:
        onUpdate(
          const WatchSignalUpdate(
            signal: WatchSignal.execAsync,
            state: WatchSignalState.error,
            errorCode: 'exec_cancelled',
          ),
        );
      case ExecTaskStatus.running:
        break;
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _sub?.cancel();
    _sub = null;
  }
}

import 'dart:async';
import 'dart:math';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Wire statuses of an exec task (`exec.run` / `exec.status`).
enum ExecTaskStatus {
  running('running'),
  completed('completed'),
  failed('failed'),
  timedOut('timed_out'),
  cancelled('cancelled');

  const ExecTaskStatus(this.wire);
  final String wire;

  bool get isTerminal => this != ExecTaskStatus.running;
}

/// Content-free terminal event used by `ExecAsyncWatchDriver`.
class ExecTaskEvent {
  const ExecTaskEvent(this.taskId, this.status);

  final String taskId;
  final ExecTaskStatus status;
}

/// Snapshot returned to tool handlers (output already U5-redacted).
class ExecTaskSnapshot {
  const ExecTaskSnapshot({
    required this.taskId,
    required this.status,
    required this.output,
    required this.truncated,
    required this.elapsedMs,
    this.exitCode,
  });

  final String taskId;
  final ExecTaskStatus status;
  final int? exitCode;
  final String output;
  final bool truncated;
  final int elapsedMs;
}

class _ExecTask {
  _ExecTask(this.id, this.handle, this.risk, this.startedAt);

  final String id;
  final ExecProcessHandle handle;
  final RiskTier risk;
  final DateTime startedAt;
  final List<int> buffer = <int>[];
  bool bufferTruncated = false;
  ExecTaskStatus status = ExecTaskStatus.running;
  int? exitCode;
  DateTime? finishedAt;
  final Completer<void> done = Completer<void>();
  Timer? timeoutTimer;
}

/// RAM-only registry of `exec.run` children (`ADR-0018`).
///
/// At most [maxTasks] run at once (`exec_task_limit_reached`); each keeps a
/// rolling [maxBufferBytes] output buffer; finished tasks are kept for
/// [retention] (at most [maxRetained]) and never written to disk. E-Stop
/// terminates every running process group (SIGTERM, then SIGKILL after
/// [killGrace]) and marks the tasks `cancelled`.
class ExecProcessRegistry {
  ExecProcessRegistry({
    required EmergencyStopController stopController,
    ExecProcessLauncher? launcher,
    ContentFreeLogger? logger,
    this.maxTasks = 4,
    this.maxBufferBytes = 64 * 1024,
    this.retention = const Duration(minutes: 5),
    this.maxRetained = 16,
    this.killGrace = const Duration(milliseconds: 500),
    this.pollInterval = const Duration(milliseconds: 100),
    DateTime Function()? clock,
  }) : _stop = stopController,
       launcher = launcher ?? defaultExecProcessLauncher(),
       _logger = logger,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    _stop.addCancelListener(_onEmergencyStop);
  }

  final ExecProcessLauncher launcher;
  final EmergencyStopController _stop;
  final ContentFreeLogger? _logger;
  final DateTime Function() _clock;
  final int maxTasks;
  final int maxBufferBytes;
  final Duration retention;
  final int maxRetained;
  final Duration killGrace;
  final Duration pollInterval;
  final Map<String, _ExecTask> _tasks = <String, _ExecTask>{};
  final Map<String, Future<void>> _terminations = <String, Future<void>>{};
  final StreamController<ExecTaskEvent> _events =
      StreamController<ExecTaskEvent>.broadcast();
  final Random _random = Random.secure();

  Stream<ExecTaskEvent> get events => _events.stream;

  /// Tasks whose process has not been reaped yet (including ones being killed).
  int get runningCount =>
      _tasks.values.where((t) => !t.done.isCompleted).length;

  /// Risk the task was started with (for `exec.write_stdin`), or null.
  RiskTier? riskOf(String taskId) => _tasks[taskId]?.risk;

  /// Local OS process id (process-group leader) of [taskId]; host-local
  /// diagnostics only, never sent on the wire.
  int? pidOf(String taskId) => _tasks[taskId]?.handle.pid;

  /// Status of [taskId], or null when unknown/expired.
  ExecTaskStatus? statusOf(String taskId) => _tasks[taskId]?.status;

  /// Starts [command] and waits up to [yieldAfter]. Returns the finished
  /// snapshot, or a `running` snapshot when the task detached.
  Future<ExecTaskSnapshot> run({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
    required Duration timeout,
    required Duration yieldAfter,
    required RiskTier risk,
    int? concurrencyLimit,
  }) async {
    _purge();
    if (_stop.isStopped) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'stopped',
      );
    }
    final limit = min(maxTasks, concurrencyLimit ?? maxTasks);
    if (runningCount >= limit) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'exec_task_limit_reached',
      );
    }
    final handle = await launcher.start(
      command: command,
      cwd: cwd,
      environment: environment,
      pty: pty,
    );
    final task = _ExecTask(_newId(), handle, risk, _clock());
    _tasks[task.id] = task;
    task.timeoutTimer = Timer(timeout, () {
      unawaited(_terminate(task, ExecTaskStatus.timedOut));
    });
    unawaited(_pump(task));
    _logger?.info('exec.started', <String, Object?>{'risk': risk.wire});
    await Future.any<void>(<Future<void>>[
      task.done.future,
      Future<void>.delayed(yieldAfter),
    ]);
    return snapshot(task.id, tailBytes: 16384)!;
  }

  Future<void> _pump(_ExecTask task) async {
    while (true) {
      ExecPollResult result;
      try {
        result = await task.handle.poll();
      } on Object {
        _finish(task, ExecTaskStatus.failed, exitCode: null);
        return;
      }
      _append(task, result.data, dropped: result.dropped);
      if (result.exited) {
        final code = result.exitCode;
        _finish(
          task,
          code == 0 ? ExecTaskStatus.completed : ExecTaskStatus.failed,
          exitCode: code,
        );
        return;
      }
      // Keep polling after a cancel/timeout signal until the exit is reaped.
      if (task.done.isCompleted) return;
      await Future<void>.delayed(pollInterval);
    }
  }

  void _append(_ExecTask task, List<int> data, {required bool dropped}) {
    if (dropped) task.bufferTruncated = true;
    if (data.isEmpty) return;
    task.buffer.addAll(data);
    final overflow = task.buffer.length - maxBufferBytes;
    if (overflow > 0) {
      task.buffer.removeRange(0, overflow);
      task.bufferTruncated = true;
    }
  }

  /// Records the terminal state once; later calls keep the first status (a
  /// timeout or cancel wins over the exit code the kill produced).
  void _finish(_ExecTask task, ExecTaskStatus status, {int? exitCode}) {
    if (task.done.isCompleted) return;
    if (!task.status.isTerminal) task.status = status;
    task.exitCode ??= exitCode;
    task.finishedAt = _clock();
    task.timeoutTimer?.cancel();
    task.done.complete();
    unawaited(task.handle.release().catchError((Object _) {}));
    if (!_events.isClosed) _events.add(ExecTaskEvent(task.id, task.status));
    _logger?.info('exec.finished', <String, Object?>{
      'status': task.status.wire,
    });
  }

  /// Terminates [task] once; concurrent callers share the same future so an
  /// E-Stop and an explicit `killAll()` both wait for the real reap.
  Future<void> _terminate(_ExecTask task, ExecTaskStatus status) {
    if (task.done.isCompleted) return Future<void>.value();
    return _terminations[task.id] ??= _doTerminate(task, status);
  }

  Future<void> _doTerminate(_ExecTask task, ExecTaskStatus status) async {
    task.status = status;
    try {
      await task.handle.killGroup(force: false);
      await task.done.future.timeout(killGrace);
    } on Object {
      try {
        await task.handle.killGroup(force: true);
      } on Object {
        // The group may already be gone; the pump records the exit.
      }
    }
    // Wait for the reaped exit (bounded) so no task stays "running".
    await task.done.future.timeout(
      killGrace * 4,
      onTimeout: () {
        _finish(task, status);
      },
    );
  }

  /// Cancels [taskId]: `cancelled` with the signal state, `already_finished`
  /// when it had ended, or `exec_task_not_found`.
  Future<({String status, bool signalSent})> cancel(String taskId) async {
    final task = _tasks[taskId];
    if (task == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_task_not_found',
      );
    }
    if (task.done.isCompleted || _terminations.containsKey(taskId)) {
      await _terminations[taskId];
      return (status: 'already_finished', signalSent: false);
    }
    await _terminate(task, ExecTaskStatus.cancelled);
    return (status: 'cancelled', signalSent: true);
  }

  Future<int> writeStdin(String taskId, List<int> bytes, {bool eof = false}) {
    final task = _tasks[taskId];
    if (task == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_task_not_found',
      );
    }
    if (task.status.isTerminal) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_task_finished',
      );
    }
    return task.handle.writeStdin(bytes, eof: eof);
  }

  /// Snapshot with the last [tailBytes] of output, U5-redacted.
  ExecTaskSnapshot? snapshot(String taskId, {int tailBytes = 8192}) {
    _purge();
    final task = _tasks[taskId];
    if (task == null) return null;
    final redacted = redactExecOutput(task.buffer, maxBytes: tailBytes);
    final end = task.finishedAt ?? _clock();
    return ExecTaskSnapshot(
      taskId: task.id,
      status: task.status,
      exitCode: task.status.isTerminal ? task.exitCode : null,
      output: redacted.text,
      truncated: redacted.truncated || task.bufferTruncated,
      elapsedMs: end.difference(task.startedAt).inMilliseconds,
    );
  }

  void _onEmergencyStop(StopReason reason) {
    unawaited(killAll());
  }

  /// Terminates every running task (E-Stop). Completes when all are reaped
  /// or marked after the bounded grace.
  Future<void> killAll() async {
    final running = _tasks.values.where((t) => !t.done.isCompleted).toList();
    await Future.wait(
      running.map((t) => _terminate(t, ExecTaskStatus.cancelled)),
    );
  }

  void _purge() {
    final now = _clock();
    _tasks.removeWhere(
      (_, t) =>
          t.finishedAt != null && now.difference(t.finishedAt!) > retention,
    );
    _terminations.removeWhere((id, _) => !_tasks.containsKey(id));
    final finished = _tasks.values.where((t) => t.finishedAt != null).toList()
      ..sort((a, b) => a.finishedAt!.compareTo(b.finishedAt!));
    while (finished.length > maxRetained) {
      _tasks.remove(finished.removeAt(0).id);
    }
  }

  String _newId() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final suffix = List<String>.generate(
      12,
      (_) => chars[_random.nextInt(chars.length)],
    ).join();
    return 'exec_$suffix';
  }

  Future<void> dispose() async {
    _stop.removeCancelListener(_onEmergencyStop);
    await killAll();
    await _events.close();
  }
}

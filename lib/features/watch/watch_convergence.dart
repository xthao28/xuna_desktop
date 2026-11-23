import 'dart:async';
import 'dart:math';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Current observation state of an individual signal inside [WatchConvergence].
enum WatchSignalState { idle, active, changed, settled, lost, error }

/// Clock provider for deterministic testing.
typedef WatchNow = DateTime Function();

/// Minimal cancellable timer abstraction for deterministic testing.
abstract interface class WatchCancellableTimer {
  bool get isActive;
  void cancel();
}

/// Timer factory abstraction for deterministic testing.
typedef WatchTimerFactory =
    WatchCancellableTimer Function(Duration delay, void Function() onFire);

class _DartWatchTimer implements WatchCancellableTimer {
  _DartWatchTimer(Duration delay, void Function() onFire)
    : _timer = Timer(delay, onFire);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}

WatchCancellableTimer _defaultTimerFactory(
  Duration delay,
  void Function() onFire,
) => _DartWatchTimer(delay, onFire);

DateTime _defaultNow() => DateTime.now().toUtc();

final RegExp _shortErrorCodePattern = RegExp(r'^[a-z0-9_.-]{1,64}$');

/// Deterministic multi-signal convergence state machine (`§5.1`).
///
/// Tracks per-signal states (`idle`, `active`, `changed`, `settled`, `lost`,
/// `error`), enforces `minWaitSeconds`, `requireInitialChange`,
/// `quiescenceSeconds`, and `maxWaitSeconds` using a single dynamically
/// scheduled convergence timer plus a hard `maxWaitSeconds` timer.
class WatchConvergence {
  WatchConvergence({
    required this.watchId,
    required this.jobId,
    required this.mode,
    required List<WatchSignal> activeSignals,
    required this.quiescenceSeconds,
    required this.minWaitSeconds,
    required this.maxWaitSeconds,
    required this.requireInitialChange,
    required this.onTerminalEvent,
    WatchNow? now,
    WatchTimerFactory? timerFactory,
  }) : activeSignals = List<WatchSignal>.unmodifiable(activeSignals),
       _now = now ?? _defaultNow,
       _timerFactory = timerFactory ?? _defaultTimerFactory {
    if (activeSignals.isEmpty || activeSignals.length > 3) {
      throw ArgumentError.value(
        activeSignals,
        'activeSignals',
        'Must contain 1..3 signals',
      );
    }
    if (activeSignals.toSet().length != activeSignals.length) {
      throw ArgumentError.value(
        activeSignals,
        'activeSignals',
        'Signals must be distinct',
      );
    }
    if (quiescenceSeconds < 2 || quiescenceSeconds > 120) {
      throw ArgumentError.value(
        quiescenceSeconds,
        'quiescenceSeconds',
        'Must be in 2..120',
      );
    }
    if (minWaitSeconds < 0 || minWaitSeconds > 60) {
      throw ArgumentError.value(
        minWaitSeconds,
        'minWaitSeconds',
        'Must be in 0..60',
      );
    }
    if (maxWaitSeconds < 5 || maxWaitSeconds > 900) {
      throw ArgumentError.value(
        maxWaitSeconds,
        'maxWaitSeconds',
        'Must be in 5..900',
      );
    }
    if (minWaitSeconds > maxWaitSeconds) {
      throw ArgumentError('minWaitSeconds must be <= maxWaitSeconds');
    }
  }

  final String watchId;
  final String jobId;
  final WatchMode mode;
  final List<WatchSignal> activeSignals;
  final int quiescenceSeconds;
  final int minWaitSeconds;
  final int maxWaitSeconds;
  final bool requireInitialChange;
  final void Function(WatchEventParams event) onTerminalEvent;
  final WatchNow _now;
  final WatchTimerFactory _timerFactory;

  final Map<WatchSignal, WatchSignalState> _states =
      <WatchSignal, WatchSignalState>{};
  final Map<WatchSignal, DateTime?> _quietSince = <WatchSignal, DateTime?>{};
  final List<WatchSignal> _observedOrder = <WatchSignal>[];

  int _changeCount = 0;
  bool _digestChanged = false;
  bool _hasInitialChange = false;
  bool _started = false;
  bool _terminated = false;
  DateTime? _startedAt;
  WatchCancellableTimer? _convergenceTimer;
  WatchCancellableTimer? _maxWaitTimer;

  bool get isActive => _started && !_terminated;
  bool get isTerminated => _terminated;
  int get changeCount => _changeCount;
  bool get digestChanged => _digestChanged;
  Map<WatchSignal, WatchSignalState> get signalStates =>
      Map<WatchSignal, WatchSignalState>.unmodifiable(_states);

  /// Starts convergence tracking and schedules the hard `maxWaitSeconds` timer.
  void start() {
    if (_started || _terminated) return;
    _started = true;
    final startTime = _now().toUtc();
    _startedAt = startTime;
    for (final sig in activeSignals) {
      _states[sig] = WatchSignalState.idle;
      _quietSince[sig] = startTime;
    }
    _maxWaitTimer = _timerFactory(
      Duration(seconds: maxWaitSeconds),
      _onMaxWaitFired,
    );
    _evaluateAndReschedule(startTime);
  }

  /// Reports an updated state for [signal].
  void reportSignal(
    WatchSignal signal,
    WatchSignalState nextState, {
    bool digestChanged = false,
    String? errorCode,
  }) {
    if (!_started || _terminated) return;
    if (!_states.containsKey(signal)) return;

    final currentNow = _now().toUtc();
    if (!_observedOrder.contains(signal)) {
      _observedOrder.add(signal);
    }

    // Keep quiescence snapshots exact for other signals before handling this update.
    _promoteQuietSignals(currentNow, exclude: signal);

    switch (nextState) {
      case WatchSignalState.lost:
        _states[signal] = WatchSignalState.lost;
        _emitTerminal(
          kind: WatchEventKind.targetLost,
          now: currentNow,
          observedSignals: const <WatchSignal>[],
        );
        return;
      case WatchSignalState.error:
        _states[signal] = WatchSignalState.error;
        final safeCode = _normalizeErrorCode(errorCode);
        _emitTerminal(
          kind: WatchEventKind.error,
          now: currentNow,
          observedSignals: const <WatchSignal>[],
          errorCode: safeCode,
        );
        return;
      case WatchSignalState.active:
        _states[signal] = WatchSignalState.active;
        _quietSince[signal] = null;
      case WatchSignalState.changed:
        _changeCount++;
        _hasInitialChange = true;
        if (digestChanged) {
          _digestChanged = true;
        }
        _states[signal] = WatchSignalState.changed;
        _quietSince[signal] = currentNow;
      case WatchSignalState.idle:
        if (_states[signal] != WatchSignalState.settled) {
          _states[signal] = WatchSignalState.idle;
          _quietSince[signal] ??= currentNow;
        }
      case WatchSignalState.settled:
        _states[signal] = WatchSignalState.settled;
        _quietSince[signal] ??= currentNow;
    }

    if (!_terminated) {
      _evaluateAndReschedule(currentNow);
    }
  }

  /// Disposes timers without emitting a terminal event.
  void dispose() {
    _terminated = true;
    _convergenceTimer?.cancel();
    _convergenceTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
  }

  void _promoteQuietSignals(DateTime now, {WatchSignal? exclude}) {
    final quiescenceDuration = Duration(seconds: quiescenceSeconds);
    for (final sig in activeSignals) {
      if (sig == exclude) continue;
      final state = _states[sig];
      final quietSince = _quietSince[sig];
      if ((state == WatchSignalState.idle ||
              state == WatchSignalState.changed) &&
          quietSince != null &&
          now.difference(quietSince) >= quiescenceDuration) {
        _states[sig] = WatchSignalState.settled;
      }
    }
  }

  void _evaluateAndReschedule(DateTime now) {
    if (!_started || _terminated) return;

    _promoteQuietSignals(now);

    final startedAt = _startedAt!;
    final minWaitDeadline = startedAt.add(Duration(seconds: minWaitSeconds));
    final minWaitOk = !now.isBefore(minWaitDeadline);

    if (mode == WatchMode.uiChange) {
      if (_changeCount > 0 && minWaitOk) {
        _emitTerminal(
          kind: WatchEventKind.changed,
          now: now,
          observedSignals: const <WatchSignal>[WatchSignal.uiChange],
        );
        return;
      }
      _convergenceTimer?.cancel();
      _convergenceTimer = null;
      if (_changeCount > 0 && !minWaitOk) {
        final delay = minWaitDeadline.difference(now);
        _convergenceTimer = _timerFactory(
          delay <= Duration.zero ? Duration.zero : delay,
          _onConvergenceTick,
        );
      }
      return;
    }

    final allSettled = activeSignals.every(
      (s) => _states[s] == WatchSignalState.settled,
    );
    final initialChangeOk = !requireInitialChange || _hasInitialChange;

    if (allSettled && initialChangeOk && minWaitOk) {
      _emitTerminal(
        kind: WatchEventKind.settled,
        now: now,
        observedSignals: List<WatchSignal>.unmodifiable(activeSignals),
      );
      return;
    }

    _convergenceTimer?.cancel();
    _convergenceTimer = null;

    DateTime? nextDue;
    final quiescenceDuration = Duration(seconds: quiescenceSeconds);
    for (final sig in activeSignals) {
      final state = _states[sig];
      final quietSince = _quietSince[sig];
      if ((state == WatchSignalState.idle ||
              state == WatchSignalState.changed) &&
          quietSince != null) {
        final candidate = quietSince.add(quiescenceDuration);
        if (nextDue == null || candidate.isBefore(nextDue)) {
          nextDue = candidate;
        }
      }
    }

    if (allSettled && initialChangeOk && !minWaitOk) {
      if (nextDue == null || minWaitDeadline.isBefore(nextDue)) {
        nextDue = minWaitDeadline;
      }
    }

    if (nextDue != null) {
      final delay = nextDue.difference(now);
      _convergenceTimer = _timerFactory(
        delay <= Duration.zero ? Duration.zero : delay,
        _onConvergenceTick,
      );
    }
  }

  void _onConvergenceTick() {
    if (!_started || _terminated) return;
    _evaluateAndReschedule(_now().toUtc());
  }

  void _onMaxWaitFired() {
    if (!_started || _terminated) return;
    final now = _now().toUtc();
    // Boundary tie-break: if settled/changed criteria are met at exact maxWait,
    // settle/change wins over timeout.
    _evaluateAndReschedule(now);
    if (_terminated) return;

    _emitTerminal(
      kind: WatchEventKind.timeout,
      now: now,
      observedSignals: List<WatchSignal>.unmodifiable(_observedOrder.take(3)),
    );
  }

  void _emitTerminal({
    required WatchEventKind kind,
    required DateTime now,
    required List<WatchSignal> observedSignals,
    String? errorCode,
  }) {
    if (_terminated) return;
    _terminated = true;
    _convergenceTimer?.cancel();
    _convergenceTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;

    final elapsed = max(0, now.difference(_startedAt!).inSeconds);
    onTerminalEvent(
      WatchEventParams(
        watchId: watchId,
        jobId: jobId,
        kind: kind,
        observedSignals: observedSignals,
        elapsedSeconds: elapsed,
        changeCount: _changeCount,
        digestChanged: _digestChanged,
        occurredAt: now,
        errorCode: errorCode,
      ),
    );
  }

  static String _normalizeErrorCode(String? raw) {
    if (raw != null &&
        !raw.contains('\n') &&
        !raw.contains('\r') &&
        _shortErrorCodePattern.hasMatch(raw)) {
      return raw;
    }
    return 'os_error';
  }
}

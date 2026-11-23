import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _ScheduledTask implements WatchCancellableTimer {
  _ScheduledTask({required this.fireAt, required this.onFire});

  final DateTime fireAt;
  final void Function() onFire;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() {
    cancelled = true;
  }
}

class _FakeWatchScheduler {
  _FakeWatchScheduler(DateTime initial) : _now = initial.toUtc();

  DateTime _now;
  final List<_ScheduledTask> _tasks = <_ScheduledTask>[];

  DateTime now() => _now;

  WatchCancellableTimer createTimer(Duration delay, void Function() onFire) {
    final task = _ScheduledTask(fireAt: _now.add(delay), onFire: onFire);
    _tasks.add(task);
    return task;
  }

  int get activeTimerCount => _tasks.where((t) => t.isActive).length;

  void advance(Duration delta) {
    final target = _now.add(delta);
    while (true) {
      _ScheduledTask? next;
      for (final t in _tasks) {
        if (!t.isActive) continue;
        if (t.fireAt.isAfter(target)) continue;
        if (next == null || t.fireAt.isBefore(next.fireAt)) {
          next = t;
        }
      }
      if (next == null) break;
      _now = next.fireAt;
      next.fired = true;
      next.onFire();
    }
    _now = target;
  }
}

void main() {
  const watchId = 'f1111111-1111-4111-8111-111111111111';
  const jobId = 'a2222222-2222-4222-8222-222222222222';

  group('WatchConvergence', () {
    test(
      'single signal settles after quiescence and respects flapping reset',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.uiQuiescence,
          activeSignals: const <WatchSignal>[WatchSignal.uiQuiescence],
          quiescenceSeconds: 4,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        );

        convergence.start();
        expect(convergence.isActive, isTrue);

        scheduler.advance(const Duration(seconds: 2));
        convergence.reportSignal(
          WatchSignal.uiQuiescence,
          WatchSignalState.active,
        );
        scheduler.advance(const Duration(seconds: 3));
        expect(events, isEmpty);

        convergence.reportSignal(
          WatchSignal.uiQuiescence,
          WatchSignalState.changed,
          digestChanged: true,
        );
        // Repeated idle reports must NOT reset the quietSince timestamp from changed.
        scheduler.advance(const Duration(seconds: 2));
        convergence.reportSignal(
          WatchSignal.uiQuiescence,
          WatchSignalState.idle,
        );
        expect(events, isEmpty);

        scheduler.advance(const Duration(seconds: 2));
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(
          events.single.observedSignals,
          equals(const <WatchSignal>[WatchSignal.uiQuiescence]),
        );
        expect(events.single.elapsedSeconds, equals(9));
        expect(events.single.changeCount, equals(1));
        expect(events.single.digestChanged, isTrue);
        expect(convergence.isTerminated, isTrue);
        expect(scheduler.activeTimerCount, equals(0));
      },
    );

    test(
      'composite mode requires simultaneous quiescence across all active signals',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.composite,
          activeSignals: const <WatchSignal>[
            WatchSignal.uiQuiescence,
            WatchSignal.processIdle,
          ],
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 60,
          requireInitialChange: false,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        );

        convergence.start();

        // At t=1s processIdle becomes active while uiQuiescence stays idle.
        scheduler.advance(const Duration(seconds: 1));
        convergence.reportSignal(
          WatchSignal.processIdle,
          WatchSignalState.active,
        );

        // At t=5s uiQuiescence promotes to settled, but processIdle is still active!
        scheduler.advance(const Duration(seconds: 4));
        expect(events, isEmpty);
        expect(
          convergence.signalStates[WatchSignal.uiQuiescence],
          equals(WatchSignalState.settled),
        );
        expect(
          convergence.signalStates[WatchSignal.processIdle],
          equals(WatchSignalState.active),
        );

        // At t=6s processIdle goes idle, starting its 5s quiescence window (due t=11s).
        scheduler.advance(const Duration(seconds: 1));
        convergence.reportSignal(
          WatchSignal.processIdle,
          WatchSignalState.idle,
        );

        // At t=9s uiQuiescence flickers changed -> resets its 5s quiescence (due t=14s).
        scheduler.advance(const Duration(seconds: 3));
        convergence.reportSignal(
          WatchSignal.uiQuiescence,
          WatchSignalState.changed,
          digestChanged: true,
        );

        // At t=11s processIdle settles, but uiQuiescence is not quiet for 5s yet.
        scheduler.advance(const Duration(seconds: 2));
        expect(events, isEmpty);

        // At t=14s both signals are simultaneously settled.
        scheduler.advance(const Duration(seconds: 3));
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(
          events.single.observedSignals,
          equals(const <WatchSignal>[
            WatchSignal.uiQuiescence,
            WatchSignal.processIdle,
          ]),
        );
        expect(events.single.elapsedSeconds, equals(14));
        expect(scheduler.activeTimerCount, equals(0));
      },
    );

    test(
      'minWaitSeconds > quiescenceSeconds holds settlement until minWaitSeconds',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.fsQuiescence,
          activeSignals: const <WatchSignal>[WatchSignal.fsQuiescence],
          quiescenceSeconds: 3,
          minWaitSeconds: 10,
          maxWaitSeconds: 60,
          requireInitialChange: false,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        );

        convergence.start();

        // Quiet at t=3s, must NOT settle before t=10s.
        scheduler.advance(const Duration(seconds: 5));
        expect(events, isEmpty);

        // Flicker at t=8s -> quiet deadline becomes t=11s (> minWait 10s).
        scheduler.advance(const Duration(seconds: 3));
        convergence.reportSignal(
          WatchSignal.fsQuiescence,
          WatchSignalState.changed,
        );
        scheduler.advance(const Duration(seconds: 2));
        expect(events, isEmpty);

        scheduler.advance(const Duration(seconds: 1));
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(events.single.elapsedSeconds, equals(11));
      },
    );

    test(
      'requireInitialChange blocks settlement until changed and times out at maxWaitSeconds',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.cdpIdle,
          activeSignals: const <WatchSignal>[WatchSignal.cdpIdle],
          quiescenceSeconds: 2,
          minWaitSeconds: 0,
          maxWaitSeconds: 10,
          requireInitialChange: true,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        );

        convergence.start();
        scheduler.advance(const Duration(seconds: 9));
        expect(events, isEmpty);

        scheduler.advance(const Duration(seconds: 1));
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.timeout));
        expect(events.single.changeCount, equals(0));
        expect(events.single.elapsedSeconds, equals(10));
        expect(scheduler.activeTimerCount, equals(0));
      },
    );

    test(
      'boundary tie-break prefers settled over timeout when quiescenceSeconds == maxWaitSeconds',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.timer,
          activeSignals: const <WatchSignal>[WatchSignal.timer],
          quiescenceSeconds: 5,
          minWaitSeconds: 5,
          maxWaitSeconds: 5,
          requireInitialChange: false,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        );

        convergence.start();
        scheduler.advance(const Duration(seconds: 5));

        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(events.single.elapsedSeconds, equals(5));
        expect(scheduler.activeTimerCount, equals(0));
      },
    );

    test(
      'target_lost and error terminate immediately, cancel timers, and normalize errorCode',
      () {
        final scheduler1 = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final lostEvents = <WatchEventParams>[];
        final conv1 = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.uiQuiescence,
          activeSignals: const <WatchSignal>[WatchSignal.uiQuiescence],
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          onTerminalEvent: lostEvents.add,
          now: scheduler1.now,
          timerFactory: scheduler1.createTimer,
        )..start();

        scheduler1.advance(const Duration(seconds: 2));
        conv1.reportSignal(WatchSignal.uiQuiescence, WatchSignalState.lost);
        conv1.reportSignal(WatchSignal.uiQuiescence, WatchSignalState.settled);
        expect(lostEvents, hasLength(1));
        expect(lostEvents.single.kind, equals(WatchEventKind.targetLost));
        expect(lostEvents.single.observedSignals, isEmpty);
        expect(scheduler1.activeTimerCount, equals(0));

        final scheduler2 = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final errEvents = <WatchEventParams>[];
        final conv2 = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.uiQuiescence,
          activeSignals: const <WatchSignal>[WatchSignal.uiQuiescence],
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          onTerminalEvent: errEvents.add,
          now: scheduler2.now,
          timerFactory: scheduler2.createTimer,
        )..start();

        scheduler2.advance(const Duration(seconds: 1));
        conv2.reportSignal(
          WatchSignal.uiQuiescence,
          WatchSignalState.error,
          errorCode: 'Invalid\nCode',
        );
        expect(errEvents, hasLength(1));
        expect(errEvents.single.kind, equals(WatchEventKind.error));
        expect(errEvents.single.errorCode, equals('os_error'));
        expect(scheduler2.activeTimerCount, equals(0));
      },
    );

    test(
      'ui_change mode respects minWaitSeconds and emits changed immediately once met',
      () {
        final scheduler = _FakeWatchScheduler(DateTime.utc(2026, 11, 22, 12));
        final events = <WatchEventParams>[];

        final convergence = WatchConvergence(
          watchId: watchId,
          jobId: jobId,
          mode: WatchMode.uiChange,
          activeSignals: const <WatchSignal>[WatchSignal.uiChange],
          quiescenceSeconds: 10,
          minWaitSeconds: 3,
          maxWaitSeconds: 30,
          requireInitialChange: true,
          onTerminalEvent: events.add,
          now: scheduler.now,
          timerFactory: scheduler.createTimer,
        )..start();

        scheduler.advance(const Duration(seconds: 1));
        convergence.reportSignal(
          WatchSignal.uiChange,
          WatchSignalState.changed,
          digestChanged: true,
        );
        expect(events, isEmpty);

        scheduler.advance(const Duration(seconds: 2));
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.changed));
        expect(
          events.single.observedSignals,
          equals(const <WatchSignal>[WatchSignal.uiChange]),
        );
        expect(events.single.changeCount, equals(1));
        expect(events.single.digestChanged, isTrue);
      },
    );
  });
}

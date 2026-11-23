import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _FakeSubscription implements WatchSignalSubscription {
  _FakeSubscription({
    this.eventDriven = true,
    this.fallbackUsed = false,
    this.throwOnDispose = false,
    this.throwSyncOnDispose = false,
  });

  @override
  final bool eventDriven;

  @override
  final bool fallbackUsed;

  final bool throwOnDispose;
  final bool throwSyncOnDispose;

  bool disposed = false;

  @override
  Future<void> dispose() {
    disposed = true;
    if (throwSyncOnDispose) {
      throw StateError('simulated sync dispose failure');
    }
    if (throwOnDispose) {
      return Future<void>.error(StateError('simulated async dispose failure'));
    }
    return Future<void>.value();
  }
}

class _FakeDriver implements WatchSignalDriver {
  _FakeDriver({
    required this.supportedSignals,
    this.throwOnStart,
    this.startCompleter,
    this.startCompleters,
    this.eventDriven = true,
    this.fallbackUsed = false,
    this.throwOnDispose = false,
    this.throwSyncOnDispose = false,
  });

  @override
  final Set<WatchSignal> supportedSignals;

  WatchDriverException? throwOnStart;
  Completer<void>? startCompleter;
  final List<Completer<void>?>? startCompleters;
  final bool eventDriven;
  final bool fallbackUsed;
  final bool throwOnDispose;
  final bool throwSyncOnDispose;
  int _startIndex = 0;

  final List<bool> recordedReleaseFocus = <bool>[];
  final List<_FakeSubscription> subscriptions = <_FakeSubscription>[];
  final List<void Function(WatchSignalUpdate)> callbackHistory =
      <void Function(WatchSignalUpdate)>[];
  final Map<String, void Function(WatchSignalUpdate)> callbacks =
      <String, void Function(WatchSignalUpdate)>{};

  @override
  Future<WatchSignalSubscription> startSignal({
    required String watchId,
    required WatchSignal signal,
    required WatchTarget target,
    required bool releaseFocus,
    required void Function(WatchSignalUpdate update) onUpdate,
  }) async {
    recordedReleaseFocus.add(releaseFocus);
    final idx = _startIndex++;
    final gate = (startCompleters != null && idx < startCompleters!.length)
        ? startCompleters![idx]
        : startCompleter;
    if (gate != null) {
      await gate.future;
    }
    if (throwOnStart != null) {
      throw throwOnStart!;
    }
    final sub = _FakeSubscription(
      eventDriven: eventDriven,
      fallbackUsed: fallbackUsed,
      throwOnDispose: throwOnDispose,
      throwSyncOnDispose: throwSyncOnDispose,
    );
    subscriptions.add(sub);
    callbackHistory.add(onUpdate);
    callbacks['$watchId:${signal.wire}'] = onUpdate;
    return sub;
  }
}

class _VirtualTimer implements WatchCancellableTimer {
  _VirtualTimer(this.fireAt, this.onFire);

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

class _VirtualClock {
  _VirtualClock(DateTime start) : _now = start.toUtc();
  DateTime _now;
  final List<_VirtualTimer> timers = <_VirtualTimer>[];

  DateTime now() => _now;

  WatchCancellableTimer createTimer(Duration delay, void Function() onFire) {
    final timer = _VirtualTimer(_now.add(delay), onFire);
    timers.add(timer);
    return timer;
  }

  void advance(Duration delta) {
    final target = _now.add(delta);
    while (true) {
      _VirtualTimer? next;
      for (final t in timers) {
        if (!t.isActive || t.fireAt.isAfter(target)) continue;
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
  const jobId = 'a2222222-2222-4222-8222-222222222222';
  String watchUuid(int n) =>
      'f1111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';

  late ContentFreeLogger logger;
  late EmergencyStopController stopController;

  setUp(() {
    logger = ContentFreeLogger();
    stopController = EmergencyStopController(logger: logger);
  });

  tearDown(() async {
    await stopController.dispose();
  });

  group('LocalWatchSentinel', () {
    test(
      'timer mode settles natively and emits content-free WatchEventParams',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final outcome = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 2,
            minWaitSeconds: 0,
            maxWaitSeconds: 5,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(outcome.accepted, isTrue);
        expect(
          outcome.activeSignals,
          equals(const <WatchSignal>[WatchSignal.timer]),
        );
        expect(sentinel.activeWatchCount, equals(1));

        clock.advance(const Duration(seconds: 2));
        await Future<void>.delayed(Duration.zero);

        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(sentinel.activeWatchCount, equals(0));
      },
    );

    test(
      'enforces max 4 concurrent watches and frees slot on terminal or cancel',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        for (var i = 1; i <= 4; i++) {
          final ok = await sentinel.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(i),
              jobId: jobId,
              mode: WatchMode.timer,
              target: const WatchTarget(),
              quiescenceSeconds: 10,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          expect(ok.accepted, isTrue);
        }
        expect(sentinel.activeWatchCount, equals(4));

        final fifth = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(5),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 10,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(fifth.accepted, isFalse);
        expect(fifth.errorCode, equals(WatchRejectErrorCode.watchLimitReached));

        // Duplicate active watchId replaces cleanly without double-counting.
        final duplicate = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 10,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(duplicate.accepted, isTrue);
        expect(sentinel.activeWatchCount, equals(4));

        // Cancelling 1 watch frees a slot.
        final cancelled = await sentinel.cancelWatches(
          WatchCancelParams(
            watchId: watchUuid(2),
            reason: WatchCancelReason.ownerCancel,
          ),
        );
        expect(cancelled, equals(1));
        expect(sentinel.activeWatchCount, equals(3));

        final fifthRetry = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(5),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 10,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(fifthRetry.accepted, isTrue);
      },
    );

    test(
      'fails closed on missing driver, hard-denied appId, and missing target fields',
      () async {
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
        );
        addTearDown(sentinel.dispose);

        // Missing driver -> watch_unsupported (Rule H1)
        final unsupported = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.uiQuiescence,
            target: const WatchTarget(pid: 123, appId: 'editor'),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(unsupported.accepted, isFalse);
        expect(
          unsupported.errorCode,
          equals(WatchRejectErrorCode.watchUnsupported),
        );

        // Hard-denied appId -> policy_blocked
        final blocked = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(2),
            jobId: jobId,
            mode: WatchMode.uiQuiescence,
            target: const WatchTarget(pid: 123, appId: 'terminal'),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(blocked.accepted, isFalse);
        expect(blocked.errorCode, equals(WatchRejectErrorCode.policyBlocked));

        // Missing workspaceAlias on fs_quiescence -> workspace_not_found (Rule H3)
        final missingWorkspace = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(3),
            jobId: jobId,
            mode: WatchMode.fsQuiescence,
            target: const WatchTarget(),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(missingWorkspace.accepted, isFalse);
        expect(
          missingWorkspace.errorCode,
          equals(WatchRejectErrorCode.workspaceNotFound),
        );

        // Missing tabId on cdp_idle -> target_not_found
        final missingTab = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(4),
            jobId: jobId,
            mode: WatchMode.cdpIdle,
            target: const WatchTarget(appId: 'browser'),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(missingTab.accepted, isFalse);
        expect(
          missingTab.errorCode,
          equals(WatchRejectErrorCode.targetNotFound),
        );
      },
    );

    test(
      'rolls back partial composite driver startup and handles concurrent cancel',
      () async {
        final uiDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
        );
        final procDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
          throwOnStart: const WatchDriverException(
            errorCode: 'needs_permission',
          ),
        );

        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[uiDriver, procDriver],
        );
        addTearDown(sentinel.dispose);

        final outcome = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.composite,
            signals: const <WatchSignal>[
              WatchSignal.uiQuiescence,
              WatchSignal.processIdle,
            ],
            target: const WatchTarget(pid: 42, windowId: 7, appId: 'editor'),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );

        expect(outcome.accepted, isFalse);
        expect(outcome.errorCode, equals(WatchRejectErrorCode.needsPermission));
        expect(uiDriver.subscriptions.single.disposed, isTrue);
        expect(uiDriver.recordedReleaseFocus, equals(const <bool>[true]));
        expect(sentinel.activeWatchCount, equals(0));

        // Async startup aborted mid-flight by watchCancel
        final gate = Completer<void>();
        final slowDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.cdpIdle},
          startCompleter: gate,
        );
        final sentinel2 = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[slowDriver],
        );
        addTearDown(sentinel2.dispose);

        final pendingFuture = sentinel2.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(9),
            jobId: jobId,
            mode: WatchMode.cdpIdle,
            target: const WatchTarget(tabId: 'tab_1'),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );

        final cancelCount = await sentinel2.cancelWatches(
          WatchCancelParams(
            watchId: watchUuid(9),
            reason: WatchCancelReason.ownerCancel,
          ),
        );
        expect(cancelCount, equals(1));
        gate.complete();

        final lateOutcome = await pendingFuture;
        expect(lateOutcome.accepted, isFalse);
        expect(slowDriver.subscriptions.single.disposed, isTrue);
      },
    );

    test(
      'E-Stop synchronously cancels watches, disposes drivers, and blocks new watches until resumed',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final driver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final reg = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.uiQuiescence,
            target: const WatchTarget(pid: 100, windowId: 200),
            quiescenceSeconds: 3,
            minWaitSeconds: 0,
            maxWaitSeconds: 20,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(reg.accepted, isTrue);
        expect(sentinel.activeWatchCount, equals(1));

        stopController.triggerStop(StopReason.ownerHost);
        expect(sentinel.activeWatchCount, equals(0));
        expect(driver.subscriptions.single.disposed, isTrue);

        clock.advance(const Duration(seconds: 30));
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);

        final whileStopped = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(2),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 2,
            minWaitSeconds: 0,
            maxWaitSeconds: 5,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(whileStopped.accepted, isFalse);
        expect(whileStopped.errorCode, equals(WatchRejectErrorCode.stopped));

        stopController.resumeFromTray();
        final afterResume = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(3),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 2,
            minWaitSeconds: 0,
            maxWaitSeconds: 5,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(afterResume.accepted, isTrue);

        // Content-free logging invariant (Consent U5)
        for (final entry in logger.entries) {
          expect(
            entry.fields.keys.every(
              ContentFreeLogger.allowedFieldKeys.contains,
            ),
            isTrue,
          );
        }
      },
    );

    test(
      'propagates fallbackUsed/eventDriven flags and replays buffered startup updates',
      () async {
        final gate = Completer<void>();
        final driver1 = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
          eventDriven: false,
          fallbackUsed: true,
        );
        final driver2 = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
          startCompleter: gate,
        );

        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver1, driver2],
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final regFuture = sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.composite,
            signals: const <WatchSignal>[
              WatchSignal.uiQuiescence,
              WatchSignal.processIdle,
            ],
            target: const WatchTarget(pid: 123, windowId: 456),
            quiescenceSeconds: 5,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );

        await Future<void>.delayed(Duration.zero);
        final sig1Emit = driver1.callbacks['${watchUuid(1)}:ui_quiescence']!;
        sig1Emit(
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );

        gate.complete();
        final outcome = await regFuture;
        expect(outcome.accepted, isTrue);
        expect(outcome.eventDriven, isFalse);
        expect(outcome.fallbackUsed, isTrue);

        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.targetLost));
        expect(sentinel.activeWatchCount, equals(0));
      },
    );

    test(
      'concurrent duplicate watchId async replacement keeps pending tracking, capacity cap, buffered updates, and ignores stale callbacks',
      () async {
        // Part 1: Call 1 aborts and wakes -> Call 2 stays tracked for cancelWatches
        // and Call 1 late onUpdate is ignored.
        final gate1 = Completer<void>();
        final gate2 = Completer<void>();
        final driver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
          startCompleters: <Completer<void>?>[gate1, gate2],
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final eventSub = sentinel.events.listen(events.add);
        addTearDown(eventSub.cancel);

        WatchRegisterParams makeUiParams(String wId) => WatchRegisterParams(
          watchId: wId,
          jobId: jobId,
          mode: WatchMode.uiQuiescence,
          target: const WatchTarget(pid: 100, windowId: 200),
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          releaseFocus: true,
        );

        final call1 = sentinel.registerWatch(makeUiParams(watchUuid(1)));
        final call2 = sentinel.registerWatch(makeUiParams(watchUuid(1)));

        gate1.complete();
        final out1 = await call1;
        expect(out1.accepted, isFalse);
        expect(driver.subscriptions[0].disposed, isTrue);

        // Late callback from Call 1 must be ignored.
        driver.callbackHistory[0](
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );

        // Call 2 must still be in _pendingRegistrations so cancelWatches finds it.
        final cancelled = await sentinel.cancelWatches(
          WatchCancelParams(
            watchId: watchUuid(1),
            reason: WatchCancelReason.ownerCancel,
          ),
        );
        expect(cancelled, equals(1));

        gate2.complete();
        final out2 = await call2;
        expect(out2.accepted, isFalse);
        expect(driver.subscriptions[1].disposed, isTrue);
        expect(sentinel.activeWatchCount, equals(0));
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);

        // Part 2: Capacity limit (4) is never exceeded when Call 1 aborts while
        // Call 2 is still pending.
        final gateA = Completer<void>();
        final gateB = Completer<void>();
        final capDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
          startCompleters: <Completer<void>?>[gateA, gateB],
        );
        final sentinelCap = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[capDriver],
        );
        addTearDown(sentinelCap.dispose);

        final capEvents = <WatchEventParams>[];
        final capSub = sentinelCap.events.listen(capEvents.add);
        addTearDown(capSub.cancel);

        final capCall1 = sentinelCap.registerWatch(makeUiParams(watchUuid(1)));
        final capCall2 = sentinelCap.registerWatch(makeUiParams(watchUuid(1)));

        gateA.complete();
        expect((await capCall1).accepted, isFalse);

        for (var i = 2; i <= 4; i++) {
          final r = await sentinelCap.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(i),
              jobId: jobId,
              mode: WatchMode.timer,
              target: const WatchTarget(),
              quiescenceSeconds: 10,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          expect(r.accepted, isTrue);
        }

        // 5th distinct watch must be rejected because Call 2 occupies slot 1.
        final fifth = await sentinelCap.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(5),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 10,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(fifth.accepted, isFalse);
        expect(fifth.errorCode, equals(WatchRejectErrorCode.watchLimitReached));

        gateB.complete();
        expect((await capCall2).accepted, isTrue);
        expect(sentinelCap.activeWatchCount, equals(4));

        // Call 1's late update must not terminate Call 2.
        capDriver.callbackHistory[0](
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(capEvents, isEmpty);
        expect(sentinelCap.activeWatchCount, equals(4));

        // Part 3: Call 2 buffered updates are preserved after Call 1 aborts.
        final gate1Ui = Completer<void>();
        final gate2Proc = Completer<void>();
        final uiDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
          startCompleters: <Completer<void>?>[gate1Ui, null],
        );
        final procDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
          startCompleters: <Completer<void>?>[gate2Proc],
        );
        final sentinelBuf = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[uiDriver, procDriver],
        );
        addTearDown(sentinelBuf.dispose);

        final bufEvents = <WatchEventParams>[];
        final bufSub = sentinelBuf.events.listen(bufEvents.add);
        addTearDown(bufSub.cancel);

        final compParams = WatchRegisterParams(
          watchId: watchUuid(6),
          jobId: jobId,
          mode: WatchMode.composite,
          signals: const <WatchSignal>[
            WatchSignal.uiQuiescence,
            WatchSignal.processIdle,
          ],
          target: const WatchTarget(pid: 123, windowId: 456),
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          releaseFocus: true,
        );

        final bufCall1 = sentinelBuf.registerWatch(compParams);
        final bufCall2 = sentinelBuf.registerWatch(compParams);

        await Future<void>.delayed(Duration.zero);
        gate1Ui.complete();
        expect((await bufCall1).accepted, isFalse);

        // Emit stale update from Call 1's uiQuiescence callback (index 1, which
        // finished after gate1Ui completed) -> must be ignored.
        uiDriver.callbackHistory[1](
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.error,
            errorCode: 'stale_call_1',
          ),
        );

        // Emit lost from Call 2's uiQuiescence driver (index 0, which started
        // immediately before awaiting gate2Proc) -> must be buffered & replayed.
        uiDriver.callbackHistory[0](
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );

        gate2Proc.complete();
        expect((await bufCall2).accepted, isTrue);

        await Future<void>.delayed(Duration.zero);
        expect(bufEvents, hasLength(1));
        expect(bufEvents.single.kind, equals(WatchEventKind.targetLost));
        expect(sentinelBuf.activeWatchCount, equals(0));
      },
    );

    test(
      'duplicate watchId with unsupported mode fails closed without killing active watch',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final initial = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.timer,
            target: const WatchTarget(),
            quiescenceSeconds: 3,
            minWaitSeconds: 0,
            maxWaitSeconds: 10,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(initial.accepted, isTrue);
        expect(sentinel.activeWatchCount, equals(1));

        // Duplicate watchId requesting unsupported driver must fail closed and
        // leave the existing active watch intact.
        final unsupportedDup = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(1),
            jobId: jobId,
            mode: WatchMode.uiQuiescence,
            target: const WatchTarget(pid: 123, appId: 'editor'),
            quiescenceSeconds: 3,
            minWaitSeconds: 0,
            maxWaitSeconds: 10,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(unsupportedDup.accepted, isFalse);
        expect(
          unsupportedDup.errorCode,
          equals(WatchRejectErrorCode.watchUnsupported),
        );
        expect(sentinel.activeWatchCount, equals(1));

        clock.advance(const Duration(seconds: 3));
        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(sentinel.activeWatchCount, equals(0));
      },
    );

    test(
      'throwing subscription dispose produces zero unhandled zone errors across E-Stop, terminal, replacement, and aborted startup',
      () async {
        final zoneErrors = <Object>[];

        await runZonedGuarded(
          () async {
            final startGate = Completer<void>();
            final driver = _FakeDriver(
              supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
              startCompleters: <Completer<void>?>[null, null, null, startGate],
              throwOnDispose: true,
            );
            final syncThrowDriver = _FakeDriver(
              supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
              throwSyncOnDispose: true,
            );

            final sentinel = LocalWatchSentinel(
              stopController: stopController,
              logger: logger,
              drivers: <WatchSignalDriver>[driver, syncThrowDriver],
            );

            WatchRegisterParams makeComp(int n) => WatchRegisterParams(
              watchId: watchUuid(n),
              jobId: jobId,
              mode: WatchMode.composite,
              signals: const <WatchSignal>[
                WatchSignal.uiQuiescence,
                WatchSignal.processIdle,
              ],
              target: const WatchTarget(pid: 123, windowId: 456),
              quiescenceSeconds: 5,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            );

            WatchRegisterParams makeUi(int n) => WatchRegisterParams(
              watchId: watchUuid(n),
              jobId: jobId,
              mode: WatchMode.uiQuiescence,
              target: const WatchTarget(pid: 123, windowId: 456),
              quiescenceSeconds: 5,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            );

            // 1. Active replacement with async + sync throwing dispose()
            expect(
              (await sentinel.registerWatch(makeComp(1))).accepted,
              isTrue,
            );
            expect(
              (await sentinel.registerWatch(makeComp(1))).accepted,
              isTrue,
            );

            // 2. Terminal convergence with throwing dispose()
            driver.callbacks['${watchUuid(1)}:ui_quiescence']!(
              const WatchSignalUpdate(
                signal: WatchSignal.uiQuiescence,
                state: WatchSignalState.lost,
              ),
            );
            await Future<void>.delayed(Duration.zero);
            expect(sentinel.activeWatchCount, equals(0));

            // 3. E-Stop on active watch with throwing dispose()
            expect((await sentinel.registerWatch(makeUi(2))).accepted, isTrue);
            stopController.triggerStop(StopReason.ownerHost);
            await Future<void>.delayed(Duration.zero);
            expect(sentinel.activeWatchCount, equals(0));

            // 4. Aborted startup under E-Stop with throwing sub.dispose()
            // must preserve WatchRejectErrorCode.stopped (not watchUnsupported).
            stopController.resumeFromTray();
            final pendingFuture = sentinel.registerWatch(makeUi(3));
            stopController.triggerStop(StopReason.ownerHost);
            startGate.complete();
            final stoppedOutcome = await pendingFuture;
            expect(stoppedOutcome.accepted, isFalse);
            expect(
              stoppedOutcome.errorCode,
              equals(WatchRejectErrorCode.stopped),
            );

            await sentinel.dispose();
            await Future<void>.delayed(Duration.zero);
          },
          (error, stack) {
            zoneErrors.add(error);
          },
        );

        expect(zoneErrors, isEmpty);
      },
    );

    test(
      'microtask buffered replay preserves ordering with early live updates and is cancelled cleanly before microtask runs',
      () async {
        final gate1 = Completer<void>();
        final gate2 = Completer<void>();
        final uiDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
        );
        final procDriver = _FakeDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
          startCompleters: <Completer<void>?>[gate1, gate2],
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[uiDriver, procDriver],
        );
        addTearDown(sentinel.dispose);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        WatchRegisterParams makeComp(int n) => WatchRegisterParams(
          watchId: watchUuid(n),
          jobId: jobId,
          mode: WatchMode.composite,
          signals: const <WatchSignal>[
            WatchSignal.uiQuiescence,
            WatchSignal.processIdle,
          ],
          target: const WatchTarget(pid: 123, windowId: 456),
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 30,
          requireInitialChange: false,
          releaseFocus: true,
        );

        // Case 1: Early live update arriving before microtask runs is ordered
        // behind startup buffered updates.
        final reg1 = sentinel.registerWatch(makeComp(1));
        await Future<void>.delayed(Duration.zero);
        uiDriver.callbacks['${watchUuid(1)}:ui_quiescence']!(
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.changed,
            digestChanged: true,
          ),
        );
        gate1.complete();
        final out1 = await reg1;
        expect(out1.accepted, isTrue);

        // Emit lost before the replay microtask drains.
        uiDriver.callbacks['${watchUuid(1)}:ui_quiescence']!(
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );

        await Future<void>.delayed(Duration.zero);
        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.targetLost));
        expect(events.single.changeCount, equals(1));
        expect(events.single.digestChanged, isTrue);

        // Case 2: Cancelled before replay microtask runs -> emits nothing.
        events.clear();
        final reg2 = sentinel.registerWatch(makeComp(2));
        await Future<void>.delayed(Duration.zero);
        uiDriver.callbacks['${watchUuid(2)}:ui_quiescence']!(
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );
        gate2.complete();
        final out2 = await reg2;
        expect(out2.accepted, isTrue);

        final cancelled = await sentinel.cancelWatches(
          WatchCancelParams(
            watchId: watchUuid(2),
            reason: WatchCancelReason.ownerCancel,
          ),
        );
        expect(cancelled, equals(1));

        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
      },
    );
  });
}

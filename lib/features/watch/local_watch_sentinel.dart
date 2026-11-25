import 'dart:async';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Result of handling an inbound `xuna/watchRegister` request.
class WatchRegisterOutcome {
  const WatchRegisterOutcome.accepted({
    required this.watchId,
    required this.activeSignals,
    required this.eventDriven,
    required this.fallbackUsed,
  }) : accepted = true,
       errorCode = null;

  const WatchRegisterOutcome.rejected({
    required this.watchId,
    required WatchRejectErrorCode this.errorCode,
  }) : accepted = false,
       activeSignals = const <WatchSignal>[],
       eventDriven = false,
       fallbackUsed = false;

  final bool accepted;
  final String watchId;
  final List<WatchSignal> activeSignals;
  final bool eventDriven;
  final bool fallbackUsed;
  final WatchRejectErrorCode? errorCode;

  XtpResponse toXtpResponse(Object requestId) => accepted
      ? XtpResponse.watchRegisterAccepted(
          id: requestId,
          watchId: watchId,
          activeSignals: activeSignals,
          eventDriven: eventDriven,
          fallbackUsed: fallbackUsed,
        )
      : XtpResponse.watchRegisterRejected(
          id: requestId,
          watchId: watchId,
          errorCode: errorCode!,
        );
}

class _PendingRegistration {
  _PendingRegistration({required this.watchId, required this.jobId});

  final String watchId;
  final String jobId;
  bool aborted = false;
  bool replayingBuffered = false;
  final List<WatchSignalUpdate> bufferedUpdates = <WatchSignalUpdate>[];
}

class _ActiveWatchEntry {
  _ActiveWatchEntry({
    required this.watchId,
    required this.jobId,
    required this.token,
    required this.convergence,
    required this.subscriptions,
  });

  final String watchId;
  final String jobId;
  final _PendingRegistration token;
  final WatchConvergence convergence;
  final List<WatchSignalSubscription> subscriptions;
}

/// Host-side local sentinel managing up to [maxConcurrentWatches] concurrent
/// event-driven watches (`XUNA_ASYNC_WATCH_AND_WAKE.md` §5.1).
class LocalWatchSentinel {
  LocalWatchSentinel({
    required EmergencyStopController stopController,
    required ContentFreeLogger logger,
    List<WatchSignalDriver> drivers = const <WatchSignalDriver>[],
    WatchNow? now,
    WatchTimerFactory? timerFactory,
  }) : _stopController = stopController,
       _logger = logger,
       _now = now,
       _timerFactory = timerFactory {
    for (final driver in drivers) {
      for (final signal in driver.supportedSignals) {
        _drivers.putIfAbsent(signal, () => driver);
      }
    }
    _stopController.addCancelListener(_onEmergencyStop);
  }

  static const int maxConcurrentWatches = 4;

  final EmergencyStopController _stopController;
  final ContentFreeLogger _logger;
  final WatchNow? _now;
  final WatchTimerFactory? _timerFactory;
  final Map<WatchSignal, WatchSignalDriver> _drivers =
      <WatchSignal, WatchSignalDriver>{};

  final Map<String, _PendingRegistration> _pendingRegistrations =
      <String, _PendingRegistration>{};
  final Map<String, _ActiveWatchEntry> _activeWatches =
      <String, _ActiveWatchEntry>{};

  final StreamController<WatchEventParams> _eventsController =
      StreamController<WatchEventParams>.broadcast();
  final StreamController<int> _activeCountController =
      StreamController<int>.broadcast();

  bool _disposed = false;

  Stream<WatchEventParams> get events => _eventsController.stream;
  Stream<int> get activeCountChanges => _activeCountController.stream;
  int get activeWatchCount => _activeWatches.length;

  /// Registers and starts an async watch, failing closed on E-Stop, policy
  /// blocks, missing targets, capacity limit, or unsupported drivers.
  Future<WatchRegisterOutcome> registerWatch(WatchRegisterParams params) async {
    try {
      params.validate();
    } on FormatException {
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: WatchRejectErrorCode.invalidArgs,
      );
    }

    if (_disposed || _stopController.isStopped) {
      _logger.warning('watch.rejected', const <String, Object?>{
        'status': 'rejected',
        'errorCode': 'stopped',
      });
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: WatchRejectErrorCode.stopped,
      );
    }

    final appId = params.target.appId;
    if (appId != null && isHardDeniedAppOrProcess(appId)) {
      _logger.warning('watch.rejected', const <String, Object?>{
        'status': 'rejected',
        'errorCode': 'policy_blocked',
      });
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: WatchRejectErrorCode.policyBlocked,
      );
    }

    final requiredSignals = _resolveSignals(params);

    final targetError = _validateTargetRequirements(
      requiredSignals,
      params.target,
    );
    if (targetError != null) {
      _logger.warning('watch.rejected', <String, Object?>{
        'status': 'rejected',
        'errorCode': targetError.wire,
      });
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: targetError,
      );
    }

    // Validate capacity and driver availability before tearing down any existing
    // pending or active watch with the same watchId.
    final alreadyTracked =
        _pendingRegistrations.containsKey(params.watchId) ||
        _activeWatches.containsKey(params.watchId);
    if (!alreadyTracked &&
        _activeWatches.length + _pendingRegistrations.length >=
            maxConcurrentWatches) {
      _logger.warning('watch.rejected', const <String, Object?>{
        'status': 'rejected',
        'errorCode': 'watch_limit_reached',
      });
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: WatchRejectErrorCode.watchLimitReached,
      );
    }

    if (params.mode != WatchMode.timer) {
      for (final sig in requiredSignals) {
        if (!_drivers.containsKey(sig)) {
          _logger.warning('watch.rejected', const <String, Object?>{
            'status': 'rejected',
            'errorCode': 'watch_unsupported',
          });
          return WatchRegisterOutcome.rejected(
            watchId: params.watchId,
            errorCode: WatchRejectErrorCode.watchUnsupported,
          );
        }
      }
    }

    // Reconnect rehydration safety: replacing a duplicate watchId is idempotent.
    final priorPending = _pendingRegistrations.remove(params.watchId);
    if (priorPending != null) {
      priorPending.aborted = true;
    }
    final priorActive = _activeWatches.remove(params.watchId);
    if (priorActive != null) {
      priorActive.convergence.dispose();
      unawaited(_disposeAll(priorActive.subscriptions));
      _emitActiveCount();
    }

    final pending = _PendingRegistration(
      watchId: params.watchId,
      jobId: params.jobId,
    );
    _pendingRegistrations[params.watchId] = pending;

    final startedSubscriptions = <WatchSignalSubscription>[];
    var eventDriven = true;
    var fallbackUsed = false;

    if (params.mode != WatchMode.timer) {
      try {
        for (final sig in requiredSignals) {
          final driver = _drivers[sig]!;
          final sub = await driver.startSignal(
            watchId: params.watchId,
            signal: sig,
            target: params.target,
            releaseFocus: params.releaseFocus,
            onUpdate: (update) {
              if (pending.aborted) return;
              _onDriverUpdate(params.watchId, pending, update);
            },
          );
          if (pending.aborted || _disposed || _stopController.isStopped) {
            await _disposeAll(<WatchSignalSubscription>[
              sub,
              ...startedSubscriptions,
            ]);
            _removePendingIfSame(params.watchId, pending);
            final code = _stopController.isStopped
                ? WatchRejectErrorCode.stopped
                : WatchRejectErrorCode.invalidArgs;
            return WatchRegisterOutcome.rejected(
              watchId: params.watchId,
              errorCode: code,
            );
          }
          startedSubscriptions.add(sub);
          eventDriven = eventDriven && sub.eventDriven;
          fallbackUsed = fallbackUsed || sub.fallbackUsed;
        }
      } on WatchDriverException catch (error) {
        await _disposeAll(startedSubscriptions);
        _removePendingIfSame(params.watchId, pending);
        final mapped = _mapRejectCode(error.errorCode);
        _logger.warning('watch.rejected', <String, Object?>{
          'status': 'rejected',
          'errorCode': mapped.wire,
        });
        return WatchRegisterOutcome.rejected(
          watchId: params.watchId,
          errorCode: mapped,
        );
      } catch (_) {
        await _disposeAll(startedSubscriptions);
        _removePendingIfSame(params.watchId, pending);
        _logger.warning('watch.rejected', const <String, Object?>{
          'status': 'rejected',
          'errorCode': 'watch_unsupported',
        });
        return WatchRegisterOutcome.rejected(
          watchId: params.watchId,
          errorCode: WatchRejectErrorCode.watchUnsupported,
        );
      }
    }

    if (pending.aborted || _disposed || _stopController.isStopped) {
      await _disposeAll(startedSubscriptions);
      _removePendingIfSame(params.watchId, pending);
      final code = _stopController.isStopped
          ? WatchRejectErrorCode.stopped
          : WatchRejectErrorCode.invalidArgs;
      return WatchRegisterOutcome.rejected(
        watchId: params.watchId,
        errorCode: code,
      );
    }

    _removePendingIfSame(params.watchId, pending);

    final convergence = WatchConvergence(
      watchId: params.watchId,
      jobId: params.jobId,
      mode: params.mode,
      activeSignals: requiredSignals,
      quiescenceSeconds: params.quiescenceSeconds,
      minWaitSeconds: params.minWaitSeconds,
      maxWaitSeconds: params.maxWaitSeconds,
      requireInitialChange: params.requireInitialChange,
      onTerminalEvent: (event) =>
          _onConvergenceTerminal(params.watchId, pending, event),
      now: _now,
      timerFactory: _timerFactory,
    );

    final entry = _ActiveWatchEntry(
      watchId: params.watchId,
      jobId: params.jobId,
      token: pending,
      convergence: convergence,
      subscriptions: startedSubscriptions,
    );
    _activeWatches[params.watchId] = entry;
    _emitActiveCount();

    _logger.info('watch.registered', <String, Object?>{
      'status': 'accepted',
      'reason': params.mode.wire,
    });

    convergence.start();
    if (pending.bufferedUpdates.isNotEmpty) {
      pending.replayingBuffered = true;
      scheduleMicrotask(() {
        try {
          var index = 0;
          while (index < pending.bufferedUpdates.length) {
            if (_disposed ||
                !identical(_activeWatches[params.watchId], entry) ||
                convergence.isTerminated) {
              break;
            }
            final buffered = pending.bufferedUpdates[index++];
            convergence.reportSignal(
              buffered.signal,
              buffered.state,
              digestChanged: buffered.digestChanged,
              errorCode: buffered.errorCode,
            );
          }
        } finally {
          pending.replayingBuffered = false;
          pending.bufferedUpdates.clear();
        }
      });
    }

    return WatchRegisterOutcome.accepted(
      watchId: params.watchId,
      activeSignals: requiredSignals,
      eventDriven: eventDriven,
      fallbackUsed: fallbackUsed,
    );
  }

  /// Cancels active and pending watches matching [params].
  Future<int> cancelWatches(WatchCancelParams params) async {
    var cancelledCount = 0;

    final pendingKeys = _pendingRegistrations.keys
        .where((id) {
          final entry = _pendingRegistrations[id]!;
          return (params.watchId == null || entry.watchId == params.watchId) &&
              (params.jobId == null || entry.jobId == params.jobId);
        })
        .toList(growable: false);

    for (final id in pendingKeys) {
      final pending = _pendingRegistrations.remove(id);
      if (pending != null) {
        pending.aborted = true;
        cancelledCount++;
      }
    }

    final activeKeys = _activeWatches.keys
        .where((id) {
          final entry = _activeWatches[id]!;
          return (params.watchId == null || entry.watchId == params.watchId) &&
              (params.jobId == null || entry.jobId == params.jobId);
        })
        .toList(growable: false);

    final toDispose = <WatchSignalSubscription>[];
    for (final id in activeKeys) {
      final entry = _activeWatches.remove(id);
      if (entry != null) {
        entry.convergence.dispose();
        toDispose.addAll(entry.subscriptions);
        cancelledCount++;
      }
    }

    await _disposeAll(toDispose);
    if (activeKeys.isNotEmpty) {
      _emitActiveCount();
    }

    _logger.info('watch.cancelled', <String, Object?>{
      'reason': params.reason.wire,
    });
    return cancelledCount;
  }

  /// Immediately cancels all active and pending watches (e.g. session revoked).
  Future<int> cancelAll({String reason = 'revoked'}) async {
    var cancelledCount = 0;

    for (final pending in _pendingRegistrations.values) {
      pending.aborted = true;
      cancelledCount++;
    }
    _pendingRegistrations.clear();

    final entries = _activeWatches.values.toList(growable: false);
    _activeWatches.clear();

    final toDispose = <WatchSignalSubscription>[];
    for (final entry in entries) {
      entry.convergence.dispose();
      toDispose.addAll(entry.subscriptions);
      cancelledCount++;
    }

    await _disposeAll(toDispose);
    _emitActiveCount();

    if (cancelledCount > 0) {
      _logger.info('watch.cancelled_all', <String, Object?>{'reason': reason});
    }
    return cancelledCount;
  }

  void _removePendingIfSame(String watchId, _PendingRegistration pending) {
    if (identical(_pendingRegistrations[watchId], pending)) {
      _pendingRegistrations.remove(watchId);
    }
  }

  void _onDriverUpdate(
    String watchId,
    _PendingRegistration token,
    WatchSignalUpdate update,
  ) {
    if (_disposed || token.aborted) return;
    final pending = _pendingRegistrations[watchId];
    if (identical(pending, token)) {
      pending!.bufferedUpdates.add(update);
      return;
    }
    final active = _activeWatches[watchId];
    if (active == null || !identical(active.token, token)) return;
    if (token.replayingBuffered) {
      token.bufferedUpdates.add(update);
      return;
    }
    active.convergence.reportSignal(
      update.signal,
      update.state,
      digestChanged: update.digestChanged,
      errorCode: update.errorCode,
    );
  }

  void _onConvergenceTerminal(
    String watchId,
    _PendingRegistration token,
    WatchEventParams event,
  ) {
    final current = _activeWatches[watchId];
    if (current == null || !identical(current.token, token)) return;
    _activeWatches.remove(watchId);
    unawaited(_disposeAll(current.subscriptions));
    _emitActiveCount();

    _logger.info('watch.event_emitted', <String, Object?>{
      'reason': event.kind.wire,
      'durationMs': event.elapsedSeconds * 1000,
      if (event.errorCode != null) 'errorCode': event.errorCode,
    });

    if (!_eventsController.isClosed) {
      _eventsController.add(event);
    }
  }

  void _onEmergencyStop(StopReason reason) {
    for (final pending in _pendingRegistrations.values) {
      pending.aborted = true;
    }
    _pendingRegistrations.clear();

    final entries = _activeWatches.values.toList(growable: false);
    _activeWatches.clear();
    final toDispose = <WatchSignalSubscription>[];
    for (final entry in entries) {
      entry.convergence.dispose();
      toDispose.addAll(entry.subscriptions);
    }
    unawaited(_disposeAll(toDispose));
    _emitActiveCount();
    _logger.warning('watch.estop_cancelled', <String, Object?>{
      'reason': reason.wire,
    });
  }

  void _emitActiveCount() {
    if (!_activeCountController.isClosed) {
      _activeCountController.add(_activeWatches.length);
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _stopController.removeCancelListener(_onEmergencyStop);

    for (final pending in _pendingRegistrations.values) {
      pending.aborted = true;
    }
    _pendingRegistrations.clear();

    final entries = _activeWatches.values.toList(growable: false);
    _activeWatches.clear();

    final toDispose = <WatchSignalSubscription>[];
    for (final entry in entries) {
      entry.convergence.dispose();
      toDispose.addAll(entry.subscriptions);
    }
    await _disposeAll(toDispose);
    _emitActiveCount();

    await _eventsController.close();
    await _activeCountController.close();
  }

  static List<WatchSignal> _resolveSignals(WatchRegisterParams params) =>
      switch (params.mode) {
        WatchMode.composite => params.signals!,
        WatchMode.uiQuiescence => const <WatchSignal>[WatchSignal.uiQuiescence],
        WatchMode.uiChange => const <WatchSignal>[WatchSignal.uiChange],
        WatchMode.processIdle => const <WatchSignal>[WatchSignal.processIdle],
        WatchMode.fsQuiescence => const <WatchSignal>[WatchSignal.fsQuiescence],
        WatchMode.cdpIdle => const <WatchSignal>[WatchSignal.cdpIdle],
        WatchMode.timer => const <WatchSignal>[WatchSignal.timer],
        WatchMode.protocolAsync => const <WatchSignal>[
          WatchSignal.protocolAsync,
        ],
        WatchMode.execAsync => const <WatchSignal>[WatchSignal.execAsync],
      };

  static WatchRejectErrorCode? _validateTargetRequirements(
    List<WatchSignal> signals,
    WatchTarget target,
  ) {
    for (final sig in signals) {
      switch (sig) {
        case WatchSignal.uiQuiescence:
        case WatchSignal.uiChange:
          if (target.pid == null &&
              target.windowId == null &&
              target.appId == null) {
            return WatchRejectErrorCode.targetNotFound;
          }
        case WatchSignal.processIdle:
          if (target.pid == null) {
            return WatchRejectErrorCode.targetNotFound;
          }
        case WatchSignal.fsQuiescence:
          if (target.workspaceAlias == null || target.workspaceAlias!.isEmpty) {
            return WatchRejectErrorCode.workspaceNotFound;
          }
        case WatchSignal.cdpIdle:
          if (target.tabId == null || target.tabId!.isEmpty) {
            return WatchRejectErrorCode.targetNotFound;
          }
        case WatchSignal.protocolAsync:
          if (target.mcpServerId == null || target.protocolTaskId == null) {
            return WatchRejectErrorCode.targetNotFound;
          }
        case WatchSignal.execAsync:
          if (target.execTaskId == null) {
            return WatchRejectErrorCode.targetNotFound;
          }
        case WatchSignal.timer:
          break;
      }
    }
    return null;
  }

  static WatchRejectErrorCode _mapRejectCode(String wire) {
    try {
      return WatchRejectErrorCode.fromWire(wire);
    } on FormatException {
      return WatchRejectErrorCode.watchUnsupported;
    }
  }

  static Future<void> _disposeAll(List<WatchSignalSubscription> subs) async {
    for (final sub in subs) {
      try {
        await sub.dispose();
      } catch (_) {
        // Best-effort cleanup during rollback/cancel.
      }
    }
  }
}

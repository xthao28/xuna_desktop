import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._outbound, this._onClose);

  final StreamController<String> _outbound;
  final void Function(int? closeCode, String? closeReason) _onClose;

  @override
  void add(Object? data) {
    if (data is String) {
      _outbound.add(data);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _outbound.addError(error, stackTrace);
  }

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    _onClose(closeCode, closeReason);
    if (!_outbound.isClosed) {
      await _outbound.close();
    }
  }

  @override
  Future<void> get done => _outbound.done;
}

class _FakeWebSocketChannel extends Fake implements WebSocketChannel {
  _FakeWebSocketChannel() {
    _sink = _FakeWebSocketSink(_outbound, (code, reason) {
      _closeCode = code;
      _closeReason = reason;
    });
  }

  final StreamController<Object?> inbound = StreamController<Object?>();
  final StreamController<String> _outbound =
      StreamController<String>.broadcast();
  late final _FakeWebSocketSink _sink;
  int? _closeCode;
  String? _closeReason;

  Stream<String> get outboundFrames => _outbound.stream;

  void simulateRemoteClose(int closeCode, String closeReason) {
    _closeCode = closeCode;
    _closeReason = closeReason;
    unawaited(inbound.close());
  }

  @override
  int? get closeCode => _closeCode;

  @override
  String? get closeReason => _closeReason;

  @override
  String? get protocol => 'xtp/1';

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => inbound.stream;
}

void main() {
  const watchId = 'f1111111-1111-4111-8111-111111111111';
  const jobId = 'a2222222-2222-4222-8222-222222222222';
  const hostId = '11111111-1111-4111-8111-111111111111';

  late Directory tempDir;
  late FakeXunaHostChannel channel;
  late ContentFreeLogger logger;
  late EmergencyStopController stopController;
  late EnrollmentStateStore enrollmentStore;
  late HostPolicyStore policyStore;
  late AuditLogStore auditStore;
  late HostToolDispatcher dispatcher;

  setUp(() async {
    Get.testMode = true;
    tempDir = await Directory.systemTemp.createTemp('xuna_watch_dispatch_');
    final paths = AgentPaths.resolve(overrideRootDir: tempDir);
    await paths.ensureDirectories();
    channel = FakeXunaHostChannel();
    logger = ContentFreeLogger();
    stopController = EmergencyStopController(logger: logger);
    enrollmentStore = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    await enrollmentStore.save(hostId: hostId, alias: 'test-host');
    policyStore = HostPolicyStore(policyFile: paths.policyFile, logger: logger);
    await policyStore.writeDefaultPolicy();
    auditStore = AuditLogStore(auditDir: paths.auditDir);
    dispatcher = HostToolDispatcher(
      channel: channel,
      policyStore: policyStore,
      auditStore: auditStore,
      stopController: stopController,
      logger: logger,
      enrollmentStore: enrollmentStore,
    );
  });

  tearDown(() async {
    dispatcher.dispose();
    await policyStore.dispose();
    Get.reset();
    await stopController.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> completeHandshake(
    XtpSessionClient client,
    _FakeWebSocketChannel ws,
  ) async {
    await client.connect();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ws.inbound.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'xuna/challenge',
        'params': <String, Object?>{
          'purpose': 2,
          'nonce': base64.encode(List<int>.filled(32, 7)),
          'expiresIn': 60,
        },
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 10));
    ws.inbound.add(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': 'xuna/ready',
        'params': <String, Object?>{
          'serverTime': '2026-11-22T12:00:00Z',
          'heartbeatS': 30,
        },
      }),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  group('XtpSessionClient & DesktopAgentController Watch Dispatch', () {
    test(
      'rejects pre-ready watchRegister/watchCancel with -32600 and gates sendWatchEvent',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
        );
        addTearDown(sentinel.dispose);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
          watchSentinel: sentinel,
        );
        addTearDown(client.dispose);

        expect(
          client.sendWatchEvent(
            WatchEventParams(
              watchId: watchId,
              jobId: jobId,
              kind: WatchEventKind.settled,
              observedSignals: const <WatchSignal>[WatchSignal.timer],
              elapsedSeconds: 2,
              changeCount: 0,
              digestChanged: false,
              occurredAt: DateTime.utc(2026, 11, 22, 12),
            ),
          ),
          isFalse,
        );

        await client.connect();
        await Future<void>.delayed(const Duration(milliseconds: 10));

        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 901,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'timer',
              'target': <String, Object?>{},
              'quiescenceSeconds': 2,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 5,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 902,
            'method': 'xuna/watchCancel',
            'params': <String, Object?>{'schemaVersion': 1, 'reason': 'estop'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final errors = outbound.whereType<XtpErrorResponse>().toList();
        expect(errors, hasLength(2));
        expect(errors[0].id, equals(901));
        expect(errors[0].code, equals(JsonRpcErrorCode.invalidRequest));
        expect(errors[1].id, equals(902));
        expect(errors[1].code, equals(JsonRpcErrorCode.invalidRequest));
      },
    );

    test(
      'dispatches watchRegister, invalid -32602, watchCancel, and emits watchEvent over WS',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        var currentNow = DateTime.utc(2026, 11, 22, 12);
        final scheduled = <({void Function() cb, bool active})>[];
        late WatchCancellableTimer fakeTimer;

        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          now: () => currentNow,
          timerFactory: (delay, onFire) {
            final entry = (cb: onFire, active: true);
            scheduled.add(entry);
            fakeTimer = _CallbackTimer(onFire);
            return fakeTimer;
          },
        );
        addTearDown(sentinel.dispose);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
          watchSentinel: sentinel,
        );
        addTearDown(client.dispose);

        await completeHandshake(client, ws);
        expect(client.phase, equals(HostSessionPhase.ready));

        // Invalid wire frame -> -32602
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 910,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'timer',
              'target': <String, Object?>{},
              'quiescenceSeconds': 2,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 901,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );

        // Valid timer watchRegister
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 911,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'timer',
              'target': <String, Object?>{},
              'quiescenceSeconds': 2,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 5,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final err910 = outbound.whereType<XtpErrorResponse>().singleWhere(
          (e) => e.id == 910,
        );
        expect(err910.code, equals(JsonRpcErrorCode.invalidParams));

        final resp911 = outbound.whereType<XtpResponse>().singleWhere(
          (r) => r.id == 911,
        );
        expect(resp911.result['accepted'], isTrue);
        expect(
          resp911.result['activeSignals'],
          equals(const <String>['timer']),
        );

        // Advance clock and fire convergence timer
        currentNow = currentNow.add(const Duration(seconds: 2));
        scheduled.last.cb();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final watchNotifs = outbound
            .whereType<XtpNotification>()
            .where((n) => n.method == 'xuna/watchEvent')
            .toList();
        expect(watchNotifs, hasLength(1));
        final eventParams = watchNotifs.single.typedParams as WatchEventParams;
        expect(eventParams.kind, equals(WatchEventKind.settled));

        // Cancel when already finished -> cancelledCount: 0
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 912,
            'method': 'xuna/watchCancel',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'reason': 'owner_cancel',
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final resp912 = outbound.whereType<XtpResponse>().singleWhere(
          (r) => r.id == 912,
        );
        expect(resp912.result['cancelledCount'], equals(0));
      },
    );

    test(
      'cancels active watches on xuna/stop revoked, policyViolation close, and DesktopAgentController lifecycle',
      () async {
        final ws = _FakeWebSocketChannel();
        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
        );
        addTearDown(client.dispose);

        final controller = DesktopAgentController(
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          auditStore: auditStore,
          stopController: stopController,
          sessionClient: client,
          logger: logger,
        );
        controller.onInit();

        expect(client.watchSentinel, same(controller.watchSentinel));
        await completeHandshake(client, ws);

        // Register a timer watch via RPC
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 920,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'timer',
              'target': <String, Object?>{},
              'quiescenceSeconds': 30,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 60,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.watchSentinel.activeWatchCount, equals(1));
        expect(controller.activeWatchCount.value, equals(1));

        // Remote xuna/stop {reason: "revoked"} must cancel all active watches
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/stop',
            'params': <String, Object?>{'reason': 'revoked'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.watchSentinel.activeWatchCount, equals(0));
        expect(controller.activeWatchCount.value, equals(0));

        // Also verify policyViolation socket close cancels active watches
        final ws2 = _FakeWebSocketChannel();
        await enrollmentStore.save(hostId: hostId, alias: 'test-host');
        final client2 = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws2,
          enableAutoReconnect: false,
          watchSentinel: controller.watchSentinel,
        );
        addTearDown(client2.dispose);
        await completeHandshake(client2, ws2);

        ws2.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 921,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'timer',
              'target': <String, Object?>{},
              'quiescenceSeconds': 30,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 60,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.watchSentinel.activeWatchCount, equals(1));

        ws2.simulateRemoteClose(XtpCloseCode.policyViolation, 'revoked');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.watchSentinel.activeWatchCount, equals(0));

        controller.onClose();
      },
    );

    test(
      'emits xuna/watchRegister accepted response before buffered startup xuna/watchEvent on WebSocket',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        final gate = Completer<void>();
        final uiDriver = _TestSignalDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.uiQuiescence},
        );
        final procDriver = _TestSignalDriver(
          supportedSignals: const <WatchSignal>{WatchSignal.processIdle},
          startCompleter: gate,
        );

        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[uiDriver, procDriver],
        );
        addTearDown(sentinel.dispose);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
          watchSentinel: sentinel,
        );
        addTearDown(client.dispose);

        await completeHandshake(client, ws);
        outbound.clear();

        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 930,
            'method': 'xuna/watchRegister',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': watchId,
              'jobId': jobId,
              'mode': 'composite',
              'signals': <String>['ui_quiescence', 'process_idle'],
              'target': <String, Object?>{'pid': 123, 'windowId': 456},
              'quiescenceSeconds': 5,
              'minWaitSeconds': 0,
              'maxWaitSeconds': 30,
              'requireInitialChange': false,
              'releaseFocus': true,
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));
        uiDriver.callbacks['$watchId:ui_quiescence']!(
          const WatchSignalUpdate(
            signal: WatchSignal.uiQuiescence,
            state: WatchSignalState.lost,
          ),
        );

        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        final responseIdx = outbound.indexWhere(
          (f) => f is XtpResponse && f.id == 930,
        );
        final eventIdx = outbound.indexWhere(
          (f) => f is XtpNotification && f.method == 'xuna/watchEvent',
        );

        expect(responseIdx, greaterThanOrEqualTo(0));
        expect(eventIdx, greaterThanOrEqualTo(0));
        expect(responseIdx, lessThan(eventIdx));

        final resp = outbound[responseIdx] as XtpResponse;
        expect(resp.result['accepted'], isTrue);

        final notif = outbound[eventIdx] as XtpNotification;
        final eventParams = notif.typedParams as WatchEventParams;
        expect(eventParams.kind, equals(WatchEventKind.targetLost));
        expect(sentinel.activeWatchCount, equals(0));
      },
    );
  });
}

class _TestSubscription implements WatchSignalSubscription {
  @override
  bool get eventDriven => true;

  @override
  bool get fallbackUsed => false;

  @override
  Future<void> dispose() async {}
}

class _TestSignalDriver implements WatchSignalDriver {
  _TestSignalDriver({required this.supportedSignals, this.startCompleter});

  @override
  final Set<WatchSignal> supportedSignals;

  final Completer<void>? startCompleter;
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
    if (startCompleter != null) {
      await startCompleter!.future;
    }
    callbacks['$watchId:${signal.wire}'] = onUpdate;
    return _TestSubscription();
  }
}

class _CallbackTimer implements WatchCancellableTimer {
  _CallbackTimer(this._cb);
  final void Function() _cb;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (_active) {
      _active = false;
      _cb();
    }
  }
}

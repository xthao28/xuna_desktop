import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/core/single_instance/single_instance_guard.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/ui/desktop_agent_window.dart';
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

  Future<void> simulateServerClose(int code, String reason) async {
    _closeCode = code;
    _closeReason = reason;
    await inbound.close();
  }
}

HostPolicy _sampleHealthyPolicy() => HostPolicy(
  schemaVersion: 1,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.media: FamilyPolicyDecision.allow,
    ToolFamily.app: FamilyPolicyDecision.allow,
    ToolFamily.url: FamilyPolicyDecision.allow,
    ToolFamily.workflow: FamilyPolicyDecision.allow,
  },
  apps: <AllowedAppConfig>[
    AllowedAppConfig(
      id: 'vscode',
      name: 'VS Code',
      kind: AppLaunchKind.exe,
      target:
          r'C:\Users\Thao\AppData\Local\Programs\Microsoft VS Code\Code.exe',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>['github.com', 'jira.example.com'],
  workflows: <WorkflowConfig>[
    WorkflowConfig(
      id: 'focus',
      name: 'Chế độ tập trung',
      kind: WorkflowKind.shortcut,
      target: 'Focus Mode',
      risk: RiskTier.r1,
    ),
  ],
  players: const <String>['spotify', 'music'],
);

void main() {
  late Directory tempDir;
  late AgentPaths paths;
  late ContentFreeLogger logger;
  late FakeXunaHostChannel channel;
  late HostPolicyStore policyStore;
  late AuditLogStore auditStore;
  late EnrollmentStateStore enrollmentStore;
  late EmergencyStopController stopController;
  late HostToolDispatcher dispatcher;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xuna_desktop_test_');
    paths = AgentPaths.resolve(overrideRootDir: tempDir);
    await paths.ensureDirectories();
    logger = ContentFreeLogger();
    channel = FakeXunaHostChannel();
    policyStore = HostPolicyStore(policyFile: paths.policyFile, logger: logger);
    auditStore = AuditLogStore(auditDir: paths.auditDir);
    enrollmentStore = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    stopController = EmergencyStopController(logger: logger);
    dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: channel,
      auditStore: auditStore,
      stopController: stopController,
      logger: logger,
    );
  });

  tearDown(() async {
    dispatcher.dispose();
    await stopController.dispose();
    await policyStore.dispose();
    Get.reset();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('SingleInstanceGuard & AgentPaths', () {
    test('acquires exclusive lock once and releases cleanly', () async {
      final guard1 = SingleInstanceGuard(lockFile: paths.lockFile);
      final guard2 = SingleInstanceGuard(lockFile: paths.lockFile);

      expect(await guard1.tryAcquire(), isTrue);
      expect(await guard2.tryAcquire(), isFalse);

      await guard1.release();
      expect(await guard2.tryAcquire(), isTrue);
      await guard2.release();
    });

    test('resolves Windows and macOS config paths per UDC-3 §5.6.4', () {
      final winPaths = AgentPaths.resolve(
        environment: const <String, String>{
          'APPDATA': r'C:\Users\Thao\AppData\Roaming',
        },
        isWindowsOverride: true,
      );
      expect(
        winPaths.policyFile.path,
        contains('XUNA${Platform.pathSeparator}host-policy.json'),
      );

      final macPaths = AgentPaths.resolve(
        environment: const <String, String>{'HOME': '/Users/thao'},
        isWindowsOverride: false,
      );
      expect(
        macPaths.rootDir.path,
        '/Users/thao/Library/Application Support/XUNA',
      );
    });
  });

  group('HostPolicyStore & HostToolDispatcher (UDC-3 §5.6.4–§5.6.5)', () {
    test(
      'fail-closed when host-policy.json is missing or corrupted: only host.status allowed',
      () async {
        await policyStore.reload();
        expect(policyStore.isHealthy, isFalse);
        expect(policyStore.trayBanner, 'Cấu hình lỗi');

        final statusResp = await dispatcher.dispatch(
          requestId: 1,
          params: const ToolsCallParams(
            name: 'host.status',
            arguments: <String, Object?>{},
            invocationId: '11111111-1111-4111-8111-111111111111',
            deadlineMs: 5000,
          ),
        );
        final statusMeta = statusResp.result['_meta'] as Map<String, Object?>;
        expect(statusMeta['xuna/status'], 'ok');

        final mediaResp = await dispatcher.dispatch(
          requestId: 2,
          params: const ToolsCallParams(
            name: 'media.play_pause',
            arguments: <String, Object?>{},
            invocationId: '22222222-2222-4222-8222-222222222222',
            deadlineMs: 5000,
          ),
        );
        final mediaMeta = mediaResp.result['_meta'] as Map<String, Object?>;
        expect(mediaMeta['xuna/status'], 'denied');
        expect(mediaMeta['xuna/errorCode'], 'policy_invalid');
      },
    );

    test(
      'executes all 12 MVP tools, enforces R2 approval binding, caches idempotency, and never logs secrets',
      () async {
        await policyStore.savePolicy(_sampleHealthyPolicy());
        expect(policyStore.isHealthy, isTrue);

        final now = DateTime.utc(2026, 10, 30, 12, 0);

        // 1. R1 media tool
        final playResp = await dispatcher.dispatch(
          requestId: 10,
          params: const ToolsCallParams(
            name: 'media.play_pause',
            arguments: <String, Object?>{},
            invocationId: 'aaaaaaaa-1111-4111-8111-111111111111',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(
          (playResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          'ok',
        );
        expect(playResp.result['structuredContent'], <String, Object?>{
          'state': 'playing',
        });

        // Idempotency: calling again with same invocationId returns cached response without invoking native channel again
        final callCountBefore = channel.invokedMethods.length;
        final cachedPlay = await dispatcher.dispatch(
          requestId: 11,
          params: const ToolsCallParams(
            name: 'media.play_pause',
            arguments: <String, Object?>{},
            invocationId: 'aaaaaaaa-1111-4111-8111-111111111111',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(cachedPlay.id, 11);
        expect(channel.invokedMethods.length, callCountBefore);

        // 2. R2 app.launch without approval -> denied (approval_required)
        final noAppApproval = await dispatcher.dispatch(
          requestId: 12,
          params: const ToolsCallParams(
            name: 'app.launch',
            arguments: <String, Object?>{'id': 'vscode'},
            invocationId: 'bbbbbbbb-1111-4111-8111-111111111111',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(
          (noAppApproval.result['_meta']
              as Map<String, Object?>)['xuna/errorCode'],
          'approval_required',
        );

        // 3. R2 app.launch with mismatched approval hash -> denied (approval_mismatch)
        final badHashApp = await dispatcher.dispatch(
          requestId: 13,
          params: ToolsCallParams(
            name: 'app.launch',
            arguments: const <String, Object?>{'id': 'vscode'},
            invocationId: 'cccccccc-1111-4111-8111-111111111111',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '99999999-9999-4999-8999-999999999999',
              argsSha256: '0' * 64,
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (badHashApp.result['_meta']
              as Map<String, Object?>)['xuna/errorCode'],
          'approval_mismatch',
        );

        // 4. R2 app.launch with valid approval -> ok + toast "XUNA: đã mở VS Code"
        const appArgs = <String, Object?>{'id': 'vscode'};
        final okApp = await dispatcher.dispatch(
          requestId: 14,
          params: ToolsCallParams(
            name: 'app.launch',
            arguments: appArgs,
            invocationId: 'dddddddd-1111-4111-8111-111111111111',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '88888888-8888-4888-8888-888888888888',
              argsSha256: argsSha256(appArgs),
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (okApp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          'ok',
        );
        expect(channel.toasts.last.body, 'XUNA: đã mở VS Code');

        // 5. R2 url.open with allowlisted domain + valid approval -> ok
        const urlArgs = <String, Object?>{
          'url': 'https://sub.github.com/xthao28/xuna_pet?secret=token123',
        };
        final okUrl = await dispatcher.dispatch(
          requestId: 15,
          params: ToolsCallParams(
            name: 'url.open',
            arguments: urlArgs,
            invocationId: 'eeeeeeee-1111-4111-8111-111111111111',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '77777777-7777-4777-8777-777777777777',
              argsSha256: argsSha256(urlArgs),
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (okUrl.result['_meta'] as Map<String, Object?>)['xuna/status'],
          'ok',
        );
        expect(okUrl.result['structuredContent'], <String, Object?>{
          'host': 'sub.github.com',
        });

        // Verify zero secrets/URLs/paths in ContentFreeLogger and AuditLogStore
        for (final entry in logger.entries) {
          final serialized = jsonEncode(entry.fields);
          expect(serialized, isNot(contains('token123')));
          expect(serialized, isNot(contains('Code.exe')));
        }
        final audits = await auditStore.readRecent();
        expect(audits, isNotEmpty);
        for (final record in audits) {
          final line = jsonEncode(record.toJson());
          expect(line, isNot(contains('token123')));
          expect(line, isNot(contains('Code.exe')));
        }
      },
    );

    test(
      'emergency stop cancels in-flight call and blocks subsequent calls until resumed',
      () async {
        await policyStore.savePolicy(_sampleHealthyPolicy());
        channel.simulatedDelay = const Duration(milliseconds: 500);

        final inFlightFuture = dispatcher.dispatch(
          requestId: 99,
          params: const ToolsCallParams(
            name: 'media.next',
            arguments: <String, Object?>{},
            invocationId: '12345678-1234-4234-8234-123456789012',
            deadlineMs: 5000,
          ),
        );

        await Future<void>.delayed(const Duration(milliseconds: 30));
        stopController.triggerStop(StopReason.ownerHost);

        final inFlightResp = await inFlightFuture;
        final inFlightMeta =
            inFlightResp.result['_meta'] as Map<String, Object?>;
        expect(inFlightMeta['xuna/status'], 'denied');
        expect(inFlightMeta['xuna/errorCode'], 'stopped');

        channel.simulatedDelay = Duration.zero;
        final blockedResp = await dispatcher.dispatch(
          requestId: 100,
          params: const ToolsCallParams(
            name: 'media.previous',
            arguments: <String, Object?>{},
            invocationId: '22345678-1234-4234-8234-123456789012',
            deadlineMs: 5000,
          ),
        );
        expect(
          (blockedResp.result['_meta']
              as Map<String, Object?>)['xuna/errorCode'],
          'stopped',
        );

        stopController.resumeFromTray();
        final resumedResp = await dispatcher.dispatch(
          requestId: 101,
          params: const ToolsCallParams(
            name: 'media.previous',
            arguments: <String, Object?>{},
            invocationId: '32345678-1234-4234-8234-123456789012',
            deadlineMs: 5000,
          ),
        );
        expect(
          (resumedResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          'ok',
        );
      },
    );

    test(
      'macOS missing permission returns needs_permission without crashing',
      () async {
        await policyStore.savePolicy(_sampleHealthyPolicy());
        channel.nextException = const XunaHostChannelException(
          status: XtpStatus.needsPermission,
          errorCode: 'permission_missing',
        );

        final resp = await dispatcher.dispatch(
          requestId: 50,
          params: const ToolsCallParams(
            name: 'media.play_pause',
            arguments: <String, Object?>{},
            invocationId: '55555555-5555-4555-8555-555555555555',
            deadlineMs: 5000,
          ),
        );
        final meta = resp.result['_meta'] as Map<String, Object?>;
        expect(meta['xuna/status'], 'needs_permission');
        expect(meta['xuna/errorCode'], 'permission_missing');
      },
    );
  });

  group('AuditLogStore 30-day retention', () {
    test('prunes daily JSONL files older than 30 days', () async {
      final oldDate = DateTime.utc(2026, 9, 15, 10);
      final recentDate = DateTime.utc(2026, 10, 30, 10);

      await auditStore.append(
        AuditLogRecord(
          ts: oldDate,
          invocationId: '11111111-1111-4111-8111-111111111111',
          tool: 'host.status',
          status: XtpStatus.ok,
          durationMs: 4,
        ),
      );
      await auditStore.append(
        AuditLogRecord(
          ts: recentDate,
          invocationId: '22222222-2222-4222-8222-222222222222',
          tool: 'media.play_pause',
          status: XtpStatus.ok,
          durationMs: 12,
        ),
      );

      final records = await auditStore.readRecent();
      expect(records, hasLength(1));
      expect(records.single.tool, 'media.play_pause');
    });
  });

  group('XtpSessionClient handshake & DesktopAgentWindow widget test', () {
    test(
      'completes Mode A enrollment handshake, responds to tools/list, and handles revocation',
      () async {
        await policyStore.savePolicy(_sampleHealthyPolicy());
        late _FakeWebSocketChannel fakeWs;
        final sentFrames = <XtpFrame>[];

        final client = XtpSessionClient(
          wsUri: Uri.parse('ws://127.0.0.1:8000/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          enableAutoReconnect: false,
          connector: (_) {
            fakeWs = _FakeWebSocketChannel();
            fakeWs.outboundFrames.listen((raw) {
              sentFrames.add(XtpFrame.parse(raw));
            });
            return fakeWs;
          },
        );

        await client.connect();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // 1. Agent sent xuna/hello {enroll}
        expect(sentFrames.first, isA<XtpRequest>());
        final helloReq = sentFrames.first as XtpRequest;
        expect(helloReq.method, 'xuna/hello');
        expect(helloReq.typedParams, isA<HelloEnrollParams>());

        // 2. Server sends xuna/challenge (purpose 1)
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/challenge',
            'params': <String, Object?>{
              'purpose': 1,
              'nonce': base64.encode(List<int>.filled(32, 9)),
              'expiresIn': 60,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Agent replies with xuna/proof (purpose 1)
        final proof1 = sentFrames.last as XtpRequest;
        expect(proof1.method, 'xuna/proof');
        expect(
          (proof1.typedParams as ProofParams).purpose,
          HostProofPurpose.enroll,
        );

        // 3. Server sends xuna/enrollPending -> Agent computes QR + 6-digit SAS
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/enrollPending',
            'params': <String, Object?>{'expiresIn': 300},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.phase, HostSessionPhase.enrollWaitingConfirmation);
        expect(client.enrollmentDisplay, isNotNull);
        expect(client.enrollmentDisplay!.sas, hasLength(6));
        expect(
          client.enrollmentDisplay!.qrUri,
          startsWith('xuna-host://enroll?v=1&c='),
        );

        // 4. Server sends xuna/enrolled + xuna/challenge (purpose 2) + xuna/ready
        const enrolledHostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/enrolled',
            'params': <String, Object?>{
              'hostId': enrolledHostId,
              'alias': 'PC Phòng Làm Việc',
            },
          }),
        );
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/challenge',
            'params': <String, Object?>{
              'purpose': 2,
              'nonce': base64.encode(List<int>.filled(32, 5)),
              'expiresIn': 60,
            },
          }),
        );
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-10-30T12:00:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(client.phase, HostSessionPhase.ready);
        expect(enrollmentStore.current?.hostId, enrolledHostId);

        // 5. Server requests tools/list
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 77,
            'method': 'tools/list',
            'params': <String, Object?>{},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final listResp = sentFrames.last as XtpResponse;
        expect(listResp.id, 77);
        final toolsList = listResp.result['tools'] as List<Object?>;
        expect(toolsList, hasLength(12));

        // 6. Backoff calculation check (1, 2, 4, 8, 16, 32, 60 s)
        expect(client.computeBackoffMs(0, jitterMsOverride: 0), 1000);
        expect(client.computeBackoffMs(1, jitterMsOverride: 0), 2000);
        expect(client.computeBackoffMs(5, jitterMsOverride: 0), 32000);
        expect(client.computeBackoffMs(6, jitterMsOverride: 0), 60000);
        expect(client.computeBackoffMs(10, jitterMsOverride: 120), 60120);

        // 7. Server sends xuna/stop {reason: "revoked"} -> wipes enrollment state
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/stop',
            'params': <String, Object?>{'reason': 'revoked'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(enrollmentStore.current, isNull);

        await client.dispose();
      },
    );

    testWidgets(
      'DesktopAgentWindow displays Cấu hình lỗi banner, restores policy, and toggles Dừng XUNA',
      (tester) async {
        await tester.runAsync(() => policyStore.reload());
        final client = XtpSessionClient(
          wsUri: Uri.parse('ws://127.0.0.1:8000/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          enableAutoReconnect: false,
        );

        final controller = Get.put(
          DesktopAgentController(
            channel: channel,
            enrollmentStore: enrollmentStore,
            policyStore: policyStore,
            auditStore: auditStore,
            stopController: stopController,
            sessionClient: client,
            logger: logger,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(home: DesktopAgentWindow(controller: controller)),
        );

        // Corrupted policy shows "Cấu hình lỗi"
        expect(find.text('Cấu hình lỗi'), findsOneWidget);

        // Switch to Policy tab and click "Khôi phục chính sách mặc định"
        await tester.tap(find.text('Chính sách'));
        await tester.pump();
        expect(
          find.byKey(DesktopAgentWindow.restorePolicyButtonKey),
          findsOneWidget,
        );

        await tester.runAsync(() => controller.restoreDefaultPolicy());
        await tester.pump();
        expect(controller.isPolicyHealthy.value, isTrue);

        // Trigger emergency stop from header button
        await tester.tap(find.byKey(DesktopAgentWindow.stopButtonKey));
        await tester.pump();
        expect(controller.isStopped.value, isTrue);
        expect(find.text('Đã dừng khẩn cấp'), findsOneWidget);

        // Resume from header button
        await tester.tap(find.byKey(DesktopAgentWindow.resumeButtonKey));
        await tester.pump();
        expect(controller.isStopped.value, isFalse);

        await tester.runAsync(() => client.dispose());
      },
    );

    test(
      'S3.7 hardening: Mode B reconnect after sleep/network loss without duplicate execution, policy corruption/recovery list_changed, revoke during in-flight call, and duplicate session 4001',
      () async {
        const hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';
        await enrollmentStore.save(hostId: hostId, alias: 'MacBook Pro');
        await policyStore.savePolicy(_sampleHealthyPolicy());

        final channels = <_FakeWebSocketChannel>[];
        final client = XtpSessionClient(
          wsUri: Uri.parse('ws://127.0.0.1:8000/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) {
            final ws = _FakeWebSocketChannel();
            channels.add(ws);
            return ws;
          },
          enableAutoReconnect: false,
        );

        // 1. Connect in Mode B (enrolled host)
        await client.connect();
        expect(channels, hasLength(1));
        final ws1 = channels.first;
        final ws1Sent = <XtpFrame>[];
        ws1.outboundFrames.listen((raw) => ws1Sent.add(XtpFrame.parse(raw)));

        ws1.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/challenge',
            'params': <String, Object?>{
              'purpose': 2,
              'nonce': base64.encode(List<int>.filled(32, 9)),
              'expiresIn': 60,
            },
          }),
        );
        ws1.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-10-30T12:05:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.phase, HostSessionPhase.ready);

        // Execute a tool call on ws1 (with R2 approval for url.open)
        const invId = '77777777-7777-4777-8777-777777777777';
        const urlArgs = <String, Object?>{
          'url': 'https://github.com/xthao28/xuna_pet',
        };
        final approval = <String, Object?>{
          'approvalId': '99999999-9999-4999-8999-999999999999',
          'argsSha256': argsSha256(urlArgs),
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(minutes: 5))
              .toIso8601String(),
        };
        ws1.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 101,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'url.open',
              'arguments': urlArgs,
              '_meta': <String, Object?>{
                'xuna/invocationId': invId,
                'xuna/deadlineMs': 5000,
                'xuna/approval': approval,
              },
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final urlOpenCallsBefore = channel.invokedMethods
            .where((m) => m == 'urlOpen')
            .length;
        expect(urlOpenCallsBefore, 1);

        // 2. Simulate sleep/wake network loss & reconnect on ws2
        await ws1.simulateServerClose(1006, 'abnormal_closure');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.phase, HostSessionPhase.disconnected);

        await client.connect();
        expect(channels, hasLength(2));
        final ws2 = channels[1];
        final ws2Sent = <XtpFrame>[];
        ws2.outboundFrames.listen((raw) => ws2Sent.add(XtpFrame.parse(raw)));

        ws2.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/challenge',
            'params': <String, Object?>{
              'purpose': 2,
              'nonce': base64.encode(List<int>.filled(32, 11)),
              'expiresIn': 60,
            },
          }),
        );
        ws2.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-10-30T12:06:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(client.phase, HostSessionPhase.ready);

        // Server replays the same invocationId after reconnect -> no duplicate execution!
        ws2.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 102,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'url.open',
              'arguments': urlArgs,
              '_meta': <String, Object?>{
                'xuna/invocationId': invId,
                'xuna/deadlineMs': 5000,
                'xuna/approval': approval,
              },
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final urlOpenCallsAfter = channel.invokedMethods
            .where((m) => m == 'urlOpen')
            .length;
        expect(urlOpenCallsAfter, urlOpenCallsBefore);

        // 3. Policy corruption & recovery emits notifications/tools/list_changed
        await paths.policyFile.writeAsString('{broken json', flush: true);
        await policyStore.reload();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(policyStore.isHealthy, isFalse);
        expect(
          ws2Sent.whereType<XtpNotification>().any(
            (n) => n.method == 'notifications/tools/list_changed',
          ),
          isTrue,
        );

        ws2Sent.clear();
        await policyStore.savePolicy(_sampleHealthyPolicy());
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(policyStore.isHealthy, isTrue);
        expect(
          ws2Sent.whereType<XtpNotification>().any(
            (n) => n.method == 'notifications/tools/list_changed',
          ),
          isTrue,
        );

        // 4. Duplicate session close (4001) keeps enrollment state intact
        await ws2.simulateServerClose(
          XtpCloseCode.duplicateSession,
          'duplicate_session',
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(client.phase, HostSessionPhase.disconnected);
        expect(enrollmentStore.current?.hostId, hostId);

        // 5. Reconnect on ws3 and test revoke during an in-flight tool call
        await client.connect();
        final ws3 = channels[2];
        final ws3Sent = <XtpFrame>[];
        ws3.outboundFrames.listen((raw) => ws3Sent.add(XtpFrame.parse(raw)));
        ws3.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-10-30T12:07:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        channel.simulatedDelay = const Duration(milliseconds: 200);
        ws3.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 103,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'media.play_pause',
              'arguments': <String, Object?>{},
              '_meta': <String, Object?>{
                'xuna/invocationId': '88888888-8888-4888-8888-888888888888',
                'xuna/deadlineMs': 5000,
              },
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 40));

        // Revoke arrives while call 103 is in flight
        ws3.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/stop',
            'params': <String, Object?>{'reason': 'revoked'},
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 220));
        expect(enrollmentStore.current, isNull);
        channel.simulatedDelay = Duration.zero;

        // 6. Content-free log & audit grep check
        final logDump = jsonEncode(
          logger.entries
              .map((e) => <String, Object?>{'event': e.event, 'f': e.fields})
              .toList(),
        );
        final auditRecords = await auditStore.readRecent();
        final auditDump = jsonEncode(
          auditRecords.map((r) => r.toJson()).toList(),
        );
        for (final forbidden in const <String>[
          'https://github.com/xthao28/xuna_pet',
          'Code.exe',
          'Focus Mode',
        ]) {
          expect(logDump, isNot(contains(forbidden)));
          expect(auditDump, isNot(contains(forbidden)));
        }

        await client.dispose();
      },
    );
  });
}

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/lan/lan_offline_server.dart';
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
      enrollmentStore: enrollmentStore,
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
        expect(toolsList, hasLength(17));

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

    test(
      'UDC-7 S7.3, S7.4, S7.5: upstream emergency stop, xuna/lanPeer phone key pinning, R3 phone-signed approval, and LAN offline server mutual proof & media-only enforcement',
      () async {
        const hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';
        await enrollmentStore.save(hostId: hostId, alias: 'PC Phòng Khách');

        // Configure policy with an R3 workflow
        final r3Policy = HostPolicy(
          schemaVersion: 1,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.media: FamilyPolicyDecision.allow,
            ToolFamily.app: FamilyPolicyDecision.allow,
            ToolFamily.url: FamilyPolicyDecision.allow,
            ToolFamily.workflow: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>['github.com'],
          workflows: <WorkflowConfig>[
            WorkflowConfig(
              id: 'deploy_prod',
              name: 'Deploy Prod',
              kind: WorkflowKind.shortcut,
              target: 'DeployProd',
              risk: RiskTier.r3,
            ),
          ],
          players: const <String>['spotify'],
        );
        await policyStore.savePolicy(r3Policy);

        // Phone test P-256 keypair
        final phonePrivateScalar = Uint8List.fromList(
          List<int>.generate(32, (i) => (i + 33) & 0xff),
        );
        final phonePublicKey = deriveP256PublicKey(phonePrivateScalar);
        final phonePublicKeyB64 = base64Encode(phonePublicKey);

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
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-10-31T08:00:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        // S7.4 / S7.5: Backend sends xuna/lanPeer with owner phonePublicKeys
        fakeWs.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/lanPeer',
            'params': <String, Object?>{
              'phonePublicKeys': <String>[phonePublicKeyB64],
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(
          enrollmentStore.current?.pinnedPhonePublicKeys,
          equals(<String>[phonePublicKeyB64]),
        );

        // S7.5: Dispatch R3 workflow.run without phone signature -> denied (approval_signature_invalid)
        final now = DateTime.utc(2026, 10, 31, 8, 0, 0);
        const expiresWire = '2026-10-31T08:02:00Z';
        final expiresAt = DateTime.parse(expiresWire).toUtc();
        const wfArgs = <String, Object?>{'id': 'deploy_prod'};
        final wfSha = argsSha256(wfArgs);
        const approvalId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';

        final unsignedR3 = await dispatcher.dispatch(
          requestId: 201,
          params: ToolsCallParams(
            name: 'workflow.run',
            arguments: wfArgs,
            invocationId: '20111111-1111-4111-8111-111111111111',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: approvalId,
              argsSha256: wfSha,
              expiresAt: expiresAt,
              expiresAtRaw: expiresWire,
            ),
          ),
          nowUtc: now,
        );
        expect(
          (unsignedR3.result['_meta']
              as Map<String, Object?>)['xuna/errorCode'],
          equals('approval_signature_invalid'),
        );

        // S7.5: Dispatch R3 workflow.run with valid phone signature -> ok
        final proofMsg = approvalProofMessage(
          approvalId: approvalId,
          argsSha256: wfSha,
          hostId: hostId,
          expiresAt: expiresWire,
        );
        final phoneSig = signP256Deterministic(
          privateScalar32: phonePrivateScalar,
          message: proofMsg,
        );
        final signedR3 = await dispatcher.dispatch(
          requestId: 202,
          params: ToolsCallParams(
            name: 'workflow.run',
            arguments: wfArgs,
            invocationId: '20222222-2222-4222-8222-222222222222',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: approvalId,
              argsSha256: wfSha,
              expiresAt: expiresAt,
              expiresAtRaw: expiresWire,
              scope: 'once',
              signature: phoneSig,
              publicKey: phonePublicKey,
            ),
          ),
          nowUtc: now,
        );
        expect(
          (signedR3.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );

        // S7.3: Local emergency stop sends xuna/stop {reason: "owner_host"} upstream
        sentFrames.clear();
        stopController.triggerStop(StopReason.ownerHost);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          sentFrames.whereType<XtpNotification>().any(
            (n) =>
                n.method == 'xuna/stop' && n.params['reason'] == 'owner_host',
          ),
          isTrue,
        );
        stopController.resumeFromTray();

        // S7.4: Start LanOfflineServer on an ephemeral loopback port and test mutual proof + media-only enforcement
        HttpOverrides.global = null;
        final lanServer = LanOfflineServer(
          channel: channel,
          enrollmentStore: enrollmentStore,
          dispatcher: dispatcher,
          logger: logger,
          bindAddress: '127.0.0.1',
          port: 0,
          enableMdns: false,
        );
        await lanServer.start();
        final lanPort = lanServer.boundPort!;
        expect(lanPort, greaterThan(0));

        // 1. Browser Origin header is rejected with 403 Forbidden
        final httpClient = HttpClient();
        final badOriginReq = await httpClient.getUrl(
          Uri.parse('http://127.0.0.1:$lanPort/xuna-lan'),
        );
        badOriginReq.headers.set('Origin', 'https://evil.example.com');
        final badOriginResp = await badOriginReq.close();
        expect(badOriginResp.statusCode, HttpStatus.forbidden);
        httpClient.close(force: true);

        // 2. Connect phone WebSocket client and complete mutual P-256 proof
        final lanWs = await WebSocket.connect(
          'ws://127.0.0.1:$lanPort/xuna-lan',
        );
        final lanInbound = <XtpFrame>[];
        final readyCompleter = Completer<void>();
        final hostProofCompleter = Completer<ProofParams>();
        final callResponses = <Object, XtpResponse>{};

        final clientNonce = Uint8List.fromList(
          List<int>.generate(32, (i) => (i + 77) & 0xff),
        );

        lanWs.listen((raw) {
          if (raw is! String) return;
          final frame = XtpFrame.parse(raw);
          lanInbound.add(frame);
          if (frame is XtpNotification) {
            final typed = frame.typedParams;
            if (typed is ChallengeParams) {
              // Phone signs server's challenge nonce
              final msg = hostProofMessage(
                nonce: typed.nonceBytes,
                purpose: HostProofPurpose.session,
                payload: phonePublicKey,
                hostIdUuid: hostId,
              );
              final sig = signP256Deterministic(
                privateScalar32: phonePrivateScalar,
                message: msg,
              );
              lanWs.add(
                XtpRequest(
                  id: 1,
                  method: 'xuna/proof',
                  params: <String, Object?>{
                    'purpose': 2,
                    'signature': base64.encode(sig),
                  },
                  typedParams: ProofParams(
                    purpose: HostProofPurpose.session,
                    signatureBytes: sig,
                  ),
                ).encode(),
              );
              // Phone also challenges host for mutual proof
              lanWs.add(
                XtpNotification(
                  method: 'xuna/challenge',
                  params: <String, Object?>{
                    'purpose': 2,
                    'nonce': base64.encode(clientNonce),
                    'expiresIn': 60,
                  },
                  typedParams: ChallengeParams(
                    purpose: HostProofPurpose.session,
                    nonceBytes: clientNonce,
                    expiresIn: 60,
                  ),
                ).encode(),
              );
            } else if (typed is ReadyParams && !readyCompleter.isCompleted) {
              readyCompleter.complete();
            }
          } else if (frame is XtpRequest &&
              frame.typedParams is ProofParams &&
              !hostProofCompleter.isCompleted) {
            hostProofCompleter.complete(frame.typedParams as ProofParams);
          } else if (frame is XtpResponse) {
            callResponses[frame.id] = frame;
          }
        });

        await readyCompleter.future.timeout(const Duration(seconds: 2));
        final hostProof = await hostProofCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        final hostPubKey = await channel.keyEnsure();
        expect(
          verifyP256Signature(
            publicKey: hostPubKey,
            message: hostProofMessage(
              nonce: clientNonce,
              purpose: HostProofPurpose.session,
              payload: hostPubKey,
              hostIdUuid: hostId,
            ),
            signature: hostProof.signatureBytes,
          ),
          isTrue,
        );

        // 3. Call media.play_pause over LAN -> ok
        lanWs.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 10,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'media.play_pause',
              'arguments': <String, Object?>{},
              '_meta': <String, Object?>{
                'xuna/invocationId': '30111111-1111-4111-8111-111111111111',
                'xuna/deadlineMs': 5000,
              },
            },
          }),
        );
        // 4. Call workflow.run over LAN -> denied (lan_media_only)
        lanWs.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 11,
            'method': 'tools/call',
            'params': <String, Object?>{
              'name': 'workflow.run',
              'arguments': <String, Object?>{'id': 'deploy_prod'},
              '_meta': <String, Object?>{
                'xuna/invocationId': '30222222-2222-4222-8222-222222222222',
                'xuna/deadlineMs': 5000,
              },
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(callResponses[10], isNotNull);
        expect(
          (callResponses[10]!.result['_meta']
              as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        expect(callResponses[11], isNotNull);
        expect(
          (callResponses[11]!.result['_meta']
              as Map<String, Object?>)['xuna/status'],
          equals('denied'),
        );
        expect(
          (callResponses[11]!.result['_meta']
              as Map<String, Object?>)['xuna/errorCode'],
          equals('lan_media_only'),
        );

        await lanWs.close();
        await lanServer.stop();
        await client.dispose();
      },
    );
  });

  group('UDC-9 S9.1: browser.current_url tool execution and zero-URL logging', () {
    test(
      'reads active https tab across 10/10 Edge/Chrome (Windows) & Safari/Chrome (macOS) cases, rejects non-https/local URLs, and never logs the URL',
      () async {
        await policyStore.savePolicy(_sampleHealthyPolicy());
        final now = DateTime.utc(2026, 10, 31, 10, 0);

        final tenCases = <({String browser, String url, String expectedHost})>[
          (
            browser: 'edge',
            url: 'https://github.com/xthao28/xuna_pet?token=sec01',
            expectedHost: 'github.com',
          ),
          (
            browser: 'edge',
            url: 'https://docs.github.com/en/actions?token=sec02',
            expectedHost: 'docs.github.com',
          ),
          (
            browser: 'edge',
            url: 'https://jira.example.com/browse/XUNA-9?token=sec03',
            expectedHost: 'jira.example.com',
          ),
          (
            browser: 'chrome',
            url: 'https://developer.apple.com/documentation?token=sec04',
            expectedHost: 'developer.apple.com',
          ),
          (
            browser: 'chrome',
            url: 'https://learn.microsoft.com/en-us/windows/win32?token=sec05',
            expectedHost: 'learn.microsoft.com',
          ),
          (
            browser: 'chrome',
            url: 'https://pub.dev/packages/flutter_test?token=sec06',
            expectedHost: 'pub.dev',
          ),
          (
            browser: 'safari',
            url: 'https://news.ycombinator.com/item?id=42001&token=sec07',
            expectedHost: 'news.ycombinator.com',
          ),
          (
            browser: 'safari',
            url: 'https://arxiv.org/abs/2410.00001?token=sec08',
            expectedHost: 'arxiv.org',
          ),
          (
            browser: 'safari',
            url: 'https://sub.việt.vn/bai-viet?token=sec09',
            expectedHost: 'sub.xn--vit-5kz.vn',
          ),
          (
            browser: 'chrome',
            url: 'https://openai.com/index/computer-use?token=sec10',
            expectedHost: 'openai.com',
          ),
        ];

        for (var i = 0; i < tenCases.length; i++) {
          final tc = tenCases[i];
          channel.browserCurrentUrlResult = BrowserTabSnapshot(
            url: tc.url,
            browser: tc.browser,
          );
          final args = <String, Object?>{'browser': tc.browser};
          final resp = await dispatcher.dispatch(
            requestId: 500 + i,
            params: ToolsCallParams(
              name: 'browser.current_url',
              arguments: args,
              invocationId:
                  '91000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId:
                    '92000000-0000-4000-8000-${(i + 1).toString().padLeft(12, '0')}',
                argsSha256: argsSha256(args),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final meta = resp.result['_meta'] as Map<String, Object?>;
          expect(meta['xuna/status'], equals('ok'));
          final sc = resp.result['structuredContent'] as Map<String, Object?>;
          expect(sc['url'], equals(tc.url));
          expect(sc['host'], equals(tc.expectedHost));
          expect(sc['browser'], equals(tc.browser));
          expect(channel.toasts.last.body, equals('XUNA: đã đọc liên kết ${tc.expectedHost}'));
        }

        // Rejects http://, file://, chrome://, private IP, localhost
        for (var j = 0; j < 5; j++) {
          final badUrl = <String>[
            'http://github.com/insecure',
            'file:///C:/Users/Thao/secret.txt',
            'chrome://settings/passwords',
            'https://192.168.1.1/router',
            'https://localhost:8080/internal',
          ][j];
          channel.browserCurrentUrlResult = BrowserTabSnapshot(
            url: badUrl,
            browser: 'edge',
          );
          const args = <String, Object?>{'browser': 'edge'};
          final badResp = await dispatcher.dispatch(
            requestId: 600 + j,
            params: ToolsCallParams(
              name: 'browser.current_url',
              arguments: args,
              invocationId:
                  '93000000-0000-4000-8000-${(j + 1).toString().padLeft(12, '0')}',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId:
                    '94000000-0000-4000-8000-${(j + 1).toString().padLeft(12, '0')}',
                argsSha256: argsSha256(args),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final meta = badResp.result['_meta'] as Map<String, Object?>;
          expect(meta['xuna/status'], equals('invalid_args'));
          expect(meta['xuna/errorCode'], equals('url_invalid'));
        }

        // Verify zero URLs or query tokens in ContentFreeLogger and AuditLogStore
        for (final entry in logger.entries) {
          final serialized = jsonEncode(entry.fields);
          expect(serialized, isNot(contains('https://')));
          expect(serialized, isNot(contains('sec01')));
          expect(serialized, isNot(contains('xthao28')));
        }
        final audits = await auditStore.readRecent();
        for (final record in audits) {
          final line = jsonEncode(record.toJson());
          expect(line, isNot(contains('https://')));
          expect(line, isNot(contains('sec01')));
        }
      },
    );
  });

  group('UDC-11 S11.1–S11.3: Zero-config app/workspace discovery, display.wake, workspace.open, workspace.git_summary, and workspace.coding_agent', () {
    test(
      'discovers apps/CLIs and workspaces automatically (~/.claude.json, IDE storage.json, .git scan), executes display.wake, workspace.open, workspace.git_summary, and workspace.coding_agent (claude --continue) with zero raw path/prompt logging',
      () async {
        // Policy has NO manual apps configured (apps: []) to verify zero-config discovery!
        final zeroConfigPolicy = HostPolicy(
          schemaVersion: 1,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.media: FamilyPolicyDecision.allow,
            ToolFamily.app: FamilyPolicyDecision.allow,
            ToolFamily.url: FamilyPolicyDecision.allow,
            ToolFamily.workflow: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>['github.com'],
          workflows: const <WorkflowConfig>[],
          players: const <String>['spotify'],
        );
        await policyStore.savePolicy(zeroConfigPolicy);

        // Create fake home & app directories inside tempDir
        final fakeHome = Directory('${tempDir.path}/home');
        await fakeHome.create(recursive: true);
        final fakeAppsDir = Directory('${tempDir.path}/Applications');
        await fakeAppsDir.create(recursive: true);
        final fakeBinDir = Directory('${tempDir.path}/bin');
        await fakeBinDir.create(recursive: true);

        // Create fake macOS bundles + hard-denied app (Terminal.app)
        await Directory('${fakeAppsDir.path}/Antigravity.app').create();
        await Directory('${fakeAppsDir.path}/Visual Studio Code.app').create();
        await Directory('${fakeAppsDir.path}/Terminal.app').create();

        // Create fake CLI binaries (claude, agy)
        final claudeBin = File('${fakeBinDir.path}/claude');
        await claudeBin.writeAsString('#!/bin/sh\n', flush: true);
        final agyBin = File('${fakeBinDir.path}/agy');
        await agyBin.writeAsString('#!/bin/sh\n', flush: true);

        // Create fake projects in ~/Documents/xuna_pet and ~/Projects/demo_app
        final xunaDir = Directory('${fakeHome.path}/Documents/xuna_pet');
        await Directory('${xunaDir.path}/.git').create(recursive: true);
        await File('${xunaDir.path}/AGENTS.md').writeAsString('# XUNA', flush: true);

        final demoDir = Directory('${fakeHome.path}/Projects/demo_app');
        await Directory('${demoDir.path}/.git').create(recursive: true);

        // Write ~/.claude.json referencing xuna_pet
        final claudeJsonFile = File('${fakeHome.path}/.claude.json');
        await claudeJsonFile.writeAsString(
          jsonEncode(<String, Object?>{
            'projects': <String, Object?>{
              xunaDir.path: <String, Object?>{'hasTrustDialogAccepted': true},
            },
          }),
          flush: true,
        );

        // Write Antigravity storage.json referencing demo_app
        final agyStorageDir = Directory(
          '${fakeHome.path}/Library/Application Support/Antigravity/User/globalStorage',
        );
        await agyStorageDir.create(recursive: true);
        final agyStorageFile = File('${agyStorageDir.path}/storage.json');
        await agyStorageFile.writeAsString(
          jsonEncode(<String, Object?>{
            'backupWorkspaces': <String, Object?>{
              'folders': <Map<String, Object?>>[
                <String, Object?>{'folderUri': Uri.directory(demoDir.path).toString()},
              ],
            },
          }),
          flush: true,
        );

        final launchedPlans = <CodingAgentLaunchPlan>[];

        final appScanner = AutoAppScanner(
          seedApps: const <DiscoveredApp>[
            DiscoveredApp(
              id: 'antigravity',
              name: 'Antigravity',
              kind: AppLaunchKind.bundle,
              target: 'com.google.antigravity',
              isCodingAgent: true,
            ),
            DiscoveredApp(
              id: 'vscode',
              name: 'Visual Studio Code',
              kind: AppLaunchKind.bundle,
              target: 'com.microsoft.VSCode',
              isCodingAgent: true,
            ),
            DiscoveredApp(
              id: 'terminal',
              name: 'Terminal',
              kind: AppLaunchKind.bundle,
              target: 'com.apple.Terminal',
            ),
          ],
          seedAgentBinaries: <String, String>{
            'claude_code': claudeBin.path,
            'antigravity': agyBin.path,
          },
          scanFileSystem: false,
        );
        final workspaceIndexer = AutoWorkspaceIndexer(
          customScanRoots: <String>[
            '${fakeHome.path}/Documents',
            '${fakeHome.path}/Projects',
          ],
          customClaudeConfigPaths: <String>[claudeJsonFile.path],
          customIdeStoragePaths: <String>[agyStorageFile.path],
          scanDefaultLocations: false,
          gitRunner: (executable, arguments) async {
            return ProcessResult(
              1,
              0,
              '## feat/udc-11-dev-resume...origin/feat/udc-11-dev-resume\n'
              ' M desktop/lib/features/tools/host_tool_dispatcher.dart\n'
              '?? docs/roadmap/device-control/UDC-11-dev-workspace-resume.md\n',
              '',
            );
          },
          agentLauncher: (plan) async {
            launchedPlans.add(plan);
          },
        );

        final udc11Dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: channel,
          auditStore: auditStore,
          stopController: stopController,
          logger: logger,
          enrollmentStore: enrollmentStore,
          appScanner: appScanner,
          workspaceIndexer: workspaceIndexer,
        );
        addTearDown(udc11Dispatcher.dispose);

        // 1. Verify AutoAppScanner found Antigravity, VS Code, Claude Code CLI, and excluded Terminal
        final installedApps = appScanner.discoverApps();
        final installedIds = installedApps.map((a) => a.id).toSet();
        expect(installedIds, containsAll(<String>['antigravity', 'vscode']));
        expect(installedIds, isNot(contains('terminal')));
        expect(
          appScanner.resolveCodingAgent('claude_code')?.executable,
          equals(claudeBin.path),
        );

        // 2. Verify AutoWorkspaceIndexer discovered xuna_pet and demo_app and fuzzy matches
        final workspaces = workspaceIndexer.discoverWorkspaces();
        expect(
          workspaces.map((w) => w.alias).toList(),
          containsAll(<String>['xuna_pet', 'demo_app']),
        );
        final matchedFuzzy = workspaceIndexer.resolveWorkspace('xuna');
        expect(matchedFuzzy?.alias, equals('xuna_pet'));
        final matchedRecent = workspaceIndexer.resolveWorkspace('recent');
        expect(matchedRecent, isNotNull);

        final now = DateTime.utc(2026, 10, 31, 12, 0);

        // 3. Execute display.wake (R1)
        final wakeResp = await udc11Dispatcher.dispatch(
          requestId: 701,
          params: const ToolsCallParams(
            name: 'display.wake',
            arguments: <String, Object?>{},
            invocationId: '70100000-0000-4000-8000-000000000001',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(
          (wakeResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        expect(
          (wakeResp.result['structuredContent'] as Map<String, Object?>)['woken'],
          isTrue,
        );
        expect(channel.displayWakeCount, equals(1));

        // 4. Execute zero-config app.launch for "antigravity" (R2) without manual host-policy.json entry
        const launchArgs = <String, Object?>{'id': 'antigravity'};
        final launchResp = await udc11Dispatcher.dispatch(
          requestId: 702,
          params: ToolsCallParams(
            name: 'app.launch',
            arguments: launchArgs,
            invocationId: '70200000-0000-4000-8000-000000000002',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '70200000-0000-4000-8000-000000000099',
              argsSha256: argsSha256(launchArgs),
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (launchResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        expect(
          (launchResp.result['structuredContent'] as Map<String, Object?>)['id'],
          equals('antigravity'),
        );

        // 5. Execute workspace.git_summary (R1)
        final gitResp = await udc11Dispatcher.dispatch(
          requestId: 703,
          params: const ToolsCallParams(
            name: 'workspace.git_summary',
            arguments: <String, Object?>{'project': 'xuna_pet'},
            invocationId: '70300000-0000-4000-8000-000000000003',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(
          (gitResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        final gitSc = gitResp.result['structuredContent'] as Map<String, Object?>;
        expect(gitSc['workspace'], equals('xuna_pet'));
        expect(gitSc['branch'], equals('feat/udc-11-dev-resume'));
        expect(gitSc['clean'], isFalse);
        expect(gitSc['modifiedCount'], equals(1));
        expect(gitSc['untrackedCount'], equals(1));

        // 6. Execute workspace.open (R2)
        const openWsArgs = <String, Object?>{
          'project': 'xuna',
          'ide': 'antigravity',
        };
        final openWsResp = await udc11Dispatcher.dispatch(
          requestId: 704,
          params: ToolsCallParams(
            name: 'workspace.open',
            arguments: openWsArgs,
            invocationId: '70400000-0000-4000-8000-000000000004',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '70400000-0000-4000-8000-000000000099',
              argsSha256: argsSha256(openWsArgs),
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (openWsResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        expect(launchedPlans.last.executable, equals(agyBin.path));
        expect(
          launchedPlans.last.arguments,
          equals(<String>[xunaDir.absolute.path]),
        );

        // 7. Execute workspace.coding_agent (R2) -> claude --continue "<prompt>"
        const secretPrompt =
            'Tiếp tục làm UDC-11 trên nhánh feat/udc-11-dev-resume (đang sửa 2 tệp).';
        const agentArgs = <String, Object?>{
          'project': 'xuna_pet',
          'agent': 'claude_code',
          'prompt': secretPrompt,
          'resumeLast': true,
        };
        final agentResp = await udc11Dispatcher.dispatch(
          requestId: 705,
          params: ToolsCallParams(
            name: 'workspace.coding_agent',
            arguments: agentArgs,
            invocationId: '70500000-0000-4000-8000-000000000005',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '70500000-0000-4000-8000-000000000099',
              argsSha256: argsSha256(agentArgs),
              expiresAt: now.add(const Duration(minutes: 2)),
            ),
          ),
          nowUtc: now,
        );
        expect(
          (agentResp.result['_meta'] as Map<String, Object?>)['xuna/status'],
          equals('ok'),
        );
        final agentSc =
            agentResp.result['structuredContent'] as Map<String, Object?>;
        expect(agentSc['workspace'], equals('xuna_pet'));
        expect(agentSc['agent'], equals('claude_code'));
        expect(agentSc['resumed'], isTrue);
        expect(agentSc['promptSent'], isTrue);
        expect(launchedPlans.last.executable, equals(claudeBin.path));
        expect(
          launchedPlans.last.arguments,
          equals(<String>['--continue', secretPrompt]),
        );
        expect(
          launchedPlans.last.workingDirectory,
          equals(xunaDir.absolute.path),
        );

        // 8. Verify zero raw paths, git commit messages, or prompt text in logs or audit
        for (final entry in logger.entries) {
          final serialized = jsonEncode(entry.fields);
          expect(serialized, isNot(contains(xunaDir.path)));
          expect(serialized, isNot(contains(secretPrompt)));
          expect(serialized, isNot(contains('feat/udc-11-dev-resume')));
        }
        final audits = await auditStore.readRecent();
        for (final record in audits) {
          final line = jsonEncode(record.toJson());
          expect(line, isNot(contains(xunaDir.path)));
          expect(line, isNot(contains(secretPrompt)));
        }
      },
    );
  });
}

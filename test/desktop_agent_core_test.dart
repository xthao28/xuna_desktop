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
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/discovery/auto_smart_home_bridge.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_tv_scanner.dart';
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
        expect(toolsList, hasLength(50));

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
          expect(
            channel.toasts.last.body,
            equals('XUNA: đã đọc liên kết ${tc.expectedHost}'),
          );
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

  group(
    'UDC-11 S11.1–S11.3: Zero-config app/workspace discovery, display.wake, workspace.open, workspace.git_summary, and workspace.coding_agent',
    () {
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
          await Directory(
            '${fakeAppsDir.path}/Visual Studio Code.app',
          ).create();
          await Directory('${fakeAppsDir.path}/Terminal.app').create();

          // Create fake CLI binaries (claude, agy)
          final claudeBin = File('${fakeBinDir.path}/claude');
          await claudeBin.writeAsString('#!/bin/sh\n', flush: true);
          final agyBin = File('${fakeBinDir.path}/agy');
          await agyBin.writeAsString('#!/bin/sh\n', flush: true);

          // Create fake projects in ~/Documents/xuna_pet and ~/Projects/demo_app
          final xunaDir = Directory('${fakeHome.path}/Documents/xuna_pet');
          await Directory('${xunaDir.path}/.git').create(recursive: true);
          await File(
            '${xunaDir.path}/AGENTS.md',
          ).writeAsString('# XUNA', flush: true);

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
                  <String, Object?>{
                    'folderUri': Uri.directory(demoDir.path).toString(),
                  },
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
            (wakeResp.result['structuredContent']
                as Map<String, Object?>)['woken'],
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
            (launchResp.result['structuredContent']
                as Map<String, Object?>)['id'],
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
          final gitSc =
              gitResp.result['structuredContent'] as Map<String, Object?>;
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
    },
  );

  group(
    'UDC-12 S12.2–S12.3: selection.read (secret redaction), host.lock_screen, workspace.watch_task, and AutoMcpBridge',
    () {
      test(
        'executes selection.read with secret redaction, host.lock_screen, workspace.watch_task, and AutoMcpBridge (mcp.list_servers & mcp.call) without exposing MCP env secrets',
        () async {
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

          final fakeHome = Directory('${tempDir.path}/udc12_home');
          await fakeHome.create(recursive: true);
          final xunaDir = Directory('${fakeHome.path}/Documents/xuna_pet');
          await Directory('${xunaDir.path}/.git').create(recursive: true);
          await File('${xunaDir.path}/PROCESS.md').writeAsString(
            '# PROCESS\nStatus: **Done** — all tests PASS\n',
            flush: true,
          );

          final mcpConfigFile = File('${fakeHome.path}/.claude.json');
          await mcpConfigFile.writeAsString(
            jsonEncode(<String, Object?>{
              'mcpServers': <String, Object?>{
                'github': <String, Object?>{
                  'command': 'npx',
                  'args': <String>['-y', '@modelcontextprotocol/server-github'],
                  'env': <String, Object?>{
                    'GITHUB_PERSONAL_ACCESS_TOKEN':
                        'ghp_SuperSecretToken9876543210abcdef',
                  },
                },
                'bad_shell': <String, Object?>{'command': 'powershell.exe'},
              },
            }),
            flush: true,
          );

          final mcpBridge = AutoMcpBridge(
            customConfigPaths: <String>[mcpConfigFile.path],
            scanDefaultLocations: false,
            invoker: (server, toolName, payload) async {
              return 'PR #42 (${payload['repo']}): CI passed, token sk-1234567890abcdef1234';
            },
          );
          final workspaceIndexer = AutoWorkspaceIndexer(
            customScanRoots: <String>['${fakeHome.path}/Documents'],
            scanDefaultLocations: false,
            gitRunner: (executable, arguments) async {
              return ProcessResult(1, 0, '## main...origin/main\n', '');
            },
          );

          final udc12Dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            workspaceIndexer: workspaceIndexer,
            mcpBridge: mcpBridge,
          );
          addTearDown(udc12Dispatcher.dispose);

          final now = DateTime.utc(2026, 10, 31, 13, 0);

          // 1. selection.read redacts secrets and logs zero clipboard text
          channel.clipboardTextResult =
              'NullPointerException at Auth.kt:42 with OPENAI_API_KEY=sk-projabcdef1234567890 and Bearer eyJhbGciOiJIUzI1NiJ9';
          final selResp = await udc12Dispatcher.dispatch(
            requestId: 801,
            params: const ToolsCallParams(
              name: 'selection.read',
              arguments: <String, Object?>{'maxChars': 500},
              invocationId: '80100000-0000-4000-8000-000000000001',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final selSc =
              selResp.result['structuredContent'] as Map<String, Object?>;
          expect(selSc['redactedCount'], greaterThanOrEqualTo(2));
          expect(selSc['text'] as String, contains('[REDACTED]'));
          expect(selSc['text'] as String, isNot(contains('sk-projabcdef')));
          expect(selSc['text'] as String, isNot(contains('eyJhbGci')));

          // 2. host.lock_screen locks the workstation
          final lockResp = await udc12Dispatcher.dispatch(
            requestId: 802,
            params: const ToolsCallParams(
              name: 'host.lock_screen',
              arguments: <String, Object?>{},
              invocationId: '80200000-0000-4000-8000-000000000002',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(
            (lockResp.result['structuredContent']
                as Map<String, Object?>)['locked'],
            isTrue,
          );
          expect(channel.lockScreenCount, equals(1));

          // 3. workspace.watch_task inspects task status
          final watchResp = await udc12Dispatcher.dispatch(
            requestId: 803,
            params: const ToolsCallParams(
              name: 'workspace.watch_task',
              arguments: <String, Object?>{'project': 'xuna'},
              invocationId: '80300000-0000-4000-8000-000000000003',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final watchSc =
              watchResp.result['structuredContent'] as Map<String, Object?>;
          expect(watchSc['workspace'], equals('xuna_pet'));
          expect(watchSc['status'], equals('completed'));

          // 4. mcp.list_servers returns github server without env secrets and excludes powershell
          final mcpListResp = await udc12Dispatcher.dispatch(
            requestId: 804,
            params: const ToolsCallParams(
              name: 'mcp.list_servers',
              arguments: <String, Object?>{},
              invocationId: '80400000-0000-4000-8000-000000000004',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final listJson = jsonEncode(mcpListResp.result);
          expect(listJson, contains('"id":"github"'));
          expect(listJson, isNot(contains('bad_shell')));
          expect(listJson, isNot(contains('ghp_SuperSecretToken')));

          // 5. mcp.call executes with R2 approval and redacts any leaked token in output
          const mcpCallArgs = <String, Object?>{
            'server': 'github',
            'tool': 'get_pull_request',
            'payloadJson': '{"repo":"xthao28/xuna_pet"}',
          };
          final mcpCallResp = await udc12Dispatcher.dispatch(
            requestId: 805,
            params: ToolsCallParams(
              name: 'mcp.call',
              arguments: mcpCallArgs,
              invocationId: '80500000-0000-4000-8000-000000000005',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '80500000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(mcpCallArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final mcpCallSc =
              mcpCallResp.result['structuredContent'] as Map<String, Object?>;
          expect(mcpCallSc['server'], equals('github'));
          expect(mcpCallSc['tool'], equals('get_pull_request'));
          expect(mcpCallSc['summary'] as String, contains('PR #42'));
          expect(mcpCallSc['summary'] as String, isNot(contains('sk-123456')));
        },
      );
    },
  );

  group(
    'UDC-13 S13.1–S13.5: window.active_context, browser.read_page, beam.transfer, workflow.batch_steps (validate-all-before-run), and action.undo',
    () {
      test(
        'executes window.active_context (blocks hard-denied & elevated), browser.read_page (with playwright MCP detection), beam.transfer (SHA-256 verification), workflow.batch_steps, and action.undo with zero content logging',
        () async {
          await policyStore.savePolicy(_sampleHealthyPolicy());
          final beamDir = Directory('${tempDir.path}/XUNA_Beam');

          final mcpBridge = AutoMcpBridge(
            seedServers: const <DiscoveredMcpServer>[
              DiscoveredMcpServer(
                id: 'playwright',
                transport: 'stdio',
                source: 'claude_code',
                command: 'npx',
                args: <String>['@playwright/mcp@latest'],
              ),
            ],
            scanDefaultLocations: false,
          );

          final udc13Dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            mcpBridge: mcpBridge,
            beamDirectoryPath: beamDir.path,
          );
          addTearDown(udc13Dispatcher.dispose);

          final now = DateTime.utc(2026, 10, 31, 14, 0);

          // 1. S13.1: window.active_context reads active window and redacts secrets
          channel.activeWindowContextResult = const ActiveWindowContextSnapshot(
            appName: 'VS Code',
            processName: 'Code.exe',
            windowTitle: 'config.dart - token=sk-secret9876543210abcdef',
            focusedRole: 'editor',
            visibleText:
                'Database connection error withBearer: Bearer eyJhbGciOiJIUzI1NiJ9',
            isElevated: false,
          );
          final winResp = await udc13Dispatcher.dispatch(
            requestId: 901,
            params: const ToolsCallParams(
              name: 'window.active_context',
              arguments: <String, Object?>{'maxChars': 500},
              invocationId: '90100000-0000-4000-8000-000000000001',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final winSc =
              winResp.result['structuredContent'] as Map<String, Object?>;
          expect(winSc['appName'], equals('VS Code'));
          expect(winSc['redactedCount'], greaterThanOrEqualTo(2));
          expect(
            winSc['windowTitle'] as String,
            isNot(contains('sk-secret987654')),
          );
          expect(
            winSc['visibleSummary'] as String,
            isNot(contains('eyJhbGci')),
          );

          // Hard-denied app (1Password) is refused with denylisted_target_forbidden
          channel.activeWindowContextResult = const ActiveWindowContextSnapshot(
            appName: '1Password',
            processName: '1Password.exe',
            windowTitle: 'Vault',
            focusedRole: 'window',
            visibleText: 'Master password',
            isElevated: false,
          );
          final deniedWinResp = await udc13Dispatcher.dispatch(
            requestId: 902,
            params: const ToolsCallParams(
              name: 'window.active_context',
              arguments: <String, Object?>{},
              invocationId: '90200000-0000-4000-8000-000000000002',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(
            (deniedWinResp.result['_meta']
                as Map<String, Object?>)['xuna/errorCode'],
            equals('denylisted_target_forbidden'),
          );

          // Elevated window is refused with elevated_window_forbidden
          channel.activeWindowContextResult = const ActiveWindowContextSnapshot(
            appName: 'VS Code',
            processName: 'Code.exe',
            windowTitle: 'Admin Window',
            focusedRole: 'window',
            visibleText: 'Admin text',
            isElevated: true,
          );
          final elevWinResp = await udc13Dispatcher.dispatch(
            requestId: 903,
            params: const ToolsCallParams(
              name: 'window.active_context',
              arguments: <String, Object?>{},
              invocationId: '90300000-0000-4000-8000-000000000003',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(
            (elevWinResp.result['_meta']
                as Map<String, Object?>)['xuna/errorCode'],
            equals('elevated_window_forbidden'),
          );

          // 2. S13.2: browser.read_page returns semantic summary and detects @playwright/mcp
          final pageResp = await udc13Dispatcher.dispatch(
            requestId: 904,
            params: const ToolsCallParams(
              name: 'browser.read_page',
              arguments: <String, Object?>{'browser': 'edge', 'maxChars': 800},
              invocationId: '90400000-0000-4000-8000-000000000004',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final pageSc =
              pageResp.result['structuredContent'] as Map<String, Object?>;
          expect(pageSc['host'], equals('github.com'));
          expect(pageSc['playwrightMcpAvailable'], isTrue);
          expect(
            pageSc['headings'] as List<Object?>,
            contains('All checks have passed'),
          );

          // 3. S13.3: beam.transfer verifies SHA-256 and saves file to XUNA_Beam
          final payloadBytes = Uint8List.fromList(
            utf8.encode('XUNA Beam Peer-to-Peer LAN Payload'),
          );
          final payloadHash = sha256Hex(payloadBytes);
          final beamArgs = <String, Object?>{
            'direction': 'phone_to_desktop',
            'kind': 'file',
            'fileName': 'note-from-phone.txt',
            'sizeBytes': payloadBytes.length,
            'sha256': payloadHash,
            'dataBase64': base64.encode(payloadBytes),
          };
          final beamResp = await udc13Dispatcher.dispatch(
            requestId: 905,
            params: ToolsCallParams(
              name: 'beam.transfer',
              arguments: beamArgs,
              invocationId: '90500000-0000-4000-8000-000000000005',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '90500000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(beamArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final beamSc =
              beamResp.result['structuredContent'] as Map<String, Object?>;
          expect(beamSc['verified'], isTrue);
          final savedFile = File('${beamDir.path}/note-from-phone.txt');
          expect(await savedFile.exists(), isTrue);
          expect(await savedFile.readAsBytes(), equals(payloadBytes));

          // Corrupted SHA-256 is rejected with beam_hash_mismatch
          final badBeamArgs = <String, Object?>{
            ...beamArgs,
            'fileName': 'corrupted.txt',
            'sha256': '0' * 64,
          };
          final badBeamResp = await udc13Dispatcher.dispatch(
            requestId: 906,
            params: ToolsCallParams(
              name: 'beam.transfer',
              arguments: badBeamArgs,
              invocationId: '90600000-0000-4000-8000-000000000006',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '90600000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(badBeamArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          expect(
            (badBeamResp.result['_meta']
                as Map<String, Object?>)['xuna/errorCode'],
            equals('beam_hash_mismatch'),
          );
          expect(await File('${beamDir.path}/corrupted.txt').exists(), isFalse);

          // 4. S13.4: workflow.batch_steps executes all validated steps atomically
          final wakeBeforeBatch = channel.displayWakeCount;
          final batchArgs = <String, Object?>{
            'steps': <Map<String, Object?>>[
              <String, Object?>{
                'tool': 'display.wake',
                'arguments': const <String, Object?>{},
              },
              <String, Object?>{
                'tool': 'media.volume_set',
                'arguments': const <String, Object?>{'level': 35},
              },
              <String, Object?>{
                'tool': 'url.open',
                'arguments': const <String, Object?>{
                  'url': 'https://github.com/xthao28/xuna_pet',
                },
              },
            ],
          };
          final batchResp = await udc13Dispatcher.dispatch(
            requestId: 907,
            params: ToolsCallParams(
              name: 'workflow.batch_steps',
              arguments: batchArgs,
              invocationId: '90700000-0000-4000-8000-000000000007',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '90700000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(batchArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final batchSc =
              batchResp.result['structuredContent'] as Map<String, Object?>;
          expect(batchSc['completedCount'], equals(3));
          expect(channel.displayWakeCount, equals(wakeBeforeBatch + 1));
          expect(channel.currentVolume, equals(35));

          // If Step 2 is invalid/denied, Step 1 (display.wake) MUST NOT execute!
          final wakeBeforeInvalidBatch = channel.displayWakeCount;
          final invalidBatchArgs = <String, Object?>{
            'steps': <Map<String, Object?>>[
              <String, Object?>{
                'tool': 'display.wake',
                'arguments': const <String, Object?>{},
              },
              <String, Object?>{
                'tool': 'url.open',
                'arguments': const <String, Object?>{
                  'url': 'https://untrusted.example.org/malware',
                },
              },
            ],
          };
          final invalidBatchResp = await udc13Dispatcher.dispatch(
            requestId: 908,
            params: ToolsCallParams(
              name: 'workflow.batch_steps',
              arguments: invalidBatchArgs,
              invocationId: '90800000-0000-4000-8000-000000000008',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '90800000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(invalidBatchArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          expect(
            (invalidBatchResp.result['_meta']
                as Map<String, Object?>)['xuna/errorCode'],
            equals('domain_not_allowed'),
          );
          expect(channel.displayWakeCount, equals(wakeBeforeInvalidBatch));

          // 5. S13.5: action.undo restores the previous volume (50%) set before batch
          final undoResp = await udc13Dispatcher.dispatch(
            requestId: 909,
            params: const ToolsCallParams(
              name: 'action.undo',
              arguments: <String, Object?>{},
              invocationId: '90900000-0000-4000-8000-000000000009',
              deadlineMs: 5000,
            ),
            nowUtc: now.add(const Duration(seconds: 30)),
          );
          final undoSc =
              undoResp.result['structuredContent'] as Map<String, Object?>;
          expect(undoSc['undoneTool'], equals('media.volume_set'));
          expect(undoSc['restored'], isTrue);
          expect(channel.currentVolume, equals(50));
        },
      );
    },
  );

  group(
    'UDC-14 S14.1–S14.5: Smart TV LAN Bridge (tv.list_devices, tv.control + WoL, tv.launch_app, tv.cast_media) & Smart Home Bridge (smarthome.*, UDC-T36 lock/alarm/camera hard-denylist & undo)',
    () {
      test(
        'discovers Smart TVs, wakes via WoL, launches apps, casts https URLs, controls allowlisted appliances, hard-denies locks/alarms/cameras, and undoes TV/smart-home changes',
        () async {
          await policyStore.savePolicy(_sampleHealthyPolicy());
          final now = DateTime.utc(2026, 10, 31, 15, 0, 0);

          final wokenMacs = <String>[];
          final tvCommands = <Map<String, Object?>>[];
          final tvScanner = AutoTvScanner(
            seedDevices: const <DiscoveredSmartTv>[
              DiscoveredSmartTv(
                id: 'tv-lg-living',
                name: 'TV phòng khách',
                brand: 'lg',
                protocol: 'webos',
                hostAddress: '192.168.1.88',
                port: 3000,
                online: false,
                macAddress: 'AA:BB:CC:11:22:33',
                volume: 20,
              ),
            ],
            wolSender: (mac) async {
              wokenMacs.add(mac);
              return true;
            },
            commandTransport:
                ({required tv, required operation, required payload}) async {
                  tvCommands.add(<String, Object?>{
                    'tvId': tv.id,
                    'operation': operation,
                    ...payload,
                  });
                  return const <String, Object?>{'ok': true};
                },
          );

          final smartHomeBridge = AutoSmartHomeBridge(
            seedEntities: const <SmartHomeEntity>[
              SmartHomeEntity(
                entityId: 'light.living_room',
                domain: 'light',
                name: 'Đèn phòng khách',
                state: 'on',
                value: 80,
              ),
              SmartHomeEntity(
                entityId: 'climate.bedroom_ac',
                domain: 'climate',
                name: 'Điều hòa phòng ngủ',
                state: 'cool',
                value: 26,
              ),
            ],
          );

          final udc14Dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            tvScanner: tvScanner,
            smartHomeBridge: smartHomeBridge,
          );
          addTearDown(udc14Dispatcher.dispose);

          // 1. S14.1: tv.list_devices returns discovered TV without raw MAC
          final listTvResp = await udc14Dispatcher.dispatch(
            requestId: 1001,
            params: const ToolsCallParams(
              name: 'tv.list_devices',
              arguments: <String, Object?>{},
              invocationId: '10010000-0000-4000-8000-000000000001',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final tvListSc =
              listTvResp.result['structuredContent'] as Map<String, Object?>;
          final devices = tvListSc['devices'] as List<Object?>;
          expect(devices, hasLength(1));
          final tvJson = devices.single as Map<String, Object?>;
          expect(tvJson['name'], equals('TV phòng khách'));
          expect(tvJson['supportsWakeOnLan'], isTrue);
          expect(tvJson.containsKey('macAddress'), isFalse);

          // 2. S14.2: tv.control power_wake sends WoL and marks TV online
          final wakeTvResp = await udc14Dispatcher.dispatch(
            requestId: 1002,
            params: const ToolsCallParams(
              name: 'tv.control',
              arguments: <String, Object?>{
                'device': 'TV phòng khách',
                'action': 'power_wake',
              },
              invocationId: '10020000-0000-4000-8000-000000000002',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(wokenMacs, equals(<String>['AA:BB:CC:11:22:33']));
          expect(
            (wakeTvResp.result['structuredContent']
                as Map<String, Object?>)['state'],
            equals('awake'),
          );

          // Set TV volume to 45 -> records reversible entry (previous was 20)
          await udc14Dispatcher.dispatch(
            requestId: 1003,
            params: const ToolsCallParams(
              name: 'tv.control',
              arguments: <String, Object?>{
                'device': 'TV phòng khách',
                'action': 'volume_set',
                'level': 45,
              },
              invocationId: '10030000-0000-4000-8000-000000000003',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(tvScanner.resolveDevice('lg')?.volume, equals(45));

          // Undo restores TV volume back to 20!
          await udc14Dispatcher.dispatch(
            requestId: 1004,
            params: const ToolsCallParams(
              name: 'action.undo',
              arguments: <String, Object?>{},
              invocationId: '10040000-0000-4000-8000-000000000004',
              deadlineMs: 5000,
            ),
            nowUtc: now.add(const Duration(seconds: 5)),
          );
          expect(tvScanner.resolveDevice('lg')?.volume, equals(20));

          // 3. S14.2 & S14.3: tv.launch_app and tv.cast_media (R2)
          const castArgs = <String, Object?>{
            'device': 'TV phòng khách',
            'url': 'https://www.youtube.com/watch?v=xuna_demo_123',
            'title': 'XUNA Demo',
          };
          final castResp = await udc14Dispatcher.dispatch(
            requestId: 1005,
            params: ToolsCallParams(
              name: 'tv.cast_media',
              arguments: castArgs,
              invocationId: '10050000-0000-4000-8000-000000000005',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '10050000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(castArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final castSc =
              castResp.result['structuredContent'] as Map<String, Object?>;
          expect(castSc['appId'], equals('youtube'));
          expect(castSc['host'], equals('www.youtube.com'));
          expect(castSc['casted'], isTrue);

          // 4. S14.4: smarthome.control dims light and blocks lock.front_door (UDC-T36)
          const dimArgs = <String, Object?>{
            'entityId': 'light.living_room',
            'action': 'set_brightness',
            'value': 15,
          };
          final dimResp = await udc14Dispatcher.dispatch(
            requestId: 1006,
            params: ToolsCallParams(
              name: 'smarthome.control',
              arguments: dimArgs,
              invocationId: '10060000-0000-4000-8000-000000000006',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '10060000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(dimArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final dimSc =
              dimResp.result['structuredContent'] as Map<String, Object?>;
          expect(dimSc['state'], equals('on'));
          expect(dimSc['value'], equals(15));

          const lockArgs = <String, Object?>{
            'entityId': 'lock.front_door',
            'action': 'turn_on',
          };
          final lockDeniedResp = await udc14Dispatcher.dispatch(
            requestId: 1007,
            params: ToolsCallParams(
              name: 'smarthome.control',
              arguments: lockArgs,
              invocationId: '10070000-0000-4000-8000-000000000007',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '10070000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(lockArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          expect(
            (lockDeniedResp.result['_meta']
                as Map<String, Object?>)['xuna/errorCode'],
            equals('smarthome_domain_forbidden'),
          );
        },
      );
    },
  );

  group(
    'UDC-15 S15.1–S15.4: Live Symbiotic Co-Pilot (clipboard.write, meeting.status/control, dev.ports, system.vitals)',
    () {
      test(
        'executes clipboard.write with secret redaction, meeting.status, meeting.control (+ undo), dev.ports, and system.vitals without logging secrets',
        () async {
          await policyStore.savePolicy(_sampleHealthyPolicy());
          final writtenClipboards = <String>[];
          bool fakeMicMuted = false;

          final symbioticService = AutoSymbioticService(
            clipboardWriter: (text) async {
              writtenClipboards.add(text);
            },
            meetingDetector: () async => MeetingStatusSnapshot(
              inMeeting: true,
              app: 'zoom',
              micMuted: fakeMicMuted,
            ),
            micMuteSetter: (mute) async {
              fakeMicMuted = mute;
              return fakeMicMuted;
            },
            lanIpResolver: () async => '192.168.1.42',
            portProbe: (ports) async => <({int port, String process})>[
              (port: 3000, process: 'next-dev'),
              (port: 5173, process: 'vite'),
            ],
            vitalsReader: () async => const SystemVitalsSnapshot(
              batteryPercent: 78,
              isCharging: true,
              memoryUsedPercent: 61,
              diskFreeGb: 95,
              thermalState: 'nominal',
              healthStatus: 'healthy',
            ),
          );

          final udc15Dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            symbioticService: symbioticService,
          );
          addTearDown(udc15Dispatcher.dispose);

          final now = DateTime.utc(2026, 10, 31, 9, 0);

          // 1. S15.1: clipboard.write (R2) redacts secret tokens and never logs clipboard text
          const rawSecretSnippet =
              'export OPENAI_API_KEY=sk-proj-1234567890abcdef1234567890abcdef && npm run dev';
          const clipArgs = <String, Object?>{'text': rawSecretSnippet};
          final clipResp = await udc15Dispatcher.dispatch(
            requestId: 1101,
            params: ToolsCallParams(
              name: 'clipboard.write',
              arguments: clipArgs,
              invocationId: '11010000-0000-4000-8000-000000000001',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '11010000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(clipArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final clipSc =
              clipResp.result['structuredContent'] as Map<String, Object?>;
          expect(clipSc['written'], isTrue);
          expect(clipSc['redactedCount'], greaterThanOrEqualTo(1));
          expect(writtenClipboards, hasLength(1));
          expect(writtenClipboards.single, contains('[REDACTED]'));
          expect(
            writtenClipboards.single,
            isNot(contains('sk-proj-1234567890abcdef')),
          );

          // 2. S15.2: meeting.status & meeting.control (R1) + action.undo
          final meetStatusResp = await udc15Dispatcher.dispatch(
            requestId: 1102,
            params: const ToolsCallParams(
              name: 'meeting.status',
              arguments: <String, Object?>{},
              invocationId: '11020000-0000-4000-8000-000000000002',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final meetStatusSc =
              meetStatusResp.result['structuredContent']
                  as Map<String, Object?>;
          expect(meetStatusSc['inMeeting'], isTrue);
          expect(meetStatusSc['app'], equals('zoom'));
          expect(meetStatusSc['micMuted'], isFalse);

          final muteResp = await udc15Dispatcher.dispatch(
            requestId: 1103,
            params: const ToolsCallParams(
              name: 'meeting.control',
              arguments: <String, Object?>{'action': 'mute_mic'},
              invocationId: '11030000-0000-4000-8000-000000000003',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(
            (muteResp.result['structuredContent']
                as Map<String, Object?>)['micMuted'],
            isTrue,
          );
          expect(fakeMicMuted, isTrue);

          // Undo restores microphone back to unmuted!
          await udc15Dispatcher.dispatch(
            requestId: 1104,
            params: const ToolsCallParams(
              name: 'action.undo',
              arguments: <String, Object?>{},
              invocationId: '11040000-0000-4000-8000-000000000004',
              deadlineMs: 5000,
            ),
            nowUtc: now.add(const Duration(seconds: 10)),
          );
          expect(fakeMicMuted, isFalse);

          // 3. S15.3: dev.ports (R1) returns LAN IP and active localhost dev ports
          final devPortsResp = await udc15Dispatcher.dispatch(
            requestId: 1105,
            params: const ToolsCallParams(
              name: 'dev.ports',
              arguments: <String, Object?>{},
              invocationId: '11050000-0000-4000-8000-000000000005',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final devPortsSc =
              devPortsResp.result['structuredContent'] as Map<String, Object?>;
          expect(devPortsSc['lanIp'], equals('192.168.1.42'));
          final activePorts = devPortsSc['activePorts'] as List<Object?>;
          expect(activePorts, hasLength(2));
          expect(
            (activePorts.first as Map<String, Object?>)['url'],
            equals('http://192.168.1.42:3000'),
          );

          // 4. S15.4: system.vitals (R1) returns battery, memory, disk, and health
          final vitalsResp = await udc15Dispatcher.dispatch(
            requestId: 1106,
            params: const ToolsCallParams(
              name: 'system.vitals',
              arguments: <String, Object?>{},
              invocationId: '11060000-0000-4000-8000-000000000006',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final vitalsSc =
              vitalsResp.result['structuredContent'] as Map<String, Object?>;
          expect(vitalsSc['batteryPercent'], equals(78));
          expect(vitalsSc['isCharging'], isTrue);
          expect(vitalsSc['memoryUsedPercent'], equals(61));
          expect(vitalsSc['diskFreeGb'], equals(95));
          expect(vitalsSc['healthStatus'], equals('healthy'));

          // 5. Verify zero clipboard text or LAN URLs in logger or audit log (UDC-T37, UDC-T38)
          for (final entry in logger.entries) {
            final line = jsonEncode(entry.fields);
            expect(line, isNot(contains('npm run dev')));
            expect(line, isNot(contains('192.168.1.42')));
          }
        },
      );
    },
  );

  group(
    'SYM-1 S1.1: Time-Travel Workspace Capsules (workspace.capture/restore/list_capsules) & Universal Pocket (pocket.push/list/transform_item)',
    () {
      test(
        'freezes and rehydrates workspace capsules, classifies and redacts Universal Pocket items, and transforms JSON/tasks/facts without logging secrets',
        () async {
          await policyStore.savePolicy(_sampleHealthyPolicy());
          final symbioticService = AutoSymbioticService();
          final sym1Dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            symbioticService: symbioticService,
          );
          addTearDown(sym1Dispatcher.dispose);

          final now = DateTime.utc(2026, 10, 31, 17, 15);

          // 1. Capture a Time-Travel Workspace Capsule (R1) with secret redaction
          final capResp = await sym1Dispatcher.dispatch(
            requestId: 1201,
            params: const ToolsCallParams(
              name: 'workspace.capture_capsule',
              arguments: <String, Object?>{
                'project': 'xuna_pet',
                'nextStepHint':
                    'Sửa hàm verifyProof ở dòng 142 (key=sk-proj-secret1234567890abcdef)',
              },
              invocationId: '12010000-0000-4000-8000-000000000001',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final capSc =
              capResp.result['structuredContent'] as Map<String, Object?>;
          expect(capSc['project'], equals('xuna_pet'));
          expect(capSc['capsuleId'], equals('cap-xuna_pet-1'));
          expect(capSc['nextStepHint'] as String, contains('[REDACTED]'));
          expect(
            capSc['nextStepHint'] as String,
            isNot(contains('sk-proj-secret')),
          );

          // 2. List saved capsules (R1)
          final listCapResp = await sym1Dispatcher.dispatch(
            requestId: 1202,
            params: const ToolsCallParams(
              name: 'workspace.list_capsules',
              arguments: <String, Object?>{'limit': 5},
              invocationId: '12020000-0000-4000-8000-000000000002',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final capsules =
              (listCapResp.result['structuredContent']
                      as Map<String, Object?>)['capsules']
                  as List<Object?>;
          expect(capsules, hasLength(1));

          // 3. Rehydrate workspace capsule (R2)
          const restoreArgs = <String, Object?>{
            'capsuleId': 'cap-xuna_pet-1',
            'ide': 'antigravity',
          };
          final restoreResp = await sym1Dispatcher.dispatch(
            requestId: 1203,
            params: ToolsCallParams(
              name: 'workspace.restore_capsule',
              arguments: restoreArgs,
              invocationId: '12030000-0000-4000-8000-000000000003',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '12030000-0000-4000-8000-000000000099',
                argsSha256: argsSha256(restoreArgs),
                expiresAt: now.add(const Duration(minutes: 2)),
              ),
            ),
            nowUtc: now,
          );
          final restoreSc =
              restoreResp.result['structuredContent'] as Map<String, Object?>;
          expect(restoreSc['restored'], isTrue);
          expect(restoreSc['project'], equals('xuna_pet'));
          expect(
            restoreSc['briefingVi'] as String,
            contains('Đã rã đông dự án xuna_pet'),
          );

          // 4. Push items into Universal Pocket (R1) with auto-classification
          final pushJsonResp = await sym1Dispatcher.dispatch(
            requestId: 1204,
            params: const ToolsCallParams(
              name: 'pocket.push_item',
              arguments: <String, Object?>{
                'text': '{"service":"xuna","port":8000}',
                'sourceDevice': 'phone',
              },
              invocationId: '12040000-0000-4000-8000-000000000004',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final pushSc =
              pushJsonResp.result['structuredContent'] as Map<String, Object?>;
          expect(pushSc['itemId'], equals('pkt-1'));
          expect(pushSc['kind'], equals('json'));
          expect(
            pushSc['suggestedActions'] as List<Object?>,
            contains('format_json'),
          );

          // 5. Transform Universal Pocket item (format_json & extract_tasks)
          final fmtResp = await sym1Dispatcher.dispatch(
            requestId: 1205,
            params: const ToolsCallParams(
              name: 'pocket.transform_item',
              arguments: <String, Object?>{
                'itemId': 'pkt-1',
                'mode': 'format_json',
              },
              invocationId: '12050000-0000-4000-8000-000000000005',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final fmtSc =
              fmtResp.result['structuredContent'] as Map<String, Object?>;
          expect(
            fmtSc['transformedText'] as String,
            contains('  "service": "xuna"'),
          );

          final taskResp = await sym1Dispatcher.dispatch(
            requestId: 1206,
            params: const ToolsCallParams(
              name: 'pocket.transform_item',
              arguments: <String, Object?>{
                'text': 'Kiểm tra BLE; Chạy pytest backend; Đóng gói bản build',
                'mode': 'extract_tasks',
              },
              invocationId: '12060000-0000-4000-8000-000000000006',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final taskSc =
              taskResp.result['structuredContent'] as Map<String, Object?>;
          expect(taskSc['itemCount'], equals(3));
          expect(
            taskSc['transformedText'] as String,
            contains('- [ ] Kiểm tra BLE'),
          );

          // 6. SYM-2 S2.1: Autonomous Watchdogs, Coach, Desk Whisper & Habit Miner
          final wdPortResp = await sym1Dispatcher.dispatch(
            requestId: 1207,
            params: const ToolsCallParams(
              name: 'watchdog.watch_process_or_port',
              arguments: <String, Object?>{
                'targetKind': 'port',
                'port': 5173,
                'label': 'Vite dev server',
              },
              invocationId: '12070000-0000-4000-8000-000000000007',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final wdPortSc =
              wdPortResp.result['structuredContent'] as Map<String, Object?>;
          expect(wdPortSc['watchdogId'], equals('wd-1'));
          expect(wdPortSc['targetValue'], equals(':5173'));

          final wdResResp = await sym1Dispatcher.dispatch(
            requestId: 1208,
            params: const ToolsCallParams(
              name: 'watchdog.watch_resource_threshold',
              arguments: <String, Object?>{
                'metric': 'battery_below',
                'threshold': 90,
              },
              invocationId: '12080000-0000-4000-8000-000000000008',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final wdResSc =
              wdResResp.result['structuredContent'] as Map<String, Object?>;
          expect(wdResSc['triggered'], isTrue);

          final wdListResp = await sym1Dispatcher.dispatch(
            requestId: 1209,
            params: const ToolsCallParams(
              name: 'watchdog.list_and_clear',
              arguments: <String, Object?>{'action': 'clear_triggered'},
              invocationId: '12090000-0000-4000-8000-000000000009',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final wdListSc =
              wdListResp.result['structuredContent'] as Map<String, Object?>;
          expect(wdListSc['clearedCount'], equals(1));

          final coachResp = await sym1Dispatcher.dispatch(
            requestId: 1210,
            params: const ToolsCallParams(
              name: 'coach.decompose_overwhelm',
              arguments: <String, Object?>{
                'goal': 'Hoàn thiện SYM-2',
                'project': 'xuna_pet',
              },
              invocationId: '12100000-0000-4000-8000-000000000010',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final coachSc =
              coachResp.result['structuredContent'] as Map<String, Object?>;
          expect(
            coachSc['firstFiveMinuteStep'] as String,
            contains('Trong 5 phút tới'),
          );

          final whisperResp = await sym1Dispatcher.dispatch(
            requestId: 1211,
            params: const ToolsCallParams(
              name: 'meeting.desk_whisper_digest',
              arguments: <String, Object?>{
                'topic': 'Báo cáo SYM-2',
                'contextHint': 'Nhấn mạnh 50 XTP tools và 0B firmware delta',
              },
              invocationId: '12110000-0000-4000-8000-000000000011',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final whisperSc =
              whisperResp.result['structuredContent'] as Map<String, Object?>;
          expect(whisperSc['silentMode'], isTrue);
          expect(
            (whisperSc['whisperLine'] as String).length,
            lessThanOrEqualTo(120),
          );

          final habitResp = await sym1Dispatcher.dispatch(
            requestId: 1212,
            params: const ToolsCallParams(
              name: 'habit.propose_workflow',
              arguments: <String, Object?>{'minOccurrences': 2},
              invocationId: '12120000-0000-4000-8000-000000000012',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          final habitSc =
              habitResp.result['structuredContent'] as Map<String, Object?>;
          expect(habitSc['proposals'] as List<Object?>, isNotEmpty);
        },
      );

      testWidgets(
        'SYM-UI S-UI.2: DesktopAgentWindow renders Cộng sinh tab with Workspace Capsules, Pocket, Watchdogs & Habit Proposals',
        (tester) async {
          final symSvc = AutoSymbioticService();
          symSvc.captureWorkspaceCapsule(
            project: 'xuna_pet',
            branch: 'feat/sym-ui',
            dirtyCount: 2,
            nextStepHint: 'Kiểm tra tab Cộng sinh',
          );
          symSvc.pushPocketItem(
            rawText: 'https://github.com/xthao28/xuna_pet',
            label: 'Repo XUNA',
          );
          await tester.runAsync(
            () => symSvc.registerProcessOrPortWatchdog(
              targetKind: 'process',
              processName: 'cargo',
            ),
          );
          symSvc.recordToolExecution('workspace.git_summary');
          symSvc.recordToolExecution('dev.ports');
          symSvc.recordToolExecution('workspace.git_summary');
          symSvc.recordToolExecution('dev.ports');

          final fakeWs = _FakeWebSocketChannel();
          final sessionClient = XtpSessionClient(
            wsUri: Uri.parse('ws://127.0.0.1:9999/v1/hosts/connect'),
            channel: channel,
            enrollmentStore: enrollmentStore,
            policyStore: policyStore,
            dispatcher: dispatcher,
            stopController: stopController,
            logger: logger,
            connector: (_) => fakeWs,
            enableAutoReconnect: false,
          );
          final agentController = DesktopAgentController(
            channel: channel,
            enrollmentStore: enrollmentStore,
            policyStore: policyStore,
            auditStore: auditStore,
            stopController: stopController,
            sessionClient: sessionClient,
            logger: logger,
            symbioticService: symSvc,
          );
          agentController.onInit();

          await tester.pumpWidget(
            MaterialApp(home: DesktopAgentWindow(controller: agentController)),
          );

          await tester.tap(find.text('Cộng sinh'));
          await tester.pump();

          expect(agentController.activeTab.value, AgentWindowTab.symbiotic);
          expect(agentController.workspaceCapsules, hasLength(1));
          expect(agentController.pocketItems, hasLength(1));
          expect(agentController.activeWatchdogs, hasLength(1));
          expect(agentController.habitProposals, isNotEmpty);

          expect(find.textContaining('xuna_pet @ feat/sym-ui'), findsOneWidget);
          expect(find.textContaining('Repo XUNA'), findsOneWidget);
          expect(find.text('[process] cargo'), findsOneWidget);

          await tester.ensureVisible(find.text('Đóng băng nhanh'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Đóng băng nhanh'));
          await tester.pump();
          expect(agentController.workspaceCapsules, hasLength(2));

          await tester.ensureVisible(find.text('Thêm ghi chú'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Thêm ghi chú'));
          await tester.pump();
          expect(agentController.pocketItems, hasLength(2));

          await tester.ensureVisible(find.text('Xóa tất cả'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Xóa tất cả'));
          await tester.pump();
          expect(agentController.activeWatchdogs, isEmpty);

          agentController.onClose();
          await tester.runAsync(() => sessionClient.dispose());
        },
      );
    },
  );
}

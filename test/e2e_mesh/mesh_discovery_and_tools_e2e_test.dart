import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/desktop_tray_service.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_shared/xuna_shared.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Wave 1 Opaque-Box E2E Suite for `desktop/` (Features 9, 10, 11, 12).
///
/// Wave 2 (`BLOCKED_ON_M3`, tracked in `handoff.md` and `TEST_INFRA.md`) will
/// live in `mesh_presence_and_focus_e2e_test.dart` once M3 exposes:
/// - `XunaHostChannel.presenceProbe()` / `HostPresenceSnapshot`
/// - Dart `subnetHash` calculator
/// - `XtpSessionClient` `xuna/presence`, `xuna/resources`, `xuna/focusRequest`
/// - `DesktopTrayService` `focus_here` / `toggle_follow_me` & `Ctrl+Alt+Shift+F`
/// - macOS Swift `RunnerTests` presence probes (`xcodebuild test`)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tier 1 — SharedHostPlatform Linux Parity (F9)', () {
    test('SharedHostPlatform.linux reports isDesktop == true and isMobile == false', () {
      expect(SharedHostPlatform.linux.wire, equals('linux'));
      expect(SharedHostPlatform.linux.isDesktop, isTrue);
      expect(SharedHostPlatform.linux.isMobile, isFalse);
      expect(
        SharedHostPlatform.fromWire('linux'),
        equals(SharedHostPlatform.linux),
      );
      expect(
        SharedHostPlatform.tryParse('  LINUX  '),
        equals(SharedHostPlatform.linux),
      );
    });
  });

  group('Tier 1/2 — Normalized Resource Digest Privacy (F11)', () {
    test(
      'T1-F11-01 & T2-F11-01: AutoAppScanner excludes hardDeniedAppsAndProcesses and emits normalized IDs without paths',
      () {
        final deniedSeeds = <DiscoveredApp>[
          for (final denied in hardDeniedAppsAndProcesses.take(6))
            DiscoveredApp(
              id: AutoAppScanner.normalizeId(denied),
              name: denied,
              kind: AppLaunchKind.bundle,
              target: '/Applications/$denied.app',
              bundleId: denied,
            ),
        ];
        final safeSeeds = <DiscoveredApp>[
          const DiscoveredApp(
            id: 'alpha_studio',
            name: 'Alpha Studio',
            kind: AppLaunchKind.bundle,
            target: '/Applications/Alpha Studio.app',
            bundleId: 'com.example.alphastudio',
          ),
          DiscoveredApp(
            id: AutoAppScanner.normalizeId('Beta Reader Pro.app'),
            name: 'Beta Reader Pro',
            kind: AppLaunchKind.exe,
            target: r'C:\Program Files\BetaReader\BetaReader.exe',
          ),
        ];

        final scanner = AutoAppScanner(
          seedApps: <DiscoveredApp>[...deniedSeeds, ...safeSeeds],
          scanFileSystem: false,
        );
        final discovered = scanner.discoverApps();
        final digestIds = discovered.map((a) => a.id).toList(growable: false);

        expect(digestIds, equals(<String>['alpha_studio', 'beta_reader_pro']));
        for (final id in digestIds) {
          expect(RegExp(r'^[a-z0-9_.-]{1,64}$').hasMatch(id), isTrue);
          expect(id.contains('/'), isFalse);
          expect(id.contains(r'\'), isFalse);
        }
        final encodedDigest = jsonEncode(<String, Object?>{
          'installedApps': digestIds,
        });
        expect(encodedDigest.contains('/Applications/'), isFalse);
        expect(encodedDigest.contains(r'C:\'), isFalse);
      },
    );

    test(
      'T1-F11-02 & T2-F11-02: AutoWorkspaceIndexer.sanitizeAlias strips paths/specials, caps at 64, and leaks zero paths',
      () async {
        final tempRoot =
            await Directory.systemTemp.createTemp('xuna_ws_e2e_');
        addTearDown(() => tempRoot.delete(recursive: true));

        final messyDir = Directory(
          '${tempRoot.path}/My Repo (2026) / Special! Project',
        );
        await messyDir.create(recursive: true);
        await Directory('${messyDir.path}/.git').create();

        final longName = 'project_${'segment_' * 10}end';
        final longDir = Directory('${tempRoot.path}/$longName');
        await longDir.create(recursive: true);
        await File('${longDir.path}/AGENTS.md').writeAsString('# agent');

        final sanitizedMessy = AutoWorkspaceIndexer.sanitizeAlias(
          'My Repo (2026) / Special! Project',
        );
        expect(
          RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(sanitizedMessy),
          isTrue,
        );
        expect(sanitizedMessy.contains('/'), isFalse);
        expect(sanitizedMessy.contains(r'\'), isFalse);

        final sanitizedLong = AutoWorkspaceIndexer.sanitizeAlias(longName);
        expect(sanitizedLong.length, lessThanOrEqualTo(64));
        expect(
          RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(sanitizedLong),
          isTrue,
        );

        final indexer = AutoWorkspaceIndexer(
          customScanRoots: <String>[tempRoot.path],
          scanDefaultLocations: false,
        );
        final workspaces = indexer.discoverWorkspaces();
        final aliases = workspaces.map((w) => w.alias).toList(growable: false);

        expect(aliases, contains(sanitizedLong));
        expect(aliases, contains('Special_Project'));
        for (final alias in aliases) {
          expect(RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(alias), isTrue);
          expect(alias.contains('/'), isFalse);
          expect(alias.contains(r'\'), isFalse);
          expect(alias.contains(tempRoot.path), isFalse);
        }
      },
    );
  });

  group('Tier 1/2 — HostToolDispatcher Cross-Machine Tools & Guardrails (F12)', () {
    late Directory tempDir;
    late ContentFreeLogger logger;
    late HostPolicyStore policyStore;
    late EmergencyStopController stopController;
    late FakeXunaHostChannel fakeChannel;
    late List<String> capturedClipboardWrites;
    late AutoSymbioticService symbioticService;
    late HostToolDispatcher dispatcher;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('xuna_disp_e2e_');
      logger = ContentFreeLogger();
      policyStore = HostPolicyStore(
        policyFile: File('${tempDir.path}/host-policy.json'),
        logger: logger,
      );
      await policyStore.writeDefaultPolicy();
      stopController = EmergencyStopController(logger: logger);
      fakeChannel = FakeXunaHostChannel(
        systemInfo: const HostSystemInfo(
          platform: HostPlatform.macos,
          osVersion: '15.1.0',
          hostname: 'test-workstation',
        ),
      );
      capturedClipboardWrites = <String>[];
      symbioticService = AutoSymbioticService(
        clipboardWriter: (text) async {
          capturedClipboardWrites.add(text);
        },
      );
      final wsDir = Directory('${tempDir.path}/ws_alpha');
      await wsDir.create();
      final indexer = AutoWorkspaceIndexer(
        seedWorkspaces: <DiscoveredWorkspace>[
          DiscoveredWorkspace(
            alias: 'ws_alpha',
            path: wsDir.path,
            lastModified: DateTime.utc(2026, 11, 20, 10, 0),
          ),
        ],
        scanDefaultLocations: false,
        gitRunner: (exe, args) async => ProcessResult(
          0,
          0,
          '## main...origin/main\n M lib/main.dart\n',
          '',
        ),
      );
      dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: fakeChannel,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        logger: logger,
        workspaceIndexer: indexer,
        symbioticService: symbioticService,
      );
    });

    tearDown(() async {
      dispatcher.dispose();
      await stopController.dispose();
      await policyStore.dispose();
      await tempDir.delete(recursive: true);
    });

    test('DSK-E2E-06a: manifest exposes non-idempotent media.play_pause and cross-machine tools', () async {
      final manifest = await dispatcher.buildManifest();
      final byName = <String, ToolDescriptor>{
        for (final tool in manifest) tool.name: tool,
      };
      expect(
        byName.keys,
        containsAll(const <String>[
          'media.now_playing',
          'media.play_pause',
          'browser.current_url',
          'workspace.capture_capsule',
          'selection.read',
          'clipboard.write',
        ]),
      );
      expect(byName['media.play_pause']!.policy.idempotent, isFalse);
    });

    test('DSK-E2E-06b: media.now_playing & media.play_pause execute and propagate errors (H4)', () async {
      final now = DateTime.utc(2026, 11, 20, 12, 0);
      final npResp = await dispatcher.dispatch(
        requestId: 'req-np-1',
        params: const ToolsCallParams(
          name: 'media.now_playing',
          arguments: <String, Object?>{},
          invocationId: '10000000-0000-4000-8000-000000000001',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(npResp.result['isError'], isFalse);
      final npSc = npResp.result['structuredContent']! as Map<String, Object?>;
      expect(npSc['state'], equals('playing'));

      final ppResp = await dispatcher.dispatch(
        requestId: 'req-pp-1',
        params: const ToolsCallParams(
          name: 'media.play_pause',
          arguments: <String, Object?>{},
          invocationId: '10000000-0000-4000-8000-000000000002',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(ppResp.result['isError'], isFalse);

      // Error propagation when channel reports needs_permission.
      fakeChannel.nextException = const XunaHostChannelException(
        status: XtpStatus.needsPermission,
        errorCode: 'automation_denied',
      );
      final errResp = await dispatcher.dispatch(
        requestId: 'req-pp-2',
        params: const ToolsCallParams(
          name: 'media.play_pause',
          arguments: <String, Object?>{},
          invocationId: '10000000-0000-4000-8000-000000000003',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(errResp.result['isError'], isTrue);
      final meta = errResp.result['_meta']! as Map<String, Object?>;
      expect(meta['xuna/status'], equals('needs_permission'));
      expect(meta['xuna/errorCode'], equals('automation_denied'));
    });

    test('T2-F12-03 & DSK-E2E-06c: browser.current_url & workspace.capture_capsule enforce HTTPS and no paths', () async {
      final now = DateTime.utc(2026, 11, 20, 12, 0);
      const urlArgs = <String, Object?>{'browser': 'edge'};
      final urlApproval = ApprovalToken(
        approvalId: '20000000-0000-4000-8000-000000000001',
        argsSha256: argsSha256(urlArgs),
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      fakeChannel.browserCurrentUrlResult = const BrowserTabSnapshot(
        url: 'https://github.com/xthao28/xuna_pet',
        browser: 'edge',
      );
      final okUrl = await dispatcher.dispatch(
        requestId: 'req-url-1',
        params: ToolsCallParams(
          name: 'browser.current_url',
          arguments: urlArgs,
          invocationId: '20000000-0000-4000-8000-000000000002',
          deadlineMs: 5000,
          approval: urlApproval,
        ),
        nowUtc: now,
      );
      expect(okUrl.result['isError'], isFalse);
      final okSc = okUrl.result['structuredContent']! as Map<String, Object?>;
      expect(okSc['host'], equals('github.com'));
      expect(okSc['browser'], equals('edge'));

      // Unsafe http:// or userinfo URL must fail closed.
      fakeChannel.browserCurrentUrlResult = const BrowserTabSnapshot(
        url: 'http://127.0.0.1:8080/internal',
        browser: 'edge',
      );
      final badUrl = await dispatcher.dispatch(
        requestId: 'req-url-2',
        params: ToolsCallParams(
          name: 'browser.current_url',
          arguments: urlArgs,
          invocationId: '20000000-0000-4000-8000-000000000003',
          deadlineMs: 5000,
          approval: urlApproval,
        ),
        nowUtc: now,
      );
      expect(badUrl.result['isError'], isTrue);
      final badMeta = badUrl.result['_meta']! as Map<String, Object?>;
      expect(badMeta['xuna/status'], equals('invalid_args'));
      expect(badMeta['xuna/errorCode'], equals('url_invalid'));

      // workspace.capture_capsule returns content-free alias + git counts without real paths.
      final capResp = await dispatcher.dispatch(
        requestId: 'req-cap-1',
        params: const ToolsCallParams(
          name: 'workspace.capture_capsule',
          arguments: <String, Object?>{'project': 'ws_alpha'},
          invocationId: '20000000-0000-4000-8000-000000000004',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(capResp.result['isError'], isFalse);
      final capSc = capResp.result['structuredContent']! as Map<String, Object?>;
      expect(capSc['project'], equals('ws_alpha'));
      expect(capSc['branch'], equals('main'));
      expect(capSc['dirtyCount'], equals(1));
      expect(jsonEncode(capSc).contains(tempDir.path), isFalse);
    });

    test('T2-F12-01 & T2-F12-02: selection.read & clipboard.write enforce bounds, approval, and redaction', () async {
      final now = DateTime.utc(2026, 11, 20, 12, 0);

      // selection.read rejects maxChars < 80 or > 1200.
      for (final badMax in const <int>[79, 1201]) {
        final badRead = await dispatcher.dispatch(
          requestId: 'req-sel-$badMax',
          params: ToolsCallParams(
            name: 'selection.read',
            arguments: <String, Object?>{'maxChars': badMax},
            invocationId: '30000000-0000-4000-8000-0000000000$badMax',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(badRead.result['isError'], isTrue);
        final meta = badRead.result['_meta']! as Map<String, Object?>;
        expect(meta['xuna/status'], equals('invalid_args'));
      }

      // selection.read caps at 1200 and redacts secrets.
      fakeChannel.clipboardTextResult =
          'token=sk-secretTokenValue987654321 ${'word ' * 600}';
      final okRead = await dispatcher.dispatch(
        requestId: 'req-sel-ok',
        params: const ToolsCallParams(
          name: 'selection.read',
          arguments: <String, Object?>{'maxChars': 1200},
          invocationId: '30000000-0000-4000-8000-000000000001',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(okRead.result['isError'], isFalse);
      final readSc = okRead.result['structuredContent']! as Map<String, Object?>;
      final textOut = readSc['text']! as String;
      expect(textOut.length, lessThanOrEqualTo(1200));
      expect(readSc['truncated'], isTrue);
      expect(readSc['redactedCount'], greaterThanOrEqualTo(1));
      expect(textOut, isNot(contains('sk-secretTokenValue987654321')));
      expect(textOut, contains('[REDACTED]'));

      // clipboard.write rejects missing R2 approval.
      const clipText = 'hello ghp_secretToken1234567890';
      const clipArgs = <String, Object?>{'text': clipText};
      final noApproval = await dispatcher.dispatch(
        requestId: 'req-clip-noauth',
        params: const ToolsCallParams(
          name: 'clipboard.write',
          arguments: clipArgs,
          invocationId: '30000000-0000-4000-8000-000000000002',
          deadlineMs: 5000,
        ),
        nowUtc: now,
      );
      expect(noApproval.result['isError'], isTrue);
      expect(
        (noApproval.result['_meta']! as Map<String, Object?>)['xuna/errorCode'],
        equals('approval_required'),
      );
      expect(capturedClipboardWrites, isEmpty);

      // clipboard.write rejects empty or > 4000 chars.
      for (final invalidText in <String>['', '   ', 'a' * 4001]) {
        final badWrite = await dispatcher.dispatch(
          requestId: 'req-clip-bad-${invalidText.length}',
          params: ToolsCallParams(
            name: 'clipboard.write',
            arguments: <String, Object?>{'text': invalidText},
            invocationId:
                '30000000-0000-4000-8000-00000000100${invalidText.length.clamp(0, 9)}',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '30000000-0000-4000-8000-000000000009',
              argsSha256: argsSha256(<String, Object?>{'text': invalidText}),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(badWrite.result['isError'], isTrue);
        expect(
          (badWrite.result['_meta']! as Map<String, Object?>)['xuna/status'],
          equals('invalid_args'),
        );
      }

      // Valid R2 approval writes redacted text via injected writer.
      final writeResp = await dispatcher.dispatch(
        requestId: 'req-clip-ok',
        params: ToolsCallParams(
          name: 'clipboard.write',
          arguments: clipArgs,
          invocationId: '30000000-0000-4000-8000-000000000005',
          deadlineMs: 5000,
          approval: ApprovalToken(
            approvalId: '30000000-0000-4000-8000-000000000006',
            argsSha256: argsSha256(clipArgs),
            expiresAt: now.add(const Duration(minutes: 5)),
          ),
        ),
        nowUtc: now,
      );
      expect(writeResp.result['isError'], isFalse);
      final writeSc =
          writeResp.result['structuredContent']! as Map<String, Object?>;
      expect(writeSc['written'], isTrue);
      expect(writeSc['redactedCount'], equals(1));
      expect(capturedClipboardWrites.single, equals('hello [REDACTED]'));
    });
  });

  group('Tier 1/2 — MethodChannel(xuna/host) presenceProbe Wire Contract (F10, H1/H2/H4)', () {
    const channel = MethodChannel('xuna/host');

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test(
      'DSK-E2E-02: presenceProbe wire contract preserves null battery on desktop and reads laptop telemetry',
      () async {
        var mode = 'laptop';
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method != 'presenceProbe') return null;
              if (mode == 'laptop') {
                return <String, Object?>{
                  'idleSeconds': 12,
                  'screenLocked': false,
                  'mediaPlaying': true,
                  'batteryPercent': 78,
                  'isCharging': true,
                  'foregroundAppId': 'editor_app',
                };
              }
              return <String, Object?>{
                'idleSeconds': 0,
                'screenLocked': true,
                'mediaPlaying': false,
                'batteryPercent': null,
                'isCharging': null,
                'foregroundAppId': null,
              };
            });

        final laptopRes = await channel.invokeMapMethod<String, Object?>(
          'presenceProbe',
        );
        expect(laptopRes, isNotNull);
        expect(laptopRes!['idleSeconds'], equals(12));
        expect(laptopRes['batteryPercent'], equals(78));
        expect(laptopRes['isCharging'], isTrue);

        mode = 'desktop_no_battery';
        final desktopRes = await channel.invokeMapMethod<String, Object?>(
          'presenceProbe',
        );
        expect(desktopRes, isNotNull);
        expect(desktopRes!['screenLocked'], isTrue);
        expect(desktopRes['batteryPercent'], isNull);
        expect(desktopRes['isCharging'], isNull);
        expect(desktopRes['foregroundAppId'], isNull);
      },
    );

    test(
      'DSK-E2E-03: presenceProbe PlatformException propagates fail-closed without fabricated defaults',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              if (call.method == 'presenceProbe') {
                throw PlatformException(
                  code: 'failed',
                  message: 'CGSession unavailable',
                );
              }
              return null;
            });

        await expectLater(
          channel.invokeMapMethod<String, Object?>('presenceProbe'),
          throwsA(
            isA<PlatformException>().having((e) => e.code, 'code', 'failed'),
          ),
        );
      },
    );
  });

  group('Tier 3 — Emergency Stop & DesktopTrayService Isolation (F11, H1)', () {
    test('DSK-E2E-05: EmergencyStopController blocks action tools while allowing host.status and resuming cleanly', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('xuna_estop_e2e_');
      addTearDown(() => tempDir.delete(recursive: true));

      final logger = ContentFreeLogger();
      final policyStore = HostPolicyStore(
        policyFile: File('${tempDir.path}/host-policy.json'),
        logger: logger,
      );
      await policyStore.writeDefaultPolicy();
      final enrollmentStore = EnrollmentStateStore(
        stateFile: File('${tempDir.path}/host-state.json'),
      );
      final stopController = EmergencyStopController(logger: logger);
      final channel = FakeXunaHostChannel();
      final dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: channel,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        logger: logger,
        enrollmentStore: enrollmentStore,
      );
      final sessionClient = XtpSessionClient(
        wsUri: Uri.parse('wss://localhost:8443/v1/hosts/ws'),
        channel: channel,
        enrollmentStore: enrollmentStore,
        policyStore: policyStore,
        dispatcher: dispatcher,
        stopController: stopController,
        logger: logger,
        enableAutoReconnect: false,
      );
      final agentController = DesktopAgentController(
        channel: channel,
        enrollmentStore: enrollmentStore,
        policyStore: policyStore,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        sessionClient: sessionClient,
        logger: logger,
      );
      final trayService = DesktopTrayService(controller: agentController);
      addTearDown(() async {
        await trayService.dispose();
        await sessionClient.dispose();
        dispatcher.dispose();
        await stopController.dispose();
        await policyStore.dispose();
      });

      // Trigger stop via tray menu item.
      trayService.onTrayMenuItemClick(MenuItem(key: 'stop', label: 'Stop'));
      expect(stopController.isStopped, isTrue);

      // Action tool must be denied with 'stopped'.
      final stoppedPlay = await dispatcher.dispatch(
        requestId: 'req-stop-1',
        params: const ToolsCallParams(
          name: 'media.play_pause',
          arguments: <String, Object?>{},
          invocationId: '40000000-0000-4000-8000-000000000001',
          deadlineMs: 5000,
        ),
      );
      expect(stoppedPlay.result['isError'], isTrue);
      expect(
        (stoppedPlay.result['_meta']! as Map<String, Object?>)['xuna/errorCode'],
        equals('stopped'),
      );

      // host.status stays allowed even during E-Stop (contract §5.6.5).
      final statusResp = await dispatcher.dispatch(
        requestId: 'req-stop-2',
        params: const ToolsCallParams(
          name: 'host.status',
          arguments: <String, Object?>{},
          invocationId: '40000000-0000-4000-8000-000000000002',
          deadlineMs: 5000,
        ),
      );
      expect(statusResp.result['isError'], isFalse);

      // Resume via tray menu restores normal tool execution.
      trayService.onTrayMenuItemClick(MenuItem(key: 'resume', label: 'Resume'));
      expect(stopController.isStopped, isFalse);

      final resumedPlay = await dispatcher.dispatch(
        requestId: 'req-stop-3',
        params: const ToolsCallParams(
          name: 'media.play_pause',
          arguments: <String, Object?>{},
          invocationId: '40000000-0000-4000-8000-000000000003',
          deadlineMs: 5000,
        ),
      );
      expect(resumedPlay.result['isError'], isFalse);
    });
  });
}

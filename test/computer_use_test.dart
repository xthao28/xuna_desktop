import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/computer_use/driver_map.dart';
import 'package:xuna_desktop/features/computer_use/mcp_stdio_client.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/ui/desktop_agent_window.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

HostPolicy _buildCuTestPolicy() => HostPolicy(
  schemaVersion: 1,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.media: FamilyPolicyDecision.allow,
    ToolFamily.app: FamilyPolicyDecision.allow,
    ToolFamily.url: FamilyPolicyDecision.allow,
    ToolFamily.workflow: FamilyPolicyDecision.allow,
    ToolFamily.cu: FamilyPolicyDecision.allow,
    ToolFamily.screen: FamilyPolicyDecision.allow,
    ToolFamily.ui: FamilyPolicyDecision.allow,
    ToolFamily.input: FamilyPolicyDecision.allow,
  },
  apps: <AllowedAppConfig>[
    AllowedAppConfig(
      id: 'explorer',
      name: 'File Explorer',
      kind: AppLaunchKind.exe,
      target: r'C:\Windows\explorer.exe',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'calendar',
      name: 'Calendar',
      kind: AppLaunchKind.bundle,
      target: 'com.apple.iCal',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'browser',
      name: 'Browser',
      kind: AppLaunchKind.exe,
      target: r'C:\Program Files\Mozilla Firefox\firefox.exe',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>['calendar.google.com', 'docs.google.com'],
  workflows: const <WorkflowConfig>[],
  players: const <String>['spotify'],
);

void main() {
  group('S8.1 — Cua Driver evaluation, v3 capability manifest and MCP stdio', () {
    test('maps all 8 XUNA computer-use tools to Cua Driver 0.38.0 MCP tools', () {
      expect(CuaDriverMap.pinnedDriverVersion, equals('0.38.0'));
      expect(CuaDriverMap.pinnedContractVersion, equals('0.8.0'));
      expect(CuaDriverMap.driverLicense, equals('MIT'));
      expect(CuaDriverMap.allowPerceptionExtension, isFalse);

      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'cu.session_start'),
        equals('start_session'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(
          xunaToolName: 'screen.capture',
          arguments: const <String, Object?>{'scope': 'active_window'},
        ),
        equals('get_window_state'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(
          xunaToolName: 'screen.capture',
          arguments: const <String, Object?>{'scope': 'screen'},
        ),
        equals('get_desktop_state'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'ui.inspect'),
        equals('get_window_state'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'input.click'),
        equals('click'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'input.type_text'),
        equals('type_text'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(
          xunaToolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Enter'},
        ),
        equals('press_key'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(
          xunaToolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Ctrl+S'},
        ),
        equals('hotkey'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'input.scroll'),
        equals('scroll'),
      );
      expect(
        CuaDriverMap.toCuaDriverTool(xunaToolName: 'cu.session_end'),
        equals('end_session'),
      );
    });

    test('generates bounded Capability Manifest v3 YAML without AGPL tools', () {
      final policy = _buildCuTestPolicy();
      final yaml = CuaDriverMap.buildBoundedCapabilityManifestYaml(
        allowedApps: policy.apps,
        allowedDomains: policy.urlDomains,
        maxMinutes: 10,
      );
      expect(yaml, contains('version: 3'));
      expect(yaml, isNot(contains('mode:')));
      expect(yaml, contains('expires_after: 10m'));
      expect(yaml, contains('idle_timeout: 5m'));
      expect(yaml, contains("executable: 'C:\\Windows\\explorer.exe'"));
      expect(yaml, contains("bundle_id: 'com.apple.iCal'"));
      expect(yaml, contains("https://calendar.google.com"));
      expect(yaml, contains('- get_window_state'));
      expect(yaml, contains('deny:'));
      expect(yaml, contains('- parse_visual_regions'));
      expect(yaml, contains('- clipboard_read'));
      expect(yaml, contains('- escalate_session'));

      final macEnv = CuaDriverMap.buildLaunchEnvironment(
        manifestFilePath: '/tmp/xuna-cu.yaml',
        platform: HostPlatform.macos,
      );
      expect(macEnv['CUA_DRIVER_PERMISSION_MODE'], equals('bounded'));
      expect(macEnv['CUA_DRIVER_CAPABILITY_MANIFEST_APPROVED'], equals('1'));
      expect(macEnv['CUA_DRIVER_EMBEDDED'], equals('1'));
      expect(
        macEnv['CUA_DRIVER_HOST_BUNDLE_ID'],
        equals('com.xuna.desktop'),
      );
    });

    test('McpStdioClient speaks MCP 2026-07-28 over stdio with CuaDriverComputerUseProvider', () async {
      final stdoutController = StreamController<String>();
      final sentLines = <Map<String, Object?>>[];

      final client = McpStdioClient.fromStreams(
        stdoutLines: stdoutController.stream,
        writeStdinLine: (line) {
          final req = (jsonDecode(line) as Map).cast<String, Object?>();
          sentLines.add(req);
          final id = req['id'] as int;
          final method = req['method'] as String;
          final params = (req['params'] as Map).cast<String, Object?>();
          final meta = (params['_meta'] as Map).cast<String, Object?>();
          expect(
            meta['io.modelcontextprotocol/protocolVersion'],
            equals('2026-07-28'),
          );

          if (method == 'server/discover') {
            stdoutController.add(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, Object?>{
                  'resultType': 'complete',
                  'protocolVersion': '2026-07-28',
                },
              }),
            );
          } else if (method == 'tools/call') {
            final toolName = params['name'] as String;
            if (toolName == 'get_window_state') {
              stdoutController.add(
                jsonEncode(<String, Object?>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, Object?>{
                    'structuredContent': <String, Object?>{
                      'appId': 'explorer',
                      'processName': 'explorer.exe',
                      'windowTitle': 'Reports',
                      'nodes': <Map<String, Object?>>[
                        <String, Object?>{
                          'id': 's0000002a:1',
                          'role': 'list_item',
                          'name': 'BaoCao_Thang10.xlsx',
                          'enabled': true,
                        },
                      ],
                    },
                  },
                }),
              );
            } else {
              stdoutController.add(
                jsonEncode(<String, Object?>{
                  'jsonrpc': '2.0',
                  'id': id,
                  'result': <String, Object?>{
                    'effect': 'changed',
                    'route': 'background',
                  },
                }),
              );
            }
          }
        },
      );

      final discoverRes = await client.discover();
      expect(discoverRes['resultType'], equals('complete'));

      final provider = CuaDriverComputerUseProvider(
        clientFactory: (_) async => client,
      );
      await provider.startSession(
        sessionId: 'cu-1',
        capabilityManifestYaml: 'version: 3',
      );
      final obs = await provider.inspectActiveWindow(maxNodes: 100);
      expect(obs.appId, equals('explorer'));
      expect(obs.windowTitle, equals('Reports'));
      expect(obs.nodes.single['id'], equals('s0000002a:1'));

      await provider.endSession(sessionId: 'cu-1');
      expect(client.isClosed, isTrue);
      await stdoutController.close();
    });
  });

  group('S8.2 — ComputerUseSessionManager hard refusals, budgets and UI overlay', () {
    test('enforces allowlist, denylist, elevation, password refusal, lexicon escalation and budgets', () async {
      final stopController = EmergencyStopController(
        logger: ContentFreeLogger(),
      );
      final fallback = FallbackUiaAxComputerUseProvider();
      final manager = ComputerUseSessionManager(
        provider: fallback,
        stopController: stopController,
      );
      final policy = _buildCuTestPolicy();

      // 1. Cannot start session with a denylisted terminal app
      expect(
        () => manager.startSession(
          goal: 'Chạy lệnh terminal',
          apps: const <String>['powershell'],
          domains: const <String>[],
          maxSteps: 5,
          maxMinutes: 5,
          policy: policy,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'denylisted_target_forbidden',
          ),
        ),
      );

      // 2. Start valid session for explorer + browser
      final sessionId = await manager.startSession(
        goal: 'Mở file báo cáo mới nhất trong thư mục Reports',
        apps: const <String>['explorer', 'browser'],
        domains: const <String>['calendar.google.com'],
        maxSteps: 4,
        maxMinutes: 5,
        policy: policy,
      );
      expect(manager.hasActiveSession, isTrue);

      // 3. Password fields are redacted on inspect and refused on type_text/click
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 's00000001:1',
            'role': 'list_item',
            'name': 'BaoCao_2026_10_31.pdf',
            'enabled': true,
          },
          <String, Object?>{
            'id': 's00000001:2',
            'role': 'password',
            'name': 'Mật khẩu tài liệu',
            'value': 'topsecret',
            'enabled': true,
          },
          <String, Object?>{
            'id': 's00000001:3',
            'role': 'button',
            'name': 'Xóa vĩnh viễn',
            'enabled': true,
          },
        ],
      );

      final inspected = await manager.inspectWindow(maxNodes: 50);
      final nodes = (inspected['nodes'] as List).cast<Map<String, Object?>>();
      expect(nodes[1]['name'], equals('•••'));
      expect(nodes[1].containsKey('value'), isFalse);

      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{
            'elementId': 's00000001:2',
            'text': '123456',
          },
          hasR3Approval: true,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'password_field_forbidden',
          ),
        ),
      );

      // 4. Consequential button in UI tree ("Xóa vĩnh viễn") requires R3 approval
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 's00000001:3'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'approval_required',
          ),
        ),
      );

      // 5. Window outside allowlist is refused
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'other_app',
        processName: 'other.exe',
        windowTitle: 'Other App',
        nodes: <Map<String, Object?>>[],
      );
      await expectLater(
        () => manager.inspectWindow(maxNodes: 50),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'target_outside_allowlist',
          ),
        ),
      );

      // 6. Elevated window is refused (UIPI boundary)
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Admin Explorer',
        isElevated: true,
        nodes: <Map<String, Object?>>[],
      );
      await expectLater(
        () => manager.inspectWindow(maxNodes: 50),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'elevated_window_forbidden',
          ),
        ),
      );

      // 7. Browser window on unallowed domain is refused
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'browser',
        processName: 'firefox.exe',
        windowTitle: 'Evil Phishing Site',
        browserUrl: 'https://evil.example.com/login',
        nodes: <Map<String, Object?>>[],
      );
      await expectLater(
        () => manager.inspectWindow(maxNodes: 50),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'domain_outside_allowlist',
          ),
        ),
      );

      // 8. Browser window on allowlisted domain succeeds
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'browser',
        processName: 'firefox.exe',
        windowTitle: 'Google Calendar',
        browserUrl: 'https://calendar.google.com/calendar/u/0/r',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 's00000005:1',
            'role': 'button',
            'name': 'Tạo sự kiện',
            'enabled': true,
          },
        ],
      );
      final calTree = await manager.inspectWindow(maxNodes: 50);
      expect(calTree['appId'], equals('browser'));

      // 9. Duplicate action on the same element twice stops the session
      final firstClick = await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': 's00000005:1'},
        hasR3Approval: false,
      );
      expect(firstClick['effect'], equals('changed'));

      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 's00000005:1'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'duplicate_action',
          ),
        ),
      );
      expect(manager.hasActiveSession, isFalse);

      // 10. Three consecutive no_change effects stops the session with no_progress
      await manager.startSession(
        goal: 'Kiểm tra dừng khi không tiến triển',
        apps: const <String>['explorer'],
        domains: const <String>[],
        maxSteps: 10,
        maxMinutes: 5,
        policy: policy,
        requestedSessionId: sessionId,
      );
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 's00000009:1',
            'role': 'list_item',
            'name': 'Item 1',
            'enabled': true,
          },
          <String, Object?>{
            'id': 's00000009:2',
            'role': 'list_item',
            'name': 'Item 2',
            'enabled': true,
          },
          <String, Object?>{
            'id': 's00000009:3',
            'role': 'list_item',
            'name': 'Item 3',
            'enabled': true,
          },
        ],
      );
      fallback.simulateSilentUipiDrop = true;

      final step1 = await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': 's00000009:1'},
        hasR3Approval: false,
      );
      expect(step1['effect'], equals('no_change'));

      final step2 = await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': 's00000009:2'},
        hasR3Approval: false,
      );
      expect(step2['effect'], equals('no_change'));

      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 's00000009:3'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'no_progress',
          ),
        ),
      );
      expect(manager.hasActiveSession, isFalse);
      manager.dispose();
    });

    testWidgets(
      'DesktopAgentWindow displays visible amber overlay border and banner during active CU session',
      (tester) async {
        late final Directory tempDir;
        late final DesktopAgentController controller;
        late final ComputerUseSessionManager cuManager;
        late final HostToolDispatcher dispatcher;

        await tester.runAsync(() async {
          tempDir = await Directory.systemTemp.createTemp('xuna_cu_ui_');
          final paths = AgentPaths.resolve(overrideRootDir: tempDir);
          await paths.ensureDirectories();
          final channel = FakeXunaHostChannel();
          final logger = ContentFreeLogger();
          final enrollmentStore = EnrollmentStateStore(
            stateFile: paths.enrollmentStateFile,
          );
          final policyStore = HostPolicyStore(
            policyFile: paths.policyFile,
            logger: logger,
          );
          await policyStore.savePolicy(_buildCuTestPolicy());
          final auditStore = AuditLogStore(auditDir: paths.auditDir);
          final stopController = EmergencyStopController(logger: logger);
          final fallback = FallbackUiaAxComputerUseProvider();
          cuManager = ComputerUseSessionManager(
            provider: fallback,
            stopController: stopController,
          );
          dispatcher = HostToolDispatcher(
            policyStore: policyStore,
            channel: channel,
            auditStore: auditStore,
            stopController: stopController,
            logger: logger,
            enrollmentStore: enrollmentStore,
            computerUseManager: cuManager,
          );
          final sessionClient = XtpSessionClient(
            wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
            channel: channel,
            enrollmentStore: enrollmentStore,
            policyStore: policyStore,
            dispatcher: dispatcher,
            stopController: stopController,
            logger: logger,
            enableAutoReconnect: false,
          );
          controller = DesktopAgentController(
            channel: channel,
            enrollmentStore: enrollmentStore,
            policyStore: policyStore,
            auditStore: auditStore,
            stopController: stopController,
            sessionClient: sessionClient,
            logger: logger,
            computerUseManager: cuManager,
          );
          controller.onInit();
        });

        await tester.pumpWidget(
          MaterialApp(home: DesktopAgentWindow(controller: controller)),
        );
        expect(find.byKey(DesktopAgentWindow.cuOverlayBannerKey), findsNothing);

        await tester.runAsync(() async {
          await cuManager.startSession(
            goal: 'Mở file báo cáo mới nhất trong thư mục Reports',
            apps: const <String>['explorer'],
            domains: const <String>[],
            maxSteps: 10,
            maxMinutes: 5,
            policy: _buildCuTestPolicy(),
          );
        });
        await tester.pump();

        expect(find.byKey(DesktopAgentWindow.cuOverlayBannerKey), findsOneWidget);
        expect(
          find.textContaining('Đang điều khiển màn hình (Bước 0/10)'),
          findsOneWidget,
        );

        // Trigger emergency stop -> immediately terminates CU session and hides overlay
        await tester.runAsync(() async {
          controller.triggerEmergencyStop();
          await Future<void>.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();
        expect(cuManager.hasActiveSession, isFalse);
        expect(find.byKey(DesktopAgentWindow.cuOverlayBannerKey), findsNothing);

        await tester.runAsync(() async {
          controller.onClose();
          cuManager.dispose();
          dispatcher.dispose();
          await tempDir.delete(recursive: true);
        });
      },
    );
  });

  group('S8.3 — agent-desktop architectural upgrades (MCP driver, @s<id>:e<N> refs, actionability, progressive inspect)', () {
    test('AgentDesktopDriverMap & AgentDesktopComputerUseProvider map all 8 tools and unwrap envelopes/errors', () async {
      expect(AgentDesktopDriverMap.driverLicense, equals('Apache-2.0'));
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'cu.session_start',
        ),
        equals('desktop_session_start'),
      );
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'ui.inspect',
        ),
        equals('desktop_snapshot'),
      );
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'input.click',
          arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
        ),
        equals('desktop_click'),
      );
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'input.click',
          arguments: const <String, Object?>{'x': 120, 'y': 240},
        ),
        equals('desktop_mouse_click'),
      );
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'input.type_text',
          arguments: const <String, Object?>{
            'elementId': '@s00000001:e2',
            'text': 'Xin chào',
          },
        ),
        equals('desktop_set_value'),
      );
      expect(
        AgentDesktopDriverMap.toAgentDesktopTool(
          xunaToolName: 'input.type_text',
          arguments: const <String, Object?>{
            'elementId': '@s00000001:e2',
            'text': 'Xin chào',
            'headed': true,
          },
        ),
        equals('desktop_type'),
      );
      expect(
        AgentDesktopDriverMap.normalizeKeyCombo('⌘S'),
        equals('cmd+s'),
      );

      final stdoutController = StreamController<String>();
      final calledTools = <String>[];
      final calledArgs = <Map<String, Object?>>[];
      var returnStaleRef = false;

      final client = McpStdioClient.fromStreams(
        stdoutLines: stdoutController.stream,
        writeStdinLine: (line) {
          final req = (jsonDecode(line) as Map).cast<String, Object?>();
          final id = req['id'] as int;
          final params = (req['params'] as Map).cast<String, Object?>();
          final toolName = params['name'] as String;
          final toolArgs =
              (params['arguments'] as Map?)?.cast<String, Object?>() ??
              const <String, Object?>{};
          calledTools.add(toolName);
          calledArgs.add(toolArgs);

          if (returnStaleRef) {
            stdoutController.add(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, Object?>{
                  'isError': true,
                  'structuredContent': <String, Object?>{
                    'version': '1.0',
                    'ok': false,
                    'command': toolName,
                    'error': <String, Object?>{
                      'code': 'STALE_REF',
                      'message': 'Element @s00000001:e1 is no longer valid.',
                    },
                  },
                },
              }),
            );
            return;
          }

          if (toolName == 'desktop_snapshot') {
            stdoutController.add(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, Object?>{
                  'structuredContent': <String, Object?>{
                    'version': '1.0',
                    'ok': true,
                    'command': 'snapshot',
                    'data': <String, Object?>{
                      'snapshot_id': 's8f3k2p9',
                      'window': <String, Object?>{
                        'app': 'explorer',
                        'title': 'Reports',
                        'pid': 4200,
                      },
                      'nodes': <Map<String, Object?>>[
                        <String, Object?>{
                          'ref_id': '@s8f3k2p9:e1',
                          'role': 'textfield',
                          'name': 'Ô tìm kiếm',
                          'enabled': true,
                          'editable': true,
                        },
                      ],
                    },
                  },
                },
              }),
            );
          } else {
            stdoutController.add(
              jsonEncode(<String, Object?>{
                'jsonrpc': '2.0',
                'id': id,
                'result': <String, Object?>{
                  'structuredContent': <String, Object?>{
                    'version': '1.0',
                    'ok': true,
                    'command': toolName,
                    'data': <String, Object?>{'delivered': true},
                  },
                },
              }),
            );
          }
        },
      );

      final provider = AgentDesktopComputerUseProvider(
        clientFactory: (_) async => client,
      );
      await provider.startSession(
        sessionId: 'ad-1',
        capabilityManifestYaml: 'version: 3',
      );
      final win = await provider.inspectActiveWindow(maxNodes: 50);
      expect(win.appId, equals('explorer'));
      expect(win.nodes.single['ref'], equals('@s8f3k2p9:e1'));

      // Headless semantic set_value vs headed physical typing
      await provider.performTypeText(
        window: win,
        elementId: '@s8f3k2p9:e1',
        text: 'BaoCao',
        headed: false,
      );
      expect(calledTools.last, equals('desktop_set_value'));
      expect(calledArgs.last['value'], equals('BaoCao'));

      await provider.performTypeText(
        window: win,
        elementId: '@s8f3k2p9:e1',
        text: 'BaoCao',
        headed: true,
      );
      expect(calledTools.last, equals('desktop_type'));
      expect(calledArgs.last['text'], equals('BaoCao'));

      // STALE_REF envelope maps to XunaHostChannelException(errorCode: 'stale_ref')
      returnStaleRef = true;
      await expectLater(
        () => provider.performClick(
          window: win,
          elementId: '@s8f3k2p9:e1',
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'stale_ref',
          ),
        ),
      );

      returnStaleRef = false;
      await provider.endSession(sessionId: 'ad-1');
      await stdoutController.close();
    });

    test('enforces strict @s<id>:e<N> ref resolution (stale_ref & ambiguous_target), actionability battery, modal occlusion, and waitFor/waitForGone', () async {
      final stopController = EmergencyStopController(
        logger: ContentFreeLogger(),
      );
      final fallback = FallbackUiaAxComputerUseProvider(
        initialWindow: const ActiveWindowObservation(
          appId: 'explorer',
          processName: 'explorer.exe',
          windowTitle: 'Reports',
          nodes: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'wrap_root',
              'role': 'group',
              'name': '',
              'depth': 0,
            },
            <String, Object?>{
              'id': 'btn_open',
              'role': 'button',
              'name': 'Mở báo cáo',
              'enabled': true,
              'depth': 1,
            },
            <String, Object?>{
              'id': 'btn_disabled',
              'role': 'button',
              'name': 'Nút bị khóa',
              'enabled': false,
              'depth': 1,
            },
            <String, Object?>{
              'id': 'btn_hidden',
              'role': 'button',
              'name': 'Nút ẩn',
              'enabled': true,
              'visible': false,
              'depth': 1,
            },
            <String, Object?>{
              'id': 'txt_readonly',
              'role': 'textfield',
              'name': 'Mã hồ sơ',
              'enabled': true,
              'editable': false,
              'depth': 1,
            },
          ],
        ),
      );
      final manager = ComputerUseSessionManager(
        provider: fallback,
        stopController: stopController,
      );
      final policy = _buildCuTestPolicy();
      await manager.startSession(
        goal: 'Kiểm tra Strict Ref, Actionability và Wait',
        apps: const <String>['explorer'],
        domains: const <String>[],
        maxSteps: 15,
        maxMinutes: 5,
        policy: policy,
      );

      // 1. Progressive inspect with collapseWebWrappers drops unnamed group wrapper
      final inspectRes = await manager.inspectWindow(
        maxNodes: 50,
        collapseWebWrappers: true,
      );
      expect(inspectRes['snapshotId'], equals('s00000001'));
      expect(inspectRes['collapsedWrappersCount'], equals(1));
      final inspectedNodes =
          (inspectRes['nodes'] as List).cast<Map<String, Object?>>();
      expect(inspectedNodes.first['id'], equals('btn_open'));
      expect(inspectedNodes.first['ref'], equals('@s00000001:e1'));

      // 2. Actionability battery rejects disabled, hidden, and non-editable elements
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 'btn_disabled'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_enabled',
          ),
        ),
      );

      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 'btn_hidden'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_visible',
          ),
        ),
      );

      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{
            'elementId': 'txt_readonly',
            'text': 'Hồ sơ mới',
          },
          hasR3Approval: true,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_editable',
          ),
        ),
      );

      // 3. Valid click by @s00000001:e1 returns disposition + semantic_headless route + waitFor
      final clickOk = await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'elementId': '@s00000001:e1',
          'waitFor': 'window:Reports [1]',
        },
        hasR3Approval: false,
      );
      expect(clickOk['effect'], equals('changed'));
      expect(clickOk['route'], equals('semantic_headless'));
      expect(clickOk['waitSatisfied'], isTrue);
      final disposition = clickOk['disposition'] as Map<String, Object?>;
      expect(disposition['delivery'], equals('delivered_verified'));
      expect(disposition['retry'], equals('unsafe'));

      // 4. Stale ref detection: mutate 'btn_open' into a completely different control
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports [1]',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'btn_open',
            'role': 'checkbox',
            'name': 'Tùy chọn khác',
            'enabled': true,
          },
        ],
      );
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': '@s00000001:e1'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'stale_ref',
          ),
        ),
      );

      // 5. Ambiguous target detection: two identical (role, name) controls without nativeId
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports [1]',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'dup_1',
            'role': 'button',
            'name': 'Chi tiết',
            'enabled': true,
          },
          <String, Object?>{
            'id': 'dup_2',
            'role': 'button',
            'name': 'Chi tiết',
            'enabled': true,
          },
        ],
      );
      final snap2 = await manager.inspectWindow(maxNodes: 50);
      expect(snap2['snapshotId'], equals('s00000002'));
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': '@s00000002:e1'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'ambiguous_target',
          ),
        ),
      );

      // 6. Modal surface occlusion: clicking background button while modal dialog is open fails with element_occluded
      fallback.currentWindow = const ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports [1]',
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'modal_dlg',
            'role': 'dialog',
            'name': 'Cảnh báo hệ thống',
            'modal': true,
            'enabled': true,
          },
          <String, Object?>{
            'id': 'bg_btn',
            'role': 'button',
            'name': 'Nút nền phía sau',
            'parentSurfaceId': 'main_window',
            'enabled': true,
          },
          <String, Object?>{
            'id': 'modal_ok',
            'role': 'button',
            'name': 'Đã hiểu',
            'parentSurfaceId': 'modal_dlg',
            'enabled': true,
          },
        ],
      );
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': 'bg_btn'},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_occluded',
          ),
        ),
      );

      // Clicking the button inside the modal succeeds and reports active surfaces
      final modalClick = await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': 'modal_ok'},
        hasR3Approval: false,
      );
      expect(modalClick['effect'], equals('changed'));
      expect(modalClick['surfaces'], isA<List>());

      manager.dispose();
    });

    test('NativeHostChannelComputerUseProvider & UiAccessibilityTreeTool bridge @s<id>:e<N> to native ui_<N> channel', () async {
      final channel = FakeXunaHostChannel()
        ..activeWindowContextResult = const ActiveWindowContextSnapshot(
          appName: 'File Explorer',
          processName: 'explorer.exe',
          windowTitle: 'Reports',
          focusedRole: 'window',
          visibleText: 'Reports',
        );
      final stopController = EmergencyStopController(
        logger: ContentFreeLogger(),
      );
      final liveProvider = NativeHostChannelComputerUseProvider(
        channel: channel,
      );
      final manager = ComputerUseSessionManager(
        provider: liveProvider,
        stopController: stopController,
      );

      await manager.startSession(
        goal: 'Thao tác trên cửa sổ thật qua XunaHostChannel',
        apps: const <String>['explorer'],
        domains: const <String>[],
        maxSteps: 8,
        maxMinutes: 5,
        policy: _buildCuTestPolicy(),
      );

      final snap = await manager.inspectWindow(
        maxNodes: 20,
        interactiveOnly: true,
        collapseWebWrappers: true,
      );
      expect(snap['snapshotId'], equals('s00000001'));
      final nodes = (snap['nodes'] as List).cast<Map<String, Object?>>();
      expect(nodes.first['ref'], equals('@s00000001:e1'));

      // Typing into @s00000001:e1 dispatches invokeWindowUiControl:set_value_ref:ui_1 to native channel
      await manager.executeInputAction(
        toolName: 'input.type_text',
        arguments: const <String, Object?>{
          'elementId': '@s00000001:e1',
          'text': 'BaoCao_Q4',
        },
        hasR3Approval: false,
      );
      expect(
        channel.invokedMethods,
        contains('invokeWindowUiControl:set_value_ref:ui_1'),
      );

      // Clicking @s00000001:e2 dispatches invokeWindowUiControl:invoke_ref:ui_2 to native channel
      await manager.executeInputAction(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': '@s00000001:e2'},
        hasR3Approval: false,
      );
      expect(
        channel.invokedMethods,
        contains('invokeWindowUiControl:invoke_ref:ui_2'),
      );

      // Password field @s00000001:e4 is refused with password_field_forbidden
      await expectLater(
        () => manager.executeInputAction(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': '@s00000001:e4'},
          hasR3Approval: true,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'password_field_forbidden',
          ),
        ),
      );

      // Verify UiAccessibilityTreeService.validateAndResolveRefKey translates @s<id>:e<N> -> ui_<N> and rejects stale refs
      final tempDir = await Directory.systemTemp.createTemp('xuna_uia_wire_');
      final paths = AgentPaths.resolve(overrideRootDir: tempDir);
      await paths.ensureDirectories();
      final policyStore = HostPolicyStore(
        policyFile: paths.policyFile,
        logger: ContentFreeLogger(),
      );
      final dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: channel,
        auditStore: AuditLogStore(auditDir: paths.auditDir),
        stopController: stopController,
        logger: ContentFreeLogger(),
        enrollmentStore: EnrollmentStateStore(
          stateFile: paths.enrollmentStateFile,
        ),
        computerUseManager: manager,
      );

      final uia = dispatcher.symbioticService.uiAccessibility;
      final treeSnap = await channel.inspectWindowUiTree(maxNodes: 20);
      uia.applyNativeWindowUiTree(
        windowTitle: treeSnap.windowTitle,
        nodes: treeSnap.nodes,
      );
      final activeSnapId = uia.activeSnapshotId;
      expect(
        uia.validateAndResolveRefKey(
          '@$activeSnapId:e3',
          defaultRefId: 'ui_1',
        ),
        equals('ui_3'),
      );
      expect(
        () => uia.validateAndResolveRefKey(
          '@s00000099:e3',
          defaultRefId: 'ui_1',
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'stale_ref',
          ),
        ),
      );

      dispatcher.dispose();
      manager.dispose();
      await tempDir.delete(recursive: true);
    });

    test('NativeHostChannelComputerUseProvider never inspects more controls than the native layer can act on', () async {
      final channel = FakeXunaHostChannel();
      final provider = NativeHostChannelComputerUseProvider(channel: channel);
      expect(NativeHostChannelComputerUseProvider.nativeActionableNodeCap, 60);

      // The session manager asks for up to 300 nodes; native refs 61..80 could be
      // listed but never invoked, so the request is capped at 60.
      await provider.inspectActiveWindow(maxNodes: 300);
      await provider.inspectActiveWindow(maxNodes: 80);
      await provider.inspectActiveWindow(maxNodes: 20);
      final inspected = channel.invokedMethods
          .where((m) => m.startsWith('inspectWindowUiTree:'))
          .map((m) => int.parse(m.split(':').last))
          .toList();
      expect(inspected, <int>[60, 60, 20]);
    });

    test('NativeHostChannelComputerUseProvider never guesses a target: no element, coordinates only or an unparseable ref fail without touching the native channel', () async {
      final channel = FakeXunaHostChannel();
      final provider = NativeHostChannelComputerUseProvider(channel: channel);
      const window = ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        nodes: <Map<String, Object?>>[],
      );

      Matcher failsWith(String code) => throwsA(
        isA<XunaHostChannelException>()
            .having((e) => e.status, 'status', XtpStatus.invalidArgs)
            .having((e) => e.errorCode, 'errorCode', code),
      );

      // Coordinates are not a target: this used to click the first control (ui_1).
      await expectLater(
        provider.performClick(window: window, x: 10, y: 20),
        failsWith('target_required'),
      );
      await expectLater(
        provider.performClick(window: window, elementId: '  '),
        failsWith('target_required'),
      );
      await expectLater(
        provider.performTypeText(
          window: window,
          elementId: '',
          text: 'hello',
        ),
        failsWith('target_required'),
      );
      await expectLater(
        provider.performScroll(window: window, direction: 'down', amount: 3),
        failsWith('target_required'),
      );
      // A string that merely ends in digits is not a ref: this used to become ui_7.
      await expectLater(
        provider.performClick(window: window, elementId: 'modal_ok_7'),
        failsWith('ref_unresolvable'),
      );
      expect(
        channel.invokedMethods.where(
          (m) => m.startsWith('invokeWindowUiControl'),
        ),
        isEmpty,
      );

      // A real native ref still reaches the channel.
      await provider.performClick(window: window, elementId: 'ui_2');
      expect(
        channel.invokedMethods,
        contains('invokeWindowUiControl:invoke_ref:ui_2'),
      );
    });
  });
}

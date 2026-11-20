import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

void main() {
  group('Wave C Desktop — ui.observe_hybrid', () {
    late CuGateHarness harness;

    setUp(() async {
      const windowWithBounds = ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        windowX: 100,
        windowY: 100,
        windowWidth: 1000,
        windowHeight: 800,
        devicePixelRatio: 2.0,
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'btn1',
            'role': 'button',
            'name': 'Xem báo cáo',
            'bounds': <String, Object?>{
              'x': 100,
              'y': 200,
              'width': 200,
              'height': 80,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'btn_send',
            'role': 'button',
            'name': 'Gửi báo cáo',
            'bounds': <String, Object?>{
              'x': 400,
              'y': 200,
              'width': 200,
              'height': 80,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd1',
            'role': 'textfield',
            'name': 'Mật khẩu bảo vệ',
            'isPassword': true,
            'bounds': <String, Object?>{
              'x': 100,
              'y': 400,
              'width': 300,
              'height': 50,
            },
            'enabled': true,
          },
        ],
      );
      harness = await CuGateHarness.create(window: windowWithBounds);
      await harness.startSession();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test(
      'observeHybrid extracts normalized tree bounds, HiDPI DPR and active window JPEG',
      () async {
        final result = await harness.manager.observeHybrid(
          maxNodes: 50,
          maxEdge: 1280,
        );

        expect(result['appId'], 'explorer');
        expect(result['windowTitle'], 'Reports');
        expect(result['devicePixelRatio'], 2.0);
        expect(result['windowBounds'], <String, Object?>{
          'x': 100,
          'y': 100,
          'width': 1000,
          'height': 800,
        });

        final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();
        expect(nodes.length, 3);

        // Verify bounds are normalized to [0.0, 1.0] relative to 1000x800 window:
        // btn1: x: 100/1000=0.1, y: 200/800=0.25, x2: 300/1000=0.3, y2: 280/800=0.35
        final btn1 = nodes.firstWhere((n) => n['name'] == 'Xem báo cáo');
        final bounds = (btn1['bounds'] as List).cast<double>();
        expect(bounds.length, 4);
        expect(bounds[0], closeTo(0.1, 0.001));
        expect(bounds[1], closeTo(0.25, 0.001));
        expect(bounds[2], closeTo(0.3, 0.001));
        expect(bounds[3], closeTo(0.35, 0.001));

        // Password node is redacted and never retains bounds or value
        final pwd1 = nodes.firstWhere((n) => n['id'] == 'pwd1');
        expect(pwd1['role'], 'password');
        expect(pwd1['name'], '•••');
        expect(pwd1['isPassword'], isTrue);
        expect(pwd1.containsKey('value'), isFalse);
        expect(pwd1.containsKey('bounds'), isFalse);

        // Set-of-Marks sent to captureScreen matches post-redaction non-password @s<id>:eK refs 1:1
        final somMarks = harness.provider.lastSomMarks;
        expect(somMarks, isNotNull);
        expect(somMarks, hasLength(2));
        expect(somMarks![0]['index'], 1);
        expect(somMarks[0]['role'], 'button');
        expect((somMarks[0]['bounds'] as List).cast<double>(), bounds);
        expect(somMarks[1]['index'], 2);
        expect(nodes[0]['ref'], '@s00000001:e1');
        expect(nodes[1]['ref'], '@s00000001:e2');

        // Verify screenshot object
        final screenshot = result['screenshot'] as Map<String, Object?>;
        expect(screenshot['width'], 1280);
        expect(screenshot['dataBase64'], isNotEmpty);
      },
    );

    test(
      'observeHybrid fails closed with screen_recording when screen recording permission is missing',
      () async {
        harness.manager.hasScreenCapturePermission = false;

        expect(
          () => harness.manager.observeHybrid(maxNodes: 50, maxEdge: 1280),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.errorCode, 'errorCode', 'screen_recording')
                .having((e) => e.status, 'status', XtpStatus.needsPermission),
          ),
        );
      },
    );

    test(
      'observeHybrid wire-level JSON status is needs_permission with errorCode screen_recording',
      () async {
        harness.manager.hasScreenCapturePermission = false;

        final meta = await harness.dispatchMeta(
          'ui.observe_hybrid',
          <String, Object?>{
            'scope': 'active_window',
            'maxNodes': 50,
            'maxEdge': 1280,
          },
          invocationId: 'inv-perm-observe-hybrid',
        );
        expect(meta['xuna/status'], 'needs_permission');
        expect(meta['xuna/errorCode'], 'screen_recording');

        final result = await harness.dispatchResult(
          'ui.observe_hybrid',
          <String, Object?>{
            'scope': 'active_window',
            'maxNodes': 50,
            'maxEdge': 1280,
          },
          invocationId: 'inv-perm-observe-hybrid-full',
        );
        final wireJson = jsonDecode(jsonEncode(result)) as Map<String, Object?>;
        final wireMeta = wireJson['_meta'] as Map<String, Object?>;
        expect(wireMeta['xuna/status'], 'needs_permission');
        expect(wireMeta['xuna/errorCode'], 'screen_recording');
      },
    );

    test(
      'observeHybrid fails closed when screen capture driver is unsupported or fails',
      () async {
        harness.provider.failCapture = true;
        harness.provider.captureErrorCode = 'platform_unsupported';

        expect(
          () => harness.manager.observeHybrid(maxNodes: 50, maxEdge: 1280),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.errorCode, 'errorCode', 'platform_unsupported')
                .having((e) => e.status, 'status', XtpStatus.unsupported),
          ),
        );
      },
    );

    test(
      'observeHybrid with interactiveOnly/collapseWebWrappers/skeleton avoids positional bounds shift and aligns somMarks 1:1',
      () async {
        harness.provider.currentWindow = const ActiveWindowObservation(
          appId: 'explorer',
          processName: 'explorer.exe',
          windowTitle: 'Filtered View',
          windowX: 0,
          windowY: 0,
          windowWidth: 1000,
          windowHeight: 1000,
          nodes: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'wrap_empty',
              'role': 'group',
              'name': '',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 0,
                'y': 0,
                'width': 1000,
                'height': 1000,
              },
            },
            <String, Object?>{
              'id': 'static_lbl',
              'role': 'text',
              'name': 'Header',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 10,
                'y': 10,
                'width': 100,
                'height': 20,
              },
            },
            <String, Object?>{
              'id': 'btn_target',
              'role': 'button',
              'name': 'Open File',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 700,
                'y': 400,
                'width': 200,
                'height': 100,
              },
              'enabled': true,
            },
            <String, Object?>{
              'id': 'deep_btn',
              'role': 'button',
              'name': 'Too Deep',
              'depth': 4,
              'bounds': <String, Object?>{
                'x': 100,
                'y': 800,
                'width': 100,
                'height': 50,
              },
              'enabled': true,
            },
            <String, Object?>{
              'id': 'btn_second',
              'role': 'button',
              'name': 'Save',
              'depth': 2,
              'bounds': <String, Object?>{
                'x': 200,
                'y': 600,
                'width': 150,
                'height': 80,
              },
              'enabled': true,
            },
          ],
        );

        final result = await harness.manager.observeHybrid(
          maxNodes: 50,
          maxEdge: 1280,
          collapseWebWrappers: true,
          interactiveOnly: true,
          skeleton: true,
        );
        final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();
        expect(nodes, hasLength(2));
        expect(nodes[0]['id'], 'btn_target');
        expect(nodes[0]['ref'], '@s00000001:e1');
        // Must have btn_target's OWN bounds [0.7, 0.4, 0.9, 0.5], NOT wrap_empty's [0,0,1,1]!
        final b0 = (nodes[0]['bounds'] as List).cast<double>();
        expect(b0[0], closeTo(0.7, 0.001));
        expect(b0[1], closeTo(0.4, 0.001));
        expect(b0[2], closeTo(0.9, 0.001));
        expect(b0[3], closeTo(0.5, 0.001));

        expect(nodes[1]['id'], 'btn_second');
        expect(nodes[1]['ref'], '@s00000001:e2');
        final b1 = (nodes[1]['bounds'] as List).cast<double>();
        expect(b1[0], closeTo(0.2, 0.001));
        expect(b1[1], closeTo(0.6, 0.001));
        expect(b1[2], closeTo(0.35, 0.001));
        expect(b1[3], closeTo(0.68, 0.001));

        final marks = harness.provider.lastSomMarks!;
        expect(marks, hasLength(2));
        expect(marks[0]['index'], 1);
        expect(marks[0]['bounds'], b0);
        expect(marks[1]['index'], 2);
        expect(marks[1]['bounds'], b1);
      },
    );

    test(
      'observeHybrid skips invalid/NaN/offscreen/invisible bounds without fabricating [0,0,0,0] and aligns somMarks with pre-existing ref numbers',
      () async {
        harness.provider.currentWindow = ActiveWindowObservation(
          appId: 'explorer',
          processName: 'explorer.exe',
          windowTitle: 'Edge Bounds',
          windowX: 0,
          windowY: 0,
          windowWidth: 1000,
          windowHeight: 500,
          nodes: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'btn_first',
              'role': 'button',
              'name': 'First',
              'bounds': <double>[0.1, 0.1, 0.2, 0.2],
            },
            const <String, Object?>{
              'id': 'btn_missing',
              'role': 'button',
              'name': 'No Bounds',
            },
            const <String, Object?>{
              'id': 'btn_zero',
              'role': 'button',
              'name': 'Zero Width',
              'bounds': <String, Object?>{
                'x': 10,
                'y': 10,
                'width': 0,
                'height': 20,
              },
            },
            <String, Object?>{
              'id': 'btn_nan',
              'role': 'button',
              'name': 'NaN Box',
              'bounds': <double>[0.1, double.nan, 0.4, 0.4],
            },
            const <String, Object?>{
              'id': 'btn_offscreen',
              'role': 'button',
              'name': 'Offscreen',
              'bounds': <String, Object?>{
                'x': -200,
                'y': 50,
                'width': 50,
                'height': 20,
              },
            },
            const <String, Object?>{
              'id': 'btn_hidden',
              'role': 'button',
              'name': 'Hidden',
              'visible': false,
              'bounds': <String, Object?>{
                'x': 300,
                'y': 100,
                'width': 100,
                'height': 50,
              },
            },
            const <String, Object?>{
              'id': 's00000001:7',
              'role': 'textfield',
              'name': 'Search',
              'bounds': <String, Object?>{
                'x': 500,
                'y': 100,
                'w': 200,
                'h': 50,
              },
            },
          ],
        );

        final result = await harness.manager.observeHybrid(
          maxNodes: 50,
          maxEdge: 1280,
        );
        final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();
        expect(nodes, hasLength(7));

        // Invalid / zero-area / NaN / offscreen bounds must be omitted, never [0,0,0,0].
        expect(nodes[1].containsKey('bounds'), isFalse);
        expect(nodes[2].containsKey('bounds'), isFalse);
        expect(nodes[3].containsKey('bounds'), isFalse);
        expect(nodes[4].containsKey('bounds'), isFalse);

        // s00000001:7 keeps elementNumber 7 in its ref AND in somMarks!
        expect(nodes[6]['ref'], '@s00000001:e7');
        final marks = harness.provider.lastSomMarks!;
        expect(marks.map((m) => m['index']).toList(), <int>[1, 7]);
        expect(marks[1]['role'], 'textfield');
        expect((marks[1]['bounds'] as List).cast<double>(), <double>[
          0.5,
          0.2,
          0.7,
          0.3,
        ]);
      },
    );

    test(
      'observeHybrid captureScreen failure preserves latestSnapshotId and prior refs',
      () async {
        final inspected = await harness.manager.inspectWindow(maxNodes: 20);
        final prevSnapshotId = inspected['snapshotId'] as String;
        expect(harness.manager.activeSession!.latestSnapshotId, prevSnapshotId);

        harness.provider.failCapture = true;
        harness.provider.captureErrorCode = 'capture_failed';
        await expectLater(
          () => harness.manager.observeHybrid(maxNodes: 20, maxEdge: 1280),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'capture_failed',
            ),
          ),
        );

        // Must not advance snapshotCounter or latestSnapshotId when capture fails.
        expect(harness.manager.activeSession!.latestSnapshotId, prevSnapshotId);
        expect(harness.manager.activeSession!.snapshotCounter, 1);
      },
    );

    test(
      'observeHybrid retains offscreen: true and omits offscreen node from somMarks, handles normalized overhang vs small pixel boxes, and clamps surrogate windowTitle safely',
      () async {
        final titleWithBoundaryEmoji = '${'a' * 119}😀tail';
        harness.provider.currentWindow = ActiveWindowObservation(
          appId: 'explorer',
          processName: 'explorer.exe',
          windowTitle: titleWithBoundaryEmoji,
          windowX: 0,
          windowY: 0,
          windowWidth: 1000,
          windowHeight: 800,
          nodes: const <Map<String, Object?>>[
            <String, Object?>{
              'id': 'offscreen_btn',
              'role': 'button',
              'name': 'Scrolled Out',
              'offscreen': true,
              'bounds': <double>[0.1, 0.1, 0.3, 0.2],
            },
            <String, Object?>{
              'id': 'overhang_norm',
              'role': 'button',
              'name': 'Overhang Norm',
              'bounds': <double>[0.8, 0.8, 1.2, 1.2],
            },
            <String, Object?>{
              'id': 'tiny_pixel_box',
              'role': 'button',
              'name': 'Tiny Pixel Box',
              'bounds': <int>[0, 0, 2, 2],
            },
          ],
        );

        final result = await harness.manager.observeHybrid(
          maxNodes: 50,
          maxEdge: 1280,
        );
        final title = result['windowTitle']! as String;
        expect(title.length, 119);
        final lastUnit = title.codeUnitAt(title.length - 1);
        expect(lastUnit < 0xD800 || lastUnit > 0xDBFF, isTrue);

        final nodes = (result['nodes'] as List).cast<Map<String, Object?>>();
        expect(nodes, hasLength(3));
        expect(nodes[0]['offscreen'], isTrue);
        expect(nodes[1]['bounds'], <double>[0.8, 0.8, 1.0, 1.0]);
        final tinyBounds = (nodes[2]['bounds']! as List).cast<double>();
        expect(tinyBounds[0], closeTo(0.0, 1e-6));
        expect(tinyBounds[1], closeTo(0.0, 1e-6));
        expect(tinyBounds[2], closeTo(0.002, 1e-6));
        expect(tinyBounds[3], closeTo(0.0025, 1e-6));

        final marks = harness.provider.lastSomMarks!;
        expect(marks.map((m) => m['index']).toList(), <int>[2, 3]);
        expect(marks[0]['bounds'], <double>[0.8, 0.8, 1.0, 1.0]);
        expect(marks[1]['bounds'], tinyBounds);
      },
    );

    test(
      'HostToolDispatcher ui.observe_hybrid forwards post-redaction somMarks to XunaHostChannel while screen.capture omits somMarks',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('xuna_som_disp_');
        addTearDown(() => tempDir.delete(recursive: true));
        final paths = AgentPaths.resolve(overrideRootDir: tempDir);
        await paths.ensureDirectories();
        final logger = ContentFreeLogger();
        final policyStore = HostPolicyStore(
          policyFile: paths.policyFile,
          logger: logger,
        );
        final policy = HostPolicy(
          schemaVersion: 1,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.cu: FamilyPolicyDecision.allow,
            ToolFamily.screen: FamilyPolicyDecision.allow,
            ToolFamily.ui: FamilyPolicyDecision.allow,
            ToolFamily.input: FamilyPolicyDecision.allow,
          },
          apps: <AllowedAppConfig>[
            AllowedAppConfig(
              id: 'figma',
              name: 'Figma',
              kind: AppLaunchKind.bundle,
              target: 'com.figma.Desktop',
              risk: RiskTier.r2,
            ),
          ],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
        );
        await policyStore.savePolicy(policy);
        final stopController = EmergencyStopController(logger: logger);
        final channel = _RecordingMacHostChannel(onInvoke: (_, __) {})
          ..activeWindowContextResult = const ActiveWindowContextSnapshot(
            appName: 'Figma',
            processName: 'com.figma.Desktop',
            windowTitle: 'Figma — Design',
            focusedRole: 'AXButton',
            visibleText: '',
          );
        final nativeProvider = NativeHostChannelComputerUseProvider(
          channel: channel,
          enableNativePointerAndCapture: true,
          isWindowsHost: false,
        );
        final manager = ComputerUseSessionManager(
          provider: nativeProvider,
          stopController: stopController,
        );
        final dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: channel,
          auditStore: AuditLogStore(auditDir: paths.auditDir),
          stopController: stopController,
          logger: logger,
          computerUseManager: manager,
          appScanner: AutoAppScanner(
            scanFileSystem: false,
            seedApps: const <DiscoveredApp>[],
          ),
        );
        addTearDown(() async {
          dispatcher.dispose();
          await stopController.dispose();
          await policyStore.dispose();
        });

        await manager.startSession(
          goal: 'Observe Figma design',
          apps: const <String>['figma'],
          domains: const <String>[],
          maxSteps: 10,
          maxMinutes: 5,
          policy: policy,
        );

        final hybridResp = await dispatcher.dispatch(
          requestId: 'rpc-som-1',
          params: const ToolsCallParams(
            name: 'ui.observe_hybrid',
            arguments: <String, Object?>{
              'scope': 'active_window',
              'maxEdge': 1280,
            },
            invocationId: 'inv-native-som-1',
            deadlineMs: 5000,
          ),
        );
        final hybridMeta = (hybridResp.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(hybridMeta['xuna/status'], 'ok');
        expect(channel.lastCaptureSomMarks, hasLength(1));
        expect(channel.lastCaptureSomMarks!.single['index'], 1);
        expect(channel.lastCaptureSomMarks!.single['role'], 'button');

        final plainResp = await dispatcher.dispatch(
          requestId: 'rpc-plain-1',
          params: const ToolsCallParams(
            name: 'screen.capture',
            arguments: <String, Object?>{
              'scope': 'active_window',
              'maxEdge': 1280,
            },
            invocationId: 'inv-plain-capture-1',
            deadlineMs: 5000,
          ),
        );
        final plainMeta = (plainResp.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(plainMeta['xuna/status'], 'ok');
        expect(channel.lastCaptureSomMarks, isNull);
      },
    );
  });

  group('Wave C Desktop — input.click normalized coordinates & reverse hit-test', () {
    late CuGateHarness harness;

    setUp(() async {
      const window = ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        windowX: 50,
        windowY: 50,
        windowWidth: 1000,
        windowHeight: 800,
        devicePixelRatio: 1.5,
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'safe_btn',
            'role': 'button',
            'name': 'Xem chi tiết',
            'bounds': <String, Object?>{
              'x': 100,
              'y': 100,
              'width': 200,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'conseq_btn',
            'role': 'button',
            'name': 'Xóa toàn bộ',
            'bounds': <String, Object?>{
              'x': 400,
              'y': 100,
              'width': 200,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd_field',
            'role': 'textfield',
            'name': 'Nhập mã pin',
            'isPassword': true,
            'bounds': <String, Object?>{
              'x': 100,
              'y': 300,
              'width': 200,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'edit_note',
            'role': 'textfield',
            'name': 'Ghi chú',
            'editable': true,
            'bounds': <String, Object?>{
              'x': 100,
              'y': 500,
              'width': 200,
              'height': 50,
            },
            'enabled': true,
          },
        ],
      );
      harness = await CuGateHarness.create(window: window);
      await harness.startSession();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test(
      'coordinate click translates normalized coordinates to physical pixels with DPR',
      () async {
        // safe_btn center is at x: 200/1000=0.2, y: 125/800=0.15625
        // Logical coords: X = 50 + 200 = 250, Y = 50 + 125 = 175
        // Physical coords with DPR 1.5: X = 250 * 1.5 = 375, Y = 175 * 1.5 = 262.5 -> 263
        final result = await harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{'xNorm': 0.2, 'yNorm': 0.15625},
          hasR3Approval: false,
        );

        expect(result['effect'], 'changed');
        expect(result['settled'], isNotNull);
        expect(result['settleMs'], isNotNull);
        expect(harness.provider.recordedCalls, contains('click:375,263'));
      },
    );

    test(
      'coordinate click on password field is unconditionally refused',
      () async {
        // pwd_field center is at x: 200/1000=0.2, y: 325/800=0.40625
        expect(
          () => harness.manager.executeInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'xNorm': 0.2, 'yNorm': 0.40625},
            hasR3Approval: false,
          ),
          throwsA(
            isA<XunaHostChannelException>()
                .having(
                  (e) => e.errorCode,
                  'errorCode',
                  'password_field_forbidden',
                )
                .having((e) => e.status, 'status', XtpStatus.denied),
          ),
        );

        // Preflight also refuses unconditionally
        expect(
          () => harness.manager.preflightInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'xNorm': 0.2, 'yNorm': 0.40625},
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'password_field_forbidden',
            ),
          ),
        );
      },
    );

    test('coordinate click on consequential button requires R3 approval', () async {
      // conseq_btn ("Xóa toàn bộ") center is at x: 500/1000=0.5, y: 125/800=0.15625
      expect(
        () => harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{'xNorm': 0.5, 'yNorm': 0.15625},
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'approval_required')
              .having((e) => e.status, 'status', XtpStatus.denied),
        ),
      );

      // Preflight indicates consequential_target R3
      final preflight = await harness.manager.preflightInputAction(
        toolName: 'input.click',
        arguments: <String, Object?>{'xNorm': 0.5, 'yNorm': 0.15625},
      );
      expect(preflight.stepRisk.risk, RiskTier.r3);
      expect(preflight.stepRisk.reasonCode, 'consequential_target');

      // With verified R3 approval over real HostToolDispatcher wire path (including
      // P-256 signature + RFC 8785 float argsSha256 binding), execution succeeds.
      const wireArgs = <String, Object?>{'xNorm': 0.5, 'yNorm': 0.15625};
      final wireResult = await harness.dispatchResult(
        'input.click',
        wireArgs,
        approval: harness.signedApproval(wireArgs),
        invocationId: 'inv-r3-coord-click-signed',
      );
      final wireMeta = (wireResult['_meta'] as Map).cast<String, Object?>();
      final wireContent = (wireResult['structuredContent'] as Map)
          .cast<String, Object?>();
      expect(wireMeta['xuna/status'], 'ok');
      expect(wireContent['effect'], 'changed');
    });

    test(
      'coordinate click on unclassified location requires R3 approval',
      () async {
        // Empty background at x: 0.9, y: 0.9
        expect(
          () => harness.manager.executeInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'xNorm': 0.9, 'yNorm': 0.9},
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
      },
    );

    test(
      'uncommitted draft text blocks coordinate click on non-draft targets',
      () async {
        // First, type some text to create an uncommitted draft
        await harness.manager.executeInputAction(
          toolName: 'input.type_text',
          arguments: <String, Object?>{
            'elementId': 'edit_note',
            'text': 'Draft line',
          },
          hasR3Approval: false,
        );
        expect(harness.manager.activeSession!.hasUncommittedDraft, isTrue);

        // A coordinate click on safe_btn ("Xem chi tiết") is escalated to R3 because of draft
        expect(
          () => harness.manager.executeInputAction(
            toolName: 'input.click',
            arguments: <String, Object?>{'xNorm': 0.2, 'yNorm': 0.15625},
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
      },
    );

    test(
      'consecutive coordinate clicks and drags in a multi-step session retain window geometry and DPR scaling',
      () async {
        // Step 1: First click on safe_btn (xNorm: 0.2, yNorm: 0.15625)
        // Logical coords: X = 50 + (0.2 * 1000) = 250, Y = 50 + (0.15625 * 800) = 175
        // Physical coords with DPR 1.5: X = 250 * 1.5 = 375, Y = 175 * 1.5 = 262.5 -> 263
        final step1Result = await harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{'xNorm': 0.2, 'yNorm': 0.15625},
          hasR3Approval: false,
        );
        expect(step1Result['effect'], 'changed');
        expect(harness.provider.recordedCalls, contains('click:375,263'));

        // Verify that after mutation, currentWindow preserved window bounds and DPR
        final winAfterStep1 = await harness.provider.inspectActiveWindow(
          maxNodes: 10,
        );
        expect(winAfterStep1.windowX, 50);
        expect(winAfterStep1.windowY, 50);
        expect(winAfterStep1.windowWidth, 1000);
        expect(winAfterStep1.windowHeight, 800);
        expect(winAfterStep1.devicePixelRatio, 1.5);

        // Step 2: Second consecutive click at xNorm: 0.25, yNorm: 0.15625
        // Logical coords: X = 50 + (0.25 * 1000) = 300, Y = 50 + (0.15625 * 800) = 175
        // Physical coords with DPR 1.5: X = 300 * 1.5 = 450, Y = 175 * 1.5 = 263
        final step2Result = await harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{'xNorm': 0.25, 'yNorm': 0.15625},
          hasR3Approval: false,
        );
        expect(step2Result['effect'], 'changed');
        expect(harness.provider.recordedCalls, contains('click:450,263'));

        // Step 3: Consecutive drag from (0.2, 0.15625) to (0.25, 0.15625) in the same session
        // from Physical: (375, 263) -> to Physical: (450, 263)
        final step3Result = await harness.manager.executeInputAction(
          toolName: 'input.drag',
          arguments: <String, Object?>{
            'fromXNorm': 0.2,
            'fromYNorm': 0.15625,
            'toXNorm': 0.25,
            'toYNorm': 0.15625,
            'durationMs': 100,
          },
          hasR3Approval: true,
        );
        expect(step3Result['effect'], 'changed');
        expect(
          harness.provider.recordedCalls,
          contains('drag:375,263->450,263'),
        );

        // Verify geometry and DPR remain intact after multiple mutations
        final winAfterStep3 = await harness.provider.inspectActiveWindow(
          maxNodes: 10,
        );
        expect(winAfterStep3.windowX, 50);
        expect(winAfterStep3.windowY, 50);
        expect(winAfterStep3.windowWidth, 1000);
        expect(winAfterStep3.windowHeight, 800);
        expect(winAfterStep3.devicePixelRatio, 1.5);
      },
    );
  });

  group('Wave C Desktop — input.drag execution & security', () {
    late CuGateHarness harness;

    setUp(() async {
      const window = ActiveWindowObservation(
        appId: 'explorer',
        processName: 'explorer.exe',
        windowTitle: 'Reports',
        windowX: 0,
        windowY: 0,
        windowWidth: 1000,
        windowHeight: 1000,
        devicePixelRatio: 1.0,
        nodes: <Map<String, Object?>>[
          <String, Object?>{
            'id': 'item1',
            'role': 'list_item',
            'name': 'File1.txt',
            'bounds': <String, Object?>{
              'x': 100,
              'y': 100,
              'width': 100,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'folder1',
            'role': 'folder',
            'name': 'FolderArchive',
            'bounds': <String, Object?>{
              'x': 500,
              'y': 500,
              'width': 100,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'delete_bin',
            'role': 'button',
            'name': 'Delete Bin',
            'bounds': <String, Object?>{
              'x': 800,
              'y': 800,
              'width': 100,
              'height': 50,
            },
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd_drop',
            'role': 'textfield',
            'name': 'Mật khẩu bảo mật',
            'isPassword': true,
            'bounds': <String, Object?>{
              'x': 800,
              'y': 200,
              'width': 100,
              'height': 50,
            },
            'enabled': true,
          },
        ],
      );
      harness = await CuGateHarness.create(window: window);
      await harness.startSession();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test(
      'input.drag executes drag between coordinates and reports settle status',
      () async {
        final result = await harness.manager.executeInputAction(
          toolName: 'input.drag',
          arguments: <String, Object?>{
            'fromXNorm': 0.15,
            'fromYNorm': 0.125,
            'toXNorm': 0.55,
            'toYNorm': 0.525,
            'durationMs': 250,
          },
          hasR3Approval: false,
        );

        expect(result['effect'], 'changed');
        expect(result['settled'], isTrue);
        expect(result['settleMs'], isNotNull);
        expect(
          harness.provider.recordedCalls,
          contains('drag:150,125->550,525'),
        );
      },
    );

    test('input.drag landing on password field is denied', () async {
      expect(
        () => harness.manager.executeInputAction(
          toolName: 'input.drag',
          arguments: <String, Object?>{
            'fromXNorm': 0.15,
            'fromYNorm': 0.125,
            'toXNorm': 0.85,
            'toYNorm': 0.225, // pwd_drop
          },
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'password_field_forbidden',
          ),
        ),
      );
    });

    test(
      'input.drag landing on consequential target requires R3 approval',
      () async {
        expect(
          () => harness.manager.executeInputAction(
            toolName: 'input.drag',
            arguments: <String, Object?>{
              'fromXNorm': 0.15,
              'fromYNorm': 0.125,
              'toXNorm': 0.85,
              'toYNorm': 0.825, // delete_bin
            },
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

        // Succeeds with approval
        final res = await harness.manager.executeInputAction(
          toolName: 'input.drag',
          arguments: <String, Object?>{
            'fromXNorm': 0.15,
            'fromYNorm': 0.125,
            'toXNorm': 0.85,
            'toYNorm': 0.825,
          },
          hasR3Approval: true,
        );
        expect(res['effect'], 'changed');
      },
    );
  });

  group('Wave C Desktop — Dispatcher Tool Registration & ParallelReadLane', () {
    late CuGateHarness harness;

    setUp(() async {
      harness = await CuGateHarness.create();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test(
      'HostToolDispatcher registers ui.observe_hybrid and input.drag in manifest',
      () async {
        final manifest = await harness.dispatcher.buildManifest();
        final toolNames = manifest.map((t) => t.name).toList();

        expect(toolNames, contains('ui.observe_hybrid'));
        expect(toolNames, contains('input.drag'));
        expect(toolNames, contains('input.click'));
        expect(toolNames, contains('screen.capture'));
        expect(toolNames, contains('ui.inspect'));
      },
    );
  });

  group('Wave C Desktop — macOS NativeHostChannel Capture & HiDPI Pointer Bridge', () {
    test(
      'captures window JPEG, converts HiDPI xNorm/yNorm back to Quartz logical points on macOS, and fails closed without Screen Recording',
      () async {
        String? lastAction;
        String? lastValueText;
        final channel = _RecordingMacHostChannel(
          onInvoke: (action, valueText) {
            lastAction = action;
            lastValueText = valueText;
          },
        );
        final provider = NativeHostChannelComputerUseProvider(
          channel: channel,
          enableNativePointerAndCapture: true,
          isWindowsHost: false,
        );
        expect(provider.hasCaptureDriver, isTrue);

        final hybrid = await provider.observeHybrid(
          maxNodes: 20,
          maxEdge: 1280,
        );
        expect(hybrid.devicePixelRatio, 2.0);
        expect(hybrid.windowBounds['x'], 100);
        expect(hybrid.windowBounds['y'], 80);
        expect(hybrid.windowBounds['width'], 1000);
        expect(hybrid.windowBounds['height'], 600);
        expect(hybrid.screenshot.dataBase64, isNotEmpty);
        expect(channel.lastCaptureSomMarks, hasLength(1));
        expect(channel.lastCaptureSomMarks!.single['index'], 1);

        // ComputerUseSessionManager passes effX = (logicalX * dpr).round():
        // logical (600, 380) * 2.0 = (1200, 760) -> macOS CGEvent receives Quartz logical (600.00, 380.00).
        await provider.performClick(window: hybrid.window, x: 1200, y: 760);
        expect(lastAction, 'click_point');
        expect(lastValueText, '600.00,380.00');

        await provider.performDrag(
          window: hybrid.window,
          fromX: 400,
          fromY: 300,
          toX: 800,
          toY: 500,
        );
        expect(lastAction, 'drag_points');
        expect(lastValueText, '200.00,150.00,400.00,250.00');

        channel.failScreenRecording = true;
        await expectLater(
          () => provider.captureScreen(scope: 'active_window', maxEdge: 1280),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.needsPermission)
                .having((e) => e.errorCode, 'errorCode', 'screen_recording'),
          ),
        );

        // Double-click, hover, menuPath, and exactFocusedRole propagation (UDC-19)
        channel.activeWindowContextResult = const ActiveWindowContextSnapshot(
          appName: 'Figma',
          processName: 'com.figma.Desktop',
          windowTitle: 'Figma — Design',
          focusedRole: 'AXComboBox',
          exactFocusedRole: 'searchbox',
          visibleText: '',
        );
        final obs = await provider.inspectActiveWindow(maxNodes: 50);
        expect(obs.focusedRole, 'searchbox');

        await provider.performClick(
          window: obs,
          x: 1200,
          y: 760,
          clickCount: 2,
        );
        expect(lastAction, 'click_point');
        expect(lastValueText, '600.00,380.00,2,left');

        await provider.performClick(window: obs, x: 1200, y: 760, hover: true);
        expect(lastAction, 'click_point');
        expect(lastValueText, '600.00,380.00,0,left,hover');

        await provider.performClick(
          window: obs,
          menuPath: 'File > Open Folder...',
        );
        expect(lastAction, 'invoke_menu');
        expect(lastValueText, 'File > Open Folder...');
      },
    );

    test(
      'NativeHostChannelComputerUseProvider.observeHybrid applies password redaction and progressive observation filters directly',
      () async {
        final channel = _RecordingMacHostChannel(
          onInvoke: (_, __) {},
          overrideTreeNodes: const <Map<String, Object?>>[
            <String, Object?>{
              'refId': 'ui_wrap',
              'role': 'AXGroup',
              'label': '',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 0,
                'y': 0,
                'width': 1000,
                'height': 600,
              },
              'isPassword': false,
            },
            <String, Object?>{
              'refId': 'ui_pwd',
              'role': 'AXSecureTextField',
              'label': 'My Secret Password',
              'value': 'hunter2',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 100,
                'y': 100,
                'width': 200,
                'height': 40,
              },
              'isPassword': true,
            },
            <String, Object?>{
              'refId': 'ui_deep',
              'role': 'AXButton',
              'label': 'Deep Button',
              'depth': 4,
              'bounds': <String, Object?>{
                'x': 100,
                'y': 200,
                'width': 120,
                'height': 40,
              },
              'isPassword': false,
            },
            <String, Object?>{
              'refId': 'ui_btn',
              'role': 'AXButton',
              'label': 'Submit',
              'depth': 1,
              'bounds': <String, Object?>{
                'x': 500,
                'y': 300,
                'width': 100,
                'height': 60,
              },
              'isPassword': false,
            },
          ],
        );
        final provider = NativeHostChannelComputerUseProvider(
          channel: channel,
          enableNativePointerAndCapture: true,
          isWindowsHost: false,
        );

        final hybrid = await provider.observeHybrid(
          maxNodes: 20,
          maxEdge: 1280,
          collapseWebWrappers: true,
          skeleton: true,
          interactiveOnly: true,
        );
        final nodes = hybrid.window.nodes;
        expect(nodes.map((n) => n['id']).toList(), <String>[
          'ui_pwd',
          'ui_btn',
        ]);
        expect(nodes[0]['role'], 'password');
        expect(nodes[0]['name'], '•••');
        expect(nodes[0]['isPassword'], isTrue);
        expect(nodes[0].containsKey('bounds'), isFalse);
        expect(nodes[0].containsKey('value'), isFalse);

        expect(channel.lastCaptureSomMarks, hasLength(1));
        expect(channel.lastCaptureSomMarks!.single['index'], 2);
        expect(channel.lastCaptureSomMarks!.single['role'], 'button');
      },
    );

    test(
      'UDC-19 resolveHomeOpenTarget resolves unique targets and fails closed on missing, ambiguous, or protected paths',
      () async {
        final tmpHome = Directory.systemTemp.createTempSync('xuna_home_');
        addTearDown(() => tmpHome.deleteSync(recursive: true));

        final repoDir = Directory('${tmpHome.path}/xuna_pet')
          ..createSync(recursive: true);
        Directory('${repoDir.path}/.git').createSync();
        Directory(
          '${tmpHome.path}/Documents/dup_proj',
        ).createSync(recursive: true);
        Directory(
          '${tmpHome.path}/Projects/dup_proj',
        ).createSync(recursive: true);
        Directory('${tmpHome.path}/.ssh').createSync(recursive: true);
        File('${tmpHome.path}/.ssh/id_rsa').writeAsStringSync('secret');

        final indexer = AutoWorkspaceIndexer(
          customScanRoots: <String>[tmpHome.path],
          scanDefaultLocations: false,
        );

        final hit = await indexer.resolveHomeOpenTarget(
          'xuna_pet',
          customHomeDir: tmpHome.path,
        );
        expect(hit.displayAlias, 'xuna_pet');
        expect(hit.path.endsWith('xuna_pet'), isTrue);

        // Fail-closed H1: missing target
        await expectLater(
          () => indexer.resolveHomeOpenTarget(
            'does_not_exist_123',
            customHomeDir: tmpHome.path,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'target_not_found',
            ),
          ),
        );

        // Fail-closed H3: ambiguous target never picks the first
        await expectLater(
          () => indexer.resolveHomeOpenTarget(
            'dup_proj',
            customHomeDir: tmpHome.path,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'ambiguous_target',
            ),
          ),
        );

        // Disambiguated relative path succeeds
        final disambiguated = await indexer.resolveHomeOpenTarget(
          'Documents/dup_proj',
          customHomeDir: tmpHome.path,
        );
        expect(disambiguated.displayAlias, 'Documents/dup_proj');

        // Fail-closed security: .ssh and outside-home paths rejected
        await expectLater(
          () => indexer.resolveHomeOpenTarget(
            '.ssh/id_rsa',
            customHomeDir: tmpHome.path,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'target_forbidden',
            ),
          ),
        );
        await expectLater(
          () => indexer.resolveHomeOpenTarget(
            '/etc/passwd',
            customHomeDir: tmpHome.path,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'target_outside_home',
            ),
          ),
        );

        // Long (>60 chars) labels and shifted sequential `ui_N` ordinals do not
        // falsely fail with `stale_ref`, and `input.click(clickCount: 2)` passes
        // full `HostToolDispatcher` schema/policy validation end-to-end.
        const longLabel =
            'Anh Sai Rồi — Sơn Tùng M-TP • Bài hát • Đĩa đơn • 2012 • 04:12 • Phát ngay';
        final shiftHarness = await CuGateHarness.create(
          window: const ActiveWindowObservation(
            appId: 'explorer',
            processName: 'explorer.exe',
            windowTitle: 'Media Library',
            nodes: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'ui_1',
                'role': 'row',
                'name': longLabel,
                'enabled': true,
              },
            ],
          ),
        );
        try {
          await shiftHarness.startSession();
          final found = await shiftHarness.manager.findElements(
            query: 'Anh Sai Rồi',
          );
          final matchList = found['matches']! as List<Object?>;
          expect(matchList, hasLength(1));
          final foundRef =
              (matchList.single! as Map<String, Object?>)['ref']! as String;

          // Shift ordinal from ui_1 -> ui_2 by inserting a header button above it
          shiftHarness.provider.currentWindow = const ActiveWindowObservation(
            appId: 'explorer',
            processName: 'explorer.exe',
            windowTitle: 'Media Library',
            nodes: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'ui_1',
                'role': 'button',
                'name': 'Home',
                'enabled': true,
              },
              <String, Object?>{
                'id': 'ui_2',
                'role': 'row',
                'name': longLabel,
                'enabled': true,
              },
            ],
          );
          final clickMeta = await shiftHarness.dispatchMeta(
            'input.click',
            <String, Object?>{'elementId': foundRef, 'clickCount': 2},
            invocationId: 'inv-dbl-1',
          );
          expect(clickMeta['xuna/status'], 'ok');
        } finally {
          await shiftHarness.dispose();
        }
      },
    );
  });
}

class _RecordingMacHostChannel extends FakeXunaHostChannel {
  _RecordingMacHostChannel({required this.onInvoke, this.overrideTreeNodes});

  final void Function(String action, String? valueText) onInvoke;
  final List<Map<String, Object?>>? overrideTreeNodes;
  bool failScreenRecording = false;

  @override
  Future<WindowUiTreeSnapshot> inspectWindowUiTree({
    String? windowTitle,
    int maxNodes = 35,
  }) async {
    return WindowUiTreeSnapshot(
      windowTitle: 'Figma — Design',
      appName: 'Figma',
      windowX: 100,
      windowY: 80,
      windowWidth: 1000,
      windowHeight: 600,
      devicePixelRatio: 2.0,
      nodes:
          overrideTreeNodes ??
          const <Map<String, Object?>>[
            <String, Object?>{
              'refId': 'ui_1',
              'role': 'AXButton',
              'label': 'Export',
              'bounds': <String, Object?>{
                'x': 800,
                'y': 20,
                'width': 100,
                'height': 40,
              },
              'isPassword': false,
            },
          ],
    );
  }

  @override
  Future<HostScreenCaptureResult> captureScreen({
    String scope = 'active_window',
    int maxEdge = 1280,
    List<Map<String, Object?>>? somMarks,
  }) async {
    if (failScreenRecording) {
      throw const XunaHostChannelException(
        status: XtpStatus.needsPermission,
        errorCode: 'screen_recording',
      );
    }
    return super.captureScreen(
      scope: scope,
      maxEdge: maxEdge,
      somMarks: somMarks,
    );
  }

  @override
  Future<WindowUiControlActionResult> invokeWindowUiControl({
    required String action,
    required String refId,
    String? windowTitle,
    String? valueText,
    bool submit = true,
  }) async {
    onInvoke(action, valueText);
    return super.invokeWindowUiControl(
      action: action,
      refId: refId,
      windowTitle: windowTitle,
      valueText: valueText,
      submit: submit,
    );
  }
}

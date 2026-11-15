import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
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
            'bounds': <String, Object?>{'x': 100, 'y': 200, 'width': 200, 'height': 80},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'btn_send',
            'role': 'button',
            'name': 'Gửi báo cáo',
            'bounds': <String, Object?>{'x': 400, 'y': 200, 'width': 200, 'height': 80},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd1',
            'role': 'textfield',
            'name': 'Mật khẩu bảo vệ',
            'isPassword': true,
            'bounds': <String, Object?>{'x': 100, 'y': 400, 'width': 300, 'height': 50},
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

    test('observeHybrid extracts normalized tree bounds, HiDPI DPR and active window JPEG', () async {
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

      // Verify screenshot object
      final screenshot = result['screenshot'] as Map<String, Object?>;
      expect(screenshot['width'], 1280);
      expect(screenshot['dataBase64'], isNotEmpty);
    });

    test('observeHybrid fails closed with screen_recording when screen recording permission is missing', () async {
      harness.manager.hasScreenCapturePermission = false;

      expect(
        () => harness.manager.observeHybrid(maxNodes: 50, maxEdge: 1280),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'screen_recording')
              .having((e) => e.status, 'status', XtpStatus.needsPermission),
        ),
      );
    });

    test('observeHybrid wire-level JSON status is needs_permission with errorCode screen_recording', () async {
      harness.manager.hasScreenCapturePermission = false;

      final meta = await harness.dispatchMeta(
        'ui.observe_hybrid',
        <String, Object?>{'scope': 'active_window', 'maxNodes': 50, 'maxEdge': 1280},
        invocationId: 'inv-perm-observe-hybrid',
      );
      expect(meta['xuna/status'], 'needs_permission');
      expect(meta['xuna/errorCode'], 'screen_recording');

      final result = await harness.dispatchResult(
        'ui.observe_hybrid',
        <String, Object?>{'scope': 'active_window', 'maxNodes': 50, 'maxEdge': 1280},
        invocationId: 'inv-perm-observe-hybrid-full',
      );
      final wireJson = jsonDecode(jsonEncode(result)) as Map<String, Object?>;
      final wireMeta = wireJson['_meta'] as Map<String, Object?>;
      expect(wireMeta['xuna/status'], 'needs_permission');
      expect(wireMeta['xuna/errorCode'], 'screen_recording');
    });

    test('observeHybrid fails closed when screen capture driver is unsupported or fails', () async {
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
    });
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
            'bounds': <String, Object?>{'x': 100, 'y': 100, 'width': 200, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'conseq_btn',
            'role': 'button',
            'name': 'Xóa toàn bộ',
            'bounds': <String, Object?>{'x': 400, 'y': 100, 'width': 200, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd_field',
            'role': 'textfield',
            'name': 'Nhập mã pin',
            'isPassword': true,
            'bounds': <String, Object?>{'x': 100, 'y': 300, 'width': 200, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'edit_note',
            'role': 'textfield',
            'name': 'Ghi chú',
            'editable': true,
            'bounds': <String, Object?>{'x': 100, 'y': 500, 'width': 200, 'height': 50},
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

    test('coordinate click translates normalized coordinates to physical pixels with DPR', () async {
      // safe_btn center is at x: 200/1000=0.2, y: 125/800=0.15625
      // Logical coords: X = 50 + 200 = 250, Y = 50 + 125 = 175
      // Physical coords with DPR 1.5: X = 250 * 1.5 = 375, Y = 175 * 1.5 = 262.5 -> 263
      final result = await harness.manager.executeInputAction(
        toolName: 'input.click',
        arguments: <String, Object?>{
          'xNorm': 0.2,
          'yNorm': 0.15625,
        },
        hasR3Approval: false,
      );

      expect(result['effect'], 'changed');
      expect(result['settled'], isNotNull);
      expect(result['settleMs'], isNotNull);
      expect(harness.provider.recordedCalls, contains('click:375,263'));
    });

    test('coordinate click on password field is unconditionally refused', () async {
      // pwd_field center is at x: 200/1000=0.2, y: 325/800=0.40625
      expect(
        () => harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{
            'xNorm': 0.2,
            'yNorm': 0.40625,
          },
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'password_field_forbidden')
              .having((e) => e.status, 'status', XtpStatus.denied),
        ),
      );

      // Preflight also refuses unconditionally
      expect(
        () => harness.manager.preflightInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{
            'xNorm': 0.2,
            'yNorm': 0.40625,
          },
        ),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'password_field_forbidden'),
        ),
      );
    });

    test('coordinate click on consequential button requires R3 approval', () async {
      // conseq_btn ("Xóa toàn bộ") center is at x: 500/1000=0.5, y: 125/800=0.15625
      expect(
        () => harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{
            'xNorm': 0.5,
            'yNorm': 0.15625,
          },
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
        arguments: <String, Object?>{
          'xNorm': 0.5,
          'yNorm': 0.15625,
        },
      );
      expect(preflight.stepRisk.risk, RiskTier.r3);
      expect(preflight.stepRisk.reasonCode, 'consequential_target');

      // With verified R3 approval over real HostToolDispatcher wire path (including
      // P-256 signature + RFC 8785 float argsSha256 binding), execution succeeds.
      const wireArgs = <String, Object?>{
        'xNorm': 0.5,
        'yNorm': 0.15625,
      };
      final wireResult = await harness.dispatchResult(
        'input.click',
        wireArgs,
        approval: harness.signedApproval(wireArgs),
        invocationId: 'inv-r3-coord-click-signed',
      );
      final wireMeta = (wireResult['_meta'] as Map).cast<String, Object?>();
      final wireContent =
          (wireResult['structuredContent'] as Map).cast<String, Object?>();
      expect(wireMeta['xuna/status'], 'ok');
      expect(wireContent['effect'], 'changed');
    });

    test('coordinate click on unclassified location requires R3 approval', () async {
      // Empty background at x: 0.9, y: 0.9
      expect(
        () => harness.manager.executeInputAction(
          toolName: 'input.click',
          arguments: <String, Object?>{
            'xNorm': 0.9,
            'yNorm': 0.9,
          },
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'approval_required'),
        ),
      );
    });

    test('uncommitted draft text blocks coordinate click on non-draft targets', () async {
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
          arguments: <String, Object?>{
            'xNorm': 0.2,
            'yNorm': 0.15625,
          },
          hasR3Approval: false,
        ),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'approval_required'),
        ),
      );
    });

    test('consecutive coordinate clicks and drags in a multi-step session retain window geometry and DPR scaling', () async {
      // Step 1: First click on safe_btn (xNorm: 0.2, yNorm: 0.15625)
      // Logical coords: X = 50 + (0.2 * 1000) = 250, Y = 50 + (0.15625 * 800) = 175
      // Physical coords with DPR 1.5: X = 250 * 1.5 = 375, Y = 175 * 1.5 = 262.5 -> 263
      final step1Result = await harness.manager.executeInputAction(
        toolName: 'input.click',
        arguments: <String, Object?>{
          'xNorm': 0.2,
          'yNorm': 0.15625,
        },
        hasR3Approval: false,
      );
      expect(step1Result['effect'], 'changed');
      expect(harness.provider.recordedCalls, contains('click:375,263'));

      // Verify that after mutation, currentWindow preserved window bounds and DPR
      final winAfterStep1 = await harness.provider.inspectActiveWindow(maxNodes: 10);
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
        arguments: <String, Object?>{
          'xNorm': 0.25,
          'yNorm': 0.15625,
        },
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
      expect(harness.provider.recordedCalls, contains('drag:375,263->450,263'));

      // Verify geometry and DPR remain intact after multiple mutations
      final winAfterStep3 = await harness.provider.inspectActiveWindow(maxNodes: 10);
      expect(winAfterStep3.windowX, 50);
      expect(winAfterStep3.windowY, 50);
      expect(winAfterStep3.windowWidth, 1000);
      expect(winAfterStep3.windowHeight, 800);
      expect(winAfterStep3.devicePixelRatio, 1.5);
    });
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
            'bounds': <String, Object?>{'x': 100, 'y': 100, 'width': 100, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'folder1',
            'role': 'folder',
            'name': 'FolderArchive',
            'bounds': <String, Object?>{'x': 500, 'y': 500, 'width': 100, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'delete_bin',
            'role': 'button',
            'name': 'Delete Bin',
            'bounds': <String, Object?>{'x': 800, 'y': 800, 'width': 100, 'height': 50},
            'enabled': true,
          },
          <String, Object?>{
            'id': 'pwd_drop',
            'role': 'textfield',
            'name': 'Mật khẩu bảo mật',
            'isPassword': true,
            'bounds': <String, Object?>{'x': 800, 'y': 200, 'width': 100, 'height': 50},
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

    test('input.drag executes drag between coordinates and reports settle status', () async {
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
    });

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
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'password_field_forbidden'),
        ),
      );
    });

    test('input.drag landing on consequential target requires R3 approval', () async {
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
          isA<XunaHostChannelException>()
              .having((e) => e.errorCode, 'errorCode', 'approval_required'),
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
    });
  });

  group('Wave C Desktop — Dispatcher Tool Registration & ParallelReadLane', () {
    late CuGateHarness harness;

    setUp(() async {
      harness = await CuGateHarness.create();
    });

    tearDown(() async {
      await harness.dispose();
    });

    test('HostToolDispatcher registers ui.observe_hybrid and input.drag in manifest', () async {
      final manifest = await harness.dispatcher.buildManifest();
      final toolNames = manifest.map((t) => t.name).toList();

      expect(toolNames, contains('ui.observe_hybrid'));
      expect(toolNames, contains('input.drag'));
      expect(toolNames, contains('input.click'));
      expect(toolNames, contains('screen.capture'));
      expect(toolNames, contains('ui.inspect'));
    });
  });
}

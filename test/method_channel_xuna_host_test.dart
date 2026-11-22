import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('xuna/host');
  late MethodChannelXunaHostChannel hostChannel;
  final recordedCalls = <MethodCall>[];

  final samplePubKey = Uint8List.fromList(<int>[
    0x04,
    ...List<int>.generate(64, (i) => (i + 1) & 0xff),
  ]);
  final sampleSignature = Uint8List.fromList(
    List<int>.generate(64, (i) => (i + 3) & 0xff),
  );

  setUp(() {
    recordedCalls.clear();
    hostChannel = MethodChannelXunaHostChannel(
      channel: channel,
      callTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'maps all 12 MethodChannel methods (keyEnsure, keySign, media, volumeSet, nowPlaying, appLaunch, urlOpen, workflowRun, permissions, requestPermission, hostInfo, showToast)',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedCalls.add(call);
            switch (call.method) {
              case 'keyEnsure':
                return <String, Object?>{
                  'publicKey': base64.encode(samplePubKey),
                };
              case 'keySign':
                return <String, Object?>{
                  'signature': base64.encode(sampleSignature),
                };
              case 'media':
                return <String, Object?>{'state': 'playing'};
              case 'volumeSet':
                final map = call.arguments as Map<Object?, Object?>;
                return <String, Object?>{'level': map['level']};
              case 'nowPlaying':
                return <String, Object?>{
                  'state': 'playing',
                  'title': 'Song A',
                  'artist': 'Artist B',
                  'app': 'spotify',
                };
              case 'appLaunch':
              case 'urlOpen':
              case 'workflowRun':
              case 'showToast':
                return <String, Object?>{};
              case 'displayWake':
                return <String, Object?>{'awake': true};
              case 'clipboardReadText':
                return <String, Object?>{'text': 'Exception: stack overflow'};
              case 'lockScreen':
                return <String, Object?>{'locked': true};
              case 'browserCurrentUrl':
                return <String, Object?>{
                  'url': 'https://github.com/xthao28/xuna_pet',
                  'browser': 'edge',
                };
              case 'permissions':
                return <String, Object?>{
                  'accessibility': 'granted',
                  'notifications': 'denied',
                  'automation': <String, Object?>{
                    'com.spotify.client': 'granted',
                  },
                };
              case 'requestPermission':
                return <String, Object?>{'state': 'granted'};
              case 'readActiveWindowContext':
                return <String, Object?>{
                  'appName': 'VS Code',
                  'processName': 'Code.exe',
                  'windowTitle': 'main.dart',
                  'focusedRole': 'editor',
                  'visibleText': 'hello',
                  'isElevated': false,
                  'runningApps': <Object?>[
                    <String, Object?>{
                      'name': 'Visual Studio Code',
                      'bundleId': 'com.microsoft.VSCode',
                    },
                    <String, Object?>{
                      'name': '1Password',
                      'bundleId': 'com.1password.1password',
                    },
                    'malformed',
                  ],
                };
              case 'hostInfo':
                return <String, Object?>{
                  'platform': 'windows',
                  'osVersion': '10.0.22631',
                  'hostname': 'THAO-PC',
                };
              default:
                return null;
            }
          });

      expect(await hostChannel.keyEnsure(), samplePubKey);
      expect(
        await hostChannel.keySign(Uint8List.fromList(<int>[1, 2, 3])),
        sampleSignature,
      );
      expect(await hostChannel.media('play_pause'), 'playing');
      expect(await hostChannel.volumeSet(75), 75);

      final np = await hostChannel.nowPlaying(const <String>['spotify']);
      expect(np.state, 'playing');
      expect(np.title, 'Song A');
      expect(np.app, 'spotify');

      final launchRes = await hostChannel.appLaunch(
        kind: AppLaunchKind.exe,
        target: r'C:\Program Files\App\app.exe',
      );
      expect(launchRes.alreadyRunning, isFalse);
      await hostChannel.urlOpen('https://github.com');
      final tabSnap = await hostChannel.browserCurrentUrl(browser: 'edge');
      expect(tabSnap.url, 'https://github.com/xthao28/xuna_pet');
      expect(tabSnap.browser, 'edge');
      await hostChannel.workflowRun(
        kind: WorkflowKind.lnk,
        target: r'C:\Users\Thao\Focus.lnk',
      );

      final perms = await hostChannel.permissions();
      expect(perms.accessibility, XtpPermissionState.granted);
      expect(perms.notifications, XtpPermissionState.denied);
      expect(
        perms.automation['com.spotify.client'],
        XtpPermissionState.granted,
      );

      expect(
        await hostChannel.requestPermission('accessibility'),
        XtpPermissionState.granted,
      );

      final info = await hostChannel.hostInfo();
      expect(info.platform, HostPlatform.windows);
      expect(info.osVersion, '10.0.22631');
      expect(info.hostname, 'THAO-PC');

      await hostChannel.showToast(title: 'XUNA', body: 'XUNA: đã mở VS Code');
      expect(await hostChannel.displayWake(), isTrue);
      expect(
        await hostChannel.clipboardReadText(),
        'Exception: stack overflow',
      );
      expect(await hostChannel.lockScreen(), isTrue);

      expect(recordedCalls.map((c) => c.method).toList(), <String>[
        'keyEnsure',
        'keySign',
        'media',
        'volumeSet',
        'nowPlaying',
        'appLaunch',
        'urlOpen',
        'browserCurrentUrl',
        'workflowRun',
        'permissions',
        'requestPermission',
        'hostInfo',
        'showToast',
        'displayWake',
        'clipboardReadText',
        'lockScreen',
      ]);

      final ctxSnap = await hostChannel.readActiveWindowContext();
      expect(ctxSnap.runningApps, hasLength(1));
      expect(ctxSnap.runningApps.first.name, 'Visual Studio Code');
      expect(ctxSnap.runningApps.first.bundleId, 'com.microsoft.VSCode');
    },
  );

  test(
    'translates PlatformException and TimeoutException to XunaHostChannelException',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'media') {
              throw PlatformException(
                code: 'needs_permission',
                message: 'AX missing',
              );
            }
            if (call.method == 'nowPlaying') {
              throw PlatformException(code: 'unsupported', message: 'No GSMTC');
            }
            if (call.method == 'volumeSet') {
              await Future<void>.delayed(const Duration(milliseconds: 500));
              return <String, Object?>{'level': 50};
            }
            throw PlatformException(code: 'failed', message: 'OS error');
          });

      await expectLater(
        hostChannel.media('play_pause'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.needsPermission)
              .having((e) => e.errorCode, 'errorCode', 'permission_missing'),
        ),
      );

      await expectLater(
        hostChannel.nowPlaying(const <String>['spotify']),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.unsupported)
              .having((e) => e.errorCode, 'errorCode', 'platform_unsupported'),
        ),
      );

      await expectLater(
        hostChannel.volumeSet(50),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.timeout)
              .having((e) => e.errorCode, 'errorCode', 'deadline_exceeded'),
        ),
      );
    },
  );

  test(
    'macOS provider contracts: bundle launch, shortcut workflow, and needs_permission in HostToolDispatcher without crash',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('xuna_macos_test_');
      addTearDown(() => tempDir.delete(recursive: true));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedCalls.add(call);
            switch (call.method) {
              case 'readActiveWindowContext':
                return <String, Object?>{
                  'appName': 'VS Code',
                  'processName': 'Code.exe',
                  'windowTitle': 'main.dart',
                  'focusedRole': 'editor',
                  'visibleText': 'hello',
                  'isElevated': false,
                  'runningApps': <Object?>[
                    <String, Object?>{
                      'name': 'Visual Studio Code',
                      'bundleId': 'com.microsoft.VSCode',
                    },
                    <String, Object?>{
                      'name': '1Password',
                      'bundleId': 'com.1password.1password',
                    },
                    'malformed',
                  ],
                };
              case 'hostInfo':
                return <String, Object?>{
                  'platform': 'macos',
                  'osVersion': '14.5.0',
                  'hostname': 'Thao-MacBook-Pro',
                };
              case 'appLaunch':
                final map = call.arguments as Map<Object?, Object?>;
                expect(map['kind'], 'bundle');
                expect(map['target'], 'com.apple.Music');
                return <String, Object?>{'alreadyRunning': true};
              case 'workflowRun':
                final map = call.arguments as Map<Object?, Object?>;
                expect(map['kind'], 'shortcut');
                expect(map['target'], 'Focus Mode');
                return <String, Object?>{};
              case 'media':
              case 'nowPlaying':
                throw PlatformException(
                  code: 'needs_permission',
                  message: 'Accessibility or Automation permission required',
                );
              case 'requestPermission':
                final map = call.arguments as Map<Object?, Object?>;
                expect(map['kind'], 'automation:com.apple.Music');
                return <String, Object?>{'state': 'denied'};
              default:
                return <String, Object?>{};
            }
          });

      final info = await hostChannel.hostInfo();
      expect(info.platform, HostPlatform.macos);
      expect(info.osVersion, '14.5.0');

      final macLaunch = await hostChannel.appLaunch(
        kind: AppLaunchKind.bundle,
        target: 'com.apple.Music',
      );
      expect(macLaunch.alreadyRunning, isTrue);
      await hostChannel.workflowRun(
        kind: WorkflowKind.shortcut,
        target: 'Focus Mode',
      );
      expect(
        await hostChannel.requestPermission('automation:com.apple.Music'),
        XtpPermissionState.denied,
      );

      final logger = ContentFreeLogger();
      final policyStore = HostPolicyStore(
        policyFile: File('${tempDir.path}/host-policy.json'),
        logger: logger,
      );
      await policyStore.writeDefaultPolicy();

      final stopController = EmergencyStopController(logger: logger);
      final dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: hostChannel,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        logger: logger,
      );
      addTearDown(() async {
        dispatcher.dispose();
        await stopController.dispose();
        await policyStore.dispose();
      });

      final mediaResp = await dispatcher.dispatch(
        requestId: 'inv-mac-1',
        params: const ToolsCallParams(
          name: 'media.play_pause',
          arguments: <String, Object?>{},
          invocationId: '33333333-3333-4333-8333-333333333333',
          deadlineMs: 5000,
        ),
      );
      final mediaMeta = mediaResp.result['_meta'] as Map<String, Object?>;
      expect(mediaResp.result['isError'], isTrue);
      expect(mediaMeta['xuna/status'], 'needs_permission');

      final nowPlayingResp = await dispatcher.dispatch(
        requestId: 'inv-mac-2',
        params: const ToolsCallParams(
          name: 'media.now_playing',
          arguments: <String, Object?>{},
          invocationId: '44444444-4444-4444-8444-444444444444',
          deadlineMs: 5000,
        ),
      );
      final npMeta = nowPlayingResp.result['_meta'] as Map<String, Object?>;
      expect(nowPlayingResp.result['isError'], isTrue);
      expect(npMeta['xuna/status'], 'needs_permission');
    },
  );

  test(
    'lockScreen and displayWake report the native result and fail instead of inventing success when it is missing',
    () async {
      var reply = <String, Object?>{'locked': false, 'awake': false};
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => reply);

      // A real "not locked" answer is passed through, not turned into true.
      expect(await hostChannel.lockScreen(), isFalse);
      expect(await hostChannel.displayWake(), isFalse);

      reply = <String, Object?>{};
      for (final call in <Future<Object?> Function()>[
        hostChannel.lockScreen,
        hostChannel.displayWake,
      ]) {
        await expectLater(
          call(),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.failed)
                .having((e) => e.errorCode, 'errorCode', 'os_error'),
          ),
        );
      }
    },
  );

  test(
    'a failed OS permission read is advertised as not_determined, never granted',
    () async {
      final tempDir = await Directory.systemTemp.createTemp('xuna_perm_test_');
      addTearDown(() => tempDir.delete(recursive: true));
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'permissions') {
              throw PlatformException(code: 'failed', message: 'probe failed');
            }
            return <String, Object?>{};
          });

      final logger = ContentFreeLogger();
      final policyStore = HostPolicyStore(
        policyFile: File('${tempDir.path}/host-policy.json'),
        logger: logger,
      );
      await policyStore.writeDefaultPolicy();
      final stopController = EmergencyStopController(logger: logger);
      final dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: hostChannel,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        logger: logger,
      );
      addTearDown(() async {
        dispatcher.dispose();
        await stopController.dispose();
        await policyStore.dispose();
      });

      final manifest = await dispatcher.buildManifest();
      final activeCtx = manifest.firstWhere(
        (t) => t.name == 'window.active_context',
      );
      expect(activeCtx.policy.permission, XtpPermissionState.notDetermined);
      expect(
        manifest.any((t) => t.policy.permission == XtpPermissionState.granted),
        isFalse,
      );
      expect(
        const HostPermissionSnapshot.unknown().toWireMap(),
        <String, String>{
          'accessibility': 'not_determined',
          'notifications': 'not_determined',
        },
      );
    },
  );

  test(
    'captureScreen forwards non-empty somMarks, omits somMarks when null or empty, and maps errors fail-closed',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedCalls.add(call);
            if (call.method == 'captureScreen') {
              final args = (call.arguments as Map<Object?, Object?>)
                  .cast<String, Object?>();
              if (args['maxEdge'] == 400) {
                return <String, Object?>{
                  'mimeType': 'image/jpeg',
                  'width': 400,
                  'height': 300,
                  'dataBase64': '',
                };
              }
              if (args['scope'] == 'denied_case') {
                throw PlatformException(
                  code: 'screen_recording',
                  message: 'Missing TCC permission',
                );
              }
              return <String, Object?>{
                'mimeType': 'image/jpeg',
                'width': 1280,
                'height': 720,
                'dataBase64': '/9j/4AAQSkZJRgABAQAAAQABAAD/',
              };
            }
            return <String, Object?>{};
          });

      // Plain capture omits somMarks
      await hostChannel.captureScreen(scope: 'active_window', maxEdge: 1280);
      final plainArgs = (recordedCalls.last.arguments as Map<Object?, Object?>)
          .cast<String, Object?>();
      expect(plainArgs.containsKey('somMarks'), isFalse);

      // Empty list omits somMarks
      await hostChannel.captureScreen(
        scope: 'active_window',
        maxEdge: 1280,
        somMarks: const <Map<String, Object?>>[],
      );
      final emptyArgs = (recordedCalls.last.arguments as Map<Object?, Object?>)
          .cast<String, Object?>();
      expect(emptyArgs.containsKey('somMarks'), isFalse);

      // Non-empty somMarks are forwarded
      final marks = <Map<String, Object?>>[
        <String, Object?>{
          'index': 1,
          'bounds': <double>[0.1, 0.2, 0.3, 0.4],
          'role': 'button',
        },
      ];
      final res = await hostChannel.captureScreen(
        scope: 'active_window',
        maxEdge: 1024,
        somMarks: marks,
      );
      expect(res.width, 1280);
      final somArgs = (recordedCalls.last.arguments as Map<Object?, Object?>)
          .cast<String, Object?>();
      expect(somArgs['somMarks'], equals(marks));

      // Empty dataBase64 fails closed with capture_failed
      await expectLater(
        () => hostChannel.captureScreen(scope: 'active_window', maxEdge: 400),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.failed)
              .having((e) => e.errorCode, 'errorCode', 'capture_failed'),
        ),
      );

      // Missing screen recording permission propagates screen_recording
      await expectLater(
        () => hostChannel.captureScreen(scope: 'denied_case', maxEdge: 640),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.needsPermission)
              .having((e) => e.errorCode, 'errorCode', 'screen_recording'),
        ),
      );
    },
  );

  test(
    'presenceProbe parses laptop & desktop payloads, filters hard-denied apps, and fails closed on invalid/error responses',
    () async {
      var mode = 'laptop';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'presenceProbe') return null;
            switch (mode) {
              case 'laptop':
                return <String, Object?>{
                  'idleSeconds': 12,
                  'screenLocked': false,
                  'mediaPlaying': true,
                  'batteryPercent': 78,
                  'isCharging': true,
                  'foregroundAppId': 'Visual Studio Code',
                };
              case 'hard_denied':
                return <String, Object?>{
                  'idleSeconds': 0,
                  'screenLocked': false,
                  'mediaPlaying': false,
                  'foregroundAppId': '1Password',
                };
              case 'desktop_no_battery':
                return <String, Object?>{
                  'idleSeconds': 45,
                  'screenLocked': true,
                  'mediaPlaying': false,
                };
              case 'missing_required':
                return <String, Object?>{
                  'idleSeconds': 1,
                  'screenLocked': false,
                };
              case 'bool_idle':
                return <String, Object?>{
                  'idleSeconds': true,
                  'screenLocked': false,
                  'mediaPlaying': false,
                };
              case 'bad_battery':
                return <String, Object?>{
                  'idleSeconds': 1,
                  'screenLocked': false,
                  'mediaPlaying': false,
                  'batteryPercent': 101,
                };
              case 'native_error':
                throw PlatformException(
                  code: 'failed',
                  message: 'CGSessionCopyCurrentDictionary returned nil',
                );
              case 'timeout':
                await Future<void>.delayed(const Duration(milliseconds: 500));
                return <String, Object?>{
                  'idleSeconds': 0,
                  'screenLocked': false,
                  'mediaPlaying': false,
                };
              default:
                return null;
            }
          });

      final laptop = await hostChannel.presenceProbe();
      expect(laptop.idleSeconds, 12);
      expect(laptop.screenLocked, isFalse);
      expect(laptop.mediaPlaying, isTrue);
      expect(laptop.batteryPercent, 78);
      expect(laptop.isCharging, isTrue);
      expect(laptop.foregroundAppId, 'visual_studio_code');

      mode = 'hard_denied';
      final denied = await hostChannel.presenceProbe();
      expect(denied.foregroundAppId, isNull);

      mode = 'desktop_no_battery';
      final desktop = await hostChannel.presenceProbe();
      expect(desktop.idleSeconds, 45);
      expect(desktop.screenLocked, isTrue);
      expect(desktop.mediaPlaying, isFalse);
      expect(desktop.batteryPercent, isNull);
      expect(desktop.isCharging, isNull);
      expect(desktop.foregroundAppId, isNull);

      for (final badMode in <String>[
        'missing_required',
        'bool_idle',
        'bad_battery',
        'native_error',
      ]) {
        mode = badMode;
        await expectLater(
          hostChannel.presenceProbe(),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.status,
              'status',
              XtpStatus.failed,
            ),
          ),
          reason: 'Expected fail-closed XunaHostChannelException for $badMode',
        );
      }

      mode = 'timeout';
      await expectLater(
        hostChannel.presenceProbe(),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.timeout)
              .having((e) => e.errorCode, 'errorCode', 'deadline_exceeded'),
        ),
      );
    },
  );

  test(
    'clipboardWriteText round-trip, PlatformException errorCode preservation, and browserCurrentUrl fail-closed',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            recordedCalls.add(call);
            switch (call.method) {
              case 'clipboardWriteText':
                final args = call.arguments as Map<Object?, Object?>;
                if (args['text'] == 'fail_native') {
                  throw PlatformException(
                    code: 'failed',
                    message: 'Pasteboard write failed',
                    details: <String, Object?>{
                      'errorCode': 'clipboard_write_failed',
                    },
                  );
                }
                return <String, Object?>{'written': true};
              case 'browserCurrentUrl':
                final args = call.arguments as Map<Object?, Object?>;
                final req = args['browser'] as String?;
                if (req == 'missing_browser') {
                  return <String, Object?>{'url': 'https://example.com'};
                }
                if (req == 'ambiguous') {
                  throw PlatformException(
                    code: 'invalid_args',
                    message: 'Multiple browsers running',
                    details: <String, Object?>{
                      'errorCode': 'browser_ambiguous',
                    },
                  );
                }
                if (req == 'tcc_denied') {
                  throw PlatformException(
                    code: 'needs_permission',
                    message: 'Automation denied',
                    details: <String, Object?>{
                      'errorCode': 'automation_denied',
                    },
                  );
                }
                if (req == 'bad_args_no_details') {
                  throw PlatformException(code: 'invalid_args', message: 'bad');
                }
                if (req == 'denied_no_details') {
                  throw PlatformException(code: 'denied', message: 'blocked');
                }
                return <String, Object?>{
                  'url': 'https://github.com/xthao28/xuna_pet',
                  'browser': 'safari',
                };
              default:
                return null;
            }
          });

      await hostChannel.clipboardWriteText('Hello XUNA');
      expect(recordedCalls.last.method, 'clipboardWriteText');
      expect(
        (recordedCalls.last.arguments as Map<Object?, Object?>)['text'],
        'Hello XUNA',
      );

      await expectLater(
        hostChannel.clipboardWriteText('fail_native'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.failed)
              .having(
                (e) => e.errorCode,
                'errorCode',
                'clipboard_write_failed',
              ),
        ),
      );

      // Missing/invalid browser from native fails closed instead of defaulting to 'edge'.
      await expectLater(
        hostChannel.browserCurrentUrl(browser: 'missing_browser'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.failed)
              .having((e) => e.errorCode, 'errorCode', 'os_error'),
        ),
      );

      // Preserves details['errorCode'] and maps invalid_args / denied without details cleanly.
      await expectLater(
        hostChannel.browserCurrentUrl(browser: 'ambiguous'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.invalidArgs)
              .having((e) => e.errorCode, 'errorCode', 'browser_ambiguous'),
        ),
      );
      await expectLater(
        hostChannel.browserCurrentUrl(browser: 'tcc_denied'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.needsPermission)
              .having((e) => e.errorCode, 'errorCode', 'automation_denied'),
        ),
      );
      await expectLater(
        hostChannel.browserCurrentUrl(browser: 'bad_args_no_details'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.invalidArgs)
              .having((e) => e.errorCode, 'errorCode', 'invalid_args'),
        ),
      );
      await expectLater(
        hostChannel.browserCurrentUrl(browser: 'denied_no_details'),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.denied)
              .having((e) => e.errorCode, 'errorCode', 'policy_blocked'),
        ),
      );
    },
  );
}

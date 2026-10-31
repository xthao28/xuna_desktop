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

      await hostChannel.appLaunch(
        kind: AppLaunchKind.exe,
        target: r'C:\Program Files\App\app.exe',
      );
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
      expect(await hostChannel.clipboardReadText(), 'Exception: stack overflow');
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
                return <String, Object?>{};
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

      await hostChannel.appLaunch(
        kind: AppLaunchKind.bundle,
        target: 'com.apple.Music',
      );
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
}

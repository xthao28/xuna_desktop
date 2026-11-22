import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/presence/presence_coordinator.dart';
import 'package:xuna_desktop/features/presence/resource_digest_builder.dart';
import 'package:xuna_desktop/features/presence/subnet_hash.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/desktop_tray_service.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._outbound);

  final StreamController<String> _outbound;

  @override
  void add(Object? data) {
    if (data is String && !_outbound.isClosed) {
      _outbound.add(data);
    }
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final item in stream) {
      add(item);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    if (!_outbound.isClosed) {
      await _outbound.close();
    }
  }

  @override
  Future<void> get done => _outbound.done;
}

class _FakeWebSocketChannel extends Fake implements WebSocketChannel {
  _FakeWebSocketChannel() {
    _sink = _FakeWebSocketSink(_outbound);
  }

  final StreamController<Object?> inbound = StreamController<Object?>();
  final StreamController<String> _outbound =
      StreamController<String>.broadcast();
  late final _FakeWebSocketSink _sink;

  Stream<String> get outboundFrames => _outbound.stream;

  @override
  String? get protocol => 'xtp/1';

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => inbound.stream;
}

Future<void> _driveReconnectToReady(
  _FakeWebSocketChannel ws,
  List<String> sentFrames,
) async {
  // Wait for xuna/hello
  while (sentFrames.isEmpty) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final hello = XtpFrame.parse(sentFrames.first) as XtpRequest;
  expect(hello.method, equals('xuna/hello'));
  ws.inbound.add(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': hello.id,
      'result': <String, Object?>{'protocol': 'xtp/1'},
    }),
  );

  final nonceB64 = base64Encode(List<int>.filled(32, 7));
  ws.inbound.add(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'xuna/challenge',
      'params': <String, Object?>{
        'purpose': 2,
        'nonce': nonceB64,
        'expiresIn': 60,
      },
    }),
  );

  // Wait for xuna/proof
  while (sentFrames.length < 2) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  final proof = XtpFrame.parse(sentFrames[1]) as XtpRequest;
  expect(proof.method, equals('xuna/proof'));
  ws.inbound.add(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'id': proof.id,
      'result': <String, Object?>{'verified': true},
    }),
  );

  ws.inbound.add(
    jsonEncode(<String, Object?>{
      'jsonrpc': '2.0',
      'method': 'xuna/ready',
      'params': <String, Object?>{
        'serverTime': '2026-11-20T16:00:00Z',
        'heartbeatS': 30,
      },
    }),
  );
  await Future<void>.delayed(const Duration(milliseconds: 20));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Tier 1/2 — Dart SubnetHashCalculator (F10)', () {
    String canonicalSubnetSha256(String canonicalCidr) => sha256
        .convert(utf8.encode('xuna.mesh.subnet.v1:$canonicalCidr'))
        .toString()
        .substring(0, 32);

    test('T1-F10-03: hashes /24 IPv4 and /64 IPv6 with canonical xuna.mesh.subnet.v1 SHA-256 parity', () {
      final hashA = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('192.168.1.42'),
      ]);
      final hashB = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('192.168.1.99'),
      ]);
      final hashDifferentSubnet =
          SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
            InternetAddress('192.168.2.42'),
          ]);

      expect(hashA, isNotNull);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(hashA!), isTrue);
      expect(hashA, equals(canonicalSubnetSha256('ipv4:192.168.1.0/24')));
      expect(hashA, equals(hashB));
      expect(
        hashDifferentSubnet,
        equals(canonicalSubnetSha256('ipv4:192.168.2.0/24')),
      );
      expect(hashA, isNot(equals(hashDifferentSubnet)));
      expect(hashA.contains('192.168'), isFalse);

      // Priority & lexicographical tie-breaking: private IPv4 > other IPv4 > IPv6.
      final prioritized = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('2001:db8:0:1::42'),
        InternetAddress('8.8.8.8'),
        InternetAddress('192.168.10.5'),
        InternetAddress('10.0.0.99'),
      ]);
      expect(prioritized, equals(canonicalSubnetSha256('ipv4:10.0.0.0/24')));

      // IPv6 /64 canonical zero-padded 4-digit lowercase hex groups.
      final v6A = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('2001:db8:abcd:12::5'),
      ]);
      final v6B = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('2001:db8:abcd:12::99'),
      ]);
      final v6ZeroPadded = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('2001:db8:0:1::1234'),
      ]);
      expect(v6A, isNotNull);
      expect(RegExp(r'^[0-9a-f]{32}$').hasMatch(v6A!), isTrue);
      expect(v6A, equals(canonicalSubnetSha256('ipv6:2001:0db8:abcd:0012::/64')));
      expect(v6A, equals(v6B));
      expect(
        v6ZeroPadded,
        equals(canonicalSubnetSha256('ipv6:2001:0db8:0000:0001::/64')),
      );
    });

    test('T2-F10-03: ignores loopback, unspecified, and link-local addresses and returns null when offline', () async {
      expect(
        SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
          InternetAddress('127.0.0.1'),
          InternetAddress('169.254.10.20'),
          InternetAddress('0.0.0.0'),
          InternetAddress('::1'),
          InternetAddress('::'),
          InternetAddress('fe80::1'),
        ]),
        isNull,
      );

      final calc = SubnetHashCalculator(
        interfaceLister: () async => throw const SocketException('no interfaces'),
      );
      expect(await calc.compute(), isNull);
    });
  });

  group('Tier 1/2 — MethodChannelXunaHostChannel.presenceProbe (F10, H1/H2/H4)', () {
    const channel = MethodChannel('xuna/host');
    late MethodChannelXunaHostChannel hostChannel;

    setUp(() {
      hostChannel = MethodChannelXunaHostChannel(
        channel: channel,
        callTimeout: const Duration(milliseconds: 200),
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('T1-F10-02 & T2-F10-01/02: preserves null battery, screenLocked/null foreground, and normalizes app ID', () async {
      var mode = 'desktop';
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method != 'presenceProbe') return null;
            if (mode == 'desktop') {
              return <String, Object?>{
                'idleSeconds': 0,
                'screenLocked': true,
                'mediaPlaying': false,
                'batteryPercent': null,
                'isCharging': null,
                'foregroundAppId': null,
              };
            }
            if (mode == 'long_app') {
              return <String, Object?>{
                'idleSeconds': 15,
                'screenLocked': false,
                'mediaPlaying': true,
                'batteryPercent': 78,
                'isCharging': true,
                'foregroundAppId':
                    'My Very Long Custom Application Name Exceeding Sixty Four Characters Total.app',
              };
            }
            // Hard-denied terminal process should be scrubbed to null.
            return <String, Object?>{
              'idleSeconds': 5,
              'screenLocked': false,
              'mediaPlaying': false,
              'foregroundAppId': '1Password',
            };
          });

      final desktop = await hostChannel.presenceProbe();
      expect(desktop.screenLocked, isTrue);
      expect(desktop.batteryPercent, isNull);
      expect(desktop.isCharging, isNull);
      expect(desktop.foregroundAppId, isNull);

      mode = 'long_app';
      final laptop = await hostChannel.presenceProbe();
      expect(laptop.batteryPercent, equals(78));
      expect(laptop.isCharging, isTrue);
      expect(laptop.foregroundAppId, isNotNull);
      expect(laptop.foregroundAppId!.length, lessThanOrEqualTo(64));
      expect(
        RegExp(r'^[a-z0-9_.-]{1,64}$').hasMatch(laptop.foregroundAppId!),
        isTrue,
      );

      mode = 'denied_app';
      final denied = await hostChannel.presenceProbe();
      expect(denied.foregroundAppId, isNull);
    });

    test('T2-F10-04/05: fail-closed on negative idleSeconds and PlatformException', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'presenceProbe') {
              return <String, Object?>{
                'idleSeconds': -1,
                'screenLocked': false,
                'mediaPlaying': false,
              };
            }
            return null;
          });

      await expectLater(
        hostChannel.presenceProbe(),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.failed),
        ),
      );

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'presenceProbe') {
              throw PlatformException(
                code: 'failed',
                message: 'probe unavailable',
              );
            }
            return null;
          });

      await expectLater(
        hostChannel.presenceProbe(),
        throwsA(
          isA<XunaHostChannelException>()
              .having((e) => e.status, 'status', XtpStatus.failed),
        ),
      );
    });
  });

  group('Tier 1/2/3 — XtpSessionClient, PresenceCoordinator & Tray Focus E2E (F10, F11)', () {
    test('T2-F11-03 & T2-F11-05: ResourceDigestBuilder caps at 256/128 and handles empty discovery cleanly', () {
      final emptyDigest = ResourceDigestBuilder(
        appScanner: AutoAppScanner(scanFileSystem: false),
        workspaceIndexer: AutoWorkspaceIndexer(scanDefaultLocations: false),
      ).build();
      expect(emptyDigest.installedApps, isEmpty);
      expect(emptyDigest.workspaces, isEmpty);
      expect(
        emptyDigest.toResourcesParams().toJson(),
        equals(<String, Object?>{
          'schemaVersion': 1,
          'installedApps': const <String>[],
          'workspaces': const <String>[],
          'capabilitiesVersion': emptyDigest.capabilitiesVersion,
        }),
      );

      final manyApps = List<DiscoveredApp>.generate(
        300,
        (i) => DiscoveredApp(
          id: 'app_${i.toString().padLeft(3, '0')}',
          name: 'App $i',
          kind: AppLaunchKind.bundle,
          target: '/Applications/App$i.app',
        ),
      );
      final manyWorkspaces = List<DiscoveredWorkspace>.generate(
        150,
        (i) => DiscoveredWorkspace(
          alias: 'ws_${i.toString().padLeft(3, '0')}',
          path: '/Users/dev/ws_$i',
          lastModified: DateTime.utc(2026, 11, 20),
        ),
      );
      final cappedDigest = ResourceDigestBuilder(
        appScanner: AutoAppScanner(seedApps: manyApps, scanFileSystem: false),
        workspaceIndexer: AutoWorkspaceIndexer(
          seedWorkspaces: manyWorkspaces,
          scanDefaultLocations: false,
        ),
      ).build();
      expect(cappedDigest.installedApps.length, equals(256));
      expect(cappedDigest.workspaces.length, equals(128));
      final frame = cappedDigest.toResourcesParams().toNotification();
      expect(XtpFrame.parse(frame.encode()), isA<XtpNotification>());
    });

    test('DSK-E2E-04 & T1-F10-04 & T1-F11-04/05: full WebSocket session emits xuna/resources, xuna/presence, and xuna/focusRequest without triggering E-Stop', () async {
      final tempDir =
          await Directory.systemTemp.createTemp('xuna_presence_e2e_');
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
      await enrollmentStore.save(
        hostId: '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10',
        alias: 'Node-Test',
        enrolledAt: DateTime.utc(2026, 11, 20),
      );

      final stopController = EmergencyStopController(logger: logger);
      final channel = FakeXunaHostChannel()
        ..presenceProbeResult = const HostPresenceProbeResult(
          idleSeconds: 8,
          screenLocked: false,
          mediaPlaying: true,
          batteryPercent: 78,
          isCharging: true,
          foregroundAppId: 'alpha_studio',
        );
      final dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: channel,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        logger: logger,
        enrollmentStore: enrollmentStore,
      );

      final fakeWs = _FakeWebSocketChannel();
      final sentFrames = <String>[];
      final outSub = fakeWs.outboundFrames.listen(sentFrames.add);

      final sessionClient = XtpSessionClient(
        wsUri: Uri.parse('wss://localhost:8443/v1/hosts/ws'),
        channel: channel,
        enrollmentStore: enrollmentStore,
        policyStore: policyStore,
        dispatcher: dispatcher,
        stopController: stopController,
        logger: logger,
        connector: (_) => fakeWs,
        enableAutoReconnect: false,
      );

      final digestBuilder = ResourceDigestBuilder(
        appScanner: AutoAppScanner(
          seedApps: const <DiscoveredApp>[
            DiscoveredApp(
              id: 'alpha_studio',
              name: 'Alpha Studio',
              kind: AppLaunchKind.bundle,
              target: '/Applications/AlphaStudio.app',
            ),
          ],
          scanFileSystem: false,
        ),
        workspaceIndexer: AutoWorkspaceIndexer(
          seedWorkspaces: <DiscoveredWorkspace>[
            DiscoveredWorkspace(
              alias: 'xuna_pet',
              path: tempDir.path,
              lastModified: DateTime.utc(2026, 11, 20),
            ),
          ],
          scanDefaultLocations: false,
        ),
      );

      final coordinator = PresenceCoordinator(
        channel: channel,
        sessionClient: sessionClient,
        resourceDigestBuilder: digestBuilder,
        subnetHashCalculator: SubnetHashCalculator(
          interfaceLister: () async => <NetworkInterface>[],
        ),
        logger: logger,
        clock: () => DateTime.utc(2026, 11, 20, 16, 0),
        deltaPollInterval: const Duration(hours: 1),
      );

      final agentController = DesktopAgentController(
        channel: channel,
        enrollmentStore: enrollmentStore,
        policyStore: policyStore,
        auditStore: AuditLogStore(auditDir: tempDir),
        stopController: stopController,
        sessionClient: sessionClient,
        logger: logger,
        presenceCoordinator: coordinator,
      );
      final trayService = DesktopTrayService(controller: agentController);

      addTearDown(() async {
        await outSub.cancel();
        await trayService.dispose();
        agentController.onClose();
        await coordinator.dispose();
        await sessionClient.dispose();
        dispatcher.dispose();
        await stopController.dispose();
        await policyStore.dispose();
        await fakeWs.inbound.close();
      });

      // T2-F11-04: Unready session guard does not throw or emit frames before xuna/ready.
      expect(
        coordinator.requestFocus(source: FocusRequestSource.hotkey),
        isFalse,
      );
      expect(sentFrames, isEmpty);

      // Drive handshake to xuna/ready.
      await sessionClient.connect();
      await _driveReconnectToReady(fakeWs, sentFrames);
      expect(sessionClient.phase, equals(HostSessionPhase.ready));

      // Verify initial xuna/resources and xuna/presence emitted and parse cleanly.
      final parsedNotifs = sentFrames
          .map(XtpFrame.parse)
          .whereType<XtpNotification>()
          .toList(growable: false);
      final methods = parsedNotifs.map((n) => n.method).toList();
      expect(methods, contains('xuna/resources'));
      expect(methods, contains('xuna/presence'));

      final resNotif =
          parsedNotifs.firstWhere((n) => n.method == 'xuna/resources');
      final resTyped = resNotif.typedParams as ResourcesParams;
      expect(resTyped.installedApps, equals(const <String>['alpha_studio']));
      expect(resTyped.workspaces, equals(const <String>['xuna_pet']));
      expect(jsonEncode(resNotif.toJson()).contains(tempDir.path), isFalse);

      // State delta emits updated xuna/presence; probe failure fails gracefully.
      channel.presenceProbeResult = const HostPresenceProbeResult(
        idleSeconds: 0,
        screenLocked: true,
        mediaPlaying: false,
      );
      expect(await coordinator.pollAndPublishPresence(), isTrue);
      channel.nextException = const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
      );
      expect(await coordinator.pollAndPublishPresence(forceEmit: true), isFalse);
      expect(sessionClient.phase, equals(HostSessionPhase.ready));

      // Tray menu & hotkey focus isolation from E-Stop.
      final menuKeys = trayService.buildTrayMenu().items!.map((i) => i.key);
      expect(
        menuKeys,
        containsAll(const <String>['focus_here', 'toggle_follow_me', 'stop']),
      );

      final beforeFocusCount = sentFrames.length;
      trayService.onTrayMenuItemClick(
        MenuItem(key: 'focus_here', label: 'Gọi XUNA sang máy này'),
      );
      trayService.onTrayMenuItemClick(
        MenuItem(key: 'toggle_follow_me', label: 'Follow Me'),
      );
      agentController.requestFocusHere(source: FocusRequestSource.hotkey);
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(stopController.isStopped, isFalse);
      expect(agentController.followMeEnabled.value, isTrue);

      final focusNotifs = sentFrames
          .skip(beforeFocusCount)
          .map(XtpFrame.parse)
          .whereType<XtpNotification>()
          .where((n) => n.method == 'xuna/focusRequest')
          .toList(growable: false);
      expect(focusNotifs, hasLength(3));
      expect(
        (focusNotifs[0].typedParams as FocusRequestParams).source,
        equals(FocusRequestSource.tray),
      );
      expect(
        (focusNotifs[1].typedParams as FocusRequestParams).followMe,
        isTrue,
      );
      expect(
        (focusNotifs[2].typedParams as FocusRequestParams).source,
        equals(FocusRequestSource.hotkey),
      );
    });

    test(
      'T1-F11-03: PresenceCoordinator coalesces rapid resource discovery deltas within debounce window',
      () async {
        final tempDir =
            await Directory.systemTemp.createTemp('xuna_res_debounce_e2e_');
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
        await enrollmentStore.save(
          hostId: '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b11',
          alias: 'Debounce-Node',
          enrolledAt: DateTime.utc(2026, 11, 20),
        );

        final stopController = EmergencyStopController(logger: logger);
        final channel = FakeXunaHostChannel()
          ..presenceProbeResult = const HostPresenceProbeResult(
            idleSeconds: 5,
            screenLocked: false,
            mediaPlaying: false,
          );
        final dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: channel,
          auditStore: AuditLogStore(auditDir: tempDir),
          stopController: stopController,
          logger: logger,
          enrollmentStore: enrollmentStore,
        );

        final fakeWs = _FakeWebSocketChannel();
        final sentFrames = <String>[];
        final outSub = fakeWs.outboundFrames.listen(sentFrames.add);

        final sessionClient = XtpSessionClient(
          wsUri: Uri.parse('wss://localhost:8443/v1/hosts/ws'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => fakeWs,
          enableAutoReconnect: false,
        );

        final mutableApps = <DiscoveredApp>[
          const DiscoveredApp(
            id: 'alpha_studio',
            name: 'Alpha Studio',
            kind: AppLaunchKind.bundle,
            target: '/Applications/AlphaStudio.app',
          ),
        ];
        final digestBuilder = ResourceDigestBuilder(
          appScanner: AutoAppScanner(
            seedApps: mutableApps,
            scanFileSystem: false,
          ),
          workspaceIndexer: AutoWorkspaceIndexer(scanDefaultLocations: false),
        );

        final coordinator = PresenceCoordinator(
          channel: channel,
          sessionClient: sessionClient,
          resourceDigestBuilder: digestBuilder,
          subnetHashCalculator: SubnetHashCalculator(
            interfaceLister: () async => <NetworkInterface>[],
          ),
          logger: logger,
          clock: () => DateTime.utc(2026, 11, 20, 16, 0),
          deltaPollInterval: const Duration(hours: 1),
          resourceDebounceDuration: const Duration(milliseconds: 120),
        );

        addTearDown(() async {
          await outSub.cancel();
          await coordinator.dispose();
          await sessionClient.dispose();
          dispatcher.dispose();
          await stopController.dispose();
          await policyStore.dispose();
          await fakeWs.inbound.close();
        });

        await sessionClient.connect();
        await _driveReconnectToReady(fakeWs, sentFrames);
        expect(sessionClient.phase, equals(HostSessionPhase.ready));

        List<ResourcesParams> sentResources() => sentFrames
            .map(XtpFrame.parse)
            .whereType<XtpNotification>()
            .where((n) => n.method == 'xuna/resources')
            .map((n) => n.typedParams as ResourcesParams)
            .toList(growable: false);

        expect(sentResources(), hasLength(1));
        expect(
          sentResources().single.installedApps,
          equals(const <String>['alpha_studio']),
        );

        // Trigger two rapid discovery deltas well inside the 120ms debounce window.
        mutableApps.add(
          const DiscoveredApp(
            id: 'delta_one',
            name: 'Delta One',
            kind: AppLaunchKind.bundle,
            target: '/Applications/DeltaOne.app',
          ),
        );
        coordinator.scheduleResourcesPublish(forceRefresh: true);
        await Future<void>.delayed(const Duration(milliseconds: 25));

        mutableApps.add(
          const DiscoveredApp(
            id: 'delta_two',
            name: 'Delta Two',
            kind: AppLaunchKind.bundle,
            target: '/Applications/DeltaTwo.app',
          ),
        );
        coordinator.scheduleResourcesPublish(forceRefresh: true);

        // Before the reset debounce timer expires, no new frame should be sent yet.
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(sentResources(), hasLength(1));

        // Once the debounce window elapses, both deltas coalesce into a single emission.
        await Future<void>.delayed(const Duration(milliseconds: 140));
        final afterCoalesce = sentResources();
        expect(afterCoalesce, hasLength(2));
        expect(
          afterCoalesce.last.installedApps,
          equals(const <String>['alpha_studio', 'delta_one', 'delta_two']),
        );

        // Re-scheduling without changes emits zero duplicate xuna/resources frames.
        coordinator.scheduleResourcesPublish(forceRefresh: true);
        await Future<void>.delayed(const Duration(milliseconds: 160));
        expect(sentResources(), hasLength(2));
      },
    );
  });
}

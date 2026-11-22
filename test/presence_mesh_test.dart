import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
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
}

class _FakeTrayManager extends Fake implements TrayManager {
  Menu? lastMenu;
  String? lastIcon;
  String? lastTitle;
  String? lastTooltip;
  final List<TrayListener> listeners = <TrayListener>[];

  @override
  void addListener(TrayListener listener) {
    listeners.add(listener);
  }

  @override
  void removeListener(TrayListener listener) {
    listeners.remove(listener);
  }

  @override
  Future<void> setIcon(
    String iconPath, {
    bool isTemplate = false,
    TrayIconPositon iconPosition = TrayIconPositon.left,
  }) async {
    lastIcon = iconPath;
  }

  @override
  Future<void> setTitle(String title) async {
    lastTitle = title;
  }

  @override
  Future<void> setContextMenu(Menu menu) async {
    lastMenu = menu;
  }

  @override
  Future<void> setToolTip(String toolTip) async {
    lastTooltip = toolTip;
  }

  @override
  Future<void> popUpContextMenu() async {}
}

class _FakeHotKeyManager extends Fake implements HotKeyManager {
  final List<({HotKey hotKey, HotKeyHandler handler})> registered =
      <({HotKey hotKey, HotKeyHandler handler})>[];
  int unregisterAllCount = 0;

  @override
  Future<void> unregisterAll() async {
    unregisterAllCount++;
    registered.clear();
  }

  @override
  Future<void> register(
    HotKey hotKey, {
    HotKeyHandler? keyDownHandler,
    HotKeyHandler? keyUpHandler,
  }) async {
    if (keyDownHandler != null) {
      registered.add((hotKey: hotKey, handler: keyDownHandler));
    }
  }
}

class _FakeWindowManager extends Fake implements WindowManager {
  @override
  Future<void> ensureInitialized() async {}

  @override
  void addListener(WindowListener listener) {}

  @override
  void removeListener(WindowListener listener) {}

  @override
  Future<void> setPreventClose(bool isPreventClose) async {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> show({bool inactive = false}) async {}

  @override
  Future<void> focus() async {}
}

void main() {
  group('SubnetHashCalculator', () {
    test('masks IPv4 /24 deterministically and skips loopback/link-local', () {
      final hashA = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('127.0.0.1'),
        InternetAddress('169.254.12.34'),
        InternetAddress('192.168.1.10'),
      ]);
      final hashB = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
        InternetAddress('192.168.1.244'),
      ]);
      final hashOtherSubnet = SubnetHashCalculator.computeFromAddresses(
        <InternetAddress>[InternetAddress('192.168.2.10')],
      );

      expect(hashA, isNotNull);
      expect(hashA, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(hashA, equals(hashB));
      expect(hashA, isNot(equals(hashOtherSubnet)));
      expect(hashA, isNot(contains('192')));
      expect(hashA, isNot(contains('168')));
    });

    test(
      'masks IPv6 /64 when no usable IPv4 exists and returns null offline',
      () {
        final v6A = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
          InternetAddress('::1'),
          InternetAddress('fe80::1'),
          InternetAddress('2001:db8:1:2::10'),
        ]);
        final v6B = SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
          InternetAddress('2001:db8:1:2:ffff::99'),
        ]);
        expect(v6A, isNotNull);
        expect(v6A, matches(RegExp(r'^[0-9a-f]{32}$')));
        expect(v6A, equals(v6B));

        final offline =
            SubnetHashCalculator.computeFromAddresses(<InternetAddress>[
              InternetAddress('127.0.0.1'),
              InternetAddress('169.254.0.5'),
              InternetAddress('::1'),
              InternetAddress('fe80::1'),
            ]);
        expect(offline, isNull);
        expect(
          SubnetHashCalculator.computeFromAddresses(const <InternetAddress>[]),
          isNull,
        );
      },
    );

    test('compute returns null when interfaceLister throws', () async {
      final calc = SubnetHashCalculator(
        interfaceLister: () async =>
            throw const SocketException('Network down'),
      );
      expect(await calc.compute(), isNull);
    });
  });

  group('ResourceDigestBuilder', () {
    test(
      'emits normalized IDs/aliases only, filters hard-denied apps, rejects paths, and enforces caps',
      () {
        final seedApps = <DiscoveredApp>[
          const DiscoveredApp(
            id: 'vscode',
            name: 'Visual Studio Code',
            kind: AppLaunchKind.bundle,
            target: '/Applications/Visual Studio Code.app',
          ),
          const DiscoveredApp(
            id: '1password',
            name: '1Password',
            kind: AppLaunchKind.bundle,
            target: '/Applications/1Password.app',
          ),
          for (var i = 0; i < 270; i++)
            DiscoveredApp(
              id: 'app_${i.toString().padLeft(3, '0')}',
              name: 'App $i',
              kind: AppLaunchKind.exe,
              target: 'C:\\Secret\\App$i.exe',
            ),
        ];

        final seedWorkspaces = <DiscoveredWorkspace>[
          DiscoveredWorkspace(
            alias: 'xuna_pet',
            path: '/Users/secret/code/xuna_pet',
            lastModified: DateTime.utc(2026, 11, 20),
            source: 'scan',
          ),
          DiscoveredWorkspace(
            alias: '../escape',
            path: '/Users/secret/escape',
            lastModified: DateTime.utc(2026, 11, 20),
            source: 'scan',
          ),
          DiscoveredWorkspace(
            alias: 'a/b',
            path: '/Users/secret/ab',
            lastModified: DateTime.utc(2026, 11, 20),
            source: 'scan',
          ),
          for (var i = 0; i < 140; i++)
            DiscoveredWorkspace(
              alias: 'Workspace_$i',
              path: '/Users/secret/ws_$i',
              lastModified: DateTime.utc(2026, 11, 20),
              source: 'scan',
            ),
        ];

        final builder = ResourceDigestBuilder(
          appScanner: AutoAppScanner(seedApps: seedApps, scanFileSystem: false),
          workspaceIndexer: AutoWorkspaceIndexer(
            seedWorkspaces: seedWorkspaces,
            scanDefaultLocations: false,
          ),
        );

        final digest1 = builder.build();
        final digest2 = builder.build();

        expect(
          digest1.capabilitiesVersion,
          equals(digest2.capabilitiesVersion),
        );
        expect(
          digest1.capabilitiesVersion,
          matches(RegExp(r'^[a-zA-Z0-9_.-]{1,32}$')),
        );
        expect(digest1.installedApps, hasLength(256));
        expect(digest1.installedApps, isNot(contains('1password')));
        expect(digest1.workspaces, hasLength(128));
        expect(digest1.workspaces, contains('xuna_pet'));
        expect(digest1.workspaces, isNot(contains('../escape')));
        expect(digest1.workspaces, isNot(contains('a/b')));

        final serialized = jsonEncode(
          digest1.toResourcesParams().toNotification().toJson(),
        );
        expect(serialized, isNot(contains('/Users/secret')));
        expect(serialized, isNot(contains('/Applications')));
        expect(serialized, isNot(contains(r'C:\Secret')));
      },
    );
  });

  group('PresenceCoordinator, XtpSessionClient & DesktopTrayService', () {
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
      tempDir = await Directory.systemTemp.createTemp('xuna_presence_test_');
      paths = AgentPaths.resolve(overrideRootDir: tempDir);
      await paths.ensureDirectories();
      logger = ContentFreeLogger();
      channel = FakeXunaHostChannel();
      policyStore = HostPolicyStore(
        policyFile: paths.policyFile,
        logger: logger,
      );
      await policyStore.writeDefaultPolicy();
      auditStore = AuditLogStore(auditDir: paths.auditDir);
      enrollmentStore = EnrollmentStateStore(
        stateFile: paths.enrollmentStateFile,
      );
      await enrollmentStore.save(
        hostId: '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10',
        alias: 'Mac-Studio',
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

    Future<void> connectAndMakeReady(
      XtpSessionClient client,
      _FakeWebSocketChannel ws,
    ) async {
      await client.connect();
      ws.inbound.add(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/challenge',
          'params': <String, Object?>{
            'purpose': 2,
            'nonce': base64.encode(List<int>.filled(32, 7)),
            'expiresIn': 60,
          },
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
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

    test(
      'gates presence/resources/focus on ready, omits desktop null battery, handles delta & fail-closed probe error',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
        );
        addTearDown(client.dispose);

        // Pre-ready: sends are strictly refused.
        expect(
          client.sendPresence(
            PresenceParams(
              idleSeconds: 0,
              screenLocked: false,
              mediaPlaying: false,
              updatedAt: DateTime.utc(2026, 11, 20, 16),
            ),
          ),
          isFalse,
        );
        expect(
          client.sendResources(
            const ResourcesParams(
              installedApps: <String>[],
              workspaces: <String>[],
            ),
          ),
          isFalse,
        );
        expect(
          client.sendFocusRequest(
            const FocusRequestParams(source: FocusRequestSource.hotkey),
          ),
          isFalse,
        );

        channel.presenceProbeResult = const HostPresenceProbeResult(
          idleSeconds: 3,
          screenLocked: false,
          mediaPlaying: false,
        );

        var now = DateTime.utc(2026, 11, 20, 16, 0, 0);
        final coordinator = PresenceCoordinator(
          channel: channel,
          sessionClient: client,
          resourceDigestBuilder: ResourceDigestBuilder(
            appScanner: AutoAppScanner(
              seedApps: const <DiscoveredApp>[
                DiscoveredApp(
                  id: 'vscode',
                  name: 'VS Code',
                  kind: AppLaunchKind.bundle,
                  target: '/Applications/Visual Studio Code.app',
                ),
              ],
              scanFileSystem: false,
            ),
            workspaceIndexer: AutoWorkspaceIndexer(
              seedWorkspaces: <DiscoveredWorkspace>[
                DiscoveredWorkspace(
                  alias: 'xuna_pet',
                  path: '/Users/thao/xuna_pet',
                  lastModified: now,
                  source: 'scan',
                ),
              ],
              scanDefaultLocations: false,
            ),
          ),
          subnetHashCalculator: SubnetHashCalculator(
            interfaceLister: () async => const <NetworkInterface>[],
          ),
          logger: logger,
          clock: () => now,
          deltaPollInterval: const Duration(hours: 1),
          periodicInterval: const Duration(seconds: 30),
        );
        addTearDown(coordinator.dispose);

        // Perform handshake -> xuna/ready.
        await client.connect();
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/challenge',
            'params': <String, Object?>{
              'purpose': 2,
              'nonce': base64.encode(List<int>.filled(32, 7)),
              'expiresIn': 60,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));
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
        await Future<void>.delayed(const Duration(milliseconds: 40));

        final notifications = outbound.whereType<XtpNotification>().toList();
        final resourcesFrames = notifications
            .where((n) => n.method == 'xuna/resources')
            .toList();
        final presenceFrames = notifications
            .where((n) => n.method == 'xuna/presence')
            .toList();

        expect(resourcesFrames, hasLength(1));
        expect(presenceFrames, hasLength(1));
        expect(
          presenceFrames.single.params.containsKey('batteryPercent'),
          isFalse,
        );
        expect(presenceFrames.single.params.containsKey('isCharging'), isFalse);
        expect(
          presenceFrames.single.params.containsKey('foregroundAppId'),
          isFalse,
        );
        expect(presenceFrames.single.params.containsKey('subnetHash'), isFalse);

        // Unchanged state inside 30s does NOT emit another presence frame.
        now = now.add(const Duration(seconds: 10));
        expect(await coordinator.pollAndPublishPresence(), isFalse);
        expect(
          outbound.whereType<XtpNotification>().where(
            (n) => n.method == 'xuna/presence',
          ),
          hasLength(1),
        );

        // State delta (mediaPlaying -> true) emits immediately!
        channel.presenceProbeResult = const HostPresenceProbeResult(
          idleSeconds: 13,
          screenLocked: false,
          mediaPlaying: true,
          foregroundAppId: 'obsidian',
        );
        now = now.add(const Duration(seconds: 3));
        expect(await coordinator.pollAndPublishPresence(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        final afterDelta = outbound
            .whereType<XtpNotification>()
            .where((n) => n.method == 'xuna/presence')
            .toList();
        expect(afterDelta, hasLength(2));
        expect(
          (afterDelta.last.typedParams as PresenceParams).mediaPlaying,
          isTrue,
        );

        // Periodic >= 30s emits even without delta.
        now = now.add(const Duration(seconds: 31));
        expect(await coordinator.pollAndPublishPresence(), isTrue);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(
          outbound.whereType<XtpNotification>().where(
            (n) => n.method == 'xuna/presence',
          ),
          hasLength(3),
        );

        // Fail-closed negative test (H1/H2/H4): native failure must NOT emit fake presence.
        channel.nextException = const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'os_error',
          message: 'probe failed',
        );
        now = now.add(const Duration(seconds: 35));
        expect(await coordinator.pollAndPublishPresence(), isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(
          outbound.whereType<XtpNotification>().where(
            (n) => n.method == 'xuna/presence',
          ),
          hasLength(3),
        );
        expect(
          logger.entries.any((e) => e.event == 'presence.probe_failed'),
          isTrue,
        );

        // Unchanged resources do not re-emit; debounced publish skips duplicate capabilitiesVersion.
        expect(await coordinator.publishResources(), isFalse);
      },
    );

    test(
      'PresenceCoordinator aborts in-flight pollAndPublishPresence without sending when disposed mid-await',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
        );
        addTearDown(client.dispose);

        await connectAndMakeReady(client, ws);

        final listerStarted = Completer<void>();
        final listerRelease = Completer<List<NetworkInterface>>();
        var blockNextLister = false;

        final coordinator = PresenceCoordinator(
          channel: channel,
          sessionClient: client,
          resourceDigestBuilder: ResourceDigestBuilder(
            appScanner: AutoAppScanner(scanFileSystem: false),
            workspaceIndexer: AutoWorkspaceIndexer(scanDefaultLocations: false),
          ),
          subnetHashCalculator: SubnetHashCalculator(
            interfaceLister: () {
              if (!blockNextLister) {
                return Future<List<NetworkInterface>>.value(
                  const <NetworkInterface>[],
                );
              }
              if (!listerStarted.isCompleted) {
                listerStarted.complete();
              }
              return listerRelease.future;
            },
          ),
          logger: logger,
          deltaPollInterval: const Duration(hours: 1),
        );
        addTearDown(coordinator.dispose);

        // Wait for initial ready emission to finish.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(
          outbound.whereType<XtpNotification>().where(
            (n) => n.method == 'xuna/presence',
          ),
          hasLength(1),
        );

        // Start a second poll suspended inside subnetHashCalculator.compute(), then dispose mid-await.
        blockNextLister = true;
        final inFlight = coordinator.pollAndPublishPresence(forceEmit: true);
        await listerStarted.future;
        await coordinator.dispose();
        listerRelease.complete(const <NetworkInterface>[]);

        expect(await inFlight, isFalse);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(
          outbound.whereType<XtpNotification>().where(
            (n) => n.method == 'xuna/presence',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'DesktopTrayService registers E-Stop (X) + Focus (F), renders menu items, and sends xuna/focusRequest',
      () async {
        final ws = _FakeWebSocketChannel();
        final outbound = <XtpFrame>[];
        final sub = ws.outboundFrames.listen((raw) {
          outbound.add(XtpFrame.parse(raw));
        });
        addTearDown(sub.cancel);

        final client = XtpSessionClient(
          wsUri: Uri.parse('wss://example.com/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          connector: (_) => ws,
          enableAutoReconnect: false,
        );
        addTearDown(client.dispose);

        final coordinator = PresenceCoordinator(
          channel: channel,
          sessionClient: client,
          resourceDigestBuilder: ResourceDigestBuilder(
            appScanner: AutoAppScanner(scanFileSystem: false),
            workspaceIndexer: AutoWorkspaceIndexer(scanDefaultLocations: false),
          ),
          subnetHashCalculator: SubnetHashCalculator(
            interfaceLister: () async => const <NetworkInterface>[],
          ),
          logger: logger,
          deltaPollInterval: const Duration(hours: 1),
        );
        addTearDown(coordinator.dispose);

        final controller = DesktopAgentController(
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          auditStore: auditStore,
          stopController: stopController,
          sessionClient: client,
          presenceCoordinator: coordinator,
          logger: logger,
        );
        controller.onInit();
        addTearDown(controller.onClose);

        final fakeTray = _FakeTrayManager();
        final fakeHotKeys = _FakeHotKeyManager();
        final fakeWindow = _FakeWindowManager();

        final trayService = DesktopTrayService(
          controller: controller,
          trayManagerOverride: fakeTray,
          hotKeyManagerOverride: fakeHotKeys,
          windowManagerOverride: fakeWindow,
          isMacOsOverride: true,
        );
        await trayService.initialize();
        addTearDown(trayService.dispose);

        // Verify hotkeys: Ctrl+Alt+Shift+X (E-Stop) & Cmd+Alt+Shift+F (macOS Focus).
        expect(fakeHotKeys.registered, hasLength(2));
        final stopReg = fakeHotKeys.registered.firstWhere(
          (r) => r.hotKey.key == PhysicalKeyboardKey.keyX,
        );
        expect(
          stopReg.hotKey.modifiers,
          unorderedEquals(<HotKeyModifier>[
            HotKeyModifier.control,
            HotKeyModifier.alt,
            HotKeyModifier.shift,
          ]),
        );
        final focusReg = fakeHotKeys.registered.firstWhere(
          (r) => r.hotKey.key == PhysicalKeyboardKey.keyF,
        );
        expect(
          focusReg.hotKey.modifiers,
          unorderedEquals(<HotKeyModifier>[
            HotKeyModifier.meta,
            HotKeyModifier.alt,
            HotKeyModifier.shift,
          ]),
        );

        // Also verify Windows/Linux uses Ctrl+Alt+Shift+F.
        final winHotKeys = _FakeHotKeyManager();
        final winTray = DesktopTrayService(
          controller: controller,
          trayManagerOverride: _FakeTrayManager(),
          hotKeyManagerOverride: winHotKeys,
          windowManagerOverride: _FakeWindowManager(),
          isMacOsOverride: false,
        );
        await winTray.initialize();
        addTearDown(winTray.dispose);
        final winFocus = winHotKeys.registered.firstWhere(
          (r) => r.hotKey.key == PhysicalKeyboardKey.keyF,
        );
        expect(
          winFocus.hotKey.modifiers,
          unorderedEquals(<HotKeyModifier>[
            HotKeyModifier.control,
            HotKeyModifier.alt,
            HotKeyModifier.shift,
          ]),
        );

        // Verify menu items.
        final items = fakeTray.lastMenu!.items!;
        final focusItem = items.firstWhere((i) => i.key == 'focus_here');
        expect(focusItem.label, equals('Gọi XUNA sang máy này'));
        final followItem = items.firstWhere((i) => i.key == 'toggle_follow_me');
        expect(followItem.label, equals('Follow Me'));
        expect(followItem.checked, isFalse);

        // Pre-ready: toggling Follow Me must NOT fake followMeEnabled = true (H1).
        trayService.onTrayMenuItemClick(followItem);
        expect(controller.followMeEnabled.value, isFalse);

        // Connect and become ready.
        await connectAndMakeReady(client, ws);

        // Trigger focus hotkey -> xuna/focusRequest {source: hotkey}.
        focusReg.handler(focusReg.hotKey);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Click 'focus_here' -> xuna/focusRequest {source: tray}.
        trayService.onTrayMenuItemClick(focusItem);
        await Future<void>.delayed(const Duration(milliseconds: 10));

        // Click 'toggle_follow_me' -> xuna/focusRequest {source: tray, followMe: true}.
        trayService.onTrayMenuItemClick(followItem);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(controller.followMeEnabled.value, isTrue);
        expect(
          fakeTray.lastMenu!.items!
              .firstWhere((i) => i.key == 'toggle_follow_me')
              .checked,
          isTrue,
        );

        final focusRequests = outbound
            .whereType<XtpNotification>()
            .where((n) => n.method == 'xuna/focusRequest')
            .toList();
        expect(focusRequests, hasLength(3));
        expect(
          (focusRequests[0].typedParams as FocusRequestParams).source,
          equals(FocusRequestSource.hotkey),
        );
        expect(
          (focusRequests[1].typedParams as FocusRequestParams).source,
          equals(FocusRequestSource.tray),
        );
        expect(
          (focusRequests[1].typedParams as FocusRequestParams).followMe,
          isNull,
        );
        expect(
          (focusRequests[2].typedParams as FocusRequestParams).source,
          equals(FocusRequestSource.tray),
        );
        expect(
          (focusRequests[2].typedParams as FocusRequestParams).followMe,
          isTrue,
        );

        // Gap 6: disconnecting resets followMeEnabled so tray checkmark cannot drift.
        await ws.inbound.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(controller.followMeEnabled.value, isFalse);
      },
    );

    test(
      'Tier 5: SubnetHashCalculator times out cleanly and ResourceDigestBuilder sorts workspaces canonically',
      () async {
        // Gap 4a: stalled interface lister times out and returns null.
        final stalledCalc = SubnetHashCalculator(
          timeout: const Duration(milliseconds: 40),
          interfaceLister: () => Completer<List<NetworkInterface>>().future,
        );
        expect(await stalledCalc.compute(), isNull);

        // Gap 4b: workspaces are canonically sorted before capping and hashing capabilitiesVersion.
        final now = DateTime.utc(2026, 11, 21, 1, 0);
        final builderA = ResourceDigestBuilder(
          appScanner: AutoAppScanner(scanFileSystem: false),
          workspaceIndexer: AutoWorkspaceIndexer(
            scanDefaultLocations: false,
            seedWorkspaces: <DiscoveredWorkspace>[
              DiscoveredWorkspace(
                alias: 'zeta_repo',
                path: '/tmp/zeta',
                lastModified: now,
              ),
              DiscoveredWorkspace(
                alias: 'alpha_repo',
                path: '/tmp/alpha',
                lastModified: now,
              ),
            ],
          ),
        );
        final builderB = ResourceDigestBuilder(
          appScanner: AutoAppScanner(scanFileSystem: false),
          workspaceIndexer: AutoWorkspaceIndexer(
            scanDefaultLocations: false,
            seedWorkspaces: <DiscoveredWorkspace>[
              DiscoveredWorkspace(
                alias: 'alpha_repo',
                path: '/tmp/alpha',
                lastModified: now,
              ),
              DiscoveredWorkspace(
                alias: 'zeta_repo',
                path: '/tmp/zeta',
                lastModified: now,
              ),
            ],
          ),
        );
        final dA = builderA.build();
        final dB = builderB.build();
        expect(dA.workspaces, equals(<String>['alpha_repo', 'zeta_repo']));
        expect(dB.workspaces, equals(<String>['alpha_repo', 'zeta_repo']));
        expect(dA.capabilitiesVersion, equals(dB.capabilitiesVersion));
      },
    );
  });
}

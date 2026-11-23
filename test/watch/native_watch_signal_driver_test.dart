import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/native_watch_signal_driver.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _VirtualTimer implements WatchCancellableTimer {
  _VirtualTimer(this.fireAt, this.onFire);

  final DateTime fireAt;
  final void Function() onFire;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() {
    cancelled = true;
  }
}

class _VirtualClock {
  _VirtualClock(DateTime start) : _now = start.toUtc();
  DateTime _now;
  final List<_VirtualTimer> timers = <_VirtualTimer>[];

  DateTime now() => _now;

  WatchCancellableTimer createTimer(Duration delay, void Function() onFire) {
    final timer = _VirtualTimer(_now.add(delay), onFire);
    timers.add(timer);
    return timer;
  }

  void advance(Duration delta) {
    final target = _now.add(delta);
    while (true) {
      _VirtualTimer? next;
      for (final t in timers) {
        if (!t.isActive || t.fireAt.isAfter(target)) continue;
        if (next == null || t.fireAt.isBefore(next.fireAt)) {
          next = t;
        }
      }
      if (next == null) break;
      _now = next.fireAt;
      next.fired = true;
      next.onFire();
    }
    _now = target;
  }
}

void main() {
  const jobId = 'a2222222-2222-4222-8222-222222222222';
  String watchUuid(int n) =>
      'f1111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';

  late Directory tmpHome;
  late Directory outsideDir;
  late ContentFreeLogger logger;
  late EmergencyStopController stopController;
  late FakeXunaHostChannel channel;

  setUp(() async {
    tmpHome = await Directory.systemTemp.createTemp('xuna_native_watch_home_');
    outsideDir = await Directory.systemTemp.createTemp(
      'xuna_native_watch_out_',
    );
    logger = ContentFreeLogger();
    stopController = EmergencyStopController(logger: logger);
    channel = FakeXunaHostChannel();
  });

  tearDown(() async {
    await stopController.dispose();
    if (await tmpHome.exists()) {
      await tmpHome.delete(recursive: true);
    }
    if (await outsideDir.exists()) {
      await outsideDir.delete(recursive: true);
    }
  });

  group('NativeWatchSignalDriver', () {
    test(
      'FakeXunaHostChannel watchStart/watchPoll fail closed by default',
      () async {
        await expectLater(
          channel.watchStart(watchId: watchUuid(1), signal: 'process_idle'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'watch_unsupported',
            ),
          ),
        );
        await expectLater(
          channel.watchPoll(watchId: watchUuid(1), signal: 'process_idle'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'watch_unsupported',
            ),
          ),
        );
      },
    );

    test(
      'process_idle active->idle transition emits changed pulse, propagates digest, and settles without resetting quiescence',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final indexer = AutoWorkspaceIndexer(
          customScanRoots: <String>[tmpHome.path],
          scanDefaultLocations: false,
        );
        final driver = NativeWatchSignalDriver(
          channel: channel,
          workspaceIndexer: indexer,
          logger: logger,
          pollInterval: const Duration(milliseconds: 20),
          homeDirectoryResolver: () => tmpHome.path,
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        final wId = watchUuid(1);
        channel.onWatchStart =
            ({
              required watchId,
              required signal,
              required releaseFocus,
              pid,
              windowId,
              appId,
              workspacePath,
            }) async {
              expect(releaseFocus, isTrue);
              return HostWatchStartResult(
                watchId: watchId,
                signal: signal,
                eventDriven: false,
                fallbackUsed: false,
              );
            };
        channel.scriptedWatchPolls['$wId:process_idle'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wId,
                signal: 'process_idle',
                state: 'active',
                changeCount: 1,
                eventDriven: false,
                fallbackUsed: false,
              ),
              HostWatchPollResult(
                watchId: wId,
                signal: 'process_idle',
                state: 'idle',
                changeCount: 1,
                eventDriven: false,
                fallbackUsed: false,
              ),
              HostWatchPollResult(
                watchId: wId,
                signal: 'process_idle',
                state: 'idle',
                changeCount: 1,
                eventDriven: false,
                fallbackUsed: false,
              ),
            ]);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final outcome = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: wId,
            jobId: jobId,
            mode: WatchMode.processIdle,
            target: const WatchTarget(pid: 4242),
            quiescenceSeconds: 2,
            minWaitSeconds: 0,
            maxWaitSeconds: 20,
            requireInitialChange: true,
            releaseFocus: true,
          ),
        );
        expect(outcome.accepted, isTrue);
        expect(outcome.eventDriven, isFalse);

        // Allow poll 1 (active) + poll 2 (idle -> changed pulse) + poll 3 (idle).
        await Future<void>.delayed(const Duration(milliseconds: 90));
        clock.advance(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(events.single.changeCount, greaterThanOrEqualTo(1));
        expect(
          channel.recordedWatchStops.any(
            (s) => s['watchId'] == wId && s['signal'] == 'process_idle',
          ),
          isTrue,
        );
      },
    );

    test(
      'composite watch shares watchId across ui_quiescence, process_idle, fs_quiescence and keeps workspacePath content-free',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final repoDir = Directory('${tmpHome.path}/my_repo');
        await repoDir.create(recursive: true);
        await Directory('${repoDir.path}/.git').create();

        final indexer = AutoWorkspaceIndexer(
          customScanRoots: <String>[tmpHome.path],
          scanDefaultLocations: false,
        );
        final driver = NativeWatchSignalDriver(
          channel: channel,
          workspaceIndexer: indexer,
          logger: logger,
          pollInterval: const Duration(milliseconds: 20),
          homeDirectoryResolver: () => tmpHome.path,
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        final wId = watchUuid(2);
        channel.onWatchStart =
            ({
              required watchId,
              required signal,
              required releaseFocus,
              pid,
              windowId,
              appId,
              workspacePath,
            }) async => HostWatchStartResult(
              watchId: watchId,
              signal: signal,
              eventDriven: signal != 'process_idle',
              fallbackUsed: false,
            );

        channel.scriptedWatchPolls['$wId:ui_quiescence'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wId,
                signal: 'ui_quiescence',
                state: 'idle',
                changeCount: 1,
                digestChangeCount: 1,
                digestChanged: true,
              ),
              HostWatchPollResult(
                watchId: wId,
                signal: 'ui_quiescence',
                state: 'idle',
                changeCount: 1,
                digestChangeCount: 1,
                digestChanged: false,
              ),
            ]);
        channel.scriptedWatchPolls['$wId:process_idle'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wId,
                signal: 'process_idle',
                state: 'active',
                changeCount: 1,
              ),
              HostWatchPollResult(
                watchId: wId,
                signal: 'process_idle',
                state: 'idle',
                changeCount: 1,
              ),
            ]);
        channel.scriptedWatchPolls['$wId:fs_quiescence'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wId,
                signal: 'fs_quiescence',
                state: 'idle',
                changeCount: 1,
              ),
            ]);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        final outcome = await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: wId,
            jobId: jobId,
            mode: WatchMode.composite,
            signals: const <WatchSignal>[
              WatchSignal.uiQuiescence,
              WatchSignal.processIdle,
              WatchSignal.fsQuiescence,
            ],
            target: const WatchTarget(pid: 777, workspaceAlias: 'my_repo'),
            quiescenceSeconds: 2,
            minWaitSeconds: 0,
            maxWaitSeconds: 20,
            requireInitialChange: true,
            releaseFocus: true,
          ),
        );
        expect(outcome.accepted, isTrue);
        expect(channel.recordedWatchStarts, hasLength(3));
        expect(
          channel.recordedWatchStarts.every((e) => e['watchId'] == wId),
          isTrue,
        );
        final fsStart = channel.recordedWatchStarts.firstWhere(
          (e) => e['signal'] == 'fs_quiescence',
        );
        expect(
          fsStart['workspacePath'],
          equals(repoDir.resolveSymbolicLinksSync()),
        );

        await Future<void>.delayed(const Duration(milliseconds: 80));
        clock.advance(const Duration(seconds: 2));
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(events, hasLength(1));
        expect(events.single.kind, equals(WatchEventKind.settled));
        expect(events.single.digestChanged, isTrue);

        // Consent U5: raw path never appears in logger entries or WatchEventParams.
        for (final entry in logger.entries) {
          final fieldsStr = entry.fields.values.join(' ');
          expect(fieldsStr, isNot(contains(tmpHome.path)));
          expect(fieldsStr, isNot(contains('my_repo')));
        }
      },
    );

    test(
      'fs_quiescence enforces strict home containment, exact alias match, and blocks sensitive/escaping paths',
      () async {
        final validRepo = Directory('${tmpHome.path}/valid_app');
        await validRepo.create(recursive: true);
        await Directory('${validRepo.path}/.git').create();

        final dupA = Directory('${tmpHome.path}/group_a/shared_name');
        final dupB = Directory('${tmpHome.path}/group_b/shared_name');
        await dupA.create(recursive: true);
        await dupB.create(recursive: true);
        await Directory('${dupA.path}/.git').create();
        await Directory('${dupB.path}/.git').create();

        final sshDir = Directory('${tmpHome.path}/.ssh');
        await sshDir.create(recursive: true);
        final envDir = Directory('${tmpHome.path}/proj/.env.local');
        await envDir.create(recursive: true);

        final outsideRepo = Directory('${outsideDir.path}/outside_repo');
        await outsideRepo.create(recursive: true);
        final escapingLink = Link('${tmpHome.path}/escaped_repo');
        await escapingLink.create(outsideRepo.path);

        final indexer = AutoWorkspaceIndexer(
          seedWorkspaces: <DiscoveredWorkspace>[
            DiscoveredWorkspace(
              alias: 'valid_app',
              path: validRepo.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
            DiscoveredWorkspace(
              alias: 'shared_name',
              path: dupA.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
            DiscoveredWorkspace(
              alias: 'shared_name',
              path: dupB.path,
              lastModified: DateTime.utc(2026, 11, 22, 1),
            ),
            DiscoveredWorkspace(
              alias: 'outside_repo',
              path: outsideRepo.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
            DiscoveredWorkspace(
              alias: 'escaped_repo',
              path: escapingLink.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
            DiscoveredWorkspace(
              alias: 'secret_ssh',
              path: sshDir.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
            DiscoveredWorkspace(
              alias: 'env_dir',
              path: envDir.path,
              lastModified: DateTime.utc(2026, 11, 22),
            ),
          ],
          scanDefaultLocations: false,
        );

        final driver = NativeWatchSignalDriver(
          channel: channel,
          workspaceIndexer: indexer,
          logger: logger,
          homeDirectoryResolver: () => tmpHome.path,
        );

        expect(
          driver.resolveSafeWatchWorkspacePath('valid_app'),
          equals(validRepo.resolveSymbolicLinksSync()),
        );

        // Rejects recent / latest / prefix / ambiguous / missing -> workspace_not_found.
        for (final badAlias in const <String>[
          'recent',
          'latest',
          'valid_a',
          'shared_name',
          'does_not_exist',
        ]) {
          expect(
            () => driver.resolveSafeWatchWorkspacePath(badAlias),
            throwsA(
              isA<WatchDriverException>().having(
                (e) => e.errorCode,
                'errorCode',
                'workspace_not_found',
              ),
            ),
            reason: 'Expected workspace_not_found for "$badAlias"',
          );
        }

        // Rejects dot/credential aliases, outside-$HOME, and escaping symlinks -> policy_blocked.
        for (final blockedAlias in const <String>[
          '.ssh',
          '.aws',
          '.env',
          'Library',
          'outside_repo',
          'escaped_repo',
          'secret_ssh',
          'env_dir',
        ]) {
          expect(
            () => driver.resolveSafeWatchWorkspacePath(blockedAlias),
            throwsA(
              isA<WatchDriverException>().having(
                (e) => e.errorCode,
                'errorCode',
                'policy_blocked',
              ),
            ),
            reason: 'Expected policy_blocked for "$blockedAlias"',
          );
        }
      },
    );

    test(
      'normalizes channel error codes (needs_permission, permission_missing, policy_blocked, MissingPluginException)',
      () async {
        final indexer = AutoWorkspaceIndexer(scanDefaultLocations: false);
        final driver = NativeWatchSignalDriver(
          channel: channel,
          workspaceIndexer: indexer,
          logger: logger,
          homeDirectoryResolver: () => tmpHome.path,
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
        );
        addTearDown(sentinel.dispose);

        Future<WatchRegisterOutcome> tryUi(String appId) =>
            sentinel.registerWatch(
              WatchRegisterParams(
                watchId: watchUuid(10),
                jobId: jobId,
                mode: WatchMode.uiQuiescence,
                target: WatchTarget(appId: appId),
                quiescenceSeconds: 4,
                minWaitSeconds: 0,
                maxWaitSeconds: 30,
                requireInitialChange: false,
                releaseFocus: true,
              ),
            );

        // Legacy permission_missing normalized to needs_permission.
        channel.nextException = const XunaHostChannelException(
          status: XtpStatus.needsPermission,
          errorCode: 'permission_missing',
        );
        var res = await tryUi('editor_a');
        expect(res.accepted, isFalse);
        expect(res.errorCode, equals(WatchRejectErrorCode.needsPermission));

        // MissingPluginException normalized to watch_unsupported.
        channel.onWatchStart =
            ({
              required watchId,
              required signal,
              required releaseFocus,
              pid,
              windowId,
              appId,
              workspacePath,
            }) async => throw MissingPluginException('no native plugin');
        res = await tryUi('editor_a');
        expect(res.accepted, isFalse);
        expect(res.errorCode, equals(WatchRejectErrorCode.watchUnsupported));

        // Explicit target_not_found preserved.
        channel.onWatchStart =
            ({
              required watchId,
              required signal,
              required releaseFocus,
              pid,
              windowId,
              appId,
              workspacePath,
            }) async => throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'target_not_found',
            );
        res = await tryUi('editor_a');
        expect(res.accepted, isFalse);
        expect(res.errorCode, equals(WatchRejectErrorCode.targetNotFound));
      },
    );

    test(
      'handles mid-watch lost, mid-watch error, and E-Stop watchStop cancellation',
      () async {
        final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
        final indexer = AutoWorkspaceIndexer(scanDefaultLocations: false);
        final driver = NativeWatchSignalDriver(
          channel: channel,
          workspaceIndexer: indexer,
          logger: logger,
          pollInterval: const Duration(milliseconds: 20),
          homeDirectoryResolver: () => tmpHome.path,
        );
        final sentinel = LocalWatchSentinel(
          stopController: stopController,
          logger: logger,
          drivers: <WatchSignalDriver>[driver],
          now: clock.now,
          timerFactory: clock.createTimer,
        );
        addTearDown(sentinel.dispose);

        channel.onWatchStart =
            ({
              required watchId,
              required signal,
              required releaseFocus,
              pid,
              windowId,
              appId,
              workspacePath,
            }) async => HostWatchStartResult(watchId: watchId, signal: signal);

        final events = <WatchEventParams>[];
        final sub = sentinel.events.listen(events.add);
        addTearDown(sub.cancel);

        // 1. Mid-watch target_lost.
        final wLost = watchUuid(21);
        channel.scriptedWatchPolls['$wLost:process_idle'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wLost,
                signal: 'process_idle',
                state: 'lost',
              ),
            ]);
        await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: wLost,
            jobId: jobId,
            mode: WatchMode.processIdle,
            target: const WatchTarget(pid: 123),
            quiescenceSeconds: 4,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(events.single.kind, equals(WatchEventKind.targetLost));

        // 2. Mid-watch error.
        final wErr = watchUuid(22);
        channel.scriptedWatchPolls['$wErr:ui_quiescence'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wErr,
                signal: 'ui_quiescence',
                state: 'error',
                errorCode: 'needs_permission',
              ),
            ]);
        await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: wErr,
            jobId: jobId,
            mode: WatchMode.uiQuiescence,
            target: const WatchTarget(pid: 124),
            quiescenceSeconds: 4,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(events, hasLength(2));
        expect(events[1].kind, equals(WatchEventKind.error));
        expect(events[1].errorCode, equals('needs_permission'));

        // 3. E-Stop cancels active watch and invokes watchStop.
        final wStop = watchUuid(23);
        channel.scriptedWatchPolls['$wStop:process_idle'] =
            Queue<HostWatchPollResult>.from(<HostWatchPollResult>[
              HostWatchPollResult(
                watchId: wStop,
                signal: 'process_idle',
                state: 'active',
              ),
            ]);
        await sentinel.registerWatch(
          WatchRegisterParams(
            watchId: wStop,
            jobId: jobId,
            mode: WatchMode.processIdle,
            target: const WatchTarget(pid: 125),
            quiescenceSeconds: 4,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(sentinel.activeWatchCount, equals(1));
        stopController.triggerStop(StopReason.ownerHost);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(sentinel.activeWatchCount, equals(0));
        expect(
          channel.recordedWatchStops.any(
            (s) => s['watchId'] == wStop && s['signal'] == 'process_idle',
          ),
          isTrue,
        );
      },
    );

    test(
      'DesktopAgentController default DI keeps protocol_async fail-closed watch_unsupported',
      () async {
        final paths = AgentPaths.resolve(overrideRootDir: tmpHome);
        await paths.ensureDirectories();
        final policyStore = HostPolicyStore(
          policyFile: paths.policyFile,
          logger: logger,
        );
        final auditStore = AuditLogStore(auditDir: paths.auditDir);
        final enrollmentStore = EnrollmentStateStore(
          stateFile: paths.enrollmentStateFile,
        );
        final dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: channel,
          auditStore: auditStore,
          stopController: stopController,
          logger: logger,
          enrollmentStore: enrollmentStore,
        );
        final sessionClient = XtpSessionClient(
          wsUri: Uri.parse('ws://127.0.0.1:8000/v1/hosts/connect'),
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
        );
        final controller = DesktopAgentController(
          channel: channel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          auditStore: auditStore,
          stopController: stopController,
          sessionClient: sessionClient,
          logger: logger,
        );
        addTearDown(() {
          controller.onClose();
          dispatcher.dispose();
          unawaited(policyStore.dispose());
        });

        final protoRes = await controller.watchSentinel.registerWatch(
          WatchRegisterParams(
            watchId: watchUuid(30),
            jobId: jobId,
            mode: WatchMode.protocolAsync,
            target: const WatchTarget(
              mcpServerId: 'srv-1',
              protocolTaskId: 'task-1',
            ),
            quiescenceSeconds: 4,
            minWaitSeconds: 0,
            maxWaitSeconds: 30,
            requireInitialChange: false,
            releaseFocus: true,
          ),
        );
        expect(protoRes.accepted, isFalse);
        expect(
          protoRes.errorCode,
          equals(WatchRejectErrorCode.watchUnsupported),
        );
      },
    );

    test(
      'MethodChannelXunaHostChannel watchStart/watchPoll/watchStop round-trips and fails closed on malformed payloads',
      () async {
        TestWidgetsFlutterBinding.ensureInitialized();
        const methodChannel = MethodChannel('xuna/host_watch_test');
        final calls = <MethodCall>[];
        final hostChannel = MethodChannelXunaHostChannel(
          channel: methodChannel,
          callTimeout: const Duration(milliseconds: 300),
        );
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(methodChannel, null);
        });

        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (call) async {
              calls.add(call);
              switch (call.method) {
                case 'watchStart':
                  return <String, Object?>{
                    'accepted': true,
                    'watchId': 'w-mc-1',
                    'signal': 'ui_quiescence',
                    'eventDriven': true,
                    'fallbackUsed': false,
                  };
                case 'watchPoll':
                  return <String, Object?>{
                    'watchId': 'w-mc-1',
                    'signal': 'ui_quiescence',
                    'state': 'active',
                    'changeCount': 3,
                    'digestChangeCount': 1,
                    'digestChanged': true,
                    'eventDriven': true,
                    'fallbackUsed': false,
                  };
                case 'watchStop':
                  return <String, Object?>{
                    'stopped': true,
                    'cancelledCount': 1,
                  };
                default:
                  return null;
              }
            });

        final startRes = await hostChannel.watchStart(
          watchId: 'w-mc-1',
          signal: 'ui_quiescence',
          releaseFocus: true,
          pid: 100,
        );
        expect(startRes.accepted, isTrue);
        expect(startRes.eventDriven, isTrue);
        expect(startRes.fallbackUsed, isFalse);

        final pollRes = await hostChannel.watchPoll(
          watchId: 'w-mc-1',
          signal: 'ui_quiescence',
        );
        expect(pollRes.state, equals('active'));
        expect(pollRes.changeCount, equals(3));
        expect(pollRes.digestChangeCount, equals(1));
        expect(pollRes.digestChanged, isTrue);

        final stopRes = await hostChannel.watchStop(
          watchId: 'w-mc-1',
          signal: 'ui_quiescence',
        );
        expect(stopRes.stopped, isTrue);
        expect(stopRes.cancelledCount, equals(1));
        expect(calls.map((c) => c.method), <String>[
          'watchStart',
          'watchPoll',
          'watchStop',
        ]);

        // Fail closed on PlatformException with details['errorCode'] and malformed watchPoll.
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(methodChannel, (call) async {
              if (call.method == 'watchStart') {
                throw PlatformException(
                  code: 'needs_permission',
                  message: 'TCC required',
                  details: <String, Object?>{'errorCode': 'needs_permission'},
                );
              }
              return <String, Object?>{'state': 'invented_state'};
            });

        await expectLater(
          hostChannel.watchStart(watchId: 'w-mc-2', signal: 'ui_quiescence'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.needsPermission)
                .having((e) => e.errorCode, 'errorCode', 'needs_permission'),
          ),
        );
        await expectLater(
          hostChannel.watchPoll(watchId: 'w-mc-2', signal: 'ui_quiescence'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'os_error',
            ),
          ),
        );
      },
    );
  });
}

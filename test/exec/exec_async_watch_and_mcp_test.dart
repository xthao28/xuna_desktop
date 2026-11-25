import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/discovery/mcp_tools_introspector.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/watch/exec_async_watch_driver.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

Future<ExecTaskSnapshot> _detach(ExecProcessRegistry r) => r.run(
  command: 'npm run build',
  cwd: Directory.systemTemp.path,
  environment: const <String, String>{},
  pty: false,
  timeout: const Duration(seconds: 30),
  yieldAfter: Duration.zero,
  risk: RiskTier.r2,
);

void main() {
  group('ExecAsyncWatchDriver (exec_async)', () {
    late EmergencyStopController stop;
    late FakeExecLauncher launcher;
    late ExecProcessRegistry registry;
    late ExecAsyncWatchDriver driver;

    setUp(() {
      stop = EmergencyStopController(logger: ContentFreeLogger());
      launcher = FakeExecLauncher();
      registry = ExecProcessRegistry(
        stopController: stop,
        launcher: launcher,
        pollInterval: const Duration(milliseconds: 5),
        killGrace: const Duration(milliseconds: 30),
      );
      driver = ExecAsyncWatchDriver(registry: registry);
    });

    Future<List<WatchSignalUpdate>> watch(String? taskId) async {
      final updates = <WatchSignalUpdate>[];
      await driver.startSignal(
        watchId: 'f1111111-1111-4111-8111-111111111117',
        signal: WatchSignal.execAsync,
        target: WatchTarget(execTaskId: taskId),
        releaseFocus: true,
        onUpdate: updates.add,
      );
      return updates;
    }

    test('detached task stays active, then changed+settled on exit', () async {
      final snap = await _detach(registry);
      final updates = await watch(snap.taskId);
      expect(updates.map((u) => u.state), <WatchSignalState>[
        WatchSignalState.active,
      ]);
      launcher.started.single.exit(1);
      await registry.events.first;
      await Future<void>.delayed(Duration.zero);
      expect(updates.map((u) => u.state), <WatchSignalState>[
        WatchSignalState.active,
        WatchSignalState.changed,
        WatchSignalState.settled,
      ]);
      expect(updates.every((u) => u.signal == WatchSignal.execAsync), isTrue);
    });

    test(
      'E-Stop turns the watch into an error (exec_cancelled), never settled',
      () async {
        final snap = await _detach(registry);
        final updates = await watch(snap.taskId);
        stop.triggerStop(StopReason.ownerHost);
        await registry.killAll();
        await Future<void>.delayed(Duration.zero);
        expect(updates.last.state, WatchSignalState.error);
        expect(updates.last.errorCode, 'exec_cancelled');
        expect(
          updates.any((u) => u.state == WatchSignalState.settled),
          isFalse,
        );
      },
    );

    test(
      'an already finished task reports its terminal state at once',
      () async {
        launcher.onStart = (h) => h.exit(0);
        final snap = await registry.run(
          command: 'true',
          cwd: '/',
          environment: const {},
          pty: false,
          timeout: const Duration(seconds: 5),
          yieldAfter: const Duration(seconds: 2),
          risk: RiskTier.r2,
        );
        final updates = await watch(snap.taskId);
        expect(updates.last.state, WatchSignalState.settled);
      },
    );

    test(
      'unknown or missing execTaskId fails closed with target_not_found',
      () async {
        for (final id in <String?>['exec_missing', null]) {
          await expectLater(
            watch(id),
            throwsA(
              isA<WatchDriverException>().having(
                (e) => e.errorCode,
                'errorCode',
                'target_not_found',
              ),
            ),
          );
        }
      },
    );
  });

  group('McpToolsIntrospector (tools/list)', () {
    const server = DiscoveredMcpServer(
      id: 'build_mcp',
      transport: 'stdio',
      source: 'host_policy',
      command: 'uvx',
    );

    test('summarizes name, redacted description and argument lists', () async {
      final intro = McpToolsIntrospector(
        lister: (_) async => <Map<String, Object?>>[
          <String, Object?>{
            'name': 'run_tests',
            'description':
                'Runs tests. Example key sk-abcdefghijklmnopqrstuv ${'x' * 300}',
            'inputSchema': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{'path': {}, 'filter': {}},
              'required': <String>['path'],
            },
          },
          <String, Object?>{'description': 'no name -> dropped'},
        ],
      );
      final out = await intro.describe(server);
      final tools = out['tools']! as List;
      expect(tools, hasLength(1));
      final tool = tools.single as Map<String, Object?>;
      expect(tool['name'], 'run_tests');
      expect(tool['requiredArgs'], <String>['path']);
      expect(tool['optionalArgs'], <String>['filter']);
      expect((tool['description']! as String).length, lessThanOrEqualTo(160));
      expect(tool['description'], isNot(contains('sk-abcdefghijklmnopqrstuv')));
    });

    test('timeout and spawn failures are reported per server (H4)', () async {
      final slow = McpToolsIntrospector(
        lister: (_) => Completer<List<Map<String, Object?>>>().future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(await slow.describe(server), <String, Object?>{
        'toolsError': 'timeout',
      });
      final broken = McpToolsIntrospector(
        lister: (_) async => throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        ),
      );
      expect(await broken.describe(server), <String, Object?>{
        'toolsError': 'spawn_failed',
      });
      final acp = McpToolsIntrospector(lister: (_) async => const []);
      expect(
        await acp.describe(
          const DiscoveredMcpServer(
            id: 'agent',
            transport: 'acp_stdio',
            source: 'host_policy',
          ),
        ),
        <String, Object?>{'toolsError': 'unsupported_transport'},
      );
    });

    test('results are cached for the TTL and re-queried after it', () async {
      var calls = 0;
      var now = DateTime.utc(2026, 11, 25);
      final intro = McpToolsIntrospector(
        lister: (_) async {
          calls++;
          return const <Map<String, Object?>>[];
        },
        clock: () => now,
      );
      await intro.describe(server);
      await intro.describe(server);
      expect(calls, 1);
      now = now.add(const Duration(seconds: 61));
      await intro.describe(server);
      expect(calls, 2);
    });

    test('the response budget drops tools and marks toolsTruncated', () async {
      final intro = McpToolsIntrospector(
        lister: (_) async => <Map<String, Object?>>[
          for (var i = 0; i < 40; i++)
            <String, Object?>{'name': 'tool_$i', 'description': 'd' * 150},
        ],
        maxResponseBytes: 2000,
      );
      final servers = <Map<String, Object?>>[
        <String, Object?>{
          ...server.toWireJson(),
          ...await intro.describe(server),
        },
      ];
      intro.enforceBudget(servers);
      expect(utf8.encode(jsonEncode(servers)).length, lessThanOrEqualTo(2000));
      expect(servers.single['toolsTruncated'], isTrue);
      expect((servers.single['tools']! as List).length, lessThan(40));
    });
  });
}

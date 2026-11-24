import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/watch/acp_harness_adapter.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/protocol_async_watch_driver.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _Timer implements WatchCancellableTimer {
  _Timer(this.q, this.at, this.fn) {
    q.add(this);
  }
  final List<_Timer> q;
  final DateTime at;
  final void Function() fn;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}

class _Pipe {
  _Pipe({this.onPrompt});
  final _out = StreamController<String>.broadcast();
  final _exit = Completer<int>();
  final sent = <Map<String, Object?>>[];
  final void Function(_Pipe p, int id)? onPrompt;
  bool terminated = false;

  void write(String line) {
    final msg = (jsonDecode(line) as Map).cast<String, Object?>();
    sent.add(msg);
    final m = msg['method'], id = msg['id'];
    if (id is! int || m is! String) {
      return;
    }
    switch (m) {
      case 'initialize':
        reply(id, {'protocolVersion': 1, 'capabilities': {}});
      case 'session/new':
        reply(id, {'sessionId': 'acp_sess_1'});
      case 'tools/call':
      case 'session/prompt':
        onPrompt?.call(this, id);
    }
  }

  void _emit(Map<String, Object?> m) {
    if (!_out.isClosed) _out.add(jsonEncode({'jsonrpc': '2.0', ...m}));
  }

  void reply(int id, Map<String, Object?> r) => _emit({'id': id, 'result': r});
  void notify(String m, Map<String, Object?> p) =>
      _emit({'method': m, 'params': p});
  Future<void> terminate([int c = 0]) async {
    terminated = true;
    await crash(c);
  }

  Future<void> crash([int c = 1]) async {
    if (!_exit.isCompleted) _exit.complete(c);
    if (!_out.isClosed) await _out.close();
  }

  bool hasMethod(String m) => sent.any((x) => x['method'] == m);
  McpStdioTransport mcp() => McpStdioTransport(
    stdoutLines: _out.stream,
    writeStdinLine: write,
    exitCode: _exit.future,
    terminate: () => terminate(0),
  );
  AcpTransport acp() => AcpTransport(
    stdoutLines: _out.stream,
    writeStdinLine: write,
    exitCode: _exit.future,
    terminate: () => terminate(0),
  );
}

class _Env {
  _Env({DateTime Function()? clock, WatchTimerFactory? timers}) {
    reg = ProtocolTaskRegistry(stopController: stop, clock: clock);
    sen = LocalWatchSentinel(
      stopController: stop,
      logger: log,
      drivers: [ProtocolAsyncWatchDriver(taskRegistry: reg, logger: log)],
      now: clock,
      timerFactory: timers,
    );
    final sub = sen.events.listen(ev.add);
    addTearDown(() async {
      await sub.cancel();
      await sen.dispose();
      await reg.dispose();
      await stop.dispose();
    });
  }
  final log = ContentFreeLogger();
  late final stop = EmergencyStopController(logger: log);
  late final ProtocolTaskRegistry reg;
  late final LocalWatchSentinel sen;
  final ev = <WatchEventParams>[];

  Future<WatchRegisterOutcome> watch(String s, String srv, String tid) =>
      sen.registerWatch(
        WatchRegisterParams(
          watchId: '11111111-1111-4111-8111-1111111111$s',
          jobId: '22222222-2222-4222-8222-222222222222',
          mode: WatchMode.protocolAsync,
          target: WatchTarget(mcpServerId: srv, protocolTaskId: tid),
          quiescenceSeconds: 5,
          minWaitSeconds: 0,
          maxWaitSeconds: 120,
          requireInitialChange: false,
          releaseFocus: true,
        ),
      );
  Future<bool> watchOk(String s, String srv, String tid) async =>
      (await watch(s, srv, tid)).accepted;
  AutoMcpBridge mcp(McpStdioTransportFactory f, [DateTime Function()? c]) =>
      AutoMcpBridge(
        scanDefaultLocations: false,
        taskRegistry: reg,
        stdioTransportFactory: f,
        clock: c,
      );
  AcpHarnessAdapter acp(AcpTransportFactory f) =>
      AcpHarnessAdapter(taskRegistry: reg, transportFactory: f);
}

Future<McpCallOutcome> _goMcp(
  AutoMcpBridge b,
  DiscoveredMcpServer s,
  String t,
) => b.callToolAsync(server: s, toolName: t, asyncMode: true);
Future<AcpPromptOutcome> _goAcp(
  AcpHarnessAdapter a,
  ProtocolHarnessConfig h,
  String t,
) => a.runPrompt(harness: h, toolName: t, asyncMode: true);

Future<Map<String, Object?>> _sc(
  HostToolDispatcher d,
  int id,
  String n,
  Map<String, Object?> a,
) async =>
    (await d.dispatch(
          requestId: id,
          params: ToolsCallParams(
            name: n,
            arguments: a,
            invocationId: '33333333-1111-4111-8111-00000000010$id',
            deadlineMs: 5000,
          ),
        )).result['structuredContent']
        as Map<String, Object?>;

ProtocolHarnessConfig _acpCfg(String id) => ProtocolHarnessConfig(
  id: id,
  name: id,
  protocol: ProtocolHarnessProtocol.acpStdio,
  executable: 'safe_acp_bin',
  args: const ['--acp'],
);

DiscoveredMcpServer _mcpSrv(String id) => DiscoveredMcpServer(
  id: id,
  transport: 'stdio',
  source: 'host_policy',
  command: 'safe_mcp_bin',
);

void main() {
  Get.testMode = true;
  tearDown(Get.reset);

  test(
    'MCP progress avoids premature settle across quiescenceSeconds then settles',
    () async {
      var now = DateTime.utc(2026, 11, 23, 15, 0);
      final q = <_Timer>[];
      void adv(int sec) {
        now = now.add(Duration(seconds: sec));
        for (final t
            in q.where((t) => t.isActive && !t.at.isAfter(now)).toList()) {
          t.isActive = false;
          t.fn();
        }
      }

      final e = _Env(
        clock: () => now,
        timers: (d, f) => _Timer(q, now.add(d), f),
      );
      int? rpcId;
      final pipe = _Pipe(onPrompt: (_, id) => rpcId = id);
      final bridge = e.mcp((_, _) async => pipe.mcp(), () => now);
      final out = await _goMcp(bridge, _mcpSrv('build_mcp'), 'run');
      expect(out.isRunning, isTrue);
      final tid = out.protocolTaskId!;
      expect(await e.watchOk('01', 'build_mcp', tid), isTrue);
      await pumpEventQueue();
      adv(15);
      pipe.notify('notifications/progress', {
        'progressToken': tid,
        'progress': 1,
        'total': 2,
      });
      await pumpEventQueue();
      adv(15);
      expect(e.ev, isEmpty);
      expect(e.reg.lookup('build_mcp', tid)!.progressPercent, 50);
      pipe.reply(rpcId!, {
        'content': [
          {'type': 'text', 'text': 'Build passed.'},
        ],
      });
      await pumpEventQueue();
      expect(
        [e.ev.single.kind, e.ev.single.digestChanged],
        [WatchEventKind.settled, true],
      );
      expect(e.ev.single.observedSignals, [WatchSignal.protocolAsync]);
      expect(e.reg.lookup('build_mcp', tid)!.redactedSummary, 'Build passed.');
    },
  );

  test(
    'Pre-completed task emits settled strictly AFTER watchRegisterAccepted',
    () async {
      final e = _Env();
      final timeline = <String>[];
      final sub = e.sen.events.listen(
        (ev) => timeline.add('watchEvent:${ev.kind.wire}'),
      );
      addTearDown(sub.cancel);
      e.reg.registerTask(
        taskId: 'fast_done_1',
        serverId: 'build_mcp',
        protocol: 'mcp_stdio',
      );
      e.reg.completeTask('fast_done_1', summary: 'Finished before watch');
      final out = await e.watch('02', 'build_mcp', 'fast_done_1');
      expect(out.accepted, isTrue);
      timeline.add(
        'watchRegisterAccepted:${out.toXtpResponse(99).result['accepted']}',
      );
      expect(e.ev, isEmpty);
      await pumpEventQueue();
      expect(timeline, ['watchRegisterAccepted:true', 'watchEvent:settled']);
      expect(e.ev.single.observedSignals, [WatchSignal.protocolAsync]);
    },
  );

  test(
    'yieldMs sync vs detach & ACP lifecycle -> mcp.task_result U5 redaction',
    () async {
      final dir = await Directory.systemTemp.createTemp('xuna_drv_acp_');
      final paths = AgentPaths.resolve(overrideRootDir: dir);
      await paths.ensureDirectories();
      final e = _Env();
      final ps = HostPolicyStore(policyFile: paths.policyFile, logger: e.log);
      await ps.savePolicy(
        HostPolicy(
          trustPreset: TrustPreset.autopilot,
          families: {
            for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
          },
          apps: const [],
          urlDomains: const [],
          workflows: const [],
          players: const [],
          protocolHarnesses: [_acpCfg('acp_eval')],
        ),
      );
      final fastPipe = _Pipe(
        onPrompt: (p, id) => p.reply(id, {
          'content': [
            {'type': 'text', 'text': 'fast ok'},
          ],
        }),
      );
      var callIdx = 0;
      final bridge = e.mcp(
        (_, _) async => (callIdx++ == 0 ? fastPipe : _Pipe()).mcp(),
      );
      int? acpId;
      final acpPipe = _Pipe(onPrompt: (_, id) => acpId = id);
      final disp = HostToolDispatcher(
        policyStore: ps,
        channel: FakeXunaHostChannel(),
        auditStore: AuditLogStore(auditDir: paths.auditDir),
        stopController: e.stop,
        logger: e.log,
        protocolTaskRegistry: e.reg,
        mcpBridge: bridge,
        acpHarnessAdapter: e.acp((_, _) async => acpPipe.acp()),
      );
      addTearDown(() async {
        disp.dispose();
        await ps.dispose();
        await dir.delete(recursive: true);
      });

      final srv = _mcpSrv('mcp_y');
      final syncOut = await bridge.callToolAsync(
        server: srv,
        toolName: 'q',
        yieldMs: 5000,
      );
      expect(
        [syncOut.isRunning, syncOut.summary, e.reg.activeCount],
        [false, 'fast ok', 0],
      );

      final detachOut = await bridge.callToolAsync(
        server: srv,
        toolName: 's',
        yieldMs: 500,
      );
      expect(detachOut.isRunning, isTrue);
      await e.reg.cancelTask('mcp_y', detachOut.protocolTaskId!);

      final sc = await _sc(disp, 1, 'mcp.call', {
        'server': 'acp_eval',
        'tool': 'solve',
        'payloadJson': '{"prompt":"Analyze build"}',
        'asyncMode': true,
      });
      expect(sc['status'], 'running');
      final tid = sc['protocolTaskId'] as String;
      expect(acpPipe.sent.map((m) => m['method']).toList(), [
        'initialize',
        'session/new',
        'session/prompt',
      ]);

      expect(await e.watchOk('03', 'acp_eval', tid), isTrue);
      acpPipe.notify('session/update', {
        'text':
            'Report /Users/alice/secret.pem sk-ant-api03-secretkey9999999999',
        'progress': 3,
        'total': 4,
      });
      await pumpEventQueue();
      expect(e.reg.lookup('acp_eval', tid)!.progressPercent, 75);

      acpPipe.reply(acpId!, {'stopReason': 'end_turn'});
      await pumpEventQueue();
      expect(e.ev.last.kind, WatchEventKind.settled);

      final resSc = await _sc(disp, 2, 'mcp.task_result', {
        'server': 'acp_eval',
        'protocolTaskId': tid,
      });
      final sum = resSc['summary'] as String;
      expect(resSc['status'], 'completed');
      expect(sum, allOf(contains('[PATH]'), contains('[REDACTED]')));
      expect(
        sum.contains('/Users/alice/secret.pem') ||
            sum.contains('secretkey9999999999'),
        isFalse,
      );
    },
  );

  test(
    'target_lost on child exit, maxConcurrentTasks=4 fail-closed, and E-Stop',
    () async {
      final e = _Env(), crashPipe = _Pipe(), h = _acpCfg('acp_crash');
      final crashed = await _goAcp(
        e.acp((_, _) async => crashPipe.acp()),
        h,
        'solve',
      );
      expect(
        await e.watchOk('04', 'acp_crash', crashed.protocolTaskId!),
        isTrue,
      );
      await crashPipe.crash(1);
      await pumpEventQueue();
      expect(e.ev.last.kind, WatchEventKind.targetLost);
      expect(
        e.reg.lookup('acp_crash', crashed.protocolTaskId!)!.targetLost,
        isTrue,
      );

      final mcpPipes = <_Pipe>[], acpPipes = <_Pipe>[];
      _Pipe mk(List<_Pipe> l) => _Pipe()..let(l.add);
      final bridge = e.mcp((_, _) async => mk(mcpPipes).mcp());
      final acpLive = e.acp((_, _) async => mk(acpPipes).acp());
      final mcpSrv = _mcpSrv('mcp_cap');
      final m1 = await _goMcp(bridge, mcpSrv, 't1');
      final m2 = await _goMcp(bridge, mcpSrv, 't2');
      final a1 = await _goAcp(acpLive, h, 'a1');
      final a2 = await _goAcp(acpLive, h, 'a2');
      expect(e.reg.activeCount, 4);

      await expectLater(
        () => _goMcp(bridge, mcpSrv, 't5'),
        throwsA(
          isA<ProtocolTaskLimitException>().having(
            (ex) => ex.errorCode,
            'errorCode',
            'protocol_task_limit_reached',
          ),
        ),
      );
      expect(await e.watchOk('05', 'mcp_cap', m1.protocolTaskId!), isTrue);
      expect(await e.watchOk('06', 'acp_crash', a1.protocolTaskId!), isTrue);
      expect(e.sen.activeWatchCount, 2);

      e.stop.triggerStop(StopReason.ownerHost);
      await pumpEventQueue();
      expect([e.sen.activeWatchCount, e.reg.activeCount], [0, 0]);
      expect(mcpPipes.every((p) => p.terminated), isTrue);
      expect(acpPipes.every((p) => p.terminated), isTrue);
      expect(mcpPipes.first.hasMethod('notifications/cancelled'), isTrue);
      expect(acpPipes.first.hasMethod('session/cancel'), isTrue);
      expect(
        [
          e.reg.lookup('mcp_cap', m2.protocolTaskId!)!.status,
          e.reg.lookup('acp_crash', a2.protocolTaskId!)!.status,
        ],
        [ProtocolTaskStatus.cancelled, ProtocolTaskStatus.cancelled],
      );
    },
  );
}

extension _Let<T> on T {
  void let(void Function(T) fn) => fn(this);
}

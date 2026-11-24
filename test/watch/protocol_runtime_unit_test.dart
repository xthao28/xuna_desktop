import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/mcp_stdio_client.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/watch/acp_harness_adapter.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/protocol_async_watch_driver.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

typedef _R = ProtocolTaskRegistry;
typedef _H = ProtocolHarnessConfig;
typedef _Go = Future<Object> Function(_R, _Pipe);

class _Timer implements WatchCancellableTimer {
  _Timer(List<_Timer> q, this.at, this.fn) {
    q.add(this);
  }
  final DateTime at;
  final void Function() fn;
  @override
  bool isActive = true;
  @override
  void cancel() => isActive = false;
}

class _Pipe {
  _Pipe({this.onReq, bool hold = false, this.throwCancel = false})
    : gate = hold ? Completer<void>() : null;
  final out = StreamController<String>.broadcast();
  final exit = Completer<int>();
  final sent = <Map<String, Object?>>[];
  var dead = false;
  final bool throwCancel;
  final void Function(_Pipe p, int id)? onReq;
  final Completer<void>? gate;
  void write(String line) {
    final m = (jsonDecode(line) as Map).cast<String, Object?>();
    sent.add(m);
    final met = m['method'], id = m['id'];
    if (throwCancel && '$met'.contains('cancel')) throw StateError('pipe');
    if (id is! int) return;
    if (met == 'initialize') {
      void ok(_) => reply(id, {'protocolVersion': 1, 'capabilities': {}});
      gate == null ? ok(null) : unawaited(gate!.future.then(ok));
    }
    if (met == 'session/new') reply(id, {'sessionId': 's_1'});
    if (met == 'session/prompt' || met == 'tools/call') onReq?.call(this, id);
  }

  void _emit(Map<String, Object?> m) => out.add(jsonEncode(m));
  void reply(int id, Map<String, Object?> r, [Object? err]) => _emit({
    'jsonrpc': '2.0',
    'id': id,
    if (err == null) 'result': r else 'error': {'code': err, 'message': r},
  });
  void notify(String m, Map<String, Object?> p) =>
      _emit({'jsonrpc': '2.0', 'method': m, 'params': p});
  Future<void> close([int c = 0]) async {
    dead = true;
    if (!exit.isCompleted) exit.complete(c);
    await out.close();
  }

  McpStdioTransport mcp() => McpStdioTransport(
    stdoutLines: out.stream,
    writeStdinLine: write,
    exitCode: exit.future,
    terminate: close,
  );
  AcpTransport acp() => AcpTransport(
    stdoutLines: out.stream,
    writeStdinLine: write,
    exitCode: exit.future,
    terminate: close,
  );
}

_H _hc(String id, String exe, [List<String> a = const [], bool m = false]) =>
    _H(
      id: id,
      name: id,
      executable: exe,
      args: a,
      protocol: m
          ? ProtocolHarnessProtocol.mcpStdio
          : ProtocolHarnessProtocol.acpStdio,
    );
final _h = _hc('ok', 'safe_bin');
void _reg(_R r, String id, [String s = 'srv']) =>
    r.registerTask(taskId: id, serverId: s, protocol: 'mcp_stdio');
const _srv = DiscoveredMcpServer(
  id: 'srv1',
  transport: 'stdio',
  source: 'seed',
  command: 'safe_mcp',
);
Future<McpCallOutcome> _mcp(_R r, _Pipe p, String t, [bool a = true, int? y]) =>
    AutoMcpBridge(
      scanDefaultLocations: false,
      taskRegistry: r,
      stdioTransportFactory: (_, _) async => p.mcp(),
    ).callToolAsync(server: _srv, toolName: t, asyncMode: a, yieldMs: y);
AcpHarnessAdapter _acpAd(_R r, _Pipe p) => AcpHarnessAdapter(
  taskRegistry: r,
  transportFactory: (_, _) async => p.acp(),
);
Future<AcpPromptOutcome> _acp(_R r, _Pipe p, [String? pj]) => _acpAd(
  r,
  p,
).runPrompt(harness: _h, toolName: 'solve', payloadJson: pj, asyncMode: true);
Future<bool> _w(LocalWatchSentinel s, int i, String t, [bool r = true]) async =>
    (await s.registerWatch(
      WatchRegisterParams(
        watchId: '0000000$i-1111-4111-8111-111111111111',
        jobId: '22222222-2222-4222-8222-222222222222',
        mode: WatchMode.protocolAsync,
        target: WatchTarget(mcpServerId: 'srv', protocolTaskId: t),
        quiescenceSeconds: 2,
        minWaitSeconds: 0,
        maxWaitSeconds: 60,
        requireInitialChange: r,
        releaseFocus: true,
      ),
    )).accepted;
var _seq = 0;
Future<dynamic> _sc(
  HostToolDispatcher d,
  String n,
  Map<String, Object?> a,
) async => (await d.dispatch(
  requestId: ++_seq,
  params: ToolsCallParams(
    name: n,
    arguments: a,
    invocationId: '33333333-1111-4111-8111-${'$_seq'.padLeft(12, '0')}',
    deadlineMs: 5000,
  ),
)).result['structuredContent'];
final _log = ContentFreeLogger();
(EmergencyStopController, _R) _env([DateTime Function()? c]) {
  final s = EmergencyStopController(logger: _log),
      r = _R(stopController: s, clock: c);
  [s.dispose, r.dispose].forEach(addTearDown);
  return (s, r);
}

void main() {
  Get.testMode = true;
  tearDown(Get.reset);
  test('Registry limits, TTL, U5 & E-Stop', () async {
    var now = DateTime.utc(2026, 11, 23, 12);
    final (stopCtrl, reg) = _env(() => now);
    List.generate(4, (i) => _reg(reg, 't$i'));
    expect(() => _reg(reg, 't4'), throwsA(isA<ProtocolTaskLimitException>()));
    const sec = '/Users/a/k sk-ant-api03-abcdef1234567890abcdef1234567890';
    reg.completeTask('t0', summary: '$sec ${'x' * 7000}');
    final d0 = reg.lookup('srv', 't0')!;
    expect(d0.redactedSummary, contains('[PATH]'));
    expect(d0.redactedSummary, contains('[REDACTED]'));
    expect(utf8.encode(d0.redactedSummary!).length, lessThanOrEqualTo(6144));
    for (var i = 0; i < 18; i++) {
      _reg(reg, 'r$i');
      reg.completeTask('r$i', summary: 'ok $i');
    }
    expect(reg.retainedCompletedCount, 16);
    expect(reg.lookup('srv', 't0'), isNull);
    now = now.add(const Duration(minutes: 4, seconds: 59));
    expect(reg.retainedCompletedCount, 16);
    now = now.add(const Duration(seconds: 1));
    expect(reg.retainedCompletedCount, 0);
    var killed = false;
    reg.registerTask(
      taskId: 'k1',
      serverId: 'srv',
      protocol: 'mcp_stdio',
      cancelCallback: () async => killed = true,
    );
    stopCtrl.triggerStop(StopReason.ownerHost);
    expect(killed, isTrue);
    expect(reg.activeCount, 0);
    expect(reg.lookup('srv', 'k1')?.status, ProtocolTaskStatus.cancelled);
  });
  test('MCP & ACP lifecycle, streaming, cancel & shell ban', () async {
    final (_, reg) = _env();
    final sc = StreamController<String>(), sent = <Map>[], notifs = <String>[];
    final c = McpStdioClient.fromStreams(
      stdoutLines: sc.stream,
      writeStdinLine: (l) => sent.add(jsonDecode(l) as Map),
      onNotification: (m, _) => notifs.add(m),
    );
    addTearDown(c.close);
    sc.add('{"jsonrpc":"2.0","method":"notifications/progress","params":{}}');
    await pumpEventQueue();
    expect(notifs, ['notifications/progress']);
    c.sendNotification('notifications/cancelled', {'requestId': 9});
    expect(sent.single['id'], isNull);
    final fast = _Pipe(onReq: (p, id) => p.reply(id, {'text': 'fast ok'}));
    expect((await _mcp(reg, fast, 'run', false, 1000)).summary, 'fast ok');
    int? callId;
    final slow = _Pipe(onReq: (_, id) => callId = id, throwCancel: true),
        det = await _mcp(reg, slow, 'build');
    final tid = det.protocolTaskId!;
    expect(det.status, 'running');
    expect((slow.sent.last['params'] as Map)['_meta'], isA<Map>());
    const pm = 'notifications/progress';
    slow.notify(pm, {'progressToken': tid, 'progress': 2, 'total': 4});
    await pumpEventQueue();
    expect(reg.lookup('srv1', tid)?.progressPercent, 50);
    expect(await reg.cancelTask('srv1', tid), isTrue);
    expect(slow.dead, isTrue);
    const can = 'notifications/cancelled';
    final cm = slow.sent.firstWhere((m) => m['method'] == can);
    expect((cm['params'] as Map)['requestId'], callId);
    final crash = _Pipe(), crashed = await _mcp(reg, crash, 'crash');
    await crash.close(1);
    await pumpEventQueue();
    final cid = crashed.protocolTaskId!;
    expect(reg.lookup('srv1', cid)?.errorCode, 'target_lost');
    expect(() => _hc('s1', '/bin/sh'), throwsFormatException);
    const py = ['-c', 'x'];
    expect(() => _hc('p1', 'python3', py), throwsFormatException);
    int? pid;
    final pipe = _Pipe(onReq: (_, id) => pid = id),
        out = await _acp(reg, pipe, '{"prompt":"go"}');
    expect(out.isRunning, isTrue);
    const txt = 'Done /Users/bob/f sk-ant-api03-1234567890abcdef1234567890';
    pipe.notify('session/update', {'text': txt, 'progress': 3, 'total': 4});
    await pumpEventQueue();
    expect(reg.lookup('ok', out.protocolTaskId!)?.progressPercent, 75);
    pipe.reply(pid!, {'stopReason': 'end_turn'});
    await pumpEventQueue();
    final done = reg.lookup('ok', out.protocolTaskId!)!;
    expect(done.status, ProtocolTaskStatus.completed);
    expect(done.redactedSummary, contains('[PATH]'));
    expect(done.redactedSummary, contains('[REDACTED]'));
    final pipe2 = _Pipe(throwCancel: true), r2 = await _acp(reg, pipe2);
    expect(await reg.cancelTask('ok', r2.protocolTaskId!), isTrue);
    expect(pipe2.dead, isTrue);
    expect(pipe2.sent.any((m) => m['method'] == 'session/cancel'), isTrue);
    final pipe3 = _Pipe(), r3 = await _acp(reg, pipe3);
    await pipe3.close(1);
    await pumpEventQueue();
    expect(reg.lookup('ok', r3.protocolTaskId!)?.targetLost, isTrue);
  });
  test('Watch driver states & firing convergence timer', () async {
    final (stopCtrl, reg) = _env();
    final driver = ProtocolAsyncWatchDriver(taskRegistry: reg, logger: _log);
    Future<void> bad() => driver.startSignal(
      watchId: 'w0',
      signal: WatchSignal.protocolAsync,
      target: const WatchTarget(mcpServerId: 'srv', protocolTaskId: 'x'),
      releaseFocus: true,
      onUpdate: (_) {},
    );
    expect(bad, throwsA(isA<WatchDriverException>()));
    var now = DateTime.utc(2026, 11, 23, 12);
    final q = <_Timer>[];
    void adv(int sec) {
      now = now.add(Duration(seconds: sec));
      for (final t
          in q.where((t) => t.isActive && !t.at.isAfter(now)).toList()) {
        t.isActive = false;
        t.fn();
      }
    }

    final s = LocalWatchSentinel(
      stopController: stopCtrl,
      logger: _log,
      drivers: [driver],
      now: () => now,
      timerFactory: (d, f) => _Timer(q, now.add(d), f),
    );
    final ev = <WatchEventParams>[];
    [s.dispose, s.events.listen(ev.add).cancel].forEach(addTearDown);
    for (final (i, id, req) in [(1, 'run1', true), (2, 'run2', false)]) {
      _reg(reg, id);
      expect(await _w(s, i, id, req), isTrue);
      await pumpEventQueue();
      adv(10);
      reg.recordProgress(id, progressPercent: 40);
      adv(10);
      await pumpEventQueue();
      expect(ev.where((e) => e.watchId.startsWith('0000000$i')), isEmpty);
      reg.completeTask(id, summary: 'ok');
      await pumpEventQueue();
      expect(ev.last.kind, WatchEventKind.settled);
      expect(ev.last.observedSignals, [WatchSignal.protocolAsync]);
    }
    for (final id in ['dp', 'fp', 'lp']) {
      _reg(reg, id);
    }
    reg.completeTask('dp', summary: 'ok');
    reg.failTask('fp', errorCode: 'mcp_tool_failed');
    reg.markLost('lp');
    for (final (i, id, k) in [
      (3, 'dp', WatchEventKind.settled),
      (4, 'fp', WatchEventKind.error),
      (5, 'lp', WatchEventKind.targetLost),
    ]) {
      expect(await _w(s, i, id), isTrue);
      await pumpEventQueue();
      expect(ev.last.kind, k);
    }
  });
  test('Policy preservation & MCP tools', () async {
    final (stopCtrl, reg) = _env();
    final dir = await Directory.systemTemp.createTemp('xuna_rt_policy_');
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    final ps = HostPolicyStore(policyFile: paths.policyFile, logger: _log);
    final h = _hc('build_srv', 'safe_builder', const ['--serve'], true);
    await ps.savePolicy(
      HostPolicy(
        families: const {
          ToolFamily.app: FamilyPolicyDecision.allow,
          ToolFamily.host: FamilyPolicyDecision.allow,
        },
        apps: const [],
        urlDomains: const ['github.com'],
        workflows: const [],
        players: const [],
        protocolHarnesses: [h],
      ),
    );
    await ps.migrateMissingDesktopFamilies();
    expect(ps.evaluator.policy!.protocolHarnesses.single.id, 'build_srv');
    final ch = FakeXunaHostChannel();
    final audit = AuditLogStore(auditDir: paths.auditDir);
    final disp = HostToolDispatcher(
      policyStore: ps,
      channel: ch,
      auditStore: audit,
      stopController: stopCtrl,
      logger: _log,
      protocolTaskRegistry: reg,
    );
    await disp.setPolicy(
      requestId: 1,
      params: const SetPolicyParams(
        trustPreset: 'standard',
        allowApps: [],
        allowDomains: ['github.com'],
      ),
    );
    expect(ps.evaluator.policy!.protocolHarnesses.single.id, 'build_srv');
    final enroll = EnrollmentStateStore(stateFile: paths.enrollmentStateFile);
    final client = XtpSessionClient(
      wsUri: Uri.https('example.com', '/v1/hosts/connect'),
      channel: ch,
      enrollmentStore: enroll,
      policyStore: ps,
      dispatcher: disp,
      stopController: stopCtrl,
      logger: _log,
      enableAutoReconnect: false,
    );
    final ctrl = DesktopAgentController(
      channel: ch,
      enrollmentStore: enroll,
      policyStore: ps,
      auditStore: audit,
      stopController: stopCtrl,
      sessionClient: client,
      logger: _log,
      protocolTaskRegistry: reg,
    )..onInit();
    final td = [ps.dispose, disp.dispose, client.dispose, ctrl.onClose];
    td.forEach(addTearDown);
    addTearDown(() => dir.delete(recursive: true));
    await ctrl.toggleFamilyPolicy(ToolFamily.url, true);
    await ctrl.addAllowedDomainToPolicy('example.com');
    expect(ps.evaluator.policy!.protocolHarnesses.single.id, 'build_srv');
    final lj = jsonEncode(await _sc(disp, 'mcp.list_servers', {}));
    expect(lj, contains('"id":"build_srv"'));
    expect(lj, contains('"supportsAsync":true'));
    expect(lj.contains('safe_builder') || lj.contains('--serve'), isFalse);
    Future<dynamic> sc(String n, String id) =>
        _sc(disp, n, {'server': 'build_srv', 'protocolTaskId': id});
    _reg(reg, 'pt_ui', 'build_srv');
    reg.completeTask('pt_ui', summary: 'done');
    expect((await sc('mcp.task_result', 'pt_ui'))['status'], 'completed');
    _reg(reg, 'pt_can', 'build_srv');
    expect((await sc('mcp.task_cancel', 'pt_can'))['cancelled'], isTrue);
  });
  test('Concurrent capacity, E-Stop handshake & update safety', () async {
    final zoneErrors = <Object>[];
    await runZonedGuarded<Future<void>>(() async {
      Future<(_Pipe, _R, String?)> race(_Go go) async {
        final (_, r) = _env();
        List.generate(3, (i) => _reg(r, 'x$i'));
        final p1 = _Pipe(hold: true), p2 = _Pipe(hold: true);
        final f1 = go(r, p1), f2 = go(r, p2);
        await pumpEventQueue();
        p1.gate!.complete();
        await pumpEventQueue();
        p2.gate!.complete();
        final r1 = await f1 as dynamic;
        expect(r1.isRunning, isTrue);
        await expectLater(f2, throwsA(isA<ProtocolTaskLimitException>()));
        expect(p2.dead, isTrue);
        return (p1, r, r1.protocolTaskId as String?);
      }

      await race((r, p) => _mcp(r, p, 't'));
      final (ap1, reg2, tid) = await race((r, p) => _acp(r, p));
      const bad = {'role': 'assistant'};
      ap1.notify('session/update', {'message': bad, 'progress': 1, 'total': 2});
      ap1.notify('session/update', {'text': 123});
      await pumpEventQueue();
      expect(reg2.lookup('ok', tid!)?.progressPercent, 50);
      final (stop3, reg3) = _env();
      final ep = _Pipe(hold: true), ef = _mcp(reg3, ep, 'estop_t');
      await pumpEventQueue();
      stop3.triggerStop(StopReason.ownerHost);
      ep.gate!.complete();
      String ec(Object e) => (e as XunaHostChannelException).errorCode;
      expect(await ef.then((_) => '', onError: ec), 'stopped');
      await pumpEventQueue();
      expect(ep.dead, isTrue);
      for (final y in [null, 500]) {
        final sp = _Pipe(onReq: (p, id) => p.reply(id, {'x': y}, 'BAD'));
        final ad = _acpAd(reg3, sp);
        final out = ad.runPrompt(harness: _h, toolName: 's', yieldMs: y);
        expect(await out.then((_) => '', onError: ec), 'mcp_tool_failed');
        expect(sp.dead, isTrue);
      }
    }, (e, _) => zoneErrors.add(e));
    expect(zoneErrors, isEmpty);
  });
}

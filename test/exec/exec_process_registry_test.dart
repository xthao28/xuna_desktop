import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

Future<ExecTaskSnapshot> _run(
  ExecProcessRegistry registry, {
  Duration yieldAfter = const Duration(milliseconds: 200),
  Duration timeout = const Duration(seconds: 30),
  String command = 'npm test',
}) => registry.run(
  command: command,
  cwd: Directory.systemTemp.path,
  environment: const <String, String>{'PATH': '/usr/bin'},
  pty: false,
  timeout: timeout,
  yieldAfter: yieldAfter,
  risk: RiskTier.r2,
);

void main() {
  late EmergencyStopController stop;
  late FakeExecLauncher launcher;
  late ExecProcessRegistry registry;

  setUp(() {
    stop = EmergencyStopController(logger: ContentFreeLogger());
    launcher = FakeExecLauncher();
    registry = ExecProcessRegistry(
      stopController: stop,
      launcher: launcher,
      pollInterval: const Duration(milliseconds: 5),
      killGrace: const Duration(milliseconds: 50),
    );
  });

  test(
    'a fast command completes before yield with exit code and output',
    () async {
      launcher.onStart = (h) {
        h.emit('PASS 3 tests\n');
        h.exit(0);
      };
      final snap = await _run(registry);
      expect(snap.status, ExecTaskStatus.completed);
      expect(snap.exitCode, 0);
      expect(snap.output, contains('PASS 3 tests'));
    },
  );

  test('a non-zero exit is reported as failed, not completed (H1)', () async {
    launcher.onStart = (h) => h.exit(2);
    final snap = await _run(registry);
    expect(snap.status, ExecTaskStatus.failed);
    expect(snap.exitCode, 2);
  });

  test(
    'a slow command detaches as running and later emits a terminal event',
    () async {
      final snap = await _run(
        registry,
        yieldAfter: const Duration(milliseconds: 30),
      );
      expect(snap.status, ExecTaskStatus.running);
      expect(snap.exitCode, isNull);
      expect(snap.taskId, matches(RegExp(r'^exec_[a-z0-9]{12}$')));
      final event = registry.events.first;
      launcher.started.single.exit(0);
      expect((await event).status, ExecTaskStatus.completed);
      expect(registry.snapshot(snap.taskId)!.exitCode, 0);
    },
  );

  test(
    'the 5th concurrent task fails closed with exec_task_limit_reached',
    () async {
      for (var i = 0; i < 4; i++) {
        expect(
          (await _run(registry, yieldAfter: Duration.zero)).status,
          ExecTaskStatus.running,
        );
      }
      await expectLater(
        _run(registry, yieldAfter: Duration.zero),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'exec_task_limit_reached',
          ),
        ),
      );
      expect(launcher.started, hasLength(4));
    },
  );

  test('the policy concurrency limit is respected below 4', () async {
    await registry.run(
      command: 'a',
      cwd: '/',
      environment: const {},
      pty: false,
      timeout: const Duration(seconds: 5),
      yieldAfter: Duration.zero,
      risk: RiskTier.r2,
      concurrencyLimit: 1,
    );
    await expectLater(
      registry.run(
        command: 'b',
        cwd: '/',
        environment: const {},
        pty: false,
        timeout: const Duration(seconds: 5),
        yieldAfter: Duration.zero,
        risk: RiskTier.r2,
        concurrencyLimit: 1,
      ),
      throwsA(isA<XunaHostChannelException>()),
    );
  });

  test('timeout kills the process group and reports timed_out', () async {
    final snap = await _run(
      registry,
      timeout: const Duration(milliseconds: 40),
      yieldAfter: const Duration(milliseconds: 400),
    );
    expect(snap.status, ExecTaskStatus.timedOut);
    expect(launcher.started.single.termSignals, 1);
  });

  test(
    'E-Stop kills every running group (SIGTERM then SIGKILL) and blocks new runs',
    () async {
      final a = await _run(registry, yieldAfter: Duration.zero);
      final b = await _run(registry, yieldAfter: Duration.zero);
      launcher.started[1].exitOnTerm = false; // ignores SIGTERM
      stop.triggerStop(StopReason.ownerHost);
      await registry.killAll();
      expect(registry.statusOf(a.taskId), ExecTaskStatus.cancelled);
      expect(registry.statusOf(b.taskId), ExecTaskStatus.cancelled);
      expect(launcher.started[0].exited, isTrue);
      expect(
        launcher.started[1].killSignals,
        1,
        reason: 'escalates to SIGKILL',
      );
      expect(launcher.started[1].exited, isTrue);
      await expectLater(
        _run(registry),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'stopped',
          ),
        ),
      );
    },
  );

  test(
    'cancel reports cancelled once and already_finished afterwards',
    () async {
      final snap = await _run(registry, yieldAfter: Duration.zero);
      expect((await registry.cancel(snap.taskId)).status, 'cancelled');
      expect((await registry.cancel(snap.taskId)).status, 'already_finished');
      await expectLater(
        registry.cancel('exec_unknown'),
        throwsA(isA<XunaHostChannelException>()),
      );
    },
  );

  test('output is redacted, ANSI-stripped and tail-bounded', () {
    final bytes = <int>[
      ...'start\n'.codeUnits,
      ...List<int>.filled(20000, 'x'.codeUnitAt(0)),
      ...'\x1B[31mFAIL\x1B[0m key=sk-abcdefghijklmnopqrstuv\n'.codeUnits,
    ];
    final out = redactExecOutput(bytes, maxBytes: 16384);
    expect(out.truncated, isTrue);
    expect(out.text, isNot(contains('start')));
    expect(out.text, contains('FAIL'));
    expect(out.text, isNot(contains('\x1B')));
    expect(out.text, isNot(contains('sk-abcdefghijklmnopqrstuv')));
    expect(out.text, contains('[REDACTED]'));
  });

  test('finished tasks expire after the retention window (RAM only)', () async {
    var now = DateTime.utc(2026, 11, 25, 12);
    final reg = ExecProcessRegistry(
      stopController: stop,
      launcher: launcher,
      pollInterval: const Duration(milliseconds: 5),
      clock: () => now,
    );
    launcher.onStart = (h) => h.exit(0);
    final snap = await _run(reg);
    expect(reg.snapshot(snap.taskId), isNotNull);
    now = now.add(const Duration(minutes: 6));
    expect(reg.snapshot(snap.taskId), isNull);
  });

  group('real Windows process tree (taskkill /T /F)', () {
    final skip = Platform.isWindows ? false : 'Windows-only runtime test';

    test(
      'E-Stop leaves 0 surviving PIDs (parent cmd.exe and child ping.exe)',
      () async {
        final real = ExecProcessRegistry(
          stopController: stop,
          launcher: WindowsExecProcessLauncher(),
          pollInterval: const Duration(milliseconds: 50),
        );
        final snap = await real.run(
          command: 'ping -n 60 127.0.0.1',
          cwd: Directory.systemTemp.path,
          environment: sanitizeExecEnvironment(
            Platform.environment,
            windows: true,
          ),
          pty: false,
          timeout: const Duration(seconds: 90),
          yieldAfter: const Duration(milliseconds: 1500),
          risk: RiskTier.r2,
        );
        expect(snap.status, ExecTaskStatus.running);
        final children = await _childPids(snap.taskId, real);
        expect(children, isNotEmpty, reason: 'ping.exe child must exist');
        stop.triggerStop(StopReason.ownerHost);
        await real.killAll();
        expect(real.statusOf(snap.taskId), ExecTaskStatus.cancelled);
        for (final pid in children) {
          expect(await _alive(pid), isFalse, reason: 'child $pid survived');
        }
        expect(await _alive(_lastParentPid!), isFalse);
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 60)),
    );

    test(
      'child does not inherit secrets and output is U5-redacted',
      () async {
        final env = sanitizeExecEnvironment(<String, String>{
          ...Platform.environment,
          'GEMINI_API_KEY': 'leaked-gemini-value',
          'XUNA_SECRET': 'leaked-xuna-value',
        }, windows: true);
        final real = ExecProcessRegistry(
          stopController: stop,
          launcher: WindowsExecProcessLauncher(),
          pollInterval: const Duration(milliseconds: 50),
        );
        final snap = await real.run(
          command:
              'echo [%GEMINI_API_KEY%][%XUNA_SECRET%] && echo token sk-abcdefghijklmnopqrstuv',
          cwd: Directory.systemTemp.path,
          environment: env,
          pty: false,
          timeout: const Duration(seconds: 20),
          yieldAfter: const Duration(seconds: 15),
          risk: RiskTier.r2,
        );
        expect(snap.status, ExecTaskStatus.completed, reason: snap.output);
        expect(snap.output, isNot(contains('leaked')));
        expect(snap.output, contains('[%GEMINI_API_KEY%]'));
        expect(snap.output, isNot(contains('sk-abcdefghijklmnopqrstuv')));
        expect(snap.output, contains('[REDACTED]'));
      },
      skip: skip,
      timeout: const Timeout(Duration(seconds: 40)),
    );
  });
}

int? _lastParentPid;

/// PIDs of the cmd.exe parent's children, read with PowerShell CIM.
Future<List<int>> _childPids(
  String taskId,
  ExecProcessRegistry registry,
) async {
  final parent = registry.pidOf(taskId)!;
  _lastParentPid = parent;
  final result = await Process.run('powershell', <String>[
    '-NoProfile',
    '-Command',
    "(Get-CimInstance Win32_Process -Filter 'ParentProcessId=$parent').ProcessId",
  ]);
  return (result.stdout as String)
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .map(int.parse)
      .toList();
}

Future<bool> _alive(int pid) async {
  final result = await Process.run('tasklist', <String>[
    '/FI',
    'PID eq $pid',
    '/NH',
  ]);
  return (result.stdout as String).contains(' $pid ');
}

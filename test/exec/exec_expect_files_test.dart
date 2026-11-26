import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/exec/exec_output_verifier.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

/// Upgrade plan P1.1 (U3): `exec.run` `expectFiles` through the real
/// `HostToolDispatcher` and real files on disk (scripted child process).
class _Harness {
  _Harness(this.dir, this.workspace, this.dispatcher, this.launcher, this.reg);

  final Directory dir;
  final Directory workspace;
  final HostToolDispatcher dispatcher;
  final FakeExecLauncher launcher;
  final ExecProcessRegistry reg;
  var _id = 1;

  static Future<_Harness> create() async {
    final dir = await Directory.systemTemp.createTemp('xuna_p11_');
    final workspace = Directory('${dir.path}/ws')..createSync();
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    final logger = ContentFreeLogger();
    final store = HostPolicyStore(policyFile: paths.policyFile, logger: logger);
    await store.savePolicy(
      HostPolicy(
        trustPreset: TrustPreset.autopilot,
        families: const <ToolFamily, FamilyPolicyDecision>{
          ToolFamily.files: FamilyPolicyDecision.allow,
        },
        apps: const <AllowedAppConfig>[],
        urlDomains: const <String>[],
        workflows: const <WorkflowConfig>[],
        players: const <String>[],
        shellControl: ShellControlPolicy(
          enabled: true,
          workspaceRoots: <String>[workspace.path],
        ),
      ),
    );
    final stop = EmergencyStopController(logger: logger);
    final launcher = FakeExecLauncher();
    final reg = ExecProcessRegistry(
      stopController: stop,
      launcher: launcher,
      pollInterval: const Duration(milliseconds: 5),
    );
    final dispatcher = HostToolDispatcher(
      policyStore: store,
      channel: FakeXunaHostChannel(),
      auditStore: AuditLogStore(auditDir: paths.auditDir),
      stopController: stop,
      logger: logger,
      appScanner: AutoAppScanner(
        scanFileSystem: false,
        seedApps: const <DiscoveredApp>[],
      ),
      execRegistry: reg,
    );
    return _Harness(dir, workspace, dispatcher, launcher, reg);
  }

  String ws(String rel) => '${workspace.path}/$rel'.replaceAll(r'\', '/');

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> args,
  ) async {
    final res = await dispatcher.dispatch(
      requestId: _id++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId:
            'c0ffee00-0000-4000-8000-${(_id).toString().padLeft(12, '0')}',
        deadlineMs: 15000,
      ),
    );
    // Must survive the strict XTP parser on its way to the backend.
    XtpFrame.parse(res.encode());
    return res.result;
  }

  Future<Map<String, Object?>> preflight(
    String tool,
    Map<String, Object?> args,
  ) async {
    final res = await dispatcher.preflight(
      requestId: _id++,
      params: PreflightParams(name: tool, arguments: args),
    );
    XtpFrame.parse(res.encode());
    return (res.result['preflight'] as Map).cast<String, Object?>();
  }

  Future<void> dispose() => dir.delete(recursive: true);
}

String? _status(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/status'] as String?;
String? _error(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/errorCode'] as String?;
Map<String, Object?> _sc(Map<String, Object?> r) =>
    (r['structuredContent'] as Map).cast<String, Object?>();
List<Map<String, Object?>> _artifacts(Map<String, Object?> r) =>
    <Map<String, Object?>>[
      for (final a in _sc(r)['artifacts']! as List) (a as Map).cast(),
    ];

void main() {
  late _Harness h;
  setUp(() async => h = await _Harness.create());
  tearDown(() => h.dispose());

  final pdfBytes = utf8.encode('%PDF-1.7\nbody\n');

  test('exit 0 but the expected file was never written → failed', () async {
    h.launcher.onStart = (handle) {
      handle.emit('done\n');
      handle.exit(0);
    };
    final out = h.ws('dist/report.pdf');
    final res = await h.call('exec.run', {
      'command': 'npm run build',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': out, 'minBytes': 1},
      ],
    });
    expect(_status(res), 'failed');
    expect(_error(res), 'expected_output_missing');
    final sc = _sc(res);
    expect(sc['status'], 'failed');
    expect(sc['exitCode'], 0);
    expect(sc['errorCode'], 'expected_output_missing');
    expect(sc['output'], contains('done'));
    expect(_artifacts(res), [
      {'path': out, 'exists': false, 'problem': 'missing'},
    ]);
  });

  test(
    'the expected file exists and matches → completed, sha256 = disk',
    () async {
      final out = h.ws('dist/report.pdf');
      h.launcher.onStart = (handle) {
        File(out)
          ..createSync(recursive: true)
          ..writeAsBytesSync(pdfBytes);
        handle.exit(0);
      };
      final res = await h.call('exec.run', {
        'command': 'npm run build',
        'cwd': h.workspace.path,
        'expectFiles': [
          {
            'path': out,
            'minBytes': 4,
            'magic': '25504446',
            'sha256': sha256.convert(pdfBytes).toString(),
          },
        ],
      });
      expect(_status(res), 'ok', reason: '${_error(res)}');
      final sc = _sc(res);
      expect(sc['status'], 'completed');
      expect(sc.containsKey('errorCode'), isFalse);
      final onDisk = File(out).readAsBytesSync();
      expect(_artifacts(res), [
        {
          'path': out,
          'exists': true,
          'sizeBytes': onDisk.length,
          'sha256': sha256.convert(onDisk).toString(),
          'magicOk': true,
        },
      ]);
    },
  );

  test('wrong magic or sha256 → expected_output_mismatch', () async {
    final a = h.ws('out/a.bin');
    final b = h.ws('out/b.bin');
    h.launcher.onStart = (handle) {
      File(a)
        ..createSync(recursive: true)
        ..writeAsBytesSync(pdfBytes);
      File(b).writeAsStringSync('hello');
      handle.exit(0);
    };
    final res = await h.call('exec.run', {
      'command': 'npm run build',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': a, 'magic': '504B0304'},
        {'path': b, 'sha256': '0' * 64},
      ],
    });
    expect(_status(res), 'failed');
    expect(_error(res), 'expected_output_mismatch');
    final arts = _artifacts(res);
    expect(arts[0]['magicOk'], isFalse);
    expect(arts[0]['problem'], 'magic_mismatch');
    expect(arts[1]['problem'], 'sha256_mismatch');
    expect(arts[1]['sha256'], sha256.convert(utf8.encode('hello')).toString());
  });

  test(
    'a file smaller than minBytes or a directory counts as missing',
    () async {
      final small = h.ws('out/small.txt');
      final dir = h.ws('out/dir.txt');
      h.launcher.onStart = (handle) {
        File(small)
          ..createSync(recursive: true)
          ..writeAsStringSync('x');
        Directory(dir).createSync(recursive: true);
        handle.exit(0);
      };
      final res = await h.call('exec.run', {
        'command': 'npm run build',
        'cwd': h.workspace.path,
        'expectFiles': [
          {'path': small, 'minBytes': 2},
          {'path': dir},
        ],
      });
      expect(_error(res), 'expected_output_missing');
      expect(_artifacts(res).map((a) => a['problem']), [
        'too_small',
        'not_a_file',
      ]);
    },
  );

  test('a non-zero exit stays failed without checking outputs', () async {
    h.launcher.onStart = (handle) => handle.exit(2);
    final res = await h.call('exec.run', {
      'command': 'npm run build',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': h.ws('never.txt')},
      ],
    });
    expect(_status(res), 'ok');
    final sc = _sc(res);
    expect(sc['status'], 'failed');
    expect(sc['exitCode'], 2);
    expect(sc.containsKey('artifacts'), isFalse);
    expect(sc.containsKey('errorCode'), isFalse);
  });

  test(
    'a detached task is checked when it exits; exec.status reports it',
    () async {
      final out = h.ws('late.txt');
      final res = await h.call('exec.run', {
        'command': 'npm run build',
        'cwd': h.workspace.path,
        'yieldMs': 500,
        'expectFiles': [
          {'path': out},
        ],
      });
      expect(_sc(res)['status'], 'running');
      final taskId = _sc(res)['execTaskId']! as String;
      h.launcher.started.single.exit(0);
      for (var i = 0; i < 200; i++) {
        if (h.reg.statusOf(taskId)?.isTerminal ?? false) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final status = await h.call('exec.status', {'taskId': taskId});
      expect(_status(status), 'failed');
      expect(_error(status), 'expected_output_missing');
      expect(_sc(status)['status'], 'failed');
      expect(_artifacts(status).single['problem'], 'missing');
    },
  );

  test('expectFiles paths go through FsPathGuard at preflight', () async {
    final ok = await h.preflight('exec.run', {
      'command': 'npm test',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': h.ws('out.txt')},
      ],
    });
    expect(ok['status'], 'ok');
    expect(ok['effectiveRisk'], 'R2');
    final relative = await h.call('exec.run', {
      'command': 'npm test',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': 'out.txt'},
      ],
    });
    expect(_status(relative), 'invalid_args');
    expect(_error(relative), 'path_not_absolute');
    final secret = await h.call('exec.run', {
      'command': 'npm test',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': h.ws('.env')},
      ],
    });
    expect(_status(secret), 'denied');
    expect(_error(secret), 'fs_secret_file_forbidden');
    final ssh = await h.call('exec.run', {
      'command': 'npm test',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': h.ws('.ssh/known_hosts')},
      ],
    });
    expect(_status(ssh), 'denied');
    expect(_error(ssh), 'fs_path_forbidden');
    final badSchema = await h.call('exec.run', {
      'command': 'npm test',
      'cwd': h.workspace.path,
      'expectFiles': [
        {'path': h.ws('a'), 'extra': 1},
      ],
    });
    expect(_status(badSchema), 'invalid_args');
    expect(h.launcher.started, isEmpty);
  });

  test('a target that now resolves into a secret store is forbidden', () async {
    final out = h.ws('link.txt');
    File(out).writeAsStringSync('looks fine');
    final check = await verifyExpectedFiles(
      [ExpectedFileSpec(path: out)],
      realPath: (_) =>
          '${h.dir.path}/home/.ssh/id_ed25519'.replaceAll(r'\', '/'),
    );
    expect(check.errorCode, 'expected_output_mismatch');
    expect(check.artifacts.single, {
      'path': out,
      'exists': true,
      'problem': 'forbidden',
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

/// Wave 3 desktop integration through `HostToolDispatcher` (`ADR-0018`):
/// default fail-closed, local-only `shellControl`, host preflight
/// classification and the `fs.*` handlers on a real temp workspace.
class _Harness {
  _Harness(
    this.dir,
    this.workspace,
    this.dispatcher,
    this.store,
    this.launcher,
  );

  final Directory dir;
  final Directory workspace;
  final HostToolDispatcher dispatcher;
  final HostPolicyStore store;
  final FakeExecLauncher launcher;
  var _id = 1;

  static Future<_Harness> create({required bool shellEnabled}) async {
    final dir = await Directory.systemTemp.createTemp('xuna_w3_');
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
          enabled: shellEnabled,
          workspaceRoots: <String>[workspace.path],
        ),
      ),
    );
    final stop = EmergencyStopController(logger: logger);
    final launcher = FakeExecLauncher();
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
      execRegistry: ExecProcessRegistry(
        stopController: stop,
        launcher: launcher,
        pollInterval: const Duration(milliseconds: 5),
      ),
    );
    return _Harness(dir, workspace, dispatcher, store, launcher);
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

void main() {
  group('default fail-closed (shellControl disabled)', () {
    late _Harness h;
    setUp(() async => h = await _Harness.create(shellEnabled: false));
    tearDown(() => h.dispose());

    test('manifest advertises exec.* as permission denied', () async {
      final manifest = await h.dispatcher.buildManifest();
      final exec = manifest.where((t) => t.name.startsWith('exec.')).toList();
      expect(
        exec.map((t) => t.name),
        containsAll(<String>['exec.run', 'exec.status']),
      );
      for (final tool in exec) {
        expect(tool.policy.permission, XtpPermissionState.denied);
      }
      expect(manifest.map((t) => t.name), contains('fs.read_file'));
    });

    test(
      'exec.run refuses with shell_not_enabled on preflight and tools/call',
      () async {
        final pre = await h.preflight('exec.run', <String, Object?>{
          'command': 'ls',
        });
        expect(pre['status'], 'denied');
        expect(pre['errorCode'], 'shell_not_enabled');
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'ls',
        });
        expect(_status(res), 'denied');
        expect(_error(res), 'shell_not_enabled');
        expect(h.launcher.started, isEmpty, reason: 'nothing may be spawned');
      },
    );

    test(
      'a local shellControl change refreshes the manifest (tools/list_changed)',
      () async {
        var events = 0;
        final sub = h.dispatcher.toolsListChanged.listen((_) => events++);
        final current = h.store.evaluator.policy!;
        await h.store.savePolicy(
          current.copyWith(trustPreset: TrustPreset.standard),
        );
        await Future<void>.delayed(Duration.zero);
        expect(events, 0, reason: 'unrelated policy edits keep the manifest');
        await h.store.savePolicy(
          current.copyWith(
            shellControl: current.shellControl.copyWith(enabled: true),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(events, 1);
        final manifest = await h.dispatcher.buildManifest();
        expect(
          manifest.firstWhere((t) => t.name == 'exec.run').policy.permission,
          XtpPermissionState.granted,
        );
        await sub.cancel();
      },
    );

    test('get_policy exposes only the shellEnabled boolean', () async {
      final res = await h.dispatcher.getPolicy(requestId: 1);
      expect(res.result['shellEnabled'], isFalse);
      expect(jsonEncode(res.result), isNot(contains('workspaceRoots')));
      expect(jsonEncode(res.result), isNot(contains(h.workspace.path)));
    });
  });

  group('shellControl enabled locally', () {
    late _Harness h;
    setUp(() async => h = await _Harness.create(shellEnabled: true));
    tearDown(() => h.dispose());

    test(
      'remote xuna/set_policy keeps the local shellControl verbatim',
      () async {
        final before = h.store.evaluator.policy!.shellControl;
        final res = await h.dispatcher.setPolicy(
          requestId: 7,
          params: SetPolicyParams(trustPreset: 'standard'),
        );
        expect(res, isA<XtpResponse>());
        final after = h.store.evaluator.policy!;
        expect(after.trustPreset, TrustPreset.standard);
        expect(after.shellControl, before);
        expect(after.shellControl.enabled, isTrue);
        final onDisk =
            jsonDecode(
                  File('${h.dir.path}/host-policy.json').readAsStringSync(),
                )
                as Map<String, Object?>;
        expect((onDisk['shellControl'] as Map)['enabled'], isTrue);
      },
    );

    test(
      'preflight: R2 local test, R3 destructive, Hard-Deny sudo/env',
      () async {
        final cwd = h.workspace.path;
        final r2 = await h.preflight('exec.run', {
          'command': 'npm test',
          'cwd': cwd,
        });
        expect(r2['status'], 'ok');
        expect(r2['effectiveRisk'], 'R2');
        final r3 = await h.preflight('exec.run', {
          'command': 'git push origin dev',
          'cwd': cwd,
        });
        expect(r3['effectiveRisk'], 'R3');
        expect(r3['reasonCode'], 'network_command');
        final sudo = await h.preflight('exec.run', {
          'command': 'sudo ls',
          'cwd': cwd,
        });
        expect(sudo['status'], 'denied');
        expect(sudo['errorCode'], 'exec_hard_denied');
        final env = await h.preflight('exec.run', {
          'command': 'printenv',
          'cwd': cwd,
        });
        expect(env['errorCode'], 'exec_env_dump_forbidden');
      },
    );

    test(
      'an R3 command without a phone-signed approval is never spawned',
      () async {
        final res = await h.call('exec.run', {
          'command': 'rm notes.txt',
          'cwd': h.workspace.path,
        });
        expect(_status(res), 'denied');
        expect(_error(res), 'approval_required');
        expect(h.launcher.started, isEmpty);
      },
    );

    test(
      'an R2 command runs under autopilot and returns the redacted output',
      () async {
        h.launcher.onStart = (handle) {
          handle.emit('ok Bearer abc.def.ghi\n');
          handle.exit(0);
        };
        final res = await h.call('exec.run', {
          'command': 'npm test',
          'cwd': h.workspace.path,
        });
        expect(_status(res), 'ok', reason: '${_error(res)}');
        final sc = _sc(res);
        expect(sc['status'], 'completed');
        expect(sc['exitCode'], 0);
        expect(sc['output'], isNot(contains('abc.def.ghi')));
        expect(
          h.launcher.environments.single.keys,
          isNot(contains('XUNA_TEXT_API_KEY')),
        );
      },
    );

    test(
      'fs.write_file then fs.patch_file are atomic and hash the result',
      () async {
        final path = h.ws('src/app.ts');
        final w = await h.call('fs.write_file', {
          'path': path,
          'content': 'const a = 1;\nconst b = 1;\n',
        });
        expect(_status(w), 'ok', reason: '${_error(w)}');
        expect(_sc(w)['created'], isTrue);
        final ambiguous = await h.call('fs.patch_file', {
          'path': path,
          'target': '= 1',
          'replacement': '= 2',
        });
        expect(_error(ambiguous), 'patch_target_ambiguous');
        final missing = await h.call('fs.patch_file', {
          'path': path,
          'target': 'zzz',
          'replacement': 'y',
        });
        expect(_error(missing), 'patch_target_not_found');
        final ok = await h.call('fs.patch_file', {
          'path': path,
          'target': 'const a = 1',
          'replacement': 'const a = 3',
        });
        expect(_status(ok), 'ok');
        final text = File(path).readAsStringSync();
        expect(text, 'const a = 3;\nconst b = 1;\n');
        expect(_sc(ok)['sha256'], sha256.convert(utf8.encode(text)).toString());
        final leftovers = Directory(
          h.ws('src'),
        ).listSync().where((e) => e.path.endsWith('.tmp'));
        expect(leftovers, isEmpty, reason: 'no temp file may remain');
      },
    );

    test(
      'fs.read_file redacts secrets; .env is refused; grep skips secrets',
      () async {
        File(h.ws('config.ts')).writeAsStringSync(
          'line1\nconst key = "sk-abcdefghijklmnopqrstuv";\n',
        );
        File(
          h.ws('.env'),
        ).writeAsStringSync('OPENAI_API_KEY=sk-zzzzzzzzzzzzzzzzzzzz\n');
        final read = await h.call('fs.read_file', {'path': h.ws('config.ts')});
        expect(_status(read), 'ok');
        expect(
          _sc(read)['content'],
          isNot(contains('sk-abcdefghijklmnopqrstuv')),
        );
        expect(_sc(read)['totalLines'], 2);
        final env = await h.call('fs.read_file', {'path': h.ws('.env')});
        expect(_status(env), 'denied');
        expect(_error(env), 'fs_secret_file_forbidden');
        final grep = await h.call('fs.grep', {
          'path': h.workspace.path,
          'pattern': 'sk-',
        });
        final matches = _sc(grep)['matches'] as List;
        expect(matches.map((m) => (m as Map)['path']), isNot(contains('.env')));
        expect(jsonEncode(matches), isNot(contains('sk-zzzz')));
      },
    );

    test('fs.list_files never lists a .ssh directory', () async {
      Directory(h.ws('.ssh')).createSync();
      File(h.ws('.ssh/id_rsa')).writeAsStringSync('x');
      File(h.ws('README.md')).writeAsStringSync('x');
      final res = await h.call('fs.list_files', {'path': h.workspace.path});
      final paths = (_sc(res)['entries'] as List).map(
        (e) => (e as Map)['path'],
      );
      expect(paths, contains('README.md'));
      expect(paths.where((p) => '$p'.contains('.ssh')), isEmpty);
    });

    test(
      'a write outside the workspace roots needs R3 (approval_required)',
      () async {
        final res = await h.call('fs.write_file', {
          'path': '${h.dir.path}/outside.txt',
          'content': 'x',
        });
        expect(_error(res), 'approval_required');
        expect(File('${h.dir.path}/outside.txt').existsSync(), isFalse);
      },
    );

    test(
      'symlink from the workspace into a .ssh directory is refused',
      () async {
        final secret = Directory('${h.dir.path}/home/.ssh')
          ..createSync(recursive: true);
        File('${secret.path}/known_hosts').writeAsStringSync('PRIVATE');
        final link = Link(h.ws('keys'));
        try {
          link.createSync(secret.path);
        } on FileSystemException {
          markTestSkipped('symlink creation not permitted on this machine');
          return;
        }
        final res = await h.call('fs.read_file', {
          'path': h.ws('keys/known_hosts'),
        });
        expect(_status(res), 'denied');
        expect(_error(res), 'fs_path_forbidden');
      },
    );
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/exec/preflight_preview_builder.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

class _PreviewHarness {
  _PreviewHarness({
    required this.dir,
    required this.workspace,
    required this.paths,
    required this.logger,
    required this.dispatcher,
  });

  final Directory dir;
  final Directory workspace;
  final AgentPaths paths;
  final ContentFreeLogger logger;
  final HostToolDispatcher dispatcher;
  int _id = 1;

  static Future<_PreviewHarness> create() async {
    final dir = await Directory.systemTemp.createTemp('xuna_w4m2_');
    final workspace = Directory('${dir.path}/ws')..createSync();
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    final logger = ContentFreeLogger();
    final store = HostPolicyStore(policyFile: paths.policyFile, logger: logger);
    await store.savePolicy(
      HostPolicy(
        trustPreset: TrustPreset.standard,
        families: const <ToolFamily, FamilyPolicyDecision>{
          ToolFamily.files: FamilyPolicyDecision.allow,
          ToolFamily.exec: FamilyPolicyDecision.allow,
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
        launcher: FakeExecLauncher(),
      ),
    );
    return _PreviewHarness(
      dir: dir,
      workspace: workspace,
      paths: paths,
      logger: logger,
      dispatcher: dispatcher,
    );
  }

  String ws(String rel) => '${workspace.path}/$rel'.replaceAll(r'\', '/');

  Future<Map<String, Object?>> preflight(
    String tool,
    Map<String, Object?> args,
  ) async {
    final res = await dispatcher.preflight(
      requestId: _id++,
      params: PreflightParams(name: tool, arguments: args),
    );
    // Must pass strict XTP frame validation on wire.
    XtpFrame.parse(res.encode());
    return (res.result['preflight']! as Map).cast<String, Object?>();
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    if (dir.existsSync()) await dir.delete(recursive: true);
  }
}

void main() {
  group('Desktop preflight preview (W4-M2 / ADR-0019 §2)', () {
    late _PreviewHarness h;
    setUp(() async => h = await _PreviewHarness.create());
    tearDown(() => h.dispose());

    test(
      'fs.patch_file generates compact redacted unified diff without touching disk or logs',
      () async {
        final path = h.ws('src/app.ts');
        Directory(h.ws('src')).createSync(recursive: true);
        const before =
            'const token = "sk-1234567890abcdefghijklmnop";\nconst port = 3000;\n';
        File(path).writeAsStringSync(before);

        final pre = await h.preflight('fs.patch_file', <String, Object?>{
          'path': path,
          'target': 'port = 3000',
          'replacement': 'port = 8080',
        });
        expect(pre['status'], 'ok');
        final preview = (pre['preview']! as Map).cast<String, Object?>();
        expect(preview['kind'], 'diff');
        expect(preview['truncated'], isFalse);
        expect(preview['summary'], contains('src/app.ts'));
        final snippet = preview['snippet']! as String;
        expect(snippet, contains('-const port = 3000;'));
        expect(snippet, contains('+const port = 8080;'));
        expect(snippet, isNot(contains('sk-1234567890abcdefghijklmnop')));
        expect(snippet, contains('[REDACTED]'));
        // Read-only invariant: file on disk is unchanged.
        expect(File(path).readAsStringSync(), before);
        // §3.6 content-free logs: snippet never enters logger.
        final logs = h.logger.entries
            .map((e) => '${e.event} ${jsonEncode(e.fields)}')
            .join('\n');
        expect(logs, isNot(contains('port = 8080')));
        expect(logs, isNot(contains('src/app.ts')));
      },
    );

    test(
      'fs.write_file truncates large diff strictly to <= 2048 UTF-8 bytes & <= 40 lines with …',
      () async {
        final path = h.ws('big.txt');
        final longContent = List<String>.generate(
          80,
          (i) => 'line-$i: ${'abcdefghij' * 6}',
        ).join('\n');

        final pre = await h.preflight('fs.write_file', <String, Object?>{
          'path': path,
          'content': longContent,
        });
        expect(pre['status'], 'ok');
        final preview = (pre['preview']! as Map).cast<String, Object?>();
        expect(preview['kind'], 'diff');
        expect(preview['truncated'], isTrue);
        final snippet = preview['snippet']! as String;
        expect(snippet, endsWith('…'));
        expect(utf8.encode(snippet).length, lessThanOrEqualTo(2048));
        expect(snippet.split('\n').length, lessThanOrEqualTo(40));
        expect(File(path).existsSync(), isFalse);
      },
    );

    test(
      'fail-closed: never generates diff preview for .env or secret files',
      () async {
        final envPath = h.ws('.env');
        File(
          envPath,
        ).writeAsStringSync('OPENAI_API_KEY=sk-topsecretvalue123456789\n');

        final pre = await h.preflight('fs.write_file', <String, Object?>{
          'path': envPath,
          'content': 'OPENAI_API_KEY=sk-othersecretvalue123456789\n',
        });
        expect(pre['status'], 'ok');
        expect(pre['effectiveRisk'], 'R3');
        expect(pre.containsKey('preview'), isFalse);
      },
    );

    test(
      'exec.run delete glob expands workspace-relative paths capped at 20 with totalCount',
      () async {
        final logsDir = Directory(h.ws('logs'))..createSync();
        for (var i = 0; i < 25; i++) {
          File(
            '${logsDir.path}/f_${i.toString().padLeft(2, '0')}.log',
          ).writeAsStringSync('log');
        }
        File('${logsDir.path}/keep.txt').writeAsStringSync('keep');

        final cmd = Platform.isWindows ? r'del logs\*.log' : 'rm logs/*.log';
        final pre = await h.preflight('exec.run', <String, Object?>{
          'command': cmd,
          'cwd': h.workspace.path,
        });
        expect(pre['status'], 'ok');
        expect(pre['effectiveRisk'], 'R3');
        final preview = (pre['preview']! as Map).cast<String, Object?>();
        expect(preview['kind'], 'paths');
        expect(preview['totalCount'], 25);
        expect(preview['truncated'], isTrue);
        final paths = (preview['paths']! as List).cast<String>();
        expect(paths, hasLength(20));
        expect(paths.first, 'logs/f_00.log');
        expect(paths, isNot(contains('logs/keep.txt')));
        // Read-only invariant: all 25 files still exist!
        expect(logsDir.listSync(), hasLength(26));
      },
    );

    test(
      'M2-2 fail-closed: glob outside workspace or matching .env returns null preview while keeping R3',
      () async {
        // 1. Glob matching a secret file (.env) inside workspace -> fail-closed preview = null
        File(h.ws('.env')).writeAsStringSync('SECRET=1');
        File(h.ws('.editorconfig')).writeAsStringSync('root = true');
        final preSecret = await h.preflight('exec.run', <String, Object?>{
          'command': 'rm .*',
          'cwd': h.workspace.path,
        });
        expect(preSecret['status'], 'ok');
        expect(preSecret['effectiveRisk'], 'R3');
        expect(preSecret.containsKey('preview'), isFalse);

        // 2. Delete target escaping workspace via .. -> fail-closed preview = null
        File('${h.dir.path}/outside.log').writeAsStringSync('outside');
        final preEscape = await h.preflight('exec.run', <String, Object?>{
          'command': 'rm ../*.log',
          'cwd': h.workspace.path,
        });
        expect(preEscape['status'], 'ok');
        expect(preEscape['effectiveRisk'], 'R3');
        expect(preEscape.containsKey('preview'), isFalse);

        // 3. Chained command or dynamic variable -> fail-closed preview = null
        final preChain = await h.preflight('exec.run', <String, Object?>{
          'command': 'rm logs/*.log && echo done',
          'cwd': h.workspace.path,
        });
        expect(preChain['status'], 'ok');
        expect(preChain.containsKey('preview'), isFalse);
      },
    );

    test('non-destructive exec.run produces no preview', () async {
      final pre = await h.preflight('exec.run', <String, Object?>{
        'command': 'npm test',
        'cwd': h.workspace.path,
      });
      expect(pre['status'], 'ok');
      expect(pre['effectiveRisk'], 'R2');
      expect(pre.containsKey('preview'), isFalse);
    });

    test(
      'direct buildPreflightPreview handles Windows del /s and POSIX rm -rf symmetrically',
      () {
        final sub = Directory(h.ws('tmp_dir/nested'))
          ..createSync(recursive: true);
        File('${sub.path}/a.tmp').writeAsStringSync('1');
        File('${sub.path}/b.tmp').writeAsStringSync('2');
        final policy = ShellControlPolicy(
          enabled: true,
          workspaceRoots: <String>[h.workspace.path],
        );
        final winPrev = buildPreflightPreview(
          toolName: 'exec.run',
          arguments: <String, Object?>{
            'command': r'del /s tmp_dir\*.tmp',
            'cwd': h.workspace.path,
          },
          shellControl: policy,
          isWindowsOverride: true,
        );
        final rmPrev = buildPreflightPreview(
          toolName: 'exec.run',
          arguments: <String, Object?>{
            'command': 'rm -rf tmp_dir',
            'cwd': h.workspace.path,
          },
          shellControl: policy,
        );
        expect(winPrev, isNotNull);
        expect(winPrev!.kind, XtpPreflightPreviewKind.paths);
        expect(winPrev.paths, <String>[
          'tmp_dir/nested/a.tmp',
          'tmp_dir/nested/b.tmp',
        ]);
        expect(winPrev.totalCount, 2);
        expect(rmPrev, isNotNull);
        expect(rmPrev!.kind, XtpPreflightPreviewKind.paths);
        expect(rmPrev.paths, <String>[
          'tmp_dir/nested/a.tmp',
          'tmp_dir/nested/b.tmp',
        ]);
        expect(rmPrev.totalCount, 2);
      },
    );
  });
}

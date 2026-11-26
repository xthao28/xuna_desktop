import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/exec/exec_process_launcher.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_remediation_catalog.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

class _SpawnFailingExecLauncher extends FakeExecLauncher {
  bool failNextSpawn = false;

  @override
  Future<ExecProcessHandle> start({
    required String command,
    required String cwd,
    required Map<String, String> environment,
    required bool pty,
  }) async {
    if (failNextSpawn) {
      failNextSpawn = false;
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_spawn_failed',
      );
    }
    return super.start(
      command: command,
      cwd: cwd,
      environment: environment,
      pty: pty,
    );
  }
}

class _RemediationHarness {
  _RemediationHarness(
    this.dir,
    this.workspace,
    this.dispatcher,
    this.launcher,
    this.refreshCalls,
    this._phonePrivate,
    this._phonePublic,
  );

  static const String _hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';

  final Directory dir;
  final Directory workspace;
  final HostToolDispatcher dispatcher;
  final _SpawnFailingExecLauncher launcher;
  final List<bool> refreshCalls;
  final Uint8List _phonePrivate;
  final Uint8List _phonePublic;
  var _id = 1;

  static Future<_RemediationHarness> create({
    Map<String, String> seedAgentBinaries = const <String, String>{},
  }) async {
    final dir = await Directory.systemTemp.createTemp('xuna_p12_rem_');
    final workspace = Directory('${dir.path}/sample_ws')..createSync();
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    final logger = ContentFreeLogger();
    final store = HostPolicyStore(policyFile: paths.policyFile, logger: logger);
    await store.savePolicy(
      HostPolicy(
        trustPreset: TrustPreset.autopilot,
        families: <ToolFamily, FamilyPolicyDecision>{
          for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
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
    final phonePrivate = Uint8List.fromList(
      List<int>.generate(32, (i) => (i + 71) & 0xff),
    );
    final phonePublic = deriveP256PublicKey(phonePrivate);
    final enrollmentStore = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    await enrollmentStore.save(hostId: _hostId, alias: 'Win-Dev');
    await enrollmentStore.updatePhonePublicKeys(<String>[
      base64.encode(phonePublic),
    ]);
    final stop = EmergencyStopController(logger: logger);
    final launcher = _SpawnFailingExecLauncher();
    final reg = ExecProcessRegistry(
      stopController: stop,
      launcher: launcher,
      pollInterval: const Duration(milliseconds: 5),
    );
    final refreshCalls = <bool>[];
    final dispatcher = HostToolDispatcher(
      policyStore: store,
      channel: FakeXunaHostChannel(),
      auditStore: AuditLogStore(auditDir: paths.auditDir),
      stopController: stop,
      logger: logger,
      enrollmentStore: enrollmentStore,
      appScanner: AutoAppScanner(
        scanFileSystem: false,
        seedApps: const <DiscoveredApp>[],
        seedAgentBinaries: seedAgentBinaries,
      ),
      workspaceIndexer: AutoWorkspaceIndexer(
        scanDefaultLocations: false,
        seedWorkspaces: <DiscoveredWorkspace>[
          DiscoveredWorkspace(
            alias: 'sample_ws',
            path: workspace.path,
            lastModified: DateTime.utc(2026, 11, 26),
          ),
        ],
      ),
      execRegistry: reg,
      onToolchainRefreshRequested: ({bool forceRefresh = true}) {
        refreshCalls.add(forceRefresh);
      },
    );
    return _RemediationHarness(
      dir,
      workspace,
      dispatcher,
      launcher,
      refreshCalls,
      phonePrivate,
      phonePublic,
    );
  }

  ApprovalToken signR3(Map<String, Object?> args) {
    final idNum = _id++;
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final expiresWire = expiresAt.toIso8601String();
    final approvalId =
        'f${idNum.toString().padLeft(7, '0')}-4444-4444-8888-111111111111';
    final sha = argsSha256(args);
    final sig = signP256Deterministic(
      privateScalar32: _phonePrivate,
      message: approvalProofMessage(
        approvalId: approvalId,
        argsSha256: sha,
        hostId: _hostId,
        expiresAt: expiresWire,
      ),
    );
    return ApprovalToken(
      approvalId: approvalId,
      argsSha256: sha,
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      signature: sig,
      publicKey: _phonePublic,
    );
  }

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> args, {
    bool withR3Approval = false,
  }) async {
    final res = await dispatcher.dispatch(
      requestId: _id++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId:
            'd00d0000-0000-4000-8000-${(_id).toString().padLeft(12, '0')}',
        deadlineMs: 15000,
        approval: withR3Approval ? signR3(args) : null,
      ),
    );
    // Must pass strict XTP wire validation (including remediation path checks).
    XtpFrame.parse(res.encode());
    return res.result;
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    await dir.delete(recursive: true);
  }
}

String? _status(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/status'] as String?;
String? _error(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/errorCode'] as String?;
Map<String, Object?> _sc(Map<String, Object?> r) =>
    (r['structuredContent'] as Map).cast<String, Object?>();

void main() {
  group('HostRemediationCatalog invariants (P1.2 / U4)', () {
    test(
      'every known toolchain & dependency validates across Windows/macOS/Linux with zero host paths',
      () {
        const ids = <String>[
          'git',
          'node',
          'npm',
          'python',
          'python3',
          'dart',
          'flutter',
          'go',
          'cargo',
          'docker',
          'gh',
          'rg',
          'ffmpeg',
          'soffice',
          'vscode',
          'cursor',
          'antigravity',
          'claude_code',
          'codex',
          'auto',
        ];
        for (final platform in const <({bool win, bool mac})>[
          (win: true, mac: false),
          (win: false, mac: true),
          (win: false, mac: false),
        ]) {
          for (final id in ids) {
            final rem = HostRemediationCatalog.forDependency(
              id,
              isWindows: platform.win,
              isMacOs: platform.mac,
            );
            expect(
              rem,
              isNotNull,
              reason:
                  'Expected remediation for $id (win=${platform.win}, mac=${platform.mac})',
            );
            rem!.validate();
            expect(XtpRemediation.tryFromJson(rem.toJson()), equals(rem));
          }
        }

        // Unknown commands/dependencies fail closed (null, never invented).
        expect(
          HostRemediationCatalog.forCommandToken('frobnicate_xyz'),
          isNull,
        );
        expect(HostRemediationCatalog.forDependency('unknown_ide_xyz'), isNull);
      },
    );

    test(
      'env wrapper unwraps KEY=VAL assignments and fails closed on -S / --split-string',
      () {
        expect(
          HostRemediationCatalog.extractMissingCommandToken(
            'env FOO=1 python script.py',
            '',
            isWindows: false,
          ),
          equals('python'),
        );
        expect(
          HostRemediationCatalog.extractMissingCommandToken(
            'env -i FOO=1 BAR=baz python3 script.py',
            '',
            isWindows: false,
          ),
          equals('python3'),
        );
        expect(
          HostRemediationCatalog.extractMissingCommandToken(
            'env -S "python script.py"',
            '',
            isWindows: false,
          ),
          isNull,
        );
        expect(
          HostRemediationCatalog.extractMissingCommandToken(
            'env --split-string="python script.py"',
            '',
            isWindows: false,
          ),
          isNull,
        );
        expect(
          HostRemediationCatalog.isPackageOrToolchainInstallCommand(
            'env FOO=1 npm install foo',
            isWindows: false,
          ),
          isTrue,
        );
        expect(
          HostRemediationCatalog.isPackageOrToolchainInstallCommand(
            'env -S "npm install foo"',
            isWindows: false,
          ),
          isFalse,
        );
      },
    );
  });

  group('exec.run & workspace.* remediation attachment (P1.2 / U4)', () {
    late _RemediationHarness h;
    setUp(() async => h = await _RemediationHarness.create());
    tearDown(() => h.dispose());

    test(
      'exec.run missing known tool via exit 9009 returns toolchain_missing with remediation and refreshes resources',
      () async {
        h.launcher.onStart = (handle) {
          handle.emit(
            "'node' is not recognized as an internal or external command,\n",
          );
          handle.exit(9009);
        };
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'node app.js',
          'cwd': h.workspace.path,
        });

        expect(res['isError'], isTrue);
        expect(_status(res), 'failed');
        expect(_error(res), 'toolchain_missing');
        final sc = _sc(res);
        expect(sc['status'], 'failed');
        expect(sc['exitCode'], 9009);
        expect(sc['errorCode'], 'toolchain_missing');
        expect(sc['output'], contains('is not recognized'));
        expect(sc.containsKey('truncated'), isTrue);
        expect(sc['durationMs'], isA<int>());
        final rem = XtpRemediation.fromJson(
          sc['remediation']! as Map<String, Object?>,
        );
        expect(rem.kind, XtpRemediationKind.install);
        expect(rem.summary, isNotEmpty);
        expect(
          jsonEncode(sc['remediation']),
          isNot(contains(h.workspace.path)),
        );
        expect(h.refreshCalls, equals(const <bool>[true]));
      },
    );

    test(
      'exec.run missing known tool via POSIX exit 127 or chained command returns toolchain_missing',
      () async {
        h.launcher.onStart = (handle) {
          handle.emit('zsh:1: command not found: cargo\n');
          handle.exit(127);
        };
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'cd sub && cargo test',
          'cwd': h.workspace.path,
        });

        expect(_status(res), 'failed');
        expect(_error(res), 'toolchain_missing');
        final sc = _sc(res);
        expect(sc['exitCode'], 127);
        final rem = XtpRemediation.fromJson(
          sc['remediation']! as Map<String, Object?>,
        );
        expect(rem.kind, isNotNull);
        expect(h.refreshCalls, equals(const <bool>[true]));
      },
    );

    test(
      'exec.run exec_spawn_failed on known tool attaches toolchain_missing remediation',
      () async {
        h.launcher.failNextSpawn = true;
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'python3 -m pytest',
          'cwd': h.workspace.path,
        });

        expect(_status(res), 'failed');
        expect(_error(res), 'toolchain_missing');
        final sc = _sc(res);
        expect(sc['status'], 'failed');
        expect(sc['errorCode'], 'toolchain_missing');
        expect(sc['remediation'], isA<Map<String, Object?>>());
        expect(h.refreshCalls, equals(const <bool>[true]));
      },
    );

    test(
      'exec.run exec_spawn_failed on env KEY=VAL wrapped tool attaches toolchain_missing remediation',
      () async {
        h.launcher.failNextSpawn = true;
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'env FOO=1 python script.py',
          'cwd': h.workspace.path,
        }, withR3Approval: true);

        expect(_status(res), 'failed');
        expect(_error(res), 'toolchain_missing');
        final sc = _sc(res);
        expect(sc['status'], 'failed');
        expect(sc['errorCode'], 'toolchain_missing');
        final rem = XtpRemediation.fromJson(
          sc['remediation']! as Map<String, Object?>,
        );
        expect(rem.kind, XtpRemediationKind.install);
        expect(rem.summary.toLowerCase(), contains('python'));
        expect(h.refreshCalls, equals(const <bool>[true]));
      },
    );

    test(
      'exec.run missing unknown command fails closed without fabricating remediation',
      () async {
        h.launcher.onStart = (handle) {
          handle.emit("'frobnicate_missing_cli' is not recognized\n");
          handle.exit(9009);
        };
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'frobnicate_missing_cli --help',
          'cwd': h.workspace.path,
        }, withR3Approval: true);

        expect(_status(res), 'ok');
        final sc = _sc(res);
        expect(sc['status'], 'failed');
        expect(sc['exitCode'], 9009);
        expect(sc.containsKey('remediation'), isFalse);
        expect(sc.containsKey('errorCode'), isFalse);
        expect(h.refreshCalls, isEmpty);

        // Unknown command on exec_spawn_failed preserves exec_spawn_failed without remediation.
        h.launcher.failNextSpawn = true;
        final spawnRes = await h.call('exec.run', <String, Object?>{
          'command': 'frobnicate_missing_cli --help',
          'cwd': h.workspace.path,
        }, withR3Approval: true);
        expect(_status(spawnRes), 'failed');
        expect(_error(spawnRes), 'exec_spawn_failed');
        expect(_sc(spawnRes).containsKey('remediation'), isFalse);
      },
    );

    test(
      'exec.run normal non-zero exit (exit 2) does not trigger toolchain_missing',
      () async {
        h.launcher.onStart = (handle) {
          handle.emit('unit test failed\n');
          handle.exit(2);
        };
        final res = await h.call('exec.run', <String, Object?>{
          'command': 'npm test',
          'cwd': h.workspace.path,
        });
        expect(_status(res), 'ok');
        final sc = _sc(res);
        expect(sc['status'], 'failed');
        expect(sc['exitCode'], 2);
        expect(sc.containsKey('remediation'), isFalse);
        expect(h.refreshCalls, isEmpty);
      },
    );

    test('exec.run successful package install triggers forceRefresh', () async {
      h.launcher.onStart = (handle) {
        handle.emit('added 1 package\n');
        handle.exit(0);
      };
      final res = await h.call('exec.run', <String, Object?>{
        'command': 'npm install -g typescript',
        'cwd': h.workspace.path,
      }, withR3Approval: true);
      expect(_status(res), 'ok');
      expect(_sc(res)['status'], 'completed');
      expect(h.refreshCalls, equals(const <bool>[true]));
    });

    test(
      'workspace.open missing known IDE preserves ide_not_found + structuredContent.remediation',
      () async {
        for (final ide in const <String>[
          'cursor',
          'vscode',
          'antigravity',
          'auto',
        ]) {
          final res = await h.call('workspace.open', <String, Object?>{
            'project': 'sample_ws',
            'ide': ide,
          });
          expect(res['isError'], isTrue);
          expect(_status(res), 'unsupported');
          expect(_error(res), 'ide_not_found');
          final sc = _sc(res);
          expect(sc['errorCode'], 'ide_not_found');
          final rem = XtpRemediation.fromJson(
            sc['remediation']! as Map<String, Object?>,
          );
          expect(rem.summary, isNotEmpty);
        }
      },
    );

    test(
      'workspace.coding_agent missing known agent preserves coding_agent_not_found + structuredContent.remediation',
      () async {
        final res = await h.call('workspace.coding_agent', <String, Object?>{
          'project': 'sample_ws',
          'agent': 'claude_code',
          'prompt': 'run tests',
        });
        expect(res['isError'], isTrue);
        expect(_status(res), 'unsupported');
        expect(_error(res), 'coding_agent_not_found');
        final sc = _sc(res);
        expect(sc['errorCode'], 'coding_agent_not_found');
        final rem = XtpRemediation.fromJson(
          sc['remediation']! as Map<String, Object?>,
        );
        expect(rem.kind, XtpRemediationKind.install);
        expect(rem.command, equals('npm install -g @anthropic-ai/claude-code'));
      },
    );
  });
}

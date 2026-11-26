import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/presence/host_toolchain_prober.dart';
import 'package:xuna_desktop/features/presence/presence_coordinator.dart';
import 'package:xuna_desktop/features/presence/resource_digest_builder.dart';
import 'package:xuna_desktop/features/presence/subnet_hash.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._outbound);

  final StreamController<String> _outbound;

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
    if (!_outbound.isClosed) {
      await _outbound.close();
    }
  }

  @override
  Future<void> get done => _outbound.done;
}

class _FakeWebSocketChannel extends Fake implements WebSocketChannel {
  _FakeWebSocketChannel() {
    _sink = _FakeWebSocketSink(_outbound);
  }

  final StreamController<Object?> inbound = StreamController<Object?>();
  final StreamController<String> _outbound =
      StreamController<String>.broadcast();
  late final _FakeWebSocketSink _sink;

  Stream<String> get outboundFrames => _outbound.stream;

  @override
  String? get protocol => 'xtp/1';

  @override
  Future<void> get ready => Future<void>.value();

  @override
  WebSocketSink get sink => _sink;

  @override
  Stream<Object?> get stream => inbound.stream;
}

void main() {
  group('HostToolchainProber (P1.2 / U4)', () {
    test(
      'probes curated tools, normalizes versions, strips secrets, unwraps npm.cmd, and omits WindowsApps stubs',
      () async {
        final logger = ContentFreeLogger();
        const files = <String, String>{
          r'C:\Program Files\Git\cmd\git.exe': 'bin',
          r'C:\Program Files\nodejs\node.exe': 'bin',
          r'C:\Program Files\nodejs\npm.cmd':
              '@ECHO OFF\r\nSET "NPM_CLI_JS=%~dp0\\node_modules\\npm\\bin\\npm-cli.js"\r\n',
          r'C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js': '// npm',
          r'C:\Python312\python.exe': 'bin',
          r'C:\Users\owner\AppData\Local\Microsoft\WindowsApps\python3.exe':
              'alias-stub',
          r'C:\tools\go.exe': 'bin',
          r'C:\tools\cargo.exe': 'bin',
          r'C:\tools\docker.exe': 'bin',
          r'C:\tools\gh.exe': 'bin',
          r'C:\tools\rg.exe': 'bin',
          r'C:\tools\ffmpeg.exe': 'bin',
          r'C:\tools\soffice.exe': 'bin',
        };
        final env = <String, String>{
          'PATH':
              r'C:\Program Files\Git\cmd;C:\Program Files\nodejs;C:\Python312;'
              r'C:\Users\owner\AppData\Local\Microsoft\WindowsApps;C:\tools',
          'PATHEXT': '.COM;.EXE;.BAT;.CMD',
          'XUNA_SECRET_TOKEN': 'sk-super-secret-value-123456',
          'OPENAI_API_KEY': 'sk-openai-secret-1234567890',
        };

        final executedCommands = <String>[];
        final seenEnvs = <Map<String, String>>[];

        final prober = HostToolchainProber(
          isWindows: true,
          isMacOs: false,
          logger: logger,
          environmentProvider: () => env,
          fileExists: files.containsKey,
          readFile: (p) => files[p],
          processRunner: (command, {required environment, required timeout}) async {
            executedCommands.add(
              '${command.executable} ${command.args.join(' ')}',
            );
            seenEnvs.add(environment);
            if (command.executable.endsWith('git.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'git version 2.55.0.windows.3\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('node.exe') &&
                command.args.contains('--version') &&
                !command.args.any((a) => a.contains('npm-cli.js'))) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'v22.11.0\r\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('node.exe') &&
                command.args.any((a) => a.endsWith('npm-cli.js'))) {
              expect(command.usesCmdShell, isFalse);
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: '10.9.0\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('python.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'Python 3.12.10\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith(r'\go.exe')) {
              expect(command.args, equals(const <String>['version']));
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'go version go1.23.4 windows/amd64\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith(r'\cargo.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'cargo 1.83.0 (5ffbef321 2024-10-29)\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('docker.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'Docker version 27.3.1, build ce12230\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('gh.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout:
                    'gh version 2.63.2 (2024-12-05)\nhttps://github.com/cli/cli\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('rg.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'ripgrep 14.1.1\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('ffmpeg.exe')) {
              expect(command.args, equals(const <String>['-version']));
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout:
                    'ffmpeg version 7.1-essentials_build-www.gyan.dev Copyright (c) 2000-2024\n'
                    'configuration: --prefix=/opt/homebrew/Cellar/ffmpeg/7.1\n',
                stderr: '',
              );
            }
            if (command.executable.endsWith('soffice.exe')) {
              return const ToolchainCommandOutput(
                exitCode: 0,
                stdout: 'LibreOffice 24.8.3.2 48a6bacd27e49\n',
                stderr: '',
              );
            }
            return const ToolchainCommandOutput(
              exitCode: 1,
              stdout: '',
              stderr: 'unexpected',
            );
          },
        );

        final probed = await prober.probe();
        final byId = <String, String>{for (final t in probed) t.id: t.version};

        expect(
          probed.map((e) => e.id).toList(),
          equals(<String>[
            'cargo',
            'docker',
            'ffmpeg',
            'gh',
            'git',
            'go',
            'node',
            'npm',
            'python',
            'rg',
            'soffice',
          ]),
        );
        expect(byId['git'], '2.55.0.windows.3');
        expect(byId['node'], '22.11.0');
        expect(byId['npm'], '10.9.0');
        expect(byId['python'], '3.12.10');
        expect(byId['go'], '1.23.4');
        expect(byId['cargo'], '1.83.0');
        expect(byId['docker'], '27.3.1');
        expect(byId['gh'], '2.63.2');
        expect(byId['rg'], '14.1.1');
        expect(byId['ffmpeg'], '7.1');
        expect(byId['soffice'], '24.8.3.2');

        // WindowsApps stub (python3.exe) was never executed and is omitted.
        expect(byId.containsKey('python3'), isFalse);
        expect(
          executedCommands.any((c) => c.toLowerCase().contains('windowsapps')),
          isFalse,
        );
        // Secret env vars were stripped before probing.
        for (final childEnv in seenEnvs) {
          expect(childEnv.containsKey('XUNA_SECRET_TOKEN'), isFalse);
          expect(childEnv.containsKey('OPENAI_API_KEY'), isFalse);
        }
        // Logs remain strictly content-free (no paths, args, or stdout).
        final serializedLogs = jsonEncode([
          for (final e in logger.entries)
            <String, Object?>{'event': e.event, 'fields': e.fields},
        ]);
        expect(serializedLogs, isNot(contains('Program Files')));
        expect(serializedLogs, isNot(contains('2.55.0')));
        expect(serializedLogs, isNot(contains('sk-')));
      },
    );

    test(
      'fails closed on non-zero exit (9009/49/1), timeouts (>1500ms), overall budget, and malicious path stdout',
      () async {
        const files = <String, String>{
          '/usr/local/bin/git': 'bin',
          '/usr/local/bin/node': 'bin',
          '/usr/local/bin/python': 'bin',
          '/usr/local/bin/python3': 'bin',
          '/usr/local/bin/dart': 'bin',
          '/usr/local/bin/flutter': 'bin',
          '/usr/local/bin/go': 'bin',
          '/usr/local/bin/cargo': 'bin',
          '/usr/local/bin/docker': 'bin',
        };
        final prober = HostToolchainProber(
          isWindows: false,
          isMacOs: true,
          perToolTimeout: const Duration(milliseconds: 60),
          overallBudget: const Duration(milliseconds: 300),
          environmentProvider: () => const <String, String>{
            'PATH': '/usr/local/bin',
            'HOME': '/Users/owner',
          },
          fileExists: files.containsKey,
          dirExists: (_) => false,
          processRunner:
              (command, {required environment, required timeout}) async {
                final bin = command.executable.split('/').last;
                return switch (bin) {
                  'git' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'git version 2.47.1\n',
                    stderr: '',
                  ),
                  'node' => const ToolchainCommandOutput(
                    exitCode: 9009,
                    stdout: 'v22.11.0',
                    stderr: '',
                  ),
                  'python' => const ToolchainCommandOutput(
                    exitCode: 49,
                    stdout: 'Python 3.12.0',
                    stderr: '',
                  ),
                  'python3' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: '/Users/owner/bin/python3\n',
                    stderr: '',
                  ),
                  'dart' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: r'C:\Users\owner\dart\3.11.0\dart.exe',
                    stderr: '',
                  ),
                  'flutter' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'Flutter 1.0..2\n',
                    stderr: '',
                  ),
                  'go' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'hello world without version\n',
                    stderr: '',
                  ),
                  'cargo' => await () async {
                    // Exceeds perToolTimeout (60ms)
                    await Future<void>.delayed(
                      const Duration(milliseconds: 120),
                    );
                    return const ToolchainCommandOutput(
                      exitCode: 0,
                      stdout: 'cargo 1.83.0\n',
                      stderr: '',
                    );
                  }(),
                  'docker' => const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'Docker version 27.3.1 (D:/tools/docker.exe)\n',
                    stderr: '',
                  ),
                  _ => const ToolchainCommandOutput(
                    exitCode: 1,
                    stdout: '',
                    stderr: '',
                  ),
                };
              },
        );

        final probed = await prober.probe();
        // Only git passes strict validation and completes before timeout.
        expect(
          probed,
          equals(const <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
          ]),
        );

        final serialized = jsonEncode(
          probed.map((e) => e.toJson()).toList(growable: false),
        );
        expect(serialized, isNot(contains('/Users')));
        expect(serialized, isNot(contains(r'C:\')));
        expect(serialized, isNot(contains('D:/')));
      },
    );

    test(
      'enforces maxConcurrency = 4, overall budget cutoff, deduplication, sorting, and 64-entry cap',
      () async {
        var inFlight = 0;
        var maxObservedInFlight = 0;

        final specs = List<HostToolchainSpec>.generate(
          70,
          (i) => HostToolchainSpec(
            id: 'tool_${(70 - i).toString().padLeft(2, '0')}',
            binaryName: 'tool_${(70 - i).toString().padLeft(2, '0')}',
            versionArgs: const <String>['--version'],
          ),
        );
        // Add a duplicate id to verify deduplication.
        specs.add(
          const HostToolchainSpec(
            id: 'tool_01',
            binaryName: 'tool_01',
            versionArgs: <String>['--version'],
          ),
        );

        final prober = HostToolchainProber(
          specs: specs,
          isWindows: false,
          isMacOs: false,
          maxConcurrency: 4,
          perToolTimeout: const Duration(milliseconds: 500),
          overallBudget: const Duration(milliseconds: 2000),
          environmentProvider: () => const <String, String>{'PATH': '/usr/bin'},
          fileExists: (p) => p.startsWith('/usr/bin/tool_'),
          processRunner:
              (command, {required environment, required timeout}) async {
                inFlight++;
                if (inFlight > maxObservedInFlight) {
                  maxObservedInFlight = inFlight;
                }
                await Future<void>.delayed(const Duration(milliseconds: 5));
                inFlight--;
                return const ToolchainCommandOutput(
                  exitCode: 0,
                  stdout: '1.2.3\n',
                  stderr: '',
                );
              },
        );

        final probed = await prober.probe();
        expect(maxObservedInFlight, lessThanOrEqualTo(4));
        expect(maxObservedInFlight, greaterThanOrEqualTo(2));
        expect(probed, hasLength(64));
        expect(probed.first.id, 'tool_01');
        expect(probed.last.id, 'tool_64');
        expect(probed.map((e) => e.id).toSet(), hasLength(64));

        // Verify overall budget stops probing remaining queued tools.
        final slowProber = HostToolchainProber(
          specs: specs.take(12).toList(),
          isWindows: false,
          isMacOs: false,
          maxConcurrency: 2,
          perToolTimeout: const Duration(milliseconds: 200),
          overallBudget: const Duration(milliseconds: 35),
          environmentProvider: () => const <String, String>{'PATH': '/usr/bin'},
          fileExists: (_) => true,
          processRunner: (_, {required environment, required timeout}) async {
            await Future<void>.delayed(const Duration(milliseconds: 80));
            return const ToolchainCommandOutput(
              exitCode: 0,
              stdout: '1.0.0\n',
              stderr: '',
            );
          },
        );
        final timedOutAll = await slowProber.probe();
        expect(timedOutAll, isEmpty);
      },
    );

    test(
      'rejects WindowsApps resolved executable even if injected into PATH lookup',
      () {
        final resolved = HostToolchainProber.resolveToolchainCommand(
          const HostToolchainSpec(
            id: 'python3',
            binaryName: 'python3',
            versionArgs: <String>['--version'],
          ),
          environment: const <String, String>{
            'PATH': r'C:\Users\owner\AppData\Local\Microsoft\WindowsApps',
            'PATHEXT': '.EXE',
          },
          isWindows: true,
          isMacOs: false,
          fileExists: (p) =>
              p ==
              r'C:\Users\owner\AppData\Local\Microsoft\WindowsApps\python3.exe',
        );
        expect(resolved, isNull);
      },
    );

    test(
      'normalizeToolchainVersion rejects path strings, dots, whitespace, control chars, and >32 chars',
      () {
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            'Flutter 3.41.1 • channel stable • https://github.com/flutter/flutter.git',
            toolId: 'flutter',
          ),
          '3.41.1',
        );
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            'Dart SDK version: 3.11.0 (stable) on "windows_x64"',
            toolId: 'dart',
          ),
          '3.11.0',
        );
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            r'C:\Users\owner\1.2.3\tool.exe',
            toolId: 'node',
          ),
          isNull,
        );
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            '/usr/local/bin/node',
            toolId: 'node',
          ),
          isNull,
        );
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            '1.2..3',
            toolId: 'node',
          ),
          isNull,
        );
        expect(
          HostToolchainProber.normalizeToolchainVersion(
            '1.${'0' * 31}-extra',
            toolId: 'node',
          ),
          isNull,
        );
      },
    );

    test(
      'live OS prober returns strictly validated, path-free entries within budget',
      () async {
        final prober = HostToolchainProber(
          specs: const <HostToolchainSpec>[
            HostToolchainSpec(
              id: 'git',
              binaryName: 'git',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'node',
              binaryName: 'node',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'npm',
              binaryName: 'npm',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'python',
              binaryName: 'python',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'python3',
              binaryName: 'python3',
              versionArgs: <String>['--version'],
            ),
          ],
        );
        final probed = await prober.probe();
        for (final entry in probed) {
          entry.validate();
          expect(entry.version, isNot(contains('/')));
          expect(entry.version, isNot(contains(r'\')));
        }
        // On Windows, if python3 only resolves to Microsoft\WindowsApps alias,
        // it must fail closed and stay absent.
        if (Platform.isWindows) {
          final rawPath = Platform.environment['PATH'] ?? '';
          final nonAliasPython3 = rawPath
              .split(';')
              .map((d) => d.trim())
              .where(
                (d) =>
                    d.isNotEmpty &&
                    !HostToolchainProber.isWindowsStoreAppAliasPath(d),
              )
              .any((d) => File('$d\\python3.exe').existsSync());
          if (!nonAliasPython3) {
            expect(probed.any((e) => e.id == 'python3'), isFalse);
          }
        }
      },
    );
  });

  group('ResourceDigestBuilder & PresenceCoordinator toolchain lifecycle', () {
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
      tempDir = await Directory.systemTemp.createTemp('xuna_tc_presence_');
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
        alias: 'Win-Dev',
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
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test(
      'keeps empty-toolchains capabilitiesVersion identical and updates hash when toolchains change',
      () async {
        final appScanner = AutoAppScanner(
          seedApps: const <DiscoveredApp>[
            DiscoveredApp(
              id: 'vscode',
              name: 'VS Code',
              kind: AppLaunchKind.exe,
              target: r'C:\Program Files\Code\Code.exe',
            ),
          ],
          scanFileSystem: false,
        );
        final wsIndexer = AutoWorkspaceIndexer(
          seedWorkspaces: <DiscoveredWorkspace>[
            DiscoveredWorkspace(
              alias: 'xuna_pet',
              path: tempDir.path,
              lastModified: DateTime.utc(2026, 11, 26),
            ),
          ],
          scanDefaultLocations: false,
        );

        final legacyBuilder = ResourceDigestBuilder(
          appScanner: appScanner,
          workspaceIndexer: wsIndexer,
        );
        final legacyDigest = legacyBuilder.build();

        var includeNode = false;
        final prober = HostToolchainProber(
          specs: const <HostToolchainSpec>[
            HostToolchainSpec(
              id: 'git',
              binaryName: 'git',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'node',
              binaryName: 'node',
              versionArgs: <String>['--version'],
            ),
          ],
          isWindows: false,
          isMacOs: false,
          environmentProvider: () => const <String, String>{'PATH': '/usr/bin'},
          fileExists: (p) =>
              p == '/usr/bin/git' || (includeNode && p == '/usr/bin/node'),
          processRunner:
              (command, {required environment, required timeout}) async {
                if (command.executable.endsWith('/git')) {
                  return const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'git version 2.47.1\n',
                    stderr: '',
                  );
                }
                if (includeNode && command.executable.endsWith('/node')) {
                  return const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'v22.11.0\n',
                    stderr: '',
                  );
                }
                return const ToolchainCommandOutput(
                  exitCode: 1,
                  stdout: '',
                  stderr: '',
                );
              },
        );

        final builder = ResourceDigestBuilder(
          appScanner: appScanner,
          workspaceIndexer: wsIndexer,
          toolchainProber: prober,
        );

        // Before probing, cachedToolchains is empty -> hash matches legacy.
        final beforeProbe = builder.build();
        expect(beforeProbe.toolchains, isEmpty);
        expect(
          beforeProbe.capabilitiesVersion,
          equals(legacyDigest.capabilitiesVersion),
        );
        expect(
          beforeProbe.toResourcesParams().toJson().containsKey('toolchains'),
          isFalse,
        );

        // Probe git -> capabilitiesVersion changes.
        await prober.probe();
        final withGit = builder.build();
        expect(
          withGit.toolchains,
          equals(const <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
          ]),
        );
        expect(
          withGit.capabilitiesVersion,
          isNot(equals(legacyDigest.capabilitiesVersion)),
        );

        // Refresh after node installed -> capabilitiesVersion changes again.
        includeNode = true;
        await prober.probe(forceRefresh: true);
        final withGitAndNode = builder.build();
        expect(
          withGitAndNode.toolchains,
          equals(const <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
            XtpToolchainEntry(id: 'node', version: '22.11.0'),
          ]),
        );
        expect(
          withGitAndNode.capabilitiesVersion,
          isNot(equals(withGit.capabilitiesVersion)),
        );
      },
    );

    test(
      'PresenceCoordinator publishes async startup warmUpToolchains, reconnect re-probe, and forceRefresh deltas',
      () async {
        final ws = _FakeWebSocketChannel();
        final sentResources = <ResourcesParams>[];
        final sub = ws.outboundFrames.listen((raw) {
          final frame = XtpFrame.parse(raw);
          if (frame is XtpNotification && frame.method == 'xuna/resources') {
            sentResources.add(frame.typedParams as ResourcesParams);
          }
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

        var hasNode = false;
        final gate = Completer<void>();
        final prober = HostToolchainProber(
          specs: const <HostToolchainSpec>[
            HostToolchainSpec(
              id: 'git',
              binaryName: 'git',
              versionArgs: <String>['--version'],
            ),
            HostToolchainSpec(
              id: 'node',
              binaryName: 'node',
              versionArgs: <String>['--version'],
            ),
          ],
          isWindows: false,
          isMacOs: false,
          environmentProvider: () => const <String, String>{'PATH': '/usr/bin'},
          fileExists: (p) =>
              p == '/usr/bin/git' || (hasNode && p == '/usr/bin/node'),
          processRunner:
              (command, {required environment, required timeout}) async {
                if (!gate.isCompleted) {
                  await gate.future;
                }
                if (command.executable.endsWith('/git')) {
                  return const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'git version 2.47.1\n',
                    stderr: '',
                  );
                }
                if (hasNode && command.executable.endsWith('/node')) {
                  return const ToolchainCommandOutput(
                    exitCode: 0,
                    stdout: 'v22.11.0\n',
                    stderr: '',
                  );
                }
                return const ToolchainCommandOutput(
                  exitCode: 1,
                  stdout: '',
                  stderr: '',
                );
              },
        );

        final coordinator = PresenceCoordinator(
          channel: channel,
          sessionClient: client,
          resourceDigestBuilder: ResourceDigestBuilder(
            appScanner: AutoAppScanner(scanFileSystem: false),
            workspaceIndexer: AutoWorkspaceIndexer(scanDefaultLocations: false),
            toolchainProber: prober,
          ),
          subnetHashCalculator: SubnetHashCalculator(
            interfaceLister: () async => const <NetworkInterface>[],
          ),
          logger: logger,
          deltaPollInterval: const Duration(hours: 1),
          resourceDebounceDuration: const Duration(milliseconds: 20),
        );
        addTearDown(coordinator.dispose);

        // Start async warm-up before connecting (does not block).
        final warmUpFuture = coordinator.warmUpToolchains();

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
        await Future<void>.delayed(const Duration(milliseconds: 15));
        ws.inbound.add(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/ready',
            'params': <String, Object?>{
              'serverTime': '2026-11-26T07:00:00Z',
              'heartbeatS': 30,
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 20));

        // Initial ready publishes immediately with empty cached toolchains.
        expect(sentResources, hasLength(1));
        expect(sentResources.first.toolchains, isEmpty);

        // Unblock probe -> updated xuna/resources with git is published automatically.
        gate.complete();
        await warmUpFuture;
        await Future<void>.delayed(const Duration(milliseconds: 30));

        expect(sentResources.length, greaterThanOrEqualTo(2));
        expect(
          sentResources.last.toolchains,
          equals(const <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
          ]),
        );

        // Install node and trigger scheduleResourcesPublish(forceRefresh: true).
        final countBeforeRefresh = sentResources.length;
        hasNode = true;
        coordinator.scheduleResourcesPublish(forceRefresh: true);
        await Future<void>.delayed(const Duration(milliseconds: 60));

        expect(sentResources.length, equals(countBeforeRefresh + 1));
        expect(
          sentResources.last.toolchains,
          equals(const <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
            XtpToolchainEntry(id: 'node', version: '22.11.0'),
          ]),
        );
      },
    );
  });
}

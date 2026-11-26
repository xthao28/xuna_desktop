import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/exec/fs_undo_journal.dart';
import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_desktop/features/exec/windows_kernel32_ffi.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'exec_test_support.dart';

typedef _CreateFileWN =
    IntPtr Function(
      Pointer<Uint16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileWFn =
    int Function(Pointer<Uint16>, int, int, Pointer<Void>, int, int, int);

/// Opens [path] with Win32 `CreateFileW(GENERIC_READ, FILE_SHARE_READ, OPEN_EXISTING)`
/// (no `FILE_SHARE_DELETE`), holding a real Windows replace-blocking read lock
/// until the returned close callback is invoked.
void Function() _acquireWindowsReadLock(String path) {
  final lib = DynamicLibrary.open('kernel32.dll');
  final createFileW = lib.lookupFunction<_CreateFileWN, _CreateFileWFn>(
    'CreateFileW',
  );
  final k32 = WinKernel32.instance;
  final nativePath = path.replaceAll('/', r'\');
  final ptr = k32.allocUtf16(encodeUtf16NullTerminated(nativePath));
  const genericRead = 0x80000000;
  const fileShareRead = 0x00000001;
  const openExisting = 3;
  const fileAttributeNormal = 0x00000080;
  final handle = createFileW(
    ptr,
    genericRead,
    fileShareRead,
    nullptr,
    openExisting,
    fileAttributeNormal,
    0,
  );
  k32.free(ptr);
  if (handle == -1 || handle == 0) {
    throw StateError('CreateFileW failed to acquire lock on $path');
  }
  return () => k32.closeHandle(handle);
}

String _sha256(String text) => sha256.convert(utf8.encode(text)).toString();

class _UndoHarness {
  _UndoHarness({
    required this.dir,
    required this.workspace,
    required this.paths,
    required this.logger,
    required this.channel,
    required this.store,
    required this.auditStore,
    required this.stop,
    required this.journal,
    required this.dispatcher,
  });

  final Directory dir;
  final Directory workspace;
  final AgentPaths paths;
  final ContentFreeLogger logger;
  final FakeXunaHostChannel channel;
  final HostPolicyStore store;
  final AuditLogStore auditStore;
  final EmergencyStopController stop;
  final FsUndoJournal journal;
  final HostToolDispatcher dispatcher;
  int _id = 1;

  static Future<_UndoHarness> create({
    int maxTotalBytes = FsUndoJournal.defaultMaxTotalBytes,
    int maxPerFileBytes = FsUndoJournal.defaultMaxPerFileBytes,
    int maxTransactions = FsUndoJournal.defaultMaxTransactions,
    Duration ttl = FsUndoJournal.defaultTtl,
    AtomicFileReplacer? replaceFile,
  }) async {
    final dir = await Directory.systemTemp.createTemp('xuna_w4m1_');
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
          ToolFamily.app: FamilyPolicyDecision.allow,
          ToolFamily.media: FamilyPolicyDecision.allow,
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
    final channel = FakeXunaHostChannel();
    final auditStore = AuditLogStore(auditDir: paths.auditDir);
    final stop = EmergencyStopController(logger: logger);
    final journal = FsUndoJournal(
      rootDir: paths.undoDir,
      logger: logger,
      maxTotalBytes: maxTotalBytes,
      maxPerFileBytes: maxPerFileBytes,
      maxTransactions: maxTransactions,
      ttl: ttl,
      replaceFile: replaceFile,
    );
    final dispatcher = _buildDispatcher(
      store: store,
      channel: channel,
      auditStore: auditStore,
      stop: stop,
      logger: logger,
      journal: journal,
    );
    return _UndoHarness(
      dir: dir,
      workspace: workspace,
      paths: paths,
      logger: logger,
      channel: channel,
      store: store,
      auditStore: auditStore,
      stop: stop,
      journal: journal,
      dispatcher: dispatcher,
    );
  }

  static HostToolDispatcher _buildDispatcher({
    required HostPolicyStore store,
    required FakeXunaHostChannel channel,
    required AuditLogStore auditStore,
    required EmergencyStopController stop,
    required ContentFreeLogger logger,
    required FsUndoJournal journal,
  }) {
    return HostToolDispatcher(
      policyStore: store,
      channel: channel,
      auditStore: auditStore,
      stopController: stop,
      logger: logger,
      appScanner: AutoAppScanner(
        scanFileSystem: false,
        seedApps: const <DiscoveredApp>[],
      ),
      execRegistry: ExecProcessRegistry(
        stopController: stop,
        launcher: FakeExecLauncher(),
        pollInterval: const Duration(milliseconds: 5),
      ),
      fsUndoJournal: journal,
    );
  }

  ShellControlPolicy get shellControl => store.evaluator.policy!.shellControl;

  String ws(String rel) => '${workspace.path}/$rel'.replaceAll(r'\', '/');

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> args, {
    DateTime? nowUtc,
    HostToolDispatcher? via,
  }) async {
    final target = via ?? dispatcher;
    final res = await target.dispatch(
      requestId: _id++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId:
            'f1000000-0000-4000-8000-${_id.toString().padLeft(12, '0')}',
        deadlineMs: 15000,
      ),
      nowUtc: nowUtc,
    );
    XtpFrame.parse(res.encode());
    return res.result;
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }
}

String? _status(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/status'] as String?;
String? _error(Map<String, Object?> r) =>
    (r['_meta'] as Map)['xuna/errorCode'] as String?;
Map<String, Object?> _sc(Map<String, Object?> r) =>
    (r['structuredContent'] as Map).cast<String, Object?>();

void main() {
  group('AgentPaths.undoDir (ADR-0019 §1)', () {
    test('uses LOCALAPPDATA on Windows and Application Support on macOS', () {
      final winPaths = AgentPaths.resolve(
        environment: const <String, String>{
          'APPDATA': r'C:\Users\Owner\AppData\Roaming',
          'LOCALAPPDATA': r'C:\Users\Owner\AppData\Local',
        },
        isWindowsOverride: true,
      );
      expect(
        winPaths.undoDir.path.replaceAll('/', r'\'),
        r'C:\Users\Owner\AppData\Local\XUNA\undo',
      );
      expect(winPaths.undoDir.path, isNot(contains(winPaths.auditDir.path)));

      final macPaths = AgentPaths.resolve(
        environment: const <String, String>{'HOME': '/Users/owner'},
        isWindowsOverride: false,
      );
      expect(
        macPaths.undoDir.path.replaceAll(r'\', '/'),
        '/Users/owner/Library/Application Support/XUNA/undo',
      );
    });

    test('stays inside overrideRootDir for test isolation', () {
      final root = Directory('/tmp/xuna_test_root');
      final paths = AgentPaths.resolve(overrideRootDir: root);
      expect(
        paths.undoDir.path.replaceAll(r'\', '/'),
        '/tmp/xuna_test_root/undo',
      );
    });
  });

  group('FsUndoJournal core WAL, TOCTOU, crash recovery & locks', () {
    late _UndoHarness h;
    setUp(() async => h = await _UndoHarness.create());
    tearDown(() => h.dispose());

    test('exposes approved M1-1 Option A default limits', () {
      expect(FsUndoJournal.defaultMaxTotalBytes, 32 * 1024 * 1024);
      expect(FsUndoJournal.defaultMaxPerFileBytes, 2 * 1024 * 1024);
      expect(FsUndoJournal.defaultMaxTransactions, 20);
      expect(FsUndoJournal.defaultTtl, const Duration(minutes: 30));
    });

    test(
      'multi-file apply (modify/create/delete) and undo restore exact SHA-256',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('alpha-v0\n');
        final b = File(h.ws('b.txt'))..writeAsStringSync('beta-v0\n');
        final c = File(h.ws('c.txt'));
        final d = File(h.ws('d.txt'))..writeAsStringSync('delta-v0\n');
        final aPre = _sha256('alpha-v0\n');
        final bPre = _sha256('beta-v0\n');
        final dPre = _sha256('delta-v0\n');
        final t0 = DateTime.utc(2026, 11, 26, 10, 0, 0);

        final applied = await h.journal.applyTransaction(
          toolName: 'draft.apply',
          changes: <FsPlannedChange>[
            FsPlannedChange(
              path: a.path,
              newBytes: utf8.encode('alpha-v1\n'),
              expectedPreSha256: aPre,
            ),
            FsPlannedChange(
              path: b.path,
              newBytes: utf8.encode('beta-v1\n'),
              expectedPreSha256: bPre,
            ),
            FsPlannedChange(
              path: c.path,
              newBytes: utf8.encode('gamma-new\n'),
              expectNotExists: true,
            ),
            FsPlannedChange(
              path: d.path,
              newBytes: null,
              expectedPreSha256: dPre,
            ),
          ],
          shellControl: h.shellControl,
          nowUtc: t0,
        );

        expect(applied.files, hasLength(4));
        expect(a.readAsStringSync(), 'alpha-v1\n');
        expect(b.readAsStringSync(), 'beta-v1\n');
        expect(c.readAsStringSync(), 'gamma-new\n');
        expect(d.existsSync(), isFalse);
        expect(
          h.workspace.listSync().where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );

        final undone = await h.journal.undoTransaction(
          txId: applied.txId,
          shellControl: h.shellControl,
          nowUtc: t0.add(const Duration(minutes: 1)),
        );
        expect(undone.filesRestored, 3);
        expect(undone.filesDeleted, 1);
        expect(_sha256(a.readAsStringSync()), aPre);
        expect(_sha256(b.readAsStringSync()), bPre);
        expect(c.existsSync(), isFalse);
        expect(_sha256(d.readAsStringSync()), dPre);
        expect(
          h.journal.peekLatestCommitted(t0.add(const Duration(minutes: 2))),
          isNull,
        );
      },
    );

    test(
      'TOCTOU mismatch rejects before touching any file or writing journal',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('a-orig');
        final b = File(h.ws('b.txt'))..writeAsStringSync('b-orig');
        final staleBSha = _sha256('b-orig');
        // External modification before apply:
        b.writeAsStringSync('b-external-edit');

        await expectLater(
          () => h.journal.applyTransaction(
            toolName: 'draft.apply',
            changes: <FsPlannedChange>[
              FsPlannedChange(path: a.path, newBytes: utf8.encode('a-new')),
              FsPlannedChange(
                path: b.path,
                newBytes: utf8.encode('b-new'),
                expectedPreSha256: staleBSha,
              ),
              FsPlannedChange(
                path: h.ws('c.txt'),
                newBytes: utf8.encode('c-new'),
              ),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'toctou_mismatch',
            ),
          ),
        );

        expect(a.readAsStringSync(), 'a-orig');
        expect(b.readAsStringSync(), 'b-external-edit');
        expect(File(h.ws('c.txt')).existsSync(), isFalse);
        expect(h.paths.undoDir.listSync(), isEmpty);
      },
    );

    test(
      'startup crash recovery rolls back applying journal and removes stray tmp',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('a-orig');
        final b = File(h.ws('b.txt'))..writeAsStringSync('b-orig');
        final c = File(h.ws('c.txt'))..writeAsStringSync('c-partial-created');
        final strayTmp = File(h.ws('.a.txt.xuna-deadbeef.tmp'))
          ..writeAsStringSync('half-written');
        final aPre = _sha256('a-orig');
        final bPre = _sha256('b-orig');

        // Simulate crash after file 1 (a.txt) was overwritten and c.txt was created,
        // while b.txt was untouched and journal remained in `applying`.
        a.writeAsStringSync('a-mutated-before-crash');
        final txDir = Directory(
          '${h.paths.undoDir.path}/tx-1764151200000-000001-abcd1234',
        )..createSync(recursive: true);
        File('${txDir.path}/bak_0.bin').writeAsStringSync('a-orig');
        File('${txDir.path}/bak_1.bin').writeAsStringSync('b-orig');
        final crashedRecord = FsJournalRecord(
          schemaVersion: 1,
          txId: 'tx-1764151200000-000001-abcd1234',
          toolName: 'draft.apply',
          state: FsJournalState.applying,
          createdAt: DateTime.utc(2026, 11, 26, 10, 0, 0),
          expiresAt: DateTime.utc(2026, 11, 26, 10, 30, 0),
          totalBackupBytes: 12,
          entries: <FsJournalFileEntry>[
            FsJournalFileEntry(
              path: a.path.replaceAll(r'\', '/'),
              op: FsChangeOp.modify,
              existed: true,
              preSha256: aPre,
              postSha256: _sha256('a-mutated-before-crash'),
              backupFile: 'bak_0.bin',
              backupBytes: 6,
            ),
            FsJournalFileEntry(
              path: b.path.replaceAll(r'\', '/'),
              op: FsChangeOp.modify,
              existed: true,
              preSha256: bPre,
              postSha256: _sha256('b-never-written'),
              backupFile: 'bak_1.bin',
              backupBytes: 6,
            ),
            FsJournalFileEntry(
              path: c.path.replaceAll(r'\', '/'),
              op: FsChangeOp.create,
              existed: false,
              preSha256: null,
              postSha256: _sha256('c-partial-created'),
              backupFile: null,
              backupBytes: 0,
            ),
          ],
        );
        File(
          '${txDir.path}/journal.json',
        ).writeAsStringSync(jsonEncode(crashedRecord.toJson()));

        // Fresh journal instance simulating process restart:
        final restarted = FsUndoJournal(
          rootDir: h.paths.undoDir,
          logger: h.logger,
        );
        final report = await restarted.recoverAndPruneOnStartup(
          nowUtc: DateTime.utc(2026, 11, 26, 10, 5, 0),
        );
        expect(report.recoveredCount, 1);
        expect(report.failedRecoveryCount, 0);
        expect(a.readAsStringSync(), 'a-orig');
        expect(b.readAsStringSync(), 'b-orig');
        expect(c.existsSync(), isFalse);
        expect(strayTmp.existsSync(), isFalse);
        expect(txDir.existsSync(), isFalse);
      },
    );

    test(
      'injected lock error on file 2/3 rolls back file 1 without touching locked file 2',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('a-v0');
        final b = File(h.ws('b.txt'))..writeAsStringSync('b-v0');
        final replacedTargets = <String>[];

        final lockedJournal = FsUndoJournal(
          rootDir: h.paths.undoDir,
          logger: h.logger,
          replaceFile: (tmp, dst) {
            final normDst = dst.replaceAll(r'\', '/');
            replacedTargets.add(normDst);
            if (normDst.endsWith('/b.txt')) {
              throw const AtomicReplaceException(
                osErrorCode: winErrorAccessDenied,
                isLocked: true,
              );
            }
            defaultAtomicReplaceFile(tmp, dst);
          },
        );

        await expectLater(
          () => lockedJournal.applyTransaction(
            toolName: 'draft.apply',
            changes: <FsPlannedChange>[
              FsPlannedChange(path: a.path, newBytes: utf8.encode('a-v1')),
              FsPlannedChange(path: b.path, newBytes: utf8.encode('b-v1')),
              FsPlannedChange(
                path: h.ws('c.txt'),
                newBytes: utf8.encode('c-v1'),
              ),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'fs_file_locked',
            ),
          ),
        );

        expect(a.readAsStringSync(), 'a-v0');
        expect(b.readAsStringSync(), 'b-v0');
        expect(File(h.ws('c.txt')).existsSync(), isFalse);
        // Rollback must NOT attempt a second replace on untouched locked b.txt!
        expect(
          replacedTargets.where((p) => p.endsWith('/b.txt')).length,
          1,
          reason:
              'Spike c C4 invariant: skip untouched file whose SHA matches preSha256',
        );
        expect(h.paths.undoDir.listSync(), isEmpty);
      },
    );

    test(
      'real Windows FILE_SHARE_READ lock on file 2/3 triggers fs_file_locked and clean rollback',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('win-a-orig');
        final b = File(h.ws('b.txt'))..writeAsStringSync('win-b-orig');
        final releaseLock = _acquireWindowsReadLock(b.path);
        try {
          await expectLater(
            () => h.journal.applyTransaction(
              toolName: 'draft.apply',
              changes: <FsPlannedChange>[
                FsPlannedChange(
                  path: a.path,
                  newBytes: utf8.encode('win-a-modified'),
                ),
                FsPlannedChange(
                  path: b.path,
                  newBytes: utf8.encode('win-b-modified'),
                ),
                FsPlannedChange(
                  path: h.ws('c.txt'),
                  newBytes: utf8.encode('win-c-created'),
                ),
              ],
              shellControl: h.shellControl,
            ),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'fs_file_locked',
              ),
            ),
          );
        } finally {
          releaseLock();
        }

        expect(a.readAsStringSync(), 'win-a-orig');
        expect(b.readAsStringSync(), 'win-b-orig');
        expect(File(h.ws('c.txt')).existsSync(), isFalse);
        expect(
          h.workspace.listSync().where((e) => e.path.endsWith('.tmp')),
          isEmpty,
        );
        expect(h.paths.undoDir.listSync(), isEmpty);
      },
      skip: !Platform.isWindows,
    );

    test(
      'fail-closed: refuses secret files, Hard-Deny paths, and outside-workspace targets without writing journal',
      () async {
        final envFile = h.ws('.env');
        final sshFile = h.ws('.ssh/id_rsa');
        final outsideFile = '${h.dir.path}/outside.txt'.replaceAll(r'\', '/');

        expect(
          h.journal.canJournalSingleWrite(
            rawPath: envFile,
            newBytesLength: 10,
            shellControl: h.shellControl,
          ),
          isFalse,
        );
        expect(
          h.journal.canJournalSingleWrite(
            rawPath: sshFile,
            newBytesLength: 10,
            shellControl: h.shellControl,
          ),
          isFalse,
        );
        expect(
          h.journal.canJournalSingleWrite(
            rawPath: outsideFile,
            newBytesLength: 10,
            shellControl: h.shellControl,
          ),
          isFalse,
        );

        await expectLater(
          () => h.journal.applyTransaction(
            toolName: 'fs.write_file',
            changes: <FsPlannedChange>[
              FsPlannedChange(path: envFile, newBytes: utf8.encode('SECRET=1')),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'fs_secret_file_forbidden',
            ),
          ),
        );
        await expectLater(
          () => h.journal.applyTransaction(
            toolName: 'fs.write_file',
            changes: <FsPlannedChange>[
              FsPlannedChange(
                path: outsideFile,
                newBytes: utf8.encode('outside'),
              ),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'fs_outside_workspace',
            ),
          ),
        );
        expect(h.paths.undoDir.listSync(), isEmpty);
      },
    );

    test(
      'fail-closed: symlink resolving outside workspace or to .env is refused',
      () async {
        final outsideReal = '${h.dir.path}/outside_target.txt'.replaceAll(
          r'\',
          '/',
        );
        final envReal = h.ws('.env');
        final symlinkJournal = FsUndoJournal(
          rootDir: h.paths.undoDir,
          logger: h.logger,
          resolveRealPath: (normalized) {
            if (normalized.endsWith('/link_out.txt')) return outsideReal;
            if (normalized.endsWith('/link_env.txt')) return envReal;
            return normalized;
          },
        );

        expect(
          symlinkJournal.canJournalSingleWrite(
            rawPath: h.ws('link_out.txt'),
            newBytesLength: 5,
            shellControl: h.shellControl,
          ),
          isFalse,
        );
        expect(
          symlinkJournal.canJournalSingleWrite(
            rawPath: h.ws('link_env.txt'),
            newBytesLength: 5,
            shellControl: h.shellControl,
          ),
          isFalse,
        );
        await expectLater(
          () => symlinkJournal.applyTransaction(
            toolName: 'fs.write_file',
            changes: <FsPlannedChange>[
              FsPlannedChange(
                path: h.ws('link_out.txt'),
                newBytes: utf8.encode('escape'),
              ),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'fs_outside_workspace',
            ),
          ),
        );
        await expectLater(
          () => symlinkJournal.applyTransaction(
            toolName: 'fs.write_file',
            changes: <FsPlannedChange>[
              FsPlannedChange(
                path: h.ws('link_env.txt'),
                newBytes: utf8.encode('escape'),
              ),
            ],
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'fs_secret_file_forbidden',
            ),
          ),
        );
        expect(h.paths.undoDir.listSync(), isEmpty);
      },
    );

    test(
      'fail-closed: corrupted backup refuses undo without touching workspace',
      () async {
        final a = File(h.ws('a.txt'))..writeAsStringSync('orig-bytes');
        final tx = await h.journal.applyTransaction(
          toolName: 'fs.write_file',
          changes: <FsPlannedChange>[
            FsPlannedChange(path: a.path, newBytes: utf8.encode('new-bytes')),
          ],
          shellControl: h.shellControl,
        );
        // Corrupt backup on disk:
        File(
          '${h.paths.undoDir.path}/${tx.txId}/bak_0.bin',
        ).writeAsStringSync('tampered!');

        await expectLater(
          () => h.journal.undoTransaction(
            txId: tx.txId,
            shellControl: h.shellControl,
          ),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'undo_backup_corrupted',
            ),
          ),
        );
        expect(a.readAsStringSync(), 'new-bytes');
      },
    );
  });

  group('Budget caps, TTL eviction & HostToolDispatcher integration', () {
    test(
      'enforces maxTransactions and maxTotalBytes LRU eviction and 30-min TTL',
      () async {
        final h = await _UndoHarness.create(
          maxTransactions: 3,
          maxTotalBytes: 256,
          maxPerFileBytes: 128,
          ttl: const Duration(minutes: 30),
        );
        addTearDown(h.dispose);

        final t0 = DateTime.utc(2026, 11, 26, 12, 0, 0);
        for (var i = 0; i < 5; i++) {
          final f = File(h.ws('f$i.txt'))..writeAsStringSync('orig-$i');
          await h.call('fs.write_file', <String, Object?>{
            'path': f.path,
            'content': 'next-$i',
          }, nowUtc: t0.add(Duration(seconds: i * 10)));
        }

        // Only the 3 most recent transactions may remain.
        final active = h.journal.listCommitted(
          t0.add(const Duration(minutes: 1)),
        );
        expect(active, hasLength(3));

        // File exceeding maxPerFileBytes (128 B) still writes atomically without journal entry.
        final bigPath = h.ws('big.txt');
        final bigRes = await h.call('fs.write_file', <String, Object?>{
          'path': bigPath,
          'content': 'X' * 200,
        }, nowUtc: t0.add(const Duration(minutes: 2)));
        expect(_status(bigRes), 'ok');
        expect(File(bigPath).readAsStringSync(), 'X' * 200);
        // Latest undo target is still f4.txt (not big.txt).
        final undo1 = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(minutes: 3)),
        );
        expect(_status(undo1), 'ok');
        expect(File(h.ws('f4.txt')).readAsStringSync(), 'orig-4');
        expect(File(bigPath).readAsStringSync(), 'X' * 200);

        // After TTL (30 min + 1 s), remaining journals expire cleanly.
        final expiredUndo = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(minutes: 35)),
        );
        expect(_status(expiredUndo), 'invalid_args');
        expect(_error(expiredUndo), 'nothing_to_undo');
      },
    );

    test(
      'fs.write_file + fs.patch_file + sequential action.undo + M1-2 external conflict + restart persistence + §3.6 zero-content logs',
      () async {
        final h = await _UndoHarness.create();
        addTearDown(h.dispose);

        final t0 = DateTime.utc(2026, 11, 26, 14, 0, 0);
        final filePath = h.ws('src/secret_marker_file.ts');
        const secretContentV1 = 'const UNIQUE_SECRET_CONTENT_42 = 1;\n';
        const secretContentV2 = 'const UNIQUE_SECRET_CONTENT_42 = 2;\n';

        // 1. Create file via fs.write_file
        final writeRes = await h.call('fs.write_file', <String, Object?>{
          'path': filePath,
          'content': secretContentV1,
        }, nowUtc: t0);
        expect(_status(writeRes), 'ok');
        expect(File(filePath).readAsStringSync(), secretContentV1);

        // 2. Patch file via fs.patch_file
        final patchRes = await h.call('fs.patch_file', <String, Object?>{
          'path': filePath,
          'target': '= 1;',
          'replacement': '= 2;',
        }, nowUtc: t0.add(const Duration(seconds: 10)));
        expect(_status(patchRes), 'ok');
        expect(File(filePath).readAsStringSync(), secretContentV2);

        // 3. M1-2: External user edit blocks action.undo fail-closed
        File(filePath).writeAsStringSync('const USER_MANUAL_EDIT = 99;\n');
        final conflictRes = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 20)),
        );
        expect(_status(conflictRes), 'failed');
        expect(_error(conflictRes), 'undo_conflict_modified_externally');
        expect(
          File(filePath).readAsStringSync(),
          'const USER_MANUAL_EDIT = 99;\n',
          reason: 'manual user edits must never be clobbered',
        );

        // Restore v2 so sequential undo proceeds cleanly:
        File(filePath).writeAsStringSync(secretContentV2);

        // 4. First action.undo reverts fs.patch_file (v2 -> v1)
        final undoPatch = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 30)),
        );
        expect(_status(undoPatch), 'ok');
        expect(_sc(undoPatch)['undoneTool'], 'fs.patch_file');
        expect(_sc(undoPatch)['restored'], isTrue);
        expect(_sc(undoPatch)['filesRestored'], 1);
        expect(_sc(undoPatch)['filesDeleted'], 0);
        expect(File(filePath).readAsStringSync(), secretContentV1);

        // 5. Simulate Desktop Agent restart: brand-new dispatcher sharing same undoDir
        final restartedJournal = FsUndoJournal(
          rootDir: h.paths.undoDir,
          logger: h.logger,
        );
        final restartedDispatcher = _UndoHarness._buildDispatcher(
          store: h.store,
          channel: h.channel,
          auditStore: h.auditStore,
          stop: h.stop,
          logger: h.logger,
          journal: restartedJournal,
        );
        addTearDown(restartedDispatcher.dispose);

        // Second action.undo on restarted dispatcher deletes created file
        final undoCreate = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 40)),
          via: restartedDispatcher,
        );
        expect(_status(undoCreate), 'ok');
        expect(_sc(undoCreate)['undoneTool'], 'fs.write_file');
        expect(_sc(undoCreate)['restored'], isTrue);
        expect(_sc(undoCreate)['filesDeleted'], 1);
        expect(File(filePath).existsSync(), isFalse);

        // Third action.undo has nothing left
        final emptyUndo = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 50)),
          via: restartedDispatcher,
        );
        expect(_status(emptyUndo), 'invalid_args');
        expect(_error(emptyUndo), 'nothing_to_undo');

        // 6. Desktop AGENTS §3.6: zero paths, filenames, or contents in logs, audit, or undo output
        final allLogs = h.logger.entries
            .map((e) => '${e.event} ${jsonEncode(e.fields)}')
            .join('\n');
        final auditContents = h.paths.auditDir
            .listSync()
            .whereType<File>()
            .map((f) => f.readAsStringSync())
            .join('\n');
        final undoWire = jsonEncode(<Object?>[undoPatch, undoCreate]);
        for (final surface in <String>[allLogs, auditContents, undoWire]) {
          expect(surface, isNot(contains('secret_marker_file.ts')));
          expect(surface, isNot(contains('UNIQUE_SECRET_CONTENT_42')));
          expect(surface, isNot(contains(h.workspace.path)));
        }
      },
    );

    test(
      'interleaves media.volume_set and fs.write_file in chronological LIFO undo order',
      () async {
        final h = await _UndoHarness.create();
        addTearDown(h.dispose);

        final t0 = DateTime.utc(2026, 11, 26, 15, 0, 0);
        final filePath = h.ws('note.txt');
        File(filePath).writeAsStringSync('v0');

        // Step 1 (t0): media.volume_set -> 80 (from default 50)
        final volRes = await h.call('media.volume_set', const <String, Object?>{
          'level': 80,
        }, nowUtc: t0);
        expect(_status(volRes), 'ok');
        expect(h.channel.currentVolume, 80);

        // Step 2 (t0 + 10s): fs.write_file -> v1
        final fsRes = await h.call('fs.write_file', <String, Object?>{
          'path': filePath,
          'content': 'v1',
        }, nowUtc: t0.add(const Duration(seconds: 10)));
        expect(_status(fsRes), 'ok');
        expect(File(filePath).readAsStringSync(), 'v1');

        // First undo reverts fs.write_file (more recent)
        final undo1 = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 20)),
        );
        expect(_status(undo1), 'ok');
        expect(_sc(undo1)['undoneTool'], 'fs.write_file');
        expect(File(filePath).readAsStringSync(), 'v0');
        expect(h.channel.currentVolume, 80);

        // Second undo reverts media.volume_set (older)
        final undo2 = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 30)),
        );
        expect(_status(undo2), 'ok');
        expect(_sc(undo2)['undoneTool'], 'media.volume_set');
        expect(h.channel.currentVolume, 50);

        // Reverse order: fs.write_file first, then media.volume_set -> undoes media first, then file
        await h.call('fs.write_file', <String, Object?>{
          'path': filePath,
          'content': 'v2',
        }, nowUtc: t0.add(const Duration(seconds: 40)));
        await h.call('media.volume_set', const <String, Object?>{
          'level': 75,
        }, nowUtc: t0.add(const Duration(seconds: 50)));
        expect(File(filePath).readAsStringSync(), 'v2');
        expect(h.channel.currentVolume, 75);

        final undoMediaFirst = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 60)),
        );
        expect(_status(undoMediaFirst), 'ok');
        expect(_sc(undoMediaFirst)['undoneTool'], 'media.volume_set');
        expect(h.channel.currentVolume, 50);
        expect(File(filePath).readAsStringSync(), 'v2');

        final undoFsSecond = await h.call(
          'action.undo',
          const <String, Object?>{},
          nowUtc: t0.add(const Duration(seconds: 70)),
        );
        expect(_status(undoFsSecond), 'ok');
        expect(_sc(undoFsSecond)['undoneTool'], 'fs.write_file');
        expect(File(filePath).readAsStringSync(), 'v0');
      },
    );
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/exec/draft_workspace_manager.dart';
import 'package:xuna_desktop/features/exec/fs_undo_journal.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _StubChannel implements XunaHostChannel {
  @override
  Future<HostPermissionSnapshot> permissions() async =>
      const HostPermissionSnapshot(
        accessibility: XtpPermissionState.granted,
        screenRecording: XtpPermissionState.granted,
        automation: <String, XtpPermissionState>{},
      );

  @override
  Future<void> showToast({required String title, required String body}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  late Directory tempRoot;
  late Directory workspaceDir;
  late Directory undoDir;
  late Directory draftsDir;
  late ContentFreeLogger logger;
  late HostPolicyStore policyStore;
  late EmergencyStopController stopController;
  late FsUndoJournal undoJournal;
  late DraftWorkspaceManager draftManager;
  late EnrollmentStateStore enrollmentStore;
  late HostToolDispatcher dispatcher;
  late Uint8List phonePriv;
  late Uint8List phonePub;

  const hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';
  final baseNow = DateTime.utc(2026, 11, 26, 12, 0, 0);

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('xuna_draft_w4_');
    workspaceDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}project_demo',
    )..createSync(recursive: true);
    undoDir = Directory('${tempRoot.path}${Platform.pathSeparator}undo');
    draftsDir = Directory('${tempRoot.path}${Platform.pathSeparator}drafts');
    logger = ContentFreeLogger();

    File(
      '${workspaceDir.path}${Platform.pathSeparator}keep.txt',
    ).writeAsStringSync('keep v1\n');
    File(
      '${workspaceDir.path}${Platform.pathSeparator}edit.txt',
    ).writeAsStringSync('hello world\n');
    File(
      '${workspaceDir.path}${Platform.pathSeparator}remove.txt',
    ).writeAsStringSync('obsolete\n');
    // Secret & cache files that MUST be excluded from draft copy.
    File(
      '${workspaceDir.path}${Platform.pathSeparator}.env',
    ).writeAsStringSync('SECRET_TOKEN=supersecret\n');
    Directory(
      '${workspaceDir.path}${Platform.pathSeparator}node_modules${Platform.pathSeparator}pkg',
    ).createSync(recursive: true);
    File(
      '${workspaceDir.path}${Platform.pathSeparator}node_modules${Platform.pathSeparator}pkg${Platform.pathSeparator}index.js',
    ).writeAsStringSync('module.exports = 1;\n');

    phonePriv = Uint8List.fromList(List<int>.generate(32, (i) => i + 7));
    phonePub = deriveP256PublicKey(phonePriv);

    policyStore = HostPolicyStore(
      policyFile: File(
        '${tempRoot.path}${Platform.pathSeparator}host-policy.json',
      ),
      logger: logger,
    );
    await policyStore.savePolicy(
      HostPolicy(
        families: <ToolFamily, FamilyPolicyDecision>{
          for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
        },
        apps: const <AllowedAppConfig>[],
        urlDomains: const <String>[],
        workflows: const <WorkflowConfig>[],
        players: const <String>[],
        shellControl: ShellControlPolicy(
          enabled: true,
          workspaceRoots: <String>[workspaceDir.path],
        ),
      ),
    );

    enrollmentStore = EnrollmentStateStore(
      stateFile: File(
        '${tempRoot.path}${Platform.pathSeparator}host-state.json',
      ),
    );
    await enrollmentStore.save(
      hostId: hostId,
      alias: 'TestHost',
      pinnedPhonePublicKeys: <String>[base64Encode(phonePub)],
    );

    stopController = EmergencyStopController(logger: logger);
    undoJournal = FsUndoJournal(rootDir: undoDir, logger: logger);
    draftManager = DraftWorkspaceManager(rootDir: draftsDir, logger: logger);
    dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: _StubChannel(),
      auditStore: AuditLogStore(
        auditDir: Directory('${tempRoot.path}${Platform.pathSeparator}audit'),
      ),
      stopController: stopController,
      logger: logger,
      enrollmentStore: enrollmentStore,
      fsUndoJournal: undoJournal,
      draftWorkspaceManager: draftManager,
    );
  });

  tearDown(() async {
    dispatcher.dispose();
    try {
      await tempRoot.delete(recursive: true);
    } on Object {
      // Best-effort cleanup.
    }
  });

  ApprovalToken makeR2Approval(
    Map<String, Object?> args, {
    String approvalId = '11111111-1111-4111-8111-111111111111',
  }) => ApprovalToken(
    approvalId: approvalId,
    argsSha256: argsSha256(args),
    expiresAt: baseNow.add(const Duration(seconds: 60)),
  );

  ApprovalToken makeV2Approval(
    Map<String, Object?> args,
    String effectSha256, {
    String approvalId = '22222222-2222-4222-8222-222222222222',
  }) {
    final expiresAt = baseNow.add(const Duration(seconds: 60));
    final expiresWire = expiresAt.toUtc().toIso8601String();
    final msg = approvalV2ProofMessage(
      approvalId: approvalId,
      effectSha256: effectSha256,
      hostId: hostId,
      expiresAt: expiresWire,
    );
    return ApprovalToken(
      approvalId: approvalId,
      argsSha256: argsSha256(args),
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      version: 2,
      effectSha256: effectSha256,
      signature: signP256Deterministic(
        privateScalar32: phonePriv,
        message: msg,
      ),
      publicKey: phonePub,
    );
  }

  test(
    'full W4-M3/W4-M4 lifecycle: draft create, edit, exec check, preflight, v2 apply, and one-step undo',
    () async {
      // 1. Create draft copy.
      final createArgs = <String, Object?>{'workspacePath': workspaceDir.path};
      final createRes = await dispatcher.dispatch(
        requestId: 1,
        params: ToolsCallParams(
          name: 'draft.create',
          arguments: createArgs,
          invocationId: '00000001-0000-4000-8000-000000000001',
          deadlineMs: 10000,
          approval: makeR2Approval(createArgs),
        ),
        nowUtc: baseNow,
      );
      expect(
        (createRes.result['_meta']! as Map)['xuna/status'],
        equals('ok'),
      );
      final createSc =
          createRes.result['structuredContent']! as Map<String, Object?>;
      final draftId = createSc['draftId']! as String;
      expect(createSc['scope'], equals('workspace_files_only'));
      expect(createSc['networkIsolated'], isFalse);
      expect(createSc['fileCount'], equals(3));

      // Verify .env and node_modules were excluded from the draft copy.
      final session = draftManager.requireSession(draftId, nowUtc: baseNow);
      expect(
        File('${session.draftDir.path}${Platform.pathSeparator}.env')
            .existsSync(),
        isFalse,
      );
      expect(
        Directory(
          '${session.draftDir.path}${Platform.pathSeparator}node_modules',
        ).existsSync(),
        isFalse,
      );

      // 2. Patch existing file, create new file, delete obsolete file inside draft.
      final patchArgs = <String, Object?>{
        'path': '${workspaceDir.path}${Platform.pathSeparator}edit.txt',
        'target': 'world',
        'replacement': 'xuna',
        'draftId': draftId,
      };
      final patchRes = await dispatcher.dispatch(
        requestId: 2,
        params: ToolsCallParams(
          name: 'fs.patch_file',
          arguments: patchArgs,
          invocationId: '00000001-0000-4000-8000-000000000002',
          deadlineMs: 10000,
          approval: makeR2Approval(patchArgs),
        ),
        nowUtc: baseNow,
      );
      expect(
        (patchRes.result['_meta']! as Map)['xuna/status'],
        equals('ok'),
      );

      final writeArgs = <String, Object?>{
        'path':
            '${workspaceDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}added.txt',
        'content': 'new file content\n',
        'createParents': true,
        'draftId': draftId,
      };
      final writeRes = await dispatcher.dispatch(
        requestId: 3,
        params: ToolsCallParams(
          name: 'fs.write_file',
          arguments: writeArgs,
          invocationId: '00000001-0000-4000-8000-000000000003',
          deadlineMs: 10000,
          approval: makeR2Approval(writeArgs),
        ),
        nowUtc: baseNow,
      );
      expect(
        (writeRes.result['_meta']! as Map)['xuna/status'],
        equals('ok'),
      );

      // Simulate deleting remove.txt inside the draft copy.
      File(
        '${session.draftDir.path}${Platform.pathSeparator}remove.txt',
      ).deleteSync();

      // Run a safe R2 command inside draft mode (records check outcome).
      final execArgs = <String, Object?>{
        'command': 'echo draft-check-ok',
        'cwd': workspaceDir.path,
        'draftId': draftId,
      };
      final execRes = await dispatcher.dispatch(
        requestId: 4,
        params: ToolsCallParams(
          name: 'exec.run',
          arguments: execArgs,
          invocationId: '00000001-0000-4000-8000-000000000004',
          deadlineMs: 10000,
          approval: makeR2Approval(execArgs),
        ),
        nowUtc: baseNow,
      );
      expect(
        (execRes.result['_meta']! as Map)['xuna/status'],
        equals('ok'),
      );

      // Original workspace must still be 100% unchanged!
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}edit.txt')
            .readAsStringSync(),
        equals('hello world\n'),
      );
      expect(
        File(
          '${workspaceDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}added.txt',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}remove.txt')
            .existsSync(),
        isTrue,
      );

      // 3. Read manifest & effectSha256.
      final manifestRes = await dispatcher.dispatch(
        requestId: 5,
        params: ToolsCallParams(
          name: 'draft.manifest',
          arguments: <String, Object?>{'draftId': draftId},
          invocationId: '00000001-0000-4000-8000-000000000005',
          deadlineMs: 10000,
        ),
        nowUtc: baseNow,
      );
      final manifestSc =
          manifestRes.result['structuredContent']! as Map<String, Object?>;
      final effectSha = manifestSc['effectSha256']! as String;
      expect(manifestSc['changeCount'], equals(3));
      expect(manifestSc['commandCount'], equals(1));
      expect(manifestSc['allCompleted'], isTrue);

      // 4. Preflight draft.apply returns R3 + effectSha256 + paths preview.
      final applyArgs = <String, Object?>{
        'draftId': draftId,
        'effectSha256': effectSha,
      };
      final preflightRes = await dispatcher.preflight(
        requestId: 6,
        params: PreflightParams(name: 'draft.apply', arguments: applyArgs),
        nowUtc: baseNow,
      );
      final pf = preflightRes.result['preflight']! as Map<String, Object?>;
      expect(pf['status'], equals('ok'));
      expect(pf['effectiveRisk'], equals('R3'));
      expect(pf['effectSha256'], equals(effectSha));
      expect((pf['preview']! as Map)['kind'], equals('paths'));
      expect((pf['preview']! as Map)['totalCount'], equals(3));

      // 5. Apply with valid xuna.approval.v2 signature.
      final applyRes = await dispatcher.dispatch(
        requestId: 7,
        params: ToolsCallParams(
          name: 'draft.apply',
          arguments: applyArgs,
          invocationId: '00000001-0000-4000-8000-000000000007',
          deadlineMs: 10000,
          approval: makeV2Approval(applyArgs, effectSha),
        ),
        nowUtc: baseNow,
      );
      expect(
        (applyRes.result['_meta']! as Map)['xuna/status'],
        equals('ok'),
      );
      final applySc =
          applyRes.result['structuredContent']! as Map<String, Object?>;
      expect(applySc['appliedCount'], equals(3));
      expect(applySc['createdCount'], equals(1));
      expect(applySc['modifiedCount'], equals(1));
      expect(applySc['deletedCount'], equals(1));
      expect(applySc['undoAvailable'], isTrue);

      // Real workspace reflects all 3 changes and draft copy is discarded!
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}edit.txt')
            .readAsStringSync(),
        equals('hello xuna\n'),
      );
      expect(
        File(
          '${workspaceDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}added.txt',
        ).readAsStringSync(),
        equals('new file content\n'),
      );
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}remove.txt')
            .existsSync(),
        isFalse,
      );
      expect(draftManager.activeDraftCount, equals(0));
      // .env untouched!
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}.env')
            .readAsStringSync(),
        equals('SECRET_TOKEN=supersecret\n'),
      );

      // 6. One-step action.undo reverts the ENTIRE multi-file draft apply!
      final undoRes = await dispatcher.dispatch(
        requestId: 8,
        params: ToolsCallParams(
          name: 'action.undo',
          arguments: const <String, Object?>{},
          invocationId: '00000001-0000-4000-8000-000000000008',
          deadlineMs: 10000,
        ),
        nowUtc: baseNow.add(const Duration(seconds: 5)),
      );
      expect((undoRes.result['_meta']! as Map)['xuna/status'], equals('ok'));
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}edit.txt')
            .readAsStringSync(),
        equals('hello world\n'),
      );
      expect(
        File(
          '${workspaceDir.path}${Platform.pathSeparator}sub${Platform.pathSeparator}added.txt',
        ).existsSync(),
        isFalse,
      );
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}remove.txt')
            .readAsStringSync(),
        equals('obsolete\n'),
      );

      // §3.6 privacy check: logs contain zero workspace paths or file contents!
      final allLogs = logger.entries
          .map((e) => '${e.event} ${e.fields}')
          .join('\n');
      expect(allLogs, isNot(contains('project_demo')));
      expect(allLogs, isNot(contains('SECRET_TOKEN')));
      expect(allLogs, isNot(contains('hello xuna')));
    },
  );

  test(
    'draft.apply refuses TOCTOU edit with 0 files modified and rejects replayed approvalId',
    () async {
      final session = await draftManager.createDraft(
        rawWorkspacePath: workspaceDir.path,
        shellControl: policyStore.evaluator.policy!.shellControl,
        nowUtc: baseNow,
      );
      File(
        '${session.draftDir.path}${Platform.pathSeparator}edit.txt',
      ).writeAsStringSync('draft edited\n');
      File(
        '${session.draftDir.path}${Platform.pathSeparator}keep.txt',
      ).writeAsStringSync('draft keep v2\n');

      final snap = draftManager.buildManifest(session.draftId, nowUtc: baseNow);
      final applyArgs = <String, Object?>{
        'draftId': session.draftId,
        'effectSha256': snap.effectSha256,
      };
      final token = makeV2Approval(applyArgs, snap.effectSha256);

      // External edit hits real workspace between signing and apply (TOCTOU!).
      File(
        '${workspaceDir.path}${Platform.pathSeparator}edit.txt',
      ).writeAsStringSync('external concurrent edit\n');

      final res = await dispatcher.dispatch(
        requestId: 20,
        params: ToolsCallParams(
          name: 'draft.apply',
          arguments: applyArgs,
          invocationId: '00000002-0000-4000-8000-000000000001',
          deadlineMs: 10000,
          approval: token,
        ),
        nowUtc: baseNow,
      );
      final meta = res.result['_meta']! as Map<String, Object?>;
      expect(meta['xuna/status'], equals('failed'));
      expect(meta['xuna/errorCode'], equals('toctou_mismatch'));

      // ZERO files modified: keep.txt must still have original content!
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}keep.txt')
            .readAsStringSync(),
        equals('keep v1\n'),
      );
      expect(
        File('${workspaceDir.path}${Platform.pathSeparator}edit.txt')
            .readAsStringSync(),
        equals('external concurrent edit\n'),
      );

      // Revert external edit and apply cleanly, then verify replay is rejected!
      File(
        '${workspaceDir.path}${Platform.pathSeparator}edit.txt',
      ).writeAsStringSync('hello world\n');
      final okRes = await dispatcher.dispatch(
        requestId: 21,
        params: ToolsCallParams(
          name: 'draft.apply',
          arguments: applyArgs,
          invocationId: '00000002-0000-4000-8000-000000000002',
          deadlineMs: 10000,
          approval: token,
        ),
        nowUtc: baseNow,
      );
      expect((okRes.result['_meta']! as Map)['xuna/status'], equals('ok'));

      // Create a second draft and attempt to replay the SAME approvalId.
      final session2 = await draftManager.createDraft(
        rawWorkspacePath: workspaceDir.path,
        shellControl: policyStore.evaluator.policy!.shellControl,
        nowUtc: baseNow,
      );
      File(
        '${session2.draftDir.path}${Platform.pathSeparator}keep.txt',
      ).writeAsStringSync('replay attempt\n');
      final snap2 = draftManager.buildManifest(
        session2.draftId,
        nowUtc: baseNow,
      );
      final replayArgs = <String, Object?>{
        'draftId': session2.draftId,
        'effectSha256': snap2.effectSha256,
      };
      final replayToken = makeV2Approval(
        replayArgs,
        snap2.effectSha256,
        approvalId: token.approvalId,
      );
      final replayRes = await dispatcher.dispatch(
        requestId: 22,
        params: ToolsCallParams(
          name: 'draft.apply',
          arguments: replayArgs,
          invocationId: '00000002-0000-4000-8000-000000000003',
          deadlineMs: 10000,
          approval: replayToken,
        ),
        nowUtc: baseNow,
      );
      final replayMeta = replayRes.result['_meta']! as Map<String, Object?>;
      expect(replayMeta['xuna/status'], equals('denied'));
      expect(replayMeta['xuna/errorCode'], equals('approval_replayed'));
    },
  );

  test(
    'enforces file cap, concurrent limit, E-Stop discard, and startup cleanup',
    () async {
      final tinyMgr = DraftWorkspaceManager(
        rootDir: draftsDir,
        maxFiles: 2,
        maxConcurrentDrafts: 1,
        logger: logger,
      );
      await expectLater(
        () => tinyMgr.createDraft(
          rawWorkspacePath: workspaceDir.path,
          shellControl: policyStore.evaluator.policy!.shellControl,
          nowUtc: baseNow,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'draft_workspace_too_large',
          ),
        ),
      );

      // Concurrent limit (default 2) + E-Stop cleanup.
      final s1 = await draftManager.createDraft(
        rawWorkspacePath: workspaceDir.path,
        shellControl: policyStore.evaluator.policy!.shellControl,
        nowUtc: baseNow,
      );
      final s2 = await draftManager.createDraft(
        rawWorkspacePath: workspaceDir.path,
        shellControl: policyStore.evaluator.policy!.shellControl,
        nowUtc: baseNow,
      );
      expect(draftManager.activeDraftCount, equals(2));
      await expectLater(
        () => draftManager.createDraft(
          rawWorkspacePath: workspaceDir.path,
          shellControl: policyStore.evaluator.policy!.shellControl,
          nowUtc: baseNow,
        ),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'draft_limit_reached',
          ),
        ),
      );

      // E-Stop immediately deletes all active drafts!
      stopController.triggerStop(StopReason.ownerApp);
      expect(draftManager.activeDraftCount, equals(0));
      expect(s1.draftDir.existsSync(), isFalse);
      expect(s2.draftDir.existsSync(), isFalse);

      // Startup cleanup removes orphaned directories left on disk.
      final stale = Directory(
        '${draftsDir.path}${Platform.pathSeparator}draft_stale_orphan',
      )..createSync(recursive: true);
      File('${stale.path}${Platform.pathSeparator}x.txt')
          .writeAsStringSync('stale');
      final removed = await draftManager.cleanupAllOnStartup();
      expect(removed, equals(1));
      expect(stale.existsSync(), isFalse);
    },
  );
}

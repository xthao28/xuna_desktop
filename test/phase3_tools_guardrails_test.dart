import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late ContentFreeLogger logger;
  late HostPolicyStore policyStore;
  late EmergencyStopController stopController;
  late FakeXunaHostChannel fakeChannel;
  late HostToolDispatcher dispatcher;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('xuna_phase3_guard_');
    logger = ContentFreeLogger();
    policyStore = HostPolicyStore(
      policyFile: File('${tempDir.path}/host-policy.json'),
      logger: logger,
    );
    await policyStore.writeDefaultPolicy();
    stopController = EmergencyStopController(logger: logger);
    fakeChannel = FakeXunaHostChannel(
      systemInfo: const HostSystemInfo(
        platform: HostPlatform.macos,
        osVersion: '15.1.0',
        hostname: 'test-workstation',
      ),
    );
    final indexer = AutoWorkspaceIndexer(
      scanDefaultLocations: false,
      gitRunner: (exe, args) async =>
          ProcessResult(0, 1, '', 'fatal: not a git repository'),
    );
    dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: fakeChannel,
      auditStore: AuditLogStore(auditDir: tempDir),
      stopController: stopController,
      logger: logger,
      workspaceIndexer: indexer,
      symbioticService: AutoSymbioticService(),
    );
  });

  tearDown(() async {
    dispatcher.dispose();
    await stopController.dispose();
    await policyStore.dispose();
    await tempDir.delete(recursive: true);
  });

  group('Phase 3 tools & guardrails (H1–H4)', () {
    test(
      'clipboard.write routes via XunaHostChannel, preserves 1601..4000 chars, and fails closed on channel errors',
      () async {
        final now = DateTime.utc(2026, 11, 20, 14, 0);
        final payload =
            '${'x' * 2200} OPENAI_KEY=sk-proj-secretValue1234567890';
        final args = <String, Object?>{'text': payload};
        final approval = ApprovalToken(
          approvalId: '40000000-0000-4000-8000-000000000001',
          argsSha256: argsSha256(args),
          expiresAt: now.add(const Duration(minutes: 5)),
        );

        final okResp = await dispatcher.dispatch(
          requestId: 'p3-clip-ok',
          params: ToolsCallParams(
            name: 'clipboard.write',
            arguments: args,
            invocationId: '40000000-0000-4000-8000-000000000002',
            deadlineMs: 5000,
            approval: approval,
          ),
          nowUtc: now,
        );
        expect(okResp.result['isError'], isFalse);
        expect(fakeChannel.invokedMethods, contains('clipboardWriteText'));
        final written = fakeChannel.lastWrittenClipboardText!;
        expect(written.length, greaterThan(2200));
        expect(written, contains('[REDACTED]'));
        expect(written, isNot(contains('sk-proj-secretValue1234567890')));

        // Channel failure propagates end-to-end (H1/H4).
        fakeChannel.nextException = const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'clipboard_write_failed',
          message: 'Pasteboard unavailable',
        );
        final failResp = await dispatcher.dispatch(
          requestId: 'p3-clip-fail',
          params: ToolsCallParams(
            name: 'clipboard.write',
            arguments: args,
            invocationId: '40000000-0000-4000-8000-000000000003',
            deadlineMs: 5000,
            approval: approval,
          ),
          nowUtc: now,
        );
        expect(failResp.result['isError'], isTrue);
        final meta = failResp.result['_meta']! as Map<String, Object?>;
        expect(meta['xuna/status'], equals('failed'));
        expect(meta['xuna/errorCode'], equals('clipboard_write_failed'));
      },
    );

    test(
      'clipboard.write and selection.read reject binary control bytes and unpaired UTF-16 surrogates',
      () async {
        final now = DateTime.utc(2026, 11, 20, 14, 5);
        for (final bad in <String>[
          'hello\u0000world',
          'bell\u0007here',
          String.fromCharCodes(<int>[0xD83D]), // orphan high surrogate
          String.fromCharCodes(<int>[0xDE00]), // orphan low surrogate
        ]) {
          fakeChannel.clipboardTextResult = bad;
          final selRes = await dispatcher.dispatch(
            requestId: 'p3-sel-bad-${bad.length}',
            params: const ToolsCallParams(
              name: 'selection.read',
              arguments: <String, Object?>{},
              invocationId: '40000000-0000-4000-8000-000000000010',
              deadlineMs: 5000,
            ),
            nowUtc: now,
          );
          expect(selRes.result['isError'], isTrue);
          expect(
            (selRes.result['_meta']! as Map<String, Object?>)['xuna/status'],
            equals('invalid_args'),
          );

          final clipArgs = <String, Object?>{'text': bad};
          final clipRes = await dispatcher.dispatch(
            requestId: 'p3-clip-bad-${bad.length}',
            params: ToolsCallParams(
              name: 'clipboard.write',
              arguments: clipArgs,
              invocationId: '40000000-0000-4000-8000-000000000011',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '40000000-0000-4000-8000-000000000012',
                argsSha256: argsSha256(clipArgs),
                expiresAt: now.add(const Duration(minutes: 5)),
              ),
            ),
            nowUtc: now,
          );
          expect(clipRes.result['isError'], isTrue);
          expect(
            (clipRes.result['_meta']! as Map<String, Object?>)['xuna/status'],
            equals('invalid_args'),
          );
        }

        // Valid UTF-8 with emoji surrogate pair succeeds.
        fakeChannel.clipboardTextResult = 'Xin chào XUNA 😀';
        final selOk = await dispatcher.dispatch(
          requestId: 'p3-sel-ok',
          params: const ToolsCallParams(
            name: 'selection.read',
            arguments: <String, Object?>{},
            invocationId: '40000000-0000-4000-8000-000000000013',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(selOk.result['isError'], isFalse);
      },
    );

    test(
      'browser.current_url fails closed on unrecognized browser instead of defaulting to edge',
      () async {
        final now = DateTime.utc(2026, 11, 20, 14, 10);
        const args = <String, Object?>{'browser': 'auto'};
        fakeChannel.browserCurrentUrlResult = const BrowserTabSnapshot(
          url: 'https://github.com/xthao28/xuna_pet',
          browser: 'unknown_browser',
        );
        final res = await dispatcher.dispatch(
          requestId: 'p3-browser-unknown',
          params: ToolsCallParams(
            name: 'browser.current_url',
            arguments: args,
            invocationId: '40000000-0000-4000-8000-000000000020',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000021',
              argsSha256: argsSha256(args),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(res.result['isError'], isTrue);
        final meta = res.result['_meta']! as Map<String, Object?>;
        expect(meta['xuna/status'], equals('failed'));
        expect(meta['xuna/errorCode'], equals('os_error'));
      },
    );

    test(
      'workspace.capture_capsule scrubs filesystem paths, avoids fabricating main branch, and workspace.restore_capsule never falls back to first capsule on miss (H1-H3)',
      () async {
        final now = DateTime.utc(2026, 11, 20, 14, 15);
        final capResp = await dispatcher.dispatch(
          requestId: 'p3-cap-1',
          params: const ToolsCallParams(
            name: 'workspace.capture_capsule',
            arguments: <String, Object?>{
              'project': 'my_app',
              'nextStepHint':
                  r'Check /Users/thao/secret/main.dart and C:\Users\thao\env.txt for long task '
                  'with extra details so that briefingVi clamping can also be verified reliably',
            },
            invocationId: '40000000-0000-4000-8000-000000000030',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(capResp.result['isError'], isFalse);
        final capSc =
            capResp.result['structuredContent']! as Map<String, Object?>;
        expect(capSc['branch'], equals('unknown'));
        final hint = capSc['nextStepHint']! as String;
        expect(hint, isNot(contains('/Users/thao')));
        expect(hint, isNot(contains(r'C:\Users\thao')));
        expect(hint, contains('[PATH]'));
        expect(jsonEncode(capSc), isNot(contains('/Users/thao')));

        // Miss by capsuleId must fail closed with capsule_not_found (never restore cap-my_app-1).
        const missIdArgs = <String, Object?>{'capsuleId': 'cap-nonexistent-99'};
        final missIdResp = await dispatcher.dispatch(
          requestId: 'p3-restore-miss-id',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: missIdArgs,
            invocationId: '40000000-0000-4000-8000-000000000031',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000032',
              argsSha256: argsSha256(missIdArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(missIdResp.result['isError'], isTrue);
        expect(
          (missIdResp.result['_meta']!
              as Map<String, Object?>)['xuna/errorCode'],
          equals('capsule_not_found'),
        );

        // Miss by project must also fail closed with capsule_not_found.
        const missProjArgs = <String, Object?>{'project': 'other_repo'};
        final missProjResp = await dispatcher.dispatch(
          requestId: 'p3-restore-miss-proj',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: missProjArgs,
            invocationId: '40000000-0000-4000-8000-000000000033',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000034',
              argsSha256: argsSha256(missProjArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(missProjResp.result['isError'], isTrue);
        expect(
          (missProjResp.result['_meta']!
              as Map<String, Object?>)['xuna/errorCode'],
          equals('capsule_not_found'),
        );

        // Matching project restore succeeds and clamps briefingVi <= 240 chars.
        const matchingProjArgs = <String, Object?>{'project': 'my_app'};
        final okRestore = await dispatcher.dispatch(
          requestId: 'p3-restore-ok',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: matchingProjArgs,
            invocationId: '40000000-0000-4000-8000-000000000035',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000036',
              argsSha256: argsSha256(matchingProjArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(okRestore.result['isError'], isFalse);
        final restoreSc =
            okRestore.result['structuredContent']! as Map<String, Object?>;
        expect(restoreSc['capsuleId'], equals(capSc['capsuleId']));
        expect(restoreSc['briefingRestored'], isTrue);
        expect(restoreSc['ideLaunched'], isFalse);
        expect(restoreSc['restored'], isFalse);
        expect(
          (restoreSc['briefingVi']! as String).length,
          lessThanOrEqualTo(240),
        );

        // Parameterless WorkspacePocketService lookup still returns latest capsule,
        // while explicit miss returns null (H3).
        final svc = AutoSymbioticService();
        svc.captureWorkspaceCapsule(
          project: 'alpha',
          branch: 'main',
          dirtyCount: 0,
        );
        expect(svc.findWorkspaceCapsule()?.project, equals('alpha'));
        expect(svc.findWorkspaceCapsule(capsuleId: 'cap-missing-1'), isNull);
        expect(svc.findWorkspaceCapsule(project: 'beta'), isNull);
      },
    );

    test(
      'Iteration 2: long project+branch capsule capture/restore roundtrip & emoji briefingVi UTF-16 safety',
      () async {
        final now = DateTime.utc(2026, 11, 20, 14, 20);
        final longProject = 'p' * 64;
        final longBranch = 'feature/${'b' * 90}';
        final emojiHint = '😀' * 120;

        final svc = AutoSymbioticService();
        final captured = svc.captureWorkspaceCapsule(
          project: longProject,
          branch: longBranch,
          dirtyCount: 3,
          nextStepHint: emojiHint,
          nowUtc: now,
        );
        expect(captured.capsuleId.length, lessThanOrEqualTo(64));
        expect(isValidShortId(captured.capsuleId), isTrue);
        expect(captured.branch.length, lessThanOrEqualTo(80));
        expect(hasBinaryOrInvalidSurrogates(captured.nextStepHint), isFalse);

        // Wire through dispatcher using a workspace whose alias is 64 chars and branch is 98 chars.
        final longDir = Directory('${tempDir.path}/${'p' * 64}');
        await longDir.create(recursive: true);
        final longIndexer = AutoWorkspaceIndexer(
          scanDefaultLocations: false,
          seedWorkspaces: <DiscoveredWorkspace>[
            DiscoveredWorkspace(
              alias: longProject,
              path: longDir.path,
              lastModified: now,
            ),
          ],
          gitRunner: (exe, args) async {
            if (args.contains('status')) {
              return ProcessResult(0, 0, '## $longBranch\n', '');
            }
            return ProcessResult(0, 0, '', '');
          },
          agentLauncher: (_) async {},
        );
        final longDispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: fakeChannel,
          auditStore: AuditLogStore(auditDir: tempDir),
          stopController: stopController,
          logger: logger,
          workspaceIndexer: longIndexer,
          symbioticService: svc,
        );
        addTearDown(longDispatcher.dispose);

        final capRes = await longDispatcher.dispatch(
          requestId: 'p3-cap-long',
          params: ToolsCallParams(
            name: 'workspace.capture_capsule',
            arguments: <String, Object?>{
              'project': longProject,
              'nextStepHint': emojiHint,
            },
            invocationId: '40000000-0000-4000-8000-000000000040',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        expect(capRes.result['isError'], isFalse);
        final capSc =
            capRes.result['structuredContent']! as Map<String, Object?>;
        final emittedId = capSc['capsuleId']! as String;
        expect(emittedId.length, lessThanOrEqualTo(64));
        expect(isValidShortId(emittedId), isTrue);
        expect((capSc['branch']! as String).length, lessThanOrEqualTo(80));

        // Restore using that emitted capsuleId MUST succeed with valid UTF-16 briefingVi <= 240.
        final restoreArgs = <String, Object?>{'capsuleId': emittedId};
        final restoreRes = await longDispatcher.dispatch(
          requestId: 'p3-restore-long',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: restoreArgs,
            invocationId: '40000000-0000-4000-8000-000000000041',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000042',
              argsSha256: argsSha256(restoreArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(restoreRes.result['isError'], isFalse);
        final restoreSc =
            restoreRes.result['structuredContent']! as Map<String, Object?>;
        final briefing = restoreSc['briefingVi']! as String;
        expect(briefing.length, lessThanOrEqualTo(240));
        expect(hasBinaryOrInvalidSurrogates(briefing), isFalse);
      },
    );

    test(
      'Iteration 2: DesktopAgentController.copyTextToSystemClipboard routes via FakeXunaHostChannel and fails honestly',
      () async {
        final enrollmentStore = EnrollmentStateStore(
          stateFile: File('${tempDir.path}/enrollment.json'),
        );
        final client = XtpSessionClient(
          wsUri: Uri.parse('ws://127.0.0.1:8000/v1/hosts/connect'),
          channel: fakeChannel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          dispatcher: dispatcher,
          stopController: stopController,
          logger: logger,
          enableAutoReconnect: false,
        );
        addTearDown(client.dispose);

        final svc = AutoSymbioticService();
        final controller = DesktopAgentController(
          channel: fakeChannel,
          enrollmentStore: enrollmentStore,
          policyStore: policyStore,
          auditStore: AuditLogStore(auditDir: tempDir),
          stopController: stopController,
          sessionClient: client,
          logger: logger,
          symbioticService: svc,
        );

        await controller.copyTextToSystemClipboard(
          'hello sk-proj-secretValue1234567890',
          labelVi: 'mã mẫu',
        );
        expect(fakeChannel.invokedMethods, contains('clipboardWriteText'));
        expect(fakeChannel.lastWrittenClipboardText, contains('[REDACTED]'));
        expect(
          fakeChannel.lastWrittenClipboardText,
          isNot(contains('sk-proj-secretValue1234567890')),
        );
        expect(
          svc.debugLastClipboardText,
          equals(fakeChannel.lastWrittenClipboardText),
        );
        expect(
          controller.frontierStatusSummaryVi.value,
          equals('📋 Đã sao chép mã mẫu vào Clipboard PC!'),
        );

        // Failure must NOT claim success or overwrite debugLastClipboardText (H1/H4).
        final previousWritten = svc.debugLastClipboardText;
        fakeChannel.nextException = const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'clipboard_write_failed',
          message: 'Pasteboard error',
        );
        await controller.copyTextToSystemClipboard(
          'second text',
          labelVi: 'mã lỗi',
        );
        expect(svc.debugLastClipboardText, equals(previousWritten));
        expect(
          controller.frontierStatusSummaryVi.value,
          isNot(contains('Đã sao chép')),
        );
        expect(
          controller.frontierStatusSummaryVi.value,
          contains('Không thể sao chép'),
        );
      },
    );

    test(
      'Tier 5: browser.read_page fails closed on unknown browser and workspace tools do not guess missing IDEs',
      () async {
        final now = DateTime.utc(2026, 11, 21, 1, 0);
        // Gap 2: browser.read_page must fail closed with os_error on unknown/empty browser.
        for (final badBrowser in <String>['', 'unknown_browser']) {
          fakeChannel.browserPageSummaryResult = BrowserPageSemanticSnapshot(
            url: 'https://github.com/xthao28/xuna_pet',
            browser: badBrowser,
            title: 'Repo',
          );
          const readArgs = <String, Object?>{'browser': 'auto'};
          final res = await dispatcher.dispatch(
            requestId: 't5-read-$badBrowser',
            params: ToolsCallParams(
              name: 'browser.read_page',
              arguments: readArgs,
              invocationId: '40000000-0000-4000-8000-000000000090',
              deadlineMs: 5000,
              approval: ApprovalToken(
                approvalId: '40000000-0000-4000-8000-000000000091',
                argsSha256: argsSha256(readArgs),
                expiresAt: now.add(const Duration(minutes: 5)),
              ),
            ),
            nowUtc: now,
          );
          expect(res.result['isError'], isTrue);
          final meta = res.result['_meta']! as Map<String, Object?>;
          expect(meta['xuna/status'], equals('failed'));
          expect(meta['xuna/errorCode'], equals('os_error'));
        }

        // Gap 5: workspace.open & workspace.restore_capsule fail closed on missing explicit IDE.
        final projDir = Directory('${tempDir.path}/sample_proj');
        await projDir.create(recursive: true);
        final launched = <String>[];
        final scanner = AutoAppScanner(
          scanFileSystem: false,
          seedAgentBinaries: const <String, String>{'vscode': '/usr/bin/code'},
        );
        final wsIndexer = AutoWorkspaceIndexer(
          scanDefaultLocations: false,
          seedWorkspaces: <DiscoveredWorkspace>[
            DiscoveredWorkspace(
              alias: 'sample_proj',
              path: projDir.path,
              lastModified: now,
            ),
          ],
          agentLauncher: (plan) async => launched.add(plan.agent),
        );
        final symbiotic = AutoSymbioticService();
        symbiotic.captureWorkspaceCapsule(
          project: 'sample_proj',
          branch: 'main',
          dirtyCount: 1,
          nowUtc: now,
        );
        final wsDispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: fakeChannel,
          auditStore: AuditLogStore(auditDir: tempDir),
          stopController: stopController,
          logger: logger,
          appScanner: scanner,
          workspaceIndexer: wsIndexer,
          symbioticService: symbiotic,
        );
        addTearDown(wsDispatcher.dispose);

        // Explicit missing IDE on workspace.open fails closed with ide_not_found.
        const openBadArgs = <String, Object?>{
          'project': 'sample_proj',
          'ide': 'cursor',
        };
        final openBad = await wsDispatcher.dispatch(
          requestId: 't5-ws-open-bad',
          params: ToolsCallParams(
            name: 'workspace.open',
            arguments: openBadArgs,
            invocationId: '40000000-0000-4000-8000-000000000092',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000093',
              argsSha256: argsSha256(openBadArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(openBad.result['isError'], isTrue);
        expect(
          (openBad.result['_meta']! as Map<String, Object?>)['xuna/errorCode'],
          equals('ide_not_found'),
        );
        expect(launched, isEmpty);

        // Explicit missing IDE on workspace.restore_capsule fails closed too.
        const restoreBadArgs = <String, Object?>{
          'project': 'sample_proj',
          'ide': 'cursor',
        };
        final restoreBad = await wsDispatcher.dispatch(
          requestId: 't5-ws-restore-bad',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: restoreBadArgs,
            invocationId: '40000000-0000-4000-8000-000000000094',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000095',
              argsSha256: argsSha256(restoreBadArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(restoreBad.result['isError'], isTrue);
        expect(
          (restoreBad.result['_meta']!
              as Map<String, Object?>)['xuna/errorCode'],
          equals('ide_not_found'),
        );

        // Auto IDE succeeds using available coding agent and reports ideLaunched=true.
        const restoreAutoArgs = <String, Object?>{
          'project': 'sample_proj',
          'ide': 'auto',
        };
        final restoreAuto = await wsDispatcher.dispatch(
          requestId: 't5-ws-restore-auto',
          params: ToolsCallParams(
            name: 'workspace.restore_capsule',
            arguments: restoreAutoArgs,
            invocationId: '40000000-0000-4000-8000-000000000096',
            deadlineMs: 5000,
            approval: ApprovalToken(
              approvalId: '40000000-0000-4000-8000-000000000097',
              argsSha256: argsSha256(restoreAutoArgs),
              expiresAt: now.add(const Duration(minutes: 5)),
            ),
          ),
          nowUtc: now,
        );
        expect(restoreAuto.result['isError'], isFalse);
        final scAuto =
            restoreAuto.result['structuredContent']! as Map<String, Object?>;
        expect(scAuto['ideLaunched'], isTrue);
        expect(scAuto['restored'], isTrue);
        expect(scAuto['ide'], equals('vscode'));
        expect(launched, equals(<String>['vscode']));
      },
    );
  });
}

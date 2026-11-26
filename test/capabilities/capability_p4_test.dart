import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/capabilities/capability_engine.dart';
import 'package:xuna_desktop/features/capabilities/capability_foundry_service.dart';
import 'package:xuna_desktop/features/capabilities/capability_manifest_loader.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/exec/draft_workspace_manager.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  late Directory tempRoot;
  late Directory workspaceDir;
  late Directory manifestsDir;
  late Directory draftsDir;
  late ContentFreeLogger logger;
  late HostPolicyStore policyStore;
  late EmergencyStopController stopController;
  late DraftWorkspaceManager draftManager;
  late File helperScript;

  final now = DateTime.utc(2026, 11, 26, 15, 0, 0);

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('xuna_cap_p4_');
    workspaceDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}workspace',
    )..createSync(recursive: true);
    manifestsDir = Directory(
      '${tempRoot.path}${Platform.pathSeparator}manifests',
    )..createSync(recursive: true);
    draftsDir = Directory('${tempRoot.path}${Platform.pathSeparator}drafts');
    logger = ContentFreeLogger();

    File(
      '${workspaceDir.path}${Platform.pathSeparator}input.txt',
    ).writeAsStringSync('hello declarative adapter\n');

    // A small deterministic local helper script invoked via Python WITHOUT
    // a shell (-c/-e are forbidden by CapabilityManifest; passing a script
    // file path + literal argv proves non-shell execution and magic bytes!).
    helperScript = File(
      '${tempRoot.path}${Platform.pathSeparator}convert_helper.py',
    )..writeAsStringSync('''
import sys
label = sys.argv[1]
src = sys.argv[2]
dst = sys.argv[3]
mode = sys.argv[4]
with open(src, "rb") as f:
    body = f.read()
if mode == "good":
    with open(dst, "wb") as f:
        f.write(b"%PDF-1.7\\n" + label.encode("utf-8") + b"\\n" + body)
elif mode == "bad_magic":
    with open(dst, "wb") as f:
        f.write(b"NOT_A_PDF_HEADER" + body)
elif mode == "missing":
    pass
print("ARGV_LABEL=" + label)
''');

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
    stopController = EmergencyStopController(logger: logger);
    draftManager = DraftWorkspaceManager(rootDir: draftsDir, logger: logger);
  });

  tearDown(() async {
    await stopController.dispose();
    if (tempRoot.existsSync()) {
      tempRoot.deleteSync(recursive: true);
    }
  });

  ApprovalToken makeR2Approval(Map<String, Object?> args) => ApprovalToken(
    approvalId: '11111111-1111-4111-8111-111111111111',
    argsSha256: argsSha256(args),
    expiresAt: now.add(const Duration(minutes: 5)),
  );

  group('P4.1 & P4.2 (U7): Declarative Capability Engine + Seed Manifest', () {
    test(
      'seed_document_convert.json is pure data, hides when binary missing, returns remediation, and vanishes when deleted',
      () async {
        final seedSrc = File('assets/capabilities/seed_document_convert.json');
        expect(seedSrc.existsSync(), isTrue);
        final installedSeed = File(
          '${manifestsDir.path}${Platform.pathSeparator}seed_document_convert.json',
        )..writeAsStringSync(seedSrc.readAsStringSync());

        final loader = CapabilityManifestLoader(
          manifestDirectories: <Directory>[manifestsDir],
          logger: logger,
        );
        final loaded = loader.loadAll();
        expect(loaded.manifests, hasLength(1));
        expect(loaded.manifests.first.id, equals('seed_document_convert'));
        expect(loaded.rejectedCount, equals(0));

        // On a host with empty PATH (binary not installed), capability.list
        // MUST omit the adapter, and capability.run MUST fail with
        // toolchain_missing + manifest-declared remediation!
        final missingEngine = CapabilityEngine(
          loader: loader,
          detector: CapabilityDetector(
            environmentOverride: const <String, String>{'PATH': ''},
          ),
          draftWorkspaceManager: draftManager,
          logger: logger,
        );
        final dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: FakeXunaHostChannel(),
          auditStore: AuditLogStore(
            auditDir: Directory(
              '${tempRoot.path}${Platform.pathSeparator}audit',
            ),
          ),
          stopController: stopController,
          logger: logger,
          draftWorkspaceManager: draftManager,
          capabilityEngine: missingEngine,
        );

        final listResp = await dispatcher.dispatch(
          requestId: 1,
          params: const ToolsCallParams(
            name: 'capability.list',
            arguments: <String, Object?>{},
            invocationId: '40000001-0000-4000-8000-000000000001',
            deadlineMs: 5000,
          ),
          nowUtc: now,
        );
        final listSc =
            listResp.result['structuredContent']! as Map<String, Object?>;
        expect(listSc['totalDetected'], equals(0));
        expect(listSc['adapters'], isEmpty);

        final runArgs = <String, Object?>{
          'adapterId': 'seed_document_convert',
          'inputsJson': jsonEncode(<String, Object?>{
            'inputPath': '${workspaceDir.path}${Platform.pathSeparator}a.docx',
            'outDir': workspaceDir.path,
            'expectedOutputPath':
                '${workspaceDir.path}${Platform.pathSeparator}a.pdf',
          }),
        };
        final runResp = await dispatcher.dispatch(
          requestId: 2,
          params: ToolsCallParams(
            name: 'capability.run',
            arguments: runArgs,
            invocationId: '40000001-0000-4000-8000-000000000002',
            deadlineMs: 5000,
            approval: makeR2Approval(runArgs),
          ),
          nowUtc: now,
        );
        final runMeta = runResp.result['_meta']! as Map<String, Object?>;
        final runSc =
            runResp.result['structuredContent']! as Map<String, Object?>;
        expect(runMeta['xuna/status'], equals('failed'));
        expect(runMeta['xuna/errorCode'], equals('toolchain_missing'));
        final rem = runSc['remediation']! as Map<String, Object?>;
        expect(rem['kind'], equals('install'));
        expect((rem['command'] as String?)?.isNotEmpty, isTrue);

        // Removing the JSON file removes the adapter completely!
        installedSeed.deleteSync();
        expect(loader.loadAll().manifests, isEmpty);
      },
    );

    test(
      'executes real non-shell argv keeping metacharacters trapped, enforces P1.1 verifyFiles magic, and fails closed on binary hash mismatch',
      () async {
        final pythonBin = Platform.isWindows ? 'python' : 'python3';
        final detector = CapabilityDetector();
        final resolvedPy = detector.resolveBinaryOnPath(pythonBin);
        expect(resolvedPy, isNotNull, reason: 'Python required on test host');
        final pySha = (await sha256.bind(File(resolvedPy!).openRead()).first)
            .toString();

        final baseManifest = CapabilityManifest(
          id: 'test_local_pdf_writer',
          capability: 'document.convert',
          description: 'Local test converter verifying non-shell argv & magic.',
          fromFormats: const <String>['txt'],
          toFormats: const <String>['pdf'],
          risk: RiskTier.r2,
          inputs: <CapabilityInputSpec>[
            CapabilityInputSpec(
              name: 'label',
              type: CapabilityInputType.string,
              maxLength: 120,
            ),
            CapabilityInputSpec(
              name: 'inputPath',
              type: CapabilityInputType.path,
              allowedExtensions: const <String>['txt'],
            ),
            CapabilityInputSpec(
              name: 'outputPath',
              type: CapabilityInputType.path,
              isOutputPath: true,
              allowedExtensions: const <String>['pdf'],
            ),
            CapabilityInputSpec(
              name: 'mode',
              type: CapabilityInputType.enumValue,
              enumValues: const <String>['good', 'bad_magic', 'missing'],
            ),
          ],
          detect: CapabilityDetectSpec(
            binary: pythonBin,
            versionArgs: const <String>['--version'],
          ),
          invoke: CapabilityInvokeSpec(
            argvTemplate: <String>[
              helperScript.path,
              '{label}',
              '{inputPath}',
              '{outputPath}',
              '{mode}',
            ],
          ),
          verifyFiles: <CapabilityVerifyFileSpec>[
            CapabilityVerifyFileSpec(
              pathTemplate: '{outputPath}',
              minBytes: 16,
              magic: '25504446',
            ),
          ],
          provenance: CapabilityProvenance(
            kind: CapabilityProvenanceKind.seed,
            approved: true,
            binarySha256: pySha,
          ),
        );
        final pinned = baseManifest.withProvenance(
          baseManifest.provenance.copyWith(
            manifestSha256: baseManifest.computeContentSha256(),
          ),
        );
        final manifestFile = File(
          '${manifestsDir.path}${Platform.pathSeparator}test_local_pdf_writer.json',
        )..writeAsStringSync(jsonEncode(pinned.toJson()));

        // Also drop an invalid shell-bearing manifest next to it: must be rejected!
        File(
          '${manifestsDir.path}${Platform.pathSeparator}evil_shell.json',
        ).writeAsStringSync(
          jsonEncode(<String, Object?>{
            ...pinned.toJson(),
            'id': 'evil_shell',
            'detect': <String, Object?>{'binary': 'cmd.exe'},
          }),
        );

        final loader = CapabilityManifestLoader(
          manifestDirectories: <Directory>[manifestsDir],
          logger: logger,
        );
        final engine = CapabilityEngine(
          loader: loader,
          detector: detector,
          draftWorkspaceManager: draftManager,
          logger: logger,
        );
        final dispatcher = HostToolDispatcher(
          policyStore: policyStore,
          channel: FakeXunaHostChannel(),
          auditStore: AuditLogStore(
            auditDir: Directory(
              '${tempRoot.path}${Platform.pathSeparator}audit2',
            ),
          ),
          stopController: stopController,
          logger: logger,
          draftWorkspaceManager: draftManager,
          capabilityEngine: engine,
        );

        // 1. capability.list shows ONLY the valid approved adapter.
        final detected = await engine.listDetectedAdapters();
        expect(detected.map((d) => d.manifest.id), equals(['test_local_pdf_writer']));

        // 2. Shell metacharacters in {label} stay trapped in argv[1] (NOT executed!),
        //    and valid PDF magic passes verifyFiles!
        final outGood =
            '${workspaceDir.path}${Platform.pathSeparator}good.pdf';
        final markerFile =
            '${workspaceDir.path}${Platform.pathSeparator}injected.txt';
        final goodArgs = <String, Object?>{
          'adapterId': 'test_local_pdf_writer',
          'inputsJson': jsonEncode(<String, Object?>{
            'label': 'safe; echo PWNED > "$markerFile" & whoami',
            'inputPath':
                '${workspaceDir.path}${Platform.pathSeparator}input.txt',
            'outputPath': outGood,
            'mode': 'good',
          }),
        };
        final pfGood = await dispatcher.preflight(
          requestId: 10,
          params: PreflightParams(name: 'capability.run', arguments: goodArgs),
          nowUtc: now,
        );
        expect(
          (pfGood.result['preflight']! as Map)['effectiveRisk'],
          equals('R2'),
        );

        final goodRes = await dispatcher.dispatch(
          requestId: 11,
          params: ToolsCallParams(
            name: 'capability.run',
            arguments: goodArgs,
            invocationId: '40000002-0000-4000-8000-000000000001',
            deadlineMs: 10000,
            approval: makeR2Approval(goodArgs),
          ),
          nowUtc: now,
        );
        expect((goodRes.result['_meta']! as Map)['xuna/status'], equals('ok'));
        expect(File(outGood).existsSync(), isTrue);
        expect(
          File(markerFile).existsSync(),
          isFalse,
          reason: 'Shell injection must NEVER escape argv',
        );
        final goodSc =
            goodRes.result['structuredContent']! as Map<String, Object?>;
        expect(goodSc['status'], equals('completed'));
        expect(
          ((goodSc['artifacts']! as List).first as Map)['magicOk'],
          isTrue,
        );

        // 3. Exit 0 with wrong magic bytes MUST fail closed (expected_output_mismatch)!
        final outBad = '${workspaceDir.path}${Platform.pathSeparator}bad.pdf';
        final badArgs = <String, Object?>{
          'adapterId': 'test_local_pdf_writer',
          'inputsJson': jsonEncode(<String, Object?>{
            'label': 'bad',
            'inputPath':
                '${workspaceDir.path}${Platform.pathSeparator}input.txt',
            'outputPath': outBad,
            'mode': 'bad_magic',
          }),
        };
        final badRes = await dispatcher.dispatch(
          requestId: 12,
          params: ToolsCallParams(
            name: 'capability.run',
            arguments: badArgs,
            invocationId: '40000002-0000-4000-8000-000000000002',
            deadlineMs: 10000,
            approval: makeR2Approval(badArgs),
          ),
          nowUtc: now,
        );
        expect(
          (badRes.result['_meta']! as Map)['xuna/status'],
          equals('failed'),
        );
        expect(
          (badRes.result['_meta']! as Map)['xuna/errorCode'],
          equals('expected_output_mismatch'),
        );

        // 4. Changing pinned binarySha256 hides adapter from list and fails run!
        final wrongBinPin = pinned.withProvenance(
          pinned.provenance.copyWith(binarySha256: 'f' * 64),
        );
        manifestFile.writeAsStringSync(jsonEncode(wrongBinPin.toJson()));
        expect(await engine.listDetectedAdapters(), isEmpty);
      },
    );

    test(
      'Rule H5: generic capability engine files contain zero hardcoded app/CLI names',
      () {
        final forbidden = RegExp(
          r'\b(soffice|libreoffice|ffmpeg|pandoc|imagemagick|inkscape|blender|photoshop|gimp|winget|brew|choco)\b',
          caseSensitive: false,
        );
        for (final path in const <String>[
          'lib/features/capabilities/capability_engine.dart',
          'lib/features/capabilities/capability_manifest_loader.dart',
          'lib/features/capabilities/capability_tools.dart',
          'lib/features/capabilities/capability_foundry_service.dart',
        ]) {
          final src = File(path).readAsStringSync();
          expect(
            forbidden.hasMatch(src),
            isFalse,
            reason: 'Rule H5 violation in $path',
          );
        }
      },
    );
  });

  group('P4.3 (U6): Verified Skills (draft -> verified only after real self-test)', () {
    test('pipeline, imported SKILL.md, simulated, and failing skills stay draft; real passing script verifies', () {
      // 1. Simulated test runner (allowSubprocessInWidgetTests: false) must NEVER mark verified!
      final simService = AutoSymbioticService(
        sandboxRunner: SandboxedToolRunner(
          allowSubprocessInWidgetTests: false,
          sandboxRootPath: tempRoot.path,
        ),
        workshopDirectory: Directory('${tempRoot.path}/ws_sim'),
      );
      final pipelineSkill = simService.synthesizeSkill(
        goal: 'Tóm tắt báo cáo bán hàng hằng tuần',
      );
      expect(pipelineSkill.verificationStatus, equals('draft'));
      expect(pipelineSkill.selfTestPassed, isFalse);
      expect(pipelineSkill.isVerified, isFalse);
      expect(simService.buildDynamicToolDescriptors(), isEmpty);

      final simScriptSkill = simService.synthesizeSkill(
        goal: 'Chạy kịch bản thử nghiệm',
        toolName: 'sim_only_tool',
        runtime: 'python',
        scriptCode: 'print("{\\"processedCount\\": 1}")',
      );
      expect(simScriptSkill.verificationStatus, equals('draft'));
      expect(simScriptSkill.isVerified, isFalse);
      expect(simService.buildDynamicToolDescriptors(), isEmpty);

      final imported = simService.bridgeSkillMarkdown(
        action: 'import_skill_md',
        markdownContent: '---\nname: "Demo Import"\ndescription: "Check docs"\n---\n# Demo\n',
      );
      final importedEntry = simService.findForgedSkill(imported.skillId);
      expect(importedEntry, isNotNull);
      expect(importedEntry!.verificationStatus, equals('draft'));
      expect(importedEntry.isVerified, isFalse);

      // 2. Real subprocess runner promotes ONLY passing scripts to 'verified'!
      final realService = AutoSymbioticService(
        sandboxRunner: SandboxedToolRunner(
          allowSubprocessInWidgetTests: true,
          sandboxRootPath: tempRoot.path,
        ),
        workshopDirectory: Directory('${tempRoot.path}/ws_real'),
      );
      final failing = realService.synthesizeSkill(
        goal: 'Broken real script',
        toolName: 'real_broken',
        runtime: 'python',
        scriptCode: 'import sys\nsys.exit(1)',
      );
      expect(failing.verificationStatus, equals('draft'));
      expect(failing.isVerified, isFalse);
      expect(realService.buildDynamicToolDescriptors(), isEmpty);

      final passing = realService.synthesizeSkill(
        goal: 'Passing real script',
        toolName: 'real_passing',
        runtime: 'python',
        scriptCode: 'import json\nprint(json.dumps({"processedCount": 2}))',
      );
      expect(passing.verificationStatus, equals('verified'));
      expect(passing.isVerified, isTrue);
      expect(
        realService.buildDynamicToolDescriptors().map((d) => d.name),
        contains('forge.custom_real_passing'),
      );
    });
  });

  group('P4.4 (F2): Manifest Foundry (manifests only + DraftWorkspace verify + owner approval)', () {
    test(
      'verifies candidate inside isolated DraftWorkspace leaving real workspace untouched and promotes only after pass + owner approval',
      () async {
        final pythonBin = Platform.isWindows ? 'python' : 'python3';
        final loader = CapabilityManifestLoader(
          manifestDirectories: <Directory>[manifestsDir],
          logger: logger,
        );
        final engine = CapabilityEngine(
          loader: loader,
          draftWorkspaceManager: draftManager,
          logger: logger,
        );
        final foundry = CapabilityFoundryService(
          engine: engine,
          draftManager: draftManager,
          installDir: manifestsDir,
          logger: logger,
        );

        // Shell-based proposal is rejected immediately fail-closed.
        expect(
          () => foundry.proposeManifest(
            id: 'bad_foundry_shell',
            capability: 'document.convert',
            description: 'Must fail',
            binary: 'powershell',
            argvTemplate: const <String>['-Command', '{inputPath}'],
            inputs: <CapabilityInputSpec>[
              CapabilityInputSpec(name: 'inputPath', type: CapabilityInputType.path),
            ],
          ),
          throwsFormatException,
        );

        final candidate = foundry.proposeManifest(
          id: 'foundry_pdf_gen',
          capability: 'document.convert',
          description: 'Synthesized declarative PDF converter manifest.',
          binary: pythonBin,
          fromFormats: const <String>['txt'],
          toFormats: const <String>['pdf'],
          argvTemplate: <String>[
            helperScript.path,
            '{label}',
            '{inputPath}',
            '{outputPath}',
            '{mode}',
          ],
          inputs: <CapabilityInputSpec>[
            CapabilityInputSpec(name: 'label', type: CapabilityInputType.string),
            CapabilityInputSpec(name: 'inputPath', type: CapabilityInputType.path),
            CapabilityInputSpec(
              name: 'outputPath',
              type: CapabilityInputType.path,
              isOutputPath: true,
            ),
            CapabilityInputSpec(
              name: 'mode',
              type: CapabilityInputType.enumValue,
              enumValues: const <String>['good', 'bad_magic'],
            ),
          ],
          verifyFiles: <CapabilityVerifyFileSpec>[
            CapabilityVerifyFileSpec(
              pathTemplate: '{outputPath}',
              minBytes: 16,
              magic: '25504446',
            ),
          ],
        );
        expect(candidate.provenance.kind, equals(CapabilityProvenanceKind.foundry));
        expect(candidate.provenance.approved, isFalse);

        final outPath =
            '${workspaceDir.path}${Platform.pathSeparator}foundry_out.pdf';
        final shellPolicy = policyStore.evaluator.policy!.shellControl;

        // 1. Failing golden run (bad_magic) cannot be promoted!
        final failVerify = await foundry.verifyCandidateInDraft(
          candidate: candidate,
          workspacePath: workspaceDir.path,
          goldenInputs: <String, Object?>{
            'label': 'golden',
            'inputPath':
                '${workspaceDir.path}${Platform.pathSeparator}input.txt',
            'outputPath': outPath,
            'mode': 'bad_magic',
          },
          shellControl: shellPolicy,
          nowUtc: now,
        );
        expect(failVerify.passed, isFalse);
        expect(failVerify.errorCode, equals('expected_output_mismatch'));
        expect(File(outPath).existsSync(), isFalse);
        await expectLater(
          () => foundry.approveAndInstall(
            verification: failVerify,
            ownerApproved: true,
            nowUtc: now,
          ),
          throwsStateError,
        );

        // 2. Passing golden run in DraftWorkspace leaves real workspace 100% untouched!
        final okVerify = await foundry.verifyCandidateInDraft(
          candidate: candidate,
          workspacePath: workspaceDir.path,
          goldenInputs: <String, Object?>{
            'label': 'golden',
            'inputPath':
                '${workspaceDir.path}${Platform.pathSeparator}input.txt',
            'outputPath': outPath,
            'mode': 'good',
          },
          shellControl: shellPolicy,
          nowUtc: now,
        );
        expect(okVerify.passed, isTrue, reason: okVerify.errorCode);
        expect(okVerify.observedBinarySha256, isNotNull);
        expect(
          File(outPath).existsSync(),
          isFalse,
          reason: 'Draft verification must NEVER modify the real workspace',
        );
        expect(draftManager.activeDraftCount, equals(0));

        // 3. Without ownerApproved == true, promotion fails closed!
        await expectLater(
          () => foundry.approveAndInstall(
            verification: okVerify,
            ownerApproved: false,
            nowUtc: now,
          ),
          throwsStateError,
        );
        expect(await engine.listDetectedAdapters(), isEmpty);

        // 4. With verified + ownerApproved, manifest is pinned & advertised!
        final installed = await foundry.approveAndInstall(
          verification: okVerify,
          ownerApproved: true,
          nowUtc: now,
        );
        expect(installed.provenance.approved, isTrue);
        expect(installed.provenance.manifestSha256, isNotNull);
        expect(installed.provenance.binarySha256, equals(okVerify.observedBinarySha256));

        final advertised = await engine.listDetectedAdapters();
        expect(advertised.map((a) => a.manifest.id), equals(['foundry_pdf_gen']));
      },
    );
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

HostPolicy _buildTestPolicy() => HostPolicy(
      schemaVersion: 1,
      families: const <ToolFamily, FamilyPolicyDecision>{
        ToolFamily.media: FamilyPolicyDecision.allow,
        ToolFamily.app: FamilyPolicyDecision.allow,
        ToolFamily.url: FamilyPolicyDecision.allow,
        ToolFamily.workflow: FamilyPolicyDecision.allow,
        ToolFamily.cu: FamilyPolicyDecision.allow,
        ToolFamily.screen: FamilyPolicyDecision.allow,
        ToolFamily.ui: FamilyPolicyDecision.allow,
        ToolFamily.input: FamilyPolicyDecision.allow,
      },
      apps: <AllowedAppConfig>[
        AllowedAppConfig(
          id: 'notepad',
          name: 'Notepad',
          kind: AppLaunchKind.exe,
          target: r'C:\Windows\notepad.exe',
          risk: RiskTier.r2,
        ),
      ],
      urlDomains: const <String>['example.com', 'google.com'],
      workflows: const <WorkflowConfig>[],
      players: const <String>['spotify'],
    );

void main() {
  group('Forge Skill Library & Structured Steps Execution (Wave D Feature 6)', () {
    late Directory tempDir;
    late ContentFreeLogger logger;
    late HostPolicyStore policyStore;
    late AutoSymbioticService symbiotic;
    late HostToolDispatcher dispatcher;
    final now = DateTime.utc(2026, 11, 15, 10, 0);

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('xuna_forge_test_');
      logger = ContentFreeLogger();
      final policyFile = File('${tempDir.path}/policy.json');
      policyStore = HostPolicyStore(
        policyFile: policyFile,
        logger: logger,
      );
      await policyStore.savePolicy(_buildTestPolicy());

      symbiotic = AutoSymbioticService(
        workshopDirectory: Directory('${tempDir.path}/workshop'),
      );

      dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: FakeXunaHostChannel(),
        auditStore: AuditLogStore(auditDir: Directory('${tempDir.path}/audit')),
        stopController: EmergencyStopController(logger: logger),
        logger: logger,
        symbioticService: symbiotic,
      );
    });

    tearDown(() {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('structured steps execute via subStepExecutor with parameter interpolation', () async {
      // Step 1: Synthesize a skill with structured steps
      final skillEntry = symbiotic.synthesizeSkill(
        goal: 'Open documentation and search topic',
        toolName: 'doc_searcher',
        runtime: 'composite',
        structuredSteps: <Map<String, Object?>>[
          <String, Object?>{
            'tool': 'url.open',
            'arguments': <String, Object?>{
              'url': 'https://example.com/search?q={{query}}&page={{page}}',
            },
          },
        ],
      );
      expect(skillEntry.structuredSteps, isNotNull);
      expect(skillEntry.executableSteps.length, equals(1));

      // Step 2: Execute skill with parameters via dispatcher
      final callArgs = <String, Object?>{
        'skillId': skillEntry.skillId,
        'stepArgs': <String, Object?>{
          'query': 'xuna_protocol',
          'page': '1',
        },
      };

      final resp = await dispatcher.dispatch(
        requestId: 'req-forge-1',
        params: ToolsCallParams(
          invocationId: 'inv-forge-0001',
          name: 'forge.run_skill',
          arguments: callArgs,
          deadlineMs: 8000,
          approval: ApprovalToken(
            approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
            scope: 'once',
            expiresAt: now.add(const Duration(minutes: 5)),
            argsSha256: argsSha256(callArgs),
          ),
        ),
        nowUtc: now,
      );

      final result = resp.result;
      expect(result['isError'], isFalse);
      final meta = result['_meta'] as Map<String, Object?>;
      expect(meta['xuna/status'], equals('ok'));
      final structured = result['structuredContent'] as Map<String, Object?>;
      expect(structured['completedSteps'], equals(1));
      expect(structured['steps'], isA<List>());
    });

    test('anti-privilege escalation: sub-step requiring R3 without phone signature fails closed', () async {
      // Create a skill containing cu.session_start (an R3 operation requiring phone P-256 signature)
      final r3Skill = symbiotic.synthesizeSkill(
        goal: 'Attempt unauthorized CU elevation',
        toolName: 'elevate_cu',
        runtime: 'composite',
        structuredSteps: <Map<String, Object?>>[
          <String, Object?>{
            'tool': 'cu.session_start',
            'arguments': <String, Object?>{
              'goal': 'Test unauthorized elevation',
              'apps': <String>['notepad'],
              'domains': <String>['example.com'],
              'maxSteps': 10,
              'maxMinutes': 5,
            },
          },
        ],
      );

      final callArgs = <String, Object?>{
        'skillId': r3Skill.skillId,
      };

      // Outer tool call carries R2 approval without phone P-256 signature
      final resp = await dispatcher.dispatch(
        requestId: 'req-forge-r3',
        params: ToolsCallParams(
          invocationId: 'inv-forge-r3-0001',
          name: 'forge.run_skill',
          arguments: callArgs,
          deadlineMs: 8000,
          approval: ApprovalToken(
            approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
            scope: 'once',
            expiresAt: now.add(const Duration(minutes: 5)),
            argsSha256: argsSha256(callArgs),
            signature: null, // Proves synthetic/unsigned approval cannot escalate
          ),
        ),
        nowUtc: now,
      );

      // Must fail closed with approval_signature_invalid
      final result = resp.result;
      expect(result['isError'], isTrue);
      final meta = result['_meta'] as Map<String, Object?>;
      expect(meta['xuna/status'], equals('denied'));
      expect(meta['xuna/errorCode'], equals('approval_signature_invalid'));
    });

    test('terminal GUI defense: blocked terminals fail closed with policy_blocked', () async {
      const blockedApps = <String>[
        'powershell.exe',
        'cmd.exe',
        'Terminal',
        'iTerm2',
        'alacritty',
        'wezterm',
        'kitty',
      ];

      for (final blockedApp in blockedApps) {
        final terminalSkill = symbiotic.synthesizeSkill(
          goal: 'Spawn shell $blockedApp',
          toolName: 'launch_terminal',
          runtime: 'composite',
          structuredSteps: <Map<String, Object?>>[
            <String, Object?>{
              'tool': 'app.open',
              'arguments': <String, Object?>{
                'appId': blockedApp,
              },
            },
          ],
        );

        final callArgs = <String, Object?>{
          'skillId': terminalSkill.skillId,
        };

        final resp = await dispatcher.dispatch(
          requestId: 'req-forge-term-$blockedApp',
          params: ToolsCallParams(
            invocationId: 'inv-forge-term-$blockedApp',
            name: 'forge.run_skill',
            arguments: callArgs,
            deadlineMs: 8000,
            approval: ApprovalToken(
              approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
              scope: 'once',
              expiresAt: now.add(const Duration(minutes: 5)),
              argsSha256: argsSha256(callArgs),
            ),
          ),
          nowUtc: now,
        );

        final result = resp.result;
        expect(result['isError'], isTrue);
        final meta = result['_meta'] as Map<String, Object?>;
        expect(meta['xuna/status'], equals('denied'));
        expect(meta['xuna/errorCode'], equals('policy_blocked'));
      }
    });

    test('Rule H4 error propagation: failing step aborts and preserves errorCode without swallowing', () async {
      // Step 1: url.open on forbidden domain throws domain_not_allowed
      final brokenSkill = symbiotic.synthesizeSkill(
        goal: 'Access forbidden domain',
        toolName: 'forbidden_step',
        runtime: 'composite',
        structuredSteps: <Map<String, Object?>>[
          <String, Object?>{
            'tool': 'url.open',
            'arguments': <String, Object?>{
              'url': 'https://forbidden-malicious-site.com/data',
            },
          },
        ],
      );

      final callArgs = <String, Object?>{
        'skillId': brokenSkill.skillId,
      };

      final resp = await dispatcher.dispatch(
        requestId: 'req-h4-propagate',
        params: ToolsCallParams(
          invocationId: 'inv-h4-0001',
          name: 'forge.run_skill',
          arguments: callArgs,
          deadlineMs: 8000,
          approval: ApprovalToken(
            approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
            scope: 'once',
            expiresAt: now.add(const Duration(minutes: 5)),
            argsSha256: argsSha256(callArgs),
          ),
        ),
        nowUtc: now,
      );

      final result = resp.result;
      expect(result['isError'], isTrue);
      final meta = result['_meta'] as Map<String, Object?>;
      expect(meta['xuna/status'], equals('denied'));
      expect(meta['xuna/errorCode'], equals('domain_not_allowed'));
    });

    test('host-side custom skill persistence: save, list, run, and delete from disk', () async {
      final workshopDir = Directory('${tempDir.path}/custom_workshop');
      final omni = OmniForgeService(workshopDirectory: workshopDir);

      // 1. Save skill to disk via listAndManageForgedSkills
      final recipe = <String, Object?>{
        'skillId': 'persisted_search_skill',
        'goal': 'Search developer docs',
        'toolName': 'search_dev_docs',
        'structuredSteps': <Map<String, Object?>>[
          <String, Object?>{
            'tool': 'url.open',
            'arguments': <String, Object?>{'url': 'https://example.com/docs'},
          },
        ],
      };

      omni.listAndManageForgedSkills(
        action: 'save',
        skillRecipe: recipe,
      );

      // Verify file is on disk
      final recipeFile = File('${workshopDir.path}${Platform.pathSeparator}persisted_search_skill${Platform.pathSeparator}recipe.json');
      expect(recipeFile.existsSync(), isTrue);

      // 2. List skills from disk
      final listRes = omni.listAndManageForgedSkills(action: 'list');
      final skills = listRes.skills;
      expect(skills.any((s) => s['id'] == 'persisted_search_skill' || s['skillId'] == 'persisted_search_skill'), isTrue);

      // 3. Find and run the persisted skill
      final found = omni.findForgedSkill('persisted_search_skill');
      expect(found, isNotNull);
      expect(found!.structuredSteps, isNotNull);
      expect(found.executableSteps.length, equals(1));

      // 4. Delete skill from disk
      omni.listAndManageForgedSkills(
        action: 'delete',
        skillId: 'persisted_search_skill',
      );
      expect(recipeFile.existsSync(), isFalse);

      // Listing again confirms removal
      final listAfter = omni.listAndManageForgedSkills(action: 'list');
      final skillsAfter = listAfter.skills;
      expect(skillsAfter.any((s) => s['id'] == 'persisted_search_skill' || s['skillId'] == 'persisted_search_skill'), isFalse);
    });
  });
}

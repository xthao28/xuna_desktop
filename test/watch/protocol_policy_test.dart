import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

Map<String, Object?> _policyJson({
  required List<Map<String, Object?>> harnesses,
  String trustPreset = 'standard',
}) => <String, Object?>{
  'schemaVersion': 1,
  'trustPreset': trustPreset,
  'families': <String, String>{
    for (final f in ToolFamily.values) f.wire: 'allow',
  },
  'apps': const <Object?>[],
  'urlDomains': const <String>['github.com'],
  'workflows': const <Object?>[],
  'players': const <Object?>[],
  'protocolHarnesses': harnesses,
};

ProtocolHarnessConfig _harness(
  String id, {
  ProtocolHarnessProtocol protocol = ProtocolHarnessProtocol.mcpStdio,
  String executable = 'safe_harness_bin',
  List<String> args = const <String>['--stdio'],
  RiskTier risk = RiskTier.r2,
}) => ProtocolHarnessConfig(
  id: id,
  name: 'Harness $id',
  protocol: protocol,
  executable: executable,
  args: args,
  risk: risk,
);

void main() {
  Get.testMode = true;
  tearDown(Get.reset);

  test(
    'HostPolicy parses valid mcp_stdio/acp_stdio R2/R3 harnesses & rejects invalid',
    () {
      final raw = jsonEncode(
        _policyJson(
          harnesses: <Map<String, Object?>>[
            <String, Object?>{
              'id': 'mcp_r2',
              'name': 'MCP Builder',
              'protocol': 'mcp_stdio',
              'executable': 'safe_mcp_runner',
              'args': <String>['--config', 'project.json'],
              'risk': 'R2',
            },
            <String, Object?>{
              'id': 'acp_r3',
              'name': 'ACP Runner',
              'protocol': 'acp_stdio',
              'executable': 'safe_acp_runner',
              'args': <String>['--stdio'],
              'risk': 'R3',
            },
          ],
        ),
      );
      final ev = HostPolicyEvaluator.fromJsonString(raw);
      expect(ev.isHealthy, isTrue);
      expect(ev.policy!.protocolHarnesses, hasLength(2));
      expect(
        ev.policy!.findProtocolHarness('mcp_r2')!.protocol,
        ProtocolHarnessProtocol.mcpStdio,
      );
      expect(
        ev.policy!.findProtocolHarness('acp_r3')!.protocol,
        ProtocolHarnessProtocol.acpStdio,
      );
      expect(ev.policy!.findProtocolHarness('acp_r3')!.risk, RiskTier.r3);

      // Duplicate IDs or R1 risk floor violation fail closed.
      final dupEv = HostPolicyEvaluator.fromJsonString(
        jsonEncode(
          _policyJson(
            harnesses: <Map<String, Object?>>[
              _harness('dup').toJson(),
              _harness('dup').toJson(),
            ],
          ),
        ),
      );
      expect(dupEv.isHealthy, isFalse);
      final r1Ev = HostPolicyEvaluator.fromJsonString(
        jsonEncode(
          _policyJson(
            harnesses: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'bad_r1',
                'name': 'Bad R1',
                'protocol': 'mcp_stdio',
                'executable': 'safe_bin',
                'risk': 'R1',
              },
            ],
          ),
        ),
      );
      expect(r1Ev.isHealthy, isFalse);
    },
  );

  test(
    'HostPolicy.fromJson fails closed on shells, interpreters, and inline eval flags',
    () {
      const forbiddenExecutables = <String>[
        'bash',
        'zsh',
        'sh',
        'fish',
        'cmd',
        'powershell',
        'pwsh',
        'osascript',
        'sudo',
        'su',
        '/bin/bash',
        'C:\\Windows\\System32\\cmd.exe',
      ];
      for (final exe in forbiddenExecutables) {
        final raw = jsonEncode(
          _policyJson(
            harnesses: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'bad_exe',
                'name': 'Forbidden',
                'protocol': 'mcp_stdio',
                'executable': exe,
                'risk': 'R2',
              },
            ],
          ),
        );
        final ev = HostPolicyEvaluator.fromJsonString(raw);
        expect(ev.isHealthy, isFalse, reason: 'Expected rejection for $exe');
        expect(ev.policy, isNull);
        final blocked = ev.evaluateInvocation(
          toolName: 'mcp.list_servers',
          arguments: const <String, Object?>{},
        );
        expect(blocked.allowed, isFalse);
        expect(blocked.errorCode, 'policy_invalid');
      }

      const forbiddenInlineCases = <(String, List<String>)>[
        ('safe_tool', ['-c', 'echo hi']),
        ('safe_tool', ['-e', 'print(1)']),
        ('safe_tool', ['-ec', 'id']),
        ('safe_tool', ['--eval', '1+1']),
        ('safe_tool', ['/c', 'dir']),
        ('safe_tool', ['-Command', 'Get-ChildItem']),
        ('python3', ['-c', 'import os']),
        ('node', ['-pe', 'process.exit(0)']),
        ('deno', ['eval', 'console.log(1)']),
      ];
      for (final (exe, args) in forbiddenInlineCases) {
        final raw = jsonEncode(
          _policyJson(
            harnesses: <Map<String, Object?>>[
              <String, Object?>{
                'id': 'bad_flag',
                'name': 'Inline Eval',
                'protocol': 'acp_stdio',
                'executable': exe,
                'args': args,
                'risk': 'R2',
              },
            ],
          ),
        );
        final ev = HostPolicyEvaluator.fromJsonString(raw);
        expect(
          ev.isHealthy,
          isFalse,
          reason: 'Expected rejection for $exe $args',
        );
      }
    },
  );

  test(
    'Remote xuna/set_policy rejects protocolHarnesses (-32602); local mutations preserve them',
    () async {
      final badSetPolicy = jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 42,
        'method': 'xuna/set_policy',
        'params': <String, Object?>{
          'trustPreset': 'standard',
          'protocolHarnesses': <Object?>[_harness('injected').toJson()],
        },
      });
      expect(
        () => XtpFrame.parse(badSetPolicy),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'jsonRpcCode',
            JsonRpcErrorCode.invalidParams,
          ),
        ),
      );

      final dir = await Directory.systemTemp.createTemp('xuna_proto_pol_');
      final paths = AgentPaths.resolve(overrideRootDir: dir);
      await paths.ensureDirectories();
      final log = ContentFreeLogger();
      final stopCtrl = EmergencyStopController(logger: log);
      final ps = HostPolicyStore(policyFile: paths.policyFile, logger: log);
      final reg = ProtocolTaskRegistry(stopController: stopCtrl);
      final ch = FakeXunaHostChannel();
      final audit = AuditLogStore(auditDir: paths.auditDir);
      final enroll = EnrollmentStateStore(stateFile: paths.enrollmentStateFile);

      final hR2 = _harness(
        'local_mcp',
        executable: 'secret_local_mcp_path',
        args: const <String>['--secret-token-flag', 'abc'],
        risk: RiskTier.r2,
      );
      final hR3 = _harness(
        'local_acp_r3',
        protocol: ProtocolHarnessProtocol.acpStdio,
        executable: 'secret_local_acp_path',
        args: const <String>['--acp-arg'],
        risk: RiskTier.r3,
      );
      await ps.savePolicy(
        HostPolicy(
          trustPreset: TrustPreset.autopilot,
          families: <ToolFamily, FamilyPolicyDecision>{
            for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>['github.com'],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
          protocolHarnesses: <ProtocolHarnessConfig>[hR2, hR3],
        ),
      );

      final disp = HostToolDispatcher(
        policyStore: ps,
        channel: ch,
        auditStore: audit,
        stopController: stopCtrl,
        logger: log,
        enrollmentStore: enroll,
        protocolTaskRegistry: reg,
      );
      final client = XtpSessionClient(
        wsUri: Uri.https('example.com', '/v1/hosts/connect'),
        channel: ch,
        enrollmentStore: enroll,
        policyStore: ps,
        dispatcher: disp,
        stopController: stopCtrl,
        logger: log,
        enableAutoReconnect: false,
      );
      final ctrl = DesktopAgentController(
        channel: ch,
        enrollmentStore: enroll,
        policyStore: ps,
        auditStore: audit,
        stopController: stopCtrl,
        sessionClient: client,
        logger: log,
        protocolTaskRegistry: reg,
      )..onInit();

      addTearDown(() async {
        ctrl.onClose();
        await client.dispose();
        disp.dispose();
        await reg.dispose();
        await ps.dispose();
        await stopCtrl.dispose();
        await dir.delete(recursive: true);
      });

      await ps.migrateMissingDesktopFamilies();
      expect(ps.evaluator.policy!.protocolHarnesses, hasLength(2));

      final setRes = await disp.setPolicy(
        requestId: 10,
        params: const SetPolicyParams(
          trustPreset: 'autopilot',
          allowApps: <String>[],
          denyApps: <String>[],
          allowDomains: <String>['github.com'],
          denyDomains: <String>[],
        ),
      );
      expect(setRes, isA<XtpResponse>());
      expect(ps.evaluator.policy!.protocolHarnesses, hasLength(2));

      await ctrl.toggleFamilyPolicy(ToolFamily.media, false);
      await ctrl.addAllowedAppToPolicy(name: 'Notes', target: 'notes_app');
      await ctrl.removeAllowedAppFromPolicy('notes');
      await ctrl.addAllowedDomainToPolicy('example.com');
      await ctrl.removeAllowedDomainFromPolicy('example.com');
      expect(
        ps.evaluator.policy!.protocolHarnesses.map((h) => h.id).toList(),
        <String>['local_mcp', 'local_acp_r3'],
      );

      // xuna/get_policy and mcp.list_servers never expose executable, args, workingDir, or env.
      final getPolJson = jsonEncode(
        (await disp.getPolicy(requestId: 11)).result,
      );
      for (final secret in const <String>[
        'secret_local_mcp_path',
        'secret_local_acp_path',
        '--secret-token-flag',
        '--acp-arg',
        'executable',
        'workingDir',
        '"env"',
      ]) {
        expect(getPolJson, isNot(contains(secret)));
      }

      final listResp = await disp.dispatch(
        requestId: 12,
        params: const ToolsCallParams(
          name: 'mcp.list_servers',
          arguments: <String, Object?>{},
          invocationId: '33333333-1111-4111-8111-000000000012',
          deadlineMs: 5000,
        ),
      );
      final listJson = jsonEncode(listResp.result['structuredContent']);
      expect(listJson, contains('local_mcp'));
      expect(listJson, contains('local_acp_r3'));
      expect(listJson, contains('"transport":"acp_stdio"'));
      for (final secret in const <String>[
        'secret_local_mcp_path',
        'secret_local_acp_path',
        '--secret-token-flag',
        '--acp-arg',
        'executable',
        'args',
        'workingDir',
        '"env"',
      ]) {
        expect(listJson, isNot(contains(secret)));
      }

      // mcp.call risk elevates to R3 when ProtocolHarnessConfig.risk == RiskTier.r3.
      final r2Eval = ps.evaluator.evaluateInvocation(
        toolName: 'mcp.call',
        arguments: const <String, Object?>{
          'server': 'local_mcp',
          'tool': 'ping',
        },
      );
      expect(r2Eval.allowed, isTrue);
      expect(r2Eval.effectiveRisk, RiskTier.r2);

      final r3Eval = ps.evaluator.evaluateInvocation(
        toolName: 'mcp.call',
        arguments: const <String, Object?>{
          'server': 'local_acp_r3',
          'tool': 'solve',
        },
      );
      expect(r3Eval.allowed, isFalse);
      expect(r3Eval.effectiveRisk, RiskTier.r3);
      expect(r3Eval.errorCode, 'approval_required');

      final preflightR3 = await disp.preflight(
        requestId: 13,
        params: const PreflightParams(
          name: 'mcp.call',
          arguments: <String, Object?>{
            'server': 'local_acp_r3',
            'tool': 'solve',
          },
        ),
      );
      expect(
        (preflightR3.result['preflight']
            as Map<String, Object?>)['effectiveRisk'],
        'R3',
      );
    },
  );
}

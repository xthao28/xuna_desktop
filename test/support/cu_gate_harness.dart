// Shared harness for the computer-use gate tests (UDC-17 S17.1–S17.2): a
// dispatcher with an enrolled phone key, a policy that allows `cu`/`input`,
// and a scripted window.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

const String _hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';

HostPolicy _policy() => HostPolicy(
  schemaVersion: 1,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.cu: FamilyPolicyDecision.allow,
    ToolFamily.screen: FamilyPolicyDecision.allow,
    ToolFamily.ui: FamilyPolicyDecision.allow,
    ToolFamily.input: FamilyPolicyDecision.allow,
  },
  apps: <AllowedAppConfig>[
    AllowedAppConfig(
      id: 'explorer',
      name: 'File Explorer',
      kind: AppLaunchKind.exe,
      target: r'C:\Windows\explorer.exe',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'calendar',
      name: 'Calendar',
      kind: AppLaunchKind.bundle,
      target: 'com.apple.iCal',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>[],
  workflows: const <WorkflowConfig>[],
  players: const <String>[],
);

const ActiveWindowObservation defaultCuTestWindow = ActiveWindowObservation(
  appId: 'explorer',
  processName: 'explorer.exe',
  windowTitle: 'Reports',
  nodes: <Map<String, Object?>>[
    <String, Object?>{
      'id': 'n1',
      'role': 'button',
      'name': 'Mở báo cáo',
      'enabled': true,
    },
    <String, Object?>{
      'id': 'n2',
      'role': 'button',
      'name': 'Gửi báo cáo',
      'enabled': true,
    },
    <String, Object?>{
      'id': 'n3',
      'role': 'textfield',
      'name': 'Ghi chú',
      'enabled': true,
      'editable': true,
    },
    <String, Object?>{
      'id': 'n4',
      'role': 'textfield',
      'name': 'Mật khẩu',
      'isPassword': true,
      'enabled': true,
    },
  ],
);

class CuGateHarness {
  CuGateHarness._(
    this.tempDir,
    this.dispatcher,
    this.manager,
    this.provider,
    this.phonePrivate,
    this.phonePublic,
  );

  final Directory tempDir;
  final HostToolDispatcher dispatcher;
  final ComputerUseSessionManager manager;
  final FallbackUiaAxComputerUseProvider provider;
  final Uint8List phonePrivate;
  final Uint8List phonePublic;
  int _rpc = 1;

  static Future<CuGateHarness> create({
    ActiveWindowObservation window = defaultCuTestWindow,
    FallbackUiaAxComputerUseProvider? provider,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('xuna_preflight_');
    final paths = AgentPaths.resolve(overrideRootDir: tempDir);
    await paths.ensureDirectories();
    final logger = ContentFreeLogger();
    final policyStore = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: logger,
    );
    await policyStore.savePolicy(_policy());
    final phonePrivate = Uint8List.fromList(
      List<int>.generate(32, (i) => (i + 41) & 0xff),
    );
    final phonePublic = deriveP256PublicKey(phonePrivate);
    final enrollment = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    await enrollment.save(hostId: _hostId, alias: 'PC test');
    await enrollment.updatePhonePublicKeys(<String>[
      base64.encode(phonePublic),
    ]);
    final stop = EmergencyStopController(logger: logger);
    final cuProvider =
        provider ?? FallbackUiaAxComputerUseProvider(initialWindow: window);
    final manager = ComputerUseSessionManager(
      provider: cuProvider,
      stopController: stop,
    );
    final dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: FakeXunaHostChannel(),
      auditStore: AuditLogStore(auditDir: paths.auditDir),
      stopController: stop,
      logger: logger,
      enrollmentStore: enrollment,
      computerUseManager: manager,
      // Deterministic: the real scanner reads this machine's installed apps.
      appScanner: AutoAppScanner(
        scanFileSystem: false,
        seedApps: const <DiscoveredApp>[],
      ),
    );
    return CuGateHarness._(
      tempDir,
      dispatcher,
      manager,
      cuProvider,
      phonePrivate,
      phonePublic,
    );
  }

  Future<void> startSession() => manager.startSession(
    goal: 'Mở báo cáo mới nhất',
    apps: const <String>['explorer'],
    domains: const <String>[],
    maxSteps: 10,
    maxMinutes: 5,
    policy: _policy(),
  );

  Future<void> startSessionAndInspect() async {
    await startSession();
    await manager.inspectWindow(maxNodes: 20);
  }

  Future<Map<String, Object?>> preflight(
    String tool,
    Map<String, Object?> args,
  ) async {
    final response = await dispatcher.preflight(
      requestId: _rpc++,
      params: PreflightParams(name: tool, arguments: args),
    );
    // The frame must survive the strict XTP parser on its way to the backend.
    final reparsed = XtpFrame.parse(response.encode());
    expect(reparsed, isA<XtpResponse>());
    return (response.result['preflight'] as Map).cast<String, Object?>();
  }

  ApprovalToken signedApproval(Map<String, Object?> args, {bool sign = true}) {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 1));
    final expiresWire = expiresAt.toIso8601String();
    const approvalId = 'b1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
    final sha = argsSha256(args);
    final sig = sign
        ? signP256Deterministic(
            privateScalar32: phonePrivate,
            message: approvalProofMessage(
              approvalId: approvalId,
              argsSha256: sha,
              hostId: _hostId,
              expiresAt: expiresWire,
            ),
          )
        : null;
    return ApprovalToken(
      approvalId: approvalId,
      argsSha256: sha,
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      signature: sig,
      publicKey: sign ? phonePublic : null,
    );
  }

  Future<Map<String, Object?>> dispatchMeta(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    required String invocationId,
  }) async {
    final response = await dispatcher.dispatch(
      requestId: _rpc++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId: invocationId,
        deadlineMs: 5000,
        approval: approval,
      ),
    );
    return (response.result['_meta'] as Map).cast<String, Object?>();
  }

  /// Like [dispatchMeta] but returns the whole `tools/call` result
  /// (`structuredContent` and `_meta`).
  Future<Map<String, Object?>> dispatchResult(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    required String invocationId,
  }) async {
    final response = await dispatcher.dispatch(
      requestId: _rpc++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId: invocationId,
        deadlineMs: 5000,
        approval: approval,
      ),
    );
    return response.result.cast<String, Object?>();
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    manager.dispose();
    await tempDir.delete(recursive: true);
  }
}

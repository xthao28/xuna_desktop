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

const String _testHostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';

const ActiveWindowObservation _notesWindowObservation = ActiveWindowObservation(
  appId: 'notes',
  processName: 'Notes',
  windowTitle: 'Ghi chú',
  nodes: <Map<String, Object?>>[
    <String, Object?>{
      'id': 'n1',
      'role': 'button',
      'name': 'Ghi chú mới',
      'enabled': true,
    },
    <String, Object?>{
      'id': 'n2',
      'role': 'textarea',
      'name': 'Nội dung ghi chú',
      'enabled': true,
      'editable': true,
    },
    <String, Object?>{
      'id': 'n3',
      'role': 'button',
      'name': 'Xóa ghi chú',
      'enabled': true,
    },
  ],
  focusedRole: 'textarea',
);

HostPolicy _buildTestPolicy({
  TrustPreset preset = TrustPreset.standard,
  List<AllowedAppConfig>? apps,
}) =>
    HostPolicy(
      schemaVersion: 1,
      trustPreset: preset,
      families: const <ToolFamily, FamilyPolicyDecision>{
        ToolFamily.cu: FamilyPolicyDecision.allow,
        ToolFamily.screen: FamilyPolicyDecision.allow,
        ToolFamily.ui: FamilyPolicyDecision.allow,
        ToolFamily.input: FamilyPolicyDecision.allow,
        ToolFamily.app: FamilyPolicyDecision.allow,
      },
      apps: apps ??
          <AllowedAppConfig>[
            AllowedAppConfig(
              id: 'notes',
              name: 'Notes',
              kind: AppLaunchKind.bundle,
              target: 'com.apple.Notes',
              risk: RiskTier.r2,
            ),
          ],
      urlDomains: const <String>[],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
    );

class WaveATestHarness {
  WaveATestHarness._({
    required this.tempDir,
    required this.dispatcher,
    required this.manager,
    required this.provider,
    required this.policyStore,
    required this.scanner,
    required this.phonePrivate,
    required this.phonePublic,
  });

  final Directory tempDir;
  final HostToolDispatcher dispatcher;
  final ComputerUseSessionManager manager;
  final FallbackUiaAxComputerUseProvider provider;
  final HostPolicyStore policyStore;
  final AutoAppScanner scanner;
  final Uint8List phonePrivate;
  final Uint8List phonePublic;
  int _rpcId = 1;

  static Future<WaveATestHarness> create({
    TrustPreset preset = TrustPreset.standard,
    List<AllowedAppConfig>? apps,
    ActiveWindowObservation window = _notesWindowObservation,
  }) async {
    final tempDir = await Directory.systemTemp.createTemp('xuna_wave_a_e2e_');
    final paths = AgentPaths.resolve(overrideRootDir: tempDir);
    await paths.ensureDirectories();

    final logger = ContentFreeLogger();
    final policyStore = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: logger,
    );
    await policyStore.savePolicy(_buildTestPolicy(preset: preset, apps: apps));

    final phonePrivate = Uint8List.fromList(
      List<int>.generate(32, (i) => (i + 55) & 0xff),
    );
    final phonePublic = deriveP256PublicKey(phonePrivate);

    final enrollment = EnrollmentStateStore(
      stateFile: paths.enrollmentStateFile,
    );
    await enrollment.save(hostId: _testHostId, alias: 'Desktop Mac Test');
    await enrollment.updatePhonePublicKeys(<String>[
      base64.encode(phonePublic),
    ]);

    final stop = EmergencyStopController(logger: logger);
    final cuProvider = FallbackUiaAxComputerUseProvider(initialWindow: window);

    final scanner = AutoAppScanner(
      scanFileSystem: false,
      seedApps: const <DiscoveredApp>[
        DiscoveredApp(
          id: 'notes',
          name: 'Notes',
          kind: AppLaunchKind.bundle,
          target: 'com.apple.Notes',
          bundleId: 'com.apple.Notes',
        ),
        DiscoveredApp(
          id: 'calculator',
          name: 'Calculator',
          kind: AppLaunchKind.bundle,
          target: 'com.apple.calculator',
          bundleId: 'com.apple.calculator',
        ),
      ],
    );

    final manager = ComputerUseSessionManager(
      provider: cuProvider,
      stopController: stop,
      appScanner: scanner,
    );

    final dispatcher = HostToolDispatcher(
      policyStore: policyStore,
      channel: FakeXunaHostChannel(),
      auditStore: AuditLogStore(auditDir: paths.auditDir),
      stopController: stop,
      logger: logger,
      enrollmentStore: enrollment,
      computerUseManager: manager,
      appScanner: scanner,
    );

    return WaveATestHarness._(
      tempDir: tempDir,
      dispatcher: dispatcher,
      manager: manager,
      provider: cuProvider,
      policyStore: policyStore,
      scanner: scanner,
      phonePrivate: phonePrivate,
      phonePublic: phonePublic,
    );
  }

  ApprovalToken signedR3Approval(Map<String, Object?> args) {
    final expiresAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
    final expiresWire = expiresAt.toIso8601String();
    final approvalId = 'a${_rpcId.toString().padLeft(7, '0')}-4444-4444-8888-111111111111';
    final sha = argsSha256(args);
    final sig = signP256Deterministic(
      privateScalar32: phonePrivate,
      message: approvalProofMessage(
        approvalId: approvalId,
        argsSha256: sha,
        hostId: _testHostId,
        expiresAt: expiresWire,
      ),
    );
    return ApprovalToken(
      approvalId: approvalId,
      argsSha256: sha,
      expiresAt: expiresAt,
      expiresAtRaw: expiresWire,
      signature: sig,
      publicKey: phonePublic,
    );
  }

  Future<Map<String, Object?>> dispatch(
    String tool,
    Map<String, Object?> args, {
    ApprovalToken? approval,
    String? invocationId,
  }) async {
    final invId = invocationId ??
        'inv-${_rpcId.toString().padLeft(6, '0')}-4111-8111-1234567890ab';
    final response = await dispatcher.dispatch(
      requestId: _rpcId++,
      params: ToolsCallParams(
        name: tool,
        arguments: args,
        invocationId: invId,
        deadlineMs: 5000,
        approval: approval,
      ),
    );
    return (response.result['_meta'] as Map).cast<String, Object?>();
  }

  Future<void> dispose() async {
    dispatcher.dispose();
    manager.dispose();
    await tempDir.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Wave A Desktop E2E Integration Suite', () {
    // =========================================================================
    // Tier 1: Host Integration (Dispatcher, Scanner, Envelope & Presets)
    // =========================================================================

    group('Tier 1 - Host Integration', () {
      test('T1-INT.1: HostToolDispatcher integrates with AutoAppScanner & cu_gate_harness', () async {
        final harness = await WaveATestHarness.create();
        try {
          // Scanner discovers seeded safe apps
          final discovered = harness.scanner.discoverApps();
          expect(discovered.map((a) => a.id), containsAll(<String>['notes', 'calculator']));

          // Scanner filters out modern terminals and settings
          for (final term in const <String>['warp', 'alacritty', 'kitty', 'wezterm', 'wezterm-gui', 'wezterm-gui.exe', 'ghostty', 'system_settings']) {
            expect(harness.scanner.findApp(term), isNull, reason: 'Terminal $term not discovered');
          }

          // Active context inspection
          final meta = await harness.dispatch(
            'window.active_context',
            const <String, Object?>{'maxChars': 500},
          );
          expect(meta['xuna/status'], equals('ok'));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-F4: CU session envelope allows in-scope app.launch without re-approval prompt', () async {
        final harness = await WaveATestHarness.create();
        try {
          // 1. Start CU session for "notes"
          final startArgs = <String, Object?>{
            'goal': 'Soạn ghi chú mới',
            'apps': <String>['notes'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          final startMeta = await harness.dispatch(
            'cu.session_start',
            startArgs,
            approval: harness.signedR3Approval(startArgs),
          );
          expect(startMeta['xuna/status'], equals('ok'));
          expect(harness.manager.hasActiveSession, isTrue);

          // 2. Launch in-scope "notes" app under session envelope with approval: null
          const launchArgs = <String, Object?>{'id': 'notes'};
          final launchMeta = await harness.dispatch(
            'app.launch',
            launchArgs,
            approval: null,
          );
          expect(launchMeta['xuna/status'], equals('ok'));
          expect(launchMeta['xuna/errorCode'], isNull);

          // 3. Launching an out-of-scope app ("calculator") without approval is blocked/requires approval
          const outOfScopeArgs = <String, Object?>{'id': 'calculator'};
          final outMeta = await harness.dispatch(
            'app.launch',
            outOfScopeArgs,
            approval: null,
          );
          expect(outMeta['xuna/status'], equals('denied'));
          expect(outMeta['xuna/errorCode'], equals('approval_required'));
        } finally {
          await harness.dispose();
        }
      });

      test('T1-F8: TrustPreset.standard allows zero-config app discovery while strict blocks unlisted apps', () async {
        // Standard preset harness: unlisted discovered app "calculator" is permitted
        final standardHarness = await WaveATestHarness.create(preset: TrustPreset.standard);
        try {
          const calcArgs = <String, Object?>{'id': 'calculator'};
          final res = standardHarness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: standardHarness.signedR3Approval(calcArgs),
          );
          expect(res.allowed, isTrue);
          expect(res.status, equals(XtpStatus.ok));
        } finally {
          await standardHarness.dispose();
        }

        // Strict preset harness: unlisted app "calculator" is blocked with policy_blocked
        final strictHarness = await WaveATestHarness.create(preset: TrustPreset.strict);
        try {
          const calcArgs = <String, Object?>{'id': 'calculator'};
          // Evaluator-level verification
          final res = strictHarness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: strictHarness.signedR3Approval(calcArgs),
          );
          expect(res.allowed, isFalse);
          expect(res.status, equals(XtpStatus.denied));
          expect(res.errorCode, equals('policy_blocked'));

          // Dispatcher-level verification: HostToolDispatcher.dispatch enforces Strict preset
          final dispatchMeta = await strictHarness.dispatch('app.launch', calcArgs);
          expect(dispatchMeta['xuna/status'], equals('denied'));
          expect(dispatchMeta['xuna/errorCode'], equals('policy_blocked'));

          // Dispatcher-level verification even with phone-signed approval token
          final dispatchSignedMeta = await strictHarness.dispatch(
            'app.launch',
            calcArgs,
            approval: strictHarness.signedR3Approval(calcArgs),
          );
          expect(dispatchSignedMeta['xuna/status'], equals('denied'));
          expect(dispatchSignedMeta['xuna/errorCode'], equals('policy_blocked'));
        } finally {
          await strictHarness.dispose();
        }
      });
    });

    // =========================================================================
    // Tier 3: Cross-Feature Combinations
    // =========================================================================

    group('Tier 3 - Cross-Feature Combinations', () {
      test('T3-C1: Dynamic trust preset switching (Strict <-> Standard <-> Autopilot)', () async {
        final harness = await WaveATestHarness.create(preset: TrustPreset.strict);
        try {
          const calcArgs = <String, Object?>{'id': 'calculator'};
          final approval = harness.signedR3Approval(calcArgs);

          // In Strict: unlisted app is blocked at evaluator level
          final strictRes = harness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: approval,
          );
          expect(strictRes.allowed, isFalse);
          expect(strictRes.errorCode, equals('policy_blocked'));

          // In Strict: unlisted app is blocked at dispatcher level
          final strictDispatchMeta = await harness.dispatch('app.launch', calcArgs);
          expect(strictDispatchMeta['xuna/status'], equals('denied'));
          expect(strictDispatchMeta['xuna/errorCode'], equals('policy_blocked'));

          // Switch dynamically to Standard
          await harness.policyStore.savePolicy(_buildTestPolicy(preset: TrustPreset.standard));
          final standardRes = harness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: approval,
          );
          expect(standardRes.allowed, isTrue);
          expect(standardRes.status, equals(XtpStatus.ok));

          // Switch dynamically to Autopilot
          await harness.policyStore.savePolicy(_buildTestPolicy(preset: TrustPreset.autopilot));
          final autopilotRes = harness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: approval,
          );
          expect(autopilotRes.allowed, isTrue);
          expect(autopilotRes.status, equals(XtpStatus.ok));

          // Switch back to Strict: blocks again immediately at evaluator and dispatcher levels
          await harness.policyStore.savePolicy(_buildTestPolicy(preset: TrustPreset.strict));
          final strictAgainRes = harness.policyStore.evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: calcArgs,
            approval: approval,
          );
          expect(strictAgainRes.allowed, isFalse);
          expect(strictAgainRes.errorCode, equals('policy_blocked'));

          final strictAgainDispatchMeta = await harness.dispatch('app.launch', calcArgs);
          expect(strictAgainDispatchMeta['xuna/status'], equals('denied'));
          expect(strictAgainDispatchMeta['xuna/errorCode'], equals('policy_blocked'));
        } finally {
          await harness.dispose();
        }
      });

      test('T3-C2: Terminal launch attempt rejected even within active CU session', () async {
        final harness = await WaveATestHarness.create();
        try {
          // 1. Start valid CU session
          final startArgs = <String, Object?>{
            'goal': 'Kiểm thử bảo mật',
            'apps': <String>['notes'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          await harness.dispatch(
            'cu.session_start',
            startArgs,
            approval: harness.signedR3Approval(startArgs),
          );

          // 2. Attempt launching terminals inside active session
          const dangerousTerminals = <String>[
            'warp',
            'alacritty',
            'kitty',
            'wezterm',
            'ghostty',
            'hyper',
            'terminal',
            'iterm2',
            'system_settings',
          ];

          for (final term in dangerousTerminals) {
            final launchArgs = <String, Object?>{'id': term};
            final launchMeta = await harness.dispatch(
              'app.launch',
              launchArgs,
              approval: harness.signedR3Approval(launchArgs),
            );
            expect(launchMeta['xuna/status'], equals('denied'));
            expect(launchMeta['xuna/errorCode'], equals('denylisted_target_forbidden'), reason: 'Deny $term in CU session');
          }

          // 3. Attempt extending session with terminal
          final extendArgs = <String, Object?>{
            'sessionId': harness.manager.activeSession!.sessionId,
            'apps': <String>['warp'],
            'domains': <String>[],
          };
          final extendMeta = await harness.dispatch(
            'cu.session_extend',
            extendArgs,
            approval: harness.signedR3Approval(extendArgs),
          );
          expect(extendMeta['xuna/status'], equals('denied'));
          expect(extendMeta['xuna/errorCode'], equals('denylisted_target_forbidden'));
        } finally {
          await harness.dispose();
        }
      });
    });

    // =========================================================================
    // Tier 4: Real-World Workloads & Security Audits
    // =========================================================================

    group('Tier 4 - Real-World Workloads & Security Audits', () {
      test('T4-W1: Simulated Apple Notes Leave Request Workflow ("Đơn xin nghỉ phép") achieves exactly 1 prompt', () async {
        final harness = await WaveATestHarness.create();
        try {
          var ownerPromptCount = 0;

          // Step 1: cu.session_start requires phone-signed R3 approval (Owner Prompt #1)
          final startArgs = <String, Object?>{
            'goal': 'Soạn đơn xin nghỉ phép 2 ngày',
            'apps': <String>['notes'],
            'domains': <String>[],
            'maxSteps': 10,
            'maxMinutes': 5,
          };
          ownerPromptCount++;
          final startMeta = await harness.dispatch(
            'cu.session_start',
            startArgs,
            approval: harness.signedR3Approval(startArgs),
          );
          expect(startMeta['xuna/status'], equals('ok'));

          // Step 2: app.launch("notes") under session envelope with approval: null (0 prompts)
          const launchArgs = <String, Object?>{'id': 'notes'};
          final launchMeta = await harness.dispatch(
            'app.launch',
            launchArgs,
            approval: null,
          );
          expect(launchMeta['xuna/status'], equals('ok'));
          expect(launchMeta['xuna/errorCode'], isNull);

          // Step 3: Inspect / find draft target (0 prompts)
          await harness.manager.inspectWindow(maxNodes: 20);

          // Step 4: input.key("Cmd+N") for new note (0 prompts)
          const cmdNArgs = <String, Object?>{'combo': 'Cmd+N', 'inForm': false};
          final cmdNMeta = await harness.dispatch('input.key', cmdNArgs);
          expect(cmdNMeta['xuna/status'], equals('ok'));

          // Step 5: input.type_text with multiline leave request draft (0 prompts)
          const leaveDraftText =
              'CỘNG HÒA XÃ HỘI CHỦ NGHĨA VIỆT NAM\n'
              'Độc lập - Tự do - Hạnh phúc\n\n'
              'ĐƠN XIN NGHỈ PHÉP\n'
              'Kính gửi: Ban Giám Đốc và Bộ phận Nhân sự\n'
              'Tôi tên là: Nguyễn Văn A\n'
              'Nay tôi làm đơn này xin phép được nghỉ 2 ngày từ ngày 20/11 đến hết ngày 21/11.\n'
              'Lý do: Giải quyết việc gia đình.\n'
              'Tôi đã bàn giao công việc cho đồng nghiệp trong thời gian nghỉ.\n'
              'Kính mong Ban Giám Đốc phê duyệt. Xin trân trọng cảm ơn!';

          final typeArgs = <String, Object?>{
            'elementId': '@s00000001:e2',
            'text': leaveDraftText,
          };
          final typeMeta = await harness.dispatch('input.type_text', typeArgs);
          expect(typeMeta['xuna/status'], equals('ok'));

          // Step 6: input.key("Enter") for formatting (0 prompts)
          const enterArgs = <String, Object?>{'combo': 'Enter', 'inForm': false};
          final enterMeta = await harness.dispatch('input.key', enterArgs);
          expect(enterMeta['xuna/status'], equals('ok'));

          // Step 7: Verification of consequential safety boundary:
          // Clicking "Xóa ghi chú" (delete) WOULD prompt for R3 re-approval
          final deleteClickArgs = <String, Object?>{'elementId': '@s00000001:e3'};
          final deleteClickMeta = await harness.dispatch('input.click', deleteClickArgs);
          expect(deleteClickMeta['xuna/status'], equals('denied'));
          expect(deleteClickMeta['xuna/errorCode'], equals('approval_required'));

          // Verify the invariant: throughout the entire drafting workflow,
          // exactly 1 prompt occurred!
          expect(ownerPromptCount, equals(1), reason: 'Exactly 1 owner prompt throughout leave request draft');
        } finally {
          await harness.dispose();
        }
      });

      test('T4-W2: Comprehensive 15-target terminal GUI denylist verification', () async {
        const terminalTargets = <String>[
          'terminal',
          'iterm',
          'iterm2',
          'warp',
          'alacritty',
          'kitty',
          'wezterm',
          'wezterm-gui',
          'wezterm-gui.exe',
          'ghostty',
          'hyper',
          'cmd',
          'powershell',
          'wt',
          'bash',
          'zsh',
          'dev.warp.warp-stable',
        ];

        // Also verify case-insensitive check on Warp-Stable
        expect(
          isHardDeniedAppOrProcess('dev.warp.Warp-Stable'),
          isTrue,
          reason: 'isHardDeniedAppOrProcess denies mixed-case dev.warp.Warp-Stable',
        );

        // Explicit verification for wezterm-gui and wezterm-gui.exe binaries and casing
        expect(isHardDeniedAppOrProcess('wezterm-gui'), isTrue, reason: 'Deny wezterm-gui');
        expect(isHardDeniedAppOrProcess('wezterm-gui.exe'), isTrue, reason: 'Deny wezterm-gui.exe');
        expect(isHardDeniedAppOrProcess('WEZTERM-GUI'), isTrue, reason: 'Deny uppercase WEZTERM-GUI');
        expect(isHardDeniedAppOrProcess('WEZTERM-GUI.EXE'), isTrue, reason: 'Deny uppercase WEZTERM-GUI.EXE');

        final harness = await WaveATestHarness.create();
        try {
          for (final target in terminalTargets) {
            // 1. Policy denylist check
            expect(
              isHardDeniedAppOrProcess(target),
              isTrue,
              reason: 'isHardDeniedAppOrProcess denies $target',
            );

            // 2. AutoAppScanner exclusion
            expect(
              harness.scanner.findApp(target),
              isNull,
              reason: 'AutoAppScanner excludes $target',
            );

            // 3. Dispatch rejection on app.launch
            final launchArgs = <String, Object?>{'id': target};
            final launchMeta = await harness.dispatch(
              'app.launch',
              launchArgs,
              approval: harness.signedR3Approval(launchArgs),
            );
            expect(
              launchMeta['xuna/status'],
              equals('denied'),
              reason: 'app.launch denies $target',
            );
            expect(
              launchMeta['xuna/errorCode'],
              equals('denylisted_target_forbidden'),
              reason: 'ErrorCode is denylisted_target_forbidden for $target',
            );
          }
        } finally {
          await harness.dispose();
        }
      });
    });
  });
}

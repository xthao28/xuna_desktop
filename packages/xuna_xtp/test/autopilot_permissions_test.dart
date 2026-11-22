import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

HostPolicy _buildPolicy(TrustPreset preset) {
  return HostPolicy(
    schemaVersion: 1,
    trustPreset: preset,
    families: const <ToolFamily, FamilyPolicyDecision>{
      ToolFamily.media: FamilyPolicyDecision.allow,
      ToolFamily.app: FamilyPolicyDecision.allow,
      ToolFamily.url: FamilyPolicyDecision.allow,
      ToolFamily.workflow: FamilyPolicyDecision.allow,
      ToolFamily.cu: FamilyPolicyDecision.allow,
      ToolFamily.screen: FamilyPolicyDecision.allow,
      ToolFamily.ui: FamilyPolicyDecision.allow,
      ToolFamily.input: FamilyPolicyDecision.allow,
      ToolFamily.files: FamilyPolicyDecision.allow,
      ToolFamily.host: FamilyPolicyDecision.allow,
    },
    apps: const <AllowedAppConfig>[],
    urlDomains: const <String>['github.com'],
    workflows: const <WorkflowConfig>[],
    players: const <String>['spotify'],
  );
}

void main() {
  group('ADR-0015 Autopilot relaxation (2026-11-22)', () {
    test(
        'isHighImpactElementName keeps financial, destructive, and send/publish R3 while relaxing ordinary UI labels',
        () {
      // High-impact MUST match
      expect(isHighImpactElementName('Send'), isTrue);
      expect(isHighImpactElementName('Gửi tin nhắn'), isTrue);
      expect(isHighImpactElementName('Post'), isTrue);
      expect(isHighImpactElementName('Publish'), isTrue);
      expect(isHighImpactElementName('Đăng bài'), isTrue);
      expect(isHighImpactElementName('Đăng'), isTrue);
      expect(isHighImpactElementName('Xuất bản'), isTrue);
      expect(isHighImpactElementName('Pay now'), isTrue);
      expect(isHighImpactElementName('Checkout'), isTrue);
      expect(isHighImpactElementName('Thanh toán'), isTrue);
      expect(isHighImpactElementName('Chuyển khoản'), isTrue);
      expect(isHighImpactElementName('Đặt hàng'), isTrue);
      expect(isHighImpactElementName('Delete'), isTrue);
      expect(isHighImpactElementName('Xóa vĩnh viễn'), isTrue);
      expect(isHighImpactElementName('Sign out'), isTrue);
      expect(isHighImpactElementName('Đăng xuất'), isTrue);
      expect(isHighImpactElementName('Uninstall'), isTrue);

      // Ordinary UI/IDE controls MUST NOT trigger high-impact
      expect(isHighImpactElementName('Submit'), isFalse);
      expect(isHighImpactElementName('Confirm'), isFalse);
      expect(isHighImpactElementName('Remove filter'), isFalse);
      expect(isHighImpactElementName('Hủy'), isFalse);
      expect(isHighImpactElementName('Đăng nhập'), isFalse);
      expect(isHighImpactElementName('Đăng ký'), isFalse);
      expect(isHighImpactElementName('Sort order'), isFalse);
    });

    test(
        'cu.session_start and cu.session_extend run at R2 without approval under autopilot, stay R3 under standard, and still hard-deny terminals',
        () {
      final autopilotEval =
          HostPolicyEvaluator.healthy(_buildPolicy(TrustPreset.autopilot));
      final standardEval =
          HostPolicyEvaluator.healthy(_buildPolicy(TrustPreset.standard));

      const startArgs = <String, Object?>{
        'goal': 'Check project progress in IDE',
        'apps': <String>['antigravity_ide'],
        'domains': <String>[],
        'maxSteps': 20,
        'maxMinutes': 10,
      };

      final autoStart = autopilotEval.evaluateInvocation(
        toolName: 'cu.session_start',
        arguments: startArgs,
        approval: null,
      );
      expect(autoStart.allowed, isTrue);
      expect(autoStart.effectiveRisk, RiskTier.r2);

      final stdStart = standardEval.evaluateInvocation(
        toolName: 'cu.session_start',
        arguments: startArgs,
        approval: null,
      );
      expect(stdStart.allowed, isFalse);
      expect(stdStart.effectiveRisk, RiskTier.r3);
      expect(stdStart.errorCode, 'approval_required');

      // Extend under autopilot
      final autoExtend = autopilotEval.evaluateInvocation(
        toolName: 'cu.session_extend',
        arguments: const <String, Object?>{
          'sessionId': 'cu-1',
          'apps': <String>['notes'],
          'domains': <String>[],
        },
        isInApprovedCuSession: true,
        approval: null,
      );
      expect(autoExtend.allowed, isTrue);
      expect(autoExtend.effectiveRisk, RiskTier.r2);

      // Hard-denied app MUST stay blocked even under autopilot
      final autoTerminal = autopilotEval.evaluateInvocation(
        toolName: 'cu.session_start',
        arguments: const <String, Object?>{
          'goal': 'Open terminal',
          'apps': <String>['terminal'],
          'domains': <String>[],
          'maxSteps': 5,
          'maxMinutes': 2,
        },
        approval: null,
      );
      expect(autoTerminal.allowed, isFalse);
      expect(autoTerminal.status, XtpStatus.denied);
    });

    test(
        'classifyInputStepRisk relaxes ordinary typing/Enter/clicks under autopilot while keeping high-impact and password R3',
        () {
      // Enter key to submit IDE prompt without known focusedRole
      final enterAuto = classifyInputStepRisk(
        toolName: 'input.key',
        arguments: const <String, Object?>{'combo': 'Enter'},
        focusedRole: null,
        autopilot: true,
      );
      expect(enterAuto.risk, RiskTier.r2);

      final enterStd = classifyInputStepRisk(
        toolName: 'input.key',
        arguments: const <String, Object?>{'combo': 'Enter'},
        focusedRole: null,
        autopilot: false,
      );
      expect(enterStd.risk, RiskTier.r3);

      // Headed typing with newline under autopilot
      final typeAuto = classifyInputStepRisk(
        toolName: 'input.type_text',
        arguments: const <String, Object?>{
          'text': 'Check progress\nnext line',
          'headed': true,
        },
        liveTarget: const <String, Object?>{'role': 'group', 'name': 'Prompt'},
        autopilot: true,
      );
      expect(typeAuto.risk, RiskTier.r2);

      // Password field MUST stay forbidden under autopilot
      final pwAuto = classifyInputStepRisk(
        toolName: 'input.type_text',
        arguments: const <String, Object?>{'text': 'secret'},
        liveTarget: const <String, Object?>{
          'role': 'password',
          'name': 'Password',
          'isPassword': true,
        },
        autopilot: true,
      );
      expect(pwAuto.risk, RiskTier.r3);
      expect(pwAuto.reasonCode, 'password_field_forbidden');

      // High-impact click ("Send" / "Thanh toán" / "Delete") MUST stay R3 under autopilot
      for (final label in <String>[
        'Send',
        'Gửi',
        'Thanh toán',
        'Delete',
        'Đăng bài'
      ]) {
        final clickRisk = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{'elementId': '@s1:e1'},
          liveTarget: <String, Object?>{'role': 'button', 'name': label},
          autopilot: true,
        );
        expect(clickRisk.risk, RiskTier.r3, reason: 'Expected R3 for "$label"');
      }

      // Ordinary click (Submit / Confirm / unlabeled coord) runs at R2 under autopilot
      final submitRisk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{'elementId': '@s1:e1'},
        liveTarget: const <String, Object?>{'role': 'button', 'name': 'Submit'},
        autopilot: true,
      );
      expect(submitRisk.risk, RiskTier.r2);

      final coordRisk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{'xNorm': 0.5, 'yNorm': 0.5},
        liveTarget: null,
        autopilot: true,
      );
      expect(coordRisk.risk, RiskTier.r2);
    });

    test(
        'web.click relaxes bare Confirm under autopilot while keeping Pay/Send/Password R3',
        () {
      final autopilotEval =
          HostPolicyEvaluator.healthy(_buildPolicy(TrustPreset.autopilot));

      final confirmClick = autopilotEval.evaluateInvocation(
        toolName: 'web.click',
        arguments: const <String, Object?>{
          'ref': 'e1',
          'targetText': 'Confirm',
        },
        approval: null,
      );
      expect(confirmClick.allowed, isTrue);
      expect(confirmClick.effectiveRisk, RiskTier.r2);

      final payClick = autopilotEval.evaluateInvocation(
        toolName: 'web.click',
        arguments: const <String, Object?>{
          'ref': 'e2',
          'targetText': 'Thanh toán',
        },
        approval: null,
      );
      expect(payClick.allowed, isFalse);
      expect(payClick.effectiveRisk, RiskTier.r3);
      expect(payClick.errorCode, 'approval_required');
    });
  });
}

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Wave C XTP Layer — Descriptors & Schemas', () {
    test('ui.observe_hybrid and input.drag are registered with proper families', () {
      final cuTools = buildComputerUseTools();
      final observeHybrid = cuTools.firstWhere((t) => t.name == 'ui.observe_hybrid');
      expect(observeHybrid.policy.family, ToolFamily.ui);
      expect(observeHybrid.policy.risk, RiskTier.r2);
      expect(observeHybrid.policy.observes, isTrue);

      final drag = cuTools.firstWhere((t) => t.name == 'input.drag');
      expect(drag.policy.family, ToolFamily.input);
      expect(drag.policy.risk, RiskTier.r2);
      expect(drag.policy.observes, isFalse);

      expect(resolveToolFamilyForName('ui.observe_hybrid'), ToolFamily.ui);
      expect(resolveToolFamilyForName('input.drag'), ToolFamily.input);
    });

    test('effectOutputSchema includes settled and settleMs telemetry', () {
      final cuTools = buildComputerUseTools();
      final click = cuTools.firstWhere((t) => t.name == 'input.click');
      final outputProps = (click.outputSchema['properties'] as Map<String, Object?>);
      expect(outputProps.containsKey('settled'), isTrue);
      expect(outputProps.containsKey('settleMs'), isTrue);
    });

    test('input.click inputSchema accepts optional xNorm and yNorm', () {
      final cuTools = buildComputerUseTools();
      final click = cuTools.firstWhere((t) => t.name == 'input.click');
      final inputProps = (click.inputSchema['properties'] as Map<String, Object?>);
      expect(inputProps.containsKey('xNorm'), isTrue);
      expect(inputProps.containsKey('yNorm'), isTrue);
    });
  });

  group('Wave C XTP Layer — Policy & Evaluator Invariants', () {
    const cuPolicyJson = '''
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow",
    "cu": "allow",
    "screen": "allow",
    "ui": "allow",
    "input": "allow"
  },
  "apps": [
    {
      "id": "vscode",
      "name": "VS Code",
      "kind": "exe",
      "target": "C:\\\\Program Files\\\\Microsoft VS Code\\\\Code.exe",
      "risk": "R2"
    }
  ],
  "urlDomains": ["github.com"],
  "workflows": [],
  "players": []
}
''';
    final evaluator = HostPolicyEvaluator.fromJsonString(cuPolicyJson);

    test('ui.observe_hybrid requires active CU session and validates args', () {
      final denied = evaluator.evaluateInvocation(
        toolName: 'ui.observe_hybrid',
        arguments: const <String, Object?>{'scope': 'active_window'},
        isInApprovedCuSession: false,
      );
      expect(denied.allowed, isFalse);
      expect(denied.errorCode, 'cu_session_required');

      final ok = evaluator.evaluateInvocation(
        toolName: 'ui.observe_hybrid',
        arguments: const <String, Object?>{
          'scope': 'active_window',
          'maxNodes': 150,
          'maxEdge': 1024,
        },
        isInApprovedCuSession: true,
      );
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      final badScope = evaluator.evaluateInvocation(
        toolName: 'ui.observe_hybrid',
        arguments: const <String, Object?>{'scope': 'screen'},
        isInApprovedCuSession: true,
      );
      expect(badScope.allowed, isFalse);
      expect(badScope.errorCode, 'schema_mismatch');

      final badEdge = evaluator.evaluateInvocation(
        toolName: 'ui.observe_hybrid',
        arguments: const <String, Object?>{
          'scope': 'active_window',
          'maxEdge': 2000,
        },
        isInApprovedCuSession: true,
      );
      expect(badEdge.allowed, isFalse);
      expect(badEdge.errorCode, 'schema_mismatch');
    });

    test('input.click accepts valid xNorm and yNorm coordinates', () {
      final ok = evaluator.evaluateInvocation(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.5,
          'yNorm': 0.75,
        },
        isInApprovedCuSession: true,
      );
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      final outOfBounds = evaluator.evaluateInvocation(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 1.05,
          'yNorm': 0.5,
        },
        isInApprovedCuSession: true,
      );
      expect(outOfBounds.allowed, isFalse);
      expect(outOfBounds.errorCode, 'schema_mismatch');

      final missingPair = evaluator.evaluateInvocation(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.5,
        },
        isInApprovedCuSession: true,
      );
      expect(missingPair.allowed, isFalse);
      expect(missingPair.errorCode, 'schema_mismatch');
    });

    test('input.drag validates normalized coordinates and duration', () {
      final ok = evaluator.evaluateInvocation(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.1,
          'fromYNorm': 0.2,
          'toXNorm': 0.8,
          'toYNorm': 0.9,
          'durationMs': 400,
        },
        isInApprovedCuSession: true,
      );
      expect(ok.allowed, isTrue);
      expect(ok.effectiveRisk, RiskTier.r2);

      final badDuration = evaluator.evaluateInvocation(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.1,
          'fromYNorm': 0.2,
          'toXNorm': 0.8,
          'toYNorm': 0.9,
          'durationMs': 6000,
        },
        isInApprovedCuSession: true,
      );
      expect(badDuration.allowed, isFalse);
      expect(badDuration.errorCode, 'schema_mismatch');
    });
  });

  group('Wave C XTP Layer — Reverse Hit-Test & Input Step Risk Policy', () {
    final liveTree = <Map<String, Object?>>[
      <String, Object?>{
        'id': 'ui_root',
        'role': 'window',
        'bounds': <double>[0.0, 0.0, 1.0, 1.0],
      },
      <String, Object?>{
        'id': 'ui_login_field',
        'role': 'textfield',
        'name': 'Username',
        'editable': true,
        'bounds': <double>[0.1, 0.2, 0.5, 0.28],
      },
      <String, Object?>{
        'id': 'ui_pass_field',
        'role': 'secure_textfield',
        'name': 'Password',
        'isPassword': true,
        'bounds': <double>[0.1, 0.35, 0.5, 0.43],
      },
      <String, Object?>{
        'id': 'ui_pay_btn',
        'role': 'button',
        'name': 'Thanh toán ngay',
        'bounds': <double>[0.1, 0.6, 0.4, 0.68],
      },
      <String, Object?>{
        'id': 'ui_cancel_btn',
        'role': 'button',
        'name': 'Cancel',
        'bounds': <double>[0.5, 0.6, 0.8, 0.68],
      },
    ];

    test('hitTestNodeAtCoordinates selects the smallest containing leaf node', () {
      final hitPass = hitTestNodeAtCoordinates(
        nodes: liveTree,
        xNorm: 0.2,
        yNorm: 0.38,
      );
      expect(hitPass?['id'], 'ui_pass_field');

      final hitOutsideLeaf = hitTestNodeAtCoordinates(
        nodes: liveTree,
        xNorm: 0.95,
        yNorm: 0.95,
      );
      expect(hitOutsideLeaf?['id'], 'ui_root');
    });

    test('coordinate click on password field is hard denied (password_field_forbidden)', () {
      final risk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.2,
          'yNorm': 0.38,
        },
        activeWindowNodes: liveTree,
      );
      expect(risk.risk, RiskTier.r3);
      expect(risk.reasonCode, 'password_field_forbidden');
    });

    test('coordinate click on consequential button elevates to R3 (consequential_target)', () {
      final risk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.25,
          'yNorm': 0.64,
        },
        activeWindowNodes: liveTree,
      );
      expect(risk.risk, RiskTier.r3);
      expect(risk.reasonCode, 'consequential_target');
    });

    test('coordinate click with uncommitted draft escalates to R3 unless verified editable text', () {
      // Click on cancel button while draft text is pending -> escalates to R3 unclassified_target
      final clickBtnRisk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.6,
          'yNorm': 0.64,
        },
        hasUncommittedDraft: true,
        activeWindowNodes: liveTree,
      );
      expect(clickBtnRisk.risk, RiskTier.r3);
      expect(clickBtnRisk.reasonCode, 'unclassified_target');

      // Click on safe editable textfield while draft text is pending -> stays R2 navigation_target
      final clickTextRisk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.2,
          'yNorm': 0.24,
        },
        hasUncommittedDraft: true,
        activeWindowNodes: liveTree,
      );
      expect(clickTextRisk.risk, RiskTier.r2);
      expect(clickTextRisk.reasonCode, 'navigation_target');
    });

    test('coordinate click without hit node escalates to R3 (unclassified_target)', () {
      final risk = classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'xNorm': 0.05,
          'yNorm': 0.05,
        },
        activeWindowNodes: const <Map<String, Object?>>[],
      );
      expect(risk.risk, RiskTier.r3);
      expect(risk.reasonCode, 'unclassified_target');
    });

    test('input.drag evaluates password refusal, consequential elevation, and draft protection', () {
      // Drag ending in password field
      final dragToPass = classifyInputStepRisk(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.6,
          'fromYNorm': 0.64,
          'toXNorm': 0.2,
          'toYNorm': 0.38,
        },
        activeWindowNodes: liveTree,
      );
      expect(dragToPass.risk, RiskTier.r3);
      expect(dragToPass.reasonCode, 'password_field_forbidden');

      // Drag hitting consequential target
      final dragToPay = classifyInputStepRisk(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.6,
          'fromYNorm': 0.64,
          'toXNorm': 0.25,
          'toYNorm': 0.64,
        },
        activeWindowNodes: liveTree,
      );
      expect(dragToPay.risk, RiskTier.r3);
      expect(dragToPay.reasonCode, 'consequential_target');

      // Drag while draft text is pending
      final dragDraft = classifyInputStepRisk(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.55,
          'fromYNorm': 0.64,
          'toXNorm': 0.75,
          'toYNorm': 0.64,
        },
        hasUncommittedDraft: true,
        activeWindowNodes: liveTree,
      );
      expect(dragDraft.risk, RiskTier.r3);
      expect(dragDraft.reasonCode, 'unclassified_target');

      // Safe drag between benign targets
      final safeDrag = classifyInputStepRisk(
        toolName: 'input.drag',
        arguments: const <String, Object?>{
          'fromXNorm': 0.55,
          'fromYNorm': 0.64,
          'toXNorm': 0.75,
          'toYNorm': 0.64,
        },
        hasUncommittedDraft: false,
        activeWindowNodes: liveTree,
      );
      expect(safeDrag.risk, RiskTier.r2);
      expect(safeDrag.reasonCode, 'navigation_target');
    });
  });
}

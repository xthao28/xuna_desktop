import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Wave C XTP Layer — Descriptors & Schemas', () {
    test('ui.observe_hybrid and input.drag are registered with proper families',
        () {
      final cuTools = buildComputerUseTools();
      final observeHybrid =
          cuTools.firstWhere((t) => t.name == 'ui.observe_hybrid');
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
      final outputProps =
          (click.outputSchema['properties'] as Map<String, Object?>);
      expect(outputProps.containsKey('settled'), isTrue);
      expect(outputProps.containsKey('settleMs'), isTrue);
      final settleSchema = outputProps['settleMs']! as Map<String, Object?>;
      expect(settleSchema['maximum'], equals(600));
    });

    test('input.click inputSchema accepts optional xNorm and yNorm', () {
      final cuTools = buildComputerUseTools();
      final click = cuTools.firstWhere((t) => t.name == 'input.click');
      final inputProps =
          (click.inputSchema['properties'] as Map<String, Object?>);
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

    test(
      'UDC-19 evaluator accepts clickCount/button/hover/menuPath on input.click and openTarget on app.launch',
      () {
        final dblClick = evaluator.evaluateInvocation(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'elementId': '@s00000001:e7',
            'clickCount': 2,
            'button': 'left',
          },
          isInApprovedCuSession: true,
        );
        expect(dblClick.allowed, isTrue);
        expect(dblClick.effectiveRisk, RiskTier.r2);

        final hoverClick = evaluator.evaluateInvocation(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'elementId': '@s00000001:e7',
            'hover': true,
          },
          isInApprovedCuSession: true,
        );
        expect(hoverClick.allowed, isTrue);

        final safeMenu = evaluator.evaluateInvocation(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'menuPath': 'File > Open Folder...',
          },
          isInApprovedCuSession: true,
        );
        expect(safeMenu.allowed, isTrue);
        expect(safeMenu.effectiveRisk, RiskTier.r2);

        final quitMenu = evaluator.evaluateInvocation(
          toolName: 'input.click',
          arguments: const <String, Object?>{'menuPath': 'File > Quit'},
          isInApprovedCuSession: true,
        );
        expect(quitMenu.allowed, isFalse);
        expect(quitMenu.effectiveRisk, RiskTier.r3);
        expect(quitMenu.errorCode, 'approval_required');

        final badClicks = evaluator.evaluateInvocation(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'elementId': '@s00000001:e7',
            'clickCount': 5,
          },
          isInApprovedCuSession: true,
        );
        expect(badClicks.allowed, isFalse);
        expect(badClicks.errorCode, 'schema_mismatch');

        final launchWithTarget = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{
            'id': 'visual-studio-code',
            'openTarget': 'xuna_pet',
          },
          isInApprovedCuSession: true,
          allowZeroConfigAppDiscovery: true,
          cuSessionApprovedApps: const <String>{'visual-studio-code'},
        );
        expect(launchWithTarget.allowed, isTrue);
        expect(launchWithTarget.effectiveRisk, RiskTier.r2);
      },
    );
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

    test('hitTestNodeAtCoordinates selects the smallest containing leaf node',
        () {
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

    test(
        'coordinate click on password field is hard denied (password_field_forbidden)',
        () {
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

    test(
        'coordinate click on consequential button elevates to R3 (consequential_target)',
        () {
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

    test(
        'coordinate click with uncommitted draft escalates to R3 unless verified editable text',
        () {
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

    test(
        'coordinate click without hit node escalates to R3 (unclassified_target)',
        () {
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

    test(
        'input.drag evaluates password refusal, consequential elevation, and draft protection',
        () {
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

    test(
      'UDC-19 universal searchbox draft roles, menuPath risk gating, and hover/clickCount schemas',
      () {
        // 1. Editable searchbox/searchfield is R2 draft_text, while non-editable combobox picker stays R3
        final searchBoxDraft = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{
            'elementId': 'ui_3',
            'text': 'search query',
          },
          liveTarget: const <String, Object?>{
            'id': 'ui_3',
            'role': 'searchbox',
            'name': 'Quick Input',
            'editable': true,
          },
          draftCharsRemaining: 500,
        );
        expect(searchBoxDraft.risk, RiskTier.r2);
        expect(searchBoxDraft.reasonCode, 'draft_text');

        final searchBoxEnter = classifyInputStepRisk(
          toolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Enter'},
          focusedRole: 'searchbox',
        );
        expect(searchBoxEnter.risk, RiskTier.r2);

        // 2. OS menuPath classification: safe navigation R2 vs destructive/commit R3
        final safeMenu = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'menuPath': 'File > Open Folder...',
          },
        );
        expect(safeMenu.risk, RiskTier.r2);
        expect(safeMenu.reasonCode, 'navigation_target');

        for (final dangerous in const <String>[
          'File > Quit',
          'Finder > Empty Trash...',
          'Message > Send',
          'Tệp > Xóa vĩnh viễn',
        ]) {
          final r3Menu = classifyInputStepRisk(
            toolName: 'input.click',
            arguments: <String, Object?>{'menuPath': dangerous},
          );
          expect(r3Menu.risk, RiskTier.r3, reason: dangerous);
          expect(r3Menu.reasonCode, 'consequential_target', reason: dangerous);
        }

        final draftMenu = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{'menuPath': 'View > Appearance'},
          hasUncommittedDraft: true,
        );
        expect(draftMenu.risk, RiskTier.r3);

        // 3. Hover without target fails closed; hover on coordinates is R2 unless password
        final missingHover = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{'hover': true},
        );
        expect(missingHover.risk, RiskTier.r3);

        final coordHover = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{
            'xNorm': 0.5,
            'yNorm': 0.5,
            'hover': true,
          },
        );
        expect(coordHover.risk, RiskTier.r2);

        // 4. Schemas expose universal openTarget on app.launch and clickCount/button/hover/menuPath on input.click
        final mvpTools = buildMvpToolCatalog();
        final appLaunch = mvpTools.firstWhere((t) => t.name == 'app.launch');
        final launchProps =
            appLaunch.inputSchema['properties']! as Map<String, Object?>;
        expect(launchProps.containsKey('openTarget'), isTrue);

        final cuTools = buildComputerUseTools();
        final inputClick = cuTools.firstWhere((t) => t.name == 'input.click');
        final clickProps =
            inputClick.inputSchema['properties']! as Map<String, Object?>;
        expect(clickProps.containsKey('clickCount'), isTrue);
        expect(clickProps.containsKey('button'), isTrue);
        expect(clickProps.containsKey('hover'), isTrue);
        expect(clickProps.containsKey('menuPath'), isTrue);
      },
    );

    test(
      'M3 redactUiTreeNodes preserves finite 4-element List bounds through filtering, strips password bounds, and sanitizes malformed bounds',
      () {
        final inputBounds = <double>[0.1, 0.2, 0.3, 0.4];
        final rawNodes = <Map<String, Object?>>[
          <String, Object?>{
            'id': 'wrap_1',
            'role': 'group',
            'name': '',
            'depth': 1,
            'bounds': <double>[0.0, 0.0, 1.0, 1.0],
          },
          <String, Object?>{
            'id': 'btn_1',
            'role': 'button',
            'name': 'Play',
            'depth': 1,
            'bounds': inputBounds,
          },
          <String, Object?>{
            'id': 'deep_text',
            'role': 'text',
            'name': 'Deep detail',
            'depth': 4,
            'bounds': <double>[0.5, 0.5, 0.9, 0.9],
          },
          <String, Object?>{
            'id': 'pwd_1',
            'role': 'AXSecureTextField',
            'name': 'Secret PIN',
            'value': '1234',
            'depth': 1,
            'bounds': <double>[0.2, 0.6, 0.7, 0.68],
          },
          <String, Object?>{
            'id': 'pwd_map',
            'role': 'textfield',
            'name': 'Mật khẩu',
            'isPassword': true,
            'depth': 1,
            'bounds': <String, Object?>{
              'x': 10,
              'y': 20,
              'width': 100,
              'height': 30
            },
          },
          <String, Object?>{
            'id': 'bad_len',
            'role': 'button',
            'name': 'Short bounds',
            'depth': 1,
            'bounds': <double>[0.1, 0.2],
          },
          <String, Object?>{
            'id': 'bad_nan',
            'role': 'button',
            'name': 'NaN bounds',
            'depth': 1,
            'bounds': <double>[0.1, double.nan, 0.5, 0.8],
          },
          <String, Object?>{
            'id': 'bad_inf',
            'role': 'button',
            'name': 'Inf bounds',
            'depth': 1,
            'bounds': <double>[0.1, 0.2, double.infinity, 0.8],
          },
          <String, Object?>{
            'id': 'bad_str',
            'role': 'button',
            'name': 'Str bounds',
            'depth': 1,
            'bounds': <Object?>[0.1, 'secret', 0.5, 0.8],
          },
          <String, Object?>{
            'id': 'pixel_btn',
            'role': 'button',
            'name': 'Pixel Coords',
            'depth': 1,
            'bounds': <int>[100, 200, 300, 280],
          },
        ];

        final redacted = redactUiTreeNodes(
          rawNodes,
          snapshotId: 's0000000b',
          collapseWebWrappers: true,
          skeleton: true,
          interactiveOnly: true,
        );

        // wrap_1 (transparent wrapper) and deep_text (skeleton depth 4 + non-interactive) are skipped.
        expect(redacted, hasLength(8));
        expect(redacted[0]['id'], 'btn_1');
        expect(redacted[0]['ref'], '@s0000000b:e1');
        expect(redacted[0]['bounds'], <double>[0.1, 0.2, 0.3, 0.4]);

        // Returned List bounds must be a fresh copy (mutating it does not alias inputBounds).
        (redacted[0]['bounds']! as List<double>)[0] = 0.99;
        expect(inputBounds[0], 0.1);

        // Password nodes strip both List and Map bounds, value, and set masked role/name.
        expect(redacted[1]['id'], 'pwd_1');
        expect(redacted[1]['ref'], '@s0000000b:e2');
        expect(redacted[1]['role'], 'password');
        expect(redacted[1]['name'], '•••');
        expect(redacted[1]['isPassword'], isTrue);
        expect(redacted[1].containsKey('value'), isFalse);
        expect(redacted[1].containsKey('bounds'), isFalse);

        expect(redacted[2]['id'], 'pwd_map');
        expect(redacted[2]['role'], 'password');
        expect(redacted[2].containsKey('bounds'), isFalse);

        // Malformed List bounds are omitted safely and argsSha256 succeeds without FormatException.
        expect(redacted[3].containsKey('bounds'), isFalse);
        expect(redacted[4].containsKey('bounds'), isFalse);
        expect(redacted[5].containsKey('bounds'), isFalse);
        expect(redacted[6].containsKey('bounds'), isFalse);

        // Pixel int List bounds (> 1.0) are preserved as List<double> for stateDigest compatibility.
        expect(redacted[7]['id'], 'pixel_btn');
        expect(redacted[7]['bounds'], isA<List<double>>());
        expect(redacted[7]['bounds'], <double>[100.0, 200.0, 300.0, 280.0]);

        expect(() => argsSha256(<String, Object?>{'nodes': redacted}),
            returnsNormally);
      },
    );

    test(
      'M3 ui.observe_hybrid and screen.capture schemas remain strict',
      () {
        final cuTools = buildComputerUseTools();
        final observeHybrid =
            cuTools.firstWhere((t) => t.name == 'ui.observe_hybrid');
        expect(observeHybrid.outputSchema['additionalProperties'], isFalse);
        final outProps =
            observeHybrid.outputSchema['properties']! as Map<String, Object?>;
        expect((outProps['nodes']! as Map<String, Object?>)['type'], 'array');
        expect(outProps.containsKey('somCount'), isFalse);
        expect(outProps.containsKey('somAnnotated'), isFalse);

        final screenCapture =
            cuTools.firstWhere((t) => t.name == 'screen.capture');
        final inProps =
            screenCapture.inputSchema['properties']! as Map<String, Object?>;
        expect(screenCapture.inputSchema['additionalProperties'], isFalse);
        expect(inProps.containsKey('somMarks'), isFalse);
      },
    );

    test(
      'M3 Iteration 2 redactUiTreeNodes preserves offscreen, prevents empty-id subtree leak, sanitizes Map bounds, and deduplicates pre-existing ref indices',
      () {
        final inputMapBounds = <String, Object?>{
          'x': 10,
          'y': 20,
          'width': 100,
          'height': 40,
        };
        final redacted = redactUiTreeNodes(
          <Map<String, Object?>>[
            <String, Object?>{
              'id': 's00000001:2',
              'role': 'button',
              'name': 'Scrolled Offscreen',
              'offscreen': true,
              'bounds': <double>[0.1, 0.1, 0.3, 0.2],
            },
            <String, Object?>{
              'id': 'plain_btn_2',
              'role': 'button',
              'name': 'Colliding Index 2',
              'bounds': inputMapBounds,
            },
            <String, Object?>{
              'id': 'bad_map_nan',
              'role': 'button',
              'name': 'NaN Map',
              'bounds': <String, Object?>{
                'x': 10,
                'y': double.nan,
                'width': 50,
                'height': 20,
              },
            },
            <String, Object?>{
              'id': 'bad_map_inf',
              'role': 'button',
              'name': 'Inf Map',
              'bounds': <String, Object?>{
                'x': 10,
                'y': 20,
                'width': double.infinity,
                'height': 20,
              },
            },
          ],
          snapshotId: 's00000003',
        );

        expect(redacted, hasLength(4));
        expect(redacted[0]['offscreen'], isTrue);
        expect(redacted[0]['ref'], '@s00000003:e2');
        expect(redacted[1]['ref'], '@s00000003:e3');
        expect(redacted[1]['bounds'], isA<Map<String, double>>());
        (redacted[1]['bounds']! as Map<String, double>)['x'] = 999.0;
        expect(inputMapBounds['x'], 10);
        expect(redacted[2].containsKey('bounds'), isFalse);
        expect(redacted[3].containsKey('bounds'), isFalse);
        expect(() => argsSha256(<String, Object?>{'nodes': redacted}),
            returnsNormally);

        // Pre-existing s00000001:7 at index 0 still keeps @s<id>:e7.
        final keepSeven = redactUiTreeNodes(
          <Map<String, Object?>>[
            <String, Object?>{
              'id': 's00000001:7',
              'role': 'button',
              'name': 'Seven'
            },
            <String, Object?>{'id': 'other', 'role': 'button', 'name': 'Other'},
          ],
          snapshotId: 's00000002',
        );
        expect(keepSeven[0]['ref'], '@s00000002:e7');
        expect(keepSeven[1]['ref'], '@s00000002:e2');

        // Empty-id descendant in Panel A must not leak unrelated empty-id nodes in Panel B.
        final scoped = redactUiTreeNodes(
          <Map<String, Object?>>[
            <String, Object?>{
              'id': 'panel_a',
              'role': 'group',
              'name': 'Panel A'
            },
            <String, Object?>{
              'id': '',
              'parentId': 'panel_a',
              'role': 'button',
              'name': 'Child in A',
            },
            <String, Object?>{
              'id': 'panel_b',
              'role': 'group',
              'name': 'Panel B'
            },
            <String, Object?>{
              'id': '',
              'parentId': 'panel_b',
              'role': 'button',
              'name': 'Unrelated Child in B',
            },
          ],
          rootElementId: 'panel_a',
        );
        expect(
          scoped.map((n) => n['name']).toList(),
          <String>['Panel A', 'Child in A'],
        );
      },
    );
  });
}

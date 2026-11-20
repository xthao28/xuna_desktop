import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Wave A Desktop Policy & Risk Tests', () {
    // =========================================================================
    // Tier 1: Feature Coverage (F7, F8, F9)
    // =========================================================================

    group('Tier 1 - Feature F7: Modern Terminal & System Settings Hard-Denial',
        () {
      test(
          'T1-F7.1: isHardDeniedAppOrProcess strictly denies all 9 modern terminals',
          () {
        const modernTerminals = <String>[
          'warp',
          'alacritty',
          'kitty',
          'wezterm',
          'wezterm-gui',
          'ghostty',
          'hyper',
          'terminal',
          'iterm',
          'iterm2',
        ];

        for (final term in modernTerminals) {
          expect(isHardDeniedAppOrProcess(term), isTrue, reason: 'Deny $term');
          expect(isHardDeniedAppOrProcess('$term.app'), isTrue,
              reason: 'Deny $term.app');
          expect(isHardDeniedAppOrProcess('$term.exe'), isTrue,
              reason: 'Deny $term.exe');
          expect(isHardDeniedAppOrProcess(term.toUpperCase()), isTrue,
              reason: 'Deny uppercase $term');
        }

        // Explicit verification of wezterm-gui and wezterm-gui.exe binaries and casing
        expect(isHardDeniedAppOrProcess('wezterm-gui'), isTrue,
            reason: 'Deny wezterm-gui');
        expect(isHardDeniedAppOrProcess('wezterm-gui.exe'), isTrue,
            reason: 'Deny wezterm-gui.exe');
        expect(isHardDeniedAppOrProcess('WEZTERM-GUI'), isTrue,
            reason: 'Deny uppercase WEZTERM-GUI');
        expect(isHardDeniedAppOrProcess('WEZTERM-GUI.EXE'), isTrue,
            reason: 'Deny uppercase WEZTERM-GUI.EXE');
      });

      test(
          'T1-F7.2: isHardDeniedAppOrProcess denies bundle identifiers of modern terminals',
          () {
        const terminalBundleIds = <String>[
          'dev.warp.warp-stable',
          'org.alacritty',
          'net.kovidgoyal.kitty',
          'com.github.wez.wezterm',
          'com.mitchellh.ghostty',
          'co.zeit.hyper',
          'com.apple.terminal',
          'com.googlecode.iterm2',
        ];

        for (final bundle in terminalBundleIds) {
          expect(isHardDeniedAppOrProcess(bundle), isTrue,
              reason: 'Deny bundle $bundle');
          expect(isHardDeniedAppOrProcess(bundle.toUpperCase()), isTrue,
              reason: 'Deny uppercase bundle $bundle');
        }
      });

      test(
          'T1-F7.3: isHardDeniedAppOrProcess strictly denies system settings panes',
          () {
        const settingsPanes = <String>[
          'com.apple.systemsettings',
          'system_settings',
          'system settings',
          'system-settings',
          'system preferences',
          'com.apple.systempreferences',
          'systemsettings',
          'systemsettings.exe',
          'com.apple.settings',
        ];

        for (final pane in settingsPanes) {
          expect(isHardDeniedAppOrProcess(pane), isTrue,
              reason: 'Deny settings pane $pane');
          expect(isHardDeniedAppOrProcess(pane.toUpperCase()), isTrue,
              reason: 'Deny uppercase pane $pane');
        }
      });

      test(
          'T1-F7.4: isHardDeniedAppOrProcess denies absolute paths to terminal emulators',
          () {
        const paths = <String>[
          '/Applications/Warp.app',
          '/Applications/Warp.app/',
          r'C:\Tools\warp.exe\',
          '/Applications/Alacritty.app',
          '/Applications/Alacritty.app/',
          '/Applications/Ghostty.app',
          '/Applications/Ghostty.app/',
          '/usr/bin/kitty',
          '/usr/local/bin/wezterm',
          '/usr/local/bin/wezterm-gui',
          r'C:\Program Files\WezTerm\wezterm-gui.exe',
          r'C:\Program Files\Hyper\hyper.exe',
          r'C:\Windows\System32\cmd.exe',
          '/bin/bash',
          '/bin/zsh',
        ];

        for (final p in paths) {
          expect(isHardDeniedAppOrProcess(p), isTrue, reason: 'Deny path $p');
        }

        expect(isHardDeniedAppOrProcess('/Applications/Warp.app/'), isTrue);
        expect(isHardDeniedAppOrProcess(r'C:\Tools\warp.exe\'), isTrue);
      });

      test(
          'T1-F7.5: isHardDeniedAppOrProcess permits benign applications and fails closed on empty',
          () {
        const safeApps = <String>[
          'notes',
          'com.apple.Notes',
          'calculator',
          'com.apple.calculator',
          'safari',
          'com.apple.Safari',
          'code',
          'com.microsoft.VSCode',
          'slack',
          'com.tinyspeck.slackmacgap',
        ];

        for (final app in safeApps) {
          expect(isHardDeniedAppOrProcess(app), isFalse,
              reason: 'Allow safe app $app');
        }

        // Fail-closed on null / empty
        expect(isHardDeniedAppOrProcess(null), isTrue,
            reason: 'Null fails closed');
        expect(isHardDeniedAppOrProcess(''), isTrue,
            reason: 'Empty string fails closed');
        expect(isHardDeniedAppOrProcess('   '), isTrue,
            reason: 'Whitespace fails closed');
      });
    });

    group('Tier 1 - Feature F8: Trust Presets and Host Policy Evaluation', () {
      test('T1-F8.1: TrustPreset enum defines strict, standard, autopilot', () {
        expect(
            TrustPreset.values,
            containsAll(<TrustPreset>[
              TrustPreset.strict,
              TrustPreset.standard,
              TrustPreset.autopilot,
            ]));
        expect(TrustPreset.fromValue('strict'), equals(TrustPreset.strict));
        expect(TrustPreset.fromValue('standard'), equals(TrustPreset.standard));
        expect(
            TrustPreset.fromValue('autopilot'), equals(TrustPreset.autopilot));
        expect(() => TrustPreset.fromValue('unknown'), throwsFormatException);
        expect(() => TrustPreset.fromValue('admin'), throwsFormatException);
      });

      test(
          'T1-F8.2: HostPolicy defaults to TrustPreset.standard when unspecified',
          () {
        final policyMap = <String, Object?>{
          'schemaVersion': 1,
          'families': <String, Object?>{
            'cu': 'allow',
            'screen': 'allow',
            'ui': 'allow',
            'input': 'allow',
          },
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
        };

        final policy = HostPolicy.fromJson(policyMap);
        expect(policy.trustPreset, equals(TrustPreset.standard));
      });

      test(
          'T1-F8.3: HostPolicy preserves explicit trustPreset across serialization roundtrip',
          () {
        for (final preset in TrustPreset.values) {
          final policyMap = <String, Object?>{
            'schemaVersion': 1,
            'trustPreset': preset.value,
            'families': <String, Object?>{'cu': 'allow'},
            'apps': <Object?>[],
            'urlDomains': <Object?>[],
            'workflows': <Object?>[],
            'players': <Object?>[],
          };

          final policy = HostPolicy.fromJson(policyMap);
          expect(policy.trustPreset, equals(preset));

          final serialized = policy.toJson();
          expect(serialized['trustPreset'], equals(preset.value));

          final roundtripped = HostPolicy.fromJson(serialized);
          expect(roundtripped.trustPreset, equals(preset));
        }
      });

      test(
          'T1-F8.3b: HostPolicy.fromJson rejects non-string trustPreset with FormatException',
          () {
        expect(
          () => HostPolicy.fromJson(<String, Object?>{
            'schemaVersion': 1,
            'trustPreset': 123,
          }),
          throwsFormatException,
        );

        expect(
          () => HostPolicy.fromJson(<String, Object?>{
            'schemaVersion': 1,
            'trustPreset': 123,
            'families': <String, Object?>{'cu': 'allow'},
            'apps': <Object?>[],
            'urlDomains': <Object?>[],
            'workflows': <Object?>[],
            'players': <Object?>[],
          }),
          throwsA(isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('Expected string for "trustPreset"'),
          )),
        );
      });

      test(
          'T1-F8.4: HostPolicyEvaluator allows zero-config app discovery in Standard and Autopilot presets',
          () {
        final standardPolicy = HostPolicy(
          schemaVersion: 1,
          trustPreset: TrustPreset.standard,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.app: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
        );

        final evaluator = HostPolicyEvaluator.healthy(standardPolicy);
        // An unlisted, benign app like "notes" evaluated with standard preset
        // should NOT be blocked by policy (errorCode != policy_blocked)
        final evalResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{'id': 'notes'},
        );

        expect(evalResult.errorCode, isNot(equals('policy_blocked')));
        expect(evalResult.errorCode, equals('approval_required'));
        expect(evalResult.effectiveRisk, equals(RiskTier.r2));

        // When provided with an approval token, it succeeds (allowed: true, status: ok)
        final now = DateTime.now().toUtc();
        const launchArgs = <String, Object?>{'id': 'notes'};
        final approvedResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: launchArgs,
          approval: ApprovalToken(
            approvalId: 'b1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
            argsSha256: argsSha256(launchArgs),
            expiresAt: now.add(const Duration(minutes: 5)),
          ),
          nowUtc: now,
        );
        expect(approvedResult.allowed, isTrue);
        expect(approvedResult.status, equals(XtpStatus.ok));
        expect(approvedResult.effectiveRisk, equals(RiskTier.r2));
      });

      test(
          'T1-F8.5: HostPolicyEvaluator strictly blocks unlisted apps in Strict preset',
          () {
        final strictPolicy = HostPolicy(
          schemaVersion: 1,
          trustPreset: TrustPreset.strict,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.app: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
        );

        final evaluator = HostPolicyEvaluator.healthy(strictPolicy);
        final evalResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{'id': 'notes'},
        );

        expect(evalResult.allowed, isFalse);
        expect(evalResult.status, equals(XtpStatus.denied));
        expect(evalResult.errorCode, equals('policy_blocked'));
      });

      test(
          'T1-F8.6: Strict preset blocks unlisted discovered apps even when allowZeroConfigAppDiscovery is true',
          () {
        final strictPolicy = HostPolicy(
          schemaVersion: 1,
          trustPreset: TrustPreset.strict,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.app: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
        );

        final evaluator = HostPolicyEvaluator.healthy(strictPolicy);
        final evalResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{'id': 'unlisted_discovered_app'},
          allowZeroConfigAppDiscovery: true,
        );

        expect(evalResult.allowed, isFalse);
        expect(evalResult.status, equals(XtpStatus.denied));
        expect(evalResult.errorCode, equals('policy_blocked'));
      });

      test(
          'T1-F8.7: In-scope app.launch requires no per-call approval inside active CU session',
          () {
        final policy = HostPolicy(
          schemaVersion: 1,
          trustPreset: TrustPreset.standard,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.app: FamilyPolicyDecision.allow,
          },
          apps: <AllowedAppConfig>[
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

        final evaluator = HostPolicyEvaluator.healthy(policy);

        // In-scope app inside active CU session without approval token succeeds
        final inScopeResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{'id': 'notes'},
          isInApprovedCuSession: true,
        );
        expect(inScopeResult.allowed, isTrue);
        expect(inScopeResult.status, equals(XtpStatus.ok));

        // Unlisted discovered app without approval token is denied with approval_required
        final unlistedResult = evaluator.evaluateInvocation(
          toolName: 'app.launch',
          arguments: const <String, Object?>{'id': 'unlisted_discovered_app'},
          isInApprovedCuSession: true,
          allowZeroConfigAppDiscovery: true,
        );
        expect(unlistedResult.allowed, isFalse);
        expect(unlistedResult.status, equals(XtpStatus.denied));
        expect(unlistedResult.errorCode, equals('approval_required'));
      });
    });

    group('Tier 1 - Feature F9: Desktop Input Step Risk Tuning', () {
      final validDraftTextarea = <String, Object?>{
        'id': 'elem-textarea',
        'role': 'textarea',
        'editable': true,
      };

      final validDraftTextfield = <String, Object?>{
        'id': 'elem-textfield',
        'role': 'textfield',
        'editable': true,
      };

      test(
          'T1-F9.1: input.type_text with newline in draft targets evaluates to R2 draft_text',
          () {
        const multilineTexts = <String>[
          'Hello\nWorld',
          'Line 1\r\nLine 2\r\nLine 3',
          'Cộng hòa xã hội chủ nghĩa Việt Nam\nĐộc lập - Tự do - Hạnh phúc\n\nĐơn xin nghỉ phép',
        ];

        for (final text in multilineTexts) {
          for (final target in <Map<String, Object?>>[
            validDraftTextarea,
            validDraftTextfield
          ]) {
            final risk = classifyInputStepRisk(
              toolName: 'input.type_text',
              arguments: <String, Object?>{'text': text},
              liveTarget: target,
              draftCharsRemaining: 500,
            );

            expect(risk.risk, equals(RiskTier.r2),
                reason: 'Risk for text: $text in ${target['role']}');
            expect(risk.reasonCode, equals('draft_text'));
          }
        }
      });

      test(
          'T1-F9.2: input.key with Enter/Return in draft targets evaluates to R2 draft_line_break',
          () {
        for (final role in const <String>['textarea', 'textfield']) {
          for (final combo in const <String>[
            'Enter',
            'Return',
            'enter',
            'return'
          ]) {
            final risk = classifyInputStepRisk(
              toolName: 'input.key',
              arguments: <String, Object?>{'combo': combo},
              focusedRole: role,
            );

            expect(risk.risk, equals(RiskTier.r2),
                reason: 'Combo $combo in $role');
            expect(risk.reasonCode, equals('draft_line_break'));
          }
        }
      });

      test(
          'T1-F9.3: input.key with Shift+Enter/Shift+Return in draft targets evaluates to R2 draft_line_break',
          () {
        for (final combo in const <String>[
          'Shift+Enter',
          'shift+enter',
          'Shift+Return',
          'shift+return',
        ]) {
          final risk = classifyInputStepRisk(
            toolName: 'input.key',
            arguments: <String, Object?>{'combo': combo},
            focusedRole: 'textarea',
          );

          expect(risk.risk, equals(RiskTier.r2));
          expect(risk.reasonCode, equals('draft_line_break'));
        }
      });

      test(
          'T1-F9.4: input.key with safe editing shortcuts evaluates to R2 editing_key',
          () {
        const safeCombos = <String>[
          'Cmd+N',
          'cmd+n',
          'Cmd+A',
          'cmd+a',
          'Cmd+C',
          'cmd+c',
          'Cmd+V',
          'cmd+v',
          'Ctrl+N',
          'ctrl+n',
          'Ctrl+A',
          'ctrl+a',
          'Ctrl+C',
          'ctrl+c',
          'Ctrl+V',
          'ctrl+v',
        ];

        for (final combo in safeCombos) {
          final risk = classifyInputStepRisk(
            toolName: 'input.key',
            arguments: <String, Object?>{'combo': combo},
            focusedRole: 'any_role',
          );

          expect(risk.risk, equals(RiskTier.r2), reason: 'Editing key $combo');
          expect(risk.reasonCode, equals('editing_key'));
        }
      });

      test(
          'T1-F9.5: Non-draft targets, password fields, and headed typing remain R3',
          () {
        // Null target
        final nullTargetRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'Hello'},
          liveTarget: null,
          draftCharsRemaining: 100,
        );
        expect(nullTargetRisk.risk, equals(RiskTier.r3));
        expect(nullTargetRisk.reasonCode, equals('unclassified_target'));

        // Non-draft role (button)
        final buttonTargetRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'Hello'},
          liveTarget: const <String, Object?>{
            'role': 'button',
            'editable': true
          },
          draftCharsRemaining: 100,
        );
        expect(buttonTargetRisk.risk, equals(RiskTier.r3));
        expect(buttonTargetRisk.reasonCode, equals('unclassified_target'));

        // Password field
        final passwordTargetRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'SecretPass123'},
          liveTarget: const <String, Object?>{
            'role': 'textfield',
            'isPassword': true,
            'editable': true,
          },
          draftCharsRemaining: 100,
        );
        expect(passwordTargetRisk.risk, equals(RiskTier.r3));
        expect(passwordTargetRisk.reasonCode, equals('unclassified_target'));

        // Headed typing
        final headedRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'Hello', 'headed': true},
          liveTarget: validDraftTextarea,
          draftCharsRemaining: 100,
        );
        expect(headedRisk.risk, equals(RiskTier.r3));
        expect(headedRisk.reasonCode, equals('physical_typing'));

        // Enter on button or unknown focus
        final enterOnButtonRisk = classifyInputStepRisk(
          toolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Enter'},
          focusedRole: 'button',
        );
        expect(enterOnButtonRisk.risk, equals(RiskTier.r3));
        expect(enterOnButtonRisk.reasonCode, equals('activation_key'));
      });
    });

    // =========================================================================
    // Tier 2: Boundary & Corner Cases
    // =========================================================================

    group('Tier 2 - Boundary & Corner Cases', () {
      final validDraftTextarea = <String, Object?>{
        'id': 'elem-textarea',
        'role': 'textarea',
        'editable': true,
      };

      test(
          'B1: Empty text, whitespace variations, and Unicode characters in draft typing',
          () {
        const edgeTexts = <String>[
          '',
          '\n',
          '   ',
          '\r\n\t',
          '🌟 Chào bạn! Cảm ơn vì đã hỗ trợ 🇻🇳',
          'Tab\tSeparated\tContent\nNew\tLines',
          'Unicode math: ∀x ∈ ℝ, x² ≥ 0',
        ];

        for (final text in edgeTexts) {
          final risk = classifyInputStepRisk(
            toolName: 'input.type_text',
            arguments: <String, Object?>{'text': text},
            liveTarget: validDraftTextarea,
            draftCharsRemaining: 1000,
          );

          expect(risk.risk, equals(RiskTier.r2),
              reason: 'Safe draft for text: $text');
          expect(risk.reasonCode, equals('draft_text'));
        }
      });

      test(
          'B2: Character draft budget exact boundaries (remaining vs exhausted)',
          () {
        const budget = 10;
        final exactText = 'A' * budget;
        final exceededText = 'A' * (budget + 1);

        // Exact match -> R2
        final exactRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: <String, Object?>{'text': exactText},
          liveTarget: validDraftTextarea,
          draftCharsRemaining: budget,
        );
        expect(exactRisk.risk, equals(RiskTier.r2));
        expect(exactRisk.reasonCode, equals('draft_text'));

        // 1 char over budget -> R3 draft_budget_exceeded
        final exceededRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: <String, Object?>{'text': exceededText},
          liveTarget: validDraftTextarea,
          draftCharsRemaining: budget,
        );
        expect(exceededRisk.risk, equals(RiskTier.r3));
        expect(exceededRisk.reasonCode, equals('draft_budget_exceeded'));

        // Zero budget with non-empty text -> R3
        final zeroBudgetRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'a'},
          liveTarget: validDraftTextarea,
          draftCharsRemaining: 0,
        );
        expect(zeroBudgetRisk.risk, equals(RiskTier.r3));
        expect(zeroBudgetRisk.reasonCode, equals('draft_budget_exceeded'));

        // Null budget -> R3
        final nullBudgetRisk = classifyInputStepRisk(
          toolName: 'input.type_text',
          arguments: const <String, Object?>{'text': 'a'},
          liveTarget: validDraftTextarea,
          draftCharsRemaining: null,
        );
        expect(nullBudgetRisk.risk, equals(RiskTier.r3));
        expect(nullBudgetRisk.reasonCode, equals('draft_budget_exceeded'));
      });

      test('B3: Key combo casing, spacing variations, and navigation keys', () {
        // Editing combos with irregular spacing / casing
        const weirdEditingCombos = <String>[
          'CMD + N',
          'cmd + a',
          '  Ctrl+V  ',
          'ctrl + c',
          'Cmd+n',
        ];

        for (final combo in weirdEditingCombos) {
          final risk = classifyInputStepRisk(
            toolName: 'input.key',
            arguments: <String, Object?>{'combo': combo},
            focusedRole: 'textarea',
          );
          expect(risk.risk, equals(RiskTier.r2),
              reason: 'Editing combo: $combo');
          expect(risk.reasonCode, equals('editing_key'));
        }

        // Search submit Enter
        final searchEnter = classifyInputStepRisk(
          toolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Enter'},
          focusedRole: 'searchfield',
        );
        expect(searchEnter.risk, equals(RiskTier.r2));
        expect(searchEnter.reasonCode, equals('search_submit'));

        // Arrow navigation keys
        for (final nav in const <String>[
          'up',
          'down',
          'left',
          'right',
          'tab',
          'pageup',
          'pagedown'
        ]) {
          final navRisk = classifyInputStepRisk(
            toolName: 'input.key',
            arguments: <String, Object?>{'combo': nav},
            focusedRole: 'textarea',
          );
          expect(navRisk.risk, equals(RiskTier.r2), reason: 'Nav key: $nav');
          expect(navRisk.reasonCode, equals('navigation_key'));
        }

        // Activation keys (Enter, Space) outside draft roles remain R3
        for (final act in const <String>['Enter', 'Return', 'Space']) {
          final actRisk = classifyInputStepRisk(
            toolName: 'input.key',
            arguments: <String, Object?>{'combo': act},
            focusedRole: 'button',
          );
          expect(actRisk.risk, equals(RiskTier.r3),
              reason: 'Activation key: $act');
          expect(actRisk.reasonCode, equals('activation_key'));
        }

        // Multi-key activation combo like Ctrl+Enter outside draft roles remains R3
        final ctrlEnter = classifyInputStepRisk(
          toolName: 'input.key',
          arguments: const <String, Object?>{'combo': 'Ctrl+Enter'},
          focusedRole: 'button',
        );
        expect(ctrlEnter.risk, equals(RiskTier.r3));
        expect(ctrlEnter.reasonCode, equals('activation_key'));
      });

      test(
          'B4: App ID path traversal and shell injection patterns are strictly rejected',
          () {
        // 1. Path traversals targeting terminal emulators are caught by isHardDeniedAppOrProcess
        const terminalTraversals = <String>[
          '../../Applications/Terminal.app',
          '../Warp.app',
          '../../../../bin/bash',
          '../../../../bin/zsh',
          r'..\..\Windows\System32\cmd.exe',
          r'C:\Windows\..\Windows\System32\powershell.exe',
        ];

        for (final pattern in terminalTraversals) {
          expect(isHardDeniedAppOrProcess(pattern), isTrue,
              reason: 'Deny terminal traversal: $pattern');
        }

        // 2. Shell injections, separators, and command chaining in app.launch are rejected by policy validation
        final evaluator = HostPolicyEvaluator.healthy(HostPolicy(
          schemaVersion: 1,
          trustPreset: TrustPreset.standard,
          families: const <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.app: FamilyPolicyDecision.allow,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
        ));

        const injectionPatterns = <String>[
          'com.apple.Terminal/../../../etc/passwd',
          '../../Applications/Terminal.app',
          'notes; rm -rf /',
          'notes; rm -rf',
          'calc && cmd.exe',
          'notes | powershell',
          'warp; echo pwned',
          'alacritty`touch /tmp/hacked`',
          'notes\ncalc',
          'notes\x00calc',
        ];

        for (final inj in injectionPatterns) {
          final res = evaluator.evaluateInvocation(
            toolName: 'app.launch',
            arguments: <String, Object?>{'id': inj},
          );
          expect(res.allowed, isFalse, reason: 'Reject injection: $inj');
          expect(res.status, equals(XtpStatus.invalidArgs),
              reason: 'Invalid args status for: $inj');
          expect(res.errorCode, equals('schema_mismatch'),
              reason: 'Schema mismatch for: $inj');
        }
      });

      test(
          'B5: Corrupted, missing, and additive policy JSON schema verification',
          () {
        // Missing required key 'schemaVersion'
        final missingVersion = <String, Object?>{
          'families': <String, Object?>{'cu': 'allow'},
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
        };
        expect(
            () => HostPolicy.fromJson(missingVersion), throwsFormatException);

        // Missing required key 'families'
        final missingFamilies = <String, Object?>{
          'schemaVersion': 1,
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
        };
        expect(
            () => HostPolicy.fromJson(missingFamilies), throwsFormatException);

        // Unsupported schema version
        final badVersion = <String, Object?>{
          'schemaVersion': 99,
          'families': <String, Object?>{'cu': 'allow'},
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
        };
        expect(() => HostPolicy.fromJson(badVersion), throwsFormatException);

        // Unknown root key outside optionalKeys
        final unknownKey = <String, Object?>{
          'schemaVersion': 1,
          'families': <String, Object?>{'cu': 'allow'},
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
          'unauthorizedExtraKey': true,
        };
        expect(() => HostPolicy.fromJson(unknownKey), throwsFormatException);

        // Additive optional key 'trustPreset' is allowed
        final additiveValid = <String, Object?>{
          'schemaVersion': 1,
          'trustPreset': 'standard',
          'families': <String, Object?>{'cu': 'allow'},
          'apps': <Object?>[],
          'urlDomains': <Object?>[],
          'workflows': <Object?>[],
          'players': <Object?>[],
        };
        final policy = HostPolicy.fromJson(additiveValid);
        expect(policy.trustPreset, equals(TrustPreset.standard));
      });
    });

    group('M5 verification wave regression tests', () {
      test(
          'hitTestNodeAtCoordinates skips left and right offscreen normalized List bounds so edge password fields stay R3',
          () {
        final leftEdgeNodes = <Map<String, Object?>>[
          <String, Object?>{
            'id': 'offscreen_left',
            'role': 'button',
            'name': 'Next',
            'bounds': <double>[-0.5, 0.1, -0.1, 0.5],
          },
          <String, Object?>{
            'id': 'pw_left_edge',
            'role': 'AXSecureTextField',
            'name': 'Password',
            'isPassword': true,
            'bounds': <double>[0.0, 0.1, 0.5, 0.5],
          },
        ];
        final leftHit = hitTestNodeAtCoordinates(
          nodes: leftEdgeNodes,
          xNorm: 0.0,
          yNorm: 0.2,
        );
        expect(leftHit?['id'], equals('pw_left_edge'));
        final leftRisk = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{'xNorm': 0.0, 'yNorm': 0.2},
          activeWindowNodes: leftEdgeNodes,
        );
        expect(leftRisk.risk, equals(RiskTier.r3));
        expect(leftRisk.reasonCode, equals('password_field_forbidden'));

        final rightEdgeNodes = <Map<String, Object?>>[
          <String, Object?>{
            'id': 'offscreen_right',
            'role': 'button',
            'name': 'Next',
            'bounds': <double>[1.2, 0.1, 1.5, 0.5],
          },
          <String, Object?>{
            'id': 'pw_right_edge',
            'role': 'AXSecureTextField',
            'name': 'Password',
            'isPassword': true,
            'bounds': <double>[0.5, 0.1, 1.0, 0.5],
          },
        ];
        final rightHit = hitTestNodeAtCoordinates(
          nodes: rightEdgeNodes,
          xNorm: 1.0,
          yNorm: 0.2,
        );
        expect(rightHit?['id'], equals('pw_right_edge'));
        final rightRisk = classifyInputStepRisk(
          toolName: 'input.click',
          arguments: const <String, Object?>{'xNorm': 1.0, 'yNorm': 0.2},
          activeWindowNodes: rightEdgeNodes,
        );
        expect(rightRisk.risk, equals(RiskTier.r3));
        expect(rightRisk.reasonCode, equals('password_field_forbidden'));
      });

      test(
          'uiNodeSignature and clampUtf16Safe never split UTF-16 surrogate pairs at index 60',
          () {
        final label = '${'a' * 59}\u{1F600}tail';
        final clamped = clampUtf16Safe(label, 60);
        expect(clamped, equals('a' * 59));
        expect(clamped.length, equals(59));

        final sig = uiNodeSignature(<String, Object?>{
          'role': 'AXButton',
          'name': label,
        });
        expect(sig, equals('axbutton\u0000${'a' * 59}'));

        final redacted = redactUiTreeNodes(<Map<String, Object?>>[
          <String, Object?>{'id': 'b1', 'role': 'AXButton', 'name': label},
        ]);
        expect(redacted.single['name'], equals('a' * 59));
      });
    });
  });
}

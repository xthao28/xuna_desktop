import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

void main() {
  group('UDC-18 Wave E M1 Desktop Policy RPC', () {
    late CuGateHarness h;

    setUp(() async {
      h = await CuGateHarness.create();
    });

    tearDown(() async {
      await h.dispose();
    });

    test('xuna/get_policy returns valid policy, presets, and discovered apps', () async {
      final res = await h.dispatcher.getPolicy(requestId: 'req-get-1');
      expect(res.id, 'req-get-1');

      final result = res.result;
      expect(result['schemaVersion'], 1);
      expect(result['trustPreset'], 'standard');
      expect(result['allowApps'], containsAll(<String>['explorer', 'calendar']));
      expect(result['denyApps'], isA<List<Object?>>());
      expect(result['allowDomains'], isA<List<Object?>>());
      expect(result['denyDomains'], isA<List<Object?>>());
      expect(result['discoveredApps'], isA<List<Object?>>());
    });

    test('xuna/set_policy updates policy and saves to store', () async {
      final setParams = SetPolicyParams(
        schemaVersion: 1,
        trustPreset: 'autopilot',
        allowApps: const <String>['explorer'],
        denyApps: const <String>['calc'],
        allowDomains: const <String>['github.com'],
        denyDomains: const <String>['malicious.com'],
      );

      final res = await h.dispatcher.setPolicy(
        requestId: 'req-set-1',
        params: setParams,
      );
      expect(res, isA<XtpResponse>());
      final xtpRes = res as XtpResponse;
      expect(xtpRes.id, 'req-set-1');
      expect(xtpRes.result['status'], 'ok');
      expect(xtpRes.result['schemaVersion'], 1);

      // Verify persistent store reloaded the updated policy
      final updatedPolicy = h.dispatcher.policyStore.evaluator.policy;
      expect(updatedPolicy, isNotNull);
      expect(updatedPolicy!.trustPreset, TrustPreset.autopilot);
      expect(updatedPolicy.apps.map((a) => a.id).toList(), <String>['explorer']);
      expect(updatedPolicy.denyApps, <String>['calc']);
      expect(updatedPolicy.urlDomains, <String>['github.com']);
      expect(updatedPolicy.denyDomains, <String>['malicious.com']);

      // Verify getPolicy reflects the changes
      final getRes = await h.dispatcher.getPolicy(requestId: 'req-get-2');
      expect(getRes.result['trustPreset'], 'autopilot');
      expect(getRes.result['allowApps'], <String>['explorer']);
      expect(getRes.result['denyApps'], <String>['calc']);
      expect(getRes.result['allowDomains'], <String>['github.com']);
      expect(getRes.result['denyDomains'], <String>['malicious.com']);
    });

    group('Safety Hard Guard: 15 Terminal GUIs and empty apps blocked', () {
      final terminalGuis = <String>[
        'Terminal',
        'iTerm',
        'iTerm2',
        'Warp',
        'Alacritty',
        'Kitty',
        'WezTerm',
        'wezterm-gui',
        'Ghostty',
        'Hyper',
        'cmd',
        'powershell',
        'pwsh',
        'wt',
        'wsl',
      ];

      for (final terminal in terminalGuis) {
        test('blocks terminal app "$terminal" with policy_blocked', () async {
          final res = await h.dispatcher.setPolicy(
            requestId: 'req-term-$terminal',
            params: SetPolicyParams(
              trustPreset: 'standard',
              allowApps: <String>['explorer', terminal],
            ),
          );

          expect(res, isA<XtpErrorResponse>());
          final err = res as XtpErrorResponse;
          expect(err.id, 'req-term-$terminal');
          expect(err.code, JsonRpcErrorCode.invalidParams);
          expect(err.message, contains('policy_blocked'));
          expect(err.message, contains(terminal));
        });
      }

      test('blocks empty and whitespace-only app names with policy_blocked', () async {
        final resEmpty = await h.dispatcher.setPolicy(
          requestId: 'req-empty',
          params: const SetPolicyParams(
            trustPreset: 'standard',
            allowApps: <String>[''],
          ),
        );
        expect(resEmpty, isA<XtpErrorResponse>());
        final errEmpty = resEmpty as XtpErrorResponse;
        expect(errEmpty.code, JsonRpcErrorCode.invalidParams);
        expect(errEmpty.message, contains('policy_blocked'));

        final resWhitespace = await h.dispatcher.setPolicy(
          requestId: 'req-ws',
          params: const SetPolicyParams(
            trustPreset: 'standard',
            allowApps: <String>['   '],
          ),
        );
        expect(resWhitespace, isA<XtpErrorResponse>());
        final errWs = resWhitespace as XtpErrorResponse;
        expect(errWs.code, JsonRpcErrorCode.invalidParams);
        expect(errWs.message, contains('policy_blocked'));
      });
    });

    test('R3 phone-signed approval gate is strictly preserved under autopilot preset', () async {
      // 1. Switch preset to autopilot
      final setRes = await h.dispatcher.setPolicy(
        requestId: 'req-auto',
        params: const SetPolicyParams(
          trustPreset: 'autopilot',
          allowApps: <String>['explorer'],
        ),
      );
      expect(setRes, isA<XtpResponse>());
      expect(
        h.dispatcher.policyStore.evaluator.policy!.trustPreset,
        TrustPreset.autopilot,
      );

      // 2. Start a CU session
      await h.startSessionAndInspect();

      // 3. Attempt an R3 consequential action (e.g. click on button e2 "Gửi báo cáo") without phone approval token
      final r3Dispatch = await h.dispatcher.dispatch(
        requestId: 'req-r3-no-sig',
        params: const ToolsCallParams(
          name: 'input.click',
          arguments: <String, Object?>{
            'elementId': '@s00000001:e2', // consequential target -> RiskTier.r3
          },
          invocationId: '7a000001-0000-0000-0000-000000000001',
          deadlineMs: 5000,
          approval: null, // No phone signature!
        ),
      );

      // Must be denied even in autopilot! Phone-signed R3 gate is never bypassed.
      expect(r3Dispatch.result['isError'], isTrue);
      final meta = r3Dispatch.result['_meta'] as Map<String, Object?>;
      expect(meta['xuna/status'], 'denied');
      expect(meta['xuna/errorCode'], 'approval_required');
    });

    test('denyApps and denyDomains set via xuna/set_policy enforce fail-closed blocking at runtime', () async {
      // Seed full desktop families (including app & url, matching writeDefaultPolicy)
      await h.dispatcher.policyStore.writeDefaultPolicy();

      final setRes = await h.dispatcher.setPolicy(
        requestId: 'req-deny-enforce',
        params: const SetPolicyParams(
          trustPreset: 'autopilot',
          allowApps: <String>['explorer', 'discord'],
          denyApps: <String>['discord'],
          allowDomains: <String>['github.com', 'evil.example.com'],
          denyDomains: <String>['evil.example.com'],
        ),
      );
      expect(setRes, isA<XtpResponse>());

      // 0. Allowed R2 app ('explorer') runs without per-call approval in autopilot
      final allowedR2Eval = h.dispatcher.policyStore.evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'explorer'},
        approval: null,
      );
      expect(allowedR2Eval.allowed, isTrue);
      expect(allowedR2Eval.effectiveRisk, RiskTier.r2);

      // 1. denyApps overrides allowApps and zero-config discovery even in autopilot
      final deniedAppEval = h.dispatcher.policyStore.evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'discord'},
        allowZeroConfigAppDiscovery: true,
      );
      expect(deniedAppEval.allowed, isFalse);
      expect(deniedAppEval.status, XtpStatus.denied);
      expect(deniedAppEval.errorCode, 'policy_blocked');

      // 2. denyDomains blocks url.open and web.navigate (including subdomains)
      final deniedUrlEval = h.dispatcher.policyStore.evaluator.evaluateInvocation(
        toolName: 'url.open',
        arguments: const <String, Object?>{'url': 'https://sub.evil.example.com/phish'},
        allowPublicHttpsDomains: true,
      );
      expect(deniedUrlEval.allowed, isFalse);
      expect(deniedUrlEval.status, XtpStatus.denied);
      expect(deniedUrlEval.errorCode, 'domain_not_allowed');
    });

    test('XTP frame parser handles xuna/get_policy and xuna/set_policy', () {
      final getFrame = XtpFrame.parse(
        '{"jsonrpc":"2.0","id":10,"method":"xuna/get_policy","params":{}}',
      );
      expect(getFrame, isA<XtpRequest>());
      final getReq = getFrame as XtpRequest;
      expect(getReq.typedParams, isA<GetPolicyParams>());

      final setFrame = XtpFrame.parse(
        json.encode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 11,
          'method': 'xuna/set_policy',
          'params': {
            'schemaVersion': 1,
            'trustPreset': 'standard',
            'allowApps': ['vscode'],
            'denyApps': ['terminal'],
            'allowDomains': ['github.com'],
            'denyDomains': ['malware.com'],
          },
        }),
      );
      expect(setFrame, isA<XtpRequest>());
      final setReq = setFrame as XtpRequest;
      expect(setReq.typedParams, isA<SetPolicyParams>());
      final setParams = setReq.typedParams as SetPolicyParams;
      expect(setParams.schemaVersion, 1);
      expect(setParams.trustPreset, 'standard');
      expect(setParams.allowApps, <String>['vscode']);
      expect(setParams.denyApps, <String>['terminal']);
      expect(setParams.allowDomains, <String>['github.com']);
      expect(setParams.denyDomains, <String>['malware.com']);
    });

    test(
      'xuna/set_policy normalizes custom app names and CU session allows zero-config app.launch',
      () async {
        await h.dispatcher.policyStore.writeDefaultPolicy();

        final setRes = await h.dispatcher.setPolicy(
          requestId: 'req-custom-names',
          params: const SetPolicyParams(
            trustPreset: 'standard',
            allowApps: <String>['Custom Music Player', 'custom_music_player'],
          ),
        );
        expect(setRes, isA<XtpResponse>());
        final saved = h.dispatcher.policyStore.evaluator.policy!;
        expect(
          saved.apps.map((a) => a.id).toList(),
          <String>['custom_music_player'],
        );

        // Start a CU session scoped to 'custom_music_player'
        await h.manager.startSession(
          goal: 'Play music',
          apps: const <String>['custom_music_player'],
          domains: const <String>[],
          maxSteps: 10,
          maxMinutes: 5,
          policy: saved,
          allowZeroConfigAppDiscovery: true,
        );

        // In-scope app launches without a separate R2 approval
        final launchInScope = await h.dispatcher.dispatch(
          requestId: 'req-launch-in-scope',
          params: const ToolsCallParams(
            name: 'app.launch',
            arguments: <String, Object?>{'id': 'custom_music_player'},
            invocationId: '8a000001-0000-0000-0000-000000000001',
            deadlineMs: 5000,
          ),
        );
        final okMeta =
            (launchInScope.result['_meta'] as Map).cast<String, Object?>();
        expect(okMeta['xuna/status'], 'ok');

        // Out-of-scope app ('notes', not in CU session) still requires R2 approval
        final launchOutOfScope = await h.dispatcher.dispatch(
          requestId: 'req-launch-out-of-scope',
          params: const ToolsCallParams(
            name: 'app.launch',
            arguments: <String, Object?>{'id': 'notes'},
            invocationId: '8a000001-0000-0000-0000-000000000002',
            deadlineMs: 5000,
          ),
        );
        final deniedMeta =
            (launchOutOfScope.result['_meta'] as Map).cast<String, Object?>();
        expect(deniedMeta['xuna/status'], 'denied');
        expect(deniedMeta['xuna/errorCode'], 'approval_required');
      },
    );
  });
}

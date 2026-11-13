import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

/// UDC-17 S17.1: the host decides the risk of an `input.*` step from the live
/// screen (`xuna/preflight`), and enforces that same risk at execution.

void main() {
  group('UDC-17 S17.1 xuna/preflight', () {
    late CuGateHarness h;

    setUp(() async {
      h = await CuGateHarness.create();
    });

    tearDown(() async {
      await h.dispose();
    });

    test(
      'outside a session the host refuses instead of guessing a risk',
      () async {
        final result = await h.preflight('input.click', const <String, Object?>{
          'elementId': '@s00000001:e1',
        });
        expect(result['status'], 'denied');
        expect(result['errorCode'], 'cu_session_required');
        expect(result.containsKey('effectiveRisk'), isFalse);
      },
    );

    test(
      'risk comes from the live element; a declared name can only raise it',
      () async {
        await h.startSessionAndInspect();

        final open = await h.preflight('input.click', const <String, Object?>{
          'elementId': '@s00000001:e1',
        });
        expect(open['status'], 'ok');
        expect(open['effectiveRisk'], 'R2');
        expect(open['reasonCode'], 'navigation_target');
        expect(open['element'], <String, Object?>{
          'role': 'button',
          'name': 'Mở báo cáo',
        });

        // The model calls "Gửi báo cáo" an innocent "Mở": the live label wins.
        final disguised = await h.preflight(
          'input.click',
          const <String, Object?>{
            'elementId': '@s00000001:e2',
            'elementName': 'Mở',
          },
        );
        expect(disguised['effectiveRisk'], 'R3');
        expect(disguised['reasonCode'], 'consequential_target');
        expect((disguised['element'] as Map)['name'], 'Gửi báo cáo');

        // A consequential declared name raises an innocent live element.
        final raised = await h.preflight('input.click', const <String, Object?>{
          'elementId': '@s00000001:e1',
          'elementName': 'Gửi',
        });
        expect(raised['effectiveRisk'], 'R3');

        final typing = await h.preflight(
          'input.type_text',
          const <String, Object?>{
            'elementId': '@s00000001:e3',
            'text': 'Mua sữa',
          },
        );
        // ADR-0015 D1: a draft into an ordinary text field is R2.
        expect(typing['effectiveRisk'], 'R2');
        expect(typing['reasonCode'], 'draft_text');

        final enter = await h.preflight('input.key', const <String, Object?>{
          'combo': 'Enter',
          'inForm': false,
        });
        expect(enter['effectiveRisk'], 'R3');
        expect(enter['reasonCode'], 'activation_key');

        final tab = await h.preflight('input.key', const <String, Object?>{
          'combo': 'Tab',
        });
        expect(tab['effectiveRisk'], 'R2');
      },
    );

    test('password targets are refused with no label', () async {
      await h.startSessionAndInspect();
      final pwd = await h.preflight('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e4',
        'text': 'secret',
      });
      expect(pwd['status'], 'denied');
      expect(pwd['errorCode'], 'password_field_forbidden');
      expect(pwd.containsKey('element'), isFalse);
    });

    test('a stale ref is refused at preflight', () async {
      await h.startSessionAndInspect();
      final stale = await h.preflight('input.click', const <String, Object?>{
        'elementId': '@s00000099:e1',
      });
      expect(stale['status'], 'failed');
      expect(stale['errorCode'], 'stale_ref');
    });

    test('preflight is read-only: the real call that follows is not stale, '
        'duplicate or over budget', () async {
      await h.startSessionAndInspect();
      final session = h.manager.activeSession!;
      const args = <String, Object?>{'elementId': '@s00000001:e1'};
      for (var i = 0; i < 3; i++) {
        await h.preflight('input.click', args);
      }
      expect(session.stepsExecuted, 0);
      expect(session.latestSnapshotId, 's00000001');
      expect(session.lastActionSignature, isNull);
      expect(
        h.provider.recordedCalls.where((c) => c.startsWith('click')),
        isEmpty,
      );

      final meta = await h.dispatchMeta(
        'input.click',
        args,
        invocationId: '31111111-1111-4111-8111-111111111111',
      );
      expect(meta['xuna/status'], 'ok');
      expect(session.stepsExecuted, 1);
    });

    test(
      'a step the host raised to R3 runs once the owner signed it',
      () async {
        await h.startSessionAndInspect();
        const args = <String, Object?>{
          'elementId': '@s00000001:e2',
          'elementName': 'Mở',
        };

        final unapproved = await h.dispatchMeta(
          'input.click',
          args,
          invocationId: '32111111-1111-4111-8111-111111111111',
        );
        expect(unapproved['xuna/status'], 'denied');
        expect(unapproved['xuna/errorCode'], 'approval_required');

        // Bound to the arguments but not phone-signed: still refused.
        final unsigned = await h.dispatchMeta(
          'input.click',
          args,
          approval: h.signedApproval(args, sign: false),
          invocationId: '32222222-2222-4222-8222-222222222222',
        );
        expect(unsigned['xuna/errorCode'], 'approval_required');

        final signed = await h.dispatchMeta(
          'input.click',
          args,
          approval: h.signedApproval(args),
          invocationId: '32333333-3333-4333-8333-333333333333',
        );
        expect(signed['xuna/status'], 'ok');
        expect(h.provider.recordedCalls, contains('click:n2'));
      },
    );
  });

  test('classifyInputStepRisk fails closed on unknown targets and tools', () {
    expect(
      classifyInputStepRisk(
        toolName: 'input.click',
        arguments: const <String, Object?>{'x': 1, 'y': 2},
      ).risk,
      RiskTier.r3,
    );
    expect(
      classifyInputStepRisk(
        toolName: 'input.drag',
        arguments: const <String, Object?>{},
      ).risk,
      RiskTier.r3,
    );
    expect(sanitizePreflightLabel('Gửi\n\tngay${'x' * 200}').length, 80);
    // 79 letters then an emoji (2 UTF-16 units): the emoji is dropped whole.
    final emojiCut = sanitizePreflightLabel('${'a' * 79}😀tail');
    expect(emojiCut, 'a' * 79);
    expect(utf8.decode(utf8.encode(emojiCut)), emojiCut);
    expect(sanitizePreflightLabel('A\u0000B'), 'A B');
  });
}

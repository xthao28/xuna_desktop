// UDC-17 S17.4 (Dart part): `ui.find` and the `changes` an `input.*` action
// reports, end to end through `HostToolDispatcher.dispatch`.
//
// The ref rule under test: after an action, a ref either still reaches the
// same element or fails with `stale_ref`. It never reaches another element.

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';

import 'support/cu_gate_harness.dart';

/// Fallback provider whose window becomes [afterNextAction] once the next
/// click, typing or key press runs.
class _ScriptedProvider extends FallbackUiaAxComputerUseProvider {
  _ScriptedProvider(ActiveWindowObservation window)
    : super(initialWindow: window);

  ActiveWindowObservation? afterNextAction;

  void _advance() {
    final next = afterNextAction;
    if (next != null) {
      currentWindow = next;
      afterNextAction = null;
    }
  }

  @override
  Future<void> performClick({
    required ActiveWindowObservation window,
    String? elementId,
    int? x,
    int? y,
  }) async {
    await super.performClick(window: window, elementId: elementId, x: x, y: y);
    _advance();
  }

  @override
  Future<void> performTypeText({
    required ActiveWindowObservation window,
    required String elementId,
    required String text,
  }) async {
    await super.performTypeText(
      window: window,
      elementId: elementId,
      text: text,
    );
    _advance();
  }

  @override
  Future<void> performKey({
    required ActiveWindowObservation window,
    required String combo,
  }) async {
    await super.performKey(window: window, combo: combo);
    _advance();
  }
}

ActiveWindowObservation _window(
  List<Map<String, Object?>> nodes, {
  String appId = 'explorer',
  String processName = 'explorer.exe',
}) => ActiveWindowObservation(
  appId: appId,
  processName: processName,
  windowTitle: 'Reports',
  nodes: nodes,
);

Map<String, Object?> _node(
  String id,
  String role,
  String name, {
  bool? enabled,
}) => <String, Object?>{
  'id': id,
  'role': role,
  'name': name,
  if (enabled != null) 'enabled': enabled,
};

int _seq = 0;
String _inv() =>
    '5${(_seq++).toString().padLeft(7, '0')}-2222-4222-8222-222222222222';

void main() {
  late CuGateHarness h;
  late _ScriptedProvider provider;

  Future<CuGateHarness> harness(List<Map<String, Object?>> nodes) async {
    provider = _ScriptedProvider(_window(nodes));
    h = await CuGateHarness.create(provider: provider);
    return h;
  }

  tearDown(() async => h.dispose());

  Future<Map<String, Object?>> call(
    String tool,
    Map<String, Object?> args, {
    bool signed = false,
  }) => h.dispatchResult(
    tool,
    args,
    approval: signed ? h.signedApproval(args) : null,
    invocationId: _inv(),
  );

  Map<String, Object?> content(Map<String, Object?> result) =>
      (result['structuredContent'] as Map).cast<String, Object?>();

  String? errorCode(Map<String, Object?> result) =>
      (result['_meta'] as Map)['xuna/errorCode'] as String?;

  Map<String, Object?> changesOf(Map<String, Object?> result) =>
      (content(result)['changes'] as Map).cast<String, Object?>();

  List<String> refsOf(List<Object?> nodes) => <String>[
    for (final n in nodes) (n as Map)['ref'] as String,
  ];

  group('ui.find', () {
    test('needs a session, returns every candidate with refs, never a '
        'pick, and the click it leads to is classified from the live '
        'element', () async {
      await harness(defaultCuTestWindow.nodes);
      final noSession = await call('ui.find', const <String, Object?>{
        'query': 'báo cáo',
      });
      expect(errorCode(noSession), 'cu_session_required');

      await h.startSession();
      final found = content(
        await call('ui.find', const <String, Object?>{'query': 'BÁO CÁO'}),
      );
      expect(found['snapshotId'], 's00000001');
      expect(found['total'], 2);
      expect(found['truncated'], isFalse);
      expect(found['searchedNodes'], 4);
      final matches = (found['matches'] as List).cast<Map<Object?, Object?>>();
      expect(matches.map((m) => m['name']), <String>[
        'Mở báo cáo',
        'Gửi báo cáo',
      ]);
      expect(refsOf(matches), <String>['@s00000001:e1', '@s00000001:e2']);

      // Find -> preflight -> click with the same ref: the risk comes from the
      // live "Gửi báo cáo", not from the name the model declares.
      const sendArgs = <String, Object?>{
        'elementId': '@s00000001:e2',
        'elementName': 'Mở',
      };
      final pre = await h.preflight('input.click', sendArgs);
      expect(pre['effectiveRisk'], 'R3');
      expect((pre['element'] as Map)['name'], 'Gửi báo cáo');
      expect(
        errorCode(await call('input.click', sendArgs)),
        'approval_required',
      );
      expect(
        provider.recordedCalls.where((c) => c.startsWith('click:')),
        isEmpty,
      );
      final signed = await call('input.click', sendArgs, signed: true);
      expect(errorCode(signed), isNull);
      expect(provider.recordedCalls, contains('click:n2'));
    });

    test('a password field is found by role only, redacted', () async {
      await harness(defaultCuTestWindow.nodes);
      await h.startSession();
      final byName = content(
        await call('ui.find', const <String, Object?>{'query': 'Mật khẩu'}),
      );
      expect(byName['total'], 0);
      expect(byName['matches'], isEmpty);

      final byRole = content(
        await call('ui.find', const <String, Object?>{'role': 'password'}),
      );
      final only = (byRole['matches'] as List).single as Map;
      expect(only['name'], '•••');
      expect(only['isPassword'], isTrue);
      expect(only.containsKey('value'), isFalse);
    });

    test('joins the current snapshot: inspect refs stay valid, new elements '
        'get the next number, a repeated find reuses its ref', () async {
      await harness(defaultCuTestWindow.nodes);
      await h.startSessionAndInspect();
      Future<List<String>> findRefs(String q) async => refsOf(
        content(await call('ui.find', <String, Object?>{'query': q}))['matches']
            as List,
      );

      expect(await findRefs('Ghi chú'), <String>['@s00000001:e3']);
      provider.currentWindow = _window(<Map<String, Object?>>[
        ...defaultCuTestWindow.nodes,
        _node('n5', 'button', 'Đính kèm'),
      ]);
      expect(await findRefs('Đính kèm'), <String>['@s00000001:e5']);
      expect(await findRefs('Đính kèm'), <String>['@s00000001:e5']);

      final draft = await call('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e3',
        'text': 'nháp',
      });
      expect(errorCode(draft), isNull);
      expect(provider.recordedCalls, contains('type:n3'));
    });
  });

  group('input.* changes', () {
    test('ordinals shift after an action: named refs follow their element, '
        'the new control gets a new ref', () async {
      await harness(<Map<String, Object?>>[
        _node('x1', 'button', 'Mở báo cáo'),
        _node('x2', 'button', 'Gửi báo cáo'),
        _node('x3', 'textfield', 'Ghi chú'),
      ]);
      await h.startSessionAndInspect();
      provider.afterNextAction = _window(<Map<String, Object?>>[
        <String, Object?>{
          ..._node('x1', 'button', 'Đóng thông báo'),
          'bounds': <String, Object?>{'x': 0, 'y': 0, 'w': 40, 'h': 20},
          'depth': 3,
        },
        _node('x2', 'button', 'Mở báo cáo'),
        _node('x3', 'button', 'Gửi báo cáo'),
        _node('x4', 'textfield', 'Ghi chú'),
      ]);

      final open = await call('input.click', const <String, Object?>{
        'elementId': '@s00000001:e1',
        'elementName': 'Mở báo cáo',
      });
      expect(errorCode(open), isNull);
      final changes = changesOf(open);
      expect(changes['snapshotId'], 's00000001');
      expect(changes['removed'], isEmpty);
      expect(changes['changed'], isEmpty);
      expect(changes['truncated'], isFalse);
      final added = (changes['added'] as List).single as Map;
      expect(added['ref'], '@s00000001:e4');
      expect(added['name'], 'Đóng thông báo');
      // Layout fields stay out of `changes` to keep it small.
      expect(added.containsKey('bounds'), isFalse);
      expect(added.containsKey('depth'), isFalse);

      // The old ordinal x3 is now the Send button; the ref still reaches the
      // note field.
      final draft = await call('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e3',
        'text': 'nháp',
      });
      expect(errorCode(draft), isNull);
      expect(provider.recordedCalls, contains('type:x4'));
      expect(provider.recordedCalls, isNot(contains('type:x3')));

      final pre = await h.preflight('input.click', const <String, Object?>{
        'elementId': '@s00000001:e2',
      });
      expect((pre['element'] as Map)['name'], 'Gửi báo cáo');
      expect(pre['effectiveRisk'], 'R3');
    });

    test('unnamed look-alike controls are dropped when the structure '
        'changes: the old ref is stale, never another element', () async {
      await harness(<Map<String, Object?>>[
        _node('d1', 'button', ''),
        _node('d2', 'button', ''),
        _node('d3', 'textarea', 'Soạn tin'),
      ]);
      await h.startSessionAndInspect();
      // An identical unnamed button appears in front of the others.
      provider.afterNextAction = _window(<Map<String, Object?>>[
        _node('d1', 'button', ''),
        _node('d2', 'button', ''),
        _node('d3', 'button', ''),
        _node('d4', 'textarea', 'Soạn tin'),
      ]);
      final draft = await call('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e3',
        'text': 'chào',
      });
      expect(errorCode(draft), isNull);
      final changes = changesOf(draft);
      expect((changes['removed'] as List).toSet(), <String>{
        '@s00000001:e1',
        '@s00000001:e2',
      });
      expect(refsOf(changes['added'] as List), <String>[
        '@s00000001:e4',
        '@s00000001:e5',
        '@s00000001:e6',
      ]);

      for (final signed in <bool>[false, true]) {
        final stale = await call('input.click', const <String, Object?>{
          'elementId': '@s00000001:e1',
        }, signed: signed);
        expect(errorCode(stale), 'stale_ref');
      }
      expect(
        provider.recordedCalls.where((c) => c.startsWith('click:')),
        isEmpty,
      );

      // The composer kept its ref across the shift.
      final more = await call('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e3',
        'text': ' bạn',
      });
      expect(errorCode(more), isNull);
      expect(provider.recordedCalls, contains('type:d4'));
    });

    test('an unchanged structure keeps unnamed refs and reports flag '
        'changes', () async {
      await harness(<Map<String, Object?>>[
        _node('d1', 'button', '', enabled: false),
        _node('d2', 'textarea', 'Soạn tin'),
      ]);
      await h.startSessionAndInspect();
      provider.afterNextAction = _window(<Map<String, Object?>>[
        _node('d1', 'button', '', enabled: true),
        _node('d2', 'textarea', 'Soạn tin'),
      ]);
      final draft = await call('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e2',
        'text': 'chào',
      });
      final changes = changesOf(draft);
      expect(changes['removed'], isEmpty);
      expect(changes['added'], isEmpty);
      expect(changes['changed'], <Object?>[
        <String, Object?>{
          'ref': '@s00000001:e1',
          'enabled': true,
          'visible': true,
        },
      ]);
      // An unnamed button after an unsigned draft is a possible Send: the
      // ref is valid, the owner must sign.
      const sendArgs = <String, Object?>{'elementId': '@s00000001:e1'};
      expect(
        errorCode(await call('input.click', sendArgs)),
        'approval_required',
      );
      expect(
        errorCode(await call('input.click', sendArgs, signed: true)),
        isNull,
      );
      expect(provider.recordedCalls, contains('click:d1'));
    });

    test('the same ref can be pressed again after the screen changed; a '
        'repeat that changed nothing ends the session', () async {
      await harness(defaultCuTestWindow.nodes);
      await h.startSessionAndInspect();
      const next = <String, Object?>{'elementId': '@s00000001:e1'};
      for (var i = 0; i < 2; i++) {
        final r = await call('input.click', next);
        expect(errorCode(r), isNull);
        expect(content(r)['effect'], 'changed');
      }
      provider.simulateSilentUipiDrop = true;
      final silent = await call('input.click', next);
      expect(errorCode(silent), isNull);
      expect(content(silent)['effect'], 'no_change');
      expect(errorCode(await call('input.click', next)), 'duplicate_action');
      expect(h.manager.hasActiveSession, isFalse);
    });

    test(
      'a window outside the session after the action is not described',
      () async {
        await harness(defaultCuTestWindow.nodes);
        await h.startSessionAndInspect();
        provider.afterNextAction = _window(
          <Map<String, Object?>>[
            <String, Object?>{
              'id': 'z1',
              'role': 'dialog',
              'name': 'Hộp thoại riêng tư',
            },
            _node('z2', 'button', 'Đồng ý'),
          ],
          appId: 'notepad',
          processName: 'notepad.exe',
        );
        final open = await call('input.click', const <String, Object?>{
          'elementId': '@s00000001:e1',
        });
        expect(errorCode(open), isNull);
        final result = content(open);
        expect(result['changes'], <String, Object?>{
          'snapshotId': 's00000001',
          'windowOutsideSession': true,
        });
        expect(result.containsKey('surfaces'), isFalse);
        expect(open.toString(), isNot(contains('riêng tư')));
      },
    );

    test('no snapshot yet: no changes; many new controls are capped and '
        'flagged', () async {
      await harness(defaultCuTestWindow.nodes);
      await h.startSession();
      provider.afterNextAction = _window(<Map<String, Object?>>[
        ...defaultCuTestWindow.nodes,
        for (var i = 0; i < 20; i++) _node('m$i', 'menuitem', 'Mục $i'),
      ]);
      final open = await call('input.click', const <String, Object?>{
        'elementId': 'n1',
      });
      expect(errorCode(open), isNull);
      expect(content(open).containsKey('changes'), isFalse);

      await h.manager.inspectWindow(maxNodes: 4);
      provider.afterNextAction = _window(<Map<String, Object?>>[
        ...defaultCuTestWindow.nodes,
        for (var i = 0; i < 40; i++) _node('k$i', 'menuitem', 'Lệnh $i'),
      ]);
      final again = await call('input.click', const <String, Object?>{
        'elementId': '@s00000001:e1',
      });
      expect(errorCode(again), isNull);
      final changes = changesOf(again);
      expect(changes['snapshotId'], 's00000001');
      expect(
        changes['added'] as List,
        hasLength(ComputerUseSessionManager.maxChangeEntries),
      );
      expect(changes['truncated'], isTrue);
    });
  });
}

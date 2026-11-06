import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';

/// A macOS-like AX snapshot in BFS order: window buttons and static text come first,
/// the editable search field later. Guessing "the first button" would close the window.
List<Map<String, Object?>> _macSnapshot() => <Map<String, Object?>>[
      <String, Object?>{
        'refId': 'ui_1',
        'role': 'AXButton',
        'label': 'close button',
        'isPassword': false,
      },
      <String, Object?>{
        'refId': 'ui_2',
        'role': 'AXStaticText',
        'label': 'Thư viện',
        'isPassword': false,
      },
      <String, Object?>{
        'refId': 'ui_3',
        'role': 'AXSecureTextField',
        'label': '[REDACTED_PASSWORD_CONTROL]',
        'isPassword': true,
      },
      <String, Object?>{
        'refId': 'ui_4',
        'role': 'AXSearchField',
        'label': 'Tìm kiếm',
        'isPassword': false,
      },
    ];

Matcher _missingRef({String? has, String? lacks}) => throwsA(
      isA<XunaHostChannelException>()
          .having((e) => e.errorCode, 'errorCode', 'missing_ref')
          .having(
            (e) => e.message ?? '',
            'message',
            allOf(
              has == null ? anything : contains(has),
              lacks == null ? anything : isNot(contains(lacks)),
            ),
          ),
    );

void main() {
  group('validateAndResolveRefKey never guesses a target element', () {
    test('invoke_ref without refId is rejected, not resolved to the first button', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      expect(
        () => uia.validateAndResolveRefKey(
          null,
          action: 'invoke_ref',
        ),
        _missingRef(has: 'candidates'),
      );
    });

    test('set_value_ref lists only editable, non-secret fields as candidates', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      expect(
        () => uia.validateAndResolveRefKey(
          '  ',
          action: 'set_value_ref',
        ),
        _missingRef(has: 'Tìm kiếm', lacks: 'Thư viện'),
      );
      expect(
        () => uia.validateAndResolveRefKey(
          null,
          action: 'set_value_ref',
        ),
        _missingRef(lacks: 'REDACTED'),
      );
    });

    test('without a snapshot the model is told to inspect first', () {
      final uia = AutoSymbioticService().uiAccessibility;
      expect(
        () => uia.validateAndResolveRefKey(
          null,
          action: 'double_click',
        ),
        _missingRef(has: 'inspect_window'),
      );
    });

    test('no action falls back to a default ref, window-level ones included', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      for (final action in const <String>['scroll_down', 'shortcut', 'drag']) {
        expect(
          () => uia.validateAndResolveRefKey(null, action: action),
          _missingRef(),
          reason: action,
        );
      }
    });

    test('an explicit ref is still resolved', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      expect(
        uia.validateAndResolveRefKey(
          'ui_4',
          action: 'set_value_ref',
        ),
        'ui_4',
      );
    });
  });

  group('executeUiAccessibilityTree only describes a tree that was really scanned', () {
    test('with no native scan applied it reports zero controls and invents none', () {
      final uia = AutoSymbioticService().uiAccessibility;
      final res = uia.executeUiAccessibilityTree(windowTitle: 'Music');
      expect(res.action, 'inspect_window');
      expect(res.nodeCount, 0);
      expect(res.nodes, isEmpty);
      expect(res.compactUiTree, isEmpty);
      expect(res.invokedRefId, isEmpty);
      expect(res.tokenSavingsPercent, 0, reason: 'savings are not measured');
    });

    test('after a native scan it lists exactly the scanned controls', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      final res = uia.executeUiAccessibilityTree(windowTitle: 'Music');
      expect(res.nodeCount, greaterThan(0));
      expect(res.compactUiTree, contains('Tìm kiếm'));
      expect(res.compactUiTree, isNot(contains('Nút thực thi chính')));
      expect(res.compactUiTree, isNot(contains('Tùy chọn xác nhận')));
    });
  });
}

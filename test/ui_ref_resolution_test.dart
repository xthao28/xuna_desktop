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
          defaultRefId: 'ui_3',
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
          defaultRefId: 'ui_1',
          action: 'set_value_ref',
        ),
        _missingRef(has: 'Tìm kiếm', lacks: 'Thư viện'),
      );
      expect(
        () => uia.validateAndResolveRefKey(
          null,
          defaultRefId: 'ui_1',
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
          defaultRefId: 'ui_1',
          action: 'double_click',
        ),
        _missingRef(has: 'inspect_window'),
      );
    });

    test('window-level actions keep their default ref', () {
      final uia = AutoSymbioticService().uiAccessibility;
      expect(
        uia.validateAndResolveRefKey(
          null,
          defaultRefId: 'ui_3',
          action: 'scroll_down',
        ),
        'ui_3',
      );
    });

    test('an explicit ref is still resolved', () {
      final uia = AutoSymbioticService().uiAccessibility;
      uia.applyNativeWindowUiTree(windowTitle: 'Music', nodes: _macSnapshot());
      expect(
        uia.validateAndResolveRefKey(
          'ui_4',
          defaultRefId: 'ui_1',
          action: 'set_value_ref',
        ),
        'ui_4',
      );
    });
  });
}

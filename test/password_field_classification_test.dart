// UDC-17 S17.6: a password field is recognised by what it is (secure flag,
// role, subrole, input type), and by its name only when it is an editable
// field. A "Quên mật khẩu" button or link is not a password field.

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

const ActiveWindowObservation _loginWindow = ActiveWindowObservation(
  appId: 'explorer',
  processName: 'explorer.exe',
  windowTitle: 'Đăng nhập',
  nodes: <Map<String, Object?>>[
    <String, Object?>{'id': 'l1', 'role': 'textfield', 'name': 'Email'},
    <String, Object?>{'id': 'l2', 'role': 'textfield', 'name': 'Mật khẩu'},
    <String, Object?>{'id': 'l3', 'role': 'button', 'name': 'Quên mật khẩu?'},
    <String, Object?>{'id': 'l4', 'role': 'link', 'name': 'Forgot password?'},
  ],
  focusedRole: 'textfield',
);

int _seq = 0;
String _nextInvocation() =>
    '5${(_seq++).toString().padLeft(7, '0')}-1111-4111-8111-111111111111';

void main() {
  test('isPasswordUiNode reads the name only for editable fields', () {
    bool pwd(Map<String, Object?> node) => isPasswordUiNode(node);

    // Real password fields, by flag, role, subrole or input type.
    expect(pwd(const {'role': 'textfield', 'secure': true}), isTrue);
    expect(pwd(const {'role': 'AXSecureTextField', 'name': 'x'}), isTrue);
    expect(
      pwd(const {'role': 'AXTextField', 'subrole': 'AXSecureTextField'}),
      isTrue,
    );
    expect(pwd(const {'role': 'textbox', 'inputType': 'password'}), isTrue);
    // Editable fields named like a password field.
    expect(pwd(const {'role': 'textfield', 'name': 'Mật khẩu'}), isTrue);
    expect(pwd(const {'role': 'edit', 'name': 'Nhập mật khẩu'}), isTrue);
    expect(pwd(const {'role': 'textbox', 'name': 'Password'}), isTrue);
    expect(pwd(const {'role': 'textarea', 'name': 'Mã PIN'}), isTrue);
    // Unknown role: still treated as a field (fail closed).
    expect(pwd(const {'name': 'Mật khẩu'}), isTrue);
    expect(pwd(const {'role': '', 'name': 'passcode'}), isTrue);

    // Buttons, links and labels that only mention a password.
    expect(pwd(const {'role': 'button', 'name': 'Quên mật khẩu?'}), isFalse);
    expect(pwd(const {'role': 'link', 'name': 'Forgot password?'}), isFalse);
    expect(pwd(const {'role': 'AXButton', 'name': 'Đổi mật khẩu'}), isFalse);
    expect(pwd(const {'role': 'AXStaticText', 'name': 'Mật khẩu'}), isFalse);
    expect(pwd(const {'role': 'text', 'name': 'Mật khẩu'}), isFalse);
    expect(
      pwd(const {'role': 'menuitem', 'name': 'Password settings'}),
      isFalse,
    );
  });

  group('end to end through the dispatcher', () {
    late CuGateHarness h;

    Future<Map<String, Object?>> run(
      String tool,
      Map<String, Object?> args, {
      bool signed = false,
    }) => h.dispatchMeta(
      tool,
      args,
      approval: signed ? h.signedApproval(args) : null,
      invocationId: _nextInvocation(),
    );

    setUp(() async {
      h = await CuGateHarness.create(window: _loginWindow);
      await h.startSessionAndInspect();
    });

    tearDown(() async => h.dispose());

    test(
      '"Quên mật khẩu" can be clicked, by ref or by declared name',
      () async {
        final byRef = await run('input.click', const <String, Object?>{
          'elementId': '@s00000001:e3',
        });
        expect(byRef['xuna/errorCode'], isNot('password_field_forbidden'));
        expect(byRef['xuna/status'], 'ok');

        final link = await run('input.click', const <String, Object?>{
          'elementId': '@s00000001:e4',
          'elementName': 'Forgot password?',
        });
        expect(link['xuna/errorCode'], isNot('password_field_forbidden'));
        expect(link['xuna/status'], 'ok');
      },
    );

    test('the password field itself stays refused, even signed', () async {
      for (final signed in <bool>[false, true]) {
        final typed = await run('input.type_text', <String, Object?>{
          'elementId': '@s00000001:e2',
          'text': 'hunter2',
        }, signed: signed);
        expect(typed['xuna/errorCode'], 'password_field_forbidden');
      }
      // A model that calls a field "Mật khẩu" while typing is refused too.
      final declared = await run('input.type_text', const <String, Object?>{
        'elementId': '@s00000001:e1',
        'elementName': 'Mật khẩu',
        'text': 'hunter2',
      });
      expect(declared['xuna/errorCode'], 'password_field_forbidden');
      expect(
        h.provider.recordedCalls.where((c) => c.startsWith('type:')),
        isEmpty,
      );
    });
  });
}

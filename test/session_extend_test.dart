// UDC-17 S17.3: `cu.session_extend` adds apps/domains to the running session
// with one owner signature, end to end through `HostToolDispatcher.dispatch`.

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

const ActiveWindowObservation _calendarWindow = ActiveWindowObservation(
  appId: 'calendar',
  processName: 'com.apple.iCal',
  windowTitle: 'Lịch',
  nodes: <Map<String, Object?>>[
    <String, Object?>{'id': 'k1', 'role': 'button', 'name': 'Hôm nay'},
  ],
);

int _seq = 0;
String _inv() =>
    '5${(_seq++).toString().padLeft(7, '0')}-1111-4111-8111-111111111111';

void main() {
  late CuGateHarness h;

  Future<Map<String, Object?>> extend(
    Map<String, Object?> args, {
    bool signed = true,
  }) => h.dispatchMeta(
    'cu.session_extend',
    args,
    approval: signed ? h.signedApproval(args) : null,
    invocationId: _inv(),
  );

  setUp(() async {
    h = await CuGateHarness.create();
    await h.startSessionAndInspect();
  });

  tearDown(() async => h.dispose());

  test('a new app is refused until the owner signs the extension', () async {
    final sessionId = h.manager.activeSession!.sessionId;
    h.provider.currentWindow = _calendarWindow;
    await expectLater(
      h.manager.inspectWindow(maxNodes: 10),
      throwsA(
        isA<Object>().having(
          (e) => '$e',
          'error',
          contains('target_outside_allowlist'),
        ),
      ),
    );

    final args = <String, Object?>{
      'sessionId': sessionId,
      'apps': const <String>['calendar'],
      'domains': const <String>['lich.example.com'],
    };
    final unsigned = await extend(args, signed: false);
    expect(unsigned['xuna/errorCode'], 'approval_required');

    final stepsBefore = h.manager.activeSession!.stepsExecuted;
    final signed = await extend(args);
    expect(signed['xuna/status'], 'ok');
    final session = h.manager.activeSession!;
    expect(session.allowedApps, containsAll(<String>['explorer', 'calendar']));
    expect(session.allowedDomains, contains('lich.example.com'));
    expect(session.stepsExecuted, stepsBefore);
    expect(session.maxSteps, 10);

    final snap = await h.manager.inspectWindow(maxNodes: 10);
    expect(snap['appId'], 'calendar');
  });

  test('extension applies the start checks and the session id', () async {
    final sessionId = h.manager.activeSession!.sessionId;
    final denied = await extend(<String, Object?>{
      'sessionId': sessionId,
      'apps': const <String>['powershell'],
      'domains': const <String>[],
    });
    expect(denied['xuna/errorCode'], 'denylisted_target_forbidden');

    final unknownApp = await extend(<String, Object?>{
      'sessionId': sessionId,
      'apps': const <String>['not_installed_app'],
      'domains': const <String>[],
    });
    expect(unknownApp['xuna/errorCode'], 'policy_blocked');

    final otherSession = await extend(const <String, Object?>{
      'sessionId': 'cu-session-999',
      'apps': <String>['calendar'],
      'domains': <String>[],
    });
    expect(otherSession['xuna/errorCode'], 'cu_session_required');
    expect(h.manager.activeSession!.allowedApps, isNot(contains('calendar')));
  });

  test(
    'a signed extension cannot add a domain session start refuses',
    () async {
      final sessionId = h.manager.activeSession!.sessionId;
      final before = List<String>.of(h.manager.activeSession!.allowedDomains);
      for (final bad in const <String>[
        'localhost',
        'printer.local',
        '192.168.1.10',
        '[::1]',
        'http://example.com',
        'user@example.com',
        'intranet',
      ]) {
        final r = await extend(<String, Object?>{
          'sessionId': sessionId,
          'apps': const <String>[],
          'domains': <String>[bad],
        });
        expect(r['xuna/status'], isNot('ok'), reason: bad);
      }
      expect(h.manager.activeSession!.allowedDomains, before);
    },
  );

  test('the total scope of a session is capped', () async {
    final sessionId = h.manager.activeSession!.sessionId;
    var n = 0;
    for (var call = 0; call < maxCuSessionDomains ~/ 3; call++) {
      final r = await extend(<String, Object?>{
        'sessionId': sessionId,
        'apps': const <String>[],
        'domains': <String>[for (var i = 0; i < 3; i++) 'd${n++}.example.com'],
      });
      expect(r['xuna/status'], 'ok');
    }
    final over = await extend(<String, Object?>{
      'sessionId': sessionId,
      'apps': const <String>[],
      'domains': const <String>['one-more.example.com'],
    });
    expect(over['xuna/errorCode'], 'session_scope_limit');
    expect(
      h.manager.activeSession!.allowedDomains,
      hasLength(maxCuSessionDomains),
    );
  });
}

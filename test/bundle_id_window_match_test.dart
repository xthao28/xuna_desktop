// UDC-17 S17.6: on macOS the window's bundle id decides which app it is. A
// window that copies an allowed app's display name but has another bundle id
// is refused; the display name counts only when the app's bundle id is
// unknown. Scripted windows on the development machine; the native side
// (that macOS really reports the bundle id as `processName`) still needs a
// run on a Mac.

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

import 'support/cu_gate_harness.dart';

HostPolicy _policy() => HostPolicy(
  schemaVersion: 1,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.cu: FamilyPolicyDecision.allow,
    ToolFamily.ui: FamilyPolicyDecision.allow,
    ToolFamily.input: FamilyPolicyDecision.allow,
  },
  apps: <AllowedAppConfig>[
    AllowedAppConfig(
      id: 'calendar',
      name: 'Calendar',
      kind: AppLaunchKind.bundle,
      target: 'com.apple.iCal',
      risk: RiskTier.r2,
    ),
    AllowedAppConfig(
      id: 'explorer',
      name: 'File Explorer',
      kind: AppLaunchKind.exe,
      target: r'C:\Windows\explorer.exe',
      risk: RiskTier.r2,
    ),
  ],
  urlDomains: const <String>[],
  workflows: const <WorkflowConfig>[],
  players: const <String>[],
);

ActiveWindowObservation _window(String appId, String processName) =>
    ActiveWindowObservation(
      appId: appId,
      processName: processName,
      windowTitle: 'Lịch',
      nodes: const <Map<String, Object?>>[
        <String, Object?>{'id': 'a', 'role': 'button', 'name': 'Hôm nay'},
      ],
    );

void main() {
  test('isWindowAppAllowed lets the bundle id decide', () {
    final session = ComputerUseSessionState(
      sessionId: 's',
      goal: 'g',
      allowedApps: <String>{'calendar', 'notes'},
      allowedAppIdentifiers: <String>{
        'calendar',
        'com.apple.ical',
        'notes',
        'explorer.exe',
      },
      // Calendar's bundle id is known; Notes' is not.
      bundleIdByIdentifier: <String, String>{'calendar': 'com.apple.ical'},
      allowedDomains: const <String>[],
      maxSteps: 10,
      maxMinutes: 5,
      startedAtUtc: DateTime.utc(2026, 11, 13),
    );
    expect(session.isWindowAppAllowed('calendar', 'com.apple.iCal'), isTrue);
    // Same display name, other bundle id: an impostor.
    expect(
      session.isWindowAppAllowed('calendar', 'com.evil.calendar'),
      isFalse,
    );
    // Unknown bundle id for Notes: the name still decides, as before.
    expect(session.isWindowAppAllowed('notes', 'com.apple.notes'), isTrue);
    // No match at all.
    expect(session.isWindowAppAllowed('mail', 'com.apple.mail'), isFalse);
    // Windows executables keep the old matching.
    expect(session.isWindowAppAllowed('explorer', 'explorer.exe'), isTrue);
    expect(ComputerUseSessionState.looksLikeBundleId('com.apple.ical'), isTrue);
    expect(ComputerUseSessionState.looksLikeBundleId('explorer.exe'), isFalse);
    expect(ComputerUseSessionState.looksLikeBundleId('calendar'), isFalse);
  });

  test(
    'a session on a bundle app refuses a window that copies its name',
    () async {
      final h = await CuGateHarness.create(
        window: _window('calendar', 'com.apple.iCal'),
      );
      try {
        await h.manager.startSession(
          goal: 'Xem lịch hôm nay',
          apps: const <String>['calendar'],
          domains: const <String>[],
          maxSteps: 10,
          maxMinutes: 5,
          policy: _policy(),
        );
        final real = await h.manager.inspectWindow(maxNodes: 20);
        expect(real, isNotEmpty);

        h.provider.currentWindow = _window('calendar', 'com.evil.calendar');
        await expectLater(
          h.manager.inspectWindow(maxNodes: 20),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'target_outside_allowlist',
            ),
          ),
        );
      } finally {
        await h.dispose();
      }
    },
  );
}

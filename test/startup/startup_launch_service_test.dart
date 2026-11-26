import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/startup/startup_launch_service.dart';

/// Reads `HKCU\...\Run\<name>` with the built-in `reg.exe` (no extra package).
Future<String?> _readRunValue(String name) async {
  final r = await Process.run('reg', <String>[
    'query',
    r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
    '/v',
    name,
  ]);
  if (r.exitCode != 0) return null;
  final match = RegExp(
    '${RegExp.escape(name)}\\s+REG_SZ\\s+(.*)\$',
    multiLine: true,
  ).firstMatch(r.stdout.toString());
  return match?.group(1)?.trimRight();
}

class _FakeBackend implements StartupLaunchBackend {
  _FakeBackend({this.failWrites = false, this.failReads = false});

  final bool failWrites;
  final bool failReads;
  bool state = false;

  @override
  Future<bool> isEnabled() async {
    if (failReads) throw StateError('registry unreadable');
    return state;
  }

  @override
  Future<bool> enable() async {
    if (failWrites) throw StateError('access denied');
    state = true;
    return true;
  }

  @override
  Future<bool> disable() async {
    if (failWrites) throw StateError('access denied');
    state = false;
    return true;
  }
}

/// P0.9: opt-in "Khởi động cùng máy" reports the real OS state (Rule H1).
void main() {
  test(
    'unsupported platform reports null and never touches a backend',
    () async {
      final backend = _FakeBackend();
      final svc = StartupLaunchService(backend: backend, supported: false);
      expect(svc.isSupported, isFalse);
      expect(await svc.readEnabled(), isNull);
      expect(await svc.setEnabled(true), isNull);
      expect(backend.state, isFalse);
    },
  );

  test('enable/disable return the state read back from the backend', () async {
    final backend = _FakeBackend();
    final svc = StartupLaunchService(backend: backend, supported: true);
    expect(await svc.readEnabled(), isFalse, reason: 'off by default');
    expect(await svc.setEnabled(true), isTrue);
    expect(await svc.setEnabled(false), isFalse);
  });

  test(
    'a failed write reports the unchanged real state, not success',
    () async {
      final backend = _FakeBackend(failWrites: true);
      final svc = StartupLaunchService(backend: backend, supported: true);
      expect(await svc.setEnabled(true), isFalse);
    },
  );

  test('an unreadable state is null, never a guessed value', () async {
    final svc = StartupLaunchService(
      backend: _FakeBackend(failReads: true),
      supported: true,
    );
    expect(await svc.readEnabled(), isNull);
  });

  test(
    'real HKCU Run entry is written quoted and removed again (Windows)',
    () async {
      final appName = 'XUNA_TEST_autostart_$pid';
      const exe = r'C:\Program Files\XUNA Test\xuna_desktop.exe';
      final svc = StartupLaunchService(
        backend: LaunchAtStartupBackend(appName: appName, executablePath: exe),
        supported: true,
      );
      addTearDown(() => svc.setEnabled(false));
      expect(await svc.setEnabled(true), isTrue);
      expect(await _readRunValue(appName), '"$exe"');
      expect(await svc.setEnabled(false), isFalse);
      expect(await _readRunValue(appName), isNull);
    },
    skip: Platform.isWindows ? false : 'Windows-only registry test',
  );
}

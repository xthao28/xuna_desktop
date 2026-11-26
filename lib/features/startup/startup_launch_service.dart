import 'dart:io';

import 'package:launch_at_startup/launch_at_startup.dart';

/// Backend that reads and writes the OS "start with the user session" entry.
abstract class StartupLaunchBackend {
  Future<bool> isEnabled();
  Future<bool> enable();
  Future<bool> disable();
}

/// `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` via the approved
/// `launch_at_startup` package (desktop AGENTS §3.7: ordinary user-session
/// app, never elevated, never a service).
class LaunchAtStartupBackend implements StartupLaunchBackend {
  LaunchAtStartupBackend({
    required String appName,
    required String executablePath,
  }) {
    // The package writes the value verbatim; quote it so a path with spaces
    // (e.g. under "C:\Program Files") cannot be split by Windows into
    // "C:\Program.exe" (unquoted service/Run path issue).
    launchAtStartup.setup(appName: appName, appPath: '"$executablePath"');
  }

  @override
  Future<bool> isEnabled() => launchAtStartup.isEnabled();

  @override
  Future<bool> enable() => launchAtStartup.enable();

  @override
  Future<bool> disable() => launchAtStartup.disable();
}

/// Opt-in "Khởi động cùng máy" switch (P0.9). Off by default: nothing is
/// registered until the owner turns it on in the desktop UI.
///
/// Supported only on Windows for now. The macOS backend of `launch_at_startup`
/// needs a native `launch_at_startup` method channel that this app does not
/// implement, so macOS reports unsupported instead of failing at runtime.
class StartupLaunchService {
  StartupLaunchService({StartupLaunchBackend? backend, bool? supported})
    : _supported = supported ?? Platform.isWindows,
      _backend =
          backend ??
          ((supported ?? Platform.isWindows)
              ? LaunchAtStartupBackend(
                  appName: 'XUNA Desktop',
                  executablePath: Platform.resolvedExecutable,
                )
              : null);

  final bool _supported;
  final StartupLaunchBackend? _backend;

  bool get isSupported => _supported && _backend != null;

  /// Current OS state, or `null` when unsupported or unreadable (never a
  /// guessed value — Rule H1).
  Future<bool?> readEnabled() async {
    final backend = _backend;
    if (!isSupported || backend == null) return null;
    try {
      return await backend.isEnabled();
    } catch (_) {
      return null;
    }
  }

  /// Applies [enabled] and returns the state read back from the OS afterwards
  /// (`null` if unsupported/unreadable), so the UI shows what really happened.
  Future<bool?> setEnabled(bool enabled) async {
    final backend = _backend;
    if (!isSupported || backend == null) return null;
    try {
      if (enabled) {
        await backend.enable();
      } else {
        await backend.disable();
      }
    } catch (_) {
      // Fall through: report the real state below.
    }
    return readEnabled();
  }
}

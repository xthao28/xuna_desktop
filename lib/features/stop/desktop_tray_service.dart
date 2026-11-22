import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Integrates system tray (`tray_manager`), settings window visibility
/// (`window_manager`), global emergency-stop hotkey (`Ctrl+Alt+Shift+X`), and
/// spatial focus hotkey/menu controls (`Cmd/Ctrl+Alt+Shift+F`, `"Gọi XUNA sang máy này"`,
/// `"Follow Me"`) (`UDC-3` §5.6, `XUNA_SPATIAL_DEVICE_MESH.md` §6.3).
class DesktopTrayService with TrayListener, WindowListener {
  DesktopTrayService({
    required this.controller,
    TrayManager? trayManagerOverride,
    HotKeyManager? hotKeyManagerOverride,
    WindowManager? windowManagerOverride,
    bool? isMacOsOverride,
    VoidCallback? onFocusHotkeyPressed,
    VoidCallback? onFocusTrayPressed,
    ValueChanged<bool>? onToggleFollowMe,
  }) : _trayManager = trayManagerOverride ?? trayManager,
       _hotKeyManager = hotKeyManagerOverride ?? hotKeyManager,
       _windowManager = windowManagerOverride ?? windowManager,
       _isMacOs = isMacOsOverride ?? Platform.isMacOS,
       _onFocusHotkeyPressed = onFocusHotkeyPressed,
       _onFocusTrayPressed = onFocusTrayPressed,
       _onToggleFollowMe = onToggleFollowMe;

  final DesktopAgentController controller;
  final TrayManager _trayManager;
  final HotKeyManager _hotKeyManager;
  final WindowManager _windowManager;
  final bool _isMacOs;
  final VoidCallback? _onFocusHotkeyPressed;
  final VoidCallback? _onFocusTrayPressed;
  final ValueChanged<bool>? _onToggleFollowMe;

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  bool _initialized = false;
  String? _currentIconAsset;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await _windowManager.ensureInitialized();
      _windowManager.addListener(this);
      await _windowManager.setPreventClose(true);
    } catch (_) {
      // Safe fallback in headless/test environments.
    }

    try {
      _trayManager.addListener(this);
      await refreshTrayMenu();

      _subs.add(
        controller.sessionPhase.listen((_) => unawaited(refreshTrayMenu())),
      );
      _subs.add(
        controller.isStopped.listen((_) => unawaited(refreshTrayMenu())),
      );
      _subs.add(
        controller.isPolicyHealthy.listen((_) => unawaited(refreshTrayMenu())),
      );
      _subs.add(
        controller.activeCuSession.listen((_) => unawaited(refreshTrayMenu())),
      );
      _subs.add(
        controller.followMeEnabled.listen((_) => unawaited(refreshTrayMenu())),
      );
    } catch (_) {
      // Safe fallback in headless/test environments.
    }

    try {
      await _hotKeyManager.unregisterAll();
      final emergencyStopKey = HotKey(
        key: PhysicalKeyboardKey.keyX,
        modifiers: <HotKeyModifier>[
          HotKeyModifier.control,
          HotKeyModifier.alt,
          HotKeyModifier.shift,
        ],
        scope: HotKeyScope.system,
      );
      await _hotKeyManager.register(
        emergencyStopKey,
        keyDownHandler: (_) {
          controller.triggerEmergencyStop();
          unawaited(refreshTrayMenu());
        },
      );

      final focusKey = HotKey(
        key: PhysicalKeyboardKey.keyF,
        modifiers: _isMacOs
            ? <HotKeyModifier>[
                HotKeyModifier.meta,
                HotKeyModifier.alt,
                HotKeyModifier.shift,
              ]
            : <HotKeyModifier>[
                HotKeyModifier.control,
                HotKeyModifier.alt,
                HotKeyModifier.shift,
              ],
        scope: HotKeyScope.system,
      );
      await _hotKeyManager.register(
        focusKey,
        keyDownHandler: (_) => _triggerFocusHotkey(),
      );
    } catch (_) {
      // Safe fallback when global hotkey registration is unavailable.
    }
  }

  void _triggerFocusHotkey() {
    final hook = _onFocusHotkeyPressed;
    if (hook != null) {
      hook();
      return;
    }
    controller.requestFocusHere(source: FocusRequestSource.hotkey);
  }

  String _resolveIconAsset() {
    if (controller.isStopped.value || !controller.isPolicyHealthy.value) {
      return 'assets/images/xuna_tray_sleep.png';
    }
    if (controller.sessionPhase.value == HostSessionPhase.ready) {
      return 'assets/images/xuna_tray_happy.png';
    }
    return 'assets/images/xuna_tray_idle.png';
  }

  @visibleForTesting
  Menu buildTrayMenu() {
    final stopped = controller.isStopped.value;
    final statusLabel = controller.trayStatusLabel;
    return Menu(
      items: <MenuItem>[
        MenuItem(key: 'status', label: '🐾 XUNA: $statusLabel', disabled: true),
        MenuItem.separator(),
        MenuItem(key: 'focus_here', label: 'Gọi XUNA sang máy này'),
        MenuItem.checkbox(
          key: 'toggle_follow_me',
          label: 'Follow Me',
          checked: controller.followMeEnabled.value,
        ),
        MenuItem.separator(),
        MenuItem(key: 'open_settings', label: 'Mở Trạm điều khiển XUNA'),
        MenuItem(
          key: 'quick_capsule',
          label: 'Đóng băng nhanh không gian làm việc',
        ),
        MenuItem.separator(),
        MenuItem(
          key: stopped ? 'resume' : 'stop',
          label: stopped ? 'Bật lại XUNA' : 'Dừng XUNA (Khẩn cấp)',
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Thoát XUNA'),
      ],
    );
  }

  Future<void> refreshTrayMenu() async {
    final statusLabel = controller.trayStatusLabel;
    final iconAsset = _resolveIconAsset();
    final menu = buildTrayMenu();

    try {
      if (_currentIconAsset != iconAsset) {
        await _trayManager.setIcon(iconAsset, isTemplate: false);
        _currentIconAsset = iconAsset;
      }
      if (_isMacOs) {
        await _trayManager.setTitle('');
      }
      await _trayManager.setContextMenu(menu);
      await _trayManager.setToolTip('XUNA ($statusLabel)');
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(_trayManager.popUpContextMenu());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(_trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'focus_here':
        final hook = _onFocusTrayPressed;
        if (hook != null) {
          hook();
        } else {
          controller.requestFocusHere(source: FocusRequestSource.tray);
        }
      case 'toggle_follow_me':
        final hook = _onToggleFollowMe;
        if (hook != null) {
          hook(!controller.followMeEnabled.value);
        } else {
          controller.toggleFollowMe();
        }
        unawaited(refreshTrayMenu());
      case 'stop':
        controller.triggerEmergencyStop();
        unawaited(refreshTrayMenu());
      case 'resume':
        controller.resumeEmergencyStop();
        unawaited(refreshTrayMenu());
      case 'open_settings':
        unawaited(_showSettingsWindow());
      case 'quick_capsule':
        controller.captureQuickWorkspaceCapsule(
          nextStepHint: 'Đóng băng từ thanh Menu Bar XUNA',
        );
        controller.activeTab.value = AgentWindowTab.symbiotic;
        unawaited(_showSettingsWindow());
      case 'quit':
        exit(0);
    }
  }

  @override
  void onWindowClose() {
    unawaited(_windowManager.hide());
  }

  @override
  void onWindowFocus() {
    unawaited(controller.refreshPermissions());
  }

  Future<void> _showSettingsWindow() async {
    try {
      await _windowManager.show();
      await _windowManager.focus();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    _trayManager.removeListener(this);
    _windowManager.removeListener(this);
    try {
      await _hotKeyManager.unregisterAll();
    } catch (_) {}
  }
}

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';

/// Integrates system tray (`tray_manager`), settings window visibility
/// (`window_manager`), and global emergency-stop hotkey (`hotkey_manager`)
/// (`UDC-3` §5.6.1 & §5.6.2).
class DesktopTrayService with TrayListener, WindowListener {
  DesktopTrayService({required this.controller});

  final DesktopAgentController controller;
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];
  bool _initialized = false;
  String? _currentIconAsset;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;

    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await windowManager.setPreventClose(true);
    } catch (_) {
      // Safe fallback in headless/test environments.
    }

    try {
      trayManager.addListener(this);
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
    } catch (_) {
      // Safe fallback in headless/test environments.
    }

    try {
      await hotKeyManager.unregisterAll();
      final hotKey = HotKey(
        key: PhysicalKeyboardKey.keyX,
        modifiers: <HotKeyModifier>[
          HotKeyModifier.control,
          HotKeyModifier.alt,
          HotKeyModifier.shift,
        ],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(
        hotKey,
        keyDownHandler: (_) {
          controller.triggerEmergencyStop();
          unawaited(refreshTrayMenu());
        },
      );
    } catch (_) {
      // Safe fallback when global hotkey registration is unavailable.
    }
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

  Future<void> refreshTrayMenu() async {
    final stopped = controller.isStopped.value;
    final statusLabel = controller.trayStatusLabel;
    final iconAsset = _resolveIconAsset();

    final menu = Menu(
      items: <MenuItem>[
        MenuItem(
          key: 'status',
          label: '🐾 XUNA: $statusLabel',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          key: 'open_settings',
          label: 'Mở Trạm điều khiển XUNA',
        ),
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
    try {
      if (_currentIconAsset != iconAsset) {
        await trayManager.setIcon(iconAsset, isTemplate: false);
        _currentIconAsset = iconAsset;
      }
      if (Platform.isMacOS) {
        await trayManager.setTitle('');
      }
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('XUNA ($statusLabel)');
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayIconRightMouseDown() {
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
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
    unawaited(windowManager.hide());
  }

  @override
  void onWindowFocus() {
    unawaited(controller.refreshPermissions());
  }

  Future<void> _showSettingsWindow() async {
    try {
      await windowManager.show();
      await windowManager.focus();
    } catch (_) {}
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await hotKeyManager.unregisterAll();
    } catch (_) {}
  }
}

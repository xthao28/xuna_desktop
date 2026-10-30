import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';

/// Integrates system tray (`tray_manager`), settings window visibility
/// (`window_manager`), and global emergency-stop hotkey (`hotkey_manager`)
/// (`UDC-3` §5.6.1 & §5.6.2).
class DesktopTrayService with TrayListener, WindowListener {
  DesktopTrayService({required this.controller});

  final DesktopAgentController controller;
  bool _initialized = false;

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

  Future<void> refreshTrayMenu() async {
    final stopped = controller.isStopped.value;
    final menu = Menu(
      items: <MenuItem>[
        MenuItem(
          key: 'status',
          label: 'XUNA: ${controller.trayStatusLabel}',
          disabled: true,
        ),
        MenuItem.separator(),
        MenuItem(
          key: stopped ? 'resume' : 'stop',
          label: stopped ? 'Bật lại XUNA' : 'Dừng XUNA (Khẩn cấp)',
        ),
        MenuItem(key: 'open_settings', label: 'Mở cửa sổ cấu hình'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Thoát XUNA'),
      ],
    );
    try {
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('XUNA (${controller.trayStatusLabel})');
    } catch (_) {}
  }

  @override
  void onTrayIconMouseDown() {
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
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await hotKeyManager.unregisterAll();
    } catch (_) {}
  }
}

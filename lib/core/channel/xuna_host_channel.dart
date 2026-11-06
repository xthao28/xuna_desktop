import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Exception raised by [XunaHostChannel] when the native host provider fails
/// or times out (`UDC-3` §5.6.3).
class XunaHostChannelException implements Exception {
  const XunaHostChannelException({
    required this.status,
    required this.errorCode,
    this.message,
  });

  final XtpStatus status;
  final String errorCode;
  final String? message;

  @override
  String toString() =>
      'XunaHostChannelException(status: ${status.wire}, errorCode: $errorCode)';
}

/// Snapshot of host platform and OS version returned by `hostInfo`.
class HostSystemInfo {
  const HostSystemInfo({
    required this.platform,
    required this.osVersion,
    required this.hostname,
  });

  final HostPlatform platform;
  final String osVersion;
  final String hostname;
}

/// Snapshot of OS permissions returned by `permissions`.
class HostPermissionSnapshot {
  const HostPermissionSnapshot({
    this.accessibility = XtpPermissionState.granted,
    this.notifications = XtpPermissionState.granted,
    this.automation = const <String, XtpPermissionState>{},
  });

  /// Used when the OS permission state could not be read. Reports
  /// `not_determined` instead of assuming access was granted.
  const HostPermissionSnapshot.unknown()
    : accessibility = XtpPermissionState.notDetermined,
      notifications = XtpPermissionState.notDetermined,
      automation = const <String, XtpPermissionState>{};

  final XtpPermissionState accessibility;
  final XtpPermissionState notifications;
  final Map<String, XtpPermissionState> automation;

  Map<String, String> toWireMap() => <String, String>{
    'accessibility': accessibility.wire,
    'notifications': notifications.wire,
    for (final entry in automation.entries)
      'automation.${entry.key}': entry.value.wire,
  };
}

/// Snapshot of active media playback returned by `nowPlaying`.
class NowPlayingSnapshot {
  const NowPlayingSnapshot({
    required this.state,
    this.title,
    this.artist,
    this.app,
  });

  final String state;
  final String? title;
  final String? artist;
  final String? app;

  Map<String, Object?> toStructuredContent() => <String, Object?>{
    'state': state,
    if (title != null && title!.isNotEmpty) 'title': title,
    if (artist != null && artist!.isNotEmpty) 'artist': artist,
    if (app != null && app!.isNotEmpty) 'app': app,
  };
}

/// Snapshot of the active browser tab returned by `browserCurrentUrl` (`UDC-9` S9.1).
class BrowserTabSnapshot {
  const BrowserTabSnapshot({required this.url, required this.browser});

  final String url;
  final String browser;
}

/// Snapshot of the frontmost desktop window returned by `readActiveWindowContext` (`UDC-13` S13.1).
class ActiveWindowContextSnapshot {
  const ActiveWindowContextSnapshot({
    required this.appName,
    required this.processName,
    required this.windowTitle,
    required this.focusedRole,
    required this.visibleText,
    this.isElevated = false,
  });

  final String appName;
  final String processName;
  final String windowTitle;
  final String focusedRole;
  final String visibleText;
  final bool isElevated;
}

/// Semantic snapshot of the active browser tab returned by `readBrowserPageSummary` (`UDC-13` S13.2).
class BrowserPageSemanticSnapshot {
  const BrowserPageSemanticSnapshot({
    required this.url,
    required this.browser,
    required this.title,
    this.headings = const <String>[],
    this.actions = const <String>[],
    this.excerpt = '',
  });

  final String url;
  final String browser;
  final String title;
  final List<String> headings;
  final List<String> actions;
  final String excerpt;
}

/// Snapshot of an OS window's accessibility UI tree returned by `inspectWindowUiTree`.
class WindowUiTreeSnapshot {
  const WindowUiTreeSnapshot({
    required this.windowTitle,
    this.appName = '',
    this.nodes = const <Map<String, Object?>>[],
    this.redactedControlsCount = 0,
  });

  final String windowTitle;
  final String appName;
  final List<Map<String, Object?>> nodes;
  final int redactedControlsCount;
}

/// Result of invoking or setting a value on a window UI control via `invokeWindowUiControl`.
class WindowUiControlActionResult {
  const WindowUiControlActionResult({
    required this.ok,
    required this.invokedRefId,
    this.detail = '',
    this.windowTitle = '',
    this.nodes = const <Map<String, Object?>>[],
  });

  final bool ok;
  final String invokedRefId;
  final String detail;
  final String windowTitle;
  final List<Map<String, Object?>> nodes;
}

/// Abstract interface for the native `xuna/host` MethodChannel (`UDC-3` §5.6.3).
///
/// Every call has a 10 s native timeout. Unit and integration tests use
/// `FakeXunaHostChannel` while S3.5 (Windows) and S3.6 (macOS) wire the native
/// C++/Swift implementations behind [MethodChannelXunaHostChannel].
abstract interface class XunaHostChannel {
  /// Ensures the hardware/keychain P-256 key exists and returns its 65-byte
  /// uncompressed SEC1 public key (`0x04 || X || Y`).
  Future<Uint8List> keyEnsure();

  /// Signs [message] (raw bytes) with the host's P-256 private key and returns
  /// a 64-byte raw `r || s` signature.
  Future<Uint8List> keySign(Uint8List message);

  /// Executes a media transport command (`play_pause`, `next`, `previous`).
  Future<String> media(String cmd);

  /// Sets system master output volume (`0..100`) and returns the applied level.
  Future<int> volumeSet(int level);

  /// Queries metadata for the active media session from allowlisted [players].
  Future<NowPlayingSnapshot> nowPlaying(List<String> players);

  /// Launches an allowlisted application (`exe`, `aumid`, or `bundle`).
  Future<void> appLaunch({required AppLaunchKind kind, required String target});

  /// Opens a pre-validated `https://` URL in the user's default browser.
  Future<void> urlOpen(String url);

  /// Reads the active `https://` tab URL from Edge/Chrome (Windows UIA) or
  /// Safari/Chrome (macOS AppleScript) (`UDC-9` S9.1).
  Future<BrowserTabSnapshot> browserCurrentUrl({String browser = 'auto'});

  /// Runs an allowlisted workflow (`lnk` or `shortcut`).
  Future<void> workflowRun({
    required WorkflowKind kind,
    required String target,
  });

  /// Queries OS permission states (`accessibility`, `automation`, `notifications`).
  Future<HostPermissionSnapshot> permissions();

  /// Triggers an OS permission prompt or opens the relevant System Settings pane.
  Future<XtpPermissionState> requestPermission(String kind);

  /// Returns the current host platform, OS version and hostname.
  Future<HostSystemInfo> hostInfo();

  /// Shows a brief content-minimal user notification (`"XUNA: đã mở VS Code"`).
  Future<void> showToast({required String title, required String body});

  /// Wakes the host display from dim/sleep (`UDC-11` S11.1).
  Future<bool> displayWake();

  /// Reads selected or clipboard text from the host OS (`UDC-12` S12.2).
  Future<String> clipboardReadText();

  /// Locks the host screen or puts the display to sleep (`UDC-12` S12.2).
  Future<bool> lockScreen();

  /// Reads the frontmost desktop window's app name, window title, focused role,
  /// and visible accessibility text (`UDC-13` S13.1).
  Future<ActiveWindowContextSnapshot> readActiveWindowContext({
    int maxChars = 600,
  });

  /// Reads a structured semantic summary (title, headings, actions, excerpt) of
  /// the active browser tab (`UDC-13` S13.2).
  Future<BrowserPageSemanticSnapshot> readBrowserPageSummary({
    String browser = 'auto',
    int maxChars = 800,
  });

  /// Inspects the accessibility control tree of the active or named application window.
  Future<WindowUiTreeSnapshot> inspectWindowUiTree({
    String? windowTitle,
    int maxNodes = 35,
  });

  /// Invokes a control, types/pastes text, sends a shortcut, or runs media search in a window.
  Future<WindowUiControlActionResult> invokeWindowUiControl({
    required String action,
    required String refId,
    String? windowTitle,
    String? valueText,
    bool submit = true,
  });
}

/// MethodChannel implementation of [XunaHostChannel] bound to `'xuna/host'`
/// with a 10-second timeout per call (`UDC-3` §5.6.3).
class MethodChannelXunaHostChannel implements XunaHostChannel {
  MethodChannelXunaHostChannel({
    MethodChannel? channel,
    this.callTimeout = const Duration(seconds: 10),
  }) : _channel = channel ?? const MethodChannel('xuna/host');

  final MethodChannel _channel;
  final Duration callTimeout;

  @override
  Future<Uint8List> keyEnsure() async {
    final map = await _invokeMap('keyEnsure');
    final b64 = map['publicKey'];
    if (b64 is! String || b64.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'Missing publicKey from keyEnsure',
      );
    }
    final bytes = Uint8List.fromList(base64.decode(b64));
    validateP256PublicKey(bytes);
    return bytes;
  }

  @override
  Future<Uint8List> keySign(Uint8List message) async {
    final map = await _invokeMap('keySign', <String, Object?>{
      'message': base64.encode(message),
    });
    final b64 = map['signature'];
    if (b64 is! String || b64.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'Missing signature from keySign',
      );
    }
    final bytes = Uint8List.fromList(base64.decode(b64));
    validateP256Signature(bytes);
    return bytes;
  }

  @override
  Future<String> media(String cmd) async {
    final map = await _invokeMap('media', <String, Object?>{'cmd': cmd});
    final state = map['state'];
    return state is String && state.isNotEmpty ? state : 'unknown';
  }

  @override
  Future<int> volumeSet(int level) async {
    final map = await _invokeMap('volumeSet', <String, Object?>{
      'level': level,
    });
    final applied = map['level'];
    return applied is int ? applied : level;
  }

  @override
  Future<NowPlayingSnapshot> nowPlaying(List<String> players) async {
    final map = await _invokeMap('nowPlaying', <String, Object?>{
      'players': players,
    });
    final state = map['state'];
    return NowPlayingSnapshot(
      state: state is String && state.isNotEmpty ? state : 'unknown',
      title: map['title'] as String?,
      artist: map['artist'] as String?,
      app: map['app'] as String?,
    );
  }

  @override
  Future<void> appLaunch({
    required AppLaunchKind kind,
    required String target,
  }) async {
    await _invokeMap('appLaunch', <String, Object?>{
      'kind': kind.wire,
      'target': target,
    });
  }

  @override
  Future<void> urlOpen(String url) async {
    await _invokeMap('urlOpen', <String, Object?>{'url': url});
  }

  @override
  Future<BrowserTabSnapshot> browserCurrentUrl({
    String browser = 'auto',
  }) async {
    final map = await _invokeMap('browserCurrentUrl', <String, Object?>{
      'browser': browser,
    });
    final url = map['url'];
    final resolvedBrowser = map['browser'];
    if (url is! String || url.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'No active browser tab URL found',
      );
    }
    return BrowserTabSnapshot(
      url: url,
      browser: resolvedBrowser is String && resolvedBrowser.isNotEmpty
          ? resolvedBrowser
          : (browser == 'auto' ? 'edge' : browser),
    );
  }

  @override
  Future<void> workflowRun({
    required WorkflowKind kind,
    required String target,
  }) async {
    await _invokeMap('workflowRun', <String, Object?>{
      'kind': kind.wire,
      'target': target,
    });
  }

  @override
  Future<HostPermissionSnapshot> permissions() async {
    final map = await _invokeMap('permissions');
    final accRaw = map['accessibility'];
    final notifRaw = map['notifications'];
    final autoRaw = map['automation'];
    final autoMap = <String, XtpPermissionState>{};
    if (autoRaw is Map) {
      for (final entry in autoRaw.entries) {
        if (entry.key is String && entry.value is String) {
          autoMap[entry.key as String] = XtpPermissionState.fromWire(
            entry.value as String,
          );
        }
      }
    }
    return HostPermissionSnapshot(
      accessibility: accRaw is String
          ? XtpPermissionState.fromWire(accRaw)
          : XtpPermissionState.granted,
      notifications: notifRaw is String
          ? XtpPermissionState.fromWire(notifRaw)
          : XtpPermissionState.granted,
      automation: autoMap,
    );
  }

  @override
  Future<XtpPermissionState> requestPermission(String kind) async {
    final map = await _invokeMap('requestPermission', <String, Object?>{
      'kind': kind,
    });
    final state = map['state'];
    if (state is String) {
      return XtpPermissionState.fromWire(state);
    }
    return XtpPermissionState.notDetermined;
  }

  @override
  Future<HostSystemInfo> hostInfo() async {
    final map = await _invokeMap('hostInfo');
    final platformWire = map['platform'];
    final osVersion = map['osVersion'];
    final hostname = map['hostname'];
    return HostSystemInfo(
      platform: platformWire is String
          ? HostPlatform.fromWire(platformWire)
          : HostPlatform.windows,
      osVersion: osVersion is String && osVersion.isNotEmpty
          ? osVersion
          : 'unknown',
      hostname: hostname is String && hostname.isNotEmpty
          ? hostname
          : 'XUNA-PC',
    );
  }

  @override
  Future<void> showToast({required String title, required String body}) async {
    await _invokeMap('showToast', <String, Object?>{
      'title': title,
      'body': body,
    });
  }

  @override
  Future<bool> displayWake() async {
    final map = await _invokeMap('displayWake');
    final woken = map['woken'] ?? map['awake'];
    if (woken is! bool) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'displayWake returned no awake/woken result.',
      );
    }
    return woken;
  }

  @override
  Future<String> clipboardReadText() async {
    final map = await _invokeMap('clipboardReadText');
    final text = map['text'];
    return text is String ? text : '';
  }

  @override
  Future<bool> lockScreen() async {
    final map = await _invokeMap('lockScreen');
    final locked = map['locked'];
    if (locked is! bool) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'lockScreen returned no locked result.',
      );
    }
    return locked;
  }

  @override
  Future<ActiveWindowContextSnapshot> readActiveWindowContext({
    int maxChars = 600,
  }) async {
    final map = await _invokeMap('readActiveWindowContext', <String, Object?>{
      'maxChars': maxChars,
    });
    final appName = map['appName'];
    final processName = map['processName'];
    final windowTitle = map['windowTitle'];
    final focusedRole = map['focusedRole'];
    final visibleText = map['visibleText'];
    final isElevated = map['isElevated'];
    return ActiveWindowContextSnapshot(
      appName: appName is String && appName.isNotEmpty ? appName : 'unknown',
      processName: processName is String && processName.isNotEmpty
          ? processName
          : (appName is String && appName.isNotEmpty ? appName : 'unknown'),
      windowTitle: windowTitle is String ? windowTitle : '',
      focusedRole: focusedRole is String && focusedRole.isNotEmpty
          ? focusedRole
          : 'window',
      visibleText: visibleText is String ? visibleText : '',
      isElevated: isElevated is bool ? isElevated : false,
    );
  }

  @override
  Future<BrowserPageSemanticSnapshot> readBrowserPageSummary({
    String browser = 'auto',
    int maxChars = 800,
  }) async {
    final map = await _invokeMap('readBrowserPageSummary', <String, Object?>{
      'browser': browser,
      'maxChars': maxChars,
    });
    final url = map['url'];
    if (url is! String || url.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'No active browser tab URL found',
      );
    }
    final resolvedBrowser = map['browser'];
    final title = map['title'];
    final excerpt = map['excerpt'];
    final headingsRaw = map['headings'];
    final actionsRaw = map['actions'];
    final headings = <String>[];
    if (headingsRaw is List) {
      for (final h in headingsRaw) {
        if (h is String && h.trim().isNotEmpty) {
          headings.add(h.trim());
        }
      }
    }
    final actions = <String>[];
    if (actionsRaw is List) {
      for (final a in actionsRaw) {
        if (a is String && a.trim().isNotEmpty) {
          actions.add(a.trim());
        }
      }
    }
    return BrowserPageSemanticSnapshot(
      url: url,
      browser: resolvedBrowser is String && resolvedBrowser.isNotEmpty
          ? resolvedBrowser
          : (browser == 'auto' ? 'edge' : browser),
      title: title is String ? title : '',
      headings: headings,
      actions: actions,
      excerpt: excerpt is String ? excerpt : '',
    );
  }

  @override
  Future<WindowUiTreeSnapshot> inspectWindowUiTree({
    String? windowTitle,
    int maxNodes = 35,
  }) async {
    final map = await _invokeMap('inspectWindowUiTree', <String, Object?>{
      if (windowTitle != null && windowTitle.trim().isNotEmpty)
        'windowTitle': windowTitle.trim(),
      'maxNodes': maxNodes,
    });
    final winTitle = map['windowTitle'];
    final appName = map['appName'];
    final redacted = map['redactedControlsCount'];
    final rawNodes = map['nodes'];
    final nodes = <Map<String, Object?>>[];
    if (rawNodes is List) {
      for (final item in rawNodes) {
        if (item is Map) {
          nodes.add(item.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    }
    return WindowUiTreeSnapshot(
      windowTitle: winTitle is String && winTitle.isNotEmpty
          ? winTitle
          : (windowTitle ?? 'Active Window'),
      appName: appName is String ? appName : '',
      nodes: nodes,
      redactedControlsCount: redacted is int ? redacted : 0,
    );
  }

  @override
  Future<WindowUiControlActionResult> invokeWindowUiControl({
    required String action,
    required String refId,
    String? windowTitle,
    String? valueText,
    bool submit = true,
  }) async {
    final map = await _invokeMap('invokeWindowUiControl', <String, Object?>{
      'action': action,
      'refId': refId,
      if (windowTitle != null && windowTitle.trim().isNotEmpty)
        'windowTitle': windowTitle.trim(),
      if (valueText != null) 'valueText': valueText,
      'submit': submit,
    });
    final rawNodes = map['nodes'];
    final nodes = <Map<String, Object?>>[];
    if (rawNodes is List) {
      for (final item in rawNodes) {
        if (item is Map) {
          nodes.add(item.map((k, v) => MapEntry(k.toString(), v)));
        }
      }
    }
    return WindowUiControlActionResult(
      ok: map['ok'] is bool ? map['ok'] as bool : true,
      invokedRefId: map['invokedRefId'] is String
          ? map['invokedRefId'] as String
          : refId,
      detail: map['detail'] is String ? map['detail'] as String : '',
      windowTitle: map['windowTitle'] is String
          ? map['windowTitle'] as String
          : (windowTitle ?? ''),
      nodes: nodes,
    );
  }

  Future<Map<String, Object?>> _invokeMap(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final raw = await _channel
          .invokeMethod<Object?>(method, args)
          .timeout(callTimeout);
      if (raw == null) return const <String, Object?>{};
      if (raw is Map) {
        return raw.map((key, value) => MapEntry(key.toString(), value));
      }
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'os_error',
        message: 'Native channel returned non-map payload',
      );
    } on MissingPluginException {
      if (Platform.isLinux) {
        return _invokeLinuxHostFallback(method, args ?? const <String, Object?>{});
      }
      rethrow;
    } on TimeoutException {
      throw const XunaHostChannelException(
        status: XtpStatus.timeout,
        errorCode: 'deadline_exceeded',
      );
    } on PlatformException catch (error) {
      final status = switch (error.code) {
        'needs_permission' => XtpStatus.needsPermission,
        'unsupported' => XtpStatus.unsupported,
        'denied' => XtpStatus.denied,
        'invalid_args' => XtpStatus.invalidArgs,
        'timeout' => XtpStatus.timeout,
        _ => XtpStatus.failed,
      };
      final errorCode = switch (error.code) {
        'needs_permission' => 'permission_missing',
        'unsupported' => 'platform_unsupported',
        'timeout' => 'deadline_exceeded',
        _ => 'os_error',
      };
      throw XunaHostChannelException(
        status: status,
        errorCode: errorCode,
        message: error.message,
      );
    }
  }

  Future<Map<String, Object?>> _invokeLinuxHostFallback(
    String method,
    Map<String, Object?> args,
  ) async {
    switch (method) {
      case 'hostInfo':
        return <String, Object?>{
          'platform': 'linux',
          'osVersion': Platform.operatingSystemVersion,
          'hostname': Platform.localHostname,
        };
      case 'permissions':
        // No Linux permission probe exists, so report that nothing was
        // determined rather than claiming access.
        return <String, Object?>{
          'accessibility': 'not_determined',
          'notifications': 'not_determined',
          'automation': const <String, String>{},
        };
      case 'requestPermission':
        throw const XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
          message: 'Requesting OS permissions is not implemented on Linux.',
        );
      case 'media':
        final cmd = (args['cmd'] as String? ?? 'play_pause').toLowerCase();
        final pcmd = switch (cmd) {
          'next' => 'next',
          'previous' => 'previous',
          _ => 'play-pause',
        };
        await Process.run('playerctl', <String>[pcmd]);
        final st = await Process.run('playerctl', <String>['status']);
        return <String, Object?>{
          'state': st.stdout.toString().trim().toLowerCase(),
        };
      case 'volumeSet':
        final level = (args['level'] as int? ?? 50).clamp(0, 100);
        await Process.run('pactl', <String>[
          'set-sink-volume',
          '@DEFAULT_SINK@',
          '$level%',
        ]);
        return <String, Object?>{'level': level};
      case 'nowPlaying':
        final title = await Process.run('playerctl', <String>['metadata', 'title']);
        final artist = await Process.run('playerctl', <String>['metadata', 'artist']);
        final status = await Process.run('playerctl', <String>['status']);
        return <String, Object?>{
          'state': status.stdout.toString().trim().toLowerCase(),
          'title': title.stdout.toString().trim(),
          'artist': artist.stdout.toString().trim(),
          'app': 'MPRIS2',
        };
      case 'appLaunch':
      case 'workflowRun':
        final target = (args['target'] as String? ?? '').trim();
        if (target.isNotEmpty) {
          await Process.start(
            'sh',
            <String>['-c', 'gtk-launch "$target" || "$target" &'],
            mode: ProcessStartMode.detached,
          );
        }
        return const <String, Object?>{};
      case 'urlOpen':
        final url = (args['url'] as String? ?? '').trim();
        if (url.startsWith('https://')) {
          await Process.run('xdg-open', <String>[url]);
        }
        return const <String, Object?>{};
      case 'showToast':
        final title = (args['title'] as String? ?? 'XUNA').trim();
        final body = (args['body'] as String? ?? '').trim();
        if (body.isNotEmpty) {
          await Process.run('notify-send', <String>[title, body]);
        }
        return <String, Object?>{'shown': true};
      case 'clipboardReadText':
        final xclip = await Process.run('xclip', <String>['-o', '-selection', 'clipboard']);
        return <String, Object?>{'text': xclip.stdout.toString()};
      case 'readActiveWindowContext':
        final winName = await Process.run('xdotool', <String>[
          'getactivewindow',
          'getwindowname',
        ]);
        final title = winName.stdout.toString().trim();
        return <String, Object?>{
          'appName': title.isEmpty ? 'Linux Window' : title,
          'processName': 'x11',
          'windowTitle': title,
          'focusedRole': 'window',
          'visibleText': title,
          'isElevated': false,
        };
      case 'inspectWindowUiTree':
        // No Linux accessibility (AT-SPI) reader exists: report that instead of
        // returning an invented control tree the model would then act on.
        throw const XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'ui_tree_unavailable',
          message: 'UI tree inspection is not implemented on Linux.',
        );
      case 'invokeWindowUiControl':
        final action = (args['action'] as String? ?? 'invoke_ref').toLowerCase();
        final refId = (args['refId'] as String? ?? 'ui_1');
        final valueText = (args['valueText'] as String? ?? '');
        final reqTitle = (args['windowTitle'] as String? ?? '').trim();
        if (reqTitle.isNotEmpty) {
          await Process.run('wmctrl', <String>['-a', reqTitle]);
        }
        String detail = 'LINUX_XDOTOOL';
        if (action == 'bring_to_front' || action == 'focus_window') {
          detail = 'LINUX_WMCTRL_ACTIVATED';
        } else if (action == 'close_window' || action == 'kill_app') {
          await Process.run('xdotool', <String>['getactivewindow', 'windowclose']);
          detail = 'LINUX_WINDOW_CLOSED';
        } else if (action == 'shortcut' || refId.startsWith('shortcut:')) {
          final spec = refId.startsWith('shortcut:')
              ? refId.substring(9)
              : (valueText.isEmpty ? refId : valueText);
          await Process.run('xdotool', <String>['key', spec.replaceAll('cmd', 'ctrl')]);
          detail = 'LINUX_SHORTCUT:$spec';
        } else if (action.startsWith('scroll')) {
          final btn = action.contains('up')
              ? '4'
              : action.contains('left')
              ? '6'
              : action.contains('right')
              ? '7'
              : '5';
          await Process.run('xdotool', <String>['click', '--repeat', '4', btn]);
          detail = 'LINUX_SCROLLED:$action';
        } else {
          // Click/type/drag actions would land on the current pointer position and
          // ignore the requested element, so refuse instead of reporting success.
          throw XunaHostChannelException(
            status: XtpStatus.unsupported,
            errorCode: 'platform_unsupported',
            message: 'Element-targeted action "$action" is not implemented on Linux.',
          );
        }
        return <String, Object?>{
          'ok': true,
          'invokedRefId': refId,
          'detail': detail,
          'windowTitle': reqTitle,
          'nodes': const <Map<String, Object?>>[],
        };
      default:
        // Methods without a Linux implementation (lockScreen, displayWake, ...)
        // must not report an empty success.
        throw XunaHostChannelException(
          status: XtpStatus.unsupported,
          errorCode: 'platform_unsupported',
          message: '"$method" is not implemented on Linux.',
        );
    }
  }
}

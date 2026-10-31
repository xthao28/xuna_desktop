import 'dart:async';
import 'dart:convert';

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
    final woken = map['woken'];
    return woken is bool ? woken : true;
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
}

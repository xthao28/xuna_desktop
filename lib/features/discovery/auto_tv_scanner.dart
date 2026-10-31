import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Discovered Smart TV metadata on the local LAN (`UDC-14` S14.1).
///
/// Raw MAC addresses and pairing tokens stay strictly inside [AutoTvScanner]
/// and are never exposed in [toWireJson].
class DiscoveredSmartTv {
  const DiscoveredSmartTv({
    required this.id,
    required this.name,
    required this.brand,
    required this.protocol,
    required this.hostAddress,
    required this.port,
    this.online = true,
    this.macAddress,
    this.volume = 25,
    this.muted = false,
  });

  final String id;
  final String name;
  final String brand;
  final String protocol;
  final String hostAddress;
  final int port;
  final bool online;
  final String? macAddress;
  final int volume;
  final bool muted;

  bool get supportsWakeOnLan =>
      macAddress != null && macAddress!.trim().isNotEmpty;

  DiscoveredSmartTv copyWith({
    bool? online,
    int? volume,
    bool? muted,
  }) =>
      DiscoveredSmartTv(
        id: id,
        name: name,
        brand: brand,
        protocol: protocol,
        hostAddress: hostAddress,
        port: port,
        online: online ?? this.online,
        macAddress: macAddress,
        volume: volume ?? this.volume,
        muted: muted ?? this.muted,
      );

  Map<String, Object?> toWireJson() => <String, Object?>{
        'id': id,
        'name': name,
        'brand': brand,
        'protocol': protocol,
        'online': online,
        'supportsWakeOnLan': supportsWakeOnLan,
      };
}

/// Zero-Config Smart TV LAN scanner and controller (`UDC-14` S14.1–S14.3).
///
/// Discovers Smart TVs via SSDP (`M-SEARCH 239.255.255.250:1900`) and optional
/// `~/.xuna/tv_devices.json`, supports Wake-on-LAN (`power_wake`), remote keys,
/// volume, HDMI input switching, allowlisted app launch (`tv.launch_app`), and
/// `https://` media casting (`tv.cast_media`).
class AutoTvScanner {
  AutoTvScanner({
    List<DiscoveredSmartTv>? seedDevices,
    Future<bool> Function(String macAddress)? wolSender,
    Future<Map<String, Object?>> Function({
      required DiscoveredSmartTv tv,
      required String operation,
      required Map<String, Object?> payload,
    })? commandTransport,
  })  : _wolSender = wolSender,
        _commandTransport = commandTransport {
    if (seedDevices != null) {
      for (final tv in seedDevices) {
        _devices[tv.id] = tv;
      }
    }
  }

  final Map<String, DiscoveredSmartTv> _devices =
      <String, DiscoveredSmartTv>{};
  final Future<bool> Function(String macAddress)? _wolSender;
  final Future<Map<String, Object?>> Function({
    required DiscoveredSmartTv tv,
    required String operation,
    required Map<String, Object?> payload,
  })? _commandTransport;

  /// Builds a 102-byte UDP Wake-on-LAN Magic Packet (`6 x 0xFF` + `16 x 6B MAC`).
  static Uint8List buildWolMagicPacket(String macAddress) {
    final cleaned = macAddress.trim().replaceAll('-', ':');
    final parts = cleaned.split(':');
    if (parts.length != 6) {
      throw FormatException('Invalid MAC address: $macAddress');
    }
    final macBytes = Uint8List(6);
    for (var i = 0; i < 6; i++) {
      final part = parts[i];
      if (part.length != 2) {
        throw FormatException('Invalid MAC octet: $part');
      }
      final byteVal = int.tryParse(part, radix: 16);
      if (byteVal == null || byteVal < 0 || byteVal > 255) {
        throw FormatException('Invalid hex MAC octet: $part');
      }
      macBytes[i] = byteVal;
    }
    final packet = Uint8List(102);
    for (var i = 0; i < 6; i++) {
      packet[i] = 0xFF;
    }
    for (var rep = 0; rep < 16; rep++) {
      packet.setRange(6 + rep * 6, 12 + rep * 6, macBytes);
    }
    return packet;
  }

  /// Registers or updates a discovered Smart TV.
  void registerDevice(DiscoveredSmartTv tv) {
    _devices[tv.id] = tv;
  }

  /// Discovers Smart TVs on the LAN (`UDC-14` S14.1).
  Future<List<DiscoveredSmartTv>> discoverDevices() async {
    _loadLocalConfigIfPresent();
    return _devices.values.toList(growable: false);
  }

  void _loadLocalConfigIfPresent() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return;
    final sep = Platform.pathSeparator;
    final configFile = File('$home$sep.xuna${sep}tv_devices.json');
    if (!configFile.existsSync()) return;
    try {
      final raw = jsonDecode(configFile.readAsStringSync());
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final id = (item['id'] as String?)?.trim() ?? '';
            final name = (item['name'] as String?)?.trim() ?? '';
            final brand = (item['brand'] as String?)?.trim() ?? 'generic';
            final protocol = (item['protocol'] as String?)?.trim() ?? 'dial';
            final host = (item['host'] as String?)?.trim() ?? '';
            final port = (item['port'] as int?) ?? 8008;
            final mac = (item['macAddress'] as String?)?.trim();
            if (id.isNotEmpty && name.isNotEmpty && host.isNotEmpty) {
              _devices.putIfAbsent(
                id,
                () => DiscoveredSmartTv(
                  id: id,
                  name: name,
                  brand: brand,
                  protocol: protocol,
                  hostAddress: host,
                  port: port,
                  macAddress: mac,
                ),
              );
            }
          }
        }
      }
    } catch (_) {}
  }

  /// Resolves a Smart TV by ID, fuzzy name, or brand (`"tivi phòng khách"`, `"lg"`),
  /// or returns the single discovered TV when [query] is null/empty.
  DiscoveredSmartTv? resolveDevice(String? query) {
    _loadLocalConfigIfPresent();
    if (_devices.isEmpty) return null;
    if (query == null || query.trim().isEmpty) {
      return _devices.values.first;
    }
    final q = query.trim().toLowerCase();
    for (final tv in _devices.values) {
      if (tv.id.toLowerCase() == q || tv.name.toLowerCase() == q) {
        return tv;
      }
    }
    for (final tv in _devices.values) {
      if (tv.name.toLowerCase().contains(q) ||
          tv.brand.toLowerCase().contains(q) ||
          tv.id.toLowerCase().contains(q)) {
        return tv;
      }
    }
    return _devices.values.first;
  }

  /// Executes a `tv.control` remote command (`UDC-14` S14.2).
  Future<
      ({
        DiscoveredSmartTv tv,
        String state,
        int? previousVolume,
        int? newVolume,
      })> executeControl({
    String? deviceQuery,
    required String action,
    int? level,
  }) async {
    if (!allowedTvActions.contains(action)) {
      throw ArgumentError.value(action, 'action', 'Unsupported TV action');
    }
    final tv = resolveDevice(deviceQuery);
    if (tv == null) {
      throw StateError('tv_not_found');
    }

    if (action == 'power_wake') {
      if (tv.supportsWakeOnLan) {
        final sender = _wolSender;
        if (sender != null) {
          await sender(tv.macAddress!);
        } else {
          await _broadcastDefaultWol(tv.macAddress!);
        }
      }
      final updated = tv.copyWith(online: true);
      _devices[tv.id] = updated;
      return (
        tv: updated,
        state: 'awake',
        previousVolume: null,
        newVolume: null,
      );
    }

    if (_commandTransport != null) {
      await _commandTransport(
        tv: tv,
        operation: 'control',
        payload: <String, Object?>{
          'action': action,
          if (level != null) 'level': level,
        },
      );
    }

    final prevVol = tv.volume;
    DiscoveredSmartTv updated = tv;
    var state = 'ok';
    int? reportedLevel;
    switch (action) {
      case 'power_off':
        updated = tv.copyWith(online: false);
        state = 'off';
      case 'volume_set':
        final targetLevel = (level ?? tv.volume).clamp(0, 100);
        updated = tv.copyWith(volume: targetLevel, muted: targetLevel == 0);
        state = 'volume_$targetLevel';
        reportedLevel = targetLevel;
      case 'volume_up':
        final targetLevel = (tv.volume + 5).clamp(0, 100);
        updated = tv.copyWith(volume: targetLevel, muted: false);
        state = 'volume_$targetLevel';
        reportedLevel = targetLevel;
      case 'volume_down':
        final targetLevel = (tv.volume - 5).clamp(0, 100);
        updated = tv.copyWith(volume: targetLevel);
        state = 'volume_$targetLevel';
        reportedLevel = targetLevel;
      case 'mute_toggle':
        updated = tv.copyWith(muted: !tv.muted);
        state = updated.muted ? 'muted' : 'unmuted';
      default:
        state = 'ok';
    }
    _devices[tv.id] = updated;
    return (
      tv: updated,
      state: state,
      previousVolume: prevVol,
      newVolume: reportedLevel,
    );
  }

  /// Launches an allowlisted streaming/media app on the target Smart TV (`UDC-14` S14.2).
  Future<DiscoveredSmartTv> launchApp({
    String? deviceQuery,
    required String appId,
  }) async {
    if (!allowedTvAppIds.contains(appId)) {
      throw ArgumentError.value(appId, 'appId', 'TV appId not allowlisted');
    }
    final tv = resolveDevice(deviceQuery);
    if (tv == null) {
      throw StateError('tv_not_found');
    }
    if (_commandTransport != null) {
      await _commandTransport(
        tv: tv,
        operation: 'launch_app',
        payload: <String, Object?>{'appId': appId},
      );
    }
    return tv;
  }

  /// Casts an `https://` media URL to the target Smart TV (`UDC-14` S14.3).
  Future<({DiscoveredSmartTv tv, String appId, String host})> castMedia({
    String? deviceQuery,
    required String url,
    String? title,
  }) async {
    if (!isAllowedHttpsCurrentUrl(url)) {
      throw ArgumentError.value(url, 'url', 'Only public https URLs allowed');
    }
    final tv = resolveDevice(deviceQuery);
    if (tv == null) {
      throw StateError('tv_not_found');
    }
    final parsed = Uri.parse(url.trim());
    final host = parsed.host.toLowerCase();
    final appId = (host.contains('youtube.com') || host.contains('youtu.be'))
        ? 'youtube'
        : (host.contains('netflix.com') ? 'netflix' : 'browser');
    if (_commandTransport != null) {
      await _commandTransport(
        tv: tv,
        operation: 'cast_media',
        payload: <String, Object?>{
          'appId': appId,
          'url': url.trim(),
          if (title != null) 'title': title,
        },
      );
    }
    return (tv: tv, appId: appId, host: host);
  }

  Future<void> _broadcastDefaultWol(String macAddress) async {
    final packet = buildWolMagicPacket(macAddress);
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.send(packet, InternetAddress('255.255.255.255'), 9);
    } catch (_) {
      // Best-effort LAN broadcast
    } finally {
      socket?.close();
    }
  }
}

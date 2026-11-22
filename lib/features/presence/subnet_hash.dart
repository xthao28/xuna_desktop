import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// Computes a privacy-preserving 32-char lowercase hex `subnetHash` from the
/// active non-loopback local network prefix (`XUNA_SPATIAL_DEVICE_MESH.md` §6.2).
///
/// Canonical formula (deterministic across Desktop and Mobile):
/// - IPv4 `/24`: `'ipv4:<b0>.<b1>.<b2>.0/24'`
/// - IPv6 `/64`: `'ipv6:<h0>:<h1>:<h2>:<h3>::/64'` (four 4-digit lowercase hex groups)
/// - Input: `'xuna.mesh.subnet.v1:<canonicalPrefix>'`
/// - Output: first 32 lowercase hex chars of `SHA-256(utf8.encode(input))`
///
/// Raw IP addresses and Wi-Fi SSIDs never leave the host and are never logged.
/// Returns `null` when offline or when only loopback/link-local addresses exist.
class SubnetHashCalculator {
  SubnetHashCalculator({
    Future<List<NetworkInterface>> Function()? interfaceLister,
    Duration timeout = defaultTimeout,
  }) : _interfaceLister =
           interfaceLister ??
           (() => NetworkInterface.list(includeLoopback: false)),
       _timeout = timeout;

  static const String domainPrefix = 'xuna.mesh.subnet.v1:';
  static const Duration defaultTimeout = Duration(milliseconds: 500);
  final Future<List<NetworkInterface>> Function() _interfaceLister;
  final Duration _timeout;

  Future<String?> compute() async {
    try {
      final interfaces = await _interfaceLister().timeout(_timeout);
      return computeFromAddresses(
        interfaces.expand((iface) => iface.addresses),
      );
    } catch (_) {
      return null;
    }
  }

  /// Computes the canonical `subnetHash` from [addresses], or returns `null` if
  /// no usable non-loopback, non-link-local address is present.
  static String? computeFromAddresses(Iterable<InternetAddress> addresses) {
    final privateIpv4Prefixes = <String>[];
    final otherIpv4Prefixes = <String>[];
    final ipv6Prefixes = <String>[];

    for (final addr in addresses) {
      if (addr.isLoopback || addr.isLinkLocal) {
        continue;
      }
      final bytes = addr.rawAddress;
      if (addr.type == InternetAddressType.IPv4 && bytes.length == 4) {
        final b0 = bytes[0];
        final b1 = bytes[1];
        // Skip unspecified (0.0.0.0/8), loopback (127.0.0.0/8), and link-local (169.254.0.0/16).
        if (b0 == 0 || b0 == 127 || (b0 == 169 && b1 == 254)) {
          continue;
        }
        final prefix = 'ipv4:$b0.$b1.${bytes[2]}.0/24';
        if (_isPrivateOrCgnatIpv4(b0, b1)) {
          privateIpv4Prefixes.add(prefix);
        } else {
          otherIpv4Prefixes.add(prefix);
        }
      } else if (addr.type == InternetAddressType.IPv6 && bytes.length == 16) {
        if (_isLoopbackOrUnspecifiedIpv6(bytes) || _isLinkLocalIpv6(bytes)) {
          continue;
        }
        final g0 = _hex16(bytes[0], bytes[1]);
        final g1 = _hex16(bytes[2], bytes[3]);
        final g2 = _hex16(bytes[4], bytes[5]);
        final g3 = _hex16(bytes[6], bytes[7]);
        ipv6Prefixes.add('ipv6:$g0:$g1:$g2:$g3::/64');
      }
    }

    final List<String> chosenTier;
    if (privateIpv4Prefixes.isNotEmpty) {
      chosenTier = privateIpv4Prefixes;
    } else if (otherIpv4Prefixes.isNotEmpty) {
      chosenTier = otherIpv4Prefixes;
    } else if (ipv6Prefixes.isNotEmpty) {
      chosenTier = ipv6Prefixes;
    } else {
      return null;
    }

    chosenTier.sort();
    final canonicalPrefix = chosenTier.first;
    final digest = sha256.convert(utf8.encode('$domainPrefix$canonicalPrefix'));
    return digest.toString().substring(0, 32);
  }

  static bool _isPrivateOrCgnatIpv4(int b0, int b1) =>
      b0 == 10 ||
      (b0 == 172 && b1 >= 16 && b1 <= 31) ||
      (b0 == 192 && b1 == 168) ||
      (b0 == 100 && b1 >= 64 && b1 <= 127);

  static bool _isLoopbackOrUnspecifiedIpv6(List<int> bytes) {
    var allZeroPrefix = true;
    for (var i = 0; i < 15; i++) {
      if (bytes[i] != 0) {
        allZeroPrefix = false;
        break;
      }
    }
    return allZeroPrefix && (bytes[15] == 0 || bytes[15] == 1);
  }

  static bool _isLinkLocalIpv6(List<int> bytes) =>
      bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;

  static String _hex16(int hi, int lo) =>
      ((hi << 8) | lo).toRadixString(16).padLeft(4, '0');
}

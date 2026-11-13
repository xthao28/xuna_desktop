/// Validates and normalizes an entry in `host-policy.json` `urlDomains`.
String normalizeDomainAllowlistEntry(String domain) {
  final trimmed = domain.trim().toLowerCase();
  if (trimmed.isEmpty ||
      trimmed.startsWith('.') ||
      trimmed.endsWith('.') ||
      trimmed.contains('/')) {
    throw FormatException('Invalid domain in urlDomains: $domain');
  }
  final asciiHost = idnToAscii(trimmed);
  if (_isForbiddenLiteralOrLocalHost(asciiHost)) {
    throw FormatException('Forbidden local/IP domain in urlDomains: $domain');
  }
  return asciiHost;
}

/// Result of validating a URL for `url.open` (`XUNA_XTP_V1_CONTRACT.md` §6).
typedef UrlValidationResult = ({
  bool validUrl,
  bool domainAllowed,
  String? asciiHost,
  String? errorCode,
});

/// Validates [rawUrl] per `XUNA_XTP_V1_CONTRACT.md` §6:
/// 1. `https` scheme only (case-insensitive)
/// 2. Length `<= 2048` and no `userinfo` (`user:pass@`)
/// 3. Hostname converted from IDN to ASCII punycode (`xn--...`)
/// 4. Reject IPv4 literals, IPv6 literals, `localhost`, `.local`, `.localhost`
/// 5. ASCII hostname equals or is a `.`-bounded subdomain of an entry in
///    [allowedDomains].
UrlValidationResult validateHttpsUrlAgainstAllowlist(
  String rawUrl,
  List<String> allowedDomains,
) {
  if (rawUrl.isEmpty || rawUrl.length > 2048) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  // Extract raw authority to detect unicode hostnames before Uri.tryParse
  final schemeSep = rawUrl.indexOf('://');
  if (schemeSep <= 0) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  final scheme = rawUrl.substring(0, schemeSep).toLowerCase();
  if (scheme != 'https') {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  final afterScheme = rawUrl.substring(schemeSep + 3);
  final slashIdx = afterScheme.indexOf('/');
  final queryIdx = afterScheme.indexOf('?');
  final hashIdx = afterScheme.indexOf('#');
  var authorityEnd = afterScheme.length;
  for (final idx in <int>[slashIdx, queryIdx, hashIdx]) {
    if (idx != -1 && idx < authorityEnd) {
      authorityEnd = idx;
    }
  }
  final authority = afterScheme.substring(0, authorityEnd);
  if (authority.isEmpty || authority.contains('@')) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  if (authority.startsWith('[')) {
    // IPv6 literal
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  var rawHost = authority;
  final colonIdx = authority.indexOf(':');
  if (colonIdx != -1) {
    final portStr = authority.substring(colonIdx + 1);
    final port = int.tryParse(portStr);
    if (port == null || port <= 0 || port > 65535) {
      return (
        validUrl: false,
        domainAllowed: false,
        asciiHost: null,
        errorCode: 'url_invalid',
      );
    }
    rawHost = authority.substring(0, colonIdx);
  }
  if (rawHost.isEmpty || rawHost.endsWith('.')) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  final String asciiHost;
  try {
    asciiHost = idnToAscii(rawHost);
  } on FormatException {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  if (_isForbiddenLiteralOrLocalHost(asciiHost)) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  // Verify the normalized URL also parses cleanly as a standard URI.
  final normalizedUrl =
      'https://$asciiHost${colonIdx != -1 ? authority.substring(colonIdx) : ''}${afterScheme.substring(authorityEnd)}';
  final parsed = Uri.tryParse(normalizedUrl);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.userInfo.isNotEmpty) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  var matched = false;
  for (final entry in allowedDomains) {
    final allowed = entry.toLowerCase();
    if (asciiHost == allowed || asciiHost.endsWith('.$allowed')) {
      matched = true;
      break;
    }
  }

  return (
    validUrl: true,
    domainAllowed: matched,
    asciiHost: asciiHost,
    errorCode: matched ? null : 'domain_not_allowed',
  );
}

/// Returns `true` if [rawUrl] is a valid public `https://` URL (rejecting
/// `http://`, `file://`, loopback/private IPs, `localhost`, `.local`).
bool isAllowedHttpsCurrentUrl(String rawUrl) =>
    validateHttpsUrlAgainstAllowlist(rawUrl, const <String>[]).validUrl;

bool _isForbiddenLiteralOrLocalHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' ||
      lower.endsWith('.localhost') ||
      lower.endsWith('.local')) {
    return true;
  }
  if (lower.contains(':')) {
    return true;
  }
  final parts = lower.split('.');
  if (parts.length == 4 &&
      parts.every((p) => RegExp(r'^[0-9]{1,3}$').hasMatch(p))) {
    return true;
  }
  // Reject numeric-only TLD or single-label hostnames
  if (parts.length < 2 || RegExp(r'^[0-9]+$').hasMatch(parts.last)) {
    return true;
  }
  return false;
}

/// Converts a domain name (potentially containing Unicode IDN labels) into
/// lower-case ASCII punycode (`xn--...`) per RFC 3492.
String idnToAscii(String domain) {
  final labels = domain.toLowerCase().split('.');
  if (labels.isEmpty) {
    throw const FormatException('Empty domain');
  }
  final encodedLabels = <String>[];
  for (final label in labels) {
    if (label.isEmpty) {
      throw const FormatException('Empty domain label');
    }
    final isAscii = label.runes.every((r) => r < 0x80);
    final asciiLabel = isAscii ? label : 'xn--${_punycodeEncode(label)}';
    if (asciiLabel.length > 63 ||
        asciiLabel.startsWith('-') ||
        asciiLabel.endsWith('-') ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(asciiLabel)) {
      throw FormatException('Invalid domain label: $label');
    }
    encodedLabels.add(asciiLabel);
  }
  final joined = encodedLabels.join('.');
  if (joined.length > 253) {
    throw const FormatException('Domain exceeds 253 characters');
  }
  return joined;
}

String _punycodeEncode(String input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const skew = 38;
  const damp = 700;
  const initialBias = 72;
  const initialN = 0x80;

  final codePoints = input.runes.toList();
  final output = StringBuffer();
  var basicCount = 0;
  for (final cp in codePoints) {
    if (cp < 0x80) {
      output.writeCharCode(cp);
      basicCount++;
    }
  }
  if (basicCount > 0) {
    output.write('-');
  }

  var n = initialN;
  var delta = 0;
  var bias = initialBias;
  var h = basicCount;

  int adapt(int deltaValue, int numPoints, bool firstTime) {
    var d = firstTime ? (deltaValue ~/ damp) : (deltaValue >> 1);
    d += d ~/ numPoints;
    var k = 0;
    while (d > ((base - tMin) * tMax) ~/ 2) {
      d ~/= base - tMin;
      k += base;
    }
    return k + (((base - tMin + 1) * d) ~/ (d + skew));
  }

  int encodeDigit(int d) => d < 26 ? (0x61 + d) : (0x30 + (d - 26));

  while (h < codePoints.length) {
    var m = 0x10ffff + 1;
    for (final cp in codePoints) {
      if (cp >= n && cp < m) {
        m = cp;
      }
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (final cp in codePoints) {
      if (cp < n) {
        delta++;
      } else if (cp == n) {
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          output.writeCharCode(encodeDigit(t + ((q - t) % (base - t))));
          q = (q - t) ~/ (base - t);
        }
        output.writeCharCode(encodeDigit(q));
        bias = adapt(delta, h + 1, h == basicCount);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}

/// Whether a resolved IP address ([raw] is 4 or 16 bytes) is a public internet
/// address `url.open` may reach (UDC-17 S17.6).
///
/// Refuses loopback, private (RFC 1918, ULA), link-local, carrier-grade NAT,
/// unspecified, multicast, broadcast, reserved and documentation ranges, and
/// IPv6 forms that embed an IPv4 address (mapped, compatible, NAT64, 6to4,
/// Teredo) unless the embedded address itself is public. Anything that is not
/// 4 or 16 bytes is refused.
bool isPublicIpAddress(List<int> raw) {
  if (raw.length == 4) return _isPublicIpv4(raw);
  if (raw.length != 16) return false;
  bool prefix(List<int> bytes) {
    for (var i = 0; i < bytes.length; i++) {
      if (raw[i] != bytes[i]) return false;
    }
    return true;
  }

  final allZeroHead = raw.sublist(0, 10).every((b) => b == 0);
  // ::ffff:a.b.c.d (mapped) and ::a.b.c.d (compatible, also :: and ::1).
  if (allZeroHead && raw[10] == 0xff && raw[11] == 0xff) {
    return _isPublicIpv4(raw.sublist(12));
  }
  if (allZeroHead && raw[10] == 0 && raw[11] == 0) return false;
  // 64:ff9b::/96 NAT64 carries an IPv4 address in the last 4 bytes.
  if (prefix(const <int>[0x00, 0x64, 0xff, 0x9b]) &&
      raw.sublist(4, 12).every((b) => b == 0)) {
    return _isPublicIpv4(raw.sublist(12));
  }
  final first = raw[0];
  if ((first & 0xfe) == 0xfc) return false; // fc00::/7 unique local
  if (first == 0xfe && (raw[1] & 0xc0) == 0x80) return false; // fe80::/10
  if (first == 0xff) return false; // ff00::/8 multicast
  if (prefix(const <int>[0x20, 0x01, 0x0d, 0xb8])) return false; // docs
  if (prefix(const <int>[0x20, 0x01, 0x00, 0x00])) return false; // Teredo
  if (prefix(const <int>[0x20, 0x02])) return false; // 6to4
  // Only global unicast (2000::/3) is public.
  return (first & 0xe0) == 0x20;
}

bool _isPublicIpv4(List<int> b) {
  final a = b[0];
  final c = b[1];
  if (a == 0 || a == 10 || a == 127) return false;
  if (a == 100 && (c & 0xc0) == 64) return false; // 100.64.0.0/10 CGNAT
  if (a == 169 && c == 254) return false; // link-local
  if (a == 172 && (c & 0xf0) == 16) return false; // 172.16.0.0/12
  if (a == 192 && c == 168) return false;
  if (a == 192 && c == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (a == 198 && (c == 18 || c == 19)) return false; // benchmarking
  if (a == 198 && c == 51 && b[2] == 100) return false; // docs
  if (a == 203 && c == 0 && b[2] == 113) return false; // docs
  if (a >= 224) return false; // multicast, reserved, broadcast
  return true;
}

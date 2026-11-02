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

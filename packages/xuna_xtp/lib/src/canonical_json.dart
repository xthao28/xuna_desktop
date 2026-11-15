import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Encodes [value] into canonical JSON per `XUNA_XTP_V1_CONTRACT.md` §3.3:
/// - UTF-8, no BOM
/// - Object keys sorted lexicographically by Unicode code point
/// - No insignificant whitespace (`","` and `":"` separators)
/// - Integers in base 10 without exponent; finite floating-point numbers follow
///   RFC 8785 (JCS / ECMA-262) deterministic formatting (`NaN` and `±Infinity`
///   are rejected).
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(buffer, value);
  return buffer.toString();
}

/// Computes `hex(sha256(canonical_json(arguments)))` for approval binding.
String argsSha256(Map<String, Object?> arguments) {
  final encoded = utf8.encode(canonicalJson(arguments));
  return sha256.convert(encoded).toString();
}

void _writeCanonical(StringBuffer buffer, Object? value) {
  if (value == null) {
    buffer.write('null');
    return;
  }
  if (value is bool) {
    buffer.write(value ? 'true' : 'false');
    return;
  }
  if (value is int) {
    buffer.write(value.toString());
    return;
  }
  if (value is double) {
    buffer.write(_formatJcsDouble(value));
    return;
  }
  if (value is String) {
    buffer.write(jsonEncode(value));
    return;
  }
  if (value is List) {
    buffer.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buffer.write(',');
      _writeCanonical(buffer, value[i]);
    }
    buffer.write(']');
    return;
  }
  if (value is Map) {
    final keys = <String>[];
    for (final key in value.keys) {
      if (key is! String) {
        throw const FormatException(
            'Canonical JSON object keys must be strings');
      }
      keys.add(key);
    }
    keys.sort();
    buffer.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buffer.write(',');
      final key = keys[i];
      buffer.write(jsonEncode(key));
      buffer.write(':');
      _writeCanonical(buffer, value[key]);
    }
    buffer.write('}');
    return;
  }
  throw FormatException(
    'Unsupported type in canonical JSON: ${value.runtimeType}',
  );
}

String _formatJcsDouble(double value) {
  if (value.isNaN || value.isInfinite) {
    throw const FormatException(
      'Infinite or NaN floating-point numbers are not allowed in canonical JSON',
    );
  }
  if (value == 0.0) {
    return '0';
  }
  final sign = value < 0.0 ? '-' : '';
  final s = (value < 0.0 ? -value : value).toString().toLowerCase();
  late final String mant;
  late final int exp;
  final eIndex = s.indexOf('e');
  if (eIndex >= 0) {
    mant = s.substring(0, eIndex);
    exp = int.parse(s.substring(eIndex + 1));
  } else {
    mant = s;
    exp = 0;
  }
  late final String rawDigits;
  late final int rawExp;
  final dotIndex = mant.indexOf('.');
  if (dotIndex >= 0) {
    final intPart = mant.substring(0, dotIndex);
    final fracPart = mant.substring(dotIndex + 1);
    rawDigits = '$intPart$fracPart';
    rawExp = exp - fracPart.length;
  } else {
    rawDigits = mant;
    rawExp = exp;
  }
  final strippedLeading = rawDigits.replaceFirst(RegExp(r'^0+'), '');
  final digits = strippedLeading.replaceFirst(RegExp(r'0+$'), '');
  final tz = strippedLeading.length - digits.length;
  final actualExp = rawExp + tz;
  final k = digits.length;
  final n = actualExp + k;
  late final String body;
  if (k <= n && n <= 21) {
    body = '$digits${'0' * (n - k)}';
  } else if (0 < n && n <= 21) {
    body = '${digits.substring(0, n)}.${digits.substring(n)}';
  } else if (-6 < n && n <= 0) {
    body = '0.${'0' * (-n)}$digits';
  } else {
    final mantissa =
        k == 1 ? digits : '${digits.substring(0, 1)}.${digits.substring(1)}';
    final expVal = n - 1;
    final expSign = expVal >= 0 ? '+' : '-';
    body = '${mantissa}e$expSign${expVal.abs()}';
  }
  return '$sign$body';
}

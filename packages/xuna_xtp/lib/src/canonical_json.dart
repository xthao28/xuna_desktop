import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Encodes [value] into canonical JSON per `XUNA_XTP_V1_CONTRACT.md` §3.3:
/// - UTF-8, no BOM
/// - Object keys sorted lexicographically by Unicode code point
/// - No insignificant whitespace (`","` and `":"` separators)
/// - Integers in base 10 without exponent; floating-point numbers are rejected
///   in XTP v1 tool arguments.
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
  if (value is num) {
    throw const FormatException(
      'Floating-point numbers are not allowed in XTP v1 canonical JSON',
    );
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

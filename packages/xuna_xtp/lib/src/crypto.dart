import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'schemas.dart';

/// Domain prefix for `xuna.host.proof.v1\0` (19 bytes).
final Uint8List hostProofDomain = Uint8List.fromList(
  <int>[...ascii.encode('xuna.host.proof.v1'), 0x00],
);

/// Domain prefix for `xuna.host.sas.v1` (16 bytes).
final Uint8List hostSasDomain = Uint8List.fromList(
  ascii.encode('xuna.host.sas.v1'),
);

/// Domain prefix for `xuna.approval.v1\0` (17 bytes, `UDC-7` S7.5).
final Uint8List approvalProofDomain = Uint8List.fromList(
  <int>[...ascii.encode('xuna.approval.v1'), 0x00],
);

const int hostProofNonceSize = 32;
const int hostEnrollmentCodeSize = 16;
const int hostPublicKeySize = 65;
const int hostSignatureSize = 64;
const int hostProofMessageSize = 100;

/// Validates an uncompressed SEC1 P-256 public key (`65` bytes starting with `0x04`).
void validateP256PublicKey(Uint8List publicKey) {
  if (publicKey.length != hostPublicKeySize || publicKey[0] != 0x04) {
    throw const FormatException(
      'Public key must be a 65-byte uncompressed P-256 point starting with 0x04',
    );
  }
}

/// Validates a 64-byte raw `r || s` P-256 signature.
void validateP256Signature(Uint8List signature) {
  if (signature.length != hostSignatureSize) {
    throw const FormatException('Signature must be 64 bytes (raw r || s)');
  }
}

/// Parses a canonical UUID (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`) or 32-hex
/// string into 16 raw bytes.
Uint8List uuidToBytes(String uuid) {
  final compact = uuid.replaceAll('-', '');
  if (compact.length != 32 || !RegExp(r'^[0-9a-fA-F]{32}$').hasMatch(compact)) {
    throw FormatException('Invalid UUID: $uuid');
  }
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    out[i] = int.parse(compact.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Builds the 100-byte `host_proof_message` per `XUNA_XTP_V1_CONTRACT.md` §3.1:
///
/// ```text
/// domain (19B) || nonce (32B) || hostId (16B) || purpose (1B) || sha256(payload) (32B)
/// ```
///
/// When [purpose] is [HostProofPurpose.enroll], [hostIdUuid] must be omitted or
/// the zero UUID (`00000000-0000-0000-0000-000000000000`), and [payload] must
/// be the 16-byte enrollment code.
/// When [purpose] is [HostProofPurpose.session], [hostIdUuid] must be a non-zero
/// UUID and [payload] must be the 65-byte uncompressed P-256 public key.
Uint8List hostProofMessage({
  required Uint8List nonce,
  required HostProofPurpose purpose,
  required Uint8List payload,
  String? hostIdUuid,
}) {
  if (nonce.length != hostProofNonceSize) {
    throw const FormatException('nonce must be 32 bytes');
  }
  late final Uint8List hostIdBytes;
  switch (purpose) {
    case HostProofPurpose.enroll:
      if (payload.length != hostEnrollmentCodeSize) {
        throw const FormatException(
          'Enroll proof payload must be the 16-byte enrollment code',
        );
      }
      if (hostIdUuid != null &&
          hostIdUuid != '00000000-0000-0000-0000-000000000000') {
        throw const FormatException(
          'Enroll proof hostId must be zero UUID or omitted',
        );
      }
      hostIdBytes = Uint8List(16);
    case HostProofPurpose.session:
      validateP256PublicKey(payload);
      if (hostIdUuid == null) {
        throw const FormatException('Session proof requires hostIdUuid');
      }
      hostIdBytes = uuidToBytes(hostIdUuid);
      if (hostIdBytes.every((b) => b == 0)) {
        throw const FormatException('Session proof hostId cannot be all zeros');
      }
  }

  final payloadHash = sha256.convert(payload).bytes;
  final builder = BytesBuilder(copy: false)
    ..add(hostProofDomain)
    ..add(nonce)
    ..add(hostIdBytes)
    ..addByte(purpose.code)
    ..add(payloadHash);
  final bytes = builder.toBytes();
  assert(bytes.length == hostProofMessageSize);
  return bytes;
}

/// Computes the 6-digit Short Authentication String (SAS) per `ADR-0013` and
/// `XUNA_XTP_V1_CONTRACT.md` §3.2:
///
/// ```python
/// int.from_bytes(sha256(b"xuna.host.sas.v1" + code_16b + pubkey_65b)[:4], "big") % 1_000_000
/// ```
String computeSas({
  required Uint8List enrollmentCode,
  required Uint8List publicKey,
}) {
  if (enrollmentCode.length != hostEnrollmentCodeSize) {
    throw const FormatException('enrollmentCode must be 16 bytes');
  }
  validateP256PublicKey(publicKey);
  final input = BytesBuilder(copy: false)
    ..add(hostSasDomain)
    ..add(enrollmentCode)
    ..add(publicKey);
  final digest = sha256.convert(input.toBytes()).bytes;
  final top32 =
      ((digest[0] << 24) | (digest[1] << 16) | (digest[2] << 8) | digest[3]) >>>
          0;
  final value = top32 % 1000000;
  return value.toString().padLeft(6, '0');
}

/// Computes the 16-byte public key fingerprint (`SHA-256(publicKey)[:16]`).
Uint8List publicKeyFingerprint(Uint8List publicKey) {
  validateP256PublicKey(publicKey);
  final digest = sha256.convert(publicKey).bytes;
  return Uint8List.fromList(digest.sublist(0, 16));
}

/// Encodes bytes as unpadded base64url.
String base64UrlNoPadEncode(Uint8List bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Decodes unpadded (or padded) base64url into bytes.
Uint8List base64UrlDecodeLoose(String input) {
  final normalized = switch (input.length % 4) {
    0 => input,
    2 => '$input==',
    3 => '$input=',
    _ => throw const FormatException('Invalid base64url length'),
  };
  return Uint8List.fromList(base64Url.decode(normalized));
}

/// Builds the enrollment QR URI (`XUNA_XTP_V1_CONTRACT.md` §3.2):
/// `xuna-host://enroll?v=1&c=<code b64url 16B>&k=<pubkey fingerprint b64url 16B>&n=<hostname>`
String buildEnrollmentUri({
  required Uint8List enrollmentCode,
  required Uint8List publicKey,
  required String hostname,
}) {
  if (enrollmentCode.length != hostEnrollmentCodeSize) {
    throw const FormatException('enrollmentCode must be 16 bytes');
  }
  validateP256PublicKey(publicKey);
  final cleanHost = hostname.trim();
  if (cleanHost.isEmpty) {
    throw const FormatException('hostname must not be empty');
  }
  final truncatedHost =
      cleanHost.length <= 32 ? cleanHost : cleanHost.substring(0, 32);
  final c = base64UrlNoPadEncode(enrollmentCode);
  final k = base64UrlNoPadEncode(publicKeyFingerprint(publicKey));
  final n = Uri.encodeQueryComponent(truncatedHost);
  return 'xuna-host://enroll?v=1&c=$c&k=$k&n=$n';
}

/// Converts a DER-encoded ASN.1 ECDSA P-256 signature (as returned by macOS
/// `SecKeyCreateSignature`) into a 64-byte raw `r || s` signature (`UDC-3` §5.6.3).
Uint8List derToRawP256Signature(Uint8List der) {
  if (der.length < 8 || der[0] != 0x30) {
    throw const FormatException('Invalid DER ECDSA signature header');
  }
  var offset = 1;
  final seqLen = _readDerLength(der, offset);
  offset = seqLen.nextOffset;
  if (offset + seqLen.length != der.length) {
    throw const FormatException('DER sequence length mismatch');
  }
  final rInt = _readDerInteger(der, offset);
  offset = rInt.nextOffset;
  final sInt = _readDerInteger(der, offset);
  if (sInt.nextOffset != der.length) {
    throw const FormatException('Trailing bytes in DER signature');
  }
  final out = Uint8List(64);
  out.setRange(0, 32, _toFixed32Bytes(rInt.bytes));
  out.setRange(32, 64, _toFixed32Bytes(sInt.bytes));
  return out;
}

/// Converts a 64-byte raw `r || s` P-256 signature into canonical ASN.1 DER.
Uint8List rawToDerP256Signature(Uint8List raw) {
  validateP256Signature(raw);
  final rDer = _encodeDerInteger(raw.sublist(0, 32));
  final sDer = _encodeDerInteger(raw.sublist(32, 64));
  final seqBodyLen = rDer.length + sDer.length;
  final out = BytesBuilder(copy: false)
    ..addByte(0x30)
    ..addByte(seqBodyLen)
    ..add(rDer)
    ..add(sDer);
  return out.toBytes();
}

({int length, int nextOffset}) _readDerLength(Uint8List bytes, int offset) {
  if (offset >= bytes.length) {
    throw const FormatException('Unexpected end of DER length');
  }
  final first = bytes[offset];
  if ((first & 0x80) == 0) {
    return (length: first, nextOffset: offset + 1);
  }
  final count = first & 0x7f;
  if (count != 1 || offset + 1 >= bytes.length) {
    throw const FormatException('Unsupported DER length encoding');
  }
  return (length: bytes[offset + 1], nextOffset: offset + 2);
}

({Uint8List bytes, int nextOffset}) _readDerInteger(
  Uint8List bytes,
  int offset,
) {
  if (offset >= bytes.length || bytes[offset] != 0x02) {
    throw const FormatException('Expected DER INTEGER tag (0x02)');
  }
  final lenInfo = _readDerLength(bytes, offset + 1);
  final start = lenInfo.nextOffset;
  final end = start + lenInfo.length;
  if (lenInfo.length <= 0 || end > bytes.length) {
    throw const FormatException('Invalid DER INTEGER length');
  }
  final slice = bytes.sublist(start, end);
  if ((slice[0] & 0x80) != 0) {
    throw const FormatException('Negative DER INTEGER in ECDSA signature');
  }
  if (slice.length > 1 && slice[0] == 0x00 && (slice[1] & 0x80) == 0) {
    throw const FormatException('Non-minimal leading zero in DER INTEGER');
  }
  return (bytes: slice, nextOffset: end);
}

Uint8List _toFixed32Bytes(Uint8List intBytes) {
  var start = 0;
  while (start < intBytes.length - 1 && intBytes[start] == 0) {
    start++;
  }
  final stripped = intBytes.sublist(start);
  if (stripped.length > 32) {
    throw const FormatException('ECDSA integer exceeds 32 bytes');
  }
  final out = Uint8List(32);
  out.setRange(32 - stripped.length, 32, stripped);
  return out;
}

Uint8List _encodeDerInteger(Uint8List fixed32) {
  var start = 0;
  while (start < fixed32.length - 1 && fixed32[start] == 0) {
    start++;
  }
  final stripped = fixed32.sublist(start);
  final needsZero = (stripped[0] & 0x80) != 0;
  final len = stripped.length + (needsZero ? 1 : 0);
  final out = BytesBuilder(copy: false)
    ..addByte(0x02)
    ..addByte(len);
  if (needsZero) {
    out.addByte(0x00);
  }
  out.add(stripped);
  return out.toBytes();
}

/// Builds the canonical phone-signed R3 approval message (`UDC-7` S7.5):
/// `b"xuna.approval.v1\x00" || approvalId || "|" || argsSha256 || "|" || hostId || "|" || expiresAt`.
Uint8List approvalProofMessage({
  required String approvalId,
  required String argsSha256,
  required String hostId,
  required String expiresAt,
}) {
  if (approvalId.isEmpty ||
      argsSha256.isEmpty ||
      hostId.isEmpty ||
      expiresAt.isEmpty) {
    throw const FormatException('Approval proof fields must not be empty');
  }
  final body = utf8.encode('$approvalId|$argsSha256|$hostId|$expiresAt');
  final builder = BytesBuilder(copy: false)
    ..add(approvalProofDomain)
    ..add(body);
  return builder.toBytes();
}

// NIST P-256 (secp256r1) curve parameters for pure-Dart ECDSA verification.
final BigInt _p256P = BigInt.parse(
  'ffffffff00000001000000000000000000000000ffffffffffffffffffffffff',
  radix: 16,
);
final BigInt _p256A = _p256P - BigInt.from(3);
final BigInt _p256B = BigInt.parse(
  '5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b',
  radix: 16,
);
final BigInt _p256N = BigInt.parse(
  'ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551',
  radix: 16,
);
final BigInt _p256Gx = BigInt.parse(
  '6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296',
  radix: 16,
);
final BigInt _p256Gy = BigInt.parse(
  '4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5',
  radix: 16,
);

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final b in bytes) {
    result = (result << 8) | BigInt.from(b);
  }
  return result;
}

bool _isOnP256Curve(BigInt x, BigInt y) {
  if (x <= BigInt.zero || x >= _p256P || y <= BigInt.zero || y >= _p256P) {
    return false;
  }
  final lhs = (y * y) % _p256P;
  final rhs = (((x * x) % _p256P) * x + _p256A * x + _p256B) % _p256P;
  return lhs == rhs;
}

(BigInt, BigInt)? _p256PointAdd((BigInt, BigInt)? p1, (BigInt, BigInt)? p2) {
  if (p1 == null) return p2;
  if (p2 == null) return p1;
  final (x1, y1) = p1;
  final (x2, y2) = p2;
  if (x1 == x2) {
    if ((y1 + y2) % _p256P == BigInt.zero) {
      return null;
    }
    return _p256PointDouble(p1);
  }
  final dx = (x2 - x1) % _p256P;
  final dy = (y2 - y1) % _p256P;
  final slope = (dy * dx.modInverse(_p256P)) % _p256P;
  final x3 = (slope * slope - x1 - x2) % _p256P;
  final y3 = (slope * (x1 - x3) - y1) % _p256P;
  return (x3, y3);
}

(BigInt, BigInt)? _p256PointDouble((BigInt, BigInt)? p) {
  if (p == null) return null;
  final (x, y) = p;
  if (y == BigInt.zero) return null;
  final num = (BigInt.from(3) * ((x * x) % _p256P) + _p256A) % _p256P;
  final den = (BigInt.two * y) % _p256P;
  final slope = (num * den.modInverse(_p256P)) % _p256P;
  final x3 = (slope * slope - BigInt.two * x) % _p256P;
  final y3 = (slope * (x - x3) - y) % _p256P;
  return (x3, y3);
}

(BigInt, BigInt)? _p256ScalarMul(BigInt k, (BigInt, BigInt) point) {
  (BigInt, BigInt)? result;
  (BigInt, BigInt)? addend = point;
  var scalar = k;
  while (scalar > BigInt.zero) {
    if (scalar.isOdd) {
      result = _p256PointAdd(result, addend);
    }
    addend = _p256PointDouble(addend);
    scalar >>= 1;
  }
  return result;
}

/// Verifies an ECDSA P-256 signature over SHA-256([message]).
///
/// [publicKey] must be a 65-byte uncompressed SEC1 point (`0x04 || X || Y`) and
/// [signature] must be a 64-byte raw `r || s` signature.
bool verifyP256Signature({
  required Uint8List publicKey,
  required Uint8List message,
  required Uint8List signature,
}) {
  if (publicKey.length != hostPublicKeySize || publicKey[0] != 0x04) {
    return false;
  }
  if (signature.length != hostSignatureSize) {
    return false;
  }
  final qx = _bytesToBigInt(publicKey.sublist(1, 33));
  final qy = _bytesToBigInt(publicKey.sublist(33, 65));
  if (!_isOnP256Curve(qx, qy)) {
    return false;
  }
  final r = _bytesToBigInt(signature.sublist(0, 32));
  final s = _bytesToBigInt(signature.sublist(32, 64));
  if (r <= BigInt.zero || r >= _p256N || s <= BigInt.zero || s >= _p256N) {
    return false;
  }
  final digestBytes = Uint8List.fromList(sha256.convert(message).bytes);
  final z = _bytesToBigInt(digestBytes);
  final w = s.modInverse(_p256N);
  final u1 = (z * w) % _p256N;
  final u2 = (r * w) % _p256N;
  final p1 = _p256ScalarMul(u1, (_p256Gx, _p256Gy));
  final p2 = _p256ScalarMul(u2, (qx, qy));
  final sum = _p256PointAdd(p1, p2);
  if (sum == null) {
    return false;
  }
  final (rx, _) = sum;
  return (rx % _p256N) == r;
}

Uint8List _bigIntTo32Bytes(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// Derives a 65-byte uncompressed SEC1 P-256 public key (`0x04 || X || Y`) from
/// a 32-byte private scalar [privateScalar32].
Uint8List deriveP256PublicKey(Uint8List privateScalar32) {
  if (privateScalar32.length != 32) {
    throw const FormatException('privateScalar32 must be 32 bytes');
  }
  final d = _bytesToBigInt(privateScalar32) % (_p256N - BigInt.one) + BigInt.one;
  final pub = _p256ScalarMul(d, (_p256Gx, _p256Gy));
  if (pub == null) {
    throw const FormatException('Invalid P-256 scalar');
  }
  final (qx, qy) = pub;
  final out = Uint8List(hostPublicKeySize);
  out[0] = 0x04;
  out.setRange(1, 33, _bigIntTo32Bytes(qx));
  out.setRange(33, 65, _bigIntTo32Bytes(qy));
  return out;
}

/// Deterministically signs SHA-256([message]) with a 32-byte P-256 private
/// scalar [privateScalar32], returning a 64-byte raw `r || s` signature.
Uint8List signP256Deterministic({
  required Uint8List privateScalar32,
  required Uint8List message,
}) {
  if (privateScalar32.length != 32) {
    throw const FormatException('privateScalar32 must be 32 bytes');
  }
  final d = _bytesToBigInt(privateScalar32) % (_p256N - BigInt.one) + BigInt.one;
  final digestBytes = Uint8List.fromList(sha256.convert(message).bytes);
  final z = _bytesToBigInt(digestBytes);
  for (var counter = 1; counter < 1000; counter++) {
    final kSeed = BytesBuilder(copy: false)
      ..add(privateScalar32)
      ..add(digestBytes)
      ..addByte(counter);
    final kBytes = Uint8List.fromList(sha256.convert(kSeed.toBytes()).bytes);
    final k = _bytesToBigInt(kBytes) % (_p256N - BigInt.one) + BigInt.one;
    final pt = _p256ScalarMul(k, (_p256Gx, _p256Gy));
    if (pt == null) continue;
    final (rx, _) = pt;
    final r = rx % _p256N;
    if (r == BigInt.zero) continue;
    final s = (k.modInverse(_p256N) * (z + r * d)) % _p256N;
    if (s == BigInt.zero) continue;
    final out = Uint8List(hostSignatureSize);
    out.setRange(0, 32, _bigIntTo32Bytes(r));
    out.setRange(32, 64, _bigIntTo32Bytes(s));
    return out;
  }
  throw StateError('Failed to generate P-256 signature');
}

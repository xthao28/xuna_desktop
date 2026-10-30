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

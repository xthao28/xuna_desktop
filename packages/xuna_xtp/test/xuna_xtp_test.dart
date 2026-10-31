import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

Uint8List _hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _bytesToHex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

BigInt _bytesToBigInt(Uint8List bytes) {
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

Uint8List _bigIntTo32Bytes(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  return _hexToBytes(hex);
}

bool _verifyP256RawSignature({
  required Uint8List publicKeyBytes,
  required Uint8List messageBytes,
  required Uint8List signatureRaw64,
}) {
  final params = ECCurve_secp256r1();
  final point = params.curve.decodePoint(publicKeyBytes);
  if (point == null) return false;
  final pubKey = ECPublicKey(point, params);
  final signer = ECDSASigner(SHA256Digest())
    ..init(false, PublicKeyParameter<ECPublicKey>(pubKey));
  final r = _bytesToBigInt(signatureRaw64.sublist(0, 32));
  final s = _bytesToBigInt(signatureRaw64.sublist(32, 64));
  return signer.verifySignature(messageBytes, ECSignature(r, s));
}

Uint8List _signP256RawDeterministic({
  required String privateScalarHex,
  required Uint8List messageBytes,
}) {
  final params = ECCurve_secp256r1();
  final d = BigInt.parse(privateScalarHex, radix: 16);
  final privKey = ECPrivateKey(d, params);
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
    ..init(true, PrivateKeyParameter<ECPrivateKey>(privKey));
  final sig = signer.generateSignature(messageBytes) as ECSignature;
  final out = Uint8List(64);
  out.setRange(0, 32, _bigIntTo32Bytes(sig.r));
  out.setRange(32, 64, _bigIntTo32Bytes(sig.s));
  return out;
}

void main() {
  late Map<String, Object?> golden;
  late Map<String, Object?> sampleFrames;

  setUpAll(() {
    final goldenFile = File('test/fixtures/xtp/golden_vectors.json');
    final framesFile = File('test/fixtures/xtp/sample_frames.json');
    golden = jsonDecode(goldenFile.readAsStringSync()) as Map<String, Object?>;
    sampleFrames =
        jsonDecode(framesFile.readAsStringSync()) as Map<String, Object?>;
  });

  group('Contract fixtures byte-match backend', () {
    test(
        'golden_vectors.json and sample_frames.json match backend byte-for-byte',
        () {
      final backendDir = Directory('../../../backend/tests/fixtures/xtp');
      if (!backendDir.existsSync()) {
        // Allows standalone package checkout while enforcing byte identity in superproject.
        return;
      }
      for (final name in <String>[
        'golden_vectors.json',
        'sample_frames.json',
      ]) {
        final localBytes = File('test/fixtures/xtp/$name').readAsBytesSync();
        final backendBytes =
            File('../../../backend/tests/fixtures/xtp/$name').readAsBytesSync();
        expect(
          sha256.convert(localBytes).toString(),
          equals(sha256.convert(backendBytes).toString()),
          reason: '$name must byte-match backend/tests/fixtures/xtp/$name',
        );
      }
    });
  });

  group('SAS, key fingerprint and enrollment URI', () {
    test('matches golden SAS vector and enrollment URI', () {
      final sasVector = golden['sas'] as Map<String, Object?>;
      final codeBytes = _hexToBytes(sasVector['codeHex'] as String);
      final pubKeyBytes = _hexToBytes(sasVector['publicKeyHex'] as String);
      final hostname = sasVector['hostname'] as String;

      expect(
        base64UrlNoPadEncode(codeBytes),
        equals(sasVector['codeB64Url']),
      );
      final fp = publicKeyFingerprint(pubKeyBytes);
      expect(_bytesToHex(fp), equals(sasVector['keyFingerprintHex']));
      expect(
        base64UrlNoPadEncode(fp),
        equals(sasVector['keyFingerprintB64Url']),
      );

      final sas = computeSas(
        enrollmentCode: codeBytes,
        publicKey: pubKeyBytes,
      );
      expect(sas, equals(sasVector['sas']));

      final uri = buildEnrollmentUri(
        enrollmentCode: codeBytes,
        publicKey: pubKeyBytes,
        hostname: hostname,
      );
      expect(uri, equals(sasVector['enrollmentUri']));
    });
  });

  group('Host proof message and P-256 signatures', () {
    test(
        'enroll and session proof messages match golden vectors and verify P-256',
        () {
      final hp = golden['hostProof'] as Map<String, Object?>;
      final privScalarHex = hp['privateScalarHex'] as String;
      final pubKeyBytes = _hexToBytes(hp['publicKeyHex'] as String);
      final nonceBytes = _hexToBytes(hp['nonceHex'] as String);

      // Purpose 1: Enroll
      final enrollVec = hp['enrollProof'] as Map<String, Object?>;
      final enrollPayload = _hexToBytes(enrollVec['payloadHex'] as String);
      final enrollMsg = hostProofMessage(
        nonce: nonceBytes,
        purpose: HostProofPurpose.enroll,
        payload: enrollPayload,
      );
      expect(_bytesToHex(enrollMsg), equals(enrollVec['messageHex']));
      expect(
        sha256.convert(enrollMsg).toString(),
        equals(enrollVec['messageSha256Hex']),
      );

      final enrollGoldenSig = _hexToBytes(enrollVec['signatureHex'] as String);
      final enrollGoldenDer =
          _hexToBytes(enrollVec['signatureDerHex'] as String);
      expect(
        _bytesToHex(derToRawP256Signature(enrollGoldenDer)),
        equals(enrollVec['signatureHex']),
      );
      expect(
        _bytesToHex(rawToDerP256Signature(enrollGoldenSig)),
        equals(enrollVec['signatureDerHex']),
      );
      expect(
        _verifyP256RawSignature(
          publicKeyBytes: pubKeyBytes,
          messageBytes: enrollMsg,
          signatureRaw64: enrollGoldenSig,
        ),
        isTrue,
      );

      // Sign in Dart with test software key and verify round-trip
      final dartSig = _signP256RawDeterministic(
        privateScalarHex: privScalarHex,
        messageBytes: enrollMsg,
      );
      expect(
        _verifyP256RawSignature(
          publicKeyBytes: pubKeyBytes,
          messageBytes: enrollMsg,
          signatureRaw64: dartSig,
        ),
        isTrue,
      );

      // Purpose 2: Session
      final sessionVec = hp['sessionProof'] as Map<String, Object?>;
      final sessionMsg = hostProofMessage(
        nonce: nonceBytes,
        purpose: HostProofPurpose.session,
        hostIdUuid: sessionVec['hostIdUuid'] as String,
        payload: pubKeyBytes,
      );
      expect(_bytesToHex(sessionMsg), equals(sessionVec['messageHex']));
      expect(
        sha256.convert(sessionMsg).toString(),
        equals(sessionVec['messageSha256Hex']),
      );

      final sessionGoldenSig =
          _hexToBytes(sessionVec['signatureHex'] as String);
      final sessionGoldenDer =
          _hexToBytes(sessionVec['signatureDerHex'] as String);
      // Session golden DER has a 33-byte r (0x00 prefix because r >= 0x80)
      expect(
        _bytesToHex(derToRawP256Signature(sessionGoldenDer)),
        equals(sessionVec['signatureHex']),
      );
      expect(
        _bytesToHex(rawToDerP256Signature(sessionGoldenSig)),
        equals(sessionVec['signatureDerHex']),
      );
      expect(
        _verifyP256RawSignature(
          publicKeyBytes: pubKeyBytes,
          messageBytes: sessionMsg,
          signatureRaw64: sessionGoldenSig,
        ),
        isTrue,
      );
    });
  });

  group('Canonical JSON and argsSha256', () {
    test('matches all golden canonicalJson vectors', () {
      final vectors = golden['canonicalJson'] as List<Object?>;
      for (final item in vectors) {
        final vec = item as Map<String, Object?>;
        final input =
            Map<String, Object?>.from(vec['input'] as Map<Object?, Object?>);
        expect(canonicalJson(input), equals(vec['canonical']));
        expect(argsSha256(input), equals(vec['argsSha256']));
      }
    });

    test('rejects floating-point numbers', () {
      expect(
        () => canonicalJson(<String, Object?>{'ratio': 0.5}),
        throwsFormatException,
      );
    });
  });

  group('XTP v1 frames', () {
    test('parses and re-encodes every sample frame in sample_frames.json', () {
      final frames = sampleFrames['frames'] as Map<String, Object?>;
      expect(frames.length, greaterThanOrEqualTo(20));
      for (final entry in frames.entries) {
        final rawText = jsonEncode(entry.value);
        final parsed = XtpFrame.parse(rawText);
        final reencoded = jsonDecode(parsed.encode());
        expect(
          reencoded,
          equals(entry.value),
          reason: 'Round-trip mismatch on sample frame ${entry.key}',
        );
      }
    });

    test('builds all 12 normative MVP tools without error', () {
      final catalog = buildMvpToolCatalog();
      expect(catalog, hasLength(12));
      for (final tool in catalog) {
        final roundTrip = ToolDescriptor.fromJson(tool.toJson());
        expect(roundTrip.name, equals(tool.name));
        expect(roundTrip.policy.risk, equals(tool.policy.risk));
      }
    });

    test('rejects forbidden tool names and prefixes', () {
      for (final badName in <String>[
        'shell.exec',
        'powershell.run',
        'osascript.run',
        'script.run',
        'eval.code',
        'keyboard.type',
        'pointer.click',
        'unknown.tool',
      ]) {
        expect(
          () => ToolDescriptor.validateToolName(badName),
          throwsFormatException,
          reason: 'Should reject $badName',
        );
      }
    });

    test(
        'enforces frame size limit (64 KiB) and structuredContent limit (16 KiB)',
        () {
      final huge = 'a' * (maxXtpFrameBytes + 10);
      expect(
        () => XtpFrame.parse(huge),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.closeCode,
            'closeCode',
            XtpCloseCode.frameTooLarge,
          ),
        ),
      );

      expect(
        () => XtpResponse.toolCallResult(
          id: 1,
          text: 'too big',
          structuredContent: <String, Object?>{
            'blob': 'x' * (maxStructuredContentBytes + 100),
          },
          status: XtpStatus.ok,
          durationMs: 5,
        ),
        throwsA(isA<XtpProtocolException>()),
      );
    });

    test(
        'maps JSON-RPC protocol errors accurately (-32700, -32600, -32601, -32602)',
        () {
      expect(
        () => XtpFrame.parse('{not-json'),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'code',
            JsonRpcErrorCode.parseError,
          ),
        ),
      );

      expect(
        () => XtpFrame.parse(
            '{"jsonrpc":"1.0","id":1,"method":"ping","params":{}}'),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'code',
            JsonRpcErrorCode.invalidRequest,
          ),
        ),
      );

      expect(
        () => XtpFrame.parse(
            '{"jsonrpc":"2.0","id":1,"method":"unknown/method","params":{}}'),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'code',
            JsonRpcErrorCode.methodNotFound,
          ),
        ),
      );

      expect(
        () => XtpFrame.parse(
            '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"extra":1}}'),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'code',
            JsonRpcErrorCode.invalidParams,
          ),
        ),
      );
    });
  });

  group('URL validation and IDN punycode', () {
    const allowlist = <String>[
      'github.com',
      'jira.example.com',
      'xn--vit-5kz.vn'
    ];

    test('accepts exact domain and subdomain over https', () {
      final exact = validateHttpsUrlAgainstAllowlist(
        'https://github.com/xthao28/xuna_pet',
        allowlist,
      );
      expect(exact.validUrl, isTrue);
      expect(exact.domainAllowed, isTrue);
      expect(exact.asciiHost, equals('github.com'));

      final sub = validateHttpsUrlAgainstAllowlist(
        'https://docs.github.com:443/en',
        allowlist,
      );
      expect(sub.validUrl, isTrue);
      expect(sub.domainAllowed, isTrue);
      expect(sub.asciiHost, equals('docs.github.com'));
    });

    test('converts IDN hostname to ASCII punycode before matching', () {
      expect(idnToAscii('việt.vn'), equals('xn--vit-5kz.vn'));
      final idn = validateHttpsUrlAgainstAllowlist(
        'https://sub.việt.vn/path',
        allowlist,
      );
      expect(idn.validUrl, isTrue);
      expect(idn.domainAllowed, isTrue);
      expect(idn.asciiHost, equals('sub.xn--vit-5kz.vn'));
    });

    test(
        'rejects http, userinfo, IP literals, localhost, and unallowed domains',
        () {
      for (final badUrl in <String>[
        'http://github.com/repo',
        'file:///C:/Windows/System32/cmd.exe',
        'javascript:alert(1)',
        'https://user:pass@github.com/',
        'https://127.0.0.1/admin',
        'https://192.168.1.1/',
        'https://[::1]/',
        'https://localhost/test',
        'https://my.local/test',
      ]) {
        final res = validateHttpsUrlAgainstAllowlist(badUrl, allowlist);
        expect(res.validUrl, isFalse,
            reason: 'Should reject invalid URL $badUrl');
        expect(res.errorCode, equals('url_invalid'));
      }

      final spoofed = validateHttpsUrlAgainstAllowlist(
        'https://evilgithub.com/',
        allowlist,
      );
      expect(spoofed.validUrl, isTrue);
      expect(spoofed.domainAllowed, isFalse);
      expect(spoofed.errorCode, equals('domain_not_allowed'));
    });
  });

  group('Fail-closed HostPolicyEvaluator', () {
    const validPolicyJson = '''
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow"
  },
  "apps": [
    {
      "id": "vscode",
      "name": "VS Code",
      "kind": "exe",
      "target": "C:\\\\Program Files\\\\Microsoft VS Code\\\\Code.exe",
      "risk": "R2"
    }
  ],
  "urlDomains": ["github.com"],
  "workflows": [
    {
      "id": "focus",
      "name": "Chế độ tập trung",
      "kind": "shortcut",
      "target": "Focus Mode",
      "risk": "R1"
    }
  ],
  "players": ["spotify"]
}
''';

    test('corrupted or missing policy denies everything except host.status',
        () {
      final corrupted = HostPolicyEvaluator.fromJsonString('{broken json');
      expect(corrupted.isHealthy, isFalse);
      expect(corrupted.trayBanner, equals('Cấu hình lỗi'));

      final statusDecision = corrupted.evaluateInvocation(
        toolName: 'host.status',
        arguments: const <String, Object?>{},
      );
      expect(statusDecision.allowed, isTrue);
      expect(statusDecision.status, equals(XtpStatus.ok));

      final mediaDecision = corrupted.evaluateInvocation(
        toolName: 'media.play_pause',
        arguments: const <String, Object?>{},
      );
      expect(mediaDecision.allowed, isFalse);
      expect(mediaDecision.status, equals(XtpStatus.denied));
      expect(mediaDecision.errorCode, equals('policy_invalid'));
    });

    test('rejects lowering app risk below R2 in host-policy.json', () {
      final lowered =
          validPolicyJson.replaceFirst('"risk": "R2"', '"risk": "R1"');
      final evaluator = HostPolicyEvaluator.fromJsonString(lowered);
      expect(evaluator.isHealthy, isFalse);
    });

    test('enforces R2 approval presence, expiration, and argsSha256 binding',
        () {
      final evaluator = HostPolicyEvaluator.fromJsonString(validPolicyJson);
      expect(evaluator.isHealthy, isTrue);
      final now = DateTime.utc(2026, 10, 30, 7, 0, 0);

      // 1. Missing approval -> denied (approval_required)
      final noApproval = evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'vscode'},
        nowUtc: now,
      );
      expect(noApproval.allowed, isFalse);
      expect(noApproval.status, equals(XtpStatus.denied));
      expect(noApproval.errorCode, equals('approval_required'));

      // 2. Expired approval -> denied (approval_expired)
      final expiredApproval = ApprovalToken(
        approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
        argsSha256: argsSha256(const <String, Object?>{'id': 'vscode'}),
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );
      final expiredRes = evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'vscode'},
        approval: expiredApproval,
        nowUtc: now,
      );
      expect(expiredRes.allowed, isFalse);
      expect(expiredRes.errorCode, equals('approval_expired'));

      // 3. Mismatched argsSha256 -> denied (approval_mismatch)
      final mismatchedApproval = ApprovalToken(
        approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
        argsSha256: argsSha256(const <String, Object?>{'id': 'other'}),
        expiresAt: now.add(const Duration(seconds: 30)),
      );
      final mismatchRes = evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'vscode'},
        approval: mismatchedApproval,
        nowUtc: now,
      );
      expect(mismatchRes.allowed, isFalse);
      expect(mismatchRes.errorCode, equals('approval_mismatch'));

      // 4. Valid approval -> allowed
      final validApproval = ApprovalToken(
        approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d',
        argsSha256: argsSha256(const <String, Object?>{'id': 'vscode'}),
        expiresAt: now.add(const Duration(seconds: 30)),
      );
      final okRes = evaluator.evaluateInvocation(
        toolName: 'app.launch',
        arguments: const <String, Object?>{'id': 'vscode'},
        approval: validApproval,
        nowUtc: now,
      );
      expect(okRes.allowed, isTrue);
      expect(okRes.status, equals(XtpStatus.ok));
      expect(okRes.app?.name, equals('VS Code'));
    });

    test('e-stop suspends tool execution with errorCode stopped', () {
      final evaluator = HostPolicyEvaluator.fromJsonString(validPolicyJson);
      final stoppedRes = evaluator.evaluateInvocation(
        toolName: 'media.play_pause',
        arguments: const <String, Object?>{},
        isStopped: true,
      );
      expect(stoppedRes.allowed, isFalse);
      expect(stoppedRes.status, equals(XtpStatus.denied));
      expect(stoppedRes.errorCode, equals('stopped'));
    });

    test(
        'enforces phone-signed R3 approval and once scope (UDC-7 S7.1 & S7.5)',
        () {
      const r3PolicyJson = '''
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow"
  },
  "apps": [],
  "urlDomains": [],
  "workflows": [
    {
      "id": "deploy_prod",
      "name": "Deploy Production",
      "kind": "shortcut",
      "target": "DeployProd",
      "risk": "R3"
    }
  ],
  "players": ["spotify"]
}
''';
      final evaluator = HostPolicyEvaluator.fromJsonString(r3PolicyJson);
      expect(evaluator.isHealthy, isTrue);

      final hp = golden['hostProof'] as Map<String, Object?>;
      final privScalarHex = hp['privateScalarHex'] as String;
      final pubKeyBytes = _hexToBytes(hp['publicKeyHex'] as String);

      const approvalId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
      const hostId = '11111111-2222-4333-8444-555555555555';
      const expiresAtWire = '2026-10-30T07:02:00Z';
      final expiresAt = DateTime.parse(expiresAtWire).toUtc();
      final now = DateTime.utc(2026, 10, 30, 7, 0, 0);
      final args = const <String, Object?>{'id': 'deploy_prod'};
      final sha = argsSha256(args);

      final msg = approvalProofMessage(
        approvalId: approvalId,
        argsSha256: sha,
        hostId: hostId,
        expiresAt: expiresAtWire,
      );
      final validSig = _signP256RawDeterministic(
        privateScalarHex: privScalarHex,
        messageBytes: msg,
      );
      expect(
        verifyP256Signature(
          publicKey: pubKeyBytes,
          message: msg,
          signature: validSig,
        ),
        isTrue,
      );

      // 1. R3 with conversation_15m scope -> denied (r3_requires_once_scope)
      final badScopeApproval = ApprovalToken(
        approvalId: approvalId,
        argsSha256: sha,
        expiresAt: expiresAt,
        expiresAtRaw: expiresAtWire,
        scope: 'conversation_15m',
        signature: validSig,
        publicKey: pubKeyBytes,
      );
      final badScopeRes = evaluator.evaluateInvocation(
        toolName: 'workflow.run',
        arguments: args,
        approval: badScopeApproval,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pubKeyBytes],
        nowUtc: now,
      );
      expect(badScopeRes.allowed, isFalse);
      expect(badScopeRes.errorCode, equals('r3_requires_once_scope'));

      // 2. R3 without signature -> denied (approval_signature_invalid)
      final unsignedApproval = ApprovalToken(
        approvalId: approvalId,
        argsSha256: sha,
        expiresAt: expiresAt,
        expiresAtRaw: expiresAtWire,
      );
      final unsignedRes = evaluator.evaluateInvocation(
        toolName: 'workflow.run',
        arguments: args,
        approval: unsignedApproval,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pubKeyBytes],
        nowUtc: now,
      );
      expect(unsignedRes.allowed, isFalse);
      expect(unsignedRes.errorCode, equals('approval_signature_invalid'));

      // 3. R3 with unpinned phone key -> denied (approval_signature_invalid)
      final signedApproval = ApprovalToken(
        approvalId: approvalId,
        argsSha256: sha,
        expiresAt: expiresAt,
        expiresAtRaw: expiresAtWire,
        scope: 'once',
        signature: validSig,
        publicKey: pubKeyBytes,
      );
      final unpinnedRes = evaluator.evaluateInvocation(
        toolName: 'workflow.run',
        arguments: args,
        approval: signedApproval,
        hostId: hostId,
        pinnedPhonePublicKeys: const <Uint8List>[],
        nowUtc: now,
      );
      expect(unpinnedRes.allowed, isFalse);
      expect(unpinnedRes.errorCode, equals('approval_signature_invalid'));

      // 4. R3 with tampered signature -> denied (approval_signature_invalid)
      final tamperedSig = Uint8List.fromList(validSig)..[0] ^= 0xff;
      final tamperedApproval = ApprovalToken(
        approvalId: approvalId,
        argsSha256: sha,
        expiresAt: expiresAt,
        expiresAtRaw: expiresAtWire,
        scope: 'once',
        signature: tamperedSig,
        publicKey: pubKeyBytes,
      );
      final tamperedRes = evaluator.evaluateInvocation(
        toolName: 'workflow.run',
        arguments: args,
        approval: tamperedApproval,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pubKeyBytes],
        nowUtc: now,
      );
      expect(tamperedRes.allowed, isFalse);
      expect(tamperedRes.errorCode, equals('approval_signature_invalid'));

      // 5. R3 with valid phone signature and pinned key -> allowed
      final validRes = evaluator.evaluateInvocation(
        toolName: 'workflow.run',
        arguments: args,
        approval: signedApproval,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pubKeyBytes],
        nowUtc: now,
      );
      expect(validRes.allowed, isTrue);
      expect(validRes.status, equals(XtpStatus.ok));
      expect(validRes.workflow?.id, equals('deploy_prod'));
    });

    test('parses xuna/lanPeer notification frames (UDC-7 S7.4)', () {
      final hp = golden['hostProof'] as Map<String, Object?>;
      final pubKeyBytes = _hexToBytes(hp['publicKeyHex'] as String);
      final pubKeyB64 = base64Encode(pubKeyBytes);

      final serverToAgent = XtpFrame.parse(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/lanPeer',
          'params': <String, Object?>{
            'phonePublicKeys': <String>[pubKeyB64],
          },
        }),
      );
      expect(serverToAgent, isA<XtpNotification>());
      final params1 =
          (serverToAgent as XtpNotification).typedParams as LanPeerParams;
      expect(params1.phonePublicKeys, hasLength(1));
      expect(params1.phonePublicKeys.single, equals(pubKeyBytes));

      final agentToServer = XtpFrame.parse(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/lanPeer',
          'params': <String, Object?>{
            'enabled': true,
            'port': 47821,
            'certFingerprint': 'abcd1234',
          },
        }),
      );
      expect(agentToServer, isA<XtpNotification>());
      final params2 =
          (agentToServer as XtpNotification).typedParams as LanPeerParams;
      expect(params2.enabled, isTrue);
      expect(params2.port, equals(47821));
      expect(params2.certFingerprint, equals('abcd1234'));
    });

    test(
        'evaluates UDC-8 computer-use tools, lexicon escalation, hard denylist and password redaction',
        () {
      const cuPolicyJson = '''
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow",
    "cu": "allow",
    "screen": "allow",
    "ui": "allow",
    "input": "allow"
  },
  "apps": [
    {
      "id": "vscode",
      "name": "VS Code",
      "kind": "exe",
      "target": "C:\\\\Program Files\\\\Microsoft VS Code\\\\Code.exe",
      "risk": "R2"
    },
    {
      "id": "explorer",
      "name": "File Explorer",
      "kind": "exe",
      "target": "C:\\\\Windows\\\\explorer.exe",
      "risk": "R2"
    }
  ],
  "urlDomains": ["github.com", "calendar.google.com"],
  "workflows": [],
  "players": ["spotify"]
}
''';
      final evaluator = HostPolicyEvaluator.fromJsonString(cuPolicyJson);
      expect(evaluator.isHealthy, isTrue);

      final cuTools = buildComputerUseTools();
      expect(cuTools, hasLength(8));
      expect(
        cuTools.map((t) => t.name).toList(),
        equals(<String>[
          'cu.session_start',
          'screen.capture',
          'ui.inspect',
          'input.click',
          'input.type_text',
          'input.key',
          'input.scroll',
          'cu.session_end',
        ]),
      );

      // Consequential lexicon (Vietnamese + English)
      expect(isConsequentialElementName('Gửi email'), isTrue);
      expect(isConsequentialElementName('Xóa tệp'), isTrue);
      expect(isConsequentialElementName('Thanh toán ngay'), isTrue);
      expect(isConsequentialElementName('Submit Form'), isTrue);
      expect(isConsequentialElementName('Buy Now'), isTrue);
      expect(isConsequentialElementName('Mở thư mục Reports'), isFalse);

      // Hard-denied apps and processes
      expect(isHardDeniedAppOrProcess('powershell.exe'), isTrue);
      expect(isHardDeniedAppOrProcess('cmd'), isTrue);
      expect(isHardDeniedAppOrProcess('com.apple.terminal'), isTrue);
      expect(isHardDeniedAppOrProcess('1password'), isTrue);
      expect(isHardDeniedAppOrProcess('systemsettings.exe'), isTrue);
      expect(isHardDeniedAppOrProcess('vscode'), isFalse);

      // Password field redaction
      final redacted = redactUiTreeNodes(<Map<String, Object?>>[
        <String, Object?>{
          'id': 's00000001:1',
          'role': 'textfield',
          'name': 'Họ và tên',
          'value': 'Thảo',
          'enabled': true,
        },
        <String, Object?>{
          'id': 's00000001:2',
          'role': 'password',
          'name': 'Nhập mật khẩu ngân hàng',
          'value': 'secret123!',
          'enabled': true,
        },
      ]);
      expect(redacted, hasLength(2));
      expect(redacted[0]['name'], equals('Họ và tên'));
      expect(redacted[0].containsKey('value'), isFalse);
      expect(redacted[1]['role'], equals('password'));
      expect(redacted[1]['name'], equals('•••'));
      expect(redacted[1].containsKey('value'), isFalse);
      expect(redacted[1]['isPassword'], isTrue);

      // Calling observation/input tools outside an active CU session -> denied
      final outsideSession = evaluator.evaluateInvocation(
        toolName: 'ui.inspect',
        arguments: const <String, Object?>{
          'scope': 'active_window',
          'maxNodes': 100,
        },
        isInApprovedCuSession: false,
      );
      expect(outsideSession.allowed, isFalse);
      expect(outsideSession.errorCode, equals('cu_session_required'));

      // Inside an active CU session, R2 ui.inspect and non-consequential input.click
      // do not require per-call approval
      final inspectInside = evaluator.evaluateInvocation(
        toolName: 'ui.inspect',
        arguments: const <String, Object?>{
          'scope': 'active_window',
          'maxNodes': 100,
        },
        isInApprovedCuSession: true,
      );
      expect(inspectInside.allowed, isTrue);
      expect(inspectInside.effectiveRisk, equals(RiskTier.r2));

      final safeClick = evaluator.evaluateInvocation(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'elementId': 's00000001:1',
          'elementName': 'Thư mục Reports',
        },
        isInApprovedCuSession: true,
      );
      expect(safeClick.allowed, isTrue);
      expect(safeClick.effectiveRisk, equals(RiskTier.r2));

      // Consequential click escalates to R3 and requires phone-signed approval
      final dangerClickNoApproval = evaluator.evaluateInvocation(
        toolName: 'input.click',
        arguments: const <String, Object?>{
          'elementId': 's00000001:9',
          'elementName': 'Xóa báo cáo',
        },
        isInApprovedCuSession: true,
      );
      expect(dangerClickNoApproval.allowed, isFalse);
      expect(dangerClickNoApproval.effectiveRisk, equals(RiskTier.r3));
      expect(dangerClickNoApproval.errorCode, equals('approval_required'));

      // input.type_text is always R3
      final typeNoApproval = evaluator.evaluateInvocation(
        toolName: 'input.type_text',
        arguments: const <String, Object?>{
          'elementId': 's00000001:3',
          'text': 'Họp nhóm',
        },
        isInApprovedCuSession: true,
      );
      expect(typeNoApproval.allowed, isFalse);
      expect(typeNoApproval.effectiveRisk, equals(RiskTier.r3));
      expect(typeNoApproval.errorCode, equals('approval_required'));
    });
  });
}

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

void main() {
  late Map<String, Object?> golden;
  late Map<String, Object?> execFsFrames;

  setUpAll(() {
    golden = jsonDecode(
      File('test/fixtures/xtp/golden_vectors.json').readAsStringSync(),
    ) as Map<String, Object?>;
    execFsFrames = jsonDecode(
      File('test/fixtures/xtp/exec_fs_frames.json').readAsStringSync(),
    ) as Map<String, Object?>;
  });

  group('W4-M3 EffectManifest & draft.* descriptors', () {
    test('golden approvalV2 manifest matches canonicalJson and effectSha256',
        () {
      final v2 = golden['approvalV2']! as Map<String, Object?>;
      final manifest = EffectManifest.fromJson(
        Map<String, Object?>.from(v2['manifest']! as Map),
      );
      expect(manifest.scope, equals('workspace_files_only'));
      expect(manifest.networkIsolated, isFalse);
      expect(manifest.encodeCanonicalJson(), equals(v2['canonicalManifest']));
      expect(computeEffectSha256(manifest), equals(v2['effectSha256']));
    });

    test('EffectManifest rejects networkIsolated:true, secrets, and traversal',
        () {
      const validHash =
          '1111111111111111111111111111111111111111111111111111111111111111';
      expect(
        () => EffectManifest(
          draftId: 'draft_1',
          workspaceAlias: 'demo',
          networkIsolated: true,
          changes: const <EffectManifestChange>[],
          createdAt: '2026-11-26T10:00:00Z',
          expiresAt: '2026-11-26T10:30:00Z',
        ),
        throwsFormatException,
      );
      for (final badPath in const <String>[
        '/etc/passwd',
        r'C:\Windows\win.ini',
        '../escape.txt',
        '.env',
        'secrets/prod.pem',
        '.ssh/id_rsa',
      ]) {
        expect(
          () => EffectManifestChange(
            relPath: badPath,
            op: EffectChangeOp.create,
            postSha256: validHash,
            sizeBytes: 10,
          ),
          throwsFormatException,
          reason: 'Should reject $badPath',
        );
      }
      // create forbids preSha256; delete forbids postSha256.
      expect(
        () => EffectManifestChange(
          relPath: 'a.txt',
          op: EffectChangeOp.create,
          preSha256: validHash,
          postSha256: validHash,
          sizeBytes: 1,
        ),
        throwsFormatException,
      );
      expect(
        () => EffectManifestChange(
          relPath: 'a.txt',
          op: EffectChangeOp.delete,
          preSha256: validHash,
          postSha256: validHash,
        ),
        throwsFormatException,
      );
    });

    test('toolsListDraftResponse equals buildDraftTools and frames round-trip',
        () {
      final frames = execFsFrames['frames']! as Map<String, Object?>;
      final draftTools = ((frames['toolsListDraftResponse']! as Map)['result']
          as Map)['tools'] as List<Object?>;
      expect(
        draftTools,
        equals(
          jsonDecode(jsonEncode([for (final t in buildDraftTools()) t.toJson()])),
        ),
      );
      for (final key in const <String>[
        'toolsListDraftResponse',
        'preflightDraftApplyResponse',
        'toolsCallDraftApplyV2Request',
      ]) {
        final raw = frames[key]! as Map<String, Object?>;
        final parsed = XtpFrame.parse(jsonEncode(raw));
        expect(jsonDecode(parsed.encode()), equals(raw), reason: key);
      }
    });

    test('refused preflight carrying effectSha256 is rejected fail-closed', () {
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 901,
            'result': <String, Object?>{
              'preflight': <String, Object?>{
                'status': 'denied',
                'errorCode': 'draft_not_found',
                'effectSha256':
                    '1111111111111111111111111111111111111111111111111111111111111111',
              },
            },
          }),
        ),
        throwsA(isA<XtpProtocolException>()),
      );
    });
  });

  group('W4-M4 xuna.approval.v2 cryptographic separation & policy', () {
    test('golden approvalV2 proof message & P-256 signature verify identically',
        () {
      final v2 = golden['approvalV2']! as Map<String, Object?>;
      final pubKey = _hexToBytes(v2['publicKeyHex']! as String);
      final sig = _hexToBytes(v2['signatureHex']! as String);
      final msg = approvalV2ProofMessage(
        approvalId: v2['approvalId']! as String,
        effectSha256: v2['effectSha256']! as String,
        hostId: v2['hostId']! as String,
        expiresAt: v2['expiresAt']! as String,
      );
      expect(_bytesToHex(msg), equals(v2['messageHex']));
      expect(sha256Hex(msg), equals(v2['messageSha256Hex']));
      expect(
        verifyP256Signature(publicKey: pubKey, message: msg, signature: sig),
        isTrue,
      );

      final args = <String, Object?>{
        'draftId': 'draft_golden_001',
        'effectSha256': v2['effectSha256'],
      };
      expect(argsSha256(args), equals(v2['argsSha256']));

      final token = ApprovalToken(
        approvalId: v2['approvalId']! as String,
        argsSha256: v2['argsSha256']! as String,
        expiresAt: DateTime.parse(v2['expiresAt']! as String),
        expiresAtRaw: v2['expiresAt']! as String,
        version: 2,
        effectSha256: v2['effectSha256']! as String,
        signature: sig,
        publicKey: pubKey,
      );
      expect(
        verifyPhoneSignedEffectApproval(
          approval: token,
          arguments: args,
          expectedEffectSha256: v2['effectSha256']! as String,
          nowUtc: DateTime.parse('2026-11-26T10:00:30Z'),
          hostId: v2['hostId']! as String,
          pinnedPhonePublicKeys: <Uint8List>[pubKey],
        ),
        isNull,
      );

      // Cross-domain rejection: v2 token presented to v1 verifier fails closed.
      expect(
        verifyPhoneSignedApproval(
          approval: token,
          arguments: args,
          nowUtc: DateTime.parse('2026-11-26T10:00:30Z'),
          hostId: v2['hostId']! as String,
          pinnedPhonePublicKeys: <Uint8List>[pubKey],
        ),
        equals('approval_version_mismatch'),
      );
    });

    test('HostPolicyEvaluator enforces v2 on draft.apply and blocks R3 in draft',
        () {
      final priv = _hexToBytes(
        (golden['hostProof']! as Map)['privateScalarHex']! as String,
      );
      final pub = deriveP256PublicKey(priv);
      final policy = HostPolicy(
        families: <ToolFamily, FamilyPolicyDecision>{
          for (final f in ToolFamily.values) f: FamilyPolicyDecision.allow,
        },
        apps: const <AllowedAppConfig>[],
        urlDomains: const <String>[],
        workflows: const <WorkflowConfig>[],
        players: const <String>[],
        shellControl: ShellControlPolicy(
          enabled: true,
          workspaceRoots: const <String>['/workspace'],
        ),
      );
      final evaluator = HostPolicyEvaluator.healthy(policy);
      final now = DateTime.utc(2026, 11, 26, 10, 0, 30);
      const effectHash =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      const applyArgs = <String, Object?>{
        'draftId': 'draft_test_1',
        'effectSha256': effectHash,
      };
      const approvalId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
      const hostId = '9b2f7e4a-5c11-4d8e-9a30-1f6d8c2e4b10';
      const expiresIso = '2026-11-26T10:01:00Z';

      // v1 signature on draft.apply must be refused fail-closed.
      final v1Msg = approvalProofMessage(
        approvalId: approvalId,
        argsSha256: argsSha256(applyArgs),
        hostId: hostId,
        expiresAt: expiresIso,
      );
      final v1Token = ApprovalToken(
        approvalId: approvalId,
        argsSha256: argsSha256(applyArgs),
        expiresAt: DateTime.parse(expiresIso),
        expiresAtRaw: expiresIso,
        signature: signP256Deterministic(privateScalar32: priv, message: v1Msg),
        publicKey: pub,
      );
      final v1Eval = evaluator.evaluateInvocation(
        toolName: 'draft.apply',
        arguments: applyArgs,
        approval: v1Token,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pub],
        nowUtc: now,
      );
      expect(v1Eval.allowed, isFalse);
      expect(v1Eval.errorCode, equals('approval_version_mismatch'));

      // Valid v2 signature passes HostPolicyEvaluator.
      final v2Msg = approvalV2ProofMessage(
        approvalId: approvalId,
        effectSha256: effectHash,
        hostId: hostId,
        expiresAt: expiresIso,
      );
      final v2Token = ApprovalToken(
        approvalId: approvalId,
        argsSha256: argsSha256(applyArgs),
        expiresAt: DateTime.parse(expiresIso),
        expiresAtRaw: expiresIso,
        version: 2,
        effectSha256: effectHash,
        signature: signP256Deterministic(privateScalar32: priv, message: v2Msg),
        publicKey: pub,
      );
      final v2Eval = evaluator.evaluateInvocation(
        toolName: 'draft.apply',
        arguments: applyArgs,
        approval: v2Token,
        hostId: hostId,
        pinnedPhonePublicKeys: <Uint8List>[pub],
        nowUtc: now,
      );
      expect(v2Eval.allowed, isTrue);
      expect(v2Eval.effectiveRisk, equals(RiskTier.r3));

      // R3 network command in draft mode is refused fail-closed.
      final r3DraftExec = evaluator.evaluateInvocation(
        toolName: 'exec.run',
        arguments: const <String, Object?>{
          'command': 'curl https://example.com',
          'cwd': '/workspace',
          'draftId': 'draft_test_1',
        },
        nowUtc: now,
      );
      expect(r3DraftExec.allowed, isFalse);
      expect(r3DraftExec.errorCode, equals('draft_r3_forbidden'));

      // R3 write outside workspaceRoots in draft mode is refused fail-closed.
      final r3DraftWrite = evaluator.evaluateInvocation(
        toolName: 'fs.write_file',
        arguments: const <String, Object?>{
          'path': '/tmp/outside.txt',
          'content': 'nope',
          'draftId': 'draft_test_1',
        },
        nowUtc: now,
      );
      expect(r3DraftWrite.allowed, isFalse);
      expect(r3DraftWrite.errorCode, equals('draft_r3_forbidden'));
    });
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  late Map<String, Object?> meshFixtures;
  late Map<String, Object?> meshFrames;

  setUpAll(() {
    final file = File('test/fixtures/xtp/mesh_frames.json');
    expect(file.existsSync(), isTrue, reason: 'mesh_frames.json must exist');
    meshFixtures =
        jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    meshFrames = meshFixtures['frames']! as Map<String, Object?>;
  });

  group('Tier 1 — XTP Golden Fixtures & Linux Hello Parity (F9)', () {
    test(
      'T1-F9-01: xuna_xtp fixtures match backend/tests/fixtures/xtp byte-for-byte',
      () {
        final backendDir = Directory('../../../backend/tests/fixtures/xtp');
        expect(
          backendDir.existsSync(),
          isTrue,
          reason: 'Superproject backend/tests/fixtures/xtp directory must exist',
        );
        for (final name in const <String>[
          'golden_vectors.json',
          'sample_frames.json',
          'mesh_frames.json',
        ]) {
          final clientBytes = File('test/fixtures/xtp/$name').readAsBytesSync();
          final backendBytes =
              File('../../../backend/tests/fixtures/xtp/$name')
                  .readAsBytesSync();
          expect(
            sha256.convert(clientBytes).toString(),
            equals(sha256.convert(backendBytes).toString()),
            reason: '$name SHA-256 must match backend fixture byte-for-byte',
          );
          expect(clientBytes, equals(backendBytes));
        }
      },
    );

    test(
      'T1-F9-02: xuna/hello accepts platform "linux" for enroll and reconnect',
      () {
        final enrollRaw = jsonEncode(meshFrames['helloEnrollLinuxRequest']);
        final enrollParsed = XtpFrame.parse(enrollRaw);
        expect(enrollParsed, isA<XtpRequest>());
        final enrollReq = enrollParsed as XtpRequest;
        expect(enrollReq.method, equals('xuna/hello'));
        expect(enrollReq.typedParams, isA<HelloEnrollParams>());
        final enrollParams = enrollReq.typedParams as HelloEnrollParams;
        expect(enrollParams.platform, equals(HostPlatform.linux));
        expect(enrollParams.hostname, equals('nuc-homelab'));
        expect(jsonDecode(enrollReq.encode()), equals(meshFrames['helloEnrollLinuxRequest']));

        final reconnectRaw =
            jsonEncode(meshFrames['helloReconnectLinuxRequest']);
        final reconnectParsed = XtpFrame.parse(reconnectRaw);
        expect(reconnectParsed, isA<XtpRequest>());
        final reconnectReq = reconnectParsed as XtpRequest;
        expect(reconnectReq.method, equals('xuna/hello'));
        expect(reconnectReq.typedParams, isA<HelloReconnectParams>());
        final reconnectParams =
            reconnectReq.typedParams as HelloReconnectParams;
        expect(reconnectParams.platform, equals(HostPlatform.linux));
        expect(
          jsonDecode(reconnectReq.encode()),
          equals(meshFrames['helloReconnectLinuxRequest']),
        );
      },
    );

    test(
      'T1-F9-03/04: knownXtpNotificationMethods includes mesh notifications and golden frames round-trip',
      () {
        // Rule H7: compiles cleanly today and fails honestly until M3 adds
        // xuna/presence, xuna/resources, and xuna/focusRequest to frames.dart.
        expect(
          knownXtpNotificationMethods,
          containsAll(const <String>[
            'xuna/presence',
            'xuna/resources',
            'xuna/focusRequest',
          ]),
        );

        for (final key in const <String>[
          'presenceNotification',
          'presenceDesktopNoBatteryNotification',
          'resourcesNotification',
          'resourcesWithToolchainsNotification',
          'focusRequestHotkeyNotification',
          'focusRequestTrayNotification',
        ]) {
          final rawMap = meshFrames[key]! as Map<String, Object?>;
          final parsed = XtpFrame.parse(jsonEncode(rawMap));
          expect(parsed, isA<XtpNotification>(), reason: 'key=$key');
          expect(jsonDecode(parsed.encode()), equals(rawMap), reason: 'key=$key');
        }
      },
    );
  });

  group('Tier 1/2 — XTP Frame & StructuredContent Ceilings (F9)', () {
    test('T1-F9-05 & T2-F9-01: enforces exact 512 KiB (524288 B) frame ceiling', () {
      expect(maxXtpFrameBytes, equals(524288));
      expect(maxStructuredContentBytes, equals(16384));
      expect(maxMediaStructuredContentBytes, equals(458752));

      const prefix = '{"jsonrpc":"2.0","id":"';
      const suffix = '","method":"ping","params":{}}';
      final exactIdLen =
          maxXtpFrameBytes - utf8.encode(prefix).length - utf8.encode(suffix).length;
      final exactFrame = '$prefix${'a' * exactIdLen}$suffix';
      expect(utf8.encode(exactFrame).length, equals(maxXtpFrameBytes));

      final parsedExact = XtpFrame.parse(exactFrame);
      expect(parsedExact, isA<XtpRequest>());
      expect(utf8.encode(parsedExact.encode()).length, equals(maxXtpFrameBytes));

      final overByOne = '$prefix${'a' * (exactIdLen + 1)}$suffix';
      expect(utf8.encode(overByOne).length, equals(maxXtpFrameBytes + 1));
      expect(
        () => XtpFrame.parse(overByOne),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.closeCode, 'closeCode', XtpCloseCode.frameTooLarge)
              .having((e) => e.closeReason, 'closeReason', 'frame_too_large'),
        ),
      );
    });

    test('T2-F9-02: enforces 16 KiB ordinary vs 448 KiB media structuredContent limits', () {
      // Ordinary structuredContent exactly at 16384 bytes succeeds.
      const ordinaryOverhead = '{"blob":""}';
      final exactOrdinaryLen =
          maxStructuredContentBytes - utf8.encode(ordinaryOverhead).length;
      final exactOrdinaryResp = XtpResponse.toolCallResult(
        id: 10,
        text: 'ok',
        structuredContent: <String, Object?>{'blob': 'x' * exactOrdinaryLen},
        status: XtpStatus.ok,
        durationMs: 1,
      );
      expect(utf8.encode(exactOrdinaryResp.encode()).length, lessThanOrEqualTo(maxXtpFrameBytes));

      // 16385 bytes ordinary structuredContent fails closed.
      expect(
        () => XtpResponse.toolCallResult(
          id: 11,
          text: 'too big',
          structuredContent: <String, Object?>{
            'blob': 'x' * (exactOrdinaryLen + 1),
          },
          status: XtpStatus.ok,
          durationMs: 1,
        ),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'jsonRpcCode',
            JsonRpcErrorCode.invalidParams,
          ),
        ),
      );

      // Media structuredContent exactly at 458752 bytes succeeds.
      const mediaOverhead = '{"dataBase64":""}';
      final exactMediaLen =
          maxMediaStructuredContentBytes - utf8.encode(mediaOverhead).length;
      final exactMediaResp = XtpResponse.toolCallResult(
        id: 12,
        text: 'media ok',
        structuredContent: <String, Object?>{'dataBase64': 'A' * exactMediaLen},
        status: XtpStatus.ok,
        durationMs: 5,
        allowMediaPayload: true,
      );
      expect(utf8.encode(exactMediaResp.encode()).length, lessThanOrEqualTo(maxXtpFrameBytes));

      // 458753 bytes media structuredContent fails closed.
      expect(
        () => XtpResponse.toolCallResult(
          id: 13,
          text: 'media too big',
          structuredContent: <String, Object?>{
            'dataBase64': 'A' * (exactMediaLen + 1),
          },
          status: XtpStatus.ok,
          durationMs: 5,
          allowMediaPayload: true,
        ),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'jsonRpcCode',
            JsonRpcErrorCode.invalidParams,
          ),
        ),
      );
    });
  });

  group('Tier 2 — Strict Mesh Notification Schema Boundaries (F9, H1/H2/H3)', () {
    Matcher throwsInvalidParams() => throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'jsonRpcCode',
            JsonRpcErrorCode.invalidParams,
          ),
        );

    test('T2-F9-04: xuna/presence rejects extra keys, bad ranges, and raw IPs', () {
      final base = Map<String, Object?>.from(
        (meshFrames['presenceNotification']! as Map<String, Object?>)['params']!
            as Map<String, Object?>,
      );

      final badCases = <String, Map<String, Object?>>{
        'extra_property': <String, Object?>{...base, 'extraKey': 1},
        'negative_idle': <String, Object?>{...base, 'idleSeconds': -1},
        'battery_below_0': <String, Object?>{...base, 'batteryPercent': -1},
        'battery_above_100': <String, Object?>{...base, 'batteryPercent': 101},
        'raw_ipv4_subnet': <String, Object?>{...base, 'subnetHash': '192.168.1.1'},
        'short_subnet_hash': <String, Object?>{...base, 'subnetHash': 'deadbeef'},
        'path_in_foregroundAppId': <String, Object?>{
          ...base,
          'foregroundAppId': '/Applications/Editor.app',
        },
      };

      for (final entry in badCases.entries) {
        final raw = jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/presence',
          'params': entry.value,
        });
        expect(
          () => XtpFrame.parse(raw),
          throwsInvalidParams(),
          reason: 'xuna/presence case ${entry.key} must fail with -32602',
        );
      }
    });

    test('T2-F9-03: xuna/resources rejects real paths, extra keys, and over-limit lists', () {
      final base = Map<String, Object?>.from(
        (meshFrames['resourcesNotification']! as Map<String, Object?>)['params']!
            as Map<String, Object?>,
      );

      final badCases = <String, Map<String, Object?>>{
        'extra_property': <String, Object?>{...base, 'rawPaths': <String>[]},
        'unix_path_in_workspaces': <String, Object?>{
          ...base,
          'workspaces': <String>['/Users/owner/project_alpha'],
        },
        'windows_path_in_apps': <String, Object?>{
          ...base,
          'installedApps': <String>[r'C:\Program Files\App\app.exe'],
        },
        'traversal_in_workspaces': <String, Object?>{
          ...base,
          'workspaces': <String>['..'],
        },
        'too_many_apps': <String, Object?>{
          ...base,
          'installedApps': List<String>.generate(257, (i) => 'app_$i'),
        },
        'too_many_workspaces': <String, Object?>{
          ...base,
          'workspaces': List<String>.generate(129, (i) => 'ws_$i'),
        },
      };

      for (final entry in badCases.entries) {
        final raw = jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/resources',
          'params': entry.value,
        });
        expect(
          () => XtpFrame.parse(raw),
          throwsInvalidParams(),
          reason: 'xuna/resources case ${entry.key} must fail with -32602',
        );
      }
    });

    test('T2-F9-05: xuna/focusRequest rejects invalid source, extra keys, and missing schemaVersion', () {
      final badCases = <String, Map<String, Object?>>{
        'invalid_source': const <String, Object?>{
          'schemaVersion': 1,
          'source': 'voice',
        },
        'missing_schemaVersion': const <String, Object?>{
          'source': 'hotkey',
        },
        'extra_property': const <String, Object?>{
          'schemaVersion': 1,
          'source': 'tray',
          'hostId': '11111111-1111-4111-8111-111111111111',
        },
      };

      for (final entry in badCases.entries) {
        final raw = jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/focusRequest',
          'params': entry.value,
        });
        expect(
          () => XtpFrame.parse(raw),
          throwsInvalidParams(),
          reason: 'xuna/focusRequest case ${entry.key} must fail with -32602',
        );
      }
    });
  });

  group('Tier 1/2 — Clipboard Redaction, Teleport URL Safety & Policy Metadata (F12, H5)', () {
    test('XTP-E2E-05a: redactSensitiveSelectionText caps at 1200 chars and redacts secrets', () {
      final secretBody = [
        'prefix_ok',
        'OPENAI_API_KEY=sk-testSecretKeyValue123456',
        'GH=ghp_abc123def456ghi789',
        'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abc.def',
        'password=SuperSecretPassword99',
        '-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----',
        'pad_' * 400,
      ].join(' ');

      final res = redactSensitiveSelectionText(secretBody);
      expect(res.text.length, equals(1200));
      expect(res.truncated, isTrue);
      expect(res.redactedCount, greaterThanOrEqualTo(5));
      expect(res.text, isNot(contains('sk-testSecretKeyValue123456')));
      expect(res.text, isNot(contains('ghp_abc123def456ghi789')));
      expect(res.text, isNot(contains('SuperSecretPassword99')));
      expect(res.text, isNot(contains('MIIEowIBAAKCAQEA')));
      expect(res.text, contains('[REDACTED]'));
    });

    test('XTP-E2E-05b: validateHttpsUrlAgainstAllowlist blocks unsafe URLs and supports IDN', () {
      const allowlist = <String>['github.com', 'xn--vit-5kz.vn'];

      for (final badUrl in const <String>[
        'http://github.com/org/repo',
        'file:///Users/owner/secret.txt',
        'https://localhost/admin',
        'https://127.0.0.1/status',
        'https://[::1]/status',
        'https://user:pass@github.com/org/repo',
      ]) {
        final result = validateHttpsUrlAgainstAllowlist(badUrl, allowlist);
        expect(result.validUrl, isFalse, reason: 'Must reject $badUrl');
        expect(result.errorCode, equals('url_invalid'));
      }

      final okPublic = validateHttpsUrlAgainstAllowlist(
        'https://github.com/xthao28/xuna_pet',
        allowlist,
      );
      expect(okPublic.validUrl, isTrue);
      expect(okPublic.domainAllowed, isTrue);
      expect(okPublic.asciiHost, equals('github.com'));

      final okIdn = validateHttpsUrlAgainstAllowlist(
        'https://docs.việt.vn/guide',
        allowlist,
      );
      expect(okIdn.validUrl, isTrue);
      expect(okIdn.domainAllowed, isTrue);
      expect(okIdn.asciiHost, equals('docs.xn--vit-5kz.vn'));
    });

    test('XTP-E2E-06: buildMvpToolCatalog declares media.play_pause.policy.idempotent == false and clipboard/selection schemas', () {
      final catalog = buildMvpToolCatalog(
        includeDeskCopilotTools: true,
        includeSymbioticCopilotTools: true,
      );

      final playPause = catalog.firstWhere((t) => t.name == 'media.play_pause');
      expect(playPause.policy.idempotent, isFalse);
      expect(playPause.policy.family, equals(ToolFamily.media));
      expect(playPause.policy.risk, equals(RiskTier.r1));

      final selectionRead = catalog.firstWhere((t) => t.name == 'selection.read');
      final inputProps =
          selectionRead.inputSchema['properties']! as Map<String, Object?>;
      final maxCharsSchema = inputProps['maxChars']! as Map<String, Object?>;
      expect(maxCharsSchema['minimum'], equals(80));
      expect(maxCharsSchema['maximum'], equals(1200));
      final outputProps =
          selectionRead.outputSchema['properties']! as Map<String, Object?>;
      final textSchema = outputProps['text']! as Map<String, Object?>;
      expect(textSchema['maxLength'], equals(1200));

      final clipboardWrite =
          catalog.firstWhere((t) => t.name == 'clipboard.write');
      expect(clipboardWrite.policy.risk, equals(RiskTier.r2));
      expect(clipboardWrite.policy.reversible, isFalse);
    });
  });
}

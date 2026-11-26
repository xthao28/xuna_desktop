import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  Matcher throwsInvalidParams() => throwsA(
        isA<XtpProtocolException>().having(
          (e) => e.jsonRpcCode,
          'jsonRpcCode',
          JsonRpcErrorCode.invalidParams,
        ),
      );

  group('P1.2 (U4) XtpToolchainEntry & ResourcesParams.toolchains', () {
    test('parses and round-trips ResourcesParams with valid toolchains', () {
      const params = ResourcesParams(
        installedApps: <String>['vscode'],
        workspaces: <String>['xuna_pet'],
        capabilitiesVersion: 'r1_0002',
        toolchains: <XtpToolchainEntry>[
          XtpToolchainEntry(id: 'git', version: '2.47.1'),
          XtpToolchainEntry(id: 'node', version: '22.11.0'),
          XtpToolchainEntry(id: 'rust_c-1.0', version: '1.83.0-nightly+abc'),
        ],
      );

      final notification = params.toNotification();
      final encoded = notification.encode();
      final decodedFrame = XtpFrame.parse(encoded) as XtpNotification;
      final parsed = decodedFrame.typedParams as ResourcesParams;

      expect(parsed.toolchains, equals(params.toolchains));
      expect(jsonDecode(encoded), equals(notification.toJson()));
      expect(
        canonicalJson(notification.params),
        equals(canonicalJson(decodedFrame.params)),
      );
    });

    test('omits toolchains when empty to keep legacy compatibility', () {
      const legacy = ResourcesParams(
        installedApps: <String>['vscode'],
        workspaces: <String>['xuna_pet'],
      );
      final json = legacy.toJson();
      expect(json.containsKey('toolchains'), isFalse);

      final parsed = XtpFrame.parse(legacy.toNotification().encode())
          as XtpNotification;
      expect((parsed.typedParams as ResourcesParams).toolchains, isEmpty);
    });

    test('tryFromJson parses valid entries and returns null on invalid entries',
        () {
      expect(
        XtpToolchainEntry.tryFromJson(
          const <String, Object?>{'id': 'git', 'version': '2.47.1'},
        ),
        equals(const XtpToolchainEntry(id: 'git', version: '2.47.1')),
      );
      expect(XtpToolchainEntry.tryFromJson('git'), isNull);
      expect(
        XtpToolchainEntry.tryFromJson(const <String, Object?>{
          'id': 'git',
          'version': '2.47.1',
          'path': '/usr/bin/git',
        }),
        isNull,
      );
      expect(
        XtpToolchainEntry.tryFromJson(const <String, Object?>{
          'id': 'git',
          'version': '/usr/bin/git',
        }),
        isNull,
      );
    });

    test('rejects invalid toolchain id/version, paths, control chars, >64, duplicates, and extra keys',
        () {
      Map<String, Object?> buildFrame(Object? toolchains) => <String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/resources',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'installedApps': const <String>['vscode'],
              'workspaces': const <String>['xuna_pet'],
              'toolchains': toolchains,
            },
          };

      final badIds = <String>[
        '',
        '.',
        '..',
        'a..b',
        'usr/bin',
        r'c:\git',
        'git cli',
        ' git',
        'git\n',
        'git\r',
        'git\t',
        'git\x00',
        'Node',
        'a' * 33,
      ];
      for (final badId in badIds) {
        expect(
          () => XtpFrame.parse(
            jsonEncode(buildFrame(<Map<String, Object?>>[
              <String, Object?>{'id': badId, 'version': '1.0.0'},
            ])),
          ),
          throwsInvalidParams(),
          reason: 'Must reject toolchain id "$badId"',
        );
      }

      final badVersions = <String>[
        '',
        '.1.0',
        '-1.0',
        '+1.0',
        '1.0..2',
        '/usr/bin/node',
        r'C:\node\22.0',
        '22.0/1',
        r'22.0\1',
        '22.0.0 (lts)',
        ' 22.0.0',
        '22.0.0 ',
        '22.0.0\n',
        '22.0.0\r',
        '22.0.0\t',
        '22.0.0\x00',
        '22.0.0\x7f',
        '1.${'0' * 31}',
      ];
      for (final badVersion in badVersions) {
        expect(
          () => XtpFrame.parse(
            jsonEncode(buildFrame(<Map<String, Object?>>[
              <String, Object?>{'id': 'node', 'version': badVersion},
            ])),
          ),
          throwsInvalidParams(),
          reason: 'Must reject toolchain version "$badVersion"',
        );
      }

      // > 64 entries
      final tooMany = List<Map<String, Object?>>.generate(
        65,
        (i) => <String, Object?>{'id': 'tool_$i', 'version': '1.0.$i'},
      );
      expect(
        () => XtpFrame.parse(jsonEncode(buildFrame(tooMany))),
        throwsInvalidParams(),
      );

      // Exactly 64 entries succeeds
      final exactly64 = List<Map<String, Object?>>.generate(
        64,
        (i) => <String, Object?>{'id': 'tool_$i', 'version': '1.0.$i'},
      );
      final parsed64 =
          XtpFrame.parse(jsonEncode(buildFrame(exactly64))) as XtpNotification;
      expect((parsed64.typedParams as ResourcesParams).toolchains, hasLength(64));

      // Duplicate ids
      expect(
        () => XtpFrame.parse(
          jsonEncode(buildFrame(const <Map<String, Object?>>[
            <String, Object?>{'id': 'git', 'version': '2.47.1'},
            <String, Object?>{'id': 'git', 'version': '2.48.0'},
          ])),
        ),
        throwsInvalidParams(),
      );

      // Outbound constructor validation rejects duplicates and > 64
      expect(
        () => const ResourcesParams(
          installedApps: <String>[],
          workspaces: <String>[],
          toolchains: <XtpToolchainEntry>[
            XtpToolchainEntry(id: 'git', version: '2.47.1'),
            XtpToolchainEntry(id: 'git', version: '2.48.0'),
          ],
        ).toJson(),
        throwsFormatException,
      );
      expect(
        () => ResourcesParams(
          installedApps: const <String>[],
          workspaces: const <String>[],
          toolchains: List<XtpToolchainEntry>.generate(
            65,
            (i) => XtpToolchainEntry(id: 't_$i', version: '1.0.$i'),
          ),
        ).toJson(),
        throwsFormatException,
      );

      // Wrong types & extra keys
      for (final badPayload in <Object?>[
        null,
        'git',
        123,
        <String, Object?>{},
        const <Object?>['git'],
        const <Map<String, Object?>>[
          <String, Object?>{'id': 'git'},
        ],
        const <Map<String, Object?>>[
          <String, Object?>{
            'id': 'git',
            'version': '2.47.1',
            'path': '/usr/bin/git',
          },
        ],
      ]) {
        expect(
          () => XtpFrame.parse(jsonEncode(buildFrame(badPayload))),
          throwsInvalidParams(),
          reason: 'Must reject malformed toolchains payload: $badPayload',
        );
      }

      // Extra key on ResourcesParams
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/resources',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'installedApps': const <String>[],
              'workspaces': const <String>[],
              'toolchainPaths': const <String>[],
            },
          }),
        ),
        throwsInvalidParams(),
      );
    });
  });

  group('P1.2 (U4) XtpRemediation & structuredContent.remediation', () {
    test('round-trips valid install, config, and manual remediations', () {
      const install = XtpRemediation(
        summary: 'Cài đặt Node.js LTS trên máy trước khi chạy lệnh này.',
        command: 'winget install OpenJS.NodeJS.LTS',
        kind: XtpRemediationKind.install,
      );
      final installJson = install.toJson();
      expect(
        installJson,
        equals(const <String, Object?>{
          'summary': 'Cài đặt Node.js LTS trên máy trước khi chạy lệnh này.',
          'command': 'winget install OpenJS.NodeJS.LTS',
          'kind': 'install',
        }),
      );
      expect(XtpRemediation.fromJson(installJson), equals(install));
      expect(XtpRemediation.tryFromJson(installJson), equals(install));

      const manual = XtpRemediation(
        summary: 'Mở VS Code một lần để đăng ký đường dẫn dòng lệnh.',
        kind: XtpRemediationKind.manual,
      );
      final manualJson = manual.toJson();
      expect(manualJson.containsKey('command'), isFalse);
      expect(XtpRemediation.fromJson(manualJson), equals(manual));

      const configWithUrlAndPackage = XtpRemediation(
        summary:
            'Install @acme/cli or review https://nodejs.org/en/download for setup.',
        command: 'npm install -g @acme/cli',
        kind: XtpRemediationKind.config,
      );
      expect(
        XtpRemediation.fromJson(configWithUrlAndPackage.toJson()),
        equals(configWithUrlAndPackage),
      );
    });

    test('fails closed on invalid kind, length, whitespace, control chars, extra keys, paths, and secrets',
        () {
      final invalidMaps = <String, Map<String, Object?>>{
        'invalid_kind': const <String, Object?>{
          'summary': 'Install Node.js',
          'kind': 'auto_exec',
        },
        'empty_summary': const <String, Object?>{
          'summary': '',
          'kind': 'install',
        },
        'over_240_summary': <String, Object?>{
          'summary': 'a' * 241,
          'kind': 'install',
        },
        'empty_command': const <String, Object?>{
          'summary': 'Install Node.js',
          'command': '',
          'kind': 'install',
        },
        'over_240_command': <String, Object?>{
          'summary': 'Install Node.js',
          'command': 'b' * 241,
          'kind': 'install',
        },
        'untrimmed_summary': const <String, Object?>{
          'summary': '  Install Node.js',
          'kind': 'install',
        },
        'untrimmed_command': const <String, Object?>{
          'summary': 'Install Node.js',
          'command': 'brew install node ',
          'kind': 'install',
        },
        'newline_summary': const <String, Object?>{
          'summary': 'Install\nNode.js',
          'kind': 'install',
        },
        'cr_command': const <String, Object?>{
          'summary': 'Install Node.js',
          'command': 'brew install node\rwhoami',
          'kind': 'install',
        },
        'tab_command': const <String, Object?>{
          'summary': 'Install Node.js',
          'command': 'brew\tinstall node',
          'kind': 'install',
        },
        'nul_summary': const <String, Object?>{
          'summary': 'Install\x00Node.js',
          'kind': 'install',
        },
        'extra_key': const <String, Object?>{
          'summary': 'Install Node.js',
          'kind': 'install',
          'autoRun': true,
        },
        'unix_path_in_summary': const <String, Object?>{
          'summary': 'Missing binary at /usr/bin/node',
          'kind': 'install',
        },
        'home_path_in_command': const <String, Object?>{
          'summary': 'Install runtime',
          'command': '/Users/owner/bin/install.sh',
          'kind': 'install',
        },
        'windows_path_in_command': const <String, Object?>{
          'summary': 'Install runtime',
          'command': r'C:\Users\owner\AppData\Local\node.exe',
          'kind': 'install',
        },
        'windows_forward_slash_path': const <String, Object?>{
          'summary': 'Missing D:/tools/python/python.exe',
          'kind': 'install',
        },
        'tilde_path': const <String, Object?>{
          'summary': 'Check ~/tools/node',
          'kind': 'config',
        },
        'secret_in_command': const <String, Object?>{
          'summary': 'Configure token',
          'command': 'export OPENAI_API_KEY=sk-1234567890abcdef',
          'kind': 'config',
        },
      };

      for (final entry in invalidMaps.entries) {
        expect(
          () => XtpRemediation.fromJson(entry.value),
          throwsFormatException,
          reason: 'XtpRemediation.fromJson must reject ${entry.key}',
        );
        expect(
          XtpRemediation.tryFromJson(entry.value),
          isNull,
          reason: 'XtpRemediation.tryFromJson must return null for ${entry.key}',
        );
      }
      expect(XtpRemediation.tryFromJson('not a map'), isNull);
    });

    test('XtpResponse.toolCallResult attaches remediation while keeping 3-key _meta and forbids remediation on ok',
        () {
      const remediation = XtpRemediation(
        summary: 'Node.js runtime is required to run this command.',
        command: 'winget install OpenJS.NodeJS.LTS',
        kind: XtpRemediationKind.install,
      );

      final errResp = XtpResponse.toolCallResult(
        id: 818,
        text: 'toolchain_missing: node',
        structuredContent: const <String, Object?>{
          'errorCode': 'toolchain_missing',
        },
        status: XtpStatus.failed,
        durationMs: 8,
        errorCode: 'toolchain_missing',
        remediation: remediation,
      );

      final meta = errResp.result['_meta']! as Map<String, Object?>;
      expect(
        meta.keys.toSet(),
        equals(const <String>{
          'xuna/status',
          'xuna/errorCode',
          'xuna/durationMs',
        }),
      );
      final sc = errResp.result['structuredContent']! as Map<String, Object?>;
      expect(sc['remediation'], equals(remediation.toJson()));
      expect(XtpFrame.parse(errResp.encode()), isA<XtpResponse>());

      expect(
        () => XtpResponse.toolCallResult(
          id: 819,
          text: 'ok',
          structuredContent: const <String, Object?>{},
          status: XtpStatus.ok,
          durationMs: 1,
          remediation: remediation,
        ),
        throwsInvalidParams(),
      );

      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 820,
            'result': <String, Object?>{
              'content': const <Map<String, Object?>>[
                <String, Object?>{'type': 'text', 'text': 'failed'},
              ],
              'structuredContent': const <String, Object?>{
                'remediation': <String, Object?>{
                  'summary': 'Bad path /Users/owner/bin',
                  'kind': 'install',
                },
              },
              'isError': true,
              '_meta': const <String, Object?>{
                'xuna/status': 'failed',
                'xuna/errorCode': 'toolchain_missing',
                'xuna/durationMs': 4,
              },
            },
          }),
        ),
        throwsInvalidParams(),
      );
    });
  });

  group('P1.2 (U4) Fixture parity & golden frame checks', () {
    test('all 6 XTP fixture files byte-match backend/tests/fixtures/xtp', () {
      final backendDir = Directory('../../../backend/tests/fixtures/xtp');
      if (!backendDir.existsSync()) {
        markTestSkipped('backend checkout not present');
        return;
      }
      for (final name in const <String>[
        'exec_fs_frames.json',
        'golden_vectors.json',
        'mesh_frames.json',
        'policy_frames.json',
        'sample_frames.json',
        'watch_frames.json',
      ]) {
        final localBytes = File('test/fixtures/xtp/$name').readAsBytesSync();
        final backendBytes =
            File('../../../backend/tests/fixtures/xtp/$name').readAsBytesSync();
        expect(
          sha256.convert(localBytes).toString(),
          equals(sha256.convert(backendBytes).toString()),
          reason: '$name SHA-256 mismatch',
        );
        expect(localBytes, equals(backendBytes), reason: '$name bytes mismatch');
      }
    });

    test('parses resourcesWithToolchainsNotification and toolsCallToolchainMissingRemediationResponse',
        () {
      final meshJson = jsonDecode(
        File('test/fixtures/xtp/mesh_frames.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final meshFrames = meshJson['frames']! as Map<String, Object?>;
      final resourcesFrame = XtpFrame.parse(
        jsonEncode(meshFrames['resourcesWithToolchainsNotification']),
      ) as XtpNotification;
      final resourcesParams = resourcesFrame.typedParams as ResourcesParams;
      expect(
        resourcesParams.toolchains,
        equals(const <XtpToolchainEntry>[
          XtpToolchainEntry(id: 'git', version: '2.47.1'),
          XtpToolchainEntry(id: 'node', version: '22.11.0'),
        ]),
      );

      final execJson = jsonDecode(
        File('test/fixtures/xtp/exec_fs_frames.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final execFrames = execJson['frames']! as Map<String, Object?>;
      final remFrame = XtpFrame.parse(
        jsonEncode(execFrames['toolsCallToolchainMissingRemediationResponse']),
      ) as XtpResponse;
      final sc = remFrame.result['structuredContent']! as Map<String, Object?>;
      final rem = XtpRemediation.fromJson(
        sc['remediation']! as Map<String, Object?>,
      );
      expect(rem.kind, equals(XtpRemediationKind.install));
      expect(rem.command, equals('winget install OpenJS.NodeJS.LTS'));
    });
  });
}

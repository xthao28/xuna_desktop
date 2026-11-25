import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Wave 3 golden fixtures (`exec_fs_frames.json`, `policy_frames.json`):
/// byte parity with the backend copy, parse round-trip, descriptor parity
/// with the builders and rejection of remote `shellControl` writes.
Map<String, Object?> _load(String name) =>
    jsonDecode(File('test/fixtures/xtp/$name').readAsStringSync())
        as Map<String, Object?>;

void main() {
  for (final name in const ['exec_fs_frames.json', 'policy_frames.json']) {
    group(name, () {
      test('byte-matches backend/tests/fixtures/xtp/$name', () {
        final backend = File('../../../backend/tests/fixtures/xtp/$name');
        if (!backend.existsSync()) {
          markTestSkipped('backend checkout not present');
          return;
        }
        expect(
          File('test/fixtures/xtp/$name').readAsBytesSync(),
          equals(backend.readAsBytesSync()),
        );
      });

      test('every valid frame parses and re-encodes identically', () {
        final frames = _load(name)['frames'] as Map<String, Object?>;
        expect(frames, isNotEmpty);
        for (final entry in frames.entries) {
          final raw = entry.value as Map<String, Object?>;
          final parsed = XtpFrame.parse(jsonEncode(raw));
          expect(
            jsonDecode(parsed.encode()),
            equals(raw),
            reason: entry.key,
          );
        }
      });
    });
  }

  test('fixture descriptors equal buildFsTools + buildExecTools', () {
    final frames =
        _load('exec_fs_frames.json')['frames'] as Map<String, Object?>;
    final tools = ((frames['toolsListExecFsResponse']! as Map)['result']
        as Map)['tools'] as List<Object?>;
    final built = <ToolDescriptor>[
      ...buildFsTools(),
      ...buildExecTools(shellEnabled: true),
    ];
    expect(
      tools,
      equals(jsonDecode(jsonEncode([for (final t in built) t.toJson()]))),
    );
    for (final raw in tools) {
      final d = ToolDescriptor.fromJson(raw! as Map<String, Object?>);
      expect(
        d.policy.family,
        d.name.startsWith('exec.') ? ToolFamily.exec : ToolFamily.files,
      );
    }
  });

  test('a refused preflight carrying a risk is rejected', () {
    expect(
      () => XtpFrame.parse(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{
            'preflight': <String, Object?>{
              'status': 'denied',
              'errorCode': 'exec_hard_denied',
              'effectiveRisk': 'R2',
            },
          },
        }),
      ),
      throwsA(isA<XtpProtocolException>()),
    );
  });

  test('policy invalid frames fail with their expected JSON-RPC code', () {
    final invalid =
        _load('policy_frames.json')['invalidFrames'] as Map<String, Object?>;
    expect(invalid.length, 3);
    for (final entry in invalid.entries) {
      final spec = entry.value! as Map<String, Object?>;
      expect(
        () => XtpFrame.parse(jsonEncode(spec['frame'])),
        throwsA(
          isA<XtpProtocolException>().having(
            (e) => e.jsonRpcCode,
            'jsonRpcCode',
            spec['expectedJsonRpcCode'],
          ),
        ),
        reason: entry.key,
      );
    }
  });

  test('get_policy shellEnabled must be a boolean', () {
    expect(
      () => XtpFrame.parse(
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'result': <String, Object?>{
            'schemaVersion': 1,
            'trustPreset': 'standard',
            'allowApps': <String>[],
            'discoveredApps': <String>[],
            'shellEnabled': 'yes',
          },
        }),
      ),
      throwsA(isA<XtpProtocolException>()),
    );
  });

  group('environment sanitization', () {
    test('drops API keys, XUNA_* and shell start-up hooks', () {
      final env = sanitizeExecEnvironment(<String, String>{
        'PATH': '/usr/bin',
        'HOME': '/Users/owner',
        'GEMINI_API_KEY': 'k',
        'OPENAI_API_KEY': 'k',
        'XUNA_TEXT_API_KEY': 'k',
        'AWS_SECRET_ACCESS_KEY': 'k',
        'GITHUB_TOKEN': 'k',
        'BASH_ENV': '/tmp/hook',
        'ZDOTDIR': '/tmp',
      }, windows: false);
      expect(env.keys.toSet(), <String>{'PATH', 'HOME'});
    });

    test('Windows keeps system variables and strips secrets case-insensitively',
        () {
      final env = sanitizeExecEnvironment(<String, String>{
        'Path': r'C:\Windows',
        'SystemRoot': r'C:\Windows',
        'ComSpec': r'C:\Windows\system32\cmd.exe',
        'xuna_secret': 'k',
        'Groq_Api_Key': 'k',
      }, windows: true);
      expect(env.keys.toSet(), <String>{'Path', 'SystemRoot', 'ComSpec'});
    });
  });

  group('watch exec_async', () {
    test('parses mode, signal and execTaskId; rejects bad task ids', () {
      expect(WatchMode.fromWire('exec_async'), WatchMode.execAsync);
      expect(WatchSignal.fromWire('exec_async'), WatchSignal.execAsync);
      expect(
        WatchSignal.allowedCompositeSignals.contains(WatchSignal.execAsync),
        isFalse,
      );
      final target = WatchTarget.fromJson(<String, Object?>{
        'execTaskId': 'exec_abc123',
      });
      expect(target.toJson(), <String, Object?>{'execTaskId': 'exec_abc123'});
      expect(
        () => WatchTarget.fromJson(<String, Object?>{'execTaskId': 'rm -rf'}),
        throwsFormatException,
      );
    });
  });
}

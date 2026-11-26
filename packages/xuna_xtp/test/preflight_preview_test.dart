import 'dart:convert';

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('XtpPreflightPreview (W4-M2 / XTP §4.2.8)', () {
    test('round-trips valid diff preview (non-truncated and truncated with …)',
        () {
      final full = XtpPreflightPreview.diff(
        summary: 'src/app.ts: 1 replacement',
        snippet: '--- a/src/app.ts\n+++ b/src/app.ts\n-old\n+new',
        truncated: false,
      );
      final frame1 = XtpResponse.preflightResult(
        id: 101,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r2,
        reasonCode: 'workspace',
        preview: full,
      );
      final parsed1 = XtpFrame.parse(frame1.encode()) as XtpResponse;
      expect(jsonDecode(parsed1.encode()), equals(jsonDecode(frame1.encode())));

      final truncated = XtpPreflightPreview.diff(
        summary: 'src/big.ts: overwrite',
        snippet: '+line 1\n+line 2\n…',
        truncated: true,
      );
      final frame2 = XtpResponse.preflightResult(
        id: 102,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r3,
        reasonCode: 'outside_workspace',
        preview: truncated,
      );
      final parsed2 = XtpFrame.parse(frame2.encode()) as XtpResponse;
      final parsedPreview = XtpPreflightPreview.fromJson(
        ((parsed2.result['preflight']! as Map)['preview']! as Map)
            .cast<String, Object?>(),
      );
      expect(parsedPreview.truncated, isTrue);
      expect(parsedPreview.snippet, endsWith('…'));
    });

    test('round-trips valid paths preview (empty, bounded, and truncated)', () {
      final empty = XtpPreflightPreview.paths(
        summary: '0 matching files in workspace',
        paths: const <String>[],
        totalCount: 0,
        truncated: false,
      );
      final frameEmpty = XtpResponse.preflightResult(
        id: 103,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r3,
        reasonCode: 'destructive_command',
        preview: empty,
      );
      expect(XtpFrame.parse(frameEmpty.encode()), isA<XtpResponse>());

      final bounded = XtpPreflightPreview.paths(
        summary: '25 matching file(s) in workspace',
        paths: List<String>.generate(20, (i) => 'logs/file_$i.log'),
        totalCount: 25,
        truncated: true,
      );
      final frameBounded = XtpResponse.preflightResult(
        id: 104,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r3,
        reasonCode: 'destructive_command',
        preview: bounded,
      );
      final parsed = XtpFrame.parse(frameBounded.encode()) as XtpResponse;
      expect(
        (((parsed.result['preflight']! as Map)['preview']! as Map)['paths']!
                as List)
            .length,
        20,
      );
    });

    test('fail-closed: rejects preview on refused preflight', () {
      expect(
        () => XtpResponse.preflightResult(
          id: 201,
          status: XtpStatus.denied,
          errorCode: 'fs_secret_file_forbidden',
          preview: XtpPreflightPreview.diff(
            summary: 'x',
            snippet: '+a',
            truncated: false,
          ),
        ),
        throwsA(isA<XtpProtocolException>()),
      );
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 202,
            'result': <String, Object?>{
              'preflight': <String, Object?>{
                'status': 'denied',
                'errorCode': 'exec_hard_denied',
                'preview': <String, Object?>{
                  'kind': 'paths',
                  'summary': '1 file',
                  'paths': <String>['a.log'],
                  'totalCount': 1,
                  'truncated': false,
                },
              },
            },
          }),
        ),
        throwsA(isA<XtpProtocolException>()),
      );
    });

    test(
        'fail-closed: enforces byte/line caps, truncation marker, path safety, and secret blocks',
        () {
      // > 2048 UTF-8 bytes
      expect(
        () => XtpPreflightPreview.diff(
          summary: 'too big',
          snippet: 'a' * 2049,
          truncated: false,
        ),
        throwsFormatException,
      );
      // > 40 lines
      expect(
        () => XtpPreflightPreview.diff(
          summary: 'too many lines',
          snippet: List<String>.filled(41, '+x').join('\n'),
          truncated: false,
        ),
        throwsFormatException,
      );
      // truncated without ellipsis
      expect(
        () => XtpPreflightPreview.diff(
          summary: 'missing marker',
          snippet: '+line1',
          truncated: true,
        ),
        throwsFormatException,
      );
      // > 20 paths
      expect(
        () => XtpPreflightPreview.paths(
          summary: 'too many paths',
          paths: List<String>.generate(21, (i) => 'f$i.log'),
          totalCount: 21,
          truncated: true,
        ),
        throwsFormatException,
      );
      // totalCount < paths.length
      expect(
        () => XtpPreflightPreview.paths(
          summary: 'bad count',
          paths: const <String>['a.log', 'b.log'],
          totalCount: 1,
          truncated: false,
        ),
        throwsFormatException,
      );
      // absolute, traversal, and secret paths rejected
      for (final badPath in const <String>[
        '/etc/passwd',
        r'C:\Users\owner\a.log',
        '../outside.log',
        'sub/../../escape.log',
        '.env',
        'config/.env.production',
        '.ssh/id_rsa',
        'certs/server.key',
      ]) {
        expect(
          () => XtpPreflightPreview.paths(
            summary: 'bad path',
            paths: <String>[badPath],
            totalCount: 1,
            truncated: false,
          ),
          throwsFormatException,
          reason: 'must reject $badPath',
        );
      }
      // mixed fields across kinds rejected by parser
      expect(
        () => XtpPreflightPreview.fromJson(const <String, Object?>{
          'kind': 'diff',
          'summary': 'bad mix',
          'snippet': '+x',
          'paths': <String>[],
          'truncated': false,
        }),
        throwsFormatException,
      );
    });
  });
}

import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  test(
    'fuzzes XtpFrame.parse with 1,000 random and mutated inputs without unexpected exceptions',
    () {
      final rng = Random(20261030);
      final seedFrames = <String>[
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'ping',
          'params': <String, Object?>{},
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/list',
          'params': <String, Object?>{},
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 3,
          'method': 'tools/call',
          'params': <String, Object?>{
            'name': 'media.play_pause',
            'arguments': <String, Object?>{},
            '_meta': <String, Object?>{
              'xuna/invocationId': '5a7c9e12-34b6-4d89-a012-3456789abcde',
              'xuna/deadlineMs': 5000,
            },
          },
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'xuna/stop',
          'params': <String, Object?>{'reason': 'owner_app'},
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': <String, Object?>{'requestId': 3, 'reason': 'timeout'},
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'result': <String, Object?>{'protocol': 'xtp/1'},
        }),
        jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 9,
          'error': <String, Object?>{
            'code': -32601,
            'message': 'Method not found',
          },
        }),
      ];

      var accepted = 0;
      var rejected = 0;

      for (var i = 0; i < 1000; i++) {
        final String candidate = switch (i % 5) {
          0 => _randomAsciiOrUnicodeString(rng),
          1 => _mutateString(rng, seedFrames[rng.nextInt(seedFrames.length)]),
          2 => _randomJsonStructure(rng, depth: 0),
          3 => _mutatedRpcEnvelope(rng),
          _ =>
            i == 999
                ? '{"jsonrpc":"2.0","id":1,"method":"ping","params":{"pad":"${'A' * 70000}"}}'
                : _mutateString(
                    rng,
                    seedFrames[rng.nextInt(seedFrames.length)],
                  ),
        };

        try {
          final frame = XtpFrame.parse(candidate);
          expect(frame, isA<XtpFrame>());
          accepted++;
        } on XtpProtocolException catch (error) {
          expect(<int>[
            JsonRpcErrorCode.parseError,
            JsonRpcErrorCode.invalidRequest,
            JsonRpcErrorCode.methodNotFound,
            JsonRpcErrorCode.invalidParams,
          ], contains(error.jsonRpcCode));
          rejected++;
        }
      }

      expect(accepted + rejected, 1000);
      expect(rejected, greaterThan(500));
    },
  );
}

String _randomAsciiOrUnicodeString(Random rng) {
  final len = rng.nextInt(256);
  final codes = List<int>.generate(len, (_) {
    final pick = rng.nextInt(4);
    if (pick == 0) return rng.nextInt(128);
    if (pick == 1) return 0x00C0 + rng.nextInt(0x0200);
    if (pick == 2) return 0x1EA0 + rng.nextInt(90); // Vietnamese block
    return 32 + rng.nextInt(95);
  });
  return String.fromCharCodes(codes);
}

String _mutateString(Random rng, String input) {
  if (input.isEmpty) return '{';
  final chars = input.runes.toList();
  final ops = 1 + rng.nextInt(6);
  for (var k = 0; k < ops && chars.isNotEmpty; k++) {
    final op = rng.nextInt(4);
    final idx = rng.nextInt(chars.length);
    switch (op) {
      case 0:
        chars.removeAt(idx);
      case 1:
        chars[idx] = 32 + rng.nextInt(95);
      case 2:
        chars.insert(
          idx,
          <int>[0, 10, 34, 58, 91, 93, 123, 125][rng.nextInt(8)],
        );
      case 3:
        if (idx > 0) {
          return String.fromCharCodes(chars.sublist(0, idx));
        }
    }
  }
  return String.fromCharCodes(chars);
}

String _randomJsonStructure(Random rng, {required int depth}) {
  if (depth > 3) {
    return jsonEncode(rng.nextBool() ? 'x' : rng.nextInt(100));
  }
  final kind = rng.nextInt(6);
  switch (kind) {
    case 0:
      return 'null';
    case 1:
      return rng.nextBool() ? 'true' : 'false';
    case 2:
      return rng.nextInt(100000).toString();
    case 3:
      return jsonEncode(_randomAsciiOrUnicodeString(rng));
    case 4:
      final list = List<String>.generate(
        rng.nextInt(4),
        (_) => _randomJsonStructure(rng, depth: depth + 1),
      );
      return '[${list.join(',')}]';
    default:
      final count = rng.nextInt(5);
      final entries = <String>[];
      for (var i = 0; i < count; i++) {
        final key = <String>[
          'jsonrpc',
          'id',
          'method',
          'params',
          'result',
          'error',
          'extra',
          'name',
        ][rng.nextInt(8)];
        entries.add(
          '${jsonEncode(key)}:${_randomJsonStructure(rng, depth: depth + 1)}',
        );
      }
      return '{${entries.join(',')}}';
  }
}

String _mutatedRpcEnvelope(Random rng) {
  final methods = <Object?>[
    'xuna/hello',
    'xuna/proof',
    'tools/list',
    'tools/call',
    'ping',
    'xuna/challenge',
    'xuna/enrollPending',
    'xuna/enrolled',
    'xuna/ready',
    'notifications/cancelled',
    'xuna/stop',
    'shell.exec',
    'unknown/method',
    '',
    42,
    null,
  ];
  final ids = <Object?>[
    1,
    'req-1',
    null,
    true,
    <int>[1],
    <String, int>{'a': 1},
  ];
  final paramsChoices = <Object?>[
    <String, Object?>{},
    <String, Object?>{
      'protocols': <String>['xtp/1'],
    },
    <String, Object?>{
      'protocols': <String>['xtp/99'],
    },
    <String, Object?>{
      'name': 'shell.exec',
      'arguments': <String, Object?>{},
      '_meta': <String, Object?>{
        'xuna/invocationId': '5a7c9e12-34b6-4d89-a012-3456789abcde',
        'xuna/deadlineMs': 5000,
      },
    },
    <String, Object?>{
      'name': 'url.open',
      'arguments': <String, Object?>{'url': 'https://github.com'},
      '_meta': <String, Object?>{
        'xuna/invocationId': 'not-a-uuid',
        'xuna/deadlineMs': 999999,
      },
    },
    'not-a-map',
    null,
  ];

  final map = <String, Object?>{
    'jsonrpc': rng.nextInt(10) == 0 ? '1.0' : '2.0',
    if (rng.nextBool()) 'id': ids[rng.nextInt(ids.length)],
    'method': methods[rng.nextInt(methods.length)],
    if (rng.nextInt(6) != 0)
      'params': paramsChoices[rng.nextInt(paramsChoices.length)],
  };
  return jsonEncode(map);
}

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  late Map<String, Object?> watchFixture;

  setUpAll(() {
    final file = File('test/fixtures/xtp/watch_frames.json');
    watchFixture = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
  });

  group('watch_frames.json parity & registries', () {
    test('byte-matches backend/tests/fixtures/xtp/watch_frames.json', () {
      final backendDir = Directory('../../../backend/tests/fixtures/xtp');
      if (!backendDir.existsSync()) {
        return;
      }
      final localBytes =
          File('test/fixtures/xtp/watch_frames.json').readAsBytesSync();
      final backendBytes =
          File('../../../backend/tests/fixtures/xtp/watch_frames.json')
              .readAsBytesSync();
      expect(localBytes, equals(backendBytes));
      expect(
        sha256.convert(localBytes).toString(),
        equals(sha256.convert(backendBytes).toString()),
      );
    });

    test('method registries register watch RPCs and notification properly', () {
      expect(knownXtpRequestMethods, contains('xuna/watchRegister'));
      expect(knownXtpRequestMethods, contains('xuna/watchCancel'));
      expect(knownXtpRequestMethods, isNot(contains('xuna/watchEvent')));
      expect(knownXtpNotificationMethods, contains('xuna/watchEvent'));
      expect(
        knownXtpNotificationMethods,
        isNot(contains('xuna/watchRegister')),
      );
      expect(knownXtpNotificationMethods, isNot(contains('xuna/watchCancel')));
    });
  });

  group('Golden valid frames round-trip', () {
    test('parses and re-encodes all 27 valid frames identically', () {
      final frames = watchFixture['frames'] as Map<String, Object?>;
      expect(frames.length, equals(27));

      for (final entry in frames.entries) {
        final rawMap = entry.value as Map<String, Object?>;
        final rawJson = jsonEncode(rawMap);
        final parsed = XtpFrame.parse(rawJson);
        final reEncoded = jsonDecode(parsed.encode()) as Map<String, Object?>;
        expect(
          reEncoded,
          equals(rawMap),
          reason: 'Frame ${entry.key} must round-trip identically',
        );
      }
    });

    test('typed params and factory constructors match golden frames', () {
      final frames = watchFixture['frames'] as Map<String, Object?>;

      final compReq = XtpFrame.parse(
        jsonEncode(frames['watchRegisterCompositeRequest']),
      ) as XtpRequest;
      final compParams = compReq.typedParams as WatchRegisterParams;
      expect(compParams.mode, equals(WatchMode.composite));
      expect(
        compParams.signals,
        equals(const <WatchSignal>[
          WatchSignal.uiQuiescence,
          WatchSignal.processIdle,
        ]),
      );
      expect(compParams.target.pid, equals(48210));
      expect(compParams.target.windowId, equals(1042));
      expect(compParams.target.appId, equals('editor'));
      expect(compParams.target.workspaceAlias, equals('xuna_pet'));
      expect(compParams.quiescenceSeconds, equals(8));
      expect(compParams.minWaitSeconds, equals(3));
      expect(compParams.maxWaitSeconds, equals(300));
      expect(compParams.requireInitialChange, isTrue);
      expect(compParams.releaseFocus, isTrue);
      expect(
        jsonDecode(XtpRequest.watchRegister(701, compParams).encode()),
        equals(frames['watchRegisterCompositeRequest']),
      );

      final timerReq = XtpFrame.parse(
        jsonEncode(frames['watchRegisterTimerRequest']),
      ) as XtpRequest;
      final timerParams = timerReq.typedParams as WatchRegisterParams;
      expect(timerParams.mode, equals(WatchMode.timer));
      expect(timerParams.signals, isNull);
      expect(timerParams.target.toJson(), isEmpty);

      final protoReq = XtpFrame.parse(
        jsonEncode(frames['watchRegisterProtocolAsyncRequest']),
      ) as XtpRequest;
      final protoParams = protoReq.typedParams as WatchRegisterParams;
      expect(protoParams.mode, equals(WatchMode.protocolAsync));
      expect(protoParams.target.mcpServerId, equals('build_mcp'));
      expect(protoParams.target.protocolTaskId, equals('task_01'));
      expect(protoParams.requireInitialChange, isFalse);

      final protoAccepted = XtpResponse.watchRegisterAccepted(
        id: 706,
        watchId: 'f1111111-1111-4111-8111-111111111116',
        activeSignals: const <WatchSignal>[WatchSignal.protocolAsync],
        eventDriven: true,
        fallbackUsed: false,
      );
      expect(
        jsonDecode(protoAccepted.encode()),
        equals(frames['watchRegisterProtocolAsyncAcceptedResponse']),
      );

      final protoSettled = XtpFrame.parse(
        jsonEncode(frames['watchEventProtocolAsyncSettledNotification']),
      ) as XtpNotification;
      final protoSettledParams = protoSettled.typedParams as WatchEventParams;
      expect(protoSettledParams.kind, equals(WatchEventKind.settled));
      expect(
        protoSettledParams.observedSignals,
        equals(const <WatchSignal>[WatchSignal.protocolAsync]),
      );

      final protoLost = XtpFrame.parse(
        jsonEncode(frames['watchEventProtocolAsyncTargetLostNotification']),
      ) as XtpNotification;
      final protoLostParams = protoLost.typedParams as WatchEventParams;
      expect(protoLostParams.kind, equals(WatchEventKind.targetLost));
      expect(protoLostParams.observedSignals, isEmpty);

      final acceptedResp = XtpResponse.watchRegisterAccepted(
        id: 701,
        watchId: 'f1111111-1111-4111-8111-111111111111',
        activeSignals: const <WatchSignal>[
          WatchSignal.uiQuiescence,
          WatchSignal.processIdle,
        ],
        eventDriven: true,
        fallbackUsed: false,
      );
      expect(
        jsonDecode(acceptedResp.encode()),
        equals(frames['watchRegisterAcceptedResponse']),
      );

      final rejectedResp = XtpResponse.watchRegisterRejected(
        id: 701,
        watchId: 'f1111111-1111-4111-8111-111111111111',
        errorCode: WatchRejectErrorCode.policyBlocked,
      );
      expect(
        jsonDecode(rejectedResp.encode()),
        equals(frames['watchRegisterRejectedPolicyBlockedResponse']),
      );

      final estopCancel = XtpFrame.parse(
        jsonEncode(frames['watchCancelEstopRequest']),
      ) as XtpRequest;
      final estopParams = estopCancel.typedParams as WatchCancelParams;
      expect(estopParams.watchId, isNull);
      expect(estopParams.jobId, isNull);
      expect(estopParams.reason, equals(WatchCancelReason.estop));
      expect(
        jsonDecode(XtpRequest.watchCancel(712, estopParams).encode()),
        equals(frames['watchCancelEstopRequest']),
      );

      final cancelResp = XtpResponse.watchCancelResult(
        id: 710,
        cancelledCount: 1,
      );
      expect(
        jsonDecode(cancelResp.encode()),
        equals(frames['watchCancelResponse']),
      );

      final errEvent = XtpFrame.parse(
        jsonEncode(frames['watchEventErrorNotification']),
      ) as XtpNotification;
      final errParams = errEvent.typedParams as WatchEventParams;
      expect(errParams.kind, equals(WatchEventKind.error));
      expect(errParams.observedSignals, isEmpty);
      expect(errParams.errorCode, equals('needs_permission'));
      final reBuiltNotif = XtpNotification.watchEvent(errParams);
      expect(reBuiltNotif.method, equals('xuna/watchEvent'));
      expect(
        DateTime.parse(
          (reBuiltNotif.params['occurredAt'] as String),
        ),
        equals(errParams.occurredAt),
      );
    });
  });

  group('Golden invalidFrames rejected', () {
    test('rejects all 14 invalidFrames with expectedJsonRpcCode', () {
      final invalidFrames =
          watchFixture['invalidFrames'] as Map<String, Object?>;
      expect(invalidFrames.length, equals(14));

      for (final entry in invalidFrames.entries) {
        final spec = entry.value as Map<String, Object?>;
        final rawFrame = spec['frame'] as Map<String, Object?>;
        final expectedCode = spec['expectedJsonRpcCode'] as int;
        expect(
          () => XtpFrame.parse(jsonEncode(rawFrame)),
          throwsA(
            isA<XtpProtocolException>().having(
              (e) => e.jsonRpcCode,
              'jsonRpcCode',
              equals(expectedCode),
            ),
          ),
          reason: 'Invalid frame ${entry.key} must throw $expectedCode',
        );
      }
    });
  });

  group('Boundary & negative contract cases', () {
    const validWatchId = 'f1111111-1111-4111-8111-111111111111';
    const validJobId = 'a2222222-2222-4222-8222-222222222222';
    const nilUuid = '00000000-0000-0000-0000-000000000000';

    Map<String, Object?> baseTimerRegister({
      Object? schemaVersion = 1,
      String watchId = validWatchId,
      String jobId = validJobId,
      String mode = 'timer',
      Object? signals,
      bool includeSignals = false,
      Map<String, Object?> target = const <String, Object?>{},
      int quiescenceSeconds = 2,
      int minWaitSeconds = 0,
      int maxWaitSeconds = 5,
    }) =>
        <String, Object?>{
          'jsonrpc': '2.0',
          'id': 800,
          'method': 'xuna/watchRegister',
          'params': <String, Object?>{
            'schemaVersion': schemaVersion,
            'watchId': watchId,
            'jobId': jobId,
            'mode': mode,
            if (includeSignals) 'signals': signals,
            'target': target,
            'quiescenceSeconds': quiescenceSeconds,
            'minWaitSeconds': minWaitSeconds,
            'maxWaitSeconds': maxWaitSeconds,
            'requireInitialChange': false,
            'releaseFocus': true,
          },
        };

    test(
        'rejects nil UUID in watchRegister, watchCancel, watchEvent, and result',
        () {
      expect(
        () => XtpFrame.parse(jsonEncode(baseTimerRegister(watchId: nilUuid))),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      expect(
        () => XtpFrame.parse(jsonEncode(baseTimerRegister(jobId: nilUuid))),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 801,
            'method': 'xuna/watchCancel',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': nilUuid,
              'reason': 'owner_cancel',
            },
          }),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/watchEvent',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': nilUuid,
              'jobId': validJobId,
              'kind': 'timeout',
              'observedSignals': <String>[],
              'elapsedSeconds': 5,
              'changeCount': 0,
              'digestChanged': false,
              'occurredAt': '2026-11-22T12:45:00Z',
            },
          }),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      expect(
        () => XtpResponse.watchRegisterRejected(
          id: 802,
          watchId: nilUuid,
          errorCode: WatchRejectErrorCode.invalidArgs,
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
    });

    test('rejects non-1 or non-int schemaVersion', () {
      for (final bad in <Object?>[1.0, true, '1', 2, 0]) {
        expect(
          () => XtpFrame.parse(
            jsonEncode(baseTimerRegister(schemaVersion: bad)),
          ),
          throwsA(
            isA<XtpProtocolException>()
                .having((e) => e.jsonRpcCode, 'code', -32602),
          ),
        );
      }
    });

    test(
        'validates WatchTarget bounds and accepts valid-syntax hard-denied appId on wire',
        () {
      // Valid-syntax hard-denied appId MUST parse on the wire so LocalWatchSentinel
      // can fail closed with accepted: false, errorCode: "policy_blocked".
      final parsed = XtpFrame.parse(
        jsonEncode(
          baseTimerRegister(
            mode: 'ui_quiescence',
            target: const <String, Object?>{
              'pid': 100,
              'appId': 'terminal',
            },
          ),
        ),
      ) as XtpRequest;
      expect(
        (parsed.typedParams as WatchRegisterParams).target.appId,
        equals('terminal'),
      );

      // Invalid target subfields rejected with -32602
      final invalidTargets = <Map<String, Object?>>[
        const <String, Object?>{'pid': 0},
        const <String, Object?>{'pid': 2147483648},
        const <String, Object?>{'windowId': -1},
        const <String, Object?>{'appId': 'Terminal'},
        const <String, Object?>{'appId': 'bad\n'},
        const <String, Object?>{'workspaceAlias': '.'},
        const <String, Object?>{'workspaceAlias': '..'},
        const <String, Object?>{'workspaceAlias': 'a..b'},
        const <String, Object?>{'workspaceAlias': r'a\b'},
        const <String, Object?>{'workspaceAlias': 'bad\n'},
        const <String, Object?>{'tabId': ''},
        <String, Object?>{'tabId': 'a' * 129},
        const <String, Object?>{'tabId': 'tab\x00id'},
        const <String, Object?>{'mcpServerId': 'BadServer'},
        const <String, Object?>{'protocolTaskId': ''},
        const <String, Object?>{'protocolTaskId': 'task\nid'},
        const <String, Object?>{'unknownKey': 'x'},
      ];
      for (final t in invalidTargets) {
        expect(
          () => XtpFrame.parse(jsonEncode(baseTimerRegister(target: t))),
          throwsA(
            isA<XtpProtocolException>()
                .having((e) => e.jsonRpcCode, 'code', -32602),
          ),
          reason: 'Target $t must fail with -32602',
        );
      }

      // JSON null values for optional target subfields are accepted and omitted in toJson()
      final nullTargetParsed = XtpFrame.parse(
        jsonEncode(
          baseTimerRegister(
            target: const <String, Object?>{
              'pid': null,
              'appId': null,
              'workspaceAlias': 'xuna_pet',
            },
          ),
        ),
      ) as XtpRequest;
      expect(
        (nullTargetParsed.typedParams as WatchRegisterParams).target.toJson(),
        equals(const <String, Object?>{'workspaceAlias': 'xuna_pet'}),
      );
    });

    test(
        'validates timing bounds and allows quiescenceSeconds > maxWaitSeconds',
        () {
      // quiescenceSeconds > maxWaitSeconds is explicitly permitted
      expect(
        () => XtpFrame.parse(
          jsonEncode(
            baseTimerRegister(quiescenceSeconds: 60, maxWaitSeconds: 10),
          ),
        ),
        returnsNormally,
      );

      for (final bad in <Map<String, int>>[
        {'q': 1, 'min': 0, 'max': 5},
        {'q': 121, 'min': 0, 'max': 5},
        {'q': 2, 'min': -1, 'max': 5},
        {'q': 2, 'min': 61, 'max': 100},
        {'q': 2, 'min': 0, 'max': 4},
        {'q': 2, 'min': 0, 'max': 901},
      ]) {
        expect(
          () => XtpFrame.parse(
            jsonEncode(
              baseTimerRegister(
                quiescenceSeconds: bad['q']!,
                minWaitSeconds: bad['min']!,
                maxWaitSeconds: bad['max']!,
              ),
            ),
          ),
          throwsA(
            isA<XtpProtocolException>()
                .having((e) => e.jsonRpcCode, 'code', -32602),
          ),
        );
      }
    });

    test('validates composite signals constraints', () {
      for (final badSignals in <Object?>[
        null,
        <String>['ui_quiescence'],
        <String>[
          'ui_quiescence',
          'process_idle',
          'fs_quiescence',
          'cdp_idle',
        ],
        <String>['ui_quiescence', 'timer'],
        <String>['ui_quiescence', 'ui_change'],
        <String>['ui_quiescence', 'protocol_async'],
      ]) {
        expect(
          () => XtpFrame.parse(
            jsonEncode(
              baseTimerRegister(
                mode: 'composite',
                includeSignals: true,
                signals: badSignals,
              ),
            ),
          ),
          throwsA(
            isA<XtpProtocolException>()
                .having((e) => e.jsonRpcCode, 'code', -32602),
          ),
        );
      }

      // Even explicit "signals": null on non-composite is forbidden
      expect(
        () => XtpFrame.parse(
          jsonEncode(
            baseTimerRegister(
              mode: 'timer',
              includeSignals: true,
              signals: null,
            ),
          ),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
    });

    test('validates watchRegister and watchCancel result payloads', () {
      // Mixing accepted=true with errorCode
      expect(
        () => XtpResponse(
          id: 1,
          result: const <String, Object?>{
            'schemaVersion': 1,
            'accepted': true,
            'watchId': validWatchId,
            'activeSignals': <String>['timer'],
            'eventDriven': true,
            'fallbackUsed': false,
            'errorCode': 'stopped',
          },
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      // accepted=false with activeSignals
      expect(
        () => XtpResponse(
          id: 1,
          result: const <String, Object?>{
            'schemaVersion': 1,
            'accepted': false,
            'watchId': validWatchId,
            'activeSignals': <String>['timer'],
            'errorCode': 'stopped',
          },
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      // invalid errorCode enum
      expect(
        () => XtpResponse(
          id: 1,
          result: const <String, Object?>{
            'schemaVersion': 1,
            'accepted': false,
            'watchId': validWatchId,
            'errorCode': 'not_a_valid_code',
          },
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
      // negative cancelledCount
      expect(
        () => XtpResponse.watchCancelResult(id: 1, cancelledCount: -1),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
    });

    test(
        'validates watchCancel null-id rule and watchEvent observedSignals/errorCode',
        () {
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 810,
            'method': 'xuna/watchCancel',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': null,
              'jobId': null,
              'reason': 'owner_cancel',
            },
          }),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );

      // settled with empty observedSignals -> -32602
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/watchEvent',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': validWatchId,
              'jobId': validJobId,
              'kind': 'settled',
              'observedSignals': <String>[],
              'elapsedSeconds': 3,
              'changeCount': 0,
              'digestChanged': false,
              'occurredAt': '2026-11-22T12:45:00Z',
            },
          }),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );

      // error with invalid errorCode format -> -32602
      expect(
        () => XtpFrame.parse(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'method': 'xuna/watchEvent',
            'params': <String, Object?>{
              'schemaVersion': 1,
              'watchId': validWatchId,
              'jobId': validJobId,
              'kind': 'error',
              'observedSignals': <String>[],
              'elapsedSeconds': 3,
              'changeCount': 0,
              'digestChanged': false,
              'occurredAt': '2026-11-22T12:45:00Z',
              'errorCode': 'Bad\nCode',
            },
          }),
        ),
        throwsA(
          isA<XtpProtocolException>()
              .having((e) => e.jsonRpcCode, 'code', -32602),
        ),
      );
    });
  });
}

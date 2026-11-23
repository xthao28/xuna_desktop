import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/browser_bridge/cdp_browser_engine_provider.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/watch/cdp_watch_signal_driver.dart';
import 'package:xuna_desktop/features/watch/local_watch_sentinel.dart';
import 'package:xuna_desktop/features/watch/watch_convergence.dart';
import 'package:xuna_desktop/features/watch/watch_signal_driver.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _VirtualTimer implements WatchCancellableTimer {
  _VirtualTimer(this.fireAt, this.onFire);

  final DateTime fireAt;
  final void Function() onFire;
  bool cancelled = false;
  bool fired = false;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  void cancel() {
    cancelled = true;
  }
}

class _VirtualClock {
  _VirtualClock(DateTime start) : _now = start.toUtc();
  DateTime _now;
  final List<_VirtualTimer> timers = <_VirtualTimer>[];

  DateTime now() => _now;

  WatchCancellableTimer createTimer(Duration delay, void Function() onFire) {
    final timer = _VirtualTimer(_now.add(delay), onFire);
    timers.add(timer);
    return timer;
  }

  void advance(Duration delta) {
    final target = _now.add(delta);
    while (true) {
      _VirtualTimer? next;
      for (final t in timers) {
        if (!t.isActive || t.fireAt.isAfter(target)) continue;
        if (next == null || t.fireAt.isBefore(next.fireAt)) {
          next = t;
        }
      }
      if (next == null) break;
      _now = next.fireAt;
      next.fired = true;
      next.onFire();
    }
    _now = target;
  }
}

void main() {
  const jobId = 'a2222222-2222-4222-8222-222222222222';
  String watchUuid(int n) =>
      'f1111111-1111-4111-8111-${n.toString().padLeft(12, '0')}';

  late ContentFreeLogger logger;
  late EmergencyStopController stopController;

  setUp(() {
    logger = ContentFreeLogger();
    stopController = EmergencyStopController(logger: logger);
  });

  tearDown(() async {
    await stopController.dispose();
  });

  group('CdpWatchSignalDriver & CdpBrowserEngineProvider.openTabWatchSession', () {
    test(
      'targets exact tabId, enables DOM/Network, tracks redirect inflightIds, DOM.documentUpdated, and settles cleanly',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));

          final socketsByTab = <String, WebSocket>{};
          final receivedMethodsByTab = <String, List<String>>{
            'tab-1': <String>[],
            'tab-2': <String>[],
          };
          final tab2Connected = Completer<void>();

          server.listen((HttpRequest req) async {
            if (req.uri.path == '/json/list') {
              req.response.statusCode = 200;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'tab-1',
                    'type': 'page',
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${server.port}/devtools/page/tab-1',
                  },
                  <String, Object?>{
                    'id': 'tab-2',
                    'type': 'page',
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${server.port}/devtools/page/tab-2',
                  },
                ]),
              );
              await req.response.close();
              return;
            }
            if (req.uri.path.startsWith('/devtools/page/') &&
                WebSocketTransformer.isUpgradeRequest(req)) {
              final tab = req.uri.pathSegments.last;
              final socket = await WebSocketTransformer.upgrade(req);
              socketsByTab[tab] = socket;
              if (tab == 'tab-2' && !tab2Connected.isCompleted) {
                tab2Connected.complete();
              }
              socket.listen((dynamic raw) {
                final msg = jsonDecode(raw as String) as Map<String, Object?>;
                final id = msg['id'] as int;
                final method = msg['method'] as String;
                receivedMethodsByTab[tab]?.add(method);
                socket.add(
                  jsonEncode(<String, Object?>{
                    'id': id,
                    'result': const <String, Object?>{},
                  }),
                );
              });
              return;
            }
            req.response.statusCode = 404;
            await req.response.close();
          });

          final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 12));
          final cdpProvider = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://127.0.0.1:${server.port}',
            autoLaunchBrowser: false,
          );
          final driver = CdpWatchSignalDriver(
            cdpProvider: cdpProvider,
            logger: logger,
          );
          final sentinel = LocalWatchSentinel(
            stopController: stopController,
            logger: logger,
            drivers: <WatchSignalDriver>[driver],
            now: clock.now,
            timerFactory: clock.createTimer,
          );
          addTearDown(sentinel.dispose);

          final events = <WatchEventParams>[];
          final sub = sentinel.events.listen(events.add);
          addTearDown(sub.cancel);

          // Missing tabId fails closed with target_not_found (no first-tab fallback).
          final missingOutcome = await sentinel.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(1),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-missing'),
              quiescenceSeconds: 3,
              minWaitSeconds: 0,
              maxWaitSeconds: 20,
              requireInitialChange: true,
              releaseFocus: true,
            ),
          );
          expect(missingOutcome.accepted, isFalse);
          expect(
            missingOutcome.errorCode,
            equals(WatchRejectErrorCode.targetNotFound),
          );
          expect(socketsByTab.containsKey('tab-1'), isFalse);

          // Exact match on tab-2 succeeds.
          final okOutcome = await sentinel.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(2),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-2'),
              quiescenceSeconds: 3,
              minWaitSeconds: 0,
              maxWaitSeconds: 20,
              requireInitialChange: true,
              releaseFocus: true,
            ),
          );
          expect(okOutcome.accepted, isTrue);
          expect(okOutcome.eventDriven, isTrue);
          expect(okOutcome.fallbackUsed, isFalse);
          await tab2Connected.future;
          expect(
            receivedMethodsByTab['tab-2'],
            equals(const <String>['DOM.enable', 'Network.enable']),
          );
          expect(receivedMethodsByTab['tab-1'], isEmpty);

          final tab2Socket = socketsByTab['tab-2']!;

          // Request starts + HTTP redirect reuses same requestId.
          tab2Socket.add(
            jsonEncode(<String, Object?>{
              'method': 'Network.requestWillBeSent',
              'params': <String, Object?>{'requestId': 'req-1'},
            }),
          );
          tab2Socket.add(
            jsonEncode(<String, Object?>{
              'method': 'Network.requestWillBeSent',
              'params': <String, Object?>{'requestId': 'req-1'},
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));

          // DOM update while request still in-flight sets digestChanged/changeCount
          // while staying active so advancing 3s does NOT settle yet.
          tab2Socket.add(
            jsonEncode(<String, Object?>{
              'method': 'DOM.documentUpdated',
              'params': const <String, Object?>{},
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          clock.advance(const Duration(seconds: 4));
          await Future<void>.delayed(Duration.zero);
          expect(events, isEmpty);

          // Single loadingFinished clears redirected req-1 -> idle -> settles after 3s.
          tab2Socket.add(
            jsonEncode(<String, Object?>{
              'method': 'Network.loadingFinished',
              'params': <String, Object?>{'requestId': 'req-1'},
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          clock.advance(const Duration(seconds: 3));
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(events, hasLength(1));
          expect(events.single.kind, equals(WatchEventKind.settled));
          expect(events.single.digestChanged, isTrue);
          expect(events.single.changeCount, greaterThanOrEqualTo(1));
        }, _RealHttpOverrides());
      },
    );

    test(
      'fails closed watch_unsupported when CDP endpoint unreachable or non-loopback, and emits target_lost on unexpected close',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          // 1. Non-loopback CDP endpoint fails closed.
          final nonLoopbackProvider = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://192.168.1.50:9222',
            autoLaunchBrowser: true,
          );
          final sentinel1 = LocalWatchSentinel(
            stopController: stopController,
            logger: logger,
            drivers: <WatchSignalDriver>[
              CdpWatchSignalDriver(
                cdpProvider: nonLoopbackProvider,
                logger: logger,
              ),
            ],
          );
          addTearDown(sentinel1.dispose);

          final nonLoopRes = await sentinel1.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(3),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-1'),
              quiescenceSeconds: 3,
              minWaitSeconds: 0,
              maxWaitSeconds: 20,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          expect(nonLoopRes.accepted, isFalse);
          expect(
            nonLoopRes.errorCode,
            equals(WatchRejectErrorCode.watchUnsupported),
          );

          // 2. Unreachable loopback port fails closed (even when autoLaunchBrowser == true).
          final unusedPort = await (() async {
            final s = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
            final p = s.port;
            await s.close(force: true);
            return p;
          })();
          final unreachableProvider = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://127.0.0.1:$unusedPort',
            autoLaunchBrowser: true,
            connectTimeout: const Duration(milliseconds: 300),
          );
          final sentinel2 = LocalWatchSentinel(
            stopController: stopController,
            logger: logger,
            drivers: <WatchSignalDriver>[
              CdpWatchSignalDriver(
                cdpProvider: unreachableProvider,
                logger: logger,
              ),
            ],
          );
          addTearDown(sentinel2.dispose);

          final unreachRes = await sentinel2.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(4),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-1'),
              quiescenceSeconds: 3,
              minWaitSeconds: 0,
              maxWaitSeconds: 20,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          expect(unreachRes.accepted, isFalse);
          expect(
            unreachRes.errorCode,
            equals(WatchRejectErrorCode.watchUnsupported),
          );

          // 3. Unexpected WebSocket close emits target_lost, and E-Stop closes socket cleanly.
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));

          final tabSockets = <String, WebSocket>{};
          final tabClosed = <String, Completer<void>>{
            'tab-lost': Completer<void>(),
            'tab-estop': Completer<void>(),
          };

          server.listen((HttpRequest req) async {
            if (req.uri.path == '/json/list') {
              req.response.statusCode = 200;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'tab-lost',
                    'type': 'page',
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${server.port}/devtools/page/tab-lost',
                  },
                  <String, Object?>{
                    'id': 'tab-estop',
                    'type': 'page',
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${server.port}/devtools/page/tab-estop',
                  },
                ]),
              );
              await req.response.close();
              return;
            }
            if (req.uri.path.startsWith('/devtools/page/') &&
                WebSocketTransformer.isUpgradeRequest(req)) {
              final tab = req.uri.pathSegments.last;
              final socket = await WebSocketTransformer.upgrade(req);
              tabSockets[tab] = socket;
              socket.listen(
                (dynamic raw) {
                  final msg = jsonDecode(raw as String) as Map<String, Object?>;
                  socket.add(
                    jsonEncode(<String, Object?>{
                      'id': msg['id'],
                      'result': const <String, Object?>{},
                    }),
                  );
                },
                onDone: () {
                  final c = tabClosed[tab];
                  if (c != null && !c.isCompleted) c.complete();
                },
              );
            }
          });

          final liveProvider = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://127.0.0.1:${server.port}',
          );
          final sentinel3 = LocalWatchSentinel(
            stopController: stopController,
            logger: logger,
            drivers: <WatchSignalDriver>[
              CdpWatchSignalDriver(cdpProvider: liveProvider, logger: logger),
            ],
          );
          addTearDown(sentinel3.dispose);

          final events = <WatchEventParams>[];
          final sub = sentinel3.events.listen(events.add);
          addTearDown(sub.cancel);

          await sentinel3.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(5),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-lost'),
              quiescenceSeconds: 4,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          await tabSockets['tab-lost']!.close();
          await Future<void>.delayed(const Duration(milliseconds: 40));
          expect(events, hasLength(1));
          expect(events.single.kind, equals(WatchEventKind.targetLost));

          await sentinel3.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(6),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-estop'),
              quiescenceSeconds: 4,
              minWaitSeconds: 0,
              maxWaitSeconds: 30,
              requireInitialChange: false,
              releaseFocus: true,
            ),
          );
          expect(sentinel3.activeWatchCount, equals(1));
          stopController.triggerStop(StopReason.ownerHost);
          await tabClosed['tab-estop']!.future.timeout(
            const Duration(seconds: 2),
          );
          expect(sentinel3.activeWatchCount, equals(0));
        }, _RealHttpOverrides());
      },
    );

    test(
      'SPA/network-only sequence without DOM.documentUpdated settles cleanly under requireInitialChange: true',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));

          WebSocket? tabSocket;
          final tabConnected = Completer<void>();

          server.listen((HttpRequest req) async {
            if (req.uri.path == '/json/list') {
              req.response.statusCode = 200;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'tab-spa',
                    'type': 'page',
                    'webSocketDebuggerUrl':
                        'ws://127.0.0.1:${server.port}/devtools/page/tab-spa',
                  },
                ]),
              );
              await req.response.close();
              return;
            }
            if (req.uri.path == '/devtools/page/tab-spa' &&
                WebSocketTransformer.isUpgradeRequest(req)) {
              final socket = await WebSocketTransformer.upgrade(req);
              tabSocket = socket;
              if (!tabConnected.isCompleted) {
                tabConnected.complete();
              }
              socket.listen((dynamic raw) {
                final msg = jsonDecode(raw as String) as Map<String, Object?>;
                socket.add(
                  jsonEncode(<String, Object?>{
                    'id': msg['id'],
                    'result': const <String, Object?>{},
                  }),
                );
              });
              return;
            }
            req.response.statusCode = 404;
            await req.response.close();
          });

          final clock = _VirtualClock(DateTime.utc(2026, 11, 22, 14));
          final cdpProvider = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://127.0.0.1:${server.port}',
            autoLaunchBrowser: false,
          );
          final sentinel = LocalWatchSentinel(
            stopController: stopController,
            logger: logger,
            drivers: <WatchSignalDriver>[
              CdpWatchSignalDriver(cdpProvider: cdpProvider, logger: logger),
            ],
            now: clock.now,
            timerFactory: clock.createTimer,
          );
          addTearDown(sentinel.dispose);

          final events = <WatchEventParams>[];
          final sub = sentinel.events.listen(events.add);
          addTearDown(sub.cancel);

          final outcome = await sentinel.registerWatch(
            WatchRegisterParams(
              watchId: watchUuid(7),
              jobId: jobId,
              mode: WatchMode.cdpIdle,
              target: const WatchTarget(tabId: 'tab-spa'),
              quiescenceSeconds: 3,
              minWaitSeconds: 0,
              maxWaitSeconds: 20,
              requireInitialChange: true,
              releaseFocus: true,
            ),
          );
          expect(outcome.accepted, isTrue);
          await tabConnected.future;

          // Network request starts without DOM.documentUpdated.
          tabSocket!.add(
            jsonEncode(<String, Object?>{
              'method': 'Network.requestWillBeSent',
              'params': <String, Object?>{'requestId': 'spa-req-1'},
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          clock.advance(const Duration(seconds: 4));
          await Future<void>.delayed(Duration.zero);
          expect(events, isEmpty);

          // Network finishes (still no DOM.documentUpdated): active -> changed,
          // then settles after quiescenceSeconds without hitting maxWaitSeconds.
          tabSocket!.add(
            jsonEncode(<String, Object?>{
              'method': 'Network.loadingFinished',
              'params': <String, Object?>{'requestId': 'spa-req-1'},
            }),
          );
          await Future<void>.delayed(const Duration(milliseconds: 20));
          clock.advance(const Duration(seconds: 3));
          await Future<void>.delayed(const Duration(milliseconds: 20));

          expect(events, hasLength(1));
          expect(events.single.kind, equals(WatchEventKind.settled));
          expect(events.single.digestChanged, isFalse);
          expect(events.single.changeCount, greaterThanOrEqualTo(1));
        }, _RealHttpOverrides());
      },
    );
  });
}

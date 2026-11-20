import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/fake_xuna_host_channel.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/browser_bridge/browser_engine_provider.dart';
import 'package:xuna_desktop/features/browser_bridge/cdp_browser_engine_provider.dart';
import 'package:xuna_desktop/features/browser_bridge/fake_browser_engine_provider.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

HostPolicy _buildBrowserTestPolicy() => HostPolicy(
  schemaVersion: 1,
  trustPreset: TrustPreset.standard,
  families: const <ToolFamily, FamilyPolicyDecision>{
    ToolFamily.url: FamilyPolicyDecision.allow,
    ToolFamily.host: FamilyPolicyDecision.allow,
    ToolFamily.app: FamilyPolicyDecision.allow,
  },
  apps: const <AllowedAppConfig>[],
  urlDomains: const <String>['example.com', 'shop.vietnam.vn'],
  workflows: const <WorkflowConfig>[],
  players: const <String>[],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CdpBrowserEngineProvider — Fail-Closed Rules (Rule H1)', () {
    final provider = CdpBrowserEngineProvider();

    test(
      'fails closed with browser_engine_not_available on all 7 browser tools',
      () async {
        await expectLater(
          () => provider.navigate(url: 'https://example.com'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.snapshot(),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.click(ref: 'e1'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.fill(ref: 'e2', value: 'test'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.select(ref: 'e4', value: 'relevance'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.extract(ref: 'e1'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );

        await expectLater(
          () => provider.waitFor(selector: '#btn-submit'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'browser_engine_not_available',
            ),
          ),
        );
      },
    );
  });

  group('FakeBrowserEngineProvider — Deterministic Test Harness', () {
    late FakeBrowserEngineProvider fake;

    setUp(() {
      fake = FakeBrowserEngineProvider();
    });

    test(
      'snapshot on unloaded browser fails closed with no_page_loaded',
      () async {
        await expectLater(
          () => fake.snapshot(),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'no_page_loaded',
            ),
          ),
        );
      },
    );

    test(
      'navigate sets URL and generates compact ARIA snapshot <= 6144 bytes',
      () async {
        final nav = await fake.navigate(url: 'https://example.com/products');
        expect(nav['url'], 'https://example.com/products');
        expect(nav['loaded'], isTrue);
        expect(fake.recordedCalls.length, 1);

        final snap = await fake.snapshot(maxBytes: 6144);
        expect(snap['url'], 'https://example.com/products');
        expect(snap['compactAriaTree'], contains('Main Heading'));
        expect(snap['compactAriaTree'], contains('Checkout & Pay'));
        expect(
          utf8.encode(snap['compactAriaTree'] as String).length <= 6144,
          isTrue,
        );
        expect(snap['elementCount'], 5);
      },
    );

    test(
      'click, fill, select modify element state deterministically',
      () async {
        await fake.navigate(url: 'https://example.com');

        // Click
        final clickRes = await fake.click(ref: 'e3', selector: '#btn-search');
        expect(clickRes['clicked'], isTrue);
        expect(clickRes['ref'], 'e3');

        // Fill
        final fillRes = await fake.fill(ref: 'e2', value: 'Bàn phím cơ');
        expect(fillRes['filled'], isTrue);
        expect(fillRes['valueLength'], 'Bàn phím cơ'.length);

        // Verify filled value reflects in snapshot
        final snap = await fake.snapshot();
        expect(snap['compactAriaTree'], contains('value="Bàn phím cơ"'));

        // Select
        final selRes = await fake.select(ref: 'e4', value: 'price_asc');
        expect(selRes['selected'], isTrue);
        expect(selRes['selectedValue'], 'price_asc');
      },
    );

    test('missing element throws element_not_found (Rule H3)', () async {
      await fake.navigate(url: 'https://example.com');

      await expectLater(
        () => fake.click(ref: 'nonexistent-ref'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_found',
          ),
        ),
      );

      await expectLater(
        () => fake.fill(ref: 'nonexistent-ref', value: 'test'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_found',
          ),
        ),
      );

      await expectLater(
        () => fake.select(ref: 'nonexistent-ref', value: 'opt'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'element_not_found',
          ),
        ),
      );
    });

    test('extract extracts text and attributes or page info', () async {
      fake.loadFixturePage(
        url: 'https://example.com/article',
        title: 'Tech News',
        fixtureElements: <SimulatedDomElement>[
          SimulatedDomElement(
            ref: 'link1',
            role: 'link',
            name: 'Read More',
            selector: 'a.read-more',
            attributes: const <String, String>{
              'href': 'https://example.com/full-story',
            },
          ),
        ],
      );

      // Extract attribute
      final attrRes = await fake.extract(ref: 'link1', attribute: 'href');
      expect(attrRes['value'], 'https://example.com/full-story');

      // Extract text
      final textRes = await fake.extract(ref: 'link1');
      expect(textRes['value'], 'Read More');

      // Extract general page info
      final pageRes = await fake.extract();
      expect(pageRes['title'], 'Tech News');
      expect(pageRes['elementCount'], 1);
    });

    test(
      'waitFor succeeds on standard selectors and times out on nonexistent (Rule H4)',
      () async {
        await fake.navigate(url: 'https://example.com');

        final waitRes = await fake.waitFor(
          selector: '#btn-search',
          state: 'visible',
        );
        expect(waitRes['satisfied'], isTrue);

        await expectLater(
          () => fake.waitFor(selector: '#nonexistent-modal', state: 'visible'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'timeout',
            ),
          ),
        );
      },
    );
  });

  group('HostToolDispatcher — Browser Tools Integration & Execution Lanes', () {
    late Directory tempDir;
    late AgentPaths paths;
    late HostPolicyStore policyStore;
    late FakeBrowserEngineProvider fakeBrowser;
    late HostToolDispatcher dispatcher;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('browser_bridge_test_');
      paths = AgentPaths(rootDir: tempDir);
      await paths.ensureDirectories();

      final logger = ContentFreeLogger();
      await paths.policyFile.writeAsString(
        jsonEncode(_buildBrowserTestPolicy().toJson()),
      );
      policyStore = HostPolicyStore(
        policyFile: paths.policyFile,
        logger: logger,
      );
      await policyStore.reload();

      fakeBrowser = FakeBrowserEngineProvider();
      dispatcher = HostToolDispatcher(
        policyStore: policyStore,
        channel: FakeXunaHostChannel(),
        auditStore: AuditLogStore(auditDir: paths.auditDir),
        stopController: EmergencyStopController(logger: logger),
        logger: logger,
        browserEngineProvider: fakeBrowser,
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    ApprovalToken approval(Map<String, Object?> args) => ApprovalToken(
      approvalId: '11111111-1111-4111-8111-111111111111',
      scope: 'once',
      argsSha256: argsSha256(args),
      expiresAt: DateTime.utc(2030, 1, 1),
    );

    test('registers all 7 web tools in buildManifest', () async {
      final manifest = await dispatcher.buildManifest();
      final names = manifest.map((t) => t.name).toSet();

      expect(
        names,
        containsAll(<String>[
          'web.navigate',
          'web.snapshot',
          'web.click',
          'web.fill',
          'web.select',
          'web.extract',
          'web.wait_for',
        ]),
      );
    });

    test(
      'routes read-only tools to ParallelReadLane and mutating tools to SerialActionLane',
      () async {
        expect(dispatcher.parallelReadLaneCount, 0);
        expect(dispatcher.serialActionLaneCount, 0);

        // 1. web.navigate (mutating -> serial)
        const navArgs = <String, Object?>{'url': 'https://example.com'};
        final navRes = await dispatcher.dispatch(
          requestId: 1,
          params: ToolsCallParams(
            name: 'web.navigate',
            arguments: navArgs,
            invocationId: 'inv-1',
            deadlineMs: 5000,
            approval: approval(navArgs),
          ),
        );
        final navMeta = (navRes.result['_meta'] as Map).cast<String, Object?>();
        expect(navMeta['xuna/status'], 'ok');
        expect(dispatcher.serialActionLaneCount, 1);
        expect(dispatcher.parallelReadLaneCount, 0);

        // 2. web.snapshot (read-only -> parallel)
        final snapRes = await dispatcher.dispatch(
          requestId: 2,
          params: const ToolsCallParams(
            name: 'web.snapshot',
            arguments: <String, Object?>{'compact': true},
            invocationId: 'inv-2',
            deadlineMs: 5000,
          ),
        );
        final snapMeta = (snapRes.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(snapMeta['xuna/status'], 'ok');
        expect(dispatcher.parallelReadLaneCount, 1);
        expect(dispatcher.serialActionLaneCount, 1);

        // 3. web.click (mutating -> serial)
        const clickArgs = <String, Object?>{'ref': 'e3'};
        final clickRes = await dispatcher.dispatch(
          requestId: 3,
          params: ToolsCallParams(
            name: 'web.click',
            arguments: clickArgs,
            invocationId: 'inv-3',
            deadlineMs: 5000,
            approval: approval(clickArgs),
          ),
        );
        final clickMeta = (clickRes.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(clickMeta['xuna/status'], 'ok');
        expect(dispatcher.serialActionLaneCount, 2);
        expect(dispatcher.parallelReadLaneCount, 1);

        // 4. web.extract (read-only -> parallel)
        final extractRes = await dispatcher.dispatch(
          requestId: 4,
          params: const ToolsCallParams(
            name: 'web.extract',
            arguments: <String, Object?>{'ref': 'e1'},
            invocationId: 'inv-4',
            deadlineMs: 5000,
          ),
        );
        final extractMeta = (extractRes.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(extractMeta['xuna/status'], 'ok');
        expect(dispatcher.parallelReadLaneCount, 2);
        expect(dispatcher.serialActionLaneCount, 2);

        // 5. web.wait_for (read-only -> parallel)
        final waitRes = await dispatcher.dispatch(
          requestId: 5,
          params: const ToolsCallParams(
            name: 'web.wait_for',
            arguments: <String, Object?>{'selector': '#btn-search'},
            invocationId: 'inv-5',
            deadlineMs: 5000,
          ),
        );
        final waitMeta = (waitRes.result['_meta'] as Map)
            .cast<String, Object?>();
        expect(waitMeta['xuna/status'], 'ok');
        expect(dispatcher.parallelReadLaneCount, 3);
        expect(dispatcher.serialActionLaneCount, 2);
      },
    );

    test('preserves error codes end-to-end (Rule H4)', () async {
      await fakeBrowser.navigate(url: 'https://example.com');

      fakeBrowser.nextException = const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'custom_browser_crash',
        message: 'Chromium tab crashed unexpectedly.',
      );

      final res = await dispatcher.dispatch(
        requestId: 10,
        params: const ToolsCallParams(
          name: 'web.snapshot',
          arguments: <String, Object?>{},
          invocationId: 'inv-crash',
          deadlineMs: 5000,
        ),
      );

      final meta = (res.result['_meta'] as Map).cast<String, Object?>();
      expect(meta['xuna/status'], 'failed');
      expect(meta['xuna/errorCode'], 'custom_browser_crash');
    });
  });

  group('CdpBrowserEngineProvider — Live Loopback CDP HTTP + WebSocket', () {
    test(
      'drives navigate, snapshot, click, fill, select, extract, waitFor and fail-closed rules over real CDP WebSocket',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          var currentUrl = 'about:blank';
          var currentTitle = '';
          var inputValue = '';
          var selectedSort = 'relevance';
          var clickedRef = '';

          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          addTearDown(() => server.close(force: true));
          final wsUrl = 'ws://127.0.0.1:${server.port}/devtools/page/tab-1';

          server.listen((HttpRequest req) async {
            if (req.uri.path == '/json/list') {
              req.response.statusCode = 200;
              req.response.headers.contentType = ContentType.json;
              req.response.write(
                jsonEncode(<Map<String, Object?>>[
                  <String, Object?>{
                    'id': 'tab-1',
                    'type': 'page',
                    'url': currentUrl,
                    'webSocketDebuggerUrl': wsUrl,
                  },
                ]),
              );
              await req.response.close();
              return;
            }
            if (req.uri.path == '/devtools/page/tab-1' &&
                WebSocketTransformer.isUpgradeRequest(req)) {
              final socket = await WebSocketTransformer.upgrade(req);
              socket.listen((dynamic raw) {
                final msg = jsonDecode(raw as String) as Map<String, Object?>;
                final id = msg['id'] as int;
                final method = msg['method'] as String;
                final params =
                    (msg['params'] as Map?)?.cast<String, Object?>() ??
                    const <String, Object?>{};

                if (method == 'Page.enable') {
                  socket.add(
                    jsonEncode(<String, Object?>{
                      'id': id,
                      'result': const <String, Object?>{},
                    }),
                  );
                } else if (method == 'Page.navigate') {
                  currentUrl = params['url'] as String;
                  currentTitle = 'XUNA Docs';
                  socket.add(
                    jsonEncode(<String, Object?>{
                      'id': id,
                      'result': <String, Object?>{'frameId': 'frame-1'},
                    }),
                  );
                } else if (method == 'Runtime.evaluate') {
                  final expr = params['expression'] as String;
                  Map<String, Object?> value;
                  if (expr.contains('document.readyState')) {
                    value = <String, Object?>{
                      'href': currentUrl,
                      'title': currentTitle,
                      'ready': currentUrl != 'about:blank',
                    };
                  } else if (expr.contains('no_page_loaded') &&
                      expr.contains('candidates')) {
                    if (currentUrl == 'about:blank') {
                      value = <String, Object?>{'error': 'no_page_loaded'};
                    } else {
                      value = <String, Object?>{
                        'url': currentUrl,
                        'title': currentTitle,
                        'elements': <Map<String, Object?>>[
                          <String, Object?>{
                            'ref': 'e1',
                            'role': 'textbox',
                            'name': 'Search Docs',
                            'selector': '#q',
                            'value': inputValue,
                            'options': const <String>[],
                            'actionable': true,
                            'isPassword': false,
                          },
                          <String, Object?>{
                            'ref': 'e2',
                            'role': 'password',
                            'name': '[REDACTED_PASSWORD_FIELD]',
                            'selector': '#pwd',
                            'value': '[REDACTED]',
                            'options': const <String>[],
                            'actionable': true,
                            'isPassword': true,
                          },
                          <String, Object?>{
                            'ref': 'e3',
                            'role': 'combobox',
                            'name': 'Sort',
                            'selector': '#sort',
                            'value': selectedSort,
                            'options': const <String>['relevance', 'newest'],
                            'actionable': true,
                            'isPassword': false,
                          },
                          <String, Object?>{
                            'ref': 'e4',
                            'role': 'button',
                            'name': 'Checkout & Pay',
                            'selector': '#pay',
                            'value': null,
                            'options': const <String>[],
                            'actionable': true,
                            'isPassword': false,
                          },
                        ],
                      };
                    }
                  } else if (expr.contains("action: 'click'")) {
                    if (expr.contains('"e99"')) {
                      value = <String, Object?>{'error': 'element_not_found'};
                    } else {
                      clickedRef = 'e4';
                      value = <String, Object?>{
                        'ref': 'e4',
                        'role': 'button',
                        'clicked': true,
                        'action': 'click',
                        'pageTitle': currentTitle,
                      };
                    }
                  } else if (expr.contains('password_field_forbidden')) {
                    if (expr.contains('"e2"')) {
                      value = <String, Object?>{
                        'error': 'password_field_forbidden',
                      };
                    } else {
                      inputValue = 'xuna protocol';
                      value = <String, Object?>{
                        'ref': 'e1',
                        'filled': true,
                        'valueLength': inputValue.length,
                      };
                    }
                  } else if (expr.contains('invalid_select_element')) {
                    selectedSort = 'newest';
                    value = <String, Object?>{
                      'ref': 'e3',
                      'selected': true,
                      'value': 'newest',
                      'selectedValue': 'newest',
                    };
                  } else if (expr.contains('extracted: true')) {
                    value = <String, Object?>{
                      'title': currentTitle,
                      'url': currentUrl,
                      'elementCount': 4,
                      'content': 'Welcome to XUNA Docs',
                      'extracted': true,
                    };
                  } else {
                    value = <String, Object?>{'ok': !expr.contains('#missing')};
                  }
                  socket.add(
                    jsonEncode(<String, Object?>{
                      'id': id,
                      'result': <String, Object?>{
                        'result': <String, Object?>{
                          'type': 'object',
                          'value': value,
                        },
                      },
                    }),
                  );
                }
              });
            }
          });

          final cdp = CdpBrowserEngineProvider(
            cdpEndpoint: 'http://127.0.0.1:${server.port}',
            connectTimeout: const Duration(seconds: 2),
          );

          // 1. Snapshot before navigate fails closed with no_page_loaded
          await expectLater(
            () => cdp.snapshot(),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'no_page_loaded',
              ),
            ),
          );

          // 2. Navigate to public https URL
          final nav = await cdp.navigate(url: 'https://docs.example.com/guide');
          expect(nav['loaded'], isTrue);
          expect(nav['title'], 'XUNA Docs');

          // 3. Snapshot redacts password and marks consequential controls
          final snap = await cdp.snapshot(maxBytes: 6144);
          expect(snap['elementCount'], 4);
          expect(
            snap['compactAriaTree'],
            contains('[e1] textbox "Search Docs"'),
          );
          expect(snap['compactAriaTree'], contains('[consequential]'));
          expect(utf8.encode(jsonEncode(snap)).length <= 6144, isTrue);

          // 4. Fill password field is refused fail-closed
          await expectLater(
            () => cdp.fill(ref: 'e2', value: 'secret'),
            throwsA(
              isA<XunaHostChannelException>()
                  .having((e) => e.status, 'status', XtpStatus.denied)
                  .having(
                    (e) => e.errorCode,
                    'errorCode',
                    'password_field_forbidden',
                  ),
            ),
          );

          // 5. Fill normal textbox, select option, click, extract, waitFor
          final fillRes = await cdp.fill(ref: 'e1', value: 'xuna protocol');
          expect(fillRes['filled'], isTrue);

          final selRes = await cdp.select(ref: 'e3', value: 'newest');
          expect(selRes['selectedValue'], 'newest');

          final clickRes = await cdp.click(ref: 'e4');
          expect(clickRes['clicked'], isTrue);
          expect(clickedRef, 'e4');

          await expectLater(
            () => cdp.click(ref: 'e99'),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'element_not_found',
              ),
            ),
          );

          final ext = await cdp.extract();
          expect(ext['content'], 'Welcome to XUNA Docs');

          final waited = await cdp.waitFor(selector: '#q', timeoutMs: 500);
          expect(waited['satisfied'], isTrue);

          await expectLater(
            () => cdp.waitFor(selector: '#missing', timeoutMs: 150),
            throwsA(
              isA<XunaHostChannelException>().having(
                (e) => e.errorCode,
                'errorCode',
                'timeout',
              ),
            ),
          );
        }, _RealHttpOverrides());
      },
    );

    test('refuses non-loopback CDP endpoint fail-closed', () async {
      final remote = CdpBrowserEngineProvider(
        cdpEndpoint: 'http://192.168.1.50:9222',
      );
      await expectLater(
        () => remote.navigate(url: 'https://example.com'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'browser_engine_not_available',
          ),
        ),
      );
    });
  });

  group('CdpBrowserEngineProvider — Live Loopback CDP HTTP + WebSocket', () {
    test('drives navigate, snapshot, click, fill, select, extract, waitFor and fail-closed rules over real CDP WebSocket', () async {
      await HttpOverrides.runWithHttpOverrides(() async {
        var currentUrl = 'about:blank';
        var currentTitle = '';
        var inputValue = '';
        var selectedSort = 'relevance';
        var clickedRef = '';

        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final wsUrl = 'ws://127.0.0.1:${server.port}/devtools/page/tab-1';

        server.listen((HttpRequest req) async {
          if (req.uri.path == '/json/list') {
            req.response.statusCode = 200;
            req.response.headers.contentType = ContentType.json;
            req.response.write(jsonEncode(<Map<String, Object?>>[
              <String, Object?>{
                'id': 'tab-1',
                'type': 'page',
                'url': currentUrl,
                'webSocketDebuggerUrl': wsUrl,
              },
            ]));
            await req.response.close();
            return;
          }
          if (req.uri.path == '/devtools/page/tab-1' &&
              WebSocketTransformer.isUpgradeRequest(req)) {
            final socket = await WebSocketTransformer.upgrade(req);
            socket.listen((dynamic raw) {
              final msg = jsonDecode(raw as String) as Map<String, Object?>;
              final id = msg['id'] as int;
              final method = msg['method'] as String;
              final params =
                  (msg['params'] as Map?)?.cast<String, Object?>() ??
                      const <String, Object?>{};

              if (method == 'Page.enable') {
                socket.add(jsonEncode(<String, Object?>{
                  'id': id,
                  'result': const <String, Object?>{},
                }));
              } else if (method == 'Page.navigate') {
                currentUrl = params['url'] as String;
                currentTitle = 'XUNA Docs';
                socket.add(jsonEncode(<String, Object?>{
                  'id': id,
                  'result': <String, Object?>{'frameId': 'frame-1'},
                }));
              } else if (method == 'Runtime.evaluate') {
                final expr = params['expression'] as String;
                Map<String, Object?> value;
                if (expr.contains('document.readyState')) {
                  value = <String, Object?>{
                    'href': currentUrl,
                    'title': currentTitle,
                    'ready': currentUrl != 'about:blank',
                  };
                } else if (expr.contains('no_page_loaded') &&
                    expr.contains('candidates')) {
                  if (currentUrl == 'about:blank') {
                    value = <String, Object?>{'error': 'no_page_loaded'};
                  } else {
                    value = <String, Object?>{
                      'url': currentUrl,
                      'title': currentTitle,
                      'elements': <Map<String, Object?>>[
                        <String, Object?>{
                          'ref': 'e1',
                          'role': 'textbox',
                          'name': 'Search Docs',
                          'selector': '#q',
                          'value': inputValue,
                          'options': const <String>[],
                          'actionable': true,
                          'isPassword': false,
                        },
                        <String, Object?>{
                          'ref': 'e2',
                          'role': 'password',
                          'name': '[REDACTED_PASSWORD_FIELD]',
                          'selector': '#pwd',
                          'value': '[REDACTED]',
                          'options': const <String>[],
                          'actionable': true,
                          'isPassword': true,
                        },
                        <String, Object?>{
                          'ref': 'e3',
                          'role': 'combobox',
                          'name': 'Sort',
                          'selector': '#sort',
                          'value': selectedSort,
                          'options': const <String>['relevance', 'newest'],
                          'actionable': true,
                          'isPassword': false,
                        },
                        <String, Object?>{
                          'ref': 'e4',
                          'role': 'button',
                          'name': 'Checkout & Pay',
                          'selector': '#pay',
                          'value': null,
                          'options': const <String>[],
                          'actionable': true,
                          'isPassword': false,
                        },
                      ],
                    };
                  }
                } else if (expr.contains("action: 'click'")) {
                  if (expr.contains('"e99"')) {
                    value = <String, Object?>{'error': 'element_not_found'};
                  } else {
                    clickedRef = 'e4';
                    value = <String, Object?>{
                      'ref': 'e4',
                      'role': 'button',
                      'clicked': true,
                      'action': 'click',
                      'pageTitle': currentTitle,
                    };
                  }
                } else if (expr.contains('password_field_forbidden')) {
                  if (expr.contains('"e2"')) {
                    value = <String, Object?>{
                      'error': 'password_field_forbidden',
                    };
                  } else {
                    inputValue = 'xuna protocol';
                    value = <String, Object?>{
                      'ref': 'e1',
                      'filled': true,
                      'valueLength': inputValue.length,
                    };
                  }
                } else if (expr.contains('invalid_select_element')) {
                  selectedSort = 'newest';
                  value = <String, Object?>{
                    'ref': 'e3',
                    'selected': true,
                    'value': 'newest',
                    'selectedValue': 'newest',
                  };
                } else if (expr.contains('extracted: true')) {
                  value = <String, Object?>{
                    'title': currentTitle,
                    'url': currentUrl,
                    'elementCount': 4,
                    'content': 'Welcome to XUNA Docs',
                    'extracted': true,
                  };
                } else {
                  value = <String, Object?>{'ok': !expr.contains('#missing')};
                }
                socket.add(jsonEncode(<String, Object?>{
                  'id': id,
                  'result': <String, Object?>{
                    'result': <String, Object?>{
                      'type': 'object',
                      'value': value,
                    },
                  },
                }));
              }
            });
          }
        });

        final cdp = CdpBrowserEngineProvider(
          cdpEndpoint: 'http://127.0.0.1:${server.port}',
          connectTimeout: const Duration(seconds: 2),
        );

        // 1. Snapshot before navigate fails closed with no_page_loaded
        await expectLater(
          () => cdp.snapshot(),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'no_page_loaded',
            ),
          ),
        );

        // 2. Navigate to public https URL
        final nav = await cdp.navigate(url: 'https://docs.example.com/guide');
        expect(nav['loaded'], isTrue);
        expect(nav['title'], 'XUNA Docs');

        // 3. Snapshot redacts password and marks consequential controls
        final snap = await cdp.snapshot(maxBytes: 6144);
        expect(snap['elementCount'], 4);
        expect(snap['compactAriaTree'], contains('[e1] textbox "Search Docs"'));
        expect(snap['compactAriaTree'], contains('[consequential]'));
        expect(utf8.encode(jsonEncode(snap)).length <= 6144, isTrue);

        // 4. Fill password field is refused fail-closed
        await expectLater(
          () => cdp.fill(ref: 'e2', value: 'secret'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'password_field_forbidden'),
          ),
        );

        // 5. Fill normal textbox, select option, click, extract, waitFor
        final fillRes = await cdp.fill(ref: 'e1', value: 'xuna protocol');
        expect(fillRes['filled'], isTrue);

        final selRes = await cdp.select(ref: 'e3', value: 'newest');
        expect(selRes['selectedValue'], 'newest');

        final clickRes = await cdp.click(ref: 'e4');
        expect(clickRes['clicked'], isTrue);
        expect(clickedRef, 'e4');

        await expectLater(
          () => cdp.click(ref: 'e99'),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'element_not_found',
            ),
          ),
        );

        final ext = await cdp.extract();
        expect(ext['content'], 'Welcome to XUNA Docs');

        final waited = await cdp.waitFor(selector: '#q', timeoutMs: 500);
        expect(waited['satisfied'], isTrue);

        await expectLater(
          () => cdp.waitFor(selector: '#missing', timeoutMs: 150),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'timeout',
            ),
          ),
        );
      }, _RealHttpOverrides());
    });

    test('refuses non-loopback CDP endpoint fail-closed', () async {
      final remote = CdpBrowserEngineProvider(
        cdpEndpoint: 'http://192.168.1.50:9222',
      );
      await expectLater(
        () => remote.navigate(url: 'https://example.com'),
        throwsA(
          isA<XunaHostChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            'browser_engine_not_available',
          ),
        ),
      );
    });
  });
}

class _RealHttpOverrides extends HttpOverrides {}

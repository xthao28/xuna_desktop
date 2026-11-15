import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

String _findDartExecutable() {
  final exec = Platform.resolvedExecutable;
  if (exec.toLowerCase().contains('dart') && !exec.toLowerCase().contains('flutter_tester')) {
    return exec;
  }
  final exeSuffix = Platform.isWindows ? '.exe' : '';
  final engineFile = File(exec);
  final dartCandidate = File(
    '${engineFile.parent.parent.parent.path}${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin${Platform.pathSeparator}dart$exeSuffix',
  );
  if (dartCandidate.existsSync()) {
    return dartCandidate.path;
  }
  return Platform.isWindows ? 'dart.bat' : 'dart';
}

void main() {
  group('AutoMcpBridge — Real MCP Client Hub & Anti-SSRF (Wave D Feature 7)', () {
    test('boundToolOutput bounds output to at most MAX_TOOL_OUTPUT_BYTES (6144)', () {
      expect(AutoMcpBridge.MAX_TOOL_OUTPUT_BYTES, equals(6144));
      final shortStr = 'Hello World';
      expect(AutoMcpBridge.boundToolOutput(shortStr), equals(shortStr));

      final hugeStr = 'A' * 10000;
      final bounded = AutoMcpBridge.boundToolOutput(hugeStr);
      expect(utf8.encode(bounded).length, lessThanOrEqualTo(6144));
      expect(bounded.length, equals(6144));
    });

    test('sanitizeServerId normalizes keys safely', () {
      expect(AutoMcpBridge.sanitizeServerId('my_mcp_server'), equals('my_mcp_server'));
      expect(AutoMcpBridge.sanitizeServerId('My MCP Server!@#'), equals('my_mcp_server'));
      expect(AutoMcpBridge.sanitizeServerId(''), equals('mcp_server'));
    });

    group('Anti-SSRF HTTP Filtering', () {
      final bridge = AutoMcpBridge();

      test('blocks loopback IPv4 127.0.0.1 with ssrf_blocked', () async {
        const server = DiscoveredMcpServer(
          id: 'test_http',
          transport: 'http',
          source: 'test',
          url: 'http://127.0.0.1:8080/mcp',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'ssrf_blocked'),
          ),
        );
      });

      test('blocks localhost literal with ssrf_blocked', () async {
        const server = DiscoveredMcpServer(
          id: 'test_localhost',
          transport: 'http',
          source: 'test',
          url: 'http://localhost:8080/mcp',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'ssrf_blocked'),
          ),
        );
      });

      test('blocks RFC 1918 192.168.1.1 with ssrf_blocked', () async {
        const server = DiscoveredMcpServer(
          id: 'test_rfc1918_192',
          transport: 'http',
          source: 'test',
          url: 'http://192.168.1.1:8080/mcp',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'ssrf_blocked'),
          ),
        );
      });

      test('blocks RFC 1918 10.0.0.1 with ssrf_blocked', () async {
        const server = DiscoveredMcpServer(
          id: 'test_rfc1918_10',
          transport: 'http',
          source: 'test',
          url: 'http://10.0.0.1:8080/mcp',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'ssrf_blocked'),
          ),
        );
      });

      test('blocks Cloud metadata IP 169.254.169.254 with ssrf_blocked', () async {
        const server = DiscoveredMcpServer(
          id: 'test_metadata',
          transport: 'http',
          source: 'test',
          url: 'http://169.254.169.254/latest/meta-data',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.denied)
                .having((e) => e.errorCode, 'errorCode', 'ssrf_blocked'),
          ),
        );
      });

      test('blocks invalid non-HTTP schemes with mcp_server_not_configured', () async {
        const server = DiscoveredMcpServer(
          id: 'test_file',
          transport: 'http',
          source: 'test',
          url: 'file:///etc/passwd',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.invalidArgs)
                .having((e) => e.errorCode, 'errorCode', 'mcp_server_not_configured'),
          ),
        );
      });
    });

    group('Stdio Security & Lifecycle', () {
      final bridge = AutoMcpBridge();

      test('refuses hard-denied commands with policy_blocked', () async {
        const blockedCommands = <String>[
          'powershell.exe',
          'cmd.exe',
          'bash',
          'zsh',
          'pwsh',
          'Terminal',
          'iTerm2',
        ];

        for (final cmd in blockedCommands) {
          final server = DiscoveredMcpServer(
            id: 'server_$cmd',
            transport: 'stdio',
            source: 'test',
            command: cmd,
          );

          expect(
            () => bridge.callTool(server: server, toolName: 'echo'),
            throwsA(
              isA<XunaHostChannelException>()
                  .having((e) => e.status, 'status', XtpStatus.denied)
                  .having((e) => e.errorCode, 'errorCode', 'policy_blocked'),
            ),
          );
        }
      });

      test('fails with mcp_server_not_configured when command is missing', () async {
        const server = DiscoveredMcpServer(
          id: 'empty_cmd',
          transport: 'stdio',
          source: 'test',
          command: '',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.invalidArgs)
                .having((e) => e.errorCode, 'errorCode', 'mcp_server_not_configured'),
          ),
        );
      });

      test('fails with mcp_connection_failed when command executable does not exist', () async {
        const server = DiscoveredMcpServer(
          id: 'nonexistent',
          transport: 'stdio',
          source: 'test',
          command: 'nonexistent_binary_xyz_12345',
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.failed)
                .having((e) => e.errorCode, 'errorCode', 'mcp_connection_failed'),
          ),
        );
      });
    });

    group('Real Stdio MCP Protocol End-to-End', () {
      late Directory tempDir;
      late File serverScript;
      late AutoMcpBridge bridge;

      setUpAll(() {
        tempDir = Directory.systemTemp.createTempSync('xuna_mcp_test_');
        serverScript = File('${tempDir.path}${Platform.pathSeparator}mcp_server.dart');
        serverScript.writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final mode = args.isNotEmpty ? args[0] : 'normal';

  if (mode == 'crash_handshake') {
    stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final req = jsonDecode(line) as Map<String, Object?>;
      final id = req['id'];
      print(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'error': {'code': -32600, 'message': 'Handshake rejected'}
      }));
    });
    return;
  }

  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    final req = jsonDecode(trimmed) as Map<String, Object?>;
    final id = req['id'];
    final method = req['method'];

    if (method == 'initialize') {
      print(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'protocolVersion': '2024-11-05',
          'capabilities': {'tools': {}},
          'serverInfo': {'name': 'mock-stdio-server', 'version': '1.0.0'}
        }
      }));
    } else if (method == 'notifications/initialized') {
      // Notification, no reply
    } else if (method == 'tools/list') {
      print(jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'result': {
          'tools': [
            {'name': 'query_notes', 'description': 'Query notes on disk'},
            {'name': 'echo', 'description': 'Echo arguments'}
          ]
        }
      }));
    } else if (method == 'tools/call') {
      final params = (req['params'] as Map).cast<String, Object?>();
      final toolName = params['name'] as String;
      final arguments = (params['arguments'] as Map?)?.cast<String, Object?>() ?? {};

      if (toolName == 'fail_tool') {
        print(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'isError': true,
            'content': [
              {'type': 'text', 'text': 'Internal failure'}
            ]
          }
        }));
      } else if (toolName == 'huge_output') {
        print(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': 'Z' * 12000}
            ]
          }
        }));
      } else if (toolName == 'secret_leak') {
        print(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': 'Here is sk-ant-api03-abcdef1234567890abcdef1234567890 leak'}
            ]
          }
        }));
      } else {
        print(jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'content': [
              {'type': 'text', 'text': 'Output: \${arguments['input'] ?? 'ok'}'}
            ]
          }
        }));
      }
    }
  });
}
''');
        bridge = AutoMcpBridge();
      });

      tearDownAll(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('completes full handshake and tool call successfully', () async {
        final server = DiscoveredMcpServer(
          id: 'test_stdio_mcp',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'normal'],
        );

        final res = await bridge.callTool(
          server: server,
          toolName: 'echo',
          payloadJson: jsonEncode({'input': 'hello_mcp'}),
        );

        expect(res, equals('Output: hello_mcp'));
      });

      test('listTools retrieves tool manifests via JSON-RPC', () async {
        final server = DiscoveredMcpServer(
          id: 'test_stdio_list',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'normal'],
        );

        final tools = await bridge.listTools(server);
        expect(tools.length, equals(2));
        expect(tools[0]['name'], equals('query_notes'));
        expect(tools[1]['name'], equals('echo'));
      });

      test('tool returning isError fails with mcp_tool_failed', () async {
        final server = DiscoveredMcpServer(
          id: 'test_stdio_fail',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'normal'],
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'fail_tool'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.failed)
                .having((e) => e.errorCode, 'errorCode', 'mcp_tool_failed'),
          ),
        );
      });

      test('truncates huge tool output to 6144 bytes', () async {
        final server = DiscoveredMcpServer(
          id: 'test_stdio_huge',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'normal'],
        );

        final res = await bridge.callTool(server: server, toolName: 'huge_output');
        expect(utf8.encode(res).length, lessThanOrEqualTo(6144));
        expect(res.length, equals(6144));
      });

      test('redacts secret tokens from tool output', () async {
        final server = DiscoveredMcpServer(
          id: 'test_stdio_secret',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'normal'],
        );

        final res = await bridge.callTool(server: server, toolName: 'secret_leak');
        expect(res, isNot(contains('sk-ant-api03-abcdef1234567890abcdef1234567890')));
        expect(res, contains('[REDACTED]'));
      });

      test('handshake failure fails with mcp_handshake_failed', () async {
        final server = DiscoveredMcpServer(
          id: 'test_handshake_err',
          transport: 'stdio',
          source: 'test',
          command: _findDartExecutable(),
          args: <String>[serverScript.path, 'crash_handshake'],
        );

        expect(
          () => bridge.callTool(server: server, toolName: 'echo'),
          throwsA(
            isA<XunaHostChannelException>()
                .having((e) => e.status, 'status', XtpStatus.failed)
                .having((e) => e.errorCode, 'errorCode', 'mcp_handshake_failed'),
          ),
        );
      });
    });

    group('Config Scanning & Secrets Stripping', () {
      late Directory tempDir;
      late File configFile;

      setUpAll(() {
        tempDir = Directory.systemTemp.createTempSync('xuna_mcp_config_');
        configFile = File('${tempDir.path}${Platform.pathSeparator}test_mcp.json');
        configFile.writeAsStringSync(jsonEncode(<String, Object?>{
          'mcpServers': <String, Object?>{
            'my_safe_server': <String, Object?>{
              'command': 'safe_tool_binary',
              'args': <String>['--flag', 'value'],
              'env': <String, Object?>{
                'API_KEY': 'SUPER_SECRET_KEY_123',
                'AUTH_TOKEN': 'SECRET_TOKEN_456',
              },
            },
            'powershell_server': <String, Object?>{
              'command': 'powershell.exe',
              'args': <String>['-c', 'dir'],
            },
            'http_remote': <String, Object?>{
              'url': 'https://api.example.com/mcp',
            },
          },
        }));
      });

      tearDownAll(() {
        try {
          tempDir.deleteSync(recursive: true);
        } catch (_) {}
      });

      test('discovers safe servers, skips denied commands, and strips env secrets', () {
        final bridge = AutoMcpBridge(
          customConfigPaths: <String>[configFile.path],
          scanDefaultLocations: false,
        );

        final servers = bridge.discoverServers();
        expect(servers.length, equals(2));

        final ids = servers.map((s) => s.id).toList();
        expect(ids, contains('http_remote'));
        expect(ids, contains('my_safe_server'));
        expect(ids, isNot(contains('powershell_server')));

        final safeServer = servers.firstWhere((s) => s.id == 'my_safe_server');
        expect(safeServer.command, equals('safe_tool_binary'));
        expect(safeServer.args, equals(<String>['--flag', 'value']));

        // Verify wire JSON strictly excludes command, args, url, and any env
        final wire = safeServer.toWireJson();
        expect(wire['id'], equals('my_safe_server'));
        expect(wire['transport'], equals('stdio'));
        expect(wire.containsKey('command'), isFalse);
        expect(wire.containsKey('args'), isFalse);
        expect(wire.containsKey('env'), isFalse);
      });
    });
  });
}

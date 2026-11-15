import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Metadata for a locally configured MCP server discovered on the host (`UDC-12` S12.3).
///
/// Security invariant: `command`, `args`, `url`, and `env` secrets are kept strictly
/// private inside the host process and NEVER serialized to the wire. Only [id],
/// [transport], and [source] are exposed via `mcp.list_servers`.
class DiscoveredMcpServer {
  const DiscoveredMcpServer({
    required this.id,
    required this.transport,
    required this.source,
    this.command,
    this.args = const <String>[],
    this.url,
  });

  final String id;
  final String transport; // 'stdio' | 'http'
  final String source; // 'claude_code' | 'claude_desktop' | 'cursor' | 'antigravity' | 'seed'
  final String? command;
  final List<String> args;
  final String? url;

  Map<String, Object?> toWireJson() => <String, Object?>{
        'id': id,
        'transport': transport,
        'source': source,
      };
}

typedef McpToolInvoker = Future<String> Function(
  DiscoveredMcpServer server,
  String toolName,
  Map<String, Object?> payload,
);

/// Zero-config Local MCP Server Bridge (`UDC-12` S12.3):
/// Scans `~/.claude.json`, Claude Desktop `claude_desktop_config.json`, Cursor
/// `~/.cursor/mcp.json`, and Antigravity MCP config files to discover already-installed
/// MCP servers without exposing environment variables or API keys.
class AutoMcpBridge {
  AutoMcpBridge({
    List<DiscoveredMcpServer>? seedServers,
    List<String>? customConfigPaths,
    bool scanDefaultLocations = true,
    McpToolInvoker? invoker,
  })  : _seedServers = seedServers ?? const <DiscoveredMcpServer>[],
        _customConfigPaths = customConfigPaths ?? const <String>[],
        _scanDefaultLocations = scanDefaultLocations,
        _invoker = invoker;

  final List<DiscoveredMcpServer> _seedServers;
  final List<String> _customConfigPaths;
  final bool _scanDefaultLocations;
  final McpToolInvoker? _invoker;

  List<DiscoveredMcpServer>? _cached;

  static String sanitizeServerId(String raw) {
    final lower = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_.\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (lower.isEmpty) return 'mcp_server';
    final capped = lower.length > 64 ? lower.substring(0, 64) : lower;
    return isValidShortId(capped) ? capped : 'mcp_server';
  }

  /// Discovers all locally configured MCP servers (stripping all `env` secrets).
  List<DiscoveredMcpServer> discoverServers({bool forceRefresh = false}) {
    if (!forceRefresh && _cached != null) {
      return _cached!;
    }
    final byId = <String, DiscoveredMcpServer>{};

    for (final s in _seedServers) {
      byId[s.id] = s;
    }

    final paths = <({String path, String source})>[
      for (final p in _customConfigPaths) (path: p, source: 'config'),
      if (_scanDefaultLocations) ..._defaultMcpConfigPaths(),
    ];

    for (final entry in paths) {
      _parseMcpConfigFile(entry.path, entry.source, (server) {
        byId.putIfAbsent(server.id, () => server);
      });
    }

    final list = byId.values.toList()..sort((a, b) => a.id.compareTo(b.id));
    _cached = list;
    return list;
  }

  DiscoveredMcpServer? findServer(String id) {
    final clean = id.trim().toLowerCase();
    for (final s in discoverServers()) {
      if (s.id == clean) return s;
    }
    return null;
  }

  /// Returns `true` if `@playwright/mcp` (`playwright` / `playwright-mcp`) is
  /// discovered in local MCP configuration (`UDC-13` S13.2).
  bool get hasPlaywrightMcp {
    for (final s in discoverServers()) {
      if (s.id.contains('playwright') ||
          s.args.any((a) => a.toLowerCase().contains('playwright'))) {
        return true;
      }
    }
    return false;
  }

  static const int maxToolOutputBytes = 6144;
  // ignore: constant_identifier_names
  static const int MAX_TOOL_OUTPUT_BYTES = 6144;

  /// Bounds [raw] output text to at most [maxToolOutputBytes] in UTF-8 bytes (`UDC-18` Wave D).
  static String boundToolOutput(String raw) {
    final bytes = utf8.encode(raw);
    if (bytes.length <= maxToolOutputBytes) {
      return raw;
    }
    return utf8.decode(bytes.sublist(0, maxToolOutputBytes), allowMalformed: true);
  }

  /// Calls [toolName] on [server] with [payloadJson] and redacts any sensitive tokens
  /// from the summary before returning. Bounded to <= 6144 bytes.
  Future<String> callTool({
    required DiscoveredMcpServer server,
    required String toolName,
    String? payloadJson,
  }) async {
    Map<String, Object?> payload = const <String, Object?>{};
    if (payloadJson != null && payloadJson.trim().isNotEmpty) {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) {
        throw const FormatException('payloadJson must decode to a JSON object');
      }
      payload = decoded.map((k, v) => MapEntry(k.toString(), v));
    }

    final invoker = _invoker;
    final rawSummary = invoker != null
        ? await invoker(server, toolName, payload)
        : await _defaultInvokeMcpTool(server, toolName, payload);
    final bounded = boundToolOutput(rawSummary);
    return redactBrowserSnapshot(bounded, maxBytes: maxToolOutputBytes).text;
  }

  /// Lists available tools on [server] via MCP JSON-RPC `tools/list` protocol (`UDC-18` Wave D).
  Future<List<Map<String, Object?>>> listTools(DiscoveredMcpServer server) async {
    return _defaultListMcpTools(server);
  }

  static Future<void> _validateAntiSsrf(Uri uri) async {
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
    if (uri.host.trim().isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
    if (uri.userInfo.isNotEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'ssrf_blocked',
      );
    }
    if (uri.hasPort && (uri.port <= 0 || uri.port > 65535)) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }

    final hostLower = uri.host.trim().toLowerCase();

    // Stage 1: Check known local/forbidden hostname literals
    if (isForbiddenLiteralOrLocalHost(hostLower)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'ssrf_blocked',
      );
    }

    // Stage 2: Direct IP parsing check
    final directIp = InternetAddress.tryParse(hostLower);
    if (directIp != null) {
      if (!isPublicIpAddress(directIp.rawAddress)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'ssrf_blocked',
        );
      }
      return;
    }

    // Stage 3: Post-DNS lookup check
    try {
      final addresses = await InternetAddress.lookup(hostLower)
          .timeout(const Duration(seconds: 3));
      if (addresses.isEmpty) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        );
      }
      for (final addr in addresses) {
        if (!isPublicIpAddress(addr.rawAddress)) {
          throw const XunaHostChannelException(
            status: XtpStatus.denied,
            errorCode: 'ssrf_blocked',
          );
        }
      }
    } on SocketException {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_connection_failed',
      );
    } on TimeoutException {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_connection_failed',
      );
    }
  }

  Future<String> _defaultInvokeMcpTool(
    DiscoveredMcpServer server,
    String toolName,
    Map<String, Object?> payload,
  ) async {
    if (server.transport == 'stdio') {
      return _invokeStdioMcpTool(server, toolName, payload);
    } else if (server.transport == 'http') {
      return _invokeHttpMcpTool(server, toolName, payload);
    } else {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
  }

  Future<String> _invokeStdioMcpTool(
    DiscoveredMcpServer server,
    String toolName,
    Map<String, Object?> payload,
  ) async {
    final command = server.command?.trim();
    if (command == null || command.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }

    if (isHardDeniedAppOrProcess(command)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'policy_blocked',
      );
    }

    final _McpStdioSession session;
    try {
      session = await _McpStdioSession.start(command, server.args);
    } catch (_) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_connection_failed',
      );
    }

    try {
      // Step 1: Handshake initialize
      final initResp = await session.request(
        id: 1,
        method: 'initialize',
        params: <String, Object?>{
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'xuna_desktop',
            'version': '0.1.0',
          },
        },
        timeout: const Duration(seconds: 5),
      ).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_handshake_failed',
        );
      });

      if (initResp.containsKey('error') || initResp['result'] == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_handshake_failed',
        );
      }

      // Step 2: Handshake initialized notification
      session.notify(method: 'notifications/initialized');

      // Step 3: tools/call
      final callResp = await session.request(
        id: 2,
        method: 'tools/call',
        params: <String, Object?>{
          'name': toolName,
          'arguments': payload,
        },
        timeout: const Duration(seconds: 10),
      ).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_tool_failed',
        );
      });

      if (callResp.containsKey('error')) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_tool_failed',
        );
      }

      final result = callResp['result'];
      if (result is Map) {
        if (result['isError'] == true) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        }
        final content = result['content'];
        if (content is List) {
          final textSegments = <String>[];
          for (final c in content) {
            if (c is Map && c['text'] != null) {
              textSegments.add(c['text'].toString());
            }
          }
          if (textSegments.isNotEmpty) {
            return boundToolOutput(textSegments.join('\n'));
          }
        }
        if (result['text'] != null) {
          return boundToolOutput(result['text'].toString());
        }
        return boundToolOutput(jsonEncode(result));
      } else if (result != null) {
        return boundToolOutput(result.toString());
      }

      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_tool_failed',
      );
    } finally {
      await session.close();
    }
  }

  Future<String> _invokeHttpMcpTool(
    DiscoveredMcpServer server,
    String toolName,
    Map<String, Object?> payload,
  ) async {
    final rawUrl = server.url?.trim();
    if (rawUrl == null || rawUrl.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
    final uri = Uri.tryParse(rawUrl);
    if (uri == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }

    await _validateAntiSsrf(uri);

    final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    try {
      // Step 1: Handshake initialize
      final initReq = await client.postUrl(uri).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        );
      });
      initReq.headers.contentType = ContentType.json;
      initReq.add(utf8.encode(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'initialize',
        'params': <String, Object?>{
          'protocolVersion': '2024-11-05',
          'capabilities': <String, Object?>{},
          'clientInfo': <String, Object?>{
            'name': 'xuna_desktop',
            'version': '0.1.0',
          },
        },
      })));
      final initResp = await initReq.close().timeout(const Duration(seconds: 5)).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_handshake_failed',
        );
      });
      if (initResp.statusCode != 200) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_handshake_failed',
        );
      }
      final rawInit = await initResp.transform(utf8.decoder).join();
      final decodedInit = jsonDecode(rawInit);
      if (decodedInit is! Map || decodedInit.containsKey('error')) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_handshake_failed',
        );
      }

      // Step 2: tools/call
      final callReq = await client.postUrl(uri).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        );
      });
      callReq.headers.contentType = ContentType.json;
      callReq.add(utf8.encode(jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'id': 2,
        'method': 'tools/call',
        'params': <String, Object?>{
          'name': toolName,
          'arguments': payload,
        },
      })));
      final callResp = await callReq.close().timeout(const Duration(seconds: 10)).catchError((_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_tool_failed',
        );
      });
      if (callResp.statusCode != 200) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_tool_failed',
        );
      }
      final rawCall = await callResp.transform(utf8.decoder).join();
      final decodedCall = jsonDecode(rawCall);
      if (decodedCall is! Map || decodedCall.containsKey('error')) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_tool_failed',
        );
      }
      final result = decodedCall['result'];
      if (result is Map) {
        if (result['isError'] == true) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        }
        final content = result['content'];
        if (content is List) {
          final textSegments = <String>[];
          for (final c in content) {
            if (c is Map && c['text'] != null) {
              textSegments.add(c['text'].toString());
            }
          }
          if (textSegments.isNotEmpty) {
            return boundToolOutput(textSegments.join('\n'));
          }
        }
        if (result['text'] != null) {
          return boundToolOutput(result['text'].toString());
        }
        return boundToolOutput(jsonEncode(result));
      } else if (result != null) {
        return boundToolOutput(result.toString());
      }

      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_tool_failed',
      );
    } finally {
      client.close(force: true);
    }
  }

  Future<List<Map<String, Object?>>> _defaultListMcpTools(
    DiscoveredMcpServer server,
  ) async {
    if (server.transport == 'stdio') {
      final command = server.command?.trim();
      if (command == null || command.isEmpty) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'mcp_server_not_configured',
        );
      }
      if (isHardDeniedAppOrProcess(command)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'policy_blocked',
        );
      }

      final _McpStdioSession session;
      try {
        session = await _McpStdioSession.start(command, server.args);
      } catch (_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        );
      }

      try {
        final initResp = await session.request(
          id: 1,
          method: 'initialize',
          params: <String, Object?>{
            'protocolVersion': '2024-11-05',
            'capabilities': <String, Object?>{},
            'clientInfo': <String, Object?>{
              'name': 'xuna_desktop',
              'version': '0.1.0',
            },
          },
          timeout: const Duration(seconds: 5),
        ).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_handshake_failed',
          );
        });
        if (initResp.containsKey('error') || initResp['result'] == null) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_handshake_failed',
          );
        }
        session.notify(method: 'notifications/initialized');

        final listResp = await session.request(
          id: 2,
          method: 'tools/list',
          params: <String, Object?>{},
          timeout: const Duration(seconds: 5),
        ).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        });

        if (listResp.containsKey('error')) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        }
        final result = listResp['result'];
        if (result is Map && result['tools'] is List) {
          final toolsList = result['tools'] as List;
          return toolsList
              .whereType<Map>()
              .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
              .toList();
        }
        return const <Map<String, Object?>>[];
      } finally {
        await session.close();
      }
    } else if (server.transport == 'http') {
      final rawUrl = server.url?.trim();
      if (rawUrl == null || rawUrl.isEmpty) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'mcp_server_not_configured',
        );
      }
      final uri = Uri.tryParse(rawUrl);
      if (uri == null) {
        throw const XunaHostChannelException(
          status: XtpStatus.invalidArgs,
          errorCode: 'mcp_server_not_configured',
        );
      }
      await _validateAntiSsrf(uri);

      final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
      try {
        final initReq = await client.postUrl(uri).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_connection_failed',
          );
        });
        initReq.headers.contentType = ContentType.json;
        initReq.add(utf8.encode(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'initialize',
          'params': <String, Object?>{
            'protocolVersion': '2024-11-05',
            'capabilities': <String, Object?>{},
            'clientInfo': <String, Object?>{
              'name': 'xuna_desktop',
              'version': '0.1.0',
            },
          },
        })));
        final initResp = await initReq.close().timeout(const Duration(seconds: 5)).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_handshake_failed',
          );
        });
        if (initResp.statusCode != 200) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_handshake_failed',
          );
        }

        final listReq = await client.postUrl(uri).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_connection_failed',
          );
        });
        listReq.headers.contentType = ContentType.json;
        listReq.add(utf8.encode(jsonEncode(<String, Object?>{
          'jsonrpc': '2.0',
          'id': 2,
          'method': 'tools/list',
          'params': <String, Object?>{},
        })));
        final listResp = await listReq.close().timeout(const Duration(seconds: 5)).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        });
        if (listResp.statusCode != 200) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_tool_failed',
          );
        }
        final rawList = await listResp.transform(utf8.decoder).join();
        final decodedList = jsonDecode(rawList);
        if (decodedList is Map && decodedList['result'] is Map) {
          final res = decodedList['result'] as Map;
          if (res['tools'] is List) {
            final toolsList = res['tools'] as List;
            return toolsList
                .whereType<Map>()
                .map((m) => m.map((k, v) => MapEntry(k.toString(), v)))
                .toList();
          }
        }
        return const <Map<String, Object?>>[];
      } finally {
        client.close(force: true);
      }
    } else {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
  }

  static void _parseMcpConfigFile(
    String filePath,
    String source,
    void Function(DiscoveredMcpServer server) onFound,
  ) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return;

      void parseServersMap(Map rawMap, String effectiveSource) {
        for (final entry in rawMap.entries) {
          final key = entry.key;
          final val = entry.value;
          if (key is! String || val is! Map) continue;
          final id = sanitizeServerId(key);
          final cmd = val['command'] as String?;
          final url = val['url'] as String?;
          if (cmd != null && isHardDeniedAppOrProcess(cmd)) {
            continue;
          }
          final transport = (url != null && url.isNotEmpty) ? 'http' : 'stdio';
          final argsList = <String>[];
          if (val['args'] is List) {
            for (final item in val['args'] as List) {
              if (item is String) argsList.add(item);
            }
          }
          // Note: val['env'] is intentionally ignored and never stored or logged.
          onFound(
            DiscoveredMcpServer(
              id: id,
              transport: transport,
              source: effectiveSource,
              command: cmd,
              args: argsList,
              url: url,
            ),
          );
        }
      }

      if (decoded['mcpServers'] is Map) {
        parseServersMap(decoded['mcpServers'] as Map, source);
      }
      if (decoded['projects'] is Map) {
        for (final proj in (decoded['projects'] as Map).values) {
          if (proj is Map && proj['mcpServers'] is Map) {
            parseServersMap(proj['mcpServers'] as Map, source);
          }
        }
      }
    } catch (_) {}
  }

  static List<({String path, String source})> _defaultMcpConfigPaths() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final appData = Platform.environment['APPDATA'] ?? '';
    if (home.isEmpty) return const <({String path, String source})>[];
    final sep = Platform.pathSeparator;
    final out = <({String path, String source})>[
      (path: '$home$sep.claude.json', source: 'claude_code'),
      (path: '$home$sep.cursor${sep}mcp.json', source: 'cursor'),
      (
        path: '$home$sep.gemini${sep}antigravity${sep}mcp_config.json',
        source: 'antigravity',
      ),
    ];
    if (Platform.isWindows && appData.isNotEmpty) {
      out.add((
        path: '$appData${sep}Claude${sep}claude_desktop_config.json',
        source: 'claude_desktop',
      ));
    } else if (Platform.isMacOS) {
      out.add((
        path:
            '$home/Library/Application Support/Claude/claude_desktop_config.json',
        source: 'claude_desktop',
      ));
    } else if (Platform.isLinux) {
      out.add((
        path: '$home/.config/Claude/claude_desktop_config.json',
        source: 'claude_desktop',
      ));
    }
    return out;
  }
}

/// JSON-RPC 2.0 stdio session with line-delimited communication and ID dispatch (`UDC-18` Wave D).
class _McpStdioSession {
  _McpStdioSession._(this._process, this._stdoutLines);

  final Process _process;
  final Stream<String> _stdoutLines;
  late final StreamSubscription<String> _sub;
  final Map<int, Completer<Map<String, Object?>>> _pendingRequests =
      <int, Completer<Map<String, Object?>>>{};
  bool _closed = false;

  static Future<_McpStdioSession> start(
    String command,
    List<String> args,
  ) async {
    final process = await Process.start(
      command,
      args,
      runInShell: false,
    );
    final stdoutLines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    final session = _McpStdioSession._(process, stdoutLines);
    session._init();
    return session;
  }

  void _init() {
    _sub = _stdoutLines.listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            final id = decoded['id'];
            if (id is int && _pendingRequests.containsKey(id)) {
              _pendingRequests.remove(id)!.complete(
                decoded.map((k, v) => MapEntry(k.toString(), v)),
              );
            }
          }
        } catch (_) {}
      },
      onError: (err) {
        _failAll(err);
      },
      onDone: () {
        _failAll(StateError('MCP process stdout closed'));
      },
    );
  }

  void _failAll(Object error) {
    for (final completer in _pendingRequests.values) {
      if (!completer.isCompleted) {
        completer.completeError(error);
      }
    }
    _pendingRequests.clear();
  }

  Future<Map<String, Object?>> request({
    required int id,
    required String method,
    Map<String, Object?>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_closed) throw StateError('Session closed');
    final completer = Completer<Map<String, Object?>>();
    _pendingRequests[id] = completer;

    final req = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    _process.stdin.writeln(jsonEncode(req));

    return completer.future.timeout(timeout);
  }

  void notify({
    required String method,
    Map<String, Object?>? params,
  }) {
    if (_closed) return;
    final msg = <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    _process.stdin.writeln(jsonEncode(msg));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _failAll(StateError('Session closed'));
    await _sub.cancel();
    try {
      await _process.stdin.close();
    } catch (_) {}
    try {
      _process.kill();
    } catch (_) {}
    try {
      await _process.exitCode.timeout(const Duration(milliseconds: 500));
    } catch (_) {
      try {
        _process.kill();
      } catch (_) {}
    }
  }
}

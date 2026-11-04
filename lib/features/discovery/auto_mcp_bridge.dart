import 'dart:convert';
import 'dart:io';

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

  /// Calls [toolName] on [server] with [payloadJson] and redacts any sensitive tokens
  /// from the summary before returning.
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
    return redactSensitiveTokens(rawSummary, maxChars: 400);
  }

  Future<String> _defaultInvokeMcpTool(
    DiscoveredMcpServer server,
    String toolName,
    Map<String, Object?> payload,
  ) async {
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      try {
        if (server.transport == 'http' &&
            server.url != null &&
            server.url!.trim().isNotEmpty) {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 3);
          try {
            final req = await client.postUrl(Uri.parse(server.url!.trim()));
            req.headers.contentType = ContentType.json;
            final body = jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': 1,
              'method': 'tools/call',
              'params': <String, Object?>{
                'name': toolName,
                'arguments': payload,
              },
            });
            req.add(utf8.encode(body));
            final resp = await req.close().timeout(const Duration(seconds: 4));
            final rawResp = await resp.transform(utf8.decoder).join();
            if (rawResp.trim().isNotEmpty) {
              return 'Đã gọi ${server.id}.$toolName: ${rawResp.trim()}';
            }
          } finally {
            client.close(force: true);
          }
        } else if (server.transport == 'stdio' &&
            server.command != null &&
            server.command!.trim().isNotEmpty) {
          final proc = await Process.start(
            server.command!.trim(),
            server.args,
            runInShell: Platform.isWindows,
          );
          try {
            final initReq = jsonEncode(<String, Object?>{
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
            });
            final callReq = jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/call',
              'params': <String, Object?>{
                'name': toolName,
                'arguments': payload,
              },
            });
            proc.stdin.writeln(initReq);
            proc.stdin.writeln(callReq);
            await proc.stdin.close();
            final out = await proc.stdout
                .transform(utf8.decoder)
                .join()
                .timeout(const Duration(seconds: 4), onTimeout: () => '');
            if (out.trim().isNotEmpty) {
              final lines = out
                  .split('\n')
                  .map((l) => l.trim())
                  .where((l) => l.isNotEmpty)
                  .toList();
              if (lines.isNotEmpty) {
                return 'Đã gọi ${server.id}.$toolName: ${lines.last}';
              }
            }
          } finally {
            proc.kill();
          }
        }
      } catch (_) {}
    }
    return 'Đã gọi ${server.id}.$toolName (${server.transport}).';
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

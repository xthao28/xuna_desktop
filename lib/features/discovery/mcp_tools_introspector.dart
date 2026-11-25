import 'dart:async';
import 'dart:convert';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/auto_mcp_bridge.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

typedef McpToolLister =
    Future<List<Map<String, Object?>>> Function(DiscoveredMcpServer server);

/// Adds real MCP `tools/list` metadata to `mcp.list_servers` (`ADR-0018`
/// Pillar 2).
///
/// Each server is asked once per [ttl] (RAM cache keyed by id, transport and
/// launch fingerprint, so a policy change re-queries), bounded by [timeout].
/// Descriptions are U5-redacted and cut to 160 characters; argument lists
/// come from the tool's `inputSchema`. A failing server reports `toolsError`
/// without hiding the others (Rule H4). The whole response is kept under
/// [maxResponseBytes] (`toolsTruncated: true` when tools were dropped).
class McpToolsIntrospector {
  McpToolsIntrospector({
    required McpToolLister lister,
    this.timeout = const Duration(seconds: 2),
    this.ttl = const Duration(seconds: 60),
    this.maxToolsPerServer = 40,
    this.maxResponseBytes = 16000,
    DateTime Function()? clock,
  }) : _lister = lister,
       _clock = clock ?? DateTime.now;

  static final Expando<McpToolsIntrospector> _byBridge =
      Expando<McpToolsIntrospector>();

  /// Shared introspector for [bridge] (one RAM cache per bridge).
  static McpToolsIntrospector forBridge(AutoMcpBridge bridge) =>
      _byBridge[bridge] ??= McpToolsIntrospector(lister: bridge.listTools);

  final McpToolLister _lister;
  final Duration timeout;
  final Duration ttl;
  final int maxToolsPerServer;
  final int maxResponseBytes;
  final DateTime Function() _clock;
  final Map<String, ({DateTime at, Map<String, Object?> value})> _cache =
      <String, ({DateTime at, Map<String, Object?> value})>{};

  void invalidate() => _cache.clear();

  String _key(DiscoveredMcpServer s) =>
      '${s.id}|${s.transport}|${s.command ?? s.url ?? ''}|${s.args.join('\u0000')}';

  /// Returns `{tools, toolsTruncated}` or `{toolsError}` for [server].
  Future<Map<String, Object?>> describe(DiscoveredMcpServer server) async {
    final key = _key(server);
    final hit = _cache[key];
    final now = _clock();
    if (hit != null && now.difference(hit.at) < ttl) return hit.value;
    final value = await _query(server);
    _cache[key] = (at: now, value: value);
    return value;
  }

  Future<Map<String, Object?>> _query(DiscoveredMcpServer server) async {
    if (server.transport != 'stdio' && server.transport != 'http') {
      return const <String, Object?>{'toolsError': 'unsupported_transport'};
    }
    final List<Map<String, Object?>> raw;
    try {
      raw = await _lister(server).timeout(timeout);
    } on TimeoutException {
      return const <String, Object?>{'toolsError': 'timeout'};
    } on XunaHostChannelException catch (error) {
      return <String, Object?>{
        'toolsError': error.errorCode == 'mcp_connection_failed'
            ? 'spawn_failed'
            : 'protocol_error',
      };
    } on Object {
      return const <String, Object?>{'toolsError': 'protocol_error'};
    }
    final tools = <Map<String, Object?>>[];
    for (final tool in raw) {
      final summary = _summarize(tool);
      if (summary != null) tools.add(summary);
      if (tools.length >= maxToolsPerServer) break;
    }
    return <String, Object?>{
      'tools': tools,
      'toolsTruncated': raw.length > tools.length,
    };
  }

  static Map<String, Object?>? _summarize(Map<String, Object?> tool) {
    final name = tool['name'];
    if (name is! String) return null;
    final cleanName = name.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
    if (cleanName.isEmpty || cleanName.length > 128) return null;
    final rawDescription = tool['description'];
    final description = rawDescription is String
        ? redactSensitiveTokens(
            rawDescription.replaceAll(RegExp(r'\s+'), ' ').trim(),
            maxChars: 160,
          )
        : '';
    final schema = tool['inputSchema'];
    final properties = schema is Map && schema['properties'] is Map
        ? (schema['properties'] as Map).keys.map((k) => '$k').toList()
        : const <String>[];
    final requiredRaw = schema is Map && schema['required'] is List
        ? (schema['required'] as List).whereType<String>().toSet()
        : const <String>{};
    return <String, Object?>{
      'name': cleanName,
      'description': description.length > 160
          ? description.substring(0, 160)
          : description,
      'requiredArgs': requiredRaw.take(16).toList(),
      'optionalArgs': properties
          .where((p) => !requiredRaw.contains(p))
          .take(16)
          .toList(),
    };
  }

  /// Drops tools from the largest lists until [servers] fits the budget.
  void enforceBudget(List<Map<String, Object?>> servers) {
    int size() => utf8.encode(jsonEncode(servers)).length;
    while (size() > maxResponseBytes) {
      Map<String, Object?>? largest;
      for (final s in servers) {
        final tools = s['tools'];
        if (tools is List &&
            tools.isNotEmpty &&
            (largest == null ||
                tools.length > (largest['tools']! as List).length)) {
          largest = s;
        }
      }
      if (largest == null) return;
      final shrunk = List<Object?>.of(largest['tools']! as List)..removeLast();
      largest['tools'] = shrunk;
      largest['toolsTruncated'] = true;
    }
  }
}

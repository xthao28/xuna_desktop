import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/windows_stdio_launcher.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Metadata for a locally configured MCP server discovered on the host (`UDC-12` S12.3).
///
/// Security invariant: `command`, `args`, `url`, and `env` secrets are kept strictly
/// private inside the host process and NEVER serialized to the wire. Only [id],
/// [transport], [source], and optional [supportsAsync] are exposed via `mcp.list_servers`.
class DiscoveredMcpServer {
  const DiscoveredMcpServer({
    required this.id,
    required this.transport,
    required this.source,
    this.command,
    this.args = const <String>[],
    this.url,
    this.supportsAsync,
  });

  final String id;
  final String transport; // 'stdio' | 'http'
  final String
  source; // 'claude_code' | 'claude_desktop' | 'cursor' | 'antigravity' | 'seed' | 'host_policy'
  final String? command;
  final List<String> args;
  final String? url;
  final bool? supportsAsync;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'id': id,
    'transport': transport,
    'source': source,
    if (supportsAsync != null) 'supportsAsync': supportsAsync,
  };
}

/// Injectable stdio transport for [AutoMcpBridge] unit tests (`AW2-M2`).
class McpStdioTransport {
  const McpStdioTransport({
    required this.stdoutLines,
    required this.writeStdinLine,
    required this.exitCode,
    required this.terminate,
  });

  final Stream<String> stdoutLines;
  final void Function(String line) writeStdinLine;
  final Future<int> exitCode;
  final Future<void> Function() terminate;
}

typedef McpStdioTransportFactory =
    Future<McpStdioTransport> Function(String executable, List<String> args);

/// Outcome returned by [AutoMcpBridge.callToolAsync] (`AW2-M2`).
class McpCallOutcome {
  const McpCallOutcome.completed({required this.summary})
    : status = 'completed',
      mcpServerId = null,
      protocolTaskId = null;

  const McpCallOutcome.running({
    required this.mcpServerId,
    required this.protocolTaskId,
    this.summary = 'Task detached and running asynchronously.',
  }) : status = 'running';

  final String status;
  final String summary;
  final String? mcpServerId;
  final String? protocolTaskId;

  bool get isRunning => status == 'running';
}

typedef McpToolInvoker =
    Future<String> Function(
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
    ProtocolTaskRegistry? taskRegistry,
    McpStdioTransportFactory? stdioTransportFactory,
    DateTime Function()? clock,
  }) : _seedServers = seedServers ?? const <DiscoveredMcpServer>[],
       _customConfigPaths = customConfigPaths ?? const <String>[],
       _scanDefaultLocations = scanDefaultLocations,
       _invoker = invoker,
       _taskRegistry = taskRegistry,
       _stdioTransportFactory = stdioTransportFactory,
       _clock = clock ?? _defaultUtcNow;

  static DateTime _defaultUtcNow() => DateTime.now().toUtc();

  final List<DiscoveredMcpServer> _seedServers;
  final List<String> _customConfigPaths;
  final bool _scanDefaultLocations;
  final McpToolInvoker? _invoker;
  final ProtocolTaskRegistry? _taskRegistry;
  final McpStdioTransportFactory? _stdioTransportFactory;
  final DateTime Function() _clock;
  int _taskSeq = 0;

  /// Builds a local-only [DiscoveredMcpServer] from an allowlisted
  /// [ProtocolHarnessConfig]. Never serialized directly to the wire.
  static DiscoveredMcpServer buildServerFromHarness(
    ProtocolHarnessConfig harness,
  ) => DiscoveredMcpServer(
    id: harness.id,
    transport: harness.mcpListTransport,
    source: 'host_policy',
    command: harness.executable,
    args: harness.args,
    supportsAsync: true,
  );

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
    return utf8.decode(
      bytes.sublist(0, maxToolOutputBytes),
      allowMalformed: true,
    );
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

  /// Calls [toolName] on [server] with optional [asyncMode] / [yieldMs] detach
  /// into [ProtocolTaskRegistry] (`AW2-M2`).
  Future<McpCallOutcome> callToolAsync({
    required DiscoveredMcpServer server,
    required String toolName,
    String? payloadJson,
    bool asyncMode = false,
    int? yieldMs,
    ProtocolTaskRegistry? taskRegistry,
  }) async {
    if (!asyncMode && yieldMs == null) {
      final summary = await callTool(
        server: server,
        toolName: toolName,
        payloadJson: payloadJson,
      );
      return McpCallOutcome.completed(summary: summary);
    }

    Map<String, Object?> payload = const <String, Object?>{};
    if (payloadJson != null && payloadJson.trim().isNotEmpty) {
      final decoded = jsonDecode(payloadJson);
      if (decoded is! Map) {
        throw const FormatException('payloadJson must decode to a JSON object');
      }
      payload = decoded.map((k, v) => MapEntry(k.toString(), v));
    }

    if (server.transport != 'stdio') {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'watch_unsupported',
      );
    }

    final command = server.command?.trim();
    if (command == null || command.isEmpty) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'mcp_server_not_configured',
      );
    }
    if (isHardDeniedAppOrProcess(command) ||
        isForbiddenProtocolHarnessExecutable(command) ||
        hasForbiddenHarnessInlineEvalArg(command, server.args)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'policy_blocked',
      );
    }

    final registry = taskRegistry ?? _taskRegistry;
    if (registry == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'watch_unsupported',
      );
    }
    if (asyncMode &&
        registry.activeCount >= ProtocolTaskRegistry.maxConcurrentTasks) {
      throw const ProtocolTaskLimitException();
    }

    final _McpStdioSession session;
    try {
      session = await _McpStdioSession.start(
        command,
        server.args,
        transportFactory: _stdioTransportFactory,
      );
    } catch (_) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_connection_failed',
      );
    }

    try {
      final initResp = await session
          .request(
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
          )
          .catchError((_) {
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

      final taskId =
          'mcp_${++_taskSeq}_${_clock().toUtc().millisecondsSinceEpoch}';
      var detached = false;
      session.onNotification = (method, params) {
        if (method != 'notifications/progress' || !detached) return;
        final token = params['progressToken'];
        if (token != null && token != taskId) return;
        registry.recordProgress(
          taskId,
          progressPercent: _extractProgressPercent(params),
        );
      };

      final callFuture = session.request(
        id: 2,
        method: 'tools/call',
        params: <String, Object?>{
          'name': toolName,
          'arguments': payload,
          '_meta': <String, Object?>{'progressToken': taskId},
        },
        timeout: const Duration(minutes: 15),
      );

      if (!asyncMode && yieldMs != null) {
        final early = await Future.any<bool>(<Future<bool>>[
          callFuture.then((_) => true, onError: (_) => true),
          Future<void>.delayed(
            Duration(milliseconds: yieldMs),
          ).then((_) => false),
        ]);
        if (early) {
          final resp = await callFuture.catchError((Object error) {
            if (error is XunaHostChannelException) throw error;
            throw const XunaHostChannelException(
              status: XtpStatus.failed,
              errorCode: 'mcp_tool_failed',
            );
          });
          final raw = _extractStdioToolResult(resp);
          await session.close();
          return McpCallOutcome.completed(
            summary: ProtocolTaskRegistry.redactSummary(raw),
          );
        }
      }

      Future<void> cancelAndClose() async {
        try {
          session.notify(
            method: 'notifications/cancelled',
            params: <String, Object?>{
              'requestId': 2,
              'reason': 'cancelled_by_caller',
            },
          );
        } catch (_) {
        } finally {
          await session.close();
        }
      }

      try {
        registry.registerTask(
          taskId: taskId,
          serverId: server.id,
          protocol: 'mcp_stdio',
          cancelCallback: cancelAndClose,
        );
      } catch (_) {
        unawaited(callFuture.catchError((_) => <String, Object?>{}));
        await cancelAndClose();
        rethrow;
      }

      detached = true;
      unawaited(
        callFuture.then(
          (resp) async {
            if (session.isClosed) return;
            try {
              final raw = _extractStdioToolResult(resp);
              registry.completeTask(taskId, summary: raw);
            } on XunaHostChannelException catch (err) {
              registry.failTask(
                taskId,
                errorCode: err.errorCode,
                summary: 'MCP tool returned an error.',
              );
            } catch (_) {
              registry.failTask(
                taskId,
                errorCode: 'mcp_tool_failed',
                summary: 'MCP tool returned an error.',
              );
            }
            await session.close();
          },
          onError: (Object error) async {
            if (session.isClosed) return;
            if (error is _McpUnexpectedExitException) {
              registry.markLost(
                taskId,
                summary: 'MCP server process exited unexpectedly.',
              );
            } else {
              registry.failTask(
                taskId,
                errorCode: 'mcp_tool_failed',
                summary: 'MCP tool call failed.',
              );
            }
            await session.close();
          },
        ),
      );
      return McpCallOutcome.running(
        mcpServerId: server.id,
        protocolTaskId: taskId,
      );
    } on XunaHostChannelException {
      await session.close();
      rethrow;
    } catch (_) {
      await session.close();
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_tool_failed',
      );
    }
  }

  static int? _extractProgressPercent(Map<String, Object?> params) {
    final direct = params['progressPercent'];
    if (direct is num) return direct.round().clamp(0, 100);
    final progress = params['progress'];
    final total = params['total'];
    if (progress is num && total is num && total > 0) {
      return ((progress / total) * 100).round().clamp(0, 100);
    }
    return null;
  }

  String _extractStdioToolResult(Map<String, Object?> callResp) {
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
  }

  /// Lists available tools on [server] via MCP JSON-RPC `tools/list` protocol (`UDC-18` Wave D).
  Future<List<Map<String, Object?>>> listTools(
    DiscoveredMcpServer server,
  ) async {
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
      final addresses = await InternetAddress.lookup(
        hostLower,
      ).timeout(const Duration(seconds: 3));
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

    if (isHardDeniedAppOrProcess(command) ||
        isForbiddenProtocolHarnessExecutable(command) ||
        hasForbiddenHarnessInlineEvalArg(command, server.args)) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'policy_blocked',
      );
    }

    final _McpStdioSession session;
    try {
      session = await _McpStdioSession.start(
        command,
        server.args,
        transportFactory: _stdioTransportFactory,
      );
    } catch (_) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'mcp_connection_failed',
      );
    }

    try {
      // Step 1: Handshake initialize
      final initResp = await session
          .request(
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
          )
          .catchError((_) {
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
      final callResp = await session
          .request(
            id: 2,
            method: 'tools/call',
            params: <String, Object?>{'name': toolName, 'arguments': payload},
            timeout: const Duration(seconds: 10),
          )
          .catchError((_) {
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
      initReq.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
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
          }),
        ),
      );
      final initResp = await initReq
          .close()
          .timeout(const Duration(seconds: 5))
          .catchError((_) {
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
      callReq.add(
        utf8.encode(
          jsonEncode(<String, Object?>{
            'jsonrpc': '2.0',
            'id': 2,
            'method': 'tools/call',
            'params': <String, Object?>{'name': toolName, 'arguments': payload},
          }),
        ),
      );
      final callResp = await callReq
          .close()
          .timeout(const Duration(seconds: 10))
          .catchError((_) {
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
      if (isHardDeniedAppOrProcess(command) ||
          isForbiddenProtocolHarnessExecutable(command) ||
          hasForbiddenHarnessInlineEvalArg(command, server.args)) {
        throw const XunaHostChannelException(
          status: XtpStatus.denied,
          errorCode: 'policy_blocked',
        );
      }

      final _McpStdioSession session;
      try {
        session = await _McpStdioSession.start(
          command,
          server.args,
          transportFactory: _stdioTransportFactory,
        );
      } catch (_) {
        throw const XunaHostChannelException(
          status: XtpStatus.failed,
          errorCode: 'mcp_connection_failed',
        );
      }

      try {
        final initResp = await session
            .request(
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
            )
            .catchError((_) {
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

        final listResp = await session
            .request(
              id: 2,
              method: 'tools/list',
              params: <String, Object?>{},
              timeout: const Duration(seconds: 5),
            )
            .catchError((_) {
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

      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3);
      try {
        final initReq = await client.postUrl(uri).catchError((_) {
          throw const XunaHostChannelException(
            status: XtpStatus.failed,
            errorCode: 'mcp_connection_failed',
          );
        });
        initReq.headers.contentType = ContentType.json;
        initReq.add(
          utf8.encode(
            jsonEncode(<String, Object?>{
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
            }),
          ),
        );
        final initResp = await initReq
            .close()
            .timeout(const Duration(seconds: 5))
            .catchError((_) {
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
        listReq.add(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'jsonrpc': '2.0',
              'id': 2,
              'method': 'tools/list',
              'params': <String, Object?>{},
            }),
          ),
        );
        final listResp = await listReq
            .close()
            .timeout(const Duration(seconds: 5))
            .catchError((_) {
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
    final home =
        Platform.environment['HOME'] ??
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

class _McpUnexpectedExitException implements Exception {
  const _McpUnexpectedExitException();
}

/// JSON-RPC 2.0 stdio session with line-delimited communication, notification
/// forwarding, and SIGTERM -> 2s -> SIGKILL teardown (`UDC-18` Wave D, `AW2-M2`).
class _McpStdioSession {
  _McpStdioSession._(this._transport);

  final McpStdioTransport _transport;
  late final StreamSubscription<String> _sub;
  final Map<int, Completer<Map<String, Object?>>> _pendingRequests =
      <int, Completer<Map<String, Object?>>>{};
  void Function(String method, Map<String, Object?> params)? onNotification;
  Timer? _exitGraceTimer;
  bool _closed = false;

  bool get isClosed => _closed;

  static Future<_McpStdioSession> start(
    String command,
    List<String> args, {
    McpStdioTransportFactory? transportFactory,
  }) async {
    final McpStdioTransport transport;
    if (transportFactory != null) {
      transport = await transportFactory(command, args);
    } else {
      final spawned = await startStdioJsonRpcProcess(command, args);
      transport = McpStdioTransport(
        stdoutLines: spawned.stdoutLines,
        writeStdinLine: spawned.writeStdinLine,
        exitCode: spawned.exitCode,
        terminate: spawned.terminate,
      );
    }
    final session = _McpStdioSession._(transport);
    session._init();
    return session;
  }

  void _init() {
    _sub = _transport.stdoutLines.listen(
      (line) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) return;
        try {
          final decoded = jsonDecode(trimmed);
          if (decoded is Map) {
            final id = decoded['id'];
            if (id == null) {
              final method = decoded['method'];
              if (method is String && method.isNotEmpty) {
                final rawParams = decoded['params'];
                final params = <String, Object?>{
                  if (rawParams is Map)
                    for (final e in rawParams.entries)
                      if (e.key is String) e.key as String: e.value,
                };
                onNotification?.call(method, params);
              }
              return;
            }
            if (id is int && _pendingRequests.containsKey(id)) {
              _pendingRequests
                  .remove(id)!
                  .complete(decoded.map((k, v) => MapEntry(k.toString(), v)));
            }
          }
        } catch (_) {}
      },
      onError: (_) {
        _failAll(const _McpUnexpectedExitException());
      },
      onDone: () {
        _failAll(const _McpUnexpectedExitException());
      },
    );
    unawaited(
      _transport.exitCode.then((_) {
        if (_closed || _pendingRequests.isEmpty) return;
        _exitGraceTimer = Timer(const Duration(milliseconds: 25), () {
          if (!_closed && _pendingRequests.isNotEmpty) {
            _failAll(const _McpUnexpectedExitException());
          }
        });
      }),
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
    _transport.writeStdinLine(jsonEncode(req));

    return completer.future.timeout(timeout);
  }

  void notify({required String method, Map<String, Object?>? params}) {
    if (_closed) return;
    final msg = <String, Object?>{
      'jsonrpc': '2.0',
      'method': method,
      if (params != null) 'params': params,
    };
    _transport.writeStdinLine(jsonEncode(msg));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _exitGraceTimer?.cancel();
    _exitGraceTimer = null;
    _failAll(StateError('Session closed'));
    await _sub.cancel();
    await _transport.terminate();
  }
}

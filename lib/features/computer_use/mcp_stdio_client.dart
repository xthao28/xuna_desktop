import 'dart:async';
import 'dart:convert';

import 'package:xuna_desktop/features/computer_use/driver_map.dart';
import 'package:xuna_desktop/features/discovery/windows_stdio_launcher.dart';

typedef McpNotificationHandler =
    void Function(String method, Map<String, Object?> params);

/// Client speaking MCP `2026-07-28` JSON-RPC 2.0 over newline-delimited `stdio`
/// with a bounded `cua-driver mcp` child process (`UDC-8` S8.1 & §4.1).
class McpStdioClient {
  McpStdioClient.fromStreams({
    required Stream<String> stdoutLines,
    required void Function(String line) writeStdinLine,
    Future<void> Function()? onTerminate,
    this.onNotification,
    Future<int>? exitCode,
  }) : _writeStdinLine = writeStdinLine,
       _onTerminate = onTerminate {
    _stdoutSub = stdoutLines.listen(
      _handleLine,
      onError: (_) => _failAllPending('stdio_stream_error'),
      onDone: () => _failAllPending('stdio_stream_closed'),
    );
    if (exitCode != null) {
      unawaited(
        exitCode.then((_) {
          if (_isClosed || _pending.isEmpty) return;
          _exitTimer = Timer(const Duration(milliseconds: 25), () {
            if (!_isClosed && _pending.isNotEmpty) {
              _failAllPending('stdio_process_exited');
            }
          });
        }),
      );
    }
  }

  final void Function(String line) _writeStdinLine;
  final Future<void> Function()? _onTerminate;
  McpNotificationHandler? onNotification;
  StreamSubscription<String>? _stdoutSub;
  Timer? _exitTimer;
  int _nextId = 1;
  bool _isClosed = false;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};

  bool get isClosed => _isClosed;

  /// Spawns a child process (e.g., `cua-driver mcp --direct ...`) and wraps its
  /// `stdin` / `stdout` in an [McpStdioClient].
  static Future<McpStdioClient> spawn({
    required String executable,
    required List<String> arguments,
    Map<String, String>? environment,
    McpNotificationHandler? onNotification,
  }) async {
    final spawned = await startStdioJsonRpcProcess(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: true,
    );
    return McpStdioClient.fromStreams(
      stdoutLines: spawned.stdoutLines,
      writeStdinLine: spawned.writeStdinLine,
      onNotification: onNotification,
      exitCode: spawned.exitCode,
      onTerminate: spawned.terminate,
    );
  }

  /// Sends a modern MCP `2026-07-28` `server/discover` request.
  Future<Map<String, Object?>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) => request(
    method: 'server/discover',
    params: const <String, Object?>{},
    timeout: timeout,
  );

  /// Calls a tool on the MCP server via `tools/call`.
  Future<Map<String, Object?>> callTool({
    required String name,
    required Map<String, Object?> arguments,
    Duration timeout = const Duration(seconds: 15),
  }) => request(
    method: 'tools/call',
    params: <String, Object?>{'name': name, 'arguments': arguments},
    timeout: timeout,
  );

  /// Sends a JSON-RPC 2.0 request with modern MCP `2026-07-28` `_meta`.
  Future<Map<String, Object?>> request({
    required String method,
    required Map<String, Object?> params,
    Duration timeout = const Duration(seconds: 10),
  }) {
    final existingMeta = params['_meta'];
    final mergedMeta = <String, Object?>{
      if (existingMeta is Map<String, Object?>) ...existingMeta,
      'io.modelcontextprotocol/protocolVersion':
          CuaDriverMap.pinnedMcpProtocolVersion,
      'io.modelcontextprotocol/clientCapabilities': const <String, Object?>{},
    };
    return requestRaw(
      method: method,
      params: <String, Object?>{...params, '_meta': mergedMeta},
      timeout: timeout,
    );
  }

  /// Sends a raw JSON-RPC 2.0 request without injecting MCP `_meta`.
  Future<Map<String, Object?>> requestRaw({
    required String method,
    Map<String, Object?>? params,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_isClosed) {
      throw StateError('McpStdioClient is already closed');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;

    final envelope = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      if (params != null) 'params': params,
    };
    _writeStdinLine(jsonEncode(envelope));

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  /// Sends a JSON-RPC 2.0 notification (`id` omitted).
  void sendNotification(String method, Map<String, Object?> params) {
    if (_isClosed) return;
    _writeStdinLine(
      jsonEncode(<String, Object?>{
        'jsonrpc': '2.0',
        'method': method,
        'params': params,
      }),
    );
  }

  void _handleLine(String rawLine) {
    final trimmed = rawLine.trim();
    if (trimmed.isEmpty) return;
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final id = decoded['id'];
    if (id == null) {
      final method = decoded['method'];
      if (method is String && method.isNotEmpty) {
        final rawParams = decoded['params'];
        final typedParams = <String, Object?>{};
        if (rawParams is Map) {
          for (final entry in rawParams.entries) {
            if (entry.key is String) {
              typedParams[entry.key as String] = entry.value;
            }
          }
        }
        onNotification?.call(method, typedParams);
      }
      return;
    }
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    if (decoded['error'] is Map) {
      final err = decoded['error'] as Map;
      final rawCode = err['code'];
      final rawMessage = err['message'];
      completer.completeError(
        McpRpcException(
          code: rawCode is int ? rawCode : -32000,
          message: rawMessage is String ? rawMessage : 'mcp_error',
        ),
      );
      return;
    }

    final result = decoded['result'];
    if (result is Map) {
      final typed = <String, Object?>{};
      for (final entry in result.entries) {
        if (entry.key is String) {
          typed[entry.key as String] = entry.value;
        }
      }
      completer.complete(typed);
    } else {
      completer.complete(const <String, Object?>{});
    }
  }

  void _failAllPending(String reason) {
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(McpRpcException(code: -32000, message: reason));
      }
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_isClosed) return;
    _isClosed = true;
    _exitTimer?.cancel();
    _exitTimer = null;
    await _stdoutSub?.cancel();
    _stdoutSub = null;
    _failAllPending('client_closed');
    if (_onTerminate != null) {
      await _onTerminate();
    }
  }
}

class McpRpcException implements Exception {
  const McpRpcException({required this.code, required this.message});

  final int code;
  final String message;

  @override
  String toString() => 'McpRpcException(code: $code, message: $message)';
}

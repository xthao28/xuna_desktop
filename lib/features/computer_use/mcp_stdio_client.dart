import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/features/computer_use/driver_map.dart';

/// Client speaking MCP `2026-07-28` JSON-RPC 2.0 over newline-delimited `stdio`
/// with a bounded `cua-driver mcp` child process (`UDC-8` S8.1 & §4.1).
class McpStdioClient {
  McpStdioClient.fromStreams({
    required Stream<String> stdoutLines,
    required void Function(String line) writeStdinLine,
    Future<void> Function()? onTerminate,
  }) : _writeStdinLine = writeStdinLine,
       _onTerminate = onTerminate {
    _stdoutSub = stdoutLines.listen(
      _handleLine,
      onError: (_) => _failAllPending('stdio_stream_error'),
      onDone: () => _failAllPending('stdio_stream_closed'),
    );
  }

  final void Function(String line) _writeStdinLine;
  final Future<void> Function()? _onTerminate;
  StreamSubscription<String>? _stdoutSub;
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
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: environment,
      includeParentEnvironment: true,
    );
    final lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    return McpStdioClient.fromStreams(
      stdoutLines: lines,
      writeStdinLine: (line) {
        process.stdin.writeln(line);
      },
      onTerminate: () async {
        process.kill(ProcessSignal.sigterm);
        try {
          await process.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          process.kill(ProcessSignal.sigkill);
        }
      },
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
  }) async {
    if (_isClosed) {
      throw StateError('McpStdioClient is already closed');
    }
    final id = _nextId++;
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;

    final existingMeta = params['_meta'];
    final mergedMeta = <String, Object?>{
      if (existingMeta is Map<String, Object?>) ...existingMeta,
      'io.modelcontextprotocol/protocolVersion':
          CuaDriverMap.pinnedMcpProtocolVersion,
      'io.modelcontextprotocol/clientCapabilities': const <String, Object?>{},
    };

    final envelope = <String, Object?>{
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': <String, Object?>{...params, '_meta': mergedMeta},
    };

    _writeStdinLine(jsonEncode(envelope));

    try {
      return await completer.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
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
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;

    if (decoded['error'] is Map) {
      final err = decoded['error'] as Map;
      completer.completeError(
        McpRpcException(
          code: (err['code'] as int?) ?? -32000,
          message: (err['message'] as String?) ?? 'mcp_error',
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


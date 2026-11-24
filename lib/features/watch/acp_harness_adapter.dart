import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/computer_use/mcp_stdio_client.dart';
import 'package:xuna_desktop/features/watch/protocol_task_registry.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Injectable stdio transport used by [AcpHarnessAdapter].
class AcpTransport {
  const AcpTransport({
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

typedef AcpTransportFactory =
    Future<AcpTransport> Function(String executable, List<String> args);

class AcpPromptOutcome {
  const AcpPromptOutcome.completed({required this.summary})
    : status = 'completed',
      mcpServerId = null,
      protocolTaskId = null;

  const AcpPromptOutcome.running({
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

/// Pure-Dart JSON-RPC 2.0 over stdio adapter for opt-in `acp_stdio` harnesses.
class AcpHarnessAdapter {
  AcpHarnessAdapter({
    required ProtocolTaskRegistry taskRegistry,
    AcpTransportFactory? transportFactory,
    DateTime Function()? clock,
  }) : _taskRegistry = taskRegistry,
       _transportFactory = transportFactory ?? _defaultTransportFactory,
       _clock = clock ?? _defaultUtcNow;

  static const int _maxBufferChars = 16384;
  final ProtocolTaskRegistry _taskRegistry;
  final AcpTransportFactory _transportFactory;
  final DateTime Function() _clock;
  int _taskSeq = 0;

  static DateTime _defaultUtcNow() => DateTime.now().toUtc();
  static Never _fail(String code, [XtpStatus status = XtpStatus.failed]) =>
      throw XunaHostChannelException(status: status, errorCode: code);

  static Future<AcpTransport> _defaultTransportFactory(
    String executable,
    List<String> args,
  ) async {
    final p = await Process.start(executable, args, runInShell: false);
    final lines = p.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    return AcpTransport(
      stdoutLines: lines,
      writeStdinLine: (line) => p.stdin.writeln(line),
      exitCode: p.exitCode,
      terminate: () async {
        try {
          await p.stdin.close();
        } catch (_) {}
        try {
          p.kill(ProcessSignal.sigterm);
        } catch (_) {}
        try {
          await p.exitCode.timeout(const Duration(seconds: 2));
        } catch (_) {
          try {
            p.kill(ProcessSignal.sigkill);
          } catch (_) {}
        }
      },
    );
  }

  Future<AcpPromptOutcome> runPrompt({
    required ProtocolHarnessConfig harness,
    required String toolName,
    String? payloadJson,
    bool asyncMode = false,
    int? yieldMs,
  }) async {
    if (harness.protocol != ProtocolHarnessProtocol.acpStdio) {
      _fail('protocol_harness_disabled', XtpStatus.invalidArgs);
    }
    if (isForbiddenProtocolHarnessExecutable(harness.executable) ||
        hasForbiddenHarnessInlineEvalArg(harness.executable, harness.args)) {
      _fail('policy_blocked', XtpStatus.denied);
    }
    final promptText = _extractPromptText(toolName, payloadJson);
    if (asyncMode &&
        _taskRegistry.activeCount >= ProtocolTaskRegistry.maxConcurrentTasks) {
      throw const ProtocolTaskLimitException();
    }

    late final AcpTransport transport;
    try {
      transport = await _transportFactory(harness.executable, harness.args);
    } catch (_) {
      _fail('mcp_connection_failed');
    }

    final textBuffer = StringBuffer();
    var detached = false;
    final taskId =
        'acp_${++_taskSeq}_${_clock().toUtc().millisecondsSinceEpoch}';
    final client = McpStdioClient.fromStreams(
      stdoutLines: transport.stdoutLines,
      writeStdinLine: transport.writeStdinLine,
      onTerminate: transport.terminate,
      exitCode: transport.exitCode,
      onNotification: (method, params) {
        if (method != 'session/update') return;
        final chunk = _extractUpdateText(params);
        if (chunk != null &&
            chunk.isNotEmpty &&
            textBuffer.length < _maxBufferChars) {
          textBuffer.write(chunk);
        }
        if (detached) {
          _taskRegistry.recordProgress(
            taskId,
            progressPercent: _extractProgressPercent(params),
          );
        }
      },
    );

    try {
      final sessionId = await _initializeAndCreateSession(client);
      final promptFuture = client.requestRaw(
        method: 'session/prompt',
        params: {
          'sessionId': sessionId,
          'prompt': [
            {'type': 'text', 'text': promptText},
          ],
        },
        timeout: const Duration(minutes: 15),
      );

      if (!asyncMode && yieldMs == null) {
        return await _awaitSync(promptFuture, client, textBuffer);
      }
      if (!asyncMode && yieldMs != null) {
        final delay = Future<void>.delayed(Duration(milliseconds: yieldMs));
        final early = await Future.any([
          promptFuture.then((_) => true, onError: (_) => true),
          delay.then((_) => false),
        ]);
        if (early) return await _awaitSync(promptFuture, client, textBuffer);
      }

      Future<void> cancelAndClose() async {
        try {
          client.sendNotification('session/cancel', {'sessionId': sessionId});
        } catch (_) {
        } finally {
          await client.close();
        }
      }

      try {
        _taskRegistry.registerTask(
          taskId: taskId,
          serverId: harness.id,
          protocol: harness.protocol.wire,
          cancelCallback: cancelAndClose,
        );
      } catch (_) {
        unawaited(promptFuture.catchError((_) => <String, Object?>{}));
        await cancelAndClose();
        rethrow;
      }

      detached = true;
      _attachDetached(taskId, promptFuture, client, textBuffer);
      return AcpPromptOutcome.running(
        mcpServerId: harness.id,
        protocolTaskId: taskId,
      );
    } catch (e) {
      await client.close();
      if (e is XunaHostChannelException) rethrow;
      _fail('mcp_tool_failed');
    }
  }

  Future<String> _initializeAndCreateSession(McpStdioClient client) async {
    Future<Map<String, Object?>> send(String m, Map<String, Object?> p) {
      const t = Duration(seconds: 5);
      return client
          .requestRaw(method: m, params: p, timeout: t)
          .catchError((Object _) => _fail('mcp_handshake_failed'));
    }

    await send('initialize', const {
      'protocolVersion': 1,
      'clientCapabilities': {},
    });
    final newRes = await send('session/new', const {'mcpServers': []});
    final sid = newRes['sessionId'];
    if (sid is! String || sid.trim().isEmpty) _fail('mcp_handshake_failed');
    return sid;
  }

  Future<AcpPromptOutcome> _awaitSync(
    Future<Map<String, Object?>> promptFuture,
    McpStdioClient client,
    StringBuffer textBuffer,
  ) async {
    final result = await promptFuture.catchError(
      (Object _) => _fail('mcp_tool_failed'),
    );
    final summary = _resolveFinalSummary(result, textBuffer.toString());
    await client.close();
    return AcpPromptOutcome.completed(summary: summary);
  }

  void _attachDetached(
    String taskId,
    Future<Map<String, Object?>> promptFuture,
    McpStdioClient client,
    StringBuffer textBuffer,
  ) {
    unawaited(
      promptFuture.then(
        (result) async {
          if (client.isClosed) return;
          final summary = _resolveFinalSummary(result, textBuffer.toString());
          _taskRegistry.completeTask(taskId, summary: summary);
          await client.close();
        },
        onError: (Object error) async {
          if (client.isClosed) return;
          final lost =
              error is McpRpcException &&
              (error.message == 'stdio_stream_closed' ||
                  error.message == 'stdio_stream_error' ||
                  error.message == 'stdio_process_exited');
          if (lost) {
            _taskRegistry.markLost(
              taskId,
              summary: 'ACP harness process exited unexpectedly.',
            );
          } else {
            _taskRegistry.failTask(
              taskId,
              errorCode: 'mcp_tool_failed',
              summary: 'ACP harness turn failed.',
            );
          }
          await client.close();
        },
      ),
    );
  }

  static String _extractPromptText(String toolName, String? payloadJson) {
    if (payloadJson == null || payloadJson.trim().isEmpty) return toolName;
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map) {
      throw const FormatException('payloadJson must decode to a JSON object');
    }
    for (final k in const ['prompt', 'text', 'message', 'input']) {
      final v = decoded[k];
      if (v is String && v.trim().isNotEmpty) return v;
    }
    return jsonEncode(decoded);
  }

  static String? _extractUpdateText(Map<String, Object?> params) {
    final update = params['update'];
    if (update is Map) {
      final content = update['content'];
      if (content is Map && content['text'] is String) {
        return content['text'] as String;
      }
      if (content is List) {
        final joined = content
            .whereType<Map>()
            .map((m) => m['text'])
            .whereType<String>()
            .join();
        if (joined.isNotEmpty) return joined;
      }
      if (update['text'] is String) return update['text'] as String;
    }
    final text = params['text'];
    if (text is String) return text;
    final msg = params['message'];
    return msg is String ? msg : null;
  }

  static int? _extractProgressPercent(Map<String, Object?> params) {
    final u = params['update'];
    final d =
        params['progressPercent'] ?? (u is Map ? u['progressPercent'] : null);
    if (d is num) return d.round().clamp(0, 100);
    final p = params['progress'];
    final t = params['total'];
    return (p is num && t is num && t > 0)
        ? ((p / t) * 100).round().clamp(0, 100)
        : null;
  }

  static String _resolveFinalSummary(Map<String, Object?> result, String buf) {
    const redact = ProtocolTaskRegistry.redactSummary;
    if (buf.trim().isNotEmpty) return redact(buf);
    for (final k in const ['summary', 'text']) {
      final v = result[k];
      if (v is String && v.trim().isNotEmpty) return redact(v);
    }
    final content = result['content'];
    if (content is List) {
      final segs = content
          .whereType<Map>()
          .map((c) => c['text'])
          .whereType<String>()
          .toList();
      if (segs.isNotEmpty) return redact(segs.join('\n'));
    }
    final stop = result['stopReason'];
    if (stop is String && stop.isNotEmpty) {
      return redact('Turn completed ($stop).');
    }
    return result.isEmpty ? 'Turn completed.' : redact(jsonEncode(result));
  }
}

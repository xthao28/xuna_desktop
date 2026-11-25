import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// `exec.*` handlers (`ADR-0018`). The dispatcher has already run the policy
/// evaluator (shellControl switch, Hard-Deny/R3/R2 classification and the
/// approval gate) on these exact arguments before any handler runs.
const List<HostToolHandler> defaultExecToolHandlers = <HostToolHandler>[
  ExecRunTool(),
  ExecStatusTool(),
  ExecWriteStdinTool(),
  ExecCancelTool(),
];

ExecProcessRegistry _registry(ToolExecutionContext context) {
  final registry = context.execRegistry;
  if (registry == null) {
    throw const XunaHostChannelException(
      status: XtpStatus.unsupported,
      errorCode: 'platform_unsupported',
    );
  }
  return registry;
}

Map<String, Object?> _snapshotJson(
  ExecTaskSnapshot s, {
  required String durationKey,
}) => <String, Object?>{
  if (durationKey == 'elapsedMs') 'taskId': s.taskId,
  'status': s.status.wire,
  if (s.status == ExecTaskStatus.running && durationKey == 'durationMs')
    'execTaskId': s.taskId,
  if (s.exitCode != null) 'exitCode': s.exitCode,
  'output': s.output,
  'truncated': s.truncated,
  durationKey: s.elapsedMs,
};

String _summary(ExecTaskSnapshot s) => switch (s.status) {
  ExecTaskStatus.running => 'running ${s.taskId}',
  ExecTaskStatus.completed => 'completed exit=${s.exitCode}',
  ExecTaskStatus.failed => 'failed exit=${s.exitCode}',
  ExecTaskStatus.timedOut => 'timed_out',
  ExecTaskStatus.cancelled => 'cancelled',
};

class ExecRunTool extends HostToolHandler {
  const ExecRunTool();

  @override
  String get name => 'exec.run';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final registry = _registry(context);
    final shell =
        context.policy?.shellControl ?? const ShellControlPolicy.disabled();
    if (!shell.enabled) {
      throw const XunaHostChannelException(
        status: XtpStatus.denied,
        errorCode: 'shell_not_enabled',
      );
    }
    final args = context.arguments;
    final fsContext = context.execFsContext;
    final rawCwd = args['cwd'] as String? ?? fsContext?.homeDirectory;
    final cwd = rawCwd == null
        ? null
        : normalizeHostPath(
            rawCwd,
            homeDirectory: fsContext?.homeDirectory,
            windows: Platform.isWindows,
          );
    if (cwd == null || !Directory(cwd).existsSync()) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'cwd_not_found',
      );
    }
    final pty = args['pty'] == true;
    if (pty && !registry.launcher.supportsPty) {
      throw const XunaHostChannelException(
        status: XtpStatus.unsupported,
        errorCode: 'pty_unsupported_on_platform',
      );
    }
    final timeoutMs = min(
      (args['timeoutMs'] as int?) ?? shell.defaultTimeoutSeconds * 1000,
      shell.maxTimeoutSeconds * 1000,
    );
    // Detach before the call deadline so the dispatcher never reports a
    // timeout for a process that keeps running.
    final deadlineMs = context.deadlineMs ?? 30000;
    final yieldMs = max(
      500,
      min((args['yieldMs'] as int?) ?? 10000, deadlineMs - 1500),
    );
    final snapshot = await registry.run(
      command: args['command']! as String,
      cwd: cwd,
      environment: await buildExecEnvironment(cwd: cwd, pty: pty),
      pty: pty,
      timeout: Duration(milliseconds: timeoutMs),
      yieldAfter: Duration(milliseconds: yieldMs),
      risk: context.evaluation.effectiveRisk,
      concurrencyLimit: shell.maxConcurrentTasks,
    );
    return ToolHandlerOutput(
      text: 'exec.run ${_summary(snapshot)}',
      structuredContent: _snapshotJson(snapshot, durationKey: 'durationMs'),
    );
  }
}

class ExecStatusTool extends HostToolHandler {
  const ExecStatusTool();

  @override
  String get name => 'exec.status';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final taskId = context.arguments['taskId']! as String;
    final snapshot = _registry(context).snapshot(
      taskId,
      tailBytes: (context.arguments['tailBytes'] as int?) ?? 8192,
    );
    if (snapshot == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_task_not_found',
      );
    }
    return ToolHandlerOutput(
      text: 'exec.status ${_summary(snapshot)}',
      structuredContent: _snapshotJson(snapshot, durationKey: 'elapsedMs'),
    );
  }
}

class ExecWriteStdinTool extends HostToolHandler {
  const ExecWriteStdinTool();

  @override
  String get name => 'exec.write_stdin';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final registry = _registry(context);
    final args = context.arguments;
    final taskId = args['taskId']! as String;
    var input = args['input']! as String;
    if (args['appendNewline'] == true) input = '$input\n';
    final written = await registry.writeStdin(
      taskId,
      utf8.encode(input),
      eof: args['eof'] == true,
    );
    if (written < 0) {
      throw const XunaHostChannelException(
        status: XtpStatus.failed,
        errorCode: 'exec_stdin_closed',
      );
    }
    return ToolHandlerOutput(
      text: 'exec.write_stdin $written bytes',
      structuredContent: <String, Object?>{
        'taskId': taskId,
        'status': (registry.statusOf(taskId) ?? ExecTaskStatus.running).wire,
        'bytesWritten': written,
      },
    );
  }
}

class ExecCancelTool extends HostToolHandler {
  const ExecCancelTool();

  @override
  String get name => 'exec.cancel';

  @override
  Future<ToolHandlerOutput> execute(ToolExecutionContext context) async {
    final taskId = context.arguments['taskId']! as String;
    final outcome = await _registry(context).cancel(taskId);
    return ToolHandlerOutput(
      text: 'exec.cancel ${outcome.status}',
      structuredContent: <String, Object?>{
        'taskId': taskId,
        'status': outcome.status,
        'signalSent': outcome.signalSent,
      },
    );
  }
}

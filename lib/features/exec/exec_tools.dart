import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';
import 'package:xuna_desktop/features/exec/exec_output_verifier.dart';
import 'package:xuna_desktop/features/exec/exec_process_registry.dart';
import 'package:xuna_desktop/features/tools/host_remediation_catalog.dart';
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
  if (s.errorCode != null) 'errorCode': s.errorCode,
  if (s.artifacts != null) 'artifacts': s.artifacts,
};

/// `ok`, or `failed` + the `expected_output_*` code when the exit code was 0
/// but `expectFiles` did not match (Rule H1/H4); the structured facts
/// (`artifacts`, output, exit code) are kept either way.
ToolHandlerOutput _output(
  String text,
  ExecTaskSnapshot s,
  String durationKey,
) => ToolHandlerOutput(
  text: s.errorCode == null ? text : '$text ${s.errorCode}',
  structuredContent: _snapshotJson(s, durationKey: durationKey),
  status: s.errorCode == null ? XtpStatus.ok : XtpStatus.failed,
  errorCode: s.errorCode,
);

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
    final expectFiles = args.containsKey('expectFiles')
        ? ExpectedFileSpec.parseList(args['expectFiles'])
        : null;
    if (args.containsKey('expectFiles') && expectFiles == null) {
      throw const XunaHostChannelException(
        status: XtpStatus.invalidArgs,
        errorCode: 'schema_mismatch',
      );
    }
    final command = args['command']! as String;
    final ExecTaskSnapshot snapshot;
    try {
      snapshot = await registry.run(
        command: command,
        cwd: cwd,
        environment: await buildExecEnvironment(cwd: cwd, pty: pty),
        pty: pty,
        timeout: Duration(milliseconds: timeoutMs),
        yieldAfter: Duration(milliseconds: yieldMs),
        risk: context.evaluation.effectiveRisk,
        concurrencyLimit: shell.maxConcurrentTasks,
        verifyOutputs: expectFiles == null
            ? null
            : () => verifyExpectedFiles(
                expectFiles,
                homeDirectory: fsContext?.homeDirectory,
              ),
      );
    } on XunaHostChannelException catch (error) {
      if (error.errorCode == 'exec_spawn_failed') {
        final token = HostRemediationCatalog.extractMissingCommandToken(
          command,
          error.message ?? '',
        );
        final remediation = HostRemediationCatalog.forCommandToken(token);
        if (remediation != null) {
          context.onToolchainRefreshRequested?.call(forceRefresh: true);
          return ToolHandlerOutput(
            status: XtpStatus.failed,
            errorCode: 'toolchain_missing',
            text: 'exec.run failed toolchain_missing ($token)',
            structuredContent: const <String, Object?>{
              'status': 'failed',
              'output': '',
              'truncated': false,
              'durationMs': 0,
              'errorCode': 'toolchain_missing',
            },
            remediation: remediation,
          );
        }
      }
      rethrow;
    }

    if (snapshot.status == ExecTaskStatus.failed &&
        snapshot.errorCode == null &&
        HostRemediationCatalog.isMissingCommandFailure(
          exitCode: snapshot.exitCode,
          output: snapshot.output,
        )) {
      final token = HostRemediationCatalog.extractMissingCommandToken(
        command,
        snapshot.output,
      );
      final remediation = HostRemediationCatalog.forCommandToken(token);
      if (remediation != null) {
        context.onToolchainRefreshRequested?.call(forceRefresh: true);
        return ToolHandlerOutput(
          status: XtpStatus.failed,
          errorCode: 'toolchain_missing',
          text: 'exec.run ${_summary(snapshot)} toolchain_missing ($token)',
          structuredContent: <String, Object?>{
            ..._snapshotJson(snapshot, durationKey: 'durationMs'),
            'errorCode': 'toolchain_missing',
          },
          remediation: remediation,
        );
      }
    }

    if (snapshot.status == ExecTaskStatus.completed &&
        snapshot.errorCode == null &&
        HostRemediationCatalog.isPackageOrToolchainInstallCommand(
          command,
          reasonCode: context.evaluation.reasonCode,
        )) {
      context.onToolchainRefreshRequested?.call(forceRefresh: true);
    }

    return _output('exec.run ${_summary(snapshot)}', snapshot, 'durationMs');
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
    return _output('exec.status ${_summary(snapshot)}', snapshot, 'elapsedMs');
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

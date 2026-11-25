import 'dart:convert';

import '../schemas.dart';
import 'exec_command_classifier.dart';
import 'fs_path_guard.dart';
import 'policy_models.dart';

/// Host facts used to classify `fs.*` and `exec.*` calls (`ADR-0018`).
///
/// The Desktop Agent passes its home directory, platform, a symlink resolver
/// and a lookup of the risk of a running `exec` task. Without a context the
/// classification is lexical only and `~` paths cannot be resolved (they fail
/// as `path_not_absolute`).
class ExecFsHostContext {
  const ExecFsHostContext({
    this.homeDirectory,
    this.windows = false,
    this.caseInsensitive = true,
    this.realPath,
    this.execTaskRisk,
  });

  final String? homeDirectory;
  final bool windows;
  final bool caseInsensitive;
  final String? Function(String normalizedPath)? realPath;
  final RiskTier? Function(String taskId)? execTaskRisk;
}

/// Pattern of an `exec` task id (`exec.status`, `exec.write_stdin`, …).
final RegExp execTaskIdPattern = RegExp(r'^exec_[a-zA-Z0-9_-]{1,64}$');

/// Whether [toolName] is one of the Wave 3 `fs.*` / `exec.*` tools.
bool isExecFsTool(String toolName) =>
    toolName.startsWith('fs.') || toolName.startsWith('exec.');

/// Tools for which the backend must ask `xuna/preflight` before every call.
const Set<String> execFsPreflightTools = <String>{
  'exec.run',
  'exec.write_stdin',
  'fs.write_file',
  'fs.patch_file',
};

const Map<String, Set<String>> _allowedKeys = <String, Set<String>>{
  'fs.list_files': {'path', 'glob', 'maxDepth', 'maxEntries'},
  'fs.read_file': {'path', 'startLine', 'endLine'},
  'fs.grep': {'path', 'pattern', 'isRegex', 'glob', 'maxMatches'},
  'fs.write_file': {'path', 'content', 'createParents', 'overwrite'},
  'fs.patch_file': {'path', 'target', 'replacement', 'replaceAll'},
  'exec.run': {'command', 'cwd', 'timeoutMs', 'yieldMs', 'pty'},
  'exec.status': {'taskId', 'tailBytes'},
  'exec.write_stdin': {'taskId', 'input', 'appendNewline', 'eof'},
  'exec.cancel': {'taskId'},
};

const Map<String, Set<String>> _requiredKeys = <String, Set<String>>{
  'fs.list_files': {'path'},
  'fs.read_file': {'path'},
  'fs.grep': {'path', 'pattern'},
  'fs.write_file': {'path', 'content'},
  'fs.patch_file': {'path', 'target', 'replacement'},
  'exec.run': {'command'},
  'exec.status': {'taskId'},
  'exec.write_stdin': {'taskId', 'input'},
  'exec.cancel': {'taskId'},
};

PolicyEvaluationResult _invalid(String code, [RiskTier risk = RiskTier.r1]) =>
    PolicyEvaluationResult(
      allowed: false,
      status: XtpStatus.invalidArgs,
      effectiveRisk: risk,
      errorCode: code,
    );

PolicyEvaluationResult _denied(String code, String reason) =>
    PolicyEvaluationResult(
      allowed: false,
      status: XtpStatus.denied,
      effectiveRisk: RiskTier.r3,
      errorCode: code,
      reasonCode: reason,
    );

PolicyEvaluationResult _ok(RiskTier risk, String reason) =>
    PolicyEvaluationResult(
      allowed: true,
      status: XtpStatus.ok,
      effectiveRisk: risk,
      reasonCode: reason,
    );

bool _string(Object? v, int min, int max) =>
    v is String && v.length >= min && v.length <= max && !v.contains('\x00');

bool _optInt(Map<String, Object?> a, String key, int min, int max) {
  if (!a.containsKey(key)) return true;
  final v = a[key];
  return v is int && v >= min && v <= max;
}

bool _optBool(Map<String, Object?> a, String key) =>
    !a.containsKey(key) || a[key] is bool;

/// Validates arguments of an `fs.*` / `exec.*` call and returns its effective
/// risk (or the refusal). Exec tools require `shellControl.enabled`.
PolicyEvaluationResult validateExecFsArguments({
  required String toolName,
  required Map<String, Object?> arguments,
  required HostPolicy activePolicy,
  ExecFsHostContext? context,
}) {
  final allowed = _allowedKeys[toolName];
  if (allowed == null) return _invalid('unknown_tool');
  if (arguments.keys.any((k) => !allowed.contains(k)) ||
      _requiredKeys[toolName]!.any((k) => !arguments.containsKey(k))) {
    return _invalid('schema_mismatch');
  }
  final shell = activePolicy.shellControl;
  if (toolName.startsWith('exec.') && !shell.enabled) {
    return _denied('shell_not_enabled', 'policy');
  }
  final ctx = context ?? const ExecFsHostContext();
  switch (toolName) {
    case 'fs.list_files':
    case 'fs.read_file':
    case 'fs.grep':
      if (!_string(arguments['path'], 1, 512) ||
          (arguments.containsKey('glob') &&
              !_string(arguments['glob'], 1, 128)) ||
          !_optInt(arguments, 'maxDepth', 1, 6) ||
          !_optInt(arguments, 'maxEntries', 1, 200) ||
          !_optInt(arguments, 'maxMatches', 1, 100) ||
          !_optBool(arguments, 'isRegex') ||
          (toolName == 'fs.grep' && !_string(arguments['pattern'], 1, 256)) ||
          !_optInt(arguments, 'startLine', 1, 1 << 30) ||
          !_optInt(arguments, 'endLine', 1, 1 << 30)) {
        return _invalid('schema_mismatch');
      }
      final start = (arguments['startLine'] as int?) ?? 1;
      final end = arguments['endLine'] as int?;
      if (end != null && (end < start || end - start + 1 > 400)) {
        return _invalid('line_window_invalid');
      }
      return _pathDecision(
          arguments['path'] as String, FsAccessKind.read, activePolicy, ctx);
    case 'fs.write_file':
      final content = arguments['content'];
      if (!_string(arguments['path'], 1, 512) ||
          content is! String ||
          utf8.encode(content).length > 262144 ||
          !_optBool(arguments, 'createParents') ||
          !_optBool(arguments, 'overwrite')) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      return _pathDecision(
          arguments['path'] as String, FsAccessKind.write, activePolicy, ctx);
    case 'fs.patch_file':
      if (!_string(arguments['path'], 1, 512) ||
          !_string(arguments['target'], 1, 65536) ||
          !_string(arguments['replacement'], 0, 65536) ||
          !_optBool(arguments, 'replaceAll')) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      return _pathDecision(
          arguments['path'] as String, FsAccessKind.write, activePolicy, ctx);
    case 'exec.run':
      final command = arguments['command'];
      if (!_string(command, 1, 4096) ||
          (arguments.containsKey('cwd') &&
              !_string(arguments['cwd'], 1, 512)) ||
          !_optInt(arguments, 'timeoutMs', 1000, 300000) ||
          !_optInt(arguments, 'yieldMs', 500, 60000) ||
          !_optBool(arguments, 'pty')) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      final timeoutMs = arguments['timeoutMs'] as int?;
      if (timeoutMs != null && timeoutMs > shell.maxTimeoutSeconds * 1000) {
        return _invalid('timeout_exceeds_policy', RiskTier.r2);
      }
      if (arguments['pty'] == true && !shell.allowPty) {
        return _denied('pty_not_allowed', 'policy');
      }
      final rawCwd = arguments['cwd'] as String? ?? ctx.homeDirectory;
      String? cwd;
      if (rawCwd != null) {
        cwd = normalizeHostPath(
          rawCwd,
          homeDirectory: ctx.homeDirectory,
          windows: ctx.windows,
        );
        if (cwd == null) return _invalid('path_not_absolute', RiskTier.r2);
        final cwdReason = hardDeniedPathReason(cwd) ??
            hardDeniedPathReason(ctx.realPath?.call(cwd) ?? cwd);
        if (cwdReason != null) return _denied('exec_hard_denied', cwdReason);
      }
      final decision = classifyExecCommand(
        command as String,
        ExecCommandContext(
          shellControl: shell,
          cwd: cwd,
          homeDirectory: ctx.homeDirectory,
          windows: ctx.windows,
          caseInsensitive: ctx.caseInsensitive,
          realPath: ctx.realPath,
        ),
      );
      if (decision.denied) {
        return _denied(decision.errorCode!, decision.reasonCode);
      }
      return decision.risk > RiskTier.r2
          ? _ok(decision.risk, decision.reasonCode)
          : _ok(RiskTier.r2, decision.reasonCode);
    case 'exec.status':
    case 'exec.cancel':
    case 'exec.write_stdin':
      final taskId = arguments['taskId'];
      if (taskId is! String ||
          !execTaskIdPattern.hasMatch(taskId) ||
          !_optInt(arguments, 'tailBytes', 256, 16384) ||
          (toolName == 'exec.write_stdin' &&
              (!_string(arguments['input'], 0, 2048) ||
                  !_optBool(arguments, 'appendNewline') ||
                  !_optBool(arguments, 'eof')))) {
        return _invalid('schema_mismatch');
      }
      if (toolName != 'exec.write_stdin') return _ok(RiskTier.r1, 'observe');
      final parentRisk = ctx.execTaskRisk?.call(taskId);
      return parentRisk != null && parentRisk >= RiskTier.r3
          ? _ok(RiskTier.r3, 'parent_task_r3')
          : _ok(RiskTier.r2, 'stdin');
  }
  return _invalid('unknown_tool');
}

PolicyEvaluationResult _pathDecision(
  String rawPath,
  FsAccessKind access,
  HostPolicy policy,
  ExecFsHostContext ctx,
) {
  final normalized = normalizeHostPath(
    rawPath,
    homeDirectory: ctx.homeDirectory,
    windows: ctx.windows,
  );
  final floor = access == FsAccessKind.read ? RiskTier.r1 : RiskTier.r2;
  if (normalized == null) return _invalid('path_not_absolute', floor);
  final decision = classifyFsPath(
    normalizedPath: normalized,
    resolvedPath: ctx.realPath?.call(normalized),
    access: access,
    shellControl: policy.shellControl,
    homeDirectory: ctx.homeDirectory,
    windows: ctx.windows,
    caseInsensitive: ctx.caseInsensitive,
    realPath: ctx.realPath,
  );
  if (decision.denied) return _denied(decision.errorCode!, decision.reasonCode);
  return _ok(
      decision.risk > floor ? decision.risk : floor, decision.reasonCode);
}

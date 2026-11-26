import 'dart:convert';

import '../draft_manifest.dart';
import '../schemas.dart';
import 'exec_command_classifier.dart';
import 'exec_expected_outputs.dart';
import 'fs_path_guard.dart';
import 'policy_models.dart';
import 'shell_control_policy.dart';

/// Host facts used to classify `fs.*`, `exec.*`, and `draft.*` calls
/// (`ADR-0018`, `ADR-0019`).
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

/// Pattern of an `exec` task id (`exec.status`, `exec.write_stdin`, ...).
final RegExp execTaskIdPattern = RegExp(r'^exec_[a-zA-Z0-9_-]{1,64}$');
final RegExp _lowerSha256Re = RegExp(r'^[0-9a-f]{64}$');
final RegExp _workspaceAliasRe = RegExp(r'^[a-zA-Z0-9_.-]{1,64}$');

/// Whether [toolName] is one of the Wave 3/4 `fs.*` / `exec.*` / `draft.*` tools.
bool isExecFsTool(String toolName) =>
    toolName.startsWith('fs.') ||
    toolName.startsWith('exec.') ||
    toolName.startsWith('draft.');

/// Tools for which the backend must ask `xuna/preflight` before every call.
const Set<String> execFsPreflightTools = <String>{
  'exec.run',
  'exec.write_stdin',
  'fs.write_file',
  'fs.patch_file',
  'draft.apply',
};

const Map<String, Set<String>> _allowedKeys = <String, Set<String>>{
  'fs.list_files': {'path', 'glob', 'maxDepth', 'maxEntries', 'draftId'},
  'fs.read_file': {'path', 'startLine', 'endLine', 'draftId'},
  'fs.grep': {'path', 'pattern', 'isRegex', 'glob', 'maxMatches', 'draftId'},
  'fs.write_file': {'path', 'content', 'createParents', 'overwrite', 'draftId'},
  'fs.patch_file': {
    'path',
    'target',
    'replacement',
    'replaceAll',
    'draftId',
  },
  'exec.run': {
    'command',
    'cwd',
    'timeoutMs',
    'yieldMs',
    'pty',
    'expectFiles',
    'draftId',
  },
  'exec.status': {'taskId', 'tailBytes'},
  'exec.write_stdin': {'taskId', 'input', 'appendNewline', 'eof'},
  'exec.cancel': {'taskId'},
  'draft.create': {'workspacePath', 'workspaceAlias'},
  'draft.manifest': {'draftId'},
  'draft.discard': {'draftId'},
  'draft.apply': {'draftId', 'effectSha256'},
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
  'draft.create': {'workspacePath'},
  'draft.manifest': {'draftId'},
  'draft.discard': {'draftId'},
  'draft.apply': {'draftId', 'effectSha256'},
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

bool _optDraftIdValid(Map<String, Object?> a) {
  if (!a.containsKey('draftId')) return true;
  final v = a['draftId'];
  return v is String && draftIdPattern.hasMatch(v);
}

/// Validates arguments of an `fs.*` / `exec.*` / `draft.*` call and returns its
/// effective risk (or the refusal). Exec tools require `shellControl.enabled`.
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
  final hasDraftId = arguments.containsKey('draftId');
  switch (toolName) {
    case 'fs.list_files':
    case 'fs.read_file':
    case 'fs.grep':
      if (!_string(arguments['path'], 1, 512) ||
          !_optDraftIdValid(arguments) ||
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
          !_optDraftIdValid(arguments) ||
          content is! String ||
          utf8.encode(content).length > 262144 ||
          !_optBool(arguments, 'createParents') ||
          !_optBool(arguments, 'overwrite')) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      final writeDecision = _pathDecision(
          arguments['path'] as String, FsAccessKind.write, activePolicy, ctx);
      if (hasDraftId &&
          writeDecision.allowed &&
          writeDecision.effectiveRisk >= RiskTier.r3) {
        return _denied('draft_r3_forbidden', 'draft_mode');
      }
      return writeDecision;
    case 'fs.patch_file':
      if (!_string(arguments['path'], 1, 512) ||
          !_optDraftIdValid(arguments) ||
          !_string(arguments['target'], 1, 65536) ||
          !_string(arguments['replacement'], 0, 65536) ||
          !_optBool(arguments, 'replaceAll')) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      final patchDecision = _pathDecision(
          arguments['path'] as String, FsAccessKind.write, activePolicy, ctx);
      if (hasDraftId &&
          patchDecision.allowed &&
          patchDecision.effectiveRisk >= RiskTier.r3) {
        return _denied('draft_r3_forbidden', 'draft_mode');
      }
      return patchDecision;
    case 'exec.run':
      final command = arguments['command'];
      if (!_string(command, 1, 4096) ||
          !_optDraftIdValid(arguments) ||
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
      if (arguments.containsKey('expectFiles')) {
        final refusal = _expectFilesRefusal(arguments['expectFiles'], ctx);
        if (refusal != null) return refusal;
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
      if (hasDraftId && decision.risk >= RiskTier.r3) {
        return _denied('draft_r3_forbidden', 'draft_mode');
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
    case 'draft.create':
      if (!_string(arguments['workspacePath'], 1, 512)) {
        return _invalid('schema_mismatch', RiskTier.r2);
      }
      if (arguments.containsKey('workspaceAlias')) {
        final alias = arguments['workspaceAlias'];
        if (alias is! String ||
            !_workspaceAliasRe.hasMatch(alias) ||
            alias == '.' ||
            alias == '..' ||
            alias.contains('..')) {
          return _invalid('schema_mismatch', RiskTier.r2);
        }
      }
      final rawWs = arguments['workspacePath'] as String;
      final normWs = normalizeHostPath(
        rawWs,
        homeDirectory: ctx.homeDirectory,
        windows: ctx.windows,
      );
      if (normWs == null) return _invalid('path_not_absolute', RiskTier.r2);
      final resolvedWs = ctx.realPath?.call(normWs);
      final wsHard = hardDeniedPathReason(normWs) ??
          (resolvedWs == null ? null : hardDeniedPathReason(resolvedWs));
      if (wsHard != null) return _denied('fs_path_forbidden', wsHard);
      if (isSecretFileName(normWs) ||
          (resolvedWs != null && isSecretFileName(resolvedWs))) {
        return _denied('fs_secret_file_forbidden', 'secret_file');
      }
      if (!_isInsideConfiguredWorkspaceRoots(normWs, resolvedWs, shell, ctx)) {
        return _denied('fs_outside_workspace', 'outside_workspace');
      }
      return _ok(RiskTier.r2, 'draft_create');
    case 'draft.manifest':
      final draftId = arguments['draftId'];
      if (draftId is! String || !draftIdPattern.hasMatch(draftId)) {
        return _invalid('schema_mismatch');
      }
      return _ok(RiskTier.r1, 'observe');
    case 'draft.discard':
      final draftId = arguments['draftId'];
      if (draftId is! String || !draftIdPattern.hasMatch(draftId)) {
        return _invalid('schema_mismatch');
      }
      return _ok(RiskTier.r1, 'draft_discard');
    case 'draft.apply':
      final draftId = arguments['draftId'];
      final effectSha256 = arguments['effectSha256'];
      if (draftId is! String ||
          !draftIdPattern.hasMatch(draftId) ||
          effectSha256 is! String ||
          !_lowerSha256Re.hasMatch(effectSha256)) {
        return _invalid('schema_mismatch', RiskTier.r3);
      }
      return _ok(RiskTier.r3, 'draft_apply');
  }
  return _invalid('unknown_tool');
}

bool _isInsideConfiguredWorkspaceRoots(
  String normalizedPath,
  String? resolvedPath,
  ShellControlPolicy shell,
  ExecFsHostContext ctx,
) {
  if (shell.workspaceRoots.isEmpty) return false;
  for (final rawRoot in shell.workspaceRoots) {
    final normRoot = normalizeHostPath(
      rawRoot,
      homeDirectory: ctx.homeDirectory,
      windows: ctx.windows,
    );
    if (normRoot == null) continue;
    final resolvedRoot = ctx.realPath?.call(normRoot) ?? normRoot;
    final lexicalOk = isPathInsideRoot(
      normalizedPath,
      normRoot,
      caseInsensitive: ctx.caseInsensitive,
    );
    final realOk = resolvedPath == null ||
        isPathInsideRoot(
          resolvedPath,
          resolvedRoot,
          caseInsensitive: ctx.caseInsensitive,
        );
    if (lexicalOk && realOk) return true;
  }
  return false;
}

/// Checks `exec.run` `expectFiles` (P1.1): schema, then every path through
/// [classifyFsPath] as a read, so a Hard-Deny location or a secret file can
/// never be named as an expected output. Reading file facts does not raise
/// the command's risk. Returns null when every entry is acceptable.
PolicyEvaluationResult? _expectFilesRefusal(
  Object? raw,
  ExecFsHostContext ctx,
) {
  final specs = ExpectedFileSpec.parseList(raw);
  if (specs == null) return _invalid('schema_mismatch', RiskTier.r2);
  for (final spec in specs) {
    final normalized = normalizeHostPath(
      spec.path,
      homeDirectory: ctx.homeDirectory,
      windows: ctx.windows,
    );
    if (normalized == null) return _invalid('path_not_absolute', RiskTier.r2);
    final decision = classifyFsPath(
      normalizedPath: normalized,
      resolvedPath: ctx.realPath?.call(normalized),
      access: FsAccessKind.read,
      shellControl: const ShellControlPolicy.disabled(),
      homeDirectory: ctx.homeDirectory,
      windows: ctx.windows,
      caseInsensitive: ctx.caseInsensitive,
      realPath: ctx.realPath,
    );
    if (decision.denied) {
      return _denied(decision.errorCode!, decision.reasonCode);
    }
  }
  return null;
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

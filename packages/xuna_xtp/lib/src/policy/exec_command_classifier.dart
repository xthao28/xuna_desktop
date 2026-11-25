import '../schemas.dart';
import 'exec_command_lexer.dart';
import 'fs_path_guard.dart';
import 'shell_control_policy.dart';

part 'exec_command_rules.dart';

/// Host facts the classifier needs. [cwd] and [homeDirectory] are local
/// absolute paths; [realPath] resolves symlinks of an existing normalized
/// path (returns `null` when it does not exist or cannot be resolved).
class ExecCommandContext {
  const ExecCommandContext({
    required this.shellControl,
    this.cwd,
    this.homeDirectory,
    this.windows = false,
    this.caseInsensitive = true,
    this.realPath,
  });

  final ShellControlPolicy shellControl;
  final String? cwd;
  final String? homeDirectory;
  final bool windows;
  final bool caseInsensitive;
  final String? Function(String normalizedPath)? realPath;
}

/// Classifies an `exec.run` [command] (`ADR-0018` Hard-Deny / `R3` / `R2`).
///
/// Every segment (pipes, chains, substitutions) is inspected. `R2` is a
/// positive allowlist of local build/test/inspection commands; anything not
/// positively classified is `R3`. Privilege escalation, credential stores,
/// secret paths, environment dumps and catastrophic commands are refused.
FsGuardDecision classifyExecCommand(String command, ExecCommandContext ctx) =>
    _classify(command, ctx, 0);

const _hardDenied = 'exec_hard_denied';

FsGuardDecision _classify(String command, ExecCommandContext ctx, int depth) {
  final compact = command.replaceAll(RegExp(r'\s'), '');
  if (compact.contains(':(){') ||
      compact.contains(':|:&') ||
      RegExp(r'(\w+)\(\)\{\1\|\1&').hasMatch(compact)) {
    return const FsGuardDecision.deny(_hardDenied, 'fork_bomb');
  }
  if (command.toLowerCase().contains('administrator privileges')) {
    return const FsGuardDecision.deny(_hardDenied, 'privilege_escalation');
  }
  if (depth > 3) return const FsGuardDecision.allow(RiskTier.r3, 'nested');
  final lex = lexExecCommand(command, windows: ctx.windows);
  var decision = const FsGuardDecision.allow(RiskTier.r1, 'empty');
  if (lex.segments.isEmpty && lex.substitutions.isEmpty) {
    return const FsGuardDecision.allow(RiskTier.r3, 'unparseable');
  }
  for (final body in lex.substitutions) {
    decision = decision.merge(_classify(body, ctx, depth + 1));
    decision = decision.merge(
      const FsGuardDecision.allow(RiskTier.r3, 'dynamic_subshell'),
    );
  }
  for (final segment in lex.segments) {
    decision = decision.merge(_classifySegment(segment, ctx));
    if (decision.denied) return decision;
  }
  if (lex.malformed || lex.hasHeredoc) {
    decision = decision.merge(
      const FsGuardDecision.allow(RiskTier.r3, 'unparseable'),
    );
  }
  return decision;
}

FsGuardDecision _classifySegment(ExecSegment segment, ExecCommandContext ctx) {
  var decision = const FsGuardDecision.allow(RiskTier.r2, 'local_command');
  for (final w in [...segment.words, ...segment.readTargets]) {
    decision = decision.merge(_checkPathWord(w.text, ctx));
    if (decision.denied) return decision;
  }
  for (final target in segment.writeTargets) {
    decision = decision.merge(_checkPathWord(target.text, ctx));
    decision = decision.merge(_writeTarget(target, ctx));
    if (decision.denied) return decision;
  }
  final words = segment.words;
  var k = 0;
  while (k < words.length &&
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[k].text)) {
    k++;
  }
  // Transparent wrappers that run the following command.
  while (k < words.length) {
    final name = _exeName(words[k].text, ctx.windows);
    if (const {
      'command',
      'builtin',
      'exec',
      'nohup',
      'time',
      'nice',
      'caffeinate'
    }.contains(name)) {
      k++;
      while (k < words.length && words[k].text.startsWith('-')) {
        k++;
      }
    } else if (name == 'timeout' || name == 'gtimeout') {
      k++;
      while (k < words.length && words[k].text.startsWith('-')) {
        k++;
      }
      k++;
    } else if (name == 'env') {
      k++;
      while (k < words.length &&
          (words[k].text.startsWith('-') || words[k].text.contains('='))) {
        if (words[k].text == '-S' || words[k].text.startsWith('--split')) {
          return const FsGuardDecision.allow(RiskTier.r3, 'dynamic_execution');
        }
        k++;
      }
      if (k >= words.length) {
        return const FsGuardDecision.deny(
            'exec_env_dump_forbidden', 'env_dump');
      }
    } else if (name == 'fvm') {
      k++;
    } else {
      break;
    }
  }
  if (k >= words.length) return decision;
  final exeWord = words[k];
  final exe = _exeName(exeWord.text, ctx.windows);
  final args = [for (final w in words.skip(k + 1)) w.text];
  if (exeWord.hasExpansion) {
    return decision.merge(
      const FsGuardDecision.allow(RiskTier.r3, 'dynamic_executable'),
    );
  }
  final hard = _hardDenyRule(exe, args, ctx);
  if (hard != null) return hard;
  if (segment.pipedFrom && _interpreters.contains(exe)) {
    return decision.merge(
      const FsGuardDecision.allow(RiskTier.r3, 'pipe_to_interpreter'),
    );
  }
  return decision.merge(_riskRule(exe, args, segment, ctx));
}

String _exeName(String word, bool windows) {
  var name = word.replaceAll(r'\', '/').split('/').last.toLowerCase();
  if (windows) {
    name = name.replaceFirst(RegExp(r'\.(exe|cmd|bat|com)$'), '');
  }
  return name;
}

FsGuardDecision _riskRule(
  String exe,
  List<String> args,
  ExecSegment segment,
  ExecCommandContext ctx,
) {
  const r2 = FsGuardDecision.allow(RiskTier.r2, 'local_command');
  const r3 = FsGuardDecision.allow(RiskTier.r3, 'unclassified_command');
  const net = FsGuardDecision.allow(RiskTier.r3, 'network_command');
  const inline = FsGuardDecision.allow(RiskTier.r3, 'inline_code');
  final positional = [
    for (final a in args)
      if (!a.startsWith('-')) a
  ];
  final sub = positional.isEmpty ? '' : positional.first.toLowerCase();
  if (_network.contains(exe)) return net;
  if (_readOnly.contains(exe)) return r2;
  if (exe == 'set' || exe == 'export' || exe == 'unset') {
    // Bare `set` / `export` / `export -p` are refused earlier as env dumps.
    return r2;
  }
  if (_destructive.contains(exe)) {
    return const FsGuardDecision.allow(RiskTier.r3, 'destructive_command');
  }
  if (exe == 'awk' || exe == 'gawk' || exe == 'sed') {
    if (args.any((a) =>
        a.contains('system') ||
        a.contains('getline') ||
        RegExp(r'(^|[;}\s])[ew]\s').hasMatch(a))) {
      return inline;
    }
    if (exe == 'sed' &&
        args.any((a) =>
            a == '-i' || a.startsWith('-i') || a.startsWith('--in-place'))) {
      return _writeTargets(positional.skip(1), ctx);
    }
    return r2;
  }
  if (exe == 'rg' && args.any((a) => a.startsWith('--pre'))) return inline;
  if (exe == 'find') {
    const actions = {
      '-delete',
      '-exec',
      '-execdir',
      '-ok',
      '-okdir',
      '-fprint',
      '-fprintf',
      '-fls'
    };
    return args.any(actions.contains) ? r3 : r2;
  }
  if (_devTools.contains(exe)) return r2;
  if (_writeCommands.contains(exe)) {
    final targets = exe == 'cp'
        ? positional.skip(positional.length > 1 ? positional.length - 1 : 0)
        : positional;
    return _writeTargets(targets, ctx);
  }
  if (exe == 'git') return _gitRule(args);
  if (_jsPackageManagers.contains(exe)) {
    return _jsR2Subcommands.contains(sub) ||
            (args.isNotEmpty && _jsR2Subcommands.contains(args.first))
        ? r2
        : r3;
  }
  if (exe == 'node') {
    if (args.any((a) => const {
          '-e',
          '--eval',
          '-p',
          '--print',
          '-pe',
          '-r',
          '--require'
        }.contains(a))) {
      return inline;
    }
    return r2;
  }
  if (RegExp(r'^python(\d+(\.\d+)*)?$').hasMatch(exe)) {
    // Only interpreter options before the script/module name matter.
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '-m') {
        final module = i + 1 < args.length ? args[i + 1] : '';
        if (module == 'pip') return _pipRule(args.skip(i + 2).toList());
        return _pythonR2Modules.contains(module) ? r2 : r3;
      }
      if (a.startsWith('-') && !a.startsWith('--') && a.contains('c')) {
        return inline;
      }
      if (!a.startsWith('-')) return r2;
    }
    return r2;
  }
  if (exe == 'pip' || exe == 'pip3') return _pipRule(args);
  if (exe == 'flutter' || exe == 'dart') {
    const ok = {
      'test',
      'analyze',
      'build',
      'format',
      'run',
      'doctor',
      '--version',
      'fix',
      'devices'
    };
    return ok.contains(sub) || args.contains('--version') ? r2 : r3;
  }
  if (exe == 'cargo') {
    const ok = {
      'test',
      'check',
      'build',
      'clippy',
      'fmt',
      'run',
      'doc',
      'bench',
      'tree',
      'metadata',
      '--version'
    };
    return ok.contains(sub) || args.contains('--version') ? r2 : r3;
  }
  if (exe == 'go') {
    const ok = {'test', 'build', 'vet', 'fmt', 'run', 'list', 'version', 'doc'};
    return ok.contains(sub) ? r2 : r3;
  }
  if (exe == 'swift') {
    return const {'build', 'test', 'run', '--version'}.contains(sub) ? r2 : r3;
  }
  if (_interpreters.contains(exe)) return inline;
  return r3;
}

FsGuardDecision _checkPathWord(String raw, ExecCommandContext ctx) {
  for (final candidate in raw.split('=')) {
    if (candidate.isEmpty) continue;
    final looksLikePath = candidate.contains('/') ||
        (ctx.windows && candidate.contains(r'\')) ||
        candidate.startsWith('~') ||
        candidate.startsWith(r'$HOME') ||
        candidate.startsWith(r'${HOME}') ||
        candidate.startsWith('.');
    // A bare word may still name an existing entry (or a symlink) in cwd, so
    // it is resolved when the host can resolve paths; flags are skipped.
    final resolvable = looksLikePath ||
        (ctx.realPath != null && ctx.cwd != null && !candidate.startsWith('-'));
    if (!resolvable && !isSecretFileName(candidate)) continue;
    final normalized = normalizeHostPath(
      candidate,
      homeDirectory: ctx.homeDirectory,
      baseDirectory: ctx.cwd,
      windows: ctx.windows,
    );
    for (final path in [
      candidate,
      normalized,
      if (normalized != null) ctx.realPath?.call(normalized)
    ]) {
      if (path == null) continue;
      final reason = hardDeniedPathReason(path);
      if (reason != null) return FsGuardDecision.deny(_hardDenied, reason);
      if (isSecretFileName(path)) {
        return const FsGuardDecision.deny(_hardDenied, 'secret_file');
      }
    }
  }
  return const FsGuardDecision.allow(RiskTier.r1, 'path_ok');
}

FsGuardDecision _writeTarget(ExecWord target, ExecCommandContext ctx) {
  final t = target.text;
  if (t == '/dev/null' ||
      t == '/dev/stdout' ||
      t == '/dev/stderr' ||
      (ctx.windows && t.toLowerCase() == 'nul')) {
    return const FsGuardDecision.allow(RiskTier.r1, 'null_sink');
  }
  if (target.hasExpansion) {
    return const FsGuardDecision.allow(RiskTier.r3, 'dynamic_write_target');
  }
  return _writeTargets([t], ctx);
}

FsGuardDecision _writeTargets(
    Iterable<String> targets, ExecCommandContext ctx) {
  var decision = const FsGuardDecision.allow(RiskTier.r2, 'workspace_write');
  for (final t in targets) {
    final normalized = normalizeHostPath(
      t,
      homeDirectory: ctx.homeDirectory,
      baseDirectory: ctx.cwd,
      windows: ctx.windows,
    );
    if (normalized == null) {
      return const FsGuardDecision.allow(RiskTier.r3, 'outside_workspace');
    }
    decision = decision.merge(
      classifyFsPath(
        normalizedPath: normalized,
        resolvedPath: ctx.realPath?.call(normalized),
        access: FsAccessKind.write,
        shellControl: ctx.shellControl,
        homeDirectory: ctx.homeDirectory,
        windows: ctx.windows,
        caseInsensitive: ctx.caseInsensitive,
        realPath: ctx.realPath,
      ),
    );
    if (decision.denied) return decision;
  }
  return decision;
}

part of 'exec_command_classifier.dart';

// Command tables and per-command rules for `classifyExecCommand`.

const Set<String> _privilege = <String>{
  'sudo',
  'su',
  'doas',
  'pkexec',
  'runas'
};
const Set<String> _credentialClis = <String>{
  'op',
  'bw',
  'keepassxc-cli',
  'lpass',
  'pass',
};
const Set<String> _keychainSubcommands = <String>{
  'find-generic-password',
  'find-internet-password',
  'dump-keychain',
  'export',
  'find-certificate',
};
const Set<String> _shutdown = <String>{
  'shutdown',
  'reboot',
  'halt',
  'poweroff',
  'format',
};
const Set<String> _interpreters = <String>{
  'sh', 'bash', 'zsh', 'fish', 'dash', 'ksh', 'csh', 'tcsh', 'cmd', //
  'pwsh', 'powershell', 'python', 'python3', 'node', 'perl', 'ruby',
  'php', 'deno', 'bun', 'osascript', 'lua', 'tclsh',
};
const Set<String> _network = <String>{
  'curl', 'wget', 'http', 'https', 'ssh', 'scp', 'sftp', 'rsync', 'nc', //
  'ncat', 'netcat', 'telnet', 'ftp', 'tftp', 'dig', 'nslookup', 'nmap',
  'gh', 'aws', 'gcloud', 'az', 'firebase', 'twine', 'kubectl', 'helm',
};
const Set<String> _readOnly = <String>{
  'ls', 'pwd', 'cat', 'head', 'tail', 'wc', 'sort', 'uniq', 'diff', 'cmp', //
  'jq', 'grep', 'egrep', 'fgrep', 'tree', 'file', 'stat', 'du', 'df',
  'echo', 'printf', 'true', 'false', 'test', '[', 'which', 'whereis',
  'type', 'basename', 'dirname', 'realpath', 'readlink', 'date', 'uname',
  'whoami', 'id', 'cut', 'tr', 'column', 'nl', 'cd', 'pushd', 'popd',
  'sleep', 'seq', 'dir', 'where', 'findstr', 'more', 'wait',
};
const Set<String> _destructive = <String>{
  'rm', 'rmdir', 'rd', 'del', 'erase', 'unlink', 'shred', 'chmod', 'chown', //
  'chgrp', 'mv', 'move', 'kill', 'pkill', 'killall', 'taskkill', 'launchctl',
  'systemctl', 'service', 'sc', 'reg', 'defaults', 'docker', 'podman', 'brew',
  'apt', 'apt-get', 'yum', 'dnf', 'winget', 'choco', 'port', 'snap', 'crontab',
};
const Set<String> _devTools = <String>{
  'pytest', 'ruff', 'mypy', 'black', 'isort', 'flake8', 'pylint', 'tsc', //
  'eslint', 'prettier', 'jest', 'vitest', 'mocha', 'make', 'cmake',
  'ninja', 'xcodebuild',
};
const Set<String> _jsPackageManagers = <String>{'npm', 'pnpm', 'yarn', 'bun'};
const Set<String> _jsR2Subcommands = <String>{
  'test', 't', 'tst', 'run', 'run-script', 'build', 'lint', 'start', //
  'typecheck', '-v', '--version', 'ls', 'list', 'outdated', 'why',
};
const Set<String> _pythonR2Modules = <String>{
  'pytest', 'unittest', 'mypy', 'ruff', 'black', 'flake8', 'pylint', //
  'compileall', 'json.tool', 'venv',
};
const Set<String> _gitR2 = <String>{
  'status', 'diff', 'log', 'show', 'add', 'commit', 'rev-parse', //
  'ls-files', 'blame', 'switch', 'shortlog', 'describe', 'grep',
};
const Set<String> _writeCommands = <String>{'mkdir', 'touch', 'cp', 'tee'};

FsGuardDecision? _hardDenyRule(
  String exe,
  List<String> args,
  ExecCommandContext ctx,
) {
  if (_privilege.contains(exe)) {
    return const FsGuardDecision.deny(_hardDenied, 'privilege_escalation');
  }
  if (_credentialClis.contains(exe)) {
    return const FsGuardDecision.deny(_hardDenied, 'credential_store');
  }
  if (exe == 'security' && args.any(_keychainSubcommands.contains)) {
    return const FsGuardDecision.deny(_hardDenied, 'credential_store');
  }
  final bareArgs = args.where((a) => !a.startsWith('-')).isEmpty;
  if (exe == 'printenv' ||
      (exe == 'export' && (args.isEmpty || args.contains('-p'))) ||
      (exe == 'set' && args.isEmpty) ||
      ((exe == 'declare' || exe == 'typeset') && bareArgs) ||
      (exe == 'env' && args.isEmpty)) {
    return const FsGuardDecision.deny('exec_env_dump_forbidden', 'env_dump');
  }
  if (_shutdown.contains(exe) ||
      exe.startsWith('mkfs') ||
      exe.startsWith('newfs')) {
    return const FsGuardDecision.deny(_hardDenied, 'catastrophic');
  }
  if (exe == 'dd' && args.any((a) => a.startsWith('of=/dev/'))) {
    return const FsGuardDecision.deny(_hardDenied, 'catastrophic');
  }
  if (exe == 'diskutil' &&
      args.any((a) => RegExp(
              r'^(erase|zero|random|secureerase|partition|reformat)',
              caseSensitive: false)
          .hasMatch(a))) {
    return const FsGuardDecision.deny(_hardDenied, 'catastrophic');
  }
  if (exe == 'rm' || exe == 'rd' || exe == 'rmdir' || exe == 'del') {
    final recursive = args.any((a) =>
        a == '--recursive' ||
        a.toLowerCase() == '/s' ||
        RegExp(r'^-[A-Za-z]*[rR]').hasMatch(a));
    if (recursive && args.any((a) => _isCatastrophicTarget(a, ctx))) {
      return const FsGuardDecision.deny(_hardDenied, 'catastrophic');
    }
  }
  if (exe == 'chmod' &&
      args.any((a) =>
          RegExp(r'^[ugoa]*[+=][rwxXt]*s').hasMatch(a) ||
          RegExp(r'^[2-7][0-7]{3}$').hasMatch(a))) {
    return const FsGuardDecision.deny(_hardDenied, 'setuid');
  }
  if ((exe == 'chown' || exe == 'chgrp') &&
      args.any((a) => RegExp(r'^(root|0|wheel)([:.]|$)').hasMatch(a))) {
    return const FsGuardDecision.deny(_hardDenied, 'root_ownership');
  }
  return null;
}

bool _isCatastrophicTarget(String raw, ExecCommandContext ctx) {
  final t = raw.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  const exact = <String>{
    '', '/', '/*', '~', '~/*', r'$home', r'${home}', r'$home/*', r'$user', //
    '..', '../*', '*', '.', '/users', '/home', '/system', '/library',
  };
  if (exact.contains(t.toLowerCase()) ||
      RegExp(r'^[A-Za-z]:(/\*?)?$').hasMatch(t)) {
    return true;
  }
  // The home directory itself (or its glob) reached through any spelling.
  final home = ctx.homeDirectory == null
      ? null
      : normalizeHostPath(ctx.homeDirectory!, windows: ctx.windows);
  final target = normalizeHostPath(
    t.endsWith('/*') ? t.substring(0, t.length - 2) : t,
    homeDirectory: ctx.homeDirectory,
    baseDirectory: ctx.cwd,
    windows: ctx.windows,
  );
  return home != null &&
      target != null &&
      target.toLowerCase() == home.toLowerCase();
}

FsGuardDecision _pipRule(List<String> args) {
  final sub = args.firstWhere((a) => !a.startsWith('-'), orElse: () => '');
  return const {'list', 'show', 'freeze', 'check'}.contains(sub) ||
          args.contains('--version')
      ? const FsGuardDecision.allow(RiskTier.r2, 'local_command')
      : const FsGuardDecision.allow(RiskTier.r3, 'package_install');
}

FsGuardDecision _gitRule(List<String> args) {
  const r2 = FsGuardDecision.allow(RiskTier.r2, 'local_command');
  const destructive = FsGuardDecision.allow(RiskTier.r3, 'destructive_command');
  if (args.isNotEmpty &&
      (args.first == '-c' || args.first.startsWith('--config'))) {
    return destructive;
  }
  var rest = args;
  if (rest.length >= 2 && rest.first == '-C') rest = rest.sublist(2);
  if (rest.isEmpty) return r2;
  final sub = rest.first;
  final tail = rest.skip(1).toList();
  if (const {
    'push',
    'fetch',
    'pull',
    'clone',
    'remote',
    'submodule',
    'ls-remote'
  }.contains(sub)) {
    return const FsGuardDecision.allow(RiskTier.r3, 'network_command');
  }
  if (_gitR2.contains(sub)) return r2;
  switch (sub) {
    case 'branch':
      return tail.any((a) => const {
                '-D',
                '-d',
                '--delete',
                '-M',
                '-m',
                '--force',
                '-f'
              }.contains(a))
          ? destructive
          : r2;
    case 'stash':
      return tail.isEmpty ||
              const {'push', 'list', 'show', 'save'}.contains(tail.first)
          ? r2
          : destructive;
    case 'checkout':
      return tail
              .any((a) => a == '--' || a == '.' || a == '-f' || a == '--force')
          ? destructive
          : r2;
    case 'reset':
      return tail.any((a) => a == '--hard' || a == '--merge' || a == '--keep')
          ? destructive
          : r2;
    case 'tag':
      return tail.isEmpty || tail.every((a) => a == '-l' || a == '--list')
          ? r2
          : destructive;
  }
  return destructive;
}

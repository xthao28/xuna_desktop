import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// Host-owned, platform-aware catalog of display-only remediations for missing
/// developer toolchains, IDEs, and coding agents (`§5.1`, P1.2 / U4).
///
/// Unknown commands or dependencies fail closed (`null`) — never fabricates
/// installation instructions.
class HostRemediationCatalog {
  const HostRemediationCatalog._();

  static final RegExp _winNotRecognizedRe = RegExp(
    r"'([^'\r\n]+)'\s+is not recognized",
    caseSensitive: false,
  );
  static final RegExp _zshCommandNotFoundRe = RegExp(
    r'command not found:\s*([^\s:\r\n]+)',
    caseSensitive: false,
  );
  static final RegExp _posixCommandNotFoundRe = RegExp(
    r'([^\s:/\\\r\n]+):\s*(?:command )?not found',
    caseSensitive: false,
  );

  static const Set<String> _transparentWrappers = <String>{
    'command',
    'builtin',
    'exec',
    'nohup',
    'time',
    'nice',
    'caffeinate',
    'fvm',
  };

  static const Set<String> _shellSetupBuiltins = <String>{
    'cd',
    'pushd',
    'popd',
    'set',
    'export',
    'unset',
    'echo',
    'printf',
  };

  static const Set<String> _packageManagers = <String>{
    'winget',
    'choco',
    'scoop',
    'brew',
    'apt',
    'apt-get',
    'dnf',
    'yum',
    'pip',
    'pip3',
    'npm',
    'pnpm',
    'yarn',
    'bun',
    'cargo',
    'rustup',
    'fvm',
    'go',
    'dart',
    'flutter',
  };

  static const Set<String> _packageMutationVerbs = <String>{
    'install',
    'i',
    'add',
    'upgrade',
    'update',
    'uninstall',
    'remove',
    'global',
    'toolchain',
  };

  /// Returns `true` when an `exec.run` failure indicates a missing binary/command
  /// (`exec_spawn_failed`, Windows exit `9009`, POSIX exit `127`, or shell
  /// missing-command diagnostics).
  static bool isMissingCommandFailure({
    required int? exitCode,
    required String output,
    bool execSpawnFailed = false,
  }) {
    if (execSpawnFailed) return true;
    if (exitCode == 9009 || exitCode == 127) return true;
    if (exitCode != null && exitCode != 0) {
      final lower = output.toLowerCase();
      if (lower.contains('is not recognized') ||
          lower.contains('command not found')) {
        return true;
      }
    }
    return false;
  }

  /// Extracts the normalized leading command token that failed to resolve in
  /// `exec.run`, preferring explicit command names reported in [output] and
  /// falling back to the first non-builtin command in [command].
  static String? extractMissingCommandToken(
    String command,
    String output, {
    bool? isWindows,
  }) {
    final win = isWindows ?? Platform.isWindows;

    final winMatch = _winNotRecognizedRe.firstMatch(output);
    if (winMatch != null) {
      final norm = normalizeCommandToken(winMatch.group(1)!, isWindows: win);
      if (norm.isNotEmpty) return norm;
    }

    final zshMatch = _zshCommandNotFoundRe.firstMatch(output);
    if (zshMatch != null) {
      final norm = normalizeCommandToken(zshMatch.group(1)!, isWindows: win);
      if (norm.isNotEmpty) return norm;
    }

    for (final match in _posixCommandNotFoundRe.allMatches(output)) {
      final candidate = (match.group(1) ?? '').trim();
      if (candidate.isEmpty || int.tryParse(candidate) != null) continue;
      final lower = candidate.toLowerCase();
      if (const <String>{'sh', 'bash', 'zsh', 'dash', 'cmd'}.contains(lower)) {
        continue;
      }
      final norm = normalizeCommandToken(candidate, isWindows: win);
      if (norm.isNotEmpty) return norm;
    }

    final lex = lexExecCommand(command, windows: win);
    String? fallbackBuiltin;
    for (final segment in lex.segments) {
      final token = _leadingCommandTokenOfSegment(segment, isWindows: win);
      if (token == null || token.isEmpty) continue;
      fallbackBuiltin ??= token;
      if (!_shellSetupBuiltins.contains(token)) {
        return token;
      }
    }
    return fallbackBuiltin;
  }

  /// Returns `true` when a completed `exec.run` invocation likely installed or
  /// changed developer toolchains on the host so cached `xuna/resources`
  /// should refresh.
  static bool isPackageOrToolchainInstallCommand(
    String command, {
    String? reasonCode,
    bool? isWindows,
  }) {
    if (reasonCode == 'package_install') return true;
    final win = isWindows ?? Platform.isWindows;
    final lex = lexExecCommand(command, windows: win);
    for (final segment in lex.segments) {
      final words = segment.words;
      if (words.isEmpty) continue;
      final token = _leadingCommandTokenOfSegment(segment, isWindows: win);
      if (token == null || !_packageManagers.contains(token)) continue;
      for (final word in words.skip(1)) {
        if (_packageMutationVerbs.contains(word.text.trim().toLowerCase())) {
          return true;
        }
      }
    }
    return false;
  }

  static String? _leadingCommandTokenOfSegment(
    ExecSegment segment, {
    required bool isWindows,
  }) {
    final words = segment.words;
    var k = 0;
    while (k < words.length &&
        RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(words[k].text)) {
      k++;
    }
    while (k < words.length) {
      final name = normalizeCommandToken(words[k].text, isWindows: isWindows);
      if (_transparentWrappers.contains(name)) {
        k++;
        while (k < words.length && words[k].text.startsWith('-')) {
          k++;
        }
        continue;
      }
      if (name == 'env') {
        k++;
        while (k < words.length &&
            (words[k].text.startsWith('-') || words[k].text.contains('='))) {
          if (words[k].text.startsWith('-S') ||
              words[k].text.startsWith('--split')) {
            return null;
          }
          k++;
        }
        continue;
      }
      if (name == 'timeout' || name == 'gtimeout') {
        k++;
        while (k < words.length && words[k].text.startsWith('-')) {
          k++;
        }
        if (k < words.length) k++;
        continue;
      }
      break;
    }
    if (k >= words.length) return null;
    var raw = words[k].text;
    if (!isWindows && raw.startsWith('=') && raw.length > 1) {
      raw = raw.substring(1);
    }
    final normalized = normalizeCommandToken(raw, isWindows: isWindows);
    return normalized.isEmpty ? null : normalized;
  }

  /// Normalizes a command token (stripping surrounding quotes, directory path,
  /// and Windows executable extensions).
  static String normalizeCommandToken(String raw, {bool? isWindows}) {
    final win = isWindows ?? Platform.isWindows;
    var trimmed = raw.trim();
    if ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
        (trimmed.startsWith("'") && trimmed.endsWith("'"))) {
      if (trimmed.length >= 2) {
        trimmed = trimmed.substring(1, trimmed.length - 1);
      }
    }
    if (trimmed.isEmpty) return '';
    var name = trimmed.replaceAll(r'\', '/').split('/').last.toLowerCase();
    if (win) {
      name = name.replaceFirst(RegExp(r'\.(exe|cmd|bat|com)$'), '');
    }
    return name;
  }

  /// Looks up a validated, platform-aware [XtpRemediation] for a missing CLI
  /// command token in `exec.run`. Returns `null` for unknown commands.
  static XtpRemediation? forCommandToken(
    String? token, {
    bool? isWindows,
    bool? isMacOs,
  }) {
    if (token == null || token.trim().isEmpty) return null;
    final win = isWindows ?? Platform.isWindows;
    final mac = isMacOs ?? Platform.isMacOS;
    final norm = normalizeCommandToken(token, isWindows: win);
    if (norm.isEmpty) return null;
    return _lookupToolchain(norm, isWindows: win, isMacOs: mac);
  }

  /// Looks up a validated, platform-aware [XtpRemediation] for a missing IDE
  /// or coding agent dependency (`workspace.open` / `workspace.coding_agent`).
  /// Returns `null` for unknown dependency names.
  static XtpRemediation? forDependency(
    String? dependency, {
    bool? isWindows,
    bool? isMacOs,
  }) {
    if (dependency == null || dependency.trim().isEmpty) return null;
    final win = isWindows ?? Platform.isWindows;
    final mac = isMacOs ?? Platform.isMacOS;
    final norm = dependency.trim().toLowerCase();

    final canonical = switch (norm) {
      'auto' => 'vscode',
      'vscode' ||
      'code' ||
      'vs_code' ||
      'vs-code' ||
      'visual_studio_code' => 'vscode',
      'cursor' => 'cursor',
      'antigravity' ||
      'antigravity_ide' ||
      'antigravity-ide' ||
      'agy' => 'antigravity',
      'claude_code' || 'claude' || 'claude-code' => 'claude_code',
      'codex' => 'codex',
      _ => norm,
    };

    final dep = switch (canonical) {
      'vscode' =>
        win
            ? const XtpRemediation(
                summary:
                    'Visual Studio Code chưa được cài đặt trên máy hoặc chưa đăng ký lệnh.',
                command: 'winget install Microsoft.VisualStudioCode',
                kind: XtpRemediationKind.install,
              )
            : mac
            ? const XtpRemediation(
                summary:
                    'Visual Studio Code chưa được cài đặt trên máy hoặc chưa bật lệnh shell.',
                command: 'brew install --cask visual-studio-code',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'Cài đặt Visual Studio Code tại https://code.visualstudio.com/download.',
                kind: XtpRemediationKind.manual,
              ),
      'cursor' =>
        win
            ? const XtpRemediation(
                summary:
                    'Cursor chưa được cài đặt trên máy hoặc chưa đăng ký lệnh.',
                command: 'winget install Anysphere.Cursor',
                kind: XtpRemediationKind.install,
              )
            : mac
            ? const XtpRemediation(
                summary:
                    'Cursor chưa được cài đặt trên máy hoặc chưa bật lệnh shell.',
                command: 'brew install --cask cursor',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Cài đặt Cursor tại https://www.cursor.com/downloads.',
                kind: XtpRemediationKind.manual,
              ),
      'antigravity' => const XtpRemediation(
        summary:
            'Cài đặt Antigravity IDE hoặc mở ứng dụng một lần để đăng ký đường dẫn.',
        kind: XtpRemediationKind.manual,
      ),
      'claude_code' => const XtpRemediation(
        summary: 'Claude Code CLI chưa được cài đặt hoặc chưa có trong PATH.',
        command: 'npm install -g @anthropic-ai/claude-code',
        kind: XtpRemediationKind.install,
      ),
      'codex' => const XtpRemediation(
        summary: 'OpenAI Codex CLI chưa được cài đặt hoặc chưa có trong PATH.',
        command: 'npm install -g @openai/codex',
        kind: XtpRemediationKind.install,
      ),
      _ => _lookupToolchain(canonical, isWindows: win, isMacOs: mac),
    };
    return _validatedOrNull(dep);
  }

  static XtpRemediation? _lookupToolchain(
    String norm, {
    required bool isWindows,
    required bool isMacOs,
  }) {
    final canonical = switch (norm) {
      'nodejs' || 'npx' => 'node',
      'pip' || 'pip3' => 'python',
      'rustc' || 'rustup' => 'cargo',
      'libreoffice' => 'soffice',
      _ => norm,
    };

    final XtpRemediation? entry = switch (canonical) {
      'git' =>
        isWindows
            ? const XtpRemediation(
                summary: 'Git chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Git.Git',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Git chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install git',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Git chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y git',
                kind: XtpRemediationKind.install,
              ),
      'node' =>
        isWindows
            ? const XtpRemediation(
                summary: 'Node.js chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install OpenJS.NodeJS.LTS',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Node.js chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install node',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Node.js chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y nodejs npm',
                kind: XtpRemediationKind.install,
              ),
      'npm' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'npm (Node.js) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install OpenJS.NodeJS.LTS',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'npm (Node.js) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install node',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'npm (Node.js) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y nodejs npm',
                kind: XtpRemediationKind.install,
              ),
      'python' || 'python3' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'Python chưa được cài đặt (tránh bản giả từ Microsoft Store).',
                command: 'winget install Python.Python.3.12',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Python 3 chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install python',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Python 3 chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y python3 python3-pip',
                kind: XtpRemediationKind.install,
              ),
      'dart' =>
        isWindows
            ? const XtpRemediation(
                summary: 'Dart SDK chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Google.Flutter',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Dart SDK chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install dart-lang/dart/dart',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'Cài đặt Dart SDK theo hướng dẫn tại https://dart.dev/get-dart và thêm vào PATH.',
                kind: XtpRemediationKind.manual,
              ),
      'flutter' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'Flutter SDK chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Google.Flutter',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'Flutter SDK chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install --cask flutter',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'Cài đặt Flutter SDK tại https://docs.flutter.dev/get-started/install và thêm vào PATH.',
                kind: XtpRemediationKind.manual,
              ),
      'go' =>
        isWindows
            ? const XtpRemediation(
                summary: 'Go chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install GoLang.Go',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Go chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install go',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Go chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y golang-go',
                kind: XtpRemediationKind.install,
              ),
      'cargo' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'Rust / Cargo chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Rustlang.Rustup',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'Rust / Cargo chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install rustup-init',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'Cài đặt Rust và Cargo tại https://rustup.rs và thêm vào PATH.',
                kind: XtpRemediationKind.manual,
              ),
      'docker' =>
        isWindows
            ? const XtpRemediation(
                summary: 'Docker chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Docker.DockerDesktop',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'Docker chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install --cask docker',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'Docker chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y docker.io',
                kind: XtpRemediationKind.install,
              ),
      'gh' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'GitHub CLI (gh) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install GitHub.cli',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'GitHub CLI (gh) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install gh',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'GitHub CLI (gh) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y gh',
                kind: XtpRemediationKind.install,
              ),
      'rg' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'ripgrep (rg) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install BurntSushi.ripgrep.MSVC',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'ripgrep (rg) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install ripgrep',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'ripgrep (rg) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y ripgrep',
                kind: XtpRemediationKind.install,
              ),
      'ffmpeg' =>
        isWindows
            ? const XtpRemediation(
                summary: 'FFmpeg chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install Gyan.FFmpeg',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary: 'FFmpeg chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install ffmpeg',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary: 'FFmpeg chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y ffmpeg',
                kind: XtpRemediationKind.install,
              ),
      'soffice' =>
        isWindows
            ? const XtpRemediation(
                summary:
                    'LibreOffice (soffice) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'winget install TheDocumentFoundation.LibreOffice',
                kind: XtpRemediationKind.install,
              )
            : isMacOs
            ? const XtpRemediation(
                summary:
                    'LibreOffice (soffice) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'brew install --cask libreoffice',
                kind: XtpRemediationKind.install,
              )
            : const XtpRemediation(
                summary:
                    'LibreOffice (soffice) chưa được cài đặt hoặc chưa có trong PATH.',
                command: 'sudo apt-get install -y libreoffice',
                kind: XtpRemediationKind.install,
              ),
      _ => null,
    };
    return _validatedOrNull(entry);
  }

  static XtpRemediation? _validatedOrNull(XtpRemediation? entry) {
    if (entry == null) return null;
    try {
      entry.validate();
      return entry;
    } on FormatException {
      return null;
    }
  }
}

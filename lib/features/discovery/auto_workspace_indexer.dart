import 'dart:convert';
import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// A local developer project/workspace discovered on the host (`UDC-11` S11.2).
///
/// Privacy invariant: [path] is kept strictly on the host and never serialized
/// into XTP responses or logs. Only [alias] crosses the wire.
class DiscoveredWorkspace {
  const DiscoveredWorkspace({
    required this.alias,
    required this.path,
    required this.lastModified,
    this.source = 'scan',
  });

  final String alias;
  final String path;
  final DateTime lastModified;
  final String source;
}

/// Content-free Git status summary for a workspace (`UDC-11` S11.2).
class GitSummarySnapshot {
  const GitSummarySnapshot({
    required this.workspace,
    required this.branch,
    required this.clean,
    required this.modifiedCount,
    required this.untrackedCount,
  });

  final String workspace;
  final String branch;
  final bool clean;
  final int modifiedCount;
  final int untrackedCount;

  Map<String, Object?> toStructuredContent() => <String, Object?>{
        'workspace': workspace,
        'branch': branch,
        'clean': clean,
        'modifiedCount': modifiedCount,
        'untrackedCount': untrackedCount,
      };
}

/// Content-free task status snapshot for `workspace.watch_task` (`UDC-12` S12.2).
class WorkspaceTaskSnapshot {
  const WorkspaceTaskSnapshot({
    required this.workspace,
    required this.status,
    required this.summary,
  });

  final String workspace;
  final String status; // 'completed' | 'running' | 'failed' | 'idle'
  final String summary;

  Map<String, Object?> toStructuredContent() => <String, Object?>{
        'workspace': workspace,
        'status': status,
        'summary': summary,
      };
}

/// Command plan executed by `workspace.coding_agent` (`UDC-11` S11.3).
class CodingAgentLaunchPlan {
  const CodingAgentLaunchPlan({
    required this.workspace,
    required this.agent,
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.resumed,
    required this.promptSent,
    this.promptText = '',
  });

  final String workspace;
  final String agent;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final bool resumed;
  final bool promptSent;
  final String promptText;
}

typedef GitProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

typedef AgentProcessLauncher = Future<void> Function(
  CodingAgentLaunchPlan plan,
);

/// Zero-config project/workspace indexer (`UDC-11` S11.2 & S11.3):
/// - Reads Claude Code project history (`~/.claude.json`),
/// - Reads Antigravity / VS Code / Cursor `User/globalStorage/storage.json`,
/// - Performs a shallow (`depth <= 3`) scan of standard developer folders
///   (`Documents`, `Projects`, `Developer`, `Repos`, `Desktop`, `work`) for
///   `.git`, `AGENTS.md`, or `CLAUDE.md`.
class AutoWorkspaceIndexer {
  AutoWorkspaceIndexer({
    List<DiscoveredWorkspace>? seedWorkspaces,
    List<String>? customScanRoots,
    List<String>? customClaudeConfigPaths,
    List<String>? customIdeStoragePaths,
    bool scanDefaultLocations = true,
    GitProcessRunner? gitRunner,
    AgentProcessLauncher? agentLauncher,
  })  : _seedWorkspaces = seedWorkspaces ?? const <DiscoveredWorkspace>[],
        _customScanRoots = customScanRoots ?? const <String>[],
        _customClaudeConfigPaths = customClaudeConfigPaths ?? const <String>[],
        _customIdeStoragePaths = customIdeStoragePaths ?? const <String>[],
        _scanDefaultLocations = scanDefaultLocations,
        _gitRunner = gitRunner ?? _defaultGitRunner,
        _agentLauncher = agentLauncher ?? _defaultAgentLauncher;

  final List<DiscoveredWorkspace> _seedWorkspaces;
  final List<String> _customScanRoots;
  final List<String> _customClaudeConfigPaths;
  final List<String> _customIdeStoragePaths;
  final bool _scanDefaultLocations;
  final GitProcessRunner _gitRunner;
  final AgentProcessLauncher _agentLauncher;

  List<DiscoveredWorkspace>? _cachedWorkspaces;

  static Future<ProcessResult> _defaultGitRunner(
    String executable,
    List<String> arguments,
  ) {
    return Process.run(
      executable,
      arguments,
      runInShell: false,
    ).timeout(const Duration(seconds: 3));
  }

  static String _shellSingleQuote(String value) {
    return "'${value.replaceAll("'", r"'\''")}'";
  }

  static String _appleScriptEscape(String value) {
    return value
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', ' ')
        .replaceAll('\r', ' ');
  }

  static Future<void> _copyTextToSystemClipboard(String text) async {
    if (text.isEmpty) return;
    try {
      if (Platform.isMacOS) {
        final proc = await Process.start('/usr/bin/pbcopy', const <String>[]);
        proc.stdin.write(text);
        await proc.stdin.close();
        await proc.exitCode.timeout(const Duration(seconds: 2));
      } else if (Platform.isWindows) {
        final proc = await Process.start(
          'clip',
          const <String>[],
          runInShell: true,
        );
        proc.stdin.write(text);
        await proc.stdin.close();
        await proc.exitCode.timeout(const Duration(seconds: 2));
      }
    } catch (_) {}
  }

  static Future<void> _defaultAgentLauncher(CodingAgentLaunchPlan plan) async {
    final cleanEnv = Map<String, String>.from(Platform.environment)
      ..removeWhere(
        (key, _) =>
            key == 'ELECTRON_RUN_AS_NODE' ||
            key.startsWith('VSCODE_') ||
            key.startsWith('ANTIGRAVITY_'),
      );

    final promptToDeliver = plan.promptText.trim();

    // 1. CLI Coding Agents (`claude_code`, `codex`): must run in an interactive Terminal TTY
    // so they don't hang or exit silently in background detached mode.
    if (plan.agent == 'claude_code' || plan.agent == 'codex') {
      if (Platform.isMacOS) {
        final quotedDir = _shellSingleQuote(plan.workingDirectory);
        final quotedExe = _shellSingleQuote(plan.executable);
        final quotedArgs = plan.arguments.map(_shellSingleQuote).join(' ');
        final fallbackCmd = plan.agent == 'claude_code' ? 'claude' : 'codex';
        // Fallback to non-continue invocation if `--continue` fails when no prior session exists
        final nonContinueArgs = plan.arguments
            .where((a) => a != '--continue')
            .map(_shellSingleQuote)
            .join(' ');
        final shellLine = plan.arguments.contains('--continue')
            ? 'cd $quotedDir && ($quotedExe $quotedArgs || $quotedExe $nonContinueArgs || $fallbackCmd $nonContinueArgs)'
            : 'cd $quotedDir && ($quotedExe $quotedArgs || $fallbackCmd $quotedArgs)';
        final escapedShellLine = _appleScriptEscape(shellLine);
        final appleScript = '''
tell application "Terminal"
  activate
  do script "$escapedShellLine"
end tell
''';
        await Process.run('/usr/bin/osascript', <String>['-e', appleScript]);
        return;
      } else if (Platform.isWindows) {
        if (promptToDeliver.isNotEmpty) {
          await _copyTextToSystemClipboard(promptToDeliver);
        }
        final fallbackCmd = plan.agent == 'claude_code' ? 'claude' : 'codex';
        String quoteCmdArg(String val) =>
            '"${val.replaceAll('"', r'\"')}"';
        final quotedExe = quoteCmdArg(plan.executable);
        final quotedArgs = plan.arguments.map(quoteCmdArg).join(' ');
        final nonContinueArgs = plan.arguments
            .where((a) => a != '--continue')
            .map(quoteCmdArg)
            .join(' ');
        final cmdChain = plan.arguments.contains('--continue')
            ? '$quotedExe $quotedArgs || $quotedExe $nonContinueArgs || $fallbackCmd $nonContinueArgs'
            : '$quotedExe $quotedArgs || $fallbackCmd $quotedArgs';
        await Process.start(
          'cmd.exe',
          <String>[
            '/c',
            'start',
            'XUNA Coding Agent',
            '/D',
            plan.workingDirectory,
            'cmd.exe',
            '/k',
            cmdChain,
          ],
          workingDirectory: plan.workingDirectory,
          environment: cleanEnv,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
        return;
      }
    }

    // 2. IDE Agents (`antigravity`, `cursor`, `vscode`, or any discovered IDE):
    // Step A: Open the exact workspace folder in the target IDE.
    final ideDisplayNames = <String, String>{
      'antigravity': 'Antigravity',
      'cursor': 'Cursor',
      'vscode': 'Visual Studio Code',
    };
    final ideLabel = ideDisplayNames[plan.agent] ?? plan.agent;
    if (Platform.isMacOS) {
      var opened = false;
      if (plan.executable.endsWith('.app')) {
        final res = await Process.run(
          '/usr/bin/open',
          <String>['-a', plan.executable, plan.workingDirectory],
          environment: cleanEnv,
        );
        opened = res.exitCode == 0;
      } else {
        try {
          final res = await Process.run(
            plan.executable,
            plan.arguments,
            workingDirectory: plan.workingDirectory,
            environment: cleanEnv,
          ).timeout(const Duration(seconds: 4));
          opened = res.exitCode == 0;
        } catch (_) {
          opened = false;
        }
      }
      if (!opened) {
        await Process.run(
          '/usr/bin/open',
          <String>['-a', ideLabel, plan.workingDirectory],
          environment: cleanEnv,
        );
      }

      if (plan.promptSent && promptToDeliver.isNotEmpty) {
        await _copyTextToSystemClipboard(promptToDeliver);
        final focusAndSubmitScript = '''
delay 1.2
tell application "${_appleScriptEscape(ideLabel)}" to activate
delay 0.4
tell application "System Events"
  keystroke "l" using {command down}
  delay 0.35
  keystroke "v" using {command down}
  delay 0.25
  key code 36
end tell
''';
        try {
          await Process.start(
            '/usr/bin/osascript',
            <String>['-e', focusAndSubmitScript],
            mode: ProcessStartMode.detached,
          );
        } catch (_) {}
      }
      return;
    }

    // Windows / Linux IDE launch
    final lowerExe = plan.executable.toLowerCase();
    final needsShell =
        Platform.isWindows &&
        (lowerExe.endsWith('.cmd') ||
            lowerExe.endsWith('.bat') ||
            lowerExe.endsWith('.lnk'));
    await Process.start(
      plan.executable,
      plan.arguments,
      workingDirectory: plan.workingDirectory,
      environment: cleanEnv,
      includeParentEnvironment: false,
      runInShell: needsShell,
      mode: ProcessStartMode.detached,
    );

    if (Platform.isWindows && plan.promptSent && promptToDeliver.isNotEmpty) {
      await _copyTextToSystemClipboard(promptToDeliver);
      final wsFolder = plan.workingDirectory
          .split(RegExp(r'[/\\]'))
          .where((s) => s.isNotEmpty)
          .lastOrNull ??
          plan.workspace;
      final safeWsFolder = wsFolder.replaceAll("'", "''");
      final safeIdeLabel = ideLabel.replaceAll("'", "''");
      final psScript =
          "\$ws = New-Object -ComObject WScript.Shell; "
          "\$activated = \$false; "
          "for (\$i = 0; \$i -lt 10; \$i++) { "
          "  Start-Sleep -Milliseconds 400; "
          "  if (\$ws.AppActivate('$safeWsFolder') -or \$ws.AppActivate('$safeIdeLabel')) { "
          "    \$activated = \$true; break; "
          "  } "
          "} "
          "Start-Sleep -Milliseconds 350; "
          "\$ws.SendKeys('^l'); "
          "Start-Sleep -Milliseconds 350; "
          "\$ws.SendKeys('^v'); "
          "Start-Sleep -Milliseconds 250; "
          "\$ws.SendKeys('{ENTER}');";
      try {
        await Process.start(
          'powershell.exe',
          <String>[
            '-NoProfile',
            '-NonInteractive',
            '-WindowStyle',
            'Hidden',
            '-Command',
            psScript,
          ],
          mode: ProcessStartMode.detached,
        );
      } catch (_) {}
    }
  }

  static String sanitizeAlias(String rawName) {
    final cleaned = rawName
        .trim()
        .replaceAll(RegExp(r'[^a-zA-Z0-9_.\-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (cleaned.isEmpty) return 'workspace';
    return cleaned.length > 64 ? cleaned.substring(0, 64) : cleaned;
  }

  /// Discovers all local workspaces (cached after first scan unless [forceRefresh] is true).
  List<DiscoveredWorkspace> discoverWorkspaces({bool forceRefresh = false}) {
    if (!forceRefresh && _cachedWorkspaces != null) {
      return _cachedWorkspaces!;
    }
    final byPath = <String, DiscoveredWorkspace>{};

    void registerPath(String rawPath, {String source = 'scan', String? alias}) {
      final cleanPath = rawPath.trim();
      if (cleanPath.isEmpty) return;
      final dir = Directory(cleanPath);
      if (!dir.existsSync()) return;
      final normalizedPath = dir.absolute.path;
      final segments = dir.uri.pathSegments.where((s) => s.isNotEmpty).toList();
      if (segments.isEmpty) return;
      final baseName = alias ?? sanitizeAlias(segments.last);
      final modTime = _estimateLastModified(dir);
      final existing = byPath[normalizedPath];
      if (existing == null || modTime.isAfter(existing.lastModified)) {
        byPath[normalizedPath] = DiscoveredWorkspace(
          alias: baseName,
          path: normalizedPath,
          lastModified: modTime,
          source: source,
        );
      }
    }

    for (final ws in _seedWorkspaces) {
      byPath[ws.path] = ws;
    }

    for (final claudePath in <String>[
      ..._customClaudeConfigPaths,
      if (_scanDefaultLocations) ..._defaultClaudeConfigPaths(),
    ]) {
      _parseClaudeJson(claudePath, registerPath);
    }

    for (final storagePath in <String>[
      ..._customIdeStoragePaths,
      if (_scanDefaultLocations) ..._defaultIdeStoragePaths(),
    ]) {
      _parseIdeStorageJson(storagePath, registerPath);
    }

    for (final root in <String>[
      ..._customScanRoots,
      if (_scanDefaultLocations) ..._defaultScanRoots(),
    ]) {
      _shallowScanDirectory(Directory(root), 0, 3, registerPath);
    }

    final list = byPath.values.toList()
      ..sort((a, b) => b.lastModified.compareTo(a.lastModified));
    _cachedWorkspaces = list;
    return list;
  }

  /// Fuzzy-matches a workspace by [query] (`"recent"`, `"xuna"`, `"xuna_pet"`, `"pet"`, etc.).
  DiscoveredWorkspace? resolveWorkspace(String query) {
    if (!isValidWorkspaceQuery(query)) {
      return null;
    }
    final clean = query.trim().toLowerCase();
    final match = _matchWorkspaceInList(clean, discoverWorkspaces());
    if (match != null) return match;
    if (_scanDefaultLocations || _customScanRoots.isNotEmpty) {
      return _matchWorkspaceInList(
        clean,
        discoverWorkspaces(forceRefresh: true),
      );
    }
    return null;
  }

  DiscoveredWorkspace? _matchWorkspaceInList(
    String clean,
    List<DiscoveredWorkspace> workspaces,
  ) {
    if (workspaces.isEmpty) return null;
    if (clean == 'recent' || clean == 'latest') {
      return workspaces.first;
    }
    final normQuery = clean.replaceAll(RegExp(r'[^a-z0-9]+'), '');

    DiscoveredWorkspace? best;
    var bestScore = -1;

    for (final ws in workspaces) {
      final aliasLower = ws.alias.toLowerCase();
      final normAlias = aliasLower.replaceAll(RegExp(r'[^a-z0-9]+'), '');
      final pathSegments = ws.path
          .split(RegExp(r'[\\/]'))
          .where((s) => s.isNotEmpty)
          .map((s) => s.toLowerCase())
          .toList();
      final combinedTail = pathSegments.length >= 2
          ? '${pathSegments[pathSegments.length - 2]}_${pathSegments.last}'
          : aliasLower;
      final normCombinedTail = combinedTail.replaceAll(
        RegExp(r'[^a-z0-9]+'),
        '',
      );
      var score = -1;
      if (aliasLower == clean ||
          normAlias == normQuery ||
          combinedTail == clean ||
          normCombinedTail == normQuery) {
        score = 100;
      } else if (aliasLower.startsWith(clean) ||
          normAlias.startsWith(normQuery) ||
          normCombinedTail.endsWith(normQuery)) {
        score = 80;
      } else if (aliasLower.contains(clean) ||
          normAlias.contains(normQuery) ||
          normCombinedTail.contains(normQuery)) {
        score = 60;
      } else {
        final queryTokens = clean
            .split(RegExp(r'[\s_\-.]+'))
            .where((t) => t.isNotEmpty)
            .toList();
        if (queryTokens.isNotEmpty &&
            queryTokens.every(
              (t) => aliasLower.contains(t) || combinedTail.contains(t),
            )) {
          score = 50;
        }
      }
      if (score > bestScore) {
        bestScore = score;
        best = ws;
      }
    }
    return best;
  }

  /// Reads content-free Git branch & dirty file counts for [ws] (`UDC-11` S11.2).
  Future<GitSummarySnapshot> readGitSummary(DiscoveredWorkspace ws) async {
    try {
      final result = await _gitRunner('git', <String>[
        '-C',
        ws.path,
        'status',
        '--porcelain',
        '-b',
      ]);
      if (result.exitCode != 0) {
        return GitSummarySnapshot(
          workspace: ws.alias,
          branch: 'unknown',
          clean: true,
          modifiedCount: 0,
          untrackedCount: 0,
        );
      }
      final stdoutText = (result.stdout as Object?)?.toString() ?? '';
      return parseGitPorcelainStatus(ws.alias, stdoutText);
    } catch (_) {
      return GitSummarySnapshot(
        workspace: ws.alias,
        branch: 'unknown',
        clean: true,
        modifiedCount: 0,
        untrackedCount: 0,
      );
    }
  }

  /// Parses `git status --porcelain -b` output into a content-free [GitSummarySnapshot].
  static GitSummarySnapshot parseGitPorcelainStatus(
    String workspaceAlias,
    String rawOutput,
  ) {
    var branch = 'HEAD';
    var modified = 0;
    var untracked = 0;
    final lines = const LineSplitter().convert(rawOutput);
    for (final line in lines) {
      if (line.startsWith('## ')) {
        final header = line.substring(3).trim();
        final dotIdx = header.indexOf('...');
        final spaceIdx = header.indexOf(' ');
        if (dotIdx > 0) {
          branch = header.substring(0, dotIdx).trim();
        } else if (spaceIdx > 0) {
          branch = header.substring(0, spaceIdx).trim();
        } else if (header.isNotEmpty) {
          branch = header;
        }
      } else if (line.startsWith('?? ')) {
        untracked++;
      } else if (line.trim().isNotEmpty) {
        modified++;
      }
    }
    return GitSummarySnapshot(
      workspace: workspaceAlias,
      branch: branch,
      clean: modified == 0 && untracked == 0,
      modifiedCount: modified,
      untrackedCount: untracked,
    );
  }

  /// Inspects recent task/build/agent state in [ws] (`UDC-12` S12.2 `workspace.watch_task`).
  Future<WorkspaceTaskSnapshot> inspectWorkspaceTask(
    DiscoveredWorkspace ws,
  ) async {
    final sep = Platform.pathSeparator;
    final processFile = File('${ws.path}${sep}PROCESS.md');
    String status = 'idle';
    if (processFile.existsSync()) {
      try {
        final raw = processFile.readAsStringSync();
        final lower = raw.toLowerCase();
        if (lower.contains('status: in progress') ||
            lower.contains('status: **in progress')) {
          status = 'running';
        } else if (lower.contains('failed') && lower.contains('status:')) {
          status = 'failed';
        } else if (lower.contains('status: done') ||
            lower.contains('status: **done') ||
            lower.contains('pass')) {
          status = 'completed';
        }
      } catch (_) {}
    }
    final git = await readGitSummary(ws);
    if (status == 'idle' && !git.clean) {
      status = 'running';
    } else if (status == 'idle' && git.clean) {
      status = 'completed';
    }
    final changed = git.modifiedCount + git.untrackedCount;
    final summary = switch (status) {
      'completed' =>
        'Dá»± Ã¡n ${ws.alias} (nhÃ¡nh ${git.branch}): Ä‘Ã£ hoÃ n táº¥t, $changed tá»‡p Ä‘ang má»Ÿ.',
      'running' =>
        'Dá»± Ã¡n ${ws.alias} (nhÃ¡nh ${git.branch}): Ä‘ang cháº¡y tÃ¡c vá»¥ ($changed tá»‡p Ä‘ang sá»­a).',
      'failed' =>
        'Dá»± Ã¡n ${ws.alias} (nhÃ¡nh ${git.branch}): phÃ¡t hiá»‡n lá»—i cáº§n kiá»ƒm tra.',
      _ => 'Dá»± Ã¡n ${ws.alias} (nhÃ¡nh ${git.branch}): Ä‘ang nghá»‰.',
    };
    return WorkspaceTaskSnapshot(
      workspace: ws.alias,
      status: status,
      summary: summary.length > 200 ? summary.substring(0, 200) : summary,
    );
  }

  /// Builds and executes the non-shell launch plan for `workspace.coding_agent` (`UDC-11` S11.3).
  Future<CodingAgentLaunchPlan> launchCodingAgent({
    required DiscoveredWorkspace workspace,
    required String agent,
    required String executable,
    bool resumeLast = true,
    String? prompt,
  }) async {
    final cleanPrompt = (prompt ?? '').trim();
    if (!isSafeAgentPrompt(cleanPrompt)) {
      throw const FormatException('Unsafe characters in agent prompt');
    }

    final List<String> args;
    final hasPrompt = cleanPrompt.isNotEmpty;
    if (agent == 'claude_code') {
      args = <String>[
        if (resumeLast) '--continue',
        if (hasPrompt) cleanPrompt,
      ];
    } else if (agent == 'codex') {
      args = <String>[
        if (hasPrompt) cleanPrompt,
      ];
    } else {
      // IDE launchers (`antigravity`, `cursor`, `vscode`) open the project folder directly
      args = <String>[workspace.path];
    }

    final plan = CodingAgentLaunchPlan(
      workspace: workspace.alias,
      agent: agent,
      executable: executable,
      arguments: args,
      workingDirectory: workspace.path,
      resumed: resumeLast,
      promptSent: hasPrompt,
      promptText: cleanPrompt,
    );
    await _agentLauncher(plan);
    return plan;
  }

  static DateTime _estimateLastModified(Directory dir) {
    final candidates = <String>[
      '${dir.path}${Platform.pathSeparator}PROCESS.md',
      '${dir.path}${Platform.pathSeparator}PLAN.md',
      '${dir.path}${Platform.pathSeparator}.git${Platform.pathSeparator}HEAD',
    ];
    for (final c in candidates) {
      try {
        final f = File(c);
        if (f.existsSync()) {
          return f.lastModifiedSync().toUtc();
        }
      } catch (_) {}
    }
    try {
      return dir.statSync().modified.toUtc();
    } catch (_) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  static void _parseClaudeJson(
    String filePath,
    void Function(String path, {String source}) registerPath,
  ) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is Map && decoded['projects'] is Map) {
        final projects = decoded['projects'] as Map;
        for (final key in projects.keys) {
          if (key is String && key.trim().isNotEmpty) {
            registerPath(key, source: 'claude_code');
          }
        }
      }
    } catch (_) {}
  }

  static void _parseIdeStorageJson(
    String filePath,
    void Function(String path, {String source}) registerPath,
  ) {
    try {
      final file = File(filePath);
      if (!file.existsSync()) return;
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is! Map) return;

      void extractUri(String rawUri) {
        try {
          final uri = Uri.parse(rawUri);
          if (uri.scheme == 'file') {
            registerPath(uri.toFilePath(), source: 'ide_recent');
          }
        } catch (_) {}
      }

      final assoc = decoded['profileAssociations'];
      if (assoc is Map && assoc['workspaces'] is Map) {
        for (final key in (assoc['workspaces'] as Map).keys) {
          if (key is String) extractUri(key);
        }
      }
      final backup = decoded['backupWorkspaces'];
      if (backup is Map && backup['folders'] is List) {
        for (final item in backup['folders'] as List) {
          if (item is Map && item['folderUri'] is String) {
            extractUri(item['folderUri'] as String);
          }
        }
      }
    } catch (_) {}
  }

  static void _shallowScanDirectory(
    Directory dir,
    int depth,
    int maxDepth,
    void Function(String path, {String source}) registerPath,
  ) {
    if (depth > maxDepth || !dir.existsSync()) return;
    try {
      final sep = Platform.pathSeparator;
      final hasGit = Directory('${dir.path}$sep.git').existsSync() ||
          File('${dir.path}$sep.git').existsSync();
      final hasAgentDoc = File('${dir.path}${sep}AGENTS.md').existsSync() ||
          File('${dir.path}${sep}CLAUDE.md').existsSync();
      if (depth > 0 && (hasGit || hasAgentDoc)) {
        registerPath(dir.path, source: 'git_scan');
        // Also scan 1 level inside monorepos/superprojects for subprojects or submodules
        if (depth < maxDepth) {
          for (final sub in dir.listSync(followLinks: false)) {
            if (sub is Directory) {
              final subName = sub.uri.pathSegments
                  .where((s) => s.isNotEmpty)
                  .lastOrNull;
              if (subName == null ||
                  subName.startsWith('.') ||
                  subName == 'node_modules' ||
                  subName == 'build' ||
                  subName == 'docs') {
                continue;
              }
              final isSubProject =
                  Directory('${sub.path}$sep.git').existsSync() ||
                  File('${sub.path}$sep.git').existsSync() ||
                  File('${sub.path}${sep}pubspec.yaml').existsSync() ||
                  File('${sub.path}${sep}pyproject.toml').existsSync() ||
                  File('${sub.path}${sep}package.json').existsSync() ||
                  File('${sub.path}${sep}platformio.ini').existsSync() ||
                  File('${sub.path}${sep}Cargo.toml').existsSync();
              if (isSubProject) {
                registerPath(sub.path, source: 'git_subproject');
              }
            }
          }
        }
        return;
      }
      if (depth == maxDepth) return;
      for (final entity in dir.listSync(followLinks: false)) {
        if (entity is Directory) {
          final name = entity.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull;
          if (name == null ||
              name.startsWith('.') ||
              name == 'node_modules' ||
              name == 'build' ||
              name == 'Library' ||
              name == 'AppData') {
            continue;
          }
          _shallowScanDirectory(entity, depth + 1, maxDepth, registerPath);
        }
      }
    } catch (_) {}
  }

  static List<String> _defaultClaudeConfigPaths() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const <String>[];
    final sep = Platform.pathSeparator;
    return <String>[
      '$home$sep.claude.json',
      '$home$sep.claude${sep}settings.json',
    ];
  }

  static List<String> _defaultIdeStoragePaths() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final appData = Platform.environment['APPDATA'] ?? '';
    final sep = Platform.pathSeparator;
    final ides = const <String>['Antigravity', 'Cursor', 'Code'];
    final paths = <String>[];
    if (Platform.isWindows && appData.isNotEmpty) {
      for (final ide in ides) {
        paths.add(
          '$appData$sep$ide${sep}User${sep}globalStorage${sep}storage.json',
        );
      }
    } else if (Platform.isMacOS && home.isNotEmpty) {
      for (final ide in ides) {
        paths.add(
          '$home/Library/Application Support/$ide/User/globalStorage/storage.json',
        );
      }
    }
    return paths;
  }

  static List<String> _defaultScanRoots() {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    if (home.isEmpty) return const <String>[];
    final sep = Platform.pathSeparator;
    return <String>[
      '$home${sep}Documents',
      '$home${sep}Projects',
      '$home${sep}Developer',
      '$home${sep}Repos',
      '$home${sep}source${sep}repos',
      '$home${sep}Desktop',
      '$home${sep}work',
      if (Platform.isWindows) ...<String>[
        r'C:\Projects',
        r'C:\dev',
        r'D:\Projects',
        r'D:\work',
      ],
    ];
  }
}

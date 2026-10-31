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
  });

  final String workspace;
  final String agent;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final bool resumed;
  final bool promptSent;
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

  static Future<void> _defaultAgentLauncher(CodingAgentLaunchPlan plan) async {
    if (plan.agent == 'claude_code' || plan.agent == 'codex') {
      // Spawn in a visible terminal window on macOS/Windows with runInShell: false
      if (Platform.isWindows) {
        await Process.start(
          plan.executable,
          plan.arguments,
          workingDirectory: plan.workingDirectory,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
      } else {
        await Process.start(
          plan.executable,
          plan.arguments,
          workingDirectory: plan.workingDirectory,
          runInShell: false,
          mode: ProcessStartMode.detached,
        );
      }
      return;
    }
    await Process.start(
      plan.executable,
      plan.arguments,
      workingDirectory: plan.workingDirectory,
      runInShell: false,
      mode: ProcessStartMode.detached,
    );
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
    final workspaces = discoverWorkspaces();
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
      var score = -1;
      if (aliasLower == clean || normAlias == normQuery) {
        score = 100;
      } else if (aliasLower.startsWith(clean) ||
          normAlias.startsWith(normQuery)) {
        score = 80;
      } else if (aliasLower.contains(clean) || normAlias.contains(normQuery)) {
        score = 60;
      } else {
        final queryTokens = clean
            .split(RegExp(r'[\s_\-.]+'))
            .where((t) => t.isNotEmpty)
            .toList();
        if (queryTokens.isNotEmpty &&
            queryTokens.every((t) => aliasLower.contains(t))) {
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
        'Dự án ${ws.alias} (nhánh ${git.branch}): đã hoàn tất, $changed tệp đang mở.',
      'running' =>
        'Dự án ${ws.alias} (nhánh ${git.branch}): đang chạy tác vụ ($changed tệp đang sửa).',
      'failed' =>
        'Dự án ${ws.alias} (nhánh ${git.branch}): phát hiện lỗi cần kiểm tra.',
      _ => 'Dự án ${ws.alias} (nhánh ${git.branch}): đang nghỉ.',
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
      '$home${sep}Desktop',
      '$home${sep}work',
    ];
  }
}

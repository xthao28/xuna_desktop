import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// A GUI application or developer CLI discovered on the host (`UDC-11` S11.2).
class DiscoveredApp {
  const DiscoveredApp({
    required this.id,
    required this.name,
    required this.kind,
    required this.target,
    this.isCodingAgent = false,
  });

  final String id;
  final String name;
  final AppLaunchKind kind;
  final String target;
  final bool isCodingAgent;
}

/// Zero-config scanner for installed macOS / Windows applications and coding
/// agent CLIs (`claude`, `agy`, `cursor`, `code`, `codex`) (`UDC-11` S11.2).
///
/// Safety invariants:
/// - Every candidate is filtered through [isHardDeniedAppOrProcess] so shells,
///   password managers, banking apps, and system tools are never exposed.
/// - Launching any discovered app still requires an `R2` owner approval token.
class AutoAppScanner {
  AutoAppScanner({
    List<DiscoveredApp>? seedApps,
    Map<String, String>? seedAgentBinaries,
    bool scanFileSystem = true,
  })  : _seedApps = seedApps ?? const <DiscoveredApp>[],
        _seedAgentBinaries = seedAgentBinaries ?? const <String, String>{},
        _scanFileSystem = scanFileSystem;

  final List<DiscoveredApp> _seedApps;
  final Map<String, String> _seedAgentBinaries;
  final bool _scanFileSystem;

  List<DiscoveredApp>? _cachedApps;
  Map<String, String>? _cachedAgents;

  static String normalizeId(String raw) {
    final lower = raw
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\.(app|exe|lnk|cmd)$'), '')
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (lower.isEmpty) return 'app';
    return lower.length > 64 ? lower.substring(0, 64) : lower;
  }

  /// Discovers installed GUI applications (cached after first scan).
  List<DiscoveredApp> discoverApps({bool forceRefresh = false}) {
    if (!forceRefresh && _cachedApps != null) {
      return _cachedApps!;
    }
    final byId = <String, DiscoveredApp>{};

    void register(DiscoveredApp app) {
      if (isHardDeniedAppOrProcess(app.id) ||
          isHardDeniedAppOrProcess(app.name) ||
          isHardDeniedAppOrProcess(app.target)) {
        return;
      }
      byId.putIfAbsent(app.id, () => app);
    }

    for (final seeded in _seedApps) {
      register(seeded);
    }

    if (_scanFileSystem) {
      if (Platform.isMacOS) {
        _scanMacOsApplications(register);
      } else if (Platform.isWindows) {
        _scanWindowsApplications(register);
      }
    }

    final result = byId.values.toList(growable: false);
    _cachedApps = result;
    return result;
  }

  /// Fuzzy-matches an application by [query] (canonical ID, display name, or alias).
  DiscoveredApp? findApp(String query) {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty || isHardDeniedAppOrProcess(clean)) {
      return null;
    }
    final norm = normalizeId(clean);
    final apps = discoverApps();

    // Common developer aliases
    final aliasTargets = switch (norm) {
      'vscode' || 'vs_code' || 'code' => const <String>[
          'vscode',
          'visual_studio_code',
          'code',
        ],
      'antigravity' || 'agy' => const <String>['antigravity', 'agy'],
      'cursor' => const <String>['cursor'],
      'claude' || 'claude_code' => const <String>[
          'claude',
          'claude_code',
        ],
      _ => <String>[norm],
    };

    for (final candidateId in aliasTargets) {
      for (final app in apps) {
        if (app.id == candidateId) return app;
      }
    }
    for (final app in apps) {
      final nameLower = app.name.toLowerCase();
      if (nameLower == clean || app.id.contains(norm) || nameLower.contains(clean)) {
        return app;
      }
    }
    return null;
  }

  /// Resolves the executable path for a coding agent (`claude_code`, `antigravity`,
  /// `cursor`, `vscode`, `codex`, or `auto`).
  ({String agent, String executable})? resolveCodingAgent(
    String requestedAgent,
  ) {
    final agents = discoverCodingAgents();
    final norm = requestedAgent.trim().toLowerCase();
    const preferenceOrder = <String>[
      'claude_code',
      'antigravity',
      'cursor',
      'vscode',
      'codex',
    ];

    if (norm.isEmpty || norm == 'auto') {
      for (final key in preferenceOrder) {
        final bin = agents[key];
        if (bin != null && bin.isNotEmpty) {
          return (agent: key, executable: bin);
        }
      }
      return null;
    }

    final direct = agents[norm];
    if (direct != null && direct.isNotEmpty) {
      return (agent: norm, executable: direct);
    }
    return null;
  }

  /// Discovers available coding agent binaries on the host (`claude_code`,
  /// `antigravity`, `cursor`, `vscode`, `codex`).
  Map<String, String> discoverCodingAgents({bool forceRefresh = false}) {
    if (!forceRefresh && _cachedAgents != null) {
      return _cachedAgents!;
    }
    final result = <String, String>{..._seedAgentBinaries};
    if (!_scanFileSystem) {
      _cachedAgents = result;
      return result;
    }

    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';
    final pathEnv = Platform.environment['PATH'] ?? '';
    final pathDirs = pathEnv
        .split(Platform.isWindows ? ';' : ':')
        .where((p) => p.trim().isNotEmpty)
        .toList();

    final searchDirs = <String>[
      if (home.isNotEmpty) ...<String>[
        '$home/.local/bin',
        '$home/.npm-global/bin',
        '$home/.claude/local',
      ],
      if (Platform.isMacOS) ...<String>[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/Applications/Antigravity.app/Contents/Resources/app/bin',
        '/Applications/Cursor.app/Contents/Resources/app/bin',
        '/Applications/Visual Studio Code.app/Contents/Resources/app/bin',
      ],
      if (Platform.isWindows) ...<String>[
        if (appData.isNotEmpty) '$appData\\npm',
        if (localAppData.isNotEmpty) ...<String>[
          '$localAppData\\Programs\\Antigravity\\bin',
          '$localAppData\\Programs\\cursor\\resources\\app\\bin',
          '$localAppData\\Programs\\Microsoft VS Code\\bin',
          '$localAppData\\AnthropicClaude',
        ],
      ],
      ...pathDirs,
    ];

    final candidates = <String, List<String>>{
      'claude_code': Platform.isWindows
          ? const <String>['claude.exe', 'claude.cmd', 'claude']
          : const <String>['claude'],
      'antigravity': Platform.isWindows
          ? const <String>['agy.cmd', 'agy.exe', 'antigravity.cmd', 'antigravity.exe']
          : const <String>['agy', 'antigravity'],
      'cursor': Platform.isWindows
          ? const <String>['cursor.cmd', 'cursor.exe']
          : const <String>['cursor'],
      'vscode': Platform.isWindows
          ? const <String>['code.cmd', 'code.exe']
          : const <String>['code'],
      'codex': Platform.isWindows
          ? const <String>['codex.cmd', 'codex.exe']
          : const <String>['codex'],
    };

    for (final entry in candidates.entries) {
      if (result.containsKey(entry.key)) continue;
      for (final dir in searchDirs) {
        for (final binName in entry.value) {
          final sep = Platform.pathSeparator;
          final fullPath = dir.endsWith(sep) ? '$dir$binName' : '$dir$sep$binName';
          try {
            if (File(fullPath).existsSync()) {
              result[entry.key] = fullPath;
              break;
            }
          } catch (_) {}
        }
        if (result.containsKey(entry.key)) break;
      }
    }

    _cachedAgents = result;
    return result;
  }

  void _scanMacOsApplications(void Function(DiscoveredApp) register) {
    final home = Platform.environment['HOME'] ?? '';
    final roots = <String>[
      '/Applications',
      '/System/Applications',
      if (home.isNotEmpty) '$home/Applications',
    ];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(followLinks: false)) {
          if (entity is Directory && entity.path.endsWith('.app')) {
            final base = entity.uri.pathSegments
                .where((s) => s.isNotEmpty)
                .last
                .replaceAll(RegExp(r'\.app$'), '');
            final id = normalizeId(base);
            register(
              DiscoveredApp(
                id: id,
                name: base,
                kind: AppLaunchKind.bundle,
                target: entity.path,
              ),
            );
          }
        }
      } catch (_) {}
    }
  }

  void _scanWindowsApplications(void Function(DiscoveredApp) register) {
    final programData = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final appData = Platform.environment['APPDATA'] ?? '';
    final roots = <String>[
      '$programData\\Microsoft\\Windows\\Start Menu\\Programs',
      if (appData.isNotEmpty)
        '$appData\\Microsoft\\Windows\\Start Menu\\Programs',
    ];
    for (final root in roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity
            in dir.listSync(recursive: true, followLinks: false)) {
          if (entity is File &&
              entity.path.toLowerCase().endsWith('.lnk')) {
            final fileName = entity.uri.pathSegments.last;
            final base =
                fileName.substring(0, fileName.length - 4).trim();
            if (base.isEmpty ||
                base.toLowerCase().contains('uninstall')) {
              continue;
            }
            final id = normalizeId(base);
            register(
              DiscoveredApp(
                id: id,
                name: base,
                kind: AppLaunchKind.exe,
                target: entity.path,
              ),
            );
          }
        }
      } catch (_) {}
    }
  }
}


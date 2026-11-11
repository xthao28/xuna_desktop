import 'dart:io';

import 'package:xuna_xtp/xuna_xtp.dart';

/// A GUI application or developer CLI discovered on the host (`UDC-11` S11.2).
class DiscoveredApp {
  const DiscoveredApp({
    required this.id,
    required this.name,
    required this.kind,
    required this.target,
    this.bundleId,
    this.isCodingAgent = false,
  });

  final String id;
  final String name;
  final AppLaunchKind kind;
  final String target;
  final String? bundleId;
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
  }) : _seedApps = seedApps ?? const <DiscoveredApp>[],
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
          isHardDeniedAppOrProcess(app.target) ||
          (app.bundleId != null && isHardDeniedAppOrProcess(app.bundleId!))) {
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

  /// Fuzzy-matches an application by [query] (canonical ID, display name, acronym, or executable stem).
  DiscoveredApp? findApp(String query) {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty || isHardDeniedAppOrProcess(clean)) {
      return null;
    }
    final norm = normalizeId(clean);
    final compactQuery = clean.replaceAll(RegExp(r'[^a-z0-9]+'), '');
    final queryTokens = clean
        .split(RegExp(r'[^a-z0-9]+'))
        .where((t) => t.isNotEmpty)
        .toList();
    final apps = discoverApps();

    DiscoveredApp? bestApp;
    var bestScore = 0;

    for (final app in apps) {
      final idLower = app.id.toLowerCase();
      final nameLower = app.name.toLowerCase();
      final bundleLower = (app.bundleId ?? '').toLowerCase();
      final compactName = nameLower.replaceAll(RegExp(r'[^a-z0-9]+'), '');
      final targetStem = app.target
          .split(RegExp(r'[/\\]'))
          .last
          .replaceAll(RegExp(r'\.(app|exe|lnk|cmd)$', caseSensitive: false), '')
          .toLowerCase();
      final compactStem = targetStem.replaceAll(RegExp(r'[^a-z0-9]+'), '');
      final nameWords = nameLower
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.isNotEmpty)
          .toList();
      final initials = nameWords.map((w) => w[0]).join();
      // E.g. "Visual Studio Code" -> "vsc" + "code" -> "vscode"
      final initialsPlusLast = nameWords.length >= 2
          ? '${nameWords.take(nameWords.length - 1).map((w) => w[0]).join()}${nameWords.last}'
          : '';

      var score = 0;
      if (idLower == norm ||
          nameLower == clean ||
          (bundleLower.isNotEmpty &&
              (bundleLower == clean || normalizeId(bundleLower) == norm)) ||
          compactName == compactQuery ||
          compactStem == compactQuery) {
        score = 100;
      } else if (initialsPlusLast.isNotEmpty &&
          (compactQuery == initialsPlusLast ||
              initialsPlusLast.startsWith(compactQuery))) {
        score = 92;
      } else if (initials.length >= 2 && compactQuery == initials) {
        score = 88;
      } else if (nameLower.startsWith(clean) ||
          idLower.startsWith(norm) ||
          compactName.startsWith(compactQuery) ||
          compactStem.startsWith(compactQuery)) {
        score = 82;
      } else if (nameLower.contains(clean) ||
          idLower.contains(norm) ||
          compactName.contains(compactQuery) ||
          compactStem.contains(compactQuery)) {
        score = 72;
      } else if (queryTokens.isNotEmpty) {
        final matchedTokens = queryTokens
            .where(
              (t) =>
                  nameLower.contains(t) ||
                  idLower.contains(t) ||
                  targetStem.contains(t) ||
                  (initialsPlusLast.isNotEmpty && initialsPlusLast.contains(t)),
            )
            .length;
        if (matchedTokens == queryTokens.length) {
          score = 65 + matchedTokens * 5;
        } else if (matchedTokens > 0) {
          score = matchedTokens * 25;
        }
      }

      if (score > bestScore) {
        bestScore = score;
        bestApp = app;
      }
    }
    return bestScore >= 25 ? bestApp : null;
  }

  /// Resolves the executable path for a coding agent or IDE (`claude_code`,
  /// `antigravity`, `cursor`, `vscode`, `codex`, `auto`, or any installed IDE).
  ({String agent, String executable})? resolveCodingAgent(
    String requestedAgent,
  ) {
    final agents = discoverCodingAgents();
    final rawNorm = requestedAgent.trim().toLowerCase();
    final norm = switch (rawNorm) {
      'claude' || 'claude-code' => 'claude_code',
      'agy' || 'antigravity_ide' || 'antigravity-ide' => 'antigravity',
      'code' || 'vs_code' || 'vs-code' || 'visual_studio_code' => 'vscode',
      _ => rawNorm,
    };
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
    if (_scanFileSystem) {
      final refreshed = discoverCodingAgents(forceRefresh: true);
      final retry = refreshed[norm];
      if (retry != null && retry.isNotEmpty) {
        return (agent: norm, executable: retry);
      }
      final appMatch = findApp(norm);
      if (appMatch != null && appMatch.target.isNotEmpty) {
        return (agent: appMatch.id, executable: appMatch.target);
      }
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

    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final appData = Platform.environment['APPDATA'] ?? '';
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    final nvmSymlink = Platform.environment['NVM_SYMLINK'] ?? '';
    final nvmHome = Platform.environment['NVM_HOME'] ?? '';
    final pathEnv = Platform.environment['PATH'] ?? '';
    final pathDirs = pathEnv
        .split(Platform.isWindows ? ';' : ':')
        .where((p) => p.trim().isNotEmpty)
        .toList();

    final nvmDirs = <String>[];
    if (home.isNotEmpty) {
      try {
        final nvmNodeDir = Directory('$home/.nvm/versions/node');
        if (nvmNodeDir.existsSync()) {
          final versions =
              nvmNodeDir
                  .listSync()
                  .whereType<Directory>()
                  .map((d) => '${d.path}/bin')
                  .toList()
                ..sort((a, b) => b.compareTo(a));
          nvmDirs.addAll(versions);
        }
      } catch (_) {}
    }
    if (Platform.isWindows) {
      if (nvmSymlink.isNotEmpty) nvmDirs.add(nvmSymlink);
      for (final root in <String>[
        if (nvmHome.isNotEmpty) nvmHome,
        if (appData.isNotEmpty) '$appData\\nvm',
      ]) {
        try {
          final d = Directory(root);
          if (d.existsSync()) {
            final versions =
                d
                    .listSync()
                    .whereType<Directory>()
                    .map((sub) => sub.path)
                    .toList()
                  ..sort((a, b) => b.compareTo(a));
            nvmDirs.addAll(versions);
          }
        } catch (_) {}
      }
    }

    final searchDirs = <String>[
      if (home.isNotEmpty) ...<String>[
        '$home${Platform.pathSeparator}.local${Platform.pathSeparator}bin',
        '$home${Platform.pathSeparator}.npm-global${Platform.pathSeparator}bin',
        '$home${Platform.pathSeparator}.claude${Platform.pathSeparator}local',
        '$home${Platform.pathSeparator}.volta${Platform.pathSeparator}bin',
        '$home${Platform.pathSeparator}.bun${Platform.pathSeparator}bin',
        '$home${Platform.pathSeparator}.asdf${Platform.pathSeparator}shims',
        if (Platform.isWindows) '$home\\scoop\\shims',
        ...nvmDirs,
      ],
      if (Platform.isMacOS) ...<String>[
        '/opt/homebrew/bin',
        '/usr/local/bin',
        '/Applications/Antigravity.app/Contents/Resources/app/bin',
        '/Applications/Cursor.app/Contents/Resources/app/bin',
        '/Applications/Visual Studio Code.app/Contents/Resources/app/bin',
        if (home.isNotEmpty) ...<String>[
          '$home/Applications/Antigravity.app/Contents/Resources/app/bin',
          '$home/Applications/Cursor.app/Contents/Resources/app/bin',
          '$home/Applications/Visual Studio Code.app/Contents/Resources/app/bin',
        ],
      ],
      if (Platform.isWindows) ...<String>[
        if (appData.isNotEmpty) '$appData\\npm',
        if (localAppData.isNotEmpty) ...<String>[
          '$localAppData\\pnpm',
          '$localAppData\\Microsoft\\WinGet\\Links',
          '$localAppData\\Microsoft\\WindowsApps',
          '$localAppData\\Programs\\Antigravity\\bin',
          '$localAppData\\Programs\\Antigravity',
          '$localAppData\\Programs\\cursor\\resources\\app\\bin',
          '$localAppData\\Programs\\cursor',
          '$localAppData\\Programs\\Microsoft VS Code\\bin',
          '$localAppData\\Programs\\Microsoft VS Code',
          '$localAppData\\AnthropicClaude',
        ],
        '$programFiles\\Antigravity\\bin',
        '$programFiles\\Antigravity',
        '$programFiles\\cursor\\resources\\app\\bin',
        '$programFiles\\cursor',
        '$programFiles\\Microsoft VS Code\\bin',
        '$programFiles\\Microsoft VS Code',
        '$programFilesX86\\Microsoft VS Code\\bin',
        '$programFilesX86\\Microsoft VS Code',
      ],
      ...pathDirs,
    ];

    final candidates = <String, List<String>>{
      'claude_code': Platform.isWindows
          ? const <String>['claude.exe', 'claude.cmd', 'claude']
          : const <String>['claude'],
      'antigravity': Platform.isWindows
          ? const <String>[
              'agy.cmd',
              'agy.exe',
              'antigravity.cmd',
              'antigravity.exe',
              'Antigravity.exe',
            ]
          : const <String>['agy', 'antigravity'],
      'cursor': Platform.isWindows
          ? const <String>['cursor.cmd', 'cursor.exe', 'Cursor.exe']
          : const <String>['cursor'],
      'vscode': Platform.isWindows
          ? const <String>['code.cmd', 'code.exe', 'Code.exe']
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
          final fullPath = dir.endsWith(sep)
              ? '$dir$binName'
              : '$dir$sep$binName';
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

    // Cross-platform fallback (Windows & macOS): if an IDE/agent is installed as a
    // GUI app (.app bundle on macOS, or .exe / .lnk in Start Menu / Programs on Windows)
    // without its CLI symlink on PATH, resolve it from discoverApps().
    const fallbackQueries = <String, List<String>>{
      'antigravity': <String>['antigravity'],
      'cursor': <String>['cursor'],
      'vscode': <String>['visual studio code', 'vscode'],
      'claude_code': <String>['claude code', 'claude'],
    };
    final installedGuiApps = discoverApps();
    for (final entry in fallbackQueries.entries) {
      if (result.containsKey(entry.key)) continue;
      for (final q in entry.value) {
        final qNorm = normalizeId(q);
        for (final app in installedGuiApps) {
          if (app.id == qNorm || app.name.toLowerCase() == q) {
            result[entry.key] = app.target;
            break;
          }
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
      '/System/Applications/Utilities',
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
                .replaceAll(RegExp(r'\.app$', caseSensitive: false), '');
            final id = normalizeId(base);
            register(
              DiscoveredApp(
                id: id,
                name: base,
                kind: AppLaunchKind.bundle,
                target: entity.path,
                bundleId: _readMacOsBundleId(entity.path),
              ),
            );
          } else if (entity is Directory) {
            // Check 1 level deeper for vendor subfolders in /Applications
            try {
              for (final sub in entity.listSync(followLinks: false)) {
                if (sub is Directory && sub.path.endsWith('.app')) {
                  final base = sub.uri.pathSegments
                      .where((s) => s.isNotEmpty)
                      .last
                      .replaceAll(RegExp(r'\.app$', caseSensitive: false), '');
                  final id = normalizeId(base);
                  register(
                    DiscoveredApp(
                      id: id,
                      name: base,
                      kind: AppLaunchKind.bundle,
                      target: sub.path,
                      bundleId: _readMacOsBundleId(sub.path),
                    ),
                  );
                }
              }
            } catch (_) {}
          }
        }
      } catch (_) {}
    }
  }

  static String? _readMacOsBundleId(String appBundlePath) {
    try {
      final plist = File('$appBundlePath/Contents/Info.plist');
      if (!plist.existsSync()) return null;
      final bytes = plist.readAsBytesSync();
      final text = String.fromCharCodes(bytes);
      final xmlMatch = RegExp(
        r'<key>\s*CFBundleIdentifier\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
      ).firstMatch(text);
      if (xmlMatch != null) {
        return xmlMatch.group(1)?.trim();
      }
      final keyIdx = text.indexOf('CFBundleIdentifier');
      if (keyIdx >= 0) {
        final tail = text.substring(keyIdx + 'CFBundleIdentifier'.length);
        final binMatch = RegExp(
          r'([A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){2,})',
        ).firstMatch(tail);
        if (binMatch != null) {
          final candidate = binMatch.group(1)!;
          final lower = candidate.toLowerCase();
          if (!lower.endsWith('.plist') && !lower.endsWith('.icns')) {
            return candidate;
          }
        }
      }
    } catch (_) {}
    return null;
  }

  static bool _isIgnoredWindowsInstallerExe(String lowerFileName) {
    return lowerFileName.startsWith('unins') ||
        lowerFileName.contains('uninstall') ||
        lowerFileName == 'update.exe' ||
        lowerFileName == 'squirrel.exe' ||
        lowerFileName == 'crashpad_handler.exe' ||
        lowerFileName == 'elevate.exe' ||
        lowerFileName.contains('setup') ||
        lowerFileName.contains('helper');
  }

  void _scanWindowsApplications(void Function(DiscoveredApp) register) {
    final programData =
        Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final appData = Platform.environment['APPDATA'] ?? '';
    final localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    final userProfile = Platform.environment['USERPROFILE'] ?? '';
    final publicDir = Platform.environment['PUBLIC'] ?? r'C:\Users\Public';
    final programFiles =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final programFilesX86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';

    // 1. Scan Start Menu and Desktop .lnk shortcuts
    final lnkRoots = <String>[
      '$programData\\Microsoft\\Windows\\Start Menu\\Programs',
      if (appData.isNotEmpty)
        '$appData\\Microsoft\\Windows\\Start Menu\\Programs',
      if (userProfile.isNotEmpty) '$userProfile\\Desktop',
      '$publicDir\\Desktop',
    ];
    for (final root in lnkRoots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      try {
        for (final entity in dir.listSync(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File && entity.path.toLowerCase().endsWith('.lnk')) {
            final fileName = entity.uri.pathSegments.last;
            final base = fileName.substring(0, fileName.length - 4).trim();
            if (base.isEmpty || base.toLowerCase().contains('uninstall')) {
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

    // 2. Scan %LOCALAPPDATA%\Programs, %ProgramFiles%, %ProgramFiles(x86)% (1 level of app folders)
    final exeRoots = <String>[
      if (localAppData.isNotEmpty) '$localAppData\\Programs',
      programFiles,
      programFilesX86,
    ];
    for (final root in exeRoots) {
      final rootDir = Directory(root);
      if (!rootDir.existsSync()) continue;
      try {
        for (final appDir in rootDir.listSync(followLinks: false)) {
          if (appDir is! Directory) continue;
          final folderName = appDir.uri.pathSegments
              .where((s) => s.isNotEmpty)
              .lastOrNull;
          if (folderName == null ||
              folderName.startsWith('.') ||
              folderName.toLowerCase() == 'common files' ||
              folderName.toLowerCase() == 'windowsapps' ||
              folderName.toLowerCase() == 'msbuild' ||
              folderName.toLowerCase() == 'reference assemblies') {
            continue;
          }
          try {
            for (final child in appDir.listSync(followLinks: false)) {
              if (child is File && child.path.toLowerCase().endsWith('.exe')) {
                final fileName = child.uri.pathSegments.last;
                if (_isIgnoredWindowsInstallerExe(fileName.toLowerCase())) {
                  continue;
                }
                final stem = fileName.substring(0, fileName.length - 4).trim();
                final displayName = stem.length >= 3 ? stem : folderName;
                register(
                  DiscoveredApp(
                    id: normalizeId(displayName),
                    name: displayName,
                    kind: AppLaunchKind.exe,
                    target: child.path,
                  ),
                );
              }
            }
          } catch (_) {}
        }
      } catch (_) {}
    }
  }
}

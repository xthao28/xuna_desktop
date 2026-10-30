import 'dart:io';

/// Resolves platform-appropriate directories and file paths for the XUNA
/// Desktop Agent (`UDC-3` §5.6.4):
/// - Windows: `%APPDATA%\XUNA\`
/// - macOS: `~/Library/Application Support/XUNA/`
class AgentPaths {
  const AgentPaths({required this.rootDir});

  /// Resolves the default `XUNA` directory from OS environment variables, or
  /// falls back to [overrideRootDir] when supplied (e.g. in tests).
  factory AgentPaths.resolve({
    Directory? overrideRootDir,
    Map<String, String>? environment,
    bool? isWindowsOverride,
  }) {
    if (overrideRootDir != null) {
      return AgentPaths(rootDir: overrideRootDir);
    }
    final env = environment ?? Platform.environment;
    final isWin = isWindowsOverride ?? Platform.isWindows;
    if (isWin) {
      final appData = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
      return AgentPaths(
        rootDir: Directory('$appData${Platform.pathSeparator}XUNA'),
      );
    }
    final home = env['HOME'] ?? '.';
    return AgentPaths(
      rootDir: Directory('$home/Library/Application Support/XUNA'),
    );
  }

  final Directory rootDir;

  /// `host-policy.json` (`UDC-3` §5.6.4).
  File get policyFile =>
      File('${rootDir.path}${Platform.pathSeparator}host-policy.json');

  /// Local enrollment state (`host-state.json` storing `hostId` and `alias`).
  File get enrollmentStateFile =>
      File('${rootDir.path}${Platform.pathSeparator}host-state.json');

  /// Single-instance lock file (`agent.lock`).
  File get lockFile =>
      File('${rootDir.path}${Platform.pathSeparator}agent.lock');

  /// Directory containing rotating audit JSONL files (`audit/audit-YYYY-MM-DD.jsonl`).
  Directory get auditDir =>
      Directory('${rootDir.path}${Platform.pathSeparator}audit');

  /// Ensures [rootDir] and [auditDir] exist.
  Future<void> ensureDirectories() async {
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }
    if (!await auditDir.exists()) {
      await auditDir.create(recursive: true);
    }
  }
}

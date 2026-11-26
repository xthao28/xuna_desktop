import 'dart:io';

/// Resolves platform-appropriate directories and file paths for the XUNA
/// Desktop Agent (`UDC-3` §5.6.4, `ADR-0019` §1):
/// - Windows: `%APPDATA%\XUNA\` (machine-local undo WAL: `%LOCALAPPDATA%\XUNA\undo\`)
/// - macOS: `~/Library/Application Support/XUNA/` (`undo/` mode `0700`)
class AgentPaths {
  AgentPaths({required this.rootDir, Directory? undoDir})
    : undoDir =
          undoDir ?? Directory('${rootDir.path}${Platform.pathSeparator}undo');

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
      final localAppData = env['LOCALAPPDATA'] ?? appData;
      return AgentPaths(
        rootDir: Directory('$appData${Platform.pathSeparator}XUNA'),
        undoDir: Directory(
          '$localAppData${Platform.pathSeparator}XUNA${Platform.pathSeparator}undo',
        ),
      );
    }
    final home = env['HOME'] ?? '.';
    return AgentPaths(
      rootDir: Directory('$home/Library/Application Support/XUNA'),
    );
  }

  final Directory rootDir;

  /// Machine-local file undo journal directory (`ADR-0019` §1).
  /// Never stored inside `audit/` or uploaded to the backend.
  final Directory undoDir;

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

  /// Ensures [rootDir], [auditDir], and [undoDir] exist.
  Future<void> ensureDirectories() async {
    if (!await rootDir.exists()) {
      await rootDir.create(recursive: true);
    }
    if (!await auditDir.exists()) {
      await auditDir.create(recursive: true);
    }
    if (!await undoDir.exists()) {
      await undoDir.create(recursive: true);
    }
    if (!Platform.isWindows) {
      try {
        await Process.run('/bin/chmod', <String>['700', undoDir.path]);
      } on Object {
        // Best-effort owner-only permissions on POSIX.
      }
    }
  }
}

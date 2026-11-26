import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Fail-closed store for `host-policy.json` (`UDC-3` §5.6.4).
///
/// - If `host-policy.json` is missing, unreadable, or fails schema validation,
///   [evaluator] becomes `HostPolicyEvaluator.corrupted`, `isHealthy == false`,
///   and every tool except `host.status` is denied with `policy_invalid`.
/// - Whenever a reload changes the active policy or health state, [changes]
///   emits the updated [HostPolicyEvaluator] so the session client can send
///   `notifications/tools/list_changed`.
class HostPolicyStore {
  HostPolicyStore({required this.policyFile, required ContentFreeLogger logger})
    : _logger = logger;

  final File policyFile;
  final ContentFreeLogger _logger;
  final StreamController<HostPolicyEvaluator> _changes =
      StreamController<HostPolicyEvaluator>.broadcast();

  HostPolicyEvaluator _evaluator = const HostPolicyEvaluator.corrupted(
    'not_loaded',
  );
  String? _lastCanonicalDigest;

  HostPolicyEvaluator get evaluator => _evaluator;
  bool get isHealthy => _evaluator.isHealthy;
  String? get trayBanner => _evaluator.trayBanner;

  Stream<HostPolicyEvaluator> get changes => _changes.stream;

  /// Loads and validates [policyFile] from disk. Never throws; any I/O or
  /// schema failure transitions into fail-closed corrupted mode.
  Future<HostPolicyEvaluator> reload() async {
    HostPolicyEvaluator next;
    String? nextDigest;
    try {
      if (!await policyFile.exists()) {
        next = const HostPolicyEvaluator.corrupted('missing_policy_file');
      } else {
        final rawText = await policyFile.readAsString();
        next = HostPolicyEvaluator.fromJsonString(rawText);
        if (next.isHealthy && next.policy != null) {
          nextDigest = canonicalJson(next.policy!.toJson());
        }
      }
    } on FileSystemException {
      next = const HostPolicyEvaluator.corrupted('unreadable_policy_file');
    }

    final changed =
        next.isHealthy != _evaluator.isHealthy ||
        nextDigest != _lastCanonicalDigest;
    _evaluator = next;
    _lastCanonicalDigest = nextDigest;

    _logger.info('policy.reload', <String, Object?>{'healthy': next.isHealthy});

    if (changed && !_changes.isClosed) {
      _changes.add(next);
    }
    return next;
  }

  /// Writes a validated [HostPolicy] to [policyFile] (applying owner-only
  /// permissions on POSIX) and reloads the evaluator.
  Future<HostPolicyEvaluator> savePolicy(HostPolicy policy) async {
    await policyFile.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    final formatted = '${encoder.convert(policy.toJson())}\n';
    await policyFile.writeAsString(formatted, flush: true);
    if (!Platform.isWindows) {
      try {
        await Process.run('chmod', <String>['0600', policyFile.path]);
      } on ProcessException {
        // Best-effort chmod on POSIX environments.
      }
    }
    return reload();
  }

  static const List<ToolFamily> _defaultDesktopFamilies = <ToolFamily>[
    ToolFamily.media,
    ToolFamily.app,
    ToolFamily.url,
    ToolFamily.workflow,
    ToolFamily.host,
    ToolFamily.cu,
    ToolFamily.screen,
    ToolFamily.ui,
    ToolFamily.input,
  ];

  /// Writes a safe default `host-policy.json` if the file does not exist yet
  /// and the owner triggers "Khôi phục mặc định" in the settings window.
  Future<HostPolicyEvaluator> writeDefaultPolicy() {
    final defaultPolicy = HostPolicy(
      schemaVersion: 1,
      trustPreset: TrustPreset.standard,
      families: <ToolFamily, FamilyPolicyDecision>{
        for (final family in _defaultDesktopFamilies)
          family: FamilyPolicyDecision.allow,
      },
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>['github.com'],
      workflows: const <WorkflowConfig>[],
      players: const <String>['spotify', 'music'],
    );
    return savePolicy(defaultPolicy);
  }

  /// Applies the local-only "Dòng lệnh & tệp" switch (`ADR-0018`): it controls
  /// `exec.*` through `shellControl.enabled` and the `files` family (`fs.*`,
  /// `finder.*`) together. On sets `files: allow`; off removes `files` so it
  /// falls back to denied (absent family).
  static HostPolicy applyShellAndFilesSwitch(HostPolicy policy, bool enabled) {
    final families = Map<ToolFamily, FamilyPolicyDecision>.from(
      policy.families,
    );
    if (enabled) {
      families[ToolFamily.files] = FamilyPolicyDecision.allow;
    } else {
      families.remove(ToolFamily.files);
    }
    return policy.copyWith(
      shellControl: policy.shellControl.copyWith(enabled: enabled),
      families: families,
    );
  }

  /// Adds `files: allow` to a healthy policy whose `shellControl` was enabled
  /// before the switch also covered `files`. An explicit `files: block` is
  /// kept, and nothing changes while `shellControl` is off.
  Future<HostPolicyEvaluator> migrateShellFilesFamily() async {
    final current = _evaluator.policy;
    if (!_evaluator.isHealthy || current == null) {
      return _evaluator;
    }
    if (!current.shellControl.enabled ||
        current.families.containsKey(ToolFamily.files)) {
      return _evaluator;
    }
    return savePolicy(
      current.copyWith(
        families: <ToolFamily, FamilyPolicyDecision>{
          ...current.families,
          ToolFamily.files: FamilyPolicyDecision.allow,
        },
      ),
    );
  }

  /// Computer-use families introduced after the first `host-policy.json`
  /// format. Only these are added by [migrateMissingDesktopFamilies].
  static const List<ToolFamily> _migratedComputerUseFamilies = <ToolFamily>[
    ToolFamily.cu,
    ToolFamily.screen,
    ToolFamily.ui,
    ToolFamily.input,
  ];

  /// Adds `allow` for the computer-use families (`cu`, `screen`, `ui`,
  /// `input`) that are absent from an older healthy `host-policy.json`.
  ///
  /// Every other family keeps its meaning: absent stays denied, and an
  /// explicit `block` is never overwritten. This runs on every start, so the
  /// owner turns a computer-use family off with `block`, not by deleting it.
  Future<HostPolicyEvaluator> migrateMissingDesktopFamilies() async {
    final current = _evaluator.policy;
    if (!_evaluator.isHealthy || current == null) {
      return _evaluator;
    }
    final updatedFamilies = <ToolFamily, FamilyPolicyDecision>{
      ...current.families,
    };
    var addedAny = false;
    for (final family in _migratedComputerUseFamilies) {
      if (!updatedFamilies.containsKey(family)) {
        updatedFamilies[family] = FamilyPolicyDecision.allow;
        addedAny = true;
      }
    }
    if (!addedAny) {
      return _evaluator;
    }
    return savePolicy(current.copyWith(families: updatedFamilies));
  }

  /// Adds a local-only `shellControl.workspaceRoots` entry (`ADR-0018`):
  /// `fs.*` writes inside a root are `R2`, elsewhere `R3`. Returns a stable
  /// code: `added`, `policy_invalid`, `invalid_path` (empty/relative/control
  /// chars), `not_a_directory`, `forbidden` (Hard-Deny location), `too_broad`
  /// (filesystem/drive root, the home directory or one of its ancestors),
  /// `duplicate`, `limit_reached`. The canonical (symlink-resolved) path is
  /// stored.
  Future<String> addWorkspaceRoot(
    String rawPath, {
    String? homeDirectory,
  }) async {
    final current = _evaluator.policy;
    if (!_evaluator.isHealthy || current == null) return 'policy_invalid';
    final windows = Platform.isWindows;
    final home =
        homeDirectory ?? Platform.environment[windows ? 'USERPROFILE' : 'HOME'];
    final trimmed = rawPath.trim().replaceAll('"', '');
    final normalized = normalizeHostPath(
      trimmed,
      homeDirectory: home,
      windows: windows,
    );
    if (trimmed.isEmpty || normalized == null) return 'invalid_path';
    final dir = Directory(
      windows ? normalized.replaceAll('/', r'\') : normalized,
    );
    if (!await dir.exists()) return 'not_a_directory';
    final String canonical;
    try {
      canonical = dir.resolveSymbolicLinksSync();
    } on FileSystemException {
      return 'not_a_directory';
    }
    final canonNorm = normalizeHostPath(canonical, windows: windows);
    if (canonNorm == null) return 'invalid_path';
    if (hardDeniedPathReason(canonNorm) != null) return 'forbidden';
    final segments = canonNorm.split('/').where((s) => s.isNotEmpty).length;
    if (segments <= (windows ? 1 : 0)) return 'too_broad';
    final caseInsensitive = windows || Platform.isMacOS;
    final homeNorm = home == null
        ? null
        : normalizeHostPath(home, windows: windows);
    String? homeRealNorm;
    if (home != null) {
      try {
        final homeDir = Directory(windows ? home.replaceAll('/', r'\') : home);
        if (homeDir.existsSync()) {
          homeRealNorm = normalizeHostPath(
            homeDir.resolveSymbolicLinksSync(),
            windows: windows,
          );
        }
      } on FileSystemException {
        homeRealNorm = null;
      }
    }
    if ((homeNorm != null &&
            isPathInsideRoot(
              homeNorm,
              canonNorm,
              caseInsensitive: caseInsensitive,
            )) ||
        (homeRealNorm != null &&
            isPathInsideRoot(
              homeRealNorm,
              canonNorm,
              caseInsensitive: caseInsensitive,
            ))) {
      return 'too_broad';
    }
    final roots = current.shellControl.workspaceRoots;
    final duplicate = roots.any((r) {
      final n = normalizeHostPath(r, homeDirectory: home, windows: windows);
      return n != null &&
          (caseInsensitive
              ? n.toLowerCase() == canonNorm.toLowerCase()
              : n == canonNorm);
    });
    if (duplicate) return 'duplicate';
    if (roots.length >= 16) return 'limit_reached';
    await savePolicy(
      current.copyWith(
        shellControl: current.shellControl.copyWith(
          workspaceRoots: <String>[...roots, canonical],
        ),
      ),
    );
    return isHealthy ? 'added' : 'policy_invalid';
  }

  /// Removes an exact `shellControl.workspaceRoots` entry. Returns `false`
  /// when the policy is unhealthy or the entry is absent.
  Future<bool> removeWorkspaceRoot(String root) async {
    final current = _evaluator.policy;
    if (!_evaluator.isHealthy || current == null) return false;
    final roots = current.shellControl.workspaceRoots;
    if (!roots.contains(root)) return false;
    await savePolicy(
      current.copyWith(
        shellControl: current.shellControl.copyWith(
          workspaceRoots: roots.where((r) => r != root).toList(),
        ),
      ),
    );
    return true;
  }

  StreamSubscription<FileSystemEvent>? _watchSub;
  Timer? _watchDebounce;

  /// Reloads automatically when `host-policy.json` changes on disk (e.g. the
  /// owner edits it by hand), debounced so a multi-write save reloads once.
  /// Reload keeps its fail-closed semantics: a broken edit turns the policy
  /// `policy_invalid`. Never throws; if the OS watcher is unavailable the
  /// store keeps the loaded policy and [reload] still works on demand.
  Future<void> startWatching({
    Duration debounce = const Duration(milliseconds: 300),
  }) async {
    if (_watchSub != null) return;
    final fileName = _baseName(policyFile.path);
    try {
      await policyFile.parent.create(recursive: true);
      _watchSub = policyFile.parent.watch().listen((event) {
        final touched = <String>[
          event.path,
          if (event is FileSystemMoveEvent && event.destination != null)
            event.destination!,
        ];
        if (!touched.any((p) => _baseName(p) == fileName)) return;
        _watchDebounce?.cancel();
        _watchDebounce = Timer(debounce, () => unawaited(reload()));
      }, onError: (Object _) {});
    } on FileSystemException {
      _watchSub = null;
    }
  }

  Future<void> stopWatching() async {
    _watchDebounce?.cancel();
    _watchDebounce = null;
    await _watchSub?.cancel();
    _watchSub = null;
  }

  static String _baseName(String path) =>
      path.split(RegExp(r'[\\/]')).last.toLowerCase();

  Future<void> dispose() async {
    await stopWatching();
    await _changes.close();
  }
}

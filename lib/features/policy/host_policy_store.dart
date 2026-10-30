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

  /// Writes a safe default `host-policy.json` if the file does not exist yet
  /// and the owner triggers "Khôi phục mặc định" in the settings window.
  Future<HostPolicyEvaluator> writeDefaultPolicy() {
    final defaultPolicy = HostPolicy(
      schemaVersion: 1,
      families: const <ToolFamily, FamilyPolicyDecision>{
        ToolFamily.media: FamilyPolicyDecision.allow,
        ToolFamily.app: FamilyPolicyDecision.allow,
        ToolFamily.url: FamilyPolicyDecision.allow,
        ToolFamily.workflow: FamilyPolicyDecision.allow,
      },
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>['github.com'],
      workflows: const <WorkflowConfig>[],
      players: const <String>['spotify', 'music'],
    );
    return savePolicy(defaultPolicy);
  }

  Future<void> dispose() async {
    await _changes.close();
  }
}

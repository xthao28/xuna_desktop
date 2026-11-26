import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// P0.6: `host-policy.json` edited on disk is picked up without restarting
/// (Windows live 2026-11-26 had to restart the app after manual edits).
void main() {
  late Directory dir;
  late HostPolicyStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('xuna_policy_watch_');
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    store = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: ContentFreeLogger(),
    );
    await store.writeDefaultPolicy();
    await store.startWatching(debounce: const Duration(milliseconds: 50));
  });

  tearDown(() async {
    await store.dispose();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  Future<HostPolicyEvaluator> nextChange() =>
      store.changes.first.timeout(const Duration(seconds: 10));

  test(
    'a valid edit on disk reloads the evaluator and emits a change',
    () async {
      expect(store.evaluator.policy!.shellControl.enabled, isFalse);
      final json =
          jsonDecode(store.policyFile.readAsStringSync())
              as Map<String, Object?>;
      (json['shellControl'] as Map<String, Object?>)['enabled'] = true;
      final changed = nextChange();
      await store.policyFile.writeAsString(jsonEncode(json), flush: true);
      final evaluator = await changed;
      expect(evaluator.isHealthy, isTrue);
      expect(evaluator.policy!.shellControl.enabled, isTrue);
      expect(store.evaluator.policy!.shellControl.enabled, isTrue);
    },
  );

  test('a broken edit on disk turns the store fail-closed', () async {
    final changed = nextChange();
    await store.policyFile.writeAsString('{broken', flush: true);
    final evaluator = await changed;
    expect(evaluator.isHealthy, isFalse);
    expect(
      store.evaluator
          .evaluateInvocation(
            toolName: 'exec.run',
            arguments: const <String, Object?>{'command': 'echo hi'},
          )
          .errorCode,
      'policy_invalid',
    );
  });

  test('after stopWatching, disk edits are no longer picked up', () async {
    await store.stopWatching();
    final json =
        jsonDecode(store.policyFile.readAsStringSync()) as Map<String, Object?>;
    (json['shellControl'] as Map<String, Object?>)['enabled'] = true;
    await store.policyFile.writeAsString(jsonEncode(json), flush: true);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.evaluator.policy!.shellControl.enabled, isFalse);
  });
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// The local "Dòng lệnh & tệp" switch controls `exec.*` (`shellControl`) and
/// the `files` family (`fs.*`) together (`ADR-0018`, Windows live 2026-11-26:
/// a fresh default policy left `fs.*` `policy_blocked` with the switch on).
void main() {
  late Directory dir;
  late HostPolicyStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('xuna_shell_files_');
    final paths = AgentPaths.resolve(overrideRootDir: dir);
    await paths.ensureDirectories();
    store = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: ContentFreeLogger(),
    );
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  PolicyEvaluationResult evaluate(String tool, Map<String, Object?> args) =>
      store.evaluator.evaluateInvocation(toolName: tool, arguments: args);

  Map<String, Object?> onDisk() =>
      jsonDecode(store.policyFile.readAsStringSync()) as Map<String, Object?>;

  final listArgs = <String, Object?>{'path': '${Directory.systemTemp.path}/x'};
  const runArgs = <String, Object?>{'command': 'echo hi'};

  test(
    'fresh default policy keeps fs.* and exec.* denied (fail-closed)',
    () async {
      await store.writeDefaultPolicy();
      expect(
        store.evaluator.policy!.families.containsKey(ToolFamily.files),
        isFalse,
      );
      expect(evaluate('fs.list_files', listArgs).errorCode, 'policy_blocked');
      expect(evaluate('exec.run', runArgs).errorCode, 'shell_not_enabled');
    },
  );

  test(
    'switch on allows files and shell; switch off denies both again',
    () async {
      final fresh = await store.writeDefaultPolicy();

      await store.savePolicy(
        HostPolicyStore.applyShellAndFilesSwitch(fresh.policy!, true),
      );
      expect(store.isHealthy, isTrue);
      expect(store.evaluator.policy!.shellControl.enabled, isTrue);
      expect(store.evaluator.policy!.isFamilyAllowed(ToolFamily.files), isTrue);
      expect(
        evaluate('fs.list_files', listArgs).errorCode,
        isNot('policy_blocked'),
      );
      expect(
        evaluate('exec.run', runArgs).errorCode,
        isNot('shell_not_enabled'),
      );
      final enabledJson = onDisk();
      expect((enabledJson['families'] as Map)['files'], 'allow');
      expect((enabledJson['shellControl'] as Map)['enabled'], isTrue);

      await store.savePolicy(
        HostPolicyStore.applyShellAndFilesSwitch(
          store.evaluator.policy!,
          false,
        ),
      );
      expect(store.evaluator.policy!.shellControl.enabled, isFalse);
      expect(
        store.evaluator.policy!.families.containsKey(ToolFamily.files),
        isFalse,
      );
      expect(evaluate('fs.list_files', listArgs).errorCode, 'policy_blocked');
      expect(evaluate('exec.run', runArgs).errorCode, 'shell_not_enabled');
      expect((onDisk()['families'] as Map).containsKey('files'), isFalse);
    },
  );

  test('switch keeps every other family and shellControl setting', () async {
    final fresh = await store.writeDefaultPolicy();
    final before = fresh.policy!;
    final on = HostPolicyStore.applyShellAndFilesSwitch(before, true);
    for (final family in before.families.keys) {
      expect(on.families[family], before.families[family]);
    }
    expect(
      on.shellControl.maxConcurrentTasks,
      before.shellControl.maxConcurrentTasks,
    );
    expect(on.shellControl.workspaceRoots, before.shellControl.workspaceRoots);
  });

  group('migrateShellFilesFamily', () {
    Future<void> seed({
      required bool shellEnabled,
      FamilyPolicyDecision? files,
    }) async {
      await store.savePolicy(
        HostPolicy(
          families: <ToolFamily, FamilyPolicyDecision>{
            ToolFamily.media: FamilyPolicyDecision.allow,
            if (files != null) ToolFamily.files: files,
          },
          apps: const <AllowedAppConfig>[],
          urlDomains: const <String>[],
          workflows: const <WorkflowConfig>[],
          players: const <String>[],
          shellControl: ShellControlPolicy(enabled: shellEnabled),
        ),
      );
    }

    test('adds files when shellControl was already enabled', () async {
      await seed(shellEnabled: true);
      final migrated = await store.migrateShellFilesFamily();
      expect(migrated.policy!.isFamilyAllowed(ToolFamily.files), isTrue);
      expect((onDisk()['families'] as Map)['files'], 'allow');
      expect(
        evaluate('fs.list_files', listArgs).errorCode,
        isNot('policy_blocked'),
      );
    });

    test('keeps an explicit files block', () async {
      await seed(shellEnabled: true, files: FamilyPolicyDecision.block);
      final migrated = await store.migrateShellFilesFamily();
      expect(migrated.policy!.isFamilyAllowed(ToolFamily.files), isFalse);
      expect(evaluate('fs.list_files', listArgs).errorCode, 'policy_blocked');
    });

    test('does nothing while shellControl is off', () async {
      await seed(shellEnabled: false);
      final migrated = await store.migrateShellFilesFamily();
      expect(migrated.policy!.families.containsKey(ToolFamily.files), isFalse);
      expect(evaluate('fs.list_files', listArgs).errorCode, 'policy_blocked');
    });

    test('does nothing on a corrupted policy (stays fail-closed)', () async {
      await store.policyFile.writeAsString('{not json');
      await store.reload();
      final migrated = await store.migrateShellFilesFamily();
      expect(migrated.isHealthy, isFalse);
      expect(store.policyFile.readAsStringSync(), '{not json');
      expect(evaluate('fs.list_files', listArgs).errorCode, 'policy_invalid');
    });
  });
}

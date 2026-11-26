import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// P0.7: local-only `shellControl.workspaceRoots` editing (no UI existed;
/// Windows live 2026-11-26 had to edit `host-policy.json` by hand).
void main() {
  late Directory tmp;
  late Directory home;
  late HostPolicyStore store;
  final windows = Platform.isWindows;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('xuna_ws_roots_');
    home = Directory('${tmp.path}${Platform.pathSeparator}home')..createSync();
    final paths = AgentPaths.resolve(
      overrideRootDir: Directory('${tmp.path}${Platform.pathSeparator}cfg'),
    );
    await paths.ensureDirectories();
    store = HostPolicyStore(
      policyFile: paths.policyFile,
      logger: ContentFreeLogger(),
    );
    await store.writeDefaultPolicy();
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Directory mk(String rel) =>
      Directory('${home.path}${Platform.pathSeparator}$rel')
        ..createSync(recursive: true);

  Future<String> add(String path) =>
      store.addWorkspaceRoot(path, homeDirectory: home.path);

  test(
    'adds a project folder; writes inside it classify as R2 workspace',
    () async {
      final proj = mk('Projects${Platform.pathSeparator}app');
      expect(await add(proj.path), 'added');
      final roots = store.evaluator.policy!.shellControl.workspaceRoots;
      expect(roots, hasLength(1));

      final shell = store.evaluator.policy!.shellControl;
      final inside = normalizeHostPath(
        '${proj.path}${Platform.pathSeparator}a.txt',
        windows: windows,
      )!;
      final outside = normalizeHostPath(
        '${home.path}${Platform.pathSeparator}other.txt',
        windows: windows,
      )!;
      final realHome = home.resolveSymbolicLinksSync();
      expect(
        classifyFsPath(
          normalizedPath: normalizeHostPath(
            '${proj.resolveSymbolicLinksSync()}${Platform.pathSeparator}a.txt',
            windows: windows,
          )!,
          access: FsAccessKind.write,
          shellControl: shell,
          homeDirectory: realHome,
          windows: windows,
        ).risk,
        RiskTier.r2,
        reason: inside,
      );
      expect(
        classifyFsPath(
          normalizedPath: outside,
          access: FsAccessKind.write,
          shellControl: shell,
          homeDirectory: home.path,
          windows: windows,
        ).risk,
        RiskTier.r3,
      );
    },
  );

  test('rejects invalid, missing, forbidden and too-broad folders', () async {
    expect(await add(''), 'invalid_path');
    expect(await add('relative/folder'), 'invalid_path');
    expect(
      await add('${home.path}${Platform.pathSeparator}nope'),
      'not_a_directory',
    );
    expect(await add(mk('.ssh').path), 'forbidden');
    expect(await add(home.path), 'too_broad');
    expect(await add(tmp.path), 'too_broad', reason: 'ancestor of home');
    expect(await add(windows ? r'C:\' : '/'), 'too_broad');
    expect(store.evaluator.policy!.shellControl.workspaceRoots, isEmpty);
  });

  test(
    'duplicates are refused (case/separator-insensitive on Windows)',
    () async {
      final proj = mk('work');
      expect(await add(proj.path), 'added');
      expect(await add(proj.path), 'duplicate');
      if (windows) {
        expect(await add(proj.path.toUpperCase()), 'duplicate');
        expect(await add('${proj.path}${Platform.pathSeparator}'), 'duplicate');
      }
    },
  );

  test('limit of 16 roots', () async {
    for (var i = 0; i < 16; i++) {
      expect(await add(mk('p$i').path), 'added');
    }
    expect(await add(mk('p16').path), 'limit_reached');
    expect(store.evaluator.policy!.shellControl.workspaceRoots, hasLength(16));
  });

  test('remove drops exactly that entry', () async {
    await add(mk('a').path);
    await add(mk('b').path);
    final roots = store.evaluator.policy!.shellControl.workspaceRoots;
    expect(await store.removeWorkspaceRoot(roots.first), isTrue);
    expect(store.evaluator.policy!.shellControl.workspaceRoots, [roots.last]);
    expect(await store.removeWorkspaceRoot('not-there'), isFalse);
  });

  test('corrupted policy refuses changes (fail-closed)', () async {
    await store.policyFile.writeAsString('{bad');
    await store.reload();
    expect(await add(mk('x').path), 'policy_invalid');
    expect(store.policyFile.readAsStringSync(), '{bad');
  });
}

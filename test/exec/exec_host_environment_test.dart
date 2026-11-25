import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/features/exec/exec_host_environment.dart';

void main() {
  group('extractMarkedShellPath', () {
    test('extracts PATH surrounded by noisy interactive shell banners', () {
      const noisy =
          'Welcome to zsh\nNow using node v22.17.1\n'
          '__XUNA_PATH_START__/Users/o/.nvm/versions/node/v22.17.1/bin:/usr/bin__XUNA_PATH_END__\n'
          'trailing noise';
      expect(
        extractMarkedShellPath(noisy),
        '/Users/o/.nvm/versions/node/v22.17.1/bin:/usr/bin',
      );
    });

    test('fails closed on missing markers, newlines, or control bytes', () {
      expect(extractMarkedShellPath('/usr/bin:/bin'), isNull);
      expect(
        extractMarkedShellPath('__XUNA_PATH_START__a\nb__XUNA_PATH_END__'),
        isNull,
      );
      expect(
        extractMarkedShellPath('__XUNA_PATH_START____XUNA_PATH_END__'),
        isNull,
      );
    });
  });

  group('mergeMacToolchainPaths', () {
    test(
      'preserves probed order and appends existing local toolchains once',
      () {
        const existingDirs = <String>{
          '/Users/o/.nvm/versions/node',
          '/Users/o/.nvm/versions/node/v22.17.1/bin',
          '/Users/o/fvm/default/bin',
          '/Users/o/.bun/bin',
          '/opt/homebrew/bin',
        };
        final merged = mergeMacToolchainPaths(
          '/usr/local/bin:/usr/bin:/bin:/Users/o/fvm/default/bin',
          homeDirectory: '/Users/o',
          dirExists: existingDirs.contains,
          listSubdirs: (dir) => dir == '/Users/o/.nvm/versions/node'
              ? const <String>['v18.20.0', 'v22.17.1', 'v20.11.0']
              : const <String>[],
        );
        final parts = merged.split(':');
        expect(parts.take(4), const <String>[
          '/usr/local/bin',
          '/usr/bin',
          '/bin',
          '/Users/o/fvm/default/bin',
        ]);
        expect(parts, contains('/Users/o/.nvm/versions/node/v22.17.1/bin'));
        expect(parts, contains('/Users/o/.bun/bin'));
        expect(parts, contains('/opt/homebrew/bin'));
        expect(
          parts,
          isNot(contains('/Users/o/.nvm/versions/node/v18.20.0/bin')),
        );
        expect(
          parts.where((p) => p == '/Users/o/fvm/default/bin'),
          hasLength(1),
        );
      },
    );
  });
}

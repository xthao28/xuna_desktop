import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/features/discovery/windows_stdio_launcher.dart';
import 'package:xuna_desktop/features/exec/windows_create_process.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

void main() {
  group('Windows CreateProcessW helpers (P0 + P1-a)', () {
    test(
      'builds verbatim cmd.exe /d /s /c command line without MSVCRT escaping',
      () {
        final line = buildWindowsCmdCommandLine(
          r'C:\Windows\System32\cmd.exe',
          'node args.js "hello world"',
        );
        expect(
          line,
          r'C:\Windows\System32\cmd.exe /d /s /c "node args.js "hello world""',
        );
        // Quotes inside command are NEVER backslash-escaped.
        expect(line, isNot(contains(r'\"')));
      },
    );

    test('quotes comspec containing spaces and rejects CR/LF/NUL', () {
      expect(
        buildWindowsCmdCommandLine(r'C:\Custom Dir\cmd.exe', 'echo ok'),
        r'"C:\Custom Dir\cmd.exe" /d /s /c "echo ok"',
      );
      for (final bad in const <String>['a\nb', 'a\rb', 'a\x00b']) {
        expect(
          () => buildWindowsCmdCommandLine('cmd.exe', bad),
          throwsA(
            isA<XunaHostChannelException>().having(
              (e) => e.errorCode,
              'errorCode',
              'invalid_exec_command',
            ),
          ),
        );
      }
    });

    test(
      'encodes sorted UTF-16LE environment block with double NUL terminator',
      () {
        final block = encodeWindowsEnvironmentBlock(const <String, String>{
          'Path': r'C:\Windows',
          'APPDATA': r'C:\Users\o\AppData',
          'BAD=KEY': 'skip',
        });
        final decoded = String.fromCharCodes(block);
        expect(
          decoded,
          'APPDATA=C:\\Users\\o\\AppData\x00Path=C:\\Windows\x00\x00',
        );
        expect(encodeWindowsEnvironmentBlock(const <String, String>{}), [0, 0]);
      },
    );

    test('resolves ComSpec from environment with System32 fallback', () {
      expect(
        resolveWindowsComspecPath(
          'cmd.exe',
          environment: const <String, String>{'ComSpec': r'D:\Win\cmd.exe'},
        ),
        r'D:\Win\cmd.exe',
      );
      expect(
        resolveWindowsComspecPath('cmd.exe', environment: const {}),
        r'C:\Windows\System32\cmd.exe',
      );
    });
  });

  group('Windows PATHEXT & npm .cmd shim resolver (P1-b)', () {
    const npmShim = '''
@ECHO off
GOTO start
:find_dp0
SET dp0=%~dp0
EXIT /b
:start
SETLOCAL
CALL :find_dp0
endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & "%_prog%"  "%dp0%\\node_modules\\@scope\\mcp-srv\\dist\\index.js" %*
''';

    test('unwraps npm .cmd shim found via PATHEXT directly to node.exe', () {
      const env = <String, String>{
        'PATH': r'C:\Program Files\nodejs;C:\Users\owner\AppData\Roaming\npm',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      };
      const files = <String, String>{
        r'C:\Users\owner\AppData\Roaming\npm\mcp-srv.cmd': npmShim,
        r'C:\Users\owner\AppData\Roaming\npm\node_modules\@scope\mcp-srv\dist\index.js':
            '// entry',
        r'C:\Program Files\nodejs\node.exe': 'bin',
      };
      final resolved = resolveStdioCommand(
        'mcp-srv',
        const <String>['--root', r'C:\repo'],
        isWindows: true,
        environment: env,
        fileExists: files.containsKey,
        readFile: (p) => files[p],
      );
      expect(resolved.usesCmdShell, isFalse);
      expect(resolved.executable, r'C:\Program Files\nodejs\node.exe');
      expect(resolved.args, <String>[
        r'C:\Users\owner\AppData\Roaming\npm\node_modules\@scope\mcp-srv\dist\index.js',
        '--root',
        r'C:\repo',
      ]);
    });

    test('resolves .exe directly before .cmd according to PATHEXT order', () {
      const env = <String, String>{
        'PATH': r'C:\tools',
        'PATHEXT': '.COM;.EXE;.BAT;.CMD',
      };
      const files = <String>{r'C:\tools\mytool.exe', r'C:\tools\mytool.cmd'};
      final resolved = resolveStdioCommand(
        'mytool',
        const <String>['--stdio'],
        isWindows: true,
        environment: env,
        fileExists: files.contains,
        readFile: (_) => null,
      );
      expect(resolved.usesCmdShell, isFalse);
      expect(resolved.executable, r'C:\tools\mytool.exe');
      expect(resolved.args, const <String>['--stdio']);
    });

    test(
      'custom non-shim .bat uses safe cmd.exe fallback and blocks injection',
      () {
        const env = <String, String>{
          'PATH': r'C:\custom',
          'PATHEXT': '.COM;.EXE;.BAT;.CMD',
          'ComSpec': r'C:\Windows\System32\cmd.exe',
        };
        const files = <String, String>{
          r'C:\custom\wrapper.bat': '@echo off\r\nmybin.exe %*\r\n',
        };
        final ok = resolveStdioCommand(
          'wrapper',
          const <String>['--port', '8080'],
          isWindows: true,
          environment: env,
          fileExists: files.containsKey,
          readFile: (p) => files[p],
        );
        expect(ok.usesCmdShell, isTrue);
        expect(ok.executable, r'C:\Windows\System32\cmd.exe');
        expect(ok.rawCmdLine, r'"C:\custom\wrapper.bat" --port 8080');

        // Injection attempts via CR/LF, `%VAR%` or `"` must fail closed.
        for (final badArg in const <String>[
          'a\ndel x',
          '%TEMP%',
          'a" & del x',
        ]) {
          expect(
            () => resolveStdioCommand(
              'wrapper',
              <String>[badArg],
              isWindows: true,
              environment: env,
              fileExists: files.containsKey,
              readFile: (p) => files[p],
            ),
            throwsA(isA<ProcessException>()),
            reason: badArg,
          );
        }
      },
    );

    test('rejects forbidden shell executables after PATHEXT resolution', () {
      const env = <String, String>{
        'PATH': r'C:\Windows\System32',
        'PATHEXT': '.EXE',
      };
      expect(
        () => resolveStdioCommand(
          'cmd',
          const <String>[],
          isWindows: true,
          environment: env,
          fileExists: (p) => p == r'C:\Windows\System32\cmd.exe',
        ),
        throwsA(isA<ProcessException>()),
      );
    });

    test('non-Windows leaves executable and args untouched', () {
      final resolved = resolveStdioCommand('npx', const <String>[
        '-y',
        '@scope/srv',
      ], isWindows: false);
      expect(resolved.usesCmdShell, isFalse);
      expect(resolved.executable, 'npx');
      expect(resolved.args, const <String>['-y', '@scope/srv']);
    });
  });

  group('Real Windows CreateProcessW quoting runtime test', () {
    final skip = Platform.isWindows ? false : 'Windows-only runtime test';

    test(
      'preserves double quotes verbatim and neutralizes ^"" injection',
      () async {
        final handle = startWindowsNativeCmdProcess(
          comspec: 'cmd.exe',
          command: 'echo "hello world"',
          cwd: Directory.systemTemp.path,
          environment: sanitizeExecEnvironment(
            Platform.environment,
            windows: true,
          ),
        );
        try {
          final bytes = <int>[];
          var exited = false;
          int? code;
          final deadline = DateTime.now().add(const Duration(seconds: 10));
          while (!exited && DateTime.now().isBefore(deadline)) {
            final p = await handle.poll();
            bytes.addAll(p.data);
            exited = p.exited;
            code = p.exitCode;
            if (!exited) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
          }
          expect(exited, isTrue);
          expect(code, 0);
          final out = String.fromCharCodes(bytes);
          expect(out, contains('"hello world"'));
          expect(out, isNot(contains(r'\"')));
        } finally {
          await handle.release();
        }
      },
      skip: skip,
    );
  });
}

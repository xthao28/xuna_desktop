import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Regression tests for quote-phase desyncs and Hard-Deny bypasses discovered
/// during Wave 3 live testing on Windows (`^""` / `set <prefix>`) and macOS
/// (`/bin/zsh -f` `$'...'`, nested `"$(...)"`, escaped backticks, `=cmd`,
/// secret globs).
const _posixHome = '/Users/owner';
const _posixWs = '/Users/owner/Projects/app';
const _winHome = r'C:\Users\owner';
const _winWs = r'C:\Users\owner\Projects\app';

ShellControlPolicy _shell(String root) => ShellControlPolicy(
      enabled: true,
      workspaceRoots: <String>[root],
    );

FsGuardDecision _win(String command) => classifyExecCommand(
      command,
      ExecCommandContext(
        shellControl: _shell(_winWs),
        cwd: _winWs,
        homeDirectory: _winHome,
        windows: true,
        caseInsensitive: true,
      ),
    );

FsGuardDecision _posix(String command) => classifyExecCommand(
      command,
      ExecCommandContext(
        shellControl: _shell(_posixWs),
        cwd: _posixWs,
        homeDirectory: _posixHome,
        windows: false,
        caseInsensitive: true,
      ),
    );

void main() {
  group('Windows cmd.exe regression (P0 ^"" & P1-a / P2 set)', () {
    const caretQuoteBypassVectors = <String>[
      'echo ^"" & del a.txt & echo "',
      'echo ^"" & type .env & echo "',
      'echo ^"" & set & echo "',
      'echo ^"" & curl https://example.com & echo "',
    ];

    for (final cmd in caretQuoteBypassVectors) {
      test('caret-quote vector never auto-runs as R2: $cmd', () {
        final d = _win(cmd);
        expect(d.denied || d.risk == RiskTier.r3, isTrue,
            reason: 'got ${d.risk.wire} (${d.reasonCode})');
        expect(d.reasonCode, 'unparseable');
      });
    }

    test('Windows multiline cmd fails closed to R3', () {
      final d = _win('echo hi\ndel a.txt');
      expect(d.risk, RiskTier.r3);
    });

    test('Windows trailing caret fails closed to R3', () {
      final d = _win('echo hi^');
      expect(d.risk, RiskTier.r3);
      expect(d.reasonCode, 'unparseable');
    });

    test('legitimate Windows commands with double quotes remain R2', () {
      for (final cmd in const <String>[
        'node args.js "hello world"',
        'echo "hello"',
        'findstr "TODO" src\\main.dart',
        'git log --format="%h %s" -n 5',
        r'dir "C:\Users\owner\Projects\app"',
      ]) {
        final d = _win(cmd);
        expect(d.denied, isFalse, reason: '$cmd -> ${d.errorCode}');
        expect(d.risk, RiskTier.r2, reason: '$cmd -> ${d.reasonCode}');
      }
    });

    test('Windows set <prefix> is Hard-Denied as env_dump; set K=V is R3', () {
      for (final dump in const <String>['set', 'set P', 'set GEMINI']) {
        final d = _win(dump);
        expect(d.denied, isTrue, reason: dump);
        expect(d.errorCode, 'exec_env_dump_forbidden', reason: dump);
      }
      final assign = _win('set FOO=bar');
      expect(assign.denied, isFalse);
      expect(assign.risk, RiskTier.r3);
      expect(assign.reasonCode, 'env_mutation');
    });
  });

  group('macOS /bin/zsh -f POSIX lexer regression (P0 ANSI-C & Hard-Deny)', () {
    test(r"ANSI-C $'...' quote-phase inversion is parsed accurately", () {
      final rm = _posix(r"echo $'\''; rm a.txt # '");
      expect(rm.denied, isFalse);
      expect(rm.risk, RiskTier.r3);
      expect(rm.reasonCode, 'destructive_command');

      final curl = _posix(r"echo $'\''; curl https://example.com # '");
      expect(curl.denied, isFalse);
      expect(curl.risk, RiskTier.r3);
      expect(curl.reasonCode, 'network_command');

      final envFile = _posix(r"echo $'\''; cat .env # '");
      expect(envFile.denied, isTrue);
      expect(envFile.errorCode, 'exec_hard_denied');
      expect(envFile.reasonCode, 'secret_file');

      final envDump = _posix(r"echo $'\''; env # '");
      expect(envDump.denied, isTrue);
      expect(envDump.errorCode, 'exec_env_dump_forbidden');

      final sudoCmd = _posix(r"echo $'\''; sudo -V # '");
      expect(sudoCmd.denied, isTrue);
      expect(sudoCmd.errorCode, 'exec_hard_denied');
      expect(sudoCmd.reasonCode, 'privilege_escalation');
    });

    test(r"ANSI-C $'...' cannot disguise secret file names", () {
      for (final cmd in const <String>[
        r"cat $'.env'",
        r"cat .e$''nv",
        r"cat $'\x2eenv'",
        r"cat $'\056env'",
      ]) {
        final d = _posix(cmd);
        expect(d.denied, isTrue, reason: '$cmd -> ${d.risk.wire}');
        expect(d.errorCode, 'exec_hard_denied', reason: cmd);
        expect(d.reasonCode, 'secret_file', reason: cmd);
      }
    });

    test(r'benign ANSI-C $' '...' ' stays R2', () {
      final d = _posix(r"echo $'hello\nworld'");
      expect(d.denied, isFalse);
      expect(d.risk, RiskTier.r2);
    });

    test(r'quote-aware $(...) and <(...) preserve Hard-Deny', () {
      final envFile = _posix('''echo "\$(echo ')'; cat .env)"''');
      expect(envFile.denied, isTrue);
      expect(envFile.errorCode, 'exec_hard_denied');

      final envDump = _posix('''echo "\$(echo ')'; env)"''');
      expect(envDump.denied, isTrue);
      expect(envDump.errorCode, 'exec_env_dump_forbidden');

      final sudoCmd = _posix('''echo "\$(echo ')'; sudo -V)"''');
      expect(sudoCmd.denied, isTrue);
      expect(sudoCmd.errorCode, 'exec_hard_denied');

      final procSub = _posix("cat <(echo ')'; env)");
      expect(procSub.denied, isTrue);
      expect(procSub.errorCode, 'exec_env_dump_forbidden');
    });

    test('escaped nested backticks inside double quotes preserve Hard-Deny',
        () {
      final envFile = _posix(r'echo "`echo \`echo x\`; cat .env`"');
      expect(envFile.denied, isTrue);
      expect(envFile.errorCode, 'exec_hard_denied');

      final envDump = _posix(r'echo "`echo \`echo x\`; env`"');
      expect(envDump.denied, isTrue);
      expect(envDump.errorCode, 'exec_env_dump_forbidden');

      final sudoCmd = _posix(r'echo "`echo \`echo x\`; sudo -V`"');
      expect(sudoCmd.denied, isTrue);
      expect(sudoCmd.errorCode, 'exec_hard_denied');
    });

    test('zsh =cmd equals expansion preserves Hard-Deny and never auto-runs R2',
        () {
      expect(_posix('=env').errorCode, 'exec_env_dump_forbidden');
      expect(_posix('=printenv').errorCode, 'exec_env_dump_forbidden');
      expect(_posix('=sudo -V').errorCode, 'exec_hard_denied');
      final eqEcho = _posix('=echo hi');
      expect(eqEcho.denied, isFalse);
      expect(eqEcho.risk, RiskTier.r3);
    });

    test(
        'secret-targeting globs are Hard-Denied or R3 without flagging normal globs',
        () {
      // Exact secret suffix/prefix globs stay Hard-Denied.
      for (final cmd in const <String>[
        'cat *.pem',
        'cat certs/*.key',
        'cat id_rsa*',
      ]) {
        final d = _posix(cmd);
        expect(d.denied, isTrue, reason: cmd);
        expect(d.errorCode, 'exec_hard_denied', reason: cmd);
      }
      // Wildcarded secret dotfile/key globs that bypass static name checks
      // elevate to R3 (`secret_glob`).
      for (final cmd in const <String>[
        'cat .en?',
        'cat .en*',
        'cat .*',
        'cat id_ed*',
      ]) {
        final d = _posix(cmd);
        expect(d.denied, isFalse, reason: cmd);
        expect(d.risk, RiskTier.r3, reason: '$cmd -> ${d.reasonCode}');
        expect(d.reasonCode, 'secret_glob', reason: cmd);
      }
      for (final ok in const <String>[
        'ls *',
        'ls src/*.dart',
        'cat tests/*.mjs',
        'grep -n TODO lib/*.dart',
      ]) {
        final d = _posix(ok);
        expect(d.denied, isFalse, reason: ok);
        expect(d.risk, RiskTier.r2, reason: '$ok -> ${d.reasonCode}');
      }
    });
  });
}

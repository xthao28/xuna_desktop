import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Upgrade plan P1.1 (U3): `exec.run` `expectFiles` parsing, decision and
/// argument validation (paths through `FsPathGuard`).
void main() {
  group('ExpectedFileSpec.parseList', () {
    test('accepts the contract keys and normalizes hex', () {
      final specs = ExpectedFileSpec.parseList([
        {
          'path': '/w/out.pdf',
          'minBytes': 0,
          'magic': '25504446',
          'sha256': 'A' * 64,
        },
        {'path': '~/b.txt'},
      ])!;
      expect(specs, hasLength(2));
      expect(specs[0].magic, [0x25, 0x50, 0x44, 0x46]);
      expect(specs[0].sha256, 'a' * 64);
      expect(specs[1].minBytes, isNull);
    });

    test('rejects every malformed shape', () {
      final bad = <Object?>[
        null,
        'x',
        <Object?>[],
        List<Object?>.filled(17, {'path': '/a'}),
        [
          {'minBytes': 1},
        ],
        [
          {'path': ''},
        ],
        [
          {'path': '/a', 'extra': true},
        ],
        [
          {'path': '/a', 'minBytes': -1},
        ],
        [
          {'path': '/a', 'minBytes': '3'},
        ],
        [
          {'path': '/a', 'magic': '255'},
        ],
        [
          {'path': '/a', 'magic': '00' * 17},
        ],
        [
          {'path': '/a', 'sha256': 'z' * 64},
        ],
        [
          {'path': '/a\x00b'},
        ],
      ];
      for (final raw in bad) {
        expect(ExpectedFileSpec.parseList(raw), isNull, reason: '$raw');
      }
    });
  });

  group('evaluateExpectedFiles', () {
    const spec = ExpectedFileSpec(path: '/w/a');

    test('all matching → no error code, artifact facts', () {
      final r = evaluateExpectedFiles(
        [
          const ExpectedFileSpec(path: '/w/a', minBytes: 3, magic: [1, 2]),
        ],
        [
          const ObservedExpectedFile.file(
            sizeBytes: 3,
            header: [1, 2, 3],
            sha256: 'f00d',
          ),
        ],
      );
      expect(r.ok, isTrue);
      expect(r.errorCode, isNull);
      expect(r.artifacts.single, {
        'path': '/w/a',
        'exists': true,
        'sizeBytes': 3,
        'sha256': 'f00d',
        'magicOk': true,
      });
    });

    test('missing wins over mismatch in the error code', () {
      final r = evaluateExpectedFiles(
        [
          ExpectedFileSpec(path: '/w/a', sha256: 'b' * 64),
          spec,
        ],
        [
          const ObservedExpectedFile.file(
            sizeBytes: 1,
            header: [0],
            sha256: 'a',
          ),
          const ObservedExpectedFile.missing(),
        ],
      );
      expect(r.errorCode, expectedOutputMissing);
      expect(r.artifacts.map((a) => a['problem']), [
        'sha256_mismatch',
        'missing',
      ]);
    });

    test('each problem maps to its code', () {
      ExpectedFileProblem? problem(
        ExpectedFileSpec s,
        ObservedExpectedFile o,
      ) =>
          evaluateExpectedFiles([s], [o]).checks.single.problem;
      expect(problem(spec, const ObservedExpectedFile.notAFile()),
          ExpectedFileProblem.notAFile);
      expect(
        problem(
          const ExpectedFileSpec(path: '/w/a', minBytes: 10),
          const ObservedExpectedFile.file(
              sizeBytes: 9, header: [], sha256: 'x'),
        ),
        ExpectedFileProblem.tooSmall,
      );
      expect(
        problem(
          ExpectedFileSpec(path: '/w/a', sha256: 'c' * 64),
          const ObservedExpectedFile.file(
              sizeBytes: 9, header: [], sha256: null),
        ),
        ExpectedFileProblem.tooLargeToHash,
      );
      expect(
        problem(
          const ExpectedFileSpec(path: '/w/a', magic: [7]),
          const ObservedExpectedFile.unreadable(sizeBytes: 4),
        ),
        ExpectedFileProblem.unreadable,
      );
      expect(
        problem(spec, const ObservedExpectedFile.unreadable(sizeBytes: 4)),
        isNull,
        reason: 'existence alone was asked and the file exists',
      );
      expect(problem(spec, const ObservedExpectedFile.forbidden()),
          ExpectedFileProblem.forbidden);
      expect(ExpectedFileProblem.tooSmall.errorCode, expectedOutputMissing);
      expect(ExpectedFileProblem.forbidden.errorCode, expectedOutputMismatch);
    });

    test('a forbidden target reveals no size, hash or magic', () {
      final r = evaluateExpectedFiles(
        [
          const ExpectedFileSpec(path: '/w/a', magic: [1]),
        ],
        [const ObservedExpectedFile.forbidden()],
      );
      expect(r.artifacts.single, {
        'path': '/w/a',
        'exists': true,
        'problem': 'forbidden',
      });
    });
  });

  group('validateExecFsArguments exec.run expectFiles', () {
    final policy = HostPolicy(
      trustPreset: TrustPreset.standard,
      families: const <ToolFamily, FamilyPolicyDecision>{},
      apps: const <AllowedAppConfig>[],
      urlDomains: const <String>[],
      workflows: const <WorkflowConfig>[],
      players: const <String>[],
      shellControl: ShellControlPolicy(
        enabled: true,
        workspaceRoots: const <String>['/Users/o/ws'],
      ),
    );
    const ctx = ExecFsHostContext(homeDirectory: '/Users/o');

    PolicyEvaluationResult run(Object? expectFiles) => validateExecFsArguments(
          toolName: 'exec.run',
          arguments: <String, Object?>{
            'command': 'npm test',
            'cwd': '/Users/o/ws',
            'expectFiles': expectFiles,
          },
          activePolicy: policy,
          context: ctx,
        );

    test('valid paths keep the command risk', () {
      final r = run([
        {'path': '/Users/o/ws/dist/app.zip', 'magic': '504b0304'},
        {'path': '~/ws/out.txt'},
      ]);
      expect(r.allowed, isTrue);
      expect(r.effectiveRisk, RiskTier.r2);
    });

    test('relative, secret, Hard-Deny and malformed entries are refused', () {
      final relative = run([
        {'path': 'out.txt'},
      ]);
      expect(relative.status, XtpStatus.invalidArgs);
      expect(relative.errorCode, 'path_not_absolute');
      final secret = run([
        {'path': '/Users/o/ws/.env'},
      ]);
      expect(secret.status, XtpStatus.denied);
      expect(secret.errorCode, 'fs_secret_file_forbidden');
      final ssh = run([
        {'path': '~/.ssh/id_ed25519.pub'},
      ]);
      expect(ssh.status, XtpStatus.denied);
      expect(ssh.errorCode, 'fs_path_forbidden');
      final malformed = run('not a list');
      expect(malformed.status, XtpStatus.invalidArgs);
      expect(malformed.errorCode, 'schema_mismatch');
    });
  });
}

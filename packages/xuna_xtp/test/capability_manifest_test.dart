import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

CapabilityManifest _sampleManifest({
  String binary = 'toolbin',
  List<String> argvTemplate = const <String>[
    '--mode',
    '{mode}',
    '--in',
    '{inputPath}',
    '--out',
    '{outputPath}',
  ],
  RiskTier risk = RiskTier.r2,
  bool approved = true,
  String? pinnedHash,
}) {
  final base = CapabilityManifest(
    id: 'sample_convert',
    capability: 'document.convert',
    description: 'Convert a workspace file into target format.',
    fromFormats: const <String>['txt'],
    toFormats: const <String>['pdf'],
    risk: risk,
    inputs: <CapabilityInputSpec>[
      CapabilityInputSpec(
        name: 'mode',
        type: CapabilityInputType.enumValue,
        enumValues: const <String>['fast', 'high'],
      ),
      CapabilityInputSpec(
        name: 'inputPath',
        type: CapabilityInputType.path,
        allowedExtensions: const <String>['txt'],
      ),
      CapabilityInputSpec(
        name: 'outputPath',
        type: CapabilityInputType.path,
        isOutputPath: true,
      ),
      CapabilityInputSpec(
        name: 'label',
        type: CapabilityInputType.string,
        required: false,
        maxLength: 64,
      ),
    ],
    detect: CapabilityDetectSpec(
      binary: binary,
      versionArgs: const <String>['--version'],
      remediationSummary: 'Install the external conversion binary.',
    ),
    invoke: CapabilityInvokeSpec(argvTemplate: argvTemplate),
    verifyFiles: <CapabilityVerifyFileSpec>[
      CapabilityVerifyFileSpec(
        pathTemplate: '{outputPath}',
        minBytes: 4,
        magic: '25504446',
      ),
    ],
    provenance: CapabilityProvenance(
      kind: CapabilityProvenanceKind.seed,
      approved: approved,
    ),
  );
  return base.withProvenance(
    base.provenance.copyWith(
      manifestSha256: pinnedHash ?? base.computeContentSha256(),
    ),
  );
}

void main() {
  group('ADR-0021 / P4.1 CapabilityManifest strict fail-closed validation', () {
    test('rejects shell binaries, inline eval flags, metacharacters, and untyped placeholders', () {
      for (final shellBin in const <String>[
        'cmd',
        'cmd.exe',
        'powershell',
        'pwsh',
        'bash',
        'sh',
        'zsh',
        'osascript',
        'sudo',
      ]) {
        expect(
          () => _sampleManifest(binary: shellBin),
          throwsFormatException,
          reason: 'Must reject shell/privileged binary $shellBin',
        );
      }

      for (final badArgv in const <List<String>>[
        <String>['-c', '{inputPath}'],
        <String>['--eval', '{inputPath}'],
        <String>['/c', '{inputPath}'],
        <String>['-EncodedCommand', '{inputPath}'],
        <String>['--in', '{inputPath};rm -rf /'],
        <String>['--in', '{inputPath}&whoami'],
        <String>['--in', '{undeclaredVar}'],
        <String>['--in', '{{nested}}'],
        <String>['--in', '{unclosed'],
      ]) {
        expect(
          () => _sampleManifest(argvTemplate: badArgv),
          throwsFormatException,
          reason: 'Must reject unsafe argvTemplate $badArgv',
        );
      }
    });

    test('content SHA-256 detects manifest tampering fail-closed', () {
      final manifest = _sampleManifest();
      expect(manifest.hasValidManifestPin, isTrue);

      final tampered = CapabilityManifest.fromJson(<String, Object?>{
        ...manifest.toJson(),
        'description': 'Silently modified description',
      });
      expect(tampered.hasValidManifestPin, isFalse);
    });

    test('compileCapabilityInvocation keeps metacharacters trapped in literal argv and guards paths', () {
      final manifest = _sampleManifest(
        argvTemplate: const <String>[
          '--mode',
          '{mode}',
          '--label',
          '{label}',
          '--in',
          '{inputPath}',
          '--out',
          '{outputPath}',
        ],
      );
      final shell = ShellControlPolicy(
        enabled: true,
        workspaceRoots: const <String>['/workspace'],
      );

      // Shell injection characters in a typed string input stay trapped inside
      // one single argv element (never split, never executed in a shell).
      final compiled = compileCapabilityInvocation(
        manifest: manifest,
        rawInputs: const <String, Object?>{
          'mode': 'fast',
          'label': 'report; rm -rf / & echo pwned',
          'inputPath': '/workspace/notes.txt',
          'outputPath': '/workspace/out.pdf',
        },
        shellControl: shell,
      );
      expect(compiled.allowed, isTrue);
      expect(compiled.effectiveRisk, equals(RiskTier.r2));
      expect(compiled.argv, hasLength(8));
      expect(compiled.argv[3], equals('report; rm -rf / & echo pwned'));
      expect(compiled.expectedFiles, hasLength(1));
      expect(compiled.expectedFiles.first.magic, equals(<int>[0x25, 0x50, 0x44, 0x46]));

      // Writing outside workspace elevates risk to R3!
      final outsideOut = compileCapabilityInvocation(
        manifest: manifest,
        rawInputs: const <String, Object?>{
          'mode': 'fast',
          'label': 'ok',
          'inputPath': '/workspace/notes.txt',
          'outputPath': '/tmp/outside.pdf',
        },
        shellControl: shell,
      );
      expect(outsideOut.allowed, isTrue);
      expect(outsideOut.effectiveRisk, equals(RiskTier.r3));

      // Secret file input is refused fail-closed by FsPathGuard!
      final secretIn = compileCapabilityInvocation(
        manifest: manifest,
        rawInputs: const <String, Object?>{
          'mode': 'fast',
          'label': 'ok',
          'inputPath': '/workspace/.env',
          'outputPath': '/workspace/out.pdf',
        },
        shellControl: shell,
      );
      expect(secretIn.allowed, isFalse);

      // Undeclared extra input fails closed!
      final extraInput = compileCapabilityInvocation(
        manifest: manifest,
        rawInputs: const <String, Object?>{
          'mode': 'fast',
          'label': 'ok',
          'inputPath': '/workspace/notes.txt',
          'outputPath': '/workspace/out.pdf',
          'injected': '1',
        },
        shellControl: shell,
      );
      expect(extraInput.allowed, isFalse);
      expect(extraInput.errorCode, equals('schema_mismatch'));
    });

    test('toolsListCapabilityResponse matches buildCapabilityTools and frames round-trip', () {
      final doc = jsonDecode(
        File('test/fixtures/xtp/exec_fs_frames.json').readAsStringSync(),
      ) as Map<String, Object?>;
      final frames = doc['frames']! as Map<String, Object?>;
      final tools = ((frames['toolsListCapabilityResponse']! as Map)['result']
          as Map)['tools'] as List<Object?>;
      expect(
        tools,
        equals(
          jsonDecode(
            jsonEncode([
              for (final t in buildCapabilityTools(shellEnabled: true))
                t.toJson(),
            ]),
          ),
        ),
      );
      for (final key in const <String>[
        'toolsListCapabilityResponse',
        'preflightCapabilityRunResponse',
        'toolsCallCapabilityRunCompletedResponse',
      ]) {
        final raw = frames[key]! as Map<String, Object?>;
        final parsed = XtpFrame.parse(jsonEncode(raw));
        expect(jsonDecode(parsed.encode()), equals(raw), reason: key);
      }
    });
  });
}

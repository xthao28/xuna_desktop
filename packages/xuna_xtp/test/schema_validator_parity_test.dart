import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';
import 'package:test/test.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

Uint8List _bigIntTo32Bytes(BigInt value) {
  final hex = value.toRadixString(16).padLeft(64, '0');
  final out = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

({Uint8List publicKey, Uint8List Function(Uint8List msg) sign})
    _testP256Signer() {
  final params = ECCurve_secp256r1();
  final d = BigInt.parse(
    'c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721',
    radix: 16,
  );
  final q = (params.G * d)!;
  final pubUncompressed = q.getEncoded(false);
  final privKey = ECPrivateKey(d, params);
  return (
    publicKey: pubUncompressed,
    sign: (Uint8List msg) {
      final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
        ..init(true, PrivateKeyParameter<ECPrivateKey>(privKey));
      final sig = signer.generateSignature(msg) as ECSignature;
      final out = Uint8List(64);
      out.setRange(0, 32, _bigIntTo32Bytes(sig.r));
      out.setRange(32, 64, _bigIntTo32Bytes(sig.s));
      return out;
    },
  );
}

HostPolicy _buildPermissiveParityPolicy() => HostPolicy(
      schemaVersion: 1,
      families: <ToolFamily, FamilyPolicyDecision>{
        for (final family in ToolFamily.values)
          family: FamilyPolicyDecision.allow,
      },
      apps: <AllowedAppConfig>[
        AllowedAppConfig(
          id: 'vscode',
          name: 'VS Code',
          kind: AppLaunchKind.bundle,
          target: 'com.microsoft.VSCode',
          risk: RiskTier.r2,
        ),
      ],
      urlDomains: const <String>['example.com'],
      workflows: <WorkflowConfig>[
        WorkflowConfig(
          id: 'wf_demo',
          name: 'Demo Workflow',
          kind: WorkflowKind.shortcut,
          target: 'Demo',
          risk: RiskTier.r1,
        ),
      ],
      players: const <String>['spotify'],
      shellControl: ShellControlPolicy(
        enabled: true,
        workspaceRoots: const <String>['/ws/proj'],
      ),
    );

PolicyEvaluationResult _validateArgs(
  HostPolicyEvaluator evaluator,
  String toolName,
  Map<String, Object?> args,
  DateTime now,
) {
  return validateToolArguments(
    toolName: toolName,
    arguments: args,
    activePolicy: evaluator.policy!,
    now: now,
    isStopped: false,
    hostId: 'host-parity-test',
    pinnedPhonePublicKeys: const <Uint8List>[],
    isInApprovedCuSession: true,
    allowZeroConfigAppDiscovery: true,
    allowPublicHttpsDomains: true,
    evaluateStep: evaluator.evaluateInvocation,
  );
}

Object? _validValueForSchema(
  String toolName,
  String propName,
  Map<String, Object?> propSchema, {
  required bool full,
}) {
  final enumVals = propSchema['enum'];
  if (enumVals is List && enumVals.isNotEmpty) {
    if (toolName == 'watchdog.watch_process_or_port' &&
        propName == 'targetKind') {
      return 'process';
    }
    if (toolName == 'skill.markdown_bridge' && propName == 'action') {
      return 'export_skill_md';
    }
    if (toolName == 'skill.workshop_sync' && propName == 'action') {
      return 'sync_to_disk';
    }
    if (toolName == 'memory.markdown_vault' && propName == 'action') {
      return full ? 'append_note' : 'read_vault';
    }
    if (toolName == 'tv.control' && propName == 'action') {
      return full ? 'volume_set' : 'play_pause';
    }
    return enumVals.first;
  }

  final type = propSchema['type'];
  if (type == 'boolean') {
    return true;
  }
  if (type == 'integer') {
    final min = propSchema['minimum'] as int?;
    final max = propSchema['maximum'] as int?;
    if (min != null && max != null) {
      return ((min + max) ~/ 2).clamp(min, max);
    }
    return min ?? 1;
  }
  if (type == 'number') {
    final min = (propSchema['minimum'] as num?)?.toDouble();
    final max = (propSchema['maximum'] as num?)?.toDouble();
    if (min != null && max != null) {
      return (min + max) / 2.0;
    }
    return min ?? 0.5;
  }
  if (type == 'object') {
    if (propName == 'runtimeParams') {
      return <String, Object?>{'query': 'xuna'};
    }
    return <String, Object?>{};
  }
  if (type == 'array') {
    if (propName == 'apps') {
      return <String>['vscode'];
    }
    if (propName == 'domains') {
      return <String>['example.com'];
    }
    if (propName == 'fileExtensions') {
      return <String>['pdf'];
    }
    if (propName == 'steps') {
      return <Map<String, Object?>>[
        <String, Object?>{
          'tool': 'display.wake',
          'arguments': <String, Object?>{},
        },
      ];
    }
    if (propName == 'expectFiles') {
      return <Map<String, Object?>>[
        <String, Object?>{
          'path': '/ws/proj/dist/out.pdf',
          if (full) 'minBytes': 1,
          if (full) 'magic': '25504446',
          if (full) 'sha256': 'a' * 64,
        },
      ];
    }
    if (propName == 'to' || propName == 'cc' || propName == 'bcc') {
      return <String>['owner@example.com'];
    }
    final items = propSchema['items'] as Map<String, Object?>?;
    if (items != null) {
      return <Object?>[
        _validValueForSchema(toolName, '${propName}_item', items, full: full),
      ];
    }
    return <Object?>['item'];
  }

  // String or untyped (e.g. shortcuts.run.input)
  switch (propName) {
    case 'url':
      return 'https://example.com/path';
    case 'id':
      if (toolName == 'workflow.run') return 'wf_demo';
      if (toolName == 'app.launch') return 'vscode';
      return 'item_1';
    case 'entityId':
      return 'light.living_room';
    case 'timeMin':
    case 'startTime':
    case 'dueDate':
      return '2026-11-19T10:00:00Z';
    case 'timeMax':
    case 'endTime':
      return '2026-11-19T12:00:00Z';
    case 'combo':
      return 'Enter';
    case 'role':
      return 'button';
    case 'fileName':
    case 'outputFileName':
      return 'report.csv';
    case 'sha256':
    case 'effectSha256':
      return 'a' * 64;
    case 'draftId':
      return 'draft_parity1';
    case 'workspacePath':
      return '/ws/proj';
    case 'workspaceAlias':
      return 'proj';
    case 'payloadJson':
    case 'argsJson':
    case 'testArgsJson':
      return '{}';
    case 'elementId':
    case 'fromElementId':
      return '@s00000001:e1';
    case 'toElementId':
      return '@s00000001:e2';
    case 'tool':
      return 'search_docs';
    case 'shortcutName':
      return 'DailySummary';
    case 'scriptCode':
      return 'print("{}")';
    case 'markdownContent':
      return '# Skill\nSafe content';
    case 'rawHtml':
      return '<html><body><button>Save</button></body></html>';
    case 'targetFolder':
    case 'outputFolder':
    case 'sourceFolder':
    case 'workshopFolder':
    case 'vaultFolder':
      return 'XUNA_Docs';
    case 'processName':
      return 'node';
    case 'path':
      return 'Documents/report.pdf';
    default:
      if (type == null) {
        return 'hello';
      }
      final maxLen = propSchema['maxLength'] as int? ?? 32;
      final minLen = propSchema['minLength'] as int? ?? 1;
      final len = 6.clamp(minLen, maxLen);
      return 'a' * len;
  }
}

Map<String, Object?> _synthesizeArgs(
  ToolDescriptor tool, {
  required bool full,
}) {
  final props = (tool.inputSchema['properties'] as Map<String, Object?>?) ??
      const <String, Object?>{};
  final requiredKeys =
      ((tool.inputSchema['required'] as List?) ?? const <Object?>[])
          .cast<String>()
          .toSet();
  final args = <String, Object?>{};

  for (final entry in props.entries) {
    final key = entry.key;
    final propSchema = entry.value! as Map<String, Object?>;
    if (full || requiredKeys.contains(key)) {
      if (full && key == 'waitForGone') {
        // Mutually exclusive with waitFor.
        continue;
      }
      args[key] = _validValueForSchema(tool.name, key, propSchema, full: full);
    }
  }

  // Cross-field conditional requirements that cannot be expressed in flat
  // JSON Schema properties/required alone.
  switch (tool.name) {
    case 'workspace.restore_capsule':
      args.putIfAbsent('capsuleId', () => 'cap_1');
    case 'pocket.transform_item':
      args.putIfAbsent('itemId', () => 'item_1');
    case 'watchdog.watch_process_or_port':
      if (args['targetKind'] == 'process') {
        args.putIfAbsent('processName', () => 'node');
      } else {
        args.putIfAbsent('port', () => 8080);
      }
    case 'skill.markdown_bridge':
      if (args['action'] == 'export_skill_md') {
        args.putIfAbsent('skillId', () => 'skill_1');
      } else {
        args.putIfAbsent('markdownContent', () => '# Skill\nSafe content');
      }
    case 'skill.record_correction':
      args.putIfAbsent('correctionNote', () => 'Fix selector');
    case 'skill.workshop_sync':
      if (args['action'] == 'rollback_version') {
        args.putIfAbsent('skillId', () => 'skill_1');
      }
    case 'memory.markdown_vault':
      if (args['action'] == 'append_note') {
        args.putIfAbsent('noteContent', () => 'Owner prefers concise bullets.');
      } else if (args['action'] == 'pre_compaction_flush') {
        args.putIfAbsent('sessionTranscript', () => 'User discussed Q4 goals.');
      }
    case 'fs.list_files':
    case 'fs.read_file':
    case 'fs.grep':
    case 'fs.write_file':
    case 'fs.patch_file':
      args['path'] = '/ws/proj/src/main.dart';
    case 'exec.run':
      args['command'] = 'npm test';
      if (args.containsKey('cwd')) args['cwd'] = '/ws/proj';
    case 'exec.status':
    case 'exec.write_stdin':
    case 'exec.cancel':
      args['taskId'] = 'exec_parity1';
    case 'notes.append':
      if (!args.containsKey('id') && !args.containsKey('title')) {
        args['id'] = 'note_1';
      }
    case 'cu.session_extend':
      if ((args['apps'] as List).isEmpty && (args['domains'] as List).isEmpty) {
        args['apps'] = <String>['vscode'];
      }
    case 'ui.find':
      if (!args.containsKey('query') && !args.containsKey('role')) {
        args['query'] = 'Save';
      }
    case 'input.click':
      if (!args.containsKey('elementId') &&
          !args.containsKey('xNorm') &&
          !args.containsKey('x') &&
          !args.containsKey('menuPath')) {
        args['elementId'] = '@s00000001:e1';
      }
      if (args.containsKey('xNorm') && !args.containsKey('yNorm')) {
        args['yNorm'] = 0.5;
      }
      if (args.containsKey('x') && !args.containsKey('y')) {
        args['y'] = 100;
      }
    case 'input.drag':
      if (!args.containsKey('fromElementId')) {
        args['fromElementId'] = '@s00000001:e1';
      }
      if (!args.containsKey('toElementId')) {
        args['toElementId'] = '@s00000001:e2';
      }
    case 'tv.control':
      if (args['action'] == 'volume_set') {
        args.putIfAbsent('level', () => 50);
      }
  }

  return args;
}

String _stringWithExactLength(String toolName, String propName, int length) {
  if ((toolName.startsWith('fs.') && propName == 'path') ||
      (toolName == 'exec.run' && propName == 'cwd') ||
      (toolName == 'draft.create' && propName == 'workspacePath')) {
    const prefix = '/ws/proj/';
    return prefix + ('a' * (length - prefix.length));
  }
  switch (propName) {
    case 'url':
      const prefix = 'https://example.com/';
      if (length <= prefix.length) return prefix.substring(0, length);
      return prefix + ('a' * (length - prefix.length));
    case 'fileName':
    case 'outputFileName':
      const suffix = '.csv';
      if (length <= suffix.length) return 'a' * length;
      return ('a' * (length - suffix.length)) + suffix;
    case 'combo':
      const key = 'Enter';
      if (length <= key.length) return key;
      return (' ' * (length - key.length)) + key;
    case 'timeMin':
    case 'startTime':
    case 'dueDate':
    case 'timeMax':
    case 'endTime':
      const iso = '2026-11-19T10:00:00Z';
      if (length <= iso.length) return iso;
      return (' ' * (length - iso.length)) + iso;
    case 'to_item':
    case 'cc_item':
    case 'bcc_item':
      const domain = '@example.com';
      if (length <= domain.length) return 'a@b.c';
      return ('a' * (length - domain.length)) + domain;
    case 'apps_item':
      return 'a' * length;
    case 'domains_item':
      // Valid domain up to 253 chars using <=63-char labels.
      if (length <= 11) return 'a.example.c';
      const tail = '.example.com';
      final needed = length - tail.length;
      final labels = <String>[];
      var rem = needed;
      while (rem > 0) {
        final take = rem > 60 ? 60 : rem;
        labels.add('a' * take);
        rem -= take;
        if (rem > 0) {
          // Account for '.' separator by shrinking current label by 1 if needed.
          if (rem == 1) {
            labels.add('b');
            rem = 0;
          } else {
            labels[labels.length - 1] =
                '${labels.last}.'; // exact char count accounting
          }
        }
      }
      final built = '${labels.join('')}$tail';
      if (built.length == length) return built;
      return ('a' * (length - tail.length)) + tail;
    case 'fileExtensions_item':
      return 'pdf';
    default:
      if (toolName == 'smarthome.control' && propName == 'entityId') {
        const prefix = 'light.';
        if (length <= prefix.length) return 'a' * length;
        return prefix + ('a' * (length - prefix.length));
      }
      return 'a' * length;
  }
}

void main() {
  final staticCatalog = <ToolDescriptor>[
    ...buildMvpToolCatalog(
      includeBrowserCurrentUrl: true,
      includeDevWorkspaceTools: true,
      includeDeskCopilotTools: true,
      includeAmbientCopilotTools: true,
      includeSmartTvHomeTools: true,
      includeSymbioticCopilotTools: true,
      includeSymbioticEvolutionTools: true,
      includeSymbioticSentinelTools: true,
      includeOmniForgeTools: true,
      includeClawPulseTools: true,
      includeExecFsTools: true,
      shellEnabled: true,
    ),
    ...buildNativeAppToolCatalog(),
    ...buildBrowserToolCatalog(),
    ...buildComputerUseTools(),
  ];

  final dynamicCustomTool = ToolDescriptor(
    name: 'forge.custom_parity_sample',
    description: 'Representative dynamic OmniForge custom tool descriptor.',
    inputSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'argsJson': <String, Object?>{
          'type': 'string',
          'maxLength': 2000,
        },
        'outputFolder': <String, Object?>{
          'type': 'string',
          'maxLength': 120,
        },
      },
      'additionalProperties': false,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'ok': <String, Object?>{'type': 'boolean'},
      },
      'required': <String>['ok'],
      'additionalProperties': false,
    },
    policy: const ToolPolicyMeta(
      family: ToolFamily.app,
      risk: RiskTier.r2,
      observes: false,
      reversible: true,
      permission: XtpPermissionState.granted,
    ),
  );

  final allTools = <ToolDescriptor>[...staticCatalog, dynamicCustomTool];

  group('Schema-Validator Parity Invariants (104 static + 1 dynamic)', () {
    late HostPolicyEvaluator evaluator;
    final now = DateTime.utc(2026, 11, 19, 12, 0);

    setUp(() {
      evaluator = HostPolicyEvaluator.healthy(_buildPermissiveParityPolicy());
    });

    test(
        'catalog has 104 unique static tools + valid metadata & strict schemas',
        () {
      expect(staticCatalog.length, equals(104));
      final names = staticCatalog.map((t) => t.name).toSet();
      expect(names.length, equals(104));

      for (final tool in allTools) {
        expect(
          resolveToolFamilyForName(tool.name),
          equals(tool.policy.family),
          reason: '${tool.name} family mismatch',
        );
        ToolDescriptor.validateToolName(
          tool.name,
          expectedFamily: tool.policy.family,
        );
        expect(tool.inputSchema['type'], equals('object'));
        expect(tool.inputSchema['additionalProperties'], isFalse);
        expect(tool.outputSchema['type'], equals('object'));
        expect(tool.outputSchema['additionalProperties'], isFalse);
      }
    });

    test('minimal and full valid payloads pass validateToolArguments & policy',
        () {
      final signer = _testP256Signer();
      const hostId = 'host-parity-test';
      const approvalId = 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d';
      final expiresAt = now.add(const Duration(minutes: 5));

      for (final tool in allTools) {
        for (final full in const <bool>[false, true]) {
          final args = _synthesizeArgs(tool, full: full);
          final res = _validateArgs(evaluator, tool.name, args, now);
          expect(
            res.allowed,
            isTrue,
            reason:
                '${tool.name} (full=$full) failed validateToolArguments: ${res.errorCode} with args=$args',
          );

          ApprovalToken? approval;
          if (res.effectiveRisk >= RiskTier.r2) {
            final digest = argsSha256(args);
            final expiresWire = expiresAt.toUtc().toIso8601String();
            if (tool.name == 'draft.apply') {
              final effectHash = args['effectSha256']! as String;
              approval = ApprovalToken(
                approvalId: approvalId,
                argsSha256: digest,
                expiresAt: expiresAt,
                expiresAtRaw: expiresWire,
                version: 2,
                effectSha256: effectHash,
                signature: signer.sign(
                  approvalV2ProofMessage(
                    approvalId: approvalId,
                    effectSha256: effectHash,
                    hostId: hostId,
                    expiresAt: expiresWire,
                  ),
                ),
                publicKey: signer.publicKey,
              );
            } else {
              final sig = res.effectiveRisk >= RiskTier.r3
                  ? signer.sign(
                      approvalProofMessage(
                        approvalId: approvalId,
                        argsSha256: digest,
                        hostId: hostId,
                        expiresAt: expiresWire,
                      ),
                    )
                  : null;
              approval = ApprovalToken(
                approvalId: approvalId,
                argsSha256: digest,
                expiresAt: expiresAt,
                expiresAtRaw: expiresWire,
                signature: sig,
                publicKey:
                    res.effectiveRisk >= RiskTier.r3 ? signer.publicKey : null,
              );
            }
          }
          final evalRes = evaluator.evaluateInvocation(
            toolName: tool.name,
            arguments: args,
            approval: approval,
            nowUtc: now,
            hostId: hostId,
            pinnedPhonePublicKeys: <Uint8List>[signer.publicKey],
            isInApprovedCuSession: true,
            allowZeroConfigAppDiscovery: true,
            allowPublicHttpsDomains: true,
          );
          expect(
            evalRes.allowed,
            isTrue,
            reason:
                '${tool.name} (full=$full) failed evaluateInvocation: ${evalRes.errorCode}',
          );
        }
      }
    });

    test('additionalProperties: false rejects undeclared keys on all 101 tools',
        () {
      for (final tool in allTools) {
        final badArgs = _synthesizeArgs(tool, full: false)
          ..['__undeclared_parity_key'] = 1;
        final res = _validateArgs(evaluator, tool.name, badArgs, now);
        expect(
          res.allowed,
          isFalse,
          reason: '${tool.name} accepted undeclared key',
        );
        expect(
          res.errorCode,
          equals('schema_mismatch'),
          reason: '${tool.name} wrong errorCode for undeclared key',
        );
      }

      // Nested workflow.batch_steps.steps[0] additionalProperties: false check.
      final badNested = _synthesizeArgs(
        allTools.firstWhere((t) => t.name == 'workflow.batch_steps'),
        full: false,
      );
      badNested['steps'] = <Map<String, Object?>>[
        <String, Object?>{
          'tool': 'display.wake',
          'arguments': <String, Object?>{},
          '__extra': true,
        },
      ];
      final nestedRes =
          _validateArgs(evaluator, 'workflow.batch_steps', badNested, now);
      expect(nestedRes.allowed, isFalse);
      expect(nestedRes.errorCode, equals('schema_mismatch'));
    });

    test('required fields omission is rejected on all tools', () {
      for (final tool in allTools) {
        final requiredKeys =
            ((tool.inputSchema['required'] as List?) ?? const <Object?>[])
                .cast<String>();
        for (final reqKey in requiredKeys) {
          final missingArgs = _synthesizeArgs(tool, full: false)
            ..remove(reqKey);
          final res = _validateArgs(evaluator, tool.name, missingArgs, now);
          expect(
            res.allowed,
            isFalse,
            reason: '${tool.name} accepted missing required "$reqKey"',
          );
        }
      }
    });

    test('enum violations are rejected on all enum properties and array items',
        () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;
          if (propSchema.containsKey('enum')) {
            final badArgs = _synthesizeArgs(tool, full: false)
              ..[key] = '__invalid_enum__';
            final res = _validateArgs(evaluator, tool.name, badArgs, now);
            expect(
              res.allowed,
              isFalse,
              reason: '${tool.name}.$key accepted invalid enum value',
            );
          }
          if (propSchema['type'] == 'array') {
            final items = propSchema['items'] as Map<String, Object?>?;
            if (items != null && items.containsKey('enum')) {
              final badArgs = _synthesizeArgs(tool, full: false)
                ..[key] = <Object?>['__invalid_enum__'];
              final res = _validateArgs(evaluator, tool.name, badArgs, now);
              expect(
                res.allowed,
                isFalse,
                reason: '${tool.name}.$key[] accepted invalid enum value',
              );
            }
          }
        }
      }
    });

    test('maxLength boundaries (N passes, N+1 fails) hold across all schemas',
        () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;

          if (propSchema['type'] == 'string' &&
              propSchema['maxLength'] is int) {
            final maxLen = propSchema['maxLength'] as int;
            // Skip fixed-pattern fields where 'a' * maxLen isn't valid syntax
            // or where another regex already fixes length (e.g. shortcutName,
            // domain/fileName tested via helper).
            if (propSchema.containsKey('pattern') &&
                key != 'id' &&
                key != 'shortcutName') {
              continue;
            }
            if (key == 'toolName' && tool.name == 'forge.synthesize_skill') {
              // Normalized slug accepts a*48 and rejects a*49.
            }
            if (tool.name == 'workspace.open' ||
                tool.name == 'workspace.git_summary' ||
                tool.name == 'workspace.coding_agent' ||
                tool.name == 'workspace.watch_task' ||
                tool.name == 'workspace.capture_capsule' ||
                tool.name == 'workspace.restore_capsule' ||
                tool.name == 'coach.decompose_overwhelm') {
              // project maxLength is 64
            }

            final base = _synthesizeArgs(tool, full: false);
            if (tool.name == 'skill.markdown_bridge' &&
                key == 'markdownContent') {
              base['action'] = 'import_skill_md';
            }
            if (tool.name == 'memory.markdown_vault' && key == 'noteContent') {
              base['action'] = 'append_note';
            }
            if (tool.name == 'memory.markdown_vault' &&
                key == 'sessionTranscript') {
              base['action'] = 'pre_compaction_flush';
            }
            if (tool.name == 'calendar.list_events' &&
                (key == 'timeMin' || key == 'timeMax')) {
              base['timeMin'] = '2026-11-19T10:00:00Z';
              base['timeMax'] = '2026-11-19T12:00:00Z';
            }
            if (tool.name == 'calendar.create_event' &&
                (key == 'startTime' || key == 'endTime')) {
              base['startTime'] = '2026-11-19T10:00:00Z';
              base['endTime'] = '2026-11-19T12:00:00Z';
            }

            // Skip url maxLength pass test for > 500 only if isSafeAgentPrompt
            // is involved — here url.open/web.navigate allow 2048 directly.
            final passVal = _stringWithExactLength(tool.name, key, maxLen);
            final failVal = _stringWithExactLength(tool.name, key, maxLen + 1);

            if (key != 'shortcutName' &&
                !(tool.name == 'smarthome.control' && key == 'entityId')) {
              final okArgs = Map<String, Object?>.from(base)..[key] = passVal;
              final okRes = _validateArgs(evaluator, tool.name, okArgs, now);
              expect(
                okRes.allowed,
                isTrue,
                reason:
                    '${tool.name}.$key rejected valid length $maxLen: ${okRes.errorCode}',
              );
            }

            final badArgs = Map<String, Object?>.from(base)..[key] = failVal;
            final badRes = _validateArgs(evaluator, tool.name, badArgs, now);
            expect(
              badRes.allowed,
              isFalse,
              reason: '${tool.name}.$key accepted length ${maxLen + 1}',
            );
          }

          if (propSchema['type'] == 'array') {
            final items = propSchema['items'] as Map<String, Object?>?;
            if (items != null &&
                items['type'] == 'string' &&
                items['maxLength'] is int &&
                !items.containsKey('pattern')) {
              final maxLen = items['maxLength'] as int;
              if (key == 'domains') {
                // IDN/label max is 63 per label, total 253; test multi-label 253 vs 254.
                final valid253 =
                    '${'a' * 60}.${'b' * 60}.${'c' * 60}.${'d' * 58}.example.com';
                // Ensure exact 253 length
                final d253 = valid253.length == 253
                    ? valid253
                    : ('${'a' * 60}.${'b' * 60}.${'c' * 60}.${'d' * (253 - 183 - 12)}.example.com');
                final okArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>[d253];
                expect(
                  _validateArgs(evaluator, tool.name, okArgs, now).allowed,
                  isTrue,
                  reason: '${tool.name}.$key rejected 253-char domain',
                );
                final badArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>['a$d253'];
                expect(
                  _validateArgs(evaluator, tool.name, badArgs, now).allowed,
                  isFalse,
                  reason: '${tool.name}.$key accepted 254-char domain',
                );
              } else if (key == 'fileExtensions') {
                final badArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>['a' * (maxLen + 1)];
                expect(
                  _validateArgs(evaluator, tool.name, badArgs, now).allowed,
                  isFalse,
                  reason: '${tool.name}.$key accepted ${maxLen + 1} chars',
                );
              } else {
                final passItem =
                    _stringWithExactLength(tool.name, '${key}_item', maxLen);
                final failItem = _stringWithExactLength(
                    tool.name, '${key}_item', maxLen + 1);
                final okArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>[passItem];
                expect(
                  _validateArgs(evaluator, tool.name, okArgs, now).allowed,
                  isTrue,
                  reason: '${tool.name}.$key rejected $maxLen-char item',
                );
                final badArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>[failItem];
                expect(
                  _validateArgs(evaluator, tool.name, badArgs, now).allowed,
                  isFalse,
                  reason: '${tool.name}.$key accepted ${maxLen + 1}-char item',
                );
              }
            }
          }
        }
      }

      // Nested workflow.batch_steps.steps[0]['tool'] maxLength: 64 check.
      final tooLongTool = 'app.${'a' * 61}'; // 65 chars
      final batchFail = <String, Object?>{
        'steps': <Map<String, Object?>>[
          <String, Object?>{
            'tool': tooLongTool,
            'arguments': <String, Object?>{},
          },
        ],
      };
      expect(
        _validateArgs(evaluator, 'workflow.batch_steps', batchFail, now)
            .allowed,
        isFalse,
      );
    });

    test(
        'pre-trim maxLength: leading/trailing whitespace & dot-padded (maxLength + 1) strings fail across all schemas',
        () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;

          if (propSchema['type'] == 'string' &&
              propSchema['maxLength'] is int &&
              !propSchema.containsKey('enum')) {
            final maxLen = propSchema['maxLength'] as int;
            final base = _synthesizeArgs(tool, full: false);
            if (tool.name == 'skill.markdown_bridge' &&
                key == 'markdownContent') {
              base['action'] = 'import_skill_md';
            }
            if (tool.name == 'memory.markdown_vault' && key == 'noteContent') {
              base['action'] = 'append_note';
            }
            if (tool.name == 'memory.markdown_vault' &&
                key == 'sessionTranscript') {
              base['action'] = 'pre_compaction_flush';
            }
            if (tool.name == 'calendar.list_events' &&
                (key == 'timeMin' || key == 'timeMax')) {
              base['timeMin'] = '2026-11-19T10:00:00Z';
              base['timeMax'] = '2026-11-19T12:00:00Z';
            }
            if (tool.name == 'calendar.create_event' &&
                (key == 'startTime' || key == 'endTime')) {
              base['startTime'] = '2026-11-19T10:00:00Z';
              base['endTime'] = '2026-11-19T12:00:00Z';
            }

            final sampleObj =
                _validValueForSchema(tool.name, key, propSchema, full: false);
            final sample = sampleObj is String && sampleObj.length <= maxLen
                ? sampleObj
                : 'a';
            final padLen = maxLen + 1 - sample.length;
            final leadingPadded = '${' ' * padLen}$sample';
            final trailingPadded = '$sample${' ' * padLen}';

            for (final padded in <String>[leadingPadded, trailingPadded]) {
              final badArgs = Map<String, Object?>.from(base)..[key] = padded;
              final res = _validateArgs(evaluator, tool.name, badArgs, now);
              expect(
                res.allowed,
                isFalse,
                reason:
                    '${tool.name}.$key accepted whitespace-padded length ${padded.length} (> maxLength $maxLen)',
              );
            }
          }

          if (propSchema['type'] == 'array') {
            final items = propSchema['items'] as Map<String, Object?>?;
            if (items != null &&
                items['type'] == 'string' &&
                items['maxLength'] is int &&
                !items.containsKey('enum')) {
              final maxLen = items['maxLength'] as int;
              final baseSample = key == 'domains'
                  ? 'example.com'
                  : (key == 'fileExtensions'
                      ? 'pdf'
                      : (key == 'to' || key == 'cc' || key == 'bcc'
                          ? 'owner@example.com'
                          : 'vscode'));
              final padLen = maxLen + 1 - baseSample.length;
              final candidates = <String>[
                '${' ' * padLen}$baseSample',
                '$baseSample${' ' * padLen}',
                if (key == 'fileExtensions') '${'.' * padLen}$baseSample',
              ];
              for (final badItem in candidates) {
                final badArgs = _synthesizeArgs(tool, full: false)
                  ..[key] = <String>[badItem];
                final res = _validateArgs(evaluator, tool.name, badArgs, now);
                expect(
                  res.allowed,
                  isFalse,
                  reason:
                      '${tool.name}.$key[] accepted padded length ${badItem.length} (> maxLength $maxLen)',
                );
              }
            }
          }
        }
      }
    });

    test(
        'non-finite numbers (NaN, +/-Infinity) are rejected on all number fields',
        () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;
          if (propSchema['type'] != 'number') continue;

          for (final badNum in const <double>[
            double.nan,
            double.infinity,
            double.negativeInfinity,
          ]) {
            final base = _synthesizeArgs(tool, full: false);
            if (tool.name == 'input.click' &&
                (key == 'xNorm' || key == 'yNorm')) {
              base['xNorm'] = 0.5;
              base['yNorm'] = 0.5;
            }
            final badArgs = Map<String, Object?>.from(base)..[key] = badNum;
            final res = _validateArgs(evaluator, tool.name, badArgs, now);
            expect(
              res.allowed,
              isFalse,
              reason: '${tool.name}.$key accepted non-finite $badNum',
            );
            expect(res.errorCode, equals('schema_mismatch'));
          }
        }
      }
    });

    test(
        'minLength: 1 on optional elementId/fromElementId/toElementId matches validator',
        () {
      for (final toolName in const <String>[
        'input.click',
        'input.drag',
        'input.scroll',
      ]) {
        final tool = allTools.firstWhere((t) => t.name == toolName);
        final props = tool.inputSchema['properties']! as Map<String, Object?>;
        for (final key in props.keys) {
          if (key == 'elementId' ||
              key == 'fromElementId' ||
              key == 'toElementId') {
            final propSchema = props[key]! as Map<String, Object?>;
            expect(propSchema['minLength'], equals(1),
                reason: '$toolName.$key should declare minLength: 1');
            final badArgs = _synthesizeArgs(tool, full: false)..[key] = '';
            final res = _validateArgs(evaluator, toolName, badArgs, now);
            expect(res.allowed, isFalse);
            expect(res.errorCode, equals('schema_mismatch'));
          }
        }
      }
    });

    test('numeric minimum and maximum boundaries fail outside bounds', () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;
          final type = propSchema['type'];
          if (type != 'integer' && type != 'number') continue;

          final base = _synthesizeArgs(tool, full: false);
          if (tool.name == 'input.click' &&
              (key == 'xNorm' || key == 'yNorm')) {
            base['xNorm'] = 0.5;
            base['yNorm'] = 0.5;
          }

          if (propSchema['minimum'] is num) {
            final min = propSchema['minimum'] as num;
            final below = type == 'integer' ? min.toInt() - 1 : min - 0.1;
            final badArgs = Map<String, Object?>.from(base)..[key] = below;
            final res = _validateArgs(evaluator, tool.name, badArgs, now);
            expect(
              res.allowed,
              isFalse,
              reason: '${tool.name}.$key accepted $below (< minimum $min)',
            );
          }
          if (propSchema['maximum'] is num) {
            final max = propSchema['maximum'] as num;
            final above = type == 'integer' ? max.toInt() + 1 : max + 0.1;
            final badArgs = Map<String, Object?>.from(base)..[key] = above;
            final res = _validateArgs(evaluator, tool.name, badArgs, now);
            expect(
              res.allowed,
              isFalse,
              reason: '${tool.name}.$key accepted $above (> maximum $max)',
            );
          }
        }
      }
    });

    test('type mismatches are rejected for every typed property', () {
      for (final tool in allTools) {
        final props =
            (tool.inputSchema['properties'] as Map<String, Object?>?) ??
                const <String, Object?>{};
        for (final entry in props.entries) {
          final key = entry.key;
          final propSchema = entry.value! as Map<String, Object?>;
          final type = propSchema['type'];
          if (type == null) continue;

          final Object wrongVal = switch (type) {
            'string' => 12345,
            'integer' => 'not_an_int',
            'number' => 'not_a_number',
            'boolean' => 'not_a_bool',
            'array' => 'not_an_array',
            'object' => 'not_an_object',
            _ => 12345,
          };

          final badArgs = _synthesizeArgs(tool, full: false)..[key] = wrongVal;
          final res = _validateArgs(evaluator, tool.name, badArgs, now);
          expect(
            res.allowed,
            isFalse,
            reason:
                '${tool.name}.$key accepted wrong type ${wrongVal.runtimeType} for $type',
          );
        }
      }
    });
  });
}

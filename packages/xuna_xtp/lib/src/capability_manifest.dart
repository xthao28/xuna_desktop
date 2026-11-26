/// Pure-Dart schema, strict fail-closed validator, and argv compiler for
/// declarative Capability Adapter manifests (`ADR-0021` / Upgrade Plan P4.1).
///
/// Zero application or CLI names are hardcoded here (Rule H5): every external
/// capability is declared as pure data, validated fail-closed against shell
/// interpreters, inline eval flags, shell metacharacters, and untyped
/// placeholders, and bound to a canonical SHA-256 content digest.
library;

import 'dart:convert';

import 'canonical_json.dart';
import 'crypto.dart';
import 'policy/exec_command_classifier.dart';
import 'policy/exec_expected_outputs.dart';
import 'policy/fs_path_guard.dart';
import 'policy/shell_control_policy.dart';
import 'schemas/core_types.dart';

final RegExp capabilityAdapterIdPattern = RegExp(r'^[a-z][a-z0-9_.-]{1,63}$');
final RegExp capabilityNamePattern =
    RegExp(r'^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$');
final RegExp _inputNameRe = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{0,31}$');
final RegExp _formatTagRe = RegExp(r'^[a-z0-9]{1,16}$');
final RegExp _binaryNameRe = RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$');
final RegExp _lowerSha256Re = RegExp(r'^[0-9a-f]{64}$');
final RegExp _hexMagicRe = RegExp(r'^([0-9a-fA-F]{2}){1,16}$');
final RegExp _placeholderRe = RegExp(r'\{([^{}]*)\}');
final RegExp _shellMetaRe = RegExp(r'[&|;<>`$\n\r\x00]');

/// Shell and scripting-host executables permanently forbidden as manifest
/// adapter binaries (`ADR-0021` §1).
const Set<String> forbiddenCapabilityBinaries = <String>{
  'cmd',
  'cmd.exe',
  'command',
  'command.com',
  'powershell',
  'powershell.exe',
  'pwsh',
  'pwsh.exe',
  'bash',
  'bash.exe',
  'sh',
  'sh.exe',
  'zsh',
  'fish',
  'dash',
  'ksh',
  'csh',
  'tcsh',
  'osascript',
  'wscript',
  'wscript.exe',
  'cscript',
  'cscript.exe',
  'mshta',
  'mshta.exe',
  'rundll32',
  'rundll32.exe',
  'regsvr32',
  'regsvr32.exe',
  'sudo',
  'su',
  'doas',
  'pkexec',
  'runas',
  'runas.exe',
  'env',
  'xargs',
};

/// Inline code-evaluation flags forbidden inside manifest `argvTemplate` tokens.
const Set<String> forbiddenCapabilityEvalFlags = <String>{
  '-c',
  '-e',
  '-pe',
  '-ec',
  '/c',
  '/k',
  '--eval',
  '--command',
  '-command',
  '-encodedcommand',
  '-enc',
  '-ecmd',
};

/// Provenance of a declarative capability adapter manifest (`ADR-0021`).
enum CapabilityProvenanceKind {
  seed('seed'),
  foundry('foundry');

  const CapabilityProvenanceKind(this.wire);
  final String wire;

  static CapabilityProvenanceKind fromWire(String raw) => switch (raw) {
        'seed' => CapabilityProvenanceKind.seed,
        'foundry' => CapabilityProvenanceKind.foundry,
        _ => throw FormatException('Unknown capability provenance kind: $raw'),
      };
}

/// Strictly typed input kinds supported by declarative capability manifests.
enum CapabilityInputType {
  path('path'),
  string('string'),
  integer('integer'),
  boolean('boolean'),
  enumValue('enum');

  const CapabilityInputType(this.wire);
  final String wire;

  static CapabilityInputType fromWire(String raw) => switch (raw) {
        'path' => CapabilityInputType.path,
        'string' => CapabilityInputType.string,
        'integer' => CapabilityInputType.integer,
        'boolean' => CapabilityInputType.boolean,
        'enum' => CapabilityInputType.enumValue,
        _ => throw FormatException('Unknown capability input type: $raw'),
      };
}

/// Declaration of one typed input field on a [CapabilityManifest].
class CapabilityInputSpec {
  CapabilityInputSpec({
    required this.name,
    required this.type,
    this.required = true,
    this.maxLength,
    this.minimum,
    this.maximum,
    this.enumValues = const <String>[],
    this.allowedExtensions = const <String>[],
    this.isOutputPath = false,
  }) {
    if (!_inputNameRe.hasMatch(name)) {
      throw FormatException('Invalid capability input name: $name');
    }
    if (maxLength != null && (maxLength! < 1 || maxLength! > 1024)) {
      throw const FormatException('maxLength must be 1..1024');
    }
    if (minimum != null && maximum != null && minimum! > maximum!) {
      throw const FormatException('minimum cannot exceed maximum');
    }
    if (type == CapabilityInputType.enumValue) {
      if (enumValues.isEmpty || enumValues.length > 32) {
        throw const FormatException('enum input requires 1..32 enumValues');
      }
      for (final v in enumValues) {
        if (v.isEmpty || v.length > 64 || _shellMetaRe.hasMatch(v)) {
          throw FormatException('Invalid enum value: $v');
        }
      }
    } else if (enumValues.isNotEmpty) {
      throw const FormatException('enumValues only allowed for enum inputs');
    }
    if (allowedExtensions.isNotEmpty && type != CapabilityInputType.path) {
      throw const FormatException(
        'allowedExtensions only allowed for path inputs',
      );
    }
    for (final ext in allowedExtensions) {
      if (!_formatTagRe.hasMatch(ext)) {
        throw FormatException('Invalid allowedExtension: $ext');
      }
    }
    if (isOutputPath && type != CapabilityInputType.path) {
      throw const FormatException('isOutputPath only allowed for path inputs');
    }
  }

  factory CapabilityInputSpec.fromJson(Map<String, Object?> json) {
    final name = json['name'];
    final rawType = json['type'];
    if (name is! String || rawType is! String) {
      throw const FormatException('input spec requires name and type');
    }
    final req = json['required'] ?? true;
    if (req is! bool) {
      throw const FormatException('input required must be bool');
    }
    final maxLen = json['maxLength'];
    if (maxLen != null && maxLen is! int) {
      throw const FormatException('maxLength must be int');
    }
    final minVal = json['minimum'];
    if (minVal != null && minVal is! int) {
      throw const FormatException('minimum must be int');
    }
    final maxVal = json['maximum'];
    if (maxVal != null && maxVal is! int) {
      throw const FormatException('maximum must be int');
    }
    final rawEnum = json['enumValues'];
    final enumVals = <String>[];
    if (rawEnum != null) {
      if (rawEnum is! List) {
        throw const FormatException('enumValues must be list');
      }
      for (final item in rawEnum) {
        if (item is! String) {
          throw const FormatException('enumValues items must be string');
        }
        enumVals.add(item);
      }
    }
    final rawExts = json['allowedExtensions'];
    final exts = <String>[];
    if (rawExts != null) {
      if (rawExts is! List) {
        throw const FormatException('allowedExtensions must be list');
      }
      for (final item in rawExts) {
        if (item is! String) {
          throw const FormatException('allowedExtensions items must be string');
        }
        exts.add(item.toLowerCase());
      }
    }
    final isOut = json['isOutputPath'] ?? false;
    if (isOut is! bool) {
      throw const FormatException('isOutputPath must be bool');
    }
    return CapabilityInputSpec(
      name: name,
      type: CapabilityInputType.fromWire(rawType),
      required: req,
      maxLength: maxLen as int?,
      minimum: minVal as int?,
      maximum: maxVal as int?,
      enumValues: List<String>.unmodifiable(enumVals),
      allowedExtensions: List<String>.unmodifiable(exts),
      isOutputPath: isOut,
    );
  }

  final String name;
  final CapabilityInputType type;
  final bool required;
  final int? maxLength;
  final int? minimum;
  final int? maximum;
  final List<String> enumValues;
  final List<String> allowedExtensions;
  final bool isOutputPath;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'type': type.wire,
        'required': required,
        if (maxLength != null) 'maxLength': maxLength,
        if (minimum != null) 'minimum': minimum,
        if (maximum != null) 'maximum': maximum,
        if (enumValues.isNotEmpty) 'enumValues': enumValues,
        if (allowedExtensions.isNotEmpty)
          'allowedExtensions': allowedExtensions,
        if (isOutputPath) 'isOutputPath': isOutputPath,
      };
}

/// Host binary detection and manifest-declared display-only remediation.
class CapabilityDetectSpec {
  CapabilityDetectSpec({
    required this.binary,
    this.versionArgs = const <String>['--version'],
    this.minVersion,
    this.remediationSummary,
    this.remediationCommandWindows,
    this.remediationCommandMacos,
    this.remediationCommandLinux,
  }) {
    final trimmed = binary.trim();
    if (!_binaryNameRe.hasMatch(trimmed)) {
      throw FormatException('Invalid detect.binary name: $binary');
    }
    if (forbiddenCapabilityBinaries.contains(trimmed.toLowerCase())) {
      throw FormatException(
        'Forbidden shell/privileged binary in manifest: $binary',
      );
    }
    if (versionArgs.length > 4) {
      throw const FormatException('detect.versionArgs allows at most 4 items');
    }
    for (final arg in versionArgs) {
      if (arg.isEmpty ||
          arg.length > 64 ||
          _shellMetaRe.hasMatch(arg) ||
          forbiddenCapabilityEvalFlags.contains(arg.toLowerCase())) {
        throw FormatException('Forbidden detect.versionArgs token: $arg');
      }
    }
    if (minVersion != null &&
        (minVersion!.isEmpty || minVersion!.length > 32)) {
      throw const FormatException('Invalid detect.minVersion');
    }
    for (final text in <String?>[
      remediationSummary,
      remediationCommandWindows,
      remediationCommandMacos,
      remediationCommandLinux,
    ]) {
      if (text != null &&
          (text.trim().isEmpty ||
              text.length > 240 ||
              text.contains('\n') ||
              text.contains('\r'))) {
        throw const FormatException('Invalid manifest remediation text');
      }
    }
  }

  factory CapabilityDetectSpec.fromJson(Map<String, Object?> json) {
    final binary = json['binary'];
    if (binary is! String) {
      throw const FormatException('detect.binary must be string');
    }
    final rawArgs = json['versionArgs'];
    final args = <String>[];
    if (rawArgs == null) {
      args.add('--version');
    } else if (rawArgs is List) {
      for (final item in rawArgs) {
        if (item is! String) {
          throw const FormatException('detect.versionArgs must be strings');
        }
        args.add(item);
      }
    } else {
      throw const FormatException('detect.versionArgs must be list');
    }
    String? optStr(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String) throw FormatException('detect.$key must be string');
      return v;
    }

    return CapabilityDetectSpec(
      binary: binary,
      versionArgs: List<String>.unmodifiable(args),
      minVersion: optStr('minVersion'),
      remediationSummary: optStr('remediationSummary'),
      remediationCommandWindows: optStr('remediationCommandWindows'),
      remediationCommandMacos: optStr('remediationCommandMacos'),
      remediationCommandLinux: optStr('remediationCommandLinux'),
    );
  }

  final String binary;
  final List<String> versionArgs;
  final String? minVersion;
  final String? remediationSummary;
  final String? remediationCommandWindows;
  final String? remediationCommandMacos;
  final String? remediationCommandLinux;

  Map<String, Object?> toJson() => <String, Object?>{
        'binary': binary,
        'versionArgs': versionArgs,
        if (minVersion != null) 'minVersion': minVersion,
        if (remediationSummary != null)
          'remediationSummary': remediationSummary,
        if (remediationCommandWindows != null)
          'remediationCommandWindows': remediationCommandWindows,
        if (remediationCommandMacos != null)
          'remediationCommandMacos': remediationCommandMacos,
        if (remediationCommandLinux != null)
          'remediationCommandLinux': remediationCommandLinux,
      };
}

/// Fixed argv template with strictly typed `{inputName}` placeholders.
class CapabilityInvokeSpec {
  CapabilityInvokeSpec({
    required this.argvTemplate,
    this.timeoutMs = 30000,
  }) {
    if (argvTemplate.isEmpty || argvTemplate.length > 32) {
      throw const FormatException('invoke.argvTemplate requires 1..32 tokens');
    }
    if (timeoutMs < 1000 || timeoutMs > 180000) {
      throw const FormatException('invoke.timeoutMs must be 1000..180000');
    }
    for (final token in argvTemplate) {
      if (token.isEmpty || token.length > 256) {
        throw const FormatException('Invalid argvTemplate token length');
      }
      if (_shellMetaRe.hasMatch(token)) {
        throw FormatException('Shell metacharacter forbidden in token: $token');
      }
      final lower = token.trim().toLowerCase();
      if (forbiddenCapabilityEvalFlags.contains(lower)) {
        throw FormatException('Inline eval flag forbidden in manifest: $token');
      }
      // Reject unescaped or malformed braces outside exact `{name}` placeholders.
      var braceDepth = 0;
      for (var i = 0; i < token.length; i++) {
        final ch = token[i];
        if (ch == '{') {
          braceDepth++;
          if (braceDepth > 1) {
            throw FormatException('Nested braces forbidden in token: $token');
          }
        } else if (ch == '}') {
          braceDepth--;
          if (braceDepth < 0) {
            throw FormatException('Unbalanced brace in token: $token');
          }
        }
      }
      if (braceDepth != 0) {
        throw FormatException('Unclosed placeholder in token: $token');
      }
      for (final m in _placeholderRe.allMatches(token)) {
        final name = m.group(1) ?? '';
        if (!_inputNameRe.hasMatch(name)) {
          throw FormatException('Invalid placeholder "{$name}" in manifest');
        }
      }
    }
  }

  factory CapabilityInvokeSpec.fromJson(Map<String, Object?> json) {
    final rawArgv = json['argvTemplate'];
    if (rawArgv is! List) {
      throw const FormatException('invoke.argvTemplate must be list');
    }
    final argv = <String>[];
    for (final item in rawArgv) {
      if (item is! String) {
        throw const FormatException('invoke.argvTemplate items must be string');
      }
      argv.add(item);
    }
    final timeout = json['timeoutMs'] ?? 30000;
    if (timeout is! int) {
      throw const FormatException('invoke.timeoutMs must be int');
    }
    return CapabilityInvokeSpec(
      argvTemplate: List<String>.unmodifiable(argv),
      timeoutMs: timeout,
    );
  }

  final List<String> argvTemplate;
  final int timeoutMs;

  Map<String, Object?> toJson() => <String, Object?>{
        'argvTemplate': argvTemplate,
        'timeoutMs': timeoutMs,
      };
}

/// Output file verification rule reusing P1.1 `expectFiles` semantics.
class CapabilityVerifyFileSpec {
  CapabilityVerifyFileSpec({
    required this.pathTemplate,
    this.minBytes,
    this.magic,
  }) {
    if (pathTemplate.isEmpty ||
        pathTemplate.length > 512 ||
        _shellMetaRe.hasMatch(pathTemplate)) {
      throw const FormatException('Invalid verifyFiles.pathTemplate');
    }
    if (minBytes != null && minBytes! < 0) {
      throw const FormatException('verifyFiles.minBytes must be >= 0');
    }
    if (magic != null && !_hexMagicRe.hasMatch(magic!)) {
      throw const FormatException('verifyFiles.magic must be 1..16 hex bytes');
    }
  }

  factory CapabilityVerifyFileSpec.fromJson(Map<String, Object?> json) {
    final tmpl = json['pathTemplate'];
    if (tmpl is! String) {
      throw const FormatException('verifyFiles.pathTemplate must be string');
    }
    final minB = json['minBytes'];
    if (minB != null && minB is! int) {
      throw const FormatException('verifyFiles.minBytes must be int');
    }
    final magic = json['magic'];
    if (magic != null && magic is! String) {
      throw const FormatException('verifyFiles.magic must be string');
    }
    return CapabilityVerifyFileSpec(
      pathTemplate: tmpl,
      minBytes: minB as int?,
      magic: magic is String ? magic.toLowerCase() : null,
    );
  }

  final String pathTemplate;
  final int? minBytes;
  final String? magic;

  Map<String, Object?> toJson() => <String, Object?>{
        'pathTemplate': pathTemplate,
        if (minBytes != null) 'minBytes': minBytes,
        if (magic != null) 'magic': magic,
      };
}

/// Tamper-evident provenance and approval record on a [CapabilityManifest].
class CapabilityProvenance {
  CapabilityProvenance({
    required this.kind,
    required this.approved,
    this.manifestSha256,
    this.binarySha256,
    this.approvedAt,
  }) {
    if (manifestSha256 != null && !_lowerSha256Re.hasMatch(manifestSha256!)) {
      throw const FormatException('provenance.manifestSha256 must be 64 hex');
    }
    if (binarySha256 != null && !_lowerSha256Re.hasMatch(binarySha256!)) {
      throw const FormatException('provenance.binarySha256 must be 64 hex');
    }
    if (approvedAt != null && DateTime.tryParse(approvedAt!) == null) {
      throw const FormatException('provenance.approvedAt must be ISO-8601');
    }
  }

  factory CapabilityProvenance.fromJson(Map<String, Object?> json) {
    final kind = json['kind'];
    final approved = json['approved'];
    if (kind is! String || approved is! bool) {
      throw const FormatException('provenance requires kind and approved');
    }
    String? optStr(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String) throw FormatException('provenance.$key must be string');
      return v;
    }

    return CapabilityProvenance(
      kind: CapabilityProvenanceKind.fromWire(kind),
      approved: approved,
      manifestSha256: optStr('manifestSha256'),
      binarySha256: optStr('binarySha256'),
      approvedAt: optStr('approvedAt'),
    );
  }

  final CapabilityProvenanceKind kind;
  final bool approved;
  final String? manifestSha256;
  final String? binarySha256;
  final String? approvedAt;

  CapabilityProvenance copyWith({
    bool? approved,
    String? manifestSha256,
    String? binarySha256,
    String? approvedAt,
  }) =>
      CapabilityProvenance(
        kind: kind,
        approved: approved ?? this.approved,
        manifestSha256: manifestSha256 ?? this.manifestSha256,
        binarySha256: binarySha256 ?? this.binarySha256,
        approvedAt: approvedAt ?? this.approvedAt,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind.wire,
        'approved': approved,
        if (manifestSha256 != null) 'manifestSha256': manifestSha256,
        if (binarySha256 != null) 'binarySha256': binarySha256,
        if (approvedAt != null) 'approvedAt': approvedAt,
      };
}

/// Complete validated declarative Capability Adapter manifest (`ADR-0021`).
class CapabilityManifest {
  CapabilityManifest({
    this.schemaVersion = 1,
    required this.id,
    required this.capability,
    required this.description,
    this.fromFormats = const <String>[],
    this.toFormats = const <String>[],
    required this.risk,
    required this.inputs,
    required this.detect,
    required this.invoke,
    this.verifyFiles = const <CapabilityVerifyFileSpec>[],
    required this.provenance,
  }) {
    if (schemaVersion != 1) {
      throw const FormatException('CapabilityManifest schemaVersion must be 1');
    }
    if (!capabilityAdapterIdPattern.hasMatch(id)) {
      throw FormatException('Invalid capability adapter id: $id');
    }
    if (!capabilityNamePattern.hasMatch(capability)) {
      throw FormatException('Invalid capability name: $capability');
    }
    if (description.trim().isEmpty || description.length > 200) {
      throw const FormatException('description must be 1..200 chars');
    }
    if (risk != RiskTier.r2 && risk != RiskTier.r3) {
      throw FormatException(
        'Capability adapter risk must be R2 or R3, got ${risk.wire}',
      );
    }
    for (final f in [...fromFormats, ...toFormats]) {
      if (!_formatTagRe.hasMatch(f)) {
        throw FormatException('Invalid format tag: $f');
      }
    }
    if (inputs.length > 16) {
      throw const FormatException('Capability manifest allows <= 16 inputs');
    }
    final inputByName = <String, CapabilityInputSpec>{};
    for (final spec in inputs) {
      if (inputByName.containsKey(spec.name)) {
        throw FormatException('Duplicate input name: ${spec.name}');
      }
      inputByName[spec.name] = spec;
    }
    // Every placeholder in argvTemplate and verifyFiles MUST match a declared
    // typed input (fail closed against untyped placeholders!).
    for (final token in invoke.argvTemplate) {
      for (final m in _placeholderRe.allMatches(token)) {
        final name = m.group(1)!;
        if (!inputByName.containsKey(name)) {
          throw FormatException(
            'Undeclared/untyped placeholder "{$name}" in argvTemplate',
          );
        }
      }
    }
    for (final vf in verifyFiles) {
      for (final m in _placeholderRe.allMatches(vf.pathTemplate)) {
        final name = m.group(1)!;
        final spec = inputByName[name];
        if (spec == null) {
          throw FormatException(
            'Undeclared placeholder "{$name}" in verifyFiles.pathTemplate',
          );
        }
      }
    }
  }

  factory CapabilityManifest.fromJson(Map<String, Object?> json) {
    final ver = json['schemaVersion'];
    if (ver != 1) {
      throw const FormatException('schemaVersion must be 1');
    }
    String reqStr(String key) {
      final v = json[key];
      if (v is! String) throw FormatException('$key must be string');
      return v;
    }

    List<String> optStrList(String key) {
      final v = json[key];
      if (v == null) return const <String>[];
      if (v is! List) throw FormatException('$key must be list');
      return List<String>.unmodifiable(<String>[
        for (final item in v)
          if (item is String)
            item.toLowerCase()
          else
            throw FormatException('$key items must be string'),
      ]);
    }

    Map<String, Object?> reqMap(String key) {
      final v = json[key];
      if (v is! Map) throw FormatException('$key must be object');
      return v.map((k, val) => MapEntry(k.toString(), val));
    }

    final rawInputs = json['inputs'];
    if (rawInputs is! List) {
      throw const FormatException('inputs must be list');
    }
    final inputs = <CapabilityInputSpec>[
      for (final item in rawInputs)
        if (item is Map)
          CapabilityInputSpec.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          )
        else
          throw const FormatException('inputs items must be object'),
    ];

    final rawVerify = json['verifyFiles'];
    final verify = <CapabilityVerifyFileSpec>[];
    if (rawVerify != null) {
      if (rawVerify is! List) {
        throw const FormatException('verifyFiles must be list');
      }
      for (final item in rawVerify) {
        if (item is! Map) {
          throw const FormatException('verifyFiles items must be object');
        }
        verify.add(
          CapabilityVerifyFileSpec.fromJson(
            item.map((k, v) => MapEntry(k.toString(), v)),
          ),
        );
      }
    }

    return CapabilityManifest(
      schemaVersion: 1,
      id: reqStr('id'),
      capability: reqStr('capability'),
      description: reqStr('description'),
      fromFormats: optStrList('fromFormats'),
      toFormats: optStrList('toFormats'),
      risk: RiskTier.fromWire(reqStr('risk')),
      inputs: List<CapabilityInputSpec>.unmodifiable(inputs),
      detect: CapabilityDetectSpec.fromJson(reqMap('detect')),
      invoke: CapabilityInvokeSpec.fromJson(reqMap('invoke')),
      verifyFiles: List<CapabilityVerifyFileSpec>.unmodifiable(verify),
      provenance: CapabilityProvenance.fromJson(reqMap('provenance')),
    );
  }

  final int schemaVersion;
  final String id;
  final String capability;
  final String description;
  final List<String> fromFormats;
  final List<String> toFormats;
  final RiskTier risk;
  final List<CapabilityInputSpec> inputs;
  final CapabilityDetectSpec detect;
  final CapabilityInvokeSpec invoke;
  final List<CapabilityVerifyFileSpec> verifyFiles;
  final CapabilityProvenance provenance;

  /// Canonical content payload excluding [provenance], hashed to pin manifest
  /// integrity (`ADR-0021` §1).
  Map<String, Object?> toContentJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'id': id,
        'capability': capability,
        'description': description,
        if (fromFormats.isNotEmpty) 'fromFormats': fromFormats,
        if (toFormats.isNotEmpty) 'toFormats': toFormats,
        'risk': risk.wire,
        'inputs': [for (final i in inputs) i.toJson()],
        'detect': detect.toJson(),
        'invoke': invoke.toJson(),
        if (verifyFiles.isNotEmpty)
          'verifyFiles': [for (final v in verifyFiles) v.toJson()],
      };

  /// Deterministic SHA-256 hex digest of [toContentJson] using RFC 8785 JCS.
  String computeContentSha256() =>
      sha256Hex(utf8.encode(canonicalJson(toContentJson())));

  /// Whether [provenance.manifestSha256] (if pinned) still matches content.
  bool get hasValidManifestPin {
    final pinned = provenance.manifestSha256;
    if (pinned == null) return true;
    return pinned == computeContentSha256();
  }

  CapabilityManifest withProvenance(CapabilityProvenance next) =>
      CapabilityManifest(
        schemaVersion: schemaVersion,
        id: id,
        capability: capability,
        description: description,
        fromFormats: fromFormats,
        toFormats: toFormats,
        risk: risk,
        inputs: inputs,
        detect: detect,
        invoke: invoke,
        verifyFiles: verifyFiles,
        provenance: next,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        ...toContentJson(),
        'provenance': provenance.toJson(),
      };
}

/// Compiled non-shell invocation ready for preflight or direct execution.
class CompiledCapabilityInvocation {
  const CompiledCapabilityInvocation({
    required this.allowed,
    required this.effectiveRisk,
    this.errorCode,
    this.reasonCode,
    this.argv = const <String>[],
    this.expectedFiles = const <ExpectedFileSpec>[],
    this.workingDirectory,
  });

  final bool allowed;
  final RiskTier effectiveRisk;
  final String? errorCode;
  final String? reasonCode;
  final List<String> argv;
  final List<ExpectedFileSpec> expectedFiles;
  final String? workingDirectory;
}

/// Validates [rawInputs] against [manifest.inputs], checks every path through
/// [classifyFsPath], builds literal non-shell [argv], and computes effective
/// risk as `max(manifest.risk, pathRisk, ExecCommandClassifier(argv))`.
CompiledCapabilityInvocation compileCapabilityInvocation({
  required CapabilityManifest manifest,
  required Map<String, Object?> rawInputs,
  required ShellControlPolicy shellControl,
  String? homeDirectory,
  bool windows = false,
  bool caseInsensitive = true,
  String? Function(String normalizedPath)? realPath,
  String Function(String normalizedPath)? mapPathForDraft,
}) {
  final specByName = <String, CapabilityInputSpec>{
    for (final s in manifest.inputs) s.name: s,
  };
  for (final key in rawInputs.keys) {
    if (!specByName.containsKey(key)) {
      return CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: manifest.risk,
        errorCode: 'schema_mismatch',
        reasonCode: 'unknown_input',
      );
    }
  }

  final renderedValues = <String, String>{};
  var maxRisk = manifest.risk;
  var riskReason = 'capability_manifest';
  String? inferredWorkDir;

  for (final spec in manifest.inputs) {
    final present = rawInputs.containsKey(spec.name) &&
        rawInputs[spec.name] != null;
    if (!present) {
      if (spec.required) {
        return CompiledCapabilityInvocation(
          allowed: false,
          effectiveRisk: maxRisk,
          errorCode: 'schema_mismatch',
          reasonCode: 'missing_required_input',
        );
      }
      continue;
    }
    final val = rawInputs[spec.name];
    switch (spec.type) {
      case CapabilityInputType.path:
        if (val is! String || val.isEmpty || val.length > 512) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        final norm = normalizeHostPath(
          val,
          homeDirectory: homeDirectory,
          windows: windows,
        );
        if (norm == null) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'path_not_absolute',
          );
        }
        if (spec.allowedExtensions.isNotEmpty) {
          final lowerPath = norm.toLowerCase();
          final okExt = spec.allowedExtensions.any(
            (ext) => lowerPath.endsWith('.$ext'),
          );
          if (!okExt) {
            return CompiledCapabilityInvocation(
              allowed: false,
              effectiveRisk: maxRisk,
              errorCode: 'schema_mismatch',
              reasonCode: 'extension_not_allowed',
            );
          }
        }
        final access =
            spec.isOutputPath ? FsAccessKind.write : FsAccessKind.read;
        final fsDecision = classifyFsPath(
          normalizedPath: norm,
          resolvedPath: realPath?.call(norm),
          access: access,
          shellControl: shellControl,
          homeDirectory: homeDirectory,
          windows: windows,
          caseInsensitive: caseInsensitive,
          realPath: realPath,
        );
        if (fsDecision.denied) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: RiskTier.r3,
            errorCode: fsDecision.errorCode ?? 'fs_path_forbidden',
            reasonCode: fsDecision.reasonCode,
          );
        }
        if (fsDecision.risk > maxRisk) {
          maxRisk = fsDecision.risk;
          riskReason = fsDecision.reasonCode;
        }
        final effectivePath =
            mapPathForDraft != null ? mapPathForDraft(norm) : norm;
        renderedValues[spec.name] = effectivePath;
        inferredWorkDir ??= _parentDirOf(effectivePath, windows: windows);
      case CapabilityInputType.string:
        if (val is! String ||
            val.isEmpty ||
            val.length > (spec.maxLength ?? 256) ||
            val.contains('\x00') ||
            val.contains('\n') ||
            val.contains('\r')) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        renderedValues[spec.name] = val;
      case CapabilityInputType.integer:
        if (val is! int) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        if ((spec.minimum != null && val < spec.minimum!) ||
            (spec.maximum != null && val > spec.maximum!)) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        renderedValues[spec.name] = val.toString();
      case CapabilityInputType.boolean:
        if (val is! bool) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        renderedValues[spec.name] = val ? 'true' : 'false';
      case CapabilityInputType.enumValue:
        if (val is! String || !spec.enumValues.contains(val)) {
          return CompiledCapabilityInvocation(
            allowed: false,
            effectiveRisk: maxRisk,
            errorCode: 'schema_mismatch',
          );
        }
        renderedValues[spec.name] = val;
    }
  }

  // Render argv without shell interpolation — each template element yields
  // exactly one literal argv entry.
  final argv = <String>[];
  for (final token in manifest.invoke.argvTemplate) {
    var missingOptional = false;
    final rendered = token.replaceAllMapped(_placeholderRe, (m) {
      final name = m.group(1)!;
      final value = renderedValues[name];
      if (value == null) {
        missingOptional = true;
        return '';
      }
      return value;
    });
    if (missingOptional) {
      return CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: maxRisk,
        errorCode: 'schema_mismatch',
        reasonCode: 'missing_template_input',
      );
    }
    argv.add(rendered);
  }

  // Also run ExecCommandClassifier on a shell-safe quoted representation so
  // classifier Hard-Deny rules always apply as a defense-in-depth floor, and
  // take max(manifest.risk, pathRisk, classifierRisk) when classifier says R3.
  // Because execution is non-shell (argv list), benign non-allowlisted adapter
  // binaries keep manifest.risk (R2/R3) unless the command trips a Hard-Deny
  // rule or explicit destructive/network command pattern.
  final binaryDecision = classifyExecCommand(
    <String>[
      manifest.detect.binary,
      for (final a in argv) _quoteForClassifier(a),
    ].join(' '),
    ExecCommandContext(
      shellControl: shellControl,
      cwd: inferredWorkDir,
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPath: realPath,
    ),
  );
  if (binaryDecision.denied) {
    return CompiledCapabilityInvocation(
      allowed: false,
      effectiveRisk: RiskTier.r3,
      errorCode: binaryDecision.errorCode ?? 'exec_hard_denied',
      reasonCode: binaryDecision.reasonCode,
    );
  }
  if (binaryDecision.risk == RiskTier.r3 &&
      (binaryDecision.reasonCode == 'network_command' ||
          binaryDecision.reasonCode == 'destructive_command' ||
          binaryDecision.reasonCode == 'system_command' ||
          binaryDecision.reasonCode == 'package_install' ||
          binaryDecision.reasonCode == 'inline_eval')) {
    maxRisk = RiskTier.r3;
    riskReason = binaryDecision.reasonCode;
  }

  // Render expected output file checks (P1.1 reuse) and guard every target path.
  final expectedFiles = <ExpectedFileSpec>[];
  for (final vf in manifest.verifyFiles) {
    var missing = false;
    final rawOut = vf.pathTemplate.replaceAllMapped(_placeholderRe, (m) {
      final v = renderedValues[m.group(1)!];
      if (v == null) {
        missing = true;
        return '';
      }
      return v;
    });
    if (missing || rawOut.isEmpty) {
      return CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: maxRisk,
        errorCode: 'schema_mismatch',
        reasonCode: 'missing_verify_input',
      );
    }
    final normOut = normalizeHostPath(
      rawOut,
      homeDirectory: homeDirectory,
      windows: windows,
    );
    if (normOut == null) {
      return CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: maxRisk,
        errorCode: 'path_not_absolute',
      );
    }
    final outDecision = classifyFsPath(
      normalizedPath: normOut,
      resolvedPath: realPath?.call(normOut),
      access: FsAccessKind.read,
      shellControl: const ShellControlPolicy.disabled(),
      homeDirectory: homeDirectory,
      windows: windows,
      caseInsensitive: caseInsensitive,
      realPath: realPath,
    );
    if (outDecision.denied) {
      return CompiledCapabilityInvocation(
        allowed: false,
        effectiveRisk: RiskTier.r3,
        errorCode: outDecision.errorCode ?? 'fs_path_forbidden',
        reasonCode: outDecision.reasonCode,
      );
    }
    expectedFiles.add(
      ExpectedFileSpec(
        path: normOut,
        minBytes: vf.minBytes,
        magic: vf.magic == null ? null : _hexToBytesList(vf.magic!),
      ),
    );
  }

  return CompiledCapabilityInvocation(
    allowed: true,
    effectiveRisk: maxRisk,
    reasonCode: riskReason,
    argv: List<String>.unmodifiable(argv),
    expectedFiles: List<ExpectedFileSpec>.unmodifiable(expectedFiles),
    workingDirectory: inferredWorkDir,
  );
}

String _quoteForClassifier(String arg) {
  final escaped = arg.replaceAll('"', '');
  return '"$escaped"';
}

List<int> _hexToBytesList(String hex) {
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    out.add(int.parse(hex.substring(i, i + 2), radix: 16));
  }
  return List<int>.unmodifiable(out);
}

String? _parentDirOf(String normalizedPath, {required bool windows}) {
  final sep = windows ? '\\' : '/';
  final idx = normalizedPath.lastIndexOf(sep);
  if (idx <= 0) return null;
  if (windows && idx == 2 && normalizedPath[1] == ':') {
    return '${normalizedPath.substring(0, 2)}\\';
  }
  return normalizedPath.substring(0, idx);
}

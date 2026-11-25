import '../schemas.dart';
import 'security_redaction.dart';
import 'shell_control_policy.dart';
import 'url_domain_validator.dart';

/// Family-level policy decision in `host-policy.json` (`allow` | `block`).
enum FamilyPolicyDecision {
  allow('allow'),
  block('block');

  const FamilyPolicyDecision(this.wire);
  final String wire;

  static FamilyPolicyDecision fromWire(String value) => switch (value) {
        'allow' => FamilyPolicyDecision.allow,
        'block' => FamilyPolicyDecision.block,
        _ => throw FormatException('Unknown family decision: $value'),
      };
}

/// Application launch target kind (`UDC-3` §5.6.3).
enum AppLaunchKind {
  exe('exe'),
  aumid('aumid'),
  bundle('bundle');

  const AppLaunchKind(this.wire);
  final String wire;

  static AppLaunchKind fromWire(String value) => switch (value) {
        'exe' => AppLaunchKind.exe,
        'aumid' => AppLaunchKind.aumid,
        'bundle' => AppLaunchKind.bundle,
        _ => throw FormatException('Unknown AppLaunchKind: $value'),
      };
}

/// Workflow target kind (`UDC-3` §5.6.3).
enum WorkflowKind {
  lnk('lnk'),
  shortcut('shortcut');

  const WorkflowKind(this.wire);
  final String wire;

  static WorkflowKind fromWire(String value) => switch (value) {
        'lnk' => WorkflowKind.lnk,
        'shortcut' => WorkflowKind.shortcut,
        _ => throw FormatException('Unknown WorkflowKind: $value'),
      };
}

/// Allowlisted application entry in `host-policy.json`.
class AllowedAppConfig {
  AllowedAppConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.target,
    this.risk = RiskTier.r2,
  }) {
    if (!isValidShortId(id)) {
      throw FormatException('Invalid app id: $id');
    }
    if (name.isEmpty || name.length > 80) {
      throw const FormatException('App name must be 1..80 characters');
    }
    if (target.trim().isEmpty) {
      throw const FormatException('App target must not be empty');
    }
    // `app.launch` has a floor of R2 (`UDC-3` §5.6.4).
    if (risk < RiskTier.r2) {
      throw const FormatException(
        'App risk in host-policy.json cannot be lowered below R2',
      );
    }
  }

  factory AllowedAppConfig.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'id', 'name', 'kind', 'target', 'risk'},
      context: 'AllowedAppConfig',
    );
    return AllowedAppConfig(
      id: _requireString(json, 'id'),
      name: _requireString(json, 'name'),
      kind: AppLaunchKind.fromWire(_requireString(json, 'kind')),
      target: _requireString(json, 'target'),
      risk: RiskTier.fromWire(_requireString(json, 'risk')),
    );
  }

  final String id;
  final String name;
  final AppLaunchKind kind;
  final String target;
  final RiskTier risk;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'kind': kind.wire,
        'target': target,
        'risk': risk.wire,
      };
}

/// Allowlisted workflow entry in `host-policy.json`.
class WorkflowConfig {
  WorkflowConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.target,
    required this.risk,
  }) {
    if (!isValidShortId(id)) {
      throw FormatException('Invalid workflow id: $id');
    }
    if (name.isEmpty || name.length > 80) {
      throw const FormatException('Workflow name must be 1..80 characters');
    }
    if (target.trim().isEmpty) {
      throw const FormatException('Workflow target must not be empty');
    }
    if (risk < RiskTier.r1 || risk > RiskTier.r3) {
      throw const FormatException('Workflow risk must be R1, R2 or R3');
    }
  }

  factory WorkflowConfig.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'id', 'name', 'kind', 'target', 'risk'},
      context: 'WorkflowConfig',
    );
    return WorkflowConfig(
      id: _requireString(json, 'id'),
      name: _requireString(json, 'name'),
      kind: WorkflowKind.fromWire(_requireString(json, 'kind')),
      target: _requireString(json, 'target'),
      risk: RiskTier.fromWire(_requireString(json, 'risk')),
    );
  }

  final String id;
  final String name;
  final WorkflowKind kind;
  final String target;
  final RiskTier risk;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'kind': kind.wire,
        'target': target,
        'risk': risk.wire,
      };
}

/// Transport protocol for an opt-in local protocol harness (`AW2-M1`).
enum ProtocolHarnessProtocol {
  mcpStdio('mcp_stdio'),
  acpStdio('acp_stdio');

  const ProtocolHarnessProtocol(this.wire);
  final String wire;

  static ProtocolHarnessProtocol fromWire(String value) => switch (value) {
        'mcp_stdio' => ProtocolHarnessProtocol.mcpStdio,
        'acp_stdio' => ProtocolHarnessProtocol.acpStdio,
        _ => throw FormatException('Unknown ProtocolHarnessProtocol: $value'),
      };
}

/// Local-only allowlisted MCP/ACP stdio harness entry in `host-policy.json`
/// (`AW2-M1`). Never serialized to remote wire (`xuna/get_policy` /
/// `mcp.list_servers`) with `executable` or `args`, and never writable remotely
/// via `xuna/set_policy`.
class ProtocolHarnessConfig {
  ProtocolHarnessConfig({
    required this.id,
    required this.name,
    required this.protocol,
    required this.executable,
    List<String> args = const <String>[],
    this.risk = RiskTier.r2,
  }) : args = List<String>.unmodifiable(args) {
    if (!isValidShortId(id)) {
      throw FormatException('Invalid protocol harness id: $id');
    }
    if (name.trim().isEmpty || name.length > 80) {
      throw const FormatException(
        'Protocol harness name must be 1..80 characters',
      );
    }
    if (isForbiddenProtocolHarnessExecutable(executable)) {
      throw FormatException(
        'Protocol harness executable is forbidden: $executable',
      );
    }
    if (this.args.length > 16) {
      throw const FormatException(
        'Protocol harness args must have 0..16 items',
      );
    }
    for (final arg in this.args) {
      if (arg.isEmpty ||
          arg.length > 256 ||
          hasBinaryOrInvalidSurrogates(arg) ||
          arg.contains('\n') ||
          arg.contains('\r')) {
        throw const FormatException(
          'Protocol harness args items must be 1..256 chars without control characters',
        );
      }
    }
    if (hasForbiddenHarnessInlineEvalArg(executable, this.args)) {
      throw const FormatException(
        'Protocol harness inline eval args are forbidden',
      );
    }
    if (risk != RiskTier.r2 && risk != RiskTier.r3) {
      throw const FormatException(
        'Protocol harness risk in host-policy.json must be R2 or R3',
      );
    }
  }

  factory ProtocolHarnessConfig.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'id', 'name', 'protocol', 'executable', 'risk'},
      optionalKeys: const <String>{'args'},
      context: 'ProtocolHarnessConfig',
    );
    final rawArgs = json['args'];
    final parsedArgs = <String>[];
    if (rawArgs != null) {
      if (rawArgs is! List) {
        throw const FormatException(
          'Protocol harness "args" must be a list of strings',
        );
      }
      for (final item in rawArgs) {
        if (item is! String) {
          throw const FormatException(
            'Protocol harness "args" items must be strings',
          );
        }
        parsedArgs.add(item);
      }
    }
    return ProtocolHarnessConfig(
      id: _requireString(json, 'id'),
      name: _requireString(json, 'name'),
      protocol: ProtocolHarnessProtocol.fromWire(
        _requireString(json, 'protocol'),
      ),
      executable: _requireString(json, 'executable'),
      args: parsedArgs,
      risk: RiskTier.fromWire(_requireString(json, 'risk')),
    );
  }

  final String id;
  final String name;
  final ProtocolHarnessProtocol protocol;
  final String executable;
  final List<String> args;
  final RiskTier risk;

  String get mcpListTransport => switch (protocol) {
        ProtocolHarnessProtocol.mcpStdio => 'stdio',
        ProtocolHarnessProtocol.acpStdio => 'acp_stdio',
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'name': name,
        'protocol': protocol.wire,
        'executable': executable,
        'args': args,
        'risk': risk.wire,
      };

  /// Sanitized wire projection omitting `executable`, `args`, `workingDir`, and
  /// `env`.
  Map<String, Object?> toSanitizedWireJson() => <String, Object?>{
        'id': id,
        'name': name,
        'protocol': protocol.wire,
        'risk': risk.wire,
      };
}

/// Trust preset governing autonomous desktop behavior (Wave A R3 / Feature F8).
enum TrustPreset {
  strict('strict'),
  standard('standard'),
  autopilot('autopilot');

  const TrustPreset(this.value);
  final String value;

  static TrustPreset fromValue(String value) {
    for (final preset in values) {
      if (preset.value == value) return preset;
    }
    throw FormatException('Unknown TrustPreset: $value');
  }
}

/// Validated `host-policy.json` model (`UDC-3` §5.6.4).
class HostPolicy {
  HostPolicy({
    this.schemaVersion = 1,
    this.trustPreset = TrustPreset.standard,
    required this.families,
    required this.apps,
    required this.urlDomains,
    required this.workflows,
    required this.players,
    this.denyApps = const <String>[],
    this.denyDomains = const <String>[],
    List<ProtocolHarnessConfig> protocolHarnesses =
        const <ProtocolHarnessConfig>[],
    this.shellControl = const ShellControlPolicy.disabled(),
  }) : protocolHarnesses = List<ProtocolHarnessConfig>.unmodifiable(
          protocolHarnesses,
        ) {
    if (schemaVersion != 1) {
      throw FormatException('Unsupported policy schemaVersion: $schemaVersion');
    }
    final seenHarnesses = <String>{};
    for (final harness in this.protocolHarnesses) {
      if (!seenHarnesses.add(harness.id)) {
        throw FormatException(
          'Duplicate protocol harness id in policy: ${harness.id}',
        );
      }
    }
  }

  factory HostPolicy.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{
        'schemaVersion',
        'families',
        'apps',
        'urlDomains',
        'workflows',
        'players',
      },
      optionalKeys: const <String>{
        'trustPreset',
        'denyApps',
        'denyDomains',
        'protocolHarnesses',
        'shellControl',
      },
      context: 'HostPolicy',
    );
    if (json['schemaVersion'] != 1) {
      throw FormatException(
        'Unsupported policy schemaVersion: ${json['schemaVersion']}',
      );
    }

    final rawPreset = json['trustPreset'];
    final trustPreset = rawPreset != null
        ? (rawPreset is String
            ? TrustPreset.fromValue(rawPreset)
            : throw const FormatException('Expected string for "trustPreset"'))
        : TrustPreset.standard;

    final familiesRaw = _requireMap(json, 'families');
    final families = <ToolFamily, FamilyPolicyDecision>{};
    for (final entry in familiesRaw.entries) {
      final family = ToolFamily.fromWire(entry.key);
      if (entry.value is! String) {
        throw FormatException('Family policy for ${entry.key} must be string');
      }
      families[family] = FamilyPolicyDecision.fromWire(entry.value as String);
    }

    final appsRaw = _requireList(json, 'apps');
    final seenApps = <String>{};
    final apps = <AllowedAppConfig>[];
    for (final item in appsRaw) {
      final app = AllowedAppConfig.fromJson(castPolicyObjectMap(item, 'apps'));
      if (!seenApps.add(app.id)) {
        throw FormatException('Duplicate app id in policy: ${app.id}');
      }
      apps.add(app);
    }

    final domainsRaw = _requireList(json, 'urlDomains');
    final urlDomains = <String>[];
    for (final item in domainsRaw) {
      if (item is! String) {
        throw const FormatException('urlDomains items must be strings');
      }
      final normalized = normalizeDomainAllowlistEntry(item);
      urlDomains.add(normalized);
    }

    final workflowsRaw = _requireList(json, 'workflows');
    final seenWorkflows = <String>{};
    final workflows = <WorkflowConfig>[];
    for (final item in workflowsRaw) {
      final wf =
          WorkflowConfig.fromJson(castPolicyObjectMap(item, 'workflows'));
      if (!seenWorkflows.add(wf.id)) {
        throw FormatException('Duplicate workflow id in policy: ${wf.id}');
      }
      workflows.add(wf);
    }

    final playersRaw = _requireList(json, 'players');
    final players = <String>[];
    for (final item in playersRaw) {
      if (item is! String || !isValidShortId(item)) {
        throw const FormatException('Invalid player id in players');
      }
      players.add(item);
    }

    final denyAppsRaw = json['denyApps'];
    final denyApps = <String>[];
    if (denyAppsRaw != null) {
      if (denyAppsRaw is! List) {
        throw const FormatException('denyApps must be a list');
      }
      for (final item in denyAppsRaw) {
        if (item is! String) {
          throw const FormatException('denyApps items must be strings');
        }
        denyApps.add(item);
      }
    }

    final denyDomainsRaw = json['denyDomains'];
    final denyDomains = <String>[];
    if (denyDomainsRaw != null) {
      if (denyDomainsRaw is! List) {
        throw const FormatException('denyDomains must be a list');
      }
      for (final item in denyDomainsRaw) {
        if (item is! String) {
          throw const FormatException('denyDomains items must be strings');
        }
        denyDomains.add(item);
      }
    }

    final harnessesRaw = json['protocolHarnesses'];
    final seenHarnesses = <String>{};
    final protocolHarnesses = <ProtocolHarnessConfig>[];
    if (harnessesRaw != null) {
      if (harnessesRaw is! List) {
        throw const FormatException('protocolHarnesses must be a list');
      }
      for (final item in harnessesRaw) {
        final harness = ProtocolHarnessConfig.fromJson(
          castPolicyObjectMap(item, 'protocolHarnesses'),
        );
        if (!seenHarnesses.add(harness.id)) {
          throw FormatException(
            'Duplicate protocol harness id in policy: ${harness.id}',
          );
        }
        protocolHarnesses.add(harness);
      }
    }

    final rawShell = json['shellControl'];
    final shellControl = rawShell == null
        ? const ShellControlPolicy.disabled()
        : ShellControlPolicy.fromJson(
            castPolicyObjectMap(rawShell, 'shellControl'),
          );

    return HostPolicy(
      schemaVersion: 1,
      trustPreset: trustPreset,
      families: Map.unmodifiable(families),
      apps: List.unmodifiable(apps),
      urlDomains: List.unmodifiable(urlDomains),
      workflows: List.unmodifiable(workflows),
      players: List.unmodifiable(players),
      denyApps: List.unmodifiable(denyApps),
      denyDomains: List.unmodifiable(denyDomains),
      protocolHarnesses: List.unmodifiable(protocolHarnesses),
      shellControl: shellControl,
    );
  }

  final int schemaVersion;
  final TrustPreset trustPreset;
  final Map<ToolFamily, FamilyPolicyDecision> families;
  final List<AllowedAppConfig> apps;
  final List<String> urlDomains;
  final List<WorkflowConfig> workflows;
  final List<String> players;
  final List<String> denyApps;
  final List<String> denyDomains;
  final List<ProtocolHarnessConfig> protocolHarnesses;

  /// Local-only command execution switch (`ADR-0018`); never set remotely.
  final ShellControlPolicy shellControl;

  bool isFamilyAllowed(ToolFamily family) {
    if (family == ToolFamily.host) {
      return families[ToolFamily.host] != FamilyPolicyDecision.block;
    }
    return families[family] == FamilyPolicyDecision.allow;
  }

  AllowedAppConfig? findApp(String id) {
    for (final app in apps) {
      if (app.id == id) return app;
    }
    return null;
  }

  /// Resolves an owner-allowlisted app by exact ID/name or unique token-prefix
  /// match (e.g. `"antigravity"` -> allowlisted `"antigravity_ide"`). Returns
  /// `null` when ambiguous (`>= 2` matches, Rule H3) so zero-config discovery
  /// does not override an explicitly configured app with a different bundle.
  AllowedAppConfig? findConfiguredAppFuzzy(String query) {
    final clean = query.trim().toLowerCase();
    if (clean.isEmpty) return null;
    final norm = clean
        .replaceAll(RegExp(r'\.(app|exe|lnk|cmd)$'), '')
        .replaceAll(RegExp(r'[^a-z0-9_.-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    if (norm.isEmpty) return null;

    for (final app in apps) {
      if (app.id.toLowerCase() == norm ||
          app.name.trim().toLowerCase() == clean) {
        return app;
      }
    }

    final prefixMatches = <AllowedAppConfig>[];
    for (final app in apps) {
      final idLower = app.id.toLowerCase();
      final nameLower = app.name.trim().toLowerCase();
      final idBoundary = idLower.startsWith('${norm}_') ||
          idLower.startsWith('$norm-') ||
          idLower.startsWith('$norm.');
      final nameBoundary = nameLower.startsWith('$clean ') ||
          nameLower.startsWith('$clean-') ||
          nameLower.startsWith('${clean}_');
      if (idBoundary || nameBoundary) {
        prefixMatches.add(app);
      }
    }
    return prefixMatches.length == 1 ? prefixMatches.first : null;
  }

  /// Returns `true` when [candidate] matches any owner-configured [denyApps]
  /// entry (case-insensitive exact match or basename without `.app`/`.exe`).
  bool isAppDenied(String? candidate) {
    if (candidate == null || denyApps.isEmpty) return false;
    final norm = _normalizeAppToken(candidate);
    if (norm.isEmpty) return false;
    final base = _stripAppExtension(norm);
    for (final entry in denyApps) {
      final deniedNorm = _normalizeAppToken(entry);
      if (deniedNorm.isEmpty) continue;
      final deniedBase = _stripAppExtension(deniedNorm);
      if (norm == deniedNorm || base == deniedBase) {
        return true;
      }
    }
    return false;
  }

  /// Returns `true` when [asciiHost] equals or is a subdomain of any entry in
  /// [denyDomains] (case-insensitive).
  bool isDomainDenied(String? asciiHost) {
    if (asciiHost == null || asciiHost.isEmpty || denyDomains.isEmpty) {
      return false;
    }
    final host = asciiHost.trim().toLowerCase();
    if (host.isEmpty) return false;
    for (final entry in denyDomains) {
      var denied = entry.trim().toLowerCase();
      while (denied.startsWith('.')) {
        denied = denied.substring(1);
      }
      if (denied.isEmpty) continue;
      if (host == denied || host.endsWith('.$denied')) {
        return true;
      }
    }
    return false;
  }

  static String _normalizeAppToken(String raw) {
    var s = raw.trim().toLowerCase().replaceAll(r'\', '/');
    while (s.endsWith('/') && s.length > 1) {
      s = s.substring(0, s.length - 1);
    }
    final slash = s.lastIndexOf('/');
    if (slash != -1 && slash < s.length - 1) {
      s = s.substring(slash + 1);
    }
    return s;
  }

  static String _stripAppExtension(String token) {
    if (token.endsWith('.app') && token.length > 4) {
      return token.substring(0, token.length - 4);
    }
    if (token.endsWith('.exe') && token.length > 4) {
      return token.substring(0, token.length - 4);
    }
    return token;
  }

  WorkflowConfig? findWorkflow(String id) {
    for (final wf in workflows) {
      if (wf.id == id) return wf;
    }
    return null;
  }

  ProtocolHarnessConfig? findProtocolHarness(String id) {
    for (final harness in protocolHarnesses) {
      if (harness.id == id) return harness;
    }
    return null;
  }

  HostPolicy copyWith({
    int? schemaVersion,
    TrustPreset? trustPreset,
    Map<ToolFamily, FamilyPolicyDecision>? families,
    List<AllowedAppConfig>? apps,
    List<String>? urlDomains,
    List<WorkflowConfig>? workflows,
    List<String>? players,
    List<String>? denyApps,
    List<String>? denyDomains,
    List<ProtocolHarnessConfig>? protocolHarnesses,
    ShellControlPolicy? shellControl,
  }) =>
      HostPolicy(
        schemaVersion: schemaVersion ?? this.schemaVersion,
        trustPreset: trustPreset ?? this.trustPreset,
        families: families ?? this.families,
        apps: apps ?? this.apps,
        urlDomains: urlDomains ?? this.urlDomains,
        workflows: workflows ?? this.workflows,
        players: players ?? this.players,
        denyApps: denyApps ?? this.denyApps,
        denyDomains: denyDomains ?? this.denyDomains,
        protocolHarnesses: protocolHarnesses ?? this.protocolHarnesses,
        shellControl: shellControl ?? this.shellControl,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'trustPreset': trustPreset.value,
        'families': <String, Object?>{
          for (final entry in families.entries)
            entry.key.wire: entry.value.wire,
        },
        'apps': apps.map((a) => a.toJson()).toList(),
        'urlDomains': urlDomains,
        'workflows': workflows.map((w) => w.toJson()).toList(),
        'players': players,
        'denyApps': denyApps,
        'denyDomains': denyDomains,
        'protocolHarnesses': protocolHarnesses.map((h) => h.toJson()).toList(),
        'shellControl': shellControl.toJson(),
      };
}

/// Decision returned by `HostPolicyEvaluator.evaluateInvocation`.
class PolicyEvaluationResult {
  const PolicyEvaluationResult({
    required this.allowed,
    required this.status,
    required this.effectiveRisk,
    this.errorCode,
    this.app,
    this.workflow,
    this.normalizedUrlHost,
    this.reasonCode,
  });

  final bool allowed;
  final XtpStatus status;
  final RiskTier effectiveRisk;
  final String? errorCode;
  final AllowedAppConfig? app;
  final WorkflowConfig? workflow;
  final String? normalizedUrlHost;

  /// Optional machine-readable reason for [effectiveRisk] or the refusal
  /// (`xuna/preflight.reasonCode`), e.g. `outside_workspace`.
  final String? reasonCode;
}

/// Casts [raw] to `Map<String, Object?>`, throwing [FormatException] on
/// non-map values or non-string keys.
Map<String, Object?> castPolicyObjectMap(Object? raw, String context) {
  if (raw is! Map) {
    throw FormatException('Expected object in $context');
  }
  final out = <String, Object?>{};
  for (final entry in raw.entries) {
    if (entry.key is! String) {
      throw FormatException('Expected string key in $context');
    }
    out[entry.key as String] = entry.value;
  }
  return out;
}

void _requireExactKeys(
  Map<String, Object?> map,
  Set<String> requiredKeys, {
  Set<String> optionalKeys = const <String>{},
  required String context,
}) {
  for (final req in requiredKeys) {
    if (!map.containsKey(req)) {
      throw FormatException('Missing required key "$req" in $context');
    }
  }
  for (final key in map.keys) {
    if (!requiredKeys.contains(key) && !optionalKeys.contains(key)) {
      throw FormatException('Unexpected key "$key" in $context');
    }
  }
}

String _requireString(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! String) {
    throw FormatException('Expected string for "$key"');
  }
  return value;
}

Map<String, Object?> _requireMap(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) {
    throw FormatException('Expected object for "$key"');
  }
  return castPolicyObjectMap(value, key);
}

List<Object?> _requireList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) {
    throw FormatException('Expected array for "$key"');
  }
  return value;
}

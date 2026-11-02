import '../schemas.dart';
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

/// Validated `host-policy.json` model (`UDC-3` §5.6.4).
class HostPolicy {
  HostPolicy({
    this.schemaVersion = 1,
    required this.families,
    required this.apps,
    required this.urlDomains,
    required this.workflows,
    required this.players,
  }) {
    if (schemaVersion != 1) {
      throw FormatException('Unsupported policy schemaVersion: $schemaVersion');
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
      context: 'HostPolicy',
    );
    if (json['schemaVersion'] != 1) {
      throw FormatException(
        'Unsupported policy schemaVersion: ${json['schemaVersion']}',
      );
    }

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
      final wf = WorkflowConfig.fromJson(castPolicyObjectMap(item, 'workflows'));
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

    return HostPolicy(
      schemaVersion: 1,
      families: Map.unmodifiable(families),
      apps: List.unmodifiable(apps),
      urlDomains: List.unmodifiable(urlDomains),
      workflows: List.unmodifiable(workflows),
      players: List.unmodifiable(players),
    );
  }

  final int schemaVersion;
  final Map<ToolFamily, FamilyPolicyDecision> families;
  final List<AllowedAppConfig> apps;
  final List<String> urlDomains;
  final List<WorkflowConfig> workflows;
  final List<String> players;

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

  WorkflowConfig? findWorkflow(String id) {
    for (final wf in workflows) {
      if (wf.id == id) return wf;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'schemaVersion': schemaVersion,
        'families': <String, Object?>{
          for (final entry in families.entries)
            entry.key.wire: entry.value.wire,
        },
        'apps': apps.map((a) => a.toJson()).toList(),
        'urlDomains': urlDomains,
        'workflows': workflows.map((w) => w.toJson()).toList(),
        'players': players,
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
  });

  final bool allowed;
  final XtpStatus status;
  final RiskTier effectiveRisk;
  final String? errorCode;
  final AllowedAppConfig? app;
  final WorkflowConfig? workflow;
  final String? normalizedUrlHost;
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
  required String context,
}) {
  for (final req in requiredKeys) {
    if (!map.containsKey(req)) {
      throw FormatException('Missing required key "$req" in $context');
    }
  }
  for (final key in map.keys) {
    if (!requiredKeys.contains(key)) {
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

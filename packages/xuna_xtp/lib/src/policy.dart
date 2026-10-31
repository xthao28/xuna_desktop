import 'dart:convert';
import 'dart:typed_data';

import 'canonical_json.dart';
import 'crypto.dart';
import 'schemas.dart';

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
      final app = AllowedAppConfig.fromJson(_castObjectMap(item, 'apps'));
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
      final wf = WorkflowConfig.fromJson(_castObjectMap(item, 'workflows'));
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

/// Decision returned by [HostPolicyEvaluator.evaluateInvocation].
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

/// Fail-closed evaluator for `host-policy.json` (`UDC-3` §5.6.4–§5.6.5).
///
/// When constructed from a missing, unreadable or invalid policy file,
/// [isHealthy] is `false`, [trayBanner] is `'Cấu hình lỗi'`, and every tool
/// except `host.status` is denied (`policy_invalid`).
class HostPolicyEvaluator {
  const HostPolicyEvaluator.healthy(this.policy)
      : isHealthy = true,
        loadError = null;

  const HostPolicyEvaluator.corrupted([this.loadError = 'invalid_policy_file'])
      : policy = null,
        isHealthy = false;

  /// Parses [jsonText] into a [HostPolicyEvaluator]; any parse or schema
  /// error returns a fail-closed [HostPolicyEvaluator.corrupted] instance.
  factory HostPolicyEvaluator.fromJsonString(String? jsonText) {
    if (jsonText == null || jsonText.trim().isEmpty) {
      return const HostPolicyEvaluator.corrupted('missing_or_empty_policy');
    }
    try {
      final decoded = jsonDecode(jsonText);
      if (decoded is! Map) {
        return const HostPolicyEvaluator.corrupted('policy_not_an_object');
      }
      final map = _castObjectMap(decoded, 'HostPolicy');
      return HostPolicyEvaluator.healthy(HostPolicy.fromJson(map));
    } catch (error) {
      return HostPolicyEvaluator.corrupted(error.toString());
    }
  }

  final HostPolicy? policy;
  final bool isHealthy;
  final String? loadError;

  /// Tray status label when the policy file is corrupted (`UDC-3` §5.6.4).
  String? get trayBanner => isHealthy ? null : 'Cấu hình lỗi';

  /// Evaluates a `tools/call` invocation following the normative order in
  /// `UDC-3` §5.6.5 and `UDC-8` §4.2:
  /// 1. `host.status` is always allowed if arguments are `{}` (even when
  ///    policy is corrupted or e-stop is active).
  /// 2. If suspended by e-stop (`isStopped == true`), deny with `stopped`.
  /// 3. Validate tool arguments against schema/URL rules (`invalid_args`).
  /// 4. Check fail-closed policy health and family/entry allowlist (`denied`).
  /// 5. If effective risk `>= R2` (or `>= R3` inside an active computer-use
  ///    session), verify `approval` is present, unexpired at [nowUtc], and
  ///    `approval.argsSha256 == argsSha256(arguments)`.
  PolicyEvaluationResult evaluateInvocation({
    required String toolName,
    required Map<String, Object?> arguments,
    ApprovalToken? approval,
    bool isStopped = false,
    DateTime? nowUtc,
    String? hostId,
    List<Uint8List> pinnedPhonePublicKeys = const <Uint8List>[],
    bool isInApprovedCuSession = false,
    bool allowZeroConfigAppDiscovery = false,
  }) {
    final now = (nowUtc ?? DateTime.now()).toUtc();
    ToolDescriptor.validateToolName(toolName);

    if (toolName == 'host.status') {
      if (arguments.isNotEmpty) {
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.invalidArgs,
          effectiveRisk: RiskTier.r0,
          errorCode: 'schema_mismatch',
        );
      }
      return const PolicyEvaluationResult(
        allowed: true,
        status: XtpStatus.ok,
        effectiveRisk: RiskTier.r0,
      );
    }

    if (isStopped) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'stopped',
      );
    }

    if (!isHealthy || policy == null) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'policy_invalid',
      );
    }

    final activePolicy = policy!;
    final prefix = toolName.split('.').first;
    final family = (prefix == 'browser' || toolName == 'tv.cast_media')
        ? ToolFamily.url
        : (toolName == 'tv.list_devices' || toolName == 'tv.control')
            ? ToolFamily.media
            : (prefix == 'display' ||
                    prefix == 'workspace' ||
                    prefix == 'selection' ||
                    prefix == 'mcp' ||
                    prefix == 'window' ||
                    prefix == 'beam' ||
                    prefix == 'action' ||
                    prefix == 'smarthome' ||
                    toolName == 'tv.launch_app')
                ? ToolFamily.app
                : ToolFamily.fromWire(prefix);
    if (!activePolicy.isFamilyAllowed(family)) {
      return const PolicyEvaluationResult(
        allowed: false,
        status: XtpStatus.denied,
        effectiveRisk: RiskTier.r1,
        errorCode: 'policy_blocked',
      );
    }

    late final RiskTier effectiveRisk;
    AllowedAppConfig? matchedApp;
    WorkflowConfig? matchedWorkflow;
    String? normalizedUrlHost;

    switch (toolName) {
      case 'media.play_pause':
      case 'media.next':
      case 'media.previous':
        if (arguments.isNotEmpty) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'media.now_playing':
        if (arguments.isNotEmpty) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r0,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r0;
      case 'media.volume_set':
        if (arguments.length != 1 || arguments['level'] is! int) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        final level = arguments['level'] as int;
        if (level < 0 || level > 100) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'app.list_allowed':
      case 'workflow.list':
        if (arguments.isNotEmpty) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r0,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r0;
      case 'app.launch':
        if (arguments.length != 1 || arguments['id'] is! String) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        final appId = arguments['id'] as String;
        if (!isValidShortId(appId)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        if (isHardDeniedAppOrProcess(appId)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'denylisted_target_forbidden',
          );
        }
        matchedApp = activePolicy.findApp(appId);
        if (matchedApp == null) {
          if (!allowZeroConfigAppDiscovery) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r2,
              errorCode: 'policy_blocked',
            );
          }
          effectiveRisk = RiskTier.r2;
        } else {
          effectiveRisk =
              matchedApp.risk >= RiskTier.r2 ? matchedApp.risk : RiskTier.r2;
        }
      case 'display.wake':
        if (arguments.isNotEmpty) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'workspace.git_summary':
      case 'workspace.watch_task':
        final proj = arguments['project'];
        if (arguments.length != 1 ||
            proj is! String ||
            !isValidWorkspaceQuery(proj)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'selection.read':
      case 'window.active_context':
        final maxChars = arguments['maxChars'];
        if (arguments.keys.any((k) => k != 'maxChars') ||
            (maxChars != null &&
                (maxChars is! int || maxChars < 80 || maxChars > 1200))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'host.lock_screen':
      case 'mcp.list_servers':
      case 'action.undo':
      case 'tv.list_devices':
        if (arguments.isNotEmpty) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'tv.control':
        final device = arguments['device'];
        final action = arguments['action'];
        final level = arguments['level'];
        const allowedTvCtrlKeys = <String>{'device', 'action', 'level'};
        if (arguments.keys.any((k) => !allowedTvCtrlKeys.contains(k)) ||
            action is! String ||
            !allowedTvActions.contains(action) ||
            (device != null &&
                (device is! String || !isValidTvDeviceQuery(device))) ||
            (level != null && (level is! int || level < 0 || level > 100)) ||
            (action == 'volume_set' && level == null)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'tv.launch_app':
        final device = arguments['device'];
        final appId = arguments['appId'];
        const allowedTvLaunchKeys = <String>{'device', 'appId'};
        if (arguments.keys.any((k) => !allowedTvLaunchKeys.contains(k)) ||
            appId is! String ||
            !allowedTvAppIds.contains(appId) ||
            (device != null &&
                (device is! String || !isValidTvDeviceQuery(device)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'tv.cast_media':
        final device = arguments['device'];
        final rawUrl = arguments['url'];
        final title = arguments['title'];
        const allowedCastKeys = <String>{'device', 'url', 'title'};
        if (arguments.keys.any((k) => !allowedCastKeys.contains(k)) ||
            rawUrl is! String ||
            (device != null &&
                (device is! String || !isValidTvDeviceQuery(device))) ||
            (title != null &&
                (title is! String ||
                    title.length > 120 ||
                    !isSafeAgentPrompt(title)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        if (!isAllowedHttpsCurrentUrl(rawUrl)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'url_invalid',
          );
        }
        normalizedUrlHost = Uri.parse(rawUrl.trim()).host.toLowerCase();
        effectiveRisk = RiskTier.r2;
      case 'smarthome.list_entities':
        final domain = arguments['domain'];
        if (arguments.keys.any((k) => k != 'domain')) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        if (domain != null) {
          if (domain is! String) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r1,
              errorCode: 'schema_mismatch',
            );
          }
          if (hardDeniedSmartHomeDomains.contains(domain.toLowerCase())) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r1,
              errorCode: 'smarthome_domain_forbidden',
            );
          }
          if (!allowedSmartHomeDomains.contains(domain)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r1,
              errorCode: 'schema_mismatch',
            );
          }
        }
        effectiveRisk = RiskTier.r1;
      case 'smarthome.control':
        final entityId = arguments['entityId'];
        final action = arguments['action'];
        final value = arguments['value'];
        const allowedShKeys = <String>{'entityId', 'action', 'value'};
        if (arguments.keys.any((k) => !allowedShKeys.contains(k)) ||
            entityId is! String ||
            action is! String ||
            !allowedSmartHomeActions.contains(action) ||
            (value != null && (value is! int || value < 0 || value > 100))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        if (isHardDeniedSmartHomeEntity(entityId)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'smarthome_domain_forbidden',
          );
        }
        if (!isValidSmartHomeEntityId(entityId)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'beam.transfer':
        final direction = arguments['direction'];
        final kind = arguments['kind'];
        final fileName = arguments['fileName'];
        final sizeBytes = arguments['sizeBytes'];
        final sha256 = arguments['sha256'];
        final dataBase64 = arguments['dataBase64'];
        const allowedBeamKeys = <String>{
          'direction',
          'kind',
          'fileName',
          'sizeBytes',
          'sha256',
          'dataBase64',
        };
        if (arguments.keys.any((k) => !allowedBeamKeys.contains(k)) ||
            direction is! String ||
            !<String>{'phone_to_desktop', 'desktop_to_phone'}
                .contains(direction) ||
            kind is! String ||
            !<String>{'clipboard_text', 'screenshot', 'file'}.contains(kind) ||
            fileName is! String ||
            !isValidBeamFileName(fileName) ||
            sizeBytes is! int ||
            sizeBytes < 1 ||
            sizeBytes > 26214400 ||
            sha256 is! String ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256) ||
            (dataBase64 != null &&
                (dataBase64 is! String || dataBase64.isEmpty))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'mcp.call':
        final server = arguments['server'];
        final tool = arguments['tool'];
        final payloadJson = arguments['payloadJson'];
        const allowedMcpKeys = <String>{'server', 'tool', 'payloadJson'};
        if (server is! String ||
            !isValidShortId(server) ||
            tool is! String ||
            !RegExp(r'^[a-zA-Z0-9_.-]{1,64}$').hasMatch(tool) ||
            arguments.keys.any((k) => !allowedMcpKeys.contains(k)) ||
            (payloadJson != null &&
                (payloadJson is! String ||
                    payloadJson.length > 1000 ||
                    !isSafeAgentPrompt(payloadJson)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'workspace.open':
        final proj = arguments['project'];
        final ide = arguments['ide'];
        if (proj is! String ||
            !isValidWorkspaceQuery(proj) ||
            arguments.keys
                .any((k) => k != 'project' && k != 'ide') ||
            (ide != null &&
                (ide is! String || !supportedWorkspaceIdes.contains(ide)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'workspace.coding_agent':
        final proj = arguments['project'];
        final agent = arguments['agent'];
        final resumeLast = arguments['resumeLast'];
        final prompt = arguments['prompt'];
        const allowedKeys = <String>{
          'project',
          'agent',
          'resumeLast',
          'prompt',
        };
        if (proj is! String ||
            !isValidWorkspaceQuery(proj) ||
            arguments.keys.any((k) => !allowedKeys.contains(k)) ||
            (agent != null &&
                (agent is! String || !supportedCodingAgents.contains(agent))) ||
            (resumeLast != null && resumeLast is! bool) ||
            (prompt != null &&
                (prompt is! String || !isSafeAgentPrompt(prompt)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'url.open':
        if (arguments.length != 1 || arguments['url'] is! String) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        final rawUrl = arguments['url'] as String;
        final urlCheck = validateHttpsUrlAgainstAllowlist(
          rawUrl,
          activePolicy.urlDomains,
        );
        if (!urlCheck.validUrl) {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: urlCheck.errorCode ?? 'url_invalid',
          );
        }
        if (!urlCheck.domainAllowed) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'domain_not_allowed',
          );
        }
        normalizedUrlHost = urlCheck.asciiHost;
        effectiveRisk = RiskTier.r2;
      case 'browser.current_url':
        if (arguments.length > 1 ||
            (arguments.containsKey('browser') &&
                (arguments['browser'] is! String ||
                    !<String>{'auto', 'edge', 'chrome', 'safari'}
                        .contains(arguments['browser'] as String)))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'browser.read_page':
        final browser = arguments['browser'];
        final maxChars = arguments['maxChars'];
        const allowedReadPageKeys = <String>{'browser', 'maxChars'};
        if (arguments.keys.any((k) => !allowedReadPageKeys.contains(k)) ||
            (browser != null &&
                (browser is! String ||
                    !<String>{'auto', 'edge', 'chrome', 'safari'}
                        .contains(browser))) ||
            (maxChars != null &&
                (maxChars is! int || maxChars < 80 || maxChars > 1600))) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'workflow.run':
        if (arguments.length != 1 || arguments['id'] is! String) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        final wfId = arguments['id'] as String;
        if (!isValidShortId(wfId)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        matchedWorkflow = activePolicy.findWorkflow(wfId);
        if (matchedWorkflow == null) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r1,
            errorCode: 'policy_blocked',
          );
        }
        effectiveRisk = matchedWorkflow.risk;
      case 'workflow.batch_steps':
        final steps = arguments['steps'];
        if (arguments.length != 1 ||
            steps is! List ||
            steps.isEmpty ||
            steps.length > 5) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        for (final rawStep in steps) {
          if (rawStep is! Map) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r2,
              errorCode: 'schema_mismatch',
            );
          }
          if (rawStep.length != 2 ||
              !rawStep.containsKey('tool') ||
              !rawStep.containsKey('arguments') ||
              rawStep['tool'] is! String ||
              rawStep['arguments'] is! Map) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r2,
              errorCode: 'schema_mismatch',
            );
          }
          final stepTool = rawStep['tool'] as String;
          if (stepTool == 'workflow.batch_steps' ||
              stepTool.startsWith('cu.') ||
              stepTool.startsWith('screen.') ||
              stepTool.startsWith('ui.') ||
              stepTool.startsWith('input.')) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r3,
              errorCode: 'batch_r3_forbidden',
            );
          }
          try {
            ToolDescriptor.validateToolName(stepTool);
          } on FormatException {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r2,
              errorCode: 'schema_mismatch',
            );
          }
          final stepArgs = _castObjectMap(rawStep['arguments'], 'batch_step');
          final syntheticApproval = ApprovalToken(
            approvalId: 'a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c99',
            scope: 'once',
            expiresAt: now.add(const Duration(minutes: 5)),
            argsSha256: argsSha256(stepArgs),
          );
          final stepEval = evaluateInvocation(
            toolName: stepTool,
            arguments: stepArgs,
            approval: syntheticApproval,
            isStopped: isStopped,
            nowUtc: now,
            hostId: hostId,
            pinnedPhonePublicKeys: pinnedPhonePublicKeys,
            isInApprovedCuSession: false,
            allowZeroConfigAppDiscovery: allowZeroConfigAppDiscovery,
          );
          if (stepEval.effectiveRisk >= RiskTier.r3) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r3,
              errorCode: 'batch_r3_forbidden',
            );
          }
          if (!stepEval.allowed) {
            return PolicyEvaluationResult(
              allowed: false,
              status: stepEval.status,
              effectiveRisk: RiskTier.r2,
              errorCode: stepEval.errorCode ?? 'batch_step_rejected',
            );
          }
        }
        effectiveRisk = RiskTier.r2;
      case 'host.notify':
        if (arguments.length != 2 ||
            arguments['title'] is! String ||
            arguments['body'] is! String) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        final title = arguments['title'] as String;
        final body = arguments['body'] as String;
        if (title.isEmpty ||
            title.length > 40 ||
            body.isEmpty ||
            body.length > 120) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r1,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r1;
      case 'cu.session_start':
        final goal = arguments['goal'];
        final apps = arguments['apps'];
        final domains = arguments['domains'];
        final maxSteps = arguments['maxSteps'];
        final maxMinutes = arguments['maxMinutes'];
        if (arguments.length != 5 ||
            goal is! String ||
            goal.trim().isEmpty ||
            goal.length > 200 ||
            apps is! List ||
            domains is! List ||
            maxSteps is! int ||
            maxSteps < 1 ||
            maxSteps > 20 ||
            maxMinutes is! int ||
            maxMinutes < 1 ||
            maxMinutes > 10) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r3,
            errorCode: 'schema_mismatch',
          );
        }
        for (final appItem in apps) {
          if (appItem is! String || !isValidShortId(appItem)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r3,
              errorCode: 'schema_mismatch',
            );
          }
          if (isHardDeniedAppOrProcess(appItem)) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r3,
              errorCode: 'denylisted_target_forbidden',
            );
          }
          if (activePolicy.findApp(appItem) == null) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r3,
              errorCode: 'policy_blocked',
            );
          }
        }
        for (final domainItem in domains) {
          if (domainItem is! String) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r3,
              errorCode: 'schema_mismatch',
            );
          }
          final String asciiDomain;
          try {
            asciiDomain = normalizeDomainAllowlistEntry(domainItem);
          } on FormatException {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.invalidArgs,
              effectiveRisk: RiskTier.r3,
              errorCode: 'url_invalid',
            );
          }
          final domainAllowed = activePolicy.urlDomains.any(
            (allowed) =>
                asciiDomain == allowed || asciiDomain.endsWith('.$allowed'),
          );
          if (!domainAllowed) {
            return const PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: RiskTier.r3,
              errorCode: 'domain_not_allowed',
            );
          }
        }
        effectiveRisk = RiskTier.r3;
      case 'cu.session_end':
        final sessionId = arguments['sessionId'];
        final outcome = arguments['outcome'];
        if (arguments.length != 2 ||
            sessionId is! String ||
            sessionId.isEmpty ||
            sessionId.length > 64 ||
            outcome is! String ||
            !<String>{'completed', 'stopped', 'budget_exceeded', 'failed'}
                .contains(outcome)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r0,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r0;
      case 'screen.capture':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'cu_session_required',
          );
        }
        final scope = arguments['scope'];
        final maxEdge = arguments['maxEdge'];
        if (arguments.length != 2 ||
            scope is! String ||
            !<String>{'active_window', 'screen'}.contains(scope) ||
            maxEdge is! int ||
            maxEdge < 320 ||
            maxEdge > 1280) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'ui.inspect':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'cu_session_required',
          );
        }
        final scope = arguments['scope'];
        final maxNodes = arguments['maxNodes'];
        if (arguments.length != 2 ||
            scope != 'active_window' ||
            maxNodes is! int ||
            maxNodes < 1 ||
            maxNodes > 300) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      case 'input.click':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'cu_session_required',
          );
        }
        final elementId = arguments['elementId'];
        final elementName = arguments['elementName'];
        final x = arguments['x'];
        final y = arguments['y'];
        final hasElement = elementId is String && elementId.isNotEmpty;
        final hasCoords = x is int && y is int;
        if ((!hasElement && !hasCoords) ||
            (elementName != null && elementName is! String)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = isConsequentialElementName(elementName as String?)
            ? RiskTier.r3
            : RiskTier.r2;
      case 'input.type_text':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r3,
            errorCode: 'cu_session_required',
          );
        }
        final elementId = arguments['elementId'];
        final text = arguments['text'];
        final elementName = arguments['elementName'];
        if (elementId is! String ||
            elementId.isEmpty ||
            elementId.length > 64 ||
            text is! String ||
            text.isEmpty ||
            text.length > 200 ||
            (elementName != null && elementName is! String)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r3,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r3;
      case 'input.key':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'cu_session_required',
          );
        }
        final combo = arguments['combo'];
        final inForm = arguments['inForm'];
        if (combo is! String ||
            !allowedInputKeyCombos.contains(combo) ||
            (inForm != null && inForm is! bool)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = (combo == 'Enter' && inForm == true)
            ? RiskTier.r3
            : RiskTier.r2;
      case 'input.scroll':
        if (!isInApprovedCuSession) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: RiskTier.r2,
            errorCode: 'cu_session_required',
          );
        }
        final direction = arguments['direction'];
        final amount = arguments['amount'];
        final elementId = arguments['elementId'];
        if (direction is! String ||
            !<String>{'up', 'down', 'left', 'right'}.contains(direction) ||
            amount is! int ||
            amount < 1 ||
            amount > 10 ||
            (elementId != null && elementId is! String)) {
          return const PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.invalidArgs,
            effectiveRisk: RiskTier.r2,
            errorCode: 'schema_mismatch',
          );
        }
        effectiveRisk = RiskTier.r2;
      default:
        return const PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.unsupported,
          effectiveRisk: RiskTier.r1,
          errorCode: 'platform_unsupported',
        );
    }

    // UDC-8 §4.2: Inside an already-approved computer-use session, R2
    // observation/input tools do not require per-call approval; R3 tools
    // ALWAYS require a phone-signed single-use approval.
    final requiresApproval = isInApprovedCuSession &&
            const <ToolFamily>{
              ToolFamily.screen,
              ToolFamily.ui,
              ToolFamily.input,
            }.contains(family)
        ? effectiveRisk >= RiskTier.r3
        : effectiveRisk >= RiskTier.r2;

    if (requiresApproval) {
      if (approval == null) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_required',
        );
      }
      if (approval.isExpiredAt(now)) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_expired',
        );
      }
      final computedHash = argsSha256(arguments);
      if (approval.argsSha256 != computedHash) {
        return PolicyEvaluationResult(
          allowed: false,
          status: XtpStatus.denied,
          effectiveRisk: effectiveRisk,
          errorCode: 'approval_mismatch',
        );
      }
      if (effectiveRisk >= RiskTier.r3) {
        if (approval.scope != 'once') {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'r3_requires_once_scope',
          );
        }
        // UDC-7 S7.5: Verify phone-signed approval for R3 tools against
        // enrolled owner phone keys; reject missing or invalid signatures.
        final sig = approval.signature;
        if (sig == null ||
            hostId == null ||
            hostId.isEmpty ||
            pinnedPhonePublicKeys.isEmpty) {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'approval_signature_invalid',
          );
        }
        final proofMsg = approvalProofMessage(
          approvalId: approval.approvalId,
          argsSha256: approval.argsSha256,
          hostId: hostId,
          expiresAt: approval.expiresAtWire,
        );
        final candidateKeys = <Uint8List>[];
        if (approval.publicKey != null) {
          final hasMatch = pinnedPhonePublicKeys.any(
            (k) => _bytesEqual(k, approval.publicKey!),
          );
          if (!hasMatch) {
            return PolicyEvaluationResult(
              allowed: false,
              status: XtpStatus.denied,
              effectiveRisk: effectiveRisk,
              errorCode: 'approval_signature_invalid',
            );
          }
          candidateKeys.add(approval.publicKey!);
        } else {
          candidateKeys.addAll(pinnedPhonePublicKeys);
        }
        if (candidateKeys.isEmpty ||
            !candidateKeys.any(
              (k) => verifyP256Signature(
                publicKey: k,
                message: proofMsg,
                signature: sig,
              ),
            )) {
          return PolicyEvaluationResult(
            allowed: false,
            status: XtpStatus.denied,
            effectiveRisk: effectiveRisk,
            errorCode: 'approval_signature_invalid',
          );
        }
      }
    }

    return PolicyEvaluationResult(
      allowed: true,
      status: XtpStatus.ok,
      effectiveRisk: effectiveRisk,
      app: matchedApp,
      workflow: matchedWorkflow,
      normalizedUrlHost: normalizedUrlHost,
    );
  }
}

/// Validates and normalizes an entry in `host-policy.json` `urlDomains`.
String normalizeDomainAllowlistEntry(String domain) {
  final trimmed = domain.trim().toLowerCase();
  if (trimmed.isEmpty ||
      trimmed.startsWith('.') ||
      trimmed.endsWith('.') ||
      trimmed.contains('/')) {
    throw FormatException('Invalid domain in urlDomains: $domain');
  }
  final asciiHost = idnToAscii(trimmed);
  if (_isForbiddenLiteralOrLocalHost(asciiHost)) {
    throw FormatException('Forbidden local/IP domain in urlDomains: $domain');
  }
  return asciiHost;
}

/// Result of validating a URL for `url.open` (`XUNA_XTP_V1_CONTRACT.md` §6).
typedef UrlValidationResult = ({
  bool validUrl,
  bool domainAllowed,
  String? asciiHost,
  String? errorCode,
});

/// Validates [rawUrl] per `XUNA_XTP_V1_CONTRACT.md` §6:
/// 1. `https` scheme only (case-insensitive)
/// 2. Length `<= 2048` and no `userinfo` (`user:pass@`)
/// 3. Hostname converted from IDN to ASCII punycode (`xn--...`)
/// 4. Reject IPv4 literals, IPv6 literals, `localhost`, `.local`, `.localhost`
/// 5. ASCII hostname equals or is a `.`-bounded subdomain of an entry in
///    [allowedDomains].
UrlValidationResult validateHttpsUrlAgainstAllowlist(
  String rawUrl,
  List<String> allowedDomains,
) {
  if (rawUrl.isEmpty || rawUrl.length > 2048) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  // Extract raw authority to detect unicode hostnames before Uri.tryParse
  final schemeSep = rawUrl.indexOf('://');
  if (schemeSep <= 0) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  final scheme = rawUrl.substring(0, schemeSep).toLowerCase();
  if (scheme != 'https') {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  final afterScheme = rawUrl.substring(schemeSep + 3);
  final slashIdx = afterScheme.indexOf('/');
  final queryIdx = afterScheme.indexOf('?');
  final hashIdx = afterScheme.indexOf('#');
  var authorityEnd = afterScheme.length;
  for (final idx in <int>[slashIdx, queryIdx, hashIdx]) {
    if (idx != -1 && idx < authorityEnd) {
      authorityEnd = idx;
    }
  }
  final authority = afterScheme.substring(0, authorityEnd);
  if (authority.isEmpty || authority.contains('@')) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  if (authority.startsWith('[')) {
    // IPv6 literal
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }
  var rawHost = authority;
  final colonIdx = authority.indexOf(':');
  if (colonIdx != -1) {
    final portStr = authority.substring(colonIdx + 1);
    final port = int.tryParse(portStr);
    if (port == null || port <= 0 || port > 65535) {
      return (
        validUrl: false,
        domainAllowed: false,
        asciiHost: null,
        errorCode: 'url_invalid',
      );
    }
    rawHost = authority.substring(0, colonIdx);
  }
  if (rawHost.isEmpty || rawHost.endsWith('.')) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  final String asciiHost;
  try {
    asciiHost = idnToAscii(rawHost);
  } on FormatException {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  if (_isForbiddenLiteralOrLocalHost(asciiHost)) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  // Verify the normalized URL also parses cleanly as a standard URI.
  final normalizedUrl =
      'https://$asciiHost${colonIdx != -1 ? authority.substring(colonIdx) : ''}${afterScheme.substring(authorityEnd)}';
  final parsed = Uri.tryParse(normalizedUrl);
  if (parsed == null ||
      parsed.scheme != 'https' ||
      parsed.userInfo.isNotEmpty) {
    return (
      validUrl: false,
      domainAllowed: false,
      asciiHost: null,
      errorCode: 'url_invalid',
    );
  }

  var matched = false;
  for (final entry in allowedDomains) {
    final allowed = entry.toLowerCase();
    if (asciiHost == allowed || asciiHost.endsWith('.$allowed')) {
      matched = true;
      break;
    }
  }

  return (
    validUrl: true,
    domainAllowed: matched,
    asciiHost: asciiHost,
    errorCode: matched ? null : 'domain_not_allowed',
  );
}

/// Returns `true` if [rawUrl] is a valid public `https://` URL (rejecting
/// `http://`, `file://`, loopback/private IPs, `localhost`, `.local`).
bool isAllowedHttpsCurrentUrl(String rawUrl) =>
    validateHttpsUrlAgainstAllowlist(rawUrl, const <String>[]).validUrl;

bool _isForbiddenLiteralOrLocalHost(String host) {
  final lower = host.toLowerCase();
  if (lower == 'localhost' ||
      lower.endsWith('.localhost') ||
      lower.endsWith('.local')) {
    return true;
  }
  if (lower.contains(':')) {
    return true;
  }
  final parts = lower.split('.');
  if (parts.length == 4 &&
      parts.every((p) => RegExp(r'^[0-9]{1,3}$').hasMatch(p))) {
    return true;
  }
  // Reject numeric-only TLD or single-label hostnames
  if (parts.length < 2 || RegExp(r'^[0-9]+$').hasMatch(parts.last)) {
    return true;
  }
  return false;
}

/// Converts a domain name (potentially containing Unicode IDN labels) into
/// lower-case ASCII punycode (`xn--...`) per RFC 3492.
String idnToAscii(String domain) {
  final labels = domain.toLowerCase().split('.');
  if (labels.isEmpty) {
    throw const FormatException('Empty domain');
  }
  final encodedLabels = <String>[];
  for (final label in labels) {
    if (label.isEmpty) {
      throw const FormatException('Empty domain label');
    }
    final isAscii = label.runes.every((r) => r < 0x80);
    final asciiLabel = isAscii ? label : 'xn--${_punycodeEncode(label)}';
    if (asciiLabel.length > 63 ||
        asciiLabel.startsWith('-') ||
        asciiLabel.endsWith('-') ||
        !RegExp(r'^[a-z0-9-]+$').hasMatch(asciiLabel)) {
      throw FormatException('Invalid domain label: $label');
    }
    encodedLabels.add(asciiLabel);
  }
  final joined = encodedLabels.join('.');
  if (joined.length > 253) {
    throw const FormatException('Domain exceeds 253 characters');
  }
  return joined;
}

String _punycodeEncode(String input) {
  const base = 36;
  const tMin = 1;
  const tMax = 26;
  const skew = 38;
  const damp = 700;
  const initialBias = 72;
  const initialN = 0x80;

  final codePoints = input.runes.toList();
  final output = StringBuffer();
  var basicCount = 0;
  for (final cp in codePoints) {
    if (cp < 0x80) {
      output.writeCharCode(cp);
      basicCount++;
    }
  }
  if (basicCount > 0) {
    output.write('-');
  }

  var n = initialN;
  var delta = 0;
  var bias = initialBias;
  var h = basicCount;

  int adapt(int deltaValue, int numPoints, bool firstTime) {
    var d = firstTime ? (deltaValue ~/ damp) : (deltaValue >> 1);
    d += d ~/ numPoints;
    var k = 0;
    while (d > ((base - tMin) * tMax) ~/ 2) {
      d ~/= base - tMin;
      k += base;
    }
    return k + (((base - tMin + 1) * d) ~/ (d + skew));
  }

  int encodeDigit(int d) => d < 26 ? (0x61 + d) : (0x30 + (d - 26));

  while (h < codePoints.length) {
    var m = 0x10ffff + 1;
    for (final cp in codePoints) {
      if (cp >= n && cp < m) {
        m = cp;
      }
    }
    delta += (m - n) * (h + 1);
    n = m;
    for (final cp in codePoints) {
      if (cp < n) {
        delta++;
      } else if (cp == n) {
        var q = delta;
        for (var k = base;; k += base) {
          final t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias);
          if (q < t) break;
          output.writeCharCode(encodeDigit(t + ((q - t) % (base - t))));
          q = (q - t) ~/ (base - t);
        }
        output.writeCharCode(encodeDigit(q));
        bias = adapt(delta, h + 1, h == basicCount);
        delta = 0;
        h++;
      }
    }
    delta++;
    n++;
  }
  return output.toString();
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
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
  return _castObjectMap(value, key);
}

List<Object?> _requireList(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! List) {
    throw FormatException('Expected array for "$key"');
  }
  return value;
}

Map<String, Object?> _castObjectMap(Object? raw, String context) {
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

/// Consequential UI element lexicon (`UDC-8` §4.2) in Vietnamese and English.
/// Clicking an element whose name matches any token here escalates `input.click`
/// from `R2` to `R3` (requiring a phone-signed single-use approval).
const List<String> consequentialElementKeywords = <String>[
  'send',
  'submit',
  'delete',
  'remove',
  'erase',
  'buy',
  'pay',
  'checkout',
  'purchase',
  'post',
  'publish',
  'transfer',
  'wire',
  'confirm payment',
  'place order',
  'gửi',
  'nộp',
  'xóa',
  'xoá',
  'gỡ bỏ',
  'mua',
  'thanh toán',
  'chuyển khoản',
  'đặt hàng',
  'đăng',
  'xuất bản',
];

final RegExp _wordSplitRe = RegExp(
  r'[^a-z0-9àáạảãâầấậẩẫăằắặẳẵèéẹẻẽêềếệểễìíịỉĩòóọỏõôồốộổỗơờớợởỡùúụủũưừứựửữỳýỵỷỹđ]+',
);

/// Returns `true` when [elementName] matches the consequential action lexicon
/// (`send`, `submit`, `delete`, `buy`, `pay`, `post` in Vietnamese or English).
bool isConsequentialElementName(String? elementName) {
  if (elementName == null || elementName.trim().isEmpty) return false;
  final normalized = elementName.trim().toLowerCase();
  final words = normalized
      .split(_wordSplitRe)
      .where((w) => w.isNotEmpty)
      .toSet();
  for (final keyword in consequentialElementKeywords) {
    if (keyword.contains(' ')) {
      if (normalized.contains(keyword)) return true;
    } else if (words.contains(keyword)) {
      return true;
    }
  }
  return false;
}

/// Built-in hard-refusal denylist for computer use (`UDC-8` §4.2):
/// terminals, password managers, banking apps, and system/security settings
/// are refused regardless of the session allowlist.
const Set<String> hardDeniedAppsAndProcesses = <String>{
  // Terminals
  'cmd',
  'cmd.exe',
  'powershell',
  'powershell.exe',
  'pwsh',
  'pwsh.exe',
  'wt',
  'wt.exe',
  'windowsterminal',
  'windowsterminal.exe',
  'terminal',
  'terminal.app',
  'com.apple.terminal',
  'iterm',
  'iterm2',
  'iterm.app',
  'com.googlecode.iterm2',
  'bash',
  'bash.exe',
  'zsh',
  'wsl',
  'wsl.exe',
  'conhost',
  'conhost.exe',
  // Password managers & credential stores
  '1password',
  '1password.exe',
  'com.1password.1password',
  'bitwarden',
  'bitwarden.exe',
  'com.bitwarden.desktop',
  'keepass',
  'keepass.exe',
  'keepassxc',
  'keepassxc.exe',
  'org.keepassxc.keepassxc',
  'lastpass',
  'dashlane',
  'keychain',
  'keychain access',
  'com.apple.keychainaccess',
  // System & security settings
  'systemsettings',
  'systemsettings.exe',
  'control',
  'control.exe',
  'regedit',
  'regedit.exe',
  'mmc',
  'mmc.exe',
  'taskmgr',
  'taskmgr.exe',
  'secpol',
  'secpol.msc',
  'gpedit',
  'gpedit.msc',
  'system settings',
  'system preferences',
  'com.apple.systempreferences',
  'com.apple.settings',
  // Banking / financial keywords
  'banking',
  'vietcombank',
  'techcombank',
  'mbbank',
  'tpbank',
  'vpbank',
  'bidv',
  'agribank',
  'acb',
  'momo',
  'zalopay',
  'vnpay',
};

/// Returns `true` if [appIdOrProcess] is on XUNA's hard-refusal denylist
/// (terminals, password managers, banking apps, or system security panes).
bool isHardDeniedAppOrProcess(String? appIdOrProcess) {
  if (appIdOrProcess == null || appIdOrProcess.trim().isEmpty) return true;
  final raw = appIdOrProcess.trim().toLowerCase();
  final baseName = raw.split(RegExp(r'[/\\]')).last;
  if (hardDeniedAppsAndProcesses.contains(raw) ||
      hardDeniedAppsAndProcesses.contains(baseName)) {
    return true;
  }
  final withoutExt = baseName.endsWith('.exe')
      ? baseName.substring(0, baseName.length - 4)
      : (baseName.endsWith('.app')
          ? baseName.substring(0, baseName.length - 4)
          : baseName);
  if (hardDeniedAppsAndProcesses.contains(withoutExt)) {
    return true;
  }
  return false;
}

/// Returns `true` if a UI node represents a password field (`UDC-8` §4.2).
bool isPasswordUiNode(Map<String, Object?> node) {
  if (node['isPassword'] == true || node['password'] == true) {
    return true;
  }
  final role = (node['role'] as String?)?.toLowerCase() ?? '';
  if (role.contains('password') ||
      role.contains('securetext') ||
      role == 'axsecuretextfield') {
    return true;
  }
  final name = (node['name'] as String?)?.toLowerCase() ?? '';
  if (name.contains('password') ||
      name.contains('mật khẩu') ||
      name.contains('passcode') ||
      name.contains('mã pin')) {
    return true;
  }
  return false;
}

/// Redacts password fields in a list of UI tree nodes (`UDC-8` §4.2):
/// replaces `name` with `'•••'` and removes `value`.
List<Map<String, Object?>> redactUiTreeNodes(
  List<Map<String, Object?>> nodes, {
  int maxNodes = 300,
}) {
  final out = <Map<String, Object?>>[];
  for (final node in nodes) {
    if (out.length >= maxNodes) break;
    final isPwd = isPasswordUiNode(node);
    final rawName = (node['name'] as String?) ?? '';
    final truncatedName = isPwd
        ? '•••'
        : (rawName.length > 60 ? rawName.substring(0, 60) : rawName);
    final redacted = <String, Object?>{
      'id': (node['id'] as String?) ?? '',
      'role': isPwd ? 'password' : ((node['role'] as String?) ?? 'unknown'),
      'name': truncatedName,
      'enabled': node['enabled'] != false,
      if (node['bounds'] is Map) 'bounds': node['bounds'],
      if (isPwd) 'isPassword': true,
    };
    out.add(redacted);
  }
  return out;
}

final RegExp _workspaceQueryRe = RegExp(r'^[a-zA-Z0-9_.\- ]{1,64}$');

/// Validates a project/workspace query string (`UDC-11` S11.2):
/// accepts `1..64` safe name characters and rejects path separators (`/`, `\`),
/// parent traversal (`..`), drive colons (`:`), home expansion (`~`), and shell
/// metacharacters.
bool isValidWorkspaceQuery(String? query) {
  if (query == null) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty || trimmed.length > 64) return false;
  if (trimmed.contains('..')) return false;
  return _workspaceQueryRe.hasMatch(trimmed);
}

/// Validates a continuation prompt passed to `workspace.coding_agent` (`UDC-11` S11.3):
/// accepts `0..500` UTF-8 characters without ASCII control characters (`\x00`..`\x08`,
/// `\x0B`, `\x0C`, `\x0E`..`\x1F`, `\x7F`).
bool isSafeAgentPrompt(String? prompt) {
  if (prompt == null) return false;
  if (prompt.length > 500) return false;
  for (var i = 0; i < prompt.length; i++) {
    final code = prompt.codeUnitAt(i);
    if ((code >= 0x00 && code <= 0x08) ||
        code == 0x0B ||
        code == 0x0C ||
        (code >= 0x0E && code <= 0x1F) ||
        code == 0x7F) {
      return false;
    }
  }
  return true;
}

final List<RegExp> _sensitiveTokenPatterns = <RegExp>[
  RegExp(r'sk-[a-zA-Z0-9_\-]{12,}'),
  RegExp(r'gh[pousr]_[a-zA-Z0-9_]{12,}'),
  RegExp(r'github_pat_[a-zA-Z0-9_]{12,}'),
  RegExp(r'AIza[0-9A-Za-z\-_]{16,}'),
  RegExp(r'xox[baprs]-[a-zA-Z0-9\-]{10,}'),
  RegExp(r'Bearer\s+[a-zA-Z0-9\-._~+/]+=*', caseSensitive: false),
  RegExp(
    r'(?:password|passwd|secret|api_key|apikey|token|access_token)\s*[:=]\s*["\x27]?[^\s"\x27,;]{4,}["\x27]?',
    caseSensitive: false,
  ),
  RegExp(r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----'),
];

/// Result of redacting secrets/tokens in selected or clipboard text (`UDC-12` S12.2).
typedef RedactedSelectionResult = ({
  String text,
  bool truncated,
  int redactedCount,
});

/// Redacts common API keys, Bearer tokens, private keys, and password assignments
/// from [rawText] and truncates the result to [maxChars] (`80..1600`).
RedactedSelectionResult redactSensitiveSelectionText(
  String rawText, {
  int maxChars = 1200,
}) {
  final clampedMax = maxChars < 80 ? 80 : (maxChars > 1600 ? 1600 : maxChars);
  var working = rawText.trim();
  var count = 0;
  for (final pattern in _sensitiveTokenPatterns) {
    working = working.replaceAllMapped(pattern, (_) {
      count++;
      return '[REDACTED]';
    });
  }
  final truncated = working.length > clampedMax;
  final finalString =
      truncated ? working.substring(0, clampedMax) : working;
  return (
    text: finalString,
    truncated: truncated,
    redactedCount: count,
  );
}

/// Convenience helper returning only the redacted string (`UDC-12` S12.2).
String redactSensitiveTokens(String rawText, {int maxChars = 1200}) =>
    redactSensitiveSelectionText(rawText, maxChars: maxChars).text;

/// Extensions forbidden for `beam.transfer` (`UDC-13` S13.3):
/// executables, scripts, installers, libraries, and app bundles.
const Set<String> forbiddenBeamExtensions = <String>{
  'exe',
  'bat',
  'cmd',
  'com',
  'msi',
  'ps1',
  'vbs',
  'js',
  'jse',
  'wsf',
  'wsh',
  'scr',
  'pif',
  'reg',
  'dll',
  'sys',
  'drv',
  'sh',
  'bash',
  'zsh',
  'command',
  'app',
  'dmg',
  'pkg',
  'dylib',
  'so',
  'bin',
  'run',
  'jar',
  'py',
  'rb',
  'pl',
};

final RegExp _beamFileNameRe =
    RegExp(r'^[a-zA-Z0-9_.\- ()]+\.[a-zA-Z0-9]{1,10}$');

/// Validates a safe filename for `beam.transfer` (`UDC-13` S13.3):
/// rejects path separators (`/`, `\`), parent traversal (`..`), hidden files
/// starting with `.`, Windows reserved device names, and executable extensions
/// in [forbiddenBeamExtensions].
bool isValidBeamFileName(String? fileName) {
  if (fileName == null) return false;
  final trimmed = fileName.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 120 ||
      trimmed != fileName ||
      trimmed.startsWith('.') ||
      trimmed.endsWith('.') ||
      trimmed.contains('..') ||
      trimmed.contains('/') ||
      trimmed.contains(r'\')) {
    return false;
  }
  if (!_beamFileNameRe.hasMatch(trimmed)) return false;
  final dotIdx = trimmed.lastIndexOf('.');
  if (dotIdx <= 0 || dotIdx == trimmed.length - 1) return false;
  final stem = trimmed.substring(0, dotIdx).toLowerCase();
  const reservedWindowsStems = <String>{
    'con',
    'prn',
    'aux',
    'nul',
    'com1',
    'com2',
    'com3',
    'com4',
    'com5',
    'com6',
    'com7',
    'com8',
    'com9',
    'lpt1',
    'lpt2',
    'lpt3',
    'lpt4',
    'lpt5',
    'lpt6',
    'lpt7',
    'lpt8',
    'lpt9',
  };
  if (reservedWindowsStems.contains(stem)) return false;
  final ext = trimmed.substring(dotIdx + 1).toLowerCase();
  if (forbiddenBeamExtensions.contains(ext)) return false;
  return true;
}

final RegExp _smartHomeEntityRe =
    RegExp(r'^[a-z0-9_]{2,32}\.[a-z0-9_]{1,64}$');

/// Returns `true` if [entityId] belongs to a hard-denied physical security
/// smart-home domain (`lock.*`, `alarm_control_panel.*`, `camera.*`,
/// `garage_door.*`, `siren.*`, `UDC-T36`).
bool isHardDeniedSmartHomeEntity(String? entityId) {
  if (entityId == null) return false;
  final trimmed = entityId.trim().toLowerCase();
  final dotIdx = trimmed.indexOf('.');
  final domain = dotIdx > 0 ? trimmed.substring(0, dotIdx) : trimmed;
  if (hardDeniedSmartHomeDomains.contains(domain)) {
    return true;
  }
  final namePart = dotIdx > 0 ? trimmed.substring(dotIdx + 1) : '';
  if (namePart.contains('door_lock') ||
      namePart.contains('front_door') ||
      namePart.contains('garage') ||
      namePart.contains('alarm')) {
    return true;
  }
  return false;
}

/// Validates a Home Assistant entity ID (`<domain>.<object_id>`) against
/// [allowedSmartHomeDomains] and [hardDeniedSmartHomeDomains] (`UDC-14` S14.4).
bool isValidSmartHomeEntityId(String? entityId) {
  if (entityId == null) return false;
  final trimmed = entityId.trim().toLowerCase();
  if (trimmed != entityId || !_smartHomeEntityRe.hasMatch(trimmed)) {
    return false;
  }
  if (isHardDeniedSmartHomeEntity(trimmed)) {
    return false;
  }
  final domain = trimmed.split('.').first;
  return allowedSmartHomeDomains.contains(domain);
}

/// Validates a Smart TV device name or ID query (`1..64` UTF-8 characters,
/// allowing Vietnamese names like `'TV phòng khách'`, rejecting control chars
/// and path separators).
bool isValidTvDeviceQuery(String? query) {
  if (query == null) return false;
  final trimmed = query.trim();
  if (trimmed.isEmpty ||
      trimmed.length > 64 ||
      trimmed.contains('..') ||
      trimmed.contains('/') ||
      trimmed.contains(r'\')) {
    return false;
  }
  return isSafeAgentPrompt(trimmed);
}

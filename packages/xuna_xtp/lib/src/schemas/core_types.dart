/// Core XTP v1 domain enums, forbidden tool set, constants, and descriptor types.
library;

import 'dart:convert';
import 'dart:typed_data';

final RegExp _toolNamePattern = RegExp(r'^[a-z]+\.[a-z_]+$');
final RegExp _shortIdPattern = RegExp(r'^[a-z0-9_.-]{1,64}$');
final RegExp _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);

/// Forbidden tool names that must never appear in a host manifest (`UDC-3` §5.4).
const Set<String> forbiddenToolNames = <String>{
  'shell.exec',
  'shell.run',
  'powershell.run',
  'powershell.exec',
  'osascript.run',
  'osascript.exec',
  'script.run',
  'script.exec',
  'eval.run',
  'eval.exec',
  'cmd.run',
  'cmd.exec',
  'bash.run',
  'bash.exec',
};

/// Forbidden tool family prefixes in XTP v1 MVP (`XUNA_XTP_V1_CONTRACT.md` §1).
const Set<String> forbiddenToolPrefixes = <String>{
  'shell.',
  'powershell.',
  'osascript.',
  'eval.',
  'script.',
  'keyboard.',
  'pointer.',
  'cmd.',
  'bash.',
};

/// Supported IDEs for `workspace.open` (`UDC-11` S11.2).
const Set<String> supportedWorkspaceIdes = <String>{
  'auto',
  'antigravity',
  'vscode',
  'cursor',
};

/// Supported coding agents for `workspace.coding_agent` (`UDC-11` S11.3).
const Set<String> supportedCodingAgents = <String>{
  'auto',
  'claude_code',
  'antigravity',
  'cursor',
  'vscode',
  'codex',
};

/// Allowed actions for `tv.control` (`UDC-14` S14.2).
const Set<String> allowedTvActions = <String>{
  'power_wake',
  'power_off',
  'play_pause',
  'mute_toggle',
  'volume_up',
  'volume_down',
  'volume_set',
  'nav_up',
  'nav_down',
  'nav_left',
  'nav_right',
  'nav_select',
  'nav_back',
  'nav_home',
  'input_hdmi1',
  'input_hdmi2',
  'input_hdmi3',
};

/// Allowed streaming / media app IDs for `tv.launch_app` (`UDC-14` S14.2).
const Set<String> allowedTvAppIds = <String>{
  'youtube',
  'netflix',
  'spotify',
  'prime_video',
  'disney_plus',
  'apple_tv',
  'plex',
  'browser',
};

/// Safe smart-home domains allowed for `smarthome.control` (`UDC-14` S14.4).
const Set<String> allowedSmartHomeDomains = <String>{
  'light',
  'switch',
  'fan',
  'climate',
  'cover',
  'media_player',
  'scene',
};

/// Physical security smart-home domains that are permanently hard-denied (`UDC-T36`).
const Set<String> hardDeniedSmartHomeDomains = <String>{
  'lock',
  'alarm_control_panel',
  'camera',
  'garage_door',
  'siren',
};

/// Allowed actions for `smarthome.control` (`UDC-14` S14.4).
const Set<String> allowedSmartHomeActions = <String>{
  'turn_on',
  'turn_off',
  'toggle',
  'set_brightness',
  'set_temperature',
  'activate_scene',
};

/// Default localhost development ports inspected by `dev.ports` (`UDC-15` S15.3).
const List<int> defaultAllowedDevPorts = <int>[
  3000,
  4200,
  5000,
  5173,
  5174,
  8000,
  8080,
  8888,
];

/// Allowed item kinds for `pocket.push_item` and `pocket.list_items` (`SYM-1` S1.1).
const Set<String> allowedPocketItemKinds = <String>{
  'auto',
  'text',
  'url',
  'json',
  'code',
  'command',
  'schedule_note',
};

/// Allowed transformation modes for `pocket.transform_item` (`SYM-1` S1.1).
const Set<String> allowedPocketTransformModes = <String>{
  'format_json',
  'extract_tasks',
  'summarize_snippet',
  'prepare_knowledge_fact',
};

/// Allowed target kinds for `watchdog.watch_process_or_port` (`SYM-2` S2.1).
const Set<String> allowedWatchdogTargetKinds = <String>{
  'process',
  'port',
};

/// Allowed resource metrics for `watchdog.watch_resource_threshold` (`SYM-2` S2.1).
const Set<String> allowedWatchdogResourceMetrics = <String>{
  'battery_below',
  'memory_above',
  'disk_free_below',
};

/// Allowed actions for `watchdog.list_and_clear` (`SYM-2` S2.1).
const Set<String> allowedWatchdogListActions = <String>{
  'list',
  'clear_triggered',
  'clear_all',
};

/// Allowed skill categories for `forge.synthesize_skill` (`FORGE-1`, `UNIV-1`).
const Set<String> allowedForgeSkillCategories = <String>{
  'auto',
  'web_harvest_invoices',
  'document_to_sheet',
  'smart_file_janitor',
  'spreadsheet_reconciler',
  'lead_harvester',
  'hr_cv_scanner',
  'ecommerce_price_radar',
  'content_news_digest',
  'media_batch_renamer',
  'universal_data_pipeline',
  'custom_script',
};

/// Allowed actions for `forge.list_and_manage` (`FORGE-1`).
const Set<String> allowedForgeManageActions = <String>{
  'list',
  'delete_one',
  'export_recipe',
};

/// Allowed demonstration modes for `teach.record_session` (`FORGE-2`).
const Set<String> allowedTeachRecordModes = <String>{
  'start',
  'record_action',
  'stop_and_compile',
};

/// Allowed actions for `skill.markdown_bridge` (`CLAW-1`).
const Set<String> allowedSkillMarkdownActions = <String>{
  'export_skill_md',
  'import_skill_md',
};

/// Allowed actions for `skill.record_correction` (`CLAW-1`).
const Set<String> allowedSkillCorrectionActions = <String>{
  'record',
  'list',
};

/// Allowed actions for `heartbeat.configure_and_tick` (`CLAW-2`).
const Set<String> allowedHeartbeatActions = <String>{
  'configure',
  'tick',
  'status',
};

/// Allowed actions for `canvas.present` (`CLAW-3`, `UNIV-1`).
const Set<String> allowedCanvasActions = <String>{
  'present_invoice_table',
  'present_workflow_board',
  'present_data_table',
  'present_kanban_board',
  'present_diff_reconcile',
  'present_metric_cards',
  'clear',
};

/// The 8 Universal Atomic Primitives of the XunaScript Composable Engine (`UNIV-1`).
const Set<String> allowedUniversalPrimitives = <String>{
  'source.filesystem',
  'source.web_http',
  'parse.universal',
  'transform.pipeline',
  'file.batch_ops',
  'export.artifact',
  'sensor.hash_delta',
  'canvas.dynamic_a2ui',
};

/// Allowed artifact export formats for `pipeline.execute_universal` (`UNIV-1`).
const Set<String> allowedUniversalExportFormats = <String>{
  'csv',
  'json',
  'md',
  'html',
};

/// Allowed actions for `skill.workshop_sync` (`WORKSHOP-1`).
const Set<String> allowedSkillWorkshopActions = <String>{
  'sync_to_disk',
  'hot_reload_from_disk',
  'rollback_version',
  'compact_index',
};

/// Allowed actions for `memory.markdown_vault` (`MIND-1`).
const Set<String> allowedMemoryVaultActions = <String>{
  'read_vault',
  'append_note',
  'pre_compaction_flush',
  'sync_to_disk',
};

/// Allowed Markdown files inside the local XUNA Memory Vault (`MIND-1`).
const Set<String> allowedMemoryVaultTargetFiles = <String>{
  'XUNA_SOUL.md',
  'OWNER_PROFILE.md',
  'MEMORY_JOURNAL.md',
};

/// Allowed actions for `ui.accessibility_tree` (`UIA-1` Zero-Screenshot Native OS UI Automation).
///
/// Observation only. `ui.accessibility_tree` is declared R1 and is not part of
/// the approved computer-use session, so it must never change another
/// application's state. Clicking, typing, scrolling, key presses, menus and
/// closing windows go through `input.*` inside an approved `cu.session_start`
/// session, where target resolution and approvals apply.
const Set<String> allowedUiAccessibilityActions = <String>{
  'inspect_window',
};

/// Security-sensitive window title substrings permanently blocked for `ui.accessibility_tree` (`UIA-1`).
const List<String> forbiddenUiWindowPatterns = <String>[
  '1password',
  'bitwarden',
  'keepass',
  'lastpass',
  'keychain',
  'credential manager',
  'windows security',
  'regedit',
  'registry editor',
];

/// Normative allowlist of key combinations for `input.key` (`UDC-8` §4.2).
const Set<String> allowedInputKeyCombos = <String>{
  'Enter',
  'Tab',
  'Esc',
  'Ctrl+S',
  'Cmd+S',
  '⌘S',
  'Ctrl+F',
  'Cmd+F',
  '⌘F',
  'ArrowUp',
  'ArrowDown',
  'ArrowLeft',
  'ArrowRight',
  'PageUp',
  'PageDown',
};

/// Longest text accepted by `input.type_text` (still always R3 phone-signed).
const int maxInputTypeTextLength = 4000;

const Set<String> _comboModifiers = <String>{
  'cmd',
  'command',
  'ctrl',
  'control',
  'alt',
  'opt',
  'option',
  'shift',
};

const Set<String> _comboNamedKeys = <String>{
  'enter',
  'return',
  'tab',
  'esc',
  'escape',
  'space',
  'backspace',
  'delete',
  'arrowup',
  'arrowdown',
  'arrowleft',
  'arrowright',
  'up',
  'down',
  'left',
  'right',
  'pageup',
  'pagedown',
  'home',
  'end',
  'f1',
  'f2',
  'f3',
  'f4',
  'f5',
  'f6',
  'f7',
  'f8',
  'f9',
  'f10',
  'f11',
  'f12',
};

/// Canonical (sorted modifiers, lower-case key) combos that quit apps, log out,
/// lock, force-quit, power off or delete data. Rejected even though they are
/// syntactically valid.
const Set<String> _deniedInputKeyCombos = <String>{
  'cmd+q',
  'cmd+shift+q',
  'cmd+alt+q',
  'cmd+alt+shift+q',
  'cmd+ctrl+q',
  'cmd+alt+escape',
  'cmd+alt+shift+escape',
  'cmd+shift+backspace',
  'cmd+alt+shift+backspace',
  'cmd+backspace',
  'cmd+delete',
  'cmd+shift+delete',
  'cmd+alt+shift+delete',
  'ctrl+alt+delete',
  'ctrl+shift+escape',
  'alt+f4',
};

String? _canonicalInputKeyCombo(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty || trimmed.length > 40) return null;
  var spec = trimmed;
  final modifiers = <String>{};
  if (spec.startsWith('⌘')) {
    modifiers.add('cmd');
    spec = spec.substring(1);
    if (spec.startsWith('+')) spec = spec.substring(1);
  }
  // Split on '+' only, so '-' stays usable as the key (e.g. `Cmd+-`).
  final tokens = spec.split('+');
  final key = tokens.last.trim().toLowerCase();
  for (final token in tokens.sublist(0, tokens.length - 1)) {
    final m = token.trim().toLowerCase();
    if (!_comboModifiers.contains(m)) return null;
    modifiers.add(switch (m) {
      'command' => 'cmd',
      'control' => 'ctrl',
      'opt' || 'option' => 'alt',
      _ => m,
    });
  }
  final isSingleChar =
      key.length == 1 && RegExp(r'^[a-z0-9\[\]\\;,./=`\-]$').hasMatch(key);
  if (!isSingleChar && !_comboNamedKeys.contains(key)) return null;
  final order = <String>['cmd', 'ctrl', 'alt', 'shift'];
  final sorted = order.where(modifiers.contains).toList();
  final normalizedKey = switch (key) {
    'esc' => 'escape',
    'return' => 'enter',
    _ => key,
  };
  return <String>[...sorted, normalizedKey].join('+');
}

/// True when [combo] is a syntactically valid `input.key` combination
/// (optional `Cmd/Ctrl/Alt/Shift` modifiers plus one key) that is not on the
/// system-destructive deny list. Replaces the former fixed allowlist
/// ([allowedInputKeyCombos], kept for compatibility) so command palettes and
/// app shortcuts work in any app.
bool isAllowedInputKeyCombo(String combo) {
  if (allowedInputKeyCombos.contains(combo)) return true;
  final canonical = _canonicalInputKeyCombo(combo);
  if (canonical == null) return false;
  return !_deniedInputKeyCombos.contains(canonical);
}

/// Supported host operating system platforms.
enum HostPlatform {
  windows('windows'),
  macos('macos'),
  android('android'),
  ios('ios'),
  linux('linux');

  const HostPlatform(this.wire);
  final String wire;

  static HostPlatform fromWire(String value) => switch (value) {
        'windows' => HostPlatform.windows,
        'macos' => HostPlatform.macos,
        'android' => HostPlatform.android,
        'ios' => HostPlatform.ios,
        'linux' => HostPlatform.linux,
        _ => throw FormatException('Unknown HostPlatform: $value'),
      };
}

/// Risk tier `R0`..`R4` (`ADR-0012`).
enum RiskTier implements Comparable<RiskTier> {
  r0('R0', 0),
  r1('R1', 1),
  r2('R2', 2),
  r3('R3', 3),
  r4('R4', 4);

  const RiskTier(this.wire, this.level);
  final String wire;
  final int level;

  bool operator <(RiskTier other) => level < other.level;
  bool operator <=(RiskTier other) => level <= other.level;
  bool operator >(RiskTier other) => level > other.level;
  bool operator >=(RiskTier other) => level >= other.level;

  @override
  int compareTo(RiskTier other) => level.compareTo(other.level);

  static RiskTier fromWire(String value) => switch (value) {
        'R0' => RiskTier.r0,
        'R1' => RiskTier.r1,
        'R2' => RiskTier.r2,
        'R3' => RiskTier.r3,
        'R4' => RiskTier.r4,
        _ => throw FormatException('Unknown RiskTier: $value'),
      };
}

/// Canonical tool families (`UDC-3` §5.4, `UDC-8` §4.2).
enum ToolFamily {
  media('media'),
  app('app'),
  url('url'),
  workflow('workflow'),
  host('host'),
  cu('cu'),
  screen('screen'),
  ui('ui'),
  input('input'),
  files('files');

  const ToolFamily(this.wire);
  final String wire;

  static ToolFamily fromWire(String value) => switch (value) {
        'media' => ToolFamily.media,
        'app' => ToolFamily.app,
        'url' => ToolFamily.url,
        'workflow' => ToolFamily.workflow,
        'host' => ToolFamily.host,
        'cu' => ToolFamily.cu,
        'screen' => ToolFamily.screen,
        'ui' => ToolFamily.ui,
        'input' => ToolFamily.input,
        'files' => ToolFamily.files,
        _ => throw FormatException('Unknown ToolFamily: $value'),
      };
}

/// Application-level tool execution status (`_meta["xuna/status"]`).
enum XtpStatus {
  ok('ok'),
  denied('denied'),
  needsPermission('needs_permission'),
  invalidArgs('invalid_args'),
  unsupported('unsupported'),
  failed('failed'),
  timeout('timeout'),
  cancelled('cancelled');

  const XtpStatus(this.wire);
  final String wire;

  bool get isError => this != XtpStatus.ok;

  static XtpStatus fromWire(String value) => switch (value) {
        'ok' => XtpStatus.ok,
        'denied' => XtpStatus.denied,
        'needs_permission' => XtpStatus.needsPermission,
        'invalid_args' => XtpStatus.invalidArgs,
        'unsupported' => XtpStatus.unsupported,
        'failed' => XtpStatus.failed,
        'timeout' => XtpStatus.timeout,
        'cancelled' => XtpStatus.cancelled,
        _ => throw FormatException('Unknown XtpStatus: $value'),
      };
}

/// OS permission readiness reported in `_meta["xuna/policy"].permission`.
enum XtpPermissionState {
  granted('granted'),
  denied('denied'),
  notDetermined('not_determined');

  const XtpPermissionState(this.wire);
  final String wire;

  static XtpPermissionState fromWire(String value) => switch (value) {
        'granted' => XtpPermissionState.granted,
        'denied' => XtpPermissionState.denied,
        'not_determined' => XtpPermissionState.notDetermined,
        _ => throw FormatException('Unknown XtpPermissionState: $value'),
      };
}

/// Emergency stop reason (`xuna/stop`).
enum StopReason {
  ownerApp('owner_app'),
  ownerHost('owner_host'),
  ownerBoard('owner_board'),
  revoked('revoked');

  const StopReason(this.wire);
  final String wire;

  static StopReason fromWire(String value) => switch (value) {
        'owner_app' => StopReason.ownerApp,
        'owner_host' => StopReason.ownerHost,
        'owner_board' => StopReason.ownerBoard,
        'revoked' => StopReason.revoked,
        _ => throw FormatException('Unknown StopReason: $value'),
      };
}

/// Cryptographic proof purpose (`xuna.host.proof.v1`).
enum HostProofPurpose {
  enroll(1),
  session(2);

  const HostProofPurpose(this.code);
  final int code;

  static HostProofPurpose fromCode(int value) => switch (value) {
        1 => HostProofPurpose.enroll,
        2 => HostProofPurpose.session,
        _ => throw FormatException('Unknown HostProofPurpose: $value'),
      };
}

/// Validates a short identifier (`^[a-z0-9_.-]{1,64}$`).
bool isValidShortId(String value) => _shortIdPattern.hasMatch(value);

/// Validates a canonical UUID string.
bool isValidUuid(String value) => _uuidPattern.hasMatch(value);

/// `_meta["xuna/policy"]` attached to a `ToolDescriptor`.
class ToolPolicyMeta {
  const ToolPolicyMeta({
    this.version = 1,
    required this.family,
    required this.risk,
    required this.observes,
    required this.reversible,
    required this.permission,
    this.idempotent,
  });

  factory ToolPolicyMeta.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{
        'version',
        'family',
        'risk',
        'observes',
        'reversible',
        'permission',
      },
      optionalKeys: const <String>{'idempotent'},
      context: 'xuna/policy',
    );
    final rawIdempotent = json['idempotent'];
    if (rawIdempotent != null && rawIdempotent is! bool) {
      throw const FormatException('xuna/policy.idempotent must be a boolean');
    }
    final version = json['version'];
    if (version != 1) {
      throw FormatException('Unsupported xuna/policy version: $version');
    }
    return ToolPolicyMeta(
      version: 1,
      family: ToolFamily.fromWire(_requireString(json, 'family')),
      risk: RiskTier.fromWire(_requireString(json, 'risk')),
      observes: _requireBool(json, 'observes'),
      reversible: _requireBool(json, 'reversible'),
      permission: XtpPermissionState.fromWire(
        _requireString(json, 'permission'),
      ),
      idempotent: rawIdempotent as bool?,
    );
  }

  final int version;
  final ToolFamily family;
  final RiskTier risk;
  final bool observes;
  final bool reversible;
  final XtpPermissionState permission;

  /// Optional: `false` declares that repeating a successful call with the same
  /// arguments changes state again (a toggle), so the agent must not re-run it.
  /// Omitted (`null`) when the tool does not declare it.
  final bool? idempotent;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'family': family.wire,
        'risk': risk.wire,
        'observes': observes,
        'reversible': reversible,
        'permission': permission.wire,
        if (idempotent != null) 'idempotent': idempotent,
      };
}

/// MCP `Tool` descriptor with `_meta["xuna/policy"]`.
class ToolDescriptor {
  ToolDescriptor({
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.outputSchema,
    required this.policy,
  }) {
    validateToolName(name, expectedFamily: policy.family);
    if (description.isEmpty || description.length > 240) {
      throw const FormatException(
        'Tool description must be 1..240 characters',
      );
    }
    if (inputSchema['type'] != 'object' ||
        inputSchema['additionalProperties'] != false) {
      throw FormatException(
        'Tool $name inputSchema must be an object with additionalProperties: false',
      );
    }
    if (outputSchema['type'] != 'object' ||
        outputSchema['additionalProperties'] != false) {
      throw FormatException(
        'Tool $name outputSchema must be an object with additionalProperties: false',
      );
    }
  }

  factory ToolDescriptor.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{
        'name',
        'description',
        'inputSchema',
        'outputSchema',
        '_meta',
      },
      context: 'ToolDescriptor',
    );
    final meta = _requireMap(json, '_meta');
    _requireExactKeys(
      meta,
      const <String>{'xuna/policy'},
      context: 'ToolDescriptor._meta',
    );
    return ToolDescriptor(
      name: _requireString(json, 'name'),
      description: _requireString(json, 'description'),
      inputSchema: _requireMap(json, 'inputSchema'),
      outputSchema: _requireMap(json, 'outputSchema'),
      policy: ToolPolicyMeta.fromJson(_requireMap(meta, 'xuna/policy')),
    );
  }

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final Map<String, Object?> outputSchema;
  final ToolPolicyMeta policy;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'description': description,
        'inputSchema': inputSchema,
        'outputSchema': outputSchema,
        '_meta': <String, Object?>{
          'xuna/policy': policy.toJson(),
        },
      };

  /// Validates that [name] matches `^[a-z]+\.[a-z_]+$`, is not in
  /// [forbiddenToolNames] or [forbiddenToolPrefixes], and starts with a valid
  /// [ToolFamily].
  static void validateToolName(String name, {ToolFamily? expectedFamily}) {
    if (forbiddenToolNames.contains(name)) {
      throw FormatException('Forbidden tool name: $name');
    }
    for (final prefix in forbiddenToolPrefixes) {
      if (name.startsWith(prefix)) {
        throw FormatException('Forbidden tool prefix in name: $name');
      }
    }
    if (!_toolNamePattern.hasMatch(name)) {
      throw FormatException('Invalid tool name format: $name');
    }
    final prefix = name.split('.').first;
    final family = resolveToolFamilyForName(name);
    if (family == null) {
      throw FormatException('Unknown ToolFamily: $prefix');
    }
    if (expectedFamily != null && family != expectedFamily) {
      throw FormatException(
        'Tool $name prefix ($prefix) does not match policy family (${expectedFamily.wire})',
      );
    }
  }
}

/// Resolves a canonical XTP tool [toolName] to its owning [ToolFamily], or
/// returns `null` if [toolName] is malformed, forbidden, or has an unknown
/// prefix.
ToolFamily? resolveToolFamilyForName(String toolName) {
  if (forbiddenToolNames.contains(toolName)) {
    return null;
  }
  for (final prefix in forbiddenToolPrefixes) {
    if (toolName.startsWith(prefix)) {
      return null;
    }
  }
  if (!_toolNamePattern.hasMatch(toolName)) {
    return null;
  }
  final prefix = toolName.split('.').first;
  if (prefix == 'browser' || toolName == 'tv.cast_media') {
    return ToolFamily.url;
  }
  if (toolName == 'tv.list_devices' ||
      toolName == 'tv.control') {
    return ToolFamily.media;
  }
  if (prefix == 'system') {
    return ToolFamily.host;
  }
  if (prefix == 'habit') {
    return ToolFamily.workflow;
  }
  if (prefix == 'display' ||
      prefix == 'workspace' ||
      prefix == 'selection' ||
      prefix == 'mcp' ||
      prefix == 'window' ||
      prefix == 'beam' ||
      prefix == 'action' ||
      prefix == 'smarthome' ||
      prefix == 'clipboard' ||
      prefix == 'dev' ||
      prefix == 'pocket' ||
      prefix == 'watchdog' ||
      prefix == 'coach' ||
      prefix == 'forge' ||
      prefix == 'teach' ||
      prefix == 'skill' ||
      prefix == 'heartbeat' ||
      prefix == 'canvas' ||
      prefix == 'pipeline' ||
      prefix == 'memory' ||
      toolName == 'tv.launch_app' ||
      toolName == 'ui.accessibility_tree') {
    return ToolFamily.app;
  }
  for (final family in ToolFamily.values) {
    if (family.wire == prefix) {
      return family;
    }
  }
  return null;
}

/// Single-use approval token in `_meta["xuna/approval"]` (`XUNA_XTP_V1_CONTRACT.md` §4.2.2, `UDC-7`).
class ApprovalToken {
  ApprovalToken({
    required this.approvalId,
    required this.argsSha256,
    required this.expiresAt,
    this.scope = 'once',
    this.signature,
    this.publicKey,
    String? expiresAtRaw,
  }) : expiresAtWire = expiresAtRaw ?? expiresAt.toUtc().toIso8601String() {
    if (!isValidUuid(approvalId)) {
      throw FormatException('Invalid approvalId UUID: $approvalId');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(argsSha256)) {
      throw FormatException('Invalid argsSha256 hex: $argsSha256');
    }
    if (scope != 'once' && scope != 'conversation_15m') {
      throw FormatException('Invalid approval scope: $scope');
    }
    if (signature != null && signature!.length != 64) {
      throw const FormatException('Approval signature must be 64 bytes');
    }
    if (publicKey != null &&
        (publicKey!.length != 65 || publicKey![0] != 0x04)) {
      throw const FormatException(
        'Approval publicKey must be a 65-byte uncompressed P-256 point',
      );
    }
  }

  factory ApprovalToken.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'approvalId', 'argsSha256', 'expiresAt'},
      optionalKeys: const <String>{'scope', 'signature', 'publicKey'},
      context: 'xuna/approval',
    );
    final expiresRaw = _requireString(json, 'expiresAt');
    final parsed = DateTime.tryParse(expiresRaw);
    if (parsed == null) {
      throw FormatException(
          'Invalid approval expiresAt timestamp: $expiresRaw');
    }
    final scope = json.containsKey('scope') && json['scope'] != null
        ? _requireString(json, 'scope')
        : 'once';
    Uint8List? sigBytes;
    if (json.containsKey('signature') && json['signature'] != null) {
      sigBytes = _decodeB64Flex(_requireString(json, 'signature'), 64);
    }
    Uint8List? pubBytes;
    if (json.containsKey('publicKey') && json['publicKey'] != null) {
      pubBytes = _decodeB64Flex(_requireString(json, 'publicKey'), 65);
    }
    return ApprovalToken(
      approvalId: _requireString(json, 'approvalId'),
      argsSha256: _requireString(json, 'argsSha256'),
      expiresAt: parsed.toUtc(),
      scope: scope,
      signature: sigBytes,
      publicKey: pubBytes,
      expiresAtRaw: expiresRaw,
    );
  }

  final String approvalId;
  final String argsSha256;
  final DateTime expiresAt;
  final String scope;
  final Uint8List? signature;
  final Uint8List? publicKey;
  final String expiresAtWire;

  bool isExpiredAt(DateTime nowUtc) => !nowUtc.toUtc().isBefore(expiresAt);

  Map<String, Object?> toJson() => <String, Object?>{
        'approvalId': approvalId,
        'argsSha256': argsSha256,
        'expiresAt': expiresAtWire,
        if (scope != 'once') 'scope': scope,
        if (signature != null) 'signature': base64.encode(signature!),
        if (publicKey != null) 'publicKey': base64.encode(publicKey!),
      };
}

Uint8List _decodeB64Flex(String raw, int expectedLen) {
  var clean = raw.trim();
  final rem = clean.length % 4;
  if (rem == 2) {
    clean = '$clean==';
  } else if (rem == 3) {
    clean = '$clean=';
  } else if (rem == 1) {
    throw const FormatException('Invalid base64 length');
  }
  final decoded = (clean.contains('-') || clean.contains('_'))
      ? base64Url.decode(clean)
      : base64.decode(clean);
  if (decoded.length != expectedLen) {
    throw FormatException('Expected $expectedLen bytes in base64 field');
  }
  return Uint8List.fromList(decoded);
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

bool _requireBool(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! bool) {
    throw FormatException('Expected boolean for "$key"');
  }
  return value;
}

Map<String, Object?> _requireMap(Map<String, Object?> map, String key) {
  final value = map[key];
  if (value is! Map) {
    throw FormatException('Expected object for "$key"');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('Expected string key in "$key"');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

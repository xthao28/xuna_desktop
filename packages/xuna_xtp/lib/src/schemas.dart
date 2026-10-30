/// Core XTP v1 domain enums, forbidden tool set, and descriptor schemas.
library;

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

/// Canonical tool families (`UDC-3` §5.4).
enum ToolFamily {
  media('media'),
  app('app'),
  url('url'),
  workflow('workflow'),
  host('host'),
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
      context: 'xuna/policy',
    );
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
    );
  }

  final int version;
  final ToolFamily family;
  final RiskTier risk;
  final bool observes;
  final bool reversible;
  final XtpPermissionState permission;

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'family': family.wire,
        'risk': risk.wire,
        'observes': observes,
        'reversible': reversible,
        'permission': permission.wire,
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
    final family = ToolFamily.fromWire(prefix);
    if (expectedFamily != null && family != expectedFamily) {
      throw FormatException(
        'Tool $name prefix ($prefix) does not match policy family (${expectedFamily.wire})',
      );
    }
  }
}

/// Single-use approval token in `_meta["xuna/approval"]` (`XUNA_XTP_V1_CONTRACT.md` §4.2.2).
class ApprovalToken {
  ApprovalToken({
    required this.approvalId,
    required this.argsSha256,
    required this.expiresAt,
  }) {
    if (!isValidUuid(approvalId)) {
      throw FormatException('Invalid approvalId UUID: $approvalId');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(argsSha256)) {
      throw FormatException('Invalid argsSha256 hex: $argsSha256');
    }
  }

  factory ApprovalToken.fromJson(Map<String, Object?> json) {
    _requireExactKeys(
      json,
      const <String>{'approvalId', 'argsSha256', 'expiresAt'},
      context: 'xuna/approval',
    );
    final expiresRaw = _requireString(json, 'expiresAt');
    final parsed = DateTime.tryParse(expiresRaw);
    if (parsed == null) {
      throw FormatException(
          'Invalid approval expiresAt timestamp: $expiresRaw');
    }
    return ApprovalToken(
      approvalId: _requireString(json, 'approvalId'),
      argsSha256: _requireString(json, 'argsSha256'),
      expiresAt: parsed.toUtc(),
    );
  }

  final String approvalId;
  final String argsSha256;
  final DateTime expiresAt;

  bool isExpiredAt(DateTime nowUtc) => !nowUtc.toUtc().isBefore(expiresAt);

  Map<String, Object?> toJson() => <String, Object?>{
        'approvalId': approvalId,
        'argsSha256': argsSha256,
        'expiresAt': expiresAt.toUtc().toIso8601String(),
      };
}

/// Normative MVP tool descriptors (`XUNA_XTP_V1_CONTRACT.md` §6).
List<ToolDescriptor> buildMvpToolCatalog({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
  bool includeHostNotify = true,
}) {
  const emptyObjectSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{},
    'additionalProperties': false,
  };
  final idPropertySchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'id': <String, Object?>{
        'type': 'string',
        'pattern': r'^[a-z0-9_.-]{1,64}$',
      },
    },
    'required': const <String>['id'],
    'additionalProperties': false,
  };

  final tools = <ToolDescriptor>[
    ToolDescriptor(
      name: 'media.play_pause',
      description: 'Toggle playback of the active media session.',
      inputSchema: emptyObjectSchema,
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'state': <String, Object?>{
            'type': 'string',
            'enum': <String>['playing', 'paused', 'unknown'],
          },
        },
        'required': <String>['state'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'media.next',
      description: 'Skip to the next media track.',
      inputSchema: emptyObjectSchema,
      outputSchema: emptyObjectSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'media.previous',
      description: 'Return to the previous media track.',
      inputSchema: emptyObjectSchema,
      outputSchema: emptyObjectSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'media.volume_set',
      description: 'Set system master output volume (0..100).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'level': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['level'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'level': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['level'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'media.now_playing',
      description: 'Read metadata for the active media session.',
      inputSchema: emptyObjectSchema,
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'state': <String, Object?>{
            'type': 'string',
            'enum': <String>['playing', 'paused', 'stopped', 'unknown'],
          },
          'title': <String, Object?>{'type': 'string', 'maxLength': 120},
          'artist': <String, Object?>{'type': 'string', 'maxLength': 120},
          'app': <String, Object?>{'type': 'string', 'maxLength': 120},
        },
        'required': <String>['state'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r0,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'app.list_allowed',
      description: 'List applications allowlisted in host-policy.json.',
      inputSchema: emptyObjectSchema,
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'apps': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{
                  'type': 'string',
                  'pattern': r'^[a-z0-9_.-]{1,64}$',
                },
                'name': <String, Object?>{'type': 'string', 'maxLength': 80},
              },
              'required': <String>['id', 'name'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['apps'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r0,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'app.launch',
      description: 'Launch an allowlisted application by id.',
      inputSchema: idPropertySchema,
      outputSchema: idPropertySchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'url.open',
      description: 'Open an https URL on an allowlisted domain.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'url': <String, Object?>{'type': 'string', 'maxLength': 2048},
        },
        'required': <String>['url'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'host': <String, Object?>{'type': 'string', 'maxLength': 255},
        },
        'required': <String>['host'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workflow.list',
      description: 'List owner-registered workflows in host-policy.json.',
      inputSchema: emptyObjectSchema,
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workflows': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{
                  'type': 'string',
                  'pattern': r'^[a-z0-9_.-]{1,64}$',
                },
                'name': <String, Object?>{'type': 'string', 'maxLength': 80},
                'risk': <String, Object?>{
                  'type': 'string',
                  'enum': <String>['R1', 'R2', 'R3'],
                },
              },
              'required': <String>['id', 'name', 'risk'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['workflows'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.workflow,
        risk: RiskTier.r0,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workflow.run',
      description: 'Run an allowlisted workflow by id.',
      inputSchema: idPropertySchema,
      outputSchema: idPropertySchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.workflow,
        risk: RiskTier.r1,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'host.status',
      description:
          'Report host platform, OS version, agent version and permission states.',
      inputSchema: emptyObjectSchema,
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'platform': <String, Object?>{
            'type': 'string',
            'enum': <String>['windows', 'macos', 'android', 'ios', 'linux'],
          },
          'osVersion': <String, Object?>{'type': 'string', 'maxLength': 64},
          'agentVersion': <String, Object?>{'type': 'string', 'maxLength': 32},
          'permissions': <String, Object?>{
            'type': 'object',
            'additionalProperties': <String, Object?>{
              'type': 'string',
              'enum': <String>['granted', 'denied', 'not_determined'],
            },
          },
        },
        'required': <String>[
          'platform',
          'osVersion',
          'agentVersion',
          'permissions',
        ],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.host,
        risk: RiskTier.r0,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    if (includeHostNotify)
      ToolDescriptor(
        name: 'host.notify',
        description: 'Display a short notification on the host.',
        inputSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'title': <String, Object?>{'type': 'string', 'maxLength': 40},
            'body': <String, Object?>{'type': 'string', 'maxLength': 120},
          },
          'required': <String>['title', 'body'],
          'additionalProperties': false,
        },
        outputSchema: emptyObjectSchema,
        policy: ToolPolicyMeta(
          family: ToolFamily.host,
          risk: RiskTier.r1,
          observes: false,
          reversible: true,
          permission: defaultPermission,
        ),
      ),
  ];
  return tools;
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

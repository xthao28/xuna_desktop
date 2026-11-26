/// MVP, Dev Workspace, Desk Co-Pilot, Ambient Co-Pilot, and Smart TV / Smart Home tool descriptors.
library;

import 'core_types.dart';
import 'exec_fs_catalog.dart';
import 'forge_claw_catalog.dart';
import 'symbiotic_catalog.dart';

/// Normative MVP tool descriptors (`XUNA_XTP_V1_CONTRACT.md` §6).
List<ToolDescriptor> buildMvpToolCatalog({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
  bool includeHostNotify = true,
  bool includeBrowserCurrentUrl = false,
  bool includeDevWorkspaceTools = false,
  bool includeDeskCopilotTools = false,
  bool includeAmbientCopilotTools = false,
  bool includeSmartTvHomeTools = false,
  bool includeSymbioticCopilotTools = false,
  bool includeSymbioticEvolutionTools = false,
  bool includeSymbioticSentinelTools = false,
  bool includeOmniForgeTools = false,
  bool includeClawPulseTools = false,
  bool includeExecFsTools = false,
  bool shellEnabled = false,
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
        idempotent: false,
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
      description:
          'Launch an allowlisted application by id, optionally opening a folder, project, or file inside the owner home directory.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'openTarget': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 256,
            'description':
                'Optional folder, project, or file name or relative path inside the owner home directory to open directly in this application.',
          },
        },
        'required': <String>['id'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'id': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'openedTarget': <String, Object?>{'type': 'string', 'maxLength': 128},
          'alreadyRunning': <String, Object?>{'type': 'boolean'},
          'windowTitle': <String, Object?>{'type': 'string', 'maxLength': 200},
          'compactUiTree': <String, Object?>{
            'type': 'string',
            'maxLength': 4096,
          },
          'snapshotId': <String, Object?>{'type': 'string', 'maxLength': 32},
          'nodes': <String, Object?>{'type': 'array'},
          'nextStepHint': <String, Object?>{'type': 'string', 'maxLength': 512},
        },
        'required': <String>['id'],
        'additionalProperties': false,
      },
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
    if (includeBrowserCurrentUrl)
      buildBrowserCurrentUrlTool(defaultPermission: defaultPermission),
    if (includeDevWorkspaceTools)
      ...buildDevWorkspaceTools(defaultPermission: defaultPermission),
    if (includeDeskCopilotTools)
      ...buildDeskCopilotTools(defaultPermission: defaultPermission),
    if (includeAmbientCopilotTools)
      ...buildAmbientCopilotTools(defaultPermission: defaultPermission),
    if (includeSmartTvHomeTools)
      ...buildSmartTvHomeTools(defaultPermission: defaultPermission),
    if (includeSymbioticCopilotTools)
      ...buildSymbioticCopilotTools(defaultPermission: defaultPermission),
    if (includeSymbioticEvolutionTools)
      ...buildSymbioticEvolutionTools(defaultPermission: defaultPermission),
    if (includeSymbioticSentinelTools)
      ...buildSymbioticSentinelTools(defaultPermission: defaultPermission),
    if (includeOmniForgeTools)
      ...buildOmniForgeTools(defaultPermission: defaultPermission),
    if (includeClawPulseTools)
      ...buildClawPulseTools(defaultPermission: defaultPermission),
    if (includeExecFsTools) ...[
      ...buildFsTools(defaultPermission: defaultPermission),
      ...buildExecTools(shellEnabled: shellEnabled),
      ...buildDraftTools(defaultPermission: defaultPermission),
      ...buildCapabilityTools(
        shellEnabled: shellEnabled,
        defaultPermission: defaultPermission,
      ),
    ],
  ];
  return tools;
}

/// Builds the `browser.current_url` descriptor (`UDC-9` S9.1: R2, `observes: true`,
/// `reversible: true`, family `url`).
ToolDescriptor buildBrowserCurrentUrlTool({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return ToolDescriptor(
    name: 'browser.current_url',
    description:
        'Read the active https tab URL from an allowlisted browser (Edge, Chrome, Safari).',
    inputSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'browser': <String, Object?>{
          'type': 'string',
          'enum': <String>['auto', 'edge', 'chrome', 'safari'],
        },
      },
      'additionalProperties': false,
    },
    outputSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'url': <String, Object?>{'type': 'string', 'maxLength': 2048},
        'host': <String, Object?>{'type': 'string', 'maxLength': 255},
        'browser': <String, Object?>{
          'type': 'string',
          'enum': <String>['edge', 'chrome', 'safari'],
        },
      },
      'required': <String>['url', 'host', 'browser'],
      'additionalProperties': false,
    },
    policy: ToolPolicyMeta(
      family: ToolFamily.url,
      risk: RiskTier.r2,
      observes: true,
      reversible: true,
      permission: defaultPermission,
    ),
  );
}

/// Builds the 4 `UDC-11` developer workspace & wake tool descriptors (`S11.1`–`S11.3`):
/// - `display.wake` (`R1`, family `app`)
/// - `workspace.open` (`R2`, family `app`)
/// - `workspace.git_summary` (`R1`, `observes: true`, family `app`)
/// - `workspace.coding_agent` (`R2`, family `app`)
List<ToolDescriptor> buildDevWorkspaceTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'display.wake',
      description:
          'Wake the host display from dim/sleep so the desktop is visible.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'woken': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['woken'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workspace.open',
      description:
          'Find a local project workspace by name/alias and open it in an IDE (Antigravity, VS Code, Cursor).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'ide': <String, Object?>{
            'type': 'string',
            'enum': <String>['auto', 'antigravity', 'vscode', 'cursor'],
          },
        },
        'required': <String>['project'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspace': <String, Object?>{'type': 'string', 'maxLength': 64},
          'ide': <String, Object?>{'type': 'string', 'maxLength': 32},
        },
        'required': <String>['workspace', 'ide'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workspace.git_summary',
      description:
          'Read branch name, uncommitted file counts, and bounded relative changed filenames for a local Git workspace (zero host paths or file contents).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
        },
        'required': <String>['project'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspace': <String, Object?>{'type': 'string', 'maxLength': 64},
          'branch': <String, Object?>{'type': 'string', 'maxLength': 120},
          'clean': <String, Object?>{'type': 'boolean'},
          'modifiedCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'untrackedCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'changedFiles': <String, Object?>{
            'type': 'array',
            'maxItems': 25,
            'items': <String, Object?>{'type': 'string', 'maxLength': 120},
          },
        },
        'required': <String>[
          'workspace',
          'branch',
          'clean',
          'modifiedCount',
          'untrackedCount',
        ],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workspace.coding_agent',
      description:
          'Open a coding agent (Claude Code, Antigravity, Cursor, Codex) in a discovered project and optionally send a continuation prompt.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'agent': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'auto',
              'claude_code',
              'antigravity',
              'cursor',
              'vscode',
              'codex',
            ],
          },
          'resumeLast': <String, Object?>{'type': 'boolean'},
          'prompt': <String, Object?>{'type': 'string', 'maxLength': 500},
        },
        'required': <String>['project'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspace': <String, Object?>{'type': 'string', 'maxLength': 64},
          'agent': <String, Object?>{'type': 'string', 'maxLength': 32},
          'resumed': <String, Object?>{'type': 'boolean'},
          'promptSent': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['workspace', 'agent', 'resumed', 'promptSent'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
  ];
}

/// Builds the 7 `UDC-12` / Wave 2 Desk Co-Pilot tool descriptors (`S12.2`, `S12.3`, `AW2-M1`):
/// - `selection.read` (`R1`, `observes: true`, family `app`)
/// - `host.lock_screen` (`R1`, family `host`)
/// - `workspace.watch_task` (`R1`, `observes: true`, family `app`)
/// - `mcp.list_servers` (`R1`, family `app`)
/// - `mcp.call` (`R2`, family `app`)
/// - `mcp.task_result` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `mcp.task_cancel` (`R1`, `observes: false`, `reversible: true`, family `app`)
List<ToolDescriptor> buildDeskCopilotTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'selection.read',
      description:
          'Read the text currently in the system clipboard (<= 1200 chars) with automatic secret/token redaction. It does not read the active selection: the owner must copy it first.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'maxChars': <String, Object?>{
            'type': 'integer',
            'minimum': 80,
            'maximum': 1200,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'text': <String, Object?>{'type': 'string', 'maxLength': 1200},
          'truncated': <String, Object?>{'type': 'boolean'},
          'redactedCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
        },
        'required': <String>['text', 'truncated', 'redactedCount'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'host.lock_screen',
      description: 'Lock the host workstation or put the display to sleep.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'locked': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['locked'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.host,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workspace.watch_task',
      description:
          'Inspect coding agent / build / test task status in a discovered project workspace.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
        },
        'required': <String>['project'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'workspace': <String, Object?>{'type': 'string', 'maxLength': 64},
          'status': <String, Object?>{
            'type': 'string',
            'enum': <String>['completed', 'running', 'failed', 'idle'],
          },
          'summary': <String, Object?>{'type': 'string', 'maxLength': 200},
        },
        'required': <String>['workspace', 'status', 'summary'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'mcp.list_servers',
      description:
          'List local MCP/ACP servers and, by default, each MCP server\'s tools/list names and argument summaries (no secrets or env vars).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'includeTools': <String, Object?>{'type': 'boolean'},
          'serverId': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'servers': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{
                  'type': 'string',
                  'pattern': r'^[a-z0-9_.-]{1,64}$',
                },
                'transport': <String, Object?>{
                  'type': 'string',
                  'enum': <String>['stdio', 'http', 'acp_stdio'],
                },
                'source': <String, Object?>{
                  'type': 'string',
                  'maxLength': 32,
                },
                'supportsAsync': <String, Object?>{'type': 'boolean'},
                'tools': <String, Object?>{
                  'type': 'array',
                  'items': <String, Object?>{
                    'type': 'object',
                    'properties': <String, Object?>{
                      'name': <String, Object?>{
                        'type': 'string',
                        'maxLength': 128,
                      },
                      'description': <String, Object?>{
                        'type': 'string',
                        'maxLength': 160,
                      },
                      'requiredArgs': <String, Object?>{
                        'type': 'array',
                        'items': <String, Object?>{'type': 'string'},
                      },
                      'optionalArgs': <String, Object?>{
                        'type': 'array',
                        'items': <String, Object?>{'type': 'string'},
                      },
                    },
                    'required': <String>[
                      'name',
                      'description',
                      'requiredArgs',
                      'optionalArgs',
                    ],
                    'additionalProperties': false,
                  },
                },
                'toolsTruncated': <String, Object?>{'type': 'boolean'},
                'toolsError': <String, Object?>{
                  'type': 'string',
                  'enum': <String>[
                    'timeout',
                    'spawn_failed',
                    'protocol_error',
                    'unsupported_transport',
                  ],
                },
              },
              'required': <String>['id', 'transport', 'source'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['servers'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'mcp.call',
      description:
          'Invoke a tool on a locally discovered MCP server or protocol harness (R2 floor, R3 if configured on harness).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'tool': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-zA-Z0-9_.-]{1,64}$',
          },
          'payloadJson': <String, Object?>{
            'type': 'string',
            'maxLength': 1000,
          },
          'asyncMode': <String, Object?>{'type': 'boolean'},
          'yieldMs': <String, Object?>{
            'type': 'integer',
            'minimum': 500,
            'maximum': 15000,
          },
        },
        'required': <String>['server', 'tool'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{'type': 'string', 'maxLength': 64},
          'tool': <String, Object?>{'type': 'string', 'maxLength': 64},
          'summary': <String, Object?>{'type': 'string', 'maxLength': 6144},
          'status': <String, Object?>{
            'type': 'string',
            'enum': <String>['completed', 'running'],
          },
          'mcpServerId': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'protocolTaskId': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-zA-Z0-9_.-]{1,128}$',
          },
        },
        'required': <String>['server', 'tool', 'summary'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'mcp.task_result',
      description:
          'Read the bounded, redacted status or completion summary of a detached MCP or ACP protocol task.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'protocolTaskId': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-zA-Z0-9_.-]{1,128}$',
          },
        },
        'required': <String>['server', 'protocolTaskId'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{'type': 'string', 'maxLength': 64},
          'protocolTaskId': <String, Object?>{
            'type': 'string',
            'maxLength': 128,
          },
          'status': <String, Object?>{
            'type': 'string',
            'enum': <String>['running', 'completed', 'failed', 'cancelled'],
          },
          'progressPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'summary': <String, Object?>{'type': 'string', 'maxLength': 6144},
          'errorCode': <String, Object?>{'type': 'string', 'maxLength': 64},
        },
        'required': <String>['server', 'protocolTaskId', 'status', 'summary'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'mcp.task_cancel',
      description:
          'Cancel an active detached MCP or ACP protocol task and terminate its child session.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-z0-9_.-]{1,64}$',
          },
          'protocolTaskId': <String, Object?>{
            'type': 'string',
            'pattern': r'^[a-zA-Z0-9_.-]{1,128}$',
          },
        },
        'required': <String>['server', 'protocolTaskId'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'server': <String, Object?>{'type': 'string', 'maxLength': 64},
          'protocolTaskId': <String, Object?>{
            'type': 'string',
            'maxLength': 128,
          },
          'cancelled': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['server', 'protocolTaskId', 'cancelled'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

/// Builds the 5 `UDC-13` Seamless Ambient Co-Pilot tool descriptors (`S13.1`–`S13.5`):
/// - `window.active_context` (`R1`, `observes: true`, family `app`)
/// - `browser.read_page` (`R1`, `observes: true`, family `url`)
/// - `beam.transfer` (`R2`, family `app`)
/// - `workflow.batch_steps` (`R2`, family `workflow`)
/// - `action.undo` (`R1`, family `app`)
List<ToolDescriptor> buildAmbientCopilotTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'window.active_context',
      description:
          'Read active foreground window app, title, and visible text summary with secret redaction.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'maxChars': <String, Object?>{
            'type': 'integer',
            'minimum': 80,
            'maximum': 1200,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'appName': <String, Object?>{'type': 'string', 'maxLength': 64},
          'windowTitle': <String, Object?>{'type': 'string', 'maxLength': 120},
          'focusedRole': <String, Object?>{'type': 'string', 'maxLength': 40},
          'visibleSummary': <String, Object?>{
            'type': 'string',
            'maxLength': 1200,
          },
          'truncated': <String, Object?>{'type': 'boolean'},
          'redactedCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'runningApps': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'name': <String, Object?>{'type': 'string', 'maxLength': 64},
                'bundleId': <String, Object?>{
                  'type': 'string',
                  'maxLength': 128,
                },
              },
              'required': <String>['name', 'bundleId'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>[
          'appName',
          'windowTitle',
          'visibleSummary',
          'redactedCount',
        ],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'browser.read_page',
      description:
          'Read structured semantic summary (title, headings, interactive items, excerpt) of active https tab.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'browser': <String, Object?>{
            'type': 'string',
            'enum': <String>['auto', 'edge', 'chrome', 'safari'],
          },
          'maxChars': <String, Object?>{
            'type': 'integer',
            'minimum': 80,
            'maximum': 1600,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'browser': <String, Object?>{'type': 'string', 'maxLength': 24},
          'host': <String, Object?>{'type': 'string', 'maxLength': 255},
          'title': <String, Object?>{'type': 'string', 'maxLength': 160},
          'headings': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 120},
          },
          'actions': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 120},
          },
          'excerpt': <String, Object?>{'type': 'string', 'maxLength': 1600},
          'redactedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
        },
        'required': <String>[
          'browser',
          'host',
          'title',
          'headings',
          'actions',
          'excerpt',
          'redactedCount',
        ],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'beam.transfer',
      description:
          'Transfer a safe file, screenshot, or text snippet peer-to-peer over LAN with SHA-256 verification.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'direction': <String, Object?>{
            'type': 'string',
            'enum': <String>['phone_to_desktop', 'desktop_to_phone'],
          },
          'kind': <String, Object?>{
            'type': 'string',
            'enum': <String>['clipboard_text', 'screenshot', 'file'],
          },
          'fileName': <String, Object?>{'type': 'string', 'maxLength': 120},
          'sizeBytes': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 26214400,
          },
          'sha256': <String, Object?>{
            'type': 'string',
            'pattern': r'^[0-9a-f]{64}$',
          },
          'dataBase64': <String, Object?>{'type': 'string', 'maxLength': 16384},
        },
        'required': <String>[
          'direction',
          'kind',
          'fileName',
          'sizeBytes',
          'sha256',
        ],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'transferId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'fileName': <String, Object?>{'type': 'string', 'maxLength': 120},
          'verifiedSha256': <String, Object?>{'type': 'boolean'},
          'savedIn': <String, Object?>{'type': 'string', 'maxLength': 64},
        },
        'required': <String>[
          'transferId',
          'fileName',
          'verifiedSha256',
          'savedIn',
        ],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'workflow.batch_steps',
      description:
          'Validate all steps upfront and execute 1..5 bounded host actions atomically in one call.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'steps': <String, Object?>{
            'type': 'array',
            'minItems': 1,
            'maxItems': 5,
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'tool': <String, Object?>{'type': 'string', 'maxLength': 64},
                'arguments': <String, Object?>{'type': 'object'},
              },
              'required': <String>['tool', 'arguments'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['steps'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'completedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'completedTools': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 64},
          },
          'summary': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>['completedCount', 'completedTools', 'summary'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.workflow,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'action.undo',
      description:
          'Undo the most recent reversible host action within the 10-minute ledger window.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'undone': <String, Object?>{'type': 'boolean'},
          'tool': <String, Object?>{'type': 'string', 'maxLength': 64},
          'summary': <String, Object?>{'type': 'string', 'maxLength': 200},
        },
        'required': <String>['undone', 'tool', 'summary'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

/// Builds the 6 `UDC-14` Smart TV LAN Bridge & Smart Home tool descriptors (`S14.1`–`S14.4`):
/// - `tv.list_devices` (`R1`, `observes: true`, family `media`)
/// - `tv.control` (`R1`, `reversible: true`, family `media`)
/// - `tv.launch_app` (`R2`, `reversible: true`, family `app`)
/// - `tv.cast_media` (`R2`, `reversible: true`, family `url`)
/// - `smarthome.list_entities` (`R1`, `observes: true`, family `app`)
/// - `smarthome.control` (`R2`, `reversible: true`, family `app`)
List<ToolDescriptor> buildSmartTvHomeTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'tv.list_devices',
      description:
          'List Smart TVs discovered on the local LAN (LG WebOS, Samsung Tizen, Android TV / Chromecast, Roku).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'devices': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'id': <String, Object?>{'type': 'string', 'maxLength': 64},
                'name': <String, Object?>{'type': 'string', 'maxLength': 80},
                'brand': <String, Object?>{'type': 'string', 'maxLength': 32},
                'protocol': <String, Object?>{
                  'type': 'string',
                  'maxLength': 32,
                },
                'online': <String, Object?>{'type': 'boolean'},
                'supportsWakeOnLan': <String, Object?>{'type': 'boolean'},
              },
              'required': <String>[
                'id',
                'name',
                'brand',
                'protocol',
                'online',
                'supportsWakeOnLan',
              ],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['devices'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.media,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'tv.control',
      description:
          'Send a remote control command (power/wake, volume, navigation, HDMI input) to a Smart TV on the LAN.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'device': <String, Object?>{'type': 'string', 'maxLength': 64},
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
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
            ],
          },
          'level': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'deviceId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'name': <String, Object?>{'type': 'string', 'maxLength': 80},
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'state': <String, Object?>{'type': 'string', 'maxLength': 32},
          'level': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['deviceId', 'name', 'action', 'state'],
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
      name: 'tv.launch_app',
      description:
          'Launch an allowlisted streaming/media application on a Smart TV over the LAN.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'device': <String, Object?>{'type': 'string', 'maxLength': 64},
          'appId': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'youtube',
              'netflix',
              'spotify',
              'prime_video',
              'disney_plus',
              'apple_tv',
              'plex',
              'browser',
            ],
          },
        },
        'required': <String>['appId'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'deviceId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'name': <String, Object?>{'type': 'string', 'maxLength': 80},
          'appId': <String, Object?>{'type': 'string', 'maxLength': 32},
          'launched': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['deviceId', 'name', 'appId', 'launched'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'tv.cast_media',
      description:
          'Cast an allowlisted https media URL (YouTube / stream) onto a Smart TV over the LAN.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'device': <String, Object?>{'type': 'string', 'maxLength': 64},
          'url': <String, Object?>{'type': 'string', 'maxLength': 2048},
          'title': <String, Object?>{'type': 'string', 'maxLength': 120},
        },
        'required': <String>['url'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'deviceId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'name': <String, Object?>{'type': 'string', 'maxLength': 80},
          'appId': <String, Object?>{'type': 'string', 'maxLength': 32},
          'host': <String, Object?>{'type': 'string', 'maxLength': 255},
          'casted': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['deviceId', 'name', 'appId', 'host', 'casted'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.url,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'smarthome.list_entities',
      description:
          'List allowlisted smart-home appliances (lights, switches, fans, AC, blinds, scenes) from the local bridge.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'domain': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'light',
              'switch',
              'fan',
              'climate',
              'cover',
              'media_player',
              'scene',
            ],
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'entities': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'entityId': <String, Object?>{
                  'type': 'string',
                  'maxLength': 80,
                },
                'domain': <String, Object?>{'type': 'string', 'maxLength': 32},
                'name': <String, Object?>{'type': 'string', 'maxLength': 80},
                'state': <String, Object?>{'type': 'string', 'maxLength': 32},
              },
              'required': <String>['entityId', 'domain', 'name', 'state'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['entities'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'smarthome.control',
      description:
          'Control an allowlisted smart-home appliance (light, switch, fan, AC, cover, scene) on the local bridge; locks/alarms/cameras are strictly denied.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'entityId': <String, Object?>{'type': 'string', 'maxLength': 80},
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'turn_on',
              'turn_off',
              'toggle',
              'set_brightness',
              'set_temperature',
              'activate_scene',
            ],
          },
          'value': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['entityId', 'action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'entityId': <String, Object?>{'type': 'string', 'maxLength': 80},
          'domain': <String, Object?>{'type': 'string', 'maxLength': 32},
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'state': <String, Object?>{'type': 'string', 'maxLength': 32},
          'value': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
        },
        'required': <String>['entityId', 'domain', 'action', 'state'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.app,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

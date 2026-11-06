/// Symbiotic Co-Pilot, Time-Travel Workspace, Universal Pocket, and Autonomous Watchdog tool descriptors.
library;

import 'core_types.dart';

/// Builds the 5 `UDC-15` Live Symbiotic Co-Pilot tool descriptors (`S15.1`–`S15.4`):
/// - `clipboard.write` (`R2`, `reversible: false`, family `app`)
/// - `dev.ports` (`R1`, `observes: true`, family `app`)
/// - `system.vitals` (`R1`, `observes: true`, family `host`)
List<ToolDescriptor> buildSymbioticCopilotTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'clipboard.write',
      description:
          'Copy generated text, code snippet, or translated reply directly into the host OS clipboard (secret-redacted, zero content logging).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'text': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 4000,
          },
          'label': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
        },
        'required': <String>['text'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'written': <String, Object?>{'type': 'boolean'},
          'charCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'redactedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
        },
        'required': <String>['written', 'charCount', 'redactedCount'],
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
      name: 'dev.ports',
      description:
          'Inspect active localhost development server ports (3000, 4200, 5000, 5173, 8000, 8080, 8888) and LAN preview URLs.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ports': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'integer',
              'minimum': 1024,
              'maximum': 65535,
            },
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'lanIp': <String, Object?>{'type': 'string', 'maxLength': 45},
          'activePorts': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'port': <String, Object?>{'type': 'integer'},
                'process': <String, Object?>{'type': 'string', 'maxLength': 48},
                'url': <String, Object?>{'type': 'string', 'maxLength': 120},
              },
              'required': <String>['port', 'process', 'url'],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['lanIp', 'activePorts'],
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
      name: 'system.vitals',
      description:
          'Read the host battery, charging state, memory usage and free disk space. Metrics the host cannot measure are omitted.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'batteryPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'isCharging': <String, Object?>{'type': 'boolean'},
          'memoryUsedPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'diskFreeGb': <String, Object?>{'type': 'integer', 'minimum': 0},
          'healthStatus': <String, Object?>{'type': 'string', 'maxLength': 32},
        },
        'required': <String>['healthStatus'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.host,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

/// Builds the 6 `SYM-1` Time-Travel Workspace & Universal Pocket tool descriptors (`S1.1`):
/// - `workspace.capture_capsule` (`R1`, `observes: true`, family `app`)
/// - `workspace.restore_capsule` (`R2`, `reversible: true`, family `app`)
/// - `workspace.list_capsules` (`R1`, `observes: true`, family `app`)
/// - `pocket.push_item` (`R1`, `reversible: true`, family `app`)
/// - `pocket.list_items` (`R1`, `observes: true`, family `app`)
/// - `pocket.transform_item` (`R1`, `reversible: true`, family `app`)
List<ToolDescriptor> buildSymbioticEvolutionTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'workspace.capture_capsule',
      description:
          'Freeze the active project workspace context (Git branch, modified files, open windows, and next-step hint) into a Time-Travel Capsule.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 80,
          },
          'nextStepHint': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'capsuleId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'project': <String, Object?>{'type': 'string', 'maxLength': 80},
          'branch': <String, Object?>{'type': 'string', 'maxLength': 80},
          'dirtyCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'nextStepHint': <String, Object?>{'type': 'string', 'maxLength': 240},
          'createdAt': <String, Object?>{'type': 'string', 'maxLength': 40},
        },
        'required': <String>[
          'capsuleId',
          'project',
          'branch',
          'dirtyCount',
          'nextStepHint',
          'createdAt',
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
      name: 'workspace.restore_capsule',
      description:
          'Rehydrate a frozen Time-Travel Workspace Capsule by capsuleId or project name and surface the 15-second context briefing.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'capsuleId': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'project': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 80,
          },
          'ide': <String, Object?>{
            'type': 'string',
            'enum': <String>['auto', 'antigravity', 'vscode', 'cursor'],
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'restored': <String, Object?>{'type': 'boolean'},
          'capsuleId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'project': <String, Object?>{'type': 'string', 'maxLength': 80},
          'branch': <String, Object?>{'type': 'string', 'maxLength': 80},
          'nextStepHint': <String, Object?>{'type': 'string', 'maxLength': 240},
          'briefingVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'restored',
          'capsuleId',
          'project',
          'branch',
          'nextStepHint',
          'briefingVi',
        ],
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
      name: 'workspace.list_capsules',
      description:
          'List saved Time-Travel Workspace Capsules sorted from newest to oldest.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'limit': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'capsules': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'capsuleId': <String, Object?>{
                  'type': 'string',
                  'maxLength': 64,
                },
                'project': <String, Object?>{'type': 'string', 'maxLength': 80},
                'branch': <String, Object?>{'type': 'string', 'maxLength': 80},
                'dirtyCount': <String, Object?>{
                  'type': 'integer',
                  'minimum': 0,
                },
                'nextStepHint': <String, Object?>{
                  'type': 'string',
                  'maxLength': 240,
                },
                'createdAt': <String, Object?>{
                  'type': 'string',
                  'maxLength': 40,
                },
              },
              'required': <String>[
                'capsuleId',
                'project',
                'branch',
                'dirtyCount',
                'nextStepHint',
                'createdAt',
              ],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['capsules'],
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
      name: 'pocket.push_item',
      description:
          'Save a secret-redacted snippet, URL, JSON, command, or note into XUNA Universal Pocket with automatic kind classification.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'text': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 4000,
          },
          'label': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
          'kind': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'auto',
              'text',
              'url',
              'json',
              'code',
              'command',
              'schedule_note',
            ],
          },
          'sourceDevice': <String, Object?>{
            'type': 'string',
            'maxLength': 40,
          },
        },
        'required': <String>['text'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'itemId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'kind': <String, Object?>{'type': 'string', 'maxLength': 32},
          'label': <String, Object?>{'type': 'string', 'maxLength': 80},
          'preview': <String, Object?>{'type': 'string', 'maxLength': 200},
          'redactedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'suggestedActions': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 48},
          },
        },
        'required': <String>[
          'itemId',
          'kind',
          'label',
          'preview',
          'redactedCount',
          'suggestedActions',
        ],
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
      name: 'pocket.list_items',
      description:
          'List recent items stored in XUNA Universal Pocket across devices with optional kind or keyword filtering.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'kind': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'auto',
              'text',
              'url',
              'json',
              'code',
              'command',
              'schedule_note',
            ],
          },
          'query': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
          'limit': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'items': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'itemId': <String, Object?>{'type': 'string', 'maxLength': 64},
                'kind': <String, Object?>{'type': 'string', 'maxLength': 32},
                'label': <String, Object?>{'type': 'string', 'maxLength': 80},
                'preview': <String, Object?>{
                  'type': 'string',
                  'maxLength': 200,
                },
                'sourceDevice': <String, Object?>{
                  'type': 'string',
                  'maxLength': 40,
                },
                'createdAt': <String, Object?>{
                  'type': 'string',
                  'maxLength': 40,
                },
              },
              'required': <String>[
                'itemId',
                'kind',
                'label',
                'preview',
                'sourceDevice',
                'createdAt',
              ],
              'additionalProperties': false,
            },
          },
        },
        'required': <String>['items'],
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
      name: 'pocket.transform_item',
      description:
          'Transform a Universal Pocket item or snippet into formatted JSON, extracted tasks, a concise summary, or a Knowledge Domain fact.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'itemId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'text': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'format_json',
              'extract_tasks',
              'summarize_snippet',
              'prepare_knowledge_fact',
            ],
          },
        },
        'required': <String>['mode'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'mode': <String, Object?>{'type': 'string', 'maxLength': 32},
          'transformedText': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'itemCount': <String, Object?>{'type': 'integer', 'minimum': 0},
        },
        'required': <String>['mode', 'transformedText', 'itemCount'],
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

/// Builds the 6 `SYM-2` Autonomous Watchdogs, Executive Coach, Desk Whisper & Habit Miner tools (`S2.1`):
/// - `watchdog.watch_process_or_port` (`R1`, `observes: true`, family `app`)
/// - `watchdog.watch_resource_threshold` (`R1`, `observes: true`, family `app`)
/// - `watchdog.list_and_clear` (`R1`, `reversible: true`, family `app`)
/// - `coach.decompose_overwhelm` (`R1`, `reversible: true`, family `app`)
/// - `habit.propose_workflow` (`R1`, `observes: true`, family `workflow`)
List<ToolDescriptor> buildSymbioticSentinelTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'watchdog.watch_process_or_port',
      description:
          'Register an autonomous background watchdog on a local process name or localhost port and report status changes.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'targetKind': <String, Object?>{
            'type': 'string',
            'enum': <String>['process', 'port'],
          },
          'processName': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'port': <String, Object?>{
            'type': 'integer',
            'minimum': 1024,
            'maximum': 65535,
          },
          'label': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
        },
        'required': <String>['targetKind'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'watchdogId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'targetKind': <String, Object?>{'type': 'string', 'maxLength': 24},
          'targetValue': <String, Object?>{'type': 'string', 'maxLength': 80},
          'status': <String, Object?>{'type': 'string', 'maxLength': 32},
          'summary': <String, Object?>{'type': 'string', 'maxLength': 200},
        },
        'required': <String>[
          'watchdogId',
          'targetKind',
          'targetValue',
          'status',
          'summary',
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
      name: 'watchdog.watch_resource_threshold',
      description:
          'Register an autonomous background threshold alert on battery, memory, or free disk space.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'metric': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'battery_below',
              'memory_above',
              'disk_free_below',
            ],
          },
          'threshold': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 99,
          },
        },
        'required': <String>['metric', 'threshold'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'watchdogId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'metric': <String, Object?>{'type': 'string', 'maxLength': 32},
          'threshold': <String, Object?>{'type': 'integer'},
          'currentValue': <String, Object?>{'type': 'integer'},
          'triggered': <String, Object?>{'type': 'boolean'},
          'summary': <String, Object?>{'type': 'string', 'maxLength': 200},
        },
        'required': <String>[
          'watchdogId',
          'metric',
          'threshold',
          'currentValue',
          'triggered',
          'summary',
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
      name: 'watchdog.list_and_clear',
      description:
          'List active or triggered background watchdogs and optionally clear triggered or all sentinels.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['list', 'clear_triggered', 'clear_all'],
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'watchdogs': <String, Object?>{'type': 'array'},
          'clearedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
        },
        'required': <String>['watchdogs', 'clearedCount'],
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
      name: 'coach.decompose_overwhelm',
      description:
          'Decompose an overwhelming goal and project state into exactly one concrete 5-minute starter micro-step plus hidden follow-ups.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'goal': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 240,
          },
          'project': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
        },
        'required': <String>['goal'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'goal': <String, Object?>{'type': 'string', 'maxLength': 240},
          'project': <String, Object?>{'type': 'string', 'maxLength': 80},
          'firstFiveMinuteStep': <String, Object?>{
            'type': 'string',
            'maxLength': 160,
          },
          'followUpSteps': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 160},
          },
          'encouragementVi': <String, Object?>{
            'type': 'string',
            'maxLength': 200,
          },
        },
        'required': <String>[
          'goal',
          'project',
          'firstFiveMinuteStep',
          'followUpSteps',
          'encouragementVi',
        ],
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
      name: 'habit.propose_workflow',
      description:
          'Mine repeated owner tool sequences to propose a bounded 1-tap macro workflow (<= 5 steps, max R2).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'minOccurrences': <String, Object?>{
            'type': 'integer',
            'minimum': 2,
            'maximum': 10,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'proposals': <String, Object?>{'type': 'array'},
        },
        'required': <String>['proposals'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.workflow,
        risk: RiskTier.r1,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

/// OmniForge, ClawPulse, Composable Engine, ClawWorkshop, ClawMind, and Computer Use tool descriptors.
library;

import 'core_types.dart';

/// Builds the 5 `OMNIFORGE` (`FORGE-1` & `FORGE-2`) citizen tool synthesis & demonstration descriptors:
/// - `forge.synthesize_skill` (`R1`, `observes: true`, family `app`)
/// - `forge.run_skill` (`R2`, `reversible: true`, family `app`)
/// - `forge.list_and_manage` (`R1`, `reversible: true`, family `app`)
/// - `teach.record_session` (`R1`, `observes: true`, family `app`)
/// - `forge.extract_invoices_to_sheet` (`R1`, `reversible: true`, family `app`)
List<ToolDescriptor> buildOmniForgeTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'forge.synthesize_skill',
      description:
          'Synthesize a sandboxed XunaScript tool from natural language or active browser/folder context and run a 1-item dry-run preview with self-debugging.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'goal': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 400,
          },
          'category': <String, Object?>{
            'type': 'string',
            'enum': <String>[
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
            ],
          },
          'targetFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'fileExtensions': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 12},
          },
        },
        'required': <String>['goal'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'skillId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'titleVi': <String, Object?>{'type': 'string', 'maxLength': 120},
          'category': <String, Object?>{'type': 'string', 'maxLength': 40},
          'detectedItemsCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'dryRunSample': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
          'selfDebugIterations': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'parameterFields': <String, Object?>{'type': 'array'},
          'scriptSteps': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'skillId',
          'titleVi',
          'category',
          'detectedItemsCount',
          'dryRunSample',
          'selfDebugIterations',
          'parameterFields',
          'scriptSteps',
          'summaryVi',
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
      name: 'forge.run_skill',
      description:
          'Execute a synthesized XunaScript tool in the local sandbox (batch download invoices, organize files, reconcile sheets) with automatic undo snapshot.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'skillId': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'maxItems': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 500,
          },
          'outputFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'exportCsv': <String, Object?>{
            'type': 'boolean',
          },
        },
        'required': <String>['skillId'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'skillId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'processedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'outputDirectory': <String, Object?>{
            'type': 'string',
            'maxLength': 160,
          },
          'exportedCsvFile': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'selfHealedSelectors': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'undoSnapshotId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'skillId',
          'processedCount',
          'outputDirectory',
          'exportedCsvFile',
          'selfHealedSelectors',
          'undoSnapshotId',
          'summaryVi',
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
      name: 'forge.list_and_manage',
      description:
          'List owner-forged personal tools in the XUNA Skill Library, delete a tool, or export its portable recipe.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['list', 'delete_one', 'export_recipe'],
          },
          'skillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'skills': <String, Object?>{'type': 'array'},
          'exportedRecipeJson': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
        },
        'required': <String>['skills', 'exportedRecipeJson'],
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
      name: 'teach.record_session',
      description:
          'Start or finish a Show-Me-Once demonstration session where the owner performs 1 example action and XUNA generalizes it into a reusable loop tool.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'mode': <String, Object?>{
            'type': 'string',
            'enum': <String>['start', 'record_action', 'stop_and_compile'],
          },
          'skillTitle': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
          'demonstratedAction': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
          'selectorOrPattern': <String, Object?>{
            'type': 'string',
            'maxLength': 160,
          },
        },
        'required': <String>['mode'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'recordingActive': <String, Object?>{'type': 'boolean'},
          'capturedStepsCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'compiledSkillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'generalizedLoopSummaryVi': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
        },
        'required': <String>[
          'recordingActive',
          'capturedStepsCount',
          'compiledSkillId',
          'generalizedLoopSummaryVi',
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
      name: 'forge.extract_invoices_to_sheet',
      description:
          'Parse local electronic invoices (XML/PDF text) or business documents into a structured accounting CSV/Excel summary table.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sourceFolder': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 120,
          },
          'outputFileName': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
          'detectDuplicates': <String, Object?>{
            'type': 'boolean',
          },
        },
        'required': <String>['sourceFolder'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'invoiceCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'totalAmountVnd': <String, Object?>{'type': 'integer', 'minimum': 0},
          'duplicateCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'outputCsvFile': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'rows': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'invoiceCount',
          'totalAmountVnd',
          'duplicateCount',
          'outputCsvFile',
          'rows',
          'summaryVi',
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
  ];
}

/// Builds the 11 `XUNA ClawPulse`, `XunaScript Universal Composable Engine`, `ClawWorkshop` & `ClawMind` (`CLAW-1`–`CLAW-3`, `UNIV-1`, `WORKSHOP-1`, `MIND-1`) tool descriptors:
/// - `skill.markdown_bridge` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `skill.record_correction` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `heartbeat.configure_and_tick` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `canvas.present` (`R1`, `observes: false`, `reversible: true`, family `app`)
/// - `pipeline.execute_universal` (`R2`, `observes: false`, `reversible: true`, family `app`)
/// - `skill.workshop_sync` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `skill.chain_and_test` (`R2`, `observes: false`, `reversible: true`, family `app`)
/// - `memory.markdown_vault` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `browser.semantic_snapshot` (`R1`, `observes: true`, `reversible: true`, family `url`)
/// - `subagent.spawn_and_poll` (`R1`, `observes: true`, `reversible: true`, family `app`)
/// - `schedule.cron_and_hooks` (`R1`, `observes: false`, `reversible: true`, family `app`)
List<ToolDescriptor> buildClawPulseTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'skill.markdown_bridge',
      description:
          'Export a forged XUNA skill as an OpenClaw-compatible SKILL.md document or import a safe SKILL.md into the sandboxed OmniForge library.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['export_skill_md', 'import_skill_md'],
          },
          'skillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'markdownContent': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'skillId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'titleVi': <String, Object?>{'type': 'string', 'maxLength': 120},
          'skillMarkdown': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'securityVerified': <String, Object?>{'type': 'boolean'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'action',
          'skillId',
          'titleVi',
          'skillMarkdown',
          'securityVerified',
          'summaryVi',
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
      name: 'skill.record_correction',
      description:
          'Record a self-improving correction rule on a forged skill when a portal layout changes or the owner gives feedback.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['record', 'list'],
          },
          'skillId': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'correctionNote': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
        },
        'required': <String>['skillId'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'skillId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'selfHealGeneration': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'correctionRules': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'skillId',
          'selfHealGeneration',
          'correctionRules',
          'summaryVi',
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
      name: 'heartbeat.configure_and_tick',
      description:
          'Run or configure XUNA Zero-Token 2-Tier Heartbeat patrol (Tier-1 0-token local sensor pre-check returning HEARTBEAT_OK or HEARTBEAT_ALERT).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['configure', 'tick', 'status'],
          },
          'checkName': <String, Object?>{
            'type': 'string',
            'maxLength': 80,
          },
          'intervalMinutes': <String, Object?>{
            'type': 'integer',
            'minimum': 5,
            'maximum': 720,
          },
          'simulateDelta': <String, Object?>{
            'type': 'boolean',
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'status': <String, Object?>{
            'type': 'string',
            'enum': <String>['HEARTBEAT_OK', 'HEARTBEAT_ALERT'],
          },
          'deltaDetected': <String, Object?>{'type': 'boolean'},
          'llmTokensUsed': <String, Object?>{'type': 'integer', 'minimum': 0},
          'suppressedNotification': <String, Object?>{'type': 'boolean'},
          'intervalMinutes': <String, Object?>{
            'type': 'integer',
            'minimum': 5,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'status',
          'deltaDetected',
          'llmTokensUsed',
          'suppressedNotification',
          'intervalMinutes',
          'summaryVi',
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
      name: 'canvas.present',
      description:
          'Push an interactive A2UI Live Canvas surface (data table, kanban, diff reconcile, metric cards, invoice table, or workflow board) to Desktop and Mobile.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'present_invoice_table',
              'present_workflow_board',
              'present_data_table',
              'present_kanban_board',
              'present_diff_reconcile',
              'present_metric_cards',
              'clear',
            ],
          },
          'title': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'sourceSkillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'canvasId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'surfaceKind': <String, Object?>{'type': 'string', 'maxLength': 40},
          'titleVi': <String, Object?>{'type': 'string', 'maxLength': 120},
          'columns': <String, Object?>{'type': 'array'},
          'rows': <String, Object?>{'type': 'array'},
          'actions': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'canvasId',
          'surfaceKind',
          'titleVi',
          'columns',
          'rows',
          'actions',
          'summaryVi',
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
      name: 'pipeline.execute_universal',
      description:
          'Execute a composable XunaScript pipeline across the 8 universal primitives (file/web source, universal parse, transform/reconcile, batch file ops, export, and A2UI canvas).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'goal': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 400,
          },
          'primitives': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'source.filesystem',
                'source.web_http',
                'parse.universal',
                'transform.pipeline',
                'file.batch_ops',
                'export.artifact',
                'sensor.hash_delta',
                'canvas.dynamic_a2ui',
              ],
            },
          },
          'sourceFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'rawInputText': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'secondaryInputText': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'exportFormat': <String, Object?>{
            'type': 'string',
            'enum': <String>['csv', 'json', 'md', 'html'],
          },
          'outputFileName': <String, Object?>{
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
          'pipelineId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'category': <String, Object?>{'type': 'string', 'maxLength': 40},
          'executedPrimitives': <String, Object?>{'type': 'array'},
          'processedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'exportedFile': <String, Object?>{'type': 'string', 'maxLength': 160},
          'canvasSurfaceKind': <String, Object?>{
            'type': 'string',
            'maxLength': 40,
          },
          'rows': <String, Object?>{'type': 'array'},
          'undoSnapshotId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'pipelineId',
          'category',
          'executedPrimitives',
          'processedCount',
          'exportedFile',
          'canvasSurfaceKind',
          'rows',
          'undoSnapshotId',
          'summaryVi',
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
      name: 'skill.workshop_sync',
      description:
          'Sync forged skills to disk (SKILL.md + recipe.json), hot-reload modified skills from disk, rollback to a prior version, or emit a compact progressive-disclosure index.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'sync_to_disk',
              'hot_reload_from_disk',
              'rollback_version',
              'compact_index',
            ],
          },
          'skillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'workshopFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'syncedCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'hotReloadedCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'activeVersion': <String, Object?>{'type': 'integer', 'minimum': 1},
          'compactIndex': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'action',
          'syncedCount',
          'hotReloadedCount',
          'activeVersion',
          'compactIndex',
          'summaryVi',
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
      name: 'skill.chain_and_test',
      description:
          'Execute a multi-skill DAG chain with {{variable}} template interpolation, run self-test assertions, and optionally bind auto-trigger on Heartbeat delta.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'chainSkillIds': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 64},
          },
          'runtimeParams': <String, Object?>{
            'type': 'object',
          },
          'autoTriggerOnDelta': <String, Object?>{
            'type': 'boolean',
          },
        },
        'required': <String>['chainSkillIds'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'chainId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'executedSkillIds': <String, Object?>{'type': 'array'},
          'interpolatedGoal': <String, Object?>{
            'type': 'string',
            'maxLength': 240,
          },
          'passedAssertions': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'totalAssertions': <String, Object?>{'type': 'integer', 'minimum': 1},
          'selfTestPassed': <String, Object?>{'type': 'boolean'},
          'autoTriggerOnDelta': <String, Object?>{'type': 'boolean'},
          'undoSnapshotId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'chainId',
          'executedSkillIds',
          'interpolatedGoal',
          'passedAssertions',
          'totalAssertions',
          'selfTestPassed',
          'autoTriggerOnDelta',
          'undoSnapshotId',
          'summaryVi',
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
      name: 'memory.markdown_vault',
      description:
          'Read, append, sync to disk, or run pre-compaction memory flush into local transparent Markdown files (XUNA_SOUL.md, OWNER_PROFILE.md, MEMORY_JOURNAL.md) with automatic secret scrubbing.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'read_vault',
              'append_note',
              'pre_compaction_flush',
              'sync_to_disk',
            ],
          },
          'targetFile': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'XUNA_SOUL.md',
              'OWNER_PROFILE.md',
              'MEMORY_JOURNAL.md',
            ],
          },
          'noteContent': <String, Object?>{
            'type': 'string',
            'maxLength': 2000,
          },
          'sessionTranscript': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'vaultFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'vaultFolder': <String, Object?>{'type': 'string', 'maxLength': 120},
          'soulMarkdown': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'ownerProfileMarkdown': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'memoryJournalMarkdown': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'flushedFactsCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'redactedSecretsCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'action',
          'vaultFolder',
          'soulMarkdown',
          'ownerProfileMarkdown',
          'memoryJournalMarkdown',
          'flushedFactsCount',
          'redactedSecretsCount',
          'summaryVi',
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
      name: 'browser.semantic_snapshot',
      description:
          'Parse raw DOM/HTML into a compact OpenClaw-style ARIA semantic accessibility tree with numbered [ref=e1]..[ref=eN] interactive refs, cutting token usage by 80-90% vs screenshots.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'rawHtml': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'pageTitle': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'maxElements': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 50,
          },
        },
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'snapshotId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'pageTitle': <String, Object?>{'type': 'string', 'maxLength': 120},
          'elementCount': <String, Object?>{'type': 'integer', 'minimum': 0},
          'tokenReductionPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 99,
          },
          'compactAriaTree': <String, Object?>{
            'type': 'string',
            'maxLength': 4000,
          },
          'elements': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'snapshotId',
          'pageTitle',
          'elementCount',
          'tokenReductionPercent',
          'compactAriaTree',
          'elements',
          'summaryVi',
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
      name: 'subagent.spawn_and_poll',
      description:
          'Spawn an isolated background sub-agent worker or a 4-specialist Zero-Token Sub-Agent Swarm with a Shared Blackboard, poll progress, or list active workers.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'spawn',
              'spawn_swarm',
              'poll',
              'list_active',
              'read_blackboard',
            ],
          },
          'taskGoal': <String, Object?>{
            'type': 'string',
            'maxLength': 400,
          },
          'workerId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'tokenBudget': <String, Object?>{
            'type': 'integer',
            'minimum': 256,
            'maximum': 8192,
          },
          'sourceFolder': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
          'specialistRoles': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'scout_harvester',
                'analyst_reconciler',
                'executor_organizer',
                'critic_verifier',
              ],
            },
          },
          'enableCriticVerification': <String, Object?>{
            'type': 'boolean',
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'workerId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'status': <String, Object?>{'type': 'string', 'maxLength': 32},
          'progressPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'tokenBudget': <String, Object?>{'type': 'integer', 'minimum': 256},
          'tokensUsed': <String, Object?>{'type': 'integer', 'minimum': 0},
          'llmTokensUsed': <String, Object?>{'type': 'integer', 'minimum': 0},
          'contextSavedPercent': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'distilledResultVi': <String, Object?>{
            'type': 'string',
            'maxLength': 1200,
          },
          'activeWorkers': <String, Object?>{'type': 'array'},
          'blackboardEntries': <String, Object?>{'type': 'array'},
          'criticPassed': <String, Object?>{'type': 'boolean'},
          'criticConfidenceScore': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
            'maximum': 100,
          },
          'specialistBreakdown': <String, Object?>{'type': 'array'},
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'action',
          'workerId',
          'status',
          'progressPercent',
          'tokenBudget',
          'tokensUsed',
          'distilledResultVi',
          'activeWorkers',
          'summaryVi',
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
      name: 'schedule.cron_and_hooks',
      description:
          'Register, trigger, list, or remove autonomous cron jobs and event-driven lifecycle hooks (cron_daily, on_morning_wake, on_file_drop, on_before_sleep, on_git_commit) bound to forged skills.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{
            'type': 'string',
            'enum': <String>['register', 'trigger_event', 'list', 'remove'],
          },
          'hookId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'eventOrCron': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'cron_daily',
              'on_morning_wake',
              'on_file_drop',
              'on_before_sleep',
              'on_git_commit',
            ],
          },
          'targetSkillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'labelVi': <String, Object?>{
            'type': 'string',
            'maxLength': 120,
          },
        },
        'required': <String>['action'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'action': <String, Object?>{'type': 'string', 'maxLength': 32},
          'hookId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'eventOrCron': <String, Object?>{'type': 'string', 'maxLength': 64},
          'targetSkillId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'triggeredCount': <String, Object?>{
            'type': 'integer',
            'minimum': 0,
          },
          'activeHooks': <String, Object?>{'type': 'array'},
          'undoSnapshotId': <String, Object?>{
            'type': 'string',
            'maxLength': 64,
          },
          'summaryVi': <String, Object?>{'type': 'string', 'maxLength': 240},
        },
        'required': <String>[
          'action',
          'hookId',
          'eventOrCron',
          'targetSkillId',
          'triggeredCount',
          'activeHooks',
          'undoSnapshotId',
          'summaryVi',
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
  ];
}

/// Builds the 8 computer-use tool descriptors (`UDC-8` §4.2).
List<ToolDescriptor> buildComputerUseTools({
  XtpPermissionState defaultPermission = XtpPermissionState.granted,
}) {
  const effectOutputSchema = <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'effect': <String, Object?>{
        'type': 'string',
        'enum': <String>['changed', 'no_change'],
      },
    },
    'required': <String>['effect'],
    'additionalProperties': false,
  };

  return <ToolDescriptor>[
    ToolDescriptor(
      name: 'cu.session_start',
      description:
          'Start a bounded desktop computer-use session with declared goal and allowlists.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'goal': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
          },
          'apps': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{
              'type': 'string',
              'pattern': r'^[a-z0-9_.-]{1,64}$',
            },
          },
          'domains': <String, Object?>{
            'type': 'array',
            'items': <String, Object?>{'type': 'string', 'maxLength': 253},
          },
          'maxSteps': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 20,
          },
          'maxMinutes': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 10,
          },
        },
        'required': <String>[
          'goal',
          'apps',
          'domains',
          'maxSteps',
          'maxMinutes',
        ],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{'type': 'string', 'maxLength': 64},
        },
        'required': <String>['sessionId'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.cu,
        risk: RiskTier.r3,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'screen.capture',
      description:
          'Capture active window or screen JPEG for an active computer-use session.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'scope': <String, Object?>{
            'type': 'string',
            'enum': <String>['active_window', 'screen'],
          },
          'maxEdge': <String, Object?>{
            'type': 'integer',
            'minimum': 320,
            'maximum': 1280,
          },
        },
        'required': <String>['scope', 'maxEdge'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'mimeType': <String, Object?>{
            'type': 'string',
            'enum': <String>['image/jpeg'],
          },
          'width': <String, Object?>{'type': 'integer'},
          'height': <String, Object?>{'type': 'integer'},
          'dataBase64': <String, Object?>{'type': 'string'},
        },
        'required': <String>['mimeType', 'width', 'height', 'dataBase64'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.screen,
        risk: RiskTier.r2,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'ui.inspect',
      description:
          'Inspect active window UI tree with password fields redacted.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'scope': <String, Object?>{
            'type': 'string',
            'enum': <String>['active_window'],
          },
          'maxNodes': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 300,
          },
        },
        'required': <String>['scope', 'maxNodes'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'appId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'windowTitle': <String, Object?>{'type': 'string', 'maxLength': 120},
          'nodes': <String, Object?>{'type': 'array'},
        },
        'required': <String>['appId', 'windowTitle', 'nodes'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.ui,
        risk: RiskTier.r2,
        observes: true,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'input.click',
      description:
          'Click a UI element by elementId or coordinates inside an allowlisted app.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'elementId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'elementName': <String, Object?>{'type': 'string', 'maxLength': 120},
          'x': <String, Object?>{'type': 'integer'},
          'y': <String, Object?>{'type': 'integer'},
        },
        'additionalProperties': false,
      },
      outputSchema: effectOutputSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.input,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'input.type_text',
      description:
          'Type text into a non-password UI element (always R3 phone-signed).',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'elementId': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'elementName': <String, Object?>{'type': 'string', 'maxLength': 120},
          'text': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 200,
          },
        },
        'required': <String>['elementId', 'text'],
        'additionalProperties': false,
      },
      outputSchema: effectOutputSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.input,
        risk: RiskTier.r3,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'input.key',
      description: 'Send an allowlisted key combination to the active window.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'combo': <String, Object?>{
            'type': 'string',
            'enum': <String>[
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
            ],
          },
          'inForm': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['combo'],
        'additionalProperties': false,
      },
      outputSchema: effectOutputSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.input,
        risk: RiskTier.r2,
        observes: false,
        reversible: false,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'input.scroll',
      description: 'Scroll inside the active allowlisted window.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'elementId': <String, Object?>{'type': 'string', 'maxLength': 64},
          'direction': <String, Object?>{
            'type': 'string',
            'enum': <String>['up', 'down', 'left', 'right'],
          },
          'amount': <String, Object?>{
            'type': 'integer',
            'minimum': 1,
            'maximum': 10,
          },
        },
        'required': <String>['direction', 'amount'],
        'additionalProperties': false,
      },
      outputSchema: effectOutputSchema,
      policy: ToolPolicyMeta(
        family: ToolFamily.input,
        risk: RiskTier.r2,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
    ToolDescriptor(
      name: 'cu.session_end',
      description: 'End an active computer-use session.',
      inputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'sessionId': <String, Object?>{
            'type': 'string',
            'minLength': 1,
            'maxLength': 64,
          },
          'outcome': <String, Object?>{
            'type': 'string',
            'enum': <String>[
              'completed',
              'stopped',
              'budget_exceeded',
              'failed',
            ],
          },
        },
        'required': <String>['sessionId', 'outcome'],
        'additionalProperties': false,
      },
      outputSchema: const <String, Object?>{
        'type': 'object',
        'properties': <String, Object?>{
          'ended': <String, Object?>{'type': 'boolean'},
        },
        'required': <String>['ended'],
        'additionalProperties': false,
      },
      policy: ToolPolicyMeta(
        family: ToolFamily.cu,
        risk: RiskTier.r0,
        observes: false,
        reversible: true,
        permission: defaultPermission,
      ),
    ),
  ];
}

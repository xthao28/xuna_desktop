/// Data models for XUNA Symbiotic Desktop Services (`UDC-15`, `SYM-1`, `SYM-2`, `FORGE`, `CLAW`, `WORKSHOP`).
library;

/// Active localhost development port entry (`UDC-15` S15.3).
class DevPortEntry {
  const DevPortEntry({
    required this.port,
    required this.process,
    required this.url,
  });

  final int port;
  final String process;
  final String url;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'port': port,
    'process': process,
    'url': url,
  };
}

/// Snapshot of measured host battery, memory and disk (`UDC-15` S15.4).
class SystemVitalsSnapshot {
  const SystemVitalsSnapshot({
    this.batteryPercent,
    this.isCharging,
    this.memoryUsedPercent,
    this.diskFreeGb,
    required this.healthStatus,
  });

  /// `null` means "not measured on this host" (e.g. a desktop without a battery),
  /// never a placeholder value.
  final int? batteryPercent;
  final bool? isCharging;
  final int? memoryUsedPercent;
  final int? diskFreeGb;
  final String healthStatus;

  /// True when at least one metric was really measured.
  bool get hasAnyMeasurement =>
      batteryPercent != null ||
      memoryUsedPercent != null ||
      diskFreeGb != null;

  /// Short Vietnamese summary built only from measured values.
  String describeVi() {
    final parts = <String>[
      if (batteryPercent != null)
        'Pin $batteryPercent%${isCharging == null ? '' : (isCharging! ? ' (đang sạc)' : ' (dùng pin)')}',
      if (memoryUsedPercent != null) 'RAM $memoryUsedPercent%',
      if (diskFreeGb != null) 'Ổ trống $diskFreeGb GB',
    ];
    return parts.isEmpty ? 'Chưa đọc được thông số máy' : parts.join(' · ');
  }

  Map<String, Object?> toWireJson() => <String, Object?>{
    if (batteryPercent != null) 'batteryPercent': batteryPercent,
    if (isCharging != null) 'isCharging': isCharging,
    if (memoryUsedPercent != null) 'memoryUsedPercent': memoryUsedPercent,
    if (diskFreeGb != null) 'diskFreeGb': diskFreeGb,
    'healthStatus': healthStatus,
  };
}

/// Frozen Time-Travel Workspace Capsule (`SYM-1` S1.1).
class WorkspaceCapsuleEntry {
  const WorkspaceCapsuleEntry({
    required this.capsuleId,
    required this.project,
    required this.branch,
    required this.dirtyCount,
    required this.nextStepHint,
    required this.createdAt,
  });

  final String capsuleId;
  final String project;
  final String branch;
  final int dirtyCount;
  final String nextStepHint;
  final String createdAt;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'capsuleId': capsuleId,
    'project': project,
    'branch': branch,
    'dirtyCount': dirtyCount,
    'nextStepHint': nextStepHint,
    'createdAt': createdAt,
  };
}

/// Secret-redacted item stored in XUNA Universal Pocket (`SYM-1` S1.1).
class UniversalPocketItem {
  const UniversalPocketItem({
    required this.itemId,
    required this.kind,
    required this.label,
    required this.text,
    required this.preview,
    required this.sourceDevice,
    required this.createdAt,
    required this.redactedCount,
    required this.suggestedActions,
  });

  final String itemId;
  final String kind;
  final String label;
  final String text;
  final String preview;
  final String sourceDevice;
  final String createdAt;
  final int redactedCount;
  final List<String> suggestedActions;

  Map<String, Object?> toWireListJson() => <String, Object?>{
    'itemId': itemId,
    'kind': kind,
    'label': label,
    'preview': preview,
    'sourceDevice': sourceDevice,
    'createdAt': createdAt,
  };
}

/// Autonomous background watchdog sentinel entry (`SYM-2` S2.1).
class WatchdogSentinelEntry {
  const WatchdogSentinelEntry({
    required this.watchdogId,
    required this.kind,
    required this.target,
    required this.status,
    required this.triggered,
    required this.summary,
    required this.createdAt,
  });

  final String watchdogId;
  final String kind;
  final String target;
  final String status;
  final bool triggered;
  final String summary;
  final String createdAt;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'watchdogId': watchdogId,
    'kind': kind,
    'target': target,
    'status': status,
    'triggered': triggered,
    'summary': summary,
    'createdAt': createdAt,
  };
}

/// Forged personal citizen tool entry in XUNA OmniForge (`FORGE-1`, `FORGE-2`, `WORKSHOP-2`, `FORGE-LATM`).
class ForgedSkillEntry {
  const ForgedSkillEntry({
    required this.skillId,
    required this.titleVi,
    required this.category,
    required this.goal,
    required this.targetFolder,
    required this.fileExtensions,
    required this.detectedItemsCount,
    required this.dryRunSample,
    required this.selfDebugIterations,
    required this.parameterFields,
    required this.scriptSteps,
    required this.summaryVi,
    required this.createdAt,
    this.toolName = '',
    this.runtime = 'pipeline',
    this.scriptCode = '',
    this.lastStdoutPreview = '',
    this.lastStderrPreview = '',
    this.runCount = 0,
    this.lastRunSummaryVi,
    this.selfHealGeneration = 0,
    this.correctionRules = const <String>[],
    this.primitives = const <String>[],
    this.canvasSurfaceKind = 'data_table',
    this.version = 1,
    this.versionHistory = const <String>['v1: Khởi tạo kỹ năng gốc'],
    this.autoTriggerOnDelta = false,
    this.selfTestPassed = true,
  });

  final String skillId;
  final String titleVi;
  final String category;
  final String goal;
  final String targetFolder;
  final List<String> fileExtensions;
  final int detectedItemsCount;
  final String dryRunSample;
  final int selfDebugIterations;
  final List<Map<String, Object?>> parameterFields;
  final List<String> scriptSteps;
  final String summaryVi;
  final String createdAt;
  final String toolName;
  final String runtime;
  final String scriptCode;
  final String lastStdoutPreview;
  final String lastStderrPreview;
  final int runCount;
  final String? lastRunSummaryVi;
  final int selfHealGeneration;
  final List<String> correctionRules;
  final List<String> primitives;
  final String canvasSurfaceKind;
  final int version;
  final List<String> versionHistory;
  final bool autoTriggerOnDelta;
  final bool selfTestPassed;

  ForgedSkillEntry copyWith({
    String? goal,
    String? targetFolder,
    String? dryRunSample,
    int? selfDebugIterations,
    List<String>? scriptSteps,
    String? summaryVi,
    String? toolName,
    String? runtime,
    String? scriptCode,
    String? lastStdoutPreview,
    String? lastStderrPreview,
    int? runCount,
    String? lastRunSummaryVi,
    int? selfHealGeneration,
    List<String>? correctionRules,
    List<String>? primitives,
    String? canvasSurfaceKind,
    int? version,
    List<String>? versionHistory,
    bool? autoTriggerOnDelta,
    bool? selfTestPassed,
  }) => ForgedSkillEntry(
    skillId: skillId,
    titleVi: titleVi,
    category: category,
    goal: goal ?? this.goal,
    targetFolder: targetFolder ?? this.targetFolder,
    fileExtensions: fileExtensions,
    detectedItemsCount: detectedItemsCount,
    dryRunSample: dryRunSample ?? this.dryRunSample,
    selfDebugIterations: selfDebugIterations ?? this.selfDebugIterations,
    parameterFields: parameterFields,
    scriptSteps: scriptSteps ?? this.scriptSteps,
    summaryVi: summaryVi ?? this.summaryVi,
    createdAt: createdAt,
    toolName: toolName ?? this.toolName,
    runtime: runtime ?? this.runtime,
    scriptCode: scriptCode ?? this.scriptCode,
    lastStdoutPreview: lastStdoutPreview ?? this.lastStdoutPreview,
    lastStderrPreview: lastStderrPreview ?? this.lastStderrPreview,
    runCount: runCount ?? this.runCount,
    lastRunSummaryVi: lastRunSummaryVi ?? this.lastRunSummaryVi,
    selfHealGeneration: selfHealGeneration ?? this.selfHealGeneration,
    correctionRules: correctionRules ?? this.correctionRules,
    primitives: primitives ?? this.primitives,
    canvasSurfaceKind: canvasSurfaceKind ?? this.canvasSurfaceKind,
    version: version ?? this.version,
    versionHistory: versionHistory ?? this.versionHistory,
    autoTriggerOnDelta: autoTriggerOnDelta ?? this.autoTriggerOnDelta,
    selfTestPassed: selfTestPassed ?? this.selfTestPassed,
  );

  Map<String, Object?> toWireJson() => <String, Object?>{
    'skillId': skillId,
    if (toolName.isNotEmpty) 'toolName': toolName,
    'runtime': runtime,
    'titleVi': titleVi,
    'category': category,
    'goal': goal,
    'targetFolder': targetFolder,
    'fileExtensions': fileExtensions,
    'detectedItemsCount': detectedItemsCount,
    'dryRunOk': selfTestPassed,
    'dryRunSample': dryRunSample,
    if (lastStdoutPreview.isNotEmpty) 'stdoutPreview': lastStdoutPreview,
    if (lastStderrPreview.isNotEmpty) 'stderrPreview': lastStderrPreview,
    'selfDebugIterations': selfDebugIterations,
    'parameterFields': parameterFields,
    'scriptSteps': scriptSteps,
    'summaryVi': summaryVi,
    'createdAt': createdAt,
    'runCount': runCount,
    if (lastRunSummaryVi != null) 'lastRunSummaryVi': lastRunSummaryVi,
    'selfHealGeneration': selfHealGeneration,
    'correctionRules': correctionRules,
    'primitives': primitives,
    'canvasSurfaceKind': canvasSurfaceKind,
    'version': version,
    'versionHistory': versionHistory,
    'autoTriggerOnDelta': autoTriggerOnDelta,
    'selfTestPassed': selfTestPassed,
  };

  Map<String, Object?> toDiskRecipeJson() => <String, Object?>{
    ...toWireJson(),
    if (scriptCode.isNotEmpty) 'scriptCode': scriptCode,
  };

  factory ForgedSkillEntry.fromDiskRecipeJson(Map<String, Object?> json) {
    List<String> readStringList(Object? raw, List<String> fallback) {
      if (raw is List) {
        final items = raw.whereType<String>().toList(growable: false);
        if (items.isNotEmpty) return List<String>.unmodifiable(items);
      }
      return fallback;
    }

    List<Map<String, Object?>> readParamFields(Object? raw) {
      if (raw is List) {
        final out = <Map<String, Object?>>[];
        for (final item in raw) {
          if (item is Map) {
            out.add(
              item.map((k, v) => MapEntry<String, Object?>(k.toString(), v)),
            );
          }
        }
        if (out.isNotEmpty) {
          return List<Map<String, Object?>>.unmodifiable(out);
        }
      }
      return const <Map<String, Object?>>[
        <String, Object?>{
          'name': 'argsJson',
          'type': 'string',
          'default': '{}',
        },
      ];
    }

    final skillId = (json['skillId'] as String? ?? '').trim();
    final titleVi = (json['titleVi'] as String? ?? 'Công cụ tùy chỉnh').trim();
    final category = (json['category'] as String? ?? 'custom_automation').trim();
    final goal = (json['goal'] as String? ?? titleVi).trim();
    final targetFolder =
        (json['targetFolder'] as String? ?? 'XUNA_Tools/Output').trim();
    final toolName = (json['toolName'] as String? ?? '').trim();
    final runtime = (json['runtime'] as String? ?? 'pipeline').trim();
    final scriptCode = json['scriptCode'] as String? ?? '';
    final selfTestPassed =
        (json['selfTestPassed'] as bool?) ??
        (json['dryRunOk'] as bool?) ??
        true;

    return ForgedSkillEntry(
      skillId: skillId.isEmpty ? 'skill_reloaded_1' : skillId,
      titleVi: titleVi,
      category: category,
      goal: goal,
      targetFolder: targetFolder,
      fileExtensions: readStringList(
        json['fileExtensions'],
        const <String>['.json', '.txt'],
      ),
      detectedItemsCount: (json['detectedItemsCount'] as num?)?.toInt() ?? 0,
      dryRunSample: (json['dryRunSample'] as String? ?? '').trim(),
      selfDebugIterations: (json['selfDebugIterations'] as num?)?.toInt() ?? 1,
      parameterFields: readParamFields(json['parameterFields']),
      scriptSteps: readStringList(
        json['scriptSteps'],
        const <String>['1. Nạp từ đĩa'],
      ),
      summaryVi: (json['summaryVi'] as String? ?? titleVi).trim(),
      createdAt:
          (json['createdAt'] as String? ?? DateTime.now().toUtc().toIso8601String())
              .trim(),
      toolName: toolName,
      runtime: runtime,
      scriptCode: scriptCode,
      lastStdoutPreview: (json['stdoutPreview'] as String? ?? '').trim(),
      lastStderrPreview: (json['stderrPreview'] as String? ?? '').trim(),
      runCount: (json['runCount'] as num?)?.toInt() ?? 0,
      lastRunSummaryVi: json['lastRunSummaryVi'] as String?,
      selfHealGeneration: (json['selfHealGeneration'] as num?)?.toInt() ?? 0,
      correctionRules: readStringList(
        json['correctionRules'],
        const <String>[],
      ),
      primitives: readStringList(json['primitives'], const <String>[]),
      canvasSurfaceKind:
          (json['canvasSurfaceKind'] as String? ?? 'data_table').trim(),
      version: (json['version'] as num?)?.toInt() ?? 1,
      versionHistory: readStringList(
        json['versionHistory'],
        const <String>['v1: Khởi tạo kỹ năng gốc'],
      ),
      autoTriggerOnDelta: (json['autoTriggerOnDelta'] as bool?) ?? false,
      selfTestPassed: selfTestPassed,
    );
  }
}

/// Snapshot of XUNA's Zero-Token 2-Tier Heartbeat (`CLAW-2`).
class HeartbeatStatusSnapshot {
  const HeartbeatStatusSnapshot({
    required this.status,
    required this.deltaDetected,
    required this.llmTokensUsed,
    required this.suppressedNotification,
    required this.intervalMinutes,
    required this.checkName,
    required this.summaryVi,
  });

  final String status;
  final bool deltaDetected;
  final int llmTokensUsed;
  final bool suppressedNotification;
  final int intervalMinutes;
  final String checkName;
  final String summaryVi;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'status': status,
    'deltaDetected': deltaDetected,
    'llmTokensUsed': llmTokensUsed,
    'suppressedNotification': suppressedNotification,
    'intervalMinutes': intervalMinutes,
    'summaryVi': summaryVi,
  };
}

/// Interactive Agent-to-UI (`A2UI`) Live Canvas surface (`CLAW-3`).
class LiveCanvasSurfaceSnapshot {
  const LiveCanvasSurfaceSnapshot({
    required this.canvasId,
    required this.surfaceKind,
    required this.titleVi,
    required this.columns,
    required this.rows,
    required this.actions,
    required this.summaryVi,
  });

  final String canvasId;
  final String surfaceKind;
  final String titleVi;
  final List<String> columns;
  final List<Map<String, Object?>> rows;
  final List<String> actions;
  final String summaryVi;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'canvasId': canvasId,
    'surfaceKind': surfaceKind,
    'titleVi': titleVi,
    'columns': columns,
    'rows': rows,
    'actions': actions,
    'summaryVi': summaryVi,
  };
}

/// Recorded step during a `Show-Me-Once` (`teach.record_session`) demonstration (`FORGE-2`).
class TeachDemonstrationStep {
  const TeachDemonstrationStep({
    required this.stepIndex,
    required this.action,
    required this.selectorOrPattern,
    required this.recordedAt,
  });

  final int stepIndex;
  final String action;
  final String selectorOrPattern;
  final String recordedAt;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'stepIndex': stepIndex,
    'action': action,
    'selectorOrPattern': selectorOrPattern,
    'recordedAt': recordedAt,
  };
}

/// Self-learning App Playbook entry (`CLAW-APP-ENGINE`):
/// Stores how XUNA controls a specific macOS/Windows application across the 3-tier ladder
/// (Tier 1 Native Bridge, Tier 2 Menu-Bar Hotkeys, Tier 3 Peekaboo Semantic Map `[B1]`, `[T1]`).
class AppPlaybookEntry {
  const AppPlaybookEntry({
    required this.appId,
    required this.appName,
    required this.executionTier,
    required this.tierBadgeVi,
    required this.learnedShortcuts,
    required this.peekabooNodes,
    required this.quickActionsVi,
    required this.lastActionSummaryVi,
    this.runCount = 1,
  });

  final String appId;
  final String appName;
  final int executionTier;
  final String tierBadgeVi;
  final List<String> learnedShortcuts;
  final List<String> peekabooNodes;
  final List<String> quickActionsVi;
  final String lastActionSummaryVi;
  final int runCount;

  AppPlaybookEntry copyWith({
    String? lastActionSummaryVi,
    int? runCount,
  }) => AppPlaybookEntry(
    appId: appId,
    appName: appName,
    executionTier: executionTier,
    tierBadgeVi: tierBadgeVi,
    learnedShortcuts: learnedShortcuts,
    peekabooNodes: peekabooNodes,
    quickActionsVi: quickActionsVi,
    lastActionSummaryVi: lastActionSummaryVi ?? this.lastActionSummaryVi,
    runCount: runCount ?? this.runCount,
  );

  Map<String, Object?> toWireJson() => <String, Object?>{
    'appId': appId,
    'appName': appName,
    'executionTier': executionTier,
    'tierBadgeVi': tierBadgeVi,
    'learnedShortcuts': learnedShortcuts,
    'peekabooNodes': peekabooNodes,
    'quickActionsVi': quickActionsVi,
    'lastActionSummaryVi': lastActionSummaryVi,
    'runCount': runCount,
  };
}

/// Human-in-the-Loop Handover snapshot (`CLAW-APP-ENGINE`):
/// Pauses automation when XUNA encounters a login, 2FA/OTP, Captcha, or payment screen
/// and resumes seamlessly once the owner clicks "Làm tiếp".
class HumanHandoverSnapshot {
  const HumanHandoverSnapshot({
    required this.handoverId,
    required this.appName,
    required this.taskTitleVi,
    required this.blockerReasonVi,
    required this.remainingStepsVi,
    this.waitingForHuman = true,
  });

  final String handoverId;
  final String appName;
  final String taskTitleVi;
  final String blockerReasonVi;
  final List<String> remainingStepsVi;
  final bool waitingForHuman;
}



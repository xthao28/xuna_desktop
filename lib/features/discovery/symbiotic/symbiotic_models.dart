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

/// Snapshot of meeting & microphone state (`UDC-15` S15.2).
class MeetingStatusSnapshot {
  const MeetingStatusSnapshot({
    required this.inMeeting,
    required this.app,
    required this.micMuted,
  });

  final bool inMeeting;
  final String app;
  final bool micMuted;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'inMeeting': inMeeting,
    'app': app,
    'micMuted': micMuted,
  };
}

/// Snapshot of host battery, memory, disk, and thermal health (`UDC-15` S15.4).
class SystemVitalsSnapshot {
  const SystemVitalsSnapshot({
    required this.batteryPercent,
    required this.isCharging,
    required this.memoryUsedPercent,
    required this.diskFreeGb,
    required this.thermalState,
    required this.healthStatus,
  });

  final int batteryPercent;
  final bool isCharging;
  final int memoryUsedPercent;
  final int diskFreeGb;
  final String thermalState;
  final String healthStatus;

  Map<String, Object?> toWireJson() => <String, Object?>{
    'batteryPercent': batteryPercent,
    'isCharging': isCharging,
    'memoryUsedPercent': memoryUsedPercent,
    'diskFreeGb': diskFreeGb,
    'thermalState': thermalState,
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

/// Forged personal citizen tool entry in XUNA OmniForge (`FORGE-1`, `FORGE-2`, `WORKSHOP-2`).
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
    String? summaryVi,
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
    dryRunSample: dryRunSample,
    selfDebugIterations: selfDebugIterations,
    parameterFields: parameterFields,
    scriptSteps: scriptSteps,
    summaryVi: summaryVi ?? this.summaryVi,
    createdAt: createdAt,
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
    'titleVi': titleVi,
    'category': category,
    'goal': goal,
    'targetFolder': targetFolder,
    'fileExtensions': fileExtensions,
    'detectedItemsCount': detectedItemsCount,
    'dryRunSample': dryRunSample,
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


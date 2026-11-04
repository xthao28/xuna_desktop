import 'dart:async';

import 'package:xuna_xtp/xuna_xtp.dart';

import 'symbiotic/frontier_2026_service.dart';
import 'symbiotic/heartbeat_canvas_service.dart';
import 'symbiotic/memory_aria_service.dart';
import 'symbiotic/omniforge_service.dart';
import 'symbiotic/skill_workshop_service.dart';
import 'symbiotic/subagent_cron_service.dart';
import 'symbiotic/symbiotic_models.dart';
import 'symbiotic/symbiotic_vitals_service.dart';
import 'symbiotic/ui_accessibility_service.dart';
import 'symbiotic/universal_pipeline_service.dart';
import 'symbiotic/watchdog_coach_service.dart';
import 'symbiotic/workspace_pocket_service.dart';

export 'symbiotic/frontier_2026_service.dart';
export 'symbiotic/heartbeat_canvas_service.dart';
export 'symbiotic/memory_aria_service.dart';
export 'symbiotic/omniforge_service.dart';
export 'symbiotic/skill_workshop_service.dart';
export 'symbiotic/subagent_cron_service.dart';
export 'symbiotic/symbiotic_models.dart';
export 'symbiotic/symbiotic_vitals_service.dart';
export 'symbiotic/ui_accessibility_service.dart';
export 'symbiotic/universal_pipeline_service.dart';
export 'symbiotic/watchdog_coach_service.dart';
export 'symbiotic/workspace_pocket_service.dart';

/// Cross-platform symbiotic desktop coordinator facade (`ECO-S1`):
/// Delegates to 9 focused sub-services under `symbiotic/`:
/// - [SymbioticVitalsService] (`UDC-15` S15.1–S15.4)
/// - [WorkspacePocketService] (`SYM-1` S1.1)
/// - [WatchdogCoachService] (`SYM-2` S2.1)
/// - [OmniForgeService] (`FORGE-1`, `FORGE-2`)
/// - [UniversalPipelineService] (`UNIV-2`)
/// - [HeartbeatCanvasService] (`CLAW-2`, `CLAW-3`)
/// - [SkillWorkshopService] (`CLAW-1`, `WORKSHOP-2`)
/// - [MemoryAriaService] (`MIND-2`)
/// - [SubagentCronService] (`MIND-2`, `SWARM-2`)
class AutoSymbioticService {
  AutoSymbioticService({
    Future<void> Function(String text)? clipboardWriter,
    Future<MeetingStatusSnapshot> Function()? meetingDetector,
    Future<bool> Function(bool mute)? micMuteSetter,
    Future<List<({int port, String process})>> Function(List<int> ports)?
    portProbe,
    Future<String> Function()? lanIpResolver,
    Future<SystemVitalsSnapshot> Function()? vitalsReader,
    SandboxedToolRunner? sandboxRunner,
    bool initialInMeeting = false,
    String initialMeetingApp = 'none',
    bool initialMicMuted = false,
  }) {
    vitals = SymbioticVitalsService(
      clipboardWriter: clipboardWriter,
      meetingDetector: meetingDetector,
      micMuteSetter: micMuteSetter,
      portProbe: portProbe,
      lanIpResolver: lanIpResolver,
      vitalsReader: vitalsReader,
      initialInMeeting: initialInMeeting,
      initialMeetingApp: initialMeetingApp,
      initialMicMuted: initialMicMuted,
    );
    workspacePocket = WorkspacePocketService();
    watchdogCoach = WatchdogCoachService(vitalsService: vitals);
    forge = OmniForgeService(sandboxRunner: sandboxRunner);
    late final HeartbeatCanvasService hbCanvas;
    pipeline = UniversalPipelineService(
      forgeService: forge,
      onCanvasUpdated: (snap) => hbCanvas.updateActiveCanvas(snap),
    );
    hbCanvas = HeartbeatCanvasService(
      forgeService: forge,
      pipelineService: pipeline,
    );
    heartbeatCanvas = hbCanvas;
    workshop = SkillWorkshopService(
      forgeService: forge,
      pipelineService: pipeline,
      heartbeatCanvasService: heartbeatCanvas,
    );
    memoryAria = MemoryAriaService();
    subagentCron = SubagentCronService(
      pipelineService: pipeline,
      memoryAriaService: memoryAria,
      workshopService: workshop,
      forgeService: forge,
    );
    frontier2026 = Frontier2026Service(
      pocketService: workspacePocket,
      canvasService: heartbeatCanvas,
    );
    uiAccessibility = UiAccessibilityTreeService(
      canvasService: heartbeatCanvas,
    );
  }

  late final SymbioticVitalsService vitals;
  late final WorkspacePocketService workspacePocket;
  late final WatchdogCoachService watchdogCoach;
  late final OmniForgeService forge;
  late final UniversalPipelineService pipeline;
  late final HeartbeatCanvasService heartbeatCanvas;
  late final SkillWorkshopService workshop;
  late final MemoryAriaService memoryAria;
  late final SubagentCronService subagentCron;
  late final Frontier2026Service frontier2026;
  late final UiAccessibilityTreeService uiAccessibility;

  bool get isTeachRecordingActive => forge.isTeachRecordingActive;
  HeartbeatStatusSnapshot? get lastHeartbeatStatus =>
      heartbeatCanvas.lastHeartbeatStatus;
  LiveCanvasSurfaceSnapshot? get activeLiveCanvas =>
      heartbeatCanvas.activeLiveCanvas;
  String get debugLastClipboardText => vitals.debugLastClipboardText;

  // ── SYM-1: Workspace Capsules & Universal Pocket ──────────────────────────

  WorkspaceCapsuleEntry captureWorkspaceCapsule({
    required String project,
    required String branch,
    required int dirtyCount,
    String? nextStepHint,
    DateTime? nowUtc,
  }) => workspacePocket.captureWorkspaceCapsule(
    project: project,
    branch: branch,
    dirtyCount: dirtyCount,
    nextStepHint: nextStepHint,
    nowUtc: nowUtc,
  );

  List<WorkspaceCapsuleEntry> listWorkspaceCapsules({int limit = 10}) =>
      workspacePocket.listWorkspaceCapsules(limit: limit);

  WorkspaceCapsuleEntry? findWorkspaceCapsule({
    String? capsuleId,
    String? project,
  }) => workspacePocket.findWorkspaceCapsule(
    capsuleId: capsuleId,
    project: project,
  );

  bool removeWorkspaceCapsule(String capsuleId) =>
      workspacePocket.removeWorkspaceCapsule(capsuleId);

  bool removePocketItem(String itemId) =>
      workspacePocket.removePocketItem(itemId);

  void clearWorkspaceAndPocket() => workspacePocket.clearAll();

  UniversalPocketItem pushPocketItem({
    required String rawText,
    String? label,
    String? kind,
    String? sourceDevice,
    DateTime? nowUtc,
  }) => workspacePocket.pushPocketItem(
    rawText: rawText,
    label: label,
    kind: kind,
    sourceDevice: sourceDevice,
    nowUtc: nowUtc,
  );

  List<UniversalPocketItem> listPocketItems({
    String? kind,
    String? query,
    int limit = 10,
  }) =>
      workspacePocket.listPocketItems(kind: kind, query: query, limit: limit);

  ({String mode, String transformedText, int itemCount}) transformPocketItem({
    String? itemId,
    String? rawText,
    required String mode,
  }) => workspacePocket.transformPocketItem(
    itemId: itemId,
    rawText: rawText,
    mode: mode,
  );

  static String classifyPocketKind(String text) =>
      WorkspacePocketService.classifyPocketKind(text);

  static List<String> suggestActionsForKind(String kind) =>
      WorkspacePocketService.suggestActionsForKind(kind);

  // ── UDC-15: Clipboard, Meeting, Dev Ports & System Vitals ─────────────────

  Future<({bool written, int charCount, int redactedCount})> writeClipboardText(
    String rawText,
  ) => vitals.writeClipboardText(rawText);

  Future<MeetingStatusSnapshot> getMeetingStatus() => vitals.getMeetingStatus();

  Future<
    ({
      String action,
      bool micMuted,
      bool previousMicMuted,
      String inverseAction,
      String app,
    })
  >
  controlMeeting(String action) => vitals.controlMeeting(action);

  Future<({String lanIp, List<DevPortEntry> activePorts})> scanDevPorts({
    List<int>? ports,
  }) => vitals.scanDevPorts(ports: ports);

  Future<SystemVitalsSnapshot> readSystemVitals() => vitals.readSystemVitals();

  // ── SYM-2: Watchdogs, Coach, Desk Whisper & Habit Miner ───────────────────

  Future<
    ({
      String watchdogId,
      String targetKind,
      String targetValue,
      String status,
      String summary,
    })
  >
  registerProcessOrPortWatchdog({
    required String targetKind,
    String? processName,
    int? port,
    String? label,
    DateTime? nowUtc,
  }) => watchdogCoach.registerProcessOrPortWatchdog(
    targetKind: targetKind,
    processName: processName,
    port: port,
    label: label,
    nowUtc: nowUtc,
  );

  Future<
    ({
      String watchdogId,
      String metric,
      int threshold,
      int currentValue,
      bool triggered,
      String summary,
    })
  >
  registerResourceWatchdog({
    required String metric,
    required int threshold,
    DateTime? nowUtc,
  }) => watchdogCoach.registerResourceWatchdog(
    metric: metric,
    threshold: threshold,
    nowUtc: nowUtc,
  );

  ({List<Map<String, Object?>> watchdogs, int clearedCount})
  listAndClearWatchdogs({String action = 'list'}) =>
      watchdogCoach.listAndClearWatchdogs(action: action);

  ({
    String goal,
    String project,
    String firstFiveMinuteStep,
    List<String> followUpSteps,
    String encouragementVi,
  })
  decomposeOverwhelm({required String goal, String? project}) =>
      watchdogCoach.decomposeOverwhelm(goal: goal, project: project);

  ({
    String topic,
    String whisperLine,
    List<String> bulletPoints,
    bool silentMode,
  })
  buildDeskWhisperDigest({required String topic, String? contextHint}) =>
      watchdogCoach.buildDeskWhisperDigest(
        topic: topic,
        contextHint: contextHint,
      );

  void recordToolExecution(String toolName) =>
      watchdogCoach.recordToolExecution(toolName);

  List<Map<String, Object?>> proposeHabitWorkflows({int minOccurrences = 2}) =>
      watchdogCoach.proposeHabitWorkflows(minOccurrences: minOccurrences);

  // ── FORGE-1 & FORGE-2: OmniForge & Show-Me-Once ───────────────────────────

  static String inferForgeSkillCategory(String goal) =>
      OmniForgeService.inferForgeSkillCategory(goal);

  ForgedSkillEntry synthesizeSkill({
    required String goal,
    String? category,
    String? targetFolder,
    List<String>? fileExtensions,
    String? toolName,
    String? runtime,
    String? scriptCode,
    String? testArgsJson,
    String? skillIdToUpdate,
    DateTime? nowUtc,
  }) => forge.synthesizeSkill(
    goal: goal,
    category: category,
    targetFolder: targetFolder,
    fileExtensions: fileExtensions,
    toolName: toolName,
    runtime: runtime,
    scriptCode: scriptCode,
    testArgsJson: testArgsJson,
    skillIdToUpdate: skillIdToUpdate,
    nowUtc: nowUtc,
  );

  ({
    String skillId,
    String runtime,
    int exitCode,
    int processedCount,
    String outputDirectory,
    String exportedCsvFile,
    String stdoutPreview,
    String stderrPreview,
    int selfHealedSelectors,
    String undoSnapshotId,
    String summaryVi,
  })
  runForgedSkill({
    required String skillId,
    int? maxItems,
    String? outputFolder,
    bool exportCsv = true,
    String? argsJson,
    DateTime? nowUtc,
  }) => forge.runForgedSkill(
    skillId: skillId,
    maxItems: maxItems,
    outputFolder: outputFolder,
    exportCsv: exportCsv,
    argsJson: argsJson,
    nowUtc: nowUtc,
  );

  List<ToolDescriptor> buildDynamicToolDescriptors({
    XtpPermissionState defaultPermission = XtpPermissionState.granted,
  }) => forge.buildDynamicToolDescriptors(defaultPermission: defaultPermission);

  ({List<Map<String, Object?>> skills, String exportedRecipeJson})
  listAndManageForgedSkills({String action = 'list', String? skillId}) =>
      forge.listAndManageForgedSkills(action: action, skillId: skillId);

  List<ForgedSkillEntry> listForgedSkillEntries() =>
      forge.listForgedSkillEntries();

  ({
    bool recordingActive,
    int capturedStepsCount,
    String compiledSkillId,
    String generalizedLoopSummaryVi,
  })
  handleTeachSession({
    required String mode,
    String? skillTitle,
    String? demonstratedAction,
    String? selectorOrPattern,
    DateTime? nowUtc,
  }) => forge.handleTeachSession(
    mode: mode,
    skillTitle: skillTitle,
    demonstratedAction: demonstratedAction,
    selectorOrPattern: selectorOrPattern,
    nowUtc: nowUtc,
  );

  ({
    int invoiceCount,
    int totalAmountVnd,
    int duplicateCount,
    String outputCsvFile,
    List<Map<String, Object?>> rows,
    String summaryVi,
  })
  extractInvoicesToSheet({
    required String sourceFolder,
    String? outputFileName,
    bool detectDuplicates = true,
  }) => forge.extractInvoicesToSheet(
    sourceFolder: sourceFolder,
    outputFileName: outputFileName,
    detectDuplicates: detectDuplicates,
  );

  // ── CLAW-1..3 & WORKSHOP-2: SKILL.md, Heartbeat, Live Canvas & Workshop ───

  ({
    String action,
    String skillId,
    String titleVi,
    String skillMarkdown,
    bool securityVerified,
    String summaryVi,
  })
  bridgeSkillMarkdown({
    required String action,
    String? skillId,
    String? markdownContent,
    DateTime? nowUtc,
  }) => workshop.bridgeSkillMarkdown(
    action: action,
    skillId: skillId,
    markdownContent: markdownContent,
    nowUtc: nowUtc,
  );

  ({
    String skillId,
    int selfHealGeneration,
    List<String> correctionRules,
    String summaryVi,
  })
  recordSkillCorrection({
    String action = 'record',
    required String skillId,
    String? correctionNote,
  }) => workshop.recordSkillCorrection(
    action: action,
    skillId: skillId,
    correctionNote: correctionNote,
  );

  HeartbeatStatusSnapshot configureAndTickHeartbeat({
    String action = 'tick',
    String? checkName,
    int? intervalMinutes,
    bool simulateDelta = false,
    String? watchedDirectoryPath,
    String? watchedContent,
  }) => heartbeatCanvas.configureAndTickHeartbeat(
    action: action,
    checkName: checkName,
    intervalMinutes: intervalMinutes,
    simulateDelta: simulateDelta,
    watchedDirectoryPath: watchedDirectoryPath,
    watchedContent: watchedContent,
  );

  LiveCanvasSurfaceSnapshot presentLiveCanvas({
    String action = 'present_invoice_table',
    String? title,
    String? sourceSkillId,
  }) => heartbeatCanvas.presentLiveCanvas(
    action: action,
    title: title,
    sourceSkillId: sourceSkillId,
  );

  ({
    String action,
    String workshopFolder,
    int syncedCount,
    int version,
    List<Map<String, Object?>> compactIndex,
    String summaryVi,
  })
  syncSkillWorkshop({
    required String action,
    String? skillId,
    String? workshopFolder,
    DateTime? nowUtc,
  }) => workshop.syncSkillWorkshop(
    action: action,
    skillId: skillId,
    workshopFolder: workshopFolder,
    nowUtc: nowUtc,
  );

  ({
    String chainId,
    List<String> executedSkills,
    int passedAssertions,
    int totalAssertions,
    bool selfTestPassed,
    bool autoTriggerOnDelta,
    String undoSnapshotId,
    String summaryVi,
  })
  executeSkillChainAndTest({
    required List<String> chainSkillIds,
    Map<String, String>? runtimeParams,
    bool autoTriggerOnDelta = false,
    DateTime? nowUtc,
  }) => workshop.executeSkillChainAndTest(
    chainSkillIds: chainSkillIds,
    runtimeParams: runtimeParams,
    autoTriggerOnDelta: autoTriggerOnDelta,
    nowUtc: nowUtc,
  );

  // ── UNIV-2: Universal Parser, Reconciler, Exporter, Batch Ops & Pipeline ──

  List<Map<String, Object?>> parseUniversalContent(
    String rawContent, {
    String format = 'auto',
    String sourceName = 'inline',
  }) => pipeline.parseUniversalContent(
    rawContent,
    format: format,
    sourceName: sourceName,
  );

  List<Map<String, Object?>> reconcileUniversalTables(
    List<Map<String, Object?>> primaryRows,
    List<Map<String, Object?>> secondaryRows,
  ) => pipeline.reconcileUniversalTables(primaryRows, secondaryRows);

  String exportUniversalArtifactToDisk({
    required String filePath,
    required String format,
    required String titleVi,
    required List<Map<String, Object?>> rows,
  }) => pipeline.exportUniversalArtifactToDisk(
    filePath: filePath,
    format: format,
    titleVi: titleVi,
    rows: rows,
  );

  List<({String oldPath, String newPath})> executeBatchFileOpsInDirectory({
    required String directoryPath,
    String prefix = 'XUNA_Item',
  }) => pipeline.executeBatchFileOpsInDirectory(
    directoryPath: directoryPath,
    prefix: prefix,
  );

  int undoLastBatchFileOps() => pipeline.undoLastBatchFileOps();

  ({
    String pipelineId,
    String category,
    List<String> executedPrimitives,
    int processedCount,
    String exportedFile,
    String canvasSurfaceKind,
    List<Map<String, Object?>> rows,
    String undoSnapshotId,
    String summaryVi,
  })
  executeUniversalPipeline({
    required String goal,
    List<String>? primitives,
    String? sourceFolder,
    String? rawInputText,
    String? secondaryInputText,
    String exportFormat = 'csv',
    String? outputFileName,
    DateTime? nowUtc,
  }) => pipeline.executeUniversalPipeline(
    goal: goal,
    primitives: primitives,
    sourceFolder: sourceFolder,
    rawInputText: rawInputText,
    secondaryInputText: secondaryInputText,
    exportFormat: exportFormat,
    outputFileName: outputFileName,
    nowUtc: nowUtc,
  );

  // ── MIND-2 & SWARM-2: Memory Vault, ARIA Snapshot, Subagent & Cron ────────

  ({
    String action,
    String vaultFolder,
    String soulMarkdown,
    String ownerProfileMarkdown,
    String memoryJournalMarkdown,
    int flushedFactsCount,
    int redactedSecretsCount,
    String summaryVi,
  })
  manageMarkdownMemoryVault({
    required String action,
    String? targetFile,
    String? noteContent,
    String? sessionTranscript,
    String? vaultFolder,
    DateTime? nowUtc,
  }) => memoryAria.manageMarkdownMemoryVault(
    action: action,
    targetFile: targetFile,
    noteContent: noteContent,
    sessionTranscript: sessionTranscript,
    vaultFolder: vaultFolder,
    nowUtc: nowUtc,
  );

  ({
    String snapshotId,
    String pageTitle,
    int elementCount,
    int tokenReductionPercent,
    String compactAriaTree,
    List<Map<String, Object?>> elements,
    String summaryVi,
  })
  captureSemanticBrowserSnapshot({
    String? rawHtml,
    String? pageTitle,
    int maxElements = 25,
  }) => memoryAria.captureSemanticBrowserSnapshot(
    rawHtml: rawHtml,
    pageTitle: pageTitle,
    maxElements: maxElements,
  );

  ({
    String action,
    String workerId,
    String status,
    int progressPercent,
    int tokenBudget,
    int tokensUsed,
    int llmTokensUsed,
    int contextSavedPercent,
    String distilledResultVi,
    List<Map<String, Object?>> activeWorkers,
    List<Map<String, Object?>> blackboardEntries,
    bool criticPassed,
    int criticConfidenceScore,
    List<Map<String, Object?>> specialistBreakdown,
    String summaryVi,
  })
  spawnOrPollSubagent({
    required String action,
    String? taskGoal,
    String? workerId,
    int tokenBudget = 2048,
    String? sourceFolder,
    List<String>? specialistRoles,
    bool enableCriticVerification = true,
    DateTime? nowUtc,
  }) => subagentCron.spawnOrPollSubagent(
    action: action,
    taskGoal: taskGoal,
    workerId: workerId,
    tokenBudget: tokenBudget,
    sourceFolder: sourceFolder,
    specialistRoles: specialistRoles,
    enableCriticVerification: enableCriticVerification,
    nowUtc: nowUtc,
  );

  ({
    String action,
    String hookId,
    String eventOrCron,
    String targetSkillId,
    int triggeredCount,
    List<Map<String, Object?>> activeHooks,
    String undoSnapshotId,
    String summaryVi,
  })
  manageCronAndHooks({
    required String action,
    String? hookId,
    String? eventOrCron,
    String? targetSkillId,
    String? labelVi,
    DateTime? nowUtc,
  }) => subagentCron.manageCronAndHooks(
    action: action,
    hookId: hookId,
    eventOrCron: eventOrCron,
    targetSkillId: targetSkillId,
    labelVi: labelVi,
    nowUtc: nowUtc,
  );

  // ── FRONTIER-1..4: Living Overlay, Bio-Acoustic, ChronoGraph & Rituals ───

  ({
    String mode,
    bool overlayVisible,
    String anchor,
    String munchAnimation,
    String routedTarget,
    int redactedSecretsCount,
    String summaryVi,
  })
  manageOverlayAndDropZone({
    required String mode,
    String? anchor,
    String? droppedItemName,
    String? droppedContent,
    String? targetAction,
    DateTime? nowUtc,
  }) => frontier2026.manageOverlayAndDropZone(
    mode: mode,
    anchor: anchor,
    droppedItemName: droppedItemName,
    droppedContent: droppedContent,
    targetAction: targetAction,
    nowUtc: nowUtc,
  );

  String get activeColorThemeId => frontier2026.activeColorThemeId;

  void syncColorTheme(String themeId, {DateTime? nowUtc}) =>
      frontier2026.syncColorTheme(themeId, nowUtc: nowUtc);

  ({
    String mode,
    String vocalKind,
    int sampleRateHz,
    int pcmByteCount,
    String wavSha256,
    String detectedOwnerTone,
    String empathyAdjustmentVi,
    String summaryVi,
  })
  vocalizeAndSenseProsody({
    required String mode,
    String? vocalKind,
    String? themeId,
    int? speechRateWpm,
    int? rmsEnergyDb,
    int? pauseRatioPercent,
  }) => frontier2026.vocalizeAndSenseProsody(
    mode: mode,
    vocalKind: vocalKind,
    themeId: themeId,
    speechRateWpm: speechRateWpm,
    rmsEnergyDb: rmsEnergyDb,
    pauseRatioPercent: pauseRatioPercent,
  );

  ({
    String mode,
    int activeEdgesCount,
    int historicalEdgesCount,
    String supersededEdgeId,
    String temporalNarrativeVi,
    List<Map<String, Object?>> constellationNodes,
    List<Map<String, Object?>> constellationEdges,
    String summaryVi,
  })
  manageTemporalLifeGraph({
    required String mode,
    String? subject,
    String? predicate,
    String? object,
    String? validFromIso,
    DateTime? nowUtc,
  }) => frontier2026.manageTemporalLifeGraph(
    mode: mode,
    subject: subject,
    predicate: predicate,
    object: object,
    validFromIso: validFromIso,
    nowUtc: nowUtc,
  );

  ({
    String mode,
    String activeRitual,
    String cadencePattern,
    bool standbyDockActive,
    String unlockedKeepsakeVi,
    String playdateSummaryVi,
    String summaryVi,
  })
  executeMindfulRitualAndPlaydate({
    required String mode,
    int? durationMinutes,
    String? focusGoal,
    String? neighborShortId,
    String? giftMessage,
  }) => frontier2026.executeMindfulRitualAndPlaydate(
    mode: mode,
    durationMinutes: durationMinutes,
    focusGoal: focusGoal,
    neighborShortId: neighborShortId,
    giftMessage: giftMessage,
  );

  // ── UIA-2: Zero-Screenshot Native OS UI Automation (UIA / AXUIElement) ────

  ({
    String action,
    String windowTitle,
    int nodeCount,
    int tokenSavingsPercent,
    int screenshotBytesUsed,
    String compactUiTree,
    String invokedRefId,
    int redactedControlsCount,
    List<Map<String, Object?>> nodes,
    String summaryVi,
  })
  executeUiAccessibilityTree({
    required String action,
    String? windowTitle,
    String? refId,
    String? valueText,
    int maxNodes = 30,
  }) => uiAccessibility.executeUiAccessibilityTree(
    action: action,
    windowTitle: windowTitle,
    refId: refId,
    valueText: valueText,
    maxNodes: maxNodes,
  );

  // ── CLAW-APP-ENGINE: 3-Tier App Router, App Playbooks & Human Handover ────

  List<AppPlaybookEntry> listAppPlaybooks() =>
      uiAccessibility.listAppPlaybooks();

  HumanHandoverSnapshot? get activeHandover => uiAccessibility.activeHandover;

  String get activeFocusedAppName => uiAccessibility.activeFocusedAppName;

  AppPlaybookEntry switchActiveFocusedApp(String appName) =>
      uiAccessibility.switchActiveFocusedApp(appName);

  AppPlaybookEntry learnOrInspectApp(
    String rawAppName, {
    String? customActionVi,
  }) => uiAccessibility.learnOrInspectApp(
    rawAppName,
    customActionVi: customActionVi,
  );

  void removeAppPlaybook(String appId) =>
      uiAccessibility.removeAppPlaybook(appId);

  HumanHandoverSnapshot triggerHumanHandover({
    required String appName,
    required String taskTitleVi,
    String? blockerReasonVi,
    List<String>? remainingStepsVi,
  }) => uiAccessibility.triggerHumanHandover(
    appName: appName,
    taskTitleVi: taskTitleVi,
    blockerReasonVi: blockerReasonVi,
    remainingStepsVi: remainingStepsVi,
  );

  String resumeHumanHandover() => uiAccessibility.resumeHumanHandover();

  void cancelHumanHandover() => uiAccessibility.cancelHumanHandover();
}

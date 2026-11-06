import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/controller/desktop_app_automation_runner.dart';
import 'package:xuna_desktop/core/controller/desktop_skill_runner.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/core/presentation/controllers/base_getx_controller.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
import 'package:xuna_desktop/features/discovery/auto_workspace_indexer.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/lan/lan_offline_server.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/shared/themes/xuna_color_themes.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Navigation tabs inside the Desktop Agent settings window.
enum AgentWindowTab { enrollment, policy, permissions, audit, symbiotic }

/// GetX controller driving the Desktop Agent tray status and settings window.
class DesktopAgentController extends BaseGetxController {
  DesktopAgentController({
    required this.channel,
    required this.enrollmentStore,
    required this.policyStore,
    required this.auditStore,
    required this.stopController,
    required this.sessionClient,
    required this.logger,
    this.lanServer,
    this.computerUseManager,
    this.symbioticService,
  }) {
    _appAutomationRunner = DesktopAppAutomationRunner(
      channel: channel,
      appScanner: _appScanner,
      workspaceIndexer: _workspaceIndexer,
      getSymbioticService: () => symbioticService,
      getDiscoveredApps: () => discoveredApps,
      scanInstalledApps: scanInstalledApps,
      getDiscoveredWorkspaces: () => discoveredWorkspaces,
      scanWorkspaces: scanWorkspaces,
      recordedTrajectorySteps: recordedTrajectorySteps,
      resolveRealSkillDirectory: resolveRealSkillDirectory,
      setFrontierStatusSummaryVi: (msg) => frontierStatusSummaryVi.value = msg,
      refreshSymbioticState: refreshSymbioticState,
    );
    _skillRunner = DesktopSkillRunner(
      channel: channel,
      appAutomationRunner: _appAutomationRunner,
      getSymbioticService: () => symbioticService,
      setFrontierStatusSummaryVi: (msg) => frontierStatusSummaryVi.value = msg,
      refreshSymbioticState: refreshSymbioticState,
    );
  }

  final XunaHostChannel channel;
  final EnrollmentStateStore enrollmentStore;
  final HostPolicyStore policyStore;
  final AuditLogStore auditStore;
  final EmergencyStopController stopController;
  final XtpSessionClient sessionClient;
  final ContentFreeLogger logger;
  final LanOfflineServer? lanServer;
  final ComputerUseSessionManager? computerUseManager;
  final AutoSymbioticService? symbioticService;

  final activeTab = AgentWindowTab.enrollment.obs;
  final sessionPhase = HostSessionPhase.disconnected.obs;
  final pendingEnrollment = Rxn<PendingEnrollmentDisplay>();
  final enrolledState = Rxn<EnrolledHostState>();
  final isPolicyHealthy = false.obs;
  final policyBanner = RxnString();
  final activePolicy = Rxn<HostPolicy>();
  final isStopped = false.obs;
  final lanModeEnabled = false.obs;
  final activeCuSession = Rxn<ComputerUseSessionState>();
  final permissionsSnapshot = const HostPermissionSnapshot().obs;
  final recentAuditRecords = <AuditLogRecord>[].obs;
  final workspaceCapsules = <WorkspaceCapsuleEntry>[].obs;
  final pocketItems = <UniversalPocketItem>[].obs;
  final activeWatchdogs = <Map<String, Object?>>[].obs;
  final habitProposals = <Map<String, Object?>>[].obs;
  final forgedSkills = <ForgedSkillEntry>[].obs;
  final isTeachRecording = false.obs;
  final teachRecordedSteps = <String>[].obs;
  final lastHeartbeatStatus = Rxn<HeartbeatStatusSnapshot>();
  final activeLiveCanvas = Rxn<LiveCanvasSurfaceSnapshot>();
  final frontierStatusSummaryVi = ''.obs;
  final selectedColorThemeId = 'green_edition'.obs;
  final isAutoColorTheme = false.obs;
  final latestVitals = Rxn<SystemVitalsSnapshot>();
  final activeDevPorts = <DevPortEntry>[].obs;
  final detectedLanIp = ''.obs;
  final discoveredApps = <DiscoveredApp>[].obs;
  final discoveredWorkspaces = <DiscoveredWorkspace>[].obs;
  final recordedTrajectorySteps = <Map<String, Object?>>[].obs;
  final learnedAppPlaybooks = <AppPlaybookEntry>[].obs;
  final activeHandover = Rxn<HumanHandoverSnapshot>();
  final activeFocusedAppName = 'Visual Studio Code'.obs;
  final AutoAppScanner _appScanner = AutoAppScanner();
  final AutoWorkspaceIndexer _workspaceIndexer = AutoWorkspaceIndexer();
  late final DesktopAppAutomationRunner _appAutomationRunner;
  late final DesktopSkillRunner _skillRunner;

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  String get trayStatusLabel {
    if (!isPolicyHealthy.value) {
      return policyBanner.value ?? 'Cấu hình lỗi';
    }
    if (isStopped.value) {
      return 'Đã dừng khẩn cấp';
    }
    final cu = activeCuSession.value;
    if (cu != null) {
      return 'Đang điều khiển màn hình (Bước ${cu.stepsExecuted}/${cu.maxSteps})';
    }
    return switch (sessionPhase.value) {
      HostSessionPhase.ready => 'Đang kết nối',
      HostSessionPhase.enrollWaitingConfirmation => 'Chờ ghép nối',
      HostSessionPhase.connecting => 'Đang kết nối...',
      HostSessionPhase.disconnected => 'Mất kết nối',
    };
  }

  @override
  void onInit() {
    super.onInit();
    _syncFromStores();

    _subs.add(
      sessionClient.phaseChanges.listen((phase) {
        sessionPhase.value = phase;
        enrolledState.value = enrollmentStore.current;
      }),
    );
    _subs.add(
      sessionClient.enrollmentDisplayChanges.listen((display) {
        pendingEnrollment.value = display;
      }),
    );
    _subs.add(
      policyStore.changes.listen((evaluator) {
        isPolicyHealthy.value = evaluator.isHealthy;
        policyBanner.value = evaluator.trayBanner;
        activePolicy.value = evaluator.policy;
      }),
    );
    _subs.add(
      stopController.stateChanges.listen((stopped) {
        isStopped.value = stopped;
      }),
    );
    if (computerUseManager != null) {
      activeCuSession.value = computerUseManager!.activeSession;
      _subs.add(
        computerUseManager!.sessionChanges.listen((session) {
          activeCuSession.value = session;
          activeCuSession.refresh();
        }),
      );
    }
  }

  void _syncFromStores() {
    sessionPhase.value = sessionClient.phase;
    pendingEnrollment.value = sessionClient.enrollmentDisplay;
    enrolledState.value = enrollmentStore.current;
    lanModeEnabled.value = enrollmentStore.current?.lanEnabled ?? false;
    isPolicyHealthy.value = policyStore.isHealthy;
    policyBanner.value = policyStore.trayBanner;
    activePolicy.value = policyStore.evaluator.policy;
    isStopped.value = stopController.isStopped;
  }

  Future<void> initializeAgent() async {
    await enrollmentStore.load();
    await policyStore.reload();
    _syncFromStores();
    scanInstalledApps();
    scanWorkspaces();
    _skillRunner.loadPersistedForgedSkillsFromDisk();
    if (lanModeEnabled.value && lanServer != null) {
      try {
        await lanServer!.start();
      } catch (_) {}
    }
    await refreshPermissions();
    await refreshAudit();
    await sessionClient.connect();
  }

  List<DiscoveredWorkspace> scanWorkspaces({bool forceRefresh = false}) {
    try {
      final list = _workspaceIndexer.discoverWorkspaces(
        forceRefresh: forceRefresh,
      );
      discoveredWorkspaces.assignAll(list);
      return list;
    } catch (_) {
      return const <DiscoveredWorkspace>[];
    }
  }

  Future<void> toggleLanMode(bool enabled) async {
    await enrollmentStore.updateLanEnabled(enabled);
    enrolledState.value = enrollmentStore.current;
    lanModeEnabled.value = enabled;
    if (lanServer != null) {
      try {
        if (enabled) {
          await lanServer!.start();
        } else {
          await lanServer!.stop();
        }
      } catch (_) {}
    }
    sessionClient.sendLanPeerAdvertisement(
      enabled: enabled,
      port: lanServer?.boundPort ?? defaultLanOfflinePort,
    );
  }

  Future<void> refreshPermissions() async {
    try {
      permissionsSnapshot.value = await channel.permissions();
    } catch (_) {}
  }

  Future<void> requestOsPermission(String kind) async {
    try {
      await channel.requestPermission(kind);
      await refreshPermissions();
    } catch (_) {}
  }

  Future<void> refreshAudit() async {
    recentAuditRecords.assignAll(await auditStore.readRecent(limit: 50));
  }

  void refreshSymbioticState() {
    final svc = symbioticService;
    if (svc == null) return;
    workspaceCapsules.assignAll(svc.listWorkspaceCapsules());
    pocketItems.assignAll(svc.listPocketItems());
    activeWatchdogs.assignAll(
      svc.listAndClearWatchdogs(action: 'list').watchdogs,
    );
    habitProposals.assignAll(svc.proposeHabitWorkflows());
    forgedSkills.assignAll(svc.listForgedSkillEntries());
    learnedAppPlaybooks.assignAll(svc.listAppPlaybooks());
    activeHandover.value = svc.activeHandover;
    activeFocusedAppName.value = svc.activeFocusedAppName;
    isTeachRecording.value = svc.isTeachRecordingActive;
    lastHeartbeatStatus.value = svc.lastHeartbeatStatus;
    activeLiveCanvas.value = svc.activeLiveCanvas;
    selectedColorThemeId.value = svc.activeColorThemeId;
  }

  AppPlaybookEntry? learnOrInspectAppFromUi(
    String appName, {
    String? customActionVi,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final entry = svc.learnOrInspectApp(
      appName,
      customActionVi: customActionVi,
    );
    frontierStatusSummaryVi.value = entry.lastActionSummaryVi;
    refreshSymbioticState();
    if (!Platform.environment.containsKey('FLUTTER_TEST')) {
      unawaited(
        _appAutomationRunner.launchAppForPlaybookInspection(
          appName,
          entry,
          customActionVi: customActionVi,
        ),
      );
    }
    return entry;
  }

  Future<Map<String, Object?>> replayRecordedTrajectoryFromUi({
    int delayMs = 450,
    bool stopOnError = false,
  }) =>
      _appAutomationRunner.replayRecordedTrajectory(
        delayMs: delayMs,
        stopOnError: stopOnError,
      );

  void removeAppPlaybookFromUi(String appId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removeAppPlaybook(appId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa ứng dụng khỏi Sổ tay Học App';
    refreshSymbioticState();
  }

  HumanHandoverSnapshot? triggerHumanHandoverFromUi({
    required String appName,
    required String taskTitleVi,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final snap = svc.triggerHumanHandover(
      appName: appName,
      taskTitleVi: taskTitleVi,
    );
    frontierStatusSummaryVi.value = '✋ ${snap.blockerReasonVi}';
    refreshSymbioticState();
    return snap;
  }

  void resumeHumanHandoverFromUi() {
    final svc = symbioticService;
    if (svc == null) return;
    final summary = svc.resumeHumanHandover();
    frontierStatusSummaryVi.value = summary;
    refreshSymbioticState();
  }

  void cancelHumanHandoverFromUi() {
    final svc = symbioticService;
    if (svc == null) return;
    svc.cancelHumanHandover();
    frontierStatusSummaryVi.value = '⏹️ Đã hủy phiên chờ xác nhận thủ công';
    refreshSymbioticState();
  }

  XunaColorThemeData selectColorTheme(String themeId) {
    final resolved = XunaColorThemes.byId(themeId);
    isAutoColorTheme.value = false;
    selectedColorThemeId.value = resolved.id;
    symbioticService?.syncColorTheme(resolved.id);
    frontierStatusSummaryVi.value =
        '🎨 Đã đồng bộ bảng màu ${resolved.name} (${resolved.nameVi}) trên Desktop';
    return resolved;
  }

  XunaColorThemeData toggleAutoColorTheme({String? dominantTrait}) {
    final nextAuto = !isAutoColorTheme.value;
    isAutoColorTheme.value = nextAuto;
    final resolved = nextAuto
        ? XunaColorThemes.resolveAutoThemeForTraits(
            dominantTrait: dominantTrait ?? 'curiosity',
          )
        : XunaColorThemes.byId(selectedColorThemeId.value);
    selectedColorThemeId.value = resolved.id;
    symbioticService?.syncColorTheme(resolved.id);
    frontierStatusSummaryVi.value = nextAuto
        ? '✨ Đã bật tự động tiến hoá màu (${resolved.nameVi}) trên Desktop'
        : '🎨 Đã cố định bảng màu ${resolved.name} (${resolved.nameVi}) trên Desktop';
    return resolved;
  }

  HeartbeatStatusSnapshot? runZeroTokenHeartbeatFromUi() {
    final svc = symbioticService;
    if (svc == null) return null;
    final snap = svc.configureAndTickHeartbeat(action: 'tick');
    refreshSymbioticState();
    return snap;
  }

  Map<String, Object?>? recordQuickSkillCorrectionFromUi(
    String skillId, {
    required String correctionNote,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final res = svc.recordSkillCorrection(
      action: 'record',
      skillId: skillId,
      correctionNote: correctionNote,
    );
    refreshSymbioticState();
    return <String, Object?>{
      'skillId': res.skillId,
      'selfHealGeneration': res.selfHealGeneration,
      'correctionRules': res.correctionRules,
      'summaryVi': res.summaryVi,
    };
  }

  String? exportSkillMarkdownFromUi(String skillId) {
    final svc = symbioticService;
    if (svc == null) return null;
    final res = svc.bridgeSkillMarkdown(
      action: 'export_skill_md',
      skillId: skillId,
    );
    refreshSymbioticState();
    return res.skillMarkdown;
  }

  LiveCanvasSurfaceSnapshot? presentLiveCanvasFromUi({
    String action = 'present_workflow_board',
    String? title,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final snap = svc.presentLiveCanvas(action: action, title: title);
    refreshSymbioticState();
    return snap;
  }

  String resolveRealSkillDirectory(String rawFolder) =>
      DesktopSkillRunner.resolveRealSkillDirectoryStatic(rawFolder);

  ForgedSkillEntry? forgeSkillFromUi({
    required String goal,
    String? targetFolder,
    List<String>? fileExtensions,
  }) =>
      _skillRunner.forgeSkill(
        goal: goal,
        targetFolder: targetFolder,
        fileExtensions: fileExtensions,
      );

  Map<String, Object?>? runForgedSkillFromUi(String skillId) =>
      _skillRunner.runForgedSkill(skillId);

  Future<void> openForgedSkillOutputFolderFromUi(String skillId) =>
      _skillRunner.openForgedSkillOutputFolder(skillId);

  void removeForgedSkillFromUi(String skillId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.listAndManageForgedSkills(action: 'delete_one', skillId: skillId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa công cụ $skillId khỏi OmniForge';
    refreshSymbioticState();
  }

  Future<void> copySkillMarkdownToClipboard(String skillId) async {
    final md = exportSkillMarkdownFromUi(skillId);
    if (md == null || md.isEmpty) return;
    await copyTextToSystemClipboard(md, labelVi: 'tài liệu SKILL.md');
  }

  void addTeachStepFromUi(String stepText) {
    final svc = symbioticService;
    final clean = stepText.trim();
    if (svc == null || clean.isEmpty) return;
    if (!svc.isTeachRecordingActive) {
      svc.handleTeachSession(
        mode: 'start',
        skillTitle: 'Công cụ học từ thao tác mẫu',
      );
    }
    svc.handleTeachSession(
      mode: 'record_action',
      demonstratedAction: clean,
    );
    teachRecordedSteps.add(clean);
    frontierStatusSummaryVi.value = '🎥 Đã ghi nhận bước mẫu: $clean';
    refreshSymbioticState();
  }

  Map<String, Object?>? toggleTeachModeFromUi({String? customTitle}) {
    final svc = symbioticService;
    if (svc == null) return null;
    if (!svc.isTeachRecordingActive) {
      final activeApp = activeFocusedAppName.value.trim().isEmpty
          ? 'Ứng dụng đang mở'
          : activeFocusedAppName.value.trim();
      final initialTitle =
          (customTitle != null && customTitle.trim().isNotEmpty)
          ? customTitle.trim()
          : 'Tự động hóa thao tác trên $activeApp';
      svc.handleTeachSession(
        mode: 'start',
        skillTitle: initialTitle,
      );
      teachRecordedSteps.clear();
      if (!Platform.environment.containsKey('FLUTTER_TEST')) {
        unawaited(_captureLiveContextForTeachSession(activeApp));
      }
      frontierStatusSummaryVi.value =
          '🎥 Đang ở chế độ Làm mẫu 1 lần (Show-Me-Once) trên $activeApp — hãy thực hiện hoặc thêm bước thao tác rồi bấm Đóng gói thành Tool!';
      refreshSymbioticState();
      return null;
    } else {
      final activeApp = activeFocusedAppName.value.trim().isEmpty
          ? 'Máy tính'
          : activeFocusedAppName.value.trim();
      final resolvedTitle =
          (customTitle != null && customTitle.trim().isNotEmpty)
          ? customTitle.trim()
          : (teachRecordedSteps.isNotEmpty
                ? 'Quy trình tự động trên $activeApp (${teachRecordedSteps.first})'
                : 'Quy trình tự động học từ thao tác mẫu trên $activeApp');
      final res = svc.handleTeachSession(
        mode: 'stop_and_compile',
        skillTitle: resolvedTitle,
      );
      teachRecordedSteps.clear();
      frontierStatusSummaryVi.value = '🎉 ${res.generalizedLoopSummaryVi}';
      refreshSymbioticState();
      return <String, Object?>{
        'recordingActive': res.recordingActive,
        'capturedStepsCount': res.capturedStepsCount,
        'compiledSkillId': res.compiledSkillId,
        'generalizedLoopSummaryVi': res.generalizedLoopSummaryVi,
      };
    }
  }

  Future<void> _captureLiveContextForTeachSession(String fallbackApp) async {
    final svc = symbioticService;
    if (svc == null || !svc.isTeachRecordingActive) return;
    try {
      final ctx = await channel.readActiveWindowContext();
      final appName = ctx.appName.trim().isNotEmpty
          ? ctx.appName.trim()
          : fallbackApp;
      final winTitle = ctx.windowTitle.trim().isNotEmpty
          ? ctx.windowTitle.trim()
          : appName;
      final snap = await channel.inspectWindowUiTree(
        windowTitle: winTitle,
        maxNodes: 15,
      );
      final stepDesc = snap.nodes.isNotEmpty
          ? 'Quét cửa sổ "$winTitle" ($appName): ghi nhận ${snap.nodes.length} thành phần tương tác'
          : 'Ghi nhận ngữ cảnh cửa sổ đang mở: "$winTitle" ($appName)';
      if (svc.isTeachRecordingActive) {
        svc.handleTeachSession(
          mode: 'record_action',
          demonstratedAction: stepDesc,
          selectorOrPattern: snap.nodes.isNotEmpty
              ? (snap.nodes.first['refId']?.toString() ?? 'ui_1')
              : 'window:$appName',
        );
        teachRecordedSteps.add(stepDesc);
        refreshSymbioticState();
      }
    } catch (_) {}
  }

  void clearAllWatchdogs() {
    final svc = symbioticService;
    if (svc == null) return;
    svc.listAndClearWatchdogs(action: 'clear_all');
    refreshSymbioticState();
  }

  WorkspaceCapsuleEntry? captureQuickWorkspaceCapsule({
    String project = 'xuna_pet',
    String branch = 'dev',
    int dirtyCount = 0,
    String? nextStepHint,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final entry = svc.captureWorkspaceCapsule(
      project: project,
      branch: branch,
      dirtyCount: dirtyCount,
      nextStepHint: nextStepHint,
    );
    refreshSymbioticState();
    return entry;
  }

  UniversalPocketItem? pushQuickPocketSnippet(String rawText, {String? label}) {
    final svc = symbioticService;
    if (svc == null) return null;
    final clean = rawText.trim();
    if (clean.isEmpty) return null;
    final item = svc.pushPocketItem(
      rawText: clean,
      label: label,
      sourceDevice: 'desktop_ui',
    );
    frontierStatusSummaryVi.value =
        '📥 Đã cất "${item.label}" vào Bộ nhớ tạm (Pocket)';
    refreshSymbioticState();
    return item;
  }

  Future<UniversalPocketItem?> pasteSystemClipboardToPocket() async {
    String clipText = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain).timeout(
        const Duration(milliseconds: 300),
        onTimeout: () => null,
      );
      clipText = (data?.text ?? '').trim();
    } catch (_) {}
    if (clipText.isEmpty) {
      frontierStatusSummaryVi.value =
          '⚠️ Clipboard đang trống — hãy sao chép văn bản hoặc link trước nhé!';
      return null;
    }
    return pushQuickPocketSnippet(clipText, label: 'Từ Clipboard PC');
  }

  Future<void> copyTextToSystemClipboard(
    String text, {
    String labelVi = 'nội dung',
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) return;
    try {
      await symbioticService?.writeClipboardText(clean);
      await Clipboard.setData(ClipboardData(text: clean)).timeout(
        const Duration(milliseconds: 300),
        onTimeout: () {},
      );
    } catch (_) {}
    frontierStatusSummaryVi.value = '📋 Đã sao chép $labelVi vào Clipboard PC!';
  }

  void removeWorkspaceCapsule(String capsuleId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removeWorkspaceCapsule(capsuleId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa phiên làm việc đã lưu';
    refreshSymbioticState();
  }

  void removePocketItem(String itemId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removePocketItem(itemId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa mục khỏi Bộ nhớ tạm';
    refreshSymbioticState();
  }

  UniversalPocketItem? transformPocketItemFromUi(UniversalPocketItem item) {
    final svc = symbioticService;
    if (svc == null) return null;
    final mode = item.kind == 'json'
        ? 'format_json'
        : (item.suggestedActions.contains('extract_tasks')
            ? 'extract_tasks'
            : 'prepare_knowledge_fact');
    final res = svc.transformPocketItem(
      itemId: item.itemId,
      rawText: item.text,
      mode: mode,
    );
    if (res.transformedText.trim().isEmpty) return null;
    final created = svc.pushPocketItem(
      rawText: res.transformedText,
      label: 'Biến đổi: ${item.label}',
      sourceDevice: 'desktop_transform',
    );
    frontierStatusSummaryVi.value =
        '⚡ Đã biến đổi "${item.label}" (${res.mode})';
    refreshSymbioticState();
    return created;
  }

  Future<void> watchDevPortFromUi(
    int port, {
    String? label,
  }) async {
    final svc = symbioticService;
    if (svc == null) return;
    final res = await svc.registerProcessOrPortWatchdog(
      targetKind: 'port',
      port: port,
      label: label ?? 'Dev Server :$port',
    );
    frontierStatusSummaryVi.value = '🛡️ ${res.summary}';
    refreshSymbioticState();
  }

  Future<void> watchCustomTargetFromUi({
    required String targetKind,
    int? port,
    String? processName,
    String? label,
  }) async {
    final svc = symbioticService;
    if (svc == null) return;
    final res = await svc.registerProcessOrPortWatchdog(
      targetKind: targetKind,
      port: port,
      processName: processName,
      label: label,
    );
    frontierStatusSummaryVi.value = '🛡️ ${res.summary}';
    refreshSymbioticState();
  }

  Future<void> scanSystemVitalsAndPorts() async {
    final svc = symbioticService;
    if (svc == null) return;
    final vitals = await svc.readSystemVitals();
    final ports = await svc.scanDevPorts();
    latestVitals.value = vitals;
    activeDevPorts.assignAll(ports.activePorts);
    detectedLanIp.value = ports.lanIp;
    frontierStatusSummaryVi.value =
        '💻 ${vitals.describeVi()} · ${ports.activePorts.length} cổng Dev đang mở';
    refreshSymbioticState();
  }

  void clearAllSymbioticDataFromUi() {
    final svc = symbioticService;
    if (svc == null) return;
    svc.clearWorkspaceAndPocket();
    svc.listAndClearWatchdogs(action: 'clear_all');
    frontierStatusSummaryVi.value =
        '🧹 Đã làm sạch toàn bộ dữ liệu Cộng sinh trên Desktop';
    refreshSymbioticState();
  }

  Future<void> reloadPolicy() async {
    await policyStore.reload();
  }

  Future<void> restoreDefaultPolicy() async {
    await policyStore.writeDefaultPolicy();
  }

  Future<void> toggleFamilyPolicy(ToolFamily family, bool allow) async {
    final current = activePolicy.value;
    if (current == null) return;
    final nextFamilies =
        Map<ToolFamily, FamilyPolicyDecision>.from(current.families)
          ..[family] = allow
              ? FamilyPolicyDecision.allow
              : FamilyPolicyDecision.block;
    final updated = HostPolicy(
      schemaVersion: current.schemaVersion,
      families: nextFamilies,
      apps: current.apps,
      urlDomains: current.urlDomains,
      workflows: current.workflows,
      players: current.players,
    );
    await policyStore.savePolicy(updated);
  }

  List<DiscoveredApp> scanInstalledApps({
    bool forceRefresh = false,
  }) {
    try {
      final apps = _appScanner.discoverApps(forceRefresh: forceRefresh);
      discoveredApps.assignAll(apps);
      return apps;
    } catch (_) {
      return const <DiscoveredApp>[];
    }
  }

  Future<bool> addAllowedAppToPolicy({
    required String name,
    required String target,
    String? customId,
  }) async {
    final current = activePolicy.value;
    if (current == null) return false;
    final cleanName = name.trim();
    final cleanTarget = target.trim();
    if (cleanName.isEmpty || cleanTarget.isEmpty) return false;
    final rawId = (customId != null && customId.trim().isNotEmpty)
        ? customId.trim()
        : cleanName;
    final normalizedId = AutoAppScanner.normalizeId(rawId);
    final validId = isValidShortId(normalizedId)
        ? normalizedId
        : 'app_${DateTime.now().millisecondsSinceEpoch % 100000}';
    final kind = Platform.isMacOS
        ? AppLaunchKind.bundle
        : (cleanTarget.contains('!')
              ? AppLaunchKind.aumid
              : AppLaunchKind.exe);
    try {
      final entry = AllowedAppConfig(
        id: validId,
        name: cleanName.length > 80 ? cleanName.substring(0, 80) : cleanName,
        kind: kind,
        target: cleanTarget,
        risk: RiskTier.r2,
      );
      final nextApps = <AllowedAppConfig>[
        ...current.apps.where((a) => a.id != validId),
        entry,
      ];
      final updated = HostPolicy(
        schemaVersion: current.schemaVersion,
        families: current.families,
        apps: nextApps,
        urlDomains: current.urlDomains,
        workflows: current.workflows,
        players: current.players,
      );
      await policyStore.savePolicy(updated);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> removeAllowedAppFromPolicy(String appId) async {
    final current = activePolicy.value;
    if (current == null) return;
    final nextApps = current.apps.where((a) => a.id != appId).toList();
    final updated = HostPolicy(
      schemaVersion: current.schemaVersion,
      families: current.families,
      apps: nextApps,
      urlDomains: current.urlDomains,
      workflows: current.workflows,
      players: current.players,
    );
    await policyStore.savePolicy(updated);
  }

  Future<bool> addAllowedDomainToPolicy(String rawDomain) async {
    final current = activePolicy.value;
    if (current == null) return false;
    var clean = rawDomain.trim().toLowerCase();
    clean = clean
        .replaceFirst(RegExp(r'^https?://'), '')
        .split('/')
        .first
        .trim();
    if (clean.isEmpty || current.urlDomains.contains(clean)) return false;
    try {
      final nextDomains = <String>[...current.urlDomains, clean];
      final updated = HostPolicy(
        schemaVersion: current.schemaVersion,
        families: current.families,
        apps: current.apps,
        urlDomains: nextDomains,
        workflows: current.workflows,
        players: current.players,
      );
      await policyStore.savePolicy(updated);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> removeAllowedDomainFromPolicy(String domain) async {
    final current = activePolicy.value;
    if (current == null) return;
    final nextDomains = current.urlDomains.where((d) => d != domain).toList();
    final updated = HostPolicy(
      schemaVersion: current.schemaVersion,
      families: current.families,
      apps: current.apps,
      urlDomains: nextDomains,
      workflows: current.workflows,
      players: current.players,
    );
    await policyStore.savePolicy(updated);
  }

  void triggerEmergencyStop() {
    stopController.triggerStop(StopReason.ownerHost);
  }

  void resumeEmergencyStop() {
    stopController.resumeFromTray();
  }

  Future<void> unpairAndRestartEnrollment() async {
    await enrollmentStore.clear();
    enrolledState.value = null;
    await sessionClient.connect();
  }

  @override
  void onClose() {
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs.clear();
    super.onClose();
  }
}

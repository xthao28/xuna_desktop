import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/core/presentation/controllers/base_getx_controller.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/discovery/auto_app_scanner.dart';
import 'package:xuna_desktop/features/discovery/auto_symbiotic_service.dart';
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
  });

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
  final learnedAppPlaybooks = <AppPlaybookEntry>[].obs;
  final activeHandover = Rxn<HumanHandoverSnapshot>();
  final activeFocusedAppName = 'Visual Studio Code'.obs;
  final AutoAppScanner _appScanner = AutoAppScanner();

  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  /// Vietnamese status label shown in the system tray and header:
  /// - `"Cấu hình lỗi"` when `host-policy.json` is invalid/missing (`UDC-3` §5.6.4)
  /// - `"Đã dừng khẩn cấp"` when e-stop is active
  /// - `"Đang kết nối"` when `sessionPhase == ready`
  /// - `"Chờ ghép nối"` when waiting for QR + SAS confirmation
  /// - `"Mất kết nối"` otherwise
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
    if (lanModeEnabled.value && lanServer != null) {
      try {
        await lanServer!.start();
      } catch (_) {}
    }
    await refreshPermissions();
    await refreshAudit();
    await sessionClient.connect();
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

  /// Refreshes the SYM-1 / SYM-2 / OMNIFORGE symbiotic state from [symbioticService] (`SYM-UI` S-UI.2 & `FORGE-3`).
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

  /// Inspects and learns an application across the 3-tier ladder (`CLAW-APP-ENGINE`).
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
    return entry;
  }

  /// Removes a learned [AppPlaybookEntry] by [appId] (`CLAW-APP-ENGINE`).
  void removeAppPlaybookFromUi(String appId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removeAppPlaybook(appId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa ứng dụng khỏi Sổ tay Học App';
    refreshSymbioticState();
  }

  /// Pauses automation at a sensitive step (Login / 2FA / Captcha / Payment) and waits for the owner (`CLAW-APP-ENGINE`).
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

  /// Resumes a paused Human-in-the-Loop Handover session (`CLAW-APP-ENGINE`).
  void resumeHumanHandoverFromUi() {
    final svc = symbioticService;
    if (svc == null) return;
    final summary = svc.resumeHumanHandover();
    frontierStatusSummaryVi.value = summary;
    refreshSymbioticState();
  }

  /// Cancels a paused Human-in-the-Loop Handover session (`CLAW-APP-ENGINE`).
  void cancelHumanHandoverFromUi() {
    final svc = symbioticService;
    if (svc == null) return;
    svc.cancelHumanHandover();
    frontierStatusSummaryVi.value = '⏹️ Đã hủy phiên chờ xác nhận thủ công';
    refreshSymbioticState();
  }

  /// Selects one of the 7 XUNA Color Themes on Desktop and records it in ChronoGraph (`THEME-3`).
  XunaColorThemeData selectColorTheme(String themeId) {
    final resolved = XunaColorThemes.byId(themeId);
    isAutoColorTheme.value = false;
    selectedColorThemeId.value = resolved.id;
    symbioticService?.syncColorTheme(resolved.id);
    frontierStatusSummaryVi.value =
        '🎨 Đã đồng bộ bảng màu ${resolved.name} (${resolved.nameVi}) trên Desktop & ChronoGraph';
    return resolved;
  }

  /// Toggles Experience-Driven Epigenetic Auto-Theme mode on Desktop (`THEME-3`).
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

  /// Runs a Zero-Token 2-Tier Heartbeat tick from the Desktop UI (`CLAW-2`).
  HeartbeatStatusSnapshot? runZeroTokenHeartbeatFromUi({
    bool simulateDelta = false,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final snap = svc.configureAndTickHeartbeat(
      action: 'tick',
      simulateDelta: simulateDelta,
    );
    refreshSymbioticState();
    return snap;
  }

  /// Records a self-healing layout correction rule on a skill from the Desktop UI (`CLAW-1`).
  Map<String, Object?>? recordQuickSkillCorrectionFromUi(
    String skillId, {
    String correctionNote =
        'Trang thuế mới đổi nút Tải PDF sang góc phải bảng hóa đơn',
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

  /// Exports a forged skill as an OpenClaw-compatible `SKILL.md` string (`CLAW-1`).
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

  /// Presents the interactive A2UI Live Canvas surface from the Desktop UI (`CLAW-3`).
  LiveCanvasSurfaceSnapshot? presentInvoiceLiveCanvasFromUi() {
    final svc = symbioticService;
    if (svc == null) return null;
    final snap = svc.presentLiveCanvas(action: 'present_invoice_table');
    refreshSymbioticState();
    return snap;
  }

  /// Feeds a dropped file into the Living Overlay Drop-Zone and synthesizes a Bio-Acoustic chirp (`FRONTIER-1`, `FRONTIER-2`).
  String? feedOverlayDropAndVocalizeFromUi({
    String droppedItemName = 'hoa_don_thang_11.csv',
    String vocalKind = 'happy_chirp',
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final dropRes = svc.manageOverlayAndDropZone(
      mode: 'feed_drop_item',
      anchor: 'mac_notch',
      droppedItemName: droppedItemName,
    );
    final vocalRes = svc.vocalizeAndSenseProsody(
      mode: 'synthesize_vocal',
      vocalKind: vocalKind,
      speechRateWpm: 105,
      rmsEnergyDb: -25,
    );
    frontierStatusSummaryVi.value =
        '${dropRes.summaryVi}\n${vocalRes.summaryVi}';
    refreshSymbioticState();
    return frontierStatusSummaryVi.value;
  }

  /// Updates the Bi-Temporal ChronoGraph and starts a 4-7-8 Mindful Co-Breathing ritual (`FRONTIER-3`, `FRONTIER-4`).
  String? updateChronoGraphAndRitualFromUi({
    String objectVal = 'XUNA Frontier 2026',
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final graphRes = svc.manageTemporalLifeGraph(
      mode: 'upsert_temporal_edge',
      subject: 'Chủ nhân',
      predicate: 'đang_tập_trung_dự_án',
      object: objectVal,
    );
    final ritualRes = svc.executeMindfulRitualAndPlaydate(
      mode: 'start_breathing_478',
    );
    frontierStatusSummaryVi.value =
        '${graphRes.summaryVi}\n${ritualRes.summaryVi}';
    refreshSymbioticState();
    return frontierStatusSummaryVi.value;
  }

  /// Runs a Zero-Screenshot Native OS UI Automation inspection and button invoke (`UIA-2`).
  String? runZeroScreenshotUiAutomationFromUi({
    String windowTitle = 'Excel - Bảng Kê Hóa Đơn',
    String refId = 'ui_3',
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final inspectRes = svc.executeUiAccessibilityTree(
      action: 'inspect_window',
      windowTitle: windowTitle,
    );
    final invokeRes = svc.executeUiAccessibilityTree(
      action: 'invoke_ref',
      windowTitle: windowTitle,
      refId: refId,
    );
    frontierStatusSummaryVi.value =
        '${inspectRes.summaryVi}\n${invokeRes.summaryVi}';
    refreshSymbioticState();
    return frontierStatusSummaryVi.value;
  }

  /// Synthesizes a quick citizen tool (e.g., Invoice Harvester) from Desktop UI (`FORGE-3`).
  ForgedSkillEntry? forgeQuickInvoiceTool({
    String goal =
        'Tự động tải hết hóa đơn PDF/XML và gom bảng kê Excel vào HoaDon_Thang',
    String? targetFolder,
  }) {
    final svc = symbioticService;
    if (svc == null) return null;
    final entry = svc.synthesizeSkill(
      goal: goal,
      targetFolder: (targetFolder == null || targetFolder.trim().isEmpty)
          ? null
          : targetFolder.trim(),
    );
    frontierStatusSummaryVi.value =
        '🛠️ Đã viết xong Tool "${entry.titleVi}" (${entry.skillId}) — thư mục: ${entry.targetFolder}';
    refreshSymbioticState();
    return entry;
  }

  /// Runs a forged personal skill from Desktop UI (`FORGE-3`).
  Map<String, Object?>? runForgedSkillFromUi(String skillId) {
    final svc = symbioticService;
    if (svc == null) return null;
    final res = svc.runForgedSkill(skillId: skillId);
    frontierStatusSummaryVi.value = '▶ ${res.summaryVi}';
    refreshSymbioticState();
    return <String, Object?>{
      'skillId': res.skillId,
      'processedCount': res.processedCount,
      'outputDirectory': res.outputDirectory,
      'exportedCsvFile': res.exportedCsvFile,
      'selfHealedSelectors': res.selfHealedSelectors,
      'undoSnapshotId': res.undoSnapshotId,
      'summaryVi': res.summaryVi,
    };
  }

  /// Deletes a forged personal skill from Desktop UI.
  void removeForgedSkillFromUi(String skillId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.listAndManageForgedSkills(action: 'delete_one', skillId: skillId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa công cụ $skillId khỏi OmniForge';
    refreshSymbioticState();
  }

  /// Exports a forged skill as OpenClaw `SKILL.md` and copies it to the PC Clipboard.
  Future<void> copySkillMarkdownToClipboard(String skillId) async {
    final md = exportSkillMarkdownFromUi(skillId);
    if (md == null || md.isEmpty) return;
    await copyTextToSystemClipboard(md, labelVi: 'tài liệu SKILL.md');
  }

  /// Adds a demonstrated action step during an active `Show-Me-Once` session on Desktop.
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

  /// Toggles `Show-Me-Once` demonstration recording and compiles a skill when stopped (`FORGE-3`).
  Map<String, Object?>? toggleTeachModeFromUi({String? customTitle}) {
    final svc = symbioticService;
    if (svc == null) return null;
    if (!svc.isTeachRecordingActive) {
      svc.handleTeachSession(
        mode: 'start',
        skillTitle: 'Tải hóa đơn mẫu và lưu vào thư mục HoaDon_Thang',
      );
      svc.handleTeachSession(
        mode: 'record_action',
        demonstratedAction: 'Click tải hóa đơn PDF mẫu #1',
        selectorOrPattern: 'a.btn-download-invoice',
      );
      teachRecordedSteps.assignAll(<String>[
        'Bước 1: Chọn dòng đầu tiên trong danh sách dữ liệu',
        'Bước 2: Bấm tải tệp & chuẩn hóa tên theo ngày tháng',
      ]);
      frontierStatusSummaryVi.value =
          '🎥 Đang ở chế độ Làm mẫu 1 lần (Show-Me-Once) — hãy thêm bước hoặc bấm Đóng gói thành Tool!';
      refreshSymbioticState();
      return null;
    } else {
      final resolvedTitle =
          (customTitle != null && customTitle.trim().isNotEmpty)
          ? customTitle.trim()
          : 'Tải hóa đơn mẫu và lặp lại cho toàn bộ danh sách';
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

  /// Clears all active watchdogs in [symbioticService] and refreshes (`SYM-UI` S-UI.2).
  void clearAllWatchdogs() {
    final svc = symbioticService;
    if (svc == null) return;
    svc.listAndClearWatchdogs(action: 'clear_all');
    refreshSymbioticState();
  }

  /// Captures a quick Workspace Time-Capsule from the Desktop UI (`SYM-LIVE` S-LIVE.2).
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

  /// Pushes a quick snippet into XUNA Universal Pocket from the Desktop UI (`SYM-LIVE` S-LIVE.2).
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

  /// Reads the PC/Mac system Clipboard and pushes it into XUNA Universal Pocket.
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

  /// Copies [text] to the system Clipboard and updates the status banner.
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

  /// Removes a saved Workspace Capsule by [capsuleId].
  void removeWorkspaceCapsule(String capsuleId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removeWorkspaceCapsule(capsuleId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa phiên làm việc đã lưu';
    refreshSymbioticState();
  }

  /// Removes a Pocket item by [itemId].
  void removePocketItem(String itemId) {
    final svc = symbioticService;
    if (svc == null) return;
    svc.removePocketItem(itemId);
    frontierStatusSummaryVi.value = '🗑️ Đã xóa mục khỏi Bộ nhớ tạm';
    refreshSymbioticState();
  }

  /// Transforms a Pocket item (format JSON, extract tasks, or summarize) and saves the result.
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

  /// Registers a background port or process watchdog from the Desktop UI.
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

  /// Registers a custom process or port watchdog from the Desktop UI.
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

  /// Scans real-time PC system vitals (Battery, RAM, Disk) and active localhost dev ports.
  Future<void> scanSystemVitalsAndPorts() async {
    final svc = symbioticService;
    if (svc == null) return;
    final vitals = await svc.readSystemVitals();
    final ports = await svc.scanDevPorts();
    latestVitals.value = vitals;
    activeDevPorts.assignAll(ports.activePorts);
    detectedLanIp.value = ports.lanIp;
    frontierStatusSummaryVi.value =
        '💻 Pin ${vitals.batteryPercent}% (${vitals.isCharging ? "Đang sạc" : "Dùng pin"}) · RAM ${vitals.memoryUsedPercent}% · Ổ trống ${vitals.diskFreeGb}GB · ${ports.activePorts.length} cổng Dev đang mở';
    refreshSymbioticState();
  }

  /// Clears all capsules, pocket items, and watchdogs on Desktop.
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

  /// Scans installed applications on macOS (`/Applications`) or Windows (Start Menu) (`UDC-11`).
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

  /// Adds a custom application entry to `host-policy.json` (`apps`).
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
    final kind = Platform.isMacOS ? AppLaunchKind.bundle : AppLaunchKind.exe;
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

  /// Removes a custom application entry from `host-policy.json` by [appId].
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

  /// Adds an HTTPS domain to `host-policy.json` (`urlDomains`).
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

  /// Removes an HTTPS domain from `host-policy.json` (`urlDomains`).
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

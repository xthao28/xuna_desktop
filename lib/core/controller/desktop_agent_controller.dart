import 'dart:async';

import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/computer_use/computer_use_session_manager.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/lan/lan_offline_server.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Navigation tabs inside the Desktop Agent settings window.
enum AgentWindowTab { enrollment, policy, permissions, audit }

/// GetX controller driving the Desktop Agent tray status and settings window.
class DesktopAgentController extends GetxController {
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

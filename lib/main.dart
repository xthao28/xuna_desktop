import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/channel/xuna_host_channel.dart';
import 'package:xuna_desktop/core/config/agent_paths.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/logging/content_free_logger.dart';
import 'package:xuna_desktop/core/single_instance/single_instance_guard.dart';
import 'package:xuna_desktop/features/audit/audit_log_store.dart';
import 'package:xuna_desktop/features/enrollment/enrollment_state_store.dart';
import 'package:xuna_desktop/features/lan/lan_offline_server.dart';
import 'package:xuna_desktop/features/policy/host_policy_store.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/features/stop/desktop_tray_service.dart';
import 'package:xuna_desktop/features/stop/emergency_stop_controller.dart';
import 'package:xuna_desktop/features/tools/host_tool_dispatcher.dart';
import 'package:xuna_desktop/features/ui/desktop_agent_window.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';

const String _defaultWsUrl = String.fromEnvironment(
  'XUNA_WS_URL',
  defaultValue: 'ws://127.0.0.1:8000/v1/hosts/connect',
);

SingleInstanceGuard? _processGuard;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final paths = AgentPaths.resolve();
  await paths.ensureDirectories();

  final guard = _processGuard ?? SingleInstanceGuard(lockFile: paths.lockFile);
  final acquired = await guard.tryAcquire();
  if (!acquired) {
    exit(0);
  }
  _processGuard = guard;

  final logger = ContentFreeLogger();
  final channel = MethodChannelXunaHostChannel();
  final enrollmentStore = EnrollmentStateStore(
    stateFile: paths.enrollmentStateFile,
  );
  final policyStore = HostPolicyStore(
    policyFile: paths.policyFile,
    logger: logger,
  );
  final auditStore = AuditLogStore(auditDir: paths.auditDir);
  final stopController = EmergencyStopController(logger: logger);

  final dispatcher = HostToolDispatcher(
    policyStore: policyStore,
    channel: channel,
    auditStore: auditStore,
    stopController: stopController,
    logger: logger,
    enrollmentStore: enrollmentStore,
  );

  final lanServer = LanOfflineServer(
    channel: channel,
    enrollmentStore: enrollmentStore,
    dispatcher: dispatcher,
    logger: logger,
  );

  final sessionClient = XtpSessionClient(
    wsUri: Uri.parse(_defaultWsUrl),
    channel: channel,
    enrollmentStore: enrollmentStore,
    policyStore: policyStore,
    dispatcher: dispatcher,
    stopController: stopController,
    logger: logger,
  );

  if (Get.isRegistered<DesktopAgentController>()) {
    await Get.delete<DesktopAgentController>(force: true);
  }
  final controller = Get.put<DesktopAgentController>(
    DesktopAgentController(
      channel: channel,
      enrollmentStore: enrollmentStore,
      policyStore: policyStore,
      auditStore: auditStore,
      stopController: stopController,
      sessionClient: sessionClient,
      lanServer: lanServer,
      symbioticService: dispatcher.symbioticService,
      logger: logger,
    ),
  );

  runApp(XunaDesktopApp(controller: controller));

  final trayService = DesktopTrayService(controller: controller);
  unawaited(trayService.initialize());
  unawaited(controller.initializeAgent());
}

class XunaDesktopApp extends StatelessWidget {
  const XunaDesktopApp({super.key, required this.controller});

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    return GetMaterialApp(
      title: 'XUNA Desktop Agent',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        fontFamily: AppTextStyle.bodyFamily,
        scaffoldBackgroundColor: AppColors.xunaPaper,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.xunaLime,
          surface: AppColors.xunaPaper,
        ),
      ),
      home: DesktopAgentWindow(controller: controller),
    );
  }
}

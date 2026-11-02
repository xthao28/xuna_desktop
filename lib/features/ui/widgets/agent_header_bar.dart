import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/features/session/xtp_session_client.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Active Computer-Use Session high-visibility banner (`CUA-1`).
class AgentComputerUseBanner extends StatelessWidget {
  const AgentComputerUseBanner({
    super.key,
    required this.controller,
    required this.bannerKey,
  });

  final DesktopAgentController controller;
  final Key bannerKey;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final cu = controller.activeCuSession.value;
      if (cu == null) return UtilWidget.shrink;
      final bannerText =
          'Đang điều khiển màn hình (${cu.goal}) · Bước ${cu.stepsExecuted}/${cu.maxSteps} · Nhấn Ctrl+Alt+X để dừng ngay';

      return Container(
        key: bannerKey,
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppDimens.defaultPadding,
          vertical: AppDimens.padding10,
        ),
        decoration: const BoxDecoration(
          color: AppColors.xunaConnecting,
          border: Border(
            bottom: BorderSide(
              color: AppColors.xunaInk,
              width: AppDimens.stroke2,
            ),
          ),
        ),
        child: Row(
          children: [
            const AppStatusDot(
              color: AppColors.xunaHeart,
              blinking: true,
              size: 12,
            ),
            UtilWidget.sizedBoxWidth10,
            Expanded(
              child: Text(
                bannerText,
                style: AppTextStyle.font13Bo,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(right: AppDimens.padding10),
              child: AppTag(
                text: '${cu.stepsExecuted}/${cu.maxSteps} bước',
                color: AppColors.xunaCard,
              ),
            ),
            AppPillButton(
              label: 'Dừng phiên CU',
              fillColor: AppColors.xunaHeart,
              onPressed: controller.triggerEmergencyStop,
            ),
          ],
        ),
      );
    });
  }
}

/// Top window header with XUNA Pixel Art avatar, title, status badge, and Emergency Stop button.
class AgentHeaderBar extends StatelessWidget {
  const AgentHeaderBar({
    super.key,
    required this.controller,
    required this.statusBadgeKey,
    required this.stopButtonKey,
    required this.resumeButtonKey,
  });

  final DesktopAgentController controller;
  final Key statusBadgeKey;
  final Key stopButtonKey;
  final Key resumeButtonKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.padding18,
        vertical: AppDimens.padding14,
      ),
      decoration: const BoxDecoration(
        color: AppColors.xunaCard,
        border: Border(
          bottom: BorderSide(
            color: AppColors.xunaInk,
            width: AppDimens.stroke2,
          ),
        ),
      ),
      child: Obx(() {
        final stopped = controller.isStopped.value;
        final healthy = controller.isPolicyHealthy.value;
        final phase = controller.sessionPhase.value;
        final statusText = controller.trayStatusLabel;

        final isReady = !stopped && healthy && phase == HostSessionPhase.ready;
        final isAlert = stopped || !healthy;

        return Row(
          children: [
            AppPetAvatarBadge(
              expression:
                  isReady ? AppPetExpression.happy : AppPetExpression.idle,
              size: 46,
              backgroundColor: isAlert
                  ? AppColors.xunaHeart
                  : isReady
                      ? AppColors.xunaLime
                      : AppColors.xunaLilacSoft,
            ),
            UtilWidget.sizedBoxWidth12,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const AppSparkleMark(size: 13),
                      UtilWidget.sizedBoxWidth6,
                      Flexible(
                        child: Text(
                          'XUNA DESKTOP AGENT',
                          style: AppTextStyle.mono10Bo.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Trạm điều khiển máy tính',
                    style: AppTextStyle.display22,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            UtilWidget.sizedBoxWidth12,
            AppTag(
              key: statusBadgeKey,
              text: statusText,
              color: isAlert
                  ? AppColors.xunaHeart
                  : isReady
                      ? AppColors.xunaLime
                      : AppColors.xunaLilacSoft,
              dotColor: isAlert
                  ? AppColors.xunaHeart
                  : isReady
                      ? AppColors.xunaOnline
                      : AppColors.xunaConnecting,
              style: AppTextStyle.font12Bo,
            ),
            UtilWidget.sizedBoxWidth12,
            if (stopped)
              AppBoxButton(
                key: resumeButtonKey,
                label: 'Bật lại XUNA',
                highlighted: true,
                compact: true,
                onPressed: controller.resumeEmergencyStop,
              )
            else
              AppBoxButton(
                key: stopButtonKey,
                label: 'Dừng XUNA',
                danger: true,
                compact: true,
                onPressed: controller.triggerEmergencyStop,
              ),
          ],
        );
      }),
    );
  }
}

/// Top pill navigation bar switching between the 4 core Desktop Agent tabs.
class AgentTabBar extends StatelessWidget {
  const AgentTabBar({super.key, required this.controller});

  final DesktopAgentController controller;

  static const _tabs = <AgentWindowTab>[
    AgentWindowTab.enrollment,
    AgentWindowTab.policy,
    AgentWindowTab.permissions,
    AgentWindowTab.audit,
  ];

  static String _tabLabel(AgentWindowTab tab) => switch (tab) {
        AgentWindowTab.enrollment => 'Ghép nối',
        AgentWindowTab.policy => 'Chính sách',
        AgentWindowTab.permissions => 'Quyền hệ thống',
        AgentWindowTab.audit => 'Nhật ký',
        AgentWindowTab.symbiotic => 'Cộng sinh',
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.padding18,
        vertical: AppDimens.padding10,
      ),
      decoration: const BoxDecoration(
        color: AppColors.xunaCardPressed,
        border: Border(
          bottom: BorderSide(
            color: AppColors.xunaInk,
            width: AppDimens.stroke2,
          ),
        ),
      ),
      child: Obx(
        () => AppFilterPillBar<AgentWindowTab>(
          items: _tabs,
          selectedItem: controller.activeTab.value,
          labelBuilder: _tabLabel,
          onSelected: (tab) {
            controller.activeTab.value = tab;
            if (tab == AgentWindowTab.audit) {
              controller.refreshAudit();
            } else if (tab == AgentWindowTab.permissions) {
              controller.refreshPermissions();
            } else if (tab == AgentWindowTab.symbiotic) {
              controller.refreshSymbioticState();
            }
          },
        ),
      ),
    );
  }
}

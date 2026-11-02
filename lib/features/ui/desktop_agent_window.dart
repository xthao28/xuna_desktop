import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_get_page.dart';
import 'package:xuna_desktop/features/ui/widgets/agent_header_bar.dart';
import 'package:xuna_desktop/features/ui/widgets/audit_tab_view.dart';
import 'package:xuna_desktop/features/ui/widgets/enrollment_tab_view.dart';
import 'package:xuna_desktop/features/ui/widgets/permissions_tab_view.dart';
import 'package:xuna_desktop/features/ui/widgets/policy_tab_view.dart';
import 'package:xuna_desktop/features/ui/widgets/symbiotic_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';

/// Main settings and status window of the XUNA Desktop Agent, extending
/// [BaseGetPage] and using the shared XUNA design system (`lib/shared/`).
class DesktopAgentWindow extends BaseGetPage<DesktopAgentController> {
  const DesktopAgentWindow({
    super.key,
    required DesktopAgentController controller,
  }) : super(injectedController: controller);

  static const statusBadgeKey = Key('desktop.header.status');
  static const cuOverlayBannerKey = Key('desktop.cu.overlay_banner');
  static const stopButtonKey = Key('desktop.header.stop');
  static const resumeButtonKey = Key('desktop.header.resume');
  static const sasCodeKey = Key('desktop.enroll.sas');
  static const lanModeSwitchKey = Key('desktop.enroll.lan_mode');
  static const restorePolicyButtonKey = Key('desktop.policy.restore');
  static const recheckPermissionsButtonKey = Key('desktop.permissions.recheck');

  @override
  Widget buildPage(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.xunaPaper,
      body: Obx(() {
        final cuActive = controller.activeCuSession.value != null;
        return Container(
          decoration: BoxDecoration(
            color: AppColors.xunaPaper,
            border: cuActive
                ? Border.all(color: AppColors.xunaConnecting, width: 4)
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (cuActive)
                AgentComputerUseBanner(
                  controller: controller,
                  bannerKey: cuOverlayBannerKey,
                ),
              AgentHeaderBar(
                controller: controller,
                statusBadgeKey: statusBadgeKey,
                stopButtonKey: stopButtonKey,
                resumeButtonKey: resumeButtonKey,
              ),
              AgentTabBar(controller: controller),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppDimens.padding18),
                  child: Obx(() {
                    return switch (controller.activeTab.value) {
                      AgentWindowTab.enrollment => EnrollmentTabView(
                          controller: controller,
                          sasCodeKey: sasCodeKey,
                          lanModeSwitchKey: lanModeSwitchKey,
                        ),
                      AgentWindowTab.policy => PolicyTabView(
                          controller: controller,
                          restorePolicyButtonKey: restorePolicyButtonKey,
                        ),
                      AgentWindowTab.permissions => PermissionsTabView(
                          controller: controller,
                          recheckPermissionsButtonKey:
                              recheckPermissionsButtonKey,
                        ),
                      AgentWindowTab.audit => AuditTabView(
                          controller: controller,
                        ),
                      AgentWindowTab.symbiotic => SymbioticTabView(
                          controller: controller,
                        ),
                    };
                  }),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/features/ui/widgets/symbiotic/symbiotic_forge_and_playbook_cards.dart';
import 'package:xuna_desktop/features/ui/widgets/symbiotic/symbiotic_workspace_cards.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Interactive Symbiotic Workspace Hub on Desktop (real user data, zero fake demo generators).
class SymbioticTabView extends BaseTabView<DesktopAgentController> {
  const SymbioticTabView({super.key, required super.controller});

  @override
  Widget buildTab(BuildContext context) {
    final hasAnyData =
        controller.workspaceCapsules.isNotEmpty ||
        controller.pocketItems.isNotEmpty ||
        controller.activeWatchdogs.isNotEmpty ||
        controller.forgedSkills.isNotEmpty;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDisplayHeading(
            eyebrow: 'WORKSPACE STATE',
            title: 'Không gian Cộng sinh trên Máy tính',
            trailing: Wrap(
              spacing: 8,
              children: [
                if (hasAnyData)
                  AppPillButton(
                    label: 'Làm sạch dữ liệu',
                    selected: false,
                    onPressed: controller.clearAllSymbioticDataFromUi,
                  ),
                AppPillButton(
                  label: 'Làm mới',
                  selected: true,
                  onPressed: controller.refreshSymbioticState,
                ),
              ],
            ),
          ),
          UtilWidget.sizedBox12,
          SymbioticQuickStartAndThemeSection(controller: controller),
          UtilWidget.sizedBox12,
          SymbioticCapsulesPocketWatchdogsSection(controller: controller),
          UtilWidget.sizedBox12,
          SymbioticOmniForgeSection(controller: controller),
          UtilWidget.sizedBox12,
          SymbioticClawdBotPlaybookSection(controller: controller),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Tab 3 (`Quyền hệ thống`): 3-step OS permission wizard (Accessibility, Automation, Notifications).
class PermissionsTabView extends BaseTabView<DesktopAgentController> {
  const PermissionsTabView({
    super.key,
    required super.controller,
    required this.recheckPermissionsButtonKey,
  });

  final Key recheckPermissionsButtonKey;

  static AppStatusBadgeVariant _badgeVariantForState(String stateWire) =>
      switch (stateWire) {
        'granted' => AppStatusBadgeVariant.success,
        'denied' => AppStatusBadgeVariant.danger,
        _ => AppStatusBadgeVariant.info,
      };

  Widget _buildPermissionStep({
    required String title,
    required String subtitle,
    required String stateWire,
    required String buttonLabel,
    required VoidCallback onPressed,
  }) {
    return AppSectionCard(
      title: title,
      subtitle: subtitle,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppStatusBadge(
            label: stateWire.toUpperCase(),
            variant: _badgeVariantForState(stateWire),
          ),
          UtilWidget.sizedBoxWidth10,
          AppPillButton(
            label: buttonLabel,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }

  @override
  Widget buildTab(BuildContext context) {
    final snap = controller.permissionsSnapshot.value;
    final automationEntries = snap.automation.entries.toList(growable: false);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDisplayHeading(
            eyebrow: 'MACOS / WINDOWS PERMISSIONS',
            title: 'Quyền hệ thống',
            subtitle:
                'Quyền hệ thống được tự động kiểm tra lại khi cửa sổ nhận tiêu điểm (Focus).',
            trailing: AppPillButton(
              key: recheckPermissionsButtonKey,
              label: 'Kiểm tra lại ngay',
              selected: true,
              onPressed: controller.refreshPermissions,
            ),
          ),
          UtilWidget.sizedBox12,
          _buildPermissionStep(
            title: 'Bước 1 · Trợ năng (Accessibility)',
            subtitle:
                'Điều khiển phím đa phương tiện & đọc cây giao diện AXUIElement · Trạng thái: ${snap.accessibility.wire}',
            stateWire: snap.accessibility.wire,
            buttonLabel: 'Kiểm tra / Cấp quyền',
            onPressed: () => controller.requestOsPermission('accessibility'),
          ),
          UtilWidget.sizedBox10,
          _buildPermissionStep(
            title: 'Bước 2 · Tự động hóa (Automation / AppleEvents)',
            subtitle: automationEntries.isEmpty
                ? 'Chỉ áp dụng trên macOS khi điều khiển Music / Spotify'
                : automationEntries
                      .map((e) => '${e.key}: ${e.value.wire}')
                      .join(' · '),
            stateWire: automationEntries.any((e) => e.value.wire == 'granted')
                ? 'granted'
                : 'not_determined',
            buttonLabel: 'Cấp quyền Music',
            onPressed: () =>
                controller.requestOsPermission('automation:com.apple.Music'),
          ),
          UtilWidget.sizedBox10,
          _buildPermissionStep(
            title: 'Bước 3 · Thông báo (Notifications)',
            subtitle:
                'Hiển thị thông báo khi XUNA thực thi công cụ · Trạng thái: ${snap.notifications.wire}',
            stateWire: snap.notifications.wire,
            buttonLabel: 'Kiểm tra / Cấp quyền',
            onPressed: () => controller.requestOsPermission('notifications'),
          ),
        ],
      ),
    );
  }
}

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Tab 2 (`Chính sách`): Local `host-policy.json` dual-consent toggles and allowlists.
class PolicyTabView extends BaseTabView<DesktopAgentController> {
  const PolicyTabView({
    super.key,
    required super.controller,
    required this.restorePolicyButtonKey,
  });

  final Key restorePolicyButtonKey;

  static const _families = <ToolFamily>[
    ToolFamily.media,
    ToolFamily.app,
    ToolFamily.url,
    ToolFamily.workflow,
  ];

  static String _familyRiskLabel(ToolFamily family) => switch (family) {
        ToolFamily.media => 'R1 · Tự động',
        ToolFamily.app => 'R2 · Hỏi trước',
        ToolFamily.url => 'R2 · Hỏi trước',
        ToolFamily.workflow => 'R2 · Hỏi trước',
        _ => 'R1',
      };

  static String _familyDescription(ToolFamily family) => switch (family) {
        ToolFamily.media =>
          'Phát / tạm dừng nhạc, chuyển bài, âm lượng, giọng kêu sinh học XUNA.',
        ToolFamily.app =>
          'Mở ứng dụng, kiểm tra không gian làm việc, Xưởng Kỹ Năng OmniForge & điều khiển UIA 0-Screenshot.',
        ToolFamily.url =>
          'Mở liên kết HTTPS hợp lệ và đọc tóm tắt tab trình duyệt đang mở.',
        ToolFamily.workflow =>
          'Chạy quy trình Shortcuts / tự động hóa thói quen đã phê duyệt.',
        _ => '',
      };

  @override
  Widget buildTab(BuildContext context) {
    if (!controller.isPolicyHealthy.value ||
        controller.activePolicy.value == null) {
      return SingleChildScrollView(
        child: AppInkCard(
          color: AppColors.xunaCardPressed,
          padding: const EdgeInsets.all(AppDimens.padding18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppDisplayHeading(
                eyebrow: 'FAIL-CLOSED GUARD',
                title: 'Cấu hình lỗi (Fail-closed)',
                trailing: AppStatusBadge(
                  label: 'LỖI CHÍNH SÁCH',
                  variant: AppStatusBadgeVariant.danger,
                ),
              ),
              UtilWidget.sizedBox10,
              Text(
                'Tệp host-policy.json bị thiếu hoặc không hợp lệ. Mọi công cụ trừ host.status đều bị từ chối cho tới khi khôi phục chính sách.',
                style: AppTextStyle.font14Re,
              ),
              UtilWidget.sizedBox16,
              AppBoxButton(
                key: restorePolicyButtonKey,
                label: 'Khôi phục chính sách mặc định',
                highlighted: true,
                onPressed: controller.restoreDefaultPolicy,
              ),
            ],
          ),
        ),
      );
    }

    final policy = controller.activePolicy.value!;
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AppDisplayHeading(
            eyebrow: 'CHÍNH SÁCH CỤC BỘ · HOST-POLICY.JSON',
            title: 'Quyền thực thi trên máy tính',
            subtitle:
                'Máy tính kiểm tra độc lập mọi lệnh từ XUNA. Chỉ những nhóm quyền được bật ở cả Điện thoại và Máy tính mới được phép thực thi.',
          ),
          UtilWidget.sizedBox12,
          for (final family in _families) ...[
            AppSectionCard(
              title: 'Nhóm quyền: ${family.wire}',
              subtitle: _familyDescription(family),
              shadow: AppDimens.shadow2,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppTag(
                    text: _familyRiskLabel(family),
                    color: family == ToolFamily.media
                        ? AppColors.xunaLime
                        : AppColors.xunaLilacSoft,
                  ),
                  UtilWidget.sizedBoxWidth12,
                  AppToggle(
                    value: policy.isFamilyAllowed(family),
                    onChanged: (val) =>
                        controller.toggleFamilyPolicy(family, val),
                  ),
                ],
              ),
            ),
            UtilWidget.sizedBox10,
          ],
          AppSectionCard(
            title: 'Tên miền cho phép (url.open)',
            shadow: AppDimens.shadow2,
            subtitle: policy.urlDomains.isEmpty
                ? 'Chưa có tên miền nào'
                : policy.urlDomains.join(', '),
          ),
          UtilWidget.sizedBox10,
          AppSectionCard(
            title: 'Ứng dụng cho phép (app.launch)',
            shadow: AppDimens.shadow2,
            subtitle: policy.apps.isEmpty
                ? 'Chưa có ứng dụng nào'
                : policy.apps.map((a) => '${a.name} (${a.id})').join(', '),
          ),
        ],
      ),
    );
  }
}


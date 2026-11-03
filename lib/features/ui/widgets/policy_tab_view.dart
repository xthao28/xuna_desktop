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
          'Phát / tạm dừng nhạc, chuyển bài và điều chỉnh âm lượng hệ thống.',
        ToolFamily.app =>
          'Mở ứng dụng trong danh sách cho phép và kiểm tra trạng thái cửa sổ.',
        ToolFamily.url =>
          'Mở liên kết HTTPS hợp lệ thuộc các tên miền được phép.',
        ToolFamily.workflow =>
          'Chạy quy trình Shortcuts / tự động hóa đã được phê duyệt.',
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
            trailing: AppBoxButton(
              label: '+ Thêm tên miền',
              compact: true,
              onPressed: () => _showAddDomainDialog(context),
            ),
            children: [
              if (policy.urlDomains.isNotEmpty)
                Wrap(
                  spacing: AppDimens.padding6,
                  runSpacing: AppDimens.padding6,
                  children: [
                    for (final domain in policy.urlDomains)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.paddingVerySmall,
                          vertical: AppDimens.paddingSmallest,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.xunaPaper,
                          borderRadius:
                              BorderRadius.circular(AppDimens.radius8),
                          border: Border.all(
                            color: AppColors.xunaInk,
                            width: AppDimens.strokeThin,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '🌐 $domain',
                              style: AppTextStyle.mono11Re,
                            ),
                            const SizedBox(width: AppDimens.padding6),
                            InkWell(
                              onTap: () => controller
                                  .removeAllowedDomainFromPolicy(domain),
                              child: Text(
                                '✕',
                                style: AppTextStyle.mono10Bo.copyWith(
                                  color: AppColors.xunaHeart,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
          UtilWidget.sizedBox10,
          AppSectionCard(
            title: 'Ứng dụng cho phép (app.launch)',
            shadow: AppDimens.shadow2,
            subtitle: policy.apps.isEmpty
                ? 'Chưa có ứng dụng nào thêm thủ công — Đang bật Tự động quét Zero-Config (UDC-11)'
                : policy.apps.map((a) => '${a.name} (${a.id})').join(', '),
            trailing: Wrap(
              spacing: AppDimens.padding6,
              children: [
                AppBoxButton(
                  label: '🔍 Quét lại App',
                  compact: true,
                  onPressed: () =>
                      controller.scanInstalledApps(forceRefresh: true),
                ),
                AppBoxButton(
                  label: '+ Thêm App',
                  compact: true,
                  highlighted: true,
                  onPressed: () => _showAddAppDialog(context),
                ),
              ],
            ),
            children: [
              Container(
                padding: const EdgeInsets.all(AppDimens.padding10),
                decoration: BoxDecoration(
                  color: AppColors.xunaLime.withValues(alpha: 0.35),
                  borderRadius: BorderRadius.circular(AppDimens.radius8),
                  border: Border.all(
                    color: AppColors.xunaInk,
                    width: AppDimens.strokeThin,
                  ),
                ),
                child: Text(
                  '✨ Cơ chế Zero-Config (UDC-11): Khi Nhóm quyền "app" đang BẬT, XUNA tự động nhận diện và mở được TẤT CẢ ứng dụng thông thường trong /Applications (macOS) hoặc Start Menu (Windows) — và trả lời được ngay khi bạn hỏi "Trên MacBook/PC có những app nào?". Các ứng dụng nhạy cảm (Terminal, Keychain, Ngân hàng, Mật khẩu) luôn bị chặn cứng để bảo vệ bạn.',
                  style: AppTextStyle.font12Re,
                ),
              ),
              if (policy.apps.isNotEmpty) ...[
                const SizedBox(height: AppDimens.paddingVerySmall),
                Text(
                  '📌 Ứng dụng đã thêm thủ công vào host-policy.json (${policy.apps.length}):',
                  style: AppTextStyle.font12Bo,
                ),
                const SizedBox(height: AppDimens.padding6),
                Wrap(
                  spacing: AppDimens.padding6,
                  runSpacing: AppDimens.padding6,
                  children: [
                    for (final app in policy.apps)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppDimens.paddingVerySmall,
                          vertical: AppDimens.paddingSmallest,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.xunaLime,
                          borderRadius:
                              BorderRadius.circular(AppDimens.radius8),
                          border: Border.all(
                            color: AppColors.xunaInk,
                            width: AppDimens.strokeThin,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '🚀 ${app.name} (${app.id})',
                              style: AppTextStyle.font12Bo,
                            ),
                            const SizedBox(width: AppDimens.padding6),
                            InkWell(
                              onTap: () => controller
                                  .removeAllowedAppFromPolicy(app.id),
                              child: Text(
                                '✕',
                                style: AppTextStyle.mono10Bo.copyWith(
                                  color: AppColors.xunaHeart,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: AppDimens.paddingVerySmall),
              Text(
                '💻 Ứng dụng tự động phát hiện trên máy (${controller.discoveredApps.length} app):',
                style: AppTextStyle.font12Bo,
              ),
              const SizedBox(height: AppDimens.padding6),
              if (controller.discoveredApps.isEmpty)
                Text(
                  'Bấm "🔍 Quét lại App" ở góc phải để xem danh sách ứng dụng trên máy.',
                  style: AppTextStyle.font12Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                Wrap(
                  spacing: AppDimens.padding6,
                  runSpacing: AppDimens.padding6,
                  children: [
                    for (final app in controller.discoveredApps.take(24))
                      AppTag(
                        text: '${app.name} (${app.id})',
                        color: AppColors.xunaPaper,
                      ),
                    if (controller.discoveredApps.length > 24)
                      AppTag(
                        text:
                            '+${controller.discoveredApps.length - 24} ứng dụng khác',
                        color: AppColors.xunaLilacSoft,
                      ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showAddAppDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final targetCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.xunaPaper,
        title: Text(
          '➕ Thêm ứng dụng tùy chỉnh',
          style: AppTextStyle.font16Bo,
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Thông thường XUNA đã tự động mở được mọi app trong /Applications (macOS) & Start Menu (Windows). Chỉ cần thêm ở đây nếu app của bạn để ở thư mục riêng biệt:',
                style: AppTextStyle.font12Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              ),
              UtilWidget.sizedBox10,
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Tên ứng dụng (VD: Blender, Postman, Figma)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              UtilWidget.sizedBox10,
              TextField(
                controller: targetCtrl,
                decoration: const InputDecoration(
                  labelText:
                      'Đường dẫn / Bundle (VD: /Applications/Figma.app hoặc C:\\...\\app.exe)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          AppBoxButton(
            label: 'Lưu vào Chính sách',
            compact: true,
            highlighted: true,
            onPressed: () async {
              final name = nameCtrl.text.trim();
              final target = targetCtrl.text.trim();
              if (name.isEmpty || target.isEmpty) return;
              await controller.addAllowedAppToPolicy(
                name: name,
                target: target,
              );
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showAddDomainDialog(BuildContext context) async {
    final domainCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.xunaPaper,
        title: Text(
          '🌐 Thêm tên miền HTTPS cho phép',
          style: AppTextStyle.font16Bo,
        ),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: domainCtrl,
            decoration: const InputDecoration(
              labelText: 'Tên miền (VD: docs.flutter.dev, notion.so, figma.com)',
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Hủy'),
          ),
          AppBoxButton(
            label: 'Thêm tên miền',
            compact: true,
            highlighted: true,
            onPressed: () async {
              final domain = domainCtrl.text.trim();
              if (domain.isEmpty) return;
              await controller.addAllowedDomainToPolicy(domain);
              if (ctx.mounted) Navigator.of(ctx).pop();
            },
          ),
        ],
      ),
    );
  }
}

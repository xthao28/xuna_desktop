import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Symbiotic state inspector view (only renders real data without fake demo generators).
class SymbioticTabView extends BaseTabView<DesktopAgentController> {
  const SymbioticTabView({super.key, required super.controller});

  @override
  Widget buildTab(BuildContext context) {
    final capsules = controller.workspaceCapsules;
    final items = controller.pocketItems;
    final watchdogs = controller.activeWatchdogs;
    final proposals = controller.habitProposals;
    final skills = controller.forgedSkills;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDisplayHeading(
            eyebrow: 'WORKSPACE STATE',
            title: 'Trạng thái Không gian làm việc',
            trailing: AppPillButton(
              label: 'Làm mới',
              selected: true,
              onPressed: controller.refreshSymbioticState,
            ),
          ),
          UtilWidget.sizedBox12,

          // 0. Synchronized 7 Color Themes
          Builder(
            builder: (context) {
              final activeTheme = XunaColorThemes.byId(
                controller.selectedColorThemeId.value,
              );
              return AppSectionCard(
                title: '0. Bảng màu XUNA đồng bộ',
                subtitle:
                    '${activeTheme.name} · ${activeTheme.nameVi} — ${activeTheme.tagline}',
                trailing: AppTag(
                  text: activeTheme.nameVi.toUpperCase(),
                  color: activeTheme.hair,
                ),
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AppPetAvatarBadge(
                        expression: AppPetExpression.happy,
                        themeId: activeTheme.id,
                        size: 52,
                        backgroundColor: activeTheme.highlight,
                      ),
                      UtilWidget.sizedBoxWidth12,
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Text(
                                  '${activeTheme.name} — ${activeTheme.nameVi}',
                                  style: AppTextStyle.font13Bo,
                                ),
                                AppPillButton(
                                  label: controller.isAutoColorTheme.value
                                      ? '✨ Tự động (Bật)'
                                      : 'Tự động theo Tính cách',
                                  selected: controller.isAutoColorTheme.value,
                                  onPressed: controller.toggleAutoColorTheme,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final t in XunaColorThemes.all)
                                  AppPillButton(
                                    label: t.nameVi,
                                    selected: t.id == activeTheme.id,
                                    fillColor: t.id == activeTheme.id
                                        ? t.hair
                                        : t.highlight,
                                    onPressed: () =>
                                        controller.selectColorTheme(t.id),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
          UtilWidget.sizedBox12,

          // 1. Workspace Time-Capsules
          AppSectionCard(
            title: '1. Phiên làm việc đã lưu (${capsules.length})',
            children: [
              if (capsules.isEmpty)
                Text(
                  'Chưa có phiên không gian làm việc nào được lưu.',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                for (final cap in capsules)
                  AppSubItemTile(
                    trailing: AppTag(
                      text: '${cap.dirtyCount} tệp đang sửa',
                      color: AppColors.xunaLilacSoft,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${cap.project} @ ${cap.branch}',
                          style: AppTextStyle.font13Bo,
                        ),
                        if (cap.nextStepHint.isNotEmpty)
                          Text(
                            'Bước tiếp: ${cap.nextStepHint}',
                            style: AppTextStyle.font12Re.copyWith(
                              color: AppColors.xunaInkMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
            ],
          ),
          UtilWidget.sizedBox12,

          // 2. Universal Cross-Device Pocket
          AppSectionCard(
            title: '2. Bộ nhớ tạm đa thiết bị (${items.length})',
            children: [
              if (items.isEmpty)
                Text(
                  'Chưa có mục nào được lưu.',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                for (final item in items)
                  AppSubItemTile(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '[${item.kind}] ${item.label}',
                          style: AppTextStyle.font13Bo,
                        ),
                        Text(
                          item.preview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyle.font12Re.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
          UtilWidget.sizedBox12,

          // 3. Sentinel Watchdogs
          AppSectionCard(
            title: '3. Theo dõi tác vụ nền (${watchdogs.length})',
            trailing: watchdogs.isNotEmpty
                ? AppPillButton(
                    label: 'Xóa tất cả',
                    fillColor: AppColors.xunaHeart,
                    onPressed: controller.clearAllWatchdogs,
                  )
                : null,
            children: [
              if (watchdogs.isEmpty)
                Text(
                  'Chưa có tác vụ nào đang được theo dõi.',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                for (final wd in watchdogs)
                  AppSubItemTile(
                    trailing: AppTag(
                      text: '${wd['status']}'.toUpperCase(),
                      color: AppColors.xunaLime,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '[${wd['kind']}] ${wd['target']}',
                          style: AppTextStyle.mono11Bo,
                        ),
                        if (wd['summary'] != null)
                          Text(
                            '${wd['summary']}',
                            style: AppTextStyle.font12Re.copyWith(
                              color: AppColors.xunaInkMuted,
                            ),
                          ),
                      ],
                    ),
                  ),
            ],
          ),
          UtilWidget.sizedBox12,

          // 4. Habit Routine Proposals
          AppSectionCard(
            title: '4. Gợi ý quy trình tự động (${proposals.length})',
            children: [
              if (proposals.isEmpty)
                Text(
                  'Chưa có gợi ý quy trình nào.',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                for (final prop in proposals)
                  AppSubItemTile(
                    color: AppColors.xunaLilacSoft,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${prop['title']}',
                          style: AppTextStyle.font13Bo,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${prop['trigger']} → ${prop['benefit']}',
                          style: AppTextStyle.font12Re.copyWith(
                            color: AppColors.xunaInkSoft,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
          if (skills.isNotEmpty) ...[
            UtilWidget.sizedBox12,
            AppSectionCard(
              title: '5. Kỹ năng tự động (${skills.length})',
              children: [
                for (final sk in skills)
                  AppSubItemTile(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${sk.titleVi} (${sk.skillId})',
                          style: AppTextStyle.font13Bo,
                        ),
                        UtilWidget.sizedBox4,
                        Text(
                          'Thư mục: ${sk.targetFolder} · Đã chạy: ${sk.runCount} lần',
                          style: AppTextStyle.font12Re.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

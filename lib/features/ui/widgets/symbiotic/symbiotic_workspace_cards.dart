import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/features/ui/widgets/symbiotic/symbiotic_dialogs.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

class SymbioticQuickStartAndThemeSection extends StatelessWidget {
  const SymbioticQuickStartAndThemeSection({
    super.key,
    required this.controller,
  });

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    final vitals = controller.latestVitals.value;
    final devPorts = controller.activeDevPorts;
    final lanIp = controller.detectedLanIp.value;
    final statusMsg = controller.frontierStatusSummaryVi.value;
    final activeTheme = XunaColorThemes.byId(
      controller.selectedColorThemeId.value,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppSectionCard(
          title: '⚡ Bắt đầu nhanh trên Máy tính (PC / Mac)',
          subtitle:
              'Cất nhanh nội dung từ Clipboard, lưu phiên làm việc đang dở, hoặc kiểm tra sức khỏe PC & các cổng Dev đang mở.',
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                AppPillButton(
                  label: '📥 + Thêm ghi chú / Link',
                  selected: true,
                  onPressed: () =>
                      SymbioticDialogs.showAddPocketDialog(context, controller),
                ),
                AppPillButton(
                  label: '📋 Dán nhanh từ Clipboard PC',
                  selected: false,
                  onPressed: () =>
                      unawaited(controller.pasteSystemClipboardToPocket()),
                ),
                AppPillButton(
                  label: '🧊 + Lưu phiên làm việc',
                  selected: false,
                  onPressed: () => SymbioticDialogs.showCaptureWorkspaceDialog(
                    context,
                    controller,
                  ),
                ),
                AppPillButton(
                  label: '💻 Quét Pin, RAM & Cổng Dev',
                  selected: false,
                  onPressed: () =>
                      unawaited(controller.scanSystemVitalsAndPorts()),
                ),
                AppPillButton(
                  label: '🛡️ + Theo dõi Cổng / Tiến trình',
                  selected: false,
                  onPressed: () => SymbioticDialogs.showAddWatchdogDialog(
                    context,
                    controller,
                  ),
                ),
                AppPillButton(
                  label: '🛠️ + Viết Tool tự động (OmniForge)',
                  selected: false,
                  onPressed: () => SymbioticDialogs.showForgeSkillDialog(
                    context,
                    controller,
                  ),
                ),
              ],
            ),
            if (statusMsg.isNotEmpty) ...[
              UtilWidget.sizedBox8,
              AppSubItemTile(
                color: AppColors.xunaLime,
                child: Text(
                  statusMsg,
                  style: AppTextStyle.font12Bo,
                ),
              ),
            ],
            if (vitals != null) ...[
              UtilWidget.sizedBox8,
              AppSubItemTile(
                color: AppColors.xunaLilacSoft,
                trailing: AppTag(
                  text: vitals.healthStatus.toUpperCase(),
                  color: AppColors.xunaLime,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '💻 Sức khỏe PC: Pin ${vitals.batteryPercent}% (${vitals.isCharging ? "Đang sạc" : "Dùng pin"}) · RAM ${vitals.memoryUsedPercent}% · Ổ cứng trống ${vitals.diskFreeGb} GB',
                      style: AppTextStyle.font13Bo,
                    ),
                    if (lanIp.isNotEmpty)
                      Text(
                        '🌐 IP nội bộ (LAN): $lanIp · ${devPorts.isEmpty ? "Chưa phát hiện cổng Dev nào đang mở" : "Đang mở ${devPorts.length} cổng Dev"}',
                        style: AppTextStyle.font12Re.copyWith(
                          color: AppColors.xunaInkMuted,
                        ),
                      ),
                    if (devPorts.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final p in devPorts)
                            AppPillButton(
                              label: '🛡️ Canh :${p.port} (${p.process})',
                              selected: false,
                              onPressed: () => unawaited(
                                controller.watchDevPortFromUi(
                                  p.port,
                                  label: '${p.process} :${p.port}',
                                ),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
        UtilWidget.sizedBox12,
        AppSectionCard(
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
                              onPressed: () => controller.selectColorTheme(t.id),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

class SymbioticCapsulesPocketWatchdogsSection extends StatelessWidget {
  const SymbioticCapsulesPocketWatchdogsSection({
    super.key,
    required this.controller,
  });

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    final capsules = controller.workspaceCapsules;
    final items = controller.pocketItems;
    final watchdogs = controller.activeWatchdogs;
    final proposals = controller.habitProposals;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 1. Workspace Time-Capsules
        AppSectionCard(
          title: '1. Phiên làm việc đã lưu (${capsules.length})',
          trailing: AppPillButton(
            label: '+ Lưu phiên mới',
            selected: false,
            onPressed: () => SymbioticDialogs.showCaptureWorkspaceDialog(
              context,
              controller,
            ),
          ),
          children: [
            if (capsules.isEmpty)
              Text(
                'Chưa có phiên không gian làm việc nào được lưu. Bấm "+ Lưu phiên mới" để ghi nhớ dự án và bước làm tiếp theo.',
                style: AppTextStyle.font13Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              )
            else
              for (final cap in capsules)
                AppSubItemTile(
                  trailing: Wrap(
                    spacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      AppTag(
                        text: '${cap.dirtyCount} tệp đang sửa',
                        color: AppColors.xunaLilacSoft,
                      ),
                      if (cap.nextStepHint.isNotEmpty)
                        AppPillButton(
                          label: '📋 Copy bước tiếp',
                          selected: false,
                          onPressed: () => unawaited(
                            controller.copyTextToSystemClipboard(
                              cap.nextStepHint,
                              labelVi: 'bước làm tiếp theo',
                            ),
                          ),
                        ),
                      AppPillButton(
                        label: '✕',
                        selected: false,
                        onPressed: () =>
                            controller.removeWorkspaceCapsule(cap.capsuleId),
                      ),
                    ],
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
          trailing: Wrap(
            spacing: 6,
            children: [
              AppPillButton(
                label: '📋 Dán Clipboard',
                selected: false,
                onPressed: () =>
                    unawaited(controller.pasteSystemClipboardToPocket()),
              ),
              AppPillButton(
                label: '+ Thêm mục',
                selected: false,
                onPressed: () =>
                    SymbioticDialogs.showAddPocketDialog(context, controller),
              ),
            ],
          ),
          children: [
            if (items.isEmpty)
              Text(
                'Chưa có mục nào được lưu. Bấm "📋 Dán Clipboard" hoặc "+ Thêm mục" để lưu nhanh văn bản, lệnh terminal, JSON hoặc đường link (tự động ẩn API key nhạy cảm).',
                style: AppTextStyle.font13Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              )
            else
              for (final item in items)
                AppSubItemTile(
                  trailing: Wrap(
                    spacing: 6,
                    children: [
                      AppPillButton(
                        label: '📋 Copy',
                        selected: false,
                        onPressed: () => unawaited(
                          controller.copyTextToSystemClipboard(
                            item.text,
                            labelVi: item.label,
                          ),
                        ),
                      ),
                      AppPillButton(
                        label: '⚡ Biến đổi',
                        selected: false,
                        onPressed: () =>
                            controller.transformPocketItemFromUi(item),
                      ),
                      AppPillButton(
                        label: '✕',
                        selected: false,
                        onPressed: () =>
                            controller.removePocketItem(item.itemId),
                      ),
                    ],
                  ),
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
          trailing: Wrap(
            spacing: 6,
            children: [
              AppPillButton(
                label: '+ Theo dõi mới',
                selected: false,
                onPressed: () =>
                    SymbioticDialogs.showAddWatchdogDialog(context, controller),
              ),
              if (watchdogs.isNotEmpty)
                AppPillButton(
                  label: 'Xóa tất cả',
                  fillColor: AppColors.xunaHeart,
                  onPressed: controller.clearAllWatchdogs,
                ),
            ],
          ),
          children: [
            if (watchdogs.isEmpty) ...[
              Text(
                'Chưa có tác vụ nào đang được theo dõi. Chọn nhanh cổng Dev cần canh bên dưới:',
                style: AppTextStyle.font13Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              ),
              UtilWidget.sizedBox8,
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final preset in const <({int port, String label})>[
                    (port: 8000, label: 'Backend :8000'),
                    (port: 3000, label: 'Web App :3000'),
                    (port: 5173, label: 'Vite :5173'),
                  ])
                    AppPillButton(
                      label: '+ Canh cổng :${preset.port}',
                      selected: false,
                      onPressed: () => unawaited(
                        controller.watchDevPortFromUi(
                          preset.port,
                          label: preset.label,
                        ),
                      ),
                    ),
                ],
              ),
            ] else
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
                'Chưa có gợi ý quy trình nào. Khi bạn lặp lại các chuỗi thao tác trên máy tính, XUNA sẽ tự động đề xuất Macro tại đây.',
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
      ],
    );
  }
}

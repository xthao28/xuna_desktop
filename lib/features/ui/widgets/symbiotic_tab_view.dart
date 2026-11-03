import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Interactive Symbiotic Workspace Hub on Desktop (real user data, zero fake demo generators).
class SymbioticTabView extends BaseTabView<DesktopAgentController> {
  const SymbioticTabView({super.key, required super.controller});

  @override
  Widget buildTab(BuildContext context) {
    final capsules = controller.workspaceCapsules;
    final items = controller.pocketItems;
    final watchdogs = controller.activeWatchdogs;
    final proposals = controller.habitProposals;
    final skills = controller.forgedSkills;
    final vitals = controller.latestVitals.value;
    final devPorts = controller.activeDevPorts;
    final lanIp = controller.detectedLanIp.value;
    final statusMsg = controller.frontierStatusSummaryVi.value;
    final hasAnyData =
        capsules.isNotEmpty ||
        items.isNotEmpty ||
        watchdogs.isNotEmpty ||
        skills.isNotEmpty;

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

          // Quick-Start Action Hub on Desktop
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
                    onPressed: () => _showAddPocketDialog(context),
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
                    onPressed: () => _showCaptureWorkspaceDialog(context),
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
                    onPressed: () => _showAddWatchdogDialog(context),
                  ),
                  AppPillButton(
                    label: '🛠️ + Viết Tool tự động (OmniForge)',
                    selected: false,
                    onPressed: () => _showForgeSkillDialog(context),
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
                                label:
                                    '🛡️ Canh :${p.port} (${p.process})',
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
            trailing: AppPillButton(
              label: '+ Lưu phiên mới',
              selected: false,
              onPressed: () => _showCaptureWorkspaceDialog(context),
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
                  onPressed: () => _showAddPocketDialog(context),
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
                  onPressed: () => _showAddWatchdogDialog(context),
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
          UtilWidget.sizedBox12,

          // 5. OmniForge Citizen Toolsmith & Skill Workshop
          AppSectionCard(
            title: '5. Công cụ tự động & Làm mẫu 1 lần (${skills.length})',
            subtitle:
                'Biến việc lặp đi lặp lại thành 1 nút bấm: tự mô tả bằng lời hoặc làm mẫu 1 lần (Show-Me-Once) để XUNA tự học và lặp lại.',
            trailing: Wrap(
              spacing: 6,
              children: [
                AppPillButton(
                  label: controller.isTeachRecording.value
                      ? '✅ Đóng gói thành Tool'
                      : '🎥 Cách 2: Làm mẫu 1 lần (Show-Me-Once)',
                  selected: controller.isTeachRecording.value,
                  onPressed: controller.toggleTeachModeFromUi,
                ),
                AppPillButton(
                  label: '✍️ Cách 1: Tự mô tả Tool mới',
                  selected: !controller.isTeachRecording.value,
                  onPressed: () => _showForgeSkillDialog(context),
                ),
              ],
            ),
            children: [
              if (controller.isTeachRecording.value) ...[
                AppSubItemTile(
                  color: AppColors.xunaLime,
                  trailing: AppPillButton(
                    label: '✅ Hoàn tất & Tạo Tool',
                    selected: true,
                    onPressed: controller.toggleTeachModeFromUi,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '🔴 ĐANG Ở CHẾ ĐỘ LÀM MẪU 1 LẦN (SHOW-ME-ONCE)',
                        style: AppTextStyle.font13Bo,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Chọn thêm các bước thao tác mẫu bên dưới rồi bấm "✅ Hoàn tất & Tạo Tool", XUNA sẽ khái quát hóa thành vòng lặp tự động:',
                        style: AppTextStyle.font12Re.copyWith(
                          color: AppColors.xunaInkMuted,
                        ),
                      ),
                      const SizedBox(height: 6),
                      for (final step
                          in (controller.teachRecordedSteps.isEmpty
                              ? const <String>[
                                  'Bước 1: Chọn dòng đầu tiên trong danh sách dữ liệu',
                                  'Bước 2: Bấm tải tệp & chuẩn hóa tên theo ngày tháng',
                                ]
                              : controller.teachRecordedSteps))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 2),
                          child: Text(
                            '✓ $step',
                            style: AppTextStyle.mono11Bo,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final stepChip in const <({
                            String label,
                            String action,
                          })>[
                            (
                              label: '+ Lọc file PDF/XML',
                              action:
                                  'Lọc các tệp đúng định dạng PDF/XML và bỏ qua tệp trùng lặp',
                            ),
                            (
                              label: '+ Đổi tên theo Ngày',
                              action:
                                  'Đổi tên tệp chuẩn hóa theo mẫu Năm-Tháng_ChủĐề_STT',
                            ),
                            (
                              label: '+ Gom ra bảng Excel',
                              action:
                                  'Trích xuất trường dữ liệu chính và xuất bảng tổng hợp CSV/Excel',
                            ),
                          ])
                            AppPillButton(
                              label: stepChip.label,
                              selected: false,
                              onPressed: () => controller.addTeachStepFromUi(
                                stepChip.action,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
                UtilWidget.sizedBox8,
              ],
              if (skills.isEmpty && !controller.isTeachRecording.value) ...[
                Text(
                  '⚡ Chưa có Tool nào — chạm 1 lần vào mẫu bên dưới để tạo ngay hoặc bấm "✍️ Cách 1: Tự mô tả Tool mới":',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                ),
                UtilWidget.sizedBox8,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tpl in const <({
                      String label,
                      String goal,
                      String folder,
                    })>[
                      (
                        label: '📄 + Tool Tải Hóa Đơn',
                        goal:
                            'Tự động tải hết hóa đơn PDF/XML và gom bảng kê Excel',
                        folder: 'XUNA_HoaDon/Thang_11_2026',
                      ),
                      (
                        label: '👤 + Tool Lọc CV Ứng Viên',
                        goal:
                            'Quét lọc hồ sơ CV ứng viên theo kỹ năng và xếp hạng Kanban',
                        folder: 'XUNA_TuyenDung/UngVien',
                      ),
                      (
                        label: '🖼️ + Tool Đổi Tên Ảnh',
                        goal:
                            'Đổi tên và phân loại bộ sưu tập ảnh/media hàng loạt',
                        folder: 'XUNA_Media/Album_ChuDe',
                      ),
                      (
                        label: '📊 + Tool Đối Soát 2 Bảng Excel',
                        goal:
                            'Đối soát chênh lệch số tiền giữa bảng đơn hàng và sao kê',
                        folder: 'XUNA_DoiSoat',
                      ),
                      (
                        label: '🛒 + Tool Canh Giá Shopee',
                        goal:
                            'Theo dõi biến động giá sản phẩm đối thủ trên Shopee và cảnh báo tồn kho',
                        folder: 'XUNA_ShopRadar/GiaDoiThu',
                      ),
                    ])
                      AppPillButton(
                        label: tpl.label,
                        selected: false,
                        onPressed: () => controller.forgeQuickInvoiceTool(
                          goal: tpl.goal,
                          targetFolder: tpl.folder,
                        ),
                      ),
                  ],
                ),
              ] else
                for (final sk in skills)
                  AppSubItemTile(
                    color: AppColors.xunaLilacSoft,
                    trailing: Wrap(
                      spacing: 6,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        AppPillButton(
                          label: sk.runCount == 0
                              ? '▶ Chạy ngay (${sk.detectedItemsCount} mục)'
                              : '▶ Chạy lại',
                          selected: true,
                          onPressed: () =>
                              controller.runForgedSkillFromUi(sk.skillId),
                        ),
                        AppPillButton(
                          label: '📄 Copy SKILL.md',
                          selected: false,
                          onPressed: () => unawaited(
                            controller.copySkillMarkdownToClipboard(sk.skillId),
                          ),
                        ),
                        AppPillButton(
                          label: '✕',
                          selected: false,
                          onPressed: () =>
                              controller.removeForgedSkillFromUi(sk.skillId),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '🛠️ ${sk.titleVi}',
                          style: AppTextStyle.font13Bo,
                        ),
                        UtilWidget.sizedBox4,
                        Text(
                          '📂 Thư mục: ${sk.targetFolder} · Định dạng: ${sk.fileExtensions.join(", ").toUpperCase()} · Đã chạy: ${sk.runCount} lần',
                          style: AppTextStyle.font12Re.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                        ),
                        if (sk.dryRunSample.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '🔍 ${sk.dryRunSample}',
                            style: AppTextStyle.font12Bo,
                          ),
                        ],
                        if (sk.lastRunSummaryVi != null &&
                            sk.lastRunSummaryVi!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            '✓ ${sk.lastRunSummaryVi}',
                            style: AppTextStyle.font12Bo,
                          ),
                        ],
                        if (sk.scriptSteps.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          for (final step in sk.scriptSteps.take(4))
                            Text(
                              '• $step',
                              style: AppTextStyle.mono11Re.copyWith(
                                color: AppColors.xunaInkSoft,
                              ),
                            ),
                        ],
                      ],
                    ),
                  ),
            ],
          ),
          UtilWidget.sizedBox12,

          // ── 6. ClawdBot 3-Tier App Engine, Peekaboo & App Playbooks ──────
          AppSectionCard(
            title:
                '6. Điều khiển App 3 Tầng & Sổ tay Học App (${controller.learnedAppPlaybooks.length})',
            subtitle:
                'Tự động chọn đường nhanh nhất: Tầng 1 Native Bridge (0.1s) → Tầng 2 Quét Thanh Menu & Phím tắt (0.2s) → Tầng 3 Mắt thần Peekaboo [B1] [T1]. Chạm 1 lần là XUNA nhớ cấu trúc App mãi mãi!',
            trailing: Wrap(
              spacing: 6,
              children: [
                AppPillButton(
                  label: '🔍 + Quét & Học App bất kỳ',
                  selected: true,
                  onPressed: () => _showLearnCustomAppDialog(context),
                ),
                AppPillButton(
                  label: '✋ Thử dừng chờ 2FA/Đăng nhập',
                  selected: controller.activeHandover.value != null,
                  onPressed: () => controller.triggerHumanHandoverFromUi(
                    appName: controller.activeFocusedAppName.value,
                    taskTitleVi:
                        'Tự động đăng nhập và trích xuất báo cáo trong ${controller.activeFocusedAppName.value}',
                  ),
                ),
              ],
            ),
            children: [
              // Active App Context Bar
              Container(
                padding: const EdgeInsets.all(AppDimens.padding10),
                decoration: BoxDecoration(
                  color: AppColors.xunaPaper,
                  borderRadius: BorderRadius.circular(AppDimens.radius8),
                  border: Border.all(
                    color: AppColors.xunaInk,
                    width: AppDimens.strokeThin,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '💻 APP ĐANG MỞ TRÊN MACBOOK / PC: ${controller.activeFocusedAppName.value.toUpperCase()}',
                      style: AppTextStyle.mono10Bo,
                    ),
                    UtilWidget.sizedBox6,
                    Text(
                      'Bấm chọn nhanh 1 ứng dụng bên dưới để XUNA quét Menu Bar + nhãn Peekaboo [B1] [T1] và lưu vào Sổ tay Học App:',
                      style: AppTextStyle.font12Re.copyWith(
                        color: AppColors.xunaInkMuted,
                      ),
                    ),
                    UtilWidget.sizedBox6,
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final appPreset in const <String>[
                          'Visual Studio Code',
                          'Safari / Chrome',
                          'Notion / Apple Notes',
                          'Figma',
                          'Spotify',
                          'Zalo / CapCut',
                        ])
                          AppPillButton(
                            label: '⚡ Học & Quét $appPreset',
                            selected: controller.activeFocusedAppName.value ==
                                appPreset,
                            onPressed: () =>
                                controller.learnOrInspectAppFromUi(appPreset),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (controller.activeHandover.value != null) ...[
                UtilWidget.sizedBox8,
                Container(
                  padding: const EdgeInsets.all(AppDimens.padding10),
                  decoration: BoxDecoration(
                    color: AppColors.xunaLime.withValues(alpha: 0.45),
                    borderRadius: BorderRadius.circular(AppDimens.radius8),
                    border: Border.all(
                      color: AppColors.xunaInk,
                      width: AppDimens.stroke2,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '✋ CHẾ ĐỘ LÀM CÙNG NHAU (HUMAN-IN-THE-LOOP HANDOVER)',
                        style: AppTextStyle.mono10Bo,
                      ),
                      UtilWidget.sizedBox4,
                      Text(
                        controller.activeHandover.value!.blockerReasonVi,
                        style: AppTextStyle.font13Bo,
                      ),
                      UtilWidget.sizedBox6,
                      for (final step
                          in controller.activeHandover.value!.remainingStepsVi)
                        Text(
                          '• $step',
                          style: AppTextStyle.mono11Re,
                        ),
                      UtilWidget.sizedBox8,
                      Wrap(
                        spacing: 6,
                        children: [
                          AppPillButton(
                            label:
                                '✅ Mình bấm xong rồi — XUNA làm tiếp đi!',
                            selected: true,
                            onPressed: controller.resumeHumanHandoverFromUi,
                          ),
                          AppPillButton(
                            label: '✕ Hủy phiên',
                            selected: false,
                            onPressed: controller.cancelHumanHandoverFromUi,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if (controller.learnedAppPlaybooks.isNotEmpty) ...[
                UtilWidget.sizedBox8,
                for (final pb in controller.learnedAppPlaybooks)
                  AppSubItemTile(
                    color: AppColors.xunaPaper,
                    trailing: AppPillButton(
                      label: '✕',
                      selected: false,
                      onPressed: () =>
                          controller.removeAppPlaybookFromUi(pb.appId),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Wrap(
                          spacing: 6,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              '🧠 ${pb.appName}',
                              style: AppTextStyle.font13Bo,
                            ),
                            AppTag(
                              text: pb.tierBadgeVi,
                              color: pb.executionTier == 1
                                  ? AppColors.xunaLime
                                  : AppColors.xunaLilacSoft,
                            ),
                            AppTag(
                              text: 'Đã dùng ${pb.runCount} lần',
                              color: AppColors.xunaPaper,
                            ),
                          ],
                        ),
                        UtilWidget.sizedBox4,
                        Text(
                          pb.lastActionSummaryVi,
                          style: AppTextStyle.font12Bo,
                        ),
                        UtilWidget.sizedBox4,
                        Text(
                          '⌨️ Phím tắt học được: ${pb.learnedShortcuts.join(" · ")}',
                          style: AppTextStyle.mono11Re.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                        ),
                        Text(
                          '👁️ Nhãn Peekaboo: ${pb.peekabooNodes.join(" · ")}',
                          style: AppTextStyle.mono11Re.copyWith(
                            color: AppColors.xunaInkSoft,
                          ),
                        ),
                        UtilWidget.sizedBox6,
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final act in pb.quickActionsVi)
                              AppPillButton(
                                label: '▶ $act',
                                selected: false,
                                onPressed: () =>
                                    controller.learnOrInspectAppFromUi(
                                      pb.appName,
                                      customActionVi: act,
                                    ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _showLearnCustomAppDialog(BuildContext context) async {
    final appNameCtrl = TextEditingController();
    final taskCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        backgroundColor: AppColors.xunaPaper,
        title: Text(
          '🔍 Quét & Học App bất kỳ trên MacBook/PC',
          style: AppTextStyle.display17,
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Nhập tên ứng dụng bất kỳ đang có trên máy bạn. XUNA sẽ tự động quét Thanh Menu + đánh nhãn Peekaboo [B1] [T1] và lưu vào Sổ tay Học App:',
                style: AppTextStyle.font12Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              ),
              UtilWidget.sizedBox8,
              TextField(
                controller: appNameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Tên ứng dụng (VD: Figma, Obsidian, CapCut, Zalo...)',
                ),
              ),
              UtilWidget.sizedBox8,
              TextField(
                controller: taskCtrl,
                decoration: const InputDecoration(
                  labelText:
                      'Việc bạn muốn làm thử trong App này (tùy chọn)',
                  hintText: 'VD: Tạo trang ghi chú mới và chèn danh sách việc cần làm',
                ),
              ),
            ],
          ),
        ),
        actions: [
          AppPillButton(
            label: 'Hủy',
            selected: false,
            onPressed: () => Navigator.of(dialogCtx).pop(),
          ),
          AppPillButton(
            label: '🧠 Quét & Học ngay',
            selected: true,
            onPressed: () {
              final appName = appNameCtrl.text.trim();
              final task = taskCtrl.text.trim();
              Navigator.of(dialogCtx).pop();
              controller.learnOrInspectAppFromUi(
                appName.isEmpty ? 'Notion' : appName,
                customActionVi: task.isEmpty ? null : task,
              );
            },
          ),
        ],
      ),
    );
  }

  Future<void> _showForgeSkillDialog(BuildContext context) async {
    final goalCtrl = TextEditingController();
    final folderCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.xunaPaper,
          title: Text(
            '🛠️ Xưởng viết Tool tự động (OmniForge)',
            style: AppTextStyle.display17,
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chọn nhanh 1 mẫu bên dưới hoặc tự mô tả bằng tiếng Việt công việc bạn muốn XUNA viết thành công cụ:',
                  style: AppTextStyle.font12Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                ),
                UtilWidget.sizedBox8,
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tpl in const <({
                      String label,
                      String goal,
                      String folder,
                    })>[
                      (
                        label: '📄 Tải hóa đơn PDF/XML',
                        goal:
                            'Tự động tải hết hóa đơn PDF/XML và gom bảng kê Excel',
                        folder: 'XUNA_HoaDon/Thang_11_2026',
                      ),
                      (
                        label: '👤 Sàng lọc CV ứng viên',
                        goal:
                            'Quét lọc hồ sơ CV ứng viên theo kỹ năng và xếp hạng Kanban',
                        folder: 'XUNA_TuyenDung/UngVien',
                      ),
                      (
                        label: '🖼️ Đổi tên ảnh hàng loạt',
                        goal:
                            'Đổi tên và phân loại bộ sưu tập ảnh/media hàng loạt',
                        folder: 'XUNA_Media/Album_ChuDe',
                      ),
                      (
                        label: '📊 Đối soát 2 bảng Excel',
                        goal:
                            'Đối soát chênh lệch số tiền giữa bảng đơn hàng và sao kê',
                        folder: 'XUNA_DoiSoat',
                      ),
                      (
                        label: '🛒 Canh giá Shopee/TikTok',
                        goal:
                            'Theo dõi biến động giá sản phẩm đối thủ trên Shopee và cảnh báo tồn kho',
                        folder: 'XUNA_ShopRadar/GiaDoiThu',
                      ),
                    ])
                      AppPillButton(
                        label: tpl.label,
                        selected: false,
                        onPressed: () {
                          goalCtrl.text = tpl.goal;
                          folderCtrl.text = tpl.folder;
                        },
                      ),
                  ],
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: goalCtrl,
                  autofocus: true,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Mô tả việc bạn muốn Tool làm',
                    hintText:
                        'VD: Gom toàn bộ file PDF trong thư mục Downloads và xuất bảng tổng hợp CSV...',
                  ),
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: folderCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Thư mục lưu kết quả (tùy chọn)',
                    hintText: 'Để trống XUNA sẽ tự đặt thư mục phù hợp',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            AppPillButton(
              label: 'Hủy',
              selected: false,
              onPressed: () => Navigator.of(dialogCtx).pop(),
            ),
            AppPillButton(
              label: '🛠️ Viết Tool & Chạy thử 1 mẫu',
              selected: true,
              onPressed: () {
                final rawGoal = goalCtrl.text.trim();
                final rawFolder = folderCtrl.text.trim();
                Navigator.of(dialogCtx).pop();
                controller.forgeQuickInvoiceTool(
                  goal: rawGoal.isEmpty
                      ? 'Tự động tải hết hóa đơn PDF/XML và gom bảng kê Excel'
                      : rawGoal,
                  targetFolder: rawFolder.isEmpty ? null : rawFolder,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddPocketDialog(BuildContext context) async {
    final labelCtrl = TextEditingController();
    final textCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.xunaPaper,
          title: Text(
            '📥 Thêm vào Bộ nhớ tạm (Pocket)',
            style: AppTextStyle.display17,
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nhãn gợi nhớ (tùy chọn)',
                    hintText: 'VD: Lệnh chạy server, Link tài liệu, JSON mẫu...',
                  ),
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: textCtrl,
                  autofocus: true,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Nội dung cần lưu',
                    hintText:
                        'Nhập ghi chú, URL, JSON hoặc lệnh. XUNA tự động ẩn các khóa bí mật (API Key/Token).',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            AppPillButton(
              label: 'Hủy',
              selected: false,
              onPressed: () => Navigator.of(dialogCtx).pop(),
            ),
            AppPillButton(
              label: 'Lưu vào Pocket',
              selected: true,
              onPressed: () {
                final raw = textCtrl.text.trim();
                if (raw.isEmpty) return;
                Navigator.of(dialogCtx).pop();
                controller.pushQuickPocketSnippet(
                  raw,
                  label: labelCtrl.text.trim().isEmpty
                      ? null
                      : labelCtrl.text.trim(),
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showCaptureWorkspaceDialog(BuildContext context) async {
    final projectCtrl = TextEditingController();
    final branchCtrl = TextEditingController(text: 'main');
    final hintCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.xunaPaper,
          title: Text(
            '🧊 Lưu phiên làm việc hiện tại',
            style: AppTextStyle.display17,
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: projectCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Tên dự án hoặc công việc',
                    hintText: 'VD: xuna_pet, Báo cáo Q4, Thiết kế UI...',
                  ),
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: branchCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Nhánh Git / Trạng thái',
                    hintText: 'VD: main, feat/login, Đang làm dở...',
                  ),
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: hintCtrl,
                  maxLines: 2,
                  decoration: const InputDecoration(
                    labelText: 'Bước tiếp theo cần làm khi mở lại',
                    hintText: 'VD: Kiểm tra lại API thanh toán và viết unit test',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            AppPillButton(
              label: 'Hủy',
              selected: false,
              onPressed: () => Navigator.of(dialogCtx).pop(),
            ),
            AppPillButton(
              label: 'Lưu phiên làm việc',
              selected: true,
              onPressed: () {
                final proj = projectCtrl.text.trim();
                final hint = hintCtrl.text.trim();
                if (proj.isEmpty && hint.isEmpty) return;
                Navigator.of(dialogCtx).pop();
                controller.captureQuickWorkspaceCapsule(
                  project: proj.isEmpty ? 'Công việc cá nhân' : proj,
                  branch: branchCtrl.text.trim().isEmpty
                      ? 'main'
                      : branchCtrl.text.trim(),
                  dirtyCount: 0,
                  nextStepHint: hint.isEmpty ? 'Tiếp tục $proj' : hint,
                );
              },
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddWatchdogDialog(BuildContext context) async {
    final targetCtrl = TextEditingController();
    final labelCtrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        return AlertDialog(
          backgroundColor: AppColors.xunaPaper,
          title: Text(
            '🛡️ Theo dõi Cổng hoặc Tiến trình',
            style: AppTextStyle.display17,
          ),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: targetCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Số cổng (Port) hoặc Tên tiến trình (Process)',
                    hintText: 'VD: 8000, 5173, node, python, cargo...',
                  ),
                ),
                UtilWidget.sizedBox8,
                TextField(
                  controller: labelCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Mô tả ngắn (tùy chọn)',
                    hintText: 'VD: Backend API server',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            AppPillButton(
              label: 'Hủy',
              selected: false,
              onPressed: () => Navigator.of(dialogCtx).pop(),
            ),
            AppPillButton(
              label: 'Bắt đầu theo dõi',
              selected: true,
              onPressed: () {
                final raw = targetCtrl.text.trim().replaceFirst(':', '');
                if (raw.isEmpty) return;
                Navigator.of(dialogCtx).pop();
                final portNum = int.tryParse(raw);
                final label = labelCtrl.text.trim().isEmpty
                    ? null
                    : labelCtrl.text.trim();
                if (portNum != null) {
                  unawaited(
                    controller.watchDevPortFromUi(portNum, label: label),
                  );
                } else {
                  unawaited(
                    controller.watchCustomTargetFromUi(
                      targetKind: 'process',
                      processName: raw,
                      label: label,
                    ),
                  );
                }
              },
            ),
          ],
        );
      },
    );
  }
}

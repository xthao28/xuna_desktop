import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/features/ui/widgets/symbiotic/symbiotic_dialogs.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

class SymbioticOmniForgeSection extends StatelessWidget {
  const SymbioticOmniForgeSection({
    super.key,
    required this.controller,
  });

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    final skills = controller.forgedSkills;

    return AppSectionCard(
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
            onPressed: () =>
                SymbioticDialogs.showForgeSkillDialog(context, controller),
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
                if (controller.teachRecordedSteps.isEmpty)
                  Text(
                    'Chưa có bước nào được ghi nhận — hãy thao tác trên ứng dụng hoặc chọn bước bên dưới:',
                    style: AppTextStyle.mono11Re.copyWith(
                      color: AppColors.xunaInkMuted,
                    ),
                  )
                else
                  for (final step in controller.teachRecordedSteps)
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
                        label: '+ Quét tệp trong thư mục',
                        action:
                            'Quét danh sách tệp trong thư mục nguồn và bỏ qua tệp trùng lặp',
                      ),
                      (
                        label: '+ Đổi tên theo Ngày',
                        action:
                            'Đổi tên tệp chuẩn hóa theo mẫu Năm-Tháng_ChủĐề_STT',
                      ),
                      (
                        label: '+ Xuất bảng CSV/Markdown',
                        action:
                            'Trích xuất trường dữ liệu chính và xuất bảng tổng hợp CSV/Markdown',
                      ),
                    ])
                      AppPillButton(
                        label: stepChip.label,
                        selected: false,
                        onPressed: () =>
                            controller.addTeachStepFromUi(stepChip.action),
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
                  label: '📂 + Dọn & Phân loại Downloads',
                  goal:
                      'Phân loại và sắp xếp gọn các tệp trong thư mục Downloads theo định dạng',
                  folder: 'XUNA_DaSapXep/Downloads',
                ),
                (
                  label: '📊 + Tổng hợp dữ liệu ra CSV',
                  goal:
                      'Quét các tệp dữ liệu trong Documents và xuất bảng tổng hợp CSV',
                  folder: 'XUNA_BangTongHop',
                ),
                (
                  label: '🖼️ + Đổi tên Ảnh/Media hàng loạt',
                  goal:
                      'Đổi tên chuẩn hóa và phân loại bộ sưu tập ảnh/media hàng loạt',
                  folder: 'XUNA_Media/Album_ChuDe',
                ),
                (
                  label: '📝 + Trích xuất việc cần làm từ Tài liệu',
                  goal:
                      'Tổng hợp nội dung các tệp ghi chú Markdown/TXT và lập danh sách việc cần làm',
                  folder: 'XUNA_Content/GhiChu',
                ),
              ])
                AppPillButton(
                  label: tpl.label,
                  selected: false,
                  onPressed: () => controller.forgeSkillFromUi(
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
                    label: '📂 Mở thư mục',
                    selected: false,
                    onPressed: () => unawaited(
                      controller.openForgedSkillOutputFolderFromUi(sk.skillId),
                    ),
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
                    '📂 Thư mục thật: ${controller.resolveRealSkillDirectory(sk.targetFolder)} · Định dạng: ${sk.fileExtensions.join(", ").toUpperCase()} · Đã chạy: ${sk.runCount} lần',
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
    );
  }
}

class SymbioticClawdBotPlaybookSection extends StatelessWidget {
  const SymbioticClawdBotPlaybookSection({
    super.key,
    required this.controller,
  });

  final DesktopAgentController controller;

  @override
  Widget build(BuildContext context) {
    return AppSectionCard(
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
            onPressed: () => SymbioticDialogs.showLearnCustomAppDialog(
              context,
              controller,
            ),
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
                '💻 ỨNG DỤNG ĐANG CHỌN TRÊN HỆ THỐNG: ${controller.activeFocusedAppName.value.toUpperCase()}',
                style: AppTextStyle.mono10Bo,
              ),
              UtilWidget.sizedBox6,
              Text(
                'Chọn ứng dụng thật đã cài trên máy bên dưới (hoặc bấm "🔍 + Quét & Học App bất kỳ") để XUNA quét Menu + nhãn Peekaboo [B1] [T1]:',
                style: AppTextStyle.font12Re.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              ),
              UtilWidget.sizedBox6,
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final appName in <String>{
                    for (final d in controller.discoveredApps.take(8)) d.name,
                    for (final a
                        in (controller.activePolicy.value?.apps ?? const [])
                            .take(6))
                      a.name,
                  }.take(8))
                    AppPillButton(
                      label: '⚡ Học & Quét $appName',
                      selected:
                          controller.activeFocusedAppName.value == appName,
                      onPressed: () =>
                          controller.learnOrInspectAppFromUi(appName),
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
                      label: '✅ Mình bấm xong rồi — XUNA làm tiếp đi!',
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
                onPressed: () => controller.removeAppPlaybookFromUi(pb.appId),
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
                          onPressed: () => controller.learnOrInspectAppFromUi(
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
    );
  }
}

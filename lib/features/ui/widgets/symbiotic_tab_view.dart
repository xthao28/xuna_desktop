import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Tab 5 (`Cộng sinh`): Symbiotic Studio (`SYM-1..4`, `OMNI-1..4`, `FRONTIER-1..4`, `UIA-1`).
class SymbioticTabView extends BaseTabView<DesktopAgentController> {
  const SymbioticTabView({super.key, required super.controller});

  @override
  Widget buildTab(BuildContext context) {
    final capsules = controller.workspaceCapsules;
    final items = controller.pocketItems;
    final watchdogs = controller.activeWatchdogs;
    final proposals = controller.habitProposals;
    final skills = controller.forgedSkills;
    final recordingTeach = controller.isTeachRecording.value;
    final heartbeat = controller.lastHeartbeatStatus.value;
    final liveCanvas = controller.activeLiveCanvas.value;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppDisplayHeading(
            eyebrow: 'SYMBIOTIC STUDIO · 71 XTP TOOLS',
            title: 'Không gian Cộng sinh XUNA (SYM-1..4)',
            trailing: AppPillButton(
              label: 'Làm mới',
              selected: true,
              onPressed: controller.refreshSymbioticState,
            ),
          ),
          UtilWidget.sizedBox12,

          // 1. Workspace Time-Capsules
          AppSectionCard(
            title: '1. Kén Thời Gian Không Gian Làm Việc (${capsules.length})',
            trailing: AppPillButton(
              label: 'Đóng băng nhanh',
              selected: true,
              onPressed: () => controller.captureQuickWorkspaceCapsule(
                nextStepHint: 'Đóng băng nhanh từ bảng điều khiển Desktop',
              ),
            ),
            children: [
              if (capsules.isEmpty)
                Text(
                  'Chưa có kén không gian làm việc nào được lưu.',
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
            title: '2. Túi Không Gian Đa Thiết Bị (${items.length})',
            trailing: AppPillButton(
              label: 'Thêm ghi chú',
              onPressed: () => controller.pushQuickPocketSnippet(
                'TODO: Kiểm tra lại luồng đồng bộ XUNA Desktop',
                label: 'Ghi chú nhanh',
              ),
            ),
            children: [
              if (items.isEmpty)
                Text(
                  'Túi không gian đang trống.',
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
            title: '3. Lính Gác Tác Vụ Dài Hạn (${watchdogs.length})',
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
                  'Chưa có lính gác nào đang canh (build / test / cổng mạng).',
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
            title: '4. Đề Xuất Thói Quen Cộng Sinh (${proposals.length})',
            children: [
              if (proposals.isEmpty)
                Text(
                  'XUNA đang quan sát nhịp làm việc để đề xuất thói quen phù hợp.',
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

          // 5. OmniForge & Teach-by-Showing
          AppSectionCard(
            title: '5. Xưởng Kỹ Năng Tự Rèn & Dạy Qua Thao Tác (${skills.length})',
            trailing: Wrap(
              spacing: AppDimens.padding6,
              children: [
                AppPillButton(
                  label: 'Rèn Tool Hóa Đơn',
                  selected: true,
                  onPressed: () => controller.forgeQuickInvoiceTool(),
                ),
                AppPillButton(
                  label: recordingTeach ? 'Chốt Kỹ Năng Dạy' : 'Bắt Đầu Dạy',
                  fillColor: recordingTeach
                      ? AppColors.xunaHeart
                      : AppColors.xunaLilacSoft,
                  onPressed: () => controller.toggleTeachModeFromUi(),
                ),
              ],
            ),
            children: [
              if (skills.isEmpty)
                Text(
                  'Chưa có kỹ năng tự rèn nào trong Xưởng Kỹ Năng Cục Bộ.',
                  style: AppTextStyle.font13Re.copyWith(
                    color: AppColors.xunaInkMuted,
                  ),
                )
              else
                for (final sk in skills)
                  AppSubItemTile(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${sk.titleVi} (${sk.skillId})',
                                style: AppTextStyle.font13Bo,
                              ),
                            ),
                            Wrap(
                              spacing: AppDimens.padding6,
                              children: [
                                AppPillButton(
                                  label: 'Chạy Ngay',
                                  selected: true,
                                  onPressed: () =>
                                      controller.runForgedSkillFromUi(sk.skillId),
                                ),
                                AppPillButton(
                                  label: 'Sửa Nhanh',
                                  onPressed: () => controller
                                      .recordQuickSkillCorrectionFromUi(sk.skillId),
                                ),
                                AppPillButton(
                                  label: 'Xuất SKILL.md',
                                  onPressed: () =>
                                      controller.exportSkillMarkdownFromUi(sk.skillId),
                                ),
                              ],
                            ),
                          ],
                        ),
                        UtilWidget.sizedBox4,
                        Text(
                          'Thư mục: ${sk.targetFolder} · Đã chạy: ${sk.runCount} lần · Tự lành: v${sk.selfHealGeneration}',
                          style: AppTextStyle.font12Re.copyWith(
                            color: AppColors.xunaInkMuted,
                          ),
                        ),
                        if (sk.lastRunSummaryVi != null)
                          Text(
                            sk.lastRunSummaryVi!,
                            style: AppTextStyle.font12Bo,
                          ),
                      ],
                    ),
                  ),
            ],
          ),
          UtilWidget.sizedBox12,

          // 6. Zero-Token Heartbeat & Live Canvas A2UI
          AppSectionCard(
            title: '6. Nhịp Tim Không Tốn Token & Khung Giao Diện Động A2UI',
            trailing: Wrap(
              spacing: AppDimens.padding6,
              children: [
                AppPillButton(
                  label: 'Nhịp tuần tra 0-Token',
                  onPressed: () => controller.runZeroTokenHeartbeatFromUi(),
                ),
                AppPillButton(
                  label: 'Mở Live Canvas A2UI',
                  selected: true,
                  onPressed: () => controller.presentInvoiceLiveCanvasFromUi(),
                ),
              ],
            ),
            children: [
              Text(
                heartbeat == null
                    ? 'Chưa chạy nhịp tuần tra nền (2-Tier Heartbeat: tầng 1 tốn 0 token LLM khi không có biến động).'
                    : '${heartbeat.status} · Token LLM: ${heartbeat.llmTokensUsed} · ${heartbeat.summaryVi}',
                style: AppTextStyle.mono11Bo,
              ),
              if (liveCanvas != null) ...[
                UtilWidget.sizedBox6,
                AppSubItemTile(
                  color: AppColors.xunaLilacSoft,
                  margin: EdgeInsets.zero,
                  padding: const EdgeInsets.all(AppDimens.padding10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${liveCanvas.titleVi} (${liveCanvas.rows.length} dòng)',
                        style: AppTextStyle.font13Bo,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        liveCanvas.summaryVi,
                        style: AppTextStyle.font12Re,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
          UtilWidget.sizedBox12,

          // 7. Frontier Living Desktop Organism & Zero-Screenshot UIA
          AppSectionCard(
            title: '7. Thực Thể Sống Nơi Mép Màn Hình & Điều Khiển 0-Screenshot',
            subtitle: controller.frontierStatusSummaryVi.value.isEmpty
                ? 'Sẵn sàng: Kéo-thả tệp vào miệng XUNA (mac_notch / góc màn hình), tổng hợp sóng âm 16-bit PCM & đồ thị ký ức thời gian.'
                : controller.frontierStatusSummaryVi.value,
            children: [
              Wrap(
                spacing: AppDimens.paddingVerySmall,
                runSpacing: AppDimens.paddingVerySmall,
                children: [
                  AppPillButton(
                    label: 'Thả Tệp Mép Màn Hình & Tiếng Kêu',
                    onPressed: () =>
                        controller.feedOverlayDropAndVocalizeFromUi(),
                  ),
                  AppPillButton(
                    label: 'Chòm Sao Ký Ức & Hít Thở 4-7-8',
                    onPressed: () =>
                        controller.updateChronoGraphAndRitualFromUi(),
                  ),
                  AppPillButton(
                    label: 'Điều Khiển Ứng Dụng 0-Screenshot',
                    selected: true,
                    onPressed: () =>
                        controller.runZeroScreenshotUiAutomationFromUi(),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

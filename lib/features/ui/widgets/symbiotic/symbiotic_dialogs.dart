import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

class SymbioticDialogs {
  const SymbioticDialogs._();

  static Future<void> showLearnCustomAppDialog(
    BuildContext context,
    DesktopAgentController controller,
  ) async {
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
                  labelText:
                      'Tên ứng dụng (VD: Figma, Obsidian, CapCut, Zalo...)',
                ),
              ),
              UtilWidget.sizedBox8,
              TextField(
                controller: taskCtrl,
                decoration: const InputDecoration(
                  labelText: 'Việc bạn muốn làm thử trong App này (tùy chọn)',
                  hintText:
                      'VD: Tạo trang ghi chú mới và chèn danh sách việc cần làm',
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
              if (appName.isEmpty) return;
              Navigator.of(dialogCtx).pop();
              controller.learnOrInspectAppFromUi(
                appName,
                customActionVi: task.isEmpty ? null : task,
              );
            },
          ),
        ],
      ),
    );
  }

  static Future<void> showForgeSkillDialog(
    BuildContext context,
    DesktopAgentController controller,
  ) async {
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
                        label: '📂 Dọn & phân loại Downloads',
                        goal:
                            'Phân loại và sắp xếp gọn các tệp trong thư mục Downloads theo định dạng',
                        folder: 'XUNA_DaSapXep/Downloads',
                      ),
                      (
                        label: '📊 Tổng hợp dữ liệu ra CSV',
                        goal:
                            'Quét các tệp dữ liệu trong Documents và xuất bảng tổng hợp CSV',
                        folder: 'XUNA_BangTongHop',
                      ),
                      (
                        label: '🖼️ Đổi tên ảnh hàng loạt',
                        goal:
                            'Đổi tên và phân loại bộ sưu tập ảnh/media hàng loạt',
                        folder: 'XUNA_Media/Album_ChuDe',
                      ),
                      (
                        label: '📝 Trích xuất việc cần làm',
                        goal:
                            'Tổng hợp nội dung các tệp ghi chú Markdown/TXT và lập danh sách việc cần làm',
                        folder: 'XUNA_Content/GhiChu',
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
                if (rawGoal.isEmpty) return;
                Navigator.of(dialogCtx).pop();
                controller.forgeSkillFromUi(
                  goal: rawGoal,
                  targetFolder: rawFolder.isEmpty ? null : rawFolder,
                );
              },
            ),
          ],
        );
      },
    );
  }

  static Future<void> showAddPocketDialog(
    BuildContext context,
    DesktopAgentController controller,
  ) async {
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

  static Future<void> showCaptureWorkspaceDialog(
    BuildContext context,
    DesktopAgentController controller,
  ) async {
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
                    hintText:
                        'VD: Kiểm tra lại API thanh toán và viết unit test',
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

  static Future<void> showAddWatchdogDialog(
    BuildContext context,
    DesktopAgentController controller,
  ) async {
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

import 'package:flutter/material.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';
import 'package:xuna_xtp/xuna_xtp.dart';

/// Tab 4 (`Nhật ký`): Content-free local tool execution audit log.
class AuditTabView extends BaseTabView<DesktopAgentController> {
  const AuditTabView({super.key, required super.controller});

  @override
  Widget buildTab(BuildContext context) {
    final items = controller.recentAuditRecords;
    if (items.isEmpty) {
      return const Center(
        child: SingleChildScrollView(
          child: AppEmptyState(
            title: 'Chưa có nhật ký thực thi công cụ nào.',
            message:
                'Mọi lệnh XTP v1 thực thi trên máy tính sẽ được ghi nhận tại đây (không lưu nội dung nhạy cảm).',
          ),
        ),
      );
    }

    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => UtilWidget.sizedBox8,
      itemBuilder: (context, index) {
        final item = items[index];
        final isOk = item.status == XtpStatus.ok;
        return AppInkCard(
          shadow: AppDimens.shadow2,
          padding: const EdgeInsets.symmetric(
            horizontal: AppDimens.padding14,
            vertical: AppDimens.padding10,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item.tool} → ${item.status.wire}',
                      style: AppTextStyle.mono12Bo,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${item.ts.toIso8601String()} · ${item.durationMs} ms · ${item.invocationId}',
                      style: AppTextStyle.mono10Re.copyWith(
                        color: AppColors.xunaInkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              AppStatusBadge(
                label: item.status.wire.toUpperCase(),
                variant: isOk
                    ? AppStatusBadgeVariant.success
                    : AppStatusBadgeVariant.danger,
              ),
            ],
          ),
        );
      },
    );
  }
}


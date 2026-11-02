import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:xuna_desktop/core/controller/desktop_agent_controller.dart';
import 'package:xuna_desktop/core/presentation/widgets/base_tab_view.dart';
import 'package:xuna_desktop/shared/constants/const_src.dart';
import 'package:xuna_desktop/shared/themes/app_colors.dart';
import 'package:xuna_desktop/shared/widgets/widget_src.dart';

/// Tab 1 (`Ghép nối`): Mode A QR + SAS pairing and Mode B enrolled host card.
class EnrollmentTabView extends BaseTabView<DesktopAgentController> {
  const EnrollmentTabView({
    super.key,
    required super.controller,
    required this.sasCodeKey,
    required this.lanModeSwitchKey,
  });

  final Key sasCodeKey;
  final Key lanModeSwitchKey;

  @override
  Widget buildTab(BuildContext context) {
    final enrolled = controller.enrolledState.value;
    if (enrolled != null) {
      return SingleChildScrollView(
        child: AppInkCard(
          padding: const EdgeInsets.all(AppDimens.padding18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              AppDisplayHeading(
                eyebrow: 'MÁY TÍNH ĐÃ LIÊN KẾT · MODE B P-256',
                title: 'Đã ghép nối: ${enrolled.alias}',
                titleStyle: AppTextStyle.display28,
                trailing: const AppStatusBadge(
                  label: 'ĐÃ GHÉP NỐI',
                  variant: AppStatusBadgeVariant.success,
                ),
              ),
              UtilWidget.sizedBox12,
              AppSubItemTile(
                margin: EdgeInsets.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: AppDimens.padding14,
                  vertical: AppDimens.padding10,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Host ID: ${enrolled.hostId}',
                      style: AppTextStyle.mono11Re,
                    ),
                    UtilWidget.sizedBox4,
                    Text(
                      'Xác thực phiên: ECDSA P-256 TOFU · 71 công cụ XTP v1 đã đồng bộ',
                      style: AppTextStyle.font12Re.copyWith(
                        color: AppColors.xunaInkMuted,
                      ),
                    ),
                  ],
                ),
              ),
              UtilWidget.sizedBox14,
              AppInkCard(
                shadow: 0,
                padding: const EdgeInsets.all(AppDimens.padding14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Chế độ LAN ngoại tuyến (chỉ điều khiển nhạc)',
                            style: AppTextStyle.font14Bo,
                          ),
                          UtilWidget.sizedBox4,
                          Text(
                            'Cho phép điện thoại đã ghép nối điều khiển nhạc (media.*) trực tiếp qua mạng LAN nội bộ khi mất kết nối máy chủ.',
                            style: AppTextStyle.font12Re.copyWith(
                              color: AppColors.xunaInkMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    UtilWidget.sizedBoxWidth12,
                    AppToggle(
                      key: lanModeSwitchKey,
                      value: controller.lanModeEnabled.value,
                      onChanged: controller.toggleLanMode,
                    ),
                  ],
                ),
              ),
              UtilWidget.sizedBox16,
              AppBoxButton(
                label: 'Hủy ghép nối và tạo mã QR mới',
                onPressed: controller.unpairAndRestartEnrollment,
              ),
            ],
          ),
        ),
      );
    }

    final display = controller.pendingEnrollment.value;
    if (display == null) {
      return const Center(
        child: SingleChildScrollView(
          child: AppEmptyState(
            icon: AppPetAvatarBadge(size: 56),
            title: 'Đang chuẩn bị mã ghép nối',
            message: 'Đang kết nối máy chủ XUNA để khởi tạo phiên Mode A...',
          ),
        ),
      );
    }

    final spacedSas = display.sas.length == 6
        ? '${display.sas.substring(0, 3)} ${display.sas.substring(3)}'
        : display.sas;

    return SingleChildScrollView(
      child: AppInkCard(
        padding: const EdgeInsets.all(AppDimens.padding18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            AppDisplayHeading(
              eyebrow: 'GHÉP NỐI MÁY TÍNH MỚI · MODE A',
              title: 'Quét mã QR bằng ứng dụng XUNA trên điện thoại',
              trailing: AppTag(
                text: 'Tên máy: ${display.hostname}',
                color: AppColors.xunaLilacSoft,
              ),
            ),
            UtilWidget.sizedBox14,
            Wrap(
              spacing: AppDimens.padding18,
              runSpacing: AppDimens.padding14,
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                AppInkCard(
                  color: Colors.white,
                  shadow: AppDimens.shadow3,
                  padding: const EdgeInsets.all(AppDimens.padding10),
                  child: QrImageView(
                    data: display.qrUri,
                    size: 176,
                    backgroundColor: Colors.white,
                  ),
                ),
                SizedBox(
                  width: 240,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Mã xác nhận 6 chữ số (SAS):',
                        style: AppTextStyle.font13Semi.copyWith(
                          color: AppColors.xunaInkMuted,
                        ),
                      ),
                      UtilWidget.sizedBox8,
                      AppInkCard(
                        color: AppColors.xunaLime,
                        shadow: AppDimens.shadow3,
                        padding: const EdgeInsets.symmetric(
                          vertical: AppDimens.padding14,
                          horizontal: AppDimens.defaultPadding,
                        ),
                        child: Center(
                          child: Text(
                            spacedSas,
                            key: sasCodeKey,
                            style: AppTextStyle.display48,
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                      UtilWidget.sizedBox10,
                      Text(
                        'Đối chiếu 6 chữ số này trên màn hình điện thoại và bấm "Khớp" để hoàn tất.',
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
        ),
      ),
    );
  }
}


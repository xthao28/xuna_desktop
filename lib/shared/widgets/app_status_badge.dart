import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

enum AppStatusBadgeVariant {
  pending,
  success,
  info,
  danger,
  neutral,
}

/// Small semantic status chip with an optional status dot.
class AppStatusBadge extends StatelessWidget {
  const AppStatusBadge({
    super.key,
    required this.label,
    this.variant = AppStatusBadgeVariant.neutral,
    this.showDot = true,
  });

  final String label;
  final AppStatusBadgeVariant variant;
  final bool showDot;

  @override
  Widget build(BuildContext context) {
    final (bg, fg, dotColor) = switch (variant) {
      AppStatusBadgeVariant.pending => (
          AppColors.xunaConnecting,
          AppColors.xunaInk,
          AppColors.xunaConnecting,
        ),
      AppStatusBadgeVariant.success => (
          AppColors.xunaLime,
          AppColors.xunaInk,
          AppColors.xunaOnline,
        ),
      AppStatusBadgeVariant.info => (
          AppColors.xunaLilacSoft,
          AppColors.xunaInk,
          AppColors.xunaLilacDeep,
        ),
      AppStatusBadgeVariant.danger => (
          AppColors.xunaHeart,
          AppColors.xunaInk,
          AppColors.xunaHeart,
        ),
      AppStatusBadgeVariant.neutral => (
          AppColors.xunaPaper,
          AppColors.xunaInkMuted,
          AppColors.xunaOffline,
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.paddingSmall,
        vertical: AppDimens.paddingSmallest,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(AppDimens.radius8),
        border: Border.all(
          color: AppColors.xunaInk,
          width: AppDimens.stroke2,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: AppDimens.padding6,
              height: AppDimens.padding6,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                border: Border.all(
                  color: AppColors.xunaInk,
                  width: AppDimens.strokeThin,
                ),
              ),
            ),
            const SizedBox(width: AppDimens.padding6),
          ],
          Text(
            label,
            style: AppTextStyle.font10Bo.copyWith(color: fg),
          ),
        ],
      ),
    );
  }
}


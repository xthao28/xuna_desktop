import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_ink_card.dart';
import 'app_pill_button.dart';

/// Reusable empty state view: optional icon, title, description, and action button.
class AppEmptyState extends StatelessWidget {
  const AppEmptyState({
    super.key,
    required this.message,
    this.title,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? title;
  final Widget? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final heading = title;
    final buttonLabel = actionLabel;
    final iconWidget = icon;

    return AppInkCard(
      shadow: AppDimens.shadow2,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.padding18,
        vertical: AppDimens.padding24,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (iconWidget != null) ...[
            iconWidget,
            const SizedBox(height: AppDimens.padding14),
          ],
          if (heading != null) ...[
            Text(
              heading,
              style: AppTextStyle.font16Semi,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppDimens.paddingSmallest),
          ],
          Text(
            message,
            style:
                AppTextStyle.font14Re.copyWith(color: AppColors.xunaInkMuted),
            textAlign: TextAlign.center,
          ),
          if (buttonLabel != null && onAction != null) ...[
            const SizedBox(height: AppDimens.padding14),
            AppPillButton(
              label: buttonLabel,
              onPressed: onAction,
              pill: false,
              selected: true,
            ),
          ],
        ],
      ),
    );
  }
}


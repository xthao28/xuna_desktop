import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_ink_card.dart';

/// Text button in an outlined box: sheet actions and menu rows.
/// [highlighted] uses the lime fill with a shadow. [danger] uses the heart fill.
class AppBoxButton extends StatelessWidget {
  const AppBoxButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.highlighted = false,
    this.danger = false,
    this.compact = false,
    this.alignStart = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool highlighted;
  final bool danger;
  final bool compact;
  final bool alignStart;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final bgColor = danger
        ? AppColors.xunaHeart
        : highlighted
            ? AppColors.xunaLime
            : AppColors.xunaCard;
    return AppInkCard(
      color: bgColor,
      radius: compact ? AppDimens.radius10 : AppDimens.radius12,
      shadow: (highlighted || danger) ? AppDimens.shadow3 : AppDimens.shadow2,
      enabled: onPressed != null,
      onTap: onPressed,
      semanticLabel: label,
      padding: EdgeInsets.symmetric(
        horizontal:
            compact ? AppDimens.paddingSmall : AppDimens.defaultPadding,
        vertical:
            compact ? AppDimens.paddingVerySmall : AppDimens.padding10,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment:
            alignStart ? MainAxisAlignment.start : MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: AppColors.xunaInk),
            const SizedBox(width: AppDimens.padding6),
          ],
          Flexible(
            child: Text(
              label,
              style: compact ? AppTextStyle.font13Bo : AppTextStyle.font15Bo,
              textAlign: alignStart ? TextAlign.start : TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}


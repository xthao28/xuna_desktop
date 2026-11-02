import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_ink_card.dart';

/// Compact outlined choice: quick replies (pill) and filters (rounded box).
/// [selected] fills it lime with a shadow. [onPressed] null disables it.
class AppPillButton extends StatelessWidget {
  const AppPillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
    this.pill = true,
    this.fillColor,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;
  final bool pill;
  final Color? fillColor;

  @override
  Widget build(BuildContext context) {
    return AppInkCard(
      color: fillColor ??
          (selected ? AppColors.xunaLime : AppColors.xunaCard),
      radius: pill ? AppDimens.radiusPill : AppDimens.radius10,
      borderWidth: pill ? AppDimens.stroke2 : AppDimens.stroke,
      shadow: pill || selected ? AppDimens.shadow2 : 0,
      enabled: onPressed != null,
      onTap: onPressed,
      semanticLabel: label,
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.paddingSmall,
        vertical: AppDimens.padding6,
      ),
      child: Text(
        label,
        style: selected ? AppTextStyle.font13Bo : AppTextStyle.font13Semi,
      ),
    );
  }
}


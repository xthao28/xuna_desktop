import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_ink_card.dart';

/// Primary XUNA action: display-font label on a lime ink card.
class AppCtaButton extends StatelessWidget {
  const AppCtaButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.color = AppColors.xunaLime,
    this.height = AppDimens.buttonHeight,
    this.large = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final Color color;
  final double height;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return AppInkCard(
      color: color,
      radius: large ? AppDimens.radius14 : AppDimens.radius12,
      borderWidth: AppDimens.strokeThick,
      shadow: large ? AppDimens.shadow5 : AppDimens.shadow4,
      enabled: onPressed != null,
      onTap: onPressed,
      semanticLabel: label,
      child: SizedBox(
        height: large ? AppDimens.ctaHeight : height,
        child: Center(
          child: Text(
            label,
            style: large ? AppTextStyle.display36 : AppTextStyle.display22,
          ),
        ),
      ),
    );
  }
}


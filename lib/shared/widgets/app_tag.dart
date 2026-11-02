import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_status_dot.dart';

/// Small outlined label: activity chips, provenance tags, status tags.
class AppTag extends StatelessWidget {
  const AppTag({
    super.key,
    required this.text,
    this.color = AppColors.xunaCard,
    this.style,
    this.outlined = true,
    this.dotColor,
    this.dotBlinking = false,
  });

  final String text;
  final Color color;
  final TextStyle? style;
  final bool outlined;
  final Color? dotColor;
  final bool dotBlinking;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimens.paddingVerySmall,
        vertical: AppDimens.paddingSmallest,
      ),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppDimens.radius8),
        border: outlined
            ? Border.all(color: AppColors.xunaInk, width: AppDimens.stroke2)
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            AppStatusDot(color: dotColor!, blinking: dotBlinking, size: 9),
            const SizedBox(width: AppDimens.padding6),
          ],
          Flexible(
            child: Text(
              text,
              style: style ?? AppTextStyle.mono9Bo,
            ),
          ),
        ],
      ),
    );
  }
}


import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// Pixel sparkle cross mark matching XUNA Mobile's `ic_sparkle.svg`.
class AppSparkleMark extends StatelessWidget {
  const AppSparkleMark({
    super.key,
    this.size = 18,
    this.color = AppColors.xunaSparkle,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _SparklePainter(color)),
    );
  }
}

class _SparklePainter extends CustomPainter {
  const _SparklePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    final unit = size.width / 5.0;
    canvas.drawRect(Rect.fromLTWH(2 * unit, 0, unit, 1.4 * unit), paint);
    canvas.drawRect(Rect.fromLTWH(2 * unit, 3.6 * unit, unit, 1.4 * unit), paint);
    canvas.drawRect(Rect.fromLTWH(0, 2 * unit, 1.4 * unit, unit), paint);
    canvas.drawRect(Rect.fromLTWH(3.6 * unit, 2 * unit, 1.4 * unit, unit), paint);
    canvas.drawRect(
      Rect.fromLTWH(2.1 * unit, 2.1 * unit, 0.8 * unit, 0.8 * unit),
      paint,
    );
  }

  @override
  bool shouldRepaint(_SparklePainter oldDelegate) => oldDelegate.color != color;
}

/// Screen or section title in the display font with the blue pixel sparkle,
/// an optional mono eyebrow/note and an optional subtitle below.
class AppDisplayHeading extends StatelessWidget {
  const AppDisplayHeading({
    super.key,
    required this.title,
    this.eyebrow,
    this.note,
    this.subtitle,
    this.titleStyle,
    this.trailing,
  });

  final String title;
  final String? eyebrow;
  final String? note;
  final String? subtitle;
  final TextStyle? titleStyle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (eyebrow != null) ...[
          Row(
            children: [
              const AppSparkleMark(size: 13),
              const SizedBox(width: AppDimens.padding6),
              Text(
                eyebrow!,
                style: AppTextStyle.mono10Bo.copyWith(
                  color: AppColors.xunaInkMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
        ],
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Flexible(
                    child: Text(
                      title,
                      style: titleStyle ?? AppTextStyle.display22,
                    ),
                  ),
                  if (eyebrow == null) ...[
                    const SizedBox(width: AppDimens.padding6),
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: AppSparkleMark(size: 14),
                    ),
                  ],
                ],
              ),
            ),
            if (note != null) ...[
              const SizedBox(width: AppDimens.paddingSmall),
              Text(note!, style: AppTextStyle.mono10Re),
            ],
            if (trailing != null) ...[
              const SizedBox(width: AppDimens.paddingSmall),
              trailing!,
            ],
          ],
        ),
        if (subtitle != null)
          Padding(
            padding: const EdgeInsets.only(top: AppDimens.paddingSmallest),
            child: Text(
              subtitle!,
              style: AppTextStyle.font13Re.copyWith(
                color: AppColors.xunaInkMuted,
              ),
            ),
          ),
      ],
    );
  }
}


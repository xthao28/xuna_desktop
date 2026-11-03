import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';
import 'app_ink_card.dart';

/// Reusable XUNA section card with a header row (title + trailing action/tags),
/// optional subtitle/description, optional action bar, and body children.
class AppSectionCard extends StatelessWidget {
  const AppSectionCard({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.children = const <Widget>[],
    this.color = AppColors.xunaCard,
    this.shadow = AppDimens.shadow3,
    this.padding = const EdgeInsets.all(AppDimens.padding14),
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget> children;
  final Color color;
  final double shadow;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return AppInkCard(
      color: color,
      shadow: shadow,
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                flex: 3,
                child: Text(
                  title,
                  style: AppTextStyle.font15Bo,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppDimens.paddingSmall),
                Flexible(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: trailing!,
                  ),
                ),
              ],
            ],
          ),
          if (subtitle != null) ...[
            const SizedBox(height: AppDimens.paddingSmallest),
            Text(
              subtitle!,
              style: AppTextStyle.font12Re.copyWith(
                color: AppColors.xunaInkMuted,
              ),
            ),
          ],
          if (children.isNotEmpty) ...[
            const SizedBox(height: AppDimens.paddingVerySmall),
            ...children,
          ],
        ],
      ),
    );
  }
}

/// Reusable inner row tile inside an [AppSectionCard] (paper fill + thin ink border).
class AppSubItemTile extends StatelessWidget {
  const AppSubItemTile({
    super.key,
    required this.child,
    this.trailing,
    this.color = AppColors.xunaPaper,
    this.margin = const EdgeInsets.only(top: AppDimens.padding6),
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppDimens.padding10,
      vertical: AppDimens.paddingVerySmall,
    ),
  });

  final Widget child;
  final Widget? trailing;
  final Color color;
  final EdgeInsetsGeometry margin;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      padding: padding,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(AppDimens.radius8),
        border: Border.all(
          color: AppColors.xunaInk,
          width: AppDimens.strokeThin,
        ),
      ),
      child: trailing == null
          ? child
          : Row(
              children: [
                Expanded(flex: 3, child: child),
                const SizedBox(width: AppDimens.paddingSmall),
                Flexible(
                  flex: 2,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: trailing!,
                  ),
                ),
              ],
            ),
    );
  }
}

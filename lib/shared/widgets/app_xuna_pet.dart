import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// Visual vocabulary only; this widget has no device or pet-life dependency.
enum AppPetExpression { idle, happy, curious, sleep }

enum AppPetBackground { room, reading, garden }

/// Shared XUNA artwork for scenes, portraits and decorative illustrations.
class AppXunaPet extends StatelessWidget {
  const AppXunaPet({
    super.key,
    this.expression = AppPetExpression.idle,
    this.animated = false,
    this.scene = false,
    this.background,
    this.themeId,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });

  final AppPetExpression expression;
  final bool animated;
  final bool scene;
  final AppPetBackground? background;
  final String? themeId;
  final double? width;
  final double? height;
  final BoxFit fit;

  String _resolveSpriteAssetPath({required bool play, required bool forcePet}) {
    final resolvedTheme = XunaColorThemes.byId(themeId);
    final isNonDefaultTheme =
        themeId != null && resolvedTheme.id != XunaColorThemes.greenEdition.id;
    if (isNonDefaultTheme) {
      return 'assets/images/xuna_pet_${resolvedTheme.id}_${expression.name}.png';
    }
    final prefix = (forcePet || background != null)
        ? 'xuna_pet'
        : scene
            ? 'xuna'
            : 'xuna_pet';
    return 'assets/images/${prefix}_${expression.name}.${play ? 'gif' : 'png'}';
  }

  @override
  Widget build(BuildContext context) {
    final resolvedTheme = XunaColorThemes.byId(themeId);
    final isNonDefaultTheme =
        themeId != null && resolvedTheme.id != XunaColorThemes.greenEdition.id;
    final play = (scene || background != null) &&
        animated &&
        !isNonDefaultTheme &&
        // ignore: deprecated_member_use
        TickerMode.of(context) &&
        !MediaQuery.disableAnimationsOf(context);
    final effectiveBackdrop = background ??
        (scene && isNonDefaultTheme ? AppPetBackground.room : null);
    final path = _resolveSpriteAssetPath(
      play: play,
      forcePet: effectiveBackdrop != null,
    );
    return Image.asset(
      path,
      key: ValueKey(path),
      width: width,
      height: height,
      fit: fit,
      filterQuality: FilterQuality.none,
      excludeFromSemantics: true,
      errorBuilder: (_, __, ___) => Icon(
        Icons.pets,
        color: AppColors.xunaInk,
        size: (width ?? 32) * 0.6,
      ),
    );
  }
}

/// Framed Pixel Art XUNA avatar badge for headers and cards.
class AppPetAvatarBadge extends StatelessWidget {
  const AppPetAvatarBadge({
    super.key,
    this.expression = AppPetExpression.idle,
    this.size = 44,
    this.backgroundColor = AppColors.xunaLilacSoft,
  });

  final AppPetExpression expression;
  final double size;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppDimens.radius10),
        border: Border.all(
          color: AppColors.xunaInk,
          width: AppDimens.stroke2,
        ),
        boxShadow: const [
          BoxShadow(
            color: AppColors.xunaInk,
            offset: Offset(AppDimens.shadow2, AppDimens.shadow2),
          ),
        ],
      ),
      child: AppXunaPet(
        expression: expression,
        width: size - 8,
        height: size - 8,
      ),
    );
  }
}


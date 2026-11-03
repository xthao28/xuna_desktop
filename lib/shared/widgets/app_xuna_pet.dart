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
    this.showAccentParticle = false,
    this.width,
    this.height,
    this.fit = BoxFit.contain,
  });

  final AppPetExpression expression;
  final bool animated;
  final bool scene;
  final AppPetBackground? background;
  final String? themeId;
  final bool showAccentParticle;
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
    final pet = Image.asset(
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
    if (effectiveBackdrop == null && !showAccentParticle) return pet;
    if (effectiveBackdrop == null && showAccentParticle) {
      return SizedBox(
        width: width,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(child: pet),
            Positioned(
              top: 2,
              right: 2,
              child: CustomPaint(
                size: const Size(18, 16),
                painter: _ThemeAccentParticlePainter(
                  kind: resolvedTheme.accentParticle,
                  color: resolvedTheme.shadow,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: AspectRatio(
        aspectRatio: 4 / 3,
        child: ClipRect(
          child: Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _PixelBackdrop(
                  effectiveBackdrop!,
                  theme: resolvedTheme,
                ),
              ),
              Align(
                alignment: const Alignment(0, 0.65),
                child: FractionallySizedBox(
                  widthFactor: 0.6,
                  heightFactor: 0.56,
                  child: Stack(
                    clipBehavior: Clip.none,
                    fit: StackFit.expand,
                    children: [
                      pet,
                      Positioned(
                        top: 2,
                        right: 10,
                        child: CustomPaint(
                          size: const Size(18, 16),
                          painter: _ThemeAccentParticlePainter(
                            kind: resolvedTheme.accentParticle,
                            color: resolvedTheme.highlight,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Renders the signature pixel particle (`rays`, `sparkle`, `heart`) for a Color Theme.
class _ThemeAccentParticlePainter extends CustomPainter {
  const _ThemeAccentParticlePainter({
    required this.kind,
    required this.color,
  });

  final String kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..isAntiAlias = false;
    if (kind == 'heart') {
      const rows = <String>[
        '.XX.XX.',
        'XXXXXXX',
        'XXXXXXX',
        '.XXXXX.',
        '..XXX..',
        '...X...',
      ];
      for (var r = 0; r < rows.length; r++) {
        for (var c = 0; c < rows[r].length; c++) {
          if (rows[r][c] == 'X') {
            canvas.drawRect(
              Rect.fromLTWH(c * 2.0, r * 2.0, 2.0, 2.0),
              paint,
            );
          }
        }
      }
    } else if (kind == 'sparkle') {
      canvas.drawRect(const Rect.fromLTWH(3, 0, 3, 9), paint);
      canvas.drawRect(const Rect.fromLTWH(0, 3, 9, 3), paint);
      canvas.drawRect(const Rect.fromLTWH(12, 8, 2, 6), paint);
      canvas.drawRect(const Rect.fromLTWH(10, 10, 6, 2), paint);
    } else {
      canvas.drawRect(const Rect.fromLTWH(2, 6, 2, 6), paint);
      canvas.drawRect(const Rect.fromLTWH(4, 2, 2, 5), paint);
      canvas.drawRect(const Rect.fromLTWH(9, 9, 4, 2), paint);
      canvas.drawRect(const Rect.fromLTWH(12, 6, 4, 2), paint);
    }
  }

  @override
  bool shouldRepaint(_ThemeAccentParticlePainter oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}

class _PixelBackdrop extends CustomPainter {
  const _PixelBackdrop(this.background, {this.theme});
  final AppPetBackground background;
  final XunaColorThemeData? theme;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 80, size.height / 60);
    final paint = Paint()..isAntiAlias = false;
    void block(double x, double y, double w, double h, Color color) {
      paint.color = color;
      canvas.drawRect(Rect.fromLTWH(x, y, w, h), paint);
    }

    const ink = Color(0xff40364e);
    const wall = Color(0xffb8a5c8);
    const floor = Color(0xff8e799e);
    final olive = theme?.body ?? const Color(0xff8f9d64);
    final light = theme?.highlight ?? const Color(0xfff5d6a0);
    block(0, 0, 80, 60, wall);
    block(0, 40, 80, 20, floor);
    block(0, 39, 80, 1, ink);
    switch (background) {
      case AppPetBackground.room:
        block(6, 8, 20, 23, ink);
        block(8, 10, 16, 19, light);
        block(15, 10, 2, 19, ink);
        block(8, 19, 16, 2, ink);
        block(65, 31, 9, 11, ink);
        block(66, 32, 7, 8, light);
        block(68, 22, 3, 10, olive);
        block(63, 25, 6, 4, olive);
        block(71, 20, 5, 5, olive);
        break;
      case AppPetBackground.reading:
        block(5, 13, 21, 23, ink);
        block(7, 15, 17, 8, floor);
        block(7, 25, 17, 9, floor);
        block(9, 16, 3, 7, light);
        block(14, 18, 4, 5, olive);
        block(19, 16, 3, 7, wall);
        block(9, 29, 12, 3, light);
        block(64, 35, 11, 3, ink);
        block(66, 38, 2, 5, ink);
        block(71, 38, 2, 5, ink);
        block(68, 25, 2, 10, ink);
        block(64, 21, 10, 5, light);
        break;
      case AppPetBackground.garden:
        block(0, 34, 80, 26, olive);
        block(0, 43, 80, 17, light);
        block(0, 42, 80, 1, ink);
        for (final x in [5.0, 17.0, 29.0, 41.0, 53.0, 65.0]) {
          block(x, 29, 2, 13, floor);
        }
        block(0, 33, 80, 2, floor);
        block(8, 9, 12, 3, light);
        block(11, 7, 6, 2, light);
        block(59, 14, 14, 3, light);
        block(62, 12, 7, 2, light);
        block(6, 40, 2, 6, ink);
        block(4, 38, 6, 3, wall);
        block(70, 39, 2, 7, ink);
        block(68, 37, 6, 3, wall);
        break;
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PixelBackdrop oldDelegate) =>
      background != oldDelegate.background ||
      theme?.id != oldDelegate.theme?.id;
}

/// Framed Pixel Art XUNA avatar badge for headers and cards.
class AppPetAvatarBadge extends StatelessWidget {
  const AppPetAvatarBadge({
    super.key,
    this.expression = AppPetExpression.idle,
    this.themeId,
    this.size = 44,
    this.backgroundColor = AppColors.xunaLilacSoft,
  });

  final AppPetExpression expression;
  final String? themeId;
  final double size;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final activeTheme =
        themeId != null ? XunaColorThemes.byId(themeId) : null;
    final borderColor = activeTheme?.outline ?? AppColors.xunaInk;
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppDimens.radius10),
        border: Border.all(
          color: borderColor,
          width: AppDimens.stroke2,
        ),
        boxShadow: [
          BoxShadow(
            color: borderColor,
            offset: const Offset(AppDimens.shadow2, AppDimens.shadow2),
          ),
        ],
      ),
      child: AppXunaPet(
        expression: expression,
        themeId: themeId,
        width: size - 8,
        height: size - 8,
      ),
    );
  }
}

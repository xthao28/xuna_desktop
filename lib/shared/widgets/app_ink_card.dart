import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// XUNA surface: ink outline, rounded corners and a hard offset shadow.
///
/// With [onTap] it behaves as a button that sinks into its shadow while
/// pressed. [enabled] false dims the card and ignores taps.
class AppInkCard extends StatefulWidget {
  const AppInkCard({
    super.key,
    required this.child,
    this.color = AppColors.xunaCard,
    this.radius = AppDimens.radius14,
    this.borderWidth = AppDimens.stroke2,
    this.shadow = AppDimens.shadow4,
    this.padding = EdgeInsets.zero,
    this.onTap,
    this.enabled = true,
    this.semanticLabel,
  });

  final Widget child;
  final Color color;
  final double radius;
  final double borderWidth;

  /// Shadow offset in both axes; 0 draws no shadow.
  final double shadow;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool enabled;
  final String? semanticLabel;

  @override
  State<AppInkCard> createState() => _AppInkCardState();
}

class _AppInkCardState extends State<AppInkCard> {
  static const _pressDuration = Duration(milliseconds: 80);
  static const _disabledOpacity = 0.5;

  bool _pressed = false;

  bool get _interactive => widget.enabled && widget.onTap != null;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final travel = _pressed ? widget.shadow * 0.75 : 0.0;
    final shadow = _pressed ? widget.shadow * 0.25 : widget.shadow;
    final card = AnimatedContainer(
      duration: _pressDuration,
      transform: Matrix4.translationValues(travel, travel, 0),
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.color,
        borderRadius: BorderRadius.circular(widget.radius),
        border: Border.all(color: AppColors.xunaInk, width: widget.borderWidth),
        boxShadow: [
          if (widget.shadow > 0)
            BoxShadow(color: AppColors.xunaInk, offset: Offset(shadow, shadow)),
        ],
      ),
      child: widget.child,
    );
    final content = Opacity(
      opacity: widget.enabled ? 1 : _disabledOpacity,
      child: card,
    );
    if (widget.onTap == null) return content;
    return Semantics(
      button: true,
      enabled: widget.enabled,
      label: widget.semanticLabel,
      child: MouseRegion(
        cursor: _interactive
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _interactive ? widget.onTap : null,
          onTapDown: _interactive ? (_) => _setPressed(true) : null,
          onTapUp: _interactive ? (_) => _setPressed(false) : null,
          onTapCancel: _interactive ? () => _setPressed(false) : null,
          child: content,
        ),
      ),
    );
  }
}

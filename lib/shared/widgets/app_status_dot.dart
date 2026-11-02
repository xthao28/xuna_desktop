import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// Outlined status light; [blinking] pulses it (e.g. while connecting).
class AppStatusDot extends StatefulWidget {
  const AppStatusDot({
    super.key,
    required this.color,
    this.blinking = false,
    this.size = AppDimens.padding10,
    this.borderWidth = AppDimens.strokeThin,
  });

  final Color color;
  final bool blinking;
  final double size;
  final double borderWidth;

  @override
  State<AppStatusDot> createState() => _AppStatusDotState();
}

class _AppStatusDotState extends State<AppStatusDot>
    with SingleTickerProviderStateMixin {
  static const _period = Duration(milliseconds: 800);

  late final AnimationController _blink =
      AnimationController(vsync: this, duration: _period);

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(AppStatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.blinking != widget.blinking) _sync();
  }

  void _sync() {
    if (widget.blinking) {
      _blink.repeat(reverse: true);
    } else {
      _blink
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _blink.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 1, end: 0.25).animate(_blink),
      child: Container(
        width: widget.size,
        height: widget.size,
        decoration: BoxDecoration(
          color: widget.color,
          shape: BoxShape.circle,
          border: Border.all(
            color: AppColors.xunaInk,
            width: widget.borderWidth,
          ),
        ),
      ),
    );
  }
}


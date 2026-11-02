import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// Pill switch with an ink knob. [onChanged] null shows it disabled.
class AppToggle extends StatelessWidget {
  const AppToggle({
    super.key,
    required this.value,
    required this.onChanged,
  });

  static const _width = 50.0;
  static const _height = 28.0;
  static const _knob = 19.0;
  static const _inset = 2.0;
  static const _duration = Duration(milliseconds: 150);

  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final changed = onChanged;
    return Semantics(
      toggled: value,
      enabled: changed != null,
      child: MouseRegion(
        cursor: changed != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: changed == null ? null : () => changed(!value),
          child: Opacity(
            opacity: changed == null ? 0.5 : 1,
            child: AnimatedContainer(
              duration: _duration,
              width: _width,
              height: _height,
              decoration: BoxDecoration(
                color: value ? AppColors.xunaLime : AppColors.xunaCard,
                borderRadius: BorderRadius.circular(AppDimens.radiusPill),
                border: Border.all(
                  color: AppColors.xunaInk,
                  width: AppDimens.stroke2,
                ),
              ),
              child: AnimatedAlign(
                duration: _duration,
                alignment:
                    value ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.all(_inset),
                  width: _knob,
                  height: _knob,
                  decoration: const BoxDecoration(
                    color: AppColors.xunaInk,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


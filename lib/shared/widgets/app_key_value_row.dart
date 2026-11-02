import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import '../themes/app_colors.dart';

/// Muted label on the left, bold value on the right.
class AppKeyValueRow extends StatelessWidget {
  const AppKeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.valueKey,
  });

  final String label;
  final String value;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final longLabel = label.length > value.length;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppDimens.padding3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: longLabel ? 3 : 2,
            child: Text(
              label,
              style: AppTextStyle.font14Re.copyWith(
                color: AppColors.xunaInkMuted,
              ),
            ),
          ),
          const SizedBox(width: AppDimens.padding14),
          Expanded(
            flex: longLabel ? 2 : 3,
            child: Text(
              value,
              key: valueKey,
              style: AppTextStyle.font14Bo,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }
}


import 'package:flutter/material.dart';
import '../constants/const_src.dart';
import 'app_pill_button.dart';

/// Horizontally scrollable or wrapped row of [AppPillButton] filter choices.
class AppFilterPillBar<T> extends StatelessWidget {
  const AppFilterPillBar({
    super.key,
    required this.items,
    required this.selectedItem,
    required this.labelBuilder,
    required this.onSelected,
    this.pill = true,
  });

  final List<T> items;
  final T selectedItem;
  final String Function(T item) labelBuilder;
  final ValueChanged<T> onSelected;
  final bool pill;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: AppDimens.paddingVerySmall,
      runSpacing: AppDimens.paddingVerySmall,
      children: [
        for (final item in items)
          AppPillButton(
            label: labelBuilder(item),
            selected: item == selectedItem,
            pill: pill,
            onPressed: () => onSelected(item),
          ),
      ],
    );
  }
}


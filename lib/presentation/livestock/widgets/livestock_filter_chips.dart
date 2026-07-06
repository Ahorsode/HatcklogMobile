import 'package:flutter/material.dart';

import '../../../features/livestock/data/livestock_models.dart';

class LivestockFilterChips extends StatelessWidget {
  const LivestockFilterChips({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final LivestockSpeciesFilter selected;
  final ValueChanged<LivestockSpeciesFilter> onSelected;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final filter in LivestockSpeciesFilter.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(filter.label),
                selected: selected == filter,
                onSelected: (_) => onSelected(filter),
                selectedColor: const Color(0xff1f7a4d).withValues(alpha: 0.16),
                checkmarkColor: const Color(0xff1f7a4d),
              ),
            ),
        ],
      ),
    );
  }
}

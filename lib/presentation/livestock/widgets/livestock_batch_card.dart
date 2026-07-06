import 'package:flutter/material.dart';

import '../../../features/livestock/data/livestock_models.dart';
import '../../../utils/livestock_breed_options.dart';

class LivestockBatchCard extends StatelessWidget {
  const LivestockBatchCard({
    super.key,
    required this.batch,
    required this.onTap,
    this.onLongPress,
  });

  final LivestockBatchRecord batch;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: Color(0xffe4e9ed)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        const Color(0xff1f7a4d).withValues(alpha: 0.12),
                    foregroundColor: const Color(0xff1f7a4d),
                    child: const Icon(Icons.groups_3_outlined, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          batch.batchName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${batch.categoryLabel} • ${batch.breedLabel}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xff66736c),
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '${batch.currentCount}',
                        style: const TextStyle(
                          color: Color(0xff1f7a4d),
                          fontWeight: FontWeight.w900,
                          fontSize: 18,
                        ),
                      ),
                      Text(
                        batch.isActive ? 'ACTIVE' : batch.status.toUpperCase(),
                        style: TextStyle(
                          color: batch.isActive
                              ? const Color(0xff1f7a4d)
                              : Colors.grey,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  _Badge(
                    label: '${batch.ageInDays}d old',
                    color: const Color(0xff27364a),
                  ),
                  if (batch.houseName.isNotEmpty)
                    _Badge(label: batch.houseName, color: const Color(0xff2f5f8f)),
                  if (batch.isolationCount > 0)
                    _Badge(
                      label: '${batch.isolationCount} ISO',
                      color: const Color(0xffd99025),
                    ),
                  if (batch.mortalityCount > 0)
                    _Badge(
                      label: '${batch.mortalityCount} lost',
                      color: const Color(0xffc0392b),
                    ),
                  if (batch.hasMissingCost)
                    const _Badge(
                      label: 'Missing cost',
                      color: Color(0xff7a3f2f),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class BreedPicker extends StatelessWidget {
  const BreedPicker({
    super.key,
    required this.category,
    required this.selectedKey,
    required this.onChanged,
  });

  final String category;
  final String selectedKey;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final options = LivestockBreedCatalog.optionsForCategory(category);
    if (options.isEmpty) {
      return const Text(
        'No predefined breeds for this category.',
        style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w600),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in options)
          ChoiceChip(
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BreedSwatch(option: option),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    option.label,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            selected: option.key == selectedKey,
            onSelected: (_) => onChanged(option.key),
            selectedColor: const Color(0xff1f7a4d).withValues(alpha: 0.16),
          ),
      ],
    );
  }
}

class _BreedSwatch extends StatelessWidget {
  const _BreedSwatch({required this.option});

  final LivestockBreedOption option;

  @override
  Widget build(BuildContext context) {
    if (option.splitColor != null) {
      return Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: option.borderColor),
          gradient: LinearGradient(
            colors: [option.color, option.splitColor!],
          ),
        ),
      );
    }
    return Container(
      width: 16,
      height: 16,
      decoration: BoxDecoration(
        color: option.color,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: option.borderColor == Colors.transparent
              ? Colors.black12
              : option.borderColor,
        ),
      ),
    );
  }
}

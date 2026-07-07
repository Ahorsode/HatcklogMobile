/// Egg sale allocation: FIFO vs batch-scoped FIFO, sorted size selection.

enum EggAllocationMode { fifo, batch }

class EggBatchStockOption {
  const EggBatchStockOption({
    required this.batchId,
    required this.batchName,
    required this.eggsRemaining,
  });

  final String batchId;
  final String batchName;
  final int eggsRemaining;
}

/// True when multiple egg SKUs exist (sorted by size/category).
bool requiresEggSizeSelection(List<Map<String, Object?>> eggInventoryRows) {
  if (eggInventoryRows.length <= 1) {
    return false;
  }
  final categories = eggInventoryRows
      .map((row) => row['egg_category_id']?.toString().trim() ?? '')
      .where((id) => id.isNotEmpty)
      .toSet();
  return categories.length > 1 || eggInventoryRows.length > 1;
}

String eggSizeLabelFromRow(Map<String, Object?> row) {
  final name = row['item_name']?.toString() ?? 'Eggs';
  final match = RegExp(r'\(([^)]+)\)').firstMatch(name);
  if (match != null) {
    return match.group(1) ?? name;
  }
  return name;
}

Map<String, Object?>? findEggInventoryBySizeLabel(
  List<Map<String, Object?>> rows,
  String sizeLabel,
) {
  final normalized = sizeLabel.trim().toLowerCase();
  for (final row in rows) {
    final label = eggSizeLabelFromRow(row).toLowerCase();
    if (label == normalized || label.contains(normalized)) {
      return row;
    }
  }
  return rows.isNotEmpty ? rows.first : null;
}

Map<String, Object?>? defaultEggInventoryRow(
  List<Map<String, Object?>> rows,
) {
  if (rows.isEmpty) {
    return null;
  }
  if (rows.length == 1) {
    return rows.first;
  }
  for (final row in rows) {
    final name = row['item_name']?.toString().toLowerCase() ?? '';
    if (name.contains('unsorted') || name == 'eggs') {
      return row;
    }
  }
  return rows.first;
}

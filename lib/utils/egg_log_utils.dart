const int defaultEggsPerCrate = 30;

int calculateEggsCollected({
  required bool useCrates,
  int crates = 0,
  int remainder = 0,
  int individualTotal = 0,
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  if (useCrates) {
    return (crates * eggsPerCrate) + remainder.clamp(0, eggsPerCrate - 1);
  }
  return individualTotal;
}

String? validateEggLog({
  required int eggsCollected,
  required int unusableCount,
  required bool isSorted,
  required int smallCount,
  required int mediumCount,
  required int largeCount,
}) {
  if (eggsCollected <= 0) {
    return 'Eggs collected is required.';
  }
  if (isSorted && (smallCount + mediumCount + largeCount) > eggsCollected) {
    return 'Sum of sizes exceeds total eggs collected';
  }
  if (unusableCount > eggsCollected) {
    return 'Unusable eggs cannot exceed total eggs collected.';
  }
  return null;
}

Map<String, dynamic> buildEggLogPayload({
  required String batchId,
  required int eggsCollected,
  required int unusableCount,
  required bool isSorted,
  String? qualityGrade,
  int smallCount = 0,
  int mediumCount = 0,
  int largeCount = 0,
  required DateTime logDate,
  bool useCrates = false,
  int crates = 0,
  int remainder = 0,
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  return {
    'batch_id': batchId,
    'eggs_collected': eggsCollected,
    'unusable_count': unusableCount,
    'quality_grade': isSorted ? null : qualityGrade,
    'is_sorted': isSorted,
    'small_count': isSorted ? smallCount : 0,
    'medium_count': isSorted ? mediumCount : 0,
    'large_count': isSorted ? largeCount : 0,
    'log_date': logDate.toIso8601String(),
    if (useCrates) 'crates': crates,
    if (useCrates)
      'single_eggs': remainder.clamp(0, eggsPerCrate - 1),
    'eggs_per_crate': eggsPerCrate,
  };
}

String normalizeQualityGrade(String? label) {
  switch (label?.trim().toUpperCase()) {
    case 'SMALL':
      return 'SMALL';
    case 'LARGE':
      return 'LARGE';
    default:
      return 'MEDIUM';
  }
}

String formatCrateDisplay(int eggsCollected, {int eggsPerCrate = defaultEggsPerCrate}) {
  final crates = eggsCollected ~/ eggsPerCrate;
  final remainder = eggsCollected % eggsPerCrate;
  final crateLabel = crates == 1 ? 'crate' : 'crates';
  return '$crates $crateLabel / $remainder';
}

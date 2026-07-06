String formatDashboardMoney(double value, {String currency = 'GHS'}) {
  return '$currency ${value.toStringAsFixed(2)}';
}

String normalizeBreedKey(String breed) {
  return breed.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
}

int growthTargetDaysForBreed(String breed) {
  return normalizeBreedKey(breed) == 'ross308' ? 42 : 700;
}

double growthProgressPercent(DateTime hatchDate, String breed) {
  final days = DateTime.now().difference(hatchDate).inDays;
  final target = growthTargetDaysForBreed(breed);
  if (target <= 0) {
    return 0;
  }
  return (days / target * 100).clamp(0, 100);
}

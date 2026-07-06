/// Whether a batch type supports egg collection (layers only).
bool isLayerBatchType(String? type) {
  final normalized = type?.trim().toUpperCase() ?? '';
  if (normalized.isEmpty) {
    return false;
  }
  return normalized == 'POULTRY_LAYER' || normalized.contains('LAYER');
}

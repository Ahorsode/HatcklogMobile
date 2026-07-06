const vaccineInventoryCategories = [
  'VACCINE',
  'VACCINATION',
  'VACCINES',
];

const medicineInventoryCategories = [
  'MEDICINE',
  'MEDICATION',
  'MEDICATIONS',
  'VETERINARY',
  'HEALTH',
];

const allHealthInventoryCategories = [
  ...vaccineInventoryCategories,
  ...medicineInventoryCategories,
];

const healthScheduleStatuses = ['PENDING', 'COMPLETED', 'CANCELLED'];

const healthUnitOptions = [
  'dose',
  'doses',
  'ml',
  'L',
  'bottle',
  'vial',
  'sachet',
  'tablet',
  'capsule',
  'g',
  'kg',
  'bag',
  'unit',
];

enum HealthScheduleKind { vaccination, medication }

enum HealthUsageType { oneTime, quantity }

HealthUsageType normalizeHealthUsageType(String? value) {
  return value?.toUpperCase() == 'QUANTITY'
      ? HealthUsageType.quantity
      : HealthUsageType.oneTime;
}

String healthUsageTypeDbValue(HealthUsageType type) {
  return type == HealthUsageType.quantity ? 'QUANTITY' : 'ONE_TIME';
}

bool isHealthScheduleCompleted(String? status) {
  final normalized = status?.toUpperCase() ?? '';
  return normalized == 'COMPLETED' || normalized == 'DONE';
}

bool isVaccineCategory(String? category) {
  return vaccineInventoryCategories.contains(
    category?.toUpperCase() ?? '',
  );
}

bool isMedicineCategory(String? category) {
  return medicineInventoryCategories.contains(
    category?.toUpperCase() ?? '',
  );
}

bool isHealthInventoryCategory(String? category) {
  return allHealthInventoryCategories.contains(
    category?.toUpperCase() ?? '',
  );
}

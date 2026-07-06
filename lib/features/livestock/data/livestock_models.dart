import '../../../utils/livestock_breed_options.dart';

enum LivestockSpeciesFilter {
  all('ALL', 'All'),
  poultry('POULTRY', 'Poultry'),
  cattle('CATTLE', 'Cattle'),
  pig('PIG', 'Pigs'),
  sheep('SHEEP_GOAT', 'Sheep'),
  other('OTHER', 'Other');

  const LivestockSpeciesFilter(this.storageKey, this.label);

  final String storageKey;
  final String label;

  bool matchesBatchType(String? type) {
    final normalized = (type ?? '').trim().toUpperCase();
    if (normalized.isEmpty) {
      return this == LivestockSpeciesFilter.other;
    }
    return switch (this) {
      LivestockSpeciesFilter.all => true,
      LivestockSpeciesFilter.poultry => normalized.startsWith('POULTRY'),
      LivestockSpeciesFilter.cattle => normalized == 'CATTLE',
      LivestockSpeciesFilter.pig => normalized == 'PIG',
      LivestockSpeciesFilter.sheep => normalized == 'SHEEP_GOAT',
      LivestockSpeciesFilter.other => normalized == 'OTHER',
    };
  }
}

class HouseOption {
  const HouseOption({required this.id, required this.name, this.capacity = 0});

  final String id;
  final String name;
  final int capacity;
}

class LivestockBatchRecord {
  const LivestockBatchRecord({
    required this.id,
    required this.farmId,
    required this.houseId,
    required this.batchName,
    required this.breedType,
    required this.type,
    required this.status,
    required this.initialCount,
    required this.currentCount,
    required this.isolationCount,
    required this.arrivalDate,
    this.houseName = '',
    this.growthTargetOverride = '',
    this.initialCostActual = 0,
    this.initialCostCarriage = 0,
    this.userId = '',
  });

  final String id;
  final String farmId;
  final String houseId;
  final String batchName;
  final String breedType;
  final String type;
  final String status;
  final int initialCount;
  final int currentCount;
  final int isolationCount;
  final DateTime arrivalDate;
  final String houseName;
  final String growthTargetOverride;
  final double initialCostActual;
  final double initialCostCarriage;
  final String userId;

  int get mortalityCount {
    final lost = initialCount - currentCount - isolationCount;
    return lost < 0 ? 0 : lost;
  }

  double get mortalityRate {
    if (initialCount <= 0) {
      return 0;
    }
    return (mortalityCount / initialCount) * 100;
  }

  int get ageInDays => DateTime.now().difference(arrivalDate).inDays;

  String get breedLabel => LivestockBreedCatalog.labelForKey(breedType);

  String get categoryLabel =>
      LivestockBreedCatalog.typeToCategory(type);

  bool get isActive => status.trim().toLowerCase() == 'active';

  bool get hasMissingCost => initialCostActual <= 0;

  LivestockBatchRecord copyWith({
    String? batchName,
    String? breedType,
    String? type,
    String? status,
    int? initialCount,
    int? currentCount,
    int? isolationCount,
    DateTime? arrivalDate,
    String? houseId,
    String? houseName,
    String? growthTargetOverride,
    double? initialCostActual,
    double? initialCostCarriage,
  }) {
    return LivestockBatchRecord(
      id: id,
      farmId: farmId,
      houseId: houseId ?? this.houseId,
      batchName: batchName ?? this.batchName,
      breedType: breedType ?? this.breedType,
      type: type ?? this.type,
      status: status ?? this.status,
      initialCount: initialCount ?? this.initialCount,
      currentCount: currentCount ?? this.currentCount,
      isolationCount: isolationCount ?? this.isolationCount,
      arrivalDate: arrivalDate ?? this.arrivalDate,
      houseName: houseName ?? this.houseName,
      growthTargetOverride: growthTargetOverride ?? this.growthTargetOverride,
      initialCostActual: initialCostActual ?? this.initialCostActual,
      initialCostCarriage: initialCostCarriage ?? this.initialCostCarriage,
      userId: userId,
    );
  }

  static LivestockBatchRecord fromMap(
    Map<String, Object?> row, {
    String houseName = '',
  }) {
    return LivestockBatchRecord(
      id: row['id']?.toString() ?? '',
      farmId: row['farm_id']?.toString() ?? '',
      houseId: row['house_id']?.toString() ?? '',
      batchName: row['batch_name']?.toString() ?? 'Unnamed batch',
      breedType: row['breed_type']?.toString() ??
          row['bird_strain']?.toString() ??
          '',
      type: row['type']?.toString() ?? 'POULTRY_BROILER',
      status: row['status']?.toString() ?? 'active',
      initialCount: _int(row['initial_count']),
      currentCount: _int(row['current_count']),
      isolationCount: _int(row['isolation_count']),
      arrivalDate: DateTime.tryParse(row['arrival_date']?.toString() ?? '') ??
          DateTime.now(),
      houseName: houseName,
      growthTargetOverride: row['growth_target_override']?.toString() ?? '',
      initialCostActual: _double(row['initial_cost_actual']),
      initialCostCarriage: _double(row['initial_cost_carriage']),
      userId: row['user_id']?.toString() ?? '',
    );
  }
}

class CreateLivestockDraft {
  const CreateLivestockDraft({
    required this.batchName,
    required this.category,
    required this.breedKey,
    required this.houseId,
    required this.initialCount,
    required this.arrivalDate,
    this.vaccinationDate,
    this.vaccineName,
  });

  final String batchName;
  final String category;
  final String breedKey;
  final String houseId;
  final int initialCount;
  final DateTime arrivalDate;
  final DateTime? vaccinationDate;
  final String? vaccineName;

  String get type => LivestockBreedCatalog.categoryToType(category);
}

class UpdateLivestockDraft {
  const UpdateLivestockDraft({
    required this.batchName,
    required this.category,
    required this.breedKey,
    required this.houseId,
    required this.initialCount,
    required this.arrivalDate,
    required this.status,
    this.growthTargetOverride = '',
  });

  final String batchName;
  final String category;
  final String breedKey;
  final String houseId;
  final int initialCount;
  final DateTime arrivalDate;
  final String status;
  final String growthTargetOverride;

  String get type => LivestockBreedCatalog.categoryToType(category);
}

class BatchFinancialDraft {
  const BatchFinancialDraft({
    required this.costPerUnit,
    required this.carriageCost,
    required this.otherExpenses,
  });

  final double costPerUnit;
  final double carriageCost;
  final List<({String label, double amount})> otherExpenses;

  double totalActualCost(int quantity) => costPerUnit * quantity;

  double get otherTotal =>
      otherExpenses.fold<double>(0, (sum, item) => sum + item.amount);
}

class BatchActivityEntry {
  const BatchActivityEntry({
    required this.kind,
    required this.summary,
    required this.logDate,
  });

  final String kind;
  final String summary;
  final DateTime logDate;
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

enum LivestockType {
  poultryBroiler('POULTRY_BROILER'),
  poultryLayer('POULTRY_LAYER'),
  cattle('CATTLE'),
  sheepGoat('SHEEP_GOAT'),
  pig('PIG'),
  other('OTHER');

  const LivestockType(this.dbValue);

  final String dbValue;
}

enum HealthEventType {
  sick('SICK'),
  dead('DEAD');

  const HealthEventType(this.dbValue);

  final String dbValue;
}

enum ExpenseCategory {
  feed('FEED'),
  medication('MEDICATION'),
  equipment('EQUIPMENT'),
  utilities('UTILITIES'),
  salary('SALARY'),
  maintenance('MAINTENANCE'),
  livestockPurchase('LIVESTOCK_PURCHASE'),
  transport('TRANSPORT'),
  other('OTHER');

  const ExpenseCategory(this.dbValue);

  final String dbValue;
}

class FarmCacheRecord {
  const FarmCacheRecord({
    required this.id,
    required this.name,
    required this.capacity,
    this.location,
    this.subscriptionTier,
    this.masterLicenseStatus,
  });

  final String id;
  final String name;
  final int capacity;
  final String? location;
  final String? subscriptionTier;
  final String? masterLicenseStatus;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'name': name,
      'capacity': capacity,
      'location': location,
      'subscription_tier': subscriptionTier,
      'master_license_status': masterLicenseStatus,
    };
  }
}

class BatchCacheRecord {
  const BatchCacheRecord({
    required this.id,
    required this.farmId,
    required this.houseId,
    required this.batchName,
    required this.currentCount,
    required this.initialCount,
    required this.arrivalDate,
    required this.status,
    required this.type,
    this.localBatchId,
  });

  final String id;
  final String farmId;
  final String houseId;
  final String batchName;
  final int currentCount;
  final int initialCount;
  final DateTime arrivalDate;
  final String status;
  final String type;
  final int? localBatchId;

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'farm_id': farmId,
      'house_id': houseId,
      'batch_name': batchName,
      'current_count': currentCount,
      'initial_count': initialCount,
      'arrival_date': arrivalDate.toIso8601String(),
      'status': status,
      'type': type,
      'local_batch_id': localBatchId,
    };
  }
}

class FarmSettingsCacheRecord {
  const FarmSettingsCacheRecord({
    required this.farmId,
    required this.eggsPerCrate,
    required this.currency,
  });

  final String farmId;
  final int eggsPerCrate;
  final String currency;

  Map<String, Object?> toMap() {
    return {
      'farm_id': farmId,
      'eggs_per_crate': eggsPerCrate,
      'currency': currency,
    };
  }
}

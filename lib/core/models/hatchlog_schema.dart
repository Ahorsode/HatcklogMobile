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
    this.eggRecordReminderTime,
    this.feedRecordReminderTime,
    this.growthTargetStandard,
    this.defaultEggUnit = 'crate',
    this.allowEggUnitChange = false,
    this.defaultEggSortMode = 'unsorted',
    this.allowEggSortModeChange = false,
  });

  final String farmId;
  final int eggsPerCrate;
  final String currency;
  final String? eggRecordReminderTime;
  final String? feedRecordReminderTime;
  final int? growthTargetStandard;
  final String defaultEggUnit;
  final bool allowEggUnitChange;
  final String defaultEggSortMode;
  final bool allowEggSortModeChange;

  Map<String, Object?> toMap() {
    return {
      'farm_id': farmId,
      'eggs_per_crate': eggsPerCrate,
      'currency': currency,
      'egg_record_reminder_time': eggRecordReminderTime,
      'feed_record_reminder_time': feedRecordReminderTime,
      'growth_target_standard': growthTargetStandard,
      'default_egg_unit': defaultEggUnit,
      'allow_egg_unit_change': allowEggUnitChange ? 1 : 0,
      'default_egg_sort_mode': defaultEggSortMode,
      'allow_egg_sort_mode_change': allowEggSortModeChange ? 1 : 0,
    };
  }
}

class SalesSettingsCacheRecord {
  const SalesSettingsCacheRecord({
    required this.farmId,
    this.allowBatchOverride = false,
    this.allowWorkerDiscounts = false,
    this.defaultDiscountType = 'item',
  });

  final String farmId;
  final bool allowBatchOverride;
  final bool allowWorkerDiscounts;
  final String defaultDiscountType;

  Map<String, Object?> toMap() {
    return {
      'farm_id': farmId,
      'allow_batch_override': allowBatchOverride ? 1 : 0,
      'allow_worker_discounts': allowWorkerDiscounts ? 1 : 0,
      'default_discount_type': defaultDiscountType,
    };
  }
}

import '../core/models/app_user.dart';
import '../core/models/hatchlog_schema.dart';
import '../core/settings/settings_profile_contract.dart';
import '../core/storage/local_database.dart';

class FeedReorderItem {
  const FeedReorderItem({
    required this.id,
    required this.itemName,
    required this.stockLevel,
    required this.unit,
    required this.reorderLevel,
  });

  final String id;
  final String itemName;
  final double stockLevel;
  final String unit;
  final double reorderLevel;
}

class FarmSettingsService {
  FarmSettingsService(this._database);

  final LocalDatabase _database;

  bool _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1';
  }

  Future<FarmSettingsData> load(String farmId) async {
    if (farmId.isEmpty) {
      return FarmSettingsData.defaults(farmId: farmId);
    }

    final farmRows = await _database.queryLocalRecords(
      'farms',
      where: 'id = ?',
      whereArgs: [farmId],
      limit: 1,
    );
    final settingsRows = await _database.queryLocalRecords(
      'farm_settings',
      where: 'farm_id = ?',
      whereArgs: [farmId],
      limit: 1,
    );

    final farm = farmRows.isEmpty ? null : farmRows.first;
    final settings = settingsRows.isEmpty ? null : settingsRows.first;

    return FarmSettingsData(
      farmId: farmId,
      farmName: farm?['name']?.toString() ?? '',
      farmLocation: farm?['location']?.toString() ?? '',
      farmCapacity: (farm?['capacity'] as int?) ??
          int.tryParse(farm?['capacity']?.toString() ?? '') ??
          0,
      currency: SettingsProfileContract.normalizeCurrency(
        settings?['currency']?.toString(),
      ),
      eggsPerCrate: (settings?['eggs_per_crate'] as int?) ??
          int.tryParse(settings?['eggs_per_crate']?.toString() ?? '') ??
          SettingsProfileContract.defaultEggsPerCrate,
      eggRecordReminderTime: settings?['egg_record_reminder_time']?.toString() ??
          SettingsProfileContract.defaultEggReminder,
      feedRecordReminderTime:
          settings?['feed_record_reminder_time']?.toString() ??
              SettingsProfileContract.defaultFeedReminder,
      growthTargetStandard: settings?['growth_target_standard'] == null
          ? null
          : int.tryParse(settings!['growth_target_standard'].toString()),
      defaultEggUnit: settings?['default_egg_unit']?.toString() == 'individual'
          ? 'individual'
          : SettingsProfileContract.defaultEggUnit,
      allowEggUnitChange: _asBool(settings?['allow_egg_unit_change']),
      defaultEggSortMode: settings?['default_egg_sort_mode']?.toString() == 'sorted'
          ? 'sorted'
          : SettingsProfileContract.defaultEggSortMode,
      allowEggSortModeChange: _asBool(settings?['allow_egg_sort_mode_change']),
    );
  }

  Future<SalesSettingsData> loadSalesSettings(String farmId) async {
    if (farmId.isEmpty) {
      return SalesSettingsData.defaults(farmId: farmId);
    }
    final rows = await _database.queryLocalRecords(
      'sales_settings',
      where: 'farm_id = ?',
      whereArgs: [farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return SalesSettingsData.defaults(farmId: farmId);
    }
    final row = rows.first;
    final discountType = row['default_discount_type']?.toString();
    return SalesSettingsData(
      farmId: farmId,
      allowBatchOverride: _asBool(row['allow_batch_override']),
      allowWorkerDiscounts: _asBool(row['allow_worker_discounts']),
      defaultDiscountType: discountType == 'flat' || discountType == 'percent'
          ? discountType!
          : SettingsProfileContract.defaultDiscountType,
    );
  }

  Future<List<FeedReorderItem>> loadFeedReorderItems(String farmId) async {
    if (farmId.isEmpty) {
      return const [];
    }
    final rows = await _database.queryLocalRecords(
      'inventory',
      where: "farm_id = ? and lower(category) = 'feed' and is_deleted = 0",
      whereArgs: [farmId],
      orderBy: 'item_name asc',
    );
    return rows
        .map(
          (row) => FeedReorderItem(
            id: row['id']?.toString() ?? '',
            itemName: row['item_name']?.toString() ?? 'Feed item',
            stockLevel: double.tryParse(row['stock_level']?.toString() ?? '') ??
                0,
            unit: row['unit']?.toString() ?? 'kg',
            reorderLevel:
                double.tryParse(row['reorder_level']?.toString() ?? '') ??
                    SettingsProfileContract.defaultReorderLevelKg,
          ),
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  Future<void> saveFarmSettings({
    required AppUser user,
    required FarmSettingsData data,
  }) async {
    if (data.farmId.isEmpty) {
      return;
    }

    await _database.updateLocalRecord(
      'farms',
      {
        'name': data.farmName.trim(),
        'location': data.farmLocation.trim(),
        'capacity': data.farmCapacity,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [data.farmId],
    );

    await _database.upsertFarmSettings(
      FarmSettingsCacheRecord(
        farmId: data.farmId,
        eggsPerCrate: data.eggsPerCrate,
        currency: data.currency,
        eggRecordReminderTime: data.eggRecordReminderTime,
        feedRecordReminderTime: data.feedRecordReminderTime,
        growthTargetStandard: data.growthTargetStandard,
        defaultEggUnit: data.defaultEggUnit,
        allowEggUnitChange: data.allowEggUnitChange,
        defaultEggSortMode: data.defaultEggSortMode,
        allowEggSortModeChange: data.allowEggSortModeChange,
      ),
    );

    await _database.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'farm_settings_update',
        payload: {
          'farm_id': data.farmId,
          'name': data.farmName.trim(),
          'location': data.farmLocation.trim(),
          'capacity': data.farmCapacity,
          'currency': data.currency,
          'eggs_per_crate': data.eggsPerCrate,
          'egg_record_reminder_time': data.eggRecordReminderTime,
          'feed_record_reminder_time': data.feedRecordReminderTime,
          'default_egg_unit': data.defaultEggUnit,
          'allow_egg_unit_change': data.allowEggUnitChange,
          'default_egg_sort_mode': data.defaultEggSortMode,
          'allow_egg_sort_mode_change': data.allowEggSortModeChange,
          if (data.growthTargetStandard != null)
            'growth_target_standard': data.growthTargetStandard,
        },
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> saveSalesSettings({
    required AppUser user,
    required SalesSettingsData data,
  }) async {
    if (data.farmId.isEmpty) {
      return;
    }
    await _database.upsertSalesSettings(
      SalesSettingsCacheRecord(
        farmId: data.farmId,
        allowBatchOverride: data.allowBatchOverride,
        allowWorkerDiscounts: data.allowWorkerDiscounts,
        defaultDiscountType: data.defaultDiscountType,
      ),
    );
    await _database.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'sales_settings_update',
        payload: {
          'farm_id': data.farmId,
          'allow_batch_override': data.allowBatchOverride,
          'allow_worker_discounts': data.allowWorkerDiscounts,
          'default_discount_type': data.defaultDiscountType,
        },
        createdAt: DateTime.now(),
      ),
    );
  }

  Future<void> saveReorderLevel({
    required AppUser user,
    required String farmId,
    required String inventoryId,
    required double reorderLevel,
  }) async {
    await _database.updateLocalRecord(
      'inventory',
      {'reorder_level': reorderLevel},
      where: 'id = ?',
      whereArgs: [inventoryId],
    );
    await _database.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'inventory_reorder_update',
        payload: {
          'farm_id': farmId,
          'inventory_id': inventoryId,
          'reorder_level': reorderLevel,
        },
        createdAt: DateTime.now(),
      ),
    );
  }
}

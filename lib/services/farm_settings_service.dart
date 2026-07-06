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
      farmCapacity: (farm?['capacity'] as int?) ?? int.tryParse(
            farm?['capacity']?.toString() ?? '',
          ) ??
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
            reorderLevel: double.tryParse(row['reorder_level']?.toString() ?? '') ??
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
          if (data.growthTargetStandard != null)
            'growth_target_standard': data.growthTargetStandard,
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

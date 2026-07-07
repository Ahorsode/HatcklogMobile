import '../../../core/storage/local_database.dart';

enum InventoryFilter { active, usedUp }

class InventoryUsageEvent {
  const InventoryUsageEvent({
    required this.date,
    required this.batchName,
    required this.amount,
    required this.source,
  });

  final DateTime date;
  final String batchName;
  final double amount;
  final String source;
}

class InventoryItemDetail {
  const InventoryItemDetail({
    required this.id,
    required this.name,
    required this.stockLevel,
    required this.unit,
    required this.category,
    required this.usageType,
    required this.usageEvents,
  });

  final String id;
  final String name;
  final double stockLevel;
  final String unit;
  final String category;
  final String? usageType;
  final List<InventoryUsageEvent> usageEvents;
}

class ActiveBatchEggRow {
  const ActiveBatchEggRow({
    required this.batchId,
    required this.batchName,
    required this.eggsRemaining,
  });

  final String batchId;
  final String batchName;
  final int eggsRemaining;
}

class ActiveBatchEggStock {
  const ActiveBatchEggStock({
    required this.totalEggs,
    required this.batches,
  });

  final int totalEggs;
  final List<ActiveBatchEggRow> batches;
}

class InventoryRepository {
  InventoryRepository(this._db);

  final LocalDatabase _db;

  Future<List<Map<String, Object?>>> getAllInventory({
    required String farmId,
    InventoryFilter filter = InventoryFilter.active,
  }) async {
    final rows = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'item_name asc',
    );

    final filtered = <Map<String, Object?>>[];
    for (final row in rows) {
      final isUsedUp = await _isUsedUp(row, farmId);
      if (filter == InventoryFilter.active && !isUsedUp) {
        filtered.add(row);
      } else if (filter == InventoryFilter.usedUp && isUsedUp) {
        filtered.add(row);
      }
    }
    return filtered;
  }

  Future<int> getUsedUpInventoryCount(String farmId) async {
    final rows = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    var count = 0;
    for (final row in rows) {
      if (await _isUsedUp(row, farmId)) {
        count++;
      }
    }
    return count;
  }

  Future<ActiveBatchEggStock> getActiveBatchEggStock(String farmId) async {
    final rows = await _db.rawLocalQuery(
      '''
      SELECT b.id AS batch_id, b.batch_name, SUM(ep.eggs_remaining) AS eggs_remaining
      FROM egg_production ep
      INNER JOIN batches b ON b.id = ep.batch_id
      WHERE ep.farm_id = ?
        AND coalesce(ep.is_deleted, 0) = 0
        AND coalesce(b.is_deleted, 0) = 0
        AND lower(b.status) = 'active'
        AND b.type = 'POULTRY_LAYER'
        AND ep.eggs_remaining > 0
      GROUP BY b.id, b.batch_name
      ORDER BY b.batch_name ASC
      ''',
      [farmId],
    );

    final batches = rows
        .map(
          (row) => ActiveBatchEggRow(
            batchId: row['batch_id']?.toString() ?? '',
            batchName: row['batch_name']?.toString() ?? 'Batch',
            eggsRemaining: _int(row['eggs_remaining']),
          ),
        )
        .where((row) => row.batchId.isNotEmpty)
        .toList(growable: false);
    final totalEggs = batches.fold<int>(
      0,
      (sum, row) => sum + row.eggsRemaining,
    );
    return ActiveBatchEggStock(totalEggs: totalEggs, batches: batches);
  }

  Future<({int totalEggs, Map<String, int> byCategoryId})> getEggFifoAvailabilityMap(
    String farmId,
  ) async {
    final rows = await _db.rawLocalQuery(
      '''
      SELECT ep.eggs_remaining, ep.category_id
      FROM egg_production ep
      INNER JOIN batches b ON b.id = ep.batch_id
      WHERE ep.farm_id = ?
        AND coalesce(ep.is_deleted, 0) = 0
        AND coalesce(b.is_deleted, 0) = 0
        AND lower(b.status) = 'active'
        AND b.type = 'POULTRY_LAYER'
        AND ep.eggs_remaining > 0
      ''',
      [farmId],
    );

    final byCategoryId = <String, int>{};
    var totalEggs = 0;
    for (final row in rows) {
      final remaining = _int(row['eggs_remaining']);
      totalEggs += remaining;
      final categoryId = row['category_id']?.toString().trim() ?? '';
      final key = categoryId.isEmpty ? '__uncategorized__' : categoryId;
      byCategoryId[key] = (byCategoryId[key] ?? 0) + remaining;
    }
    return (totalEggs: totalEggs, byCategoryId: byCategoryId);
  }

  Future<List<Map<String, Object?>>> getHealthInventory(String farmId) async {
    final rows = await getAllInventory(
      farmId: farmId,
      filter: InventoryFilter.active,
    );
    return rows.where((row) {
      final usageType = row['usage_type']?.toString().toUpperCase() ?? '';
      if (usageType == 'ONE_TIME' && _double(row['stock_level']) <= 0) {
        return false;
      }
      return true;
    }).toList();
  }

  Future<InventoryItemDetail?> getInventoryItemWithUsage(
    String farmId,
    String itemId,
  ) async {
    final rows = await _db.queryLocalRecords(
      'inventory',
      where: 'id = ? and farm_id = ?',
      whereArgs: [itemId, farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final item = rows.first;
    final events = await _loadUsageEvents(farmId, item);
    return InventoryItemDetail(
      id: itemId,
      name: item['item_name']?.toString() ?? 'Item',
      stockLevel: _double(item['stock_level']),
      unit: item['unit']?.toString() ?? '',
      category: item['category']?.toString() ?? '',
      usageType: item['usage_type']?.toString(),
      usageEvents: events,
    );
  }

  Future<bool> _isUsedUp(Map<String, Object?> item, String farmId) async {
    final stock = _double(item['stock_level']);
    if (stock <= 0) {
      return true;
    }

    final usageType = item['usage_type']?.toString().toUpperCase() ?? '';
    if (usageType != 'ONE_TIME') {
      return false;
    }

    final itemId = item['id']?.toString() ?? '';
    final itemName = item['item_name']?.toString() ?? '';
    final completed = await _completedScheduleCount(farmId, itemId, itemName);
    return completed > 0;
  }

  Future<int> _completedScheduleCount(
    String farmId,
    String itemId,
    String itemName,
  ) async {
    final vaccinations = await _db.queryLocalRecords(
      'vaccination_schedules',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );
    final medications = await _db.queryLocalRecords(
      'medication_schedules',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );

    var count = 0;
    final allSchedules = <Map<String, Object?>>[
      ...vaccinations,
      ...medications,
    ];
    for (final schedule in allSchedules) {
      if (!_isCompleted(schedule)) {
        continue;
      }
      final matches =
          schedule['inventory_id']?.toString() == itemId ||
          _namesMatch(
            schedule['vaccine_name'] ?? schedule['medication_name'],
            itemName,
          );
      if (matches) {
        count++;
      }
    }
    return count;
  }

  Future<List<InventoryUsageEvent>> _loadUsageEvents(
    String farmId,
    Map<String, Object?> item,
  ) async {
    final itemId = item['id']?.toString() ?? '';
    final itemName = item['item_name']?.toString() ?? '';
    final events = <InventoryUsageEvent>[];

    final feedingLogs = await _db.queryLocalRecords(
      'daily_feeding_logs',
      where: 'farm_id = ? and feed_type_id = ? and is_deleted = 0',
      whereArgs: [farmId, itemId],
      orderBy: 'log_date desc',
    );
    for (final log in feedingLogs) {
      events.add(
        InventoryUsageEvent(
          date: DateTime.tryParse(log['log_date']?.toString() ?? '') ??
              DateTime.now(),
          batchName: await _batchName(log['batch_id']?.toString() ?? ''),
          amount: _double(log['amount_consumed']),
          source: 'feeding_log',
        ),
      );
    }

    for (final table in const ['vaccination_schedules', 'medication_schedules']) {
      final schedules = await _db.queryLocalRecords(
        table,
        where: 'farm_id = ?',
        whereArgs: [farmId],
      );
      for (final schedule in schedules) {
        if (_isCancelled(schedule['status']?.toString() ?? '')) {
          continue;
        }
        final matches =
            schedule['inventory_id']?.toString() == itemId ||
            _namesMatch(
              schedule['vaccine_name'] ?? schedule['medication_name'],
              itemName,
            );
        if (!matches) {
          continue;
        }
        events.add(
          InventoryUsageEvent(
            date: DateTime.tryParse(
                  schedule['scheduled_date']?.toString() ?? '',
                ) ??
                DateTime.now(),
            batchName: await _batchName(schedule['batch_id']?.toString() ?? ''),
            amount: _double(schedule['quantity'], fallback: 1),
            source: table == 'vaccination_schedules'
                ? 'vaccination'
                : 'medication',
          ),
        );
      }
    }

    events.sort((a, b) => b.date.compareTo(a.date));
    return events;
  }

  Future<String> _batchName(String batchId) async {
    if (batchId.isEmpty) {
      return '-';
    }
    final rows = await _db.queryLocalRecords(
      'batches',
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return batchId;
    }
    return rows.first['batch_name']?.toString() ?? batchId;
  }

  bool _isCancelled(String status) {
    return status.toUpperCase() == 'CANCELLED';
  }

  bool _isCompleted(Map<String, Object?> schedule) {
    final status = schedule['status']?.toString().toUpperCase() ?? '';
    return status == 'COMPLETED' || status == 'DONE';
  }

  bool _namesMatch(Object? left, Object? right) {
    return left?.toString().trim().toLowerCase() ==
        right?.toString().trim().toLowerCase();
  }

  double _double(Object? value, {double fallback = 0}) {
    if (value == null) {
      return fallback;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? fallback;
  }

  int _int(Object? value, {int fallback = 0}) {
    if (value == null) {
      return fallback;
    }
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString()) ?? fallback;
  }
}

import 'dart:math';

import '../core/storage/local_database.dart';
import '../utils/inventory_sale_utils.dart';

class EggFifoService {
  EggFifoService(this.localDatabase);

  final LocalDatabase localDatabase;

  Future<void> deductFromProductionLogs({
    required String farmId,
    required int quantity,
  }) async {
    if (quantity <= 0) {
      return;
    }
    var qtyToDeduct = quantity;
    final rows = await localDatabase.rawLocalQuery(
      '''
      select id, eggs_remaining
      from egg_production
      where farm_id = ?
        and coalesce(is_deleted, 0) = 0
        and coalesce(eggs_remaining, 0) > 0
      order by log_date asc
      ''',
      [farmId],
    );
    for (final row in rows) {
      if (qtyToDeduct <= 0) {
        break;
      }
      final remaining = _asInt(row['eggs_remaining']);
      final take = min(remaining, qtyToDeduct);
      await localDatabase.updateLocalRecord(
        'egg_production',
        {
          'eggs_remaining': remaining - take,
          'is_synced': 0,
        },
        where: 'id = ?',
        whereArgs: [row['id']],
      );
      qtyToDeduct -= take;
    }
  }

  Future<void> deductForInventorySale({
    required String farmId,
    required String? inventoryId,
    required int quantity,
  }) async {
    if (inventoryId == null || inventoryId.isEmpty || quantity <= 0) {
      return;
    }
    final rows = await localDatabase.queryLocalRecords(
      'inventory',
      where: 'id = ? and farm_id = ?',
      whereArgs: [inventoryId, farmId],
      limit: 1,
    );
    if (rows.isEmpty || !isEggInventoryRow(rows.first)) {
      return;
    }
    await deductFromProductionLogs(farmId: farmId, quantity: quantity);
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

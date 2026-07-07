import 'dart:math';

import '../core/storage/local_database.dart';
import '../utils/inventory_sale_utils.dart';
import '../utils/egg_sale_allocation_utils.dart';

class BatchEggAllocation {
  const BatchEggAllocation({
    required this.batchId,
    required this.eggsUsed,
  });

  final String batchId;
  final int eggsUsed;
}

class EggFifoService {
  EggFifoService(this.localDatabase);

  final LocalDatabase localDatabase;

  Future<int> getFifoEggAvailability({
    required String farmId,
    String? batchId,
    String? categoryId,
  }) async {
    final args = <Object?>[farmId];
    var batchFilter = '';
    var categoryFilter = '';
    if (batchId != null && batchId.isNotEmpty) {
      batchFilter = ' and ep.batch_id = ?';
      args.add(batchId);
    } else {
      batchFilter = '''
        and exists (
          select 1 from batches b
          where b.id = ep.batch_id
            and coalesce(b.is_deleted, 0) = 0
            and upper(b.status) = 'ACTIVE'
        )
      ''';
    }
    if (categoryId != null && categoryId.isNotEmpty) {
      categoryFilter = ' and ep.category_id = ?';
      args.add(categoryId);
    }
    final rows = await localDatabase.rawLocalQuery(
      '''
      select coalesce(sum(ep.eggs_remaining), 0) as total
      from egg_production ep
      where ep.farm_id = ?
        and coalesce(ep.is_deleted, 0) = 0
        and coalesce(ep.eggs_remaining, 0) > 0
        $batchFilter
        $categoryFilter
      ''',
      args,
    );
    return _asInt(rows.first['total']);
  }

  Future<List<BatchEggAllocation>> deductFromProductionLogs({
    required String farmId,
    required int quantity,
    String? batchId,
    String? categoryId,
  }) async {
    if (quantity <= 0) {
      return const [];
    }
    var qtyToDeduct = quantity;
    final args = <Object?>[farmId];
    var batchFilter = '';
    var categoryFilter = '';
    if (batchId != null && batchId.isNotEmpty) {
      batchFilter = ' and batch_id = ?';
      args.add(batchId);
    }
    if (categoryId != null && categoryId.isNotEmpty) {
      categoryFilter = ' and category_id = ?';
      args.add(categoryId);
    }
    final rows = await localDatabase.rawLocalQuery(
      '''
      select id, batch_id, eggs_remaining
      from egg_production
      where farm_id = ?
        and coalesce(is_deleted, 0) = 0
        and coalesce(eggs_remaining, 0) > 0
        $batchFilter
        $categoryFilter
      order by log_date asc
      ''',
      args,
    );
    final byBatch = <String, int>{};
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
      final resolvedBatchId = row['batch_id']?.toString() ?? '';
      if (resolvedBatchId.isNotEmpty) {
        byBatch[resolvedBatchId] = (byBatch[resolvedBatchId] ?? 0) + take;
      }
      qtyToDeduct -= take;
    }
    if (qtyToDeduct > 0) {
      throw StateError('Insufficient egg stock. Short by $qtyToDeduct egg(s).');
    }
    return byBatch.entries
        .map((entry) => BatchEggAllocation(batchId: entry.key, eggsUsed: entry.value))
        .toList();
  }

  Future<List<BatchEggAllocation>> deductForInventorySale({
    required String farmId,
    required String? inventoryId,
    required int quantity,
    String? batchId,
    String? categoryId,
  }) async {
    if (inventoryId == null || inventoryId.isEmpty || quantity <= 0) {
      return const [];
    }
    final rows = await localDatabase.queryLocalRecords(
      'inventory',
      where: 'id = ? and farm_id = ?',
      whereArgs: [inventoryId, farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const [];
    }
    if (!isEggInventoryRow(rows.first)) {
      final currentStock = _asDouble(rows.first['stock_level']);
      await localDatabase.updateLocalRecord(
        'inventory',
        {
          'stock_level': max(0, currentStock - quantity),
          'is_synced': 0,
        },
        where: 'id = ?',
        whereArgs: [inventoryId],
      );
      return const [];
    }
    final allocations = await deductFromProductionLogs(
      farmId: farmId,
      quantity: quantity,
      batchId: batchId,
      categoryId: isUnsortedEggInventoryRow(rows.first)
          ? null
          : (categoryId ?? rows.first['egg_category_id']?.toString()),
    );
    final currentStock = _asDouble(rows.first['stock_level']);
    await localDatabase.updateLocalRecord(
      'inventory',
      {
        'stock_level': max(0, currentStock - quantity),
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [inventoryId],
    );
    return allocations;
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

  double _asDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }
}

import '../../core/storage/local_database.dart';
import '../features/inventory/data/inventory_repository.dart';

class HealthInventoryService {
  HealthInventoryService(this._db, {InventoryRepository? inventoryRepository})
    : _inventoryRepository =
          inventoryRepository ?? InventoryRepository(_db);

  final LocalDatabase _db;
  final InventoryRepository _inventoryRepository;

  Future<void> reconcileFarmDepletion(String farmId) async {
    for (final table in const ['vaccination_schedules', 'medication_schedules']) {
      final schedules = await _db.queryLocalRecords(
        table,
        where: 'farm_id = ?',
        whereArgs: [farmId],
      );
      for (final schedule in schedules) {
        if (!_isCompleted(schedule['status']?.toString() ?? '')) {
          continue;
        }
        await applyScheduleStatusChange(
          farmId: farmId,
          inventoryId: schedule['inventory_id']?.toString(),
          itemName: schedule['vaccine_name']?.toString() ??
              schedule['medication_name']?.toString() ??
              '',
          previousStatus: 'PENDING',
          newStatus: schedule['status']?.toString() ?? '',
          quantity: _double(schedule['quantity'], fallback: 1),
        );
      }
    }
  }

  Future<String?> validateScheduleItem({
    required String farmId,
    required String? inventoryId,
    required String itemName,
  }) async {
    final item = await _resolveItem(farmId, inventoryId, itemName);
    if (item == null) {
      return null;
    }

    final usageType = item['usage_type']?.toString().toUpperCase() ?? '';
    if (usageType != 'ONE_TIME') {
      return _double(item['stock_level']) <= 0
          ? 'Selected item is out of stock.'
          : null;
    }

    if (_double(item['stock_level']) <= 0) {
      return 'This one-time item is already used up.';
    }

    final completed = await _inventoryRepository.getAllInventory(
      farmId: farmId,
      filter: InventoryFilter.usedUp,
    );
    final itemId = item['id']?.toString() ?? '';
    if (completed.any((row) => row['id']?.toString() == itemId)) {
      return 'This one-time item has already been consumed.';
    }
    return null;
  }

  Future<void> applyScheduleStatusChange({
    required String farmId,
    required String? inventoryId,
    required String itemName,
    required String previousStatus,
    required String newStatus,
    required double quantity,
  }) async {
    final item = await _resolveItem(farmId, inventoryId, itemName);
    if (item == null) {
      return;
    }

    final wasCompleted = _isCompleted(previousStatus);
    final isCompleted = _isCompleted(newStatus);
    if (wasCompleted == isCompleted) {
      return;
    }

    if (isCompleted) {
      await _depleteOnCompletion(item, quantity);
      return;
    }
    await _restoreOnRevert(item, quantity);
  }

  Future<void> normalizeOneTimeStockOnSave(Map<String, Object?> item) async {
    final usageType = item['usage_type']?.toString().toUpperCase() ?? '';
    if (usageType == 'ONE_TIME') {
      item['stock_level'] = 1;
    }
  }

  Future<void> _depleteOnCompletion(
    Map<String, Object?> item,
    double quantity,
  ) async {
    final usageType = item['usage_type']?.toString().toUpperCase() ?? '';
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) {
      return;
    }

    final nextStock = usageType == 'ONE_TIME'
        ? 0.0
        : (_double(item['stock_level']) - quantity)
              .clamp(0.0, double.infinity)
              .toDouble();

    await _db.rawLocalUpdate('inventory', {
      'stock_level': nextStock,
      'updated_at': DateTime.now().toIso8601String(),
    }, 'id = ?', [itemId]);
  }

  Future<void> _restoreOnRevert(
    Map<String, Object?> item,
    double quantity,
  ) async {
    final usageType = item['usage_type']?.toString().toUpperCase() ?? '';
    final itemId = item['id']?.toString() ?? '';
    if (itemId.isEmpty) {
      return;
    }

    final nextStock = usageType == 'ONE_TIME'
        ? 1
        : _double(item['stock_level']) + quantity;

    await _db.rawLocalUpdate('inventory', {
      'stock_level': nextStock,
      'updated_at': DateTime.now().toIso8601String(),
    }, 'id = ?', [itemId]);
  }

  Future<Map<String, Object?>?> _resolveItem(
    String farmId,
    String? inventoryId,
    String itemName,
  ) async {
    if (inventoryId != null && inventoryId.isNotEmpty) {
      final rows = await _db.queryLocalRecords(
        'inventory',
        where: 'id = ? and farm_id = ?',
        whereArgs: [inventoryId, farmId],
        limit: 1,
      );
      if (rows.isNotEmpty) {
        return rows.first;
      }
    }

    final rows = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    for (final row in rows) {
      if (_namesMatch(row['item_name'], itemName)) {
        return row;
      }
    }
    return null;
  }

  bool _isCompleted(String status) {
    final normalized = status.toUpperCase();
    return normalized == 'COMPLETED' || normalized == 'DONE';
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
}

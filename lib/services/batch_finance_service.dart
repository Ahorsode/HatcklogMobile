import 'dart:convert';

import '../core/storage/local_database.dart';

class BatchFinanceBreakdown {
  const BatchFinanceBreakdown({
    required this.batchId,
    required this.batchLabel,
    required this.initial,
    required this.operating,
    required this.consumption,
    required this.general,
    required this.revenue,
  });

  final String batchId;
  final String batchLabel;
  final double initial;
  final double operating;
  final double consumption;
  final double general;
  final double revenue;

  double get totalExpense => initial + operating + consumption + general;
  double get netProfit => revenue - totalExpense;
}

class BatchFinanceService {
  BatchFinanceService(this._db);

  final LocalDatabase _db;

  Future<List<BatchFinanceBreakdown>> computeFarmBreakdown(String farmId) async {
    final batches = await _loadActiveBatches(farmId);
    if (batches.isEmpty) {
      return const [];
    }

    final expenses = await _db.queryLocalRecords(
      'expenses',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    final allocations = await _db.queryLocalRecords(
      'expense_allocations',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );
    final feedingLogs = await _db.queryLocalRecords(
      'daily_feeding_logs',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
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
    final inventory = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    final saleItems = await _db.queryLocalRecords(
      'sale_items',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );
    final orders = await _db.queryLocalRecords(
      'orders',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    final orderIds = orders
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final orderItems = orderIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await _db.rawLocalQuery(
            'select * from order_items where order_id in (${List.filled(orderIds.length, '?').join(',')})',
            orderIds,
          );

    final batchIds = batches.map((b) => b['id'] as String).toSet();
    final totals = {
      for (final id in batchIds)
        id: _BatchAccumulator(
          batchId: id,
          batchLabel: _batchLabel(batches.firstWhere((b) => b['id'] == id)),
          initial: _initialInvestment(
            batches.firstWhere((b) => b['id'] == id),
          ),
        ),
    };

    final allocatedExpenseIds = allocations
        .map((row) => row['expense_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    final cancelledOrderIds = orders
        .where(
          (order) =>
              order['status']?.toString().toUpperCase() == 'CANCELLED',
        )
        .map((order) => order['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

    for (final expense in expenses) {
      final expenseId = expense['id']?.toString() ?? '';
      final amount = _double(expense['amount']);
      if (amount <= 0 || expenseId.isEmpty) {
        continue;
      }

      final description = expense['description']?.toString() ?? '';
      if (_isBatchInitialExpense(description)) {
        continue;
      }

      final batchId = expense['batch_id']?.toString();
      if (batchId != null && batchId.isNotEmpty && batchIds.contains(batchId)) {
        totals[batchId]!.operating += amount;
        continue;
      }

      if (allocatedExpenseIds.contains(expenseId)) {
        continue;
      }

      if (_isConsumptionBasedExpense(expense)) {
        _allocateConsumptionExpense(
          expense: expense,
          inventory: inventory,
          feedingLogs: feedingLogs,
          vaccinations: vaccinations,
          medications: medications,
          batches: batches,
          batchIds: batchIds,
          totals: totals,
        );
        continue;
      }

      if (batchId == null || batchId.isEmpty) {
        _splitByHeadcount(batches, amount, (id, share) {
          totals[id]!.general += share;
        });
      }
    }

    for (final allocation in allocations) {
      final batchId = allocation['batch_id']?.toString() ?? '';
      if (!batchIds.contains(batchId)) {
        continue;
      }
      final amount = _double(allocation['allocated_amount']);
      if (amount > 0) {
        totals[batchId]!.operating += amount;
        continue;
      }
      final expenseId = allocation['expense_id']?.toString() ?? '';
      Map<String, Object?>? expense;
      for (final row in expenses) {
        if (row['id']?.toString() == expenseId) {
          expense = row;
          break;
        }
      }
      if (expense == null || _isBatchInitialExpense(expense['description']?.toString())) {
        continue;
      }
      final pct = _double(allocation['allocation_percentage']);
      totals[batchId]!.operating += _double(expense['amount']) * (pct / 100);
    }

    _allocateRevenue(
      batches,
      saleItems,
      cancelledOrderIds,
      totals,
    );
    _allocateRevenue(
      batches,
      orderItems,
      cancelledOrderIds,
      totals,
      orderIdKey: 'order_id',
    );

    return totals.values
        .map(
          (item) => BatchFinanceBreakdown(
            batchId: item.batchId,
            batchLabel: item.batchLabel,
            initial: item.initial,
            operating: item.operating,
            consumption: item.consumption,
            general: item.general,
            revenue: item.revenue,
          ),
        )
        .toList()
      ..sort((a, b) => a.batchLabel.compareTo(b.batchLabel));
  }

  Future<BatchFinanceBreakdown?> computeBatchBreakdown(
    String farmId,
    String batchId,
  ) async {
    final all = await computeFarmBreakdown(farmId);
    for (final item in all) {
      if (item.batchId == batchId) {
        return item;
      }
    }
    return null;
  }

  Future<List<Map<String, Object?>>> _loadActiveBatches(String farmId) async {
    return _db.queryLocalRecords(
      'batches',
      where: "farm_id = ? and is_deleted = 0 and upper(status) = 'ACTIVE'",
      whereArgs: [farmId],
      orderBy: 'batch_name asc',
    );
  }

  void _allocateConsumptionExpense({
    required Map<String, Object?> expense,
    required List<Map<String, Object?>> inventory,
    required List<Map<String, Object?>> feedingLogs,
    required List<Map<String, Object?>> vaccinations,
    required List<Map<String, Object?>> medications,
    required List<Map<String, Object?>> batches,
    required Set<String> batchIds,
    required Map<String, _BatchAccumulator> totals,
  }) {
    final amount = _double(expense['amount']);
    final description = expense['description']?.toString() ?? '';
    final category = expense['category']?.toString().toUpperCase() ?? '';
    final inventoryPurchase = _parseInventoryPurchaseExpense(description);
    final healthStock = _parseHealthStockExpense(description);
    final itemName = inventoryPurchase?.itemName ?? healthStock?.itemName;

    final usageByBatch = <String, double>{};

    if (inventoryPurchase != null && category == 'FEED') {
      final inventoryId = _inventoryIdForName(itemName, inventory);
      for (final log in feedingLogs) {
        if (inventoryId != null &&
            log['feed_type_id']?.toString() != inventoryId) {
          continue;
        }
        final batchId = log['batch_id']?.toString() ?? '';
        if (!batchIds.contains(batchId)) {
          continue;
        }
        usageByBatch[batchId] =
            (usageByBatch[batchId] ?? 0) + _double(log['amount_consumed']);
      }
    } else if ((inventoryPurchase != null && category == 'MEDICATION') ||
        healthStock != null) {
      final normalizedName = _normalizeName(itemName ?? '');
      for (final schedule in [...vaccinations, ...medications]) {
        if (!_isCompletedSchedule(schedule)) {
          continue;
        }
        final scheduleName = _normalizeName(
          (schedule['vaccine_name'] ??
                  schedule['medication_name'] ??
                  schedule['name'])
              ?.toString() ??
              '',
        );
        final matchesItem = scheduleName == normalizedName ||
            schedule['inventory_id']?.toString() ==
                _inventoryIdForName(itemName, inventory);
        if (!matchesItem) {
          continue;
        }
        final batchId = schedule['batch_id']?.toString() ?? '';
        if (!batchIds.contains(batchId)) {
          continue;
        }
        usageByBatch[batchId] =
            (usageByBatch[batchId] ?? 0) + _double(schedule['quantity'], 1);
      }
    }

    final totalUsage = usageByBatch.values.fold<double>(0, (sum, v) => sum + v);
    if (totalUsage <= 0) {
      _splitByHeadcount(batches, amount, (id, share) {
        totals[id]!.consumption += share;
      });
      return;
    }

    for (final entry in usageByBatch.entries) {
      totals[entry.key]!.consumption += amount * (entry.value / totalUsage);
    }
  }

  void _allocateRevenue(
    List<Map<String, Object?>> batches,
    List<Map<String, Object?>> saleItems,
    Set<String> cancelledOrderIds,
    Map<String, _BatchAccumulator> totals, {
    String orderIdKey = 'order_id',
  }) {
    final linked = <String, double>{};
    var unlinked = 0.0;

    for (final item in saleItems) {
      if (cancelledOrderIds.contains(item[orderIdKey]?.toString()) ||
          cancelledOrderIds.contains(item['sale_id']?.toString())) {
        continue;
      }
      final total = _double(item['total_price']);
      final batchId = item['livestock_id']?.toString() ?? '';
      if (batchId.isNotEmpty && totals.containsKey(batchId)) {
        linked[batchId] = (linked[batchId] ?? 0) + total;
      } else {
        unlinked += total;
      }
    }

    for (final entry in linked.entries) {
      totals[entry.key]!.revenue += entry.value;
    }

    if (unlinked > 0) {
      _splitByHeadcount(batches, unlinked, (id, share) {
        totals[id]!.revenue += share;
      });
    }
  }

  void _splitByHeadcount(
    List<Map<String, Object?>> batches,
    double amount,
    void Function(String batchId, double share) apply,
  ) {
    final totalHeadcount = batches.fold<int>(
      0,
      (sum, batch) => sum + _int(batch['current_count']),
    );
    if (totalHeadcount <= 0) {
      final share = amount / batches.length;
      for (final batch in batches) {
        apply(batch['id'] as String, share);
      }
      return;
    }

    for (final batch in batches) {
      final batchId = batch['id'] as String;
      final share = amount * (_int(batch['current_count']) / totalHeadcount);
      apply(batchId, share);
    }
  }

  bool _isBatchInitialExpense(String? description) {
    final text = description ?? '';
    return RegExp(r'^Initial cost for ', caseSensitive: false).hasMatch(text) ||
        RegExp(r'^Carriage for ', caseSensitive: false).hasMatch(text) ||
        RegExp(r'\(Initial for ', caseSensitive: false).hasMatch(text);
  }

  bool _isConsumptionBasedExpense(Map<String, Object?> expense) {
    final category = expense['category']?.toString().toUpperCase() ?? '';
    final description = expense['description']?.toString() ?? '';
    if (_parseInventoryPurchaseExpense(description) != null) {
      return category == 'FEED' || category == 'MEDICATION';
    }
    if (_parseHealthStockExpense(description) != null) {
      return category == 'MEDICATION';
    }
    return false;
  }

  ({String itemName, double purchasedQty})? _parseInventoryPurchaseExpense(
    String description,
  ) {
    final match = RegExp(
      r'^Inventory Purchase:\s*(.+?)\s*\(([0-9.]+)\s',
      caseSensitive: false,
    ).firstMatch(description);
    if (match == null) {
      return null;
    }
    return (
      itemName: match.group(1)!.trim(),
      purchasedQty: double.tryParse(match.group(2)!) ?? 0,
    );
  }

  ({String itemName, double stockQty})? _parseHealthStockExpense(
    String description,
  ) {
    final match = RegExp(
      r'^Health stock cost:\s*(.+?)\s*\(([0-9.]+)\s',
      caseSensitive: false,
    ).firstMatch(description);
    if (match == null) {
      return null;
    }
    return (
      itemName: match.group(1)!.trim(),
      stockQty: double.tryParse(match.group(2)!) ?? 0,
    );
  }

  String? _inventoryIdForName(
    String? itemName,
    List<Map<String, Object?>> inventory,
  ) {
    if (itemName == null || itemName.isEmpty) {
      return null;
    }
    final normalized = _normalizeName(itemName);
    for (final item in inventory) {
      if (_normalizeName(item['item_name']?.toString() ?? '') == normalized) {
        return item['id']?.toString();
      }
    }
    return null;
  }

  String _normalizeName(String value) => value.trim().toLowerCase();

  bool _isCompletedSchedule(Map<String, Object?> schedule) {
    final status = schedule['status']?.toString().toUpperCase() ?? '';
    return status == 'COMPLETED' || status == 'DONE';
  }

  double _initialInvestment(Map<String, Object?> batch) {
    final actual = _double(batch['initial_cost_actual']);
    final carriage = _double(batch['initial_cost_carriage']);
    final otherRaw = batch['initial_cost_other'];
    var other = 0.0;
    if (otherRaw is String && otherRaw.trim().startsWith('[')) {
      try {
        final decoded = jsonDecode(otherRaw);
        if (decoded is List) {
          for (final entry in decoded) {
            if (entry is Map && entry['amount'] != null) {
              other += _double(entry['amount']);
            }
          }
        }
      } catch (_) {
        other = _double(otherRaw);
      }
    } else {
      other = _double(otherRaw);
    }
    return actual + carriage + other;
  }

  String _batchLabel(Map<String, Object?> batch) {
    return batch['batch_name']?.toString().trim().isNotEmpty == true
        ? batch['batch_name'].toString()
        : batch['id'].toString();
  }

  double _double(Object? value, [double fallback = 0]) {
    if (value == null) {
      return fallback;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? fallback;
  }

  int _int(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value.toString()) ?? 0;
  }
}

class _BatchAccumulator {
  _BatchAccumulator({
    required this.batchId,
    required this.batchLabel,
    required this.initial,
  });

  final String batchId;
  final String batchLabel;
  final double initial;
  double operating = 0;
  double consumption = 0;
  double general = 0;
  double revenue = 0;
}

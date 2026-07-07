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
    final formulationRows = await _db.queryLocalRecords(
      'feed_formulations',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );
    final formulationIds = formulationRows
        .map((row) => row['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final formulationIngredientRows = formulationIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await _db.rawLocalQuery(
            'select * from feed_formulation_ingredients where formulation_id in (${List.filled(formulationIds.length, '?').join(',')})',
            formulationIds,
          );
    final formulations = _loadFormulationInputs(
      formulationRows,
      formulationIngredientRows,
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

    final batchAllocations = await _db.queryLocalRecords(
      'order_item_batch_allocations',
      where: 'farm_id = ?',
      whereArgs: [farmId],
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

    final feedAllocationIndexes = _buildFeedAllocationIndexes(
      expenses: expenses,
      feedingLogs: feedingLogs,
      inventory: inventory,
      batchIds: batchIds,
      formulations: formulations,
    );
    final feedFifoAllocationsByExpenseId =
        feedAllocationIndexes.feedFifoAllocationsByExpenseId;

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
          feedFifoAllocationsByExpenseId: feedFifoAllocationsByExpenseId,
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

    for (final batchId in batchIds) {
      final formulationFeed =
          feedAllocationIndexes.formulationFeedCostByBatchId[batchId] ?? 0;
      if (formulationFeed > 0) {
        totals[batchId]!.consumption += formulationFeed;
      }
    }

    _allocateRevenue(
      batches,
      saleItems,
      cancelledOrderIds,
      totals,
      batchAllocations: batchAllocations,
    );
    _allocateRevenue(
      batches,
      orderItems,
      cancelledOrderIds,
      totals,
      orderIdKey: 'order_id',
      batchAllocations: batchAllocations,
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


  List<_FormulationInput> _loadFormulationInputs(
    List<Map<String, Object?>> formulationRows,
    List<Map<String, Object?>> ingredientRows,
  ) {
    final ingredientsByFormulation =
        <String, List<_FormulationIngredientInput>>{};
    for (final row in ingredientRows) {
      final formulationId = row['formulation_id']?.toString() ?? '';
      final inventoryId = row['inventory_id']?.toString() ?? '';
      final qty = _double(row['quantity']);
      if (formulationId.isEmpty || inventoryId.isEmpty || qty <= 0) {
        continue;
      }
      ingredientsByFormulation
          .putIfAbsent(formulationId, () => [])
          .add(
            _FormulationIngredientInput(
              inventoryId: inventoryId,
              quantity: qty,
            ),
          );
    }

    final inputs = <_FormulationInput>[];
    for (final row in formulationRows) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) {
        continue;
      }
      inputs.add(
        _FormulationInput(
          id: id,
          name: row['name']?.toString() ?? '',
          createdAt: _parseDateTime(row['created_at'] ?? row['updated_at']),
          ingredients: ingredientsByFormulation[id] ?? const [],
        ),
      );
    }
    return inputs;
  }

  Map<String, double> _inventoryCostPerUnitById(
    List<Map<String, Object?>> inventory,
  ) {
    final costs = <String, double>{};
    for (final item in inventory) {
      final id = item['id']?.toString() ?? '';
      final cost = _double(item['cost_per_unit']);
      if (id.isEmpty || cost <= 0) {
        continue;
      }
      costs[id] = cost;
    }
    return costs;
  }

  _FeedAllocationIndexes _buildFeedAllocationIndexes({
    required List<Map<String, Object?>> expenses,
    required List<Map<String, Object?>> feedingLogs,
    required List<Map<String, Object?>> inventory,
    required Set<String> batchIds,
    required List<_FormulationInput> formulations,
  }) {
    final inventoryCostPerUnitById = _inventoryCostPerUnitById(inventory);
    final lotsByInventoryId = _buildIngredientLotsFromFeedExpenses(
      expenses: expenses,
      inventory: inventory,
    );

    final formulationLots = _buildFormulationLots(
      lotsByInventoryId: lotsByInventoryId,
      formulations: formulations,
      inventoryCostPerUnitById: inventoryCostPerUnitById,
    );

    final logsByInventoryId = <String, List<_FeedUsageLog>>{};
    final logsByFormulationId = <String, List<_FeedUsageLog>>{};
    for (final log in feedingLogs) {
      final batchId = log['batch_id']?.toString() ?? '';
      final qty = _double(log['amount_consumed']);
      if (!batchIds.contains(batchId) || qty <= 0) {
        continue;
      }
      final logDate = _parseDateTime(log['log_date']);
      final feedTypeId = log['feed_type_id']?.toString() ?? '';
      if (feedTypeId.isNotEmpty) {
        final entries = logsByInventoryId.putIfAbsent(feedTypeId, () => []);
        entries.add(
          _FeedUsageLog(
            batchId: batchId,
            quantity: qty,
            logDate: logDate,
          ),
        );
        continue;
      }
      final formulationId = log['formulation_id']?.toString() ?? '';
      if (formulationId.isNotEmpty) {
        final entries =
            logsByFormulationId.putIfAbsent(formulationId, () => []);
        entries.add(
          _FeedUsageLog(
            batchId: batchId,
            quantity: qty,
            logDate: logDate,
          ),
        );
      }
    }
    for (final logs in logsByInventoryId.values) {
      logs.sort((a, b) => a.logDate.compareTo(b.logDate));
    }
    for (final logs in logsByFormulationId.values) {
      logs.sort((a, b) => a.logDate.compareTo(b.logDate));
    }

    final feedFifoAllocationsByExpenseId = _allocateDirectFeedLotsFifo(
      lotsByInventoryId: lotsByInventoryId,
      logsByInventoryId: logsByInventoryId,
    );
    final formulationFeedCostByBatchId = _allocateFormulationFeedToBatches(
      formulationLots: formulationLots,
      logsByFormulationId: logsByFormulationId,
    );

    return _FeedAllocationIndexes(
      feedFifoAllocationsByExpenseId: feedFifoAllocationsByExpenseId,
      formulationFeedCostByBatchId: formulationFeedCostByBatchId,
    );
  }

  Map<String, List<_FeedFifoLot>> _buildIngredientLotsFromFeedExpenses({
    required List<Map<String, Object?>> expenses,
    required List<Map<String, Object?>> inventory,
  }) {
    final lotsByInventoryId = <String, List<_FeedFifoLot>>{};
    for (final expense in expenses) {
      if (expense['category']?.toString().toUpperCase() != 'FEED') {
        continue;
      }
      final parsed = _parseInventoryPurchaseExpense(
        expense['description']?.toString() ?? '',
      );
      if (parsed == null || parsed.purchasedQty <= 0) {
        continue;
      }
      final inventoryId = _inventoryIdForName(parsed.itemName, inventory);
      if (inventoryId == null || inventoryId.isEmpty) {
        continue;
      }
      final amount = _double(expense['amount']);
      if (amount <= 0) {
        continue;
      }
      final expenseId = expense['id']?.toString() ?? '';
      if (expenseId.isEmpty) {
        continue;
      }
      final lots = lotsByInventoryId.putIfAbsent(inventoryId, () => []);
      lots.add(
        _FeedFifoLot(
          expenseId: expenseId,
          expenseDate: _parseDateTime(expense['expense_date']),
          remainingQty: parsed.purchasedQty,
          unitCost: amount / parsed.purchasedQty,
        ),
      );
    }

    for (final lots in lotsByInventoryId.values) {
      lots.sort((a, b) {
        final byDate = a.expenseDate.compareTo(b.expenseDate);
        if (byDate != 0) {
          return byDate;
        }
        return a.expenseId.compareTo(b.expenseId);
      });
    }

    return lotsByInventoryId;
  }

  ({double cost, double qtyUsed}) _depleteIngredientLots(
    List<_FeedFifoLot>? lots,
    double qty,
    DateTime asOfDate, {
    double? fallbackUnitCost,
  }) {
    var remaining = qty;
    var cost = 0.0;

    while (remaining > 0 && lots != null && lots.isNotEmpty) {
      _FeedFifoLot? lot;
      for (final candidate in lots) {
        if (candidate.remainingQty <= 0) {
          continue;
        }
        if (!candidate.expenseDate.isAfter(asOfDate)) {
          lot = candidate;
          break;
        }
      }
      lot ??= () {
        for (final candidate in lots) {
          if (candidate.remainingQty > 0) {
            return candidate;
          }
        }
        return null;
      }();
      if (lot == null) {
        break;
      }

      final usedQty =
          remaining < lot.remainingQty ? remaining : lot.remainingQty;
      if (usedQty <= 0) {
        break;
      }
      lot.remainingQty -= usedQty;
      remaining -= usedQty;
      cost += usedQty * lot.unitCost;
    }

    if (remaining > 0 && fallbackUnitCost != null && fallbackUnitCost > 0) {
      cost += remaining * fallbackUnitCost;
      remaining = 0;
    }

    return (cost: cost, qtyUsed: qty - remaining);
  }

  List<_FormulationLot> _buildFormulationLots({
    required Map<String, List<_FeedFifoLot>> lotsByInventoryId,
    required List<_FormulationInput> formulations,
    required Map<String, double> inventoryCostPerUnitById,
  }) {
    final formulationLots = <_FormulationLot>[];
    final sortedFormulations = [...formulations]
      ..sort((a, b) {
        final byDate = a.createdAt.compareTo(b.createdAt);
        if (byDate != 0) {
          return byDate;
        }
        return a.id.compareTo(b.id);
      });

    for (final formulation in sortedFormulations) {
      if (formulation.ingredients.isEmpty) {
        continue;
      }

      var totalCost = 0.0;
      var totalProducedQty = 0.0;
      for (final ingredient in formulation.ingredients) {
        final qty = ingredient.quantity;
        if (ingredient.inventoryId.isEmpty || qty <= 0) {
          continue;
        }
        final lots = lotsByInventoryId[ingredient.inventoryId];
        final fallbackUnitCost =
            inventoryCostPerUnitById[ingredient.inventoryId];
        final depleted = _depleteIngredientLots(
          lots,
          qty,
          formulation.createdAt,
          fallbackUnitCost: fallbackUnitCost,
        );
        totalCost += depleted.cost;
        totalProducedQty += qty;
      }

      if (totalProducedQty <= 0 || totalCost <= 0) {
        continue;
      }

      formulationLots.add(
        _FormulationLot(
          formulationId: formulation.id,
          createdAt: formulation.createdAt,
          unitCost: totalCost / totalProducedQty,
          remainingQty: totalProducedQty,
        ),
      );
    }

    return formulationLots;
  }

  Map<String, Map<String, double>> _allocateDirectFeedLotsFifo({
    required Map<String, List<_FeedFifoLot>> lotsByInventoryId,
    required Map<String, List<_FeedUsageLog>> logsByInventoryId,
  }) {
    final allocationsByExpenseId = <String, Map<String, double>>{};

    for (final entry in logsByInventoryId.entries) {
      final lots = lotsByInventoryId[entry.key];
      if (lots == null || lots.isEmpty) {
        continue;
      }
      for (final log in entry.value) {
        var qtyToAllocate = log.quantity;
        while (qtyToAllocate > 0) {
          _FeedFifoLot? lot;
          for (final candidate in lots) {
            if (candidate.remainingQty <= 0) {
              continue;
            }
            if (!candidate.expenseDate.isAfter(log.logDate)) {
              lot = candidate;
              break;
            }
          }
          lot ??= () {
            for (final candidate in lots) {
              if (candidate.remainingQty > 0) {
                return candidate;
              }
            }
            return null;
          }();
          if (lot == null || lot.remainingQty <= 0) {
            break;
          }

          final usedQty = qtyToAllocate < lot.remainingQty
              ? qtyToAllocate
              : lot.remainingQty;
          if (usedQty <= 0) {
            break;
          }
          lot.remainingQty -= usedQty;
          qtyToAllocate -= usedQty;

          final batchCosts = allocationsByExpenseId.putIfAbsent(
            lot.expenseId,
            () => {},
          );
          batchCosts[log.batchId] =
              (batchCosts[log.batchId] ?? 0) + (usedQty * lot.unitCost);
        }
      }
    }

    return allocationsByExpenseId;
  }

  Map<String, double> _allocateFormulationFeedToBatches({
    required List<_FormulationLot> formulationLots,
    required Map<String, List<_FeedUsageLog>> logsByFormulationId,
  }) {
    final costByBatchId = <String, double>{};
    final lotsByFormulationId = <String, List<_FormulationLot>>{};
    for (final lot in formulationLots) {
      lotsByFormulationId.putIfAbsent(lot.formulationId, () => []).add(lot);
    }

    for (final entry in logsByFormulationId.entries) {
      final lots = lotsByFormulationId[entry.key];
      if (lots == null || lots.isEmpty) {
        continue;
      }
      for (final log in entry.value) {
        var qtyToAllocate = log.quantity;
        while (qtyToAllocate > 0) {
          _FormulationLot? lot;
          for (final candidate in lots) {
            if (candidate.remainingQty <= 0) {
              continue;
            }
            if (!candidate.createdAt.isAfter(log.logDate)) {
              lot = candidate;
              break;
            }
          }
          lot ??= () {
            for (final candidate in lots) {
              if (candidate.remainingQty > 0) {
                return candidate;
              }
            }
            return null;
          }();
          if (lot == null) {
            break;
          }

          final usedQty = qtyToAllocate < lot.remainingQty
              ? qtyToAllocate
              : lot.remainingQty;
          if (usedQty <= 0) {
            break;
          }
          lot.remainingQty -= usedQty;
          qtyToAllocate -= usedQty;

          final cost = _roundBatchMoney(usedQty * lot.unitCost);
          costByBatchId[log.batchId] = (costByBatchId[log.batchId] ?? 0) + cost;
        }
      }
    }

    return costByBatchId;
  }

  double _roundBatchMoney(double value) => (value * 100).roundToDouble() / 100;

  DateTime _parseDateTime(Object? value) {
    if (value == null) return DateTime.fromMillisecondsSinceEpoch(0);
    if (value is DateTime) return value;
    return DateTime.tryParse(value.toString()) ??
        DateTime.fromMillisecondsSinceEpoch(0);
  }

  void _allocateConsumptionExpense({
    required Map<String, Object?> expense,
    required Map<String, Map<String, double>> feedFifoAllocationsByExpenseId,
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
      final expenseId = expense['id']?.toString() ?? '';
      final fifoCosts = feedFifoAllocationsByExpenseId[expenseId];
      if (fifoCosts != null && fifoCosts.isNotEmpty) {
        usageByBatch.addAll(fifoCosts);
      } else {
        final inventoryId = _inventoryIdForName(itemName, inventory);
        final purchasedQty = inventoryPurchase.purchasedQty;
        if (purchasedQty > 0) {
          final expenseDate = _parseDateTime(expense['expense_date']);
          final sortedLogs = feedingLogs.where((log) {
            if (inventoryId != null &&
                log['feed_type_id']?.toString() != inventoryId) {
              return false;
            }
            final batchId = log['batch_id']?.toString() ?? '';
            return batchIds.contains(batchId);
          }).toList()
            ..sort(
              (a, b) => _parseDateTime(a['log_date'])
                  .compareTo(_parseDateTime(b['log_date'])),
            );
          var remainingQty = purchasedQty;
          for (final log in sortedLogs) {
            if (remainingQty <= 0) break;
            if (_parseDateTime(log['log_date']).isBefore(expenseDate)) continue;
            final consumed = _double(log['amount_consumed']);
            if (consumed <= 0) continue;
            final allocatedQty =
                consumed < remainingQty ? consumed : remainingQty;
            remainingQty -= allocatedQty;
            final batchId = log['batch_id']?.toString() ?? '';
            usageByBatch[batchId] =
                (usageByBatch[batchId] ?? 0) + allocatedQty;
          }
        }
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

    if (inventoryPurchase != null &&
        category == 'FEED' &&
        inventoryPurchase.purchasedQty > 0) {
      final expenseId = expense['id']?.toString() ?? '';
      final fifoCosts = feedFifoAllocationsByExpenseId[expenseId];
      if (fifoCosts != null && fifoCosts.isNotEmpty) {
        for (final entry in fifoCosts.entries) {
          totals[entry.key]!.consumption += entry.value;
        }
        return;
      }
      final purchasedQty = inventoryPurchase.purchasedQty;
      for (final entry in usageByBatch.entries) {
        final share = (entry.value / purchasedQty).clamp(0, 1);
        totals[entry.key]!.consumption += amount * share;
      }
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
    List<Map<String, Object?>> batchAllocations = const [],
  }) {
    final allocatedItemIds = <String>{};
    for (final row in batchAllocations) {
      final batchId = row['batch_id']?.toString() ?? '';
      if (batchId.isEmpty || !totals.containsKey(batchId)) {
        continue;
      }
      totals[batchId]!.revenue += _double(row['revenue_amount']);
      final orderItemId = row['order_item_id']?.toString() ?? '';
      if (orderItemId.isNotEmpty) {
        allocatedItemIds.add(orderItemId);
      }
    }

    final linked = <String, double>{};
    var unlinked = 0.0;

    for (final item in saleItems) {
      if (cancelledOrderIds.contains(item[orderIdKey]?.toString()) ||
          cancelledOrderIds.contains(item['sale_id']?.toString())) {
        continue;
      }
      final itemId = item['id']?.toString() ?? '';
      if (allocatedItemIds.contains(itemId)) {
        continue;
      }
      final total = _double(item['total_price']);
      final eggMode = item['egg_allocation_mode']?.toString() ?? '';
      final eggBatchId = item['egg_batch_id']?.toString() ?? '';
      if (eggMode == 'batch' &&
          eggBatchId.isNotEmpty &&
          totals.containsKey(eggBatchId)) {
        linked[eggBatchId] = (linked[eggBatchId] ?? 0) + total;
        continue;
      }
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

class _FeedAllocationIndexes {
  const _FeedAllocationIndexes({
    required this.feedFifoAllocationsByExpenseId,
    required this.formulationFeedCostByBatchId,
  });

  final Map<String, Map<String, double>> feedFifoAllocationsByExpenseId;
  final Map<String, double> formulationFeedCostByBatchId;
}

class _FormulationInput {
  const _FormulationInput({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.ingredients,
  });

  final String id;
  final String name;
  final DateTime createdAt;
  final List<_FormulationIngredientInput> ingredients;
}

class _FormulationIngredientInput {
  const _FormulationIngredientInput({
    required this.inventoryId,
    required this.quantity,
  });

  final String inventoryId;
  final double quantity;
}

class _FormulationLot {
  _FormulationLot({
    required this.formulationId,
    required this.createdAt,
    required this.unitCost,
    required this.remainingQty,
  });

  final String formulationId;
  final DateTime createdAt;
  final double unitCost;
  double remainingQty;
}

class _FeedUsageLog {
  const _FeedUsageLog({
    required this.batchId,
    required this.quantity,
    required this.logDate,
  });

  final String batchId;
  final double quantity;
  final DateTime logDate;
}

class _FeedFifoLot {
  _FeedFifoLot({
    required this.expenseId,
    required this.expenseDate,
    required this.remainingQty,
    required this.unitCost,
  });

  final String expenseId;
  final DateTime expenseDate;
  final double unitCost;
  double remainingQty;
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

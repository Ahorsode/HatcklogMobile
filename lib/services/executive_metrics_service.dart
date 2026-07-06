import 'package:flutter/foundation.dart';

import '../core/permissions/farm_permissions.dart';
import '../core/storage/local_database.dart';
import '../features/auth/data/supabase_remote_api.dart';

enum StrategicPriorityType { finance, stock, performance }

class StrategicPriority {
  const StrategicPriority({
    required this.title,
    required this.detail,
    required this.type,
  });

  final String title;
  final String detail;
  final StrategicPriorityType type;
}

class ExecutiveStats {
  const ExecutiveStats({
    required this.totalProfit,
    required this.profitTrend,
    required this.globalFcr,
    required this.totalDebt,
    required this.supplierDebt,
    required this.customerDebt,
    required this.activeLivestock,
    required this.mortalityRate,
  });

  final double totalProfit;
  final double profitTrend;
  final double globalFcr;
  final double totalDebt;
  final double supplierDebt;
  final double customerDebt;
  final int activeLivestock;
  final double mortalityRate;
}

class RevenueVelocityPoint {
  const RevenueVelocityPoint({
    required this.date,
    required this.revenue,
    required this.target,
  });

  final String date;
  final double revenue;
  final double target;
}

class ExecutiveDashboardSnapshot {
  const ExecutiveDashboardSnapshot({
    required this.executiveStats,
    required this.strategicPriorities,
    required this.revenueVelocityData,
  });

  final ExecutiveStats executiveStats;
  final List<StrategicPriority> strategicPriorities;
  final List<RevenueVelocityPoint> revenueVelocityData;
}

class ExecutiveMetricsService {
  ExecutiveMetricsService(this._db, [this._remoteApi]);

  final LocalDatabase _db;
  final SupabaseRemoteApi? _remoteApi;

  static const _feedCategories = {
    'feed',
    'feeds',
    'feed_raw',
    'feed_finished',
  };

  Future<bool> isPremiumOwner(String farmId, String role) async {
    if (role.toLowerCase() != 'owner') {
      return false;
    }
    final rows = await _db.queryLocalRecords(
      'farms',
      where: 'id = ?',
      whereArgs: [farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return false;
    }
    final tier =
        rows.first['subscription_tier']?.toString().toUpperCase() ?? '';
    return tier == 'PREMIUM' || tier == 'PAID_PREMIUM';
  }

  Future<ExecutiveDashboardSnapshot> loadDashboard({
    required String farmId,
    required FarmPermissions permissions,
  }) async {
    final today = _dayOnly(DateTime.now());
    final windowStart = today.subtract(const Duration(days: 6));
    final previousStart = windowStart.subtract(const Duration(days: 7));
    final previousEnd = windowStart.subtract(const Duration(days: 1));

    final currentRevenue = await _sumRevenue(farmId, windowStart, today);
    final previousRevenue = await _sumRevenue(
      farmId,
      previousStart,
      previousEnd,
    );
    final currentExpenses = await _sumExpenses(farmId, windowStart, today);
    final totalProfit = currentRevenue - currentExpenses;
    final profitTrend = previousRevenue <= 0
        ? (currentRevenue > 0 ? 100.0 : 0.0)
        : ((currentRevenue - previousRevenue) / previousRevenue) * 100;

    final supplierDebt = permissions.canViewFinance
        ? await _sumColumn('suppliers', 'balance_owed', farmId)
        : 0;
    final customerDebt = permissions.canViewFinance
        ? await _sumColumn('customers', 'balance_owed', farmId)
        : 0;

    final batches = await _loadActiveBatches(farmId);
    final activeLivestock = batches.fold<int>(
      0,
      (sum, batch) => sum + _int(batch['current_count']),
    );
    final mortalityRatePercent = await _farmMortalityRate(farmId, batches);
    final globalFcr = permissions.canViewBatches
        ? await _globalFcr(farmId, batches)
        : 0;

    final priorities = <StrategicPriority>[];
    if (permissions.canViewFinance) {
      final supplierPriority = await _supplierDebtPriority(farmId);
      if (supplierPriority != null) {
        priorities.add(supplierPriority);
      }
    }
    if (permissions.canViewInventory) {
      final stockPriority = await _inventoryShortfallPriority(farmId);
      if (stockPriority != null) {
        priorities.add(stockPriority);
      }
    }
    if (permissions.canViewBatches) {
      final batchPriority = await _batchOptimizationPriority(farmId, batches);
      if (batchPriority != null) {
        priorities.add(batchPriority);
      }
    }

    final revenueVelocity = permissions.canViewFinance
        ? await _revenueVelocity(farmId, windowStart, today)
        : const <RevenueVelocityPoint>[];

    return ExecutiveDashboardSnapshot(
      executiveStats: ExecutiveStats(
        totalProfit: totalProfit,
        profitTrend: profitTrend.toDouble(),
        globalFcr: globalFcr.toDouble(),
        totalDebt: (supplierDebt + customerDebt).toDouble(),
        supplierDebt: supplierDebt.toDouble(),
        customerDebt: customerDebt.toDouble(),
        activeLivestock: activeLivestock,
        mortalityRate: (mortalityRatePercent * 100).toDouble(),
      ),
      strategicPriorities: priorities.take(3).toList(growable: false),
      revenueVelocityData: revenueVelocity,
    );
  }

  Future<double> _sumRevenue(
    String farmId,
    DateTime start,
    DateTime end,
  ) async {
    final sales = await _db.rawLocalQuery(
      'select coalesce(sum(total_amount), 0) as total from sales '
      'where farm_id = ? and is_deleted = 0 and date(sale_date) between date(?) and date(?)',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );
    final orders = await _db.rawLocalQuery(
      'select coalesce(sum(total_amount), 0) as total from orders '
      'where farm_id = ? and is_deleted = 0 and date(order_date) between date(?) and date(?)',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );
    return _double(sales.first['total']) + _double(orders.first['total']);
  }

  Future<double> _sumExpenses(
    String farmId,
    DateTime start,
    DateTime end,
  ) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum(amount), 0) as total from expenses '
      'where farm_id = ? and is_deleted = 0 and date(expense_date) between date(?) and date(?)',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );
    return _double(rows.first['total']);
  }

  Future<double> _sumColumn(
    String table,
    String column,
    String farmId,
  ) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum($column), 0) as total from $table where farm_id = ?',
      [farmId],
    );
    return _double(rows.first['total']);
  }

  Future<List<Map<String, Object?>>> _loadActiveBatches(String farmId) async {
    var rows = await _loadLocalBatchRows(farmId);
    if (rows.isEmpty) {
      rows = await _hydrateBatchesFromCloud(farmId);
    }
    return rows;
  }

  Future<List<Map<String, Object?>>> _loadLocalBatchRows(String farmId) async {
    final activeRows = await _db.queryLocalRecords(
      'batches',
      where: "farm_id = ? and is_deleted = 0 and lower(status) = 'active'",
      whereArgs: [farmId],
    );
    if (activeRows.isNotEmpty) {
      return activeRows;
    }

    return _db.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'batch_name asc',
    );
  }

  Future<List<Map<String, Object?>>> _hydrateBatchesFromCloud(
    String farmId,
  ) async {
    final remoteApi = _remoteApi;
    if (remoteApi == null || !remoteApi.isConfigured || farmId.isEmpty) {
      return const [];
    }

    List<Map<String, Object?>> cloudRows;
    try {
      cloudRows = await remoteApi.fetchLivestockBatchesForFarm(farmId);
    } on Object catch (error) {
      debugPrint('WARN: Executive livestock cloud fetch failed: $error');
      return const [];
    }

    if (cloudRows.isEmpty) {
      return const [];
    }

    try {
      await _db.upsertCloudRecords({'batches': cloudRows});
    } on Object catch (error) {
      debugPrint('WARN: Executive batch local mirror failed: $error');
    }

    final localRows = await _loadLocalBatchRows(farmId);
    return localRows.isNotEmpty ? localRows : cloudRows;
  }

  Future<double> _farmMortalityRate(
    String farmId,
    List<Map<String, Object?>> batches,
  ) async {
    if (batches.isEmpty) {
      return 0;
    }
    final initial = batches.fold<int>(
      0,
      (sum, batch) => sum + _int(batch['initial_count']),
    );
    if (initial <= 0) {
      return 0;
    }
    final rows = await _db.rawLocalQuery(
      "select coalesce(sum(count), 0) as total from mortality "
      "where farm_id = ? and is_deleted = 0 and upper(type) = 'DEAD'",
      [farmId],
    );
    return _int(rows.first['total']) / initial;
  }

  Future<double> _globalFcr(
    String farmId,
    List<Map<String, Object?>> batches,
  ) async {
    final values = <double>[];
    for (final batch in batches) {
      final fcr = await _batchFcr(farmId, batch);
      if (fcr > 0) {
        values.add(fcr);
      }
    }
    if (values.isEmpty) {
      return 0;
    }
    return values.reduce((a, b) => a + b) / values.length;
  }

  Future<double> _batchFcr(
    String farmId,
    Map<String, Object?> batch,
  ) async {
    final batchId = batch['id']?.toString() ?? '';
    final feedRows = await _db.rawLocalQuery(
      'select coalesce(sum(amount_consumed), 0) as total from daily_feeding_logs '
      'where farm_id = ? and batch_id = ? and is_deleted = 0',
      [farmId, batchId],
    );
    final totalFeed = _double(feedRows.first['total']);
    if (totalFeed <= 0) {
      return 0;
    }

    final type = batch['type']?.toString().toUpperCase() ?? '';
    if (type.contains('LAYER')) {
      final eggRows = await _db.rawLocalQuery(
        'select coalesce(sum(eggs_collected), 0) as total from egg_production '
        'where farm_id = ? and batch_id = ? and is_deleted = 0',
        [farmId, batchId],
      );
      final eggs = _double(eggRows.first['total']);
      return eggs <= 0 ? 0 : totalFeed / eggs;
    }

    final weights = await _db.queryLocalRecords(
      'weight_records',
      where: 'farm_id = ? and batch_id = ?',
      whereArgs: [farmId, batchId],
      orderBy: 'log_date asc',
    );
    if (weights.length < 2) {
      return 0;
    }
    final initialWeight = _double(weights.first['average_weight']);
    final latestWeight = _double(weights.last['average_weight']);
    final gain =
        (latestWeight - initialWeight) * _int(batch['current_count']);
    return gain <= 0 ? 0 : totalFeed / gain;
  }

  double _fcrTarget(Map<String, Object?> batch) {
    final type = batch['type']?.toString().toUpperCase() ?? '';
    if (type.contains('LAYER')) {
      return 1.70;
    }
    if (type.contains('BROILER')) {
      return 1.80;
    }
    return 2.00;
  }

  Future<StrategicPriority?> _supplierDebtPriority(String farmId) async {
    final rows = await _db.queryLocalRecords(
      'suppliers',
      where: 'farm_id = ? and balance_owed > 0',
      whereArgs: [farmId],
      orderBy: 'balance_owed desc',
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final supplier = rows.first;
    return StrategicPriority(
      title: 'Supplier Payment Due',
      detail:
          'Debt to ${supplier['name']} — ${_double(supplier['balance_owed']).toStringAsFixed(2)} outstanding',
      type: StrategicPriorityType.finance,
    );
  }

  Future<StrategicPriority?> _inventoryShortfallPriority(String farmId) async {
    final items = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    final candidates = <({Map<String, Object?> item, double reserveHours})>[];

    for (final item in items) {
      if (!_isFeedCategory(item['category']?.toString())) {
        continue;
      }
      final itemId = item['id']?.toString() ?? '';
      final stock = _double(item['stock_level']);
      final logs = await _db.rawLocalQuery(
        'select coalesce(sum(amount_consumed), 0) as total from daily_feeding_logs '
        'where farm_id = ? and feed_type_id = ? and is_deleted = 0 '
        'and date(log_date) >= date(?, "-7 day")',
        [farmId, itemId, DateTime.now().toIso8601String()],
      );
      final weeklyUse = _double(logs.first['total']);
      final avgDaily = weeklyUse / 7;
      final threshold = avgDaily > 0 ? avgDaily * 2 : 500;
      if (stock >= threshold) {
        continue;
      }
      final reserveHours = avgDaily > 0 ? (stock / avgDaily) * 24 : 0;
      candidates.add((item: item, reserveHours: reserveHours.toDouble()));
    }

    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => a.reserveHours.compareTo(b.reserveHours));
    final worst = candidates.first;
    final reserveLabel = worst.reserveHours > 0
        ? 'below ${worst.reserveHours.round() < 1 ? 1 : worst.reserveHours.round()}-hour reserve'
        : 'below 48-hour reserve';
    return StrategicPriority(
      title: 'Inventory Shortfall',
      detail:
          '${worst.item['item_name']} $reserveLabel (${worst.item['stock_level']} ${worst.item['unit'] ?? 'units'} left)',
      type: StrategicPriorityType.stock,
    );
  }

  Future<StrategicPriority?> _batchOptimizationPriority(
    String farmId,
    List<Map<String, Object?>> batches,
  ) async {
    Map<String, Object?>? worstBatch;
    var worstFcr = 0.0;
    var worstTarget = 0.0;

    for (final batch in batches) {
      final fcr = await _batchFcr(farmId, batch);
      final target = _fcrTarget(batch);
      if (fcr > target && fcr > worstFcr) {
        worstBatch = batch;
        worstFcr = fcr;
        worstTarget = target;
      }
    }

    if (worstBatch == null) {
      return null;
    }

    return StrategicPriority(
      title: 'Batch Optimization',
      detail:
          '${worstBatch['batch_name']} FCR ${worstFcr.toStringAsFixed(2)} (Target ${worstTarget.toStringAsFixed(2)})',
      type: StrategicPriorityType.performance,
    );
  }

  Future<List<RevenueVelocityPoint>> _revenueVelocity(
    String farmId,
    DateTime start,
    DateTime end,
  ) async {
    final points = <RevenueVelocityPoint>[];
    final dailyTotals = <String, double>{};

    for (var i = 0; i < 7; i++) {
      final day = start.add(Duration(days: i));
      final key = _formatDay(day);
      dailyTotals[key] = 0;
    }

    final sales = await _db.rawLocalQuery(
      'select date(sale_date) as day, coalesce(sum(total_amount), 0) as total '
      'from sales where farm_id = ? and is_deleted = 0 '
      'and date(sale_date) between date(?) and date(?) group by date(sale_date)',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );
    for (final row in sales) {
      final day = row['day']?.toString() ?? '';
      dailyTotals[day] = (dailyTotals[day] ?? 0) + _double(row['total']);
    }

    final orders = await _db.rawLocalQuery(
      'select date(order_date) as day, coalesce(sum(total_amount), 0) as total '
      'from orders where farm_id = ? and is_deleted = 0 '
      'and date(order_date) between date(?) and date(?) group by date(order_date)',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );
    for (final row in orders) {
      final day = row['day']?.toString() ?? '';
      dailyTotals[day] = (dailyTotals[day] ?? 0) + _double(row['total']);
    }

    final nonZero =
        dailyTotals.values.where((value) => value > 0).toList(growable: false);
    final target = nonZero.isEmpty
        ? 0
        : nonZero.reduce((a, b) => a + b) / nonZero.length;

    for (final entry in dailyTotals.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key))) {
      points.add(
        RevenueVelocityPoint(
          date: entry.key,
          revenue: entry.value,
          target: target.toDouble(),
        ),
      );
    }
    return points;
  }

  bool _isFeedCategory(String? category) {
    final normalized = category?.trim().toLowerCase() ?? '';
    return _feedCategories.contains(normalized);
  }

  DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  String _formatDay(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  double _double(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? 0;
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

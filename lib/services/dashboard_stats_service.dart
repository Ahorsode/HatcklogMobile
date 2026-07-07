import 'package:flutter/foundation.dart';

import '../core/permissions/farm_permissions.dart';
import '../core/storage/local_database.dart';
import '../features/auth/data/supabase_remote_api.dart';

enum DashboardAlertType { vaccine, medication, eggs, feed }

class DashboardAlert {
  const DashboardAlert({
    required this.type,
    required this.title,
    required this.message,
    required this.severity,
  });

  final DashboardAlertType type;
  final String title;
  final String message;
  final String severity;
}

class TrendPoint {
  const TrendPoint({required this.date, required this.count});

  final String date;
  final double count;
}

class DashboardActiveBatch {
  const DashboardActiveBatch({
    required this.id,
    required this.batchName,
    required this.numericId,
    required this.type,
    required this.breed,
    required this.quantity,
    required this.hatchDate,
    required this.houseNumber,
  });

  final String id;
  final String? batchName;
  final String numericId;
  final String type;
  final String breed;
  final int quantity;
  final DateTime hatchDate;
  final String houseNumber;
}

class MonthlyProductionSummary {
  const MonthlyProductionSummary({
    required this.revenue,
    required this.expenses,
    required this.eggs,
  });

  final double revenue;
  final double expenses;
  final int eggs;
}

class RecentFinancialEvent {
  const RecentFinancialEvent({
    required this.type,
    required this.date,
    required this.totalAmount,
    required this.customerName,
    this.status,
  });

  final String type;
  final DateTime date;
  final double totalAmount;
  final String customerName;
  final String? status;
}

class DashboardStatsSnapshot {
  const DashboardStatsSnapshot({
    required this.totalBirds,
    required this.mortalityRate,
    required this.overallDead,
    required this.todayDead,
    required this.totalEggs,
    required this.todayEggs,
    required this.lowFeedItems,
    required this.alerts,
    required this.eggTrendData,
    required this.feedTrendData,
    required this.revenueTrendData,
    required this.mortalityTrendData,
    required this.activeBatches,
    required this.monthlySummary,
    required this.weeklyFeedBags,
    required this.todayFeedBags,
    this.recentFinancialEvents = const [],
    this.customerReceivables = 0,
    this.weeklyOperationalBurn = 0,
  });

  final int totalBirds;
  final double mortalityRate;
  final int overallDead;
  final int todayDead;
  final int totalEggs;
  final int todayEggs;
  final List<({String name, double stockLevel, String category})> lowFeedItems;
  final List<DashboardAlert> alerts;
  final List<TrendPoint> eggTrendData;
  final List<TrendPoint> feedTrendData;
  final List<TrendPoint> revenueTrendData;
  final List<TrendPoint> mortalityTrendData;
  final List<DashboardActiveBatch> activeBatches;
  final MonthlyProductionSummary? monthlySummary;
  final double weeklyFeedBags;
  final double todayFeedBags;
  final List<RecentFinancialEvent> recentFinancialEvents;
  final double customerReceivables;
  final double weeklyOperationalBurn;
}

/// Computes farm dashboard stats from the local SQLite cache (offline-first).
class DashboardStatsService {
  DashboardStatsService(this._db, [this._remoteApi]);

  final LocalDatabase _db;
  final SupabaseRemoteApi? _remoteApi;

  static const _watchedTables = [
    'batches',
    'mortality',
    'egg_production',
    'inventory',
    'daily_feeding_logs',
    'sales',
    'orders',
    'expenses',
    'vaccination_schedules',
    'medication_schedules',
    'houses',
  ];

  Stream<void> watchStats() => _db.watchTables(_watchedTables);

  Future<DashboardStatsSnapshot> loadStats({
    required String farmId,
    required FarmPermissions permissions,
  }) async {
    final today = _dayOnly(DateTime.now());
    final sevenDaysAgo = today.subtract(const Duration(days: 6));
    final thirtyDaysAgo = today.subtract(const Duration(days: 30));
    final trendDates = _lastSevenDayLabels(today);

    final batches = await _loadFarmBatches(farmId);
    final totalBirds = batches.fold<int>(
      0,
      (sum, batch) => sum + _int(batch['current_count']),
    );

    final initialBirds = await _sumColumn(
      'batches',
      'initial_count',
      farmId,
      extraWhere: 'is_deleted = 0',
    );
    final overallDeadRows = await _db.rawLocalQuery(
      "select coalesce(sum(count), 0) as total from mortality "
      "where farm_id = ? and is_deleted = 0 and upper(type) = 'DEAD'",
      [farmId],
    );
    final overallDead = _int(overallDeadRows.first['total']);
    final mortalityRate = initialBirds > 0
        ? (overallDead / initialBirds) * 100
        : 0.0;

    final todayDeadRows = await _db.rawLocalQuery(
      "select coalesce(sum(count), 0) as total from mortality "
      "where farm_id = ? and is_deleted = 0 and upper(type) = 'DEAD' "
      "and date(log_date) = date(?)",
      [farmId, today.toIso8601String()],
    );
    final todayDead = _int(todayDeadRows.first['total']);

    final eggInventoryRows = await _db.queryLocalRecords(
      'inventory',
      where: "farm_id = ? and is_deleted = 0 and upper(category) = 'EGGS'",
      whereArgs: [farmId],
      limit: 1,
    );
    final totalEggs = eggInventoryRows.isEmpty
        ? 0
        : _int(eggInventoryRows.first['stock_level']);

    final todayEggsRows = await _db.rawLocalQuery(
      'select coalesce(sum(eggs_collected), 0) as total from egg_production '
      'where farm_id = ? and is_deleted = 0 and date(log_date) = date(?)',
      [farmId, today.toIso8601String()],
    );
    final todayEggs = _int(todayEggsRows.first['total']);

    final lowFeedRows = await _db.queryLocalRecords(
      'inventory',
      where:
          "farm_id = ? and is_deleted = 0 and lower(category) = 'feed' "
          "and stock_level < 500",
      whereArgs: [farmId],
    );
    final lowFeedItems = lowFeedRows
        .map(
          (row) => (
            name: row['item_name']?.toString() ?? 'Feed item',
            stockLevel: _double(row['stock_level']),
            category: row['category']?.toString() ?? 'feed',
          ),
        )
        .toList(growable: false);

    final recentEggs = await _db.rawLocalQuery(
      'select log_date, eggs_collected from egg_production '
      'where farm_id = ? and is_deleted = 0 and date(log_date) >= date(?) '
      'order by log_date asc',
      [farmId, sevenDaysAgo.toIso8601String()],
    );
    final recentFeed = await _db.rawLocalQuery(
      'select log_date, amount_consumed from daily_feeding_logs '
      'where farm_id = ? and is_deleted = 0 and date(log_date) >= date(?) '
      'order by log_date asc',
      [farmId, sevenDaysAgo.toIso8601String()],
    );
    final recentMortality = await _db.rawLocalQuery(
      "select log_date, count from mortality "
      "where farm_id = ? and is_deleted = 0 and upper(type) = 'DEAD' "
      "and date(log_date) >= date(?) order by log_date asc",
      [farmId, sevenDaysAgo.toIso8601String()],
    );

    final recentSales = permissions.canViewFinance
        ? await _db.rawLocalQuery(
            'select sale_date, total_amount from sales '
            'where farm_id = ? and is_deleted = 0 and date(sale_date) >= date(?) '
            'order by sale_date asc',
            [farmId, sevenDaysAgo.toIso8601String()],
          )
        : const <Map<String, Object?>>[];
    final recentOrders = permissions.canViewFinance
        ? await _db.rawLocalQuery(
            'select order_date, total_amount from orders '
            'where farm_id = ? and is_deleted = 0 and date(order_date) >= date(?) '
            'order by order_date asc',
            [farmId, sevenDaysAgo.toIso8601String()],
          )
        : const <Map<String, Object?>>[];

    final eggTrendData = _buildTrend(
      trendDates,
      recentEggs,
      'log_date',
      'eggs_collected',
    );
    final feedTrendData = _buildTrend(
      trendDates,
      recentFeed,
      'log_date',
      'amount_consumed',
    );
    final mortalityTrendData = _buildTrend(
      trendDates,
      recentMortality,
      'log_date',
      'count',
    );
    final revenueTrendData = permissions.canViewFinance
        ? trendDates.map((date) {
            final saleTotal = recentSales
                .where((row) => _formatDayFromValue(row['sale_date']) == date)
                .fold<double>(
                  0,
                  (sum, row) => sum + _double(row['total_amount']),
                );
            final orderTotal = recentOrders
                .where((row) => _formatDayFromValue(row['order_date']) == date)
                .fold<double>(
                  0,
                  (sum, row) => sum + _double(row['total_amount']),
                );
            return TrendPoint(date: date, count: saleTotal + orderTotal);
          }).toList(growable: false)
        : const <TrendPoint>[];

    final alerts = await _buildAlerts(farmId, today);

    final houses = await _db.queryLocalRecords(
      'houses',
      where: 'farm_id = ?',
      whereArgs: [farmId],
    );
    final houseNames = {
      for (final house in houses)
        house['id']?.toString(): house['name']?.toString() ?? 'N/A',
    };

    final activeBatches = batches
        .map((batch) {
          final numericId = batch['id']?.toString() ?? '';
          final localBatchId = batch['local_batch_id']?.toString() ?? numericId;
          final padded = localBatchId.padLeft(3, '0');
          return DashboardActiveBatch(
            id: 'FLK-$padded',
            batchName: batch['batch_name']?.toString(),
            numericId: numericId,
            type: batch['type']?.toString() ?? 'POULTRY',
            breed: batch['breed_type']?.toString() ?? 'Unknown',
            quantity: _int(batch['current_count']),
            hatchDate: DateTime.tryParse(
                  batch['arrival_date']?.toString() ?? '',
                ) ??
                today,
            houseNumber:
                houseNames[batch['house_id']?.toString()] ?? 'N/A',
          );
        })
        .toList(growable: false);

    MonthlyProductionSummary? monthlySummary;
    if (permissions.canViewFinance || permissions.canViewEggs) {
      final monthEggs = permissions.canViewEggs
          ? await _sumEggsSince(farmId, thirtyDaysAgo)
          : 0;
      final monthExpenses = permissions.canViewFinance
          ? await _sumExpensesSince(farmId, thirtyDaysAgo)
          : 0.0;
      final monthRevenue = permissions.canViewFinance
          ? await _sumRevenueSince(farmId, thirtyDaysAgo)
          : 0.0;
      monthlySummary = MonthlyProductionSummary(
        revenue: monthRevenue,
        expenses: monthExpenses,
        eggs: monthEggs,
      );
    }

    final weeklyFeedBags = feedTrendData.fold<double>(
      0,
      (sum, point) => sum + point.count,
    );
    final todayFeedRows = await _db.rawLocalQuery(
      'select coalesce(sum(amount_consumed), 0) as total from daily_feeding_logs '
      'where farm_id = ? and is_deleted = 0 and date(log_date) = date(?)',
      [farmId, today.toIso8601String()],
    );
    final todayFeedBags = _double(todayFeedRows.first['total']);

    var recentFinancialEvents = const <RecentFinancialEvent>[];
    var customerReceivables = 0.0;
    var weeklyOperationalBurn = 0.0;
    if (permissions.canViewFinance) {
      final saleAuditRows = await _db.rawLocalQuery(
        'select sale_date, total_amount, customer_name, status from sales '
        'where farm_id = ? and is_deleted = 0 '
        'order by sale_date desc limit 5',
        [farmId],
      );
      final orderAuditRows = await _db.rawLocalQuery(
        '''
        select o.order_date,
               o.total_amount,
               o.status,
               coalesce(c.name, 'Walk-in') as customer_name
        from orders o
        left join customers c on c.id = o.customer_id
        where o.farm_id = ? and o.is_deleted = 0
        order by o.order_date desc
        limit 5
        ''',
        [farmId],
      );
      recentFinancialEvents = [
        ...saleAuditRows.map(
          (row) => RecentFinancialEvent(
            type: 'SALE',
            date:
                DateTime.tryParse(row['sale_date']?.toString() ?? '') ??
                today,
            totalAmount: _double(row['total_amount']),
            customerName: row['customer_name']?.toString() ?? 'Walk-in',
            status: row['status']?.toString(),
          ),
        ),
        ...orderAuditRows.map(
          (row) => RecentFinancialEvent(
            type: 'ORDER',
            date:
                DateTime.tryParse(row['order_date']?.toString() ?? '') ??
                today,
            totalAmount: _double(row['total_amount']),
            customerName: row['customer_name']?.toString() ?? 'Walk-in',
            status: row['status']?.toString(),
          ),
        ),
      ]..sort((a, b) => b.date.compareTo(a.date));
      if (recentFinancialEvents.length > 5) {
        recentFinancialEvents = recentFinancialEvents.sublist(0, 5);
      }

      final receivableRows = await _db.rawLocalQuery(
        'select coalesce(sum(balance_owed), 0) as total from customers '
        'where farm_id = ?',
        [farmId],
      );
      customerReceivables = _double(receivableRows.first['total']);

      final expenseWeekRows = await _db.rawLocalQuery(
        'select coalesce(sum(amount), 0) as total from expenses '
        'where farm_id = ? and is_deleted = 0 and date(expense_date) >= date(?)',
        [farmId, sevenDaysAgo.toIso8601String()],
      );
      weeklyOperationalBurn = _double(expenseWeekRows.first['total']);
    }

    return DashboardStatsSnapshot(
      totalBirds: totalBirds,
      mortalityRate: mortalityRate,
      overallDead: overallDead,
      todayDead: todayDead,
      totalEggs: totalEggs,
      todayEggs: todayEggs,
      lowFeedItems: lowFeedItems,
      alerts: alerts,
      eggTrendData: eggTrendData,
      feedTrendData: feedTrendData,
      revenueTrendData: revenueTrendData,
      mortalityTrendData: mortalityTrendData,
      activeBatches: activeBatches,
      monthlySummary: monthlySummary,
      weeklyFeedBags: weeklyFeedBags,
      todayFeedBags: todayFeedBags,
      recentFinancialEvents: recentFinancialEvents,
      customerReceivables: customerReceivables,
      weeklyOperationalBurn: weeklyOperationalBurn,
    );
  }

  Future<List<DashboardAlert>> _buildAlerts(
    String farmId,
    DateTime today,
  ) async {
    final alerts = <DashboardAlert>[];
    final threeDaysAhead = today.add(const Duration(days: 3));

    final vaccinations = await _db.queryLocalRecords(
      'vaccination_schedules',
      where:
          "farm_id = ? and upper(status) = 'PENDING' "
          "and date(scheduled_date) <= date(?)",
      whereArgs: [farmId, threeDaysAhead.toIso8601String()],
    );
    for (final row in vaccinations) {
      final batchId = row['batch_id']?.toString() ?? '';
      final batchName = await _batchLabel(farmId, batchId);
      alerts.add(
        DashboardAlert(
          type: DashboardAlertType.vaccine,
          title: 'Upcoming Vaccination',
          message: '${row['vaccine_name']} for $batchName',
          severity: 'warning',
        ),
      );
    }

    final medications = await _db.queryLocalRecords(
      'medication_schedules',
      where: "farm_id = ? and upper(status) = 'PENDING'",
      whereArgs: [farmId],
    );
    for (final row in medications) {
      final batchId = row['batch_id']?.toString() ?? '';
      final batchName = await _batchLabel(farmId, batchId);
      alerts.add(
        DashboardAlert(
          type: DashboardAlertType.medication,
          title: 'Medication Due',
          message: '${row['medication_name']} for $batchName',
          severity: 'error',
        ),
      );
    }

    final batchesNeedingEggs = await _db.rawLocalQuery(
      'select b.id, b.batch_name from batches b '
      'where b.farm_id = ? and b.is_deleted = 0 and upper(b.status) = ? '
      'and not exists ( '
      '  select 1 from egg_production e '
      '  where e.batch_id = b.id and e.farm_id = b.farm_id '
      '  and e.is_deleted = 0 and date(e.log_date) = date(?) '
      ')',
      [farmId, 'ACTIVE', today.toIso8601String()],
    );
    for (final row in batchesNeedingEggs) {
      alerts.add(
        DashboardAlert(
          type: DashboardAlertType.eggs,
          title: 'Egg Collection Due',
          message:
              'Flock ${row['batch_name'] ?? row['id']} needs collection',
          severity: 'info',
        ),
      );
    }

    return alerts;
  }

  Future<String> _batchLabel(String farmId, String batchId) async {
    if (batchId.isEmpty) {
      return 'batch';
    }
    final rows = await _db.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and id = ?',
      whereArgs: [farmId, batchId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return batchId;
    }
    return rows.first['batch_name']?.toString() ?? batchId;
  }

  Future<List<Map<String, Object?>>> _loadFarmBatches(String farmId) async {
    var rows = await _loadLocalBatchRows(farmId);
    if (rows.isEmpty) {
      rows = await _hydrateBatchesFromCloud(farmId);
    }
    return rows;
  }

  Future<List<Map<String, Object?>>> _loadLocalBatchRows(String farmId) async {
    return _db.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: "case when lower(status) = 'active' then 0 else 1 end, batch_name asc",
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
      debugPrint('WARN: Dashboard livestock cloud fetch failed: $error');
      return const [];
    }

    if (cloudRows.isEmpty) {
      return const [];
    }

    try {
      await _db.upsertCloudRecords({'batches': cloudRows});
    } on Object catch (error) {
      debugPrint('WARN: Dashboard batch local mirror failed: $error');
    }

    final localRows = await _loadLocalBatchRows(farmId);
    return localRows.isNotEmpty ? localRows : cloudRows;
  }

  Future<double> _sumColumn(
    String table,
    String column,
    String farmId, {
    String extraWhere = '',
  }) async {
    final where = extraWhere.isEmpty
        ? 'farm_id = ?'
        : 'farm_id = ? and $extraWhere';
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum($column), 0) as total from $table where $where',
      [farmId],
    );
    return _double(rows.first['total']);
  }

  Future<int> _sumEggsSince(String farmId, DateTime start) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum(eggs_collected), 0) as total from egg_production '
      'where farm_id = ? and is_deleted = 0 and date(log_date) >= date(?)',
      [farmId, start.toIso8601String()],
    );
    return _int(rows.first['total']);
  }

  Future<double> _sumExpensesSince(String farmId, DateTime start) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum(amount), 0) as total from expenses '
      'where farm_id = ? and is_deleted = 0 and date(expense_date) >= date(?)',
      [farmId, start.toIso8601String()],
    );
    return _double(rows.first['total']);
  }

  Future<double> _sumRevenueSince(String farmId, DateTime start) async {
    final sales = await _db.rawLocalQuery(
      'select coalesce(sum(total_amount), 0) as total from sales '
      'where farm_id = ? and is_deleted = 0 and date(sale_date) >= date(?)',
      [farmId, start.toIso8601String()],
    );
    final orders = await _db.rawLocalQuery(
      'select coalesce(sum(total_amount), 0) as total from orders '
      'where farm_id = ? and is_deleted = 0 and date(order_date) >= date(?)',
      [farmId, start.toIso8601String()],
    );
    return _double(sales.first['total']) + _double(orders.first['total']);
  }

  List<TrendPoint> _buildTrend(
    List<String> dates,
    List<Map<String, Object?>> rows,
    String dateColumn,
    String valueColumn,
  ) {
    return dates
        .map((date) {
          final total = rows
              .where(
                (row) => _formatDayFromValue(row[dateColumn]) == date,
              )
              .fold<double>(
                0,
                (sum, row) => sum + _double(row[valueColumn]),
              );
          return TrendPoint(date: date, count: total);
        })
        .toList(growable: false);
  }

  List<String> _lastSevenDayLabels(DateTime today) {
    return List.generate(7, (index) {
      final day = today.subtract(Duration(days: 6 - index));
      return _formatDay(day);
    });
  }

  DateTime _dayOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  String _formatDay(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String _formatDayFromValue(Object? value) {
    if (value == null) {
      return '';
    }
    if (value is DateTime) {
      return _formatDay(value);
    }
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) {
      return value.toString().split('T').first;
    }
    return _formatDay(parsed);
  }

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

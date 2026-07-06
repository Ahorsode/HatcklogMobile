import '../core/permissions/farm_permissions.dart';
import '../core/permissions/navigation_permissions.dart';
import '../core/storage/local_database.dart';
import 'finance_ledger_service.dart';

class ReportKpis {
  const ReportKpis({
    required this.totalRevenue,
    required this.totalExpense,
    required this.netIncome,
    required this.totalFeedConsumed,
    required this.totalEggsCollected,
    required this.totalMortality,
    required this.mortalityRate,
    required this.averageFcr,
  });

  final double totalRevenue;
  final double totalExpense;
  final double netIncome;
  final double totalFeedConsumed;
  final int totalEggsCollected;
  final int totalMortality;
  final double mortalityRate;
  final double averageFcr;
}

class ReportFinancialRow {
  const ReportFinancialRow({
    required this.id,
    required this.type,
    required this.category,
    required this.amount,
    required this.paymentStatus,
    required this.paymentMethod,
    required this.transactionDate,
    required this.description,
    required this.referenceNum,
    required this.userName,
  });

  final String id;
  final String type;
  final String category;
  final double amount;
  final String paymentStatus;
  final String paymentMethod;
  final DateTime transactionDate;
  final String? description;
  final String? referenceNum;
  final String userName;
}

class DailyReportTrend {
  const DailyReportTrend({
    required this.date,
    required this.revenue,
    required this.expense,
    required this.eggs,
    required this.feed,
    required this.mortality,
  });

  final String date;
  final double revenue;
  final double expense;
  final int eggs;
  final double feed;
  final int mortality;
}

class ReportBatchRow {
  const ReportBatchRow({
    required this.id,
    required this.batchName,
    required this.initialCount,
    required this.currentCount,
    required this.status,
    required this.mortalityCount,
    required this.feedConsumed,
  });

  final String id;
  final String batchName;
  final int initialCount;
  final int currentCount;
  final String status;
  final int mortalityCount;
  final double feedConsumed;
}

class AuditTimelineEntry {
  const AuditTimelineEntry({
    required this.id,
    required this.actionType,
    required this.description,
    required this.createdAt,
    required this.userName,
  });

  final String id;
  final String? actionType;
  final String? description;
  final DateTime createdAt;
  final String userName;
}

class ComprehensiveFarmReport {
  const ComprehensiveFarmReport({
    required this.startDate,
    required this.endDate,
    required this.kpis,
    required this.financials,
    required this.revenueByCategory,
    required this.expenseByCategory,
    required this.paymentStatusMatrix,
    required this.dailyTrends,
    required this.batches,
    required this.auditTimeline,
  });

  final DateTime startDate;
  final DateTime endDate;
  final ReportKpis kpis;
  final List<ReportFinancialRow> financials;
  final Map<String, double> revenueByCategory;
  final Map<String, double> expenseByCategory;
  final Map<String, ({int count, double total})> paymentStatusMatrix;
  final List<DailyReportTrend> dailyTrends;
  final List<ReportBatchRow> batches;
  final List<AuditTimelineEntry> auditTimeline;
}

/// Offline-first comprehensive farm report — mirrors web `generateComprehensiveFarmReport`.
class ComprehensiveFarmReportService {
  ComprehensiveFarmReportService(this._db);

  final LocalDatabase _db;

  Future<ComprehensiveFarmReport?> generate({
    required String farmId,
    required DateTime startDate,
    required DateTime endDate,
    required FarmPermissions permissions,
    required String? role,
    required List<String> assignableRoles,
  }) async {
    final canAccess = canShowNavigationItem(
      name: 'Reports',
      role: role,
      roles: assignableRoles,
      permissions: permissions,
    );
    if (!canAccess) {
      return null;
    }

    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
      23,
      59,
      59,
      999,
    );

    final ledger = FinanceLedgerService(_db);
    final allTransactions = await ledger.loadTransactions(farmId);
    final periodTransactions = allTransactions
        .where(
          (entry) =>
              !entry.transactionDate.isBefore(start) &&
              !entry.transactionDate.isAfter(end),
        )
        .toList();

    final feedRows = await _db.rawLocalQuery(
      '''
      select amount_consumed, log_date
      from daily_feeding_logs
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      order by log_date asc
      ''',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );

    final eggRows = await _db.rawLocalQuery(
      '''
      select eggs_collected, log_date
      from egg_production
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      order by log_date asc
      ''',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );

    final mortalityRows = await _db.rawLocalQuery(
      '''
      select count, log_date
      from mortality
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      order by log_date asc
      ''',
      [farmId, start.toIso8601String(), end.toIso8601String()],
    );

    final batchRows = await _db.rawLocalQuery(
      '''
      select id, batch_name, initial_count, current_count, status, local_batch_id
      from batches
      where farm_id = ? and is_deleted = 0
      ''',
      [farmId],
    );

    var totalRevenue = 0.0;
    var totalExpense = 0.0;
    final revenueByCategory = <String, double>{};
    final expenseByCategory = <String, double>{};
    final paymentStatusMatrix = <String, ({int count, double total})>{};

    final financials = <ReportFinancialRow>[];
    for (final entry in periodTransactions) {
      final amount = entry.amount;
      final type = entry.type.toUpperCase();
      if (type == 'REVENUE') {
        totalRevenue += amount;
        revenueByCategory[entry.category] =
            (revenueByCategory[entry.category] ?? 0) + amount;
      } else {
        totalExpense += amount;
        expenseByCategory[entry.category] =
            (expenseByCategory[entry.category] ?? 0) + amount;
      }

      final status = entry.paymentStatus.isEmpty ? 'UNPAID' : entry.paymentStatus;
      final matrix = paymentStatusMatrix[status];
      paymentStatusMatrix[status] = (
        count: (matrix?.count ?? 0) + 1,
        total: (matrix?.total ?? 0) + amount,
      );

      financials.add(
        ReportFinancialRow(
          id: entry.id,
          type: type,
          category: entry.category,
          amount: amount,
          paymentStatus: status,
          paymentMethod: entry.paymentMethod,
          transactionDate: entry.transactionDate,
          description: entry.description,
          referenceNum: entry.referenceNum,
          userName: 'System',
        ),
      );
    }

    financials.sort((a, b) => b.transactionDate.compareTo(a.transactionDate));

    final totalFeedConsumed = feedRows.fold<double>(
      0,
      (sum, row) => sum + _asDouble(row['amount_consumed']),
    );
    final totalEggsCollected = eggRows.fold<int>(
      0,
      (sum, row) => sum + _asInt(row['eggs_collected']),
    );
    final totalMortality = mortalityRows.fold<int>(
      0,
      (sum, row) => sum + _asInt(row['count']),
    );

    var totalInitialBirds = 0;
    var totalCurrentBirds = 0;
    final batches = <ReportBatchRow>[];

    for (final batch in batchRows) {
      final batchId = _text(batch['id']);
      final status = _text(batch['status'], 'active').toLowerCase();
      final initialCount = _asInt(batch['initial_count']);
      final currentCount = _asInt(batch['current_count']);

      if (status == 'active') {
        totalInitialBirds += initialCount;
        totalCurrentBirds += currentCount;
      }

      final batchFeedRows = await _db.rawLocalQuery(
        '''
        select coalesce(sum(amount_consumed), 0) as total
        from daily_feeding_logs
        where batch_id = ? and is_deleted = 0
        ''',
        [batchId],
      );
      final batchMortalityRows = await _db.rawLocalQuery(
        '''
        select coalesce(sum(count), 0) as total
        from mortality
        where batch_id = ? and is_deleted = 0
        ''',
        [batchId],
      );

      final batchName = _text(batch['batch_name']);
      final localBatchId = batch['local_batch_id'];
      final fallbackName = localBatchId != null
          ? 'Batch $localBatchId'
          : 'Batch ${batchId.length > 5 ? batchId.substring(0, 5) : batchId}';

      batches.add(
        ReportBatchRow(
          id: batchId,
          batchName: batchName.isEmpty ? fallbackName : batchName,
          initialCount: initialCount,
          currentCount: currentCount,
          status: status,
          mortalityCount: _asInt(batchMortalityRows.first['total']),
          feedConsumed: _asDouble(batchFeedRows.first['total']),
        ),
      );
    }

    final mortalityRate = totalInitialBirds > 0
        ? double.parse(
            (((totalInitialBirds - totalCurrentBirds) / totalInitialBirds) *
                    100)
                .toStringAsFixed(2),
          )
        : 0.0;

    var totalFcrSum = 0.0;
    var batchesWithFcrCount = 0;
    for (final batch in batches) {
      if (batch.feedConsumed > 0 && batch.currentCount > 0) {
        const avgWeight = 1.8;
        totalFcrSum += batch.feedConsumed / (batch.currentCount * avgWeight);
        batchesWithFcrCount++;
      }
    }
    final averageFcr = batchesWithFcrCount > 0
        ? double.parse(
            (totalFcrSum / batchesWithFcrCount).toStringAsFixed(2),
          )
        : 1.65;

    final trendsMap = <String, ({double revenue, double expense, int eggs, double feed, int mortality})>{};
    var day = start;
    while (!day.isAfter(end)) {
      final dateStr = _dateKey(day);
      trendsMap[dateStr] = (
        revenue: 0,
        expense: 0,
        eggs: 0,
        feed: 0,
        mortality: 0,
      );
      day = day.add(const Duration(days: 1));
    }

    for (final entry in periodTransactions) {
      final dateStr = _dateKey(entry.transactionDate);
      final slot = trendsMap[dateStr];
      if (slot == null) continue;
      if (entry.type.toUpperCase() == 'REVENUE') {
        trendsMap[dateStr] = (
          revenue: slot.revenue + entry.amount,
          expense: slot.expense,
          eggs: slot.eggs,
          feed: slot.feed,
          mortality: slot.mortality,
        );
      } else {
        trendsMap[dateStr] = (
          revenue: slot.revenue,
          expense: slot.expense + entry.amount,
          eggs: slot.eggs,
          feed: slot.feed,
          mortality: slot.mortality,
        );
      }
    }

    for (final row in eggRows) {
      final dateStr = _dateKey(_parseDate(row['log_date']));
      final slot = trendsMap[dateStr];
      if (slot == null) continue;
      trendsMap[dateStr] = (
        revenue: slot.revenue,
        expense: slot.expense,
        eggs: slot.eggs + _asInt(row['eggs_collected']),
        feed: slot.feed,
        mortality: slot.mortality,
      );
    }

    for (final row in feedRows) {
      final dateStr = _dateKey(_parseDate(row['log_date']));
      final slot = trendsMap[dateStr];
      if (slot == null) continue;
      trendsMap[dateStr] = (
        revenue: slot.revenue,
        expense: slot.expense,
        eggs: slot.eggs,
        feed: slot.feed + _asDouble(row['amount_consumed']),
        mortality: slot.mortality,
      );
    }

    for (final row in mortalityRows) {
      final dateStr = _dateKey(_parseDate(row['log_date']));
      final slot = trendsMap[dateStr];
      if (slot == null) continue;
      trendsMap[dateStr] = (
        revenue: slot.revenue,
        expense: slot.expense,
        eggs: slot.eggs,
        feed: slot.feed,
        mortality: slot.mortality + _asInt(row['count']),
      );
    }

    final dailyTrends = trendsMap.entries
        .map(
          (entry) => DailyReportTrend(
            date: entry.key,
            revenue: entry.value.revenue,
            expense: entry.value.expense,
            eggs: entry.value.eggs,
            feed: entry.value.feed,
            mortality: entry.value.mortality,
          ),
        )
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    return ComprehensiveFarmReport(
      startDate: start,
      endDate: end,
      kpis: ReportKpis(
        totalRevenue: totalRevenue,
        totalExpense: totalExpense,
        netIncome: totalRevenue - totalExpense,
        totalFeedConsumed: totalFeedConsumed,
        totalEggsCollected: totalEggsCollected,
        totalMortality: totalMortality,
        mortalityRate: mortalityRate,
        averageFcr: averageFcr,
      ),
      financials: financials,
      revenueByCategory: revenueByCategory,
      expenseByCategory: expenseByCategory,
      paymentStatusMatrix: paymentStatusMatrix,
      dailyTrends: dailyTrends,
      batches: batches,
      auditTimeline: const [],
    );
  }

  String _dateKey(DateTime date) {
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  DateTime _parseDate(Object? value) {
    return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
  }

  int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.round();
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _asDouble(Object? value) {
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  String _text(Object? value, [String fallback = '']) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }
}

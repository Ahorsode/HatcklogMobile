import 'dart:math' as math;

import '../core/permissions/farm_permissions.dart';
import '../core/storage/local_database.dart';
import 'batch_finance_service.dart';

class BatchPerformanceReport {
  const BatchPerformanceReport({
    required this.id,
    required this.name,
    required this.status,
    required this.type,
    required this.houseName,
    required this.initialCount,
    required this.currentCount,
    required this.totalFeed,
    required this.totalEggs,
    required this.totalDead,
    required this.fcr,
    required this.mortalityRate,
    required this.initialInvestment,
    required this.directExpenses,
    required this.allocatedExpenses,
    required this.operatingExpenses,
    required this.consumptionShare,
    required this.generalShare,
    required this.totalExpenses,
    required this.totalRevenue,
    required this.netProfitability,
  });

  final String id;
  final String name;
  final String status;
  final String type;
  final String houseName;
  final int initialCount;
  final int currentCount;
  final double totalFeed;
  final int totalEggs;
  final int totalDead;
  final double fcr;
  final double mortalityRate;
  final double initialInvestment;
  final double directExpenses;
  final double allocatedExpenses;
  final double operatingExpenses;
  final double consumptionShare;
  final double generalShare;
  final double totalExpenses;
  final double totalRevenue;
  final double netProfitability;
}

class BatchPerformancePayload {
  const BatchPerformancePayload({
    required this.batches,
    required this.canViewFinance,
  });

  final List<BatchPerformanceReport> batches;
  final bool canViewFinance;
}

class BatchAnalyticsService {
  BatchAnalyticsService(this._db);

  final LocalDatabase _db;

  Future<BatchPerformancePayload> loadReports({
    required String farmId,
    required FarmPermissions permissions,
  }) async {
    final canViewFinance = permissions.canViewFinance || permissions.canEditFinance;
    final batches = await _db.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'upper(status) asc, batch_name asc',
    );
    if (batches.isEmpty) {
      return BatchPerformancePayload(batches: const [], canViewFinance: canViewFinance);
    }

    final houses = await _db.queryLocalRecords(
      'houses',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    final houseNames = {
      for (final house in houses)
        if (house['id'] != null) house['id']!.toString(): house['name']?.toString() ?? 'Unassigned',
    };

    final financeByBatch = canViewFinance
        ? {
            for (final item in await BatchFinanceService(_db).computeFarmBreakdown(farmId))
              item.batchId: item,
          }
        : const <String, BatchFinanceBreakdown>{};

    final reports = <BatchPerformanceReport>[];
    for (final batch in batches) {
      final batchId = batch['id']?.toString() ?? '';
      if (batchId.isEmpty) continue;

      final initialCount = _int(batch['initial_count']);
      final currentCount = _int(batch['current_count']);
      final totalFeed = await _sumFeed(farmId, batchId);
      final totalEggs = await _sumEggs(farmId, batchId);
      final totalDead = await _sumMortality(farmId, batchId);
      final fcr = await _batchFcr(farmId, batch, totalFeed: totalFeed, totalEggs: totalEggs);
      final mortalityRate = calculateMortalityRatePercentage(
        totalDeadBirds: totalDead,
        initialPopulation: initialCount,
      );
      final finance = financeByBatch[batchId];
      final operating = (finance?.operating ?? 0) + (finance?.consumption ?? 0);
      final direct = finance?.initial ?? 0;
      final allocated = finance?.general ?? 0;

      reports.add(
        BatchPerformanceReport(
          id: batchId,
          name: _batchLabel(batch),
          status: batch['status']?.toString().toLowerCase() ?? 'unknown',
          type: batch['type']?.toString() ?? '',
          houseName: houseNames[batch['house_id']?.toString()] ?? 'Unassigned',
          initialCount: initialCount,
          currentCount: currentCount,
          totalFeed: totalFeed,
          totalEggs: totalEggs,
          totalDead: totalDead,
          fcr: fcr,
          mortalityRate: mortalityRate,
          initialInvestment: direct,
          directExpenses: finance?.operating ?? 0,
          allocatedExpenses: allocated,
          operatingExpenses: operating,
          consumptionShare: finance?.consumption ?? 0,
          generalShare: allocated,
          totalExpenses: finance?.totalExpense ?? 0,
          totalRevenue: finance?.revenue ?? 0,
          netProfitability: finance?.netProfit ?? 0,
        ),
      );
    }

    return BatchPerformancePayload(batches: reports, canViewFinance: canViewFinance);
  }

  Future<double> _batchFcr(
    String farmId,
    Map<String, Object?> batch, {
    required double totalFeed,
    required int totalEggs,
  }) async {
    if (totalFeed <= 0) return 0;
    final type = batch['type']?.toString().toUpperCase() ?? '';
    if (type.contains('LAYER')) {
      return calculateFeedConversionRatio(
        livestockType: type,
        totalFeed: totalFeed,
        eggOutput: totalEggs,
        birdBiomassGain: 0,
      );
    }

    final batchId = batch['id']?.toString() ?? '';
    final weights = await _db.queryLocalRecords(
      'weight_records',
      where: 'farm_id = ? and batch_id = ?',
      whereArgs: [farmId, batchId],
      orderBy: 'log_date asc',
    );
    if (weights.isEmpty) return 0;
    final initialWeight = _double(weights.first['average_weight']);
    final latestWeight = _double(weights.last['average_weight']);
    final biomassGain = calculateBatchBiomassGain(
      initialAverageWeight: initialWeight,
      latestAverageWeight: latestWeight,
      currentBirdCount: _int(batch['current_count']),
    );
    return calculateFeedConversionRatio(
      livestockType: type,
      totalFeed: totalFeed,
      eggOutput: 0,
      birdBiomassGain: biomassGain,
    );
  }

  Future<double> _sumFeed(String farmId, String batchId) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum(amount_consumed), 0) as total from daily_feeding_logs '
      'where farm_id = ? and batch_id = ? and is_deleted = 0',
      [farmId, batchId],
    );
    return _double(rows.first['total']);
  }

  Future<int> _sumEggs(String farmId, String batchId) async {
    final rows = await _db.rawLocalQuery(
      'select coalesce(sum(eggs_collected), 0) as total from egg_production '
      'where farm_id = ? and batch_id = ? and is_deleted = 0',
      [farmId, batchId],
    );
    return _int(rows.first['total']);
  }

  Future<int> _sumMortality(String farmId, String batchId) async {
    final rows = await _db.rawLocalQuery(
      "select coalesce(sum(count), 0) as total from mortality "
      "where farm_id = ? and batch_id = ? and is_deleted = 0 and upper(type) = 'DEAD'",
      [farmId, batchId],
    );
    return _int(rows.first['total']);
  }
}

double calculateFeedConversionRatio({
  required String livestockType,
  required double totalFeed,
  required int eggOutput,
  required double birdBiomassGain,
}) {
  final isLayer = livestockType.toUpperCase().contains('LAYER');
  final denominator = isLayer ? eggOutput.toDouble() : birdBiomassGain;
  if (denominator <= 0 || totalFeed <= 0) return 0;
  return _roundMetric(totalFeed / denominator);
}

double calculateMortalityRatePercentage({
  required int totalDeadBirds,
  required int initialPopulation,
}) {
  if (initialPopulation <= 0) return 0;
  return _roundMetric((totalDeadBirds / initialPopulation) * 100);
}

double calculateBatchBiomassGain({
  required double initialAverageWeight,
  required double latestAverageWeight,
  required int currentBirdCount,
}) {
  final gainPerBird = math.max(0.0, latestAverageWeight - initialAverageWeight);
  return _roundMetric(gainPerBird * currentBirdCount.toDouble(), decimals: 3);
}

String _batchLabel(Map<String, Object?> batch) {
  final name = batch['batch_name']?.toString().trim();
  if (name != null && name.isNotEmpty) return name;
  final localId = batch['local_batch_id']?.toString();
  if (localId != null && localId.isNotEmpty) return 'Batch $localId';
  return 'Batch ${batch['id']}';
}

double _roundMetric(double value, {int decimals = 2}) {
  if (!value.isFinite) return 0;
  final factor = math.pow(10, decimals).toDouble();
  return (value * factor).roundToDouble() / factor;
}

int _int(Object? value) {
  if (value == null) return 0;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? 0;
}

double _double(Object? value) {
  if (value == null) return 0;
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString()) ?? 0;
}

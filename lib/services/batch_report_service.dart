import '../core/permissions/farm_permissions.dart';
import '../core/storage/local_database.dart';

enum BatchReportDurationPreset {
  lifetime,
  today,
  weekly,
  monthly,
  custom,
}

enum BatchReportSection {
  feed,
  mortality,
  eggs,
  health,
  finance,
  sales,
  expenses,
}

class BatchReportDateRange {
  const BatchReportDateRange({
    required this.start,
    required this.end,
    required this.label,
  });

  final DateTime start;
  final DateTime end;
  final String label;
}

class BatchReportLogEntry {
  const BatchReportLogEntry({
    required this.date,
    required this.type,
    required this.title,
    required this.detail,
    this.amount,
  });

  final DateTime date;
  final String type;
  final String title;
  final String detail;
  final double? amount;
}

class BatchReportDocument {
  const BatchReportDocument({
    required this.batchName,
    required this.breed,
    required this.house,
    required this.status,
    required this.periodLabel,
    required this.generatedAt,
    required this.sections,
    required this.currentCount,
    required this.initialCount,
    required this.ageInDays,
    required this.totalFeed,
    required this.totalEggs,
    required this.totalMortality,
    required this.mortalityRate,
    required this.entries,
    this.totalRevenue,
    this.totalExpenses,
    this.netProfit,
  });

  final String batchName;
  final String breed;
  final String house;
  final String status;
  final String periodLabel;
  final String generatedAt;
  final List<BatchReportSection> sections;
  final int currentCount;
  final int initialCount;
  final int ageInDays;
  final double totalFeed;
  final int totalEggs;
  final int totalMortality;
  final double mortalityRate;
  final List<BatchReportLogEntry> entries;
  final double? totalRevenue;
  final double? totalExpenses;
  final double? netProfit;
}

class BatchReportBatchOption {
  const BatchReportBatchOption({
    required this.id,
    required this.batchName,
    required this.breed,
    required this.houseName,
    required this.status,
    required this.arrivalDate,
    required this.initialCount,
    required this.currentCount,
  });

  final String id;
  final String batchName;
  final String breed;
  final String houseName;
  final String status;
  final DateTime arrivalDate;
  final int initialCount;
  final int currentCount;
}

/// Offline-first batch report builder — mirrors web BatchReportWizard sections.
class BatchReportService {
  BatchReportService(this._db);

  final LocalDatabase _db;

  static List<BatchReportSection> sectionsForPermissions(
    FarmPermissions permissions,
  ) {
    final sections = <BatchReportSection>[];
    if (permissions.canViewFeeding) {
      sections.add(BatchReportSection.feed);
    }
    if (permissions.canViewMortality) {
      sections.add(BatchReportSection.mortality);
    }
    if (permissions.canViewEggs) {
      sections.add(BatchReportSection.eggs);
    }
    if (permissions.canViewHealth) {
      sections.add(BatchReportSection.health);
    }
    if (permissions.canViewFinance || permissions.canViewSales) {
      sections.add(BatchReportSection.finance);
      sections.add(BatchReportSection.sales);
      sections.add(BatchReportSection.expenses);
    }
    return sections;
  }

  Future<List<BatchReportBatchOption>> loadActiveBatches(String farmId) async {
    final rows = await _db.rawLocalQuery(
      '''
      select b.id,
             b.batch_name,
             b.breed_type,
             b.status,
             b.arrival_date,
             b.initial_count,
             b.current_count,
             h.name as house_name
      from batches b
      left join houses h on h.id = b.house_id
      where b.farm_id = ?
        and coalesce(b.is_deleted, 0) = 0
        and lower(coalesce(b.status, '')) = 'active'
      order by b.batch_name asc
      ''',
      [farmId],
    );
    return rows
        .map(
          (row) => BatchReportBatchOption(
            id: row['id']?.toString() ?? '',
            batchName: row['batch_name']?.toString() ?? 'Batch',
            breed: row['breed_type']?.toString() ?? '—',
            houseName: row['house_name']?.toString() ?? '—',
            status: row['status']?.toString() ?? 'ACTIVE',
            arrivalDate: DateTime.tryParse(row['arrival_date']?.toString() ?? '') ??
                DateTime.now(),
            initialCount: _asInt(row['initial_count']),
            currentCount: _asInt(row['current_count']),
          ),
        )
        .where((batch) => batch.id.isNotEmpty)
        .toList(growable: false);
  }

  BatchReportDateRange resolveDateRange({
    required BatchReportDurationPreset preset,
    required DateTime batchArrivalDate,
    DateTime? customStart,
    DateTime? customEnd,
  }) {
    final now = DateTime.now();
    final end = DateTime(now.year, now.month, now.day, 23, 59, 59, 999);

    switch (preset) {
      case BatchReportDurationPreset.today:
        final start = DateTime(now.year, now.month, now.day);
        return BatchReportDateRange(start: start, end: end, label: 'Today');
      case BatchReportDurationPreset.weekly:
        final start = DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
        return BatchReportDateRange(start: start, end: end, label: 'Last 7 days');
      case BatchReportDurationPreset.monthly:
        final start = DateTime(now.year, now.month, 1);
        return BatchReportDateRange(
          start: start,
          end: end,
          label: 'This month',
        );
      case BatchReportDurationPreset.custom:
        final start = customStart ?? DateTime(now.year, now.month, now.day);
        final customEndDate =
            customEnd ?? DateTime(now.year, now.month, now.day, 23, 59, 59);
        return BatchReportDateRange(
          start: DateTime(start.year, start.month, start.day),
          end: DateTime(
            customEndDate.year,
            customEndDate.month,
            customEndDate.day,
            23,
            59,
            59,
          ),
          label: 'Custom range',
        );
      case BatchReportDurationPreset.lifetime:
        final start = DateTime(
          batchArrivalDate.year,
          batchArrivalDate.month,
          batchArrivalDate.day,
        );
        return BatchReportDateRange(start: start, end: end, label: 'Lifetime');
    }
  }

  Future<BatchReportDocument> buildReport({
    required String farmId,
    required BatchReportBatchOption batch,
    required BatchReportDateRange range,
    required List<BatchReportSection> sections,
    required FarmPermissions permissions,
  }) async {
    final entries = <BatchReportLogEntry>[];
    var totalFeed = 0.0;
    var totalEggs = 0;
    var totalMortality = 0;
    double totalRevenue = 0;
    double totalExpenses = 0;

    if (sections.contains(BatchReportSection.feed)) {
      final rows = await _db.rawLocalQuery(
        '''
        select log_date, amount_consumed, feed_type_label
        from daily_feeding_logs
        where farm_id = ? and batch_id = ? and coalesce(is_deleted, 0) = 0
        order by log_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in rows) {
        final date = DateTime.tryParse(row['log_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        final amount = _asDouble(row['amount_consumed']);
        totalFeed += amount;
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'FEED',
            title: 'Feed log',
            detail:
                '${amount.toStringAsFixed(2)} bags — ${row['feed_type_label'] ?? 'Feed'}',
          ),
        );
      }
    }

    if (sections.contains(BatchReportSection.eggs)) {
      final rows = await _db.rawLocalQuery(
        '''
        select log_date, eggs_collected, unusable_count
        from egg_production
        where farm_id = ? and batch_id = ? and coalesce(is_deleted, 0) = 0
        order by log_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in rows) {
        final date = DateTime.tryParse(row['log_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        final eggs = _asInt(row['eggs_collected']);
        totalEggs += eggs;
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'EGGS',
            title: 'Egg collection',
            detail:
                '$eggs eggs (${_asInt(row['unusable_count'])} damaged)',
          ),
        );
      }
    }

    if (sections.contains(BatchReportSection.mortality)) {
      final rows = await _db.rawLocalQuery(
        '''
        select log_date, count, type, reason, sub_category
        from mortality
        where farm_id = ? and batch_id = ? and coalesce(is_deleted, 0) = 0
        order by log_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in rows) {
        final date = DateTime.tryParse(row['log_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        final count = _asInt(row['count']);
        final type = row['type']?.toString().toUpperCase() ?? 'DEAD';
        if (type == 'DEAD') {
          totalMortality += count;
        }
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'MORTALITY',
            title: type == 'SICK' ? 'Quarantine' : 'Mortality',
            detail:
                '$count birds — ${row['sub_category'] ?? row['reason'] ?? 'Recorded'}',
          ),
        );
      }
    }

    if (sections.contains(BatchReportSection.health)) {
      final vaccineRows = await _db.rawLocalQuery(
        '''
        select scheduled_date, vaccine_name, status, notes
        from vaccination_schedules
        where farm_id = ? and batch_id = ?
        order by scheduled_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in vaccineRows) {
        final date =
            DateTime.tryParse(row['scheduled_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'HEALTH',
            title: 'Vaccination',
            detail:
                '${row['vaccine_name'] ?? 'Vaccine'} — ${row['status'] ?? 'PENDING'}',
          ),
        );
      }

      final medicineRows = await _db.rawLocalQuery(
        '''
        select scheduled_date, medication_name, status, notes
        from medication_schedules
        where farm_id = ? and batch_id = ?
        order by scheduled_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in medicineRows) {
        final date =
            DateTime.tryParse(row['scheduled_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'HEALTH',
            title: 'Medication',
            detail:
                '${row['medication_name'] ?? 'Medicine'} — ${row['status'] ?? 'PENDING'}',
          ),
        );
      }
    }

    if (permissions.canViewSales &&
        (sections.contains(BatchReportSection.sales) ||
            sections.contains(BatchReportSection.finance))) {
      final rows = await _db.rawLocalQuery(
        '''
        select sale_date, total_amount, customer_name
        from sales
        where farm_id = ? and batch_id = ? and coalesce(is_deleted, 0) = 0
        order by sale_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in rows) {
        final date = DateTime.tryParse(row['sale_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        final amount = _asDouble(row['total_amount']);
        totalRevenue += amount;
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'SALES',
            title: 'Sale',
            detail: row['customer_name']?.toString() ?? 'Customer',
            amount: amount,
          ),
        );
      }
    }

    if (permissions.canViewFinance &&
        (sections.contains(BatchReportSection.expenses) ||
            sections.contains(BatchReportSection.finance))) {
      final rows = await _db.rawLocalQuery(
        '''
        select expense_date, amount, category, description
        from expenses
        where farm_id = ? and batch_id = ? and coalesce(is_deleted, 0) = 0
        order by expense_date desc
        ''',
        [farmId, batch.id],
      );
      for (final row in rows) {
        final date = DateTime.tryParse(row['expense_date']?.toString() ?? '');
        if (date == null || !_inRange(date, range)) {
          continue;
        }
        final amount = _asDouble(row['amount']);
        totalExpenses += amount;
        entries.add(
          BatchReportLogEntry(
            date: date,
            type: 'EXPENSE',
            title: row['category']?.toString() ?? 'Expense',
            detail: row['description']?.toString() ?? '',
            amount: amount,
          ),
        );
      }
    }

    entries.sort((a, b) => b.date.compareTo(a.date));
    final mortalityRate = batch.initialCount > 0
        ? (totalMortality / batch.initialCount) * 100
        : 0.0;
    final ageInDays = DateTime.now().difference(batch.arrivalDate).inDays;

    return BatchReportDocument(
      batchName: batch.batchName,
      breed: batch.breed,
      house: batch.houseName,
      status: batch.status.toUpperCase(),
      periodLabel: range.label,
      generatedAt: DateTime.now().toLocal().toString(),
      sections: sections,
      currentCount: batch.currentCount,
      initialCount: batch.initialCount,
      ageInDays: ageInDays,
      totalFeed: totalFeed,
      totalEggs: totalEggs,
      totalMortality: totalMortality,
      mortalityRate: mortalityRate,
      entries: entries,
      totalRevenue: sections.contains(BatchReportSection.finance)
          ? totalRevenue
          : null,
      totalExpenses: sections.contains(BatchReportSection.finance)
          ? totalExpenses
          : null,
      netProfit: sections.contains(BatchReportSection.finance)
          ? totalRevenue - totalExpenses
          : null,
    );
  }

  Future<BatchReportDocument> buildCombinedReport({
    required String farmId,
    required List<BatchReportBatchOption> batches,
    required BatchReportDateRange range,
    required List<BatchReportSection> sections,
    required FarmPermissions permissions,
  }) async {
    final reports = <BatchReportDocument>[];
    for (final batch in batches) {
      reports.add(
        await buildReport(
          farmId: farmId,
          batch: batch,
          range: range,
          sections: sections,
          permissions: permissions,
        ),
      );
    }

    final entries = <BatchReportLogEntry>[];
    var totalFeed = 0.0;
    var totalEggs = 0;
    var totalMortality = 0;
    var totalRevenue = 0.0;
    var totalExpenses = 0.0;
    var currentCount = 0;
    var initialCount = 0;
    var maxAge = 0;

    for (final report in reports) {
      currentCount += report.currentCount;
      initialCount += report.initialCount;
      maxAge = maxAge < report.ageInDays ? report.ageInDays : maxAge;
      totalFeed += report.totalFeed;
      totalEggs += report.totalEggs;
      totalMortality += report.totalMortality;
      totalRevenue += report.totalRevenue ?? 0;
      totalExpenses += report.totalExpenses ?? 0;
      entries.addAll(
        report.entries.map(
          (entry) => BatchReportLogEntry(
            date: entry.date,
            type: entry.type,
            title: '[${report.batchName}] ${entry.title}',
            detail: entry.detail,
            amount: entry.amount,
          ),
        ),
      );
    }

    entries.sort((a, b) => b.date.compareTo(a.date));
    final mortalityRate =
        initialCount > 0 ? (totalMortality / initialCount) * 100 : 0.0;

    return BatchReportDocument(
      batchName: 'All batches (${batches.length})',
      breed: '${batches.length} livestock units',
      house: 'Multiple houses',
      status: 'COMBINED',
      periodLabel: range.label,
      generatedAt: DateTime.now().toLocal().toString(),
      sections: sections,
      currentCount: currentCount,
      initialCount: initialCount,
      ageInDays: maxAge,
      totalFeed: totalFeed,
      totalEggs: totalEggs,
      totalMortality: totalMortality,
      mortalityRate: mortalityRate,
      entries: entries,
      totalRevenue:
          sections.contains(BatchReportSection.finance) ? totalRevenue : null,
      totalExpenses:
          sections.contains(BatchReportSection.finance) ? totalExpenses : null,
      netProfit: sections.contains(BatchReportSection.finance)
          ? totalRevenue - totalExpenses
          : null,
    );
  }

  bool _inRange(DateTime date, BatchReportDateRange range) {
    return !date.isBefore(range.start) && !date.isAfter(range.end);
  }

  int _asInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
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

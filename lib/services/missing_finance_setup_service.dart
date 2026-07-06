import '../core/storage/local_database.dart';

class MissingCostBatch {
  const MissingCostBatch({
    required this.id,
    required this.batchName,
    required this.initialCount,
    required this.type,
  });

  final String id;
  final String batchName;
  final int initialCount;
  final String type;
}

class MissingCostHealthItem {
  const MissingCostHealthItem({
    required this.id,
    required this.itemName,
    required this.unit,
    required this.stockLevel,
    required this.kind,
  });

  final String id;
  final String itemName;
  final String unit;
  final double stockLevel;
  final String kind;
}

/// Detects batches and health stock missing cost data (mirrors web finance page).
class MissingFinanceSetupService {
  MissingFinanceSetupService(this._db);

  final LocalDatabase _db;

  static const _vaccineCategories = {'VACCINE', 'VACCINATION', 'VACCINES'};
  static const _healthCategories = {
    'VACCINE',
    'VACCINATION',
    'VACCINES',
    'MEDICATION',
    'MEDICINE',
    'MEDICATIONS',
    'VETERINARY',
    'HEALTH',
  };

  Future<List<MissingCostBatch>> loadBatchesMissingCost(String farmId) async {
    final rows = await _db.queryLocalRecords(
      'batches',
      where:
          "farm_id = ? and is_deleted = 0 and upper(status) = 'ACTIVE' "
          'and (initial_cost_actual is null or initial_cost_actual = 0)',
      whereArgs: [farmId],
      orderBy: 'batch_name asc',
    );
    return rows
        .map(
          (row) => MissingCostBatch(
            id: row['id']?.toString() ?? '',
            batchName: row['batch_name']?.toString() ?? 'Batch',
            initialCount: _int(row['initial_count']),
            type: row['type']?.toString() ?? '',
          ),
        )
        .where((batch) => batch.id.isNotEmpty)
        .toList();
  }

  Future<List<MissingCostHealthItem>> loadHealthItemsMissingCost(
    String farmId,
  ) async {
    final rows = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'item_name asc',
    );
    return rows
        .where((row) {
          final category = row['category']?.toString().toUpperCase() ?? '';
          if (!_healthCategories.contains(category)) {
            return false;
          }
          final cost = row['cost_per_unit'];
          return cost == null || _double(cost) <= 0;
        })
        .map(
          (row) {
            final category = row['category']?.toString().toUpperCase() ?? '';
            return MissingCostHealthItem(
              id: row['id']?.toString() ?? '',
              itemName: row['item_name']?.toString() ?? 'Health item',
              unit: row['unit']?.toString() ?? 'units',
              stockLevel: _double(row['stock_level']),
              kind: _vaccineCategories.contains(category)
                  ? 'VACCINE'
                  : 'MEDICATION',
            );
          },
        )
        .where((item) => item.id.isNotEmpty)
        .toList();
  }

  double _double(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  int _int(Object? value) {
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }
}

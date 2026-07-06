import 'dart:async';
import 'dart:math';

import '../../../core/storage/local_database.dart';
import 'livestock_models.dart';

class LivestockRepository {
  LivestockRepository(this._db);

  final LocalDatabase _db;

  LocalDatabase get database => _db;

  Stream<void> watchBatches(String farmId) {
    return _db.watchTables(const ['batches', 'houses']);
  }

  Future<List<LivestockBatchRecord>> loadBatches(String farmId) async {
    if (farmId.isEmpty) {
      return const [];
    }
    final houseNames = await _houseNameMap(farmId);
    final rows = await _db.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and coalesce(is_deleted, 0) = 0',
      whereArgs: [farmId],
      orderBy: 'created_at desc',
    );
    return rows
        .map(
          (row) => LivestockBatchRecord.fromMap(
            row,
            houseName: houseNames[row['house_id']?.toString()] ?? '',
          ),
        )
        .where((batch) => batch.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<List<HouseOption>> loadHouses(String farmId) async {
    if (farmId.isEmpty) {
      return const [];
    }
    final rows = await _db.queryLocalRecords(
      'houses',
      where: 'farm_id = ? and coalesce(is_deleted, 0) = 0',
      whereArgs: [farmId],
      orderBy: 'name asc',
    );
    return rows
        .map(
          (row) => HouseOption(
            id: row['id']?.toString() ?? '',
            name: row['name']?.toString() ?? 'House',
            capacity: _int(row['capacity']),
          ),
        )
        .where((house) => house.id.isNotEmpty)
        .toList(growable: false);
  }

  Future<Map<String, Object?>> insertBatchLocal({
    required String id,
    required String farmId,
    required String userId,
    required CreateLivestockDraft draft,
  }) async {
    final now = DateTime.now().toIso8601String();
    final row = <String, Object?>{
      'id': id,
      'farm_id': farmId,
      'house_id': draft.houseId,
      'user_id': userId,
      'batch_name': draft.batchName.trim(),
      'breed_type': draft.breedKey,
      'bird_strain': draft.breedKey,
      'type': draft.type,
      'status': 'active',
      'active_state': 'active',
      'initial_count': draft.initialCount,
      'current_count': draft.initialCount,
      'isolation_count': 0,
      'arrival_date': draft.arrivalDate.toIso8601String(),
      'initial_cost_actual': 0,
      'initial_cost_carriage': 0,
      'initial_cost_other': 0,
      'growth_target_override': '',
      'is_deleted': 0,
      'is_synced': 0,
      'created_at': now,
      'updated_at': now,
    };
    await _db.insertLocalRecord('batches', row);
    return row;
  }

  Future<void> updateBatchLocal({
    required String batchId,
    required UpdateLivestockDraft draft,
    int? syncedCurrentCount,
  }) async {
    final existing = await _loadBatchRow(batchId);
    if (existing == null) {
      throw StateError('Batch not found');
    }
    final existingInitial = _int(existing['initial_count']);
    final existingCurrent = _int(existing['current_count']);
    var nextCurrent = syncedCurrentCount ?? existingCurrent;
    if (draft.initialCount != existingInitial) {
      final diff = draft.initialCount - existingInitial;
      nextCurrent = existingCurrent + diff;
      if (nextCurrent < 0) {
        nextCurrent = 0;
      }
    }

    await _db.updateLocalRecord(
      'batches',
      {
        'batch_name': draft.batchName.trim(),
        'breed_type': draft.breedKey,
        'bird_strain': draft.breedKey,
        'type': draft.type,
        'house_id': draft.houseId,
        'initial_count': draft.initialCount,
        'current_count': nextCurrent,
        'status': draft.status,
        'active_state': draft.status,
        'arrival_date': draft.arrivalDate.toIso8601String(),
        'growth_target_override': draft.growthTargetOverride.trim(),
        'updated_at': DateTime.now().toIso8601String(),
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<void> softDeleteBatchLocal({
    required String batchId,
    required String reason,
  }) async {
    await _db.updateLocalRecord(
      'batches',
      {
        'is_deleted': 1,
        'deleted_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
        'status': 'deleted',
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<void> updateFinancialsLocal({
    required String batchId,
    required double actualCost,
    required double carriageCost,
  }) async {
    await _db.updateLocalRecord(
      'batches',
      {
        'initial_cost_actual': actualCost,
        'initial_cost_carriage': carriageCost,
        'updated_at': DateTime.now().toIso8601String(),
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<void> applyIsolationRecoveryLocal({
    required String batchId,
    required int count,
  }) async {
    final row = await _loadBatchRow(batchId);
    if (row == null) {
      throw StateError('Batch not found');
    }
    final current = _int(row['current_count']);
    final isolation = _int(row['isolation_count']);
    if (isolation < count) {
      throw StateError('Not enough birds in isolation to recover');
    }
    await _db.updateLocalRecord(
      'batches',
      {
        'current_count': current + count,
        'isolation_count': isolation - count,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<void> applyIsolationMortalityLocal({
    required String batchId,
    required int count,
  }) async {
    final row = await _loadBatchRow(batchId);
    if (row == null) {
      throw StateError('Batch not found');
    }
    final isolation = _int(row['isolation_count']);
    if (isolation < count) {
      throw StateError('Not enough birds in isolation');
    }
    await _db.updateLocalRecord(
      'batches',
      {
        'isolation_count': isolation - count,
        'updated_at': DateTime.now().toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<List<BatchActivityEntry>> loadRecentActivity({
    required String farmId,
    required String batchId,
    int limit = 12,
  }) async {
    final entries = <BatchActivityEntry>[];

    final eggs = await _db.queryLocalRecords(
      'egg_production',
      where: 'farm_id = ? and batch_id = ? and is_deleted = 0',
      whereArgs: [farmId, batchId],
      orderBy: 'log_date desc',
      limit: limit,
    );
    for (final row in eggs) {
      entries.add(
        BatchActivityEntry(
          kind: 'Eggs',
          summary: '${_int(row['eggs_collected'])} eggs collected',
          logDate: _parseDate(row['log_date']),
        ),
      );
    }

    final feed = await _db.queryLocalRecords(
      'daily_feeding_logs',
      where: 'farm_id = ? and batch_id = ? and is_deleted = 0',
      whereArgs: [farmId, batchId],
      orderBy: 'log_date desc',
      limit: limit,
    );
    for (final row in feed) {
      entries.add(
        BatchActivityEntry(
          kind: 'Feed',
          summary: '${_double(row['amount_consumed']).toStringAsFixed(1)} consumed',
          logDate: _parseDate(row['log_date']),
        ),
      );
    }

    final mortality = await _db.queryLocalRecords(
      'mortality',
      where: 'farm_id = ? and batch_id = ? and is_deleted = 0',
      whereArgs: [farmId, batchId],
      orderBy: 'log_date desc',
      limit: limit,
    );
    for (final row in mortality) {
      final type = row['type']?.toString().toUpperCase() ?? 'DEAD';
      entries.add(
        BatchActivityEntry(
          kind: type == 'SICK' ? 'Sick' : 'Mortality',
          summary: '${_int(row['count'])} birds — ${row['category'] ?? 'Logged'}',
          logDate: _parseDate(row['log_date']),
        ),
      );
    }

    entries.sort((a, b) => b.logDate.compareTo(a.logDate));
    return entries.take(limit).toList(growable: false);
  }

  Future<Map<String, String>> _houseNameMap(String farmId) async {
    final rows = await _db.queryLocalRecords(
      'houses',
      where: 'farm_id = ? and coalesce(is_deleted, 0) = 0',
      whereArgs: [farmId],
    );
    return {
      for (final row in rows)
        if (row['id'] != null) row['id']!.toString(): row['name']?.toString() ?? '',
    };
  }

  Future<void> markBatchSynced(String batchId) async {
    await _db.updateLocalRecord(
      'batches',
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [batchId],
    );
  }

  Future<Map<String, Object?>?> _loadBatchRow(String batchId) async {
    final rows = await _db.queryLocalRecords(
      'batches',
      where: 'id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first;
  }

  DateTime _parseDate(Object? value) {
    return DateTime.tryParse(value?.toString() ?? '') ?? DateTime.now();
  }
}

String newLivestockId(String prefix) {
  final random = Random.secure();
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$suffix';
}

int _int(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

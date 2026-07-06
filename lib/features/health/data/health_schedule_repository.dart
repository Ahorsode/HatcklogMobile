import 'dart:math';

import '../../../core/storage/local_database.dart';
import '../../../services/health_inventory_service.dart';
import '../../../utils/health_constants.dart';
import '../../inventory/data/inventory_repository.dart';

class HealthScheduleEntry {
  const HealthScheduleEntry({
    required this.kind,
    required this.batchId,
    required this.name,
    required this.scheduledDate,
    this.status = 'PENDING',
    this.usageType = HealthUsageType.oneTime,
    this.quantity = 1,
    this.unit = 'dose',
    this.notes,
    this.isNewItem = false,
    this.inventoryId,
  });

  final HealthScheduleKind kind;
  final String batchId;
  final String name;
  final DateTime scheduledDate;
  final String status;
  final HealthUsageType usageType;
  final double quantity;
  final String unit;
  final String? notes;
  final bool isNewItem;
  final String? inventoryId;
}

class HealthInventoryOption {
  const HealthInventoryOption({
    required this.id,
    required this.itemName,
    required this.stockLevel,
    required this.unit,
    this.usageType,
    this.category,
  });

  final String id;
  final String itemName;
  final double stockLevel;
  final String unit;
  final String? usageType;
  final String? category;
}

class HealthSchedulesSnapshot {
  const HealthSchedulesSnapshot({
    required this.vaccinations,
    required this.medications,
    required this.pendingCount,
  });

  final List<Map<String, Object?>> vaccinations;
  final List<Map<String, Object?>> medications;
  final int pendingCount;
}

class HealthScheduleRepository {
  HealthScheduleRepository(
    this._db, {
    InventoryRepository? inventoryRepository,
    HealthInventoryService? healthInventoryService,
  }) : _inventoryRepository =
           inventoryRepository ?? InventoryRepository(_db),
       _healthInventoryService =
           healthInventoryService ?? HealthInventoryService(_db);

  final LocalDatabase _db;
  final InventoryRepository _inventoryRepository;
  final HealthInventoryService _healthInventoryService;

  Future<HealthSchedulesSnapshot> loadSchedules(String farmId) async {
    final vaccinations = await _db.queryLocalRecords(
      'vaccination_schedules',
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'scheduled_date asc',
    );
    final medications = await _db.queryLocalRecords(
      'medication_schedules',
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'scheduled_date asc',
    );
    final pendingCount = [
      ...vaccinations,
      ...medications,
    ].where((row) => (row['status']?.toString().toUpperCase() ?? '') == 'PENDING').length;

    return HealthSchedulesSnapshot(
      vaccinations: vaccinations,
      medications: medications,
      pendingCount: pendingCount,
    );
  }

  Future<List<Map<String, Object?>>> loadActiveBatches(String farmId) async {
    return _db.queryLocalRecords(
      'batches',
      where: "farm_id = ? and is_deleted = 0 and upper(status) = 'ACTIVE'",
      whereArgs: [farmId],
      orderBy: 'batch_name asc',
    );
  }

  Future<({List<HealthInventoryOption> vaccine, List<HealthInventoryOption> medicine})>
  loadHealthInventory(String farmId) async {
    final rows = await _inventoryRepository.getAllInventory(
      farmId: farmId,
      filter: InventoryFilter.active,
    );

    final vaccine = <HealthInventoryOption>[];
    final medicine = <HealthInventoryOption>[];
    for (final row in rows) {
      final category = row['category']?.toString() ?? '';
      if (!isHealthInventoryCategory(category)) {
        continue;
      }
      final option = HealthInventoryOption(
        id: row['id']?.toString() ?? '',
        itemName: row['item_name']?.toString() ?? '',
        stockLevel: _double(row['stock_level']),
        unit: row['unit']?.toString() ?? 'dose',
        usageType: row['usage_type']?.toString(),
        category: category,
      );
      if (isVaccineCategory(category)) {
        vaccine.add(option);
      } else {
        medicine.add(option);
      }
    }

    vaccine.sort((a, b) => a.itemName.compareTo(b.itemName));
    medicine.sort((a, b) => a.itemName.compareTo(b.itemName));
    return (vaccine: vaccine, medicine: medicine);
  }

  Future<void> createSchedulesBulk({
    required String farmId,
    required List<HealthScheduleEntry> entries,
  }) async {
    if (entries.isEmpty) {
      throw StateError('Add at least one vaccine or medication.');
    }

    for (final entry in entries) {
      await _assertBatchOwned(farmId, entry.batchId);
      final name = entry.name.trim();
      if (name.isEmpty) {
        throw StateError('A name is required.');
      }

      String? inventoryId = entry.inventoryId;
      if (entry.isNewItem) {
        inventoryId = await _registerInventoryItem(farmId, entry);
      } else {
        final validation = await _healthInventoryService.validateScheduleItem(
          farmId: farmId,
          inventoryId: inventoryId,
          itemName: name,
        );
        if (validation != null) {
          throw StateError(validation);
        }
      }

      final table = entry.kind == HealthScheduleKind.vaccination
          ? 'vaccination_schedules'
          : 'medication_schedules';
      final id = _newId(table);
      final row = <String, Object?>{
        'id': id,
        'batch_id': entry.batchId,
        'farm_id': farmId,
        'scheduled_date': entry.scheduledDate.toIso8601String(),
        'status': entry.status.toUpperCase(),
        'notes': entry.notes,
        'inventory_id': inventoryId,
        'quantity': entry.usageType == HealthUsageType.oneTime
            ? 1
            : entry.quantity,
        'usage_type': healthUsageTypeDbValue(entry.usageType),
        'unit': entry.unit,
        'is_synced': 0,
      };
      if (entry.kind == HealthScheduleKind.vaccination) {
        row['vaccine_name'] = name;
      } else {
        row['medication_name'] = name;
      }

      await _db.insertLocalRecord(table, row);

      if (isHealthScheduleCompleted(entry.status)) {
        await _healthInventoryService.applyScheduleStatusChange(
          farmId: farmId,
          inventoryId: inventoryId,
          itemName: name,
          previousStatus: 'PENDING',
          newStatus: entry.status,
          quantity: entry.usageType == HealthUsageType.oneTime
              ? 1
              : entry.quantity,
        );
      }
    }
  }

  Future<void> updateScheduleStatus({
    required String farmId,
    required HealthScheduleKind kind,
    required String id,
    required String status,
  }) async {
    final table = kind == HealthScheduleKind.vaccination
        ? 'vaccination_schedules'
        : 'medication_schedules';
    final rows = await _db.queryLocalRecords(
      table,
      where: 'id = ? and farm_id = ?',
      whereArgs: [id, farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Schedule not found.');
    }

    final schedule = rows.first;
    final previousStatus = schedule['status']?.toString() ?? 'PENDING';
    final nextStatus = status.toUpperCase();
    final itemName =
        schedule['vaccine_name']?.toString() ??
        schedule['medication_name']?.toString() ??
        '';

    if (nextStatus == 'COMPLETED' &&
        !isHealthScheduleCompleted(previousStatus)) {
      final validation = await _healthInventoryService.validateScheduleItem(
        farmId: farmId,
        inventoryId: schedule['inventory_id']?.toString(),
        itemName: itemName,
      );
      if (validation != null) {
        throw StateError(validation);
      }
    }

    await _healthInventoryService.applyScheduleStatusChange(
      farmId: farmId,
      inventoryId: schedule['inventory_id']?.toString(),
      itemName: itemName,
      previousStatus: previousStatus,
      newStatus: nextStatus,
      quantity: _double(schedule['quantity'], fallback: 1),
    );

    await _db.updateLocalRecord(
      table,
      {
        'status': nextStatus,
        'is_synced': 0,
      },
      where: 'id = ? and farm_id = ?',
      whereArgs: [id, farmId],
    );
  }

  Future<void> deleteSchedule({
    required String farmId,
    required HealthScheduleKind kind,
    required String id,
  }) async {
    final table = kind == HealthScheduleKind.vaccination
        ? 'vaccination_schedules'
        : 'medication_schedules';
    await _db.rawLocalQuery('delete from $table where id = ? and farm_id = ?', [
      id,
      farmId,
    ]);
  }

  Future<String> _registerInventoryItem(
    String farmId,
    HealthScheduleEntry entry,
  ) async {
    final name = entry.name.trim();
    final existing = await _db.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
    );
    for (final row in existing) {
      if (_namesMatch(row['item_name'], name)) {
        return row['id']?.toString() ?? '';
      }
    }

    final id = _newId('inv');
    final category = entry.kind == HealthScheduleKind.vaccination
        ? 'VACCINE'
        : 'MEDICINE';
    final item = <String, Object?>{
      'id': id,
      'farm_id': farmId,
      'item_name': name,
      'stock_level': entry.usageType == HealthUsageType.oneTime
          ? 1
          : entry.quantity,
      'unit': entry.unit,
      'category': category,
      'usage_type': healthUsageTypeDbValue(entry.usageType),
      'cost_per_unit': null,
      'is_deleted': 0,
      'is_synced': 0,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    };
    await _healthInventoryService.normalizeOneTimeStockOnSave(item);
    await _db.insertLocalRecord('inventory', item);
    return id;
  }

  Future<void> _assertBatchOwned(String farmId, String batchId) async {
    if (batchId.isEmpty) {
      throw StateError('A batch is required.');
    }
    final rows = await _db.queryLocalRecords(
      'batches',
      where: 'id = ? and farm_id = ? and is_deleted = 0',
      whereArgs: [batchId, farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('A selected batch was not found on this farm.');
    }
  }

  String _newId(String prefix) {
    final random = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$suffix';
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

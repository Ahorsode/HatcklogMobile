import 'package:flutter/foundation.dart';

import '../../../core/models/app_user.dart';
import '../../../core/models/worker_input_type.dart';
import '../../../core/storage/local_database.dart';
import '../../../utils/mortality_log_utils.dart';
import '../../auth/data/supabase_remote_api.dart';
import '../sync_engine_service.dart';
import '../../../presentation/worker/worker_module_definitions.dart';
import '../../../utils/worker_log_edit_policy.dart';
import 'worker_input_sink.dart';
import 'worker_log_mutator.dart';

class SyncRepository implements WorkerInputSink, WorkerLogMutator {
  SyncRepository({
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
    required SyncEngineService syncEngineService,
  }) : _localDatabase = localDatabase,
       _remoteApi = remoteApi,
       _syncEngineService = syncEngineService;

  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;
  final SyncEngineService _syncEngineService;
  AppUser? _activeUser;

  void setActiveUser(AppUser? user) {
    _activeUser = user;
  }

  @override
  Future<void> enqueueWorkerInput({
    required AppUser user,
    required WorkerInputType type,
    required Map<String, dynamic> payload,
  }) async {
    final farmId = await _resolveFarmId(user);
    if (farmId.isEmpty) {
      throw StateError(
        'No active farm is available on this device. Sync while online, then try again.',
      );
    }
    final selectedBatchId = _optionalString(payload['batch_id']).isEmpty
        ? user.activeBatchId
        : _optionalString(payload['batch_id']);
    if (selectedBatchId.isEmpty) {
      throw StateError('Choose a batch before saving this log.');
    }
    final input = PendingSyncInput(
      userId: user.id,
      inputType: type.storageKey,
      payload: {
        ...payload,
        'farm_id': farmId,
        'batch_id': selectedBatchId,
        'captured_by_role': user.role.name,
      },
      createdAt: DateTime.now(),
    );
    final queueId = await _localDatabase.insertPendingInput(input);
    await _insertLocalOperationalRecord(input, queueId);
  }

  Future<String> _resolveFarmId(AppUser user) async {
    final fromUser = user.activeFarmId.trim();
    if (fromUser.isNotEmpty) {
      return fromUser;
    }
    final session = await _localDatabase.readSessionContext();
    return session.farmId?.trim() ?? '';
  }

  @override
  Future<int> pendingCount() {
    return _localDatabase.countPendingInputs();
  }

  @override
  Future<List<RecentWorkerLog>> recentLogs({
    required AppUser user,
    int limit = 3,
  }) async {
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final inputs = await _localDatabase.readRecentInputsForUser(
      userId: user.id,
      since: startOfToday,
      limit: limit,
    );

    return inputs.map((input) {
      final type = WorkerInputType.fromStorageKey(input.inputType);
      return RecentWorkerLog(
        type: type,
        summary: _summaryFor(input),
        createdAt: input.createdAt,
        isSynced: input.isSynced,
      );
    }).toList();
  }

  @override
  Stream<WorkerDashboardSnapshot> watchDashboardState({required AppUser user}) {
    return _localDatabase
        .watchTables(const [
          'pending_sync_inputs',
          'egg_production',
          'daily_feeding_logs',
          'mortality',
          'quarantine',
          'batches',
          'houses',
        ])
        .asyncMap((_) async {
          return WorkerDashboardSnapshot(
            pendingCount: await pendingCount(),
            recentLogs: await recentLogs(user: user),
            unitOptions: await _loadWorkerUnitOptions(user),
          );
        });
  }

  Future<List<WorkerUnitOption>> _loadWorkerUnitOptions(AppUser user) async {
    if (user.activeFarmId.isEmpty) {
      return const [];
    }

    final rows = await _localDatabase.rawLocalQuery(
      '''
      select b.id as batch_id,
             b.batch_name as batch_name,
             b.house_id as house_id,
             h.name as house_name,
             b.status as status
      from batches b
      left join houses h on h.id = b.house_id
      where b.farm_id = ? and b.is_deleted = 0
      order by case when lower(b.status) = 'active' then 0 else 1 end,
               b.batch_name asc
      ''',
      [user.activeFarmId],
    );

    final options = rows
        .map((row) {
          final batchId = _asString(row['batch_id']);
          return WorkerUnitOption(
            batchId: batchId,
            batchLabel: _asString(row['batch_name']).isEmpty
                ? 'Batch $batchId'
                : _asString(row['batch_name']),
            houseId: _asString(row['house_id']),
            houseLabel: _asString(row['house_name']),
          );
        })
        .where((option) => option.batchId.isNotEmpty)
        .toList();

    if (options.isEmpty && user.activeBatchId.isNotEmpty) {
      final batchName = await _lookupLocalBatchName(
        user.activeFarmId,
        user.activeBatchId,
      );
      return [
        WorkerUnitOption(
          batchId: user.activeBatchId,
          batchLabel: batchName.isNotEmpty ? batchName : user.batchLabel,
        ),
      ];
    }

    return options;
  }

  Future<String> _lookupLocalBatchName(String farmId, String batchId) async {
    if (farmId.isEmpty || batchId.isEmpty) {
      return '';
    }
    final rows = await _localDatabase.rawLocalQuery(
      '''
      select batch_name
      from batches
      where farm_id = ? and id = ? and is_deleted = 0
      limit 1
      ''',
      [farmId, batchId],
    );
    if (rows.isEmpty) {
      return '';
    }
    return _asString(rows.first['batch_name']).trim();
  }

  Future<void> flushPendingInputs() async {
    if (!_remoteApi.isConfigured) {
      return;
    }

    final pendingInputs = await _localDatabase.readPendingInputs();
    for (final input in pendingInputs) {
      try {
        await _remoteApi.pushQueuedInput(input);
        final id = input.id;
        if (id != null) {
          await _localDatabase.markInputSynced(id);
          await _markLocalOperationalRecordSynced(input);
        }
      } on Object catch (error) {
        final id = input.id;
        if (id != null) {
          await _localDatabase.markInputAttemptFailed(id, error);
        }
        debugPrint('[Sync] Worker input push failed, continuing: $error');
      }
    }

    final user = _activeUser;
    if (user != null) {
      await syncWithCloud(user);
    }
  }

  Future<void> syncWithCloud(
    AppUser user, {
    bool forceFullRefresh = false,
  }) async {
    if (!_remoteApi.isConfigured) {
      return;
    }

    _activeUser = user;
    await _pushLocalChanges(user.activeFarmId);
    await hydrateFromCloud(user, forceFullRefresh: forceFullRefresh);
  }

  Future<void> _pushLocalChanges(String farmId) async {
    if (farmId.isEmpty) {
      return;
    }

    try {
      await _pushUnsyncedHouses(farmId);
    } on Object catch (error) {
      debugPrint('[Sync] House push failed: $error');
    }

    try {
      await _pushUnsyncedBatches(farmId);
    } on Object catch (error) {
      debugPrint('[Sync] Batch push failed: $error');
    }

    try {
      await _pushUnsyncedHealthSchedules(farmId);
    } on Object catch (error) {
      debugPrint('[Sync] Health schedule push failed: $error');
    }

    try {
      await _pushUnsyncedPartnerSettlements(farmId);
    } on Object catch (error) {
      debugPrint('[Sync] Partner settlement push failed: $error');
    }
  }

  Future<void> _pushUnsyncedBatches(String farmId) async {
    if (farmId.isEmpty) {
      return;
    }

    final batches = await _localDatabase.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and is_synced = 0 and coalesce(is_deleted, 0) = 0',
      whereArgs: [farmId],
    );
    if (batches.isEmpty) {
      return;
    }

    debugPrint('[Sync] Pushing ${batches.length} unsynced livestock unit(s) to cloud');

    final syncedIds = await _remoteApi.pushUnsyncedBatches(
      farmId: farmId,
      batches: batches,
    );

    for (final id in syncedIds) {
      await _localDatabase.updateLocalRecord(
        'batches',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    debugPrint('[Sync] Synced ${syncedIds.length} livestock unit(s) to cloud');
  }

  Future<void> _pushUnsyncedHouses(String farmId) async {
    if (farmId.isEmpty) {
      return;
    }

    final houses = await _localDatabase.queryLocalRecords(
      'houses',
      where: 'farm_id = ? and is_synced = 0',
      whereArgs: [farmId],
    );
    if (houses.isEmpty) {
      return;
    }

    debugPrint('[Sync] Pushing ${houses.length} unsynced house(s) to cloud');

    final syncedIds = await _remoteApi.pushUnsyncedHouses(
      farmId: farmId,
      houses: houses,
    );

    for (final id in syncedIds) {
      await _localDatabase.updateLocalRecord(
        'houses',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    debugPrint('[Sync] Synced ${syncedIds.length} house(s) to cloud');
  }

  Future<void> _pushUnsyncedPartnerSettlements(String farmId) async {
    if (farmId.isEmpty) {
      return;
    }

    final settlements = await _localDatabase.queryLocalRecords(
      'expenses',
      where:
          "farm_id = ? and is_synced = 0 and is_deleted = 0 and upper(category) in ('PAYMENT', 'COLLECTION')",
      whereArgs: [farmId],
    );
    if (settlements.isEmpty) {
      return;
    }

    final supplierIds = settlements
        .map((row) => row['supplier_id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();
    final suppliers = supplierIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await _localDatabase.queryLocalRecords(
            'suppliers',
            where: 'farm_id = ? and id in (${List.filled(supplierIds.length, '?').join(',')})',
            whereArgs: [farmId, ...supplierIds],
          );

    final customerIds = <String>{};
    for (final row in settlements) {
      final description = row['description']?.toString() ?? '';
      final match = RegExp(r'customer ([A-Za-z0-9_-]+)').firstMatch(description);
      if (match != null) {
        customerIds.add(match.group(1)!);
      }
    }
    final customers = customerIds.isEmpty
        ? const <Map<String, Object?>>[]
        : await _localDatabase.queryLocalRecords(
            'customers',
            where: 'farm_id = ? and id in (${List.filled(customerIds.length, '?').join(',')})',
            whereArgs: [farmId, ...customerIds],
          );

    await _remoteApi.pushUnsyncedPartnerSettlements(
      farmId: farmId,
      expenses: settlements,
      suppliers: suppliers,
      customers: customers,
    );

    for (final row in settlements) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) {
        continue;
      }
      await _localDatabase.updateLocalRecord(
        'expenses',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> _pushUnsyncedHealthSchedules(String farmId) async {
    if (farmId.isEmpty) {
      return;
    }

    final vaccinations = await _localDatabase.queryLocalRecords(
      'vaccination_schedules',
      where: 'farm_id = ? and is_synced = 0',
      whereArgs: [farmId],
    );
    final medications = await _localDatabase.queryLocalRecords(
      'medication_schedules',
      where: 'farm_id = ? and is_synced = 0',
      whereArgs: [farmId],
    );
    if (vaccinations.isEmpty && medications.isEmpty) {
      return;
    }

    await _remoteApi.pushUnsyncedHealthSchedules(
      farmId: farmId,
      vaccinations: vaccinations,
      medications: medications,
    );

    for (final row in vaccinations) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) {
        continue;
      }
      await _localDatabase.updateLocalRecord(
        'vaccination_schedules',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
    for (final row in medications) {
      final id = row['id']?.toString();
      if (id == null || id.isEmpty) {
        continue;
      }
      await _localDatabase.updateLocalRecord(
        'medication_schedules',
        {'is_synced': 1},
        where: 'id = ?',
        whereArgs: [id],
      );
    }
  }

  Future<void> hydrateFromCloud(
    AppUser user, {
    bool forceFullRefresh = false,
  }) async {
    final sessionChanged = await _localDatabase.prepareSessionForUser(
      userId: user.id,
      farmId: user.activeFarmId,
    );
    var shouldForceFullRefresh = forceFullRefresh || sessionChanged;
    if (!shouldForceFullRefresh && user.activeFarmId.isNotEmpty) {
      final cachedHouses = await _localDatabase.queryLocalRecords(
        'houses',
        where: 'farm_id = ? and coalesce(is_deleted, 0) = 0',
        whereArgs: [user.activeFarmId],
        limit: 1,
      );
      final cachedBatches = await _localDatabase.queryLocalRecords(
        'batches',
        where: 'farm_id = ? and coalesce(is_deleted, 0) = 0',
        whereArgs: [user.activeFarmId],
        limit: 1,
      );
      shouldForceFullRefresh =
          cachedHouses.isEmpty || cachedBatches.isEmpty;
    }
    await _syncEngineService.syncWebEntitiesToLocalCache(
      user: user,
      forceFullRefresh: shouldForceFullRefresh,
    );
  }

  Future<void> _insertLocalOperationalRecord(
    PendingSyncInput input,
    int queueId,
  ) async {
    final serverRecordId = input.resolvedServerRecordId;
    final payload = input.payload;
    switch (input.inputType) {
      case 'egg_collection':
        final eggsPerCrate = _asInt(payload['eggs_per_crate'], fallback: 30);
        final crates = _asDouble(payload['crates']);
        final singleEggs = _asInt(payload['single_eggs']);
        final payloadEggs = _asInt(payload['eggs_collected']);
        final eggsCollected = payloadEggs > 0
            ? payloadEggs
            : (crates * eggsPerCrate).round() + singleEggs;
        final unusableCount = _asInt(payload['unusable_count']);
        final usableEggs = (eggsCollected - unusableCount).clamp(0, eggsCollected);
        final logDate = _optionalString(payload['log_date']).isEmpty
            ? input.createdAt.toIso8601String()
            : _optionalString(payload['log_date']);
        await _localDatabase.insertLocalRecord('egg_production', {
          'id': serverRecordId,
          'local_queue_id': queueId,
          'batch_id': payload['batch_id'],
          'farm_id': payload['farm_id'],
          'house_id': payload['house_id'],
          'user_id': input.userId,
          'eggs_collected': eggsCollected,
          'crates_collected': crates,
          'eggs_remaining': usableEggs,
          'unusable_count': unusableCount,
          'cracked_count': unusableCount,
          'quality_grade': payload['quality_grade'],
          'small_count': _asInt(payload['small_count']),
          'medium_count': _asInt(payload['medium_count']),
          'large_count': _asInt(payload['large_count']),
          'is_sorted': _asBool(payload['is_sorted']) ? 1 : 0,
          'log_date': logDate,
          'created_at': input.createdAt.toIso8601String(),
          'is_deleted': 0,
          'is_synced': 0,
        });
      case 'feed_usage':
        final logDate = _optionalString(payload['log_date']).isEmpty
            ? _optionalString(payload['device_logged_at']).isEmpty
                ? input.createdAt.toIso8601String()
                : _optionalString(payload['device_logged_at'])
            : _optionalString(payload['log_date']);
        final amountConsumed = _asDouble(
          payload['amount_consumed'] ?? payload['bags'],
        );
        await _localDatabase.insertLocalRecord('daily_feeding_logs', {
          'id': serverRecordId,
          'local_queue_id': queueId,
          'batch_id': payload['batch_id'],
          'feed_type_id': payload['feed_type_id'],
          'formulation_id': payload['formulation_id'],
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'amount_consumed': amountConsumed,
          'feed_type_label': payload['feed_type'],
          'note': payload['note'],
          'log_date': logDate,
          'created_at': input.createdAt.toIso8601String(),
          'is_deleted': 0,
          'is_synced': 0,
        });
        await _decrementFeedStock(
          feedTypeId: _optionalString(payload['feed_type_id']),
          formulationId: _optionalString(payload['formulation_id']),
          amount: amountConsumed,
        );
      case 'mortality':
        final healthType = resolveHealthType(
          _optionalString(payload['health_type'] ?? payload['type']),
        );
        final logDate = _optionalString(payload['log_date']).isEmpty
            ? input.createdAt.toIso8601String()
            : _optionalString(payload['log_date']);
        final batchId = _optionalString(payload['batch_id']);
        final count = _asInt(payload['count']);
        await _localDatabase.insertLocalRecord('mortality', {
          'id': serverRecordId,
          'local_queue_id': queueId,
          'batch_id': batchId,
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'count': count,
          'type': healthType,
          'reason': payload['reason'],
          'category': payload['category'],
          'sub_category': payload['sub_category'],
          'isolation_room_id': payload['isolation_room_id'],
          'mortality_percent': 0,
          'loss_trend': 'LOCAL_ENTRY',
          'log_date': logDate,
          'created_at': input.createdAt.toIso8601String(),
          'is_deleted': 0,
          'is_synced': 0,
        });
        await _applyMortalityBatchCounts(
          batchId: batchId,
          healthType: healthType,
          count: count,
        );
      case 'inventory_item':
        final now = input.createdAt.toIso8601String();
        await _localDatabase.insertLocalRecord('inventory', {
          'id': serverRecordId,
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'item_name': payload['item_name'],
          'stock_level': _asDouble(payload['stock_level']),
          'unit': _optionalString(payload['unit']).isEmpty
              ? 'bags'
              : payload['unit'],
          'category': payload['category'],
          'item_group': payload['category'],
          'is_deleted': 0,
          'is_synced': 0,
          'created_at': now,
          'updated_at': now,
        });
      case 'expense_allocation':
        final now = input.createdAt.toIso8601String();
        final expenseId = '${serverRecordId}_expense';
        await _localDatabase.insertLocalRecord('expenses', {
          'id': expenseId,
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'amount': _asDouble(payload['amount']),
          'category': _optionalString(payload['category']).toUpperCase(),
          'description': payload['description'],
          'expense_date': _optionalString(payload['expense_date']).isEmpty
              ? now
              : payload['expense_date'],
          'reference': payload['reference'],
          'allocation_mode':
              payload['allocationMode'] ?? payload['allocation_mode'],
          'batch_id': null,
          'is_deleted': 0,
          'is_synced': 0,
          'created_at': now,
          'updated_at': now,
        });
        final allocations = (payload['allocations'] as List?) ?? const [];
        for (var index = 0; index < allocations.length; index += 1) {
          final allocation = Map<String, dynamic>.from(
            allocations[index] as Map,
          );
          final batchId = _optionalString(
            allocation['batch_id'] ?? allocation['batchId'],
          );
          if (batchId.isEmpty) {
            continue;
          }
          await _localDatabase.insertLocalRecord('expense_allocations', {
            'id': '${expenseId}_allocation_$index',
            'expense_id': expenseId,
            'batch_id': batchId,
            'farm_id': payload['farm_id'],
            'allocated_amount': _asDouble(allocation['amount']),
            'allocation_percentage': _asDouble(allocation['percentage']),
            'created_at': now,
            'is_synced': 0,
          });
        }
    }
  }

  Future<void> _markLocalOperationalRecordSynced(PendingSyncInput input) async {
    final table = switch (input.inputType) {
      'egg_collection' => 'egg_production',
      'feed_usage' => 'daily_feeding_logs',
      'mortality' => 'mortality',
      'inventory_item' => 'inventory',
      'expense_allocation' => 'expenses',
      'worker_log_update' || 'worker_log_delete' =>
        _workerLogTableFromPayload(input.payload),
      _ => '',
    };
    if (table.isEmpty) {
      return;
    }
    final recordId = input.inputType == 'expense_allocation'
        ? '${input.resolvedServerRecordId}_expense'
        : input.inputType == 'worker_log_update' ||
              input.inputType == 'worker_log_delete'
        ? _optionalString(input.payload['record_id']).isEmpty
              ? input.resolvedServerRecordId
              : _optionalString(input.payload['record_id'])
        : input.resolvedServerRecordId;
    await _localDatabase.updateLocalRecord(
      table,
      {'is_synced': 1},
      where: 'id = ?',
      whereArgs: [recordId],
    );
    if (input.inputType == 'expense_allocation') {
      await _localDatabase.updateLocalRecord(
        'expense_allocations',
        {'is_synced': 1},
        where: 'expense_id = ?',
        whereArgs: [recordId],
      );
    }
  }

  String _summaryFor(PendingSyncInput input) {
    final type = WorkerInputType.fromStorageKey(input.inputType);
    final payload = input.payload;

    switch (type) {
      case WorkerInputType.eggCollection:
        final crates = _numberText(payload['crates']);
        final eggs = _numberText(payload['single_eggs']);
        return '$crates crates, $eggs eggs collected';
      case WorkerInputType.feedUsage:
        final feedType = (payload['feed_type'] ?? 'Feed').toString();
        final bags = _numberText(payload['bags']);
        return '$bags bags of $feedType feed';
      case WorkerInputType.mortality:
        final count = _numberText(payload['count']);
        return isSickHealthType(_optionalString(payload['health_type']))
            ? '$count sick birds logged'
            : '$count bird losses logged';
      case WorkerInputType.inventoryItem:
        return '${payload['item_name'] ?? 'Inventory item'} added';
      case WorkerInputType.expenseAllocation:
        final amount = _asDouble(payload['amount']).toStringAsFixed(2);
        return 'GHS $amount ${payload['category'] ?? 'expense'} logged';
    }
  }

  String _numberText(Object? value) {
    if (value == null) {
      return '0';
    }
    return value.toString();
  }

  int _asInt(Object? value, {int fallback = 0}) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }

  double _asDouble(Object? value, {double fallback = 0}) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  bool _asBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes';
  }

  String _optionalString(Object? value) {
    return value?.toString().trim() ?? '';
  }

  String _asString(Object? value) {
    return value?.toString() ?? '';
  }

  Future<void> _applyMortalityBatchCounts({
    required String batchId,
    required String healthType,
    required int count,
  }) async {
    if (batchId.isEmpty || count <= 0) {
      return;
    }

    final rows = await _localDatabase.rawLocalQuery(
      'select current_count, isolation_count from batches where id = ?',
      [batchId],
    );
    if (rows.isEmpty) {
      return;
    }

    final row = rows.first;
    final currentCount =
        int.tryParse(row['current_count']?.toString() ?? '') ?? 0;
    final isolationCount =
        int.tryParse(row['isolation_count']?.toString() ?? '') ?? 0;
    final deltas = healthLogBatchDeltas(healthType: healthType, count: count);
    final nextCurrentCount = currentCount + deltas.currentCountDelta;
    final nextIsolationCount = isolationCount + deltas.isolationCountDelta;

    await _localDatabase.rawLocalUpdate(
      'batches',
      {
        'current_count': nextCurrentCount < 0 ? 0 : nextCurrentCount,
        'isolation_count': nextIsolationCount < 0 ? 0 : nextIsolationCount,
        'is_synced': 0,
      },
      'id = ?',
      [batchId],
    );
  }

  Future<void> _decrementFeedStock({
    required String feedTypeId,
    required String formulationId,
    required double amount,
  }) async {
    if (amount <= 0) {
      return;
    }
    if (feedTypeId.isNotEmpty) {
      final rows = await _localDatabase.queryLocalRecords(
        'inventory',
        where: 'id = ? and is_deleted = 0',
        whereArgs: [feedTypeId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final current = _asDouble(rows.first['stock_level']);
      await _localDatabase.updateLocalRecord(
        'inventory',
        {
          'stock_level': (current - amount).clamp(0, 999999),
          'is_synced': 0,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [feedTypeId],
      );
      return;
    }
    if (formulationId.isNotEmpty) {
      final rows = await _localDatabase.queryLocalRecords(
        'feed_formulations',
        where: 'id = ?',
        whereArgs: [formulationId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final current = _asDouble(rows.first['stockLevel'] ?? rows.first['stock_level']);
      await _localDatabase.updateLocalRecord(
        'feed_formulations',
        {
          'stockLevel': (current - amount).clamp(0, 999999),
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [formulationId],
      );
    }
  }

  @override
  Future<void> deleteWorkerLog({
    required AppUser user,
    required WorkerModule module,
    required String recordId,
  }) async {
    final table = _workerLogTable(module);
    final rows = await _localDatabase.queryLocalRecords(
      table,
      where: 'id = ? and coalesce(is_deleted, 0) = 0',
      whereArgs: [recordId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Log record not found.');
    }
    final row = rows.first;
    if (!canWorkerMutateLogRow(currentUserId: user.id, row: row)) {
      throw StateError(workerLogLockMessage());
    }

    final now = DateTime.now().toIso8601String();
    await _localDatabase.updateLocalRecord(
      table,
      {'is_deleted': 1, 'deleted_at': now, 'is_synced': 0},
      where: 'id = ?',
      whereArgs: [recordId],
    );

    if (module == WorkerModule.mortality) {
      await _reverseMortalityBatchCounts(
        batchId: _optionalString(row['batch_id']),
        healthType: resolveHealthType(_optionalString(row['type'])),
        count: _asInt(row['count']),
      );
    } else if (module == WorkerModule.feeding) {
      await _incrementFeedStock(
        feedTypeId: _optionalString(row['feed_type_id']),
        formulationId: _optionalString(row['formulation_id']),
        amount: _asDouble(row['amount_consumed']),
      );
    }

    await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'worker_log_delete',
        payload: {
          'table': table,
          'record_id': recordId,
          'farm_id': user.activeFarmId,
        },
        createdAt: DateTime.now(),
        serverRecordId: recordId,
      ),
    );
  }

  @override
  Future<void> updateWorkerLog({
    required AppUser user,
    required WorkerModule module,
    required String recordId,
    required Map<String, dynamic> payload,
  }) async {
    final table = _workerLogTable(module);
    final rows = await _localDatabase.queryLocalRecords(
      table,
      where: 'id = ? and coalesce(is_deleted, 0) = 0',
      whereArgs: [recordId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw StateError('Log record not found.');
    }
    final row = rows.first;
    if (!canWorkerMutateLogRow(currentUserId: user.id, row: row)) {
      throw StateError(workerLogLockMessage());
    }

    final recordType = _workerLogRecordType(module);
    final mergedPayload = {
      ...payload,
      'farm_id': user.activeFarmId,
      'batch_id': _optionalString(payload['batch_id']).isEmpty
          ? _optionalString(row['batch_id'])
          : payload['batch_id'],
    };

    switch (module) {
      case WorkerModule.eggs:
        await _applyEggLogUpdate(recordId, mergedPayload);
      case WorkerModule.feeding:
        await _applyFeedLogUpdate(recordId, row, mergedPayload);
      case WorkerModule.mortality:
        await _applyMortalityLogUpdate(recordId, row, mergedPayload);
      default:
        throw StateError('Unsupported worker log module: $module');
    }

    await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'worker_log_update',
        payload: {
          ...mergedPayload,
          'record_type': recordType,
          'record_id': recordId,
        },
        createdAt: DateTime.now(),
        serverRecordId: recordId,
      ),
    );
  }

  String _workerLogTable(WorkerModule module) {
    return switch (module) {
      WorkerModule.eggs => 'egg_production',
      WorkerModule.feeding => 'daily_feeding_logs',
      WorkerModule.mortality => 'mortality',
      _ => throw StateError('Unsupported worker log module: $module'),
    };
  }

  String _workerLogRecordType(WorkerModule module) {
    return switch (module) {
      WorkerModule.eggs => 'egg_collection',
      WorkerModule.feeding => 'feed_usage',
      WorkerModule.mortality => 'mortality',
      _ => throw StateError('Unsupported worker log module: $module'),
    };
  }

  String _workerLogTableFromPayload(Map<String, dynamic> payload) {
    final recordType = _optionalString(payload['record_type']);
    return switch (recordType) {
      'egg_collection' => 'egg_production',
      'feed_usage' => 'daily_feeding_logs',
      'mortality' => 'mortality',
      _ => _optionalString(payload['table']),
    };
  }

  Future<void> _applyEggLogUpdate(
    String recordId,
    Map<String, dynamic> payload,
  ) async {
    final eggsPerCrate = _asInt(payload['eggs_per_crate'], fallback: 30);
    final crates = _asDouble(payload['crates']);
    final singleEggs = _asInt(payload['single_eggs']);
    final payloadEggs = _asInt(payload['eggs_collected']);
    final eggsCollected = payloadEggs > 0
        ? payloadEggs
        : (crates * eggsPerCrate).round() + singleEggs;
    final unusableCount = _asInt(payload['unusable_count']);
    final usableEggs = (eggsCollected - unusableCount).clamp(0, eggsCollected);
    final logDate = _optionalString(payload['log_date']);

    await _localDatabase.updateLocalRecord(
      'egg_production',
      {
        'eggs_collected': eggsCollected,
        'crates_collected': crates,
        'eggs_remaining': usableEggs,
        'unusable_count': unusableCount,
        'cracked_count': unusableCount,
        'quality_grade': payload['quality_grade'],
        'small_count': _asInt(payload['small_count']),
        'medium_count': _asInt(payload['medium_count']),
        'large_count': _asInt(payload['large_count']),
        'is_sorted': _asBool(payload['is_sorted']) ? 1 : 0,
        if (logDate.isNotEmpty) 'log_date': logDate,
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  Future<void> _applyFeedLogUpdate(
    String recordId,
    Map<String, Object?> existing,
    Map<String, dynamic> payload,
  ) async {
    final oldAmount = _asDouble(existing['amount_consumed']);
    final newAmount = _asDouble(
      payload['amount_consumed'] ?? payload['bags'],
    );
    final oldFeedTypeId = _optionalString(existing['feed_type_id']);
    final oldFormulationId = _optionalString(existing['formulation_id']);
    final newFeedTypeId = _optionalString(payload['feed_type_id']);
    final newFormulationId = _optionalString(payload['formulation_id']);
    final logDate = _optionalString(payload['log_date']);

    await _incrementFeedStock(
      feedTypeId: oldFeedTypeId,
      formulationId: oldFormulationId,
      amount: oldAmount,
    );
    await _decrementFeedStock(
      feedTypeId: newFeedTypeId,
      formulationId: newFormulationId,
      amount: newAmount,
    );

    await _localDatabase.updateLocalRecord(
      'daily_feeding_logs',
      {
        'feed_type_id': newFeedTypeId.isEmpty ? null : newFeedTypeId,
        'formulation_id': newFormulationId.isEmpty ? null : newFormulationId,
        'amount_consumed': newAmount,
        'feed_type_label': payload['feed_type'],
        if (logDate.isNotEmpty) 'log_date': logDate,
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  Future<void> _applyMortalityLogUpdate(
    String recordId,
    Map<String, Object?> existing,
    Map<String, dynamic> payload,
  ) async {
    final oldBatchId = _optionalString(existing['batch_id']);
    final oldHealthType = resolveHealthType(_optionalString(existing['type']));
    final oldCount = _asInt(existing['count']);
    final newHealthType = resolveHealthType(
      _optionalString(payload['health_type'] ?? payload['type']),
    );
    final newCount = _asInt(payload['count']);
    final newBatchId = _optionalString(payload['batch_id']).isEmpty
        ? oldBatchId
        : _optionalString(payload['batch_id']);
    final logDate = _optionalString(payload['log_date']);

    await _reverseMortalityBatchCounts(
      batchId: oldBatchId,
      healthType: oldHealthType,
      count: oldCount,
    );
    await _applyMortalityBatchCounts(
      batchId: newBatchId,
      healthType: newHealthType,
      count: newCount,
    );

    await _localDatabase.updateLocalRecord(
      'mortality',
      {
        'count': newCount,
        'type': newHealthType,
        'reason': payload['reason'],
        'category': payload['category'],
        'sub_category': payload['sub_category'],
        'isolation_room_id': payload['isolation_room_id'],
        if (logDate.isNotEmpty) 'log_date': logDate,
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [recordId],
    );
  }

  Future<void> _reverseMortalityBatchCounts({
    required String batchId,
    required String healthType,
    required int count,
  }) async {
    if (batchId.isEmpty || count <= 0) {
      return;
    }

    final rows = await _localDatabase.rawLocalQuery(
      'select current_count, isolation_count from batches where id = ?',
      [batchId],
    );
    if (rows.isEmpty) {
      return;
    }

    final row = rows.first;
    final currentCount =
        int.tryParse(row['current_count']?.toString() ?? '') ?? 0;
    final isolationCount =
        int.tryParse(row['isolation_count']?.toString() ?? '') ?? 0;
    final deltas = healthLogBatchDeltas(healthType: healthType, count: count);
    final nextCurrentCount = currentCount - deltas.currentCountDelta;
    final nextIsolationCount = isolationCount - deltas.isolationCountDelta;

    await _localDatabase.rawLocalUpdate(
      'batches',
      {
        'current_count': nextCurrentCount < 0 ? 0 : nextCurrentCount,
        'isolation_count': nextIsolationCount < 0 ? 0 : nextIsolationCount,
        'is_synced': 0,
      },
      'id = ?',
      [batchId],
    );
  }

  Future<void> _incrementFeedStock({
    required String feedTypeId,
    required String formulationId,
    required double amount,
  }) async {
    if (amount <= 0) {
      return;
    }
    if (feedTypeId.isNotEmpty) {
      final rows = await _localDatabase.queryLocalRecords(
        'inventory',
        where: 'id = ? and is_deleted = 0',
        whereArgs: [feedTypeId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final current = _asDouble(rows.first['stock_level']);
      await _localDatabase.updateLocalRecord(
        'inventory',
        {
          'stock_level': current + amount,
          'is_synced': 0,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [feedTypeId],
      );
      return;
    }
    if (formulationId.isNotEmpty) {
      final rows = await _localDatabase.queryLocalRecords(
        'feed_formulations',
        where: 'id = ?',
        whereArgs: [formulationId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }
      final current = _asDouble(
        rows.first['stockLevel'] ?? rows.first['stock_level'],
      );
      await _localDatabase.updateLocalRecord(
        'feed_formulations',
        {
          'stockLevel': current + amount,
          'updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [formulationId],
      );
    }
  }
}

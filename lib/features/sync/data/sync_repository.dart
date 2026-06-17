import '../../../core/models/app_user.dart';
import '../../../core/models/worker_input_type.dart';
import '../../../core/storage/local_database.dart';
import '../../auth/data/supabase_remote_api.dart';
import '../sync_engine_service.dart';
import 'worker_input_sink.dart';

class SyncRepository implements WorkerInputSink {
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
    final selectedBatchId = _optionalString(payload['batch_id']).isEmpty
        ? user.activeBatchId
        : _optionalString(payload['batch_id']);
    final input = PendingSyncInput(
      userId: user.id,
      inputType: type.storageKey,
      payload: {
        ...payload,
        'farm_id': user.activeFarmId,
        'batch_id': selectedBatchId,
        'captured_by_role': user.role.name,
      },
      createdAt: DateTime.now(),
    );
    final queueId = await _localDatabase.insertPendingInput(input);
    await _insertLocalOperationalRecord(input, queueId);
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
      return [
        WorkerUnitOption(
          batchId: user.activeBatchId,
          batchLabel: user.batchLabel,
        ),
      ];
    }

    return options;
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
        return;
      }
    }

    final user = _activeUser;
    if (user != null) {
      await hydrateFromCloud(user);
    }
  }

  Future<void> hydrateFromCloud(AppUser user) async {
    await _syncEngineService.syncWebEntitiesToLocalCache(user: user);
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
          'eggs_remaining': eggsCollected,
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
            ? input.createdAt.toIso8601String()
            : _optionalString(payload['log_date']);
        await _localDatabase.insertLocalRecord('daily_feeding_logs', {
          'id': serverRecordId,
          'local_queue_id': queueId,
          'batch_id': payload['batch_id'],
          'feed_type_id': payload['feed_type_id'],
          'formulation_id': payload['formulation_id'],
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'amount_consumed': _asDouble(
            payload['amount_consumed'] ?? payload['bags'],
          ),
          'feed_type_label': payload['feed_type'],
          'note': payload['note'],
          'log_date': logDate,
          'created_at': input.createdAt.toIso8601String(),
          'is_deleted': 0,
          'is_synced': 0,
        });
      case 'mortality':
        final healthType = _optionalString(
          payload['health_type'] ?? payload['type'],
        ).toUpperCase();
        final resolvedHealthType = healthType == 'SICK' ? 'SICK' : 'DEAD';
        final logDate = _optionalString(payload['log_date']).isEmpty
            ? input.createdAt.toIso8601String()
            : _optionalString(payload['log_date']);
        await _localDatabase.insertLocalRecord('mortality', {
          'id': serverRecordId,
          'local_queue_id': queueId,
          'batch_id': payload['batch_id'],
          'farm_id': payload['farm_id'],
          'user_id': input.userId,
          'count': _asInt(payload['count']),
          'type': resolvedHealthType,
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
      _ => '',
    };
    if (table.isEmpty) {
      return;
    }
    final recordId = input.inputType == 'expense_allocation'
        ? '${input.resolvedServerRecordId}_expense'
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
        final type = _optionalString(payload['health_type']).toUpperCase();
        return type == 'SICK'
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
}

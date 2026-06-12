import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import '../models/app_user.dart';
import '../models/hatchlog_schema.dart';

class PendingSyncInput {
  const PendingSyncInput({
    this.id,
    required this.userId,
    required this.inputType,
    required this.payload,
    required this.createdAt,
    this.serverRecordId,
    this.isSynced = false,
    this.syncedAt,
    this.lastAttemptAt,
    this.attemptCount = 0,
    this.lastError,
  });

  final int? id;
  final String userId;
  final String inputType;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final String? serverRecordId;
  final bool isSynced;
  final DateTime? syncedAt;
  final DateTime? lastAttemptAt;
  final int attemptCount;
  final String? lastError;

  String get resolvedServerRecordId => serverRecordId ?? buildServerRecordId();

  String buildServerRecordId() {
    final canonicalPayload = jsonEncode(_sortedJson(payload));
    final digest = sha256
        .convert(
          utf8.encode(
            '$userId|$inputType|${createdAt.toUtc().toIso8601String()}|$canonicalPayload',
          ),
        )
        .toString()
        .substring(0, 32);
    return 'mobile_${inputType}_$digest';
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'user_id': userId,
      'input_type': inputType,
      'payload_json': jsonEncode(payload),
      'created_at': createdAt.toIso8601String(),
      'server_record_id': resolvedServerRecordId,
      'is_synced': isSynced ? 1 : 0,
      'synced_at': syncedAt?.toIso8601String(),
      'last_attempt_at': lastAttemptAt?.toIso8601String(),
      'attempt_count': attemptCount,
      'last_error': lastError,
    };
  }

  static PendingSyncInput fromMap(Map<String, Object?> map) {
    final decodedPayload = jsonDecode(map['payload_json'] as String) as Map;
    final input = PendingSyncInput(
      id: map['id'] as int?,
      userId: map['user_id'] as String,
      inputType: map['input_type'] as String,
      payload: Map<String, dynamic>.from(decodedPayload),
      createdAt: DateTime.parse(map['created_at'] as String),
      serverRecordId: map['server_record_id'] as String?,
      isSynced: (map['is_synced'] as int) == 1,
      syncedAt: map['synced_at'] == null
          ? null
          : DateTime.parse(map['synced_at'] as String),
      lastAttemptAt: map['last_attempt_at'] == null
          ? null
          : DateTime.parse(map['last_attempt_at'] as String),
      attemptCount: (map['attempt_count'] as int?) ?? 0,
      lastError: map['last_error'] as String?,
    );
    return input.serverRecordId == null || input.serverRecordId!.isEmpty
        ? PendingSyncInput(
            id: input.id,
            userId: input.userId,
            inputType: input.inputType,
            payload: input.payload,
            createdAt: input.createdAt,
            serverRecordId: input.buildServerRecordId(),
            isSynced: input.isSynced,
            syncedAt: input.syncedAt,
            lastAttemptAt: input.lastAttemptAt,
            attemptCount: input.attemptCount,
            lastError: input.lastError,
          )
        : input;
  }

  static Object? _sortedJson(Object? value) {
    if (value is Map) {
      final sorted = <String, Object?>{};
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      for (final key in keys) {
        sorted[key] = _sortedJson(value[key]);
      }
      return sorted;
    }
    if (value is List) {
      return value.map(_sortedJson).toList();
    }
    return value;
  }
}

class LocalDatabase {
  Database? _database;
  final StreamController<Set<String>> _tableChangeController =
      StreamController<Set<String>>.broadcast();

  Future<void> initialize() async {
    final databasePath = await getDatabasesPath();
    final fullPath = path.join(databasePath, 'hatchlog_mobile.db');
    _database = await openDatabase(
      fullPath,
      version: 6,
      onCreate: _createSchema,
      onUpgrade: _upgradeSchema,
    );
  }

  Stream<void> watchTables(Iterable<String> tableNames) async* {
    final watched = tableNames.toSet();
    yield null;
    await for (final changedTables in _tableChangeController.stream) {
      if (watched.isEmpty ||
          changedTables.any((table) => watched.contains(table))) {
        yield null;
      }
    }
  }

  Future<void> upsertUser(AppUser user) async {
    await _db.insert(
      'local_users',
      user.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyTablesChanged(const ['local_users']);
  }

  Future<void> upsertFarm(FarmCacheRecord farm) async {
    await _db.insert(
      'farms',
      farm.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyTablesChanged(const ['farms']);
  }

  Future<void> upsertBatch(BatchCacheRecord batch) async {
    await _db.insert(
      'batches',
      batch.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyTablesChanged(const ['batches']);
  }

  Future<void> upsertFarmSettings(FarmSettingsCacheRecord settings) async {
    await _db.insert(
      'farm_settings',
      settings.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyTablesChanged(const ['farm_settings']);
  }

  Future<AppUser?> readUserByPhone(String phoneNumber) async {
    final rows = await _db.query(
      'local_users',
      where: 'phone_number = ?',
      whereArgs: [phoneNumber],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return AppUser.fromMap(rows.first);
  }

  Future<AppUser?> readUserByIdentifier(String identifier) async {
    final normalized = identifier.trim().toLowerCase();
    final rows = await _db.query(
      'local_users',
      where: 'phone_number = ? or lower(email) = ?',
      whereArgs: [identifier.trim(), normalized],
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    return AppUser.fromMap(rows.first);
  }

  Future<int> insertPendingInput(PendingSyncInput input) async {
    final id = await _db.insert('pending_sync_inputs', input.toMap());
    _notifyTablesChanged(const ['pending_sync_inputs']);
    return id;
  }

  Future<List<PendingSyncInput>> readPendingInputs({int limit = 50}) async {
    final rows = await _db.query(
      'pending_sync_inputs',
      where: 'is_synced = ?',
      whereArgs: [0],
      orderBy: 'created_at ASC',
      limit: limit,
    );

    return rows.map(PendingSyncInput.fromMap).toList();
  }

  Future<int> countPendingInputs() async {
    final rows = await _db.rawQuery(
      'select count(*) as count from pending_sync_inputs where is_synced = 0',
    );
    return (rows.first['count'] as int?) ?? 0;
  }

  Future<List<PendingSyncInput>> readRecentInputsForUser({
    required String userId,
    required DateTime since,
    int limit = 3,
  }) async {
    final rows = await _db.query(
      'pending_sync_inputs',
      where: 'user_id = ? and created_at >= ?',
      whereArgs: [userId, since.toIso8601String()],
      orderBy: 'created_at DESC',
      limit: limit,
    );

    return rows.map(PendingSyncInput.fromMap).toList();
  }

  Future<void> markInputSynced(int id) async {
    await _db.update(
      'pending_sync_inputs',
      {
        'is_synced': 1,
        'synced_at': DateTime.now().toIso8601String(),
        'last_error': null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
    _notifyTablesChanged(const ['pending_sync_inputs']);
  }

  Future<void> markInputAttemptFailed(int id, Object error) async {
    await _db.rawUpdate(
      '''
      update pending_sync_inputs
      set attempt_count = attempt_count + 1,
          last_attempt_at = ?,
          last_error = ?
      where id = ?
      ''',
      [DateTime.now().toIso8601String(), error.toString(), id],
    );
    _notifyTablesChanged(const ['pending_sync_inputs']);
  }

  Future<DateTime?> readSyncCursor(String scope) async {
    final rows = await _db.query(
      'sync_state',
      columns: ['pulled_at'],
      where: 'scope = ?',
      whereArgs: [scope],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final value = rows.first['pulled_at']?.toString() ?? '';
    return value.isEmpty ? null : DateTime.tryParse(value);
  }

  Future<void> writeSyncCursor(String scope, DateTime pulledAt) async {
    await _db.insert('sync_state', {
      'scope': scope,
      'pulled_at': pulledAt.toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _notifyTablesChanged(const ['sync_state']);
  }

  Future<void> upsertCloudRecords(
    Map<String, List<Map<String, Object?>>> recordsByTable,
  ) async {
    final changedTables = <String>{};
    await _db.transaction((txn) async {
      for (final entry in recordsByTable.entries) {
        for (final row in entry.value) {
          await txn.insert(
            entry.key,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
          changedTables.add(entry.key);
        }
      }
    });
    if (changedTables.isNotEmpty) {
      _notifyTablesChanged(changedTables);
    }
  }

  Future<int> insertLocalRecord(
    String table,
    Map<String, Object?> values,
  ) async {
    final id = await _db.insert(
      table,
      values,
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _notifyTablesChanged([table]);
    return id;
  }

  Future<int> updateLocalRecord(
    String table,
    Map<String, Object?> values, {
    required String where,
    required List<Object?> whereArgs,
  }) async {
    final count = await _db.update(
      table,
      values,
      where: where,
      whereArgs: whereArgs,
    );
    if (count > 0) {
      _notifyTablesChanged([table]);
    }
    return count;
  }

  Future<List<Map<String, Object?>>> queryLocalRecords(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
  }) {
    return _db.query(
      table,
      distinct: distinct,
      columns: columns,
      where: where,
      whereArgs: whereArgs,
      groupBy: groupBy,
      having: having,
      orderBy: orderBy,
      limit: limit,
    );
  }

  Future<List<Map<String, Object?>>> rawLocalQuery(
    String sql, [
    List<Object?>? arguments,
  ]) {
    return _db.rawQuery(sql, arguments);
  }

  Database get _db {
    final database = _database;
    if (database == null) {
      throw StateError('LocalDatabase.initialize() must be called first.');
    }
    return database;
  }

  void _notifyTablesChanged(Iterable<String> tableNames) {
    if (_tableChangeController.isClosed) {
      return;
    }
    final changedTables = tableNames
        .where((table) => table.trim().isNotEmpty)
        .toSet();
    if (changedTables.isNotEmpty) {
      _tableChangeController.add(changedTables);
    }
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
      create table local_users (
        id text primary key,
        phone_number text not null unique,
        email text,
        role text not null,
        first_name text,
        last_name text,
        active_farm_id text,
        active_batch_id text,
        updated_at text not null
      )
    ''');

    await _createWebSchemaCacheTables(db);

    await db.execute('''
      create table pending_sync_inputs (
        id integer primary key autoincrement,
        user_id text not null,
        input_type text not null,
        payload_json text not null,
        created_at text not null,
        server_record_id text not null unique,
        is_synced integer not null default 0,
        synced_at text,
        last_attempt_at text,
        attempt_count integer not null default 0,
        last_error text
      )
    ''');

    await db.execute(
      'create index idx_pending_sync_inputs_unsynced '
      'on pending_sync_inputs(is_synced, created_at)',
    );

    await _createSyncStateTable(db);
  }

  Future<void> _upgradeSchema(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await db.execute(
        'alter table local_users add column active_batch_id text',
      );
    }
    if (oldVersion < 3) {
      await db.execute(
        'alter table local_users add column active_farm_id text',
      );
      await _createWebSchemaCacheTables(db);
    }
    if (oldVersion < 4) {
      await db.execute('alter table local_users add column email text');
    }
    if (oldVersion < 5) {
      await _createWebSchemaCacheTables(db);
      await _ensureWebSchemaColumns(db);
      await _ensurePendingSyncQueueColumns(db);
      await _createSyncStateTable(db);
    }
    if (oldVersion < 6) {
      await _createWebSchemaCacheTables(db);
      await _ensureWebSchemaColumns(db);
      await _ensureCoreHubColumns(db);
      await _createSyncStateTable(db);
    }
  }

  Future<void> _createSyncStateTable(Database db) async {
    await db.execute('''
      create table if not exists sync_state (
        scope text primary key,
        pulled_at text not null
      )
    ''');
  }

  Future<void> _ensurePendingSyncQueueColumns(Database db) async {
    await _addColumnIfMissing(
      db,
      'pending_sync_inputs',
      'server_record_id',
      'text',
    );
    await _addColumnIfMissing(
      db,
      'pending_sync_inputs',
      'last_attempt_at',
      'text',
    );
    await _addColumnIfMissing(
      db,
      'pending_sync_inputs',
      'attempt_count',
      'integer not null default 0',
    );
    await _addColumnIfMissing(db, 'pending_sync_inputs', 'last_error', 'text');
    await db.execute(
      'create unique index if not exists idx_pending_sync_inputs_server_record '
      'on pending_sync_inputs(server_record_id) where server_record_id is not null',
    );
  }

  Future<void> _ensureWebSchemaColumns(Database db) async {
    for (final column in const [
      'can_view_sales',
      'can_edit_sales',
      'can_view_houses',
      'can_edit_houses',
      'can_view_customers',
      'can_edit_customers',
      'can_view_team',
      'can_edit_team',
      'can_view_quarantine',
      'can_edit_quarantine',
    ]) {
      await _addColumnIfMissing(
        db,
        'user_permissions',
        column,
        'integer not null default 0',
      );
    }

    for (final table in const [
      'egg_production',
      'daily_feeding_logs',
      'mortality',
    ]) {
      await _addColumnIfMissing(
        db,
        table,
        'is_deleted',
        'integer not null default 0',
      );
      await _addColumnIfMissing(db, table, 'deleted_at', 'text');
    }
  }

  Future<void> _ensureCoreHubColumns(Database db) async {
    for (final column in const ['user_id', 'created_at']) {
      await _addColumnIfMissing(db, 'houses', column, 'text');
    }
    await _addColumnIfMissing(db, 'houses', 'environmental_state', 'text');
    await _addColumnIfMissing(db, 'houses', 'last_environment_log_at', 'text');

    for (final column in const [
      'user_id',
      'created_at',
      'deleted_at',
      'bird_strain',
      'active_state',
    ]) {
      await _addColumnIfMissing(db, 'batches', column, 'text');
    }
    await _addColumnIfMissing(db, 'batches', 'age_days', 'integer');

    for (final column in const ['created_at', 'feed_type_label', 'note']) {
      await _addColumnIfMissing(db, 'daily_feeding_logs', column, 'text');
    }
    await _addColumnIfMissing(
      db,
      'daily_feeding_logs',
      'remaining_sack_count',
      'real',
    );

    await _addColumnIfMissing(db, 'egg_production', 'created_at', 'text');
    await _addColumnIfMissing(
      db,
      'egg_production',
      'cracked_count',
      'integer not null default 0',
    );
    await _addColumnIfMissing(
      db,
      'egg_production',
      'crack_percentage',
      'real not null default 0',
    );
    for (final column in const ['small_count', 'medium_count', 'large_count']) {
      await _addColumnIfMissing(
        db,
        'egg_production',
        column,
        'integer not null default 0',
      );
    }
    await _addColumnIfMissing(
      db,
      'egg_production',
      'is_sorted',
      'integer not null default 0',
    );

    for (final column in const ['house_id', 'created_at', 'loss_trend']) {
      await _addColumnIfMissing(db, 'mortality', column, 'text');
    }
    await _addColumnIfMissing(
      db,
      'mortality',
      'mortality_percent',
      'real not null default 0',
    );

    for (final column in const [
      'user_id',
      'created_at',
      'deleted_at',
      'item_group',
      'variant_name',
      'storage_location',
      'last_restocked_at',
    ]) {
      await _addColumnIfMissing(db, 'inventory', column, 'text');
    }

    for (final column in const [
      'customer_id',
      'payment_method',
      'receipt_number',
      'updated_at',
    ]) {
      await _addColumnIfMissing(db, 'sales', column, 'text');
    }
    for (final column in const [
      'amount_received',
      'deposit_amount',
      'outstanding_credit',
    ]) {
      await _addColumnIfMissing(db, 'sales', column, 'real not null default 0');
    }

    for (final column in const ['customer_id', 'created_at', 'deleted_at']) {
      await _addColumnIfMissing(db, 'financial_transactions', column, 'text');
    }
    for (final column in const [
      'deposit_amount',
      'outstanding_credit',
      'expense_outlay',
    ]) {
      await _addColumnIfMissing(
        db,
        'financial_transactions',
        column,
        'real not null default 0',
      );
    }

    for (final table in const ['customers', 'suppliers']) {
      await _addColumnIfMissing(db, table, 'created_at', 'text');
      await _addColumnIfMissing(db, table, 'contact_person', 'text');
      await _addColumnIfMissing(db, table, 'notes', 'text');
      await _addColumnIfMissing(
        db,
        table,
        'is_active',
        'integer not null default 1',
      );
    }

    await _addColumnIfMissing(db, 'expenses', 'created_at', 'text');
    await _addColumnIfMissing(db, 'expenses', 'deleted_at', 'text');
    await _addColumnIfMissing(db, 'orders', 'created_at', 'text');
    await _addColumnIfMissing(db, 'orders', 'paid_at', 'text');
    await _addColumnIfMissing(db, 'orders', 'invoice_number', 'integer');
    await _addColumnIfMissing(
      db,
      'orders',
      'subtotal_amount',
      'real not null default 0',
    );
    await _addColumnIfMissing(
      db,
      'orders',
      'tax_amount',
      'real not null default 0',
    );

    await db.execute('''
      insert or replace into quarantine (
        id,
        source_mortality_id,
        batch_id,
        farm_id,
        user_id,
        isolation_room_id,
        sick_count,
        diagnosis,
        symptoms,
        status,
        log_date,
        created_at,
        is_deleted,
        deleted_at,
        is_synced
      )
      select
        'quarantine_' || id,
        id,
        batch_id,
        farm_id,
        user_id,
        isolation_room_id,
        count,
        reason,
        coalesce(category, sub_category),
        'ACTIVE',
        log_date,
        coalesce(created_at, log_date),
        is_deleted,
        deleted_at,
        is_synced
      from mortality
      where upper(type) = 'SICK'
    ''');
    await db.execute(
      "delete from mortality where upper(type) = 'SICK' and is_synced = 1",
    );
  }

  Future<void> _addColumnIfMissing(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('pragma table_info($table)');
    final exists = columns.any((row) => row['name'] == column);
    if (!exists) {
      await db.execute('alter table $table add column $column $definition');
    }
  }

  Future<void> _createWebSchemaCacheTables(Database db) async {
    await db.execute('''
      create table if not exists farms (
        id text primary key,
        name text not null,
        location text,
        capacity integer not null default 0,
        subscription_tier text,
        master_license_status text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists farm_members (
        id text primary key,
        farm_id text not null,
        user_id text not null,
        role text not null,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists user_permissions (
        id text primary key,
        user_id text not null,
        farm_id text not null,
        can_view_finance integer not null default 0,
        can_edit_finance integer not null default 0,
        can_view_inventory integer not null default 0,
        can_edit_inventory integer not null default 0,
        can_view_batches integer not null default 0,
        can_edit_batches integer not null default 0,
        can_view_sales integer not null default 0,
        can_edit_sales integer not null default 0,
        can_view_eggs integer not null default 0,
        can_edit_eggs integer not null default 0,
        can_view_feeding integer not null default 0,
        can_edit_feeding integer not null default 0,
        can_view_houses integer not null default 0,
        can_edit_houses integer not null default 0,
        can_view_mortality integer not null default 0,
        can_edit_mortality integer not null default 0,
        can_view_quarantine integer not null default 0,
        can_edit_quarantine integer not null default 0,
        can_view_customers integer not null default 0,
        can_edit_customers integer not null default 0,
        can_view_team integer not null default 0,
        can_edit_team integer not null default 0
      )
    ''');

    await db.execute('''
      create table if not exists farm_settings (
        farm_id text primary key,
        eggs_per_crate integer not null default 30,
        currency text not null default 'GHS',
        egg_record_reminder_time text,
        feed_record_reminder_time text
      )
    ''');

    await db.execute('''
      create table if not exists houses (
        id text primary key,
        farm_id text not null,
        user_id text,
        name text not null,
        capacity integer not null default 0,
        current_temperature real,
        current_humidity real,
        is_isolation integer not null default 0,
        environmental_state text,
        last_environment_log_at text,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists house_environment_logs (
        id text primary key,
        house_id text not null,
        farm_id text not null,
        user_id text,
        temperature real,
        humidity real,
        ammonia_level real,
        ventilation_state text,
        water_state text,
        note text,
        log_date text not null,
        created_at text
      )
    ''');

    await db.execute('''
      create table if not exists batches (
        id text primary key,
        farm_id text not null,
        house_id text not null,
        user_id text,
        batch_name text not null,
        breed_type text,
        bird_strain text,
        age_days integer,
        type text not null,
        status text not null,
        active_state text,
        current_count integer not null,
        initial_count integer not null,
        isolation_count integer not null default 0,
        arrival_date text not null,
        local_batch_id integer,
        is_deleted integer not null default 0,
        created_at text,
        deleted_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists inventory (
        id text primary key,
        farm_id text not null,
        user_id text,
        item_name text not null,
        stock_level real not null,
        unit text not null,
        category text,
        item_group text,
        variant_name text,
        storage_location text,
        reorder_level real,
        cost_per_unit real,
        egg_category_id text,
        supplier_id text,
        is_deleted integer not null default 0,
        created_at text,
        deleted_at text,
        last_restocked_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists egg_production (
        id text primary key,
        local_queue_id integer,
        batch_id text not null,
        farm_id text not null,
        user_id text not null,
        eggs_collected integer not null,
        crates_collected real,
        eggs_remaining integer not null default 0,
        unusable_count integer not null default 0,
        cracked_count integer not null default 0,
        crack_percentage real not null default 0,
        category_id text,
        quality_grade text,
        small_count integer not null default 0,
        medium_count integer not null default 0,
        large_count integer not null default 0,
        is_sorted integer not null default 0,
        log_date text not null,
        created_at text,
        is_deleted integer not null default 0,
        deleted_at text,
        is_synced integer not null default 0
      )
    ''');

    await db.execute('''
      create table if not exists daily_feeding_logs (
        id text primary key,
        local_queue_id integer,
        batch_id text,
        feed_type_id text,
        feed_type_label text,
        formulation_id text,
        farm_id text not null,
        user_id text,
        amount_consumed real not null,
        remaining_sack_count real,
        note text,
        log_date text not null,
        created_at text,
        is_deleted integer not null default 0,
        deleted_at text,
        is_synced integer not null default 0
      )
    ''');

    await db.execute('''
      create table if not exists mortality (
        id text primary key,
        local_queue_id integer,
        batch_id text not null,
        farm_id text not null,
        house_id text,
        user_id text not null,
        count integer not null,
        type text not null default 'DEAD',
        reason text,
        category text,
        sub_category text,
        isolation_room_id text,
        mortality_percent real not null default 0,
        loss_trend text,
        log_date text not null,
        created_at text,
        is_deleted integer not null default 0,
        deleted_at text,
        is_synced integer not null default 0
      )
    ''');

    await db.execute('''
      create table if not exists quarantine (
        id text primary key,
        source_mortality_id text,
        batch_id text not null,
        farm_id text not null,
        house_id text,
        isolation_room_id text,
        user_id text,
        sick_count integer not null default 0,
        diagnosis text,
        symptoms text,
        treatment_plan text,
        medication_name text,
        recovery_count integer not null default 0,
        recovery_rate real not null default 0,
        status text not null default 'ACTIVE',
        log_date text not null,
        recovered_at text,
        created_at text,
        updated_at text,
        is_deleted integer not null default 0,
        deleted_at text,
        is_synced integer not null default 0
      )
    ''');

    await db.execute('''
      create table if not exists expenses (
        id text primary key,
        farm_id text not null,
        user_id text not null,
        amount real not null,
        category text not null,
        description text,
        expense_date text not null,
        batch_id text,
        supplier_id text,
        is_deleted integer not null default 0,
        created_at text,
        deleted_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists financial_transactions (
        id text primary key,
        farm_id text not null,
        user_id text not null,
        type text not null,
        category text not null,
        amount real not null,
        payment_status text not null,
        payment_method text not null,
        reference_num text,
        transaction_date text not null,
        description text,
        customer_id text,
        deposit_amount real not null default 0,
        outstanding_credit real not null default 0,
        expense_outlay real not null default 0,
        is_deleted integer not null default 0,
        deleted_at text,
        settled_at text,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists sales (
        id text primary key,
        local_queue_id integer,
        customer_id text,
        customer_name text,
        total_amount real not null,
        amount_received real not null default 0,
        deposit_amount real not null default 0,
        outstanding_credit real not null default 0,
        payment_method text,
        receipt_number text,
        sale_date text not null,
        status text not null default 'completed',
        user_id text not null,
        farm_id text not null,
        is_deleted integer not null default 0,
        deleted_at text,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists sale_items (
        id text primary key,
        sale_id text not null,
        description text not null,
        quantity integer not null,
        unit_price real not null,
        total_price real not null,
        farm_id text not null
      )
    ''');

    await db.execute('''
      create table if not exists customers (
        id text primary key,
        farm_id text not null,
        name text not null,
        phone text,
        email text,
        address text,
        contact_person text,
        notes text,
        balance_owed real not null default 0,
        is_active integer not null default 1,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists orders (
        id text primary key,
        farm_id text not null,
        customer_id text,
        invoice_number integer,
        subtotal_amount real not null default 0,
        tax_amount real not null default 0,
        total_amount real not null,
        currency text not null default 'USD',
        status text not null default 'PENDING',
        discount_amount real not null default 0,
        order_date text not null,
        paid_at text,
        user_id text not null,
        is_deleted integer not null default 0,
        deleted_at text,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists order_items (
        id text primary key,
        order_id text not null,
        description text not null,
        quantity integer not null,
        unit_price real not null,
        total_price real not null,
        inventory_id text,
        livestock_id text
      )
    ''');

    await db.execute('''
      create table if not exists health_records (
        id text primary key,
        batch_id text,
        record_type text,
        description text,
        record_date text not null,
        farm_id text not null
      )
    ''');

    await db.execute('''
      create table if not exists weight_records (
        id text primary key,
        batch_id text not null,
        average_weight real not null,
        log_date text not null,
        user_id text not null,
        farm_id text not null,
        created_at text
      )
    ''');

    await db.execute('''
      create table if not exists vaccination_schedules (
        id text primary key,
        batch_id text not null,
        vaccine_name text not null,
        scheduled_date text not null,
        status text not null default 'PENDING',
        notes text,
        farm_id text not null
      )
    ''');

    await db.execute('''
      create table if not exists medication_schedules (
        id text primary key,
        batch_id text not null,
        medication_name text not null,
        scheduled_date text not null,
        status text not null default 'PENDING',
        notes text,
        farm_id text not null
      )
    ''');

    await db.execute('''
      create table if not exists suppliers (
        id text primary key,
        farm_id text not null,
        name text not null,
        phone text,
        email text,
        address text,
        contact_person text,
        notes text,
        balance_owed real not null default 0,
        is_active integer not null default 1,
        created_at text,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists egg_categories (
        id text primary key,
        farm_id text not null,
        name text not null,
        description text,
        is_stock_internal integer not null default 1,
        selling_price real not null default 0,
        unit_size integer not null default 30,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists feed_formulations (
        id text primary key,
        farm_id text not null,
        name text not null,
        notes text,
        target_livestock text,
        type text not null,
        stock_level real not null default 0,
        updated_at text
      )
    ''');

    await db.execute('''
      create table if not exists feed_formulation_ingredients (
        id text primary key,
        formulation_id text not null,
        inventory_id text not null,
        quantity real not null,
        unit text not null
      )
    ''');

    await db.execute('''
      create table if not exists isolation_rooms (
        id text primary key,
        farm_id text not null,
        name text not null,
        capacity integer not null,
        user_id text not null,
        updated_at text
      )
    ''');

    await db.execute(
      'create index if not exists idx_batches_farm_active '
      'on batches(farm_id, status, is_deleted)',
    );
    await db.execute(
      'create index if not exists idx_egg_production_batch_date '
      'on egg_production(batch_id, log_date)',
    );
    await db.execute(
      'create index if not exists idx_feeding_logs_batch_date '
      'on daily_feeding_logs(batch_id, log_date)',
    );
    await db.execute(
      'create index if not exists idx_house_environment_logs_house_date '
      'on house_environment_logs(house_id, log_date)',
    );
    await db.execute(
      'create index if not exists idx_mortality_batch_date '
      'on mortality(batch_id, log_date)',
    );
    await db.execute(
      'create index if not exists idx_quarantine_farm_status '
      'on quarantine(farm_id, status, is_deleted)',
    );
    await db.execute(
      'create index if not exists idx_quarantine_batch_date '
      'on quarantine(batch_id, log_date)',
    );
    await db.execute(
      'create index if not exists idx_sales_farm_date '
      'on sales(farm_id, sale_date)',
    );
    await db.execute(
      'create index if not exists idx_expenses_farm_date '
      'on expenses(farm_id, expense_date)',
    );
    await db.execute(
      'create index if not exists idx_transactions_farm_date '
      'on financial_transactions(farm_id, transaction_date)',
    );
  }
}

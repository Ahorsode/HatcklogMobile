import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../../../core/models/app_user.dart';
import '../../../core/storage/local_database.dart';

class MobileGoogleAuthResult {
  const MobileGoogleAuthResult({
    required this.user,
    required this.isNewMobileSocialRegistrant,
  });

  final AppUser user;
  final bool isNewMobileSocialRegistrant;
}

class CloudSyncSnapshot {
  const CloudSyncSnapshot({
    required this.pulledAt,
    required this.recordsByLocalTable,
  });

  final DateTime pulledAt;
  final Map<String, List<Map<String, Object?>>> recordsByLocalTable;
}

class SupabaseRemoteApi {
  const SupabaseRemoteApi._(this._client);

  final SupabaseClient? _client;

  bool get isConfigured => _client != null;

  static Future<SupabaseRemoteApi> fromEnvironment({
    bool autoRefreshToken = true,
  }) async {
    final config = await SupabaseConfig.load();
    if (!config.isConfigured) {
      return const SupabaseRemoteApi._(null);
    }

    final supabase = await Supabase.initialize(
      url: config.url,
      anonKey: config.clientKey,
      authOptions: FlutterAuthClientOptions(autoRefreshToken: autoRefreshToken),
    );
    return SupabaseRemoteApi._(supabase.client);
  }

  void setAutoRefreshEnabled(bool enabled) {
    final client = _client;
    if (client == null) {
      return;
    }
    if (enabled) {
      client.auth.startAutoRefresh();
    } else {
      client.auth.stopAutoRefresh();
    }
  }

  Future<AppUser> signInWithPhone({
    required String phoneNumber,
    required String password,
  }) async {
    return signInWithCredentials(identifier: phoneNumber, password: password);
  }

  Future<AppUser> signInWithCredentials({
    required String identifier,
    String? fallbackIdentifier,
    required String password,
  }) async {
    final client = _requireClient();
    final credential = _credentialParts(
      identifier,
      fallbackIdentifier: fallbackIdentifier,
    );
    final authResponse = await _signInWithCredentialCandidates(
      client,
      credential,
      password,
    );
    final authUser = authResponse.user ?? client.auth.currentUser;
    if (authUser == null) {
      throw const AuthException('Supabase did not return a signed-in user.');
    }

    return _appUserFromAuthUser(
      authUser,
      fallbackIdentifier: credential.fallbackIdentifier,
    );
  }

  Future<AppUser?> currentAuthenticatedUser() async {
    final client = _client;
    if (client == null) {
      return null;
    }

    final authUser = client.auth.currentUser;
    if (authUser == null) {
      return null;
    }

    final authEmail = _asString(authUser.email).trim().toLowerCase();
    final authPhone = _asString(authUser.phone).trim();
    return _appUserFromAuthUser(
      authUser,
      fallbackIdentifier: authEmail.isEmpty ? authPhone : authEmail,
    );
  }

  Future<AppUser> signUpWithCredentials({
    required String identifier,
    String? fallbackIdentifier,
    required String password,
  }) async {
    final client = _requireClient();
    final credential = _credentialParts(
      identifier,
      fallbackIdentifier: fallbackIdentifier,
    );
    final AuthResponse authResponse;
    try {
      authResponse = await client.auth.signUp(
        email: credential.authEmail,
        password: password,
        data: {
          'mobile_client': true,
          if (credential.isPhoneMask) ...{
            'phone_number': credential.fallbackIdentifier,
            'auth_identity_mask': credential.authEmail,
          },
        },
      );
    } on AuthException {
      rethrow;
    }
    final authUser = authResponse.user ?? client.auth.currentUser;
    if (authUser == null) {
      throw const AuthException('Supabase did not return a registered user.');
    }

    return _appUserFromAuthUser(
      authUser,
      fallbackIdentifier: credential.fallbackIdentifier,
    );
  }

  Future<MobileGoogleAuthResult> signInWithGoogleTokens({
    required String idToken,
    required String accessToken,
    required String email,
  }) async {
    final client = _requireClient();
    final requestedEmail = email.trim().toLowerCase();
    final profileBeforeSignIn = requestedEmail.isEmpty
        ? null
        : await _safeReadWebUserProfileByEmail(requestedEmail);
    final authResponse = await client.auth.signInWithIdToken(
      provider: OAuthProvider.google,
      idToken: idToken,
      accessToken: accessToken,
    );
    final authUser = authResponse.user ?? client.auth.currentUser;
    if (authUser == null) {
      throw const AuthException('Supabase did not return a Google user.');
    }

    final authenticatedEmail = _asString(authUser.email).trim().toLowerCase();
    final lookupEmail = authenticatedEmail.isEmpty
        ? requestedEmail
        : authenticatedEmail;
    var profile =
        profileBeforeSignIn ??
        (lookupEmail.isEmpty
            ? null
            : await _safeReadWebUserProfileByEmail(lookupEmail));
    final hadExistingProfile = profile != null;
    profile ??= await _linkPendingInvitationForGoogleUser(
      authUser,
      lookupEmail,
    );
    if (profile == null) {
      await client.auth.signOut();
      throw const AuthException(
        'No active farm assignment found for this email address. Please request an invite from your Farm Owner.',
      );
    }

    final user = await _appUserFromAuthUser(
      authUser,
      fallbackIdentifier: lookupEmail,
      preferredProfile: profile,
    );
    if (user.activeFarmId.trim().isEmpty) {
      await client.auth.signOut();
      throw const AuthException(
        'No active farm assignment found for this email address. Please request an invite from your Farm Owner.',
      );
    }
    return MobileGoogleAuthResult(
      user: user,
      isNewMobileSocialRegistrant: !hadExistingProfile,
    );
  }

  Future<AppUser> completeInitialSetup({
    required AppUser user,
    required String newPassword,
    required String firstName,
    required String lastName,
  }) async {
    final client = _requireClient();

    await client.auth.updateUser(
      UserAttributes(
        password: newPassword,
        data: {
          'first_name': firstName,
          'last_name': lastName,
          'onboarding_completed': true,
        },
      ),
    );

    await _updateWebUserProfile(user.id, firstName, lastName);

    return user.copyWith(
      firstName: firstName,
      lastName: lastName,
      requiresInitialSetup: false,
      authenticatedOffline: false,
    );
  }

  Future<void> pushQueuedInput(PendingSyncInput input) async {
    switch (input.inputType) {
      case 'egg_collection':
        await _pushEggCollection(input);
      case 'feed_usage':
        await _pushFeedUsage(input);
      case 'mortality':
        await _pushMortality(input);
      case 'expense_allocation':
        await _pushExpenseAllocation(input);
      case 'sales_invoice':
        await _pushSalesInvoice(input);
      case 'farm_gate_sale':
        await _pushFarmGateSale(input);
      case 'role_promotion':
        await _pushRolePromotion(input);
      default:
        throw StateError('Unsupported worker input type: ${input.inputType}');
    }
  }

  Future<void> promoteFarmMemberAndRevokeSessions({
    required String farmId,
    required String targetUserId,
    required String newRole,
  }) async {
    final client = _requireClient();
    await client.rpc(
      'promote_farm_member_and_revoke_sessions',
      params: {
        'p_farm_id': farmId,
        'p_target_user_id': targetUserId,
        'p_new_role': newRole,
      },
    );
  }

  Future<void> signOut() async {
    final client = _client;
    if (client != null) {
      await client.auth.signOut(scope: SignOutScope.global);
    }
  }

  Future<CloudSyncSnapshot> fetchOperationalSnapshot({
    required AppUser user,
    DateTime? modifiedAfter,
  }) async {
    final farmId = user.activeFarmId;
    if (farmId.isEmpty) {
      return CloudSyncSnapshot(
        pulledAt: DateTime.now().toUtc(),
        recordsByLocalTable: const {},
      );
    }

    final records = <String, List<Map<String, Object?>>>{};
    void addRows(String localTable, Iterable<Map<String, Object?>> rows) {
      final bucket = records.putIfAbsent(localTable, () => []);
      bucket.addAll(rows);
    }

    final farms = await _selectFarmRows(
      'farms',
      farmId,
      farmColumn: 'id',
      updatedColumn: 'updatedAt',
      modifiedAfter: modifiedAfter,
    );
    addRows('farms', farms.map(_mapFarm));

    final farmMembers = await _selectFarmRows(
      'farm_members',
      farmId,
      farmColumn: 'farmId',
      updatedColumn: 'updatedAt',
      modifiedAfter: modifiedAfter,
    );
    addRows('farm_members', farmMembers.map(_mapFarmMember));

    final userIds = <String>{user.id};
    for (final member in farmMembers) {
      final memberUserId = _asString(member['userId']);
      if (memberUserId.isNotEmpty) {
        userIds.add(memberUserId);
      }
    }
    final users = await _selectRowsByIds('users', 'id', userIds);
    addRows('local_users', users.map((row) => _mapUser(row, user)));

    final farmScopedQueries = await Future.wait([
      _selectFarmRows(
        'user_permissions',
        farmId,
        farmColumn: 'farm_id',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'farm_settings',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'houses',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'batches',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'inventory',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'egg_production',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'daily_feeding_logs',
        farmId,
        farmColumn: 'farmId',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'mortality',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'expenses',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'financial_transactions',
        farmId,
        farmColumn: 'farm_id',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'sales',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows('sale_items', farmId, farmColumn: 'farmId'),
      _selectFarmRows('customers', farmId, farmColumn: 'farmId'),
      _selectFarmRows(
        'orders',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows('health_records', farmId, farmColumn: 'farmId'),
      _selectFarmRows(
        'weight_records',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows('vaccination_schedules', farmId, farmColumn: 'farmId'),
      _selectFarmRows('medication_schedules', farmId, farmColumn: 'farmId'),
      _selectFarmRows('suppliers', farmId, farmColumn: 'farmId'),
      _selectFarmRows('egg_categories', farmId, farmColumn: 'farmId'),
      _selectFarmRows(
        'feed_formulations',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRows(
        'isolation_rooms',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
    ]);

    final userPermissions = farmScopedQueries[0];
    final farmSettings = farmScopedQueries[1];
    final houses = farmScopedQueries[2];
    final batches = farmScopedQueries[3];
    final inventory = farmScopedQueries[4];
    final eggProduction = farmScopedQueries[5];
    final feedingLogs = farmScopedQueries[6];
    final mortality = farmScopedQueries[7];
    final mortalityDeaths = mortality.where((row) => !_isSickHealthEvent(row));
    final quarantineCases = mortality.where(_isSickHealthEvent);
    final expenses = farmScopedQueries[8];
    final transactions = farmScopedQueries[9];
    final sales = farmScopedQueries[10];
    final saleItems = farmScopedQueries[11];
    final customers = farmScopedQueries[12];
    final orders = farmScopedQueries[13];
    final healthRecords = farmScopedQueries[14];
    final weightRecords = farmScopedQueries[15];
    final vaccinationSchedules = farmScopedQueries[16];
    final medicationSchedules = farmScopedQueries[17];
    final suppliers = farmScopedQueries[18];
    final eggCategories = farmScopedQueries[19];
    final feedFormulations = farmScopedQueries[20];
    final isolationRooms = farmScopedQueries[21];

    addRows('user_permissions', userPermissions.map(_mapUserPermission));
    addRows('farm_settings', farmSettings.map(_mapFarmSettings));
    addRows('houses', houses.map(_mapHouse));
    addRows(
      'house_environment_logs',
      houses.where(_hasEnvironmentState).map(_mapHouseEnvironmentLog),
    );
    addRows('batches', batches.map(_mapBatch));
    addRows('inventory', inventory.map(_mapInventory));
    addRows('egg_production', eggProduction.map(_mapEggProduction));
    addRows('daily_feeding_logs', feedingLogs.map(_mapFeedingLog));
    addRows('mortality', mortalityDeaths.map(_mapMortality));
    addRows('quarantine', quarantineCases.map(_mapQuarantine));
    addRows('expenses', expenses.map(_mapExpense));
    addRows('financial_transactions', transactions.map(_mapTransaction));
    addRows('sales', sales.map(_mapSale));
    addRows('sale_items', saleItems.map(_mapSaleItem));
    addRows('customers', customers.map(_mapCustomer));
    addRows('orders', orders.map(_mapOrder));
    addRows('health_records', healthRecords.map(_mapHealthRecord));
    addRows('weight_records', weightRecords.map(_mapWeightRecord));
    addRows('vaccination_schedules', vaccinationSchedules.map(_mapVaccination));
    addRows('medication_schedules', medicationSchedules.map(_mapMedication));
    addRows('suppliers', suppliers.map(_mapSupplier));
    addRows('egg_categories', eggCategories.map(_mapEggCategory));
    addRows('feed_formulations', feedFormulations.map(_mapFeedFormulation));
    addRows('isolation_rooms', isolationRooms.map(_mapIsolationRoom));

    final orderItems = await _selectRowsByIds(
      'order_items',
      'orderId',
      orders.map((row) => _asString(row['id'])).where((id) => id.isNotEmpty),
    );
    addRows('order_items', orderItems.map(_mapOrderItem));

    final formulationIngredients = await _selectRowsByIds(
      'feed_formulation_ingredients',
      'formulationId',
      feedFormulations
          .map((row) => _asString(row['id']))
          .where((id) => id.isNotEmpty),
    );
    addRows(
      'feed_formulation_ingredients',
      formulationIngredients.map(_mapFeedIngredient),
    );

    return CloudSyncSnapshot(
      pulledAt: DateTime.now().toUtc(),
      recordsByLocalTable: records,
    );
  }

  SupabaseClient _requireClient() {
    final client = _client;
    if (client == null) {
      throw const AuthException(
        'Supabase is not configured. Provide SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY.',
      );
    }
    return client;
  }

  Future<List<Map<String, dynamic>>> _selectFarmRows(
    String table,
    String farmId, {
    required String farmColumn,
    String? updatedColumn,
    DateTime? modifiedAfter,
  }) async {
    dynamic query = _requireClient()
        .from(table)
        .select()
        .eq(farmColumn, farmId);
    if (modifiedAfter != null && updatedColumn != null) {
      query = query.gte(updatedColumn, modifiedAfter.toUtc().toIso8601String());
    }
    final response = await query.limit(1000);
    return _asRows(response);
  }

  Future<List<Map<String, dynamic>>> _selectRowsByIds(
    String table,
    String column,
    Iterable<String> ids,
  ) async {
    final filteredIds = ids.where((id) => id.isNotEmpty).toSet().toList();
    if (filteredIds.isEmpty) {
      return const [];
    }
    final response = await _requireClient()
        .from(table)
        .select()
        .inFilter(column, filteredIds)
        .limit(1000);
    return _asRows(response);
  }

  List<Map<String, dynamic>> _asRows(Object? response) {
    final rows = (response as List?) ?? const [];
    return rows.map((row) => Map<String, dynamic>.from(row as Map)).toList();
  }

  Map<String, Object?> _mapUser(Map<String, dynamic> row, AppUser activeUser) {
    final id = _asString(row['id']);
    final email = _asString(row['email']).trim().toLowerCase();
    final phone = _asString(row['phone_number']).trim();
    final loginIdentifier = phone.isNotEmpty
        ? phone
        : email.isNotEmpty
        ? email
        : id;
    final isActiveUser = id == activeUser.id;
    return {
      'id': id,
      'phone_number': loginIdentifier,
      'email': email,
      'role': _asString(row['role']),
      'first_name': _asString(row['firstname']),
      'last_name': _asString(row['surname']),
      'active_farm_id': isActiveUser ? activeUser.activeFarmId : '',
      'active_batch_id': isActiveUser ? activeUser.activeBatchId : '',
      'updated_at': _timestamp(row['updated_at'] ?? row['created_at']),
    };
  }

  Map<String, Object?> _mapFarm(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'name': _asString(row['name']),
      'location': _nullIfEmpty(_asString(row['location'])),
      'capacity': _asInt(row['capacity']),
      'subscription_tier': _asString(row['subscriptionTier']),
      'master_license_status': _asString(row['master_license_status']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapFarmMember(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['userId']),
      'role': _asString(row['role']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapUserPermission(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'user_id': _asString(row['user_id']),
      'farm_id': _asString(row['farm_id']),
      'can_view_finance': _boolInt(row['can_view_finance']),
      'can_edit_finance': _boolInt(row['can_edit_finance']),
      'can_view_inventory': _boolInt(row['can_view_inventory']),
      'can_edit_inventory': _boolInt(row['can_edit_inventory']),
      'can_view_batches': _boolInt(row['can_view_batches']),
      'can_edit_batches': _boolInt(row['can_edit_batches']),
      'can_view_sales': _boolInt(row['can_view_sales']),
      'can_edit_sales': _boolInt(row['can_edit_sales']),
      'can_view_eggs': _boolInt(row['can_view_eggs']),
      'can_edit_eggs': _boolInt(row['can_edit_eggs']),
      'can_view_feeding': _boolInt(row['can_view_feeding']),
      'can_edit_feeding': _boolInt(row['can_edit_feeding']),
      'can_view_houses': _boolInt(row['can_view_houses']),
      'can_edit_houses': _boolInt(row['can_edit_houses']),
      'can_view_mortality': _boolInt(row['can_view_mortality']),
      'can_edit_mortality': _boolInt(row['can_edit_mortality']),
      'can_view_quarantine': _boolInt(row['can_view_quarantine']),
      'can_edit_quarantine': _boolInt(row['can_edit_quarantine']),
      'can_view_customers': _boolInt(row['can_view_customers']),
      'can_edit_customers': _boolInt(row['can_edit_customers']),
      'can_view_team': _boolInt(row['can_view_team']),
      'can_edit_team': _boolInt(row['can_edit_team']),
    };
  }

  Map<String, Object?> _mapFarmSettings(Map<String, dynamic> row) {
    return {
      'farm_id': _asString(row['farmId']),
      'eggs_per_crate': _asInt(row['eggsPerCrate'], fallback: 30),
      'currency': _asString(row['currency']),
      'egg_record_reminder_time': _asString(row['eggRecordReminderTime']),
      'feed_record_reminder_time': _asString(row['feedRecordReminderTime']),
    };
  }

  Map<String, Object?> _mapHouse(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['userId']),
      'name': _asString(row['name']),
      'capacity': _asInt(row['capacity']),
      'current_temperature': _asDouble(row['currentTemperature']),
      'current_humidity': _asDouble(row['currentHumidity']),
      'is_isolation': _boolInt(row['isIsolation']),
      'environmental_state': _environmentState(row),
      'last_environment_log_at': _timestamp(row['updatedAt']),
      'created_at': _timestamp(row['createdAt']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapHouseEnvironmentLog(Map<String, dynamic> row) {
    return {
      'id': '${_asString(row['id'])}_latest_environment',
      'house_id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['userId']),
      'temperature': _asDouble(row['currentTemperature']),
      'humidity': _asDouble(row['currentHumidity']),
      'ammonia_level': null,
      'ventilation_state': _environmentState(row),
      'water_state': null,
      'note': 'Latest house environment snapshot from web.',
      'log_date': _timestamp(row['updatedAt'] ?? row['createdAt']),
      'created_at': _timestamp(row['updatedAt'] ?? row['createdAt']),
    };
  }

  Map<String, Object?> _mapBatch(Map<String, dynamic> row) {
    final arrivalDate = row['arrivalDate'];
    final status = _asString(row['status']);
    final breedType = _asString(row['breedType']);
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'house_id': _asString(row['houseId']),
      'user_id': _asString(row['userId']),
      'batch_name': _asString(row['batchName']),
      'breed_type': breedType,
      'bird_strain': breedType,
      'age_days': _ageDays(arrivalDate),
      'type': _asString(row['type']),
      'status': status,
      'active_state': status,
      'current_count': _asInt(row['currentCount']),
      'initial_count': _asInt(row['initialCount']),
      'isolation_count': _asInt(row['isolationCount']),
      'arrival_date': _timestamp(arrivalDate),
      'local_batch_id': row['local_batch_id'],
      'is_deleted': _boolInt(row['is_deleted']),
      'created_at': _timestamp(row['createdAt']),
      'deleted_at': _timestamp(row['deleted_at']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapInventory(Map<String, dynamic> row) {
    final category = _asString(row['category']);
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['userId']),
      'item_name': _asString(row['itemName']),
      'stock_level': _asDouble(row['stockLevel']),
      'unit': _asString(row['unit']),
      'category': category,
      'item_group': _inventoryGroup(category),
      'variant_name': _asString(row['variantName']),
      'storage_location': _asString(row['storageLocation']),
      'reorder_level': _asDouble(row['reorderLevel']),
      'cost_per_unit': _asDouble(row['costPerUnit']),
      'egg_category_id': _asString(row['eggCategoryId']),
      'supplier_id': _asString(row['supplierId']),
      'is_deleted': _boolInt(row['is_deleted']),
      'created_at': _timestamp(row['createdAt']),
      'deleted_at': _timestamp(row['deleted_at']),
      'last_restocked_at': _timestamp(row['lastRestockedAt']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapEggProduction(Map<String, dynamic> row) {
    final eggsCollected = _asInt(row['eggsCollected']);
    final crackedCount = _asInt(row['unusableCount']);
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['userId']),
      'eggs_collected': eggsCollected,
      'crates_collected': _asDouble(row['cratesCollected']),
      'eggs_remaining': _asInt(row['eggsRemaining']),
      'unusable_count': crackedCount,
      'cracked_count': crackedCount,
      'crack_percentage': eggsCollected <= 0 ? 0 : crackedCount / eggsCollected,
      'category_id': _asString(row['categoryId']),
      'quality_grade': _asString(row['qualityGrade']),
      'small_count': _asInt(row['smallCount']),
      'medium_count': _asInt(row['mediumCount']),
      'large_count': _asInt(row['largeCount']),
      'is_sorted': _boolInt(row['isSorted']),
      'log_date': _timestamp(row['logDate']),
      'created_at': _timestamp(row['createdAt']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'is_synced': 1,
    };
  }

  Map<String, Object?> _mapFeedingLog(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batch_id']),
      'feed_type_id': _asString(row['feed_type_id']),
      'feed_type_label': _asString(row['feedTypeLabel']),
      'formulation_id': _asString(row['formulation_id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['user_id']),
      'amount_consumed': _asDouble(row['amount_consumed']),
      'remaining_sack_count': _asDouble(row['remainingSackCount']),
      'note': _asString(row['note']),
      'log_date': _timestamp(row['log_date']),
      'created_at': _timestamp(row['createdAt'] ?? row['log_date']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'is_synced': 1,
    };
  }

  Map<String, Object?> _mapMortality(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'farm_id': _asString(row['farmId']),
      'house_id': _asString(row['houseId']),
      'user_id': _asString(row['userId']),
      'count': _asInt(row['count']),
      'type': _asString(row['type']),
      'reason': _asString(row['reason']),
      'category': _asString(row['category']),
      'sub_category': _asString(row['sub_category']),
      'isolation_room_id': _asString(row['isolation_room_id']),
      'mortality_percent': _asDouble(row['mortalityPercent']),
      'loss_trend': _asString(row['lossTrend']),
      'log_date': _timestamp(row['logDate']),
      'created_at': _timestamp(row['createdAt']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'is_synced': 1,
    };
  }

  Map<String, Object?> _mapQuarantine(Map<String, dynamic> row) {
    final count = _asInt(row['count']);
    final recovered = _asInt(row['recoveryCount']);
    return {
      'id': 'quarantine_${_asString(row['id'])}',
      'source_mortality_id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'farm_id': _asString(row['farmId']),
      'house_id': _asString(row['houseId']),
      'isolation_room_id': _asString(row['isolation_room_id']),
      'user_id': _asString(row['userId']),
      'sick_count': count,
      'diagnosis': _asString(row['reason']),
      'symptoms': _symptomSummary(row),
      'treatment_plan': _asString(row['treatmentPlan']),
      'medication_name': _asString(row['medicationName']),
      'recovery_count': recovered,
      'recovery_rate': count <= 0 ? 0 : recovered / count,
      'status': _asString(row['status']).isEmpty
          ? 'ACTIVE'
          : _asString(row['status']),
      'log_date': _timestamp(row['logDate']),
      'recovered_at': _timestamp(row['recoveredAt']),
      'created_at': _timestamp(row['createdAt']),
      'updated_at': _timestamp(row['updatedAt'] ?? row['createdAt']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'is_synced': 1,
    };
  }

  Map<String, Object?> _mapExpense(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'user_id': _asString(row['user_id']),
      'amount': _asDouble(row['amount']),
      'category': _asString(row['category']),
      'description': _asString(row['description']),
      'expense_date': _timestamp(row['expense_date']),
      'batch_id': _asString(row['batch_id']),
      'supplier_id': _asString(row['supplierId']),
      'is_deleted': _boolInt(row['is_deleted']),
      'created_at': _timestamp(row['created_at']),
      'deleted_at': _timestamp(row['deleted_at']),
      'updated_at': _timestamp(row['updated_at']),
    };
  }

  Map<String, Object?> _mapTransaction(Map<String, dynamic> row) {
    final type = _asString(row['type']);
    final amount = _asDouble(row['amount']);
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farm_id']),
      'user_id': _asString(row['user_id']),
      'type': type,
      'category': _asString(row['category']),
      'amount': amount,
      'payment_status': _asString(row['payment_status']),
      'payment_method': _asString(row['payment_method']),
      'reference_num': _asString(row['reference_num']),
      'transaction_date': _timestamp(row['transaction_date']),
      'description': _asString(row['description']),
      'customer_id': _asString(row['customerId']),
      'deposit_amount': _asDouble(row['depositAmount']),
      'outstanding_credit': _asDouble(row['outstandingCredit']),
      'expense_outlay': type.toUpperCase() == 'EXPENSE' ? amount : 0,
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'settled_at': _timestamp(row['settled_at']),
      'created_at': _timestamp(row['created_at']),
      'updated_at': _timestamp(row['updated_at']),
    };
  }

  Map<String, Object?> _mapSale(Map<String, dynamic> row) {
    final total = _asDouble(row['totalAmount']);
    final received = _asDouble(row['amountReceived'], fallback: total);
    return {
      'id': _asString(row['id']),
      'customer_id': _asString(row['customerId']),
      'customer_name': _asString(row['customerName']),
      'total_amount': total,
      'amount_received': received,
      'deposit_amount': received,
      'outstanding_credit': (total - received).clamp(0, double.infinity),
      'payment_method': _asString(row['paymentMethod']),
      'receipt_number': _asString(row['receiptNumber'] ?? row['invoiceNumber']),
      'sale_date': _timestamp(row['saleDate']),
      'status': _asString(row['status']),
      'user_id': _asString(row['userId']),
      'farm_id': _asString(row['farmId']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'created_at': _timestamp(row['createdAt']),
      'updated_at': _timestamp(row['updatedAt'] ?? row['createdAt']),
    };
  }

  Map<String, Object?> _mapSaleItem(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'sale_id': _asString(row['saleId']),
      'description': _asString(row['description']),
      'quantity': _asInt(row['quantity']),
      'unit_price': _asDouble(row['unitPrice']),
      'total_price': _asDouble(row['totalPrice']),
      'farm_id': _asString(row['farmId']),
    };
  }

  Map<String, Object?> _mapCustomer(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'name': _asString(row['name']),
      'phone': _asString(row['phone']),
      'email': _asString(row['email']),
      'address': _asString(row['address']),
      'contact_person': _asString(row['contactPerson']),
      'notes': _asString(row['notes']),
      'balance_owed': _asDouble(row['balanceOwed']),
      'is_active': _boolInt(row['isActive'] ?? true),
      'created_at': _timestamp(row['createdAt']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapOrder(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'customer_id': _asString(row['customerId']),
      'invoice_number': row['invoice_number'],
      'subtotal_amount': _asDouble(row['subtotal_amount']),
      'tax_amount': _asDouble(row['tax_amount']),
      'total_amount': _asDouble(row['totalAmount']),
      'currency': _asString(row['currency']),
      'status': _asString(row['status']),
      'discount_amount': _asDouble(row['discountAmount']),
      'order_date': _timestamp(row['order_date']),
      'paid_at': _timestamp(row['paid_at']),
      'user_id': _asString(row['user_id']),
      'is_deleted': _boolInt(row['is_deleted']),
      'deleted_at': _timestamp(row['deleted_at']),
      'created_at': _timestamp(row['created_at']),
      'updated_at': _timestamp(row['updated_at']),
    };
  }

  Map<String, Object?> _mapOrderItem(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'order_id': _asString(row['orderId']),
      'description': _asString(row['description']),
      'quantity': _asInt(row['quantity']),
      'unit_price': _asDouble(row['unitPrice']),
      'total_price': _asDouble(row['totalPrice']),
      'inventory_id': _asString(row['inventoryId']),
      'livestock_id': _asString(row['livestockId']),
    };
  }

  Map<String, Object?> _mapHealthRecord(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batch_id']),
      'record_type': _asString(row['record_type']),
      'description': _asString(row['description']),
      'record_date': _timestamp(row['record_date']),
      'farm_id': _asString(row['farmId']),
    };
  }

  Map<String, Object?> _mapWeightRecord(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'average_weight': _asDouble(row['averageWeight']),
      'log_date': _timestamp(row['logDate']),
      'user_id': _asString(row['userId']),
      'farm_id': _asString(row['farmId']),
      'created_at': _timestamp(row['createdAt']),
    };
  }

  Map<String, Object?> _mapVaccination(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'vaccine_name': _asString(row['vaccineName']),
      'scheduled_date': _timestamp(row['scheduledDate']),
      'status': _asString(row['status']),
      'notes': _asString(row['notes']),
      'farm_id': _asString(row['farmId']),
    };
  }

  Map<String, Object?> _mapMedication(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'batch_id': _asString(row['batchId']),
      'medication_name': _asString(row['medicationName']),
      'scheduled_date': _timestamp(row['scheduledDate']),
      'status': _asString(row['status']),
      'notes': _asString(row['notes']),
      'farm_id': _asString(row['farmId']),
    };
  }

  Map<String, Object?> _mapSupplier(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'name': _asString(row['name']),
      'phone': _asString(row['phone']),
      'email': _asString(row['email']),
      'address': _asString(row['address']),
      'contact_person': _asString(row['contactPerson']),
      'notes': _asString(row['notes']),
      'balance_owed': _asDouble(row['balanceOwed']),
      'is_active': _boolInt(row['isActive'] ?? true),
      'created_at': _timestamp(row['createdAt']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapEggCategory(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'name': _asString(row['name']),
      'description': _asString(row['description']),
      'is_stock_internal': _boolInt(row['isStockInternal']),
      'selling_price': _asDouble(row['sellingPrice']),
      'unit_size': _asInt(row['unitSize'], fallback: 30),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapFeedFormulation(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'name': _asString(row['name']),
      'notes': _asString(row['notes']),
      'target_livestock': _asString(row['targetLivestock']),
      'type': _asString(row['type']),
      'stock_level': _asDouble(row['stockLevel']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  Map<String, Object?> _mapFeedIngredient(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'formulation_id': _asString(row['formulationId']),
      'inventory_id': _asString(row['inventoryId']),
      'quantity': _asDouble(row['quantity']),
      'unit': _asString(row['unit']),
    };
  }

  Map<String, Object?> _mapIsolationRoom(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'name': _asString(row['name']),
      'capacity': _asInt(row['capacity']),
      'user_id': _asString(row['userId']),
      'updated_at': _timestamp(row['updatedAt']),
    };
  }

  bool _isSickHealthEvent(Map<String, dynamic> row) {
    return _asString(row['type']).trim().toUpperCase() == 'SICK';
  }

  bool _hasEnvironmentState(Map<String, dynamic> row) {
    return _asString(row['currentTemperature']).isNotEmpty ||
        _asString(row['currentHumidity']).isNotEmpty;
  }

  String _environmentState(Map<String, dynamic> row) {
    final temperature = _asDouble(row['currentTemperature']);
    final humidity = _asDouble(row['currentHumidity']);
    if (temperature <= 0 && humidity <= 0) {
      return '';
    }
    if (temperature > 35 || humidity > 80) {
      return 'ALERT';
    }
    if (temperature < 18 || humidity < 35) {
      return 'WATCH';
    }
    return 'NORMAL';
  }

  String _inventoryGroup(String category) {
    final normalized = category.trim().toUpperCase();
    if (normalized.contains('MED')) {
      return 'MEDICATION_STOCK';
    }
    if (normalized.contains('VACC')) {
      return 'VACCINE_VARIANT';
    }
    if (normalized.contains('EQUIP') || normalized.contains('GEAR')) {
      return 'PROCESSING_GEAR';
    }
    if (normalized.contains('RAW') || normalized.contains('SUPPL')) {
      return 'RAW_SUPPLY';
    }
    if (normalized.contains('FEED')) {
      return 'FEED_STOCK';
    }
    return normalized.isEmpty ? 'GENERAL_INVENTORY' : normalized;
  }

  String _symptomSummary(Map<String, dynamic> row) {
    final parts = [
      _asString(row['category']),
      _asString(row['sub_category']),
    ].where((value) => value.trim().isNotEmpty).toList();
    return parts.join(' / ');
  }

  int? _ageDays(Object? arrivalDate) {
    final timestamp = _timestamp(arrivalDate);
    if (timestamp == null || timestamp.isEmpty) {
      return null;
    }
    final parsed = DateTime.tryParse(timestamp);
    if (parsed == null) {
      return null;
    }
    return DateTime.now().difference(parsed).inDays.clamp(0, 99999).toInt();
  }

  Future<Map<String, dynamic>?> _readLegacyProfile(String userId) async {
    final client = _requireClient();
    final response = await client
        .from('profiles')
        .select(
          'id, phone_number, role, first_name, last_name, active_batch_id, onboarding_completed',
        )
        .eq('id', userId)
        .maybeSingle();
    return response;
  }

  Future<Map<String, dynamic>?> _safeReadLegacyProfile(String userId) async {
    try {
      return await _readLegacyProfile(userId);
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _linkPendingInvitationForGoogleUser(
    User authUser,
    String email,
  ) async {
    final normalizedEmail = email.trim().toLowerCase();
    if (normalizedEmail.isEmpty) {
      return null;
    }

    final invite = await _readPendingInvitationByEmail(normalizedEmail);
    if (invite == null) {
      return null;
    }

    final assignedFarmId =
        (invite['farm_id'] ?? invite['farmId'] ?? invite['tenant_id'])
            ?.toString()
            .trim() ??
        '';
    final assignedRole =
        invite['role']?.toString().toLowerCase().trim() ?? 'worker';
    final discoveredRole = assignedRole.isEmpty ? 'worker' : assignedRole;
    final dbRole = discoveredRole.toUpperCase();
    if (assignedFarmId.isEmpty) {
      throw const AuthException(
        'The farm invitation is missing a farm or role assignment. Please request a fresh invite from your Farm Owner.',
      );
    }

    final client = _requireClient();
    final now = DateTime.now().toIso8601String();
    final fullName = _asString(
      authUser.userMetadata?['full_name'] ??
          authUser.userMetadata?['name'] ??
          authUser.userMetadata?['display_name'],
    ).trim();
    final nameParts = fullName.split(RegExp(r'\s+'));
    final firstName = nameParts.isEmpty || nameParts.first.isEmpty
        ? 'New'
        : nameParts.first;
    final lastName = nameParts.length <= 1
        ? 'Staff'
        : nameParts.skip(1).join(' ');

    final profile = {
      'id': authUser.id,
      'email': normalizedEmail,
      'firstname': firstName,
      'surname': lastName,
      'name': fullName.isEmpty ? '$firstName $lastName' : fullName,
      'role': dbRole,
      'created_at': now,
      'updated_at': now,
      'must_change_password': false,
      'is_payment_admin': false,
    };
    await client.from('users').upsert(profile);
    await _safeUpsertLegacyProfileForInvite(
      authUser: authUser,
      email: normalizedEmail,
      farmId: assignedFarmId,
      role: discoveredRole,
      fullName: fullName.isEmpty ? '$firstName $lastName' : fullName,
      createdAt: now,
    );

    await client.from('farm_members').upsert({
      'id': _stableJoinId('farm_member', assignedFarmId, authUser.id),
      'farmId': assignedFarmId,
      'userId': authUser.id,
      'role': dbRole,
      'createdAt': now,
      'updatedAt': now,
    });

    await client.from('user_permissions').upsert({
      'id': _stableJoinId('permission', assignedFarmId, authUser.id),
      'user_id': authUser.id,
      'farm_id': assignedFarmId,
      ..._defaultPermissionsForRole(discoveredRole),
    });

    final inviteId = invite['id']?.toString().trim() ?? '';
    if (inviteId.isNotEmpty) {
      await client
          .from('invitations')
          .update({'status': 'accepted', 'updated_at': now})
          .eq('id', inviteId);
    }

    await client.auth.updateUser(
      UserAttributes(
        data: {
          'farm_id': assignedFarmId,
          'role': discoveredRole,
          'mobile_invitation_linked': true,
        },
      ),
    );

    debugPrint(
      'HatchLog Auth Engine: Linked Google user $normalizedEmail to farm $assignedFarmId as $discoveredRole.',
    );
    return profile;
  }

  Future<void> _safeUpsertLegacyProfileForInvite({
    required User authUser,
    required String email,
    required String farmId,
    required String role,
    required String fullName,
    required String createdAt,
  }) async {
    try {
      await _requireClient().from('profiles').upsert({
        'id': authUser.id,
        'email': email,
        'farm_id': farmId,
        'role': role,
        'full_name': fullName,
        'createdAt': createdAt,
      });
    } on Object catch (error) {
      debugPrint(
        'HatchLog Auth Engine: Optional legacy profiles upsert skipped -> $error',
      );
    }
  }

  Future<Map<String, dynamic>?> _readPendingInvitationByEmail(
    String email,
  ) async {
    try {
      final client = _requireClient();
      final rows = await client
          .from('invitations')
          .select('id, email, role, status, farm_id, phone_number, updated_at')
          .filter('email', 'ilike', email.trim().toLowerCase())
          .inFilter('status', const ['pending', 'PENDING', 'active', 'ACTIVE'])
          .order('updated_at', ascending: false)
          .limit(1);
      final mappedRows = _asRows(rows);
      return mappedRows.isEmpty ? null : mappedRows.first;
    } on Object catch (error) {
      debugPrint(
        'HatchLog Auth Engine: Invitation lookup failed for $email -> $error',
      );
      return null;
    }
  }

  Map<String, bool> _defaultPermissionsForRole(String role) {
    final normalized = role.trim().toLowerCase();
    final isManager = normalized == 'manager' || normalized == 'owner';
    final isAccountant = normalized == 'accountant' || normalized == 'finance';
    final isWorker = normalized == 'worker' || normalized == 'staff';

    return {
      'can_view_finance': isManager || isAccountant,
      'can_edit_finance': isManager || isAccountant,
      'can_view_inventory': isManager || isAccountant || isWorker,
      'can_edit_inventory': isManager,
      'can_view_batches': isManager || isWorker,
      'can_edit_batches': isManager,
      'can_view_sales': isManager || isAccountant,
      'can_edit_sales': isManager || isAccountant,
      'can_view_eggs': isManager || isWorker,
      'can_edit_eggs': isManager || isWorker,
      'can_view_feeding': isManager || isWorker,
      'can_edit_feeding': isManager || isWorker,
      'can_view_houses': isManager || isWorker,
      'can_edit_houses': isManager,
      'can_view_mortality': isManager || isWorker,
      'can_edit_mortality': isManager || isWorker,
      'can_view_customers': isManager || isAccountant,
      'can_edit_customers': isManager || isAccountant,
      'can_view_team': isManager,
      'can_edit_team': isManager,
    };
  }

  String _stableJoinId(String prefix, String farmId, String userId) {
    final raw = '${prefix}_${farmId}_$userId'.toLowerCase();
    return raw.replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
  }

  Future<AppUser> _appUserFromAuthUser(
    User authUser, {
    required String fallbackIdentifier,
    Map<String, dynamic>? preferredProfile,
  }) async {
    final fallbackEmail = _looksLikeEmail(fallbackIdentifier)
        ? fallbackIdentifier.trim().toLowerCase()
        : '';
    final fallbackPhone = fallbackEmail.isEmpty
        ? fallbackIdentifier.trim()
        : '';
    final authEmail = _asString(authUser.email).trim().toLowerCase();
    final authPhone = _asString(authUser.phone).trim();
    final email = authEmail.isEmpty ? fallbackEmail : authEmail;
    final phone = authPhone.isEmpty ? fallbackPhone : authPhone;

    final profile =
        preferredProfile ??
        (email.isEmpty ? null : await _safeReadWebUserProfileByEmail(email)) ??
        (phone.isEmpty ? null : await _safeReadWebUserProfileByPhone(phone)) ??
        await _safeReadLegacyProfile(authUser.id);

    final authMetadataRole = _metadataRole(authUser.appMetadata);
    final userMetadataRole = _metadataRole(authUser.userMetadata);
    final roleValue = authMetadataRole.isNotEmpty
        ? authMetadataRole
        : userMetadataRole.isNotEmpty
        ? userMetadataRole
        : profile?['role'];
    final profileRole = UserRole.fromString(_asString(roleValue));
    final webUserId = _asString(profile?['id']);
    final activeFarm = webUserId.isEmpty
        ? null
        : await _readActiveFarmForUser(webUserId);
    final activeFarmId = _asString(activeFarm?['farm_id']);
    final membershipRole = UserRole.fromString(_asString(activeFarm?['role']));
    final effectiveRole = profileRole.hasUniversalAccess
        ? profileRole
        : membershipRole == UserRole.unknown
        ? profileRole
        : membershipRole;
    final String userRole = effectiveRole.name.toLowerCase().trim();
    debugPrint('HatchLog Auth Engine: Authenticated user role is -> $userRole');
    final activeBatchId = activeFarmId.isEmpty
        ? ''
        : await _readActiveBatchId(activeFarmId);
    final profilePhone = _asString(profile?['phone_number']);
    final profileEmail = _asString(profile?['email']).trim().toLowerCase();
    final resolvedEmail = profileEmail.isEmpty ? email : profileEmail;
    final resolvedPhone = profilePhone.isEmpty ? phone : profilePhone;
    final primaryIdentifier = resolvedPhone.isEmpty
        ? resolvedEmail
        : resolvedPhone;

    return AppUser(
      id: webUserId.isEmpty ? authUser.id : webUserId,
      phoneNumber: primaryIdentifier,
      email: resolvedEmail,
      role: effectiveRole,
      firstName: _asString(profile?['first_name'] ?? profile?['firstname']),
      lastName: _asString(profile?['last_name'] ?? profile?['surname']),
      activeFarmId: activeFarmId,
      activeBatchId: activeBatchId,
      requiresInitialSetup:
          profile?['onboarding_completed'] == false ||
          profile?['must_change_password'] == true,
    );
  }

  Future<Map<String, dynamic>?> _readWebUserProfile(String phoneNumber) async {
    return _readWebUserProfileByPhone(phoneNumber);
  }

  Future<Map<String, dynamic>?> _readWebUserProfileByPhone(
    String phoneNumber,
  ) async {
    try {
      final client = _requireClient();
      final response = await client
          .from('users')
          .select(
            'id, email, phone_number, firstname, surname, role, must_change_password',
          )
          .eq('phone_number', phoneNumber)
          .maybeSingle();
      return response;
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _safeReadWebUserProfileByPhone(
    String phoneNumber,
  ) async {
    for (final candidate in _phoneLookupCandidates(phoneNumber)) {
      final profile = await _readWebUserProfileByPhone(candidate);
      if (profile != null) {
        return profile;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _safeReadWebUserProfileByEmail(
    String email,
  ) async {
    try {
      final client = _requireClient();
      final response = await client
          .from('users')
          .select(
            'id, email, phone_number, firstname, surname, role, must_change_password',
          )
          .eq('email', email.trim().toLowerCase())
          .maybeSingle();
      return response;
    } on Object {
      return null;
    }
  }

  /// Public helper to fetch a user's role by phone number. Returns empty string when not available.
  Future<String> fetchUserRoleByPhone(String phoneNumber) async {
    final profile = await _readWebUserProfile(phoneNumber);
    if (profile == null) return '';
    return _asString(profile['role']);
  }

  Future<String> fetchUserRoleByIdentifier(String identifier) async {
    final profile = _looksLikeEmail(identifier)
        ? await _safeReadWebUserProfileByEmail(identifier)
        : await _safeReadWebUserProfileByPhone(identifier);
    if (profile == null) return '';
    return _asString(profile['role']);
  }

  Future<Map<String, dynamic>?> _readActiveFarmForUser(String userId) async {
    final client = _requireClient();
    final Map<String, dynamic>? membership;
    try {
      membership = await client
          .from('farm_members')
          .select('id, farmId, role')
          .eq('userId', userId)
          .limit(1)
          .maybeSingle();
    } on Object {
      return null;
    }

    if (membership != null) {
      return {'farm_id': membership['farmId'], 'role': membership['role']};
    }

    final Map<String, dynamic>? ownedFarm;
    try {
      ownedFarm = await client
          .from('farms')
          .select('id')
          .eq('userId', userId)
          .limit(1)
          .maybeSingle();
    } on Object {
      return null;
    }

    if (ownedFarm == null) {
      return null;
    }

    return {'farm_id': ownedFarm['id'], 'role': 'OWNER'};
  }

  Future<String> _readActiveBatchId(String farmId) async {
    try {
      final client = _requireClient();
      final batch = await client
          .from('batches')
          .select('id, batchName, local_batch_id')
          .eq('farmId', farmId)
          .eq('status', 'active')
          .eq('is_deleted', false)
          .order('createdAt')
          .limit(1)
          .maybeSingle();
      return _asString(batch?['id']);
    } on Object {
      return '';
    }
  }

  Future<void> _updateWebUserProfile(
    String userId,
    String firstName,
    String lastName,
  ) async {
    final client = _requireClient();
    await client
        .from('users')
        .update({
          'firstname': firstName,
          'surname': lastName,
          'must_change_password': false,
          'updated_at': DateTime.now().toIso8601String(),
        })
        .eq('id', userId);
  }

  Future<void> _verifiedUpsert(
    String table,
    Map<String, Object?> values,
  ) async {
    final client = _requireClient();
    final response = await client
        .from(table)
        .upsert(values)
        .select('id')
        .single();
    final id = _asString(response['id']);
    if (id.isEmpty) {
      throw StateError('Supabase did not confirm $table sync.');
    }
  }

  Future<void> _pushEggCollection(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final batchId = _requiredString(payload, 'batch_id');
    final crates = _asDouble(payload['crates']);
    final singleEggs = _asInt(payload['single_eggs']);
    final eggsPerCrate = _asInt(payload['eggs_per_crate'], fallback: 30);
    final eggsCollected = (crates * eggsPerCrate).round() + singleEggs;

    await _verifiedUpsert('egg_production', {
      'id': input.resolvedServerRecordId,
      'batchId': batchId,
      'farmId': farmId,
      'userId': input.userId,
      'eggsCollected': eggsCollected,
      'cratesCollected': crates,
      'eggsRemaining': eggsCollected,
      'unusableCount': 0,
      'isSorted': false,
      'smallCount': 0,
      'mediumCount': 0,
      'largeCount': 0,
      'logDate': input.createdAt.toIso8601String(),
    });
  }

  Future<void> _pushFeedUsage(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final batchId = _optionalString(payload, 'batch_id');

    await _verifiedUpsert('daily_feeding_logs', {
      'id': input.resolvedServerRecordId,
      'batch_id': batchId.isEmpty ? null : batchId,
      'feed_type_id': _nullIfEmpty(_optionalString(payload, 'feed_type_id')),
      'formulation_id': _nullIfEmpty(
        _optionalString(payload, 'formulation_id'),
      ),
      'amount_consumed': _asDouble(payload['bags']),
      'log_date': input.createdAt.toIso8601String(),
      'farmId': farmId,
      'user_id': input.userId,
    });
  }

  Future<void> _pushMortality(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final batchId = _requiredString(payload, 'batch_id');

    await _verifiedUpsert('mortality', {
      'id': input.resolvedServerRecordId,
      'batchId': batchId,
      'farmId': farmId,
      'userId': input.userId,
      'count': _asInt(payload['count']),
      'type': 'DEAD',
      'reason': _nullIfEmpty(_optionalString(payload, 'reason')),
      'category': _nullIfEmpty(_optionalString(payload, 'category')),
      'sub_category': _nullIfEmpty(_optionalString(payload, 'sub_category')),
      'logDate': input.createdAt.toIso8601String(),
    });
  }

  Future<void> _pushExpenseAllocation(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final allocations = (payload['allocations'] as List?) ?? const [];

    if (allocations.isEmpty) {
      await _verifiedUpsert('expenses', {
        'id': '${input.resolvedServerRecordId}_expense',
        'farmId': farmId,
        'user_id': input.userId,
        'amount': _asDouble(payload['amount']),
        'category': _asString(payload['category']).toUpperCase(),
        'description': _nullIfEmpty(_optionalString(payload, 'description')),
        'expense_date': _asString(payload['expense_date']),
      });
      return;
    }

    for (var index = 0; index < allocations.length; index += 1) {
      final allocation = allocations[index];
      final item = Map<String, dynamic>.from(allocation as Map);
      await _verifiedUpsert('expenses', {
        'id': '${input.resolvedServerRecordId}_expense_$index',
        'farmId': farmId,
        'user_id': input.userId,
        'amount': _asDouble(item['amount']),
        'category': _asString(payload['category']).toUpperCase(),
        'description':
            '${_optionalString(payload, 'description')} (${(_asDouble(item['percent']) * 100).round()}% allocated)',
        'expense_date': _asString(payload['expense_date']),
        'batch_id': _nullIfEmpty(_asString(item['batch_id'])),
      });
    }
  }

  Future<void> _pushSalesInvoice(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final total = _asDouble(payload['total']);
    final customerName = _optionalString(payload, 'customer_name');
    final invoiceNumber = _optionalString(payload, 'invoice_number');
    final saleId = input.resolvedServerRecordId;
    final quantity = _asInt(payload['quantity'], fallback: 1);
    final item = _optionalString(payload, 'item');

    await _verifiedUpsert('sales', {
      'id': saleId,
      'farmId': farmId,
      'userId': input.userId,
      'customerName': customerName,
      'totalAmount': total,
      'saleDate': input.createdAt.toIso8601String(),
      'status': payload['is_paid'] == true ? 'completed' : 'pending',
    });

    await _verifiedUpsert('sale_items', {
      'id': '${saleId}_item_0',
      'saleId': saleId,
      'farmId': farmId,
      'description': item.isEmpty ? 'Sale item' : item,
      'quantity': quantity,
      'unitPrice': quantity <= 0 ? total : total / quantity,
      'totalPrice': total,
    });

    await _verifiedUpsert('financial_transactions', {
      'id': '${saleId}_transaction',
      'farm_id': farmId,
      'user_id': input.userId,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': total,
      'payment_status': payload['is_paid'] == true ? 'PAID' : 'PARTIALLY_PAID',
      'payment_method': _optionalString(payload, 'payment_method'),
      'reference_num': invoiceNumber,
      'transaction_date': input.createdAt.toIso8601String(),
      'description':
          '${payload['quantity']} x ${payload['item']} to $customerName',
    });
  }

  Future<void> _pushFarmGateSale(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final quantity = _asInt(
      payload['quantity_crates'] ?? payload['quantity'],
      fallback: 1,
    );
    final total = _asDouble(payload['amount_received']);
    final saleId = input.resolvedServerRecordId;
    final unit = _optionalString(payload, 'unit');
    final paymentMethod = _optionalString(payload, 'payment_method');
    final timestamp = _optionalString(payload, 'device_timestamp').isEmpty
        ? input.createdAt.toIso8601String()
        : _optionalString(payload, 'device_timestamp');

    await _verifiedUpsert('sales', {
      'id': saleId,
      'farmId': farmId,
      'userId': input.userId,
      'customerName': 'Farm Gate Customer',
      'totalAmount': total,
      'saleDate': timestamp,
      'status': 'completed',
    });

    await _verifiedUpsert('sale_items', {
      'id': '${saleId}_item_0',
      'saleId': saleId,
      'farmId': farmId,
      'description': unit.isEmpty ? 'Farm-gate sale' : 'Farm-gate sale ($unit)',
      'quantity': quantity,
      'unitPrice': quantity <= 0 ? total : total / quantity,
      'totalPrice': total,
    });

    await _verifiedUpsert('financial_transactions', {
      'id': '${saleId}_transaction',
      'farm_id': farmId,
      'user_id': input.userId,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': total,
      'payment_status': 'PAID',
      'payment_method': paymentMethod.isEmpty ? 'CASH' : paymentMethod,
      'reference_num': _optionalString(payload, 'transaction_hash'),
      'transaction_date': timestamp,
      'description': '$quantity ${unit.isEmpty ? 'unit' : unit} farm-gate sale',
    });
  }

  Future<void> _pushRolePromotion(PendingSyncInput input) async {
    final payload = input.payload;
    await promoteFarmMemberAndRevokeSessions(
      farmId: _requiredString(payload, 'farm_id'),
      targetUserId: _requiredString(payload, 'target_user_id'),
      newRole: _requiredString(payload, 'new_role'),
    );
  }

  String _requiredString(Map<String, dynamic> payload, String key) {
    final value = _optionalString(payload, key);
    if (value.isEmpty) {
      throw StateError('Pending sync input is missing required $key.');
    }
    return value;
  }

  String _optionalString(Map<String, dynamic> payload, String key) {
    return _asString(payload[key]);
  }

  String? _nullIfEmpty(String value) {
    return value.isEmpty ? null : value;
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

  String _asString(Object? value) {
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  String? _timestamp(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    final string = value.toString();
    return string.isEmpty ? null : string;
  }

  int _boolInt(Object? value) {
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value == 0 ? 0 : 1;
    }
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1' ? 1 : 0;
  }

  bool _looksLikeEmail(String value) {
    return value.trim().contains('@');
  }

  Future<AuthResponse> _signInWithCredentialCandidates(
    SupabaseClient client,
    _CredentialParts credential,
    String password,
  ) async {
    AuthException? invalidPhoneAttempt;
    for (final authEmail in credential.signInAuthEmails) {
      try {
        return await client.auth.signInWithPassword(
          email: authEmail,
          password: password,
        );
      } on AuthException catch (error) {
        if (!credential.isPhoneMask || !_isInvalidCredentialError(error)) {
          rethrow;
        }
        invalidPhoneAttempt = error;
      }
    }

    if (invalidPhoneAttempt != null) {
      throw const AuthException(_phoneCredentialFailureMessage);
    }
    throw const AuthException('Invalid login credentials.');
  }

  String _metadataRole(Map<String, dynamic>? metadata) {
    if (metadata == null || metadata.isEmpty) {
      return '';
    }
    for (final key in const [
      'role',
      'user_role',
      'userRole',
      'account_role',
      'accountRole',
      'farm_role',
      'farmRole',
    ]) {
      final value = _asString(metadata[key]).trim();
      if (value.isNotEmpty) {
        return value;
      }
    }
    return '';
  }

  List<String> _phoneLookupCandidates(String phoneNumber) {
    final candidates = <String>[];
    void add(String value) {
      final candidate = value.trim();
      if (candidate.isNotEmpty && !candidates.contains(candidate)) {
        candidates.add(candidate);
      }
    }

    final trimmed = phoneNumber.trim();
    add(trimmed);

    final digits = trimmed.replaceAll(RegExp(r'[^\d]'), '');
    add(digits);
    if (digits.isNotEmpty) {
      add('+$digits');
    }
    if (digits.startsWith('0') && digits.length > 1) {
      final international = '233${digits.substring(1)}';
      add(international);
      add('+$international');
    }
    if (digits.startsWith('233') && digits.length > 3) {
      add('0${digits.substring(3)}');
    }

    return candidates;
  }

  static String internalEmailForPhoneIdentifier(String identifier) {
    final digits = identifier.trim().replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) {
      return '';
    }
    return '$digits@$_internalPhoneIdentityDomain';
  }

  _CredentialParts _credentialParts(
    String identifier, {
    String? fallbackIdentifier,
  }) {
    final trimmed = identifier.trim();
    if (_looksLikeEmail(trimmed)) {
      final normalizedEmail = trimmed.toLowerCase();
      return _CredentialParts(
        authEmail: normalizedEmail,
        fallbackIdentifier:
            fallbackIdentifier?.trim().toLowerCase() ?? normalizedEmail,
      );
    }

    final internalEmail = internalEmailForPhoneIdentifier(trimmed);
    if (internalEmail.isEmpty) {
      throw const AuthException('Enter a valid phone number.');
    }
    final authEmailCandidates = _phoneLookupCandidates(trimmed)
        .map(internalEmailForPhoneIdentifier)
        .where((email) => email.isNotEmpty)
        .toList();
    return _CredentialParts(
      authEmail: internalEmail,
      authEmailCandidates: authEmailCandidates,
      fallbackIdentifier: fallbackIdentifier?.trim().isNotEmpty == true
          ? fallbackIdentifier!.trim()
          : trimmed,
      isPhoneMask: true,
    );
  }

  bool _isInvalidCredentialError(AuthException error) {
    final message = error.message.toLowerCase();
    return message.contains('invalid login credentials') ||
        message.contains('invalid credentials') ||
        message.contains('invalid password');
  }
}

class _CredentialParts {
  const _CredentialParts({
    required this.authEmail,
    required this.fallbackIdentifier,
    this.authEmailCandidates = const [],
    this.isPhoneMask = false,
  });

  final String authEmail;
  final String fallbackIdentifier;
  final List<String> authEmailCandidates;
  final bool isPhoneMask;

  Iterable<String> get signInAuthEmails sync* {
    final seen = <String>{};
    if (seen.add(authEmail)) {
      yield authEmail;
    }
    for (final candidate in authEmailCandidates) {
      if (seen.add(candidate)) {
        yield candidate;
      }
    }
  }
}

const _internalPhoneIdentityDomain = 'hatchlog.internal';
const _phoneCredentialFailureMessage =
    'Invalid phone number or master password combination.';

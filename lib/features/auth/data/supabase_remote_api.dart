import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/config/supabase_config.dart';
import '../../../core/models/app_user.dart';
import '../../../core/permissions/farm_permissions.dart';
import '../../../core/permissions/navigation_permissions.dart';
import '../../../core/permissions/staff_permission_defaults.dart';
import '../../../core/storage/local_database.dart';
import '../../../utils/house_climate_utils.dart';

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

  Future<Map<String, Object?>?> fetchUserPermissionsRow({
    required String userId,
    required String farmId,
  }) async {
    if (userId.isEmpty || farmId.isEmpty) {
      return null;
    }
    final client = _requireClient();
    final row = await client
        .from('user_permissions')
        .select()
        .eq('user_id', userId)
        .eq('farm_id', farmId)
        .limit(1)
        .maybeSingle();
    if (row == null) {
      return null;
    }
    return _mapUserPermission(row);
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

    var authUser = client.auth.currentUser;
    if (authUser == null) {
      try {
        final response = await client.auth.refreshSession();
        authUser = response.session?.user ?? client.auth.currentUser;
      } on Object {
        return null;
      }
    }
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
          'onboarding_status': 'active',
        },
      ),
    );

    final phoneNumber = user.phoneNumber.trim();
    if (phoneNumber.isNotEmpty) {
      try {
        await client.rpc(
          'complete_worker_activation',
          params: {
            'p_phone_number': phoneNumber,
            'p_first_name': firstName,
            'p_last_name': lastName,
          },
        );
        return user.copyWith(
          firstName: firstName,
          lastName: lastName,
          requiresInitialSetup: false,
          authenticatedOffline: false,
        );
      } on Object catch (error) {
        debugPrint(
          'HatchLog Auth Engine: complete_worker_activation skipped -> $error',
        );
      }

      final accepted = await _acceptPendingInvitation(
        userId: user.id,
        phoneNumber: phoneNumber,
      );
      if (accepted != null) {
        final farmId = _asString(accepted['farm_id']);
        final farmName = farmId.isEmpty ? '' : await _readFarmName(farmId);
        return user.copyWith(
          firstName: firstName,
          lastName: lastName,
          activeFarmId: farmId,
          activeFarmName: farmName,
          requiresInitialSetup: false,
          authenticatedOffline: false,
        );
      }
    }

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
      case 'inventory_item':
        await _pushInventoryItem(input);
      case 'expense_allocation':
        await _pushExpenseAllocation(input);
      case 'sales_invoice':
        await _pushSalesInvoice(input);
      case 'farm_gate_sale':
        await _pushFarmGateSale(input);
      case 'role_promotion':
        await _pushRolePromotion(input);
      case 'team_permission_update':
        await _pushTeamPermissionUpdate(input);
      case 'restore_record':
        await _pushRestoreRecord(input);
      case 'farm_settings_update':
        await _pushFarmSettingsUpdate(input);
      case 'inventory_reorder_update':
        await _pushInventoryReorderUpdate(input);
      case 'profile_update':
        await _pushProfileUpdate(input);
      case 'worker_log_update':
        await _pushWorkerLogUpdate(input);
      case 'worker_log_delete':
        await _pushWorkerLogDelete(input);
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

  Future<void> updateWorkerPermissions({
    required String farmId,
    required String targetUserId,
    required FarmPermissions permissions,
  }) async {
    final client = _requireClient();
    final map = permissions.toMap();
    await client.from('user_permissions').upsert({
      'id': _stableJoinId('permission', farmId, targetUserId),
      'user_id': targetUserId,
      'farm_id': farmId,
      for (final entry in map.entries) entry.key: entry.value,
    });
    try {
      await client.rpc(
        'invalidate_user_sessions',
        params: {'p_user_id': targetUserId},
      );
    } on Object catch (error) {
      debugPrint('Session invalidation RPC failed: $error');
    }
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
    String? farmIdOverride,
  }) async {
    final override = farmIdOverride?.trim() ?? '';
    final farmId = override.isNotEmpty ? override : user.activeFarmId;
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

    final farms = await _selectFarmRowsSafe(
      'farms',
      farmId,
      farmColumn: 'id',
      updatedColumn: 'updatedAt',
      modifiedAfter: modifiedAfter,
    );
    addRows('farms', farms.map(_mapFarm));

    final farmMembers = await _selectFarmRowsSafe(
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
    final users = await _selectRowsByIdsSafe('users', 'id', userIds);
    for (final row in users) {
      addRows('local_users', [
        _mapUser(
          row,
          user,
          farmMembers: farmMembers,
          farms: farms,
        ),
      ]);
    }

    final farmScopedQueries = await Future.wait([
      _selectFarmRowsSafe(
        'user_permissions',
        farmId,
        farmColumn: 'farm_id',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'farm_settings',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'houses',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'batches',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'inventory',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'egg_production',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'daily_feeding_logs',
        farmId,
        farmColumn: 'farmId',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'mortality',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'expenses',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'financial_transactions',
        farmId,
        farmColumn: 'farm_id',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'sales',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe('sale_items', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe('customers', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe(
        'orders',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updated_at',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe('health_records', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe(
        'weight_records',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'createdAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe('vaccination_schedules', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe('medication_schedules', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe('suppliers', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe('egg_categories', farmId, farmColumn: 'farmId'),
      _selectFarmRowsSafe(
        'feed_formulations',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'isolation_rooms',
        farmId,
        farmColumn: 'farmId',
        updatedColumn: 'updatedAt',
        modifiedAfter: modifiedAfter,
      ),
      _selectFarmRowsSafe(
        'expense_allocations',
        farmId,
        farmColumn: 'farm_id',
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
    final expenseAllocations = farmScopedQueries[22];

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
    addRows(
      'expense_allocations',
      expenseAllocations.map(_mapExpenseAllocation),
    );
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

    final orderItems = await _selectRowsByIdsSafe(
      'order_items',
      'orderId',
      orders.map((row) => _asString(row['id'])).where((id) => id.isNotEmpty),
    );
    addRows('order_items', orderItems.map(_mapOrderItem));

    final formulationIngredients = await _selectRowsByIdsSafe(
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

  Future<List<Map<String, dynamic>>> _selectFarmRowsSafe(
    String table,
    String farmId, {
    required String farmColumn,
    String? updatedColumn,
    DateTime? modifiedAfter,
  }) async {
    try {
      return await _selectFarmRows(
        table,
        farmId,
        farmColumn: farmColumn,
        updatedColumn: updatedColumn,
        modifiedAfter: modifiedAfter,
      );
    } on Object catch (error) {
      debugPrint(
        'WARN: Cloud pull skipped table $table for farm $farmId: $error',
      );
      return const [];
    }
  }

  Future<List<Map<String, dynamic>>> _selectRowsByIdsSafe(
    String table,
    String idColumn,
    Iterable<String> ids,
  ) async {
    try {
      return await _selectRowsByIds(table, idColumn, ids);
    } on Object catch (error) {
      debugPrint('WARN: Cloud pull skipped table $table by ids: $error');
      return const [];
    }
  }

  /// Same livestock source used by the Livestock tab Supabase stream.
  Future<List<Map<String, Object?>>> fetchLivestockBatchesForFarm(
    String farmId,
  ) async {
    if (farmId.isEmpty) {
      return const [];
    }
    final response = await _requireClient()
        .from('batches')
        .select()
        .eq('farmId', farmId)
        .order('createdAt', ascending: false)
        .limit(250);
    final rows = _asRows(response);
    return rows
        .map(_mapBatch)
        .where((row) => _boolInt(row['is_deleted']) == 0)
        .toList(growable: false);
  }

  Future<void> createLivestockBatch({
    required String id,
    required String farmId,
    required String userId,
    required String batchName,
    required String breedType,
    required String type,
    required String houseId,
    required int initialCount,
    required DateTime arrivalDate,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _upsertBatchOnCloud(
      {
        'id': id,
        'farmId': farmId,
        'userId': userId,
        'batchName': batchName,
        'breedType': breedType,
        'type': type,
        'houseId': houseId,
        'initialCount': initialCount,
        'currentCount': initialCount,
        'isolationCount': 0,
        'arrivalDate': arrivalDate.toUtc().toIso8601String(),
        'status': 'active',
        'is_deleted': false,
        'createdAt': now,
        'updatedAt': now,
      },
      batchId: id,
    );
  }

  Future<void> updateLivestockBatch({
    required String id,
    required String farmId,
    required String batchName,
    required String breedType,
    required String type,
    required String houseId,
    required int initialCount,
    required DateTime arrivalDate,
    required String status,
    String growthTargetOverride = '',
  }) async {
    final client = _requireClient();
    final existing = await client
        .from('batches')
        .select('initialCount, currentCount')
        .eq('id', id)
        .eq('farmId', farmId)
        .maybeSingle();
    if (existing == null) {
      throw StateError('Batch not found');
    }

    final existingInitial = _asInt(existing['initialCount']);
    final existingCurrent = _asInt(existing['currentCount']);
    var nextCurrent = existingCurrent;
    if (initialCount != existingInitial) {
      nextCurrent = existingCurrent + (initialCount - existingInitial);
      if (nextCurrent < 0) {
        nextCurrent = 0;
      }
    }

    await client.from('batches').update({
      'batchName': batchName,
      'breedType': breedType,
      'type': type,
      'houseId': houseId,
      'initialCount': initialCount,
      'currentCount': nextCurrent,
      'arrivalDate': arrivalDate.toUtc().toIso8601String(),
      'status': status,
      if (growthTargetOverride.isNotEmpty)
        'growthTargetOverride': growthTargetOverride,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id).eq('farmId', farmId);
  }

  Future<void> deleteLivestockBatch({
    required String id,
    required String farmId,
    required String reason,
  }) async {
    await _requireClient().from('batches').update({
      'is_deleted': true,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
      'status': 'deleted',
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', id).eq('farmId', farmId);
  }

  Future<void> updateLivestockBatchFinancials({
    required String batchId,
    required String farmId,
    required String userId,
    required double actualCost,
    required double carriageInward,
    required List<Map<String, Object>> otherExpenses,
  }) async {
    await _requireClient().from('batches').update({
      'initialCostActual': actualCost,
      'initialCostCarriage': carriageInward,
      'initialCostOther': otherExpenses,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', batchId).eq('farmId', farmId);

    final expenses = <Map<String, Object>>[
      if (actualCost > 0)
        {
          'farmId': farmId,
          'userId': userId,
          'amount': actualCost,
          'category': 'EQUIPMENT',
          'description': 'Initial livestock purchase cost',
          'batch_id': batchId,
          'expenseDate': DateTime.now().toUtc().toIso8601String(),
          'is_deleted': false,
        },
      if (carriageInward > 0)
        {
          'farmId': farmId,
          'userId': userId,
          'amount': carriageInward,
          'category': 'MAINTENANCE',
          'description': 'Livestock carriage inward',
          'batch_id': batchId,
          'expenseDate': DateTime.now().toUtc().toIso8601String(),
          'is_deleted': false,
        },
      for (final item in otherExpenses)
        if (_asDouble(item['amount']) > 0)
          {
            'farmId': farmId,
            'userId': userId,
            'amount': _asDouble(item['amount']),
            'category': 'OTHER',
            'description': _asString(item['label']).isEmpty
                ? 'Other initial livestock cost'
                : _asString(item['label']),
            'batch_id': batchId,
            'expenseDate': DateTime.now().toUtc().toIso8601String(),
            'is_deleted': false,
          },
    ];

    for (final expense in expenses) {
      await _verifiedUpsert('expenses', {
        'id': 'mobile_exp_${batchId}_${expense['category']}_${DateTime.now().microsecondsSinceEpoch}',
        ...expense,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
    }
  }

  Future<void> returnLivestockFromIsolation({
    required String batchId,
    required String farmId,
    required int count,
  }) async {
    final client = _requireClient();
    final batch = await client
        .from('batches')
        .select('isolationCount, currentCount')
        .eq('id', batchId)
        .eq('farmId', farmId)
        .maybeSingle();
    if (batch == null) {
      throw StateError('Batch not found');
    }
    final isolation = _asInt(batch['isolationCount']);
    if (isolation < count) {
      throw StateError('Not enough birds in isolation to recover');
    }
    await client.from('batches').update({
      'isolationCount': isolation - count,
      'currentCount': _asInt(batch['currentCount']) + count,
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', batchId).eq('farmId', farmId);
  }

  Future<void> logLivestockMortalityInIsolation({
    required String batchId,
    required String farmId,
    required String userId,
    required int count,
    required String reason,
  }) async {
    final client = _requireClient();
    final batch = await client
        .from('batches')
        .select('isolationCount')
        .eq('id', batchId)
        .eq('farmId', farmId)
        .maybeSingle();
    if (batch == null) {
      throw StateError('Batch not found');
    }
    final isolation = _asInt(batch['isolationCount']);
    if (isolation < count) {
      throw StateError('Not enough birds in isolation');
    }

    final now = DateTime.now().toUtc().toIso8601String();
    await _verifiedUpsert('mortality', {
      'id': 'mobile_iso_mort_${batchId}_${DateTime.now().microsecondsSinceEpoch}',
      'batchId': batchId,
      'farmId': farmId,
      'userId': userId,
      'count': count,
      'type': 'DEAD',
      'category': 'Health',
      'subCategory': 'Isolation Mortality',
      'reason': reason,
      'logDate': now,
      'createdAt': now,
      'is_deleted': false,
    });

    await client.from('batches').update({
      'isolationCount': isolation - count,
      'updatedAt': now,
    }).eq('id', batchId).eq('farmId', farmId);
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

  Map<String, Object?> _mapUser(
    Map<String, dynamic> row,
    AppUser activeUser, {
    List<Map<String, dynamic>> farmMembers = const [],
    List<Map<String, dynamic>> farms = const [],
  }) {
    final id = _asString(row['id']);
    final email = _asString(row['email']).trim().toLowerCase();
    final phone = _asString(row['phone_number']).trim();
    final loginIdentifier = phone.isNotEmpty
        ? phone
        : email.isNotEmpty
        ? email
        : id;
    final isActiveUser = id == activeUser.id;
    final activeFarmId = isActiveUser ? activeUser.activeFarmId : '';
    final UserRole role;
    if (isActiveUser && activeFarmId.isNotEmpty) {
      final farmOwnerId = farms
              .where((farm) => _asString(farm['id']) == activeFarmId)
              .map((farm) => _asString(farm['userId']))
              .firstOrNull ??
          '';
      Map<String, dynamic>? membership;
      for (final member in farmMembers) {
        if (_asString(member['userId']) == id &&
            _asString(member['farmId']) == activeFarmId) {
          membership = member;
          break;
        }
      }
      role = resolveEffectiveFarmRole(
        farmOwnerId: farmOwnerId,
        userId: id,
        membershipRole: UserRole.fromString(_asString(membership?['role'])),
      );
    } else {
      role = UserRole.fromString(_asString(row['role']));
    }
    return {
      'id': id,
      'phone_number': loginIdentifier,
      'email': email,
      'role': role.name.toLowerCase(),
      'first_name': _asString(row['firstname']),
      'last_name': _asString(row['surname']),
      'active_farm_id': activeFarmId,
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
      'user_id': _asString(row['userId']),
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
      'can_view_health': _boolInt(row['can_view_health']),
      'can_edit_health': _boolInt(row['can_edit_health']),
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
      'is_deleted': 0,
      'is_synced': 1,
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
    final batchName = _asString(row['batchName']);
    final batchType = _asString(row['type']);
    return {
      'id': _asString(row['id']),
      'farm_id': _asString(row['farmId']),
      'house_id': _asString(row['houseId']).isEmpty
          ? 'unassigned'
          : _asString(row['houseId']),
      'user_id': _asString(row['userId']),
      'batch_name': batchName.isEmpty ? 'New Batch' : batchName,
      'breed_type': breedType,
      'bird_strain': breedType,
      'age_days': _ageDays(arrivalDate),
      'type': batchType.isEmpty ? 'POULTRY_BROILER' : batchType,
      'status': status.isEmpty ? 'active' : status,
      'active_state': status.isEmpty ? 'active' : status,
      'current_count': _asInt(row['currentCount']),
      'initial_count': _asInt(row['initialCount']),
      'isolation_count': _asInt(row['isolationCount']),
      'growth_target_override': _asString(row['growthTargetOverride']),
      'initial_cost_actual': _asDouble(row['initialCostActual']),
      'initial_cost_carriage': _asDouble(row['initialCostCarriage']),
      'initial_cost_other': _asDouble(row['initialCostOther']),
      'arrival_date':
          _timestamp(arrivalDate) ?? DateTime.now().toUtc().toIso8601String(),
      'local_batch_id': row['localBatchId'] ?? row['local_batch_id'],
      'is_deleted': _boolInt(row['isDeleted'] ?? row['is_deleted']),
      'created_at': _timestamp(row['createdAt']),
      'deleted_at': _timestamp(row['deleted_at']),
      'updated_at': _timestamp(row['updatedAt']),
      'is_synced': 1,
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
      'usage_type': _asString(row['usageType']),
      'is_deleted': _boolInt(row['is_deleted']),
      'is_synced': 1,
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
      'reference': _asString(row['reference']),
      'allocation_mode': _asString(row['allocationMode']),
      'batch_id': _asString(row['batch_id']),
      'supplier_id': _asString(row['supplierId']),
      'is_deleted': _boolInt(row['is_deleted']),
      'is_synced': 1,
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
      'payment_method': _asString(row['paymentMethod']),
      'payment_reference': _asString(row['paymentReference']),
      'payment_account_name': _asString(row['paymentAccountName']),
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
      'inventory_id': _asString(row['inventoryId']),
      'quantity': _asDouble(row['quantity'], fallback: 1),
      'usage_type': _asString(row['usageType']),
      'unit': _asString(row['unit']),
      'farm_id': _asString(row['farmId']),
      'is_synced': 1,
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
      'inventory_id': _asString(row['inventoryId']),
      'quantity': _asDouble(row['quantity'], fallback: 1),
      'usage_type': _asString(row['usageType']),
      'unit': _asString(row['unit']),
      'farm_id': _asString(row['farmId']),
      'is_synced': 1,
    };
  }

  Map<String, Object?> _mapExpenseAllocation(Map<String, dynamic> row) {
    return {
      'id': _asString(row['id']),
      'expense_id': _asString(row['expenseId']),
      'batch_id': _asString(row['batchId']),
      'farm_id': _asString(row['farmId']),
      'allocated_amount': _asDouble(row['allocatedAmount']),
      'allocation_percentage': _asDouble(row['allocationPercentage']),
      'created_at': _timestamp(row['createdAt']),
      'is_synced': 1,
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
    final temperature = row['currentTemperature'];
    final humidity = row['currentHumidity'];
    final hasTemp = temperature != null && _asDouble(temperature) != 0.0;
    final hasHumidity = humidity != null && _asDouble(humidity) != 0.0;
    return hasTemp || hasHumidity;
  }

  String _environmentState(Map<String, dynamic> row) {
    final temperature = _nullableDouble(row['currentTemperature']);
    final humidity = _nullableDouble(row['currentHumidity']);
    return environmentalStateLabel(
      temperature: temperature,
      humidity: humidity,
    );
  }

  double? _nullableDouble(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
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
      ...defaultPermissionsForRole(discoveredRole).toMap(),
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

  Future<Map<String, dynamic>?> _readPendingInvitationByPhone(
    String phoneNumber,
  ) async {
    for (final candidate in _phoneLookupCandidates(phoneNumber)) {
      try {
        final client = _requireClient();
        final rows = await client
            .from('invitations')
            .select(
              'id, email, role, status, farm_id, phone_number, updated_at',
            )
            .eq('phone_number', candidate)
            .inFilter('status', const ['pending', 'PENDING'])
            .order('updated_at', ascending: false)
            .limit(1);
        final mappedRows = _asRows(rows);
        if (mappedRows.isNotEmpty) {
          return mappedRows.first;
        }
      } on Object catch (error) {
        debugPrint(
          'HatchLog Auth Engine: Invitation lookup failed for $candidate -> $error',
        );
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> _acceptPendingInvitation({
    required String userId,
    String? phoneNumber,
    String? email,
  }) async {
    if (userId.trim().isEmpty) {
      return null;
    }
    try {
      final client = _requireClient();
      final response = await client.rpc(
        'accept_pending_invitation',
        params: {
          'p_user_id': userId,
          'p_phone_number': phoneNumber?.trim() ?? '',
          'p_email': email?.trim().toLowerCase() ?? '',
        },
      );
      if (response == null) {
        return null;
      }
      if (response is Map<String, dynamic>) {
        return response;
      }
      if (response is Map) {
        return Map<String, dynamic>.from(response);
      }
      return null;
    } on Object catch (error) {
      debugPrint(
        'HatchLog Auth Engine: accept_pending_invitation failed -> $error',
      );
      return null;
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

    final provisionedProfile = await _safeReadProvisionedProfile(
      authUserId: authUser.id,
      phoneNumber: phone.isNotEmpty ? phone : fallbackPhone,
    );

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
        : profile?['role'] ?? provisionedProfile?['role'];
    final profileRole = UserRole.fromString(_asString(roleValue));
    final webUserId = _asString(profile?['id']);
    final resolvedUserId = webUserId.isEmpty ? authUser.id : webUserId;
    var activeFarm = webUserId.isEmpty
        ? null
        : await _readActiveFarmForUser(webUserId);
    if (activeFarm == null && resolvedUserId != authUser.id) {
      activeFarm = await _readActiveFarmForUser(authUser.id);
    }
    var activeFarmId = _asString(activeFarm?['farm_id']);
    if (activeFarmId.isEmpty && provisionedProfile != null) {
      activeFarmId = _asString(
        provisionedProfile['farmId'] ?? provisionedProfile['farm_id'],
      );
    }
    if (activeFarmId.isEmpty && resolvedUserId.isNotEmpty) {
      final accepted = await _acceptPendingInvitation(
        userId: resolvedUserId,
        phoneNumber: phone.isNotEmpty ? phone : fallbackPhone,
        email: email,
      );
      if (accepted != null) {
        activeFarmId = _asString(accepted['farm_id']);
        activeFarm = {
          'farm_id': activeFarmId,
          'role': _asString(accepted['role']),
          'farm_owner_id': await _readFarmOwnerId(activeFarmId),
        };
        debugPrint(
          'HatchLog Auth Engine: Accepted pending invitation for farm=$activeFarmId',
        );
      }
    }
    if (activeFarmId.isEmpty) {
      Map<String, dynamic>? pendingInvitation;
      if (phone.isNotEmpty) {
        pendingInvitation = await _readPendingInvitationByPhone(phone);
      }
      pendingInvitation ??= email.isNotEmpty
          ? await _readPendingInvitationByEmail(email)
          : null;
      activeFarmId = _asString(pendingInvitation?['farm_id']);
      if (activeFarmId.isNotEmpty && activeFarm == null) {
        activeFarm = {
          'farm_id': activeFarmId,
          'role': _asString(pendingInvitation?['role']),
          'farm_owner_id': await _readFarmOwnerId(activeFarmId),
        };
      }
    }
    final farmOwnerId = _asString(activeFarm?['farm_owner_id']);
    final membershipRole = UserRole.fromString(_asString(activeFarm?['role']));
    final effectiveRole = activeFarmId.isEmpty
        ? (profileRole == UserRole.unknown ? UserRole.worker : profileRole)
        : resolveEffectiveFarmRole(
            farmOwnerId: farmOwnerId,
            userId: resolvedUserId,
            membershipRole: membershipRole,
          );
    final String userRole = effectiveRole.name.toLowerCase().trim();
    debugPrint(
      'HatchLog Auth Engine: Authenticated user role is -> $userRole '
      '(farm=$activeFarmId membership=${membershipRole.name} owner=$farmOwnerId)',
    );
    final activeBatchId = activeFarmId.isEmpty
        ? ''
        : await _readActiveBatchId(activeFarmId);
    final activeBatchName = activeBatchId.isEmpty
        ? ''
        : await _readBatchName(activeFarmId, activeBatchId);
    final activeFarmName = activeFarmId.isEmpty
        ? ''
        : await _readFarmName(activeFarmId);
    final profilePhone = _asString(
      profile?['phone_number'] ??
          provisionedProfile?['phoneNumber'] ??
          provisionedProfile?['phone_number'],
    );
    final profileEmail = _asString(profile?['email']).trim().toLowerCase();
    final resolvedEmail = profileEmail.isEmpty ? email : profileEmail;
    final resolvedPhone = profilePhone.isEmpty ? phone : profilePhone;
    final primaryIdentifier = resolvedPhone.isEmpty
        ? resolvedEmail
        : resolvedPhone;
    final provisionedStatus = _asString(
      provisionedProfile?['status'],
    ).toUpperCase();

    return AppUser(
      id: webUserId.isEmpty ? authUser.id : webUserId,
      phoneNumber: primaryIdentifier,
      email: resolvedEmail,
      role: effectiveRole,
      firstName: _asString(
        profile?['first_name'] ??
            profile?['firstname'] ??
            provisionedProfile?['firstName'] ??
            provisionedProfile?['first_name'],
      ),
      lastName: _asString(
        profile?['last_name'] ??
            profile?['surname'] ??
            provisionedProfile?['lastName'] ??
            provisionedProfile?['last_name'],
      ),
      activeFarmId: activeFarmId,
      activeFarmName: activeFarmName,
      activeBatchId: activeBatchId,
      activeBatchName: activeBatchName,
      requiresInitialSetup:
          provisionedStatus == 'PENDING' ||
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

  Future<Map<String, dynamic>?> _readProvisionedProfileByAuthUserId(
    String authUserId,
  ) async {
    try {
      final client = _requireClient();
      return await client
          .from('profiles')
          .select(
            'id, farmId, authUserId, phoneNumber, role, firstName, lastName, status, customPermissionsJson',
          )
          .eq('authUserId', authUserId)
          .maybeSingle();
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _readProvisionedProfileByPhone(
    String phoneNumber,
  ) async {
    try {
      final client = _requireClient();
      return await client
          .from('profiles')
          .select(
            'id, farmId, authUserId, phoneNumber, role, firstName, lastName, status, customPermissionsJson',
          )
          .eq('phoneNumber', phoneNumber)
          .maybeSingle();
    } on Object {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _safeReadProvisionedProfile({
    required String authUserId,
    required String phoneNumber,
  }) async {
    if (authUserId.isNotEmpty) {
      final byAuth = await _readProvisionedProfileByAuthUserId(authUserId);
      if (byAuth != null) {
        return byAuth;
      }
    }

    if (phoneNumber.isEmpty) {
      return null;
    }

    for (final candidate in _phoneLookupCandidates(phoneNumber)) {
      final profile = await _readProvisionedProfileByPhone(candidate);
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

  /// Farm-scoped role used for session refresh — mirrors web dashboard routing.
  Future<UserRole> fetchEffectiveFarmRole({
    required String userId,
    required String farmId,
  }) async {
    if (userId.isEmpty || farmId.isEmpty) {
      return UserRole.unknown;
    }
    final farmOwnerId = await _readFarmOwnerId(farmId);
    final membershipRole = await _readFarmMembershipRole(
      userId: userId,
      farmId: farmId,
    );
    return resolveEffectiveFarmRole(
      farmOwnerId: farmOwnerId,
      userId: userId,
      membershipRole: membershipRole,
    );
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
      final farmId = _asString(membership['farmId']);
      final farmOwnerId = await _readFarmOwnerId(farmId);
      return {
        'farm_id': farmId,
        'role': membership['role'],
        'farm_owner_id': farmOwnerId,
      };
    }

    final Map<String, dynamic>? ownedFarm;
    try {
      ownedFarm = await client
          .from('farms')
          .select('id, userId')
          .eq('userId', userId)
          .limit(1)
          .maybeSingle();
    } on Object {
      return null;
    }

    if (ownedFarm == null) {
      return null;
    }

    return {
      'farm_id': ownedFarm['id'],
      'role': 'OWNER',
      'farm_owner_id': _asString(ownedFarm['userId']),
    };
  }

  Future<String> _readFarmName(String farmId) async {
    if (farmId.isEmpty) {
      return '';
    }
    try {
      final client = _requireClient();
      final farm = await client
          .from('farms')
          .select('name')
          .eq('id', farmId)
          .maybeSingle();
      return _asString(farm?['name']);
    } on Object {
      return '';
    }
  }

  Future<String> _readFarmOwnerId(String farmId) async {
    if (farmId.isEmpty) {
      return '';
    }
    try {
      final client = _requireClient();
      final farm = await client
          .from('farms')
          .select('userId')
          .eq('id', farmId)
          .maybeSingle();
      return _asString(farm?['userId']);
    } on Object {
      return '';
    }
  }

  Future<UserRole> _readFarmMembershipRole({
    required String userId,
    required String farmId,
  }) async {
    try {
      final client = _requireClient();
      final membership = await client
          .from('farm_members')
          .select('role')
          .eq('userId', userId)
          .eq('farmId', farmId)
          .maybeSingle();
      return UserRole.fromString(_asString(membership?['role']));
    } on Object {
      return UserRole.unknown;
    }
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

  Future<String> _readBatchName(String farmId, String batchId) async {
    if (farmId.isEmpty || batchId.isEmpty) {
      return '';
    }
    try {
      final client = _requireClient();
      final batch = await client
          .from('batches')
          .select('batchName, batch_name')
          .eq('farmId', farmId)
          .eq('id', batchId)
          .maybeSingle();
      final name = _asString(batch?['batchName']).trim().isNotEmpty
          ? _asString(batch?['batchName']).trim()
          : _asString(batch?['batch_name']).trim();
      return name;
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
    final payloadEggs = _asInt(payload['eggs_collected']);
    final eggsCollected = payloadEggs > 0
        ? payloadEggs
        : (crates * eggsPerCrate).round() + singleEggs;
    final logDate = _optionalString(payload, 'log_date').isEmpty
        ? input.createdAt.toIso8601String()
        : _optionalString(payload, 'log_date');
    final unusableCount = _asInt(payload['unusable_count']);

    await _verifiedUpsert('egg_production', {
      'id': input.resolvedServerRecordId,
      'batchId': batchId,
      'farmId': farmId,
      'userId': input.userId,
      'eggsCollected': eggsCollected,
      'cratesCollected': crates,
      'eggsRemaining': eggsCollected,
      'unusableCount': unusableCount,
      'qualityGrade': _nullIfEmpty(_optionalString(payload, 'quality_grade')),
      'isSorted': _boolInt(payload['is_sorted']) == 1,
      'smallCount': _asInt(payload['small_count']),
      'mediumCount': _asInt(payload['medium_count']),
      'largeCount': _asInt(payload['large_count']),
      'logDate': logDate,
    });
  }

  Future<void> _pushFeedUsage(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final batchId = _optionalString(payload, 'batch_id');
    final logDate = _optionalString(payload, 'log_date').isEmpty
        ? input.createdAt.toIso8601String()
        : _optionalString(payload, 'log_date');

    await _verifiedUpsert('daily_feeding_logs', {
      'id': input.resolvedServerRecordId,
      'batch_id': batchId.isEmpty ? null : batchId,
      'feed_type_id': _nullIfEmpty(_optionalString(payload, 'feed_type_id')),
      'formulation_id': _nullIfEmpty(
        _optionalString(payload, 'formulation_id'),
      ),
      'amount_consumed': _asDouble(
        payload['amount_consumed'] ?? payload['bags'],
      ),
      'log_date': logDate,
      'farmId': farmId,
      'user_id': input.userId,
    });
  }

  Future<void> _pushMortality(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final batchId = _requiredString(payload, 'batch_id');
    final healthType = _optionalString(payload, 'health_type').toUpperCase();
    final resolvedHealthType = healthType == 'SICK' ? 'SICK' : 'DEAD';
    final logDate = _optionalString(payload, 'log_date').isEmpty
        ? input.createdAt.toIso8601String()
        : _optionalString(payload, 'log_date');

    await _verifiedUpsert('mortality', {
      'id': input.resolvedServerRecordId,
      'batchId': batchId,
      'farmId': farmId,
      'userId': input.userId,
      'count': _asInt(payload['count']),
      'type': resolvedHealthType,
      'reason': _nullIfEmpty(_optionalString(payload, 'reason')),
      'category': _nullIfEmpty(_optionalString(payload, 'category')),
      'sub_category': _nullIfEmpty(_optionalString(payload, 'sub_category')),
      'isolation_room_id': _nullIfEmpty(
        _optionalString(payload, 'isolation_room_id'),
      ),
      'logDate': logDate,
    });
  }

  Future<void> _pushInventoryItem(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final now = input.createdAt.toIso8601String();

    await _verifiedUpsert('inventory', {
      'id': input.resolvedServerRecordId,
      'farmId': farmId,
      'userId': input.userId,
      'itemName': _requiredString(payload, 'item_name'),
      'stockLevel': _asDouble(payload['stock_level']),
      'unit': _optionalString(payload, 'unit').isEmpty
          ? 'bags'
          : _optionalString(payload, 'unit'),
      'category': _optionalString(payload, 'category').isEmpty
          ? 'other'
          : _optionalString(payload, 'category'),
      'createdAt': now,
      'updatedAt': now,
      'is_deleted': false,
    });
  }

  Future<void> _pushRestoreRecord(PendingSyncInput input) async {
    final payload = input.payload;
    final table = _requiredString(payload, 'table');
    final recordId = _requiredString(payload, 'record_id');
    const allowedTables = {
      'batches',
      'inventory',
      'egg_production',
      'daily_feeding_logs',
      'mortality',
      'expenses',
      'sales',
      'orders',
    };
    if (!allowedTables.contains(table)) {
      throw StateError('Unsupported restore table: $table');
    }
    final client = _requireClient();
    await client
        .from(table)
        .update({'is_deleted': false, 'deleted_at': null})
        .eq('id', recordId);
  }

  Future<void> _pushWorkerLogDelete(PendingSyncInput input) async {
    final payload = input.payload;
    final table = _requiredString(payload, 'table');
    final recordId = _requiredString(payload, 'record_id');
    const allowedTables = {
      'egg_production',
      'daily_feeding_logs',
      'mortality',
    };
    if (!allowedTables.contains(table)) {
      throw StateError('Unsupported worker log delete table: $table');
    }
    final client = _requireClient();
    await client.from(table).update({
      'is_deleted': true,
      'deleted_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', recordId);
  }

  Future<void> _pushWorkerLogUpdate(PendingSyncInput input) async {
    final recordType = _requiredString(input.payload, 'record_type');
    switch (recordType) {
      case 'egg_collection':
        await _pushEggCollection(input);
      case 'feed_usage':
        await _pushFeedUsage(input);
      case 'mortality':
        await _pushMortality(input);
      default:
        throw StateError('Unsupported worker log update type: $recordType');
    }
  }

  Future<void> _pushFarmSettingsUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final client = _requireClient();

    await client.from('farms').update({
      'name': _requiredString(payload, 'name'),
      'location': _optionalString(payload, 'location'),
      'capacity': _asInt(payload['capacity']),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', farmId);

    await client.from('farm_settings').upsert({
      'farmId': farmId,
      'currency': _asString(payload['currency']),
      'eggsPerCrate': _asInt(payload['eggs_per_crate'], fallback: 30),
      'eggRecordReminderTime': _optionalString(payload, 'egg_record_reminder_time'),
      'feedRecordReminderTime': _optionalString(payload, 'feed_record_reminder_time'),
      if (payload['growth_target_standard'] != null)
        'growth_target_standard': _asInt(payload['growth_target_standard']),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    });
  }

  Future<void> _pushInventoryReorderUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final inventoryId = _requiredString(payload, 'inventory_id');
    final client = _requireClient();
    await client.from('inventory').update({
      'reorderLevel': _asDouble(payload['reorder_level']),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', inventoryId);
  }

  Future<void> _pushProfileUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final userId = _requiredString(payload, 'user_id');
    final client = _requireClient();
    await client.from('users').update({
      'firstname': _requiredString(payload, 'firstname'),
      'middleName': _optionalString(payload, 'middle_name'),
      'surname': _requiredString(payload, 'surname'),
      'name': _requiredString(payload, 'name'),
      'updatedAt': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', userId);
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
    final items = payload['items'];
    if (items is List && items.isNotEmpty) {
      await _pushMultiLineSale(input, items);
      return;
    }

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

  Future<void> _pushMultiLineSale(
    PendingSyncInput input,
    List<dynamic> items,
  ) async {
    final payload = input.payload;
    final farmId = _requiredString(payload, 'farm_id');
    final orderId = input.resolvedServerRecordId;
    final cashReceived = _asDouble(payload['total_cash_received']);
    final computedTotal = _asDouble(
      payload['computed_total'],
      fallback: cashReceived,
    );
    final subtotal = _asDouble(
      payload['subtotal_amount'],
      fallback: computedTotal,
    );
    final discount = _asDouble(payload['discount_amount']);
    final outstanding = _asDouble(payload['outstanding_credit']);
    final customerId = _optionalString(payload, 'customer_id');
    final customerName = _optionalString(payload, 'customer_name');
    final paymentMethod = _optionalString(payload, 'payment_method');
    final paymentReference = _optionalString(payload, 'payment_reference');
    final paymentAccountName = _optionalString(payload, 'payment_account_name');
    final timestamp = _optionalString(payload, 'order_date').isEmpty
        ? _optionalString(payload, 'device_timestamp').isEmpty
              ? input.createdAt.toIso8601String()
              : _optionalString(payload, 'device_timestamp')
        : _optionalString(payload, 'order_date');
    final isPaid = outstanding <= 0.01;
    final paymentStatus = isPaid
        ? 'PAID'
        : (cashReceived > 0 ? 'PARTIALLY_PAID' : 'UNPAID');

    await _verifiedUpsert('orders', {
      'id': orderId,
      'farmId': farmId,
      'userId': input.userId,
      'customerId': customerId.isEmpty ? null : customerId,
      'subtotalAmount': subtotal,
      'taxAmount': 0,
      'totalAmount': computedTotal,
      'discountAmount': discount,
      'currency': 'GHS',
      'status': isPaid ? 'PAID' : 'PENDING',
      'paymentMethod': paymentMethod.isEmpty ? 'CASH' : paymentMethod,
      if (paymentReference.isNotEmpty) 'paymentReference': paymentReference,
      if (paymentAccountName.isNotEmpty)
        'paymentAccountName': paymentAccountName,
      'orderDate': timestamp,
      if (isPaid) 'paidAt': timestamp,
    });

    final descriptions = <String>[];
    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      if (item is! Map) {
        continue;
      }
      final itemMap = Map<String, dynamic>.from(item);
      final quantity = _asInt(itemMap['quantity'], fallback: 1);
      final unitPrice = _asDouble(itemMap['unit_price']);
      final lineTotal = _asDouble(itemMap['total_price']);
      final description = _optionalString(itemMap, 'description');
      descriptions.add('$quantity x $description');
      final lineDiscount = _asDouble(itemMap['line_discount_amount']);
      final lineDiscountType = _optionalString(itemMap, 'line_discount_type');
      final eggAllocationMode = _optionalString(itemMap, 'egg_allocation_mode');
      final eggBatchId = _optionalString(itemMap, 'egg_batch_id');
      await _verifiedUpsert('order_items', {
        'id': '${orderId}_item_$index',
        'orderId': orderId,
        'description': description.isEmpty ? 'Sale item' : description,
        'quantity': quantity,
        'unitPrice': unitPrice,
        'totalPrice': lineTotal <= 0 ? quantity * unitPrice : lineTotal,
        if (lineDiscount > 0) 'lineDiscountAmount': lineDiscount,
        if (lineDiscountType.isNotEmpty) 'lineDiscountType': lineDiscountType,
        'inventoryId': _optionalString(itemMap, 'inventory_id').isEmpty
            ? null
            : _optionalString(itemMap, 'inventory_id'),
        'livestockId': _optionalString(itemMap, 'livestock_id').isEmpty
            ? null
            : _optionalString(itemMap, 'livestock_id'),
        if (eggAllocationMode.isNotEmpty)
          'eggAllocationMode': eggAllocationMode,
        if (eggBatchId.isNotEmpty) 'eggBatchId': eggBatchId,
      });
    }

    await _verifiedUpsert('financial_transactions', {
      'id': '${orderId}_transaction',
      'farm_id': farmId,
      'user_id': input.userId,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': computedTotal,
      'payment_status': paymentStatus,
      'payment_method': paymentMethod.isEmpty ? 'CASH' : paymentMethod,
      'reference_num': paymentReference.isNotEmpty
          ? paymentReference
          : _optionalString(payload, 'transaction_hash'),
      'transaction_date': timestamp,
      'description': paymentAccountName.isNotEmpty
          ? '${descriptions.join(', ')} to ${customerName.isEmpty ? 'Walk-in Customer' : customerName} ($paymentAccountName)'
          : '${descriptions.join(', ')} to ${customerName.isEmpty ? 'Walk-in Customer' : customerName}',
      if (isPaid) 'settled_at': timestamp,
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

  Future<void> _pushTeamPermissionUpdate(PendingSyncInput input) async {
    final payload = input.payload;
    final permissionMap = Map<String, dynamic>.from(
      payload['permissions'] as Map? ?? const {},
    );
    await updateWorkerPermissions(
      farmId: _requiredString(payload, 'farm_id'),
      targetUserId: _requiredString(payload, 'target_user_id'),
      permissions: FarmPermissions.fromToggleMap(
        permissionMap.map(
          (key, value) => MapEntry(key, value == true || value == 1),
        ),
      ),
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

  Future<AuthResponse> _signInViaLegacyMobilePasswordFunction(
    SupabaseClient client,
    String phoneNumber,
    String password,
  ) async {
    final response = await client.functions.invoke(
      'mobile-password-sign-in',
      body: {
        'phoneNumber': phoneNumber,
        'password': password,
      },
    );

    if (response.status != 200) {
      final data = response.data;
      var message = _phoneCredentialFailureMessage;
      if (data is Map) {
        final error = _asString(data['error']).trim();
        if (error.isNotEmpty) {
          message = error;
        }
      }
      throw AuthException(message);
    }

    final data = response.data;
    if (data is! Map) {
      throw const AuthException(_phoneCredentialFailureMessage);
    }

    final refreshToken = _asString(data['refresh_token']);
    if (refreshToken.isEmpty) {
      throw const AuthException(_phoneCredentialFailureMessage);
    }

    return client.auth.setSession(refreshToken);
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

    if (credential.isPhoneMask) {
      for (final phone in _phoneLookupCandidates(credential.fallbackIdentifier)) {
        try {
          return await client.auth.signInWithPassword(
            phone: phone,
            password: password,
          );
        } on AuthException catch (error) {
          if (!_isInvalidCredentialError(error)) {
            rethrow;
          }
          invalidPhoneAttempt = error;
        }
      }

      try {
        return await _signInViaLegacyMobilePasswordFunction(
          client,
          credential.fallbackIdentifier,
          password,
        );
      } on AuthException catch (error) {
        invalidPhoneAttempt = error;
      } on Object {
        // Edge function may not be deployed yet; keep the auth error below.
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

  Future<void> pushUnsyncedHealthSchedules({
    required String farmId,
    required Iterable<Map<String, Object?>> vaccinations,
    required Iterable<Map<String, Object?>> medications,
  }) async {
    final client = _requireClient();
    for (final row in vaccinations) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      final payload = {
        'id': id,
        'farmId': farmId,
        'batchId': _asString(row['batch_id']),
        'vaccineName': _asString(row['vaccine_name']),
        'scheduledDate': _asString(row['scheduled_date']),
        'status': _asString(row['status']).isEmpty
            ? 'PENDING'
            : _asString(row['status']),
        'notes': row['notes'],
        'quantity': _asDouble(row['quantity'], fallback: 1),
        'usageType': row['usage_type'],
        'unit': row['unit'],
      };
      await client.from('vaccination_schedules').upsert(payload);
    }

    for (final row in medications) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      final payload = {
        'id': id,
        'farmId': farmId,
        'batchId': _asString(row['batch_id']),
        'medicationName': _asString(row['medication_name']),
        'scheduledDate': _asString(row['scheduled_date']),
        'status': _asString(row['status']).isEmpty
            ? 'PENDING'
            : _asString(row['status']),
        'notes': row['notes'],
        'quantity': _asDouble(row['quantity'], fallback: 1),
        'usageType': row['usage_type'],
        'unit': row['unit'],
      };
      await client.from('medication_schedules').upsert(payload);
    }
  }

  Future<Set<String>> pushUnsyncedBatches({
    required String farmId,
    required Iterable<Map<String, Object?>> batches,
  }) async {
    final synced = <String>{};
    for (final row in batches) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final createdAt = _asString(row['created_at']);
      final payload = {
        'id': id,
        'farmId': farmId,
        'userId': _asString(row['user_id']),
        'batchName': _asString(row['batch_name']),
        'breedType': _asString(row['breed_type']),
        'type': _asString(row['type']).isEmpty
            ? 'POULTRY_BROILER'
            : _asString(row['type']),
        'houseId': _asString(row['house_id']),
        'initialCount': _asInt(row['initial_count']),
        'currentCount': _asInt(row['current_count']),
        'isolationCount': _asInt(row['isolation_count']),
        'arrivalDate': _asString(row['arrival_date']).isEmpty
            ? now
            : _asString(row['arrival_date']),
        'status': _asString(row['status']).isEmpty
            ? 'active'
            : _asString(row['status']),
        'is_deleted': _boolInt(row['is_deleted']) == 1,
        'createdAt': createdAt.isEmpty ? now : createdAt,
        'updatedAt': now,
      };
      try {
        await _upsertBatchOnCloud(payload, batchId: id);
        synced.add(id);
      } on Object catch (error) {
        debugPrint('[Sync] Batch push error for $id: $error');
      }
    }
    return synced;
  }

  Future<Set<String>> pushUnsyncedHouses({
    required String farmId,
    required Iterable<Map<String, Object?>> houses,
  }) async {
    final synced = <String>{};
    for (final row in houses) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final payload = buildHouseCloudPayload(
        id: id,
        farmId: farmId,
        userId: _asString(row['user_id']),
        name: _asString(row['name']),
        capacity: _asInt(row['capacity']),
        isIsolation: _boolInt(row['is_isolation']) == 1,
        currentTemperature: _nullableDouble(row['current_temperature']),
        currentHumidity: _nullableDouble(row['current_humidity']),
        updatedAt: now,
        createdAt: _asString(row['created_at']).isEmpty
            ? now
            : _asString(row['created_at']),
      );
      try {
        await _upsertHouseOnCloud(payload, houseId: id);
        synced.add(id);
      } on Object catch (error) {
        debugPrint('[Sync] House push error for $id: $error');
      }
    }
    return synced;
  }

  Future<void> _upsertBatchOnCloud(
    Map<String, dynamic> payload, {
    required String batchId,
  }) async {
    final client = _requireClient();
    try {
      final result = await client.rpc(
        'upsert_farm_batch',
        params: {'p_payload': payload},
      );
      final data = _rpcResultMap(result);
      if (data?['success'] == true) {
        return;
      }
      throw StateError(
        data?['error']?.toString() ?? 'upsert_farm_batch failed',
      );
    } on PostgrestException catch (error) {
      if (!_isMissingRpcError(error)) {
        rethrow;
      }
      debugPrint(
        '[Sync] upsert_farm_batch RPC unavailable for $batchId, '
        'falling back to direct upsert: $error',
      );
      await client.from('batches').upsert(payload);
    }
  }

  Future<void> _upsertHouseOnCloud(
    Map<String, dynamic> payload, {
    required String houseId,
  }) async {
    final client = _requireClient();
    try {
      final result = await client.rpc(
        'upsert_farm_house',
        params: {'p_payload': payload},
      );
      final data = _rpcResultMap(result);
      if (data?['success'] == true) {
        return;
      }
      throw StateError(
        data?['error']?.toString() ?? 'upsert_farm_house failed',
      );
    } on PostgrestException catch (error) {
      if (!_isMissingRpcError(error)) {
        rethrow;
      }
      debugPrint(
        '[Sync] upsert_farm_house RPC unavailable for $houseId, '
        'falling back to direct upsert: $error',
      );
      await client.from('houses').upsert(payload);
    }
  }

  bool _isMissingRpcError(PostgrestException error) {
    final message = error.message.toLowerCase();
    return error.code == '42883' ||
        message.contains('could not find the function') ||
        message.contains('does not exist');
  }

  Map<String, dynamic>? _rpcResultMap(Object? result) {
    if (result is Map<String, dynamic>) {
      return result;
    }
    if (result is Map) {
      return result.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }
    return null;
  }

  Future<void> pushUnsyncedPartnerSettlements({
    required String farmId,
    required Iterable<Map<String, Object?>> expenses,
    required Iterable<Map<String, Object?>> suppliers,
    required Iterable<Map<String, Object?>> customers,
  }) async {
    final client = _requireClient();

    for (final row in suppliers) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      await client.from('suppliers').upsert({
        'id': id,
        'farmId': farmId,
        'name': _asString(row['name']),
        'phone': row['phone'],
        'email': row['email'],
        'address': row['address'],
        'balanceOwed': _asDouble(row['balance_owed']),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
    }

    for (final row in customers) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      await client.from('customers').upsert({
        'id': id,
        'farmId': farmId,
        'name': _asString(row['name']),
        'phone': row['phone'],
        'email': row['email'],
        'address': row['address'],
        'balanceOwed': _asDouble(row['balance_owed']),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      });
    }

    for (final row in expenses) {
      final id = _asString(row['id']);
      if (id.isEmpty) {
        continue;
      }
      await client.from('expenses').upsert({
        'id': id,
        'farmId': farmId,
        'user_id': _asString(row['user_id']),
        'supplierId': _nullIfEmpty(_asString(row['supplier_id'])),
        'category': _asString(row['category']).toUpperCase(),
        'amount': _asDouble(row['amount']),
        'description': row['description'],
        'expense_date': _asString(row['expense_date']),
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
    }
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

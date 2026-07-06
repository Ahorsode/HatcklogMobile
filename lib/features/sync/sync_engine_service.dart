import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../services/health_inventory_service.dart';
import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../utils/active_farm_id.dart';
import '../auth/data/supabase_remote_api.dart';

class SyncEngineService {
  const SyncEngineService({
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
  }) : _localDatabase = localDatabase,
       _remoteApi = remoteApi;

  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;

  Future<void> syncWebEntitiesToLocalCache({
    required AppUser user,
    bool forceFullRefresh = false,
  }) async {
    SupabaseClient? supabase;
    try {
      supabase = Supabase.instance.client;
    } on Object {
      supabase = null;
    }
    final farmId = resolveActiveFarmId(user: user, supabase: supabase);
    if (!_remoteApi.isConfigured || farmId.isEmpty) {
      return;
    }

    final scope = 'farm:$farmId';
    try {
      final cursor = forceFullRefresh
          ? null
          : await _localDatabase.readSyncCursor(scope);
      final snapshot = await _remoteApi.fetchOperationalSnapshot(
        user: user,
        modifiedAfter: cursor,
        farmIdOverride: farmId,
      );
      await _localDatabase.upsertCloudRecords(snapshot.recordsByLocalTable);
      await HealthInventoryService(_localDatabase).reconcileFarmDepletion(
        farmId,
      );
      await _localDatabase.writeSyncCursor(scope, snapshot.pulledAt);
      debugPrint(
        'HatchLog Sync Engine: Cloud data hydration sequence complete.',
      );
    } on Object catch (error) {
      debugPrint('WARN: HatchLog Sync Engine skipped $scope: $error');
    }
  }
}

import 'package:flutter/foundation.dart';

import '../../../services/health_inventory_service.dart';
import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
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
    if (!_remoteApi.isConfigured || user.activeFarmId.isEmpty) {
      return;
    }

    final scope = 'farm:${user.activeFarmId}';
    try {
      final cursor = forceFullRefresh
          ? null
          : await _localDatabase.readSyncCursor(scope);
      final snapshot = await _remoteApi.fetchOperationalSnapshot(
        user: user,
        modifiedAfter: cursor,
      );
      await _localDatabase.upsertCloudRecords(snapshot.recordsByLocalTable);
      await HealthInventoryService(_localDatabase).reconcileFarmDepletion(
        user.activeFarmId,
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

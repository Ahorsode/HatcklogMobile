import '../../../core/models/app_user.dart';
import '../../../features/auth/data/supabase_remote_api.dart';
import '../../../features/health/data/health_schedule_repository.dart';
import '../../../utils/health_constants.dart';
import '../data/livestock_models.dart';
import '../data/livestock_repository.dart';

class LivestockOperationResult {
  const LivestockOperationResult({
    required this.success,
    this.batchId,
    this.error,
    this.remoteSynced = false,
  });

  final bool success;
  final String? batchId;
  final String? error;
  final bool remoteSynced;
}

class LivestockService {
  LivestockService({
    required LivestockRepository repository,
    SupabaseRemoteApi? remoteApi,
  })  : _repository = repository,
        _remoteApi = remoteApi;

  final LivestockRepository _repository;
  final SupabaseRemoteApi? _remoteApi;

  LivestockRepository get repository => _repository;

  Stream<void> watchBatches(String farmId) => _repository.watchBatches(farmId);

  Future<List<LivestockBatchRecord>> loadBatches(String farmId) =>
      _repository.loadBatches(farmId);

  Future<List<HouseOption>> loadHouses(String farmId) =>
      _repository.loadHouses(farmId);

  Future<List<BatchActivityEntry>> loadRecentActivity({
    required String farmId,
    required String batchId,
  }) =>
      _repository.loadRecentActivity(farmId: farmId, batchId: batchId);

  Future<LivestockOperationResult> createBatch({
    required AppUser user,
    required CreateLivestockDraft draft,
  }) async {
    if (draft.batchName.trim().length < 2) {
      return const LivestockOperationResult(
        success: false,
        error: 'Unit name is required',
      );
    }
    if (draft.houseId.isEmpty) {
      return const LivestockOperationResult(
        success: false,
        error: 'Select a house for this unit',
      );
    }
    if (draft.initialCount < 1) {
      return const LivestockOperationResult(
        success: false,
        error: 'Initial quantity must be at least 1',
      );
    }

    final batchId = newLivestockId('batch');
    await _repository.insertBatchLocal(
      id: batchId,
      farmId: user.activeFarmId,
      userId: user.id,
      draft: draft,
    );

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.createLivestockBatch(
          id: batchId,
          farmId: user.activeFarmId,
          userId: user.id,
          batchName: draft.batchName.trim(),
          breedType: draft.breedKey,
          type: draft.type,
          houseId: draft.houseId,
          initialCount: draft.initialCount,
          arrivalDate: draft.arrivalDate,
        );
        await _repository.markBatchSynced(batchId);
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Saved locally. Cloud sync pending: $error',
      );
    }

    final vaccineName = draft.vaccineName?.trim() ?? '';
    if (draft.vaccinationDate != null && vaccineName.isNotEmpty) {
      try {
        await HealthScheduleRepository(_repository.database).createSchedulesBulk(
          farmId: user.activeFarmId,
          entries: [
            HealthScheduleEntry(
              kind: HealthScheduleKind.vaccination,
              batchId: batchId,
              name: vaccineName,
              scheduledDate: draft.vaccinationDate!,
              isNewItem: true,
            ),
          ],
        );
      } on Object catch (error) {
        return LivestockOperationResult(
          success: true,
          batchId: batchId,
          remoteSynced: remoteSynced,
          error: 'Unit registered. Vaccination schedule pending: $error',
        );
      }
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }

  Future<LivestockOperationResult> updateBatch({
    required AppUser user,
    required String batchId,
    required UpdateLivestockDraft draft,
  }) async {
    if (draft.batchName.trim().length < 2) {
      return const LivestockOperationResult(
        success: false,
        error: 'Unit name is required',
      );
    }
    if (draft.houseId.isEmpty) {
      return const LivestockOperationResult(
        success: false,
        error: 'Select a house for this unit',
      );
    }

    await _repository.updateBatchLocal(batchId: batchId, draft: draft);

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.updateLivestockBatch(
          id: batchId,
          farmId: user.activeFarmId,
          batchName: draft.batchName.trim(),
          breedType: draft.breedKey,
          type: draft.type,
          houseId: draft.houseId,
          initialCount: draft.initialCount,
          arrivalDate: draft.arrivalDate,
          status: draft.status,
          growthTargetOverride: draft.growthTargetOverride.trim(),
        );
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Updated locally. Cloud sync pending: $error',
      );
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }

  Future<LivestockOperationResult> deleteBatch({
    required AppUser user,
    required String batchId,
    required String reason,
  }) async {
    if (reason.trim().length < 5) {
      return const LivestockOperationResult(
        success: false,
        error: 'Provide a reason with at least 5 characters',
      );
    }

    await _repository.softDeleteBatchLocal(batchId: batchId, reason: reason);

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.deleteLivestockBatch(
          id: batchId,
          farmId: user.activeFarmId,
          reason: reason.trim(),
        );
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Deleted locally. Cloud sync pending: $error',
      );
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }

  Future<LivestockOperationResult> saveFinancials({
    required AppUser user,
    required String batchId,
    required BatchFinancialDraft draft,
    required int quantity,
  }) async {
    final actualCost = draft.totalActualCost(quantity);
    await _repository.updateFinancialsLocal(
      batchId: batchId,
      actualCost: actualCost,
      carriageCost: draft.carriageCost,
    );

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.updateLivestockBatchFinancials(
          batchId: batchId,
          farmId: user.activeFarmId,
          userId: user.id,
          actualCost: actualCost,
          carriageInward: draft.carriageCost,
          otherExpenses: draft.otherExpenses
              .map((item) => {'label': item.label, 'amount': item.amount})
              .toList(),
        );
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Saved locally. Cloud sync pending: $error',
      );
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }

  Future<LivestockOperationResult> recoverFromIsolation({
    required AppUser user,
    required String batchId,
    required int count,
  }) async {
    if (count <= 0) {
      return const LivestockOperationResult(
        success: false,
        error: 'Enter a valid recovery count',
      );
    }

    await _repository.applyIsolationRecoveryLocal(
      batchId: batchId,
      count: count,
    );

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.returnLivestockFromIsolation(
          batchId: batchId,
          farmId: user.activeFarmId,
          count: count,
        );
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Updated locally. Cloud sync pending: $error',
      );
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }

  Future<LivestockOperationResult> logMortalityInIsolation({
    required AppUser user,
    required String batchId,
    required int count,
    String reason = 'Mortality while in isolation',
  }) async {
    if (count <= 0) {
      return const LivestockOperationResult(
        success: false,
        error: 'Enter a valid mortality count',
      );
    }

    await _repository.applyIsolationMortalityLocal(
      batchId: batchId,
      count: count,
    );

    var remoteSynced = false;
    try {
      final remote = _remoteApi;
      if (remote != null && remote.isConfigured) {
        await remote.logLivestockMortalityInIsolation(
          batchId: batchId,
          farmId: user.activeFarmId,
          userId: user.id,
          count: count,
          reason: reason,
        );
        remoteSynced = true;
      }
    } on Object catch (error) {
      return LivestockOperationResult(
        success: true,
        batchId: batchId,
        remoteSynced: false,
        error: 'Updated locally. Cloud sync pending: $error',
      );
    }

    return LivestockOperationResult(
      success: true,
      batchId: batchId,
      remoteSynced: remoteSynced,
    );
  }
}

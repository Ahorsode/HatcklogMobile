import '../../../core/models/app_user.dart';
import '../../../core/models/worker_input_type.dart';

class RecentWorkerLog {
  const RecentWorkerLog({
    required this.type,
    required this.summary,
    required this.createdAt,
    required this.isSynced,
  });

  final WorkerInputType type;
  final String summary;
  final DateTime createdAt;
  final bool isSynced;
}

class WorkerDashboardSnapshot {
  const WorkerDashboardSnapshot({
    required this.pendingCount,
    required this.recentLogs,
    required this.unitOptions,
  });

  final int pendingCount;
  final List<RecentWorkerLog> recentLogs;
  final List<WorkerUnitOption> unitOptions;
}

class WorkerUnitOption {
  const WorkerUnitOption({
    required this.batchId,
    required this.batchLabel,
    this.houseId = '',
    this.houseLabel = '',
  });

  final String batchId;
  final String batchLabel;
  final String houseId;
  final String houseLabel;

  String get displayLabel {
    if (houseLabel.trim().isEmpty) {
      return batchLabel;
    }
    return '$batchLabel / $houseLabel';
  }
}

abstract class WorkerInputSink {
  Future<void> enqueueWorkerInput({
    required AppUser user,
    required WorkerInputType type,
    required Map<String, dynamic> payload,
  });

  Future<int> pendingCount();

  Future<List<RecentWorkerLog>> recentLogs({
    required AppUser user,
    int limit = 3,
  });

  Stream<WorkerDashboardSnapshot> watchDashboardState({required AppUser user});
}

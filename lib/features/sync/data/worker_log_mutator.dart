import '../../../core/models/app_user.dart';
import '../../../presentation/worker/worker_module_definitions.dart';

class WorkerLogEditConfig {
  const WorkerLogEditConfig({
    required this.recordId,
    required this.mutator,
    required this.module,
  });

  final String recordId;
  final WorkerLogMutator mutator;
  final WorkerModule module;
}

abstract class WorkerLogMutator {
  Future<void> deleteWorkerLog({
    required AppUser user,
    required WorkerModule module,
    required String recordId,
  });

  Future<void> updateWorkerLog({
    required AppUser user,
    required WorkerModule module,
    required String recordId,
    required Map<String, dynamic> payload,
  });
}

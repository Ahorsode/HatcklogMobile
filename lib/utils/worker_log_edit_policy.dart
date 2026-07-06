/// Workers may edit or delete their own log entries within this window.
const Duration workerLogEditWindow = Duration(hours: 24);

DateTime? parseWorkerLogTimestamp(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is DateTime) {
    return value;
  }
  return DateTime.tryParse(value.toString());
}

bool canWorkerMutateLog({
  required String currentUserId,
  required String? recordUserId,
  required DateTime? createdAt,
  DateTime? logDate,
  DateTime? now,
}) {
  if (recordUserId == null || recordUserId.isEmpty) {
    return false;
  }
  if (recordUserId != currentUserId) {
    return false;
  }
  final anchor = createdAt ?? logDate;
  if (anchor == null) {
    return false;
  }
  final clock = now ?? DateTime.now();
  return clock.difference(anchor.toLocal()) <= workerLogEditWindow;
}

bool canWorkerMutateLogRow({
  required String currentUserId,
  required Map<String, Object?> row,
  DateTime? now,
}) {
  return canWorkerMutateLog(
    currentUserId: currentUserId,
    recordUserId: row['user_id']?.toString(),
    createdAt: parseWorkerLogTimestamp(row['created_at']),
    logDate: parseWorkerLogTimestamp(row['log_date']),
    now: now,
  );
}

String workerLogLockMessage() =>
    'Locked — you can only edit or delete your own logs within 24 hours.';

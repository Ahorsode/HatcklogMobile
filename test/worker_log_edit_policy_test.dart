import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/worker_log_edit_policy.dart';

void main() {
  final now = DateTime(2026, 7, 6, 12, 0);

  test('allows own log within 24 hours', () {
    expect(
      canWorkerMutateLog(
        currentUserId: 'user-1',
        recordUserId: 'user-1',
        createdAt: now.subtract(const Duration(hours: 23, minutes: 59)),
        now: now,
      ),
      isTrue,
    );
  });

  test('blocks own log after 24 hours', () {
    expect(
      canWorkerMutateLog(
        currentUserId: 'user-1',
        recordUserId: 'user-1',
        createdAt: now.subtract(const Duration(hours: 24, minutes: 1)),
        now: now,
      ),
      isFalse,
    );
  });

  test('blocks other users logs even when recent', () {
    expect(
      canWorkerMutateLog(
        currentUserId: 'user-1',
        recordUserId: 'user-2',
        createdAt: now.subtract(const Duration(minutes: 5)),
        now: now,
      ),
      isFalse,
    );
  });

  test('falls back to log_date when created_at is missing', () {
    expect(
      canWorkerMutateLogRow(
        currentUserId: 'user-1',
        row: {
          'user_id': 'user-1',
          'log_date': now.subtract(const Duration(hours: 2)).toIso8601String(),
        },
        now: now,
      ),
      isTrue,
    );
  });
}

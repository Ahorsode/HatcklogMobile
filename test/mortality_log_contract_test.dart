import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/mortality_log_utils.dart';

void main() {
  test('resolveHealthType maps SICK and QUARANTINE consistently', () {
    expect(resolveHealthType('SICK'), 'SICK');
    expect(resolveHealthType('QUARANTINE'), 'SICK');
    expect(resolveHealthType('DEAD'), 'DEAD');
    expect(resolveHealthType(null), 'DEAD');
  });

  test('validateHealthLog enforces count against current flock', () {
    expect(
      validateHealthLog(count: 0, currentCount: 100, healthType: 'DEAD'),
      isNotNull,
    );
    expect(
      validateHealthLog(count: 5, currentCount: 100, healthType: 'DEAD'),
      isNull,
    );
    expect(
      validateHealthLog(count: 101, currentCount: 100, healthType: 'DEAD'),
      isNotNull,
    );
  });

  test('validateHealthLog requires isolation room for sick events', () {
    expect(
      validateHealthLog(
        count: 2,
        currentCount: 100,
        healthType: 'SICK',
        requireIsolationRoom: true,
      ),
      isNotNull,
    );
    expect(
      validateHealthLog(
        count: 2,
        currentCount: 100,
        healthType: 'SICK',
        requireIsolationRoom: true,
        isolationRoomId: 'room-1',
      ),
      isNull,
    );
  });

  test('buildHealthLogPayload matches web logHealthEvent contract', () {
    final payload = buildHealthLogPayload(
      batchId: 'batch-1',
      count: 3,
      healthType: 'SICK',
      category: 'Unknown',
      subCategory: 'Unknown cause yet',
      isolationRoomId: 'room-1',
      logDate: DateTime.utc(2026, 7, 1),
    );

    expect(payload['batch_id'], 'batch-1');
    expect(payload['count'], 3);
    expect(payload['health_type'], 'SICK');
    expect(payload['type'], 'SICK');
    expect(payload['category'], 'Unknown');
    expect(payload['sub_category'], 'Unknown cause yet');
    expect(payload['isolation_room_id'], 'room-1');
    expect(payload.containsKey('reason'), isFalse);
  });

  test('healthLogBatchDeltas mirrors web count updates', () {
    expect(
      healthLogBatchDeltas(healthType: 'DEAD', count: 4),
      (currentCountDelta: -4, isolationCountDelta: 0),
    );
    expect(
      healthLogBatchDeltas(healthType: 'SICK', count: 2),
      (currentCountDelta: -2, isolationCountDelta: 2),
    );
  });

  test('record filters distinguish dead vs sick rows', () {
    expect(
      isDeadMortalityRecord(healthType: 'DEAD', category: 'Disease'),
      isTrue,
    );
    expect(
      isSickMortalityRecord(healthType: 'SICK', category: 'Disease'),
      isTrue,
    );
    expect(
      isDeadMortalityRecord(
        healthType: 'DEAD',
        category: legacyIsolationCategory,
      ),
      isFalse,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/egg_log_utils.dart';

void main() {
  test('calculateEggsCollected uses crate math with remainder cap', () {
    expect(
      calculateEggsCollected(useCrates: true, crates: 2, remainder: 40),
      89,
    );
    expect(
      calculateEggsCollected(useCrates: false, individualTotal: 125),
      125,
    );
  });

  test('validateEggLog enforces sorted and unusable caps', () {
    expect(
      validateEggLog(
        eggsCollected: 100,
        unusableCount: 5,
        isSorted: true,
        smallCount: 40,
        mediumCount: 40,
        largeCount: 20,
      ),
      isNull,
    );

    expect(
      validateEggLog(
        eggsCollected: 100,
        unusableCount: 5,
        isSorted: true,
        smallCount: 50,
        mediumCount: 40,
        largeCount: 20,
      ),
      isNotNull,
    );

    expect(
      validateEggLog(
        eggsCollected: 20,
        unusableCount: 25,
        isSorted: false,
        smallCount: 0,
        mediumCount: 0,
        largeCount: 0,
      ),
      isNotNull,
    );
  });

  test('buildEggLogPayload matches web egg_production contract', () {
    final payload = buildEggLogPayload(
      batchId: 'batch-1',
      eggsCollected: 90,
      unusableCount: 3,
      isSorted: false,
      qualityGrade: 'MEDIUM',
      logDate: DateTime.utc(2026, 7, 1),
      useCrates: true,
      crates: 3,
      remainder: 0,
    );

    expect(payload['batch_id'], 'batch-1');
    expect(payload['eggs_collected'], 90);
    expect(payload['unusable_count'], 3);
    expect(payload['quality_grade'], 'MEDIUM');
    expect(payload['is_sorted'], isFalse);
    expect(payload['small_count'], 0);
    expect(payload['crates'], 3);
  });
}

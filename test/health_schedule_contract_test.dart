import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/health_constants.dart';

void main() {
  group('health schedule contract', () {
    test('normalizeHealthUsageType defaults to one-time', () {
      expect(normalizeHealthUsageType(null), HealthUsageType.oneTime);
      expect(normalizeHealthUsageType('ONE_TIME'), HealthUsageType.oneTime);
      expect(normalizeHealthUsageType('QUANTITY'), HealthUsageType.quantity);
    });

    test('isHealthScheduleCompleted accepts COMPLETED and legacy DONE', () {
      expect(isHealthScheduleCompleted('COMPLETED'), isTrue);
      expect(isHealthScheduleCompleted('DONE'), isTrue);
      expect(isHealthScheduleCompleted('PENDING'), isFalse);
      expect(isHealthScheduleCompleted('CANCELLED'), isFalse);
    });

    test('health categories split vaccines and medicines', () {
      expect(isVaccineCategory('VACCINE'), isTrue);
      expect(isMedicineCategory('MEDICATION'), isTrue);
      expect(isHealthInventoryCategory('HEALTH'), isTrue);
      expect(isVaccineCategory('FEED'), isFalse);
    });

    test('web-aligned status values exclude MISSED', () {
      expect(healthScheduleStatuses, contains('CANCELLED'));
      expect(healthScheduleStatuses, isNot(contains('MISSED')));
    });
  });
}

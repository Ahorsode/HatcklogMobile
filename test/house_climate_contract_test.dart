import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/utils/house_climate_utils.dart';

void main() {
  group('House climate contract', () {
    test('status badges follow web/desktop thresholds', () {
      expect(
        resolveClimateStatus(temperature: 24, humidity: 55).label,
        'OPTIMAL',
      );
      expect(
        resolveClimateStatus(temperature: 24, humidity: 30).label,
        'ATTENTION',
      );
      expect(
        resolveClimateStatus(temperature: 35, humidity: 80).label,
        'CRITICAL',
      );
      expect(
        resolveClimateStatus(temperature: null, humidity: null).label,
        'UNKNOWN',
      );
    });

    test('temperature and humidity color coding matches FEATURES_PROMPT', () {
      expect(temperatureColor(16), const Color(0xFF3B82F6));
      expect(temperatureColor(24), const Color(0xFF22C55E));
      expect(temperatureColor(34), const Color(0xFFEF4444));
      expect(humidityColor(30), const Color(0xFFF59E0B));
      expect(humidityColor(55), const Color(0xFF22C55E));
      expect(humidityColor(75), const Color(0xFFF97316));
    });

    test('local row and cloud payload share web House fields', () {
      final local = buildHouseLocalRow(
        id: 'house-1',
        farmId: 'farm-1',
        userId: 'user-1',
        name: 'House A',
        capacity: 1000,
        isIsolation: true,
        currentTemperature: 26.5,
        currentHumidity: 58,
      );
      expect(local['name'], 'House A');
      expect(local['capacity'], 1000);
      expect(local['is_isolation'], 1);
      expect(local['current_temperature'], 26.5);
      expect(local['current_humidity'], 58);
      expect(local['is_synced'], 0);

      final cloud = buildHouseCloudPayload(
        id: 'house-1',
        farmId: 'farm-1',
        userId: 'user-1',
        name: 'House A',
        capacity: 1000,
        isIsolation: true,
        currentTemperature: 26.5,
        currentHumidity: 58,
        updatedAt: '2026-07-01T00:00:00.000Z',
      );
      expect(cloud['currentTemperature'], 26.5);
      expect(cloud['currentHumidity'], 58);
      expect(cloud['isIsolation'], isTrue);
    });
  });
}

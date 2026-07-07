import 'package:flutter/material.dart';

enum ClimateOverallStatus { optimal, attention, critical, unknown }

class ClimateStatusResult {
  const ClimateStatusResult({
    required this.status,
    required this.label,
  });

  final ClimateOverallStatus status;
  final String label;
}

/// Web/desktop parity thresholds from FEATURES_PROMPT.
ClimateStatusResult resolveClimateStatus({
  double? temperature,
  double? humidity,
}) {
  final tempInRange =
      temperature != null && temperature >= 18 && temperature <= 32;
  final humidityInRange =
      humidity != null && humidity >= 40 && humidity <= 70;
  final bothNull = temperature == null && humidity == null;
  final outCount = [
    if (temperature != null && !tempInRange) 1,
    if (humidity != null && !humidityInRange) 1,
  ].length;

  if (bothNull) {
    return const ClimateStatusResult(
      status: ClimateOverallStatus.unknown,
      label: 'UNKNOWN',
    );
  }
  if (outCount == 0) {
    return const ClimateStatusResult(
      status: ClimateOverallStatus.optimal,
      label: 'OPTIMAL',
    );
  }
  if (outCount == 1) {
    return const ClimateStatusResult(
      status: ClimateOverallStatus.attention,
      label: 'ATTENTION',
    );
  }
  return const ClimateStatusResult(
    status: ClimateOverallStatus.critical,
    label: 'CRITICAL',
  );
}

Color climateStatusColor(ClimateOverallStatus status) {
  return switch (status) {
    ClimateOverallStatus.optimal => const Color(0xFF22C55E),
    ClimateOverallStatus.attention => const Color(0xFFF59E0B),
    ClimateOverallStatus.critical => const Color(0xFFEF4444),
    ClimateOverallStatus.unknown => Colors.grey,
  };
}

Color temperatureColor(double? value) {
  if (value == null) return Colors.grey;
  if (value < 18) return const Color(0xFF3B82F6);
  if (value > 32) return const Color(0xFFEF4444);
  return const Color(0xFF22C55E);
}

Color humidityColor(double? value) {
  if (value == null) return Colors.grey;
  if (value < 40) return const Color(0xFFF59E0B);
  if (value > 70) return const Color(0xFFF97316);
  return const Color(0xFF22C55E);
}

/// Legacy environmental_state column used by management hub cards.
String environmentalStateLabel({
  double? temperature,
  double? humidity,
}) {
  final status = resolveClimateStatus(
    temperature: temperature,
    humidity: humidity,
  );
  return switch (status.status) {
    ClimateOverallStatus.optimal => 'NORMAL',
    ClimateOverallStatus.attention => 'WATCH',
    ClimateOverallStatus.critical => 'ALERT',
    ClimateOverallStatus.unknown => '',
  };
}

Map<String, Object?> buildHouseLocalRow({
  required String id,
  required String farmId,
  required String userId,
  required String name,
  required int capacity,
  bool isIsolation = false,
  double? currentTemperature,
  double? currentHumidity,
  bool isSynced = false,
}) {
  final now = DateTime.now().toIso8601String();
  return {
    'id': id,
    'farm_id': farmId,
    'user_id': userId,
    'name': name,
    'capacity': capacity,
    'current_temperature': currentTemperature,
    'current_humidity': currentHumidity,
    'is_isolation': isIsolation ? 1 : 0,
    'environmental_state': environmentalStateLabel(
      temperature: currentTemperature,
      humidity: currentHumidity,
    ),
    'last_environment_log_at': now,
    'created_at': now,
    'updated_at': now,
    'is_deleted': 0,
    'is_synced': isSynced ? 1 : 0,
  };
}

Map<String, dynamic> buildHouseCloudPayload({
  required String id,
  required String farmId,
  required String userId,
  required String name,
  required int capacity,
  required bool isIsolation,
  double? currentTemperature,
  double? currentHumidity,
  required String updatedAt,
  String? createdAt,
}) {
  return {
    'id': id,
    'farmId': farmId,
    'userId': userId,
    'name': name,
    'capacity': capacity,
    'currentTemperature': currentTemperature,
    'currentHumidity': currentHumidity,
    'isIsolation': isIsolation,
    'updatedAt': updatedAt,
    'createdAt': ?createdAt,
  };
}

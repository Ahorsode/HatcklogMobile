import 'dart:math';

import '../core/storage/local_database.dart';
import '../utils/house_climate_utils.dart';

class LocalHouseService {
  LocalHouseService(this._localDatabase);

  final LocalDatabase _localDatabase;

  String _newId() {
    final random = Random.secure();
    final suffix = List<int>.generate(
      8,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return 'house_${DateTime.now().microsecondsSinceEpoch}_$suffix';
  }

  Future<String> createHouse({
    required String farmId,
    required String userId,
    required String name,
    required int capacity,
    bool isIsolation = false,
    double? currentTemperature,
    double? currentHumidity,
  }) async {
    final id = _newId();
    await _localDatabase.insertLocalRecord(
      'houses',
      buildHouseLocalRow(
        id: id,
        farmId: farmId,
        userId: userId,
        name: name.trim(),
        capacity: capacity,
        isIsolation: isIsolation,
        currentTemperature: currentTemperature,
        currentHumidity: currentHumidity,
      ),
    );
    return id;
  }

  Future<void> updateHouse({
    required String houseId,
    String? name,
    int? capacity,
    bool? isIsolation,
  }) async {
    final updates = <String, Object?>{
      'updated_at': DateTime.now().toIso8601String(),
      'is_synced': 0,
    };
    if (name != null) {
      updates['name'] = name.trim();
    }
    if (capacity != null) {
      updates['capacity'] = capacity;
    }
    if (isIsolation != null) {
      updates['is_isolation'] = isIsolation ? 1 : 0;
    }
    await _localDatabase.updateLocalRecord(
      'houses',
      updates,
      where: 'id = ?',
      whereArgs: [houseId],
    );
  }

  Future<void> updateClimate({
    required String houseId,
    double? currentTemperature,
    double? currentHumidity,
  }) async {
    final now = DateTime.now().toIso8601String();
    await _localDatabase.updateLocalRecord(
      'houses',
      {
        'current_temperature': currentTemperature,
        'current_humidity': currentHumidity,
        'environmental_state': environmentalStateLabel(
          temperature: currentTemperature,
          humidity: currentHumidity,
        ),
        'last_environment_log_at': now,
        'updated_at': now,
        'is_synced': 0,
      },
      where: 'id = ?',
      whereArgs: [houseId],
    );
  }
}

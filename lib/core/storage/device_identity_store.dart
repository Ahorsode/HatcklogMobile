import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class DeviceIdentityStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'hatchlog.mobile.device_id.v1';

  static Future<String> getOrCreate() async {
    final existing = await _storage.read(key: _key);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }

    final newId = _generateDeviceId();
    await _storage.write(key: _key, value: newId);
    return newId;
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    final hex = bytes
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    return 'device-$hex';
  }
}

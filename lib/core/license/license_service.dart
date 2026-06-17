import 'package:supabase_flutter/supabase_flutter.dart';

import '../storage/local_database.dart';
import 'license_status.dart';

class LicenseConfig {
  const LicenseConfig({
    required this.mode,
    required this.farmId,
    required this.userId,
    required this.hardwareId,
    required this.installedAt,
    required this.expiresAt,
    required this.lastUsed,
    required this.lastCloudCheckAt,
  });

  final String mode;
  final String? farmId;
  final String? userId;
  final String? hardwareId;
  final DateTime installedAt;
  final DateTime expiresAt;
  final DateTime lastUsed;
  final DateTime? lastCloudCheckAt;

  factory LicenseConfig.fromMap(Map<String, Object?> map) {
    return LicenseConfig(
      mode: map['mode'] as String,
      farmId: map['farm_id'] as String?,
      userId: map['user_id'] as String?,
      hardwareId: map['hardware_id'] as String?,
      installedAt: DateTime.parse(map['installed_at'] as String),
      expiresAt: DateTime.parse(map['expires_at'] as String),
      lastUsed: DateTime.parse(map['last_used'] as String),
      lastCloudCheckAt: map['last_cloud_check_at'] == null
          ? null
          : DateTime.parse(map['last_cloud_check_at'] as String),
    );
  }
}

class LicenseService {
  LicenseService(this._db);

  final LocalDatabase _db;

  Future<LicenseStatus> checkLicense() async {
    final config = await _loadConfig();
    if (config == null) {
      return LicenseStatus.firstLaunch;
    }

    final now = DateTime.now();

    if (now.isBefore(config.lastUsed.subtract(const Duration(minutes: 2)))) {
      return LicenseStatus.clockTampered;
    }

    if (now.isBefore(config.expiresAt)) {
      return LicenseStatus.valid;
    }

    final lastCloudCheckAt = config.lastCloudCheckAt;
    if (lastCloudCheckAt != null) {
      final daysSinceCheck = now.difference(lastCloudCheckAt).inDays;
      if (daysSinceCheck < 10) {
        return LicenseStatus.valid;
      }
    }

    final daysPastExpiry = now.difference(config.expiresAt).inDays;
    if (daysPastExpiry <= 5) {
      return LicenseStatus.softLocked;
    }

    await _setMode('HARD_LOCKED');
    return LicenseStatus.hardLocked;
  }

  Future<String?> initTrialFromCloud({
    required String userId,
    required String farmId,
    required String hardwareId,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'register_device_trial',
        params: {
          'p_user_id': userId,
          'p_farm_id': farmId,
          'p_hardware_id': hardwareId,
          'p_device_name': 'Mobile App',
          'p_device_type': 'Mobile',
        },
      );
      final data = _resultMap(result);
      if (data == null) {
        return 'Trial registration returned no data.';
      }
      if (data['success'] != true) {
        return data['error']?.toString() ?? 'Trial registration failed.';
      }

      final now = DateTime.now();
      final expiresAt =
          DateTime.tryParse(data['license_expires_at']?.toString() ?? '') ??
          now.add(const Duration(days: 30));

      await _upsertConfig(
        mode: _serverStatusToLocalMode(
          data['license_status']?.toString() ?? 'CLOUD_TRIAL',
        ),
        farmId: farmId,
        userId: userId,
        hardwareId: hardwareId,
        installedAt: now,
        expiresAt: expiresAt,
        lastCloudCheckAt: now,
      );
      return null;
    } on Object {
      await _initLocalFallbackTrial(
        userId: userId,
        farmId: farmId,
        hardwareId: hardwareId,
      );
      return null;
    }
  }

  Future<void> renewFromCloud(String hardwareId) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'get_device_subscription_status',
        params: {'p_hardware_id': hardwareId},
      );
      final data = _resultMap(result);
      if (data == null || data['success'] != true) {
        return;
      }

      final serverExpiry = DateTime.tryParse(
        data['license_expires_at']?.toString() ?? '',
      );
      final statusStr = data['license_status']?.toString();
      final now = DateTime.now();
      final config = await _loadConfig();
      if (config == null) {
        return;
      }

      final updates = <String, Object?>{
        'last_used': now.toIso8601String(),
        'last_cloud_check_at': now.toIso8601String(),
      };
      if (serverExpiry != null && serverExpiry.isAfter(config.expiresAt)) {
        updates['expires_at'] = serverExpiry.toIso8601String();
      }
      if (statusStr != null) {
        updates['mode'] = _serverStatusToLocalMode(statusStr);
      }

      await _db.rawLocalUpdate('license_configs', updates, "id = 'singleton'");
    } on Object {
      // Offline or transient cloud failure: desktop silently keeps local state.
    }
  }

  Future<void> touchLastUsed() async {
    try {
      await _db.rawLocalUpdate('license_configs', {
        'last_used': DateTime.now().toIso8601String(),
      }, "id = 'singleton'");
    } on Object {
      // Missing table/config during early boot should never block data writes.
    }
  }

  Future<LicenseConfig?> getConfig() => _loadConfig();

  Future<void> _initLocalFallbackTrial({
    required String userId,
    required String farmId,
    required String hardwareId,
  }) async {
    if (await _loadConfig() != null) {
      return;
    }

    final now = DateTime.now();
    await _upsertConfig(
      mode: 'CLOUD_TRIAL',
      farmId: farmId,
      userId: userId,
      hardwareId: hardwareId,
      installedAt: now,
      expiresAt: now.add(const Duration(days: 30)),
      lastCloudCheckAt: null,
    );
  }

  Future<LicenseConfig?> _loadConfig() async {
    final rows = await _db.rawLocalQuery(
      "select * from license_configs where id = 'singleton'",
    );
    if (rows.isEmpty) {
      return null;
    }
    return LicenseConfig.fromMap(rows.first);
  }

  Future<void> _upsertConfig({
    required String mode,
    required String? farmId,
    required String? userId,
    required String? hardwareId,
    required DateTime installedAt,
    required DateTime expiresAt,
    DateTime? lastCloudCheckAt,
  }) async {
    final now = DateTime.now();
    await _db.rawLocalInsertOrReplace('license_configs', {
      'id': 'singleton',
      'mode': mode,
      'farm_id': farmId,
      'user_id': userId,
      'hardware_id': hardwareId,
      'installed_at': installedAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(),
      'last_used': now.toIso8601String(),
      'last_cloud_check_at': lastCloudCheckAt?.toIso8601String(),
    });
  }

  Future<void> _setMode(String mode) async {
    await _db.rawLocalUpdate('license_configs', {
      'mode': mode,
    }, "id = 'singleton'");
  }

  String _serverStatusToLocalMode(String status) {
    return switch (status) {
      'ACTIVE' => 'CLOUD_ACTIVE',
      'CLOUD_TRIAL' => 'CLOUD_TRIAL',
      'GRACE_PERIOD' => 'EXPIRED',
      'EXPIRED' => 'EXPIRED',
      _ => 'CLOUD_TRIAL',
    };
  }

  Map<String, dynamic>? _resultMap(Object? result) {
    if (result is Map) {
      return Map<String, dynamic>.from(result);
    }
    if (result is List && result.isNotEmpty && result.first is Map) {
      return Map<String, dynamic>.from(result.first as Map);
    }
    return null;
  }
}

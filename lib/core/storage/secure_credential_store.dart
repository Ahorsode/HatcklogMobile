import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/app_user.dart';
import '../security/password_hasher.dart';

abstract class CredentialStore {
  Future<CachedCredential?> read(String identifier);

  Future<void> save({required AppUser user, required String password});

  Future<void> delete(String identifier);
}

class CachedCredential {
  const CachedCredential({
    required this.user,
    required this.passwordHash,
    required this.updatedAt,
  });

  final AppUser user;
  final PasswordHash passwordHash;
  final DateTime updatedAt;

  Future<bool> matches(String password) {
    return PasswordHasher.verifyAsync(password, passwordHash);
  }

  Map<String, Object?> toJson() {
    return {
      'user_id': user.id,
      'phone_number': user.phoneNumber,
      'email': user.email,
      'role': user.role.name,
      'first_name': user.firstName,
      'last_name': user.lastName,
      'active_farm_id': user.activeFarmId,
      'active_batch_id': user.activeBatchId,
      'password_hash': passwordHash.toJson(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  static CachedCredential fromJson(Map<String, Object?> json) {
    final hashJson = json['password_hash'] as Map<String, Object?>;
    return CachedCredential(
      user: AppUser(
        id: json['user_id'] as String,
        phoneNumber: json['phone_number'] as String,
        email: (json['email'] as String?) ?? '',
        role: UserRole.fromString(json['role'] as String?),
        firstName: (json['first_name'] as String?) ?? '',
        lastName: (json['last_name'] as String?) ?? '',
        activeFarmId: (json['active_farm_id'] as String?) ?? '',
        activeBatchId: (json['active_batch_id'] as String?) ?? '',
      ),
      passwordHash: PasswordHash.fromJson(hashJson),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }
}

class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore({FlutterSecureStorage? storage})
    : _storage = storage ?? _defaultStorage;

  static const _defaultStorage = FlutterSecureStorage(
    aOptions: AndroidOptions(storageNamespace: 'hatchlog_mobile_vault'),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
      useSecureEnclave: true,
    ),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<CachedCredential?> read(String identifier) async {
    final key = _keyFor(identifier);
    var rawValue = await _storage.read(key: key);
    rawValue ??= await _storage.read(key: _legacyKeyFor(identifier));
    if (rawValue == null) {
      return null;
    }

    final json = jsonDecode(rawValue) as Map<String, dynamic>;
    final credential = CachedCredential.fromJson(json);
    if (await _storage.read(key: key) == null) {
      await _storage.write(key: key, value: rawValue);
    }
    return credential;
  }

  @override
  Future<void> save({required AppUser user, required String password}) async {
    final credential = CachedCredential(
      user: user,
      passwordHash: await PasswordHasher.hashAsync(password),
      updatedAt: DateTime.now(),
    );

    final encoded = jsonEncode(credential.toJson());
    for (final identifier in _identifiersFor(user)) {
      await _storage.write(key: _keyFor(identifier), value: encoded);
    }
  }

  @override
  Future<void> delete(String identifier) async {
    await _storage.delete(key: _keyFor(identifier));
    await _storage.delete(key: _legacyKeyFor(identifier));
  }

  String _keyFor(String identifier) {
    final digest = sha256.convert(utf8.encode(identifier.trim().toLowerCase()));
    return 'hatchlog.mobile.credential.v2.$digest';
  }

  String _legacyKeyFor(String identifier) {
    return 'hatchlog.mobile.credential.${identifier.trim()}';
  }

  Iterable<String> _identifiersFor(AppUser user) sync* {
    final seen = <String>{};
    for (final identifier in [
      user.phoneNumber.trim(),
      user.email.trim().toLowerCase(),
      user.loginIdentifier,
    ]) {
      final normalized = identifier.trim().toLowerCase();
      if (normalized.isNotEmpty && seen.add(normalized)) {
        yield identifier;
      }
    }
  }
}

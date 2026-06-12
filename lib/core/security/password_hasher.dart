import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

class PasswordHash {
  const PasswordHash({
    required this.hashBase64,
    required this.saltBase64,
    required this.iterations,
  });

  final String hashBase64;
  final String saltBase64;
  final int iterations;

  Map<String, Object?> toJson() {
    return {'hash': hashBase64, 'salt': saltBase64, 'iterations': iterations};
  }

  static PasswordHash fromJson(Map<String, Object?> json) {
    return PasswordHash(
      hashBase64: json['hash'] as String,
      saltBase64: json['salt'] as String,
      iterations: json['iterations'] as int,
    );
  }
}

class PasswordHasher {
  static const int defaultIterations = 120000;
  static const int _keyLength = 32;
  static const int _saltLength = 16;

  static Future<PasswordHash> hashAsync(
    String password, {
    int iterations = defaultIterations,
  }) {
    return Isolate.run(() => hash(password, iterations: iterations));
  }

  static Future<bool> verifyAsync(String password, PasswordHash stored) {
    return Isolate.run(() => verify(password, stored));
  }

  static PasswordHash hash(
    String password, {
    int iterations = defaultIterations,
  }) {
    final salt = _randomBytes(_saltLength);
    final key = _pbkdf2(
      password: utf8.encode(password),
      salt: salt,
      iterations: iterations,
      length: _keyLength,
    );

    return PasswordHash(
      hashBase64: base64Encode(key),
      saltBase64: base64Encode(salt),
      iterations: iterations,
    );
  }

  static bool verify(String password, PasswordHash stored) {
    final recalculated = _pbkdf2(
      password: utf8.encode(password),
      salt: base64Decode(stored.saltBase64),
      iterations: stored.iterations,
      length: _keyLength,
    );
    return _constantTimeEquals(recalculated, base64Decode(stored.hashBase64));
  }

  static List<int> _randomBytes(int length) {
    final random = Random.secure();
    return List<int>.generate(length, (_) => random.nextInt(256));
  }

  static List<int> _pbkdf2({
    required List<int> password,
    required List<int> salt,
    required int iterations,
    required int length,
  }) {
    final hmac = Hmac(sha256, password);
    final blockCount =
        (length + hmac.convert(<int>[]).bytes.length - 1) ~/
        hmac.convert(<int>[]).bytes.length;
    final derivedKey = <int>[];

    for (var blockIndex = 1; blockIndex <= blockCount; blockIndex++) {
      final blockSalt = Uint8List(salt.length + 4);
      blockSalt.setAll(0, salt);
      blockSalt[salt.length] = (blockIndex >> 24) & 0xff;
      blockSalt[salt.length + 1] = (blockIndex >> 16) & 0xff;
      blockSalt[salt.length + 2] = (blockIndex >> 8) & 0xff;
      blockSalt[salt.length + 3] = blockIndex & 0xff;

      var u = hmac.convert(blockSalt).bytes;
      final block = List<int>.from(u);

      for (var round = 1; round < iterations; round++) {
        u = hmac.convert(u).bytes;
        for (var i = 0; i < block.length; i++) {
          block[i] ^= u[i];
        }
      }

      derivedKey.addAll(block);
    }

    return derivedKey.sublist(0, length);
  }

  static bool _constantTimeEquals(List<int> a, List<int> b) {
    var diff = a.length ^ b.length;
    final count = min(a.length, b.length);
    for (var i = 0; i < count; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

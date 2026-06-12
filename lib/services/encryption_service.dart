import 'dart:convert';
import 'package:crypto/crypto.dart';

class EncryptionService {
  // Lightweight integrity hash used to detect tampering.
  String computeHmac(String payload, String key) {
    final hmac = Hmac(sha256, utf8.encode(key));
    return hmac.convert(utf8.encode(payload)).toString();
  }

  // Simple deterministic transaction hash combining payload and timestamp
  String transactionHash(Map<String, dynamic> data, String deviceId) {
    final payload = jsonEncode({...data, 'deviceId': deviceId});
    final digest = sha256.convert(utf8.encode(payload));
    return digest.toString();
  }
}

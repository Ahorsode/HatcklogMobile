import 'dart:io' show Platform;

import 'package:device_info_plus/device_info_plus.dart';

Future<String> getDeviceHardwareId() async {
  final deviceInfo = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      return info.id;
    }
    if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      return info.identifierForVendor ?? 'UNKNOWN-IOS-DEVICE';
    }
  } on Object {
    // Fall through to the sentinel below. License registration can still
    // fail open locally if the platform fingerprint is temporarily unavailable.
  }
  return 'UNKNOWN-HARDWARE-ID';
}

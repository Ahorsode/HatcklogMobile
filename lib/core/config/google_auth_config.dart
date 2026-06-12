import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'env_file_loader.dart';

class GoogleAuthConfig {
  const GoogleAuthConfig({
    required this.iosClientId,
    required this.androidClientId,
    required this.webClientId,
    required this.webClientIdSource,
    required this.androidClientIdSource,
  });

  static const webClientIdKey = 'GOOGLE_WEB_CLIENT_ID';
  static const androidClientIdKey = 'GOOGLE_ANDROID_CLIENT_ID';
  static const iosClientIdKey = 'GOOGLE_IOS_CLIENT_ID';

  static const _definedIosClientId = String.fromEnvironment(iosClientIdKey);
  static const _definedAndroidClientId = String.fromEnvironment(
    androidClientIdKey,
  );
  static const _definedWebClientId = String.fromEnvironment(webClientIdKey);

  final String iosClientId;
  final String androidClientId;
  final String webClientId;
  final GoogleAuthConfigSource webClientIdSource;
  final GoogleAuthConfigSource androidClientIdSource;

  bool get isConfigured => webClientId.isNotEmpty;

  static Future<GoogleAuthConfig> load() async {
    final dotenvValues = _safeDotenvValues();
    final localEnv = await loadLocalEnvFile();
    final webClientId = _resolveToken(
      key: webClientIdKey,
      dotenvValues: dotenvValues,
      compileTimeValue: _definedWebClientId,
      localEnv: localEnv,
      localAliases: const ['AUTH_GOOGLE_ID'],
    );
    final androidClientId = _resolveToken(
      key: androidClientIdKey,
      dotenvValues: dotenvValues,
      compileTimeValue: _definedAndroidClientId,
      localEnv: localEnv,
    );
    final iosClientId = _resolveToken(
      key: iosClientIdKey,
      dotenvValues: dotenvValues,
      compileTimeValue: _definedIosClientId,
      localEnv: localEnv,
    );

    _logResolution(webClientId, localAliases: const ['AUTH_GOOGLE_ID']);
    _logResolution(androidClientId);

    return GoogleAuthConfig(
      iosClientId: iosClientId.value,
      androidClientId: androidClientId.value,
      webClientId: webClientId.value,
      webClientIdSource: webClientId.source,
      androidClientIdSource: androidClientId.source,
    );
  }

  static Map<String, String> _safeDotenvValues() {
    if (!dotenv.isInitialized) {
      return const {};
    }

    try {
      return dotenv.env;
    } on Object {
      return const {};
    }
  }

  static _ResolvedGoogleToken _resolveToken({
    required String key,
    required Map<String, String> dotenvValues,
    required String compileTimeValue,
    required Map<String, String> localEnv,
    List<String> localAliases = const [],
  }) {
    final dotenvValue = (dotenvValues[key] ?? '').trim();
    if (dotenvValue.isNotEmpty) {
      return _ResolvedGoogleToken(
        key: key,
        value: dotenvValue,
        source: GoogleAuthConfigSource.packedAsset,
      );
    }

    final definedValue = compileTimeValue.trim();
    if (definedValue.isNotEmpty) {
      return _ResolvedGoogleToken(
        key: key,
        value: definedValue,
        source: GoogleAuthConfigSource.compileTimeNative,
      );
    }

    for (final localKey in [key, ...localAliases]) {
      final localValue = (localEnv[localKey] ?? '').trim();
      if (localValue.isNotEmpty) {
        return _ResolvedGoogleToken(
          key: key,
          value: localValue,
          source: GoogleAuthConfigSource.localEnvFile,
        );
      }
    }

    return _ResolvedGoogleToken(
      key: key,
      value: '',
      source: GoogleAuthConfigSource.unresolved,
    );
  }

  static void _logResolution(
    _ResolvedGoogleToken token, {
    List<String> localAliases = const [],
  }) {
    if (token.value.isNotEmpty) {
      debugPrint('INFO: ${token.key} hydrated via ${token.source.label}.');
      return;
    }

    final localKeys = [token.key, ...localAliases].join(', ');
    debugPrint(
      'ERROR: ${token.key} failed to hydrate. Checked packed asset key '
      '${token.key}, compile-time --dart-define key ${token.key}, and local '
      '.env key(s): $localKeys. Verify the exact key name is ${token.key}.',
    );
  }
}

enum GoogleAuthConfigSource {
  packedAsset,
  compileTimeNative,
  localEnvFile,
  unresolved,
}

extension on GoogleAuthConfigSource {
  String get label {
    switch (this) {
      case GoogleAuthConfigSource.packedAsset:
        return 'Packed Asset Layer';
      case GoogleAuthConfigSource.compileTimeNative:
        return 'Compile-Time Native Definition Tokens';
      case GoogleAuthConfigSource.localEnvFile:
        return 'Local .env File Fallback';
      case GoogleAuthConfigSource.unresolved:
        return 'Unresolved';
    }
  }
}

class _ResolvedGoogleToken {
  const _ResolvedGoogleToken({
    required this.key,
    required this.value,
    required this.source,
  });

  final String key;
  final String value;
  final GoogleAuthConfigSource source;
}

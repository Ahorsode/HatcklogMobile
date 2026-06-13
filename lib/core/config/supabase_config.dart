import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class SupabaseConfig {
  const SupabaseConfig({
    required this.url,
    required this.clientKey,
    required this.source,
  });

  static const _definedUrl = String.fromEnvironment('SUPABASE_URL');
  static const _definedPublishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
  );
  static const _definedAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  final String url;
  final String clientKey;
  final SupabaseConfigSource source;

  bool get isConfigured => url.isNotEmpty && clientKey.isNotEmpty;

  static Future<SupabaseConfig> load() async {
    final assetUrl = (dotenv.env['SUPABASE_URL'] ?? '').trim();
    final assetClientKey =
        (dotenv.env['SUPABASE_PUBLISHABLE_KEY'] ??
                dotenv.env['SUPABASE_ANON_KEY'] ??
                '')
            .trim();

    if (assetUrl.isNotEmpty && assetClientKey.isNotEmpty) {
      debugPrint('INFO: Base Config Hydrated via Packed Asset Layer');
      return SupabaseConfig(
        url: assetUrl,
        clientKey: assetClientKey,
        source: SupabaseConfigSource.packedAsset,
      );
    }

    final definedUrl = _definedUrl.trim();
    final definedClientKey =
        (_definedPublishableKey.isNotEmpty
                ? _definedPublishableKey
                : _definedAnonKey)
            .trim();

    if (definedUrl.isNotEmpty && definedClientKey.isNotEmpty) {
      debugPrint('WARN: Falling Back to Compile-Time Native Definition Tokens');
      return SupabaseConfig(
        url: definedUrl,
        clientKey: definedClientKey,
        source: SupabaseConfigSource.compileTimeNative,
      );
    }

    debugPrint(
      'WARN: Supabase credentials not found in packed asset or compile-time '
      'tokens. App will operate in offline-only mode.',
    );
    return const SupabaseConfig(
      url: '',
      clientKey: '',
      source: SupabaseConfigSource.packedAsset,
    );
  }
}

enum SupabaseConfigSource { packedAsset, compileTimeNative }

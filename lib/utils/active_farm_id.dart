import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/models/app_user.dart';

/// Resolves the active farm id for the signed-in [user].
///
/// The cached [AppUser.activeFarmId] always wins so a worker session is not
/// overridden by a stale Supabase session left from a previous owner login.
String resolveActiveFarmId({
  required AppUser user,
  SupabaseClient? supabase,
}) {
  final fromUser = user.activeFarmId.trim();
  if (fromUser.isNotEmpty) {
    return fromUser;
  }

  if (user.authenticatedOffline) {
    return '';
  }

  final client = supabase;
  if (client != null) {
    final metadata = client.auth.currentUser?.userMetadata;
    final fromMetadata =
        metadata?['farm_id']?.toString() ??
        metadata?['farmId']?.toString() ??
        metadata?['tenant_id']?.toString() ??
        metadata?['tenantId']?.toString() ??
        '';
    if (fromMetadata.isNotEmpty) {
      return fromMetadata;
    }
  }

  return '';
}

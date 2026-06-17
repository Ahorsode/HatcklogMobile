import 'dart:async';

import 'package:flutter/foundation.dart';

import '../features/auth/data/auth_repository.dart';
import '../features/auth/data/supabase_remote_api.dart';
import '../core/storage/local_database.dart';
import '../core/models/app_user.dart';
import 'permissions/farm_permissions.dart';
import 'permissions/permissions_repository.dart';
import 'connectivity/connectivity_service.dart';

class SessionWatcher {
  SessionWatcher({
    required this.authRepository,
    required this.remoteApi,
    required this.localDatabase,
    required this.permissionsRepository,
    required this.currentUser,
    required this.connectivityService,
    required this.onForcedSignOut,
    required this.onPermissionsChanged,
    this.pollInterval = const Duration(seconds: 12),
  });

  final AuthRepository authRepository;
  final SupabaseRemoteApi remoteApi;
  final LocalDatabase localDatabase;
  final PermissionsRepository permissionsRepository;
  final AppUser currentUser;
  final ConnectivityService connectivityService;
  final VoidCallback onForcedSignOut;
  final ValueChanged<FarmPermissions> onPermissionsChanged;
  final Duration pollInterval;

  Timer? _timer;
  FarmPermissions? _lastPermissions;

  void start() {
    if (!remoteApi.isConfigured) return;
    if (currentUser.authenticatedOffline) return;
    if (currentUser.role.hasUniversalAccess) return;
    _timer = Timer.periodic(pollInterval, (_) => _check());
  }

  void dispose() {
    _timer?.cancel();
  }

  Future<void> _check() async {
    try {
      // Query remote for role of current user
      final client = remoteApi;
      if (!client.isConfigured) return;
      if (!await connectivityService.isOnline) return;

      final remoteRole = await client.fetchUserRoleByIdentifier(
        currentUser.loginIdentifier,
      );
      final remoteUserRole = UserRole.fromString(remoteRole);
      if (remoteUserRole != UserRole.unknown &&
          remoteUserRole != currentUser.role) {
        // Role changed remotely — force logout
        await authRepository.signOut();
        onForcedSignOut();
        return;
      }

      final remotePermissions = await client.fetchUserPermissionsRow(
        userId: currentUser.id,
        farmId: currentUser.activeFarmId,
      );
      if (remotePermissions != null) {
        await localDatabase.upsertCloudRecords({
          'user_permissions': [remotePermissions],
        });
      }
      final permissions = await permissionsRepository.loadForUser(currentUser);
      if (_lastPermissions != permissions) {
        _lastPermissions = permissions;
        onPermissionsChanged(permissions);
      }
    } catch (_) {
      // ignore network errors
    }
  }
}

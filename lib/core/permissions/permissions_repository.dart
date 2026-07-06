import '../models/app_user.dart';
import '../storage/local_database.dart';
import 'farm_permissions.dart';
import 'staff_permission_defaults.dart';

class PermissionsRepository {
  const PermissionsRepository({required LocalDatabase localDatabase})
    : _localDatabase = localDatabase;

  final LocalDatabase _localDatabase;

  Future<FarmPermissions> loadForUser(AppUser user) async {
    if (user.role == UserRole.owner || user.role == UserRole.admin) {
      return FarmPermissions.fullAccess();
    }
    if (user.role == UserRole.manager) {
      return FarmPermissions.fullAccess();
    }
    if (user.id.isEmpty || user.activeFarmId.isEmpty) {
      return const FarmPermissions();
    }

    final rows = await _localDatabase.rawLocalQuery(
      '''
      select * from user_permissions
      where user_id = ? and farm_id = ?
      limit 1
      ''',
      [user.id, user.activeFarmId],
    );
    if (rows.isNotEmpty) {
      return _applyRoleHealthDefaults(
        user.role.name,
        FarmPermissions.fromMap(rows.first),
      );
    }

    if (user.activeFarmId.isNotEmpty &&
        (user.role == UserRole.worker ||
            user.role == UserRole.cashier ||
            user.role == UserRole.accountant ||
            user.role == UserRole.manager)) {
      return defaultPermissionsForRole(user.role.name);
    }

    return const FarmPermissions();
  }

  /// Grants health access for legacy permission rows created before health
  /// columns existed (mirrors web migration copying mortality -> health).
  FarmPermissions _applyRoleHealthDefaults(
    String role,
    FarmPermissions stored,
  ) {
    final defaults = defaultPermissionsForRole(role);
    final map = stored.toMap();
    var changed = false;

    if (!stored.canViewHealth &&
        defaults.canViewHealth &&
        (stored.canViewMortality ||
            stored.canViewEggs ||
            stored.canViewFeeding)) {
      map['can_view_health'] = true;
      changed = true;
    }

    if (!stored.canEditHealth &&
        (stored.canEditMortality || defaults.canEditHealth) &&
        (map['can_view_health'] == true || stored.canViewHealth)) {
      map['can_edit_health'] = true;
      changed = true;
    }

    return changed ? FarmPermissions.fromToggleMap(map) : stored;
  }
}

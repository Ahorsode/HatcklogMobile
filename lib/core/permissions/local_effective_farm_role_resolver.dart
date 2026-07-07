import '../models/app_user.dart';
import '../storage/local_database.dart';
import 'navigation_permissions.dart';

/// Resolves farm-effective routing role from cached [farm_members] and [farms].
class LocalEffectiveFarmRoleResolver {
  LocalEffectiveFarmRoleResolver(this._database);

  final LocalDatabase _database;

  Future<UserRole> resolveRole({
    required String userId,
    required String farmId,
  }) async {
    if (userId.isEmpty || farmId.isEmpty) {
      return UserRole.unknown;
    }

    final farmRows = await _database.queryLocalRecords(
      'farms',
      where: 'id = ?',
      whereArgs: [farmId],
      limit: 1,
    );
    final farmOwnerId = farmRows.isEmpty
        ? ''
        : farmRows.first['user_id']?.toString().trim() ?? '';

    final memberRows = await _database.queryLocalRecords(
      'farm_members',
      where: 'farm_id = ? and user_id = ?',
      whereArgs: [farmId, userId],
      limit: 1,
    );
    final membershipRole = memberRows.isEmpty
        ? UserRole.unknown
        : UserRole.fromString(memberRows.first['role']?.toString());

    return resolveEffectiveFarmRole(
      farmOwnerId: farmOwnerId,
      userId: userId,
      membershipRole: membershipRole,
    );
  }

  Future<AppUser> applyToUser(AppUser user) async {
    final farmId = user.activeFarmId.trim();
    final userId = user.id.trim();
    if (farmId.isEmpty || userId.isEmpty) {
      return user;
    }

    final effectiveRole = await resolveRole(userId: userId, farmId: farmId);
    if (effectiveRole == user.role) {
      return user;
    }
    return user.copyWith(role: effectiveRole);
  }
}

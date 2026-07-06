import '../../../core/models/app_user.dart';
import '../../../core/permissions/farm_permissions.dart';
import '../../../core/permissions/navigation_permissions.dart';
import '../../../core/permissions/staff_permission_defaults.dart';
import '../../../core/storage/local_database.dart';
import '../../auth/data/supabase_remote_api.dart';
import '../../management/data/management_models.dart';

class TeamSnapshot {
  const TeamSnapshot({
    required this.members,
    required this.currentUserRole,
    required this.isAbsoluteOwner,
    required this.canViewTeam,
    required this.canEditTeam,
    required this.canInvite,
    required this.canManagePermissions,
    required this.canChangeRoles,
  });

  final List<TeamMemberRecord> members;
  final UserRole currentUserRole;
  final bool isAbsoluteOwner;
  final bool canViewTeam;
  final bool canEditTeam;
  final bool canInvite;
  final bool canManagePermissions;
  final bool canChangeRoles;
}

class TeamRepository {
  TeamRepository({
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
  }) : _localDatabase = localDatabase,
       _remoteApi = remoteApi;

  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;

  Future<TeamSnapshot> loadSnapshot({
    required AppUser currentUser,
    required FarmPermissions permissions,
    required bool isFarmOwner,
  }) async {
    final farmId = currentUser.activeFarmId;
    final members = await _loadTeamMembers(farmId);
    final currentRole = isFarmOwner
        ? UserRole.owner
        : members
                  .where((member) => member.userId == currentUser.id)
                  .map((member) => member.role)
                  .firstOrNull ??
              currentUser.role;

    final canView = canViewModule(
      role: currentRole,
      isFarmOwner: isFarmOwner,
      permissions: permissions,
      module: 'team',
    );
    final canEdit = canEditModule(
      role: currentRole,
      isFarmOwner: isFarmOwner,
      permissions: permissions,
      module: 'team',
    );

    return TeamSnapshot(
      members: members,
      currentUserRole: currentRole,
      isAbsoluteOwner: isFarmOwner,
      canViewTeam: canView,
      canEditTeam: canEdit,
      canInvite: canEdit && (isFarmOwner || currentRole == UserRole.manager),
      canManagePermissions: isFarmOwner,
      canChangeRoles: isFarmOwner,
    );
  }

  Future<FarmPermissions?> loadMemberPermissions({
    required String farmId,
    required String userId,
  }) async {
    final rows = await _localDatabase.rawLocalQuery(
      '''
      select * from user_permissions
      where farm_id = ? and user_id = ?
      limit 1
      ''',
      [farmId, userId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return FarmPermissions.fromMap(rows.first).withLegacyHealthBackfill();
  }

  Future<void> updateMemberPermissions({
    required AppUser owner,
    required String targetUserId,
    required FarmPermissions permissions,
  }) async {
    final farmId = owner.activeFarmId;
    final permissionId = 'perm_${farmId}_$targetUserId';
    final row = permissions.toDbRow(
      id: permissionId,
      userId: targetUserId,
      farmId: farmId,
    );

    await _localDatabase.insertLocalRecord('user_permissions', row);
    await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: owner.id,
        inputType: 'team_permission_update',
        payload: {
          'farm_id': farmId,
          'target_user_id': targetUserId,
          'permissions': permissions.toMap(),
        },
        createdAt: DateTime.now(),
      ),
    );

    if (_remoteApi.isConfigured) {
      await _remoteApi.updateWorkerPermissions(
        farmId: farmId,
        targetUserId: targetUserId,
        permissions: permissions,
      );
    }
  }

  Future<void> resetMemberPermissions({
    required AppUser owner,
    required TeamMemberRecord member,
  }) async {
    final defaults = defaultPermissionsForRole(member.role.apiRole);
    await updateMemberPermissions(
      owner: owner,
      targetUserId: member.userId,
      permissions: defaults,
    );
  }

  Future<void> promoteTeamMember({
    required AppUser owner,
    required TeamMemberRecord member,
    required UserRole targetRole,
  }) async {
    await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: owner.id,
        inputType: 'role_promotion',
        payload: {
          'farm_id': owner.activeFarmId,
          'target_user_id': member.userId,
          'membership_id': member.membershipId,
          'new_role': targetRole.apiRole,
        },
        createdAt: DateTime.now(),
      ),
    );

    await _localDatabase.updateLocalRecord(
      'farm_members',
      {'role': targetRole.apiRole},
      where: 'id = ?',
      whereArgs: [member.membershipId],
    );

    if (_remoteApi.isConfigured) {
      await _remoteApi.promoteFarmMemberAndRevokeSessions(
        farmId: owner.activeFarmId,
        targetUserId: member.userId,
        newRole: targetRole.apiRole,
      );
    }
  }

  Future<List<TeamMemberRecord>> _loadTeamMembers(String farmId) async {
    final rows = await _localDatabase.rawLocalQuery(
      '''
      select fm.id as membership_id,
             fm.user_id as user_id,
             fm.role as role,
             u.first_name as first_name,
             u.last_name as last_name,
             u.phone_number as phone
      from farm_members fm
      left join local_users u on u.id = fm.user_id
      where fm.farm_id = ?
      order by fm.role asc
      ''',
      [farmId],
    );

    return rows.map((row) {
      final first = row['first_name']?.toString() ?? '';
      final last = row['last_name']?.toString() ?? '';
      final name = '$first $last'.trim();
      return TeamMemberRecord(
        membershipId: row['membership_id']?.toString() ?? '',
        userId: row['user_id']?.toString() ?? '',
        name: name.isEmpty
            ? (row['phone']?.toString() ?? 'Team member')
            : name,
        phone: row['phone']?.toString() ?? '',
        role: UserRole.fromString(row['role']?.toString()),
      );
    }).toList();
  }
}

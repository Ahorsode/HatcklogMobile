import '../models/app_user.dart';
import '../storage/local_database.dart';
import 'farm_permissions.dart';

class PermissionsRepository {
  const PermissionsRepository({required LocalDatabase localDatabase})
    : _localDatabase = localDatabase;

  final LocalDatabase _localDatabase;

  Future<FarmPermissions> loadForUser(AppUser user) async {
    if (user.role == UserRole.owner || user.role == UserRole.admin) {
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
      return FarmPermissions.fromMap(rows.first);
    }

    return const FarmPermissions();
  }
}

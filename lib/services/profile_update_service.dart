import '../core/models/app_user.dart';
import '../core/settings/settings_profile_contract.dart';
import '../core/storage/local_database.dart';

class ProfileUpdateService {
  ProfileUpdateService(this._database);

  final LocalDatabase _database;

  Future<ProfileEditData> load(AppUser user) async {
    return ProfileEditData(
      firstName: user.firstName,
      middleName: user.middleName,
      surname: user.lastName,
      email: user.email,
      roleLabel: user.role.label,
    );
  }

  Future<AppUser> saveProfile({
    required AppUser user,
    required String firstName,
    String middleName = '',
    required String surname,
  }) async {
    final validation = SettingsProfileContract.validateProfileNames(
      firstName: firstName,
      surname: surname,
    );
    if (validation != null) {
      throw StateError(validation);
    }

    final updated = user.copyWith(
      firstName: firstName.trim(),
      middleName: middleName.trim(),
      lastName: surname.trim(),
    );
    await _database.upsertUser(updated);
    await _database.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'profile_update',
        payload: {
          'user_id': user.id,
          'firstname': firstName.trim(),
          'middle_name': middleName.trim(),
          'surname': surname.trim(),
          'name': SettingsProfileContract.buildDisplayName(
            firstName: firstName,
            middleName: middleName,
            surname: surname,
          ),
        },
        createdAt: DateTime.now(),
      ),
    );
    return updated;
  }
}

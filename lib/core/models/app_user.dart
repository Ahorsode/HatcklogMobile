enum UserRole {
  worker,
  manager,
  accountant,
  owner,
  admin,
  unknown;

  static UserRole fromString(String? value) {
    switch (_roleKey(value)) {
      case 'worker':
      case 'farmworker':
      case 'staff':
        return UserRole.worker;
      case 'manager':
      case 'farmmanager':
        return UserRole.manager;
      case 'accountant':
      case 'finance':
      case 'bookkeeper':
        return UserRole.accountant;
      case 'owner':
      case 'owners':
      case 'farmowner':
      case 'farmowners':
      case 'primaryowner':
      case 'proprietor':
      case 'businessowner':
      case 'accountowner':
        return UserRole.owner;
      case 'admin':
      case 'admins':
      case 'farmadmin':
      case 'farmadmins':
      case 'administrator':
      case 'administrators':
      case 'superadmin':
      case 'systemadmin':
      case 'sysadmin':
      case 'appadmin':
      case 'mobileadmin':
      case 'superuser':
        return UserRole.admin;
      default:
        return UserRole.unknown;
    }
  }

  static String _roleKey(String? value) {
    return value?.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '') ??
        '';
  }

  String get label {
    switch (this) {
      case UserRole.worker:
        return 'Worker';
      case UserRole.manager:
        return 'Manager';
      case UserRole.accountant:
        return 'Accountant';
      case UserRole.owner:
        return 'Owner';
      case UserRole.admin:
        return 'Admin';
      case UserRole.unknown:
        return 'Unknown';
    }
  }

  bool get hasUniversalAccess {
    return this == UserRole.owner || this == UserRole.admin;
  }

  bool get hasMobileDashboardAccess {
    switch (this) {
      case UserRole.worker:
      case UserRole.manager:
      case UserRole.accountant:
      case UserRole.owner:
      case UserRole.admin:
        return true;
      case UserRole.unknown:
        return false;
    }
  }
}

class AppUser {
  const AppUser({
    required this.id,
    required this.phoneNumber,
    required this.role,
    this.email = '',
    this.firstName = '',
    this.lastName = '',
    this.activeFarmId = '',
    this.activeBatchId = '',
    this.requiresInitialSetup = false,
    this.authenticatedOffline = false,
  });

  final String id;
  final String phoneNumber;
  final String email;
  final UserRole role;
  final String firstName;
  final String lastName;
  final String activeFarmId;
  final String activeBatchId;
  final bool requiresInitialSetup;
  final bool authenticatedOffline;

  String get batchLabel {
    return activeBatchId.trim().isEmpty ? 'Unassigned Batch' : activeBatchId;
  }

  String get displayName {
    final fullName = '$firstName $lastName'.trim();
    if (fullName.isNotEmpty) {
      return fullName;
    }
    if (email.trim().isNotEmpty) {
      return email;
    }
    return phoneNumber;
  }

  String get loginIdentifier {
    final normalizedPhone = phoneNumber.trim();
    if (normalizedPhone.isNotEmpty) {
      return normalizedPhone;
    }
    return email.trim().toLowerCase();
  }

  AppUser copyWith({
    String? id,
    String? phoneNumber,
    String? email,
    UserRole? role,
    String? firstName,
    String? lastName,
    String? activeFarmId,
    String? activeBatchId,
    bool? requiresInitialSetup,
    bool? authenticatedOffline,
  }) {
    return AppUser(
      id: id ?? this.id,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      role: role ?? this.role,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      activeFarmId: activeFarmId ?? this.activeFarmId,
      activeBatchId: activeBatchId ?? this.activeBatchId,
      requiresInitialSetup: requiresInitialSetup ?? this.requiresInitialSetup,
      authenticatedOffline: authenticatedOffline ?? this.authenticatedOffline,
    );
  }

  Map<String, Object?> toMap() {
    return {
      'id': id,
      'phone_number': phoneNumber,
      'email': email,
      'role': role.name,
      'first_name': firstName,
      'last_name': lastName,
      'active_farm_id': activeFarmId,
      'active_batch_id': activeBatchId,
      'updated_at': DateTime.now().toIso8601String(),
    };
  }

  static AppUser fromMap(Map<String, Object?> map) {
    return AppUser(
      id: map['id'] as String,
      phoneNumber: map['phone_number'] as String,
      email: (map['email'] as String?) ?? '',
      role: UserRole.fromString(map['role'] as String?),
      firstName: (map['first_name'] as String?) ?? '',
      lastName: (map['last_name'] as String?) ?? '',
      activeFarmId: (map['active_farm_id'] as String?) ?? '',
      activeBatchId: (map['active_batch_id'] as String?) ?? '',
    );
  }
}

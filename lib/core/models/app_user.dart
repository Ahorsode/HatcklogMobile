enum UserRole {
  worker,
  manager,
  accountant,
  cashier,
  financeOfficer,
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
      case 'cashier':
        return UserRole.cashier;
      case 'financeofficer':
        return UserRole.financeOfficer;
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
      case UserRole.cashier:
        return 'Cashier';
      case UserRole.financeOfficer:
        return 'Finance Officer';
      case UserRole.owner:
        return 'Owner';
      case UserRole.admin:
        return 'Admin';
      case UserRole.unknown:
        return 'Unknown';
    }
  }

  String get apiRole {
    switch (this) {
      case UserRole.financeOfficer:
        return 'FINANCE_OFFICER';
      case UserRole.cashier:
        return 'CASHIER';
      case UserRole.worker:
        return 'WORKER';
      case UserRole.manager:
        return 'MANAGER';
      case UserRole.accountant:
        return 'ACCOUNTANT';
      case UserRole.owner:
        return 'OWNER';
      case UserRole.admin:
        return 'ADMIN';
      case UserRole.unknown:
        return 'WORKER';
    }
  }

  bool get hasUniversalAccess {
    return this == UserRole.owner ||
        this == UserRole.admin ||
        this == UserRole.manager;
  }

  bool get hasMobileDashboardAccess {
    switch (this) {
      case UserRole.worker:
      case UserRole.manager:
      case UserRole.accountant:
      case UserRole.cashier:
      case UserRole.financeOfficer:
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
    this.middleName = '',
    this.lastName = '',
    this.activeFarmId = '',
    this.activeFarmName = '',
    this.activeBatchId = '',
    this.activeBatchName = '',
    this.requiresInitialSetup = false,
    this.authenticatedOffline = false,
  });

  final String id;
  final String phoneNumber;
  final String email;
  final UserRole role;
  final String firstName;
  final String middleName;
  final String lastName;
  final String activeFarmId;
  final String activeFarmName;
  final String activeBatchId;
  final String activeBatchName;
  final bool requiresInitialSetup;
  final bool authenticatedOffline;

  String get farmLabel {
    final name = activeFarmName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return activeFarmId.trim().isEmpty ? 'Active Farm Monitor' : 'Active Farm Monitor';
  }

  String get farmDisplayLabel {
    final name = activeFarmName.trim();
    if (name.isNotEmpty) {
      return 'Active Farm Monitor - $name';
    }
    return 'Active Farm Monitor';
  }

  String get batchLabel {
    final name = activeBatchName.trim();
    if (name.isNotEmpty) {
      return name;
    }
    return activeBatchId.trim().isEmpty ? 'Unassigned Batch' : 'Batch';
  }

  String get displayName {
    final middle = middleName.trim();
    final fullName = middle.isEmpty
        ? '$firstName $lastName'.trim()
        : '$firstName $middle $lastName'.trim();
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
    String? middleName,
    String? lastName,
    String? activeFarmId,
    String? activeFarmName,
    String? activeBatchId,
    String? activeBatchName,
    bool? requiresInitialSetup,
    bool? authenticatedOffline,
  }) {
    return AppUser(
      id: id ?? this.id,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      email: email ?? this.email,
      role: role ?? this.role,
      firstName: firstName ?? this.firstName,
      middleName: middleName ?? this.middleName,
      lastName: lastName ?? this.lastName,
      activeFarmId: activeFarmId ?? this.activeFarmId,
      activeFarmName: activeFarmName ?? this.activeFarmName,
      activeBatchId: activeBatchId ?? this.activeBatchId,
      activeBatchName: activeBatchName ?? this.activeBatchName,
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
      'middle_name': middleName,
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
      middleName: (map['middle_name'] as String?) ?? '',
      lastName: (map['last_name'] as String?) ?? '',
      activeFarmId: (map['active_farm_id'] as String?) ?? '',
      activeBatchId: (map['active_batch_id'] as String?) ?? '',
    );
  }
}

import '../models/app_user.dart';
import 'farm_permissions.dart';

/// Resolves farm-scoped navigation role — mirrors web `resolveFarmNavigationRole`.
String resolveFarmNavigationRole({
  required String farmOwnerId,
  required String userId,
  String? userRole,
  String? membershipRole,
}) {
  if (farmOwnerId == userId) {
    return 'OWNER';
  }
  if (membershipRole != null && membershipRole.isNotEmpty) {
    return membershipRole.toUpperCase();
  }
  if (userRole != null &&
      userRole.isNotEmpty &&
      userRole.toUpperCase() != 'OWNER') {
    return userRole.toUpperCase();
  }
  return 'WORKER';
}

/// Farm-scoped role for auth and dashboard routing — mirrors web dashboard/page.tsx.
UserRole resolveEffectiveFarmRole({
  required String farmOwnerId,
  required String userId,
  UserRole membershipRole = UserRole.unknown,
}) {
  final navigationRole = resolveFarmNavigationRole(
    farmOwnerId: farmOwnerId,
    userId: userId,
    membershipRole: membershipRole == UserRole.unknown
        ? null
        : membershipRole.name.toUpperCase(),
  );
  return UserRole.fromString(navigationRole);
}

/// Human-readable label for a role enum value.
String formatRoleLabel(String? role) {
  if (role == null || role.trim().isEmpty) {
    return 'Unknown';
  }
  return role
      .trim()
      .toUpperCase()
      .split('_')
      .map((part) {
        if (part.isEmpty) {
          return part;
        }
        return part[0] + part.substring(1).toLowerCase();
      })
      .join(' ');
}

const _navPermissionMap = <String, List<String>>{
  'Finance Control': ['can_view_finance', 'can_edit_finance'],
  'Finance Hub': ['can_view_finance', 'can_edit_finance'],
  'Reports': ['can_view_finance', 'can_edit_finance'],
  'Livestock': ['can_view_batches', 'can_edit_batches'],
  'Analytics': ['can_view_batches', 'can_edit_batches'],
  'Inventory': ['can_view_inventory', 'can_edit_inventory'],
  'Sales': ['can_view_sales', 'can_edit_sales'],
  'Eggs': ['can_view_eggs', 'can_edit_eggs'],
  'Feeding': ['can_view_feeding', 'can_edit_feeding'],
  'Houses': ['can_view_houses', 'can_edit_houses'],
  'Mortality': ['can_view_mortality', 'can_edit_mortality'],
  'Quarantine': ['can_view_mortality', 'can_edit_mortality'],
  'Health': ['can_view_health', 'can_edit_health'],
  'Customers': ['can_view_customers', 'can_edit_customers'],
  'Suppliers': ['can_view_customers', 'can_edit_customers'],
  'Team Management': ['can_view_team', 'can_edit_team'],
  'Team': ['can_view_team', 'can_edit_team'],
};

bool canShowNavigationItem({
  required String name,
  required String? role,
  required List<String> roles,
  FarmPermissions? permissions,
}) {
  final normalizedRole = role?.trim().toUpperCase();
  if (normalizedRole == 'OWNER' || normalizedRole == 'MANAGER') {
    return true;
  }
  if (normalizedRole == null ||
      normalizedRole.isEmpty ||
      !roles.map((r) => r.toUpperCase()).contains(normalizedRole)) {
    return false;
  }

  final permissionKeys = _navPermissionMap[name];
  if (permissionKeys == null) {
    return true;
  }
  if (permissions == null) {
    return false;
  }

  final map = permissions.toMap();
  return permissionKeys.any((key) => map[key] == true);
}

/// Module-level view gate aligned with web `checkWorkerPermissions(..., 'view')`.
bool canViewModule({
  required UserRole role,
  required bool isFarmOwner,
  required FarmPermissions permissions,
  required String module,
}) {
  if (isFarmOwner || role == UserRole.owner) {
    return true;
  }
  if (role == UserRole.manager) {
    return true;
  }

  return switch (module) {
    'finance' =>
      permissions.canViewFinance || permissions.canEditFinance,
    'inventory' =>
      permissions.canViewInventory || permissions.canEditInventory,
    'batches' => permissions.canViewBatches || permissions.canEditBatches,
    'sales' => permissions.canViewSales || permissions.canEditSales,
    'eggs' => permissions.canViewEggs || permissions.canEditEggs,
    'feeding' => permissions.canViewFeeding || permissions.canEditFeeding,
    'houses' => permissions.canViewHouses || permissions.canEditHouses,
    'mortality' =>
      permissions.canViewMortality || permissions.canEditMortality,
    'health' => permissions.canViewHealth || permissions.canEditHealth,
    'customers' =>
      permissions.canViewCustomers || permissions.canEditCustomers,
    'team' => permissions.canViewTeam || permissions.canEditTeam,
    _ => false,
  };
}

/// Module-level edit gate aligned with web `checkWorkerPermissions(..., 'edit')`.
bool canEditModule({
  required UserRole role,
  required bool isFarmOwner,
  required FarmPermissions permissions,
  required String module,
}) {
  if (isFarmOwner || role == UserRole.owner) {
    return true;
  }
  if (role == UserRole.manager) {
    return true;
  }

  return switch (module) {
    'finance' => permissions.canEditFinance,
    'inventory' => permissions.canEditInventory,
    'batches' => permissions.canEditBatches,
    'sales' => permissions.canEditSales,
    'eggs' => permissions.canEditEggs,
    'feeding' => permissions.canEditFeeding,
    'houses' => permissions.canEditHouses,
    'mortality' => permissions.canEditMortality,
    'health' => permissions.canEditHealth,
    'customers' => permissions.canEditCustomers,
    'team' => permissions.canEditTeam,
    _ => false,
  };
}

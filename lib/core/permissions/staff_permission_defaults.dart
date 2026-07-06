import 'farm_permissions.dart';

/// Web-parity staff roles for farm team management (not platform admin).
const assignableStaffRoles = <String>[
  'WORKER',
  'CASHIER',
  'MANAGER',
  'ACCOUNTANT',
  'FINANCE_OFFICER',
];

/// Returns role defaults merged with optional overrides — mirrors web
/// `getDefaultPermissionsForRole` in poultry-pms.
FarmPermissions defaultPermissionsForRole(
  String role, {
  Map<String, bool>? overrides,
}) {
  final defaults = _roleDefaults(role);
  if (overrides == null || overrides.isEmpty) {
    return defaults;
  }

  final map = defaults.toMap();
  for (final entry in overrides.entries) {
    final key = _normalizePermissionKey(entry.key);
    if (map.containsKey(key)) {
      map[key] = entry.value;
    }
  }
  return FarmPermissions.fromToggleMap(map);
}

FarmPermissions _roleDefaults(String role) {
  const base = FarmPermissions();

  const workerDefaults = FarmPermissions(
    canViewEggs: true,
    canEditEggs: true,
    canViewFeeding: true,
    canEditFeeding: true,
    canViewMortality: true,
    canEditMortality: true,
    canViewHealth: true,
    canEditHealth: true,
    canViewBatches: true,
  );

  const managerDefaults = FarmPermissions(
    canViewFinance: true,
    canEditFinance: true,
    canViewInventory: true,
    canEditInventory: true,
    canViewBatches: true,
    canEditBatches: true,
    canViewSales: true,
    canEditSales: true,
    canViewEggs: true,
    canEditEggs: true,
    canViewFeeding: true,
    canEditFeeding: true,
    canViewHouses: true,
    canEditHouses: true,
    canViewMortality: true,
    canEditMortality: true,
    canViewCustomers: true,
    canEditCustomers: true,
    canViewTeam: true,
    canEditTeam: true,
  );

  const accountantDefaults = FarmPermissions(
    canViewFinance: true,
    canEditFinance: true,
    canViewSales: true,
    canViewInventory: true,
  );

  const financeOfficerDefaults = FarmPermissions(
    canViewFinance: true,
    canEditFinance: true,
    canViewSales: true,
    canEditSales: true,
    canViewInventory: true,
  );

  const cashierDefaults = FarmPermissions(
    canViewSales: true,
    canEditSales: true,
    canViewFinance: true,
  );

  return switch (role.trim().toUpperCase()) {
    'MANAGER' => managerDefaults,
    'ACCOUNTANT' => accountantDefaults,
    'FINANCE_OFFICER' => financeOfficerDefaults,
    'CASHIER' => cashierDefaults,
    'WORKER' => workerDefaults,
    _ => base,
  };
}

/// Applies view/edit coupling used by web PermissionsModal toggles.
FarmPermissions setPermission(FarmPermissions current, String key, bool value) {
  final map = current.toMap();
  final snakeKey = _normalizePermissionKey(key);
  if (!map.containsKey(snakeKey)) {
    return current;
  }

  map[snakeKey] = value;

  if (snakeKey.startsWith('can_view_') && value == false) {
    final editKey = snakeKey.replaceFirst('can_view_', 'can_edit_');
    if (map.containsKey(editKey)) {
      map[editKey] = false;
    }
  }
  if (snakeKey.startsWith('can_edit_') && value == true) {
    final viewKey = snakeKey.replaceFirst('can_edit_', 'can_view_');
    if (map.containsKey(viewKey)) {
      map[viewKey] = true;
    }
  }

  return FarmPermissions.fromToggleMap(map);
}

/// Toggles a permission flag with view/edit coupling.
FarmPermissions togglePermission(FarmPermissions current, String key) {
  final map = current.toMap();
  final snakeKey = _normalizePermissionKey(key);
  if (!map.containsKey(snakeKey)) {
    return current;
  }
  return setPermission(current, snakeKey, !(map[snakeKey] ?? false));
}

String _normalizePermissionKey(String key) {
  if (key.contains('_')) {
    return key;
  }
  final buffer = StringBuffer();
  for (var i = 0; i < key.length; i++) {
    final char = key[i];
    if (char == char.toUpperCase() && i > 0) {
      buffer.write('_');
    }
    buffer.write(char.toLowerCase());
  }
  return buffer.toString();
}

/// Permission matrix rows for team UI (view + edit pairs).
const teamPermissionModules = <({String label, String viewKey, String editKey})>[
  (label: 'Finance', viewKey: 'can_view_finance', editKey: 'can_edit_finance'),
  (
    label: 'Inventory',
    viewKey: 'can_view_inventory',
    editKey: 'can_edit_inventory',
  ),
  (
    label: 'Livestock / Batches',
    viewKey: 'can_view_batches',
    editKey: 'can_edit_batches',
  ),
  (label: 'Sales', viewKey: 'can_view_sales', editKey: 'can_edit_sales'),
  (label: 'Eggs', viewKey: 'can_view_eggs', editKey: 'can_edit_eggs'),
  (
    label: 'Feeding',
    viewKey: 'can_view_feeding',
    editKey: 'can_edit_feeding',
  ),
  (label: 'Houses', viewKey: 'can_view_houses', editKey: 'can_edit_houses'),
  (
    label: 'Mortality / Quarantine',
    viewKey: 'can_view_mortality',
    editKey: 'can_edit_mortality',
  ),
  (
    label: 'Health',
    viewKey: 'can_view_health',
    editKey: 'can_edit_health',
  ),
  (
    label: 'Customers / Suppliers',
    viewKey: 'can_view_customers',
    editKey: 'can_edit_customers',
  ),
  (
    label: 'Team Management',
    viewKey: 'can_view_team',
    editKey: 'can_edit_team',
  ),
];

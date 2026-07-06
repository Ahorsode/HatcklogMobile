import '../models/app_user.dart';

class FarmPermissions {
  const FarmPermissions({
    this.canViewFinance = false,
    this.canEditFinance = false,
    this.canViewInventory = false,
    this.canEditInventory = false,
    this.canViewBatches = false,
    this.canEditBatches = false,
    this.canViewSales = false,
    this.canEditSales = false,
    this.canViewEggs = false,
    this.canEditEggs = false,
    this.canViewFeeding = false,
    this.canEditFeeding = false,
    this.canViewHouses = false,
    this.canEditHouses = false,
    this.canViewMortality = false,
    this.canEditMortality = false,
    this.canViewHealth = false,
    this.canEditHealth = false,
    this.canViewCustomers = false,
    this.canEditCustomers = false,
    this.canViewTeam = false,
    this.canEditTeam = false,
  });

  final bool canViewFinance;
  final bool canEditFinance;
  final bool canViewInventory;
  final bool canEditInventory;
  final bool canViewBatches;
  final bool canEditBatches;
  final bool canViewSales;
  final bool canEditSales;
  final bool canViewEggs;
  final bool canEditEggs;
  final bool canViewFeeding;
  final bool canEditFeeding;
  final bool canViewHouses;
  final bool canEditHouses;
  final bool canViewMortality;
  final bool canEditMortality;
  final bool canViewHealth;
  final bool canEditHealth;
  final bool canViewCustomers;
  final bool canEditCustomers;
  final bool canViewTeam;
  final bool canEditTeam;

  factory FarmPermissions.fullAccess() => const FarmPermissions(
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
    canViewHealth: true,
    canEditHealth: true,
    canViewCustomers: true,
    canEditCustomers: true,
    canViewTeam: true,
    canEditTeam: true,
  );

  factory FarmPermissions.fromMap(Map<String, Object?> row) {
    return FarmPermissions(
      canViewFinance: _truthy(row['can_view_finance']),
      canEditFinance: _truthy(row['can_edit_finance']),
      canViewInventory: _truthy(row['can_view_inventory']),
      canEditInventory: _truthy(row['can_edit_inventory']),
      canViewBatches: _truthy(row['can_view_batches']),
      canEditBatches: _truthy(row['can_edit_batches']),
      canViewSales: _truthy(row['can_view_sales']),
      canEditSales: _truthy(row['can_edit_sales']),
      canViewEggs: _truthy(row['can_view_eggs']),
      canEditEggs: _truthy(row['can_edit_eggs']),
      canViewFeeding: _truthy(row['can_view_feeding']),
      canEditFeeding: _truthy(row['can_edit_feeding']),
      canViewHouses: _truthy(row['can_view_houses']),
      canEditHouses: _truthy(row['can_edit_houses']),
      canViewMortality: _truthy(row['can_view_mortality']),
      canEditMortality: _truthy(row['can_edit_mortality']),
      canViewCustomers: _truthy(row['can_view_customers']),
      canEditCustomers: _truthy(row['can_edit_customers']),
      canViewTeam: _truthy(row['can_view_team']),
      canEditTeam: _truthy(row['can_edit_team']),
    );
  }

  factory FarmPermissions.fromToggleMap(Map<String, bool> map) {
    return FarmPermissions(
      canViewFinance: map['can_view_finance'] ?? false,
      canEditFinance: map['can_edit_finance'] ?? false,
      canViewInventory: map['can_view_inventory'] ?? false,
      canEditInventory: map['can_edit_inventory'] ?? false,
      canViewBatches: map['can_view_batches'] ?? false,
      canEditBatches: map['can_edit_batches'] ?? false,
      canViewSales: map['can_view_sales'] ?? false,
      canEditSales: map['can_edit_sales'] ?? false,
      canViewEggs: map['can_view_eggs'] ?? false,
      canEditEggs: map['can_edit_eggs'] ?? false,
      canViewFeeding: map['can_view_feeding'] ?? false,
      canEditFeeding: map['can_edit_feeding'] ?? false,
      canViewHouses: map['can_view_houses'] ?? false,
      canEditHouses: map['can_edit_houses'] ?? false,
      canViewMortality: map['can_view_mortality'] ?? false,
      canEditMortality: map['can_edit_mortality'] ?? false,
      canViewHealth: map['can_view_health'] ?? false,
      canEditHealth: map['can_edit_health'] ?? false,
      canViewCustomers: map['can_view_customers'] ?? false,
      canEditCustomers: map['can_edit_customers'] ?? false,
      canViewTeam: map['can_view_team'] ?? false,
      canEditTeam: map['can_edit_team'] ?? false,
    );
  }

  Map<String, Object?> toDbRow({
    required String id,
    required String userId,
    required String farmId,
  }) {
    int intFlag(bool value) => value ? 1 : 0;

    return {
      'id': id,
      'user_id': userId,
      'farm_id': farmId,
      'can_view_finance': intFlag(canViewFinance),
      'can_edit_finance': intFlag(canEditFinance),
      'can_view_inventory': intFlag(canViewInventory),
      'can_edit_inventory': intFlag(canEditInventory),
      'can_view_batches': intFlag(canViewBatches),
      'can_edit_batches': intFlag(canEditBatches),
      'can_view_sales': intFlag(canViewSales),
      'can_edit_sales': intFlag(canEditSales),
      'can_view_eggs': intFlag(canViewEggs),
      'can_edit_eggs': intFlag(canEditEggs),
      'can_view_feeding': intFlag(canViewFeeding),
      'can_edit_feeding': intFlag(canEditFeeding),
      'can_view_houses': intFlag(canViewHouses),
      'can_edit_houses': intFlag(canEditHouses),
      'can_view_mortality': intFlag(canViewMortality),
      'can_edit_mortality': intFlag(canEditMortality),
      'can_view_quarantine': intFlag(canViewMortality),
      'can_edit_quarantine': intFlag(canEditMortality),
      'can_view_health': intFlag(canViewHealth),
      'can_edit_health': intFlag(canEditHealth),
      'can_view_customers': intFlag(canViewCustomers),
      'can_edit_customers': intFlag(canEditCustomers),
      'can_view_team': intFlag(canViewTeam),
      'can_edit_team': intFlag(canEditTeam),
    };
  }

  bool canViewPermission(String key) {
    return switch (key) {
      'can_view_finance' => canViewFinance,
      'can_view_inventory' => canViewInventory,
      'can_view_batches' || 'can_view_livestock' => canViewBatches,
      'can_view_sales' => canViewSales,
      'can_view_eggs' => canViewEggs,
      'can_view_feeding' => canViewFeeding,
      'can_view_houses' => canViewHouses,
      'can_view_mortality' || 'can_view_quarantine' => canViewMortality,
      'can_view_health' => canViewHealth,
      'can_view_customers' => canViewCustomers,
      'can_view_team' => canViewTeam,
      _ => false,
    };
  }

  bool canEditPermission(String key) {
    return switch (key) {
      'can_edit_finance' => canEditFinance,
      'can_edit_inventory' => canEditInventory,
      'can_edit_batches' || 'can_edit_livestock' => canEditBatches,
      'can_edit_sales' => canEditSales,
      'can_edit_eggs' => canEditEggs,
      'can_edit_feeding' => canEditFeeding,
      'can_edit_houses' => canEditHouses,
      'can_edit_mortality' || 'can_edit_quarantine' => canEditMortality,
      'can_edit_health' => canEditHealth,
      'can_edit_customers' => canEditCustomers,
      'can_edit_team' => canEditTeam,
      _ => false,
    };
  }

  Map<String, bool> toMap() {
    return {
      'can_view_finance': canViewFinance,
      'can_edit_finance': canEditFinance,
      'can_view_inventory': canViewInventory,
      'can_edit_inventory': canEditInventory,
      'can_view_batches': canViewBatches,
      'can_edit_batches': canEditBatches,
      'can_view_livestock': canViewBatches,
      'can_edit_livestock': canEditBatches,
      'can_view_sales': canViewSales,
      'can_edit_sales': canEditSales,
      'can_view_eggs': canViewEggs,
      'can_edit_eggs': canEditEggs,
      'can_view_feeding': canViewFeeding,
      'can_edit_feeding': canEditFeeding,
      'can_view_houses': canViewHouses,
      'can_edit_houses': canEditHouses,
      'can_view_mortality': canViewMortality,
      'can_edit_mortality': canEditMortality,
      'can_view_quarantine': canViewMortality,
      'can_edit_quarantine': canEditMortality,
      'can_view_health': canViewHealth,
      'can_edit_health': canEditHealth,
      'can_view_customers': canViewCustomers,
      'can_edit_customers': canEditCustomers,
      'can_view_team': canViewTeam,
      'can_edit_team': canEditTeam,
    };
  }

  static FarmPermissions forPrivilegedUser(AppUser user) {
    if (user.role == UserRole.owner || user.role == UserRole.admin) {
      return FarmPermissions.fullAccess();
    }
    return const FarmPermissions();
  }

  /// Backfills health flags when mortality is granted but health was never set
  /// (legacy rows synced before health permission columns existed).
  FarmPermissions withLegacyHealthBackfill() {
    if (canViewHealth || canEditHealth || !canViewMortality) {
      return this;
    }
    final map = toMap();
    map['can_view_health'] = true;
    if (canEditMortality) {
      map['can_edit_health'] = true;
    }
    return FarmPermissions.fromToggleMap(map);
  }

  static bool _truthy(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1' || text == 'yes' || text == 'y';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is FarmPermissions &&
            other.canViewFinance == canViewFinance &&
            other.canEditFinance == canEditFinance &&
            other.canViewInventory == canViewInventory &&
            other.canEditInventory == canEditInventory &&
            other.canViewBatches == canViewBatches &&
            other.canEditBatches == canEditBatches &&
            other.canViewSales == canViewSales &&
            other.canEditSales == canEditSales &&
            other.canViewEggs == canViewEggs &&
            other.canEditEggs == canEditEggs &&
            other.canViewFeeding == canViewFeeding &&
            other.canEditFeeding == canEditFeeding &&
            other.canViewHouses == canViewHouses &&
            other.canEditHouses == canEditHouses &&
            other.canViewMortality == canViewMortality &&
            other.canEditMortality == canEditMortality &&
            other.canViewHealth == canViewHealth &&
            other.canEditHealth == canEditHealth &&
            other.canViewCustomers == canViewCustomers &&
            other.canEditCustomers == canEditCustomers &&
            other.canViewTeam == canViewTeam &&
            other.canEditTeam == canEditTeam;
  }

  @override
  int get hashCode => Object.hashAll(toMap().values);
}

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
            other.canViewCustomers == canViewCustomers &&
            other.canEditCustomers == canEditCustomers &&
            other.canViewTeam == canViewTeam &&
            other.canEditTeam == canEditTeam;
  }

  @override
  int get hashCode => Object.hashAll(toMap().values);
}

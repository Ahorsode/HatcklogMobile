import 'package:flutter/material.dart';

import '../../core/permissions/farm_permissions.dart';

enum WorkerModule {
  eggs,
  feeding,
  mortality,
  health,
  reports,
  houses,
  sales,
  inventory,
  finance,
  customers,
  team,
}

class WorkerModuleDef {
  const WorkerModuleDef({
    required this.module,
    required this.label,
    required this.icon,
    required this.canView,
    required this.canEdit,
  });

  final WorkerModule module;
  final String label;
  final IconData icon;
  final bool canView;
  final bool canEdit;
}

List<WorkerModuleDef> buildVisibleModules(FarmPermissions permissions) {
  return [
    WorkerModuleDef(
      module: WorkerModule.eggs,
      label: 'Eggs',
      icon: Icons.egg_alt_outlined,
      canView: permissions.canViewEggs,
      canEdit: permissions.canEditEggs,
    ),
    WorkerModuleDef(
      module: WorkerModule.feeding,
      label: 'Feeding',
      icon: Icons.grass_outlined,
      canView: permissions.canViewFeeding,
      canEdit: permissions.canEditFeeding,
    ),
    WorkerModuleDef(
      module: WorkerModule.mortality,
      label: 'Mortality',
      icon: Icons.healing_outlined,
      canView: permissions.canViewMortality,
      canEdit: permissions.canEditMortality,
    ),
    WorkerModuleDef(
      module: WorkerModule.health,
      label: 'Health',
      icon: Icons.vaccines_outlined,
      canView: permissions.canViewHealth,
      canEdit: permissions.canEditHealth,
    ),
    WorkerModuleDef(
      module: WorkerModule.reports,
      label: 'Reports',
      icon: Icons.description_outlined,
      canView: permissions.canViewEggs ||
          permissions.canViewFeeding ||
          permissions.canViewMortality ||
          permissions.canViewHealth ||
          permissions.canViewFinance ||
          permissions.canViewSales,
      canEdit: false,
    ),
    WorkerModuleDef(
      module: WorkerModule.houses,
      label: 'Houses',
      icon: Icons.home_work_outlined,
      canView: permissions.canViewHouses,
      canEdit: permissions.canEditHouses,
    ),
    WorkerModuleDef(
      module: WorkerModule.sales,
      label: 'Sales',
      icon: Icons.point_of_sale_outlined,
      canView: permissions.canViewSales,
      canEdit: permissions.canEditSales,
    ),
    WorkerModuleDef(
      module: WorkerModule.inventory,
      label: 'Inventory',
      icon: Icons.inventory_2_outlined,
      canView: permissions.canViewInventory,
      canEdit: permissions.canEditInventory,
    ),
    WorkerModuleDef(
      module: WorkerModule.finance,
      label: 'Finance',
      icon: Icons.attach_money,
      canView: permissions.canViewFinance,
      canEdit: permissions.canEditFinance,
    ),
    WorkerModuleDef(
      module: WorkerModule.customers,
      label: 'Customers',
      icon: Icons.people_outline,
      canView: permissions.canViewCustomers,
      canEdit: permissions.canEditCustomers,
    ),
    WorkerModuleDef(
      module: WorkerModule.team,
      label: 'Team',
      icon: Icons.groups_outlined,
      canView: permissions.canViewTeam,
      canEdit: permissions.canEditTeam,
    ),
  ].where((module) => module.canView).toList(growable: false);
}

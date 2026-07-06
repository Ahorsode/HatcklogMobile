import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/permissions/farm_permissions.dart';
import 'package:hatchlog_m/core/permissions/navigation_permissions.dart';
import 'package:hatchlog_m/core/permissions/staff_permission_defaults.dart';

void main() {
  group('Team contract — staff permission defaults', () {
    test('worker defaults match web poultry-pms', () {
      final defaults = defaultPermissionsForRole('WORKER');
      expect(defaults.canViewEggs, isTrue);
      expect(defaults.canEditEggs, isTrue);
      expect(defaults.canViewSales, isFalse);
      expect(defaults.canViewTeam, isFalse);
    });

    test('manager defaults grant full module access', () {
      final defaults = defaultPermissionsForRole('MANAGER');
      expect(defaults.canViewFinance, isTrue);
      expect(defaults.canEditTeam, isTrue);
    });

    test('cashier defaults match web', () {
      final defaults = defaultPermissionsForRole('CASHIER');
      expect(defaults.canViewSales, isTrue);
      expect(defaults.canEditSales, isTrue);
      expect(defaults.canViewFinance, isTrue);
      expect(defaults.canEditFinance, isFalse);
    });

    test('view/edit coupling disables edit when view is turned off', () {
      var permissions = defaultPermissionsForRole('MANAGER');
      permissions = setPermission(permissions, 'can_view_sales', false);
      expect(permissions.canViewSales, isFalse);
      expect(permissions.canEditSales, isFalse);
    });
  });

  group('Team contract — navigation permissions', () {
    test('workers without flags cannot open mapped modules', () {
      expect(
        canShowNavigationItem(
          name: 'Sales',
          role: 'WORKER',
          roles: const ['OWNER', 'MANAGER', 'WORKER'],
          permissions: const FarmPermissions(),
        ),
        isFalse,
      );
    });

    test('reports require finance view permission', () {
      expect(
        canShowNavigationItem(
          name: 'Reports',
          role: 'ACCOUNTANT',
          roles: const ['OWNER', 'MANAGER', 'ACCOUNTANT'],
          permissions: const FarmPermissions(
            canViewFinance: true,
            canEditFinance: false,
          ),
        ),
        isTrue,
      );
    });

    test('managers bypass navigation permission checks', () {
      expect(
        canShowNavigationItem(
          name: 'Team',
          role: 'MANAGER',
          roles: const ['OWNER', 'MANAGER'],
          permissions: null,
        ),
        isTrue,
      );
    });
  });
}

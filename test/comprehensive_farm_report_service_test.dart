import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/permissions/farm_permissions.dart';
import 'package:hatchlog_m/core/permissions/navigation_permissions.dart';

void main() {
  group('Comprehensive report contract', () {
    test('reports require finance view permission', () {
      expect(
        canShowNavigationItem(
          name: 'Reports',
          role: 'ACCOUNTANT',
          roles: const ['OWNER', 'MANAGER', 'ACCOUNTANT'],
          permissions: const FarmPermissions(canViewFinance: true),
        ),
        isTrue,
      );
      expect(
        canShowNavigationItem(
          name: 'Reports',
          role: 'WORKER',
          roles: const ['OWNER', 'MANAGER', 'WORKER'],
          permissions: const FarmPermissions(),
        ),
        isFalse,
      );
    });

    test('managers bypass report permission checks', () {
      expect(
        canShowNavigationItem(
          name: 'Reports',
          role: 'MANAGER',
          roles: const ['OWNER', 'MANAGER'],
          permissions: null,
        ),
        isTrue,
      );
    });
  });
}

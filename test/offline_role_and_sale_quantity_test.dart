import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/core/models/app_user.dart';
import 'package:hatchlog_m/core/permissions/navigation_permissions.dart';
import 'package:hatchlog_m/features/sales/sale_line_draft.dart';
import 'package:hatchlog_m/utils/sale_quantity_utils.dart';

void main() {
  group('Offline effective farm role', () {
    test('worker membership overrides poisoned owner profile role', () {
      final effectiveRole = resolveEffectiveFarmRole(
        farmOwnerId: 'owner-1',
        userId: 'worker-1',
        membershipRole: UserRole.worker,
      );

      expect(effectiveRole, UserRole.worker);

      final restoredUser = const AppUser(
        id: 'worker-1',
        phoneNumber: '+233200000001',
        role: UserRole.owner,
        activeFarmId: 'farm-1',
      ).copyWith(role: effectiveRole);

      expect(restoredUser.role, UserRole.worker);
    });
  });

  group('Sale crate conversion', () {
    test('SaleLineDraft converts crates to eggs for FIFO payload', () {
      const draft = SaleLineDraft(
        productType: SaleProductType.inventory,
        description: 'Large eggs',
        quantity: 2,
        unitPrice: 45,
        inventoryId: 'inv-1',
        eggQuantityUnit: EggSaleQuantityUnit.crate,
        eggsPerCrate: 30,
      );

      expect(draft.resolvedQuantityEggs, 60);
      expect(draft.resolvedUnitPricePerEgg, 1.5);
      expect(draft.lineTotal, 90);

      final payload = draft.toPayloadMap();
      expect(payload['quantity'], 60);
      expect(payload['unit_price'], 1.5);
    });

    test('saleQuantityInEggs handles individual egg quantity', () {
      expect(
        saleQuantityInEggs(
          displayQuantity: 15,
          unit: EggSaleQuantityUnit.egg,
          eggsPerCrate: 30,
        ),
        15,
      );
    });

    test('line discount reduces line total before order discount', () {
      const draft = SaleLineDraft(
        productType: SaleProductType.livestock,
        description: 'Broilers',
        quantity: 10,
        unitPrice: 25,
        livestockId: 'batch-1',
        lineDiscountAmount: 20,
      );

      expect(draft.lineSubtotal, 250);
      expect(draft.lineDiscountValue, 20);
      expect(draft.lineTotal, 230);
    });
  });
}

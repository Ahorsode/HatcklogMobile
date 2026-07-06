import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/features/inventory/data/inventory_repository.dart';

void main() {
  group('inventory repository contract', () {
    test('InventoryFilter exposes active and usedUp modes', () {
      expect(InventoryFilter.values, contains(InventoryFilter.active));
      expect(InventoryFilter.values, contains(InventoryFilter.usedUp));
    });

    test('InventoryUsageEvent carries source and amount fields', () {
      final event = InventoryUsageEvent(
        date: DateTime(2026, 1, 1),
        batchName: 'Batch A',
        amount: 2,
        source: 'vaccination',
      );
      expect(event.source, 'vaccination');
      expect(event.amount, 2);
    });
  });
}

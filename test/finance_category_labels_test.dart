import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/services/finance_category_labels.dart';

void main() {
  group('finance_category_labels', () {
    test('maps expense enum to hub label', () {
      expect(expenseCategoryLabel('FEED'), 'Feed Purchases');
      expect(expenseCategoryLabel('MEDICATION'), 'Flock Vaccines & Medication');
      expect(expenseCategoryLabel('LIVESTOCK_PURCHASE'), 'Day-Old Chicks Purchase');
    });

    test('round-trips known labels to enum', () {
      expect(expenseEnumFromLabel('Feed Purchases'), 'FEED');
      expect(expenseEnumFromLabel('Labor & Salaries'), 'SALARY');
    });
  });
}

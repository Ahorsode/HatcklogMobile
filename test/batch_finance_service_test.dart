import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/services/batch_finance_service.dart';

void main() {
  group('BatchFinanceBreakdown', () {
    test('computes total expense and net profit across layers', () {
      const breakdown = BatchFinanceBreakdown(
        batchId: 'batch-1',
        batchLabel: 'Broiler A',
        initial: 1000,
        operating: 200,
        consumption: 150,
        general: 50,
        revenue: 1800,
      );

      expect(breakdown.totalExpense, 1400);
      expect(breakdown.netProfit, 400);
    });
  });
}

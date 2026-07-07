import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/features/sales/sale_line_draft.dart';
import 'package:hatchlog_m/utils/sale_payment_utils.dart';

double _roundMoney(double value) => (value * 100).roundToDouble() / 100;

String _paymentStatus({
  required double computedTotal,
  required double cashReceived,
}) {
  final outstanding = _roundMoney(
    (computedTotal - cashReceived).clamp(0, double.infinity),
  );
  final isPaid = outstanding <= 0.01;
  return isPaid
      ? 'PAID'
      : (cashReceived > 0 ? 'PARTIALLY_PAID' : 'UNPAID');
}

void main() {
  group('Sales data contract', () {
    test('SaleLineDraft payload includes livestock and inventory ids', () {
      const draft = SaleLineDraft(
        productType: SaleProductType.livestock,
        description: 'Broiler Batch A',
        quantity: 10,
        unitPrice: 25,
        livestockId: 'batch-1',
      );

      final payload = draft.toPayloadMap();
      expect(payload['livestock_id'], 'batch-1');
      expect(payload['product_type'], 'livestock');
      expect(payload['total_price'], 250);
    });

    test('partial payment status matches web createOrder contract', () {
      expect(
        _paymentStatus(computedTotal: 100, cashReceived: 80),
        'PARTIALLY_PAID',
      );
      expect(
        _paymentStatus(computedTotal: 100, cashReceived: 100),
        'PAID',
      );
      expect(
        _paymentStatus(computedTotal: 100, cashReceived: 0),
        'UNPAID',
      );
    });

    test('MoMo and credit payment validation', () {
      expect(
        validateSalePaymentFields(
          paymentMethod: SalePaymentMethod.mobileMoney,
        ),
        contains('MoMo phone number is required'),
      );
      expect(
        validateSalePaymentFields(
          paymentMethod: SalePaymentMethod.credit,
        ),
        contains('Credit sales require a saved customer'),
      );
      expect(
        validateSalePaymentFields(
          paymentMethod: SalePaymentMethod.cash,
        ),
        isEmpty,
      );
    });
  });
}

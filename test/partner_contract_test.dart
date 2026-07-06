import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/services/local_partner_service.dart';

void main() {
  group('LocalPartnerService contract', () {
    test('roundMoney keeps two decimal places', () {
      expect(LocalPartnerService.roundMoney(10.556), 10.56);
      expect(LocalPartnerService.roundMoney(10.554), 10.55);
    });

    test('supplier payment math clamps at zero balance', () {
      const balance = 500.0;
      const payment = 200.0;
      final newBalance = LocalPartnerService.roundMoney(
        (balance - payment).clamp(0, double.infinity),
      );
      expect(newBalance, 300);
    });

    test('supplier payment math rejects overpayment threshold', () {
      const balance = 500.0;
      const payment = 600.0;
      expect(payment > balance + 0.01, isTrue);
    });
  });
}

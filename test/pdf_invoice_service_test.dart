import 'package:flutter_test/flutter_test.dart';
import 'package:hatchlog_m/services/pdf_invoice_service.dart';

void main() {
  group('PdfInvoiceService', () {
    test('buildInvoiceBytes accepts multi-line sale payload totals', () async {
      final bytes = await PdfInvoiceService().buildInvoiceBytes(
        sale: {
          'total_cash_received': 740,
          'customer_name': 'Walk-in Customer',
          'payment_method': 'CASH',
          'device_timestamp': DateTime.utc(2026, 7, 7, 12).toIso8601String(),
          'items': [
            {
              'description': 'Large Eggs',
              'quantity': 600,
              'total_price': 740,
            },
          ],
        },
        invoiceNumber: 'INV-TEST',
        taxRate: 0,
        paid: true,
      );

      expect(bytes, isNotEmpty);
    });
  });
}

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

class PdfInvoiceService {
  Future<Uint8List> buildInvoiceBytes({
    required Map<String, dynamic> sale,
    required String invoiceNumber,
    required double taxRate,
    required bool paid,
  }) async {
    final pdf = pw.Document();

    final total = _readMoney(
      sale,
      const [
        'total_cash_received',
        'amount_received',
        'computed_total',
        'total_amount',
        'total',
      ],
    );
    final tax = total * taxRate;
    final net = total - tax;
    final items = sale['items'];
    final customerName =
        sale['customer_name']?.toString().trim().isNotEmpty == true
        ? sale['customer_name'].toString()
        : 'Walk-in Customer';
    final timestamp = sale['device_timestamp'] ?? sale['order_date'];
    final paymentMethod = sale['payment_method']?.toString() ?? 'CASH';

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.roll80, // phone-friendly
        build: (context) {
          return pw.Container(
            padding: const pw.EdgeInsets.all(16),
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'HatchLog',
                  style: pw.TextStyle(
                    fontSize: 22,
                    fontWeight: pw.FontWeight.bold,
                  ),
                ),
                pw.SizedBox(height: 8),
                pw.Text('Invoice: $invoiceNumber'),
                if (timestamp != null)
                  pw.Text(
                    'Date: ${DateTime.tryParse(timestamp.toString())?.toLocal() ?? timestamp}',
                  ),
                pw.Text('Customer: $customerName'),
                pw.Divider(),
                if (items is List && items.isNotEmpty) ...[
                  for (final raw in items)
                    if (raw is Map) ...[
                      pw.Text(
                        '${raw['quantity']} x ${raw['description'] ?? 'Sale item'}',
                      ),
                      pw.Text(
                        'Line total: ${_readMoney(Map<String, dynamic>.from(raw), const ['total_price']).toStringAsFixed(2)}',
                      ),
                      pw.SizedBox(height: 6),
                    ],
                ] else ...[
                  pw.Text(
                    'Quantity: ${sale['quantity_crates'] ?? sale['quantity'] ?? '-'} ${sale['unit'] ?? ''}',
                  ),
                ],
                pw.Text('Payment: $paymentMethod'),
                pw.SizedBox(height: 12),
                pw.Row(
                  children: [
                    pw.Expanded(child: pw.Text('Subtotal')),
                    pw.Text(net.toStringAsFixed(2)),
                  ],
                ),
                pw.Row(
                  children: [
                    pw.Expanded(child: pw.Text('Tax')),
                    pw.Text(tax.toStringAsFixed(2)),
                  ],
                ),
                pw.Divider(),
                pw.Row(
                  children: [
                    pw.Expanded(
                      child: pw.Text(
                        'Total',
                        style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                      ),
                    ),
                    pw.Text(
                      total.toStringAsFixed(2),
                      style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                    ),
                  ],
                ),
                pw.SizedBox(height: 24),
                pw.Align(
                  alignment: pw.Alignment.center,
                  child: pw.Opacity(
                    opacity: 0.15,
                    child: pw.Text(
                      paid ? 'PAID' : 'PENDING',
                      style: pw.TextStyle(
                        fontSize: 60,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );

    return pdf.save();
  }

  double _readMoney(Map<String, dynamic> source, List<String> keys) {
    for (final key in keys) {
      final value = source[key];
      if (value == null) {
        continue;
      }
      if (value is num) {
        return value.toDouble();
      }
      final parsed = double.tryParse(value.toString());
      if (parsed != null) {
        return parsed;
      }
    }
    return 0;
  }

  Future<String> savePdfToTemp(Uint8List data, String filename) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/$filename');
    await file.writeAsBytes(data, flush: true);
    return file.path;
  }

  Future<void> sharePdfToWhatsApp({
    required String filePath,
    String text = '',
  }) async {
    final xfile = XFile(filePath, mimeType: 'application/pdf');
    await SharePlus.instance.share(ShareParams(files: [xfile], text: text));
  }
}

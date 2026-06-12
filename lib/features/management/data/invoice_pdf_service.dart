import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import 'management_models.dart';

class InvoicePdfService {
  Future<Uint8List> buildInvoice(InvoiceRecord record) async {
    final pdf = pw.Document();
    final draft = record.draft;

    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        build: (context) {
          return pw.Stack(
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Row(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            'HatchLog',
                            style: pw.TextStyle(
                              fontSize: 28,
                              fontWeight: pw.FontWeight.bold,
                              color: PdfColor.fromHex('#145F3B'),
                            ),
                          ),
                          pw.SizedBox(height: 4),
                          pw.Text('Poultry management invoice'),
                          pw.Text('Generated from HatchLog Mobile'),
                        ],
                      ),
                      pw.Container(
                        padding: const pw.EdgeInsets.all(12),
                        decoration: pw.BoxDecoration(
                          border: pw.Border.all(color: PdfColors.grey300),
                          borderRadius: pw.BorderRadius.circular(6),
                        ),
                        child: pw.Column(
                          crossAxisAlignment: pw.CrossAxisAlignment.end,
                          children: [
                            pw.Text(
                              'INVOICE',
                              style: pw.TextStyle(
                                fontSize: 18,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                            pw.Text(record.invoiceNumber),
                            pw.Text(_date(record.createdAt)),
                          ],
                        ),
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 34),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      _infoBlock('Bill To', [
                        draft.customerName,
                        draft.customerType,
                      ]),
                      _infoBlock('Payment', [
                        draft.paymentMethod,
                        draft.isPaid ? 'Paid in full' : 'Part payment',
                      ]),
                    ],
                  ),
                  pw.SizedBox(height: 28),
                  pw.Table(
                    border: pw.TableBorder.all(color: PdfColors.grey300),
                    children: [
                      pw.TableRow(
                        decoration: pw.BoxDecoration(
                          color: PdfColor.fromHex('#F3F6F4'),
                        ),
                        children: [
                          _cell('Item', bold: true),
                          _cell('Qty', bold: true),
                          _cell('Unit Price', bold: true),
                          _cell('Total', bold: true),
                        ],
                      ),
                      pw.TableRow(
                        children: [
                          _cell(draft.item),
                          _cell('${draft.quantity}'),
                          _cell(_money(draft.unitPrice)),
                          _cell(_money(draft.subtotal)),
                        ],
                      ),
                    ],
                  ),
                  pw.SizedBox(height: 18),
                  pw.Align(
                    alignment: pw.Alignment.centerRight,
                    child: pw.Container(
                      width: 220,
                      child: pw.Column(
                        children: [
                          _totalRow('Subtotal', draft.subtotal),
                          _totalRow('Discount', -draft.discount),
                          _totalRow('Tax', draft.taxAmount),
                          pw.Divider(),
                          _totalRow('Total', draft.total, bold: true),
                          _totalRow('Received', draft.amountReceived),
                        ],
                      ),
                    ),
                  ),
                  pw.Spacer(),
                  pw.Container(
                    width: double.infinity,
                    padding: const pw.EdgeInsets.all(12),
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#F8F9FA'),
                      borderRadius: pw.BorderRadius.circular(6),
                    ),
                    child: pw.Text(
                      'Thank you for doing business with HatchLog. This receipt was generated on a mobile device and queued for cloud sync if connectivity was unavailable.',
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ),
                ],
              ),
              if (draft.isPaid)
                pw.Positioned(
                  top: 280,
                  left: 95,
                  child: pw.Transform.rotate(
                    angle: -0.55,
                    child: pw.Opacity(
                      opacity: 0.12,
                      child: pw.Text(
                        'PAID',
                        style: pw.TextStyle(
                          fontSize: 92,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#145F3B'),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  Future<void> shareInvoice(InvoiceRecord record) async {
    final bytes = await buildInvoice(record);
    await Printing.sharePdf(
      bytes: bytes,
      filename: '${record.invoiceNumber}.pdf',
      subject: 'HatchLog invoice ${record.invoiceNumber}',
      body: 'Invoice ${record.invoiceNumber} from HatchLog.',
    );
  }

  pw.Widget _infoBlock(String title, List<String> lines) {
    return pw.Container(
      width: 220,
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#46516A'),
            ),
          ),
          pw.SizedBox(height: 6),
          for (final line in lines.where((line) => line.trim().isNotEmpty))
            pw.Text(line),
        ],
      ),
    );
  }

  pw.Widget _cell(String value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(9),
      child: pw.Text(
        value,
        style: pw.TextStyle(
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
      ),
    );
  }

  pw.Widget _totalRow(String label, double value, {bool bold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
          pw.Text(
            _money(value),
            style: pw.TextStyle(
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  String _money(double value) {
    return 'GHS ${value.toStringAsFixed(2)}';
  }

  String _date(DateTime value) {
    return '${value.year}-${_two(value.month)}-${_two(value.day)}';
  }

  String _two(int value) => value.toString().padLeft(2, '0');
}

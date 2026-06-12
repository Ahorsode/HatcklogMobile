import 'package:flutter/material.dart';

import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';

class SaleEntryScreen extends StatefulWidget {
  const SaleEntryScreen({
    super.key,
    required this.queue,
    required this.pdfService,
    required this.currentUserId,
    required this.currentFarmId,
  });

  final LocalSalesQueue queue;
  final PdfInvoiceService pdfService;
  final String currentUserId;
  final String currentFarmId;

  @override
  State<SaleEntryScreen> createState() => _SaleEntryScreenState();
}

class _SaleEntryScreenState extends State<SaleEntryScreen> {
  final _qtyController = TextEditingController(text: '0');
  final _amountController = TextEditingController(text: '0.00');
  bool _busy = false;

  @override
  void dispose() {
    _qtyController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final qty = int.tryParse(_qtyController.text) ?? 0;
    final amount = double.tryParse(_amountController.text) ?? 0.0;
    if (qty <= 0 || amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter quantity and amount.')),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final id = await widget.queue.enqueueSale(
        userId: widget.currentUserId,
        farmId: widget.currentFarmId,
        quantityCrates: qty,
        amountReceived: amount,
        unit: 'CRATE',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Sale recorded locally.')));

      // Generate a quick invoice and offer to share
      final pending = {
        'quantity_crates': qty,
        'amount_received': amount,
        'unit': 'CRATE',
        'payment_method': 'CASH',
        'device_timestamp': DateTime.now().toUtc().toIso8601String(),
      };

      final bytes = await widget.pdfService.buildInvoiceBytes(
        sale: pending,
        invoiceNumber: 'INV-${DateTime.now().millisecondsSinceEpoch}',
        taxRate: 0.0,
        paid: true,
      );

      final path = await widget.pdfService.savePdfToTemp(
        bytes,
        'invoice_$id.pdf',
      );

      // Show share button
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        builder: (_) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.send_outlined),
                title: const Text('Send Invoice via WhatsApp'),
                onTap: () async {
                  Navigator.of(context).pop();
                  await widget.pdfService.sharePdfToWhatsApp(
                    filePath: path,
                    text: 'Invoice for your purchase',
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.close),
                title: const Text('Close'),
                onTap: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Farm-Gate Sale')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            TextField(
              controller: _qtyController,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: 'Quantity Sold (Crates/Birds)',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _amountController,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
              decoration: const InputDecoration(
                labelText: 'Cash/Mobile Money Received (₵)',
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _busy ? null : _submit,
              icon: const Icon(Icons.check),
              label: _busy
                  ? const Text('Working...')
                  : const Text('Record Sale & Send Invoice'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Workers cannot edit prices or discounts.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}

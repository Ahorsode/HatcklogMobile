import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../features/livestock/data/livestock_models.dart';
import '../../../features/livestock/services/livestock_service.dart';

class FinancialSetupSheet extends StatefulWidget {
  const FinancialSetupSheet({
    super.key,
    required this.batchName,
    required this.quantity,
    required this.onSubmit,
  });

  final String batchName;
  final int quantity;
  final Future<LivestockOperationResult> Function(BatchFinancialDraft draft)
      onSubmit;

  @override
  State<FinancialSetupSheet> createState() => _FinancialSetupSheetState();
}

class _FinancialSetupSheetState extends State<FinancialSetupSheet> {
  final _costPerUnitController = TextEditingController(text: '0');
  final _carriageController = TextEditingController(text: '0');
  final List<_OtherExpenseRow> _otherRows = [];
  var _saving = false;

  double get _costPerUnit =>
      double.tryParse(_costPerUnitController.text.trim()) ?? 0;

  double get _carriage =>
      double.tryParse(_carriageController.text.trim()) ?? 0;

  double get _totalActual => _costPerUnit * widget.quantity;

  @override
  void dispose() {
    _costPerUnitController.dispose();
    _carriageController.dispose();
    for (final row in _otherRows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _submit({required bool skip}) async {
    if (skip) {
      Navigator.of(context).pop(const LivestockOperationResult(success: true));
      return;
    }
    setState(() => _saving = true);
    try {
      final draft = BatchFinancialDraft(
        costPerUnit: _costPerUnit,
        carriageCost: _carriage,
        otherExpenses: [
          for (final row in _otherRows)
            if (row.labelController.text.trim().isNotEmpty &&
                (double.tryParse(row.amountController.text.trim()) ?? 0) > 0)
              (
                label: row.labelController.text.trim(),
                amount: double.tryParse(row.amountController.text.trim()) ?? 0,
              ),
        ],
      );
      final result = await widget.onSubmit(draft);
      if (!mounted) {
        return;
      }
      if (result.success) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Failed to save financials')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Financial setup: ${widget.batchName}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            Text('Quantity: ${widget.quantity} birds'),
            const SizedBox(height: 12),
            TextFormField(
              controller: _costPerUnitController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Cost per bird (GHS)',
                prefixIcon: Icon(Icons.payments_outlined),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Text(
              'Total purchase cost: GHS ${_totalActual.toStringAsFixed(2)}',
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _carriageController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                labelText: 'Carriage inward (GHS)',
                prefixIcon: Icon(Icons.local_shipping_outlined),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Other initial costs',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => setState(
                    () => _otherRows.add(_OtherExpenseRow()),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add'),
                ),
              ],
            ),
            for (final row in _otherRows) ...[
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: row.labelController,
                      decoration: const InputDecoration(labelText: 'Label'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: row.amountController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Amount'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _saving ? null : () => _submit(skip: false),
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save financial setup'),
            ),
            TextButton(
              onPressed: _saving ? null : () => _submit(skip: true),
              child: const Text('Skip for now'),
            ),
          ],
        ),
      ),
    );
  }
}

class _OtherExpenseRow {
  _OtherExpenseRow()
      : labelController = TextEditingController(),
        amountController = TextEditingController();

  final TextEditingController labelController;
  final TextEditingController amountController;

  void dispose() {
    labelController.dispose();
    amountController.dispose();
  }
}

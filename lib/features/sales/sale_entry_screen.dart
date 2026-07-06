import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../../utils/inventory_sale_utils.dart';
import 'sale_line_draft.dart';

enum _DiscountMode { flat, percentage }

class _ProductOption {
  const _ProductOption({
    required this.id,
    required this.label,
    required this.description,
    required this.unitPrice,
    required this.available,
    required this.productType,
  });

  final String id;
  final String label;
  final String description;
  final double unitPrice;
  final double available;
  final SaleProductType productType;
}

class _SaleLineState {
  SaleProductType productType = SaleProductType.inventory;
  String? productId;
  String description = '';
  final TextEditingController quantityController = TextEditingController(
    text: '1',
  );
  final TextEditingController unitPriceController = TextEditingController();
  final TextEditingController customDescriptionController =
      TextEditingController();
  String? stockError;

  void dispose() {
    quantityController.dispose();
    unitPriceController.dispose();
    customDescriptionController.dispose();
  }
}

class SaleEntryScreen extends StatefulWidget {
  const SaleEntryScreen({
    super.key,
    required this.queue,
    required this.pdfService,
    required this.currentUser,
    required this.localDatabase,
    this.canOverridePrices = false,
  });

  final LocalSalesQueue queue;
  final PdfInvoiceService pdfService;
  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final bool canOverridePrices;

  @override
  State<SaleEntryScreen> createState() => _SaleEntryScreenState();
}

class _SaleEntryScreenState extends State<SaleEntryScreen> {
  final _cashReceivedController = TextEditingController();
  final _discountController = TextEditingController(text: '0');

  String? _customerId;
  DateTime _orderDate = DateTime.now();
  _DiscountMode _discountMode = _DiscountMode.flat;
  bool _busy = false;
  bool _loading = true;
  String? _submitError;

  List<Map<String, Object?>> _customers = const [];
  List<_ProductOption> _inventoryOptions = const [];
  List<_ProductOption> _livestockOptions = const [];
  bool _inventoryIsEggCatalog = false;
  final List<_SaleLineState> _lines = [_SaleLineState()];

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _cashReceivedController.dispose();
    _discountController.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final farmId = widget.currentUser.activeFarmId;
      final customers = await widget.localDatabase.queryLocalRecords(
        'customers',
        where: 'farm_id = ? and coalesce(is_active, 1) = 1',
        whereArgs: [farmId],
        orderBy: 'name asc',
      );
      final inventoryRows = await widget.localDatabase.queryLocalRecords(
        'inventory',
        where:
            'farm_id = ? and coalesce(is_deleted, 0) = 0 and coalesce(stock_level, 0) > 0',
        whereArgs: [farmId],
        orderBy: 'item_name asc',
      );
      final saleInventoryRows = inventoryRowsForSale(inventoryRows);
      final batchRows = await widget.localDatabase.queryLocalRecords(
        'batches',
        where:
            'farm_id = ? and coalesce(is_deleted, 0) = 0 and current_count > 0',
        whereArgs: [farmId],
        orderBy: 'batch_name asc',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _customers = customers;
        _inventoryIsEggCatalog = inventoryCatalogIsEggFocused(saleInventoryRows);
        _inventoryOptions = saleInventoryRows
            .map(
              (row) {
                final sellingPrice = _asDouble(row['selling_price']);
                final costPerUnit = _asDouble(row['cost_per_unit']);
                final label = formatSaleInventoryLabel(row);
                return _ProductOption(
                  id: _text(row['id']),
                  label: label,
                  description: label,
                  unitPrice: sellingPrice > 0 ? sellingPrice : costPerUnit,
                  available: inventoryStockLevel(row['stock_level']),
                  productType: SaleProductType.inventory,
                );
              },
            )
            .where((option) => option.id.isNotEmpty)
            .toList(growable: false);
        _livestockOptions = batchRows
            .map(
              (row) {
                final initialCost = _asDouble(row['initial_actual_cost']);
                final initialCount = _asInt(row['initial_count'], fallback: 1);
                final basePrice = initialCount > 0
                    ? initialCost / initialCount
                    : 0.0;
                return _ProductOption(
                  id: _text(row['id']),
                  label: _text(row['batch_name'], 'Batch'),
                  description: _text(row['batch_name'], 'Livestock batch'),
                  unitPrice: basePrice,
                  available: _asDouble(row['current_count']),
                  productType: SaleProductType.livestock,
                );
              },
            )
            .where((option) => option.id.isNotEmpty)
            .toList(growable: false);
        _loading = false;
        for (final line in _lines) {
          _autoSelectProduct(line);
        }
      });
      _syncLockedCashTotal();
    } on StateError {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  List<_ProductOption> _optionsFor(SaleProductType type) {
    return switch (type) {
      SaleProductType.inventory => _inventoryOptions,
      SaleProductType.livestock => _livestockOptions,
      SaleProductType.custom => const [],
    };
  }

  bool _shouldHideProductPicker(_SaleLineState line) {
    if (line.productType == SaleProductType.custom) {
      return false;
    }
    final options = _optionsFor(line.productType);
    if (options.isEmpty) {
      return false;
    }
    if (options.length == 1) {
      return true;
    }
    if (line.productType == SaleProductType.inventory && _inventoryIsEggCatalog) {
      return true;
    }
    return false;
  }

  void _autoSelectProduct(_SaleLineState line) {
    if (line.productType == SaleProductType.custom) {
      return;
    }
    final options = _optionsFor(line.productType);
    if (options.isEmpty) {
      line.productId = null;
      line.description = '';
      line.unitPriceController.clear();
      return;
    }
    final shouldAutoSelect = options.length == 1 ||
        (line.productType == SaleProductType.inventory && _inventoryIsEggCatalog);
    if (!shouldAutoSelect) {
      return;
    }
    final selected = options.first;
    line.productId = selected.id;
    line.description = selected.description;
    line.unitPriceController.text = selected.unitPrice.toStringAsFixed(2);
    line.stockError = null;
  }

  _ProductOption? _selectedProduct(_SaleLineState line) {
    final options = _optionsFor(line.productType);
    for (final option in options) {
      if (option.id == line.productId) {
        return option;
      }
    }
    return null;
  }

  String? _stockErrorFor(_SaleLineState line, _ProductOption product) {
    final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
    if (quantity <= 0) {
      return null;
    }
    if (quantity > product.available.floor()) {
      return '${product.label} only has ${product.available.floor()} available';
    }
    return null;
  }

  void _onFieldChanged([VoidCallback? extra]) {
    setState(() {
      extra?.call();
      for (final line in _lines) {
        final product = _selectedProduct(line);
        if (product != null) {
          line.stockError = _stockErrorFor(line, product);
        }
      }
      _submitError = null;
      _syncLockedCashTotal();
    });
  }

  double get _subtotal {
    var total = 0.0;
    for (final line in _lines) {
      final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
      final unitPrice = double.tryParse(line.unitPriceController.text.trim()) ?? 0;
      total += quantity * unitPrice;
    }
    return total;
  }

  double get _discountAmount {
    final raw = double.tryParse(_discountController.text.trim()) ?? 0;
    if (_discountMode == _DiscountMode.percentage) {
      return (_subtotal * raw / 100).clamp(0, _subtotal);
    }
    return raw.clamp(0, _subtotal);
  }

  double get _computedTotal =>
      (_subtotal - _discountAmount).clamp(0, double.infinity);

  bool get _canSubmit {
    if (_busy || _loading) {
      return false;
    }
    if (_lines.isEmpty) {
      return false;
    }
    for (final line in _lines) {
      final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
      final unitPrice = double.tryParse(line.unitPriceController.text.trim());
      if (quantity <= 0 || unitPrice == null || unitPrice < 0) {
        return false;
      }
      if (line.productType == SaleProductType.custom) {
        if (!widget.canOverridePrices ||
            line.customDescriptionController.text.trim().isEmpty) {
          return false;
        }
      } else if (line.productId == null || line.productId!.isEmpty) {
        return false;
      }
      final product = _selectedProduct(line);
      if (product != null &&
          quantity > product.available.floor()) {
        return false;
      }
      if (_stockErrorFor(line, product ?? _placeholderProduct(line)) != null) {
        return false;
      }
    }
    final cash = double.tryParse(_cashReceivedController.text.trim()) ?? 0;
    if (cash < 0) {
      return false;
    }
    if (widget.canOverridePrices) {
      return cash >= 0 && _computedTotal > 0;
    }
    if (cash <= 0) {
      return false;
    }
    if ((cash - _computedTotal).abs() > 0.01) {
      return false;
    }
    return true;
  }

  _ProductOption _placeholderProduct(_SaleLineState line) {
    return _ProductOption(
      id: line.productId ?? '',
      label: line.description,
      description: line.description,
      unitPrice: 0,
      available: 0,
      productType: line.productType,
    );
  }

  void _syncLockedCashTotal() {
    if (widget.canOverridePrices) {
      return;
    }
    _cashReceivedController.text = _computedTotal.toStringAsFixed(2);
  }

  List<SaleLineDraft> _buildDrafts() {
    return _lines.map((line) {
      final quantity = int.parse(line.quantityController.text.trim());
      final unitPrice = double.parse(line.unitPriceController.text.trim());
      final description = line.productType == SaleProductType.custom
          ? line.customDescriptionController.text.trim()
          : line.description;
      return SaleLineDraft(
        productType: line.productType,
        description: description,
        quantity: quantity,
        unitPrice: unitPrice,
        inventoryId: line.productType == SaleProductType.inventory
            ? line.productId
            : null,
        livestockId: line.productType == SaleProductType.livestock
            ? line.productId
            : null,
      );
    }).toList(growable: false);
  }

  Future<void> _submit() async {
    if (!_canSubmit) {
      setState(() {
        _submitError = widget.canOverridePrices
            ? 'Complete every line item before saving.'
            : 'Cash received must equal the locked sale total';
      });
      return;
    }

    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      final customerName = _customerId == null
          ? 'Walk-in Customer'
          : _customers
                .firstWhere(
                  (row) => _text(row['id']) == _customerId,
                  orElse: () => const {},
                )['name']
                ?.toString();
      final cashReceived =
          double.parse(_cashReceivedController.text.trim());
      final id = await widget.queue.enqueueMultiLineSale(
        userId: widget.currentUser.id,
        farmId: widget.currentUser.activeFarmId,
        items: _buildDrafts(),
        orderDate: _orderDate,
        totalCashReceived: cashReceived,
        customerId: _customerId,
        customerName: customerName,
        discountAmount: widget.canOverridePrices ? _discountAmount : 0,
        requireExactCashTotal: !widget.canOverridePrices,
      );

      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Sale recorded locally.')),
      );

      final pending = {
        'total_cash_received': cashReceived,
        'customer_name': customerName ?? 'Walk-in Customer',
        'payment_method': 'CASH',
        'device_timestamp': _orderDate.toUtc().toIso8601String(),
        'items': _buildDrafts().map((item) => item.toPayloadMap()).toList(),
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
      if (!mounted) {
        return;
      }
      await showModalBottomSheet<void>(
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
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      if (mounted) {
        setState(() => _submitError = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
    }
  }

  Future<void> _pickOrderDate() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _orderDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_orderDate),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _orderDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Record Sale')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: _customerId,
                  decoration: const InputDecoration(
                    labelText: 'Customer',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('Walk-in Customer'),
                    ),
                    for (final row in _customers)
                      DropdownMenuItem<String?>(
                        value: _text(row['id']),
                        child: Text(_text(row['name'], 'Customer')),
                      ),
                  ],
                  onChanged: (value) => setState(() => _customerId = value),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Sale Date & Time'),
                  subtitle: Text(_formatDateTime(_orderDate)),
                  trailing: IconButton(
                    icon: const Icon(Icons.event_outlined),
                    onPressed: _pickOrderDate,
                  ),
                ),
                const SizedBox(height: 8),
                for (var index = 0; index < _lines.length; index += 1)
                  _LineCard(
                    key: ValueKey('sale-line-$index'),
                    line: _lines[index],
                    index: index,
                    canOverridePrices: widget.canOverridePrices,
                    inventoryTypeLabel:
                        _inventoryIsEggCatalog ? 'Eggs' : 'Inventory',
                    options: _optionsFor(_lines[index].productType),
                    hideProductPicker: _shouldHideProductPicker(_lines[index]),
                    onProductTypeChanged: (type) {
                      setState(() {
                        final line = _lines[index];
                        line.productType = type;
                        line.productId = null;
                        line.customDescriptionController.clear();
                        line.unitPriceController.clear();
                        line.description = '';
                        line.stockError = null;
                        _autoSelectProduct(line);
                        _syncLockedCashTotal();
                      });
                    },
                    onChanged: _onFieldChanged,
                    onRemove: _lines.length == 1
                        ? null
                        : () {
                            setState(() {
                              _lines[index].dispose();
                              _lines.removeAt(index);
                              _syncLockedCashTotal();
                            });
                          },
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      final line = _SaleLineState();
                      _lines.add(line);
                      _autoSelectProduct(line);
                      _syncLockedCashTotal();
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Item'),
                ),
                if (widget.canOverridePrices) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Discount',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<_DiscountMode>(
                    segments: const [
                      ButtonSegment(
                        value: _DiscountMode.flat,
                        label: Text('Flat'),
                      ),
                      ButtonSegment(
                        value: _DiscountMode.percentage,
                        label: Text('Percentage'),
                      ),
                    ],
                    selected: {_discountMode},
                    onSelectionChanged: (selection) {
                      _onFieldChanged(() => _discountMode = selection.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _discountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: _discountMode == _DiscountMode.percentage
                          ? 'Discount (%)'
                          : 'Discount (GHS)',
                    ),
                    onChanged: (_) => _onFieldChanged(),
                  ),
                ],
                const SizedBox(height: 16),
                _SummaryRow(label: 'Subtotal', value: _money(_subtotal)),
                if (widget.canOverridePrices && _discountAmount > 0)
                  _SummaryRow(
                    label: 'Discount',
                    value: '- ${_money(_discountAmount)}',
                  ),
                _SummaryRow(
                  label: 'Sale Total',
                  value: _money(_computedTotal),
                  emphasized: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _cashReceivedController,
                  readOnly: !widget.canOverridePrices,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Total Cash Received (GHS)',
                    errorText: !widget.canOverridePrices &&
                            ((double.tryParse(
                                      _cashReceivedController.text.trim(),
                                    ) ??
                                    0) -
                                    _computedTotal)
                                .abs() >
                            0.01
                        ? 'Cash received must equal the locked sale total'
                        : null,
                  ),
                  onChanged: widget.canOverridePrices
                      ? (_) => _onFieldChanged()
                      : null,
                ),
                if (!widget.canOverridePrices)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Workers cannot edit prices or discounts.',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                if (_submitError != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _submitError!,
                    style: const TextStyle(
                      color: Color(0xffb83b3b),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: FilledButton.icon(
            onPressed: _canSubmit && !_busy ? _submit : null,
            icon: _busy
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check),
            label: Text(_busy ? 'Saving...' : 'Record Sale'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
            ),
          ),
        ),
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    super.key,
    required this.line,
    required this.index,
    required this.canOverridePrices,
    required this.inventoryTypeLabel,
    required this.options,
    required this.hideProductPicker,
    required this.onProductTypeChanged,
    required this.onChanged,
    this.onRemove,
  });

  final _SaleLineState line;
  final int index;
  final bool canOverridePrices;
  final String inventoryTypeLabel;
  final List<_ProductOption> options;
  final bool hideProductPicker;
  final ValueChanged<SaleProductType> onProductTypeChanged;
  final ValueChanged<VoidCallback?> onChanged;
  final VoidCallback? onRemove;

  _ProductOption? get _selectedOption {
    for (final option in options) {
      if (option.id == line.productId) {
        return option;
      }
    }
    return options.isNotEmpty ? options.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final selected = _selectedOption;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Item ${index + 1}',
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                const Spacer(),
                IconButton(
                  tooltip: 'Remove item',
                  onPressed: onRemove,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            SegmentedButton<SaleProductType>(
              segments: [
                ButtonSegment(
                  value: SaleProductType.inventory,
                  label: Text(inventoryTypeLabel),
                ),
                const ButtonSegment(
                  value: SaleProductType.livestock,
                  label: Text('Livestock'),
                ),
                if (canOverridePrices)
                  const ButtonSegment(
                    value: SaleProductType.custom,
                    label: Text('Custom'),
                  ),
              ],
              selected: {line.productType},
              onSelectionChanged: (selection) {
                onProductTypeChanged(selection.first);
              },
            ),
            const SizedBox(height: 12),
            if (line.productType == SaleProductType.custom) ...[
              TextField(
                controller: line.customDescriptionController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  prefixIcon: Icon(Icons.edit_outlined),
                ),
                onChanged: (_) => onChanged(null),
              ),
            ] else if (hideProductPicker && selected != null)
              InputDecorator(
                decoration: InputDecoration(
                  labelText: line.productType == SaleProductType.inventory
                      ? inventoryTypeLabel
                      : 'Livestock Batch',
                ),
                child: Text(
                  selected.label,
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              )
            else
              DropdownButtonFormField<String?>(
                initialValue: line.productId,
                decoration: InputDecoration(
                  labelText: line.productType == SaleProductType.inventory
                      ? '$inventoryTypeLabel Product'
                      : 'Livestock Batch',
                ),
                items: [
                  for (final option in options)
                    DropdownMenuItem<String?>(
                      value: option.id,
                      child: Text(option.label),
                    ),
                ],
                onChanged: (value) {
                  onChanged(() {
                    line.productId = value;
                    final selected = options
                        .where((option) => option.id == value)
                        .firstOrNull;
                    if (selected != null) {
                      line.description = selected.description;
                      line.unitPriceController.text = selected.unitPrice
                          .toStringAsFixed(2);
                      line.stockError = null;
                    }
                  });
                },
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.quantityController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Quantity',
                      errorText: line.stockError,
                    ),
                    onChanged: (_) => onChanged(null),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: line.unitPriceController,
                    readOnly: !canOverridePrices,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Unit Price',
                    ),
                    onChanged: canOverridePrices ? (_) => onChanged(null) : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final style = emphasized
        ? Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w900,
          )
        : Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

String _formatDateTime(DateTime value) {
  final month = value.month.toString().padLeft(2, '0');
  final day = value.day.toString().padLeft(2, '0');
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '${value.year}-$month-$day $hour:$minute';
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

double _asDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

int _asInt(Object? value, {int fallback = 0}) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? fallback;
}

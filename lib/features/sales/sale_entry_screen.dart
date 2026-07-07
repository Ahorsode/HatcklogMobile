import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../services/farm_settings_service.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../../utils/inventory_sale_utils.dart';
import '../../features/inventory/data/inventory_repository.dart';
import '../../utils/egg_sale_allocation_utils.dart';
import '../../utils/egg_log_utils.dart';
import '../../utils/sale_quantity_utils.dart';
import '../../utils/sale_payment_utils.dart';
import '../../presentation/sales/egg_size_picker_dialog.dart';
import '../../presentation/sales/quick_add_customer_sheet.dart';
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
  EggAllocationMode eggAllocationMode = EggAllocationMode.fifo;
  String? eggBatchId;
  final TextEditingController quantityController = TextEditingController(
    text: '1',
  );
  final TextEditingController unitPriceController = TextEditingController();
  final TextEditingController customDescriptionController =
      TextEditingController();
  EggSaleQuantityUnit eggQuantityUnit = EggSaleQuantityUnit.crate;
  _DiscountMode lineDiscountMode = _DiscountMode.flat;
  final TextEditingController lineDiscountController = TextEditingController(
    text: '0',
  );
  String? stockError;

  void dispose() {
    quantityController.dispose();
    unitPriceController.dispose();
    customDescriptionController.dispose();
    lineDiscountController.dispose();
  }
}

class SaleEntryScreen extends StatefulWidget {
  const SaleEntryScreen({
    super.key,
    required this.queue,
    required this.pdfService,
    required this.currentUser,
    required this.localDatabase,
    this.permissions,
    this.canOverridePrices = false,
  });

  final LocalSalesQueue queue;
  final PdfInvoiceService pdfService;
  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final FarmPermissions? permissions;
  final bool canOverridePrices;

  @override
  State<SaleEntryScreen> createState() => _SaleEntryScreenState();
}

class _SaleEntryScreenState extends State<SaleEntryScreen> {
  final _cashReceivedController = TextEditingController();
  final _discountController = TextEditingController(text: '0');
  final _paymentReferenceController = TextEditingController();
  final _paymentAccountNameController = TextEditingController();

  String? _customerId;
  DateTime _orderDate = DateTime.now();
  _DiscountMode _discountMode = _DiscountMode.flat;
  SalePaymentMethod _paymentMethod = SalePaymentMethod.cash;
  int _step = 1;
  bool _busy = false;
  bool _loading = true;
  String? _submitError;

  List<Map<String, Object?>> _customers = const [];
  List<_ProductOption> _inventoryOptions = const [];
  List<_ProductOption> _livestockOptions = const [];
  List<Map<String, Object?>> _eggInventoryRows = const [];
  List<EggBatchStockOption> _eggBatchOptions = const [];
  int _fifoTotalEggs = 0;
  Map<String, Map<String, Object?>> _eggCategoriesById = const {};
  final List<_SaleLineState> _lines = [_SaleLineState()];
  int _eggsPerCrate = defaultEggsPerCrate;

  bool get _canOverridePrices =>
      widget.permissions?.canEditSales ?? widget.canOverridePrices;

  bool get _canAddCustomer =>
      _canOverridePrices ||
      (widget.permissions?.canViewSales ?? false) ||
      (widget.permissions?.canEditSales ?? false);

  bool get _isWalkIn => _customerId == null;

  bool get _isCreditSale => _paymentMethod == SalePaymentMethod.credit;

  bool get _cashFieldEditable => _canOverridePrices || _isCreditSale;

  @override
  void initState() {
    super.initState();
    _loadCatalog();
  }

  @override
  void dispose() {
    _cashReceivedController.dispose();
    _discountController.dispose();
    _paymentReferenceController.dispose();
    _paymentAccountNameController.dispose();
    for (final line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _loadCatalog() async {
    try {
      final farmId = widget.currentUser.activeFarmId;
      final settings = await FarmSettingsService(widget.localDatabase).load(
        farmId,
      );
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
      final eggCategoryRows = await widget.localDatabase.queryLocalRecords(
        'egg_categories',
        where: 'farm_id = ?',
        whereArgs: [farmId],
      );
      final eggCategoriesById = {
        for (final row in eggCategoryRows)
          if ((row['id']?.toString().trim() ?? '').isNotEmpty)
            row['id']!.toString(): row,
      };
      final saleInventoryRows = sellableEggInventoryRows(inventoryRows);
      final eggStock = await InventoryRepository(
        widget.localDatabase,
      ).getActiveBatchEggStock(farmId);
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
        _eggsPerCrate = settings.eggsPerCrate;
        _customers = customers;
        _eggInventoryRows = saleInventoryRows;
        _eggCategoriesById = eggCategoriesById;
        _eggBatchOptions = eggStock.batches
            .map(
              (row) => EggBatchStockOption(
                batchId: row.batchId,
                batchName: row.batchName,
                eggsRemaining: row.eggsRemaining,
              ),
            )
            .toList(growable: false);
        _fifoTotalEggs = eggStock.totalEggs;
        _inventoryOptions = saleInventoryRows
            .map(
              (row) {
                final unitPrice = saleUnitPriceForDisplay(
                  catalogPricePerCrate: inventorySalePrice(
                    row,
                    eggCategoriesById: eggCategoriesById,
                  ),
                  unit: EggSaleQuantityUnit.crate,
                  eggsPerCrate: settings.eggsPerCrate,
                );
                final stockEggs = inventoryStockLevel(row['stock_level']).floor();
                final label =
                    '${formatSaleInventoryLabel(row)} (${formatEggStockCrateLabel(stockEggs, eggsPerCrate: settings.eggsPerCrate)})';
                return _ProductOption(
                  id: _text(row['id']),
                  label: label,
                  description: label,
                  unitPrice: unitPrice,
                  available: stockEggs.toDouble(),
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
      _syncCashReceived();
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
    if (line.productType == SaleProductType.inventory) {
      return false;
    }
    if (line.productType == SaleProductType.custom) {
      return false;
    }
    final options = _optionsFor(line.productType);
    if (options.isEmpty) {
      return false;
    }
    return options.length == 1;
  }

  void _setEggProductFromRow(_SaleLineState line, Map<String, Object?> row) {
    line.productId = _text(row['id']);
    line.description = formatSaleInventoryLabel(row);
    line.unitPriceController.text = saleUnitPriceForDisplay(
      catalogPricePerCrate: inventorySalePrice(
        row,
        eggCategoriesById: _eggCategoriesById,
      ),
      unit: line.eggQuantityUnit,
      eggsPerCrate: _eggsPerCrate,
    ).toStringAsFixed(2);
    line.stockError = null;
  }

  void _applyDefaultEggProduct(_SaleLineState line) {
    if (_eggInventoryRows.isEmpty) {
      line.productId = null;
      line.description = '';
      line.unitPriceController.clear();
      return;
    }
    if (!requiresEggSizeSelection(_eggInventoryRows)) {
      final row = defaultEggInventoryRow(_eggInventoryRows);
      if (row != null) {
        _setEggProductFromRow(line, row);
      }
      return;
    }
    line.productId = null;
    line.description = 'Eggs';
    line.unitPriceController.clear();
  }

  int _eggAvailableForLine(_SaleLineState line) {
    if (line.eggAllocationMode == EggAllocationMode.batch) {
      if (line.eggBatchId == null || line.eggBatchId!.isEmpty) {
        return 0;
      }
      for (final batch in _eggBatchOptions) {
        if (batch.batchId == line.eggBatchId) {
          return batch.eggsRemaining;
        }
      }
      return 0;
    }
    return _fifoTotalEggs;
  }

  bool get _needsCompletionPrompt {
    final cash = double.tryParse(_cashReceivedController.text.trim()) ?? 0;
    return _isCreditSale || (_computedTotal - cash).abs() > 0.01;
  }

  Future<void> _pickEggSizeForLine(int index) async {
    final line = _lines[index];
    final selected = await showEggSizePickerDialog(
      context: context,
      eggInventoryRows: _eggInventoryRows,
    );
    if (selected == null || !mounted) {
      return;
    }
    setState(() {
      _setEggProductFromRow(line, selected);
      final product = _selectedProduct(line);
      if (product != null) {
        line.stockError = _stockErrorFor(line, product);
      }
      _syncCashReceived();
    });
  }

  void _autoSelectProduct(_SaleLineState line) {
    if (line.productType == SaleProductType.custom) {
      return;
    }
    if (line.productType == SaleProductType.inventory) {
      line.eggAllocationMode = EggAllocationMode.fifo;
      line.eggBatchId = null;
      _applyDefaultEggProduct(line);
      return;
    }
    final options = _optionsFor(line.productType);
    if (options.isEmpty) {
      line.productId = null;
      line.description = '';
      line.unitPriceController.clear();
      return;
    }
    if (options.length != 1) {
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
    if (line.productType == SaleProductType.inventory) {
      if (line.eggAllocationMode == EggAllocationMode.batch &&
          (line.eggBatchId == null || line.eggBatchId!.isEmpty)) {
        return 'Select a batch';
      }
      final quantityEggs = saleQuantityInEggs(
        displayQuantity: quantity,
        unit: line.eggQuantityUnit,
        eggsPerCrate: _eggsPerCrate,
      );
      final available = _eggAvailableForLine(line);
      if (quantityEggs > available) {
        return line.eggAllocationMode == EggAllocationMode.batch
            ? 'Selected batch only has ${formatEggStockCrateLabel(available, eggsPerCrate: _eggsPerCrate)} available'
            : '${product.label} only has ${formatEggStockCrateLabel(available, eggsPerCrate: _eggsPerCrate)} available';
      }
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
      _syncCashReceived();
    });
  }

  double _lineSubtotalFor(_SaleLineState line) {
    final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
    final unitPrice =
        double.tryParse(line.unitPriceController.text.trim()) ?? 0;
    return quantity * unitPrice;
  }

  double _lineDiscountFor(_SaleLineState line) {
    final raw = double.tryParse(line.lineDiscountController.text.trim()) ?? 0;
    final subtotal = _lineSubtotalFor(line);
    if (line.lineDiscountMode == _DiscountMode.percentage) {
      return (subtotal * raw / 100).clamp(0, subtotal);
    }
    return raw.clamp(0, subtotal);
  }

  double _lineTotalFor(_SaleLineState line) =>
      (_lineSubtotalFor(line) - _lineDiscountFor(line)).clamp(0, double.infinity);

  double get _subtotal {
    var total = 0.0;
    for (final line in _lines) {
      total += _lineTotalFor(line);
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
        if (!_canOverridePrices ||
            line.customDescriptionController.text.trim().isEmpty) {
          return false;
        }
      } else if (line.productId == null || line.productId!.isEmpty) {
        return false;
      }
      if (line.productType == SaleProductType.inventory &&
          line.eggAllocationMode == EggAllocationMode.batch &&
          (line.eggBatchId == null || line.eggBatchId!.isEmpty)) {
        return false;
      }
      final product = _selectedProduct(line);
      if (product != null && line.productType != SaleProductType.inventory) {
        if (quantity > product.available.floor()) {
          return false;
        }
      }
      if (line.productType == SaleProductType.inventory) {
        final quantityEggs = saleQuantityInEggs(
          displayQuantity: quantity,
          unit: line.eggQuantityUnit,
          eggsPerCrate: _eggsPerCrate,
        );
        if (quantityEggs > _eggAvailableForLine(line)) {
          return false;
        }
      }
      if (_stockErrorFor(line, product ?? _placeholderProduct(line)) != null) {
        return false;
      }
    }
    final cash = double.tryParse(_cashReceivedController.text.trim()) ?? 0;
    if (cash < 0) {
      return false;
    }
    if (_computedTotal <= 0) {
      return false;
    }
    if (_isWalkIn) {
      return cash >= 0;
    }
    if (_canOverridePrices || _isCreditSale) {
      return cash >= 0;
    }
    if (cash <= 0) {
      return false;
    }
    return (cash - _computedTotal).abs() <= 0.01;
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

  void _syncCashReceived() {
    if (!_isWalkIn && _canOverridePrices && !_isCreditSale) {
      return;
    }
    if (_isCreditSale) {
      return;
    }
    _cashReceivedController.text = _computedTotal.toStringAsFixed(2);
  }

  bool get _canContinueStep1 {
    if (_busy || _loading || _lines.isEmpty) {
      return false;
    }
    return !_canSubmitStep1Blocked;
  }

  bool get _canSubmitStep1Blocked {
    for (final line in _lines) {
      final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
      final unitPrice = double.tryParse(line.unitPriceController.text.trim());
      if (quantity <= 0 || unitPrice == null || unitPrice < 0) {
        return true;
      }
      if (line.productType == SaleProductType.custom) {
        if (!_canOverridePrices ||
            line.customDescriptionController.text.trim().isEmpty) {
          return true;
        }
      } else if (line.productId == null || line.productId!.isEmpty) {
        return true;
      }
      if (line.productType == SaleProductType.inventory &&
          line.eggAllocationMode == EggAllocationMode.batch &&
          (line.eggBatchId == null || line.eggBatchId!.isEmpty)) {
        return true;
      }
      final product = _selectedProduct(line);
      if (product != null && line.productType != SaleProductType.inventory) {
        if (quantity > product.available.floor()) {
          return true;
        }
      }
      if (line.productType == SaleProductType.inventory) {
        final quantityEggs = saleQuantityInEggs(
          displayQuantity: quantity,
          unit: line.eggQuantityUnit,
          eggsPerCrate: _eggsPerCrate,
        );
        if (quantityEggs > _eggAvailableForLine(line)) {
          return true;
        }
      }
      if (_stockErrorFor(line, product ?? _placeholderProduct(line)) != null) {
        return true;
      }
    }
    return _computedTotal <= 0;
  }

  bool get _canSubmitStep2 {
    if (!_canSubmit) {
      return false;
    }
    final paymentErrors = validateSalePaymentFields(
      paymentMethod: _paymentMethod,
      paymentReference: _paymentReferenceController.text,
      paymentAccountName: _paymentAccountNameController.text,
      customerId: _customerId,
    );
    return paymentErrors.isEmpty;
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
        eggAllocationMode: line.productType == SaleProductType.inventory
            ? line.eggAllocationMode.name
            : null,
        eggBatchId: line.productType == SaleProductType.inventory &&
                line.eggAllocationMode == EggAllocationMode.batch
            ? line.eggBatchId
            : null,
        eggQuantityUnit: line.eggQuantityUnit,
        lineDiscountAmount:
            double.tryParse(line.lineDiscountController.text.trim()) ?? 0,
        lineDiscountType: line.lineDiscountMode == _DiscountMode.percentage
            ? 'percent'
            : 'flat',
        eggsPerCrate: _eggsPerCrate,
      );
    }).toList(growable: false);
  }

  Future<void> _submit({bool? completeNow}) async {
    if (!_canSubmitStep2) {
      setState(() {
        _submitError = _canOverridePrices
            ? 'Complete every line item before saving.'
            : 'Cash received must equal the locked sale total';
      });
      return;
    }

    if (completeNow == null && _needsCompletionPrompt) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Complete this sale now?'),
          content: const Text(
            'This credit or partial-payment sale can be completed now to deduct stock, or saved to complete later.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Skip for now'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Complete sale now'),
            ),
          ],
        ),
      );
      if (choice == null || !mounted) {
        return;
      }
      return _submit(completeNow: choice);
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
        discountAmount: _canOverridePrices ? _discountAmount : 0,
        paymentMethod: _paymentMethod.apiValue,
        paymentReference: _paymentReferenceController.text.trim().isEmpty
            ? null
            : _paymentReferenceController.text.trim(),
        paymentAccountName: _paymentAccountNameController.text.trim().isEmpty
            ? null
            : _paymentAccountNameController.text.trim(),
        requireExactCashTotal:
            !_isWalkIn && !_canOverridePrices && !_isCreditSale,
        completeNow: completeNow,
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
        'payment_method': _paymentMethod.apiValue,
        'payment_reference': _paymentReferenceController.text.trim(),
        'payment_account_name': _paymentAccountNameController.text.trim(),
        'device_timestamp': _orderDate.toUtc().toIso8601String(),
        'items': _buildDrafts().map((item) => item.toPayloadMap()).toList(),
      };
      try {
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
      } on Object catch (invoiceError) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Sale saved, but invoice preview failed: $invoiceError',
              ),
            ),
          );
        }
      }
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
                Row(
                  children: [
                    Expanded(
                      child: _WizardStepChip(
                        label: '1. Customer & Products',
                        active: _step == 1,
                        completed: _step > 1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _WizardStepChip(
                        label: '2. Payment',
                        active: _step == 2,
                        completed: false,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                if (_step == 1) ...[
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
                  onChanged: (value) => setState(() {
                    _customerId = value;
                    _syncCashReceived();
                  }),
                ),
                if (_canAddCustomer) ...[
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () async {
                        final created = await QuickAddCustomerSheet.show(
                          context,
                          localDatabase: widget.localDatabase,
                          currentUser: widget.currentUser,
                        );
                        if (created == null || !mounted) {
                          return;
                        }
                        setState(() {
                          _customers = [..._customers, created];
                          _customerId = created['id']?.toString();
                          _syncCashReceived();
                        });
                      },
                      icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
                      label: const Text('Add new customer'),
                    ),
                  ),
                ],
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
                    canOverridePrices: _canOverridePrices,
                    eggsPerCrate: _eggsPerCrate,
                    inventoryTypeLabel: 'Eggs',
                    options: _optionsFor(_lines[index].productType),
                    hideProductPicker: _shouldHideProductPicker(_lines[index]),
                    inventoryEmpty: _lines[index].productType ==
                            SaleProductType.inventory &&
                        _inventoryOptions.isEmpty,
                    eggBatchOptions: _eggBatchOptions,
                    requiresEggSizeSelection:
                        requiresEggSizeSelection(_eggInventoryRows),
                    onPickEggSize: () => _pickEggSizeForLine(index),
                    onProductTypeChanged: (type) {
                      setState(() {
                        final line = _lines[index];
                        line.productType = type;
                        line.productId = null;
                        line.eggAllocationMode = EggAllocationMode.fifo;
                        line.eggBatchId = null;
                        line.customDescriptionController.clear();
                        line.unitPriceController.clear();
                        line.description = '';
                        line.stockError = null;
                        _autoSelectProduct(line);
                        _syncCashReceived();
                      });
                    },
                    onChanged: _onFieldChanged,
                    onRemove: _lines.length == 1
                        ? null
                        : () {
                            setState(() {
                              _lines[index].dispose();
                              _lines.removeAt(index);
                              _syncCashReceived();
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
                      _syncCashReceived();
                    });
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('Add Item'),
                ),
                const SizedBox(height: 16),
                _SummaryRow(label: 'Line Subtotal', value: _money(_subtotal)),
                if (_canSubmitStep1Blocked) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Complete every line item before continuing.',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
                ] else ...[
                if (_canOverridePrices) ...[
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
                DropdownButtonFormField<SalePaymentMethod>(
                  value: _paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'Payment Method',
                    prefixIcon: Icon(Icons.payments_outlined),
                  ),
                  items: SalePaymentMethod.values
                      .map(
                        (method) => DropdownMenuItem(
                          value: method,
                          child: Text(method.label),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    _onFieldChanged(() {
                      _paymentMethod = value;
                      _syncCashReceived();
                    });
                  },
                ),
                if (_paymentMethod == SalePaymentMethod.mobileMoney) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _paymentReferenceController,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'MoMo Phone Number',
                    ),
                    onChanged: (_) => _onFieldChanged(),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _paymentAccountNameController,
                    decoration: const InputDecoration(
                      labelText: 'Account Holder Name',
                    ),
                    onChanged: (_) => _onFieldChanged(),
                  ),
                ] else if (_paymentMethod == SalePaymentMethod.bankTransfer) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _paymentReferenceController,
                    decoration: const InputDecoration(
                      labelText: 'Bank Reference (optional)',
                    ),
                    onChanged: (_) => _onFieldChanged(),
                  ),
                ],
                const SizedBox(height: 16),
                _SummaryRow(label: 'Subtotal', value: _money(_subtotal)),
                if (_canOverridePrices && _discountAmount > 0)
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
                  readOnly: !_cashFieldEditable,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Total Cash Received (GHS)',
                    errorText: !_isWalkIn &&
                            !_canOverridePrices &&
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
                  onChanged: _cashFieldEditable ? (_) => _onFieldChanged() : null,
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _isCreditSale
                        ? 'Credit sale: partial or zero payment allowed for saved customers.'
                        : _isWalkIn
                        ? 'Walk-in sale: cash is locked to the sale total'
                        : _canOverridePrices
                            ? 'Credit sale: cash can differ from total for named customers.'
                            : 'Workers cannot edit prices or discounts for named customers.',
                    style: const TextStyle(color: Colors.grey),
                  ),
                ),
                ],
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
          child: _step == 1
              ? FilledButton.icon(
                  onPressed: _canContinueStep1 && !_busy
                      ? () => setState(() => _step = 2)
                      : null,
                  icon: const Icon(Icons.arrow_forward),
                  label: const Text('Continue'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                )
              : Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => setState(() => _step = 1),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back'),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _canSubmitStep2 && !_busy ? _submit : null,
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
                  ],
                ),
        ),
      ),
    );
  }
}

class _WizardStepChip extends StatelessWidget {
  const _WizardStepChip({
    required this.label,
    required this.active,
    required this.completed,
  });

  final String label;
  final bool active;
  final bool completed;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: active
              ? colorScheme.primary
              : completed
                  ? colorScheme.outline
                  : colorScheme.outlineVariant,
        ),
        color: active
            ? colorScheme.primaryContainer.withValues(alpha: 0.35)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: active
              ? colorScheme.primary
              : completed
                  ? colorScheme.onSurface
                  : colorScheme.onSurfaceVariant,
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
    required this.eggsPerCrate,
    required this.inventoryTypeLabel,
    required this.options,
    required this.hideProductPicker,
    required this.inventoryEmpty,
    required this.onProductTypeChanged,
    required this.onChanged,
    this.eggBatchOptions = const [],
    this.requiresEggSizeSelection = false,
    this.onPickEggSize,
    this.onRemove,
  });

  final _SaleLineState line;
  final int index;
  final bool canOverridePrices;
  final int eggsPerCrate;
  final String inventoryTypeLabel;
  final List<_ProductOption> options;
  final bool hideProductPicker;
  final bool inventoryEmpty;
  final List<EggBatchStockOption> eggBatchOptions;
  final bool requiresEggSizeSelection;
  final VoidCallback? onPickEggSize;
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

  double get _lineSubtotal {
    final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
    final unitPrice =
        double.tryParse(line.unitPriceController.text.trim()) ?? 0;
    return quantity * unitPrice;
  }

  double get _lineDiscount {
    final raw = double.tryParse(line.lineDiscountController.text.trim()) ?? 0;
    if (line.lineDiscountMode == _DiscountMode.percentage) {
      return (_lineSubtotal * raw / 100).clamp(0, _lineSubtotal);
    }
    return raw.clamp(0, _lineSubtotal);
  }

  double get _lineTotal =>
      (_lineSubtotal - _lineDiscount).clamp(0, double.infinity);

  void _toggleEggQuantityUnit() {
    final quantity = int.tryParse(line.quantityController.text.trim()) ?? 0;
    final unitPrice =
        double.tryParse(line.unitPriceController.text.trim()) ?? 0;
    if (line.eggQuantityUnit == EggSaleQuantityUnit.crate) {
      line.eggQuantityUnit = EggSaleQuantityUnit.egg;
      line.quantityController.text = quantity > 0
          ? (quantity * eggsPerCrate).toString()
          : line.quantityController.text;
      line.unitPriceController.text = eggsPerCrate > 0
          ? (unitPrice / eggsPerCrate).toStringAsFixed(2)
          : line.unitPriceController.text;
    } else {
      line.eggQuantityUnit = EggSaleQuantityUnit.crate;
      line.quantityController.text = quantity > 0 && eggsPerCrate > 0
          ? (quantity / eggsPerCrate).ceil().toString()
          : line.quantityController.text;
      line.unitPriceController.text =
          (unitPrice * eggsPerCrate).toStringAsFixed(2);
    }
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
            ] else if (line.productType == SaleProductType.inventory &&
                !inventoryEmpty) ...[
              SegmentedButton<EggAllocationMode>(
                segments: const [
                  ButtonSegment(
                    value: EggAllocationMode.fifo,
                    label: Text('FIFO'),
                  ),
                  ButtonSegment(
                    value: EggAllocationMode.batch,
                    label: Text('By Batch'),
                  ),
                ],
                selected: {line.eggAllocationMode},
                onSelectionChanged: (selection) {
                  onChanged(() {
                    line.eggAllocationMode = selection.first;
                    if (selection.first == EggAllocationMode.fifo) {
                      line.eggBatchId = null;
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
              if (line.eggAllocationMode == EggAllocationMode.batch) ...[
                if (eggBatchOptions.isEmpty)
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Batch',
                    ),
                    child: Text(
                      'No active layer batches with eggs in stock',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else
                  DropdownButtonFormField<String?>(
                    initialValue: line.eggBatchId,
                    decoration: const InputDecoration(
                      labelText: 'Batch',
                      prefixIcon: Icon(Icons.layers_outlined),
                    ),
                    items: [
                      for (final batch in eggBatchOptions)
                        DropdownMenuItem<String?>(
                          value: batch.batchId,
                          child: Text(
                            '${batch.batchName} (${formatEggStockCrateLabel(batch.eggsRemaining, eggsPerCrate: eggsPerCrate)})',
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      onChanged(() {
                        line.eggBatchId = value;
                        line.stockError = null;
                      });
                    },
                  ),
                const SizedBox(height: 12),
              ],
              if (requiresEggSizeSelection)
                OutlinedButton.icon(
                  onPressed: onPickEggSize,
                  icon: const Icon(Icons.egg_outlined),
                  label: Text(
                    selected == null
                        ? 'Select egg size'
                        : 'Size: ${selected.label}',
                  ),
                )
              else if (selected != null)
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: inventoryTypeLabel,
                  ),
                  child: Text(
                    selected.label,
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
            ] else if (inventoryEmpty &&
                line.productType == SaleProductType.inventory)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Eggs Product',
                ),
                child: Text(
                  'No eggs in stock — log egg production first',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              )
            else if (hideProductPicker && selected != null)
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
            if (line.productType == SaleProductType.inventory) ...[
              SegmentedButton<EggSaleQuantityUnit>(
                segments: const [
                  ButtonSegment(
                    value: EggSaleQuantityUnit.crate,
                    label: Text('Crates'),
                  ),
                  ButtonSegment(
                    value: EggSaleQuantityUnit.egg,
                    label: Text('Eggs'),
                  ),
                ],
                selected: {line.eggQuantityUnit},
                onSelectionChanged: (selection) {
                  onChanged(() {
                    if (selection.first != line.eggQuantityUnit) {
                      _toggleEggQuantityUnit();
                    }
                  });
                },
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.quantityController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: line.productType == SaleProductType.inventory
                          ? line.eggQuantityUnit == EggSaleQuantityUnit.crate
                              ? 'Crates'
                              : 'Eggs'
                          : 'Quantity',
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
                    decoration: InputDecoration(
                      labelText: line.productType == SaleProductType.inventory
                          ? line.eggQuantityUnit == EggSaleQuantityUnit.crate
                              ? 'Price / crate'
                              : 'Price / egg'
                          : 'Unit Price',
                    ),
                    onChanged: canOverridePrices ? (_) => onChanged(null) : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: line.lineDiscountController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: line.lineDiscountMode == _DiscountMode.percentage
                          ? 'Line discount %'
                          : 'Line discount (GHS)',
                    ),
                    onChanged: (_) => onChanged(null),
                  ),
                ),
                const SizedBox(width: 8),
                SegmentedButton<_DiscountMode>(
                  segments: const [
                    ButtonSegment(
                      value: _DiscountMode.flat,
                      label: Text('GHS'),
                    ),
                    ButtonSegment(
                      value: _DiscountMode.percentage,
                      label: Text('%'),
                    ),
                  ],
                  selected: {line.lineDiscountMode},
                  onSelectionChanged: (selection) {
                    onChanged(() {
                      line.lineDiscountMode = selection.first;
                    });
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Line subtotal: ${_money(_lineSubtotal)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  'Line total: ${_money(_lineTotal)}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w800,
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

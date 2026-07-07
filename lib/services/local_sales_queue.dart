import '../core/storage/local_database.dart';
import '../features/sales/sale_line_draft.dart';
import 'egg_fifo_service.dart';
import 'encryption_service.dart';

class LocalSalesQueue {
  LocalSalesQueue({
    required this.localDatabase,
    required this.encryptionService,
    required this.deviceId,
  });

  final LocalDatabase localDatabase;
  final EncryptionService encryptionService;
  final String deviceId;

  static double _roundMoney(double value) =>
      (value * 100).roundToDouble() / 100;

  /// Creates a pending sale entry which will be synced when online.
  /// Validates chronological order to detect local clock tampering.
  Future<int> enqueueSale({
    required String userId,
    required String farmId,
    required int quantityCrates,
    required double amountReceived,
    required String unit, // 'CRATE' or 'BIRD'
    String paymentMethod = 'CASH',
  }) async {
    if (quantityCrates <= 0) {
      throw ArgumentError.value(
        quantityCrates,
        'quantityCrates',
        'Quantity must be greater than zero.',
      );
    }
    if (amountReceived <= 0) {
      throw ArgumentError.value(
        amountReceived,
        'amountReceived',
        'Amount received must be greater than zero.',
      );
    }

    final deviceTimestamp = DateTime.now().toUtc();
    await _assertChronologicalOrder(userId, deviceTimestamp);

    final payload = {
      'type': 'farm_gate_sale',
      'quantity_crates': quantityCrates,
      'amount_received': amountReceived,
      'unit': unit,
      'payment_method': paymentMethod,
    };

    final txHash = encryptionService.transactionHash(payload, deviceId);

    final pending = PendingSyncInput(
      userId: userId,
      inputType: 'farm_gate_sale',
      payload: {
        ...payload,
        'farm_id': farmId,
        'transaction_hash': txHash,
        'device_timestamp': deviceTimestamp.toIso8601String(),
        'is_synced': false,
      },
      createdAt: deviceTimestamp,
      isSynced: false,
    );

    final queueId = await localDatabase.insertPendingInput(pending);
    final saleId = pending.resolvedServerRecordId;
    await localDatabase.insertLocalRecord('sales', {
      'id': saleId,
      'local_queue_id': queueId,
      'customer_name': 'Farm Gate Customer',
      'total_amount': amountReceived,
      'amount_received': amountReceived,
      'deposit_amount': amountReceived,
      'outstanding_credit': 0,
      'payment_method': paymentMethod,
      'receipt_number': txHash,
      'sale_date': deviceTimestamp.toIso8601String(),
      'status': 'completed',
      'user_id': userId,
      'farm_id': farmId,
      'is_deleted': 0,
      'created_at': deviceTimestamp.toIso8601String(),
      'updated_at': deviceTimestamp.toIso8601String(),
    });
    await localDatabase.insertLocalRecord('sale_items', {
      'id': '${saleId}_item_0',
      'sale_id': saleId,
      'description': 'Farm-gate sale ($unit)',
      'quantity': quantityCrates,
      'unit_price': amountReceived / quantityCrates,
      'total_price': amountReceived,
      'farm_id': farmId,
    });
    await localDatabase.insertLocalRecord('financial_transactions', {
      'id': '${saleId}_transaction',
      'farm_id': farmId,
      'user_id': userId,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': amountReceived,
      'payment_status': 'PAID',
      'payment_method': paymentMethod,
      'reference_num': txHash,
      'transaction_date': deviceTimestamp.toIso8601String(),
      'description': '$quantityCrates $unit farm-gate sale',
      'deposit_amount': amountReceived,
      'outstanding_credit': 0,
      'expense_outlay': 0,
      'is_deleted': 0,
      'settled_at': deviceTimestamp.toIso8601String(),
      'created_at': deviceTimestamp.toIso8601String(),
      'updated_at': deviceTimestamp.toIso8601String(),
    });
    return queueId;
  }

  /// Records a multi-line sale locally and queues it for cloud sync.
  Future<int> enqueueMultiLineSale({
    required String userId,
    required String farmId,
    required List<SaleLineDraft> items,
    required DateTime orderDate,
    required double totalCashReceived,
    String? customerId,
    String? customerName,
    double discountAmount = 0,
    String paymentMethod = 'CASH',
    bool requireExactCashTotal = true,
  }) async {
    if (items.isEmpty) {
      throw ArgumentError('At least one sale line item is required.');
    }
    for (final item in items) {
      if (item.quantity <= 0) {
        throw ArgumentError.value(
          item.quantity,
          'quantity',
          'Quantity must be greater than zero.',
        );
      }
      if (item.unitPrice < 0) {
        throw ArgumentError.value(
          item.unitPrice,
          'unitPrice',
          'Unit price cannot be negative.',
        );
      }
      if (item.description.trim().isEmpty) {
        throw ArgumentError('Each sale line requires a description.');
      }
    }

    final subtotal = _roundMoney(
      items.fold<double>(0, (sum, item) => sum + item.lineTotal),
    );
    final discount = _roundMoney(discountAmount.clamp(0, subtotal));
    final computedTotal = _roundMoney(
      (subtotal - discount).clamp(0, double.infinity),
    );
    final cashReceived = _roundMoney(totalCashReceived);
    if (cashReceived < 0) {
      throw ArgumentError.value(
        totalCashReceived,
        'totalCashReceived',
        'Total cash received cannot be negative.',
      );
    }
    if (requireExactCashTotal && (cashReceived - computedTotal).abs() > 0.01) {
      throw ArgumentError(
        'Cash received must equal the locked sale total.',
      );
    }
    if (!requireExactCashTotal && cashReceived <= 0 && computedTotal > 0) {
      throw ArgumentError.value(
        totalCashReceived,
        'totalCashReceived',
        'Total cash received must be greater than zero.',
      );
    }
    final outstanding = _roundMoney(
      (computedTotal - cashReceived).clamp(0, double.infinity),
    );
    final isPaid = outstanding <= 0.01;
    final paymentStatus = isPaid
        ? 'PAID'
        : (cashReceived > 0 ? 'PARTIALLY_PAID' : 'UNPAID');

    final deviceTimestamp = orderDate.toUtc();
    await _assertChronologicalOrder(userId, deviceTimestamp);

    final linePayloads = items.map((item) => item.toPayloadMap()).toList();
    final payload = {
      'type': 'multi_line_sale',
      'farm_id': farmId,
      'customer_id': customerId,
      'customer_name': customerName ?? 'Walk-in Customer',
      'discount_amount': discount,
      'subtotal_amount': subtotal,
      'total_cash_received': cashReceived,
      'computed_total': computedTotal,
      'outstanding_credit': outstanding,
      'order_date': deviceTimestamp.toIso8601String(),
      'payment_method': paymentMethod,
      'items': linePayloads,
    };

    final txHash = encryptionService.transactionHash(payload, deviceId);
    final pending = PendingSyncInput(
      userId: userId,
      inputType: 'farm_gate_sale',
      payload: {
        ...payload,
        'transaction_hash': txHash,
        'device_timestamp': deviceTimestamp.toIso8601String(),
        'is_synced': false,
      },
      createdAt: deviceTimestamp,
      isSynced: false,
    );

    final queueId = await localDatabase.insertPendingInput(pending);
    final saleId = pending.resolvedServerRecordId;
    final resolvedCustomerName =
        (customerName == null || customerName.trim().isEmpty)
        ? 'Walk-in Customer'
        : customerName.trim();

    await localDatabase.insertLocalRecord('sales', {
      'id': saleId,
      'local_queue_id': queueId,
      'customer_id': customerId,
      'customer_name': resolvedCustomerName,
      'total_amount': computedTotal,
      'amount_received': cashReceived,
      'deposit_amount': cashReceived,
      'outstanding_credit': outstanding,
      'payment_method': paymentMethod,
      'receipt_number': txHash,
      'sale_date': deviceTimestamp.toIso8601String(),
      'status': isPaid ? 'completed' : 'pending',
      'user_id': userId,
      'farm_id': farmId,
      'is_deleted': 0,
      'created_at': deviceTimestamp.toIso8601String(),
      'updated_at': deviceTimestamp.toIso8601String(),
    });

    for (var index = 0; index < items.length; index += 1) {
      final item = items[index];
      await localDatabase.insertLocalRecord('sale_items', {
        'id': '${saleId}_item_$index',
        'sale_id': saleId,
        'description': item.description,
        'quantity': item.quantity,
        'unit_price': item.unitPrice,
        'total_price': item.lineTotal,
        'farm_id': farmId,
        if (item.inventoryId != null && item.inventoryId!.isNotEmpty)
          'inventory_id': item.inventoryId,
        if (item.livestockId != null && item.livestockId!.isNotEmpty)
          'livestock_id': item.livestockId,
      });
      await EggFifoService(localDatabase).deductForInventorySale(
        farmId: farmId,
        inventoryId: item.inventoryId,
        quantity: item.quantity,
        batchId: item.eggAllocationMode == 'batch' ? item.eggBatchId : null,
      );
    }

    if (customerId != null && customerId.isNotEmpty && outstanding > 0) {
      final customerRows = await localDatabase.queryLocalRecords(
        'customers',
        where: 'id = ? and farm_id = ?',
        whereArgs: [customerId, farmId],
        limit: 1,
      );
      if (customerRows.isNotEmpty) {
        final currentBalance = _asDouble(customerRows.first['balance_owed']);
        await localDatabase.updateLocalRecord(
          'customers',
          {
            'balance_owed': _roundMoney(currentBalance + outstanding),
            'updated_at': deviceTimestamp.toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [customerId],
        );
      }
    }

    final itemSummary = items
        .map((item) => '${item.quantity} x ${item.description}')
        .join(', ');
    await localDatabase.insertLocalRecord('financial_transactions', {
      'id': '${saleId}_transaction',
      'farm_id': farmId,
      'user_id': userId,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': computedTotal,
      'payment_status': paymentStatus,
      'payment_method': paymentMethod,
      'reference_num': txHash,
      'transaction_date': deviceTimestamp.toIso8601String(),
      'description': '$itemSummary to $resolvedCustomerName',
      'customer_id': customerId,
      'deposit_amount': cashReceived,
      'outstanding_credit': outstanding,
      'expense_outlay': 0,
      'is_deleted': 0,
      'settled_at': isPaid ? deviceTimestamp.toIso8601String() : null,
      'created_at': deviceTimestamp.toIso8601String(),
      'updated_at': deviceTimestamp.toIso8601String(),
    });
    return queueId;
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

  Future<void> _assertChronologicalOrder(
    String userId,
    DateTime deviceTimestamp,
  ) async {
    final recent = await localDatabase.readRecentInputsForUser(
      userId: userId,
      since: deviceTimestamp.subtract(const Duration(days: 365)),
      limit: 1,
    );
    if (recent.isEmpty) {
      return;
    }
    final last = recent.first.createdAt;
    if (deviceTimestamp.isBefore(last)) {
      throw StateError(
        'Device clock appears to be earlier than last recorded sale.',
      );
    }
  }
}

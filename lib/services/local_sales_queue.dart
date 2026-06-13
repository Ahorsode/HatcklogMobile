import '../core/storage/local_database.dart';
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

    // Check recent inputs to detect backwards time travel
    final recent = await localDatabase.readRecentInputsForUser(
      userId: userId,
      since: deviceTimestamp.subtract(const Duration(days: 365)),
      limit: 1,
    );

    if (recent.isNotEmpty) {
      final last = recent.first.createdAt;
      if (deviceTimestamp.isBefore(last)) {
        throw StateError(
          'Device clock appears to be earlier than last recorded sale.',
        );
      }
    }

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
}

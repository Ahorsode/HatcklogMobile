import '../../../core/models/app_user.dart';
import '../../../core/storage/local_database.dart';
import '../../auth/data/supabase_remote_api.dart';
import 'management_models.dart';

abstract class ManagementDataSource {
  Future<ManagementSnapshot> loadSnapshot(AppUser user);

  Stream<ManagementSnapshot> watchSnapshot(AppUser user);

  Future<void> logExpense({required AppUser user, required ExpenseDraft draft});

  Future<InvoiceRecord> createInvoice({
    required AppUser user,
    required InvoiceDraft draft,
  });

  Future<void> promoteTeamMember({
    required AppUser owner,
    required TeamMemberRecord member,
    required UserRole targetRole,
  });
}

class ManagementRepository implements ManagementDataSource {
  ManagementRepository({
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
  }) : _localDatabase = localDatabase,
       _remoteApi = remoteApi;

  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;

  static const _snapshotTables = [
    'farms',
    'batches',
    'houses',
    'house_environment_logs',
    'egg_production',
    'daily_feeding_logs',
    'mortality',
    'quarantine',
    'inventory',
    'sales',
    'sale_items',
    'customers',
    'suppliers',
    'expenses',
    'financial_transactions',
    'farm_members',
    'local_users',
    'pending_sync_inputs',
  ];

  @override
  Future<ManagementSnapshot> loadSnapshot(AppUser user) async {
    final farmId = user.activeFarmId;
    final farms = await _loadFarms(user);
    final batches = await _loadBatches(farmId);
    final houseRecords = await _loadHouseRecords(farmId);
    final eggRecords = await _loadEggRecords(farmId);
    final feedingRecords = await _loadFeedingRecords(farmId);
    final mortalityRecords = await _loadMortalityRecords(farmId);
    final quarantineRecords = await _loadQuarantineRecords(farmId);
    final salesRecords = await _loadSalesRecords(farmId);
    final inventoryRecords = await _loadInventoryRecords(farmId);
    final customerRecords = await _loadCustomerRecords(farmId);
    final supplierRecords = await _loadSupplierRecords(farmId);
    final financeRecords = await _loadFinanceRecords(farmId);
    final analytics = await Future.wait(
      batches.map((batch) => _loadBatchAnalytics(batch, farmId)),
    );
    final profitability = await Future.wait(
      batches.map((batch) => _loadProfitability(batch, farmId)),
    );
    final team = await _loadTeamMembers(farmId);
    final pendingCount = await _localDatabase.countPendingInputs();

    return ManagementSnapshot(
      totalRevenue: profitability.fold(0, (sum, item) => sum + item.revenue),
      totalExpenses: profitability.fold(0, (sum, item) => sum + item.expense),
      pendingSyncCount: pendingCount,
      farms: farms,
      batches: batches,
      analytics: analytics,
      profitability: profitability,
      teamMembers: team,
      houseRecords: houseRecords,
      eggRecords: eggRecords,
      feedingRecords: feedingRecords,
      mortalityRecords: mortalityRecords,
      quarantineRecords: quarantineRecords,
      salesRecords: salesRecords,
      inventoryRecords: inventoryRecords,
      customerRecords: customerRecords,
      supplierRecords: supplierRecords,
      financeRecords: financeRecords,
    );
  }

  @override
  Stream<ManagementSnapshot> watchSnapshot(AppUser user) {
    return _localDatabase
        .watchTables(_snapshotTables)
        .asyncMap((_) => loadSnapshot(user));
  }

  @override
  Future<void> logExpense({
    required AppUser user,
    required ExpenseDraft draft,
  }) async {
    final queueId = await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: user.id,
        inputType: 'expense_allocation',
        payload: {
          'farm_id': user.activeFarmId,
          'amount': draft.amount,
          'category': draft.category,
          'description': draft.description,
          'expense_date': draft.expenseDate.toIso8601String(),
          'allocations': draft.allocations
              .map(
                (allocation) => {
                  'batch_id': allocation.batchId,
                  'batch_label': allocation.batchLabel,
                  'percent': allocation.percent,
                  'amount': draft.amount * allocation.percent,
                },
              )
              .toList(),
        },
        createdAt: DateTime.now(),
      ),
    );

    if (draft.allocations.isEmpty) {
      await _localDatabase.insertLocalRecord('expenses', {
        'id': 'local-expense-$queueId',
        'farm_id': user.activeFarmId,
        'user_id': user.id,
        'amount': draft.amount,
        'category': draft.category,
        'description': draft.description,
        'expense_date': draft.expenseDate.toIso8601String(),
        'batch_id': null,
        'is_deleted': 0,
        'updated_at': DateTime.now().toIso8601String(),
      });
      return;
    }

    for (final allocation in draft.allocations) {
      await _localDatabase.insertLocalRecord('expenses', {
        'id': 'local-expense-$queueId-${allocation.batchId}',
        'farm_id': user.activeFarmId,
        'user_id': user.id,
        'amount': draft.amount * allocation.percent,
        'category': draft.category,
        'description':
            '${draft.description} (${(allocation.percent * 100).round()}%)',
        'expense_date': draft.expenseDate.toIso8601String(),
        'batch_id': allocation.batchId,
        'is_deleted': 0,
        'updated_at': DateTime.now().toIso8601String(),
      });
    }
  }

  @override
  Future<InvoiceRecord> createInvoice({
    required AppUser user,
    required InvoiceDraft draft,
  }) async {
    final createdAt = DateTime.now();
    final invoiceNumber = 'HL-${createdAt.millisecondsSinceEpoch}';
    final pending = PendingSyncInput(
      userId: user.id,
      inputType: 'sales_invoice',
      payload: {
        'farm_id': user.activeFarmId,
        'invoice_number': invoiceNumber,
        'customer_name': draft.customerName,
        'customer_type': draft.customerType,
        'item': draft.item,
        'quantity': draft.quantity,
        'unit_price': draft.unitPrice,
        'discount': draft.discount,
        'tax_rate': draft.taxRate,
        'tax_amount': draft.taxAmount,
        'amount_received': draft.amountReceived,
        'payment_method': draft.paymentMethod,
        'total': draft.total,
        'is_paid': draft.isPaid,
      },
      createdAt: createdAt,
    );
    final queueId = await _localDatabase.insertPendingInput(pending);
    final saleId = pending.resolvedServerRecordId;

    await _localDatabase.insertLocalRecord('sales', {
      'id': saleId,
      'local_queue_id': queueId,
      'customer_name': draft.customerName,
      'total_amount': draft.total,
      'amount_received': draft.amountReceived,
      'deposit_amount': draft.amountReceived,
      'outstanding_credit': (draft.total - draft.amountReceived).clamp(
        0,
        double.infinity,
      ),
      'payment_method': draft.paymentMethod,
      'receipt_number': invoiceNumber,
      'sale_date': createdAt.toIso8601String(),
      'status': draft.isPaid ? 'completed' : 'pending',
      'user_id': user.id,
      'farm_id': user.activeFarmId,
      'is_deleted': 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': createdAt.toIso8601String(),
    });

    await _localDatabase.insertLocalRecord('sale_items', {
      'id': '${saleId}_item_0',
      'sale_id': saleId,
      'description': draft.item,
      'quantity': draft.quantity,
      'unit_price': draft.unitPrice,
      'total_price': draft.subtotal,
      'farm_id': user.activeFarmId,
    });

    await _localDatabase.insertLocalRecord('financial_transactions', {
      'id': '${saleId}_transaction',
      'farm_id': user.activeFarmId,
      'user_id': user.id,
      'type': 'REVENUE',
      'category': 'SALES',
      'amount': draft.total,
      'payment_status': draft.isPaid ? 'PAID' : 'PARTIALLY_PAID',
      'payment_method': draft.paymentMethod,
      'reference_num': invoiceNumber,
      'transaction_date': createdAt.toIso8601String(),
      'description':
          '${draft.quantity} x ${draft.item} to ${draft.customerName}',
      'deposit_amount': draft.amountReceived,
      'outstanding_credit': (draft.total - draft.amountReceived).clamp(
        0,
        double.infinity,
      ),
      'expense_outlay': 0,
      'is_deleted': 0,
      'settled_at': draft.isPaid ? createdAt.toIso8601String() : null,
      'created_at': createdAt.toIso8601String(),
      'updated_at': createdAt.toIso8601String(),
    });

    return InvoiceRecord(
      invoiceNumber: invoiceNumber,
      createdAt: createdAt,
      draft: draft,
    );
  }

  @override
  Future<void> promoteTeamMember({
    required AppUser owner,
    required TeamMemberRecord member,
    required UserRole targetRole,
  }) async {
    await _localDatabase.insertPendingInput(
      PendingSyncInput(
        userId: owner.id,
        inputType: 'role_promotion',
        payload: {
          'farm_id': owner.activeFarmId,
          'target_user_id': member.userId,
          'membership_id': member.membershipId,
          'new_role': targetRole.name.toUpperCase(),
        },
        createdAt: DateTime.now(),
      ),
    );

    await _localDatabase.updateLocalRecord(
      'farm_members',
      {'role': targetRole.name.toUpperCase()},
      where: 'id = ?',
      whereArgs: [member.membershipId],
    );

    if (_remoteApi.isConfigured) {
      await _remoteApi.promoteFarmMemberAndRevokeSessions(
        farmId: owner.activeFarmId,
        targetUserId: member.userId,
        newRole: targetRole.name.toUpperCase(),
      );
    }
  }

  Future<List<BatchOption>> _loadBatches(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'batches',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'batch_name asc',
      limit: 20,
    );

    return rows.map((row) {
      final label = _string(row['batch_name'], fallback: 'Batch ${row['id']}');
      return BatchOption(
        id: _string(row['id']),
        label: label,
        currentCount: _int(row['current_count']),
      );
    }).toList();
  }

  Future<List<FarmOption>> _loadFarms(AppUser user) async {
    final rows = await _localDatabase.queryLocalRecords(
      'farms',
      orderBy: 'name asc',
      limit: 50,
    );

    if (rows.isEmpty && user.activeFarmId.isNotEmpty) {
      return [
        FarmOption(id: user.activeFarmId, name: 'Farm ${user.activeFarmId}'),
      ];
    }

    return rows.map((row) {
      return FarmOption(
        id: _string(row['id']),
        name: _string(row['name'], fallback: 'Unnamed farm'),
        location: _string(row['location']),
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadHouseRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'houses',
      where: 'farm_id = ?',
      whereArgs: [farmId],
      orderBy: 'name asc',
      limit: 50,
    );
    return rows.map((row) {
      final temperature = _double(row['current_temperature']);
      final humidity = _double(row['current_humidity']);
      final environment = _string(row['environmental_state']);
      final metric = temperature > 0 || humidity > 0
          ? '${temperature.toStringAsFixed(1)}C / ${humidity.toStringAsFixed(0)}%'
          : '${_int(row['capacity'])} cap';
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['name'], fallback: 'House ${row['id']}'),
        subtitle: _bool(row['is_isolation'])
            ? 'Isolation house'
            : 'Capacity ${_int(row['capacity'])}',
        metric: metric,
        status: environment,
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadEggRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'egg_production',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'log_date desc',
      limit: 50,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: '${_int(row['eggs_collected'])} eggs collected',
        subtitle:
            '${_int(row['cracked_count'])} cracked | ${_dateText(row['log_date'])}',
        metric: _string(row['quality_grade'], fallback: 'Ungraded'),
        status: _bool(row['is_synced']) ? 'SYNCED' : 'LOCAL',
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadFeedingRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'daily_feeding_logs',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'log_date desc',
      limit: 50,
    );
    return rows.map((row) {
      final feedLabel = _string(
        row['feed_type_label'],
        fallback: _string(row['feed_type_id'], fallback: 'Feed'),
      );
      final remaining = _double(row['remaining_sack_count']);
      return HubModuleRecord(
        id: _string(row['id']),
        title: feedLabel,
        subtitle:
            '${_double(row['amount_consumed']).toStringAsFixed(2)} sacks used | ${_dateText(row['log_date'])}',
        metric: remaining > 0 ? '${remaining.toStringAsFixed(1)} left' : '',
        status: _bool(row['is_synced']) ? 'SYNCED' : 'LOCAL',
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadMortalityRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'mortality',
      where: "farm_id = ? and is_deleted = 0 and upper(type) = 'DEAD'",
      whereArgs: [farmId],
      orderBy: 'log_date desc',
      limit: 50,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: '${_int(row['count'])} bird losses',
        subtitle:
            '${_string(row['reason'], fallback: 'No reason logged')} | ${_dateText(row['log_date'])}',
        metric: _double(row['mortality_percent']) > 0
            ? '${(_double(row['mortality_percent']) * 100).toStringAsFixed(1)}%'
            : '',
        status: _string(row['loss_trend']),
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadQuarantineRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'quarantine',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'log_date desc',
      limit: 50,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: '${_int(row['sick_count'])} birds isolated',
        subtitle:
            '${_string(row['diagnosis'], fallback: 'Diagnosis pending')} | ${_dateText(row['log_date'])}',
        metric: '${(_double(row['recovery_rate']) * 100).toStringAsFixed(0)}%',
        status: _string(row['status'], fallback: 'ACTIVE'),
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadSalesRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'sales',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'sale_date desc',
      limit: 50,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['customer_name'], fallback: 'Farm sale'),
        subtitle:
            '${_string(row['payment_method'], fallback: 'Payment')} | ${_dateText(row['sale_date'])}',
        metric: _moneyText(_double(row['total_amount'])),
        status: _string(row['status']),
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadInventoryRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'item_name asc',
      limit: 80,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['item_name'], fallback: 'Inventory item'),
        subtitle: _string(
          row['item_group'],
          fallback: _string(row['category']),
        ),
        metric:
            '${_double(row['stock_level']).toStringAsFixed(1)} ${_string(row['unit'])}',
        status: _double(row['stock_level']) <= _double(row['reorder_level'])
            ? 'REORDER'
            : 'OK',
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadCustomerRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'customers',
      where: 'farm_id = ? and is_active = 1',
      whereArgs: [farmId],
      orderBy: 'name asc',
      limit: 80,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['name'], fallback: 'Customer'),
        subtitle: _string(
          row['phone'],
          fallback: _string(row['email'], fallback: 'No contact cached'),
        ),
        metric: _moneyText(_double(row['balance_owed'])),
        status: 'CUSTOMER',
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadSupplierRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'suppliers',
      where: 'farm_id = ? and is_active = 1',
      whereArgs: [farmId],
      orderBy: 'name asc',
      limit: 80,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['name'], fallback: 'Supplier'),
        subtitle: _string(
          row['phone'],
          fallback: _string(row['email'], fallback: 'No contact cached'),
        ),
        metric: _moneyText(_double(row['balance_owed'])),
        status: 'SUPPLIER',
      );
    }).toList();
  }

  Future<List<HubModuleRecord>> _loadFinanceRecords(String farmId) async {
    final rows = await _localDatabase.queryLocalRecords(
      'financial_transactions',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'transaction_date desc',
      limit: 80,
    );
    return rows.map((row) {
      return HubModuleRecord(
        id: _string(row['id']),
        title: _string(row['category'], fallback: 'Transaction'),
        subtitle:
            '${_string(row['payment_status'])} | ${_dateText(row['transaction_date'])}',
        metric: _moneyText(_double(row['amount'])),
        status: _string(row['type']),
      );
    }).toList();
  }

  Future<BatchAnalytics> _loadBatchAnalytics(
    BatchOption batch,
    String farmId,
  ) async {
    final feed = await _localDatabase.rawLocalQuery(
      'select coalesce(sum(amount_consumed), 0) as total from daily_feeding_logs where farm_id = ? and batch_id = ?',
      [farmId, batch.id],
    );
    final eggs = await _localDatabase.rawLocalQuery(
      'select coalesce(sum(eggs_collected), 0) as total from egg_production where farm_id = ? and batch_id = ?',
      [farmId, batch.id],
    );
    final mortality = await _localDatabase.rawLocalQuery(
      "select coalesce(sum(count), 0) as total from mortality where farm_id = ? and batch_id = ? and is_deleted = 0 and upper(type) = 'DEAD'",
      [farmId, batch.id],
    );
    final batchRows = await _localDatabase.queryLocalRecords(
      'batches',
      where: 'id = ?',
      whereArgs: [batch.id],
      limit: 1,
    );
    final initialCount = batchRows.isEmpty
        ? batch.currentCount
        : _int(batchRows.first['initial_count']);

    return BatchAnalytics(
      batchId: batch.id,
      batchLabel: batch.label,
      feedConsumed: _double(feed.first['total']),
      eggsCollected: _int(eggs.first['total']),
      currentCount: batch.currentCount,
      initialCount: initialCount,
      mortalityCount: _int(mortality.first['total']),
    );
  }

  Future<BatchProfitability> _loadProfitability(
    BatchOption batch,
    String farmId,
  ) async {
    final revenue = await _localDatabase.rawLocalQuery(
      "select coalesce(sum(amount), 0) as total from financial_transactions where farm_id = ? and is_deleted = 0 and type = 'REVENUE'",
      [farmId],
    );
    final expense = await _localDatabase.rawLocalQuery(
      'select coalesce(sum(amount), 0) as total from expenses where farm_id = ? and is_deleted = 0 and batch_id = ?',
      [farmId, batch.id],
    );

    final batchShare = await _loadBatches(farmId);
    final divisor = batchShare.isEmpty ? 1 : batchShare.length;

    return BatchProfitability(
      batchId: batch.id,
      batchLabel: batch.label,
      revenue: _double(revenue.first['total']) / divisor,
      expense: _double(expense.first['total']),
    );
  }

  Future<List<TeamMemberRecord>> _loadTeamMembers(String farmId) async {
    final rows = await _localDatabase.rawLocalQuery(
      '''
      select fm.id as membership_id,
             fm.user_id as user_id,
             fm.role as role,
             u.first_name as first_name,
             u.last_name as last_name,
             u.phone_number as phone
      from farm_members fm
      left join local_users u on u.id = fm.user_id
      where fm.farm_id = ?
      order by fm.role asc
      ''',
      [farmId],
    );

    return rows.map((row) {
      final name = '${_string(row['first_name'])} ${_string(row['last_name'])}'
          .trim();
      return TeamMemberRecord(
        membershipId: _string(row['membership_id']),
        userId: _string(row['user_id']),
        name: name.isEmpty
            ? _string(row['phone'], fallback: 'Team member')
            : name,
        phone: _string(row['phone']),
        role: UserRole.fromString(_string(row['role'])),
      );
    }).toList();
  }

  String _string(Object? value, {String fallback = ''}) {
    final string = value?.toString() ?? '';
    return string.isEmpty ? fallback : string;
  }

  int _int(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _double(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _bool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final normalized = value?.toString().trim().toLowerCase() ?? '';
    return normalized == 'true' || normalized == '1';
  }

  String _dateText(Object? value) {
    final text = _string(value);
    final parsed = DateTime.tryParse(text);
    if (parsed == null) {
      return text.isEmpty ? 'No date' : text;
    }
    return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
  }

  String _moneyText(double value) {
    return 'GHS ${value.toStringAsFixed(2)}';
  }
}

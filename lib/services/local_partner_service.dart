import '../core/storage/local_database.dart';

class PartnerProfile {
  const PartnerProfile({
    required this.id,
    required this.farmId,
    required this.name,
    required this.balanceOwed,
    this.phone,
    this.email,
    this.address,
    this.contactPerson,
  });

  final String id;
  final String farmId;
  final String name;
  final double balanceOwed;
  final String? phone;
  final String? email;
  final String? address;
  final String? contactPerson;
}

class PartnerStatementLine {
  const PartnerStatementLine({
    required this.id,
    required this.date,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.kind,
  });

  final String id;
  final DateTime date;
  final String title;
  final String subtitle;
  final double amount;
  final String kind;
}

class PartnerStatement {
  const PartnerStatement({
    required this.profile,
    required this.lines,
    required this.totalActivity,
    required this.totalSettled,
    required this.outstanding,
  });

  final PartnerProfile profile;
  final List<PartnerStatementLine> lines;
  final double totalActivity;
  final double totalSettled;
  final double outstanding;
}

enum PartnerKind { customer, supplier }

class LocalPartnerService {
  LocalPartnerService(this._localDatabase);

  final LocalDatabase _localDatabase;

  static double roundMoney(double value) => (value * 100).roundToDouble() / 100;

  String _tableFor(PartnerKind kind) =>
      kind == PartnerKind.supplier ? 'suppliers' : 'customers';

  Future<PartnerProfile?> loadProfile({
    required PartnerKind kind,
    required String farmId,
    required String partnerId,
  }) async {
    final rows = await _localDatabase.queryLocalRecords(
      _tableFor(kind),
      where: 'id = ? and farm_id = ?',
      whereArgs: [partnerId, farmId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return _profileFromRow(rows.first);
  }

  Future<PartnerStatement> loadSupplierStatement({
    required String farmId,
    required String supplierId,
  }) async {
    final profile = await loadProfile(
      kind: PartnerKind.supplier,
      farmId: farmId,
      partnerId: supplierId,
    );
    if (profile == null) {
      throw StateError('Supplier not found');
    }

    final expenses = await _localDatabase.queryLocalRecords(
      'expenses',
      where: 'farm_id = ? and supplier_id = ? and is_deleted = 0',
      whereArgs: [farmId, supplierId],
      orderBy: 'expense_date desc',
      limit: 100,
    );
    final inventory = await _localDatabase.queryLocalRecords(
      'inventory',
      where: 'farm_id = ? and supplier_id = ? and is_deleted = 0',
      whereArgs: [farmId, supplierId],
      orderBy: 'updated_at desc',
      limit: 100,
    );

    final lines = <PartnerStatementLine>[];
    var totalActivity = 0.0;
    var totalSettled = 0.0;

    for (final expense in expenses) {
      final amount = _asDouble(expense['amount']);
      final category = _asString(expense['category']).toUpperCase();
      if (category == 'PAYMENT') {
        totalSettled += amount;
      } else {
        totalActivity += amount;
      }
      lines.add(
        PartnerStatementLine(
          id: _asString(expense['id']),
          date: _parseDate(expense['expense_date']),
          title: _asString(expense['description'], fallback: category),
          subtitle: category,
          amount: amount,
          kind: category == 'PAYMENT' ? 'PAYMENT' : 'EXPENSE',
        ),
      );
    }

    if (expenses.isEmpty) {
      for (final item in inventory) {
        final stock = _asDouble(item['stock_level']);
        final unitCost = _asDouble(item['cost_per_unit']);
        final total = stock * unitCost;
        totalActivity += total;
        lines.add(
          PartnerStatementLine(
            id: _asString(item['id']),
            date: _parseDate(item['updated_at'] ?? item['created_at']),
            title: _asString(item['item_name'], fallback: 'Inventory item'),
            subtitle:
                '${stock.toStringAsFixed(1)} ${_asString(item['unit'])} @ ${unitCost.toStringAsFixed(2)}',
            amount: total,
            kind: 'INVENTORY',
          ),
        );
      }
    }

    lines.sort((a, b) => b.date.compareTo(a.date));

    return PartnerStatement(
      profile: profile,
      lines: lines,
      totalActivity: roundMoney(totalActivity),
      totalSettled: roundMoney(totalSettled),
      outstanding: roundMoney(profile.balanceOwed),
    );
  }

  Future<PartnerStatement> loadCustomerStatement({
    required String farmId,
    required String customerId,
  }) async {
    final profile = await loadProfile(
      kind: PartnerKind.customer,
      farmId: farmId,
      partnerId: customerId,
    );
    if (profile == null) {
      throw StateError('Customer not found');
    }

    final orders = await _localDatabase.queryLocalRecords(
      'orders',
      where: 'farm_id = ? and customer_id = ? and is_deleted = 0',
      whereArgs: [farmId, customerId],
      orderBy: 'order_date desc',
      limit: 100,
    );
    final sales = orders.isEmpty
        ? await _localDatabase.queryLocalRecords(
            'sales',
            where: 'farm_id = ? and customer_id = ? and is_deleted = 0',
            whereArgs: [farmId, customerId],
            orderBy: 'sale_date desc',
            limit: 100,
          )
        : const <Map<String, Object?>>[];

    final lines = <PartnerStatementLine>[];
    var totalActivity = 0.0;

    for (final order in orders) {
      final amount = _asDouble(order['total_amount']);
      totalActivity += amount;
      lines.add(
        PartnerStatementLine(
          id: _asString(order['id']),
          date: _parseDate(order['order_date'] ?? order['created_at']),
          title: 'Order',
          subtitle: _asString(order['status'], fallback: 'PENDING'),
          amount: amount,
          kind: 'ORDER',
        ),
      );
    }

    for (final sale in sales) {
      final amount = _asDouble(sale['total_amount']);
      totalActivity += amount;
      lines.add(
        PartnerStatementLine(
          id: _asString(sale['id']),
          date: _parseDate(sale['sale_date'] ?? sale['created_at']),
          title: _asString(sale['customer_name'], fallback: 'Sale'),
          subtitle: _asString(sale['status'], fallback: 'completed'),
          amount: amount,
          kind: 'SALE',
        ),
      );
    }

    final settlements = await _localDatabase.queryLocalRecords(
      'expenses',
      where:
          "farm_id = ? and is_deleted = 0 and upper(category) = 'COLLECTION' and description like ?",
      whereArgs: [farmId, '%customer $customerId%'],
      orderBy: 'expense_date desc',
      limit: 100,
    );
    var totalSettled = 0.0;
    for (final settlement in settlements) {
      final amount = _asDouble(settlement['amount']);
      totalSettled += amount;
      lines.add(
        PartnerStatementLine(
          id: _asString(settlement['id']),
          date: _parseDate(settlement['expense_date']),
          title: 'Collection',
          subtitle: 'COLLECTION',
          amount: amount,
          kind: 'COLLECTION',
        ),
      );
    }

    lines.sort((a, b) => b.date.compareTo(a.date));

    return PartnerStatement(
      profile: profile,
      lines: lines,
      totalActivity: roundMoney(totalActivity),
      totalSettled: roundMoney(totalSettled),
      outstanding: roundMoney(profile.balanceOwed),
    );
  }

  Future<void> recordSupplierPayment({
    required String farmId,
    required String userId,
    required String supplierId,
    required double amount,
  }) async {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'Payment must be positive.');
    }

    final profile = await loadProfile(
      kind: PartnerKind.supplier,
      farmId: farmId,
      partnerId: supplierId,
    );
    if (profile == null) {
      throw StateError('Supplier not found');
    }
    if (amount > profile.balanceOwed + 0.01) {
      throw ArgumentError('Payment exceeds outstanding balance.');
    }

    final now = DateTime.now().toUtc();
    final paymentId = 'pay_${now.microsecondsSinceEpoch}';
    final newBalance = roundMoney(
      (profile.balanceOwed - amount).clamp(0, double.infinity),
    );

    await _localDatabase.updateLocalRecord(
      'suppliers',
      {
        'balance_owed': newBalance,
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [supplierId],
    );
    await _localDatabase.insertLocalRecord('expenses', {
      'id': paymentId,
      'farm_id': farmId,
      'user_id': userId,
      'amount': roundMoney(amount),
      'category': 'PAYMENT',
      'description': 'Settlement PAYMENT (supplier $supplierId)',
      'expense_date': now.toIso8601String(),
      'supplier_id': supplierId,
      'is_deleted': 0,
      'is_synced': 0,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
  }

  Future<void> recordCustomerCollection({
    required String farmId,
    required String userId,
    required String customerId,
    required double amount,
  }) async {
    if (amount <= 0) {
      throw ArgumentError.value(amount, 'amount', 'Collection must be positive.');
    }

    final profile = await loadProfile(
      kind: PartnerKind.customer,
      farmId: farmId,
      partnerId: customerId,
    );
    if (profile == null) {
      throw StateError('Customer not found');
    }
    if (amount > profile.balanceOwed + 0.01) {
      throw ArgumentError('Collection exceeds outstanding balance.');
    }

    final now = DateTime.now().toUtc();
    final collectionId = 'col_${now.microsecondsSinceEpoch}';
    final newBalance = roundMoney(
      (profile.balanceOwed - amount).clamp(0, double.infinity),
    );

    await _localDatabase.updateLocalRecord(
      'customers',
      {
        'balance_owed': newBalance,
        'updated_at': now.toIso8601String(),
      },
      where: 'id = ?',
      whereArgs: [customerId],
    );
    await _localDatabase.insertLocalRecord('expenses', {
      'id': collectionId,
      'farm_id': farmId,
      'user_id': userId,
      'amount': roundMoney(amount),
      'category': 'COLLECTION',
      'description': 'Settlement COLLECTION (customer $customerId)',
      'expense_date': now.toIso8601String(),
      'is_deleted': 0,
      'is_synced': 0,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
  }

  PartnerProfile _profileFromRow(Map<String, Object?> row) {
    return PartnerProfile(
      id: _asString(row['id']),
      farmId: _asString(row['farm_id']),
      name: _asString(row['name'], fallback: 'Partner'),
      balanceOwed: _asDouble(row['balance_owed']),
      phone: _nullableString(row['phone']),
      email: _nullableString(row['email']),
      address: _nullableString(row['address']),
      contactPerson: _nullableString(row['contact_person']),
    );
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

  String _asString(Object? value, {String fallback = ''}) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? fallback : text;
  }

  String? _nullableString(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  DateTime _parseDate(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) {
      return DateTime.now();
    }
    return DateTime.tryParse(text) ?? DateTime.now();
  }
}

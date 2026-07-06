import '../core/storage/local_database.dart';
import 'finance_category_labels.dart';

enum FinanceLedgerSource { ledger, expense }

class FinanceLedgerEntry {
  const FinanceLedgerEntry({
    required this.id,
    required this.type,
    required this.category,
    required this.amount,
    required this.paymentStatus,
    required this.paymentMethod,
    required this.referenceNum,
    required this.transactionDate,
    required this.description,
    required this.source,
  });

  final String id;
  final String type;
  final String category;
  final double amount;
  final String paymentStatus;
  final String paymentMethod;
  final String? referenceNum;
  final DateTime transactionDate;
  final String? description;
  final FinanceLedgerSource source;

  bool get isAutoLogged => source == FinanceLedgerSource.expense;
  bool get isOutstanding => paymentStatus.toUpperCase() != 'PAID';
}

class FinanceLedgerSummary {
  const FinanceLedgerSummary({
    required this.totalRevenue,
    required this.totalExpense,
    required this.netPosition,
    required this.outstandingCount,
  });

  final double totalRevenue;
  final double totalExpense;
  final double netPosition;
  final int outstandingCount;
}

/// Merges manual `financial_transactions` with operational `expenses`
/// (mirrors web `getFinancialTransactions`).
class FinanceLedgerService {
  FinanceLedgerService(this._db);

  final LocalDatabase _db;

  Future<List<FinanceLedgerEntry>> loadTransactions(String farmId) async {
    final ledgerRows = await _db.queryLocalRecords(
      'financial_transactions',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'transaction_date desc',
    );
    final expenseRows = await _db.queryLocalRecords(
      'expenses',
      where: 'farm_id = ? and is_deleted = 0',
      whereArgs: [farmId],
      orderBy: 'expense_date desc',
    );

    final entries = <FinanceLedgerEntry>[
      ...ledgerRows.map(_mapLedgerRow),
      ...expenseRows.map(_mapExpenseRow),
    ]..sort((a, b) => b.transactionDate.compareTo(a.transactionDate));

    return entries;
  }

  Future<FinanceLedgerSummary> loadSummary(String farmId) async {
    final entries = await loadTransactions(farmId);
    final revenue = entries
        .where((entry) => entry.type.toUpperCase() == 'REVENUE')
        .fold<double>(0, (sum, entry) => sum + entry.amount);
    final expense = entries
        .where((entry) => entry.type.toUpperCase() == 'EXPENSE')
        .fold<double>(0, (sum, entry) => sum + entry.amount);
    final outstanding = entries.where((entry) => entry.isOutstanding).length;
    return FinanceLedgerSummary(
      totalRevenue: revenue,
      totalExpense: expense,
      netPosition: revenue - expense,
      outstandingCount: outstanding,
    );
  }

  Future<List<FinanceLedgerEntry>> loadOutstanding(String farmId) async {
    final entries = await loadTransactions(farmId);
    return entries.where((entry) => entry.isOutstanding).toList();
  }

  FinanceLedgerEntry _mapLedgerRow(Map<String, Object?> row) {
    return FinanceLedgerEntry(
      id: row['id']?.toString() ?? '',
      type: row['type']?.toString().toUpperCase() ?? 'EXPENSE',
      category: row['category']?.toString() ?? '',
      amount: _double(row['amount']),
      paymentStatus: row['payment_status']?.toString().toUpperCase() ?? 'PAID',
      paymentMethod: row['payment_method']?.toString() ?? 'Cash',
      referenceNum: row['reference_num']?.toString(),
      transactionDate: _parseDate(row['transaction_date']),
      description: row['description']?.toString(),
      source: FinanceLedgerSource.ledger,
    );
  }

  FinanceLedgerEntry _mapExpenseRow(Map<String, Object?> row) {
    return FinanceLedgerEntry(
      id: row['id']?.toString() ?? '',
      type: 'EXPENSE',
      category: expenseCategoryLabel(row['category']?.toString()),
      amount: _double(row['amount']),
      paymentStatus: 'PAID',
      paymentMethod: 'Operational',
      referenceNum: null,
      transactionDate: _parseDate(row['expense_date'] ?? row['date']),
      description: row['description']?.toString(),
      source: FinanceLedgerSource.expense,
    );
  }

  double _double(Object? value) {
    if (value == null) {
      return 0;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value.toString()) ?? 0;
  }

  DateTime _parseDate(Object? value) {
    if (value == null) {
      return DateTime.now();
    }
    return DateTime.tryParse(value.toString()) ?? DateTime.now();
  }
}

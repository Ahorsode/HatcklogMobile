import '../../../core/models/app_user.dart';

enum ManagementSection {
  dashboard,
  livestock,
  houses,
  eggs,
  feeding,
  mortality,
  quarantine,
  sales,
  inventory,
  customers,
  financeControl,
  profile,
  settings,
}

class ManagementPermissions {
  const ManagementPermissions({
    required this.canViewFinance,
    required this.canEditFinance,
    required this.canViewOperations,
    required this.canEditBatches,
    required this.canIssueInvoices,
    required this.canDiscount,
    required this.canManageTeam,
    required this.canPromoteUsers,
    required this.canEditHistoricalLedger,
  });

  final bool canViewFinance;
  final bool canEditFinance;
  final bool canViewOperations;
  final bool canEditBatches;
  final bool canIssueInvoices;
  final bool canDiscount;
  final bool canManageTeam;
  final bool canPromoteUsers;
  final bool canEditHistoricalLedger;

  bool canOpen(ManagementSection section) {
    return true;
  }

  static ManagementPermissions forRole(UserRole role) {
    return const ManagementPermissions(
      canViewFinance: true,
      canEditFinance: true,
      canViewOperations: true,
      canEditBatches: true,
      canIssueInvoices: true,
      canDiscount: true,
      canManageTeam: true,
      canPromoteUsers: true,
      canEditHistoricalLedger: true,
    );
  }
}

class BatchOption {
  const BatchOption({
    required this.id,
    required this.label,
    required this.currentCount,
  });

  final String id;
  final String label;
  final int currentCount;
}

class FarmOption {
  const FarmOption({required this.id, required this.name, this.location = ''});

  final String id;
  final String name;
  final String location;
}

class HubModuleRecord {
  const HubModuleRecord({
    required this.id,
    required this.title,
    required this.subtitle,
    this.metric = '',
    this.status = '',
  });

  final String id;
  final String title;
  final String subtitle;
  final String metric;
  final String status;
}

class ExpenseAllocation {
  const ExpenseAllocation({
    required this.batchId,
    required this.batchLabel,
    required this.percent,
  });

  final String batchId;
  final String batchLabel;
  final double percent;
}

class ExpenseDraft {
  const ExpenseDraft({
    required this.amount,
    required this.category,
    required this.description,
    required this.expenseDate,
    required this.allocations,
  });

  final double amount;
  final String category;
  final String description;
  final DateTime expenseDate;
  final List<ExpenseAllocation> allocations;
}

class InvoiceLineItem {
  const InvoiceLineItem({
    required this.description,
    required this.quantity,
    required this.unitPrice,
  });

  final String description;
  final int quantity;
  final double unitPrice;

  double get subtotal => quantity * unitPrice;
}

class InvoiceDraft {
  const InvoiceDraft({
    required this.customerName,
    required this.customerType,
    required this.item,
    required this.quantity,
    required this.unitPrice,
    required this.amountReceived,
    required this.discount,
    required this.taxRate,
    required this.paymentMethod,
  });

  final String customerName;
  final String customerType;
  final String item;
  final int quantity;
  final double unitPrice;
  final double amountReceived;
  final double discount;
  final double taxRate;
  final String paymentMethod;

  double get subtotal => quantity * unitPrice;

  double get taxAmount =>
      (subtotal - discount).clamp(0, double.infinity) * taxRate;

  double get total =>
      (subtotal - discount).clamp(0, double.infinity) + taxAmount;

  bool get isPaid => amountReceived >= total;
}

class InvoiceRecord {
  const InvoiceRecord({
    required this.invoiceNumber,
    required this.createdAt,
    required this.draft,
  });

  final String invoiceNumber;
  final DateTime createdAt;
  final InvoiceDraft draft;
}

class BatchProfitability {
  const BatchProfitability({
    required this.batchId,
    required this.batchLabel,
    required this.revenue,
    required this.expense,
  });

  final String batchId;
  final String batchLabel;
  final double revenue;
  final double expense;

  double get netProfit => revenue - expense;
}

class BatchAnalytics {
  const BatchAnalytics({
    required this.batchId,
    required this.batchLabel,
    required this.feedConsumed,
    required this.eggsCollected,
    required this.currentCount,
    required this.initialCount,
    required this.mortalityCount,
  });

  final String batchId;
  final String batchLabel;
  final double feedConsumed;
  final int eggsCollected;
  final int currentCount;
  final int initialCount;
  final int mortalityCount;

  double get mortalityRate {
    if (initialCount <= 0) {
      return 0;
    }
    return mortalityCount / initialCount;
  }

  double get fcrProxy {
    if (eggsCollected <= 0) {
      return 0;
    }
    return feedConsumed / eggsCollected;
  }
}

class ManagementSnapshot {
  const ManagementSnapshot({
    required this.totalRevenue,
    required this.totalExpenses,
    required this.pendingSyncCount,
    required this.farms,
    required this.batches,
    required this.analytics,
    required this.profitability,
    required this.teamMembers,
    required this.houseRecords,
    required this.eggRecords,
    required this.feedingRecords,
    required this.mortalityRecords,
    required this.quarantineRecords,
    required this.salesRecords,
    required this.inventoryRecords,
    required this.customerRecords,
    required this.supplierRecords,
    required this.financeRecords,
  });

  final double totalRevenue;
  final double totalExpenses;
  final int pendingSyncCount;
  final List<FarmOption> farms;
  final List<BatchOption> batches;
  final List<BatchAnalytics> analytics;
  final List<BatchProfitability> profitability;
  final List<TeamMemberRecord> teamMembers;
  final List<HubModuleRecord> houseRecords;
  final List<HubModuleRecord> eggRecords;
  final List<HubModuleRecord> feedingRecords;
  final List<HubModuleRecord> mortalityRecords;
  final List<HubModuleRecord> quarantineRecords;
  final List<HubModuleRecord> salesRecords;
  final List<HubModuleRecord> inventoryRecords;
  final List<HubModuleRecord> customerRecords;
  final List<HubModuleRecord> supplierRecords;
  final List<HubModuleRecord> financeRecords;

  double get netProfit => totalRevenue - totalExpenses;
}

class TeamMemberRecord {
  const TeamMemberRecord({
    required this.membershipId,
    required this.userId,
    required this.name,
    required this.phone,
    required this.role,
  });

  final String membershipId;
  final String userId;
  final String name;
  final String phone;
  final UserRole role;
}

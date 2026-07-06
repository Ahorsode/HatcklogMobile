/// Maps Prisma `Expense.category` enum values to Finance Hub display labels
/// (mirrors web `financial-transaction-actions.ts`).
const expenseCategoryLabels = <String, String>{
  'FEED': 'Feed Purchases',
  'MEDICATION': 'Flock Vaccines & Medication',
  'EQUIPMENT': 'Equipment & Maintenance',
  'UTILITIES': 'Utilities',
  'SALARY': 'Labor & Salaries',
  'MAINTENANCE': 'Equipment & Maintenance',
  'OTHER': 'Other OpEx',
  'LIVESTOCK_PURCHASE': 'Day-Old Chicks Purchase',
  'TRANSPORT': 'Transport',
};

const revenueCategories = [
  'Egg Wholesale Revenue',
  'Broiler Sales',
  'Manure Sales',
  'Other Revenue',
];

const opexCategories = [
  'Feed Purchases',
  'Flock Vaccines & Medication',
  'Day-Old Chicks Purchase',
  'Labor & Salaries',
  'Utilities',
  'Transport',
  'Other OpEx',
];

const capexCategories = [
  'Equipment & Maintenance',
  'Infrastructure & Setup',
  'Other CapEx',
];

const expenseLedgerCategories = [...opexCategories, ...capexCategories];

const expenseEnumCategories = [
  'FEED',
  'MEDICATION',
  'EQUIPMENT',
  'UTILITIES',
  'SALARY',
  'MAINTENANCE',
  'OTHER',
  'LIVESTOCK_PURCHASE',
  'TRANSPORT',
];

const paymentMethods = [
  'Cash',
  'Mobile Money',
  'Bank Transfer',
  'Card',
];

String expenseCategoryLabel(String? raw) {
  final key = raw?.trim().toUpperCase() ?? '';
  return expenseCategoryLabels[key] ?? raw?.trim() ?? 'Other OpEx';
}

String expenseEnumFromLabel(String label) {
  for (final entry in expenseCategoryLabels.entries) {
    if (entry.value == label) {
      return entry.key;
    }
  }
  return 'OTHER';
}

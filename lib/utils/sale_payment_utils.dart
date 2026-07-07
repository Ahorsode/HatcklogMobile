enum SalePaymentMethod {
  cash('CASH'),
  mobileMoney('MOBILE_MONEY'),
  bankTransfer('BANK_TRANSFER'),
  credit('CREDIT');

  const SalePaymentMethod(this.apiValue);
  final String apiValue;

  static SalePaymentMethod fromApiValue(String? value) {
    final normalized = (value ?? 'CASH').trim().toUpperCase().replaceAll(' ', '_');
    return SalePaymentMethod.values.firstWhere(
      (method) => method.apiValue == normalized,
      orElse: () => SalePaymentMethod.cash,
    );
  }

  String get label => switch (this) {
    SalePaymentMethod.cash => 'Cash',
    SalePaymentMethod.mobileMoney => 'Mobile Money',
    SalePaymentMethod.bankTransfer => 'Bank Transfer',
    SalePaymentMethod.credit => 'Credit',
  };
}

List<String> validateSalePaymentFields({
  required SalePaymentMethod paymentMethod,
  String? paymentReference,
  String? paymentAccountName,
  String? customerId,
}) {
  final errors = <String>[];
  if (paymentMethod == SalePaymentMethod.mobileMoney) {
    if (paymentReference == null || paymentReference.trim().isEmpty) {
      errors.add('MoMo phone number is required');
    }
    if (paymentAccountName == null || paymentAccountName.trim().isEmpty) {
      errors.add('MoMo account holder name is required');
    }
  }
  if (paymentMethod == SalePaymentMethod.credit &&
      (customerId == null || customerId.isEmpty)) {
    errors.add('Credit sales require a saved customer');
  }
  return errors;
}

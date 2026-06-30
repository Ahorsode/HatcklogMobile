enum SaleProductType { inventory, livestock, custom }

class SaleLineDraft {
  const SaleLineDraft({
    required this.productType,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    this.inventoryId,
    this.livestockId,
  });

  final SaleProductType productType;
  final String description;
  final int quantity;
  final double unitPrice;
  final String? inventoryId;
  final String? livestockId;

  double get lineTotal => quantity * unitPrice;

  Map<String, dynamic> toPayloadMap() {
    return {
      'description': description,
      'quantity': quantity,
      'unit_price': unitPrice,
      'total_price': lineTotal,
      'product_type': productType.name,
      if (inventoryId != null && inventoryId!.isNotEmpty)
        'inventory_id': inventoryId,
      if (livestockId != null && livestockId!.isNotEmpty)
        'livestock_id': livestockId,
    };
  }
}

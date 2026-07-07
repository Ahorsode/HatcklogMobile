import '../../utils/egg_log_utils.dart';
import '../../utils/sale_quantity_utils.dart';

enum SaleProductType { inventory, livestock, custom }

class SaleLineDraft {
  const SaleLineDraft({
    required this.productType,
    required this.description,
    required this.quantity,
    required this.unitPrice,
    this.inventoryId,
    this.livestockId,
    this.eggAllocationMode,
    this.eggBatchId,
    this.eggQuantityUnit = EggSaleQuantityUnit.crate,
    this.lineDiscountAmount = 0,
    this.lineDiscountType = 'flat',
    this.eggsPerCrate = defaultEggsPerCrate,
  });

  final SaleProductType productType;
  final String description;
  /// User-entered quantity in [eggQuantityUnit] for eggs, or birds for livestock.
  final int quantity;
  /// Display unit price (per crate or per egg for inventory).
  final double unitPrice;
  final String? inventoryId;
  final String? livestockId;
  /// `fifo` = oldest eggs first farm-wide; `batch` = FIFO within [eggBatchId].
  final String? eggAllocationMode;
  final String? eggBatchId;
  final EggSaleQuantityUnit eggQuantityUnit;
  final double lineDiscountAmount;
  final String lineDiscountType;
  final int eggsPerCrate;

  int get resolvedQuantityEggs {
    if (productType != SaleProductType.inventory) {
      return quantity;
    }
    return saleQuantityInEggs(
      displayQuantity: quantity,
      unit: eggQuantityUnit,
      eggsPerCrate: eggsPerCrate,
    );
  }

  double get lineSubtotal => quantity * unitPrice;

  double get lineDiscountValue => computeLineDiscount(
        lineSubtotal: lineSubtotal,
        discountAmount: lineDiscountAmount,
        discountType: lineDiscountType,
      );

  double get lineTotal =>
      (lineSubtotal - lineDiscountValue).clamp(0, double.infinity);

  double get resolvedUnitPricePerEgg {
    if (productType != SaleProductType.inventory) {
      return unitPrice;
    }
    return saleUnitPricePerEgg(
      displayUnitPrice: unitPrice,
      unit: eggQuantityUnit,
      eggsPerCrate: eggsPerCrate,
    );
  }

  Map<String, dynamic> toPayloadMap() {
    final syncQuantity = productType == SaleProductType.inventory
        ? resolvedQuantityEggs
        : quantity;
    final syncUnitPrice = productType == SaleProductType.inventory
        ? resolvedUnitPricePerEgg
        : unitPrice;
    return {
      'description': description,
      'quantity': syncQuantity,
      'unit_price': syncUnitPrice,
      'total_price': lineTotal,
      'product_type': productType.name,
      'line_discount_amount': lineDiscountValue,
      'line_discount_type': lineDiscountType,
      if (inventoryId != null && inventoryId!.isNotEmpty)
        'inventory_id': inventoryId,
      if (livestockId != null && livestockId!.isNotEmpty)
        'livestock_id': livestockId,
      if (eggAllocationMode != null && eggAllocationMode!.isNotEmpty)
        'egg_allocation_mode': eggAllocationMode,
      if (eggBatchId != null && eggBatchId!.isNotEmpty)
        'egg_batch_id': eggBatchId,
      if (productType == SaleProductType.inventory)
        'egg_quantity_unit': eggQuantityUnit.name,
    };
  }
}

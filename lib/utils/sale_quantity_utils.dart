import 'egg_log_utils.dart';

enum EggSaleQuantityUnit { crate, egg }

int saleQuantityInEggs({
  required int displayQuantity,
  required EggSaleQuantityUnit unit,
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  if (displayQuantity <= 0) {
    return 0;
  }
  if (unit == EggSaleQuantityUnit.crate) {
    return displayQuantity * eggsPerCrate;
  }
  return displayQuantity;
}

double saleUnitPriceForDisplay({
  required double catalogPricePerCrate,
  required EggSaleQuantityUnit unit,
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  if (unit == EggSaleQuantityUnit.crate) {
    return catalogPricePerCrate;
  }
  return eggsPerCrate > 0
      ? catalogPricePerCrate / eggsPerCrate
      : catalogPricePerCrate;
}

double saleUnitPricePerEgg({
  required double displayUnitPrice,
  required EggSaleQuantityUnit unit,
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  if (unit == EggSaleQuantityUnit.egg) {
    return displayUnitPrice;
  }
  return eggsPerCrate > 0 ? displayUnitPrice / eggsPerCrate : displayUnitPrice;
}

/// Money value of free units given on top of paid quantity.
double computeItemGiveawayDiscount(double giveawayQty, double unitPrice) {
  if (giveawayQty <= 0 || unitPrice <= 0) {
    return 0;
  }
  return giveawayQty * unitPrice;
}

/// Stock quantity leaving inventory = paid units + free giveaway units.
int saleQuantityWithGiveaway(int paidQuantity, int giveawayQuantity) {
  final paid = paidQuantity < 0 ? 0 : paidQuantity;
  final free = giveawayQuantity < 0 ? 0 : giveawayQuantity;
  return paid + free;
}

double computeLineDiscount({
  required double lineSubtotal,
  required double discountAmount,
  String discountType = 'flat',
  double unitPrice = 0,
}) {
  if (discountType == 'item') {
    return computeItemGiveawayDiscount(discountAmount, unitPrice);
  }
  if (lineSubtotal <= 0) {
    return 0;
  }
  if (discountType == 'percent') {
    return (lineSubtotal * discountAmount / 100).clamp(0, lineSubtotal);
  }
  return discountAmount.clamp(0, lineSubtotal);
}

String formatEggStockCrateLabel(
  int eggsInStock, {
  int eggsPerCrate = defaultEggsPerCrate,
}) {
  if (eggsInStock <= 0) {
    return '0 crates';
  }
  final crates = eggsInStock ~/ eggsPerCrate;
  final remainder = eggsInStock % eggsPerCrate;
  final crateLabel = crates == 1 ? 'crate' : 'crates';
  if (remainder == 0) {
    return '$crates $crateLabel';
  }
  final eggLabel = remainder == 1 ? 'egg' : 'eggs';
  return '$crates $crateLabel (+$remainder $eggLabel)';
}

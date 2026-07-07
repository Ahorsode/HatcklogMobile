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

double computeLineDiscount({
  required double lineSubtotal,
  required double discountAmount,
  String discountType = 'flat',
}) {
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

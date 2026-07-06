/// Helpers aligned with web `SalesForm` egg inventory selection.
bool isEggInventoryRow(Map<String, Object?> row) {
  final category = row['category']?.toString().trim().toUpperCase() ?? '';
  final name = row['item_name']?.toString().trim().toLowerCase() ?? '';
  return category == 'EGGS' || name.contains('egg');
}

double inventoryStockLevel(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool isInStockForSale(Map<String, Object?> row) {
  return inventoryStockLevel(row['stock_level']) > 0;
}

String inventoryUnitLabel(Map<String, Object?> row) {
  final unit = row['unit']?.toString().trim();
  if (unit != null && unit.isNotEmpty) {
    return unit;
  }
  return 'units';
}

String formatSaleInventoryLabel(Map<String, Object?> row) {
  final name = row['item_name']?.toString().trim();
  final label = name == null || name.isEmpty ? 'Inventory item' : name;
  final stock = inventoryStockLevel(row['stock_level']).floor();
  final unit = inventoryUnitLabel(row);
  return '$label ($stock $unit)';
}

List<Map<String, Object?>> inventoryRowsForSale(
  List<Map<String, Object?>> rows,
) {
  final inStock = rows.where(isInStockForSale).toList(growable: false);
  final eggRows = inStock.where(isEggInventoryRow).toList(growable: false);
  if (eggRows.isNotEmpty) {
    return eggRows;
  }
  return inStock;
}

/// Egg-only sellable rows for sales (no feed/medicine fallback).
List<Map<String, Object?>> sellableEggInventoryRows(
  List<Map<String, Object?>> rows,
) {
  return rows
      .where(isInStockForSale)
      .where(isEggInventoryRow)
      .toList(growable: false);
}

double inventorySalePrice(
  Map<String, Object?> row, {
  Map<String, Map<String, Object?>> eggCategoriesById = const {},
}) {
  final rowSellingPrice = _rowDouble(row['selling_price']);
  if (rowSellingPrice > 0) {
    return rowSellingPrice;
  }
  final categoryId = row['egg_category_id']?.toString().trim() ?? '';
  if (categoryId.isNotEmpty) {
    final category = eggCategoriesById[categoryId];
    final categoryPrice = _rowDouble(category?['selling_price']);
    if (categoryPrice > 0) {
      return categoryPrice;
    }
  }
  return _rowDouble(row['cost_per_unit']);
}

double _rowDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool inventoryCatalogIsEggFocused(List<Map<String, Object?>> saleRows) {
  return saleRows.isNotEmpty && saleRows.every(isEggInventoryRow);
}

int eggUsableCount({required int collected, required int unusable}) {
  final usable = collected - unusable;
  return usable < 0 ? 0 : usable;
}

int eggSoldCount({
  required int collected,
  required int unusable,
  required int remaining,
}) {
  final sold = eggUsableCount(collected: collected, unusable: unusable) - remaining;
  return sold < 0 ? 0 : sold;
}

bool isEggLogSoldOut({
  required int remaining,
  required int collected,
  required int unusable,
}) {
  if (collected <= 0) {
    return true;
  }
  return remaining <= 0;
}

bool isEggLogActive({
  required int remaining,
  required int collected,
}) {
  return collected > 0 && remaining > 0;
}

int eggActivePercent({
  required int collected,
  required int unusable,
  required int remaining,
}) {
  final usable = eggUsableCount(collected: collected, unusable: unusable);
  if (usable <= 0) {
    return 0;
  }
  return ((remaining / usable) * 100).round();
}

int eggSoldPercent({
  required int collected,
  required int unusable,
  required int remaining,
}) {
  final usable = eggUsableCount(collected: collected, unusable: unusable);
  if (usable <= 0) {
    return 0;
  }
  final sold = eggSoldCount(
    collected: collected,
    unusable: unusable,
    remaining: remaining,
  );
  return ((sold / usable) * 100).round();
}

bool matchesEggStockFilter(
  Map<String, Object?> row,
  String filter,
) {
  final collected = _eggRowInt(row, 'eggs_collected');
  final remaining = _eggRowInt(row, 'eggs_remaining');
  final unusable = _eggRowInt(row, 'unusable_count');
  return switch (filter) {
    'active' => isEggLogActive(remaining: remaining, collected: collected),
    'sold_out' =>
      collected > 0 &&
          isEggLogSoldOut(
            remaining: remaining,
            collected: collected,
            unusable: unusable,
          ),
    _ => true,
  };
}

int _eggRowInt(Map<String, Object?> row, String key) {
  final value = row[key];
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

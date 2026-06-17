enum WorkerInputType {
  eggCollection,
  feedUsage,
  mortality,
  inventoryItem,
  expenseAllocation;

  static WorkerInputType fromStorageKey(String value) {
    switch (value) {
      case 'egg_collection':
        return WorkerInputType.eggCollection;
      case 'feed_usage':
        return WorkerInputType.feedUsage;
      case 'mortality':
        return WorkerInputType.mortality;
      case 'inventory_item':
        return WorkerInputType.inventoryItem;
      case 'expense_allocation':
        return WorkerInputType.expenseAllocation;
      default:
        return WorkerInputType.eggCollection;
    }
  }

  String get storageKey {
    switch (this) {
      case WorkerInputType.eggCollection:
        return 'egg_collection';
      case WorkerInputType.feedUsage:
        return 'feed_usage';
      case WorkerInputType.mortality:
        return 'mortality';
      case WorkerInputType.inventoryItem:
        return 'inventory_item';
      case WorkerInputType.expenseAllocation:
        return 'expense_allocation';
    }
  }

  String get title {
    switch (this) {
      case WorkerInputType.eggCollection:
        return 'Egg Collection';
      case WorkerInputType.feedUsage:
        return 'Feed Usage';
      case WorkerInputType.mortality:
        return 'Mortality';
      case WorkerInputType.inventoryItem:
        return 'Inventory Item';
      case WorkerInputType.expenseAllocation:
        return 'Expense';
    }
  }

  String get valueLabel {
    switch (this) {
      case WorkerInputType.eggCollection:
        return 'Trays or eggs collected';
      case WorkerInputType.feedUsage:
        return 'Feed used';
      case WorkerInputType.mortality:
        return 'Bird count';
      case WorkerInputType.inventoryItem:
        return 'Stock level';
      case WorkerInputType.expenseAllocation:
        return 'Expense amount';
    }
  }

  String get unitHint {
    switch (this) {
      case WorkerInputType.eggCollection:
        return 'Example: 42';
      case WorkerInputType.feedUsage:
        return 'Example: 3 bags';
      case WorkerInputType.mortality:
        return 'Example: 2';
      case WorkerInputType.inventoryItem:
        return 'Example: 12 bags';
      case WorkerInputType.expenseAllocation:
        return 'Example: 250.00';
    }
  }
}

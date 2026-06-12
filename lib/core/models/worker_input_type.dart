enum WorkerInputType {
  eggCollection,
  feedUsage,
  mortality;

  static WorkerInputType fromStorageKey(String value) {
    switch (value) {
      case 'egg_collection':
        return WorkerInputType.eggCollection;
      case 'feed_usage':
        return WorkerInputType.feedUsage;
      case 'mortality':
        return WorkerInputType.mortality;
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
    }
  }
}

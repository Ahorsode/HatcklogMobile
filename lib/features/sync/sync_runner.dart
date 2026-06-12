import 'dart:async';

import '../../core/connectivity/connectivity_service.dart';
import 'data/sync_repository.dart';

class SyncRunner {
  SyncRunner({
    required ConnectivityService connectivityService,
    required SyncRepository syncRepository,
  }) : _connectivityService = connectivityService,
       _syncRepository = syncRepository;

  final ConnectivityService _connectivityService;
  final SyncRepository _syncRepository;

  StreamSubscription<bool>? _connectivitySubscription;
  Timer? _periodicSync;
  bool _isSyncing = false;

  void start() {
    _connectivitySubscription = _connectivityService.onOnlineChanged.listen((
      isOnline,
    ) {
      if (isOnline) {
        syncNow();
      }
    });

    _periodicSync = Timer.periodic(
      const Duration(minutes: 2),
      (_) => syncWhenOnline(),
    );
    syncWhenOnline();
  }

  Future<void> syncWhenOnline() async {
    if (await _connectivityService.isOnline) {
      await syncNow();
    }
  }

  Future<void> syncNow() async {
    if (_isSyncing) {
      return;
    }

    _isSyncing = true;
    try {
      await _syncRepository.flushPendingInputs();
    } finally {
      _isSyncing = false;
    }
  }

  void dispose() {
    _connectivitySubscription?.cancel();
    _periodicSync?.cancel();
  }
}

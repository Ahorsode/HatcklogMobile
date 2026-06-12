import 'package:connectivity_plus/connectivity_plus.dart';

class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  Future<bool> get isOnline async {
    final results = await _connectivity.checkConnectivity();
    return _hasNetwork(results);
  }

  Stream<bool> get onOnlineChanged {
    return _connectivity.onConnectivityChanged.map(_hasNetwork).distinct();
  }

  bool _hasNetwork(List<ConnectivityResult> results) {
    return results.any((result) => result != ConnectivityResult.none);
  }
}

import 'env_file_loader_stub.dart'
    if (dart.library.io) 'env_file_loader_io.dart';

Future<Map<String, String>> loadLocalEnvFile() {
  return loadLocalEnvFileImpl();
}

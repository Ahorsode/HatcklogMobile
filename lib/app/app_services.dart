import 'dart:async';

import '../core/connectivity/connectivity_service.dart';
import '../core/storage/local_database.dart';
import '../core/storage/secure_credential_store.dart';
import '../features/auth/data/auth_repository.dart';
import '../features/auth/data/supabase_remote_api.dart';
import '../features/management/data/management_repository.dart';
import '../features/sync/data/sync_repository.dart';
import '../features/sync/sync_engine_service.dart';
import '../features/sync/sync_runner.dart';
import '../services/encryption_service.dart';
import '../services/local_sales_queue.dart';
import '../services/pdf_invoice_service.dart';

class AppServices {
  AppServices({
    required this.authRepository,
    required this.connectivityService,
    required this.managementRepository,
    required this.syncRepository,
    required this.syncRunner,
    required this.encryptionService,
    required this.localSalesQueue,
    required this.pdfInvoiceService,
    required this.remoteApi,
    required this.localDatabase,
    required this.authRefreshSubscription,
  });

  final AuthRepository authRepository;
  final ConnectivityService connectivityService;
  final ManagementRepository managementRepository;
  final SyncRepository syncRepository;
  final SyncRunner syncRunner;
  final EncryptionService encryptionService;
  final LocalSalesQueue localSalesQueue;
  final PdfInvoiceService pdfInvoiceService;
  final SupabaseRemoteApi remoteApi;
  final LocalDatabase localDatabase;
  final StreamSubscription<bool> authRefreshSubscription;

  static Future<AppServices> bootstrap() async {
    final localDatabase = LocalDatabase();
    await localDatabase.initialize();

    final connectivityService = ConnectivityService();
    final initiallyOnline = await connectivityService.isOnline;
    final remoteApi = await SupabaseRemoteApi.fromEnvironment(
      autoRefreshToken: initiallyOnline,
    );
    remoteApi.setAutoRefreshEnabled(initiallyOnline);
    final authRefreshSubscription = connectivityService.onOnlineChanged.listen(
      remoteApi.setAutoRefreshEnabled,
    );
    final syncRepository = SyncRepository(
      localDatabase: localDatabase,
      remoteApi: remoteApi,
      syncEngineService: SyncEngineService(
        localDatabase: localDatabase,
        remoteApi: remoteApi,
      ),
    );
    final syncRunner = SyncRunner(
      connectivityService: connectivityService,
      syncRepository: syncRepository,
    )..start();
    final managementRepository = ManagementRepository(
      localDatabase: localDatabase,
      remoteApi: remoteApi,
    );

    final authRepository = AuthRepository(
      connectivityService: connectivityService,
      credentialStore: SecureCredentialStore(),
      localDatabase: localDatabase,
      remoteApi: remoteApi,
    );

    final encryptionService = EncryptionService();
    final deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
    final localSalesQueue = LocalSalesQueue(
      localDatabase: localDatabase,
      encryptionService: encryptionService,
      deviceId: deviceId,
    );
    final pdfService = PdfInvoiceService();

    return AppServices(
      authRepository: authRepository,
      connectivityService: connectivityService,
      managementRepository: managementRepository,
      syncRepository: syncRepository,
      syncRunner: syncRunner,
      encryptionService: encryptionService,
      localSalesQueue: localSalesQueue,
      pdfInvoiceService: pdfService,
      remoteApi: remoteApi,
      localDatabase: localDatabase,
      authRefreshSubscription: authRefreshSubscription,
    );
  }

  void dispose() {
    authRefreshSubscription.cancel();
    syncRunner.dispose();
  }
}

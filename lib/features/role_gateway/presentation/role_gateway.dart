import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../../../core/permissions/farm_permissions.dart';
import '../../../core/storage/local_database.dart';
import '../../../features/management/data/management_repository.dart';
import '../../../features/sync/data/worker_input_sink.dart';
import '../../../presentation/universal/universal_mobile_dashboard.dart';
import '../../../presentation/worker/worker_home_screen.dart';

class RoleGateway extends StatelessWidget {
  const RoleGateway({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.connectionChanges,
    required this.isOnline,
    required this.inputSink,
    required this.managementRepository,
    required this.localDatabase,
    required this.onSignOut,
    this.showSoftLockBanner = false,
    this.localSalesQueue,
    this.pdfInvoiceService,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final WorkerInputSink inputSink;
  final ManagementDataSource managementRepository;
  final LocalDatabase localDatabase;
  final Future<void> Function() onSignOut;
  final bool showSoftLockBanner;
  final dynamic localSalesQueue;
  final dynamic pdfInvoiceService;

  @override
  Widget build(BuildContext context) {
    final String userRole = currentUser.role.name.toLowerCase().trim();
    debugPrint('HatchLog Auth Engine: Authenticated user role is -> $userRole');

    if (currentUser.role == UserRole.worker) {
      debugPrint(
        'HatchLog Auth Engine: Worker access granted. Navigating to worker-first dashboard.',
      );
      return WorkerHomeScreen(
        currentUser: currentUser,
        permissions: permissions,
        connectionChanges: connectionChanges,
        isOnline: isOnline,
        inputSink: inputSink,
        localDatabase: localDatabase,
        onSignOut: onSignOut,
        showSoftLockBanner: showSoftLockBanner,
        localSalesQueue: localSalesQueue,
        pdfInvoiceService: pdfInvoiceService,
      );
    }

    return UniversalMobileDashboard(
      currentUser: currentUser,
      permissions: permissions,
      connectionChanges: connectionChanges,
      isOnline: isOnline,
      onSignOut: onSignOut,
      inputSink: inputSink,
      managementRepository: managementRepository,
      localDatabase: localDatabase,
      showSoftLockBanner: showSoftLockBanner,
      localSalesQueue: localSalesQueue,
      pdfInvoiceService: pdfInvoiceService,
    );
  }
}

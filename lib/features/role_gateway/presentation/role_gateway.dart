import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../../../features/management/data/management_repository.dart';
import '../../../features/sync/data/worker_input_sink.dart';
import '../../../presentation/universal/universal_mobile_dashboard.dart';

class RoleGateway extends StatelessWidget {
  const RoleGateway({
    super.key,
    required this.currentUser,
    required this.connectionChanges,
    required this.isOnline,
    required this.inputSink,
    required this.managementRepository,
    required this.onSignOut,
    this.localSalesQueue,
    this.pdfInvoiceService,
  });

  final AppUser currentUser;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final WorkerInputSink inputSink;
  final ManagementDataSource managementRepository;
  final Future<void> Function() onSignOut;
  final dynamic localSalesQueue;
  final dynamic pdfInvoiceService;

  @override
  Widget build(BuildContext context) {
    final String userRole = currentUser.role.name.toLowerCase().trim();
    debugPrint('HatchLog Auth Engine: Authenticated user role is -> $userRole');

    debugPrint(
      'HatchLog Auth Engine: Universal access granted. Navigating to shared mobile dashboard.',
    );

    return UniversalMobileDashboard(
      currentUser: currentUser,
      connectionChanges: connectionChanges,
      isOnline: isOnline,
      onSignOut: onSignOut,
      inputSink: inputSink,
      managementRepository: managementRepository,
      localSalesQueue: localSalesQueue,
      pdfInvoiceService: pdfInvoiceService,
    );
  }
}

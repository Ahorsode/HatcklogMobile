import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../services/executive_metrics_service.dart';
import '../dashboard/executive_dashboard_view.dart';

class ExecutiveDashboardScreen extends StatefulWidget {
  const ExecutiveDashboardScreen({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.executiveMetricsService,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final ExecutiveMetricsService executiveMetricsService;

  @override
  State<ExecutiveDashboardScreen> createState() =>
      _ExecutiveDashboardScreenState();
}

class _ExecutiveDashboardScreenState extends State<ExecutiveDashboardScreen> {
  late Future<ExecutiveDashboardSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _snapshotFuture = widget.executiveMetricsService.loadDashboard(
      farmId: widget.currentUser.activeFarmId,
      permissions: widget.permissions,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff4f6f8),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Executive Summary'),
      ),
      body: FutureBuilder<ExecutiveDashboardSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Text('Failed to load dashboard: ${snapshot.error}'),
            );
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: Text('No executive data available.'));
          }
          return ExecutiveDashboardView(
            displayName: widget.currentUser.displayName,
            activeFarmLabel: widget.currentUser.farmDisplayLabel,
            permissionsLoading: false,
            snapshot: data,
            permissions: widget.permissions,
          );
        },
      ),
    );
  }
}

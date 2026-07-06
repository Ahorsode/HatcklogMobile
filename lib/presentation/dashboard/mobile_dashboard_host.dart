import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../services/dashboard_stats_service.dart';
import '../../services/executive_metrics_service.dart';
import '../../utils/farm_display_name.dart';
import 'accountant_dashboard_view.dart';
import 'dashboard_type.dart';
import 'executive_dashboard_view.dart';
import 'farm_overview_dashboard_view.dart';
import 'worker_dashboard_view.dart';

typedef WorkerQuickAction = VoidCallback;

/// Routes the signed-in user to the same four dashboard experiences as web.
class MobileDashboardHost extends StatefulWidget {
  const MobileDashboardHost({
    super.key,
    required this.localDatabase,
    required this.dashboardStatsService,
    required this.executiveMetricsService,
    required this.permissions,
    required this.activeFarmId,
    required this.displayName,
    this.activeFarmNameFallback = '',
    required this.role,
    required this.permissionsLoading,
    this.permissionError,
    this.onLogFeed,
    this.onLogEggs,
    this.onLogMortality,
    this.onLogQuarantine,
    this.onLogHealth,
    this.onRefreshFromCloud,
  });

  final LocalDatabase localDatabase;
  final DashboardStatsService dashboardStatsService;
  final ExecutiveMetricsService executiveMetricsService;
  final FarmPermissions permissions;
  final String activeFarmId;
  final String displayName;
  final String activeFarmNameFallback;
  final UserRole role;
  final bool permissionsLoading;
  final Object? permissionError;
  final WorkerQuickAction? onLogFeed;
  final WorkerQuickAction? onLogEggs;
  final WorkerQuickAction? onLogMortality;
  final WorkerQuickAction? onLogQuarantine;
  final WorkerQuickAction? onLogHealth;
  final Future<void> Function()? onRefreshFromCloud;

  @override
  State<MobileDashboardHost> createState() => _MobileDashboardHostState();
}

class _MobileDashboardHostState extends State<MobileDashboardHost> {
  var _requestedCloudRefresh = false;

  Future<DashboardStatsSnapshot> _loadStatsSnapshot() {
    return widget.dashboardStatsService.loadStats(
      farmId: widget.activeFarmId,
      permissions: widget.permissions,
    );
  }

  Future<DashboardStatsSnapshot> _loadStatsWithCloudFallback() async {
    var stats = await _loadStatsSnapshot();
    if (stats.activeBatches.isNotEmpty ||
        _requestedCloudRefresh ||
        widget.onRefreshFromCloud == null) {
      return stats;
    }

    _requestedCloudRefresh = true;
    try {
      await widget.onRefreshFromCloud!();
      stats = await _loadStatsSnapshot();
    } on Object {
      // Keep the first snapshot if cloud refresh fails offline.
    }
    return stats;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: widget.localDatabase.watchTables(const ['farms', 'batches']),
      builder: (context, _) {
        return FutureBuilder<String?>(
          future: loadFarmSubscriptionTier(
            widget.localDatabase,
            widget.activeFarmId,
          ),
          builder: (context, tierSnapshot) {
            final dashboardType = resolveMobileDashboardType(
              role: widget.role,
              subscriptionTier: tierSnapshot.data,
            );

            return FutureBuilder<String>(
              future: resolveFarmDisplayLabel(
                widget.localDatabase,
                widget.activeFarmId,
                fallbackName: widget.activeFarmNameFallback,
              ),
              builder: (context, farmLabelSnapshot) {
                final activeFarmLabel =
                    farmLabelSnapshot.data ?? 'Active Farm Monitor';

                return StreamBuilder<void>(
              stream: widget.dashboardStatsService.watchStats(),
              builder: (context, _) {
                return FutureBuilder<DashboardStatsSnapshot>(
                  future: _loadStatsWithCloudFallback(),
                  builder: (context, statsSnapshot) {
                    if (dashboardType == MobileDashboardType.executive) {
                      return FutureBuilder<ExecutiveDashboardSnapshot>(
                        future: widget.executiveMetricsService.loadDashboard(
                          farmId: widget.activeFarmId,
                          permissions: widget.permissions,
                        ),
                        builder: (context, executiveSnapshot) {
                          if (executiveSnapshot.connectionState !=
                                  ConnectionState.done &&
                              !executiveSnapshot.hasData) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          if (executiveSnapshot.hasError) {
                            return Center(
                              child: Text(
                                'Failed to load executive dashboard: ${executiveSnapshot.error}',
                              ),
                            );
                          }
                          final executiveData = executiveSnapshot.data;
                          if (executiveData == null) {
                            return const Center(
                              child: Text('No executive data available.'),
                            );
                          }
                          return ExecutiveDashboardView(
                            displayName: widget.displayName,
                            activeFarmLabel: activeFarmLabel,
                            permissionsLoading: widget.permissionsLoading,
                            permissionError: widget.permissionError,
                            snapshot: executiveData,
                            permissions: widget.permissions,
                          );
                        },
                      );
                    }

                    if (statsSnapshot.connectionState !=
                            ConnectionState.done &&
                        !statsSnapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (statsSnapshot.hasError) {
                      return Center(
                        child: Text(
                          'Failed to load dashboard: ${statsSnapshot.error}',
                        ),
                      );
                    }
                    final stats = statsSnapshot.data;
                    if (stats == null) {
                      return const Center(
                        child: Text('No dashboard data available.'),
                      );
                    }

                    switch (dashboardType) {
                      case MobileDashboardType.worker:
                        return WorkerDashboardView(
                          displayName: widget.displayName,
                          activeFarmLabel: activeFarmLabel,
                          permissionsLoading: widget.permissionsLoading,
                          permissionError: widget.permissionError,
                          stats: stats,
                          permissions: widget.permissions,
                          onLogFeed: widget.onLogFeed,
                          onLogEggs: widget.onLogEggs,
                          onLogMortality: widget.onLogMortality,
                          onLogQuarantine: widget.onLogQuarantine,
                          onLogHealth: widget.onLogHealth,
                        );
                      case MobileDashboardType.accountant:
                        return AccountantDashboardView(
                          displayName: widget.displayName,
                          activeFarmLabel: activeFarmLabel,
                          permissionsLoading: widget.permissionsLoading,
                          permissionError: widget.permissionError,
                          stats: stats,
                        );
                      case MobileDashboardType.executive:
                        return const SizedBox.shrink();
                      case MobileDashboardType.farmOverview:
                        return FarmOverviewDashboardView(
                          displayName: widget.displayName,
                          activeFarmLabel: activeFarmLabel,
                          permissionsLoading: widget.permissionsLoading,
                          permissionError: widget.permissionError,
                          stats: stats,
                          permissions: widget.permissions,
                        );
                    }
                  },
                );
              },
            );
              },
            );
          },
        );
      },
    );
  }
}

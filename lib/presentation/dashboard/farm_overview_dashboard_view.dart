import 'package:flutter/material.dart';

import '../../core/permissions/farm_permissions.dart';
import '../../services/dashboard_stats_service.dart';
import 'dashboard_formatters.dart';
import 'dashboard_shared_widgets.dart';

class FarmOverviewDashboardView extends StatelessWidget {
  const FarmOverviewDashboardView({
    super.key,
    required this.displayName,
    required this.activeFarmLabel,
    required this.permissionsLoading,
    required this.stats,
    required this.permissions,
    this.permissionError,
  });

  final String displayName;
  final String activeFarmLabel;
  final bool permissionsLoading;
  final Object? permissionError;
  final DashboardStatsSnapshot stats;
  final FarmPermissions permissions;

  @override
  Widget build(BuildContext context) {
    if (stats.activeBatches.isEmpty && stats.totalBirds <= 0) {
      return _EmptyFarmOverview(
        displayName: displayName,
        activeFarmLabel: activeFarmLabel,
        permissionsLoading: permissionsLoading,
        permissionError: permissionError,
      );
    }

    final summary = stats.monthlySummary;
    final productivity = stats.activeBatches.isEmpty
        ? 0.0
        : stats.activeBatches
                  .map((b) => growthProgressPercent(b.hatchDate, b.breed))
                  .fold<double>(0, (sum, value) => sum + value) /
              stats.activeBatches.length;
    final crates = stats.totalEggs ~/ 30;
    final remainder = stats.totalEggs % 30;

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmLabel: activeFarmLabel,
          ),
          DashboardPermissionBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 18),
          const DashboardSectionHeader(
            title: 'Farm Overview',
            subtitle: 'Live operations tracking',
          ),
          const SizedBox(height: 12),
          if (permissions.canViewBatches)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Total Population',
                      style: TextStyle(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${stats.totalBirds}',
                      style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                        color: const Color(0xff1f7a4d),
                      ),
                    ),
                    const Text('Active Livestock'),
                    if (permissions.canViewMortality) ...[
                      const SizedBox(height: 12),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Mortality ${stats.mortalityRate.toStringAsFixed(1)}%',
                          ),
                          Text('Today: ${stats.todayDead}'),
                        ],
                      ),
                      DashboardMiniBarChart(
                        values: stats.mortalityTrendData
                            .map((point) => point.count)
                            .toList(),
                        color: const Color(0xffb83b3b),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.05,
            children: [
              if (permissions.canViewEggs) ...[
                DashboardKpiCard(
                  icon: Icons.egg_alt_outlined,
                  color: const Color(0xff2563eb),
                  metric: '${stats.todayEggs}',
                  label: 'Eggs Collected Today',
                ),
                DashboardKpiCard(
                  icon: Icons.inventory_2_outlined,
                  color: const Color(0xffc7851f),
                  metric: '$crates crates${remainder > 0 ? ' + $remainder' : ''}',
                  label: 'Egg Stock (${stats.totalEggs} eggs)',
                ),
              ],
              if (permissions.canViewFinance && summary != null)
                DashboardKpiCard(
                  icon: Icons.point_of_sale_outlined,
                  color: const Color(0xff16845c),
                  metric: formatDashboardMoney(summary.revenue),
                  label: '30d Revenue',
                ),
              if (permissions.canViewFinance && summary != null)
                DashboardKpiCard(
                  icon: Icons.account_balance_wallet_outlined,
                  color: const Color(0xff27364a),
                  metric: formatDashboardMoney(summary.revenue - summary.expenses),
                  label: '30d Net Income',
                ),
              if (permissions.canViewBatches)
                DashboardKpiCard(
                  icon: Icons.trending_up,
                  color: const Color(0xff6a4c93),
                  metric: '${productivity.toStringAsFixed(1)}%',
                  label: 'Productivity Index',
                ),
              DashboardKpiCard(
                icon: Icons.restaurant_outlined,
                color: const Color(0xff2563eb),
                metric: stats.weeklyFeedBags.toStringAsFixed(0),
                label: 'Weekly Feed (bags)',
              ),
            ],
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Resources & Consumption',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 8),
                  DashboardMiniBarChart(
                    values: stats.feedTrendData.map((p) => p.count).toList(),
                    color: const Color(0xff1f7a4d),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Daily feed breakdown (last 7 days)',
                    style: TextStyle(color: Color(0xff66736c), fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          DashboardAlertsPanel(
            alerts: stats.alerts,
            lowFeedItems: stats.lowFeedItems,
          ),
          if (stats.activeBatches.isNotEmpty) ...[
            const SizedBox(height: 18),
            DashboardActiveBatchesPanel(
              batches: stats.activeBatches,
              showGrowthProgress: true,
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyFarmOverview extends StatelessWidget {
  const _EmptyFarmOverview({
    required this.displayName,
    required this.activeFarmLabel,
    required this.permissionsLoading,
    this.permissionError,
  });

  final String displayName;
  final String activeFarmLabel;
  final bool permissionsLoading;
  final Object? permissionError;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmLabel: activeFarmLabel,
          ),
          DashboardPermissionBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 24),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.monitor_heart_outlined, size: 48),
                  const SizedBox(height: 12),
                  Text(
                    'Welcome to your Agri-ERP',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Add your first unit to begin tracking performance.',
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

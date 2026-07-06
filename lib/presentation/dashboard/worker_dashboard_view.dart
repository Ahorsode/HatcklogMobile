import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/permissions/farm_permissions.dart';
import '../../services/dashboard_stats_service.dart';
import 'dashboard_shared_widgets.dart';

typedef WorkerQuickAction = VoidCallback;

class WorkerDashboardView extends StatelessWidget {
  const WorkerDashboardView({
    super.key,
    required this.displayName,
    required this.activeFarmLabel,
    required this.permissionsLoading,
    required this.stats,
    required this.permissions,
    this.permissionError,
    this.onLogFeed,
    this.onLogEggs,
    this.onLogMortality,
    this.onLogQuarantine,
    this.onLogHealth,
    this.embedded = false,
  });

  final String displayName;
  final String activeFarmLabel;
  final bool permissionsLoading;
  final Object? permissionError;
  final DashboardStatsSnapshot stats;
  final FarmPermissions permissions;
  final WorkerQuickAction? onLogFeed;
  final WorkerQuickAction? onLogEggs;
  final WorkerQuickAction? onLogMortality;
  final WorkerQuickAction? onLogQuarantine;
  final WorkerQuickAction? onLogHealth;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    final content = _buildContent(context);
    if (embedded) {
      return content;
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: content,
    );
  }

  Widget _buildContent(BuildContext context) {
    final quickActions = <_QuickActionConfig>[
      if (permissions.canEditFeeding && onLogFeed != null)
        _QuickActionConfig(
          label: 'Log Feed',
          icon: Icons.grain,
          color: const Color(0xff1f7a4d),
          onTap: onLogFeed!,
        ),
      if (permissions.canEditEggs && onLogEggs != null)
        _QuickActionConfig(
          label: 'Log Eggs',
          icon: Icons.egg_alt_outlined,
          color: const Color(0xff2563eb),
          onTap: onLogEggs!,
        ),
      if (permissions.canEditMortality && onLogMortality != null)
        _QuickActionConfig(
          label: 'Mortality',
          icon: Icons.warning_amber_rounded,
          color: const Color(0xffb83b3b),
          onTap: onLogMortality!,
        ),
      if (permissions.canEditMortality && onLogQuarantine != null)
        _QuickActionConfig(
          label: 'Quarantine',
          icon: Icons.coronavirus_outlined,
          color: const Color(0xff6a4c93),
          onTap: onLogQuarantine!,
        ),
      if (permissions.canEditHealth && onLogHealth != null)
        _QuickActionConfig(
          label: 'Health',
          icon: Icons.vaccines_outlined,
          color: const Color(0xff2f7a6d),
          onTap: onLogHealth!,
        ),
    ];

    final cards = <Widget>[];
    if (permissions.canViewEggs) {
      cards.add(
        DashboardKpiCard(
          icon: Icons.egg_alt_outlined,
          color: const Color(0xffc7851f),
          metric: '${stats.todayEggs}',
          label: 'Eggs Collected Today',
        ),
      );
    }
    if (permissions.canViewFeeding) {
      cards.add(
        DashboardKpiCard(
          icon: Icons.inventory_2_outlined,
          color: const Color(0xff7a5c1f),
          metric: stats.todayFeedBags.toStringAsFixed(1),
          label: 'Feed Logged Today',
        ),
      );
    }
    if (permissions.canViewMortality) {
      cards.add(
        DashboardKpiCard(
          icon: Icons.warning_amber_rounded,
          color: const Color(0xffb83b3b),
          metric: '${stats.todayDead}',
          label: 'Mortality Today',
        ),
      );
    }
    cards.add(
      DashboardKpiCard(
        icon: Icons.pets_outlined,
        color: const Color(0xff2f5f8f),
        metric: '${stats.activeBatches.length}',
        label: 'Active Units',
      ),
    );

    return Column(
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
          title: 'Operational Hub',
          subtitle: 'Live task management',
        ),
        if (quickActions.isNotEmpty) ...[
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.15,
            children: [
              for (final action in quickActions)
                _WorkerQuickActionTile(action: action),
            ],
          ),
        ],
        const SizedBox(height: 18),
        if (cards.isNotEmpty)
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.08,
            children: cards,
          ),
        const SizedBox(height: 18),
        DashboardAlertsPanel(
          alerts: stats.alerts,
          lowFeedItems: stats.lowFeedItems,
        ),
        if (stats.activeBatches.isNotEmpty) ...[
          const SizedBox(height: 18),
          DashboardActiveBatchesPanel(batches: stats.activeBatches),
        ],
      ],
    );
  }
}

class _QuickActionConfig {
  const _QuickActionConfig({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
}

class _WorkerQuickActionTile extends StatelessWidget {
  const _WorkerQuickActionTile({required this.action});

  final _QuickActionConfig action;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: action.color.withValues(alpha: 0.08),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: action.color.withValues(alpha: 0.2)),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () {
          HapticFeedback.lightImpact();
          action.onTap();
        },
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(action.icon, color: action.color, size: 32),
            const SizedBox(height: 8),
            Text(
              action.label,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

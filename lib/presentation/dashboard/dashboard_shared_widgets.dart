import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/dashboard_stats_service.dart';
import '../../widgets/dynamic_details_dialog.dart';
import 'dashboard_formatters.dart';

class DashboardWelcomeBanner extends StatelessWidget {
  const DashboardWelcomeBanner({
    super.key,
    required this.displayName,
    required this.activeFarmLabel,
  });

  final String displayName;
  final String activeFarmLabel;

  @override
  Widget build(BuildContext context) {
    final name = displayName.trim().isEmpty ? 'HatchLog User' : displayName;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xff27364a),
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1a546570),
            blurRadius: 22,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.monitor_heart_outlined,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(height: 12),
          Text(
            'Hello, $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            activeFarmLabel.trim().isEmpty
                ? 'Active Farm Monitor'
                : activeFarmLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class DashboardPermissionBanner extends StatelessWidget {
  const DashboardPermissionBanner({
    super.key,
    required this.isLoading,
    this.error,
  });

  final bool isLoading;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (!isLoading && error == null) {
      return const SizedBox.shrink();
    }
    final hasError = error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hasError ? const Color(0xfffff4f4) : const Color(0xffeef6ff),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasError ? const Color(0xffffcccc) : const Color(0xffcfe6ff),
          ),
        ),
        child: Text(
          hasError
              ? 'Data Sync Interrupted: $error'
              : 'Loading permission matrix...',
          style: TextStyle(
            color: hasError ? const Color(0xff9f2626) : const Color(0xff25527a),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class DashboardKpiCard extends StatelessWidget {
  const DashboardKpiCard({
    super.key,
    required this.icon,
    required this.color,
    required this.metric,
    required this.label,
    this.isLoading = false,
  });

  final bool isLoading;
  final IconData icon;
  final Color color;
  final String metric;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: color.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withValues(alpha: 0.18)),
      ),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          showHatchLogDetailsPopup(context, {
            'metric': metric,
            'label': label,
            'isLoading': isLoading,
          }, '$label Details');
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 10),
              if (isLoading)
                const SizedBox.square(
                  dimension: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              else
                Text(
                  metric,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: const Color(0xff27364a),
                  ),
                ),
              const SizedBox(height: 6),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xff66736c),
                  fontWeight: FontWeight.w800,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DashboardAlertsPanel extends StatelessWidget {
  const DashboardAlertsPanel({
    super.key,
    required this.alerts,
    required this.lowFeedItems,
  });

  final List<DashboardAlert> alerts;
  final List<({String name, double stockLevel, String category})> lowFeedItems;

  @override
  Widget build(BuildContext context) {
    final hasAlerts = alerts.isNotEmpty || lowFeedItems.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Alerts & Reminders',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            if (!hasAlerts)
              const Text(
                'No urgent alerts.',
                style: TextStyle(color: Color(0xff66736c)),
              )
            else ...[
              for (final alert in alerts)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(_alertIcon(alert.type)),
                  title: Text(alert.title),
                  subtitle: Text(alert.message),
                ),
              for (final item in lowFeedItems)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.grain, color: Color(0xffb83b3b)),
                  title: Text('Low Stock: ${item.name}'),
                  subtitle: Text(
                    '${item.stockLevel.toStringAsFixed(0)} bags remaining',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _alertIcon(DashboardAlertType type) {
    switch (type) {
      case DashboardAlertType.vaccine:
        return Icons.vaccines_outlined;
      case DashboardAlertType.medication:
        return Icons.medical_services_outlined;
      case DashboardAlertType.eggs:
        return Icons.egg_alt_outlined;
      case DashboardAlertType.feed:
        return Icons.grain;
    }
  }
}

class DashboardActiveBatchesPanel extends StatelessWidget {
  const DashboardActiveBatchesPanel({
    super.key,
    required this.batches,
    this.showGrowthProgress = false,
  });

  final List<DashboardActiveBatch> batches;
  final bool showGrowthProgress;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              showGrowthProgress
                  ? 'Active Livestock Units'
                  : 'Unit Health Overview',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            for (final batch in batches)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _BatchTile(batch: batch, showGrowth: showGrowthProgress),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  const _BatchTile({required this.batch, required this.showGrowth});

  final DashboardActiveBatch batch;
  final bool showGrowth;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      title: Text(batch.batchName ?? batch.id),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${batch.houseNumber} • ${batch.breed} • ${batch.quantity} birds',
          ),
          if (showGrowth) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value:
                  growthProgressPercent(batch.hatchDate, batch.breed) / 100,
              backgroundColor: const Color(0xffe1e7e3),
              color: const Color(0xff1f7a4d),
            ),
          ],
        ],
      ),
      trailing: Text(
        batch.hatchDate.toLocal().toString().split(' ').first,
        style: const TextStyle(fontSize: 11),
      ),
    );
  }
}

class DashboardMiniBarChart extends StatelessWidget {
  const DashboardMiniBarChart({
    super.key,
    required this.values,
    required this.color,
    this.height = 48,
  });

  final List<double> values;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (values.isEmpty) {
      return SizedBox(height: height);
    }
    final max = values.fold<double>(0, (current, value) => value > current ? value : current);
    final safeMax = max <= 0 ? 1.0 : max;
    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final value in values)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: FractionallySizedBox(
                  heightFactor: (value / safeMax).clamp(0.04, 1.0),
                  alignment: Alignment.bottomCenter,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.85),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DashboardSectionHeader extends StatelessWidget {
  const DashboardSectionHeader({
    super.key,
    required this.title,
    this.subtitle,
  });

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: const Color(0xff27364a),
            fontWeight: FontWeight.w900,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: const TextStyle(
              color: Color(0xff66736c),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}

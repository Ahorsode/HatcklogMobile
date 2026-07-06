import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/permissions/farm_permissions.dart';
import '../../services/executive_metrics_service.dart';
import 'dashboard_formatters.dart';
import 'dashboard_shared_widgets.dart';

class ExecutiveDashboardView extends StatelessWidget {
  const ExecutiveDashboardView({
    super.key,
    required this.displayName,
    required this.activeFarmLabel,
    required this.permissionsLoading,
    required this.snapshot,
    required this.permissions,
    this.permissionError,
    this.currency = 'GHS',
  });

  final String displayName;
  final String activeFarmLabel;
  final bool permissionsLoading;
  final Object? permissionError;
  final ExecutiveDashboardSnapshot snapshot;
  final FarmPermissions permissions;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final stats = snapshot.executiveStats;
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
            title: 'Executive Summary',
            subtitle: 'Global performance and financial health',
          ),
          const SizedBox(height: 12),
          if (permissions.canViewFinance) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _ExecutiveMetricCard(
                  label: '7d Profit',
                  value: formatDashboardMoney(stats.totalProfit, currency: currency),
                  subtitle:
                      '${stats.profitTrend.toStringAsFixed(1)}% vs prior week',
                ),
                _ExecutiveMetricCard(
                  label: 'Total Debt',
                  value: formatDashboardMoney(stats.totalDebt, currency: currency),
                  subtitle:
                      'Suppliers ${formatDashboardMoney(stats.supplierDebt, currency: currency)} | Customers ${formatDashboardMoney(stats.customerDebt, currency: currency)}',
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (permissions.canViewBatches)
                _ExecutiveMetricCard(
                  label: 'Global FCR',
                  value: stats.globalFcr.toStringAsFixed(2),
                  subtitle: 'Active birds ${stats.activeLivestock}',
                ),
              _ExecutiveMetricCard(
                label: 'Mortality Rate',
                value: '${stats.mortalityRate.toStringAsFixed(1)}%',
                subtitle: 'Since batch start',
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'Strategic Priorities',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          if (snapshot.strategicPriorities.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'All clear — no urgent supplier, inventory, or performance issues detected.',
                ),
              ),
            )
          else
            for (final priority in snapshot.strategicPriorities)
              Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(priority.title),
                  subtitle: Text(priority.detail),
                  leading: Icon(_priorityIcon(priority.type)),
                ),
              ),
          if (permissions.canViewFinance) ...[
            const SizedBox(height: 24),
            Text(
              'Revenue Velocity (7d)',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            if (snapshot.revenueVelocityData.every((point) => point.revenue <= 0))
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'No finance activity recorded in the last 7 days.',
                  ),
                ),
              )
            else
              SizedBox(
                height: 220,
                child: _RevenueVelocityChart(
                  points: snapshot.revenueVelocityData,
                ),
              ),
          ],
        ],
      ),
    );
  }

  IconData _priorityIcon(StrategicPriorityType type) {
    switch (type) {
      case StrategicPriorityType.finance:
        return Icons.payments_outlined;
      case StrategicPriorityType.stock:
        return Icons.inventory_2_outlined;
      case StrategicPriorityType.performance:
        return Icons.trending_down;
    }
  }
}

class _ExecutiveMetricCard extends StatelessWidget {
  const _ExecutiveMetricCard({
    required this.label,
    required this.value,
    required this.subtitle,
  });

  final String label;
  final String value;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 170,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.labelLarge),
              const SizedBox(height: 8),
              Text(
                value,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _RevenueVelocityChart extends StatelessWidget {
  const _RevenueVelocityChart({required this.points});

  final List<RevenueVelocityPoint> points;

  @override
  Widget build(BuildContext context) {
    final maxRevenue = points.fold<double>(
      0,
      (max, point) => math.max(max, point.revenue),
    );
    final maxTarget = points.fold<double>(
      0,
      (max, point) => math.max(max, point.target),
    );
    final maxY = math.max(maxRevenue, maxTarget) * 1.2;
    final safeMaxY = maxY <= 0 ? 1.0 : maxY;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
        child: BarChart(
          BarChartData(
            maxY: safeMaxY,
            gridData: const FlGridData(show: false),
            borderData: FlBorderData(show: false),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(),
              rightTitles: const AxisTitles(),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 36,
                  getTitlesWidget: (value, meta) => Text(
                    value.toInt().toString(),
                    style: const TextStyle(fontSize: 10),
                  ),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  getTitlesWidget: (value, meta) {
                    final index = value.toInt();
                    if (index < 0 || index >= points.length) {
                      return const SizedBox.shrink();
                    }
                    final day = points[index].date;
                    return Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        day.length >= 5 ? day.substring(5) : day,
                        style: const TextStyle(fontSize: 10),
                      ),
                    );
                  },
                ),
              ),
            ),
            barGroups: [
              for (var i = 0; i < points.length; i++)
                BarChartGroupData(
                  x: i,
                  barRods: [
                    BarChartRodData(
                      toY: points[i].revenue,
                      color: const Color(0xff2f6fed),
                      width: 14,
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ],
                ),
            ],
            extraLinesData: ExtraLinesData(
              horizontalLines: points.isEmpty
                  ? []
                  : [
                      HorizontalLine(
                        y: points.first.target,
                        color: const Color(0xffe67e22),
                        strokeWidth: 2,
                        dashArray: [6, 4],
                      ),
                    ],
            ),
          ),
        ),
      ),
    );
  }
}

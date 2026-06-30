import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../services/executive_metrics_service.dart';

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
            return Center(child: Text('Failed to load dashboard: ${snapshot.error}'));
          }
          final data = snapshot.data;
          if (data == null) {
            return const Center(child: Text('No executive data available.'));
          }
          return _ExecutiveContent(snapshot: data, permissions: widget.permissions);
        },
      ),
    );
  }
}

class _ExecutiveContent extends StatelessWidget {
  const _ExecutiveContent({
    required this.snapshot,
    required this.permissions,
  });

  final ExecutiveDashboardSnapshot snapshot;
  final FarmPermissions permissions;

  @override
  Widget build(BuildContext context) {
    final stats = snapshot.executiveStats;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (permissions.canViewFinance) ...[
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _MetricCard(
                  label: '7d Profit',
                  value: stats.totalProfit.toStringAsFixed(0),
                  subtitle: '${stats.profitTrend.toStringAsFixed(1)}% vs prior week',
                ),
                _MetricCard(
                  label: 'Total Debt',
                  value: stats.totalDebt.toStringAsFixed(0),
                  subtitle:
                      'Suppliers ${stats.supplierDebt.toStringAsFixed(0)} | Customers ${stats.customerDebt.toStringAsFixed(0)}',
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              if (permissions.canViewBatches)
                _MetricCard(
                  label: 'Global FCR',
                  value: stats.globalFcr.toStringAsFixed(2),
                  subtitle: 'Active birds ${stats.activeLivestock}',
                ),
              _MetricCard(
                label: 'Mortality Rate',
                value: '${(stats.mortalityRate * 100).toStringAsFixed(1)}%',
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
            const _EmptyPanel(message: 'No strategic priorities flagged right now.')
          else
            ...snapshot.strategicPriorities.map(
              (priority) => Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  title: Text(priority.title),
                  subtitle: Text(priority.detail),
                  leading: Icon(_priorityIcon(priority.type)),
                ),
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
              const _EmptyPanel(
                message: 'No finance activity recorded in the last 7 days.',
              )
            else
              SizedBox(
                height: 220,
                child: _RevenueVelocityChart(points: snapshot.revenueVelocityData),
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

class _MetricCard extends StatelessWidget {
  const _MetricCard({
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
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(message),
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

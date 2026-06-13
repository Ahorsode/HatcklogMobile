import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/models/app_user.dart';
import '../../features/management/data/management_repository.dart';
import 'analytics_models.dart';

class FarmAnalyticsScreen extends StatefulWidget {
  const FarmAnalyticsScreen({
    super.key,
    required this.currentUser,
    required this.managementRepository,
  });

  final AppUser currentUser;
  final ManagementDataSource managementRepository;

  @override
  State<FarmAnalyticsScreen> createState() => _FarmAnalyticsScreenState();
}

class _FarmAnalyticsScreenState extends State<FarmAnalyticsScreen> {
  late Future<FarmAnalyticsSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = widget.managementRepository.loadAnalytics(
      widget.currentUser,
    );
  }

  void _retry() {
    setState(() {
      _snapshotFuture = widget.managementRepository.loadAnalytics(
        widget.currentUser,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _AnalyticsColors.background,
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Farm Analytics'),
      ),
      body: FutureBuilder<FarmAnalyticsSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const _AnalyticsSkeleton();
          }
          if (snapshot.hasError) {
            return _AnalyticsError(error: snapshot.error, onRetry: _retry);
          }
          final data = snapshot.data;
          if (data == null) {
            return const _AnalyticsEmpty();
          }
          return _AnalyticsContent(snapshot: data);
        },
      ),
    );
  }
}

class _AnalyticsContent extends StatelessWidget {
  const _AnalyticsContent({required this.snapshot});

  final FarmAnalyticsSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.55,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _KpiCard(
                label: 'Peak Egg Day',
                value: '${snapshot.peakEggDay}',
                icon: Icons.egg_alt_outlined,
              ),
              _KpiCard(
                label: 'Avg Daily Mortality',
                value: snapshot.avgDailyMortality.toStringAsFixed(1),
                icon: Icons.warning_amber_rounded,
                accent: _AnalyticsColors.red,
              ),
              _KpiCard(
                label: 'Feed Used (7d)',
                value: snapshot.totalFeedUsed7d.toStringAsFixed(1),
                suffix: 'sacks',
                icon: Icons.inventory_2_outlined,
              ),
              _KpiCard(
                label: 'Net Profit (14d)',
                value: _money(snapshot.netProfit14d),
                icon: Icons.account_balance_wallet_outlined,
                accent: snapshot.netProfit14d >= 0
                    ? _AnalyticsColors.green
                    : _AnalyticsColors.red,
              ),
            ],
          ),
          const SizedBox(height: 20),
          _ChartSection(
            title: 'Egg Production - Last 7 Days',
            child: _EggProductionChart(points: snapshot.eggProduction7d),
          ),
          _ChartSection(
            title: 'Bird Losses - Last 7 Days',
            child: _MortalityChart(
              points: snapshot.mortality7d,
              average: snapshot.avgDailyMortality,
            ),
          ),
          _ChartSection(
            title: 'Feed Consumption - Last 7 Days',
            child: _FeedUsageChart(points: snapshot.feedUsage7d),
          ),
          _ChartSection(
            title: 'Revenue vs Expenses - Last 14 Days',
            child: _RevenueExpenseChart(
              revenue: snapshot.revenue14d,
              expenses: snapshot.expenses14d,
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiCard extends StatelessWidget {
  const _KpiCard({
    required this.label,
    required this.value,
    required this.icon,
    this.suffix = '',
    this.accent = _AnalyticsColors.green,
  });

  final String label;
  final String value;
  final String suffix;
  final IconData icon;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xffe4e9ed)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(icon, color: accent, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: _AnalyticsColors.muted,
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      color: accent,
                      fontWeight: FontWeight.w900,
                      fontSize: 23,
                      letterSpacing: 0,
                    ),
                  ),
                  if (suffix.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        suffix,
                        style: const TextStyle(
                          color: _AnalyticsColors.muted,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartSection extends StatelessWidget {
  const _ChartSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: _AnalyticsColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 10),
          Card(
            elevation: 0,
            color: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: const BorderSide(color: Color(0xffe4e9ed)),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 16, 14, 8),
              child: SizedBox(height: 200, child: child),
            ),
          ),
        ],
      ),
    );
  }
}

class _EggProductionChart extends StatelessWidget {
  const _EggProductionChart({required this.points});

  final List<DailyDataPoint> points;

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: _maxX(points),
        minY: 0,
        maxY: _lineMaxY(points),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
        titlesData: _titlesData(points),
        lineBarsData: [
          LineChartBarData(
            spots: _spots(points),
            isCurved: true,
            color: _AnalyticsColors.green,
            barWidth: 3,
            dotData: const FlDotData(show: true),
          ),
        ],
      ),
    );
  }
}

class _MortalityChart extends StatelessWidget {
  const _MortalityChart({required this.points, required this.average});

  final List<DailyDataPoint> points;
  final double average;

  @override
  Widget build(BuildContext context) {
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: math.max(_barMaxY(points), average * 1.35),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
        titlesData: _titlesData(points),
        barGroups: [
          for (var i = 0; i < points.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: points[i].value,
                  width: 14,
                  color: _AnalyticsColors.red,
                  borderRadius: BorderRadius.circular(4),
                ),
              ],
            ),
        ],
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: average,
              color: _AnalyticsColors.red.withValues(alpha: 0.55),
              strokeWidth: 2,
              dashArray: [6, 4],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeedUsageChart extends StatelessWidget {
  const _FeedUsageChart({required this.points});

  final List<DailyDataPoint> points;

  @override
  Widget build(BuildContext context) {
    return LineChart(
      LineChartData(
        minX: 0,
        maxX: _maxX(points),
        minY: 0,
        maxY: _lineMaxY(points),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
        titlesData: _titlesData(points),
        lineBarsData: [
          LineChartBarData(
            spots: _spots(points),
            isCurved: true,
            color: _AnalyticsColors.green,
            barWidth: 3,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  _AnalyticsColors.green.withValues(alpha: 0.30),
                  _AnalyticsColors.green.withValues(alpha: 0.02),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RevenueExpenseChart extends StatelessWidget {
  const _RevenueExpenseChart({required this.revenue, required this.expenses});

  final List<DailyDataPoint> revenue;
  final List<DailyDataPoint> expenses;

  @override
  Widget build(BuildContext context) {
    final maxValue = math.max(_barMaxY(revenue), _barMaxY(expenses));
    return BarChart(
      BarChartData(
        minY: 0,
        maxY: math.max(1, maxValue),
        gridData: const FlGridData(show: true),
        borderData: FlBorderData(show: false),
        titlesData: _titlesData(revenue, showEveryOtherBottomLabel: true),
        barGroups: [
          for (var i = 0; i < revenue.length; i++)
            BarChartGroupData(
              x: i,
              barsSpace: 3,
              barRods: [
                BarChartRodData(
                  toY: revenue[i].value,
                  width: 7,
                  color: _AnalyticsColors.green,
                  borderRadius: BorderRadius.circular(3),
                ),
                BarChartRodData(
                  toY: i < expenses.length ? expenses[i].value : 0,
                  width: 7,
                  color: _AnalyticsColors.red,
                  borderRadius: BorderRadius.circular(3),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _AnalyticsSkeleton extends StatelessWidget {
  const _AnalyticsSkeleton();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: const Color(0xffe9edf0),
      highlightColor: Colors.white,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            childAspectRatio: 1.55,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (var i = 0; i < 4; i++)
                Container(
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          for (var i = 0; i < 4; i++) ...[
            Container(height: 22, width: 220, color: Colors.white),
            const SizedBox(height: 10),
            Container(
              height: 224,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }
}

class _AnalyticsError extends StatelessWidget {
  const _AnalyticsError({required this.error, required this.onRetry});

  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.error_outline,
              color: _AnalyticsColors.red,
              size: 42,
            ),
            const SizedBox(height: 12),
            const Text(
              'Analytics could not be loaded.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: _AnalyticsColors.ink,
                fontWeight: FontWeight.w900,
                fontSize: 17,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error?.toString() ?? 'Unknown error',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: _AnalyticsColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 14),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _AnalyticsEmpty extends StatelessWidget {
  const _AnalyticsEmpty();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'No analytics data is available yet.',
        style: TextStyle(
          color: _AnalyticsColors.muted,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

FlTitlesData _titlesData(
  List<DailyDataPoint> points, {
  bool showEveryOtherBottomLabel = false,
}) {
  return FlTitlesData(
    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
    leftTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 42,
        getTitlesWidget: (value, meta) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Text(
            _axisNumber(value),
            style: const TextStyle(
              color: _AnalyticsColors.muted,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    ),
    bottomTitles: AxisTitles(
      sideTitles: SideTitles(
        showTitles: true,
        reservedSize: 28,
        getTitlesWidget: (value, meta) {
          final index = value.round();
          if (index < 0 || index >= points.length) {
            return const SizedBox.shrink();
          }
          if (showEveryOtherBottomLabel && index.isOdd) {
            return const SizedBox.shrink();
          }
          return Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _weekday(points[index].date),
              style: const TextStyle(
                color: _AnalyticsColors.muted,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          );
        },
      ),
    ),
  );
}

List<FlSpot> _spots(List<DailyDataPoint> points) {
  return [
    for (var i = 0; i < points.length; i++)
      FlSpot(i.toDouble(), points[i].value),
  ];
}

double _maxX(List<DailyDataPoint> points) {
  return math.max(0, points.length - 1).toDouble();
}

double _lineMaxY(List<DailyDataPoint> points) {
  return math.max(1, _maxPointValue(points) * 1.25);
}

double _barMaxY(List<DailyDataPoint> points) {
  return math.max(1, _maxPointValue(points) * 1.25);
}

double _maxPointValue(List<DailyDataPoint> points) {
  return points.fold(0.0, (maxValue, point) {
    return point.value > maxValue ? point.value : maxValue;
  });
}

String _weekday(DateTime date) {
  const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  return labels[date.weekday - 1];
}

String _axisNumber(double value) {
  if (value >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}m';
  }
  if (value >= 1000) {
    return '${(value / 1000).toStringAsFixed(1)}k';
  }
  if (value == value.roundToDouble()) {
    return value.round().toString();
  }
  return value.toStringAsFixed(1);
}

String _money(double value) {
  final sign = value < 0 ? '-' : '';
  return '${sign}GHS ${value.abs().toStringAsFixed(2)}';
}

class _AnalyticsColors {
  static const background = Color(0xfff7f9fb);
  static const ink = Color(0xff172130);
  static const muted = Color(0xff667085);
  static const green = Color(0xff145f3b);
  static const red = Color(0xffb83b3b);
}

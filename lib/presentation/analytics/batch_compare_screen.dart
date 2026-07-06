import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/permissions/navigation_permissions.dart';
import '../../core/permissions/staff_permission_defaults.dart';
import '../../core/storage/local_database.dart';
import '../../services/batch_analytics_service.dart';

enum CompareMetricKey {
  netProfit,
  revenue,
  expenses,
  eggs,
  fcr,
  mortalityRate,
}

class _MetricDef {
  const _MetricDef({
    required this.label,
    required this.short,
    required this.accessor,
    required this.format,
    this.lowerIsBetter = false,
    this.finance = false,
    this.benchmark,
  });

  final String label;
  final String short;
  final double Function(BatchPerformanceReport batch) accessor;
  final String Function(double value) format;
  final bool lowerIsBetter;
  final bool finance;
  final double? benchmark;
}

const _palette = [
  Color(0xff34d399),
  Color(0xff38bdf8),
  Color(0xfffbbf24),
  Color(0xffa78bfa),
  Color(0xfff472b6),
  Color(0xff22d3ee),
];

class BatchCompareScreen extends StatefulWidget {
  const BatchCompareScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    required this.permissions,
    this.navigationRole,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final FarmPermissions permissions;
  final String? navigationRole;

  @override
  State<BatchCompareScreen> createState() => _BatchCompareScreenState();
}

class _BatchCompareScreenState extends State<BatchCompareScreen> {
  late Future<BatchPerformancePayload> _payloadFuture;
  final Set<String> _selectedBatchIds = {};
  final Set<String> _hiddenBatchIds = {};
  CompareMetricKey _selectedMetric = CompareMetricKey.fcr;
  bool _showBenchmark = true;

  bool get _canAccess => canShowNavigationItem(
        name: 'Analytics',
        role: widget.navigationRole ?? widget.currentUser.role.apiRole,
        roles: assignableStaffRoles,
        permissions: widget.permissions,
      );

  Map<CompareMetricKey, _MetricDef> _metrics(bool canViewFinance) {
    return {
      CompareMetricKey.netProfit: _MetricDef(
        label: 'Net Profitability',
        short: 'Profit',
        accessor: (b) => b.netProfitability,
        format: _money,
        finance: true,
      ),
      CompareMetricKey.revenue: _MetricDef(
        label: 'Total Revenue',
        short: 'Revenue',
        accessor: (b) => b.totalRevenue,
        format: _money,
        finance: true,
      ),
      CompareMetricKey.expenses: _MetricDef(
        label: 'Total Expenses',
        short: 'Expenses',
        accessor: (b) => b.totalExpenses,
        format: _money,
        lowerIsBetter: true,
        finance: true,
      ),
      CompareMetricKey.eggs: _MetricDef(
        label: 'Eggs Collected',
        short: 'Eggs',
        accessor: (b) => b.totalEggs.toDouble(),
        format: (v) => '${v.round()} eggs',
      ),
      CompareMetricKey.fcr: _MetricDef(
        label: 'Feed Conversion Ratio',
        short: 'FCR',
        accessor: (b) => b.fcr,
        format: (v) => v.toStringAsFixed(2),
        lowerIsBetter: true,
        benchmark: 1.6,
      ),
      CompareMetricKey.mortalityRate: _MetricDef(
        label: 'Mortality Rate',
        short: 'Mortality',
        accessor: (b) => b.mortalityRate,
        format: (v) => '${v.toStringAsFixed(2)}%',
        lowerIsBetter: true,
        benchmark: 3.5,
      ),
    };
  }

  @override
  void initState() {
    super.initState();
    _reload();
  }

  void _reload() {
    _payloadFuture = BatchAnalyticsService(widget.localDatabase).loadReports(
      farmId: widget.currentUser.activeFarmId,
      permissions: widget.permissions,
    );
  }

  void _ensureSelection(List<BatchPerformanceReport> batches) {
    if (_selectedBatchIds.isNotEmpty || batches.isEmpty) return;
    for (final batch in batches.take(4)) {
      _selectedBatchIds.add(batch.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_canAccess) {
      return Scaffold(
        appBar: AppBar(title: const Text('Compare Batches')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Batch view permission is required to access comparative analytics.',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xfff7f9fb),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Compare Batches'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: () => setState(_reload),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<BatchPerformancePayload>(
        future: _payloadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load analytics: ${snapshot.error}'));
          }
          final payload = snapshot.data;
          if (payload == null || payload.batches.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No batch data yet. Add livestock batches and start logging feed, eggs, and finance.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }

          _ensureSelection(payload.batches);
          return _CompareContent(
            payload: payload,
            selectedBatchIds: _selectedBatchIds,
            hiddenBatchIds: _hiddenBatchIds,
            selectedMetric: _selectedMetric,
            showBenchmark: _showBenchmark,
            metrics: _metrics(payload.canViewFinance),
            onToggleBatch: (id) {
              setState(() {
                if (_selectedBatchIds.contains(id)) {
                  _selectedBatchIds.remove(id);
                  _hiddenBatchIds.remove(id);
                } else {
                  _selectedBatchIds.add(id);
                }
              });
            },
            onToggleHidden: (id) {
              setState(() {
                if (_hiddenBatchIds.contains(id)) {
                  _hiddenBatchIds.remove(id);
                } else {
                  _hiddenBatchIds.add(id);
                }
              });
            },
            onMetricChanged: (metric) => setState(() => _selectedMetric = metric),
            onBenchmarkChanged: (value) => setState(() => _showBenchmark = value),
          );
        },
      ),
    );
  }
}

class _CompareContent extends StatelessWidget {
  const _CompareContent({
    required this.payload,
    required this.selectedBatchIds,
    required this.hiddenBatchIds,
    required this.selectedMetric,
    required this.showBenchmark,
    required this.metrics,
    required this.onToggleBatch,
    required this.onToggleHidden,
    required this.onMetricChanged,
    required this.onBenchmarkChanged,
  });

  final BatchPerformancePayload payload;
  final Set<String> selectedBatchIds;
  final Set<String> hiddenBatchIds;
  final CompareMetricKey selectedMetric;
  final bool showBenchmark;
  final Map<CompareMetricKey, _MetricDef> metrics;
  final ValueChanged<String> onToggleBatch;
  final ValueChanged<String> onToggleHidden;
  final ValueChanged<CompareMetricKey> onMetricChanged;
  final ValueChanged<bool> onBenchmarkChanged;

  List<CompareMetricKey> get _availableMetrics => metrics.entries
      .where((entry) => payload.canViewFinance || !entry.value.finance)
      .map((entry) => entry.key)
      .toList();

  List<BatchPerformanceReport> get _activeBatches => payload.batches
      .where(
        (batch) =>
            selectedBatchIds.contains(batch.id) && !hiddenBatchIds.contains(batch.id),
      )
      .toList();

  BatchPerformanceReport? get _leader {
    final active = _activeBatches;
    if (active.isEmpty) return null;
    final sorted = [...active]..sort((a, b) {
        if (payload.canViewFinance) {
          return b.netProfitability.compareTo(a.netProfitability);
        }
        return b.totalEggs.compareTo(a.totalEggs);
      });
    return sorted.first;
  }

  @override
  Widget build(BuildContext context) {
    final metric = metrics[selectedMetric]!;
    final leader = _leader;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
      children: [
        if (leader != null) _LeaderCard(leader: leader, canViewFinance: payload.canViewFinance),
        const SizedBox(height: 16),
        _BatchSelector(
          batches: payload.batches,
          selectedBatchIds: selectedBatchIds,
          hiddenBatchIds: hiddenBatchIds,
          onToggleBatch: onToggleBatch,
          onToggleHidden: onToggleHidden,
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final key in _availableMetrics)
              ChoiceChip(
                label: Text(metrics[key]!.short),
                selected: selectedMetric == key,
                onSelected: (_) => onMetricChanged(key),
              ),
          ],
        ),
        if (metric.benchmark != null) ...[
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Industry benchmark'),
            value: showBenchmark,
            onChanged: onBenchmarkChanged,
          ),
        ],
        const SizedBox(height: 12),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.label,
                  style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 220,
                  child: _activeBatches.isEmpty
                      ? const Center(child: Text('Select batches to compare.'))
                      : _MetricBarChart(
                          batches: _activeBatches,
                          metric: metric,
                          showBenchmark: showBenchmark && metric.benchmark != null,
                        ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        ..._activeBatches.map(
          (batch) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _BatchDetailCard(batch: batch, canViewFinance: payload.canViewFinance),
          ),
        ),
      ],
    );
  }
}

class _LeaderCard extends StatelessWidget {
  const _LeaderCard({required this.leader, required this.canViewFinance});

  final BatchPerformanceReport leader;
  final bool canViewFinance;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: const Color(0xff145f3b),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Performance Leader',
              style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              leader.name,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w900,
                fontSize: 22,
              ),
            ),
            Text(
              '${leader.houseName} • ${leader.type.replaceAll('_', ' ')}',
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                if (canViewFinance)
                  _LeaderStat(label: 'Net Profit', value: _money(leader.netProfitability)),
                _LeaderStat(label: 'Eggs', value: '${leader.totalEggs}'),
                _LeaderStat(label: 'FCR', value: leader.fcr.toStringAsFixed(2)),
                _LeaderStat(label: 'Mortality', value: '${leader.mortalityRate.toStringAsFixed(1)}%'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _LeaderStat extends StatelessWidget {
  const _LeaderStat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
          Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900)),
        ],
      ),
    );
  }
}

class _BatchSelector extends StatelessWidget {
  const _BatchSelector({
    required this.batches,
    required this.selectedBatchIds,
    required this.hiddenBatchIds,
    required this.onToggleBatch,
    required this.onToggleHidden,
  });

  final List<BatchPerformanceReport> batches;
  final Set<String> selectedBatchIds;
  final Set<String> hiddenBatchIds;
  final ValueChanged<String> onToggleBatch;
  final ValueChanged<String> onToggleHidden;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Select batches', style: TextStyle(fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            ...batches.map((batch) {
              final selected = selectedBatchIds.contains(batch.id);
              final hidden = hiddenBatchIds.contains(batch.id);
              return CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: selected,
                onChanged: (_) => onToggleBatch(batch.id),
                title: Text(batch.name, overflow: TextOverflow.ellipsis),
                subtitle: Text('${batch.houseName} • ${batch.status}'),
                secondary: selected
                    ? IconButton(
                        tooltip: hidden ? 'Show in charts' : 'Hide from charts',
                        onPressed: () => onToggleHidden(batch.id),
                        icon: Icon(hidden ? Icons.visibility_off : Icons.visibility),
                      )
                    : null,
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _MetricBarChart extends StatelessWidget {
  const _MetricBarChart({
    required this.batches,
    required this.metric,
    required this.showBenchmark,
  });

  final List<BatchPerformanceReport> batches;
  final _MetricDef metric;
  final bool showBenchmark;

  @override
  Widget build(BuildContext context) {
    final values = batches.map(metric.accessor).toList();
    final maxValue = values.fold<double>(0, math.max);
    final benchmark = metric.benchmark ?? 0;
    final chartMax = math.max(maxValue, showBenchmark ? benchmark : 0) * 1.2;
    final safeMax = chartMax <= 0 ? 1.0 : chartMax;

    return BarChart(
      BarChartData(
        maxY: safeMax,
        gridData: const FlGridData(show: true, drawVerticalLine: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 42,
              getTitlesWidget: (value, meta) => Text(
                metric.finance ? _compactMoney(value) : value.toStringAsFixed(1),
                style: const TextStyle(fontSize: 10),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 36,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= batches.length) {
                  return const SizedBox.shrink();
                }
                final name = batches[index].name;
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    name.length > 8 ? '${name.substring(0, 7)}…' : name,
                    style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
                  ),
                );
              },
            ),
          ),
        ),
        extraLinesData: showBenchmark && metric.benchmark != null
            ? ExtraLinesData(
                horizontalLines: [
                  HorizontalLine(
                    y: metric.benchmark!,
                    color: const Color(0xff38bdf8),
                    strokeWidth: 2,
                    dashArray: [6, 4],
                  ),
                ],
              )
            : null,
        barGroups: [
          for (var i = 0; i < batches.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: values[i],
                  width: 18,
                  color: _palette[i % _palette.length],
                  borderRadius: BorderRadius.circular(6),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _BatchDetailCard extends StatelessWidget {
  const _BatchDetailCard({required this.batch, required this.canViewFinance});

  final BatchPerformanceReport batch;
  final bool canViewFinance;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(batch.name, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            Text('${batch.houseName} • ${batch.type.replaceAll('_', ' ')}'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                _DetailStat(label: 'FCR', value: batch.fcr.toStringAsFixed(2)),
                _DetailStat(
                  label: 'Mortality',
                  value: '${batch.mortalityRate.toStringAsFixed(1)}%',
                  danger: batch.mortalityRate > 5,
                ),
                _DetailStat(label: 'Eggs', value: '${batch.totalEggs}'),
                if (canViewFinance)
                  _DetailStat(
                    label: 'Net Profit',
                    value: _money(batch.netProfitability),
                    danger: batch.netProfitability < 0,
                  )
                else
                  _DetailStat(label: 'Birds', value: '${batch.currentCount}'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailStat extends StatelessWidget {
  const _DetailStat({
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 11, color: Color(0xff667085))),
        Text(
          value,
          style: TextStyle(
            fontWeight: FontWeight.w900,
            color: danger ? const Color(0xffb83b3b) : const Color(0xff172130),
          ),
        ),
      ],
    );
  }
}

String _money(double value) {
  final sign = value < 0 ? '-' : '';
  return '${sign}GHS ${value.abs().toStringAsFixed(2)}';
}

String _compactMoney(double value) {
  if (value.abs() >= 1000000) return '${(value / 1000000).toStringAsFixed(1)}m';
  if (value.abs() >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return value.toStringAsFixed(0);
}

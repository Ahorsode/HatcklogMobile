import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/permissions/navigation_permissions.dart';
import '../../core/permissions/staff_permission_defaults.dart';
import '../../core/storage/local_database.dart';
import '../../services/comprehensive_farm_report_service.dart';

class FarmReportScreen extends StatefulWidget {
  const FarmReportScreen({
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
  State<FarmReportScreen> createState() => _FarmReportScreenState();
}

class _FarmReportScreenState extends State<FarmReportScreen> {
  late DateTime _startDate;
  late DateTime _endDate;
  bool _loading = false;
  ComprehensiveFarmReport? _report;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _endDate = DateTime(now.year, now.month, now.day, 23, 59, 59);
    _startDate = DateTime(
      now.year,
      now.month,
      now.day,
    ).subtract(const Duration(days: 29));
    _generateReport();
  }

  bool get _canAccess =>
      canShowNavigationItem(
        name: 'Reports',
        role: widget.navigationRole ?? widget.currentUser.role.name.toUpperCase(),
        roles: assignableStaffRoles,
        permissions: widget.permissions,
      );

  Future<void> _generateReport() async {
    if (!_canAccess) return;
    setState(() => _loading = true);
    try {
      final report = await ComprehensiveFarmReportService(
        widget.localDatabase,
      ).generate(
        farmId: widget.currentUser.activeFarmId,
        startDate: _startDate,
        endDate: _endDate,
        permissions: widget.permissions,
        role: widget.navigationRole ?? widget.currentUser.role.name.toUpperCase(),
        assignableRoles: assignableStaffRoles,
      );
      if (mounted) {
        setState(() => _report = report);
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _pickStart() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _startDate,
      firstDate: DateTime(2020),
      lastDate: _endDate,
    );
    if (picked != null && mounted) {
      setState(
        () => _startDate = DateTime(picked.year, picked.month, picked.day),
      );
    }
  }

  Future<void> _pickEnd() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: _startDate,
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null && mounted) {
      setState(
        () => _endDate = DateTime(
          picked.year,
          picked.month,
          picked.day,
          23,
          59,
          59,
        ),
      );
    }
  }

  Future<void> _applyPreset(int days) async {
    final end = DateTime.now();
    setState(() {
      _endDate = DateTime(end.year, end.month, end.day, 23, 59, 59);
      _startDate = DateTime(end.year, end.month, end.day).subtract(
        Duration(days: days - 1),
      );
    });
    await _generateReport();
  }

  Future<void> _applyThisMonth() async {
    final end = DateTime.now();
    setState(() {
      _endDate = DateTime(end.year, end.month, end.day, 23, 59, 59);
      _startDate = DateTime(end.year, end.month, 1);
    });
    await _generateReport();
  }

  Future<void> _exportPdf() async {
    final report = _report;
    if (report == null) return;
    final bytes = await _buildPdf(report);
    if (!mounted) return;
    await Printing.layoutPdf(
      name:
          'farm_intelligence_report_${_dateLabel(report.startDate)}_${_dateLabel(report.endDate)}.pdf',
      onLayout: (_) async => bytes,
    );
  }

  Future<Uint8List> _buildPdf(ComprehensiveFarmReport report) async {
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          return [
            pw.Text(
              'Farm Intelligence Report',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              '${_dateLabel(report.startDate)} to ${_dateLabel(report.endDate)}',
            ),
            pw.SizedBox(height: 16),
            pw.Text('KPI Summary', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('Net Income: ${_money(report.kpis.netIncome)}'),
            pw.Text('Revenue: ${_money(report.kpis.totalRevenue)}'),
            pw.Text('Expense: ${_money(report.kpis.totalExpense)}'),
            pw.Text('Eggs: ${report.kpis.totalEggsCollected}'),
            pw.Text('Feed: ${report.kpis.totalFeedConsumed.toStringAsFixed(1)} kg'),
            pw.Text('Mortality Rate: ${report.kpis.mortalityRate.toStringAsFixed(2)}%'),
            pw.Text('FCR: ${report.kpis.averageFcr.toStringAsFixed(2)}'),
            pw.SizedBox(height: 16),
            pw.Text('Financial Ledger', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.TableHelper.fromTextArray(
              headers: const ['Date', 'Type', 'Category', 'Amount', 'Status'],
              data: [
                for (final row in report.financials.take(40))
                  [
                    _dateLabel(row.transactionDate),
                    row.type,
                    row.category,
                    _money(row.amount),
                    row.paymentStatus,
                  ],
              ],
            ),
            pw.SizedBox(height: 16),
            pw.Text('Batch Performance', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.TableHelper.fromTextArray(
              headers: const [
                'Batch',
                'Status',
                'Initial',
                'Current',
                'Mortality',
                'Feed (kg)',
              ],
              data: [
                for (final batch in report.batches)
                  [
                    batch.batchName,
                    batch.status,
                    '${batch.initialCount}',
                    '${batch.currentCount}',
                    '${batch.mortalityCount}',
                    batch.feedConsumed.toStringAsFixed(1),
                  ],
              ],
            ),
          ];
        },
      ),
    );
    return pdf.save();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canAccess) {
      return Scaffold(
        appBar: AppBar(title: const Text('Intelligence Reports')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'Finance view permission is required to access farm intelligence reports.',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final report = _report;
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Intelligence Reports'),
        actions: [
          if (report != null)
            IconButton(
              tooltip: 'Export PDF',
              onPressed: _loading ? null : _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'GAAP Analytics & Consolidated Performance',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Color(0xFF64748B),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: _loading ? null : () => _applyPreset(7),
                  child: const Text('Last 7 Days'),
                ),
                OutlinedButton(
                  onPressed: _loading ? null : () => _applyPreset(30),
                  child: const Text('Last 30 Days'),
                ),
                OutlinedButton(
                  onPressed: _loading ? null : _applyThisMonth,
                  child: const Text('This Month'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _DateButton(
              label: 'Start Date',
              value: _dateLabel(_startDate),
              onPressed: _pickStart,
            ),
            const SizedBox(height: 12),
            _DateButton(
              label: 'End Date',
              value: _dateLabel(_endDate),
              onPressed: _pickEnd,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _loading ? null : _generateReport,
              icon: _loading
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.analytics_outlined),
              label: Text(_loading ? 'Aggregating...' : 'Generate Report'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
            ),
            if (report != null) ...[
              const SizedBox(height: 20),
              _KpiGrid(report: report),
              const SizedBox(height: 16),
              _CategoryCard(report: report),
              const SizedBox(height: 16),
              _TrendCard(report: report),
              const SizedBox(height: 16),
              _FinancialTable(report: report),
              const SizedBox(height: 16),
              _BatchTable(report: report),
              const SizedBox(height: 16),
              _AuditCard(report: report),
            ],
          ],
        ),
      ),
    );
  }
}

class _KpiGrid extends StatelessWidget {
  const _KpiGrid({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    final kpis = report.kpis;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.45,
      children: [
        _MetricCard(
          label: 'Net Income',
          value: _money(kpis.netIncome),
          accent: kpis.netIncome >= 0 ? Colors.green : Colors.red,
        ),
        _MetricCard(
          label: 'Feed Conversion Ratio',
          value: kpis.averageFcr.toStringAsFixed(2),
        ),
        _MetricCard(
          label: 'Egg Yield',
          value: kpis.totalEggsCollected.toString(),
        ),
        _MetricCard(
          label: 'Mortality Rate',
          value: '${kpis.mortalityRate.toStringAsFixed(2)}%',
          subtitle: '${kpis.totalMortality} deaths logged',
          accent: kpis.mortalityRate < 5 ? Colors.green : Colors.red,
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    this.subtitle,
    this.accent,
  });

  final String label;
  final String value;
  final String? subtitle;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: Color(0xFF64748B),
              ),
            ),
            const Spacer(),
            Text(
              value,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w900,
                color: accent ?? const Color(0xFF0F172A),
              ),
            ),
            if (subtitle != null)
              Text(
                subtitle!,
                style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    final hasData = report.revenueByCategory.isNotEmpty ||
        report.expenseByCategory.isNotEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Chart of Accounts Split',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            if (!hasData)
              const Text('No category data logged.')
            else ...[
              for (final entry in report.revenueByCategory.entries)
                _CategoryRow(
                  label: entry.key,
                  value: _money(entry.value),
                  color: Colors.green,
                ),
              for (final entry in report.expenseByCategory.entries)
                _CategoryRow(
                  label: entry.key,
                  value: _money(entry.value),
                  color: Colors.red,
                ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
          Text(value, style: TextStyle(color: color, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }
}

class _TrendCard extends StatelessWidget {
  const _TrendCard({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    final trends = report.dailyTrends;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ledger Inflow / Outflow Trends',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            if (trends.length < 2)
              const Text('Insufficient data points to plot trend line.')
            else
              SizedBox(
                height: 160,
                child: CustomPaint(
                  painter: _TrendPainter(trends: trends),
                  size: Size.infinite,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({required this.trends});

  final List<DailyReportTrend> trends;

  @override
  void paint(Canvas canvas, Size size) {
    final maxVal = trends
        .map((t) => [t.revenue, t.expense, 100.0].reduce((a, b) => a > b ? a : b))
        .reduce((a, b) => a > b ? a : b);
    final padding = 12.0;
    final chartWidth = size.width - padding * 2;
    final chartHeight = size.height - padding * 2;

    void drawLine(Color color, double Function(DailyReportTrend) value) {
      final paint = Paint()
        ..color = color
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (var i = 0; i < trends.length; i++) {
        final x = padding + (i / (trends.length - 1)) * chartWidth;
        final y = padding +
            chartHeight -
            (value(trends[i]) / maxVal) * chartHeight;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      canvas.drawPath(path, paint);
    }

    drawLine(Colors.green, (t) => t.revenue);
    drawLine(Colors.red, (t) => t.expense);
  }

  @override
  bool shouldRepaint(covariant _TrendPainter oldDelegate) =>
      oldDelegate.trends != trends;
}

class _FinancialTable extends StatelessWidget {
  const _FinancialTable({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Financial Ledger',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            if (report.financials.isEmpty)
              const Text('No financial transactions in this period.')
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Date')),
                    DataColumn(label: Text('Type')),
                    DataColumn(label: Text('Category')),
                    DataColumn(label: Text('Amount')),
                    DataColumn(label: Text('Status')),
                  ],
                  rows: report.financials.take(25).map((row) {
                    return DataRow(
                      cells: [
                        DataCell(Text(_dateLabel(row.transactionDate))),
                        DataCell(Text(row.type)),
                        DataCell(Text(row.category)),
                        DataCell(Text(_money(row.amount))),
                        DataCell(Text(row.paymentStatus)),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _BatchTable extends StatelessWidget {
  const _BatchTable({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Flock Production Performance',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            if (report.batches.isEmpty)
              const Text('No batch data available.')
            else
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columns: const [
                    DataColumn(label: Text('Batch')),
                    DataColumn(label: Text('Status')),
                    DataColumn(label: Text('Initial')),
                    DataColumn(label: Text('Current')),
                    DataColumn(label: Text('Mortality')),
                    DataColumn(label: Text('Feed (kg)')),
                  ],
                  rows: report.batches.map((batch) {
                    return DataRow(
                      cells: [
                        DataCell(Text(batch.batchName)),
                        DataCell(Text(batch.status)),
                        DataCell(Text('${batch.initialCount}')),
                        DataCell(Text('${batch.currentCount}')),
                        DataCell(Text('${batch.mortalityCount}')),
                        DataCell(Text(batch.feedConsumed.toStringAsFixed(1))),
                      ],
                    );
                  }).toList(),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _AuditCard extends StatelessWidget {
  const _AuditCard({required this.report});

  final ComprehensiveFarmReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Operational Audit Logs',
              style: TextStyle(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            if (report.auditTimeline.isEmpty)
              const Text(
                'No system activity logs found for this date range (offline cache).',
              )
            else
              for (final entry in report.auditTimeline)
                ListTile(
                  dense: true,
                  title: Text(entry.actionType ?? 'SYSTEM'),
                  subtitle: Text(entry.description ?? ''),
                  trailing: Text(entry.userName),
                ),
          ],
        ),
      ),
    );
  }
}

class _DateButton extends StatelessWidget {
  const _DateButton({
    required this.label,
    required this.value,
    required this.onPressed,
  });

  final String label;
  final String value;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: const Icon(Icons.event_outlined),
      label: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w900)),
        ],
      ),
      style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(54)),
    );
  }
}

String _dateLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

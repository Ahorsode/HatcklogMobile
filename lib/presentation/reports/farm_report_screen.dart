import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';

class FarmReportScreen extends StatefulWidget {
  const FarmReportScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;

  @override
  State<FarmReportScreen> createState() => _FarmReportScreenState();
}

class _FarmReportScreenState extends State<FarmReportScreen> {
  late DateTime _startDate;
  late DateTime _endDate;
  bool _generating = false;

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

  Future<void> _generateReport() async {
    setState(() => _generating = true);
    try {
      final data = await _loadReportData();
      final bytes = await _buildPdf(data);
      if (!mounted) {
        return;
      }
      await Printing.layoutPdf(
        name: 'hatchlog_farm_report.pdf',
        onLayout: (_) async => bytes,
      );
    } finally {
      if (mounted) {
        setState(() => _generating = false);
      }
    }
  }

  Future<_FarmReportData> _loadReportData() async {
    final farmId = widget.currentUser.activeFarmId;
    final start = _startDate.toIso8601String();
    final end = _endDate.toIso8601String();
    final farms = await widget.localDatabase.queryLocalRecords(
      'farms',
      where: 'id = ?',
      whereArgs: [farmId],
      limit: 1,
    );
    final revenueRows = await widget.localDatabase.rawLocalQuery(
      '''
      select coalesce(sum(amount), 0) as total
      from financial_transactions
      where farm_id = ?
        and datetime(transaction_date) between datetime(?) and datetime(?)
        and is_deleted = 0
        and upper(type) in ('REVENUE', 'SALE', 'SALES')
      ''',
      [farmId, start, end],
    );
    final expenseRows = await widget.localDatabase.rawLocalQuery(
      '''
      select coalesce(sum(amount), 0) as total
      from expenses
      where farm_id = ?
        and datetime(expense_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      ''',
      [farmId, start, end],
    );
    final batchRows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, batch_name, current_count, initial_count
      from batches
      where farm_id = ? and is_deleted = 0
      order by batch_name asc
      ''',
      [farmId],
    );
    final eggRows = await widget.localDatabase.rawLocalQuery(
      '''
      select batch_id, coalesce(sum(eggs_collected), 0) as total
      from egg_production
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      group by batch_id
      ''',
      [farmId, start, end],
    );
    final feedRows = await widget.localDatabase.rawLocalQuery(
      '''
      select batch_id, coalesce(sum(amount_consumed), 0) as total
      from daily_feeding_logs
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
      group by batch_id
      ''',
      [farmId, start, end],
    );
    final mortalityRows = await widget.localDatabase.rawLocalQuery(
      '''
      select batch_id, coalesce(sum(count), 0) as total
      from mortality
      where farm_id = ?
        and datetime(log_date) between datetime(?) and datetime(?)
        and is_deleted = 0
        and upper(type) = 'DEAD'
      group by batch_id
      ''',
      [farmId, start, end],
    );
    final inventoryRows = await widget.localDatabase.rawLocalQuery(
      '''
      select item_name, stock_level, unit, category
      from inventory
      where farm_id = ? and is_deleted = 0
      order by category asc, item_name asc
      limit 60
      ''',
      [farmId],
    );

    final eggByBatch = _totalsByBatch(eggRows);
    final feedByBatch = _totalsByBatch(feedRows);
    final mortalityByBatch = _totalsByBatch(mortalityRows);
    return _FarmReportData(
      farmName: farms.isEmpty ? 'HatchLog Farm' : _text(farms.first['name']),
      startDate: _startDate,
      endDate: _endDate,
      revenue: _asDouble(revenueRows.first['total']),
      expenses: _asDouble(expenseRows.first['total']),
      batches: [
        for (final row in batchRows)
          _BatchReportRow(
            label: _text(row['batch_name'], 'Batch'),
            currentCount: _asInt(row['current_count']),
            initialCount: _asInt(row['initial_count']),
            eggs: _asInt(eggByBatch[_text(row['id'])]),
            feed: _asDouble(feedByBatch[_text(row['id'])]),
            mortality: _asInt(mortalityByBatch[_text(row['id'])]),
          ),
      ],
      inventory: [
        for (final row in inventoryRows)
          _InventoryReportRow(
            name: _text(row['item_name'], 'Inventory item'),
            stock: _asDouble(row['stock_level']),
            unit: _text(row['unit']),
            category: _text(row['category'], 'other'),
          ),
      ],
    );
  }

  Future<Uint8List> _buildPdf(_FarmReportData data) async {
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          return [
            pw.Text(
              data.farmName,
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 4),
            pw.Text('Comprehensive Farm Report'),
            pw.Text(
              '${_dateLabel(data.startDate)} to ${_dateLabel(data.endDate)}',
            ),
            pw.SizedBox(height: 18),
            pw.Row(
              children: [
                _pdfMetric('Revenue', _money(data.revenue)),
                pw.SizedBox(width: 12),
                _pdfMetric('Expenses', _money(data.expenses)),
                pw.SizedBox(width: 12),
                _pdfMetric('Net', _money(data.revenue - data.expenses)),
              ],
            ),
            pw.SizedBox(height: 22),
            pw.Text(
              'Batch Performance',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.TableHelper.fromTextArray(
              headers: const [
                'Batch',
                'Current',
                'Initial',
                'Eggs',
                'Feed Bags',
                'Mortality',
              ],
              data: [
                for (final batch in data.batches)
                  [
                    batch.label,
                    '${batch.currentCount}',
                    '${batch.initialCount}',
                    '${batch.eggs}',
                    batch.feed.toStringAsFixed(2),
                    '${batch.mortality}',
                  ],
              ],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
            pw.SizedBox(height: 22),
            pw.Text(
              'Inventory Status',
              style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 8),
            pw.TableHelper.fromTextArray(
              headers: const ['Item', 'Category', 'Stock', 'Unit'],
              data: [
                for (final item in data.inventory)
                  [
                    item.name,
                    item.category,
                    item.stock.toStringAsFixed(2),
                    item.unit,
                  ],
              ],
              headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
              cellAlignment: pw.Alignment.centerLeft,
            ),
          ];
        },
      ),
    );
    return pdf.save();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Farm Report'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
            const SizedBox(height: 18),
            FilledButton.icon(
              onPressed: _generating ? null : _generateReport,
              icon: _generating
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.picture_as_pdf_outlined),
              label: const Text('Generate Report'),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
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

class _FarmReportData {
  const _FarmReportData({
    required this.farmName,
    required this.startDate,
    required this.endDate,
    required this.revenue,
    required this.expenses,
    required this.batches,
    required this.inventory,
  });

  final String farmName;
  final DateTime startDate;
  final DateTime endDate;
  final double revenue;
  final double expenses;
  final List<_BatchReportRow> batches;
  final List<_InventoryReportRow> inventory;
}

class _BatchReportRow {
  const _BatchReportRow({
    required this.label,
    required this.currentCount,
    required this.initialCount,
    required this.eggs,
    required this.feed,
    required this.mortality,
  });

  final String label;
  final int currentCount;
  final int initialCount;
  final int eggs;
  final double feed;
  final int mortality;
}

class _InventoryReportRow {
  const _InventoryReportRow({
    required this.name,
    required this.stock,
    required this.unit,
    required this.category,
  });

  final String name;
  final double stock;
  final String unit;
  final String category;
}

pw.Widget _pdfMetric(String label, String value) {
  return pw.Expanded(
    child: pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(label),
          pw.SizedBox(height: 4),
          pw.Text(value, style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
        ],
      ),
    ),
  );
}

Map<String, double> _totalsByBatch(List<Map<String, Object?>> rows) {
  return {
    for (final row in rows) _text(row['batch_id']): _asDouble(row['total']),
  };
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _dateLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

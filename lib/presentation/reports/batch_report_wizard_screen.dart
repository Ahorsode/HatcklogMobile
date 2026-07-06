import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../services/batch_report_service.dart';

class BatchReportWizardScreen extends StatefulWidget {
  const BatchReportWizardScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    required this.permissions,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final FarmPermissions permissions;

  @override
  State<BatchReportWizardScreen> createState() =>
      _BatchReportWizardScreenState();
}

class _BatchReportWizardScreenState extends State<BatchReportWizardScreen> {
  late final BatchReportService _service;
  late final List<BatchReportSection> _availableSections;

  var _step = 0;
  var _scopeAllBatches = true;
  String? _selectedBatchId;
  BatchReportDurationPreset _duration = BatchReportDurationPreset.weekly;
  DateTime? _customStart;
  DateTime? _customEnd;
  final Set<BatchReportSection> _selectedSections = {};
  List<BatchReportBatchOption> _batches = const [];
  BatchReportDocument? _report;
  var _loading = false;

  @override
  void initState() {
    super.initState();
    _service = BatchReportService(widget.localDatabase);
    _availableSections = BatchReportService.sectionsForPermissions(
      widget.permissions,
    );
    _selectedSections.addAll(_availableSections);
    _loadBatches();
  }

  Future<void> _loadBatches() async {
    final batches = await _service.loadActiveBatches(
      widget.currentUser.activeFarmId,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _batches = batches;
      _selectedBatchId = batches.isEmpty ? null : batches.first.id;
    });
  }

  Future<void> _generateReport() async {
    if (_batches.isEmpty || _selectedSections.isEmpty) {
      return;
    }
    setState(() => _loading = true);
    try {
      final arrival = _scopeAllBatches
          ? _batches
              .map((batch) => batch.arrivalDate)
              .reduce((a, b) => a.isBefore(b) ? a : b)
          : _batches
                .firstWhere((batch) => batch.id == _selectedBatchId)
                .arrivalDate;
      final range = _service.resolveDateRange(
        preset: _duration,
        batchArrivalDate: arrival,
        customStart: _customStart,
        customEnd: _customEnd,
      );
      final sections = _selectedSections.toList(growable: false);
      final report = _scopeAllBatches
          ? await _service.buildCombinedReport(
              farmId: widget.currentUser.activeFarmId,
              batches: _batches,
              range: range,
              sections: sections,
              permissions: widget.permissions,
            )
          : await _service.buildReport(
              farmId: widget.currentUser.activeFarmId,
              batch: _batches.firstWhere(
                (batch) => batch.id == _selectedBatchId,
              ),
              range: range,
              sections: sections,
              permissions: widget.permissions,
            );
      if (!mounted) {
        return;
      }
      setState(() {
        _report = report;
        _step = 3;
      });
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _exportPdf() async {
    final report = _report;
    if (report == null) {
      return;
    }
    final bytes = await _buildPdf(report);
    if (!mounted) {
      return;
    }
    await Printing.layoutPdf(
      name:
          'batch_report_${report.batchName.replaceAll(RegExp(r'[^a-zA-Z0-9]+'), '_')}.pdf',
      onLayout: (_) async => bytes,
    );
  }

  Future<Uint8List> _buildPdf(BatchReportDocument report) async {
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(28),
        build: (context) {
          return [
            pw.Text(
              'Batch Report — ${report.batchName}',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text('${report.breed} • ${report.house} • ${report.status}'),
            pw.Text('Period: ${report.periodLabel}'),
            pw.Text('Generated: ${report.generatedAt}'),
            pw.SizedBox(height: 14),
            pw.Text('Summary', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Text('Stock: ${report.currentCount} / ${report.initialCount}'),
            pw.Text('Age: ${report.ageInDays} days'),
            pw.Text('Feed: ${report.totalFeed.toStringAsFixed(2)} bags'),
            pw.Text('Eggs: ${report.totalEggs}'),
            pw.Text(
              'Mortality: ${report.totalMortality} (${report.mortalityRate.toStringAsFixed(1)}%)',
            ),
            if (report.netProfit != null) ...[
              pw.Text('Revenue: ${report.totalRevenue?.toStringAsFixed(2) ?? '0'}'),
              pw.Text('Expenses: ${report.totalExpenses?.toStringAsFixed(2) ?? '0'}'),
              pw.Text('Net: ${report.netProfit?.toStringAsFixed(2) ?? '0'}'),
            ],
            pw.SizedBox(height: 14),
            pw.Text('Activity log', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.TableHelper.fromTextArray(
              headers: const ['Date', 'Type', 'Title', 'Detail'],
              data: [
                for (final entry in report.entries.take(80))
                  [
                    _dateLabel(entry.date),
                    entry.type,
                    entry.title,
                    entry.detail,
                  ],
              ],
            ),
          ];
        },
      ),
    );
    return pdf.save();
  }

  String _dateLabel(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Generate Report'),
        actions: [
          if (_report != null)
            IconButton(
              tooltip: 'Export PDF',
              onPressed: _exportPdf,
              icon: const Icon(Icons.picture_as_pdf_outlined),
            ),
        ],
      ),
      body: _batches.isEmpty
          ? const Center(
              child: Text(
                'No active batches are cached on this device yet.',
                textAlign: TextAlign.center,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                _StepIndicator(currentStep: _step),
                const SizedBox(height: 16),
                if (_step == 0) _buildScopeStep(),
                if (_step == 1) _buildDurationStep(),
                if (_step == 2) _buildDataStep(),
                if (_step == 3) _buildPreviewStep(),
                const SizedBox(height: 20),
                _buildNavButtons(),
              ],
            ),
    );
  }

  Widget _buildScopeStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Report scope',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            RadioListTile<bool>(
              value: true,
              groupValue: _scopeAllBatches,
              title: const Text('All active batches'),
              onChanged: (value) => setState(() => _scopeAllBatches = true),
            ),
            RadioListTile<bool>(
              value: false,
              groupValue: _scopeAllBatches,
              title: const Text('Single batch'),
              onChanged: (value) => setState(() => _scopeAllBatches = false),
            ),
            if (!_scopeAllBatches)
              DropdownButtonFormField<String>(
                initialValue: _selectedBatchId,
                decoration: const InputDecoration(labelText: 'Batch'),
                items: [
                  for (final batch in _batches)
                    DropdownMenuItem(
                      value: batch.id,
                      child: Text(batch.batchName),
                    ),
                ],
                onChanged: (value) => setState(() => _selectedBatchId = value),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDurationStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Duration',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            for (final preset in BatchReportDurationPreset.values)
              RadioListTile<BatchReportDurationPreset>(
                value: preset,
                groupValue: _duration,
                title: Text(_durationLabel(preset)),
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() => _duration = value);
                },
              ),
            if (_duration == BatchReportDurationPreset.custom) ...[
              ListTile(
                title: const Text('Start date'),
                subtitle: Text(
                  _customStart == null ? 'Pick date' : _dateLabel(_customStart!),
                ),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDate: _customStart ?? DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _customStart = picked);
                  }
                },
              ),
              ListTile(
                title: const Text('End date'),
                subtitle: Text(
                  _customEnd == null ? 'Pick date' : _dateLabel(_customEnd!),
                ),
                trailing: const Icon(Icons.calendar_today_outlined),
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDate: _customEnd ?? DateTime.now(),
                  );
                  if (picked != null) {
                    setState(() => _customEnd = picked);
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDataStep() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Data sections',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            for (final section in _availableSections)
              CheckboxListTile(
                value: _selectedSections.contains(section),
                title: Text(_sectionLabel(section)),
                onChanged: (checked) {
                  setState(() {
                    if (checked == true) {
                      _selectedSections.add(section);
                    } else {
                      _selectedSections.remove(section);
                    }
                  });
                },
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewStep() {
    final report = _report;
    if (report == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              report.batchName,
              style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 18),
            ),
            Text('${report.periodLabel} • ${report.entries.length} records'),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _MetricChip(
                  label: 'Feed',
                  value: report.totalFeed.toStringAsFixed(1),
                ),
                _MetricChip(label: 'Eggs', value: '${report.totalEggs}'),
                _MetricChip(
                  label: 'Mortality',
                  value: '${report.totalMortality}',
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final entry in report.entries.take(12))
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  entry.title,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                subtitle: Text('${_dateLabel(entry.date)} • ${entry.detail}'),
              ),
            if (report.entries.length > 12)
              Text('+ ${report.entries.length - 12} more records in PDF export'),
          ],
        ),
      ),
    );
  }

  Widget _buildNavButtons() {
    return Row(
      children: [
        if (_step > 0 && _step < 3)
          OutlinedButton(
            onPressed: _loading ? null : () => setState(() => _step -= 1),
            child: const Text('Back'),
          ),
        const Spacer(),
        if (_step < 2)
          FilledButton(
            onPressed: _loading
                ? null
                : () {
                    HapticFeedback.selectionClick();
                    setState(() => _step += 1);
                  },
            child: const Text('Continue'),
          ),
        if (_step == 2)
          FilledButton(
            onPressed: _loading || _selectedSections.isEmpty
                ? null
                : () {
                    HapticFeedback.lightImpact();
                    _generateReport();
                  },
            child: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Preview report'),
          ),
        if (_step == 3)
          FilledButton.icon(
            onPressed: _exportPdf,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Export PDF'),
          ),
      ],
    );
  }

  String _durationLabel(BatchReportDurationPreset preset) {
    return switch (preset) {
      BatchReportDurationPreset.lifetime => 'Lifetime',
      BatchReportDurationPreset.today => 'Today',
      BatchReportDurationPreset.weekly => 'Last 7 days',
      BatchReportDurationPreset.monthly => 'This month',
      BatchReportDurationPreset.custom => 'Custom range',
    };
  }

  String _sectionLabel(BatchReportSection section) {
    return switch (section) {
      BatchReportSection.feed => 'Feed logs',
      BatchReportSection.mortality => 'Mortality & quarantine',
      BatchReportSection.eggs => 'Eggs',
      BatchReportSection.health => 'Health schedules',
      BatchReportSection.finance => 'Finance summary',
      BatchReportSection.sales => 'Sales',
      BatchReportSection.expenses => 'Expenses',
    };
  }
}

class _StepIndicator extends StatelessWidget {
  const _StepIndicator({required this.currentStep});

  final int currentStep;

  @override
  Widget build(BuildContext context) {
    const labels = ['Scope', 'Duration', 'Data', 'Preview'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++)
          Expanded(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 14,
                  backgroundColor: i <= currentStep
                      ? const Color(0xff1f7a4d)
                      : const Color(0xffd5ddd8),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      color: i <= currentStep ? Colors.white : Colors.black54,
                      fontWeight: FontWeight.w900,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: i <= currentStep
                        ? const Color(0xff1f7a4d)
                        : Colors.black54,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(
        '$label: $value',
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    );
  }
}

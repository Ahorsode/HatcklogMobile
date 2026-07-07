import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../features/auth/data/supabase_remote_api.dart';
import '../../features/health/data/health_schedule_repository.dart';
import '../../features/livestock/data/livestock_models.dart';
import '../../features/livestock/data/livestock_repository.dart';
import '../../features/livestock/services/livestock_service.dart';
import '../../features/sales/sale_entry_screen.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../services/batch_analytics_service.dart';
import '../../services/batch_finance_service.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../../utils/batch_type_utils.dart';
import '../eggs/egg_quick_add_sheet.dart';
import '../feeding/feeding_quick_add_sheet.dart';
import '../mortality/mortality_quick_add_sheet.dart';
import '../worker/widgets/quick_add_batch_grid.dart';
import 'edit_livestock_sheet.dart';
import 'financial_setup_sheet.dart';
import 'quarantine_actions_sheet.dart';

class LivestockDetailScreen extends StatefulWidget {
  const LivestockDetailScreen({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.localDatabase,
    required this.batchId,
    this.remoteApi,
    this.inputSink,
    this.localSalesQueue,
    this.pdfInvoiceService,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final LocalDatabase localDatabase;
  final String batchId;
  final SupabaseRemoteApi? remoteApi;
  final WorkerInputSink? inputSink;
  final LocalSalesQueue? localSalesQueue;
  final PdfInvoiceService? pdfInvoiceService;

  @override
  State<LivestockDetailScreen> createState() => _LivestockDetailScreenState();
}

class _LivestockDetailScreenState extends State<LivestockDetailScreen>
    with SingleTickerProviderStateMixin {
  late final LivestockService _service;
  late final BatchAnalyticsService _analyticsService;
  late final HealthScheduleRepository _healthRepository;
  late TabController _tabController;

  LivestockBatchRecord? _batch;
  BatchPerformanceReport? _report;
  BatchFinanceBreakdown? _finance;
  List<BatchActivityEntry> _activity = const [];
  List<Map<String, Object?>> _healthSchedules = const [];
  var _loading = true;

  bool get _canEdit => widget.permissions.canEditBatches;
  bool get _canViewFinance =>
      widget.permissions.canViewFinance || widget.permissions.canEditFinance;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _canViewFinance ? 4 : 3, vsync: this);
    _service = LivestockService(
      repository: LivestockRepository(widget.localDatabase),
      remoteApi: widget.remoteApi,
    );
    _analyticsService = BatchAnalyticsService(widget.localDatabase);
    _healthRepository = HealthScheduleRepository(widget.localDatabase);
    _reload();
    _service.watchBatches(widget.currentUser.activeFarmId).listen((_) {
      if (mounted) {
        _reload(silent: true);
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _reload({bool silent = false}) async {
    if (!silent) {
      setState(() => _loading = true);
    }
    final farmId = widget.currentUser.activeFarmId;
    final batches = await _service.loadBatches(farmId);
    LivestockBatchRecord? batch;
    for (final item in batches) {
      if (item.id == widget.batchId) {
        batch = item;
        break;
      }
    }

    BatchPerformanceReport? report;
    BatchFinanceBreakdown? finance;
    if (batch != null) {
      final payload = await _analyticsService.loadReports(
        farmId: farmId,
        permissions: widget.permissions,
      );
      for (final item in payload.batches) {
        if (item.id == batch.id) {
          report = item;
          break;
        }
      }
      if (_canViewFinance) {
        final breakdown =
            await BatchFinanceService(widget.localDatabase).computeFarmBreakdown(
          farmId,
        );
        for (final item in breakdown) {
          if (item.batchId == batch.id) {
            finance = item;
            break;
          }
        }
      }
    }

    final activity = await _service.loadRecentActivity(
      farmId: farmId,
      batchId: widget.batchId,
    );
    final healthSnapshot =
        await _healthRepository.loadSchedules(farmId);
    final schedules = [
      ...healthSnapshot.vaccinations,
      ...healthSnapshot.medications,
    ].where((row) => row['batch_id']?.toString() == widget.batchId).toList();

    if (!mounted) {
      return;
    }
    setState(() {
      _batch = batch;
      _report = report;
      _finance = finance;
      _activity = activity;
      _healthSchedules = schedules;
      _loading = false;
    });
  }

  BatchSummary _batchSummary(LivestockBatchRecord batch) {
    return BatchSummary(
      id: batch.id,
      batchLabel: batch.batchName,
      livestockType: batch.categoryLabel,
      currentCount: batch.currentCount,
      houseId: batch.houseId,
      houseLabel: batch.houseName,
    );
  }

  Future<void> _openEdit() async {
    final batch = _batch;
    if (batch == null || !_canEdit) {
      return;
    }
    final houses = await _service.loadHouses(widget.currentUser.activeFarmId);
    final result = await showModalBottomSheet<LivestockOperationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => EditLivestockSheet(
        batch: batch,
        houses: houses,
        onSubmit: (draft) => _service.updateBatch(
          user: widget.currentUser,
          batchId: batch.id,
          draft: draft,
        ),
      ),
    );
    if (result?.success == true) {
      await _reload(silent: true);
    }
  }

  Future<void> _openDelete() async {
    final batch = _batch;
    if (batch == null || !_canEdit) {
      return;
    }
    final result = await showModalBottomSheet<LivestockOperationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => DeleteLivestockSheet(
        batchName: batch.batchName,
        onConfirm: (reason) => _service.deleteBatch(
          user: widget.currentUser,
          batchId: batch.id,
          reason: reason,
        ),
      ),
    );
    if (result?.success == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _openFinancialSetup() async {
    final batch = _batch;
    if (batch == null || !widget.permissions.canEditFinance) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FinancialSetupSheet(
        batchName: batch.batchName,
        quantity: batch.initialCount,
        onSubmit: (draft) => _service.saveFinancials(
          user: widget.currentUser,
          batchId: batch.id,
          draft: draft,
          quantity: batch.initialCount,
        ),
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openQuarantine() async {
    final batch = _batch;
    if (batch == null || batch.isolationCount <= 0 || !_canEdit) {
      return;
    }
    final result = await showModalBottomSheet<LivestockOperationResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => QuarantineActionsSheet(
        batch: batch,
        onRecover: (count) => _service.recoverFromIsolation(
          user: widget.currentUser,
          batchId: batch.id,
          count: count,
        ),
        onLogMortality: (count) => _service.logMortalityInIsolation(
          user: widget.currentUser,
          batchId: batch.id,
          count: count,
        ),
      ),
    );
    if (result?.success == true) {
      await _reload(silent: true);
    }
  }

  Future<void> _openMortality({MortalityHealthType? defaultType}) async {
    final batch = _batch;
    final sink = widget.inputSink;
    if (batch == null || sink == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => MortalityQuickAddSheet(
        currentUser: widget.currentUser,
        batch: _batchSummary(batch),
        inputSink: sink,
        localDatabase: widget.localDatabase,
        defaultHealthType: defaultType,
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openEggs() async {
    final batch = _batch;
    final sink = widget.inputSink;
    if (batch == null || sink == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => EggQuickAddSheet(
        currentUser: widget.currentUser,
        batch: _batchSummary(batch),
        inputSink: sink,
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openFeeding() async {
    final batch = _batch;
    final sink = widget.inputSink;
    if (batch == null || sink == null) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => FeedingQuickAddSheet(
        currentUser: widget.currentUser,
        batch: _batchSummary(batch),
        inputSink: sink,
        localDatabase: widget.localDatabase,
      ),
    );
    await _reload(silent: true);
  }

  Future<void> _openSales() async {
    final queue = widget.localSalesQueue;
    final pdf = widget.pdfInvoiceService;
    if (queue == null || pdf == null) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SaleEntryScreen(
          queue: queue,
          pdfService: pdf,
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final batch = _batch;
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        title: Text(batch?.batchName ?? 'Livestock unit'),
        actions: [
          if (_canEdit && batch != null)
            PopupMenuButton<String>(
              onSelected: (value) {
                switch (value) {
                  case 'edit':
                    _openEdit();
                  case 'finance':
                    _openFinancialSetup();
                  case 'delete':
                    _openDelete();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit unit')),
                if (widget.permissions.canEditFinance)
                  const PopupMenuItem(
                    value: 'finance',
                    child: Text('Financial setup'),
                  ),
                const PopupMenuItem(value: 'delete', child: Text('Delete unit')),
              ],
            ),
        ],
        bottom: batch == null
            ? null
            : TabBar(
                controller: _tabController,
                tabs: [
                  const Tab(text: 'Overview'),
                  const Tab(text: 'Activity'),
                  if (_canViewFinance) const Tab(text: 'Finance'),
                  const Tab(text: 'Health'),
                ],
              ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : batch == null
              ? const Center(child: Text('Batch not found'))
              : TabBarView(
                  controller: _tabController,
                  children: [
                    _OverviewTab(
                      batch: batch,
                      report: _report,
                      canEdit: _canEdit,
                      onLogEggs: widget.inputSink != null &&
                              isLayerBatchType(batch.type)
                          ? _openEggs
                          : null,
                      onLogFeed: widget.inputSink != null ? _openFeeding : null,
                      onLogMortality: widget.inputSink != null
                          ? () => _openMortality()
                          : null,
                      onLogSick: widget.inputSink != null
                          ? () => _openMortality(
                                defaultType: MortalityHealthType.sick,
                              )
                          : null,
                      onSell: widget.localSalesQueue != null ? _openSales : null,
                      onQuarantine: batch.isolationCount > 0 && _canEdit
                          ? _openQuarantine
                          : null,
                      onFinancialSetup: batch.hasMissingCost &&
                              widget.permissions.canEditFinance
                          ? _openFinancialSetup
                          : null,
                    ),
                    _ActivityTab(entries: _activity),
                    if (_canViewFinance)
                      _FinanceTab(finance: _finance, report: _report),
                    _HealthTab(schedules: _healthSchedules),
                  ],
                ),
    );
  }
}

class _OverviewTab extends StatelessWidget {
  const _OverviewTab({
    required this.batch,
    required this.report,
    required this.canEdit,
    this.onLogEggs,
    this.onLogFeed,
    this.onLogMortality,
    this.onLogSick,
    this.onSell,
    this.onQuarantine,
    this.onFinancialSetup,
  });

  final LivestockBatchRecord batch;
  final BatchPerformanceReport? report;
  final bool canEdit;
  final VoidCallback? onLogEggs;
  final VoidCallback? onLogFeed;
  final VoidCallback? onLogMortality;
  final VoidCallback? onLogSick;
  final VoidCallback? onSell;
  final VoidCallback? onQuarantine;
  final VoidCallback? onFinancialSetup;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (batch.hasMissingCost && onFinancialSetup != null)
          Card(
            color: const Color(0xff7a3f2f).withValues(alpha: 0.08),
            child: ListTile(
              leading: const Icon(Icons.warning_amber_outlined),
              title: const Text(
                'Purchase cost not recorded',
                style: TextStyle(fontWeight: FontWeight.w800),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: onFinancialSetup,
            ),
          ),
        if (batch.isolationCount > 0)
          Card(
            color: const Color(0xffd99025).withValues(alpha: 0.1),
            child: ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: Text(
                '${batch.isolationCount} birds in isolation',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              subtitle: const Text('Recover or log deaths in quarantine'),
              trailing: onQuarantine == null
                  ? null
                  : const Icon(Icons.chevron_right),
              onTap: onQuarantine,
            ),
          ),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _MetricTile(
              label: 'Age',
              value: '${batch.ageInDays} days',
              icon: Icons.calendar_today_outlined,
            ),
            _MetricTile(
              label: 'Stock',
              value: '${batch.currentCount}',
              icon: Icons.groups_3_outlined,
            ),
            _MetricTile(
              label: 'Mortality',
              value: '${batch.mortalityRate.toStringAsFixed(1)}%',
              icon: Icons.dangerous_outlined,
            ),
            _MetricTile(
              label: 'FCR',
              value: report != null && report!.fcr > 0
                  ? report!.fcr.toStringAsFixed(2)
                  : '—',
              icon: Icons.speed_outlined,
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          '${batch.categoryLabel} • ${batch.breedLabel}',
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        if (batch.houseName.isNotEmpty)
          Text(
            'House: ${batch.houseName}',
            style: const TextStyle(color: Color(0xff66736c)),
          ),
        const SizedBox(height: 16),
        const Text(
          'Quick actions',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (onLogEggs != null)
              _ActionChip(label: 'Log eggs', icon: Icons.egg_alt_outlined, onTap: onLogEggs!),
            if (onLogFeed != null)
              _ActionChip(label: 'Log feed', icon: Icons.grass_outlined, onTap: onLogFeed!),
            if (onLogMortality != null)
              _ActionChip(
                label: 'Mortality',
                icon: Icons.dangerous_outlined,
                onTap: onLogMortality!,
              ),
            if (onLogSick != null)
              _ActionChip(
                label: 'Log sick',
                icon: Icons.healing_outlined,
                onTap: onLogSick!,
              ),
            if (onSell != null)
              _ActionChip(
                label: 'Quick sell',
                icon: Icons.point_of_sale_outlined,
                onTap: onSell!,
              ),
          ],
        ),
      ],
    );
  }
}

class _ActivityTab extends StatelessWidget {
  const _ActivityTab({required this.entries});

  final List<BatchActivityEntry> entries;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Text(
          'No recent activity for this unit yet.',
          style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final entry = entries[index];
        return ListTile(
          title: Text(entry.summary),
          subtitle: Text(entry.kind),
          trailing: Text(
            '${entry.logDate.day}/${entry.logDate.month}/${entry.logDate.year}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        );
      },
    );
  }
}

class _FinanceTab extends StatelessWidget {
  const _FinanceTab({required this.finance, required this.report});

  final BatchFinanceBreakdown? finance;
  final BatchPerformanceReport? report;

  @override
  Widget build(BuildContext context) {
    final financeData = finance;
    if (financeData == null && report == null) {
      return const Center(child: Text('No finance data available yet.'));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _MetricTile(
          label: 'Revenue',
          value: 'GHS ${(financeData?.revenue ?? report?.totalRevenue ?? 0).toStringAsFixed(2)}',
          icon: Icons.payments_outlined,
        ),
        const SizedBox(height: 10),
        _MetricTile(
          label: 'Total expenses',
          value: 'GHS ${(financeData?.totalExpense ?? report?.totalExpenses ?? 0).toStringAsFixed(2)}',
          icon: Icons.receipt_long_outlined,
        ),
        const SizedBox(height: 10),
        _MetricTile(
          label: 'Net profit',
          value: 'GHS ${(financeData?.netProfit ?? report?.netProfitability ?? 0).toStringAsFixed(2)}',
          icon: Icons.trending_up,
        ),
      ],
    );
  }
}

class _HealthTab extends StatelessWidget {
  const _HealthTab({required this.schedules});

  final List<Map<String, Object?>> schedules;

  @override
  Widget build(BuildContext context) {
    if (schedules.isEmpty) {
      return const Center(
        child: Text(
          'No vaccination or medication schedules for this unit.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey, fontWeight: FontWeight.w700),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: schedules.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final row = schedules[index];
        return ListTile(
          title: Text(
            row['vaccine_name']?.toString() ??
                row['medication_name']?.toString() ??
                'Health task',
          ),
          subtitle: Text(row['status']?.toString() ?? 'PENDING'),
          trailing: Text(row['scheduled_date']?.toString() ?? ''),
        );
      },
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 160,
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: const Color(0xff1f7a4d)),
              const SizedBox(height: 8),
              Text(label, style: const TextStyle(color: Color(0xff66736c))),
              Text(
                value,
                style: const TextStyle(
                  fontWeight: FontWeight.w900,
                  fontSize: 18,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(icon, size: 18),
      label: Text(label),
      onPressed: () {
        HapticFeedback.lightImpact();
        onTap();
      },
    );
  }
}

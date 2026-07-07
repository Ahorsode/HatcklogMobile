import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../features/sales/sale_entry_screen.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/sync/data/worker_log_mutator.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../eggs/egg_quick_add_sheet.dart';
import '../feeding/feed_formulation_create_sheet.dart';
import '../feeding/feeding_quick_add_sheet.dart';
import '../finance/log_expense_sheet.dart';
import '../houses/climate_control_screen.dart';
import '../inventory/inventory_quick_add_sheet.dart';
import '../license/soft_lock_banner.dart';
import '../../features/auth/data/supabase_remote_api.dart';
import '../../services/dashboard_stats_service.dart';
import '../../utils/active_farm_id.dart';
import '../../utils/batch_type_utils.dart';
import '../../utils/inventory_sale_utils.dart';
import '../../utils/farm_display_name.dart';
import '../dashboard/worker_dashboard_view.dart';
import '../reports/batch_report_wizard_screen.dart';
import '../health/health_screen.dart';
import '../mortality/mortality_quick_add_sheet.dart';
import '../../utils/worker_log_edit_policy.dart';
import 'widgets/worker_log_actions_sheet.dart';
import 'widgets/quick_add_batch_grid.dart';
import 'worker_module_definitions.dart';

class WorkerHomeScreen extends StatefulWidget {
  const WorkerHomeScreen({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.connectionChanges,
    required this.isOnline,
    required this.inputSink,
    required this.localDatabase,
    required this.onSignOut,
    this.showSoftLockBanner = false,
    this.localSalesQueue,
    this.pdfInvoiceService,
    this.onRefreshFromCloud,
    this.remoteApi,
    this.logMutator,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final WorkerInputSink inputSink;
  final LocalDatabase localDatabase;
  final Future<void> Function() onSignOut;
  final bool showSoftLockBanner;
  final LocalSalesQueue? localSalesQueue;
  final PdfInvoiceService? pdfInvoiceService;
  final Future<void> Function()? onRefreshFromCloud;
  final SupabaseRemoteApi? remoteApi;
  final WorkerLogMutator? logMutator;

  @override
  State<WorkerHomeScreen> createState() => _WorkerHomeScreenState();
}

class _WorkerHomeScreenState extends State<WorkerHomeScreen> {
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<void>? _dataSubscription;

  bool _isOnline = false;
  int _pendingCount = 0;
  String _farmName = 'HatchLog';
  List<BatchSummary> _batches = const [];
  late final DashboardStatsService _dashboardStatsService;

  List<WorkerModuleDef> get _visibleModules =>
      buildVisibleModules(widget.permissions);

  List<WorkerModuleDef> get _editableModules =>
      _visibleModules.where((module) => module.canEdit).toList(growable: false);

  bool get _canViewReports =>
      widget.permissions.canViewEggs ||
      widget.permissions.canViewFeeding ||
      widget.permissions.canViewMortality ||
      widget.permissions.canViewHealth ||
      widget.permissions.canViewFinance ||
      widget.permissions.canViewSales;

  String _resolvedFarmId() {
    try {
      return resolveActiveFarmId(
        user: widget.currentUser,
        supabase: Supabase.instance.client,
      );
    } on Object {
      return widget.currentUser.activeFarmId;
    }
  }

  @override
  void initState() {
    super.initState();
    _dashboardStatsService = DashboardStatsService(
      widget.localDatabase,
      widget.remoteApi,
    );
    _connectionSubscription = widget.connectionChanges.listen((online) {
      if (mounted) {
        setState(() => _isOnline = online);
      }
    });
    _dataSubscription = widget.localDatabase
        .watchTables(const [
          'farms',
          'batches',
          'houses',
          'egg_production',
          'daily_feeding_logs',
          'mortality',
          'pending_sync_inputs',
        ])
        .listen((_) => _loadDashboardData());
    _loadDashboardData();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _dataSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadDashboardData() async {
    final online = await widget.isOnline();
    final pending = await widget.inputSink.pendingCount();
    var farmName = 'HatchLog';
    var batches = const <BatchSummary>[];
    try {
      final farmId = _resolvedFarmId();
      final farmRows = await widget.localDatabase.queryLocalRecords(
        'farms',
        columns: const ['name'],
        where: 'id = ?',
        whereArgs: [farmId],
        limit: 1,
      );
      final batchRows = await widget.localDatabase.rawLocalQuery(
        '''
        select b.id,
               b.batch_name,
               b.type,
               b.current_count,
               b.house_id,
               h.name as house_name
        from batches b
        left join houses h on h.id = b.house_id
        where b.farm_id = ? and b.is_deleted = 0
        order by case when lower(b.status) = 'active' then 0 else 1 end,
                 b.batch_name asc
        ''',
        [farmId],
      );
      farmName = farmRows.isEmpty
          ? 'HatchLog'
          : (farmRows.first['name']?.toString() ?? 'HatchLog');
      batches = batchRows
          .map(
            (row) => BatchSummary(
              id: row['id']?.toString() ?? '',
              batchLabel: row['batch_name']?.toString() ?? 'Batch',
              livestockType: row['type']?.toString() ?? '',
              currentCount: _asInt(row['current_count']),
              houseId: row['house_id']?.toString() ?? '',
              houseLabel: row['house_name']?.toString() ?? '',
            ),
          )
          .where((batch) => batch.id.isNotEmpty)
          .toList(growable: false);
    } on StateError {
      // Widget tests can pass an uninitialized LocalDatabase. The worker shell
      // still renders from permissions with empty local data.
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _farmName = farmName;
      _batches = batches;
      _isOnline = online;
      _pendingCount = pending;
    });
  }

  Future<void> _openQuickLogSheet() async {
    HapticFeedback.lightImpact();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: ListView.separated(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            itemCount: _editableModules.length,
            separatorBuilder: (context, index) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final module = _editableModules[index];
              return ListTile(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: const BorderSide(color: Color(0xffe1e7e3)),
                ),
                leading: Icon(module.icon, color: _colorFor(module.module)),
                title: Text(
                  module.label,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                trailing: const Icon(Icons.add),
                onTap: () {
                  Navigator.of(context).pop();
                  _openQuickAdd(module);
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _openModule(WorkerModuleDef module) async {
    HapticFeedback.selectionClick();
    if (module.module == WorkerModule.houses) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (context) => ClimateControlScreen(
            currentUser: widget.currentUser,
            localDatabase: widget.localDatabase,
            canEdit: module.canEdit,
          ),
        ),
      );
      return;
    }
    if (module.module == WorkerModule.health) {
      await _openHealthScreen(canEdit: module.canEdit);
      return;
    }
    if (module.module == WorkerModule.reports) {
      await _openReportsWizard();
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => WorkerModuleListScreen(
          currentUser: widget.currentUser,
          module: module,
          localDatabase: widget.localDatabase,
          inputSink: widget.inputSink,
          logMutator: widget.logMutator,
          batches: _batches,
          canEditModule: module.canEdit,
          onQuickAdd: module.canEdit ? () => _openQuickAdd(module) : null,
          onEditLog: (row) => _openLogEdit(module, row),
        ),
      ),
    );
    _loadDashboardData();
  }

  Future<void> _openQuickAdd(WorkerModuleDef module) async {
    if (!module.canEdit) {
      return;
    }
    switch (module.module) {
      case WorkerModule.eggs:
      case WorkerModule.feeding:
      case WorkerModule.mortality:
        await _openBatchScopedQuickAdd(module);
      case WorkerModule.health:
        await _openHealthScreen(canEdit: module.canEdit);
      case WorkerModule.reports:
        await _openReportsWizard();
      case WorkerModule.inventory:
        await _showInventorySheet();
      case WorkerModule.finance:
        await _showExpenseSheet();
      case WorkerModule.sales:
        await _openSaleEntry();
      case WorkerModule.houses:
      case WorkerModule.customers:
      case WorkerModule.team:
        _showUnavailable(module.label);
    }
  }

  List<BatchSummary> _batchesForModule(WorkerModule module) {
    if (module == WorkerModule.eggs) {
      return _batches
          .where((batch) => isLayerBatchType(batch.livestockType))
          .toList(growable: false);
    }
    return _batches;
  }

  Future<void> _openReportsWizard() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BatchReportWizardScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  Future<void> _handleSyncTap() async {
    HapticFeedback.selectionClick();
    final online = await widget.isOnline();
    if (!online) {
      if (!mounted) {
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.wifi_off_outlined),
          title: const Text('You are offline'),
          content: const Text(
            'Connect to the internet to sync your pending logs with the farm cloud.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      return;
    }

    if (_pendingCount == 0 && widget.onRefreshFromCloud == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All logs are synced.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _pendingCount > 0
              ? 'Syncing $_pendingCount pending item${_pendingCount == 1 ? '' : 's'}...'
              : 'Refreshing farm data from cloud...',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );

    try {
      if (widget.onRefreshFromCloud != null) {
        await widget.onRefreshFromCloud!();
      }
      await _loadDashboardData();
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _pendingCount > 0
                ? 'Sync finished with $_pendingCount item${_pendingCount == 1 ? '' : 's'} still pending.'
                : 'Sync complete. You are up to date.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Sync failed: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _openHealthScreen({required bool canEdit}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HealthScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          canEdit: canEdit,
        ),
      ),
    );
    _loadDashboardData();
  }

  Future<void> _openBatchScopedQuickAdd(
    WorkerModuleDef module, {
    MortalityHealthType? defaultHealthType,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.68,
          minChildSize: 0.44,
          maxChildSize: 0.9,
          builder: (context, scrollController) {
            return Material(
              color: const Color(0xfff8faf7),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(18),
              ),
              child: SafeArea(
                top: false,
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  children: [
                    Row(
                      children: [
                        Icon(module.icon, color: _colorFor(module.module)),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            module.label,
                            style: Theme.of(context).textTheme.titleLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0,
                                ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Close',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    QuickAddBatchGrid(
                      batches: _batchesForModule(module.module),
                      accentColor: _colorFor(module.module),
                      icon: module.icon,
                      emptyMessage: module.module == WorkerModule.eggs
                          ? 'No active layer batches are cached.'
                          : 'No active batches are cached.',
                      onTapAdd: (batch) {
                        Navigator.of(context).pop();
                        _showBatchForm(
                          module,
                          batch,
                          defaultHealthType: defaultHealthType,
                        );
                      },
                      onLongPress: (batch) {
                        Navigator.of(context).pop();
                        _showBatchQuickMenu(batch);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showBatchForm(
    WorkerModuleDef module,
    BatchSummary batch, {
    MortalityHealthType? defaultHealthType,
    WorkerLogEditConfig? editConfig,
    Map<String, Object?>? initialRow,
  }) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return switch (module.module) {
          WorkerModule.eggs => EggQuickAddSheet(
            currentUser: widget.currentUser,
            batch: batch,
            inputSink: widget.inputSink,
            editConfig: editConfig,
            initialRow: initialRow,
          ),
          WorkerModule.feeding => FeedingQuickAddSheet(
            currentUser: widget.currentUser,
            batch: batch,
            inputSink: widget.inputSink,
            localDatabase: widget.localDatabase,
            onOpenInventory: _openInventoryFromEmptyFeed,
            onCreateFormulation: _openFeedFormulationCreate,
            editConfig: editConfig,
            initialRow: initialRow,
          ),
          WorkerModule.mortality => MortalityQuickAddSheet(
            currentUser: widget.currentUser,
            batch: batch,
            inputSink: widget.inputSink,
            localDatabase: widget.localDatabase,
            defaultHealthType:
                defaultHealthType ?? MortalityHealthType.dead,
            editConfig: editConfig,
            initialRow: initialRow,
          ),
          _ => const SizedBox.shrink(),
        };
      },
    );
    _handleSaved(saved);
  }

  Future<void> _openLogEdit(
    WorkerModuleDef module,
    Map<String, Object?> row,
  ) async {
    final mutator = widget.logMutator;
    if (mutator == null || !module.canEdit) {
      return;
    }
    final batchId = row['batch_id']?.toString() ?? '';
    final batch = _batches.where((item) => item.id == batchId).firstOrNull;
    if (batch == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Batch data is not cached. Sync first, then try again.'),
        ),
      );
      return;
    }
    final recordId = row['id']?.toString() ?? '';
    if (recordId.isEmpty) {
      return;
    }
    await _showBatchForm(
      module,
      batch,
      editConfig: WorkerLogEditConfig(
        recordId: recordId,
        mutator: mutator,
        module: module.module,
      ),
      initialRow: row,
    );
    _loadDashboardData();
  }

  Future<void> _showBatchQuickMenu(BatchSummary batch) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  batch.batchLabel,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(batch.detailLabel),
              ),
              if (widget.permissions.canEditEggs &&
                  isLayerBatchType(batch.livestockType))
                ListTile(
                  leading: const Icon(Icons.egg_alt_outlined),
                  title: const Text('Log eggs'),
                  onTap: () => Navigator.of(context).pop('eggs'),
                ),
              if (widget.permissions.canEditFeeding)
                ListTile(
                  leading: const Icon(Icons.grass_outlined),
                  title: const Text('Log feed'),
                  onTap: () => Navigator.of(context).pop('feed'),
                ),
              if (widget.permissions.canEditMortality) ...[
                ListTile(
                  leading: const Icon(Icons.dangerous_outlined),
                  title: const Text('Log mortality'),
                  onTap: () => Navigator.of(context).pop('mortality'),
                ),
                ListTile(
                  leading: const Icon(Icons.coronavirus_outlined),
                  title: const Text('Quarantine'),
                  onTap: () => Navigator.of(context).pop('sick'),
                ),
              ],
            ],
          ),
        );
      },
    );
    if (!mounted || action == null) {
      return;
    }
    switch (action) {
      case 'eggs':
        final module = _moduleFor(WorkerModule.eggs);
        if (module != null) {
          await _showBatchForm(module, batch);
        }
      case 'feed':
        final module = _moduleFor(WorkerModule.feeding);
        if (module != null) {
          await _showBatchForm(module, batch);
        }
      case 'mortality':
        final module = _moduleFor(WorkerModule.mortality);
        if (module != null) {
          await _showBatchForm(module, batch);
        }
      case 'sick':
        final module = _moduleFor(WorkerModule.mortality);
        if (module != null) {
          await _showBatchForm(
            module,
            batch,
            defaultHealthType: MortalityHealthType.sick,
          );
        }
    }
  }

  WorkerModuleDef? _moduleFor(WorkerModule module) {
    for (final item in _visibleModules) {
      if (item.module == module) {
        return item;
      }
    }
    return null;
  }

  Future<void> _showInventorySheet() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => InventoryQuickAddSheet(
        currentUser: widget.currentUser,
        inputSink: widget.inputSink,
      ),
    );
    _handleSaved(saved);
  }

  Future<void> _showExpenseSheet() async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => LogExpenseSheet(
        currentUser: widget.currentUser,
        inputSink: widget.inputSink,
        localDatabase: widget.localDatabase,
      ),
    );
    _handleSaved(saved);
  }

  Future<void> _openInventoryFromEmptyFeed() async {
    final inventory = _visibleModules
        .where((module) => module.module == WorkerModule.inventory)
        .firstOrNull;
    if (inventory != null) {
      await _openModule(inventory);
    }
  }

  Future<void> _openFeedFormulationCreate() async {
    SupabaseClient? supabase;
    try {
      supabase = Supabase.instance.client;
    } on Object {
      supabase = null;
    }

    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FeedFormulationCreateSheet(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          supabase: supabase,
        );
      },
    );

    if (!mounted || message == null) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _openSaleEntry() async {
    final queue = widget.localSalesQueue;
    final pdfService = widget.pdfInvoiceService;
    if (queue == null || pdfService == null) {
      _showUnavailable('Sales');
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SaleEntryScreen(
          queue: queue,
          pdfService: pdfService,
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  Future<void> _openDashboardQuickAction(
    WorkerModule module, {
    MortalityHealthType? defaultHealthType,
  }) async {
    final workerModule = _editableModules
        .where((entry) => entry.module == module)
        .firstOrNull;
    if (workerModule == null) {
      return;
    }
    switch (module) {
      case WorkerModule.eggs:
      case WorkerModule.feeding:
      case WorkerModule.mortality:
        await _openBatchScopedQuickAdd(
          workerModule,
          defaultHealthType: defaultHealthType,
        );
      case WorkerModule.health:
        await _openHealthScreen(canEdit: workerModule.canEdit);
      default:
        await _openQuickAdd(workerModule);
    }
  }

  void _showUnavailable(String label) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label quick-add is not available yet.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _handleSaved(bool? saved) {
    if (saved != true || !mounted) {
      return;
    }
    _loadDashboardData();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Saved locally. Sync will run automatically.'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _signOut() async {
    HapticFeedback.lightImpact();
    await widget.onSignOut();
  }

  @override
  Widget build(BuildContext context) {
    final modules = _visibleModules;
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _farmName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            Text(
              widget.currentUser.firstName.trim().isEmpty
                  ? widget.currentUser.displayName
                  : widget.currentUser.firstName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                color: Color(0xff66736c),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Sync status',
            onPressed: _handleSyncTap,
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  Icons.cloud_queue_outlined,
                  color: _pendingCount > 0
                      ? const Color(0xffd99025)
                      : _isOnline
                      ? const Color(0xff1f7a4d)
                      : const Color(0xff8a948d),
                ),
                Positioned(
                  right: -1,
                  top: -1,
                  child: Container(
                    width: 9,
                    height: 9,
                    decoration: BoxDecoration(
                      color: _pendingCount > 0
                          ? const Color(0xffd99025)
                          : _isOnline
                          ? const Color(0xff1f7a4d)
                          : const Color(0xff8a948d),
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      floatingActionButton: _editableModules.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _openQuickLogSheet,
              icon: const Icon(Icons.add),
              label: const Text('Quick Log'),
            ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.showSoftLockBanner) const SoftLockBanner(),
            Expanded(
              child: modules.isEmpty
                  ? const _NoWorkerModulesView()
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                      children: [
                        _WorkerDashboardSection(
                          dashboardStatsService: _dashboardStatsService,
                          localDatabase: widget.localDatabase,
                          activeFarmId: _resolvedFarmId(),
                          activeFarmNameFallback:
                              widget.currentUser.activeFarmName,
                          displayName: widget.currentUser.displayName,
                          permissions: widget.permissions,
                          onLogFeed: () => _openDashboardQuickAction(
                            WorkerModule.feeding,
                          ),
                          onLogEggs: () => _openDashboardQuickAction(
                            WorkerModule.eggs,
                          ),
                          onLogMortality: () => _openDashboardQuickAction(
                            WorkerModule.mortality,
                            defaultHealthType: MortalityHealthType.dead,
                          ),
                          onLogQuarantine: () => _openDashboardQuickAction(
                            WorkerModule.mortality,
                            defaultHealthType: MortalityHealthType.sick,
                          ),
                          onLogHealth: () => _openHealthScreen(
                            canEdit: widget.permissions.canEditHealth,
                          ),
                          onRefreshFromCloud: widget.onRefreshFromCloud,
                        ),
                        const SizedBox(height: 20),
                        if (_canViewReports)
                          Card(
                            child: ListTile(
                              leading: const Icon(
                                Icons.description_outlined,
                                color: Color(0xff4d6475),
                              ),
                              title: const Text(
                                'Generate Report',
                                style: TextStyle(fontWeight: FontWeight.w900),
                              ),
                              subtitle: const Text(
                                'Batch PDF report from your local farm logs',
                              ),
                              trailing: const Icon(Icons.chevron_right),
                              onTap: _openReportsWizard,
                            ),
                          ),
                        if (_canViewReports) const SizedBox(height: 12),
                        Text(
                          'Your Modules',
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        const SizedBox(height: 12),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 2,
                                mainAxisSpacing: 12,
                                crossAxisSpacing: 12,
                                childAspectRatio: 1.08,
                              ),
                          itemCount: modules.length,
                          itemBuilder: (context, index) {
                            final module = modules[index];
                            return _ModuleCard(
                              module: module,
                              color: _colorFor(module.module),
                              onOpen: () => _openModule(module),
                              onQuickAdd: module.canEdit
                                  ? () => _openQuickAdd(module)
                                  : null,
                            );
                          },
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class WorkerModuleListScreen extends StatefulWidget {
  const WorkerModuleListScreen({
    super.key,
    required this.currentUser,
    required this.module,
    required this.localDatabase,
    this.inputSink,
    this.logMutator,
    this.batches = const [],
    this.canEditModule = false,
    this.onQuickAdd,
    this.onEditLog,
  });

  final AppUser currentUser;
  final WorkerModuleDef module;
  final LocalDatabase localDatabase;
  final WorkerInputSink? inputSink;
  final WorkerLogMutator? logMutator;
  final List<BatchSummary> batches;
  final bool canEditModule;
  final VoidCallback? onQuickAdd;
  final Future<void> Function(Map<String, Object?> row)? onEditLog;

  @override
  State<WorkerModuleListScreen> createState() => _WorkerModuleListScreenState();
}

class _WorkerModuleListScreenState extends State<WorkerModuleListScreen> {
  StreamSubscription<void>? _subscription;
  List<Map<String, Object?>> _rows = const [];
  String _eggStockFilter = 'all';

  bool get _isEggsModule => widget.module.module == WorkerModule.eggs;

  @override
  void initState() {
    super.initState();
    _subscription = widget.localDatabase
        .watchTables([_tableFor(widget.module.module)])
        .listen((_) => _loadRows());
    _loadRows();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  bool get _supportsWorkerLogActions =>
      widget.canEditModule &&
      widget.logMutator != null &&
      (widget.module.module == WorkerModule.eggs ||
          widget.module.module == WorkerModule.feeding ||
          widget.module.module == WorkerModule.mortality);

  Future<void> _openLogActions(Map<String, Object?> row) async {
    final mutator = widget.logMutator;
    if (mutator == null) {
      return;
    }
    await showWorkerLogActionsSheet(
      context: context,
      currentUser: widget.currentUser,
      module: widget.module.module,
      row: row,
      logMutator: mutator,
      onEdit: () {
        widget.onEditLog?.call(row);
      },
      onDeleted: () {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Log entry deleted.')),
          );
        }
        _loadRows();
      },
    );
  }

  Future<void> _loadRows() async {
    final farmId = widget.currentUser.activeFarmId;
    final rows = switch (widget.module.module) {
      WorkerModule.eggs => await widget.localDatabase.rawLocalQuery(
        '''
        select e.*, b.batch_name
        from egg_production e
        left join batches b on b.id = e.batch_id
        where e.farm_id = ? and coalesce(e.is_deleted, 0) = 0
        order by log_date desc
        limit 200
        ''',
        [farmId],
      ),
      WorkerModule.team => await widget.localDatabase.rawLocalQuery(
        '''
        select fm.*,
               u.first_name as first_name,
               u.last_name as last_name,
               u.phone_number as phone_number
        from farm_members fm
        left join local_users u on u.id = fm.user_id
        where fm.farm_id = ?
        order by fm.role asc
        limit 80
        ''',
        [farmId],
      ),
      _ => await widget.localDatabase.queryLocalRecords(
        _tableFor(widget.module.module),
        where: _whereFor(widget.module.module),
        whereArgs: [farmId],
        orderBy: _orderByFor(widget.module.module),
        limit: 200,
      ),
    };
    if (mounted) {
      setState(() => _rows = rows);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayRows = _isEggsModule
        ? _rows
              .where((row) => matchesEggStockFilter(row, _eggStockFilter))
              .toList(growable: false)
        : _rows;

    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(widget.module.label),
      ),
      floatingActionButton: widget.onQuickAdd == null
          ? null
          : FloatingActionButton.extended(
              onPressed: widget.onQuickAdd,
              icon: const Icon(Icons.add),
              label: Text('Add ${widget.module.label}'),
            ),
      body: SafeArea(
        child: _rows.isEmpty
            ? Center(
                child: Text(
                  'No ${widget.module.label.toLowerCase()} records cached.',
                  style: const TextStyle(
                    color: Color(0xff66736c),
                    fontWeight: FontWeight.w800,
                  ),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                children: [
                  if (_isEggsModule) ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('In stock'),
                          selected: _eggStockFilter == 'active',
                          onSelected: (_) {
                            setState(() => _eggStockFilter = 'active');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('Sold out'),
                          selected: _eggStockFilter == 'sold_out',
                          onSelected: (_) {
                            setState(() => _eggStockFilter = 'sold_out');
                          },
                        ),
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _eggStockFilter == 'all',
                          onSelected: (_) {
                            setState(() => _eggStockFilter = 'all');
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (displayRows.isEmpty && _isEggsModule)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(
                        child: Text(
                          'No egg logs match this filter.',
                          style: TextStyle(
                            color: Color(0xff66736c),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    )
                  else
                    for (final row in displayRows) ...[
                      Builder(
                        builder: (context) {
                          final vm = _recordFor(widget.module.module, row);
                          final isOwnLog =
                              row['user_id']?.toString() == widget.currentUser.id;
                          final canMutate = _supportsWorkerLogActions &&
                              isOwnLog &&
                              canWorkerMutateLogRow(
                                currentUserId: widget.currentUser.id,
                                row: row,
                              );
                          final isLockedOwnLog = _supportsWorkerLogActions &&
                              isOwnLog &&
                              !canMutate;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: ListTile(
                              onTap: _supportsWorkerLogActions && isOwnLog
                                  ? () => _openLogActions(row)
                                  : null,
                              tileColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(color: Color(0xffe1e7e3)),
                              ),
                              leading: Icon(
                                widget.module.icon,
                                color: _colorFor(widget.module.module),
                              ),
                              title: Text(
                                vm.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontWeight: FontWeight.w900),
                              ),
                              subtitle: Text(
                                isLockedOwnLog
                                    ? '${vm.subtitle}\nLocked after 24h'
                                    : vm.subtitle,
                                maxLines: isLockedOwnLog ? 3 : 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: canMutate
                                  ? const Icon(Icons.edit_outlined, size: 20)
                                  : vm.metric.isEmpty
                                  ? null
                                  : Text(
                                      vm.metric,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                            ),
                          );
                        },
                      ),
                    ],
                ],
              ),
      ),
    );
  }
}

class _WorkerDashboardSection extends StatefulWidget {
  const _WorkerDashboardSection({
    required this.dashboardStatsService,
    required this.localDatabase,
    required this.activeFarmId,
    this.activeFarmNameFallback = '',
    required this.displayName,
    required this.permissions,
    this.onLogFeed,
    this.onLogEggs,
    this.onLogMortality,
    this.onLogQuarantine,
    this.onLogHealth,
    this.onRefreshFromCloud,
  });

  final DashboardStatsService dashboardStatsService;
  final LocalDatabase localDatabase;
  final String activeFarmId;
  final String activeFarmNameFallback;
  final String displayName;
  final FarmPermissions permissions;
  final VoidCallback? onLogFeed;
  final VoidCallback? onLogEggs;
  final VoidCallback? onLogMortality;
  final VoidCallback? onLogQuarantine;
  final VoidCallback? onLogHealth;
  final Future<void> Function()? onRefreshFromCloud;

  @override
  State<_WorkerDashboardSection> createState() =>
      _WorkerDashboardSectionState();
}

class _WorkerDashboardSectionState extends State<_WorkerDashboardSection> {
  var _requestedCloudRefresh = false;

  Future<DashboardStatsSnapshot> _loadStatsWithCloudFallback() async {
    var stats = await widget.dashboardStatsService.loadStats(
      farmId: widget.activeFarmId,
      permissions: widget.permissions,
    );
    if (stats.activeBatches.isNotEmpty ||
        _requestedCloudRefresh ||
        widget.onRefreshFromCloud == null) {
      return stats;
    }

    _requestedCloudRefresh = true;
    try {
      await widget.onRefreshFromCloud!();
      stats = await widget.dashboardStatsService.loadStats(
        farmId: widget.activeFarmId,
        permissions: widget.permissions,
      );
    } on Object {
      // Keep the first snapshot if cloud refresh fails offline.
    }
    return stats;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<void>(
      stream: widget.dashboardStatsService.watchStats(),
      builder: (context, _) {
        return FutureBuilder<DashboardStatsSnapshot>(
          future: _loadStatsWithCloudFallback(),
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done &&
                !snapshot.hasData) {
              return const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              );
            }
            if (snapshot.hasError) {
              return Text('Failed to load dashboard: ${snapshot.error}');
            }
            final stats = snapshot.data;
            if (stats == null) {
              return const Text('No dashboard data available.');
            }
            return FutureBuilder<String>(
              future: resolveFarmDisplayLabel(
                widget.localDatabase,
                widget.activeFarmId,
                fallbackName: widget.activeFarmNameFallback,
              ),
              builder: (context, farmLabelSnapshot) {
                return WorkerDashboardView(
                  embedded: true,
                  displayName: widget.displayName,
                  activeFarmLabel:
                      farmLabelSnapshot.data ?? 'Active Farm Monitor',
                  permissionsLoading: false,
                  stats: stats,
                  permissions: widget.permissions,
                  onLogFeed: widget.onLogFeed,
                  onLogEggs: widget.onLogEggs,
                  onLogMortality: widget.onLogMortality,
                  onLogQuarantine: widget.onLogQuarantine,
                  onLogHealth: widget.onLogHealth,
                );
              },
            );
          },
        );
      },
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.color,
    required this.onOpen,
    this.onQuickAdd,
  });

  final WorkerModuleDef module;
  final Color color;
  final VoidCallback onOpen;
  final VoidCallback? onQuickAdd;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: onOpen,
        child: Stack(
          children: [
            Positioned.fill(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: color.withValues(alpha: 0.16)),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x105c6b62),
                      blurRadius: 18,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    CircleAvatar(
                      radius: 24,
                      backgroundColor: color.withValues(alpha: 0.12),
                      foregroundColor: color,
                      child: Icon(module.icon),
                    ),
                    const Spacer(),
                    Text(
                      module.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Icon(Icons.chevron_right, color: color),
                  ],
                ),
              ),
            ),
            if (onQuickAdd != null)
              Positioned(
                right: 8,
                top: 8,
                child: IconButton.filled(
                  tooltip: 'Add ${module.label}',
                  onPressed: onQuickAdd,
                  style: IconButton.styleFrom(
                    backgroundColor: color,
                    foregroundColor: Colors.white,
                    fixedSize: const Size.square(38),
                  ),
                  icon: const Icon(Icons.add),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoWorkerModulesView extends StatelessWidget {
  const _NoWorkerModulesView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'No modules assigned.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Color(0xff66736c),
            fontSize: 17,
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _RecordVm {
  const _RecordVm({
    required this.title,
    required this.subtitle,
    required this.metric,
  });

  final String title;
  final String subtitle;
  final String metric;
}

_RecordVm _recordFor(WorkerModule module, Map<String, Object?> row) {
  return switch (module) {
    WorkerModule.eggs => _RecordVm(
      title: '${_asInt(row['eggs_collected'])} eggs',
      subtitle:
          '${_batchDisplayName(row)} | ${_dateText(row['log_date'])} | '
          '${eggActivePercent(collected: _asInt(row['eggs_collected']), unusable: _asInt(row['unusable_count']), remaining: _asInt(row['eggs_remaining']))}% active',
      metric:
          '${_asInt(row['eggs_remaining'])} left · ${eggSoldCount(collected: _asInt(row['eggs_collected']), unusable: _asInt(row['unusable_count']), remaining: _asInt(row['eggs_remaining']))} sold',
    ),
    WorkerModule.feeding => _RecordVm(
      title: '${_asDouble(row['amount_consumed']).toStringAsFixed(2)} bags',
      subtitle:
          '${_text(row['feed_type_label'], 'Feed')} | ${_dateText(row['log_date'])}',
      metric: '',
    ),
    WorkerModule.mortality => _RecordVm(
      title:
          '${_asInt(row['count'])} ${_text(row['type'], 'DEAD').toLowerCase()}',
      subtitle:
          '${_text(row['sub_category'], _text(row['reason'], 'Unknown'))} | ${_dateText(row['log_date'])}',
      metric: _text(row['category']),
    ),
    WorkerModule.health => const _RecordVm(
      title: 'Health schedule',
      subtitle: 'Vaccination & medication',
      metric: '',
    ),
    WorkerModule.reports => const _RecordVm(
      title: 'Batch reports',
      subtitle: 'Generate PDF from local logs',
      metric: '',
    ),
    WorkerModule.houses => _RecordVm(
      title: _text(row['name'], 'House'),
      subtitle: _bool(row['is_isolation'])
          ? 'Isolation | Capacity ${_asInt(row['capacity'])}'
          : 'Capacity ${_asInt(row['capacity'])}',
      metric: _formatHouseClimate(row),
    ),
    WorkerModule.sales => _RecordVm(
      title: _text(row['customer_name'], 'Walk-in customer'),
      subtitle: _dateText(row['sale_date']),
      metric: _money(_asDouble(row['total_amount'])),
    ),
    WorkerModule.inventory => _RecordVm(
      title: _text(row['item_name'], 'Inventory item'),
      subtitle: _text(row['category'], 'Other'),
      metric:
          '${_asDouble(row['stock_level']).toStringAsFixed(2)} ${_text(row['unit'])}',
    ),
    WorkerModule.finance => _RecordVm(
      title: _text(row['category'], 'Expense'),
      subtitle: _dateText(row['expense_date']),
      metric: _money(_asDouble(row['amount'])),
    ),
    WorkerModule.customers => _RecordVm(
      title: _text(row['name'], 'Customer'),
      subtitle: _text(row['phone'], _text(row['email'], 'No contact')),
      metric: '',
    ),
    WorkerModule.team => _RecordVm(
      title: _memberDisplayName(row),
      subtitle: _text(row['role'], 'Worker'),
      metric: '',
    ),
  };
}

String _memberDisplayName(Map<String, Object?> row) {
  final composed =
      '${_text(row['first_name'])} ${_text(row['last_name'])}'.trim();
  if (composed.isNotEmpty) {
    return composed;
  }
  final phone = _text(row['phone_number']).trim();
  if (phone.isNotEmpty) {
    return phone;
  }
  return 'Team member';
}

String _batchDisplayName(Map<String, Object?> row) {
  final name = _text(row['batch_name']).trim();
  if (name.isNotEmpty) {
    return name;
  }
  return 'Batch';
}

String _tableFor(WorkerModule module) {
  return switch (module) {
    WorkerModule.eggs => 'egg_production',
    WorkerModule.feeding => 'daily_feeding_logs',
    WorkerModule.mortality => 'mortality',
    WorkerModule.health => 'health_schedules',
    WorkerModule.reports => 'batches',
    WorkerModule.houses => 'houses',
    WorkerModule.sales => 'sales',
    WorkerModule.inventory => 'inventory',
    WorkerModule.finance => 'expenses',
    WorkerModule.customers => 'customers',
    WorkerModule.team => 'farm_members',
  };
}

String _whereFor(WorkerModule module) {
  return switch (module) {
    WorkerModule.team => 'farm_id = ?',
    WorkerModule.houses => 'farm_id = ?',
    WorkerModule.customers => 'farm_id = ?',
    _ => 'farm_id = ? and coalesce(is_deleted, 0) = 0',
  };
}

String _orderByFor(WorkerModule module) {
  return switch (module) {
    WorkerModule.eggs => 'log_date desc',
    WorkerModule.feeding => 'log_date desc',
    WorkerModule.mortality => 'log_date desc',
    WorkerModule.health => 'scheduled_date desc',
    WorkerModule.reports => 'batch_name asc',
    WorkerModule.sales => 'sale_date desc',
    WorkerModule.finance => 'expense_date desc',
    WorkerModule.inventory => 'item_name asc',
    WorkerModule.houses => 'name asc',
    WorkerModule.customers => 'name asc',
    WorkerModule.team => 'updated_at desc',
  };
}

Color _colorFor(WorkerModule module) {
  return switch (module) {
    WorkerModule.eggs => const Color(0xffc7851f),
    WorkerModule.feeding => const Color(0xff1f7a4d),
    WorkerModule.mortality => const Color(0xffb83b3b),
    WorkerModule.health => const Color(0xff2f7a6d),
    WorkerModule.reports => const Color(0xff4d6475),
    WorkerModule.houses => const Color(0xff2f5f8f),
    WorkerModule.sales => const Color(0xff4d6475),
    WorkerModule.inventory => const Color(0xff5c6f2f),
    WorkerModule.finance => const Color(0xff2e6f61),
    WorkerModule.customers => const Color(0xff6d4f8f),
    WorkerModule.team => const Color(0xff7a3f2f),
  };
}

int _asInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _asDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _text(Object? value, [String fallback = '']) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? fallback : text;
}

String _dateText(Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    return _text(value, 'No date');
  }
  final month = parsed.month.toString().padLeft(2, '0');
  final day = parsed.day.toString().padLeft(2, '0');
  return '${parsed.year}-$month-$day';
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

bool _bool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes';
}

String _formatHouseClimate(Map<String, Object?> row) {
  final tempRaw = row['current_temperature'];
  final humidityRaw = row['current_humidity'];
  if (tempRaw == null && humidityRaw == null) {
    return 'Climate not set';
  }
  final temp = tempRaw == null ? null : _asDouble(tempRaw);
  final humidity = humidityRaw == null ? null : _asDouble(humidityRaw);
  return '${temp?.toStringAsFixed(1) ?? '--'}C / ${humidity?.toStringAsFixed(0) ?? '--'}%';
}

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../features/sales/sale_entry_screen.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../eggs/egg_quick_add_sheet.dart';
import '../feeding/feeding_quick_add_sheet.dart';
import '../finance/log_expense_sheet.dart';
import '../houses/climate_control_screen.dart';
import '../inventory/inventory_quick_add_sheet.dart';
import '../license/soft_lock_banner.dart';
import '../mortality/mortality_quick_add_sheet.dart';
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

  @override
  State<WorkerHomeScreen> createState() => _WorkerHomeScreenState();
}

class _WorkerHomeScreenState extends State<WorkerHomeScreen> {
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<void>? _dataSubscription;

  bool _isOnline = false;
  int _pendingCount = 0;
  String _farmName = 'HatchLog';
  int _eggsToday = 0;
  double _feedToday = 0;
  int _mortalityToday = 0;
  List<BatchSummary> _batches = const [];

  List<WorkerModuleDef> get _visibleModules =>
      buildVisibleModules(widget.permissions);

  List<WorkerModuleDef> get _editableModules =>
      _visibleModules.where((module) => module.canEdit).toList(growable: false);

  @override
  void initState() {
    super.initState();
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
    final today = DateTime.now();
    final todayIso = DateTime(
      today.year,
      today.month,
      today.day,
    ).toIso8601String();
    var farmName = 'HatchLog';
    var eggsToday = 0;
    var feedToday = 0.0;
    var mortalityToday = 0;
    var batches = const <BatchSummary>[];
    try {
      final farmRows = await widget.localDatabase.queryLocalRecords(
        'farms',
        columns: const ['name'],
        where: 'id = ?',
        whereArgs: [widget.currentUser.activeFarmId],
        limit: 1,
      );
      final eggRows = await widget.localDatabase.rawLocalQuery(
        '''
        select coalesce(sum(eggs_collected), 0) as total
        from egg_production
        where farm_id = ? and date(log_date) = date(?) and is_deleted = 0
        ''',
        [widget.currentUser.activeFarmId, todayIso],
      );
      final feedRows = await widget.localDatabase.rawLocalQuery(
        '''
        select coalesce(sum(amount_consumed), 0) as total
        from daily_feeding_logs
        where farm_id = ? and date(log_date) = date(?) and is_deleted = 0
        ''',
        [widget.currentUser.activeFarmId, todayIso],
      );
      final mortalityRows = await widget.localDatabase.rawLocalQuery(
        '''
        select coalesce(sum(count), 0) as total
        from mortality
        where farm_id = ?
          and date(log_date) = date(?)
          and is_deleted = 0
          and upper(type) = 'DEAD'
        ''',
        [widget.currentUser.activeFarmId, todayIso],
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
        [widget.currentUser.activeFarmId],
      );
      farmName = farmRows.isEmpty
          ? 'HatchLog'
          : (farmRows.first['name']?.toString() ?? 'HatchLog');
      eggsToday = _asInt(eggRows.first['total']);
      feedToday = _asDouble(feedRows.first['total']);
      mortalityToday = _asInt(mortalityRows.first['total']);
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
      _eggsToday = eggsToday;
      _feedToday = feedToday;
      _mortalityToday = mortalityToday;
      _batches = batches;
      _isOnline = online;
      _pendingCount = pending;
    });
  }

  Future<void> _showPendingCount() async {
    HapticFeedback.selectionClick();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '$_pendingCount pending sync item${_pendingCount == 1 ? '' : 's'}',
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
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
          ),
        ),
      );
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => WorkerModuleListScreen(
          currentUser: widget.currentUser,
          module: module,
          localDatabase: widget.localDatabase,
          onQuickAdd: module.canEdit ? () => _openQuickAdd(module) : null,
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

  Future<void> _openBatchScopedQuickAdd(WorkerModuleDef module) async {
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
                      batches: _batches,
                      accentColor: _colorFor(module.module),
                      icon: module.icon,
                      emptyMessage: 'No active batches are cached.',
                      onTapAdd: (batch) {
                        Navigator.of(context).pop();
                        _showBatchForm(module, batch);
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
    BatchSummary batch,
  ) async {
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
          ),
          WorkerModule.feeding => FeedingQuickAddSheet(
            currentUser: widget.currentUser,
            batch: batch,
            inputSink: widget.inputSink,
            localDatabase: widget.localDatabase,
            onOpenInventory: _openInventoryFromEmptyFeed,
            onCreateFormulation: () => _showUnavailable('Feed Formulations'),
          ),
          WorkerModule.mortality => MortalityQuickAddSheet(
            currentUser: widget.currentUser,
            batch: batch,
            inputSink: widget.inputSink,
            localDatabase: widget.localDatabase,
            defaultHealthType: MortalityHealthType.dead,
          ),
          _ => const SizedBox.shrink(),
        };
      },
    );
    _handleSaved(saved);
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
          currentUserId: widget.currentUser.id,
          currentFarmId: widget.currentUser.activeFarmId,
        ),
      ),
    );
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
            onPressed: _showPendingCount,
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
                        _TodaySummaryStrip(
                          permissions: widget.permissions,
                          eggsToday: _eggsToday,
                          feedToday: _feedToday,
                          mortalityToday: _mortalityToday,
                        ),
                        const SizedBox(height: 16),
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
    this.onQuickAdd,
  });

  final AppUser currentUser;
  final WorkerModuleDef module;
  final LocalDatabase localDatabase;
  final VoidCallback? onQuickAdd;

  @override
  State<WorkerModuleListScreen> createState() => _WorkerModuleListScreenState();
}

class _WorkerModuleListScreenState extends State<WorkerModuleListScreen> {
  StreamSubscription<void>? _subscription;
  List<Map<String, Object?>> _rows = const [];

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

  Future<void> _loadRows() async {
    final table = _tableFor(widget.module.module);
    final orderBy = _orderByFor(widget.module.module);
    final rows = await widget.localDatabase.queryLocalRecords(
      table,
      where: _whereFor(widget.module.module),
      whereArgs: [widget.currentUser.activeFarmId],
      orderBy: orderBy,
      limit: 80,
    );
    if (mounted) {
      setState(() => _rows = rows);
    }
  }

  @override
  Widget build(BuildContext context) {
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
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: _rows.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final vm = _recordFor(widget.module.module, _rows[index]);
                  return ListTile(
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
                      vm.subtitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: vm.metric.isEmpty
                        ? null
                        : Text(
                            vm.metric,
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                  );
                },
              ),
      ),
    );
  }
}

class _TodaySummaryStrip extends StatelessWidget {
  const _TodaySummaryStrip({
    required this.permissions,
    required this.eggsToday,
    required this.feedToday,
    required this.mortalityToday,
  });

  final FarmPermissions permissions;
  final int eggsToday;
  final double feedToday;
  final int mortalityToday;

  @override
  Widget build(BuildContext context) {
    final chips = [
      if (permissions.canViewEggs)
        _TodayChip(
          icon: Icons.egg_alt_outlined,
          label: 'Eggs Collected',
          value: '$eggsToday',
          color: const Color(0xffc7851f),
        ),
      if (permissions.canViewFeeding)
        _TodayChip(
          icon: Icons.grass_outlined,
          label: 'Feed Used',
          value: '${feedToday.toStringAsFixed(2)} bags',
          color: const Color(0xff1f7a4d),
        ),
      if (permissions.canViewMortality)
        _TodayChip(
          icon: Icons.healing_outlined,
          label: 'Mortality Count',
          value: '$mortalityToday',
          color: const Color(0xffb83b3b),
        ),
    ];
    if (chips.isEmpty) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (var i = 0; i < chips.length; i += 1) ...[
            chips[i],
            if (i != chips.length - 1) const SizedBox(width: 10),
          ],
        ],
      ),
    );
  }
}

class _TodayChip extends StatelessWidget {
  const _TodayChip({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 172,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: color.withValues(alpha: 0.12),
            foregroundColor: color,
            child: Icon(icon, size: 19),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xff66736c),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
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
          'Batch ${_text(row['batch_id'])} | ${_dateText(row['log_date'])}',
      metric: '${_asInt(row['unusable_count'])} damaged',
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
    WorkerModule.houses => _RecordVm(
      title: _text(row['name'], 'House'),
      subtitle: 'Capacity ${_asInt(row['capacity'])}',
      metric: '${_asDouble(row['current_temperature']).toStringAsFixed(1)}C',
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
      title: _text(row['user_id'], 'Team member'),
      subtitle: _text(row['role'], 'Worker'),
      metric: '',
    ),
  };
}

String _tableFor(WorkerModule module) {
  return switch (module) {
    WorkerModule.eggs => 'egg_production',
    WorkerModule.feeding => 'daily_feeding_logs',
    WorkerModule.mortality => 'mortality',
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

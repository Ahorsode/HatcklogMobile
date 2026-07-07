import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../core/permissions/farm_permissions.dart';
import '../../core/storage/local_database.dart';
import '../../features/management/data/management_repository.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/auth/data/supabase_remote_api.dart';
import '../../services/feed_formulation_service.dart';
import '../../services/local_house_service.dart';
import '../../utils/active_farm_id.dart';
import '../../utils/house_climate_utils.dart';
import '../../services/local_sales_queue.dart';
import '../../services/pdf_invoice_service.dart';
import '../analytics/farm_analytics_screen.dart';
import '../analytics/batch_compare_screen.dart';
import '../../features/inventory/data/inventory_repository.dart';
import '../../services/dashboard_stats_service.dart';
import '../../services/executive_metrics_service.dart';
import '../../utils/livestock_breed_options.dart';
import '../../utils/feed_source_utils.dart';
import '../../utils/inventory_sale_utils.dart';
import '../../utils/egg_log_utils.dart';
import '../eggs/egg_quick_add_sheet.dart';
import '../feeding/feed_formulation_create_sheet.dart';
import '../worker/widgets/quick_add_batch_grid.dart';
import '../dashboard/mobile_dashboard_host.dart';
import '../inventory/inventory_list_screen.dart';
import '../health/health_screen.dart';
import '../houses/climate_control_screen.dart';
import '../livestock/livestock_hub_screen.dart';
import '../license/soft_lock_banner.dart';
import '../reports/farm_report_screen.dart';
import '../profile/profile_screen.dart';
import '../settings/settings_hub_screen.dart';
import '../settings/trash_screen.dart';
import '../shared/hatchlog_details_popup.dart';
import '../shared/session_mode_badge.dart';

class UniversalMobileDashboard extends StatefulWidget {
  const UniversalMobileDashboard({
    super.key,
    required this.currentUser,
    required this.permissions,
    required this.connectionChanges,
    required this.isOnline,
    required this.onSignOut,
    required this.inputSink,
    required this.managementRepository,
    required this.localDatabase,
    this.showSoftLockBanner = false,
    this.localSalesQueue,
    this.pdfInvoiceService,
    this.onRefreshFromCloud,
    this.remoteApi,
  });

  final AppUser currentUser;
  final FarmPermissions permissions;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final Future<void> Function() onSignOut;
  final WorkerInputSink inputSink;
  final ManagementDataSource managementRepository;
  final LocalDatabase localDatabase;
  final bool showSoftLockBanner;
  final LocalSalesQueue? localSalesQueue;
  final PdfInvoiceService? pdfInvoiceService;
  final Future<void> Function()? onRefreshFromCloud;
  final SupabaseRemoteApi? remoteApi;

  @override
  State<UniversalMobileDashboard> createState() =>
      _UniversalMobileDashboardState();
}

class _UniversalMobileDashboardState extends State<UniversalMobileDashboard> {
  SupabaseClient? _supabase;
  late List<_HatchModuleConfig> _modules;
  late List<_HatchModuleConfig> _visibleModules;
  late Map<String, Stream<List<Map<String, dynamic>>>> _streams;
  StreamSubscription<bool>? _connectionSubscription;
  Map<String, dynamic> _permissions = const <String, dynamic>{};
  Map<String, String> _batchNameById = const {};
  final bool _permissionsLoading = false;
  Object? _permissionError;
  bool _isOnline = true;
  int _selectedIndex = 0;
  late final ExecutiveMetricsService _executiveMetricsService;
  late final DashboardStatsService _dashboardStatsService;
  late final InventoryRepository _inventoryRepository;

  @override
  void initState() {
    super.initState();
    try {
      _supabase = Supabase.instance.client;
    } on Object catch (error) {
      debugPrint('WARN: Supabase unavailable for dashboard streams: $error');
    }
    _modules = _buildModules();
    _loadBatchNameCache();
    _executiveMetricsService = ExecutiveMetricsService(
      widget.localDatabase,
      widget.remoteApi,
    );
    _dashboardStatsService = DashboardStatsService(
      widget.localDatabase,
      widget.remoteApi,
    );
    _inventoryRepository = InventoryRepository(widget.localDatabase);
    _permissions = widget.permissions.toMap();
    _visibleModules = _buildFencedModules(_modules, _permissions);
    _streams = {
      for (final module in _visibleModules)
        if (!module.isDashboard) module.table: _streamFor(module),
    };
    widget.isOnline().then((online) {
      if (mounted) {
        setState(() => _isOnline = online);
      }
    });
    _connectionSubscription = widget.connectionChanges.listen((online) {
      if (mounted) {
        setState(() => _isOnline = online);
      }
    });
  }

  Map<String, Stream<List<Map<String, dynamic>>>> _buildStreams(
    List<_HatchModuleConfig> modules,
  ) {
    return {
      for (final module in modules)
        if (!module.isDashboard && !module.isPermissionAdmin)
          module.table: _streamFor(module),
    };
  }

  List<_HatchModuleConfig> _buildFencedModules(
    List<_HatchModuleConfig> modules,
    Map<String, dynamic> permissions,
  ) {
    final privileged = _isPrivilegedRole(widget.currentUser.role);
    return modules
        .where((module) {
          if (module.isPermissionAdmin) {
            return widget.currentUser.role == UserRole.owner;
          }
          if (module.isDashboard) {
            return true;
          }
          if (privileged) {
            return true;
          }
          return _hasModulePermission(
            permissions,
            module.viewPermissionKey,
            module.viewPermissionAliases,
          );
        })
        .toList(growable: false);
  }

  @override
  void didUpdateWidget(covariant UniversalMobileDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.permissions != widget.permissions) {
      _permissions = widget.permissions.toMap();
      _visibleModules = _buildFencedModules(_modules, _permissions);
      _streams = _buildStreams(_visibleModules);
      _selectedIndex = _clampedIndex(_selectedIndex, _visibleModules);
    }
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  Stream<List<Map<String, dynamic>>> _streamFor(_HatchModuleConfig module) {
    if (module.table == 'houses') {
      return widget.localDatabase
          .watchTables(const ['houses', 'batches'])
          .asyncMap((_) => _loadLocalHouseRows())
          .asBroadcastStream();
    }

    final supabase = _supabase;
    if (supabase == null) {
      return Stream<List<Map<String, dynamic>>>.empty().asBroadcastStream();
    }
    final activeFarmId = _activeFarmId(supabase);
    if (activeFarmId.isEmpty || module.tenantColumn == null) {
      return Stream<List<Map<String, dynamic>>>.empty().asBroadcastStream();
    }

    final stream = supabase
        .from(module.table)
        .stream(primaryKey: ['id'])
        .eq(module.tenantColumn!, activeFarmId)
        .order(module.orderBy, ascending: false)
        .limit(100);
    if (module.streamEquals.isEmpty) {
      return stream.asBroadcastStream();
    }
    return stream
        .map((rows) => _applyEqualsFilters(rows, module.streamEquals))
        .asBroadcastStream();
  }

  String _activeFarmId(SupabaseClient supabase) {
    return resolveActiveFarmId(
      user: widget.currentUser,
      supabase: supabase,
    );
  }

  String _dashboardFarmId() {
    final supabase = _supabase;
    if (supabase != null) {
      final resolved = _activeFarmId(supabase);
      if (resolved.isNotEmpty) {
        return resolved;
      }
    }
    return widget.currentUser.activeFarmId;
  }

  Future<void> _loadBatchNameCache() async {
    final farmId = _dashboardFarmId();
    if (farmId.isEmpty) {
      return;
    }

    try {
      final rows = await widget.localDatabase.rawLocalQuery(
        '''
        select id, batch_name
        from batches
        where farm_id = ? and is_deleted = 0
        order by batch_name asc
        ''',
        [farmId],
      );
      final names = <String, String>{};
      for (final row in rows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) {
          continue;
        }
        final name = row['batch_name']?.toString().trim() ?? '';
        names[id] = name.isEmpty ? 'Batch' : name;
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _batchNameById = names;
        _modules = _buildModules(_batchNameById);
        _visibleModules = _buildFencedModules(_modules, _permissions);
      });
    } on Object catch (error) {
      debugPrint('WARN: Failed to load batch name cache: $error');
    }
  }

  Future<List<Map<String, dynamic>>> _loadLocalHouseRows() async {
    final farmId = widget.currentUser.activeFarmId;
    if (farmId.isEmpty) {
      return const [];
    }

    final rows = await widget.localDatabase.rawLocalQuery(
      '''
      select h.*,
             coalesce(sum(case when b.is_deleted = 0 then b.current_count else 0 end), 0) as occupied
      from houses h
      left join batches b on b.house_id = h.id
      where h.farm_id = ?
        and coalesce(h.is_deleted, 0) = 0
      group by h.id
      order by h.name asc
      ''',
      [farmId],
    );

    return rows
        .map(
          (row) => {
            'id': row['id'],
            'farmId': row['farm_id'],
            'userId': row['user_id'],
            'name': row['name'],
            'capacity': row['capacity'],
            'currentTemperature': row['current_temperature'],
            'currentHumidity': row['current_humidity'],
            'isIsolation': (row['is_isolation'] as int? ?? 0) == 1,
            'environmental_state': row['environmental_state'],
            'currentPopulation': row['occupied'],
            'createdAt': row['created_at'],
            'updatedAt': row['updated_at'],
          },
        )
        .toList(growable: false);
  }

  Future<void> _insertRow(
    _HatchModuleConfig module,
    Map<String, dynamic> row,
  ) async {
    if (module.table == 'houses') {
      final service = LocalHouseService(widget.localDatabase);
      await service.createHouse(
        farmId: widget.currentUser.activeFarmId,
        userId: widget.currentUser.id,
        name: _objectText(row['name'] ?? row['house_number']),
        capacity: _objectInt(row['capacity']),
        isIsolation: _objectBool(row['isIsolation'] ?? row['is_isolation']),
        currentTemperature: _nullablePayloadDouble(
          row['currentTemperature'] ?? row['current_temperature'],
        ),
        currentHumidity: _nullablePayloadDouble(
          row['currentHumidity'] ?? row['current_humidity'],
        ),
      );
      return;
    }

    if (module.table == 'feed_formulations') {
      final ingredients = (row['ingredients'] as List<dynamic>? ?? const [])
          .map(
            (item) => FeedFormulationIngredientInput(
              inventoryId: _objectText(
                (item as Map)['inventoryId'] ?? item['inventory_id'],
              ),
              bags: _objectDouble(item['bags'] ?? item['quantity']),
            ),
          )
          .toList();
      final service = FeedFormulationService(widget.localDatabase);
      await service.createFormulation(
        farmId: widget.currentUser.activeFarmId,
        name: _objectText(row['name']),
        type: _objectText(row['type']).isEmpty ? 'CUSTOM' : _objectText(row['type']),
        targetLivestock: _objectText(
          row['targetLivestock'] ?? row['target_livestock'],
        ),
        ingredients: ingredients,
        supabase: _supabase,
      );
      return;
    }

    final queuedInput = _queuedWorkerInputFor(module, row);
    if (queuedInput != null) {
      await widget.inputSink.enqueueWorkerInput(
        user: widget.currentUser,
        type: queuedInput.type,
        payload: queuedInput.payload,
      );
      return;
    }

    final supabase = _supabase;
    if (supabase == null) {
      throw Exception('Supabase is not initialized for this session.');
    }

    final authUser = supabase.auth.currentUser;
    if (authUser == null) {
      throw Exception('No active Supabase session is available.');
    }

    final activeTenantId = _activeFarmId(supabase);
    final createdBy = authUser.id.isNotEmpty
        ? authUser.id
        : widget.currentUser.id;
    final metadata = <String, dynamic>{};
    if (module.tenantColumn != null && activeTenantId.isNotEmpty) {
      metadata[module.tenantColumn!] = activeTenantId;
    }
    if (module.creatorColumn != null && createdBy.isNotEmpty) {
      metadata[module.creatorColumn!] = createdBy;
    }

    final recordId = row['id']?.toString() ?? _newTextId(module.table);

    await supabase.from(module.table).insert({
      'id': recordId,
      ...metadata,
      ...row,
    });

    if (module.table == 'batches') {
      await _mirrorBatchToLocal(
        row: {
          'id': recordId,
          ...metadata,
          ...row,
        },
        farmId: activeTenantId,
        userId: createdBy,
      );
    }
  }

  Future<void> _mirrorBatchToLocal({
    required Map<String, dynamic> row,
    required String farmId,
    required String userId,
  }) async {
    if (farmId.isEmpty) {
      return;
    }
    final now = DateTime.now().toIso8601String();
    final status = _objectText(row['status']);
    await widget.localDatabase.insertLocalRecord('batches', {
      'id': _objectText(row['id']),
      'farm_id': farmId,
      'house_id': _objectText(row['houseId'] ?? row['house_id']),
      'user_id': userId,
      'batch_name': _objectText(row['batchName'] ?? row['batch_name']),
      'breed_type': _objectText(row['breedType'] ?? row['breed_type']),
      'bird_strain': _objectText(row['breedType'] ?? row['breed_type']),
      'type': _objectText(row['type']),
      'status': status.isEmpty ? 'active' : status,
      'active_state': status.isEmpty ? 'active' : status,
      'current_count': _objectInt(row['currentCount'] ?? row['current_count']),
      'initial_count': _objectInt(row['initialCount'] ?? row['initial_count']),
      'isolation_count': _objectInt(
        row['isolationCount'] ?? row['isolation_count'],
      ),
      'arrival_date': _objectText(
        row['arrivalDate'] ?? row['arrival_date'],
      ).isEmpty
          ? now
          : _objectText(row['arrivalDate'] ?? row['arrival_date']),
      'is_deleted': 0,
      'created_at': _objectText(row['createdAt'] ?? row['created_at']).isEmpty
          ? now
          : _objectText(row['createdAt'] ?? row['created_at']),
      'updated_at': _objectText(row['updatedAt'] ?? row['updated_at']).isEmpty
          ? now
          : _objectText(row['updatedAt'] ?? row['updated_at']),
    });
  }

  _QueuedWorkerInput? _queuedWorkerInputFor(
    _HatchModuleConfig module,
    Map<String, dynamic> row,
  ) {
    switch (module.table) {
      case 'egg_production':
        return _QueuedWorkerInput(
          type: WorkerInputType.eggCollection,
          payload: buildEggLogPayload(
            batchId: _objectText(row['batchId'] ?? row['batch_id']),
            eggsCollected: _objectInt(
              row['eggsCollected'] ?? row['eggs_collected'],
            ),
            unusableCount: _objectInt(
              row['unusableCount'] ?? row['unusable_count'],
            ),
            isSorted: _objectBool(row['isSorted'] ?? row['is_sorted']),
            qualityGrade: _objectText(row['qualityGrade'] ?? row['quality_grade']),
            smallCount: _objectInt(row['smallCount'] ?? row['small_count']),
            mediumCount: _objectInt(row['mediumCount'] ?? row['medium_count']),
            largeCount: _objectInt(row['largeCount'] ?? row['large_count']),
            logDate: _objectText(row['logDate'] ?? row['log_date']).isEmpty
                ? DateTime.now()
                : DateTime.parse(_objectText(row['logDate'] ?? row['log_date'])),
            useCrates: _objectDouble(
                  row['cratesCollected'] ?? row['crates_collected'],
                ) >
                0,
            crates: _objectDouble(
              row['cratesCollected'] ?? row['crates_collected'],
            ).round(),
            remainder: _objectInt(row['eggsCollected'] ?? row['eggs_collected']) %
                defaultEggsPerCrate,
          ),
        );
      case 'daily_feeding_logs':
        return _QueuedWorkerInput(
          type: WorkerInputType.feedUsage,
          payload: {
            'batch_id': _objectText(row['batch_id'] ?? row['batchId']),
            'amount_consumed': _objectDouble(
              row['amount_consumed'] ?? row['sacks_used'],
            ),
            'bags': _objectDouble(row['amount_consumed'] ?? row['sacks_used']),
            'feed_type': _objectText(
              row['feed_type_label'] ?? row['feed_type'] ?? row['feed_variant'],
            ),
            'feed_type_id': _objectText(row['feed_type_id']),
            'formulation_id': _objectText(row['formulation_id']),
            'note': _objectText(row['note'] ?? row['notes']),
            'log_date':
                _objectText(row['log_date'] ?? row['logged_at']).isEmpty
                ? DateTime.now().toIso8601String()
                : _objectText(row['log_date'] ?? row['logged_at']),
          },
        );
      case 'mortality':
        if (_objectText(row['type']).toUpperCase() != 'DEAD') {
          return null;
        }
        return _QueuedWorkerInput(
          type: WorkerInputType.mortality,
          payload: {
            'batch_id': _objectText(row['batchId'] ?? row['batch_id']),
            'count': _objectInt(row['count'] ?? row['dead_count']),
            'reason': _objectText(row['reason'] ?? row['suspected_cause']),
            'category': _objectText(row['category']),
            'sub_category': _objectText(row['sub_category']),
            'device_logged_at':
                _objectText(row['logDate'] ?? row['log_date']).isEmpty
                ? DateTime.now().toIso8601String()
                : _objectText(row['logDate'] ?? row['log_date']),
          },
        );
    }
    return null;
  }

  Future<void> _openEntryForm(_HatchModuleConfig module) async {
    HapticFeedback.lightImpact();
    if (module.table == 'egg_production') {
      await _openEggEntryForm(module);
      return;
    }
    if (module.table == 'feed_formulations') {
      await _openFeedFormulationForm(module);
      return;
    }

    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _ModuleEntrySheet(
          module: module,
          localDatabase: widget.localDatabase,
          currentUser: widget.currentUser,
          onSubmit: (payload) => _insertRow(module, module.toRow(payload)),
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

  Future<void> _openFeedFormulationForm(_HatchModuleConfig module) async {
    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FeedFormulationCreateSheet(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          supabase: _supabase,
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

  Future<void> _openEggEntryForm(_HatchModuleConfig module) async {
    final batchRows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, batch_name, breed_type, current_count, house_id
      from batches
      where farm_id = ?
        and is_deleted = 0
        and lower(coalesce(status, '')) = 'active'
        and upper(coalesce(type, '')) = 'POULTRY_LAYER'
      order by batch_name asc
      ''',
      [widget.currentUser.activeFarmId],
    );
    final batches = batchRows
        .map(
          (row) => BatchSummary(
            id: row['id']?.toString() ?? '',
            batchLabel: row['batch_name']?.toString() ?? 'Layer batch',
            livestockType: row['breed_type']?.toString() ?? 'POULTRY_LAYER',
            currentCount: int.tryParse(row['current_count']?.toString() ?? '') ?? 0,
            houseId: row['house_id']?.toString() ?? '',
          ),
        )
        .where((batch) => batch.id.isNotEmpty)
        .toList();

    if (!mounted) {
      return;
    }

    if (batches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No active layer batches are available.'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

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
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              child: SafeArea(
                top: false,
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
                  children: [
                    Row(
                      children: [
                        Icon(module.icon, color: module.color),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            module.title,
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
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
                      batches: batches,
                      accentColor: module.color,
                      icon: module.icon,
                      emptyMessage: 'No active layer batches found.',
                      onTapAdd: (batch) async {
                        Navigator.of(context).pop();
                        final saved = await showModalBottomSheet<bool>(
                          context: this.context,
                          isScrollControlled: true,
                          useSafeArea: true,
                          backgroundColor: Colors.transparent,
                          builder: (context) => EggQuickAddSheet(
                            currentUser: widget.currentUser,
                            batch: batch,
                            inputSink: widget.inputSink,
                          ),
                        );
                        if (!mounted || saved != true) {
                          return;
                        }
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          SnackBar(
                            content: Text(module.successMessage),
                            behavior: SnackBarBehavior.floating,
                          ),
                        );
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

  Future<void> _signOut() async {
    HapticFeedback.lightImpact();
    await widget.onSignOut();
  }

  Future<void> _openInventoryHub() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => InventoryListScreen(
          currentUser: widget.currentUser,
          inventoryRepository: _inventoryRepository,
        ),
      ),
    );
  }

  Future<void> _openHealthHub() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => HealthScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          canEdit: widget.permissions.canEditHealth,
        ),
      ),
    );
  }

  Future<void> _openAnalytics() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FarmAnalyticsScreen(
          currentUser: widget.currentUser,
          managementRepository: widget.managementRepository,
        ),
      ),
    );
  }

  Future<void> _openBatchCompare() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => BatchCompareScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  Future<void> _openClimate() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ClimateControlScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          canEdit: widget.permissions.canEditHouses,
        ),
      ),
    );
  }

  Future<void> _openFarmReport() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => FarmReportScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          permissions: widget.permissions,
        ),
      ),
    );
  }

  Future<void> _openTrash() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TrashScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  Future<void> _openSettings() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => SettingsHubScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
          onOpenProfile: _openProfile,
        ),
      ),
    );
  }

  Future<void> _openProfile() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).maybePop();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => ProfileScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  Future<void> _refreshDashboard() async {
    HapticFeedback.lightImpact();
    setState(() {
      _permissions = widget.permissions.toMap();
      _visibleModules = _buildFencedModules(_modules, _permissions);
      _streams = _buildStreams(_visibleModules);
      _selectedIndex = _clampedIndex(_selectedIndex, _visibleModules);
    });
    await _loadBatchNameCache();
    final refresh = widget.onRefreshFromCloud;
    if (refresh != null) {
      await refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final module = _visibleModules[_selectedIndex];
    final canEditSelectedModule = _canEditModule(module);

    return Scaffold(
      backgroundColor: _UniversalColors.background,
      drawer: _UniversalDrawer(
        currentUser: widget.currentUser,
        modules: _visibleModules,
        selectedIndex: _selectedIndex,
        onSelected: (index) {
          HapticFeedback.lightImpact();
          setState(() => _selectedIndex = index);
          Navigator.of(context).maybePop();
        },
        onOpenAnalytics: () {
          _openAnalytics();
        },
        onOpenBatchCompare: widget.permissions.canViewBatches
            ? _openBatchCompare
            : null,
        onOpenInventoryHub: widget.permissions.canViewInventory
            ? _openInventoryHub
            : null,
        onOpenHealthHub: widget.permissions.canViewHealth
            ? _openHealthHub
            : null,
        onOpenClimate: widget.permissions.canViewHouses ? _openClimate : null,
        onOpenFarmReport: widget.permissions.canViewFinance
            ? _openFarmReport
            : null,
        onOpenTrash:
            widget.currentUser.role == UserRole.owner ||
                widget.currentUser.role == UserRole.manager
            ? _openTrash
            : null,
        onOpenSettings:
            widget.currentUser.role == UserRole.owner ||
                widget.currentUser.role == UserRole.manager
            ? _openSettings
            : null,
        onOpenProfile: _openProfile,
        onSignOut: _signOut,
      ),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(module.title),
        actions: [
          IconButton(
            tooltip: 'Refresh streams',
            onPressed: _refreshDashboard,
            icon: const Icon(Icons.sync),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _signOut,
            icon: const Icon(Icons.logout),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(94),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: SessionModeBadge(
                    isOnline: _isOnline,
                    authenticatedOffline:
                        widget.currentUser.authenticatedOffline,
                  ),
                ),
              ),
              _ModuleTabStrip(
                modules: _visibleModules,
                selectedIndex: _selectedIndex,
                onSelected: (index) {
                  HapticFeedback.selectionClick();
                  setState(() => _selectedIndex = index);
                },
              ),
            ],
          ),
        ),
      ),
      floatingActionButton:
          module.isDashboard ||
              module.isPermissionAdmin ||
              module.isLivestockHub ||
              !canEditSelectedModule
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEntryForm(module),
              icon: const Icon(Icons.add),
              label: Text('Add ${module.shortLabel}'),
            ),
      body: SafeArea(
        child: Column(
          children: [
            if (widget.showSoftLockBanner) const SoftLockBanner(),
            Expanded(
              child: module.isDashboard
                  ? MobileDashboardHost(
                      localDatabase: widget.localDatabase,
                      dashboardStatsService: _dashboardStatsService,
                      executiveMetricsService: _executiveMetricsService,
                      permissions: widget.permissions,
                      activeFarmId: _dashboardFarmId(),
                      activeFarmNameFallback: widget.currentUser.activeFarmName,
                      displayName: widget.currentUser.displayName,
                      role: widget.currentUser.role,
                      permissionError: _permissionError,
                      permissionsLoading: _permissionsLoading,
                      onRefreshFromCloud: widget.onRefreshFromCloud,
                    )
                  : module.isPermissionAdmin
                  ? _OwnerPermissionsControlPanel(
                      supabase: _supabase,
                      activeFarmId: _supabase == null
                          ? widget.currentUser.activeFarmId
                          : _activeFarmId(_supabase!),
                      currentUser: widget.currentUser,
                    )
                  : module.isLivestockHub
                  ? LivestockHubScreen(
                      currentUser: widget.currentUser,
                      permissions: widget.permissions,
                      localDatabase: widget.localDatabase,
                      remoteApi: widget.remoteApi,
                      onRefreshFromCloud: widget.onRefreshFromCloud,
                      inputSink: widget.inputSink,
                      localSalesQueue: widget.localSalesQueue,
                      pdfInvoiceService: widget.pdfInvoiceService,
                    )
                  : _ModuleDataView(
                      key: ValueKey(module.table),
                      module: module,
                      stream: _streams[module.table]!,
                      onRefresh: widget.onRefreshFromCloud,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  bool _canEditModule(_HatchModuleConfig module) {
    if (_isPrivilegedRole(widget.currentUser.role)) {
      return true;
    }
    return _hasModulePermission(
      _permissions,
      module.editPermissionKey,
      module.editPermissionAliases,
    );
  }
}

bool _hasModulePermission(
  Map<String, dynamic> permissions,
  String? primaryKey,
  List<String> aliases,
) {
  if (primaryKey != null && _permissionEnabled(permissions[primaryKey])) {
    return true;
  }
  for (final alias in aliases) {
    if (_permissionEnabled(permissions[alias])) {
      return true;
    }
  }
  return false;
}

bool _isPrivilegedRole(UserRole role) {
  return role == UserRole.owner || role == UserRole.admin;
}

bool _permissionEnabled(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes' || text == 'y';
}

int _clampedIndex(int selectedIndex, List<_HatchModuleConfig> modules) {
  if (modules.isEmpty) {
    return 0;
  }
  if (selectedIndex < 0) {
    return 0;
  }
  if (selectedIndex >= modules.length) {
    return modules.length - 1;
  }
  return selectedIndex;
}

T? _firstWhereOrNull<T>(Iterable<T> values, bool Function(T value) test) {
  for (final value in values) {
    if (test(value)) {
      return value;
    }
  }
  return null;
}

String _newTextId(String prefix) {
  final random = Random.secure();
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${prefix}_${DateTime.now().microsecondsSinceEpoch}_$suffix';
}


List<Map<String, dynamic>> _applyEqualsFilters(
  List<Map<String, dynamic>> rows,
  Map<String, Object> equals,
) {
  return rows
      .where((row) {
        for (final filter in equals.entries) {
          if (row[filter.key]?.toString().toLowerCase() !=
              filter.value.toString().toLowerCase()) {
            return false;
          }
        }
        return true;
      })
      .toList(growable: false);
}

bool _isLoading(AsyncSnapshot<Object?> snapshot) {
  return snapshot.connectionState == ConnectionState.waiting &&
      !snapshot.hasData;
}

class _OwnerPermissionsControlPanel extends StatefulWidget {
  const _OwnerPermissionsControlPanel({
    required this.supabase,
    required this.activeFarmId,
    required this.currentUser,
  });

  final SupabaseClient? supabase;
  final String activeFarmId;
  final AppUser currentUser;

  @override
  State<_OwnerPermissionsControlPanel> createState() =>
      _OwnerPermissionsControlPanelState();
}

class _OwnerPermissionsControlPanelState
    extends State<_OwnerPermissionsControlPanel> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  String? _selectedUserId;
  bool _saving = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.currentUser.role != UserRole.owner) {
      return const Center(
        child: _StatePanel(
          icon: Icons.lock_outline,
          title: 'Owner access required',
          message: 'Only farm owners can change operator permissions.',
        ),
      );
    }
    final supabase = widget.supabase;
    if (supabase == null || widget.activeFarmId.isEmpty) {
      return const Center(
        child: _StatePanel(
          icon: Icons.sync_problem_outlined,
          title: 'Permissions unavailable',
          message: 'No active Supabase farm session is available.',
        ),
      );
    }

    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: supabase
          .from('farm_members')
          .stream(primaryKey: ['id'])
          .eq('farmId', widget.activeFarmId)
          .order('role'),
      builder: (context, membersSnapshot) {
        if (membersSnapshot.hasError) {
          return Center(
            child: _StatePanel(
              icon: Icons.sync_problem_outlined,
              title: 'Data Sync Interrupted',
              message: membersSnapshot.error.toString(),
            ),
          );
        }
        if (_isLoading(membersSnapshot)) {
          return const Center(child: CircularProgressIndicator());
        }

        final memberRows = membersSnapshot.data ?? const <Map<String, dynamic>>[];
        final memberIds = memberRows
            .map((row) => _text(row, const ['userId', 'user_id']))
            .where((id) => id.isNotEmpty)
            .toList(growable: false);

        return FutureBuilder<Map<String, String>>(
          future: _loadMemberDisplayNames(supabase, memberIds),
          builder: (context, namesSnapshot) {
            final displayNames = namesSnapshot.data ?? const {};
            final members = memberRows
                .map((row) => _TeamMemberVm.fromRow(row, displayNames: displayNames))
                .where((member) {
                  if (member.userId == widget.currentUser.id) return false;
                  final q = _query.trim().toLowerCase();
                  return q.isEmpty || member.searchText.contains(q);
                })
                .toList(growable: false);
            final selected = _firstWhereOrNull(
              members,
              (member) => member.userId == _selectedUserId,
            );
            final effectiveSelected =
                selected ?? (members.isEmpty ? null : members.first);
            _selectedUserId = effectiveSelected?.userId;

            return StreamBuilder<List<Map<String, dynamic>>>(
              stream: supabase
                  .from('user_permissions')
                  .stream(primaryKey: ['id'])
                  .eq('farm_id', widget.activeFarmId),
              builder: (context, permissionSnapshot) {
                if (permissionSnapshot.hasError) {
                  return Center(
                    child: _StatePanel(
                      icon: Icons.sync_problem_outlined,
                      title: 'Data Sync Interrupted',
                      message: permissionSnapshot.error.toString(),
                    ),
                  );
                }

                final permissionRows =
                    permissionSnapshot.data ?? const <Map<String, dynamic>>[];
                final selectedPermissions = _firstWhereOrNull(
                  permissionRows,
                  (row) =>
                      _text(row, const ['user_id']) ==
                      (effectiveSelected?.userId ?? ''),
                );

                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
                  children: [
                    _PermissionsHeader(
                      searchController: _searchController,
                      onSearchChanged: (value) => setState(() => _query = value),
                    ),
                    const SizedBox(height: 14),
                    if (members.isEmpty)
                      const _StatePanel(
                        icon: Icons.people_outline,
                        title: 'No operators found',
                        message:
                            'Invite workers, accountants, or managers before assigning access rights.',
                      )
                    else ...[
                      SizedBox(
                        height: 92,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: members.length,
                          separatorBuilder: (context, index) =>
                              const SizedBox(width: 10),
                          itemBuilder: (context, index) {
                            final member = members[index];
                            return _OperatorChip(
                              member: member,
                              selected: member.userId == _selectedUserId,
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _selectedUserId = member.userId);
                              },
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 14),
                      _PermissionMatrixCard(
                        member: effectiveSelected!,
                        permissions: selectedPermissions,
                        saving: _saving || _isLoading(permissionSnapshot),
                        onChanged: (column, value) => _updateOperatorPermission(
                          effectiveSelected.userId,
                          column,
                          value,
                          selectedPermissions,
                        ),
                      ),
                    ],
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Future<Map<String, String>> _loadMemberDisplayNames(
    SupabaseClient supabase,
    List<String> userIds,
  ) async {
    final ids = userIds.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) {
      return const {};
    }

    try {
      final rows = await supabase
          .from('users')
          .select('id, firstname, surname, name, phone_number')
          .inFilter('id', ids.toList());
      final names = <String, String>{};
      for (final row in rows) {
        final userId = _text(row, const ['id']);
        if (userId.isEmpty) {
          continue;
        }
        final fullName = _text(row, const ['name']).trim();
        if (fullName.isNotEmpty) {
          names[userId] = fullName;
          continue;
        }
        final composed =
            '${_text(row, const ['firstname'])} ${_text(row, const ['surname'])}'
                .trim();
        if (composed.isNotEmpty) {
          names[userId] = composed;
          continue;
        }
        final phone = _text(row, const ['phone_number']).trim();
        names[userId] = phone.isNotEmpty ? phone : 'Team member';
      }
      return names;
    } on Object {
      return const {};
    }
  }

  Future<void> _updateOperatorPermission(
    String userId,
    String targetPermissionColumn,
    bool newValue,
    Map<String, dynamic>? existingPermissions,
  ) async {
    final supabase = widget.supabase;
    if (supabase == null || widget.activeFarmId.isEmpty) return;
    setState(() => _saving = true);
    try {
      if (existingPermissions == null) {
        await supabase.from('user_permissions').insert({
          'id': _newTextId('perm'),
          'user_id': userId,
          'farm_id': widget.activeFarmId,
          for (final permission in _permissionColumns) permission.column: false,
          targetPermissionColumn: newValue,
        });
      } else {
        await supabase
            .from('user_permissions')
            .update({targetPermissionColumn: newValue})
            .eq('user_id', userId)
            .eq('farm_id', widget.activeFarmId);
      }
      debugPrint(
        'HatchLog Security: Permission $targetPermissionColumn updated to $newValue.',
      );
    } on Object catch (error) {
      debugPrint(
        'HatchLog Security Failure: Could not commit RBAC modification -> $error',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Permission update failed: ${_friendlyError(error)}'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }
}

class _PermissionsHeader extends StatelessWidget {
  const _PermissionsHeader({
    required this.searchController,
    required this.onSearchChanged,
  });

  final TextEditingController searchController;
  final ValueChanged<String> onSearchChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          const Row(
            children: [
              Icon(Icons.admin_panel_settings_outlined),
              SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Administrative Permissions Control',
                  style: TextStyle(
                    color: _UniversalColors.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          TextField(
            controller: searchController,
            onChanged: onSearchChanged,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              labelText: 'Search operators',
              filled: true,
              fillColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}

class _OperatorChip extends StatelessWidget {
  const _OperatorChip({
    required this.member,
    required this.selected,
    required this.onTap,
  });

  final _TeamMemberVm member;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? _UniversalColors.ink : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected ? _UniversalColors.ink : const Color(0xffe4e9ed),
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: selected
                  ? Colors.white24
                  : const Color(0xffeef2f5),
              foregroundColor: selected ? Colors.white : _UniversalColors.ink,
              child: const Icon(Icons.person_outline),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    member.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white : _UniversalColors.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    member.roleLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: selected ? Colors.white70 : _UniversalColors.muted,
                      fontWeight: FontWeight.w700,
                    ),
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

class _PermissionMatrixCard extends StatelessWidget {
  const _PermissionMatrixCard({
    required this.member,
    required this.permissions,
    required this.saving,
    required this.onChanged,
  });

  final _TeamMemberVm member;
  final Map<String, dynamic>? permissions;
  final bool saving;
  final void Function(String column, bool value) onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: _panelDecoration(),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(Icons.fact_check_outlined),
            title: Text(
              '${member.label} Access Matrix',
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
            subtitle: Text(
              saving
                  ? 'Committing permission changes...'
                  : 'Toggle each module right for this farm operator.',
            ),
          ),
          const Divider(height: 1),
          for (final permission in _permissionColumns)
            SwitchListTile(
              value: _permissionEnabled(permissions?[permission.column]),
              title: Text(permission.label),
              secondary: Icon(permission.icon),
              onChanged: saving
                  ? null
                  : (value) => onChanged(permission.column, value),
            ),
        ],
      ),
    );
  }
}

class _TeamMemberVm {
  const _TeamMemberVm({
    required this.userId,
    required this.roleLabel,
    required this.label,
  });

  final String userId;
  final String roleLabel;
  final String label;

  String get searchText => '$label $roleLabel $userId'.toLowerCase();

  static _TeamMemberVm fromRow(
    Map<String, dynamic> row, {
    Map<String, String> displayNames = const {},
  }) {
    final userId = _text(row, const ['userId', 'user_id']);
    final role = UserRole.fromString(_text(row, const ['role']));
    final resolvedName = displayNames[userId]?.trim() ?? '';
    return _TeamMemberVm(
      userId: userId,
      roleLabel: role.label,
      label: resolvedName.isNotEmpty ? resolvedName : 'Team member',
    );
  }
}

class _PermissionColumnSpec {
  const _PermissionColumnSpec(this.column, this.label, this.icon);

  final String column;
  final String label;
  final IconData icon;
}

const _permissionColumns = [
  _PermissionColumnSpec(
    'can_view_finance',
    'View Finance',
    Icons.account_balance_wallet_outlined,
  ),
  _PermissionColumnSpec(
    'can_edit_finance',
    'Edit Finance',
    Icons.account_balance_wallet,
  ),
  _PermissionColumnSpec(
    'can_view_inventory',
    'View Inventory',
    Icons.warehouse_outlined,
  ),
  _PermissionColumnSpec(
    'can_edit_inventory',
    'Edit Inventory',
    Icons.inventory_2,
  ),
  _PermissionColumnSpec(
    'can_view_batches',
    'View Livestock',
    Icons.groups_3_outlined,
  ),
  _PermissionColumnSpec('can_edit_batches', 'Edit Livestock', Icons.groups_3),
  _PermissionColumnSpec('can_view_sales', 'View Sales', Icons.receipt_long),
  _PermissionColumnSpec('can_edit_sales', 'Edit Sales', Icons.point_of_sale),
  _PermissionColumnSpec('can_view_eggs', 'View Eggs', Icons.egg_alt_outlined),
  _PermissionColumnSpec('can_edit_eggs', 'Edit Eggs', Icons.egg_alt),
  _PermissionColumnSpec(
    'can_view_feeding',
    'View Feeding',
    Icons.inventory_2_outlined,
  ),
  _PermissionColumnSpec('can_edit_feeding', 'Edit Feeding', Icons.restaurant),
  _PermissionColumnSpec(
    'can_view_houses',
    'View Houses',
    Icons.home_work_outlined,
  ),
  _PermissionColumnSpec('can_edit_houses', 'Edit Houses', Icons.home_work),
  _PermissionColumnSpec(
    'can_view_mortality',
    'View Mortality and Quarantine',
    Icons.warning_amber_rounded,
  ),
  _PermissionColumnSpec(
    'can_edit_mortality',
    'Edit Mortality and Quarantine',
    Icons.health_and_safety_outlined,
  ),
  _PermissionColumnSpec(
    'can_view_health',
    'View Health (Vaccines & Meds)',
    Icons.vaccines_outlined,
  ),
  _PermissionColumnSpec(
    'can_edit_health',
    'Edit Health (Vaccines & Meds)',
    Icons.medical_services_outlined,
  ),
  _PermissionColumnSpec(
    'can_view_customers',
    'View Customers',
    Icons.contacts_outlined,
  ),
  _PermissionColumnSpec('can_edit_customers', 'Edit Customers', Icons.contacts),
  _PermissionColumnSpec('can_view_team', 'View Team', Icons.people_outline),
  _PermissionColumnSpec('can_edit_team', 'Edit Team', Icons.manage_accounts),
];

class _UniversalDrawer extends StatelessWidget {
  const _UniversalDrawer({
    required this.currentUser,
    required this.modules,
    required this.selectedIndex,
    required this.onSelected,
    required this.onOpenAnalytics,
    this.onOpenBatchCompare,
    this.onOpenInventoryHub,
    this.onOpenHealthHub,
    this.onOpenClimate,
    this.onOpenFarmReport,
    this.onOpenTrash,
    this.onOpenSettings,
    this.onOpenProfile,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final List<_HatchModuleConfig> modules;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final VoidCallback onOpenAnalytics;
  final VoidCallback? onOpenBatchCompare;
  final VoidCallback? onOpenInventoryHub;
  final VoidCallback? onOpenHealthHub;
  final VoidCallback? onOpenClimate;
  final VoidCallback? onOpenFarmReport;
  final VoidCallback? onOpenTrash;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onOpenProfile;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              color: _UniversalColors.ink,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    Icons.agriculture_outlined,
                    color: Colors.white,
                    size: 34,
                  ),
                  const SizedBox(height: 14),
                  Text(
                    currentUser.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Universal HatchLog workspace',
                    style: TextStyle(
                      color: Colors.white70,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 10),
                children: [
                  for (var index = 0; index < modules.length; index += 1)
                    ListTile(
                      selected: index == selectedIndex,
                      leading: Icon(modules[index].icon),
                      title: Text(modules[index].title),
                      subtitle: Text(modules[index].subtitle),
                      onTap: () => onSelected(index),
                    ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.bar_chart),
                    title: const Text('Farm Analytics'),
                    subtitle: const Text(
                      'Charts for eggs, losses, feed, and cash',
                    ),
                    onTap: onOpenAnalytics,
                  ),
                  if (onOpenBatchCompare != null)
                    ListTile(
                      leading: const Icon(Icons.compare_arrows),
                      title: const Text('Compare Batches'),
                      subtitle: const Text(
                        'FCR, mortality, eggs, and finance side-by-side',
                      ),
                      onTap: onOpenBatchCompare,
                    ),
                  if (onOpenInventoryHub != null)
                    ListTile(
                      leading: const Icon(Icons.inventory_2_outlined),
                      title: const Text('Inventory Hub'),
                      subtitle: const Text(
                        'In stock, used up, and usage history',
                      ),
                      onTap: onOpenInventoryHub,
                    ),
                  if (onOpenHealthHub != null)
                    ListTile(
                      leading: const Icon(Icons.vaccines_outlined),
                      title: const Text('Health Schedules'),
                      subtitle: const Text(
                        'Vaccination and medication planning',
                      ),
                      onTap: onOpenHealthHub,
                    ),
                  if (onOpenClimate != null)
                    ListTile(
                      leading: const Icon(Icons.thermostat_outlined),
                      title: const Text('Climate Control'),
                      subtitle: const Text('House temperature and humidity'),
                      onTap: onOpenClimate,
                    ),
                  if (onOpenFarmReport != null)
                    ListTile(
                      leading: const Icon(Icons.picture_as_pdf_outlined),
                      title: const Text('Farm Report'),
                      subtitle: const Text(
                        'Revenue, expenses, batches, inventory',
                      ),
                      onTap: onOpenFarmReport,
                    ),
                  if (onOpenTrash != null)
                    ListTile(
                      leading: const Icon(Icons.restore_from_trash_outlined),
                      title: const Text('Data Recovery'),
                      subtitle: const Text('Restore locally deleted records'),
                      onTap: onOpenTrash,
                    ),
                  if (onOpenSettings != null)
                    ListTile(
                      leading: const Icon(Icons.settings_outlined),
                      title: const Text('Farm Settings'),
                      subtitle: const Text('Farm info, reminders, stock levels'),
                      onTap: onOpenSettings,
                    ),
                  if (onOpenProfile != null)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: const Text('Profile'),
                      subtitle: const Text('Personal identity and farm context'),
                      onTap: onOpenProfile,
                    ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.logout),
                    title: const Text('Sign out'),
                    onTap: onSignOut,
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

class _ModuleTabStrip extends StatelessWidget {
  const _ModuleTabStrip({
    required this.modules,
    required this.selectedIndex,
    required this.onSelected,
  });

  final List<_HatchModuleConfig> modules;
  final int selectedIndex;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        scrollDirection: Axis.horizontal,
        itemCount: modules.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final module = modules[index];
          final selected = index == selectedIndex;
          return ChoiceChip(
            selected: selected,
            avatar: Icon(
              module.icon,
              size: 18,
              color: selected ? Colors.white : module.color,
            ),
            label: Text(module.shortLabel),
            onSelected: (_) => onSelected(index),
            selectedColor: module.color,
            labelStyle: TextStyle(
              color: selected ? Colors.white : _UniversalColors.ink,
              fontWeight: FontWeight.w800,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          );
        },
      ),
    );
  }
}

class _ModuleDataView extends StatefulWidget {
  const _ModuleDataView({
    super.key,
    required this.module,
    required this.stream,
    this.onRefresh,
  });

  final _HatchModuleConfig module;
  final Stream<List<Map<String, dynamic>>> stream;
  final Future<void> Function()? onRefresh;

  @override
  State<_ModuleDataView> createState() => _ModuleDataViewState();
}

class _ModuleDataViewState extends State<_ModuleDataView> {
  String _eggStockFilter = 'all';

  bool get _isEggModule => widget.module.table == 'egg_production';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return _StatePanel(
            icon: Icons.error_outline,
            title: '${widget.module.title} stream failed',
            message: snapshot.error.toString(),
          );
        }

        final rows = (snapshot.data ?? const <Map<String, dynamic>>[])
            .where(widget.module.includeRow)
            .toList(growable: false);
        final displayRows = _isEggModule
            ? rows
                  .where((row) => matchesEggStockFilter(row, _eggStockFilter))
                  .toList(growable: false)
            : rows;

        return RefreshIndicator(
          onRefresh: () async {
            final refresh = widget.onRefresh;
            if (refresh != null) {
              await refresh();
              return;
            }
            await Future<void>.delayed(const Duration(milliseconds: 300));
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
            children: [
              _SummaryCard(module: widget.module, rows: displayRows),
              const SizedBox(height: 14),
              if (_isEggModule) ...[
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
                const SizedBox(height: 14),
              ],
              if (displayRows.isEmpty)
                _StatePanel(
                  icon: widget.module.icon,
                  title: _isEggModule && rows.isNotEmpty
                      ? 'No egg logs match this filter'
                      : 'No ${widget.module.shortLabel.toLowerCase()} records yet',
                  message: widget.module.emptyText,
                )
              else
                for (final row in displayRows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _RecordCard(module: widget.module, row: row),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.module, required this.rows});

  final _HatchModuleConfig module;
  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      color: module.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          showHatchLogDetailsPopup(context, {
            'module': module.title,
            'summaryTitle': module.summaryTitle,
            'summaryValue': module.summaryValue(rows),
            'visibleRows': rows.length,
          }, '${module.shortLabel} Summary');
        },
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              Container(
                width: 58,
                height: 58,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(module.icon, color: Colors.white, size: 32),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      module.summaryTitle,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      module.summaryValue(rows),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0,
                          ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _SummaryCountBadge(count: rows.length),
            ],
          ),
        ),
      ),
    );
  }
}

class _SummaryCountBadge extends StatelessWidget {
  const _SummaryCountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 62),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Text(
            '$count',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w900,
            ),
          ),
          const Text(
            'Rows',
            style: TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordCard extends StatelessWidget {
  const _RecordCard({required this.module, required this.row});

  final _HatchModuleConfig module;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final record = module.record(row);
    final progress = module.progress?.call(row);

    return Card(
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: Color(0xffe4e9ed)),
      ),
      child: InkWell(
        onTap: () {
          HapticFeedback.selectionClick();
          showHatchLogDetailsPopup(
            context,
            row,
            '${module.shortLabel} Details',
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor: module.color.withValues(alpha: 0.12),
                    foregroundColor: module.color,
                    child: Icon(module.icon),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _UniversalColors.ink,
                            fontWeight: FontWeight.w900,
                            fontSize: 16,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          record.subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: _UniversalColors.muted,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        record.metric,
                        style: TextStyle(
                          color: module.color,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      if (record.status.isNotEmpty)
                        Text(
                          record.status,
                          style: const TextStyle(
                            color: _UniversalColors.muted,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              if (progress != null) ...[
                const SizedBox(height: 12),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    minHeight: 8,
                    value: progress.clamp(0, 1),
                    backgroundColor: module.color.withValues(alpha: 0.12),
                    color: module.color,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ModuleEntrySheet extends StatefulWidget {
  const _ModuleEntrySheet({
    required this.module,
    required this.onSubmit,
    this.localDatabase,
    this.currentUser,
  });

  final _HatchModuleConfig module;
  final Future<void> Function(Map<String, dynamic> payload) onSubmit;
  final LocalDatabase? localDatabase;
  final AppUser? currentUser;

  @override
  State<_ModuleEntrySheet> createState() => _ModuleEntrySheetState();
}

class _ModuleEntrySheetState extends State<_ModuleEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _dropdownValues = {};
  final Map<String, DateTime> _dateValues = {};
  final Map<String, Set<String>> _checklistValues = {};
  final Map<String, bool> _toggleValues = {};
  final Map<String, List<String>> _dynamicDropdownOptions = {};
  final Map<String, String> _dynamicDropdownLabels = {};
  bool _saving = false;
  bool _loadingDynamicOptions = false;

  @override
  void initState() {
    super.initState();
    if (widget.module.table == 'batches') {
      _dropdownValues['livestock_category'] =
          LivestockBreedCatalog.categories.first;
      final breeds = _breedLabelsForCategory(
        _dropdownValues['livestock_category']!,
      );
      _dropdownValues['livestock_breed'] =
          breeds.isNotEmpty ? breeds.first : '';
    }

    for (final field in widget.module.fields) {
      if (field.type == _FieldType.dropdown) {
        _dropdownValues.putIfAbsent(
          field.key,
          () => field.options.isNotEmpty ? field.options.first : '',
        );
      } else if (field.type == _FieldType.date) {
        _dateValues[field.key] = DateTime.now();
      } else if (field.type == _FieldType.checklist) {
        _checklistValues[field.key] = <String>{};
      } else if (field.type == _FieldType.toggle) {
        _toggleValues[field.key] = false;
      } else {
        _controllers[field.key] = TextEditingController();
      }
    }

    if (widget.module.table == 'daily_feeding_logs') {
      _loadFeedingOptions();
    }
  }

  Future<void> _loadFeedingOptions() async {
    final db = widget.localDatabase;
    final user = widget.currentUser;
    if (db == null || user == null) {
      return;
    }
    setState(() => _loadingDynamicOptions = true);
    try {
      final batchRows = await db.rawLocalQuery(
        '''
        select id, batch_name, breed_type
        from batches
        where farm_id = ?
          and is_deleted = 0
          and lower(coalesce(status, '')) = 'active'
        order by batch_name asc
        ''',
        [user.activeFarmId],
      );
      final inventoryRows = await db.rawLocalQuery(
        '''
        select id, item_name
        from inventory
        where farm_id = ?
          and is_deleted = 0
          and (lower(coalesce(category, '')) = 'feed'
            or lower(coalesce(item_group, '')) = 'feed')
        order by item_name asc
        ''',
        [user.activeFarmId],
      );
      final formulationRows = await db.rawLocalQuery(
        '''
        select id, name
        from feed_formulations
        where farm_id = ?
        order by name asc
        ''',
        [user.activeFarmId],
      );

      final batchOptions = <String>[];
      final batchLabels = <String, String>{};
      for (final row in batchRows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) {
          continue;
        }
        final breed = LivestockBreedCatalog.labelForKey(
          row['breed_type']?.toString(),
        );
        final name = row['batch_name']?.toString().trim().isEmpty ?? true
            ? 'Batch $id'
            : row['batch_name']?.toString() ?? 'Batch $id';
        batchOptions.add(id);
        batchLabels[id] = '$name ($breed)';
      }

      final feedOptions = <String>[];
      final feedLabels = <String, String>{};
      for (final row in inventoryRows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) {
          continue;
        }
        final value = 'inv_$id';
        feedOptions.add(value);
        feedLabels[value] = '[Inventory] ${row['item_name']}';
      }
      for (final row in formulationRows) {
        final id = row['id']?.toString() ?? '';
        if (id.isEmpty) {
          continue;
        }
        final value = 'form_$id';
        feedOptions.add(value);
        feedLabels[value] = '[Formulation] ${row['name']}';
      }

      if (!mounted) {
        return;
      }
      setState(() {
        _dynamicDropdownOptions['batch_id'] = batchOptions;
        _dynamicDropdownLabels.addAll(batchLabels);
        _dynamicDropdownOptions['feed_source'] = feedOptions;
        _dynamicDropdownLabels.addAll(feedLabels);
        if (batchOptions.isNotEmpty) {
          _dropdownValues['batch_id'] = batchOptions.first;
        }
        if (feedOptions.isNotEmpty) {
          _dropdownValues['feed_source'] = feedOptions.first;
        }
        _loadingDynamicOptions = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() => _loadingDynamicOptions = false);
      }
    }
  }

  List<String> _breedLabelsForCategory(String category) {
    return LivestockBreedCatalog.optionsForCategory(category)
        .map((option) => option.label)
        .toList();
  }

  void _onDropdownChanged(String key, String value) {
    setState(() {
      _dropdownValues[key] = value;
      if (widget.module.table == 'batches' && key == 'livestock_category') {
        final breeds = _breedLabelsForCategory(value);
        _dropdownValues['livestock_breed'] =
            breeds.isNotEmpty ? breeds.first : '';
      }
    });
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_saving || !_formKey.currentState!.validate()) {
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _saving = true);
    try {
      await widget.onSubmit(_collectPayload());
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(widget.module.successMessage);
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save failed: ${_friendlyError(error)}'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Map<String, dynamic> _collectPayload() {
    final payload = <String, dynamic>{};
    for (final field in widget.module.fields) {
      switch (field.type) {
        case _FieldType.number:
          final numberText = _controllers[field.key]!.text.trim();
          payload[field.key] = field.required
              ? (num.tryParse(numberText) ?? 0)
              : (numberText.isEmpty ? null : num.tryParse(numberText));
        case _FieldType.money:
          payload[field.key] =
              double.tryParse(_controllers[field.key]!.text.trim()) ?? 0;
        case _FieldType.dropdown:
          payload[field.key] = _dropdownValues[field.key] ?? '';
        case _FieldType.date:
          payload[field.key] = _dateValues[field.key]!.toIso8601String();
        case _FieldType.multiline:
        case _FieldType.text:
          payload[field.key] = _controllers[field.key]!.text.trim();
        case _FieldType.checklist:
          payload[field.key] = _checklistValues[field.key]!.toList();
        case _FieldType.toggle:
          payload[field.key] = _toggleValues[field.key] ?? false;
      }
    }
    if (widget.module.table == 'daily_feeding_logs') {
      final feedSource = _dropdownValues['feed_source'] ?? '';
      payload['feed_source_label'] =
          _dynamicDropdownLabels[feedSource] ?? feedSource;
    }
    return payload;
  }

  void _setFeedAmount(double amount) {
    final controller = _controllers['amount_consumed'];
    if (controller == null) {
      return;
    }
    controller.text = amount.toStringAsFixed(
      amount.truncateToDouble() == amount ? 0 : 2,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.88,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        builder: (context, scrollController) {
          return Material(
            color: _UniversalColors.background,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(8)),
            child: Form(
              key: _formKey,
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
                children: [
                  Row(
                    children: [
                      IconButton.filledTonal(
                        tooltip: 'Close',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                      const Spacer(),
                      FilledButton.icon(
                        onPressed: _saving ? null : _submit,
                        icon: _saving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.check_circle_outline),
                        label: const Text('Save'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _SheetHeader(module: widget.module),
                  const SizedBox(height: 18),
                  if (_loadingDynamicOptions)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    for (final field in widget.module.fields) ...[
                      _fieldFor(field),
                      if (widget.module.table == 'daily_feeding_logs' &&
                          field.key == 'amount_consumed') ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final entry in const [
                              (0.25, '1/4 Bag'),
                              (0.5, '1/2 Bag'),
                              (0.75, '3/4 Bag'),
                              (1.0, '1 Bag'),
                            ])
                              ActionChip(
                                label: Text(entry.$2),
                                onPressed: () => _setFeedAmount(entry.$1),
                              ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 12),
                    ],
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _fieldFor(_FieldSpec field) {
    switch (field.type) {
      case _FieldType.dropdown:
        final options = widget.module.table == 'daily_feeding_logs' &&
                _dynamicDropdownOptions.containsKey(field.key)
            ? _dynamicDropdownOptions[field.key]!
            : widget.module.table == 'batches' &&
                  field.key == 'livestock_breed'
            ? _breedLabelsForCategory(
                _dropdownValues['livestock_category'] ??
                    LivestockBreedCatalog.categories.first,
              )
            : field.options;
        return DropdownButtonFormField<String>(
          initialValue: _dropdownValues[field.key],
          decoration: _decoration(field),
          items: options
              .map(
                (option) => DropdownMenuItem(
                  value: option,
                  child: Text(
                    _dynamicDropdownLabels[option] ?? option,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              )
              .toList(),
          onChanged: options.isEmpty
              ? null
              : (value) {
                  if (value != null) {
                    _onDropdownChanged(field.key, value);
                  }
                },
        );
      case _FieldType.date:
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _pickDate(field),
          child: InputDecorator(
            decoration: _decoration(field),
            child: Text(_dateText(_dateValues[field.key])),
          ),
        );
      case _FieldType.checklist:
        return _ChecklistField(
          field: field,
          selected: _checklistValues[field.key]!,
          onChanged: (selected) {
            setState(() => _checklistValues[field.key] = selected);
          },
        );
      case _FieldType.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(field.label),
          value: _toggleValues[field.key] ?? false,
          onChanged: (value) {
            setState(() => _toggleValues[field.key] = value);
          },
        );
      case _FieldType.multiline:
        return TextFormField(
          controller: _controllers[field.key],
          decoration: _decoration(field),
          minLines: 3,
          maxLines: 5,
          validator: field.required ? _required : null,
        );
      case _FieldType.money:
      case _FieldType.number:
      case _FieldType.text:
        return TextFormField(
          controller: _controllers[field.key],
          decoration: _decoration(field),
          keyboardType: field.type == _FieldType.text
              ? null
              : TextInputType.number,
          validator: field.required
              ? field.type == _FieldType.text
                    ? _required
                    : _positiveNumber
              : null,
        );
    }
  }

  Future<void> _pickDate(_FieldSpec field) async {
    final current = _dateValues[field.key] ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (selected != null) {
      setState(() => _dateValues[field.key] = selected);
    }
  }

  InputDecoration _decoration(_FieldSpec field) {
    return InputDecoration(
      labelText: field.label,
      prefixIcon: Icon(field.icon, color: widget.module.color),
      filled: true,
      fillColor: Colors.white,
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.module});

  final _HatchModuleConfig module;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _panelDecoration(),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: module.color.withValues(alpha: 0.12),
            foregroundColor: module.color,
            child: Icon(module.icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${module.title} Entry',
                  style: const TextStyle(
                    color: _UniversalColors.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 18,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  module.formSubtitle,
                  style: const TextStyle(
                    color: _UniversalColors.muted,
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

class _ChecklistField extends StatelessWidget {
  const _ChecklistField({
    required this.field,
    required this.selected,
    required this.onChanged,
  });

  final _FieldSpec field;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: _panelDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            field.label,
            style: const TextStyle(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          for (final option in field.options)
            CheckboxListTile(
              value: selected.contains(option),
              title: Text(option),
              dense: true,
              contentPadding: EdgeInsets.zero,
              onChanged: (checked) {
                final next = Set<String>.from(selected);
                if (checked ?? false) {
                  next.add(option);
                } else {
                  next.remove(option);
                }
                onChanged(next);
              },
            ),
        ],
      ),
    );
  }
}

class _StatePanel extends StatelessWidget {
  const _StatePanel({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _panelDecoration(),
      child: Column(
        children: [
          Icon(icon, color: _UniversalColors.muted, size: 34),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: _UniversalColors.muted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _HatchModuleConfig {
  const _HatchModuleConfig({
    required this.title,
    required this.shortLabel,
    required this.subtitle,
    required this.formSubtitle,
    required this.table,
    required this.orderBy,
    required this.icon,
    required this.color,
    required this.emptyText,
    required this.summaryTitle,
    required this.successMessage,
    required this.summaryValue,
    required this.record,
    required this.fields,
    required this.toRow,
    this.isDashboard = false,
    this.isPermissionAdmin = false,
    this.isLivestockHub = false,
    this.tenantColumn,
    this.creatorColumn,
    this.viewPermissionKey,
    this.editPermissionKey,
    this.viewPermissionAliases = const [],
    this.editPermissionAliases = const [],
    this.streamEquals = const {},
    this.includeRow = _includeEveryRow,
    this.progress,
  });

  final String title;
  final String shortLabel;
  final String subtitle;
  final String formSubtitle;
  final String table;
  final String orderBy;
  final IconData icon;
  final Color color;
  final String emptyText;
  final String summaryTitle;
  final String successMessage;
  final bool isDashboard;
  final bool isPermissionAdmin;
  final bool isLivestockHub;
  final String? tenantColumn;
  final String? creatorColumn;
  final String? viewPermissionKey;
  final String? editPermissionKey;
  final List<String> viewPermissionAliases;
  final List<String> editPermissionAliases;
  final Map<String, Object> streamEquals;
  final String Function(List<Map<String, dynamic>> rows) summaryValue;
  final _RecordVm Function(Map<String, dynamic> row) record;
  final bool Function(Map<String, dynamic> row) includeRow;
  final double? Function(Map<String, dynamic> row)? progress;
  final List<_FieldSpec> fields;
  final Map<String, dynamic> Function(Map<String, dynamic> payload) toRow;
}

class _QueuedWorkerInput {
  const _QueuedWorkerInput({required this.type, required this.payload});

  final WorkerInputType type;
  final Map<String, dynamic> payload;
}

class _RecordVm {
  const _RecordVm({
    required this.title,
    required this.subtitle,
    required this.metric,
    this.status = '',
  });

  final String title;
  final String subtitle;
  final String metric;
  final String status;
}

class _FieldSpec {
  const _FieldSpec({
    required this.key,
    required this.label,
    required this.icon,
    this.type = _FieldType.text,
    this.options = const [],
    this.required = true,
  });

  final String key;
  final String label;
  final IconData icon;
  final _FieldType type;
  final List<String> options;
  final bool required;
}

enum _FieldType { text, number, money, dropdown, date, multiline, checklist, toggle }

List<_HatchModuleConfig> _buildModules([
  Map<String, String> batchNames = const {},
]) {
  String batchLabel(Map<String, dynamic> row) =>
      _batchLabelForRow(row, batchNames);

  return [
    _HatchModuleConfig(
      title: 'HatchLog Central Dashboard',
      shortLabel: 'Dashboard',
      subtitle: 'Live farm pulse and recent activity',
      formSubtitle: '',
      table: '_dashboard',
      orderBy: 'createdAt',
      icon: Icons.dashboard_outlined,
      color: const Color(0xff27364a),
      emptyText: '',
      summaryTitle: 'Operational Pulse',
      successMessage: '',
      isDashboard: true,
      summaryValue: (rows) => '',
      record: (row) => const _RecordVm(title: '', subtitle: '', metric: ''),
      fields: const [],
      toRow: (payload) => const <String, dynamic>{},
    ),
    _HatchModuleConfig(
      title: 'Permissions Matrix',
      shortLabel: 'Permissions',
      subtitle: 'Owner controls for operator access rights',
      formSubtitle: '',
      table: 'user_permissions',
      orderBy: 'id',
      icon: Icons.admin_panel_settings_outlined,
      color: const Color(0xff7a3f2f),
      emptyText: '',
      summaryTitle: 'Operator Rights',
      successMessage: '',
      isPermissionAdmin: true,
      summaryValue: (rows) => '',
      record: (row) => const _RecordVm(title: '', subtitle: '', metric: ''),
      fields: const [],
      toRow: (payload) => const <String, dynamic>{},
    ),
    _HatchModuleConfig(
      title: 'Livestock',
      shortLabel: 'Livestock',
      subtitle: 'Livestock units, breeds, age, and population',
      formSubtitle: '',
      table: 'batches',
      orderBy: 'createdAt',
      icon: Icons.groups_3_outlined,
      color: const Color(0xff1f7a4d),
      emptyText: '',
      summaryTitle: '',
      successMessage: '',
      isLivestockHub: true,
      viewPermissionKey: 'can_view_batches',
      editPermissionKey: 'can_edit_batches',
      viewPermissionAliases: const ['can_view_livestock'],
      editPermissionAliases: const ['can_edit_livestock'],
      summaryValue: (_) => '',
      record: (_) => const _RecordVm(title: '', subtitle: '', metric: ''),
      fields: const [],
      toRow: (_) => const <String, dynamic>{},
    ),
    _HatchModuleConfig(
      title: 'Houses',
      shortLabel: 'Houses',
      subtitle: 'Capacity, isolation flags, and environment',
      formSubtitle: 'Register a house with optional climate readings.',
      table: 'houses',
      orderBy: 'name',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_houses',
      editPermissionKey: 'can_edit_houses',
      icon: Icons.home_work_outlined,
      color: const Color(0xff2f5f8f),
      emptyText: 'Add poultry houses to monitor capacity and climate.',
      summaryTitle: 'Total Capacity',
      successMessage: 'House saved successfully!',
      summaryValue: (rows) => '${_sumInt(rows, const ['capacity'])}',
      progress: (row) {
        final population = _int(row, const [
          'currentPopulation',
          'current_population',
          'occupied',
        ]);
        final capacity = _int(row, const ['capacity']);
        if (capacity <= 0) {
          return null;
        }
        return population / capacity;
      },
      record: (row) {
        final temperature = _nullableDouble(
          row,
          const ['currentTemperature', 'current_temperature'],
        );
        final humidity = _nullableDouble(
          row,
          const ['currentHumidity', 'current_humidity'],
        );
        final status = resolveClimateStatus(
          temperature: temperature,
          humidity: humidity,
        );
        return _RecordVm(
          title: _text(row, const ['name', 'house_number'], 'Unnamed house'),
          subtitle:
              'Capacity ${_int(row, const ['capacity'])} | ${_int(row, const ['currentPopulation', 'current_population', 'occupied'])} occupied',
          metric: temperature == null
              ? 'Climate not set'
              : '${temperature.toStringAsFixed(1)}C / ${humidity?.toStringAsFixed(0) ?? '--'}%',
          status: _bool(row, const ['isIsolation', 'is_isolation'])
              ? 'Isolation'
              : status.label,
        );
      },
      fields: const [
        _FieldSpec(
          key: 'name',
          label: 'House Name / Number',
          icon: Icons.home_outlined,
        ),
        _FieldSpec(
          key: 'capacity',
          label: 'Capacity',
          icon: Icons.groups_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'current_temperature',
          label: 'Temperature (C)',
          icon: Icons.thermostat_outlined,
          type: _FieldType.number,
          required: false,
        ),
        _FieldSpec(
          key: 'current_humidity',
          label: 'Humidity (%)',
          icon: Icons.water_drop_outlined,
          type: _FieldType.number,
          required: false,
        ),
        _FieldSpec(
          key: 'is_isolation',
          label: 'Isolation House',
          icon: Icons.health_and_safety_outlined,
          type: _FieldType.toggle,
          required: false,
        ),
      ],
      toRow: (payload) {
        return {
          'name': payload['name'],
          'capacity': payload['capacity'],
          'currentTemperature': _nullablePayloadDouble(
            payload['current_temperature'],
          ),
          'currentHumidity': _nullablePayloadDouble(payload['current_humidity']),
          'isIsolation': payload['is_isolation'] == true,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Eggs',
      shortLabel: 'Eggs',
      subtitle: 'Daily collection, grading, and unusable counts',
      formSubtitle: 'Log batch production with crate math and sorting.',
      table: 'egg_production',
      orderBy: 'logDate',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_eggs',
      editPermissionKey: 'can_edit_eggs',
      icon: Icons.egg_alt_outlined,
      color: const Color(0xffc7851f),
      emptyText: 'Add egg collection rows to build the daily ledger.',
      summaryTitle: 'Daily Egg Tally',
      successMessage: 'Egg log saved successfully!',
      summaryValue: (rows) =>
          '${_sumInt(rows, const ['eggsCollected', 'eggs_collected'])} eggs',
      record: (row) {
        final eggs = _int(row, const ['eggsCollected', 'eggs_collected']);
        final remaining = _int(row, const ['eggsRemaining', 'eggs_remaining']);
        final unusable = _int(row, const ['unusableCount', 'unusable_count']);
        final sorted = _objectBool(row['isSorted'] ?? row['is_sorted']);
        final sold = eggSoldCount(
          collected: eggs,
          unusable: unusable,
          remaining: remaining,
        );
        final activePct = eggActivePercent(
          collected: eggs,
          unusable: unusable,
          remaining: remaining,
        );
        return _RecordVm(
          title: _dateText(
            _first(row, const [
              'logDate',
              'log_date',
              'createdAt',
              'created_at',
            ]),
          ),
          subtitle:
              '${batchLabel(row)} | ${sorted ? 'Sorted' : 'Unsorted'} | $activePct% active',
          metric: '$remaining left · $sold sold',
          status:
              '${_int(row, const ['unusableCount', 'unusable_count'])} unusable',
        );
      },
      fields: const [],
      toRow: (payload) => payload,
    ),
    _HatchModuleConfig(
      title: 'Feeding',
      shortLabel: 'Feeding',
      subtitle: 'Feed stock depletion and usage history',
      formSubtitle: 'Log batch, feed source, bags consumed, and log date.',
      table: 'daily_feeding_logs',
      orderBy: 'log_date',
      tenantColumn: 'farmId',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_feeding',
      editPermissionKey: 'can_edit_feeding',
      icon: Icons.inventory_2_outlined,
      color: const Color(0xff7a5c1f),
      emptyText: 'Add feed usage records to monitor depletion.',
      summaryTitle: 'Feed Bags Used',
      successMessage: 'Feed log saved successfully!',
      summaryValue: (rows) => _sumDouble(rows, const [
        'amount_consumed',
        'sacks_used',
      ]).toStringAsFixed(1),
      record: (row) {
        return _RecordVm(
          title: _text(row, const [
            'feed_type_label',
            'feed_type',
            'feed_variant',
          ], 'Feed log'),
          subtitle:
              '${_dateText(_first(row, const ['log_date', 'logged_at', 'created_at']))} | ${batchLabel(row)}',
          metric:
              '${_double(row, const ['amount_consumed', 'sacks_used']).toStringAsFixed(1)} bags',
          status: _text(row, const ['note', 'notes'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'batch_id',
          label: 'Batch',
          icon: Icons.groups_outlined,
          type: _FieldType.dropdown,
        ),
        _FieldSpec(
          key: 'feed_source',
          label: 'Feed Type',
          icon: Icons.inventory_2_outlined,
          type: _FieldType.dropdown,
        ),
        _FieldSpec(
          key: 'amount_consumed',
          label: 'Amount Consumed (Bags)',
          icon: Icons.scale_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'log_date',
          label: 'Log Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) {
        final feedSource = parseFeedSource(
          payload['feed_source']?.toString() ?? '',
          label: payload['feed_source_label']?.toString(),
        );
        return {
          'batch_id': payload['batch_id'],
          'feed_type_id': feedSource.feedTypeId,
          'formulation_id': feedSource.formulationId,
          'feed_type_label': feedSource.label,
          'feed_type': feedSource.label,
          'amount_consumed': payload['amount_consumed'],
          'log_date': payload['log_date'],
          'is_deleted': false,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Mortality',
      shortLabel: 'Mortality',
      subtitle: 'Bird losses only, separate from quarantine',
      formSubtitle: 'Record dead birds, house origin, cause, and notes.',
      table: 'mortality',
      orderBy: 'logDate',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_mortality',
      editPermissionKey: 'can_edit_mortality',
      includeRow: _includeDeadMortality,
      icon: Icons.warning_amber_rounded,
      color: const Color(0xffb83b3b),
      emptyText: 'Add mortality records when bird losses occur.',
      summaryTitle: 'Dead Bird Count',
      successMessage: 'Mortality log saved successfully!',
      summaryValue: (rows) =>
          '${_sumInt(rows, const ['dead_count', 'quantity', 'count'])}',
      record: (row) {
        return _RecordVm(
          title:
              '${_int(row, const ['dead_count', 'quantity', 'count'])} bird losses',
          subtitle:
              '${_text(row, const ['suspected_cause', 'reason', 'cause'], 'No cause logged')} | ${_dateText(_first(row, const ['logDate', 'loss_date', 'createdAt', 'created_at']))}',
          metric: batchLabel(row),
          status: _text(row, const ['observations', 'notes'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'dead_count',
          label: 'Dead Birds',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'batch_id',
          label: 'Batch ID',
          icon: Icons.home_work_outlined,
        ),
        _FieldSpec(
          key: 'suspected_cause',
          label: 'Suspected Cause',
          icon: Icons.help_outline,
        ),
        _FieldSpec(
          key: 'observations',
          label: 'Observations',
          icon: Icons.notes_outlined,
          type: _FieldType.multiline,
          required: false,
        ),
        _FieldSpec(
          key: 'loss_date',
          label: 'Date of Loss',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) => {
        'batch_id': payload['batch_id'],
        'batchId': payload['batch_id'],
        'count': payload['dead_count'],
        'type': 'DEAD',
        'category': payload['category'] ?? 'Unknown',
        'sub_category':
            payload['sub_category'] ?? payload['suspected_cause'] ?? 'Unknown cause yet',
        'reason': payload['observations'] ?? payload['suspected_cause'],
        'logDate': payload['loss_date'],
        'createdAt': DateTime.now().toIso8601String(),
        'is_deleted': false,
      },
    ),
    _HatchModuleConfig(
      title: 'Quarantine',
      shortLabel: 'Quarantine',
      subtitle: 'Sick bird isolation, treatment, and recovery',
      formSubtitle: 'Track isolated birds, symptoms, treatment, and progress.',
      table: 'mortality',
      orderBy: 'logDate',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_mortality',
      editPermissionKey: 'can_edit_mortality',
      includeRow: _includeSickMortality,
      icon: Icons.health_and_safety_outlined,
      color: const Color(0xff5c6f2f),
      emptyText: 'Add quarantine logs for sick or isolated birds.',
      summaryTitle: 'Birds Isolated',
      successMessage: 'Quarantine log saved successfully!',
      summaryValue: (rows) =>
          '${_sumInt(rows, const ['isolated_count', 'sick_count', 'count'])}',
      record: (row) {
        return _RecordVm(
          title:
              '${_int(row, const ['isolated_count', 'sick_count', 'count'])} birds isolated',
          subtitle:
              '${_text(row, const ['symptoms', 'reason'], 'Symptoms pending')} | ${_dateText(_first(row, const ['logDate', 'isolation_date', 'createdAt', 'created_at']))}',
          metric: _text(row, const ['progress_update', 'category'], 'Active'),
          status: _text(row, const [
            'treatment_checklist',
            'sub_category',
            'treatments',
          ], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'isolated_count',
          label: 'Birds Isolated',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'symptoms',
          label: 'Symptoms',
          icon: Icons.sick_outlined,
          type: _FieldType.multiline,
        ),
        _FieldSpec(
          key: 'batch_id',
          label: 'Target Batch or House ID',
          icon: Icons.home_work_outlined,
        ),
        _FieldSpec(
          key: 'treatment_checklist',
          label: 'Treatment or Vaccine Checklist',
          icon: Icons.checklist_outlined,
          type: _FieldType.checklist,
          options: ['Vitamins', 'Antibiotics', 'Vaccine', 'Isolation cleanout'],
          required: false,
        ),
        _FieldSpec(
          key: 'progress_update',
          label: 'Health Progress',
          icon: Icons.timeline_outlined,
          type: _FieldType.dropdown,
          options: ['Active', 'Improving', 'Recovered', 'Escalated'],
        ),
        _FieldSpec(
          key: 'isolation_date',
          label: 'Isolation Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) => {
        'batch_id': payload['batch_id'],
        'batchId': payload['batch_id'],
        'count': payload['isolated_count'],
        'type': 'SICK',
        'category': payload['category'] ?? payload['progress_update'] ?? 'Disease',
        'sub_category': payload['sub_category'] ??
            ((payload['treatment_checklist'] as List?)?.join(', ') ??
                payload['symptoms']),
        'reason': payload['symptoms'],
        'isolation_room_id': payload['isolation_room_id'],
        'logDate': payload['isolation_date'],
        'createdAt': DateTime.now().toIso8601String(),
        'is_deleted': false,
      },
    ),
    _HatchModuleConfig(
      title: 'Sales',
      shortLabel: 'Sales',
      subtitle: 'Receipts, totals, and transaction ledger',
      formSubtitle: 'Create an easy receipt with quantity and unit price.',
      table: 'financial_transactions',
      orderBy: 'transaction_date',
      tenantColumn: 'farm_id',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_sales',
      editPermissionKey: 'can_edit_sales',
      streamEquals: const {'category': 'SALES'},
      includeRow: _includeRevenueTransaction,
      icon: Icons.receipt_long_outlined,
      color: const Color(0xff16845c),
      emptyText: 'Add sales receipts to populate the commercial ledger.',
      summaryTitle: 'Sales Revenue',
      successMessage: 'Sales receipt saved successfully!',
      summaryValue: (rows) =>
          _money(_sumDouble(rows, const ['total_amount', 'amount', 'total'])),
      record: (row) {
        return _RecordVm(
          title: _text(row, const ['customer_name'], 'Farm sale'),
          subtitle:
              '${_text(row, const ['description', 'item', 'product_name'], 'Item')} | ${_dateText(_first(row, const ['transaction_date', 'created_at', 'sale_date']))}',
          metric: _money(
            _double(row, const ['total_amount', 'amount', 'total']),
          ),
          status: _text(row, const ['payment_method', 'status'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'customer_name',
          label: 'Customer Name',
          icon: Icons.person_outline,
        ),
        _FieldSpec(
          key: 'item',
          label: 'Item',
          icon: Icons.inventory_2_outlined,
          type: _FieldType.dropdown,
          options: ['Egg Crate', 'Bird Sale', 'Manure', 'Other'],
        ),
        _FieldSpec(
          key: 'quantity',
          label: 'Quantity',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'unit_price',
          label: 'Unit Price',
          icon: Icons.payments_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'amount_received',
          label: 'Amount Received',
          icon: Icons.account_balance_wallet_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'payment_method',
          label: 'Payment Method',
          icon: Icons.point_of_sale_outlined,
          type: _FieldType.dropdown,
          options: ['Cash', 'Mobile Money', 'Bank Transfer', 'Credit'],
        ),
      ],
      toRow: (payload) {
        final quantity = _numPayload(payload, 'quantity');
        final unitPrice = _numPayload(payload, 'unit_price');
        final total = quantity * unitPrice;
        final received = _numPayload(payload, 'amount_received');
        final outstanding = (total - received).clamp(0, double.infinity);
        final now = DateTime.now().toIso8601String();
        return {
          'type': 'REVENUE',
          'category': 'SALES',
          'amount': total,
          'payment_status': received >= total
              ? 'PAID'
              : (received > 0 ? 'PARTIALLY_PAID' : 'UNPAID'),
          'payment_method': payload['payment_method'],
          'reference_num': _newTextId('sale_ref'),
          'transaction_date': now,
          'created_at': now,
          'updated_at': now,
          'is_deleted': false,
          'deposit_amount': received,
          'outstanding_credit': outstanding,
          'description':
              '${payload['quantity']} x ${payload['item']} to ${payload['customer_name']}',
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Inventory',
      shortLabel: 'Inventory',
      subtitle: 'Product, feed, medicine, and supply stocks',
      formSubtitle: 'Adjust stock counts and item profile information.',
      table: 'inventory',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_inventory',
      editPermissionKey: 'can_edit_inventory',
      icon: Icons.warehouse_outlined,
      color: const Color(0xff4d6475),
      emptyText: 'Add inventory items to track stock levels.',
      summaryTitle: 'Stock Units',
      successMessage: 'Inventory item saved successfully!',
      summaryValue: (rows) => _sumDouble(rows, const [
        'stock_level',
        'quantity',
      ]).toStringAsFixed(1),
      progress: (row) {
        final stock = _double(row, const ['stock_level', 'quantity']);
        final reorder = _double(row, const ['reorder_level']);
        if (stock <= 0 && reorder <= 0) {
          return null;
        }
        return stock / (stock + reorder);
      },
      record: (row) {
        return _RecordVm(
          title: _text(row, const [
            'itemName',
            'item_name',
            'name',
          ], 'Inventory item'),
          subtitle: _text(row, const [
            'category',
            'item_group',
          ], 'Uncategorized'),
          metric:
              '${_double(row, const ['stockLevel', 'stock_level', 'quantity']).toStringAsFixed(1)} ${_text(row, const ['unit'], '')}',
          status: _text(row, const ['adjustment_note', 'status'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'item_name',
          label: 'Item Name',
          icon: Icons.label_outline,
        ),
        _FieldSpec(
          key: 'category',
          label: 'Category',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: ['Feed', 'Eggs', 'Medication', 'Vaccine', 'Equipment'],
        ),
        _FieldSpec(
          key: 'stock_level',
          label: 'Stock Level',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'unit',
          label: 'Unit',
          icon: Icons.straighten_outlined,
          type: _FieldType.dropdown,
          options: ['sacks', 'crates', 'bottles', 'units', 'kg'],
        ),
        _FieldSpec(
          key: 'adjustment_note',
          label: 'Adjustment Note',
          icon: Icons.notes_outlined,
          required: false,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'itemName': payload['item_name'],
          'category': payload['category'],
          'stockLevel': payload['stock_level'],
          'unit': payload['unit'],
          'createdAt': now,
          'updatedAt': now,
          'is_deleted': false,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Customers',
      shortLabel: 'Customers',
      subtitle: 'Customer profiles and vendor details',
      formSubtitle: 'Create a profile for recurring customers or vendors.',
      table: 'customers',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_customers',
      editPermissionKey: 'can_edit_customers',
      icon: Icons.contacts_outlined,
      color: const Color(0xff6a4c93),
      emptyText: 'Add customers to build contact and credit history.',
      summaryTitle: 'Customer Profiles',
      successMessage: 'Customer profile saved successfully!',
      summaryValue: (rows) => '${rows.length}',
      record: (row) {
        return _RecordVm(
          title: _text(row, const ['name', 'customer_name'], 'Customer'),
          subtitle: _text(row, const ['phone', 'email'], 'No contact saved'),
          metric: _text(row, const ['customer_type', 'type'], 'Customer'),
          status: _money(
            _double(row, const [
              'balanceOwed',
              'balance_owed',
              'credit_balance',
            ]),
          ),
        );
      },
      fields: const [
        _FieldSpec(key: 'name', label: 'Name', icon: Icons.person_outline),
        _FieldSpec(
          key: 'phone',
          label: 'Phone',
          icon: Icons.phone_outlined,
          required: false,
        ),
        _FieldSpec(
          key: 'email',
          label: 'Email',
          icon: Icons.email_outlined,
          required: false,
        ),
        _FieldSpec(
          key: 'customer_type',
          label: 'Customer Type',
          icon: Icons.sell_outlined,
          type: _FieldType.dropdown,
          options: ['Retail', 'Wholesale', 'Vendor', 'Distributor'],
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'name': payload['name'],
          'phone': payload['phone'],
          'email': payload['email'],
          'address': '',
          'balanceOwed': 0,
          'createdAt': now,
          'updatedAt': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Finance Control',
      shortLabel: 'Finance',
      subtitle: 'Expense ledgers and payment controls',
      formSubtitle: 'Record manual ledger entries with payment status.',
      table: 'financial_transactions',
      orderBy: 'transaction_date',
      tenantColumn: 'farm_id',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_finance',
      editPermissionKey: 'can_edit_finance',
      icon: Icons.account_balance_wallet_outlined,
      color: const Color(0xff27364a),
      emptyText: 'Add finance entries to monitor expenses and cash flow.',
      summaryTitle: 'Net Position',
      successMessage: 'Finance entry saved successfully!',
      summaryValue: (rows) {
        final revenue = _sumDouble(
          rows
              .where(
                (row) =>
                    _text(row, const ['type'], '').toUpperCase() == 'REVENUE',
              )
              .toList(),
          const ['amount'],
        );
        final expense = _sumDouble(
          rows
              .where(
                (row) =>
                    _text(row, const ['type'], '').toUpperCase() == 'EXPENSE',
              )
              .toList(),
          const ['amount'],
        );
        return _money(revenue - expense);
      },
      record: (row) {
        final type = _text(row, const ['type'], 'EXPENSE').toUpperCase();
        return _RecordVm(
          title: _text(row, const ['category'], 'Finance entry'),
          subtitle:
              '${_text(row, const ['description'], 'No description')} | ${_dateText(_first(row, const ['transaction_date', 'created_at']))}',
          metric: '${type == 'REVENUE' ? '+' : '-'}${_money(_double(row, const ['amount']))}',
          status: _text(row, const ['payment_status'], 'PAID'),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'type',
          label: 'Ledger Type',
          icon: Icons.swap_vert_outlined,
          type: _FieldType.dropdown,
          options: ['REVENUE', 'EXPENSE'],
        ),
        _FieldSpec(
          key: 'category',
          label: 'Category',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: [
            'Feed Purchases',
            'Flock Vaccines & Medication',
            'Day-Old Chicks Purchase',
            'Labor & Salaries',
            'Utilities',
            'Transport',
            'Equipment & Maintenance',
            'Other OpEx',
            'Egg Wholesale Revenue',
            'Broiler Sales',
            'Manure Sales',
            'Other Revenue',
          ],
        ),
        _FieldSpec(
          key: 'amount',
          label: 'Amount',
          icon: Icons.payments_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'payment_status',
          label: 'Payment Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['PAID', 'UNPAID', 'PARTIALLY_PAID'],
        ),
        _FieldSpec(
          key: 'payment_method',
          label: 'Payment Method',
          icon: Icons.point_of_sale_outlined,
          type: _FieldType.dropdown,
          options: ['Cash', 'Mobile Money', 'Bank Transfer', 'Card'],
        ),
        _FieldSpec(
          key: 'description',
          label: 'Description',
          icon: Icons.notes_outlined,
          type: _FieldType.multiline,
        ),
        _FieldSpec(
          key: 'transaction_date',
          label: 'Transaction Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        final type = (payload['type']?.toString() ?? 'EXPENSE').toUpperCase();
        return {
          'type': type,
          'category': payload['category'],
          'amount': payload['amount'],
          'payment_status': payload['payment_status'] ?? 'PAID',
          'payment_method': payload['payment_method'] ?? 'Cash',
          'reference_num': _newTextId('fin_ref'),
          'transaction_date': payload['transaction_date'] ?? now,
          'description': payload['description'],
          'deposit_amount': 0,
          'outstanding_credit': 0,
          'expense_outlay': 0,
          'is_deleted': false,
          'created_at': now,
          'updated_at': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Orders',
      shortLabel: 'Orders',
      subtitle: 'Customer orders, status, discounts, and totals',
      formSubtitle: 'Create a customer order with amount and status.',
      table: 'orders',
      orderBy: 'order_date',
      tenantColumn: 'farmId',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_sales',
      editPermissionKey: 'can_edit_sales',
      icon: Icons.shopping_bag_outlined,
      color: const Color(0xff4d6475),
      emptyText: 'Add orders to track customer commitments.',
      summaryTitle: 'Order Book Value',
      successMessage: 'Order saved successfully!',
      summaryValue: (rows) => _money(_sumDouble(rows, const ['totalAmount'])),
      record: (row) => _RecordVm(
        title: _text(
          row,
          const ['customerName', 'customer_name', 'name'],
          'Walk-in customer',
        ),
        subtitle:
            '${_text(row, const ['status'], 'Pending')} | ${_dateText(row['order_date'])}',
        metric: _money(_double(row, const ['totalAmount'])),
        status: _text(row, const ['currency'], 'GHS'),
      ),
      fields: const [
        _FieldSpec(
          key: 'customer_id',
          label: 'Customer ID',
          icon: Icons.person_outline,
          required: false,
        ),
        _FieldSpec(
          key: 'total_amount',
          label: 'Total Amount',
          icon: Icons.payments_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'status',
          label: 'Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['PENDING', 'PAID', 'DELIVERED', 'CANCELLED'],
        ),
        _FieldSpec(
          key: 'order_date',
          label: 'Order Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'customerId': payload['customer_id'].toString().trim().isEmpty
              ? null
              : payload['customer_id'],
          'totalAmount': payload['total_amount'],
          'currency': 'GHS',
          'status': payload['status'],
          'discountAmount': 0,
          'order_date': payload['order_date'],
          'created_at': now,
          'updated_at': now,
          'is_deleted': false,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Suppliers',
      shortLabel: 'Suppliers',
      subtitle: 'Supplier contacts and payable balances',
      formSubtitle: 'Create a supplier profile for feed and farm inputs.',
      table: 'suppliers',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      viewPermissionKey: 'can_view_customers',
      editPermissionKey: 'can_edit_customers',
      icon: Icons.local_shipping_outlined,
      color: const Color(0xff5c6f2f),
      emptyText: 'Add suppliers to monitor farm input partners.',
      summaryTitle: 'Supplier Payables',
      successMessage: 'Supplier saved successfully!',
      summaryValue: (rows) =>
          _money(_sumDouble(rows, const ['balanceOwed', 'balance_owed'])),
      record: (row) => _RecordVm(
        title: _text(row, const ['name'], 'Supplier'),
        subtitle: _text(row, const ['phone', 'email'], 'No contact saved'),
        metric: _money(_double(row, const ['balanceOwed', 'balance_owed'])),
      ),
      fields: const [
        _FieldSpec(key: 'name', label: 'Name', icon: Icons.business_outlined),
        _FieldSpec(
          key: 'phone',
          label: 'Phone',
          icon: Icons.phone_outlined,
          required: false,
        ),
        _FieldSpec(
          key: 'email',
          label: 'Email',
          icon: Icons.email_outlined,
          required: false,
        ),
        _FieldSpec(
          key: 'address',
          label: 'Address',
          icon: Icons.place_outlined,
          required: false,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'name': payload['name'],
          'phone': payload['phone'],
          'email': payload['email'],
          'address': payload['address'],
          'balanceOwed': 0,
          'createdAt': now,
          'updatedAt': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Feed Formulations',
      shortLabel: 'Formulas',
      subtitle: 'Feed recipes, livestock target, and stock level',
      formSubtitle: 'Create a feed formula profile and stock balance.',
      table: 'feed_formulations',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      viewPermissionKey: 'can_view_feeding',
      editPermissionKey: 'can_edit_feeding',
      icon: Icons.science_outlined,
      color: const Color(0xff7a5c1f),
      emptyText: 'Add feed formulations used by the farm.',
      summaryTitle: 'Formula Stock',
      successMessage: 'Feed formulation saved successfully!',
      summaryValue: (rows) =>
          _sumDouble(rows, const ['stockLevel']).toStringAsFixed(1),
      record: (row) => _RecordVm(
        title: _text(row, const ['name'], 'Feed formula'),
        subtitle: _text(row, const ['type'], 'Feed'),
        metric: _double(row, const ['stockLevel']).toStringAsFixed(1),
        status: _text(row, const ['targetLivestock'], ''),
      ),
      fields: const [
        _FieldSpec(key: 'name', label: 'Name', icon: Icons.label_outline),
        _FieldSpec(
          key: 'type',
          label: 'Type',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: ['STARTER', 'GROWER', 'LAYER', 'FINISHER'],
        ),
        _FieldSpec(
          key: 'target_livestock',
          label: 'Target Livestock',
          icon: Icons.groups_3_outlined,
          type: _FieldType.dropdown,
          options: ['LAYER', 'BROILER', 'NOILER', 'SASSO'],
        ),
        _FieldSpec(
          key: 'stock_level',
          label: 'Stock Level',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'notes',
          label: 'Notes',
          icon: Icons.notes_outlined,
          type: _FieldType.multiline,
          required: false,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'name': payload['name'],
          'type': payload['type'],
          'targetLivestock': payload['target_livestock'],
          'stockLevel': payload['stock_level'],
          'notes': payload['notes'],
          'createdAt': now,
          'updatedAt': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Egg Categories',
      shortLabel: 'Egg Types',
      subtitle: 'Egg category, unit size, and selling price',
      formSubtitle: 'Create a category used for sorted egg stock.',
      table: 'egg_categories',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      viewPermissionKey: 'can_view_eggs',
      editPermissionKey: 'can_edit_eggs',
      icon: Icons.category_outlined,
      color: const Color(0xffc7851f),
      emptyText: 'Add egg categories for sorted sales and inventory.',
      summaryTitle: 'Category Prices',
      successMessage: 'Egg category saved successfully!',
      summaryValue: (rows) =>
          _money(_sumDouble(rows, const ['sellingPrice', 'selling_price'])),
      record: (row) => _RecordVm(
        title: _text(row, const ['name'], 'Egg category'),
        subtitle: _text(row, const ['description'], 'No description'),
        metric: _money(_double(row, const ['sellingPrice', 'selling_price'])),
        status: '${_int(row, const ['unitSize', 'unit_size'])} eggs per unit',
      ),
      fields: const [
        _FieldSpec(key: 'name', label: 'Name', icon: Icons.label_outline),
        _FieldSpec(
          key: 'description',
          label: 'Description',
          icon: Icons.notes_outlined,
          required: false,
        ),
        _FieldSpec(
          key: 'selling_price',
          label: 'Selling Price',
          icon: Icons.payments_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'unit_size',
          label: 'Eggs Per Unit',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'is_stock_internal',
          label: 'Stock Internal',
          icon: Icons.inventory_2_outlined,
          type: _FieldType.dropdown,
          options: ['true', 'false'],
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'name': payload['name'],
          'description': payload['description'],
          'sellingPrice': payload['selling_price'],
          'unitSize': payload['unit_size'],
          'isStockInternal': _permissionEnabled(payload['is_stock_internal']),
          'createdAt': now,
          'updatedAt': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Weight Records',
      shortLabel: 'Weights',
      subtitle: 'Average batch weights over time',
      formSubtitle: 'Log the average weight for a livestock batch.',
      table: 'weight_records',
      orderBy: 'logDate',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_batches',
      editPermissionKey: 'can_edit_batches',
      icon: Icons.monitor_weight_outlined,
      color: const Color(0xff1f7a4d),
      emptyText: 'Add weight records for growth tracking.',
      summaryTitle: 'Average Weight',
      successMessage: 'Weight record saved successfully!',
      summaryValue: (rows) {
        if (rows.isEmpty) return '0.0';
        return (_sumDouble(rows, const ['averageWeight']) / rows.length)
            .toStringAsFixed(2);
      },
      record: (row) => _RecordVm(
        title: batchLabel(row),
        subtitle: _dateText(row['logDate']),
        metric:
            '${_double(row, const ['averageWeight']).toStringAsFixed(2)} kg',
      ),
      fields: const [
        _FieldSpec(
          key: 'batch_id',
          label: 'Batch ID',
          icon: Icons.badge_outlined,
        ),
        _FieldSpec(
          key: 'average_weight',
          label: 'Average Weight',
          icon: Icons.monitor_weight_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'log_date',
          label: 'Log Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) => {
        'batchId': payload['batch_id'],
        'averageWeight': payload['average_weight'],
        'logDate': payload['log_date'],
        'createdAt': DateTime.now().toIso8601String(),
      },
    ),
    _HatchModuleConfig(
      title: 'Vaccination Schedules',
      shortLabel: 'Vaccines',
      subtitle: 'Upcoming and completed vaccination actions',
      formSubtitle: 'Schedule a vaccine for a livestock batch.',
      table: 'vaccination_schedules',
      orderBy: 'scheduledDate',
      tenantColumn: 'farmId',
      viewPermissionKey: 'can_view_batches',
      editPermissionKey: 'can_edit_batches',
      icon: Icons.vaccines_outlined,
      color: const Color(0xff5c6f2f),
      emptyText: 'Add vaccination schedules for flock health.',
      summaryTitle: 'Vaccine Tasks',
      successMessage: 'Vaccination schedule saved successfully!',
      summaryValue: (rows) => '${rows.length}',
      record: (row) => _RecordVm(
        title: _text(row, const ['vaccineName'], 'Vaccine'),
        subtitle:
            '${batchLabel(row)} | ${_dateText(row['scheduledDate'])}',
        metric: _text(row, const ['status'], 'PENDING'),
        status: _text(row, const ['notes'], ''),
      ),
      fields: const [
        _FieldSpec(
          key: 'batch_id',
          label: 'Batch ID',
          icon: Icons.badge_outlined,
        ),
        _FieldSpec(
          key: 'vaccine_name',
          label: 'Vaccine Name',
          icon: Icons.vaccines_outlined,
        ),
        _FieldSpec(
          key: 'scheduled_date',
          label: 'Scheduled Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
        _FieldSpec(
          key: 'status',
          label: 'Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['PENDING', 'COMPLETED', 'CANCELLED'],
        ),
        _FieldSpec(
          key: 'notes',
          label: 'Notes',
          icon: Icons.notes_outlined,
          required: false,
        ),
      ],
      toRow: (payload) => {
        'batchId': payload['batch_id'],
        'vaccineName': payload['vaccine_name'],
        'scheduledDate': payload['scheduled_date'],
        'status': payload['status'],
        'notes': payload['notes'],
      },
    ),
    _HatchModuleConfig(
      title: 'Medication Schedules',
      shortLabel: 'Medication',
      subtitle: 'Medication tasks and treatment notes',
      formSubtitle: 'Schedule medication for a livestock batch.',
      table: 'medication_schedules',
      orderBy: 'scheduledDate',
      tenantColumn: 'farmId',
      viewPermissionKey: 'can_view_batches',
      editPermissionKey: 'can_edit_batches',
      icon: Icons.medication_outlined,
      color: const Color(0xffb83b3b),
      emptyText: 'Add medication schedules for flock treatment.',
      summaryTitle: 'Medication Tasks',
      successMessage: 'Medication schedule saved successfully!',
      summaryValue: (rows) => '${rows.length}',
      record: (row) => _RecordVm(
        title: _text(row, const ['medicationName'], 'Medication'),
        subtitle:
            '${batchLabel(row)} | ${_dateText(row['scheduledDate'])}',
        metric: _text(row, const ['status'], 'PENDING'),
        status: _text(row, const ['notes'], ''),
      ),
      fields: const [
        _FieldSpec(
          key: 'batch_id',
          label: 'Batch ID',
          icon: Icons.badge_outlined,
        ),
        _FieldSpec(
          key: 'medication_name',
          label: 'Medication Name',
          icon: Icons.medication_outlined,
        ),
        _FieldSpec(
          key: 'scheduled_date',
          label: 'Scheduled Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
        _FieldSpec(
          key: 'status',
          label: 'Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['PENDING', 'COMPLETED', 'CANCELLED'],
        ),
        _FieldSpec(
          key: 'notes',
          label: 'Notes',
          icon: Icons.notes_outlined,
          required: false,
        ),
      ],
      toRow: (payload) => {
        'batchId': payload['batch_id'],
        'medicationName': payload['medication_name'],
        'scheduledDate': payload['scheduled_date'],
        'status': payload['status'],
        'notes': payload['notes'],
      },
    ),
  ];
}

String? _required(String? value) {
  if (value == null || value.trim().isEmpty) {
    return 'Required.';
  }
  return null;
}

String? _positiveNumber(String? value) {
  final parsed = num.tryParse(value ?? '');
  if (parsed == null || parsed < 0) {
    return 'Enter a valid number.';
  }
  return null;
}

String _friendlyError(Object error) {
  final text = error.toString();
  if (text.contains('violates not-null constraint')) {
    return 'A required database column is missing from this form.';
  }
  if (text.contains('permission denied') ||
      text.contains('row-level security')) {
    return 'Your session is not allowed to write this row. Check tenant access.';
  }
  return text;
}

Object? _first(Map<String, dynamic> row, List<String> keys) {
  for (final key in keys) {
    final value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) {
      return value;
    }
  }
  return null;
}

String _batchLabelForRow(
  Map<String, dynamic> row,
  Map<String, String> batchNames,
) {
  final inline = _text(row, const ['batch_name', 'batchName']);
  if (inline.isNotEmpty) {
    return inline;
  }
  final batchId = _text(row, const ['batch_id', 'batchId']);
  if (batchId.isEmpty) {
    return 'Unassigned';
  }
  final mapped = batchNames[batchId]?.trim();
  if (mapped != null && mapped.isNotEmpty) {
    return mapped;
  }
  return 'Batch';
}

String _text(
  Map<String, dynamic> row,
  List<String> keys, [
  String fallback = '',
]) {
  final value = _first(row, keys);
  if (value == null) {
    return fallback;
  }
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

String _dateText(Object? value) {
  final parsed = value is DateTime
      ? value
      : DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    final text = value?.toString() ?? '';
    return text.isEmpty ? 'No date' : text;
  }
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')}';
}

int _int(Map<String, dynamic> row, List<String> keys) {
  final value = _first(row, keys);
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

double _double(Map<String, dynamic> row, List<String> keys) {
  final value = _first(row, keys);
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _nullableDouble(Map<String, dynamic> row, List<String> keys) {
  final value = _first(row, keys);
  return _nullablePayloadDouble(value);
}

double? _nullablePayloadDouble(Object? value) {
  if (value == null) {
    return null;
  }
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  final text = value.toString().trim();
  if (text.isEmpty) {
    return null;
  }
  return double.tryParse(text);
}

bool _bool(Map<String, dynamic> row, List<String> keys) {
  final value = _first(row, keys);
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final text = value?.toString().trim().toLowerCase() ?? '';
  return text == 'true' || text == '1' || text == 'yes';
}

int _sumInt(List<Map<String, dynamic>> rows, List<String> keys) {
  return rows.fold(0, (sum, row) => sum + _int(row, keys));
}

double _sumDouble(List<Map<String, dynamic>> rows, List<String> keys) {
  return rows.fold(0, (sum, row) => sum + _double(row, keys));
}

int _ageWeeks(Map<String, dynamic> row) {
  final value = _first(row, const [
    'arrivalDate',
    'date_hatched',
    'hatched_at',
    'hatch_date',
  ]);
  final hatched = DateTime.tryParse(value?.toString() ?? '');
  if (hatched == null) {
    return _int(row, const ['age_weeks', 'age_in_weeks']);
  }
  return DateTime.now().difference(hatched).inDays ~/ 7;
}

double _numPayload(Map<String, dynamic> payload, String key) {
  final value = payload[key];
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

String _objectText(Object? value) {
  return value?.toString().trim() ?? '';
}

int _objectInt(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.round();
  }
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

bool _objectBool(Object? value) {
  if (value is bool) {
    return value;
  }
  if (value is num) {
    return value != 0;
  }
  final normalized = value?.toString().trim().toLowerCase();
  return normalized == '1' || normalized == 'true';
}

double _objectDouble(Object? value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool _includeEveryRow(Map<String, dynamic> row) => true;

bool _includeDeadMortality(Map<String, dynamic> row) {
  return _text(row, const ['type'], 'DEAD').toUpperCase() == 'DEAD';
}

bool _includeSickMortality(Map<String, dynamic> row) {
  final type = _text(row, const ['type'], '').toUpperCase();
  return type == 'SICK' || type == 'QUARANTINE';
}

bool _includeRevenueTransaction(Map<String, dynamic> row) {
  final type = _text(row, const ['type'], '').toUpperCase();
  final category = _text(row, const ['category'], '').toUpperCase();
  return type == 'SALE' ||
      type == 'SALES' ||
      type == 'REVENUE' ||
      category == 'SALES';
}

String _money(double value) => 'GHS ${value.toStringAsFixed(2)}';

BoxDecoration _panelDecoration() {
  return BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(8),
    border: Border.all(color: const Color(0xffe4e9ed)),
    boxShadow: const [
      BoxShadow(
        color: Color(0x14546570),
        blurRadius: 22,
        offset: Offset(0, 12),
      ),
    ],
  );
}

class _UniversalColors {
  static const background = Color(0xfff7f9fb);
  static const ink = Color(0xff172130);
  static const muted = Color(0xff667085);
}

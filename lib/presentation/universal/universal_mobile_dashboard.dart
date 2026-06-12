import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../shared/hatchlog_details_popup.dart';
import '../shared/session_mode_badge.dart';

class UniversalMobileDashboard extends StatefulWidget {
  const UniversalMobileDashboard({
    super.key,
    required this.currentUser,
    required this.connectionChanges,
    required this.isOnline,
    required this.onSignOut,
  });

  final AppUser currentUser;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final Future<void> Function() onSignOut;

  @override
  State<UniversalMobileDashboard> createState() =>
      _UniversalMobileDashboardState();
}

class _UniversalMobileDashboardState extends State<UniversalMobileDashboard> {
  SupabaseClient? _supabase;
  late final List<_HatchModuleConfig> _modules;
  late List<_HatchModuleConfig> _visibleModules;
  late Map<String, Stream<List<Map<String, dynamic>>>> _streams;
  StreamSubscription<bool>? _connectionSubscription;
  Map<String, dynamic> _permissions = const <String, dynamic>{};
  bool _permissionsLoading = true;
  Object? _permissionError;
  bool _isOnline = true;
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    try {
      _supabase = Supabase.instance.client;
    } on Object catch (error) {
      debugPrint('WARN: Supabase unavailable for dashboard streams: $error');
    }
    _modules = _buildModules();
    _visibleModules = _buildFencedModules(_modules, _permissions);
    _streams = {
      for (final module in _visibleModules)
        if (!module.isDashboard) module.table: _streamFor(module),
    };
    _loadPermissions();
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

  Future<void> _loadPermissions() async {
    if (_isPrivilegedRole(widget.currentUser.role)) {
      if (mounted) {
        setState(() {
          _permissionsLoading = false;
          _permissionError = null;
          _permissions = const <String, dynamic>{};
          _visibleModules = _buildFencedModules(_modules, _permissions);
          _streams = _buildStreams(_visibleModules);
          _selectedIndex = _clampedIndex(_selectedIndex, _visibleModules);
        });
      }
      return;
    }

    final supabase = _supabase;
    if (supabase == null) {
      if (mounted) {
        setState(() {
          _permissionsLoading = false;
          _permissionError = 'Supabase is not initialized for this session.';
          _visibleModules = _buildFencedModules(_modules, _permissions);
          _streams = _buildStreams(_visibleModules);
        });
      }
      return;
    }

    final activeFarmId = _activeFarmId(supabase);
    final userId = supabase.auth.currentUser?.id ?? widget.currentUser.id;
    if (activeFarmId.isEmpty || userId.isEmpty) {
      if (mounted) {
        setState(() {
          _permissionsLoading = false;
          _permissionError = 'No active farm or user reference was found.';
          _visibleModules = _buildFencedModules(_modules, _permissions);
          _streams = _buildStreams(_visibleModules);
        });
      }
      return;
    }

    try {
      final rows = await supabase
          .from('user_permissions')
          .select()
          .eq('user_id', userId)
          .eq('farm_id', activeFarmId)
          .limit(1);
      final permissions = rows.isEmpty
          ? const <String, dynamic>{}
          : Map<String, dynamic>.from(rows.first);
      if (!mounted) {
        return;
      }
      setState(() {
        _permissions = permissions;
        _permissionsLoading = false;
        _permissionError = null;
        _visibleModules = _buildFencedModules(_modules, _permissions);
        _streams = _buildStreams(_visibleModules);
        _selectedIndex = _clampedIndex(_selectedIndex, _visibleModules);
      });
    } on Object catch (error) {
      debugPrint(
        'HatchLog Security Failure: Could not load RBAC permissions -> $error',
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _permissionsLoading = false;
        _permissionError = error;
        _visibleModules = _buildFencedModules(_modules, _permissions);
        _streams = _buildStreams(_visibleModules);
      });
    }
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
          final viewKey = module.viewPermissionKey;
          return viewKey != null && _permissionEnabled(permissions[viewKey]);
        })
        .toList(growable: false);
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    super.dispose();
  }

  Stream<List<Map<String, dynamic>>> _streamFor(_HatchModuleConfig module) {
    final supabase = _supabase;
    if (supabase == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }
    final activeFarmId = _activeFarmId(supabase);
    if (activeFarmId.isEmpty || module.tenantColumn == null) {
      return Stream<List<Map<String, dynamic>>>.value(
        const <Map<String, dynamic>>[],
      );
    }

    return supabase
        .from(module.table)
        .stream(primaryKey: ['id'])
        .eq(module.tenantColumn!, activeFarmId)
        .order(module.orderBy, ascending: false)
        .limit(100);
  }

  String _activeFarmId(SupabaseClient supabase) {
    final metadata = supabase.auth.currentUser?.userMetadata;
    return metadata?['farm_id']?.toString() ??
        metadata?['farmId']?.toString() ??
        metadata?['tenant_id']?.toString() ??
        metadata?['tenantId']?.toString() ??
        widget.currentUser.activeFarmId;
  }

  Future<void> _insertRow(
    _HatchModuleConfig module,
    Map<String, dynamic> row,
  ) async {
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

    await supabase.from(module.table).insert({
      'id': row['id'] ?? _newTextId(module.table),
      ...metadata,
      ...row,
    });
  }

  Future<void> _openEntryForm(_HatchModuleConfig module) async {
    HapticFeedback.lightImpact();
    final message = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return _ModuleEntrySheet(
          module: module,
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

  Future<void> _signOut() async {
    HapticFeedback.lightImpact();
    await widget.onSignOut();
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
        onSignOut: _signOut,
      ),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: Text(module.title),
        actions: [
          IconButton(
            tooltip: 'Refresh streams',
            onPressed: () {
              HapticFeedback.lightImpact();
              setState(() {
                _streams = _buildStreams(_visibleModules);
              });
              _loadPermissions();
            },
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
              !canEditSelectedModule
          ? null
          : FloatingActionButton.extended(
              onPressed: () => _openEntryForm(module),
              icon: const Icon(Icons.add),
              label: Text('Add ${module.shortLabel}'),
            ),
      body: SafeArea(
        child: module.isDashboard
            ? FarmDashboardHomeView(
                supabase: _supabase,
                activeFarmId: _supabase == null
                    ? widget.currentUser.activeFarmId
                    : _activeFarmId(_supabase!),
                displayName: widget.currentUser.displayName,
                role: widget.currentUser.role,
                permissionError: _permissionError,
                permissionsLoading: _permissionsLoading,
              )
            : module.isPermissionAdmin
            ? _OwnerPermissionsControlPanel(
                supabase: _supabase,
                activeFarmId: _supabase == null
                    ? widget.currentUser.activeFarmId
                    : _activeFarmId(_supabase!),
                currentUser: widget.currentUser,
              )
            : _ModuleDataView(
                key: ValueKey(module.table),
                module: module,
                stream: _streams[module.table]!,
              ),
      ),
    );
  }

  bool _canEditModule(_HatchModuleConfig module) {
    if (_isPrivilegedRole(widget.currentUser.role)) {
      return true;
    }
    final editKey = module.editPermissionKey;
    return editKey != null && _permissionEnabled(_permissions[editKey]);
  }
}

bool _isPrivilegedRole(UserRole role) {
  return role == UserRole.owner ||
      role == UserRole.manager ||
      role == UserRole.admin;
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

class FarmDashboardHomeView extends StatelessWidget {
  const FarmDashboardHomeView({
    super.key,
    required this.supabase,
    required this.activeFarmId,
    required this.displayName,
    required this.role,
    required this.permissionsLoading,
    this.permissionError,
  });

  final SupabaseClient? supabase;
  final String activeFarmId;
  final String displayName;
  final UserRole role;
  final bool permissionsLoading;
  final Object? permissionError;

  @override
  Widget build(BuildContext context) {
    if (role == UserRole.worker) {
      return _WorkerDashboardHomeView(
        supabase: supabase,
        activeFarmId: activeFarmId,
        displayName: displayName,
        permissionsLoading: permissionsLoading,
        permissionError: permissionError,
      );
    }
    if (role == UserRole.accountant) {
      return _AccountantDashboardHomeView(
        supabase: supabase,
        activeFarmId: activeFarmId,
        displayName: displayName,
        permissionsLoading: permissionsLoading,
        permissionError: permissionError,
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmId: activeFarmId,
          ),
          _PermissionStatusBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 18),
          Text(
            'Operational Pulse',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.08,
            children: [
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'batches',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  final activeRows = rows
                      .where(
                        (row) =>
                            _text(row, const [
                              'status',
                            ], 'active').toLowerCase() !=
                            'closed',
                      )
                      .toList(growable: false);
                  final totalBirds = _sumInt(activeRows, const [
                    'currentCount',
                    'current_count',
                  ]);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.groups_3_outlined,
                    color: const Color(0xff1f7a4d),
                    metric: '$totalBirds',
                    label: 'Active Layers/Broilers',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'houses',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  final activeCount = rows
                      .where(
                        (row) =>
                            _text(row, const [
                              'status',
                            ], 'active').toLowerCase() !=
                            'inactive',
                      )
                      .length;
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.home_work_outlined,
                    color: const Color(0xff2f5f8f),
                    metric: '$activeCount / ${rows.length}',
                    label: 'Houses Active',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'egg_production',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'logDate',
                ),
                builder: (context, snapshot) {
                  final todayRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where(
                            (row) => _isToday(
                              _first(row, const ['logDate', 'collection_date']),
                            ),
                          )
                          .toList(growable: false);
                  final crates = _sumDouble(todayRows, const [
                    'cratesCollected',
                    'crates_collected',
                  ]);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.egg_alt_outlined,
                    color: const Color(0xffc7851f),
                    metric: crates.toStringAsFixed(1),
                    label: 'Crates Yielded Today',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'inventory',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  final feedRows = rows
                      .where((row) {
                        final category = _text(row, const [
                          'category',
                        ]).toLowerCase();
                        final unit = _text(row, const ['unit']).toLowerCase();
                        final item = _text(row, const [
                          'itemName',
                          'item_name',
                        ]).toLowerCase();
                        return category.contains('feed') ||
                            unit.contains('sack') ||
                            item.contains('feed');
                      })
                      .toList(growable: false);
                  final source = feedRows.isEmpty ? rows : feedRows;
                  final sacks = _sumDouble(source, const [
                    'stockLevel',
                    'stock_level',
                  ]);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.inventory_2_outlined,
                    color: const Color(0xff7a5c1f),
                    metric: sacks.toStringAsFixed(1),
                    label: 'Sacks Left',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'financial_transactions',
                  farmColumn: 'farm_id',
                  activeFarmId: activeFarmId,
                  orderBy: 'transaction_date',
                ),
                builder: (context, snapshot) {
                  final salesRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where(_includeRevenueTransaction)
                          .where(
                            (row) => _isToday(
                              _first(row, const [
                                'transaction_date',
                                'created_at',
                              ]),
                            ),
                          )
                          .toList(growable: false);
                  final sales = _sumDouble(salesRows, const ['amount']);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.point_of_sale_outlined,
                    color: const Color(0xff16845c),
                    metric: _money(sales),
                    label: 'Formulated Today',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'Recent Activity',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          _DashboardActivityStream(
            title: 'Egg Production',
            icon: Icons.egg_alt_outlined,
            color: const Color(0xffc7851f),
            stream: _dashboardStream(
              supabase,
              table: 'egg_production',
              farmColumn: 'farmId',
              activeFarmId: activeFarmId,
              orderBy: 'logDate',
              limit: 5,
            ),
            titleFor: (row) =>
                '${_double(row, const ['cratesCollected', 'crates_collected']).toStringAsFixed(1)} crates',
            subtitleFor: (row) =>
                _dateText(_first(row, const ['logDate', 'createdAt'])),
          ),
          const SizedBox(height: 10),
          _DashboardActivityStream(
            title: 'Feed Logs',
            icon: Icons.inventory_2_outlined,
            color: const Color(0xff7a5c1f),
            stream: _dashboardStream(
              supabase,
              table: 'daily_feeding_logs',
              farmColumn: 'farmId',
              activeFarmId: activeFarmId,
              orderBy: 'log_date',
              limit: 5,
            ),
            titleFor: (row) =>
                '${_double(row, const ['amount_consumed']).toStringAsFixed(1)} sacks used',
            subtitleFor: (row) => _dateText(row['log_date']),
          ),
          const SizedBox(height: 10),
          _DashboardActivityStream(
            title: 'Financial Sales',
            icon: Icons.receipt_long_outlined,
            color: const Color(0xff16845c),
            stream:
                _dashboardStream(
                  supabase,
                  table: 'financial_transactions',
                  farmColumn: 'farm_id',
                  activeFarmId: activeFarmId,
                  orderBy: 'transaction_date',
                  limit: 5,
                ).map(
                  (rows) => rows
                      .where(_includeRevenueTransaction)
                      .toList(growable: false),
                ),
            titleFor: (row) => _money(_double(row, const ['amount'])),
            subtitleFor: (row) =>
                _text(row, const ['description'], 'Sales ledger entry'),
          ),
        ],
      ),
    );
  }
}

class _WorkerDashboardHomeView extends StatelessWidget {
  const _WorkerDashboardHomeView({
    required this.supabase,
    required this.activeFarmId,
    required this.displayName,
    required this.permissionsLoading,
    this.permissionError,
  });

  final SupabaseClient? supabase;
  final String activeFarmId;
  final String displayName;
  final bool permissionsLoading;
  final Object? permissionError;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmId: activeFarmId,
          ),
          _PermissionStatusBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 18),
          Text(
            'Daily Operations',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.08,
            children: [
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'egg_production',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'logDate',
                ),
                builder: (context, snapshot) {
                  final todayRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where(
                            (row) => _isToday(
                              _first(row, const ['logDate', 'createdAt']),
                            ),
                          )
                          .toList(growable: false);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.egg_alt_outlined,
                    color: const Color(0xffc7851f),
                    metric:
                        '${_sumInt(todayRows, const ['eggsCollected', 'eggs_collected'])}',
                    label: 'Eggs Collected Today',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'daily_feeding_logs',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'log_date',
                ),
                builder: (context, snapshot) {
                  final todayRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where((row) => _isToday(row['log_date']))
                          .toList(growable: false);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.inventory_2_outlined,
                    color: const Color(0xff7a5c1f),
                    metric: _sumDouble(todayRows, const [
                      'amount_consumed',
                      'sacks_used',
                    ]).toStringAsFixed(1),
                    label: 'Feed Sacks Used',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'mortality',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'logDate',
                ),
                builder: (context, snapshot) {
                  final todayRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where(_includeDeadMortality)
                          .where(
                            (row) => _isToday(
                              _first(row, const ['logDate', 'createdAt']),
                            ),
                          )
                          .toList(growable: false);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.warning_amber_rounded,
                    color: const Color(0xffb83b3b),
                    metric: '${_sumInt(todayRows, const ['count'])}',
                    label: 'Mortality Logged',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'houses',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.home_work_outlined,
                    color: const Color(0xff2f5f8f),
                    metric: '${rows.length}',
                    label: 'House Checks Open',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'Action Tracks',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          _DashboardActivityStream(
            title: 'Egg Collection Schedule',
            icon: Icons.egg_alt_outlined,
            color: const Color(0xffc7851f),
            stream: _dashboardStream(
              supabase,
              table: 'egg_production',
              farmColumn: 'farmId',
              activeFarmId: activeFarmId,
              orderBy: 'logDate',
              limit: 5,
            ),
            titleFor: (row) =>
                '${_int(row, const ['eggsCollected', 'eggs_collected'])} eggs',
            subtitleFor: (row) => _dateText(row['logDate']),
          ),
          const SizedBox(height: 10),
          _DashboardActivityStream(
            title: 'Feed Bucket Usage',
            icon: Icons.inventory_2_outlined,
            color: const Color(0xff7a5c1f),
            stream: _dashboardStream(
              supabase,
              table: 'daily_feeding_logs',
              farmColumn: 'farmId',
              activeFarmId: activeFarmId,
              orderBy: 'log_date',
              limit: 5,
            ),
            titleFor: (row) =>
                '${_double(row, const ['amount_consumed']).toStringAsFixed(1)} sacks',
            subtitleFor: (row) => _dateText(row['log_date']),
          ),
        ],
      ),
    );
  }
}

class _AccountantDashboardHomeView extends StatelessWidget {
  const _AccountantDashboardHomeView({
    required this.supabase,
    required this.activeFarmId,
    required this.displayName,
    required this.permissionsLoading,
    this.permissionError,
  });

  final SupabaseClient? supabase;
  final String activeFarmId;
  final String displayName;
  final bool permissionsLoading;
  final Object? permissionError;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DashboardWelcomeBanner(
            displayName: displayName,
            activeFarmId: activeFarmId,
          ),
          _PermissionStatusBanner(
            isLoading: permissionsLoading,
            error: permissionError,
          ),
          const SizedBox(height: 18),
          Text(
            'Financial Overview',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.08,
            children: [
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'financial_transactions',
                  farmColumn: 'farm_id',
                  activeFarmId: activeFarmId,
                  orderBy: 'transaction_date',
                ),
                builder: (context, snapshot) {
                  final todayRows =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where(_includeRevenueTransaction)
                          .where((row) => _isToday(row['transaction_date']))
                          .toList(growable: false);
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.point_of_sale_outlined,
                    color: const Color(0xff16845c),
                    metric: _money(_sumDouble(todayRows, const ['amount'])),
                    label: 'Sales Ledger Today',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'customers',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.credit_score_outlined,
                    color: const Color(0xff6a4c93),
                    metric: _money(
                      _sumDouble(rows, const ['balanceOwed', 'balance_owed']),
                    ),
                    label: 'Customer Credit',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'suppliers',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'createdAt',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.local_shipping_outlined,
                    color: const Color(0xff4d6475),
                    metric: _money(
                      _sumDouble(rows, const ['balanceOwed', 'balance_owed']),
                    ),
                    label: 'Supplier Payables',
                  );
                },
              ),
              StreamBuilder<List<Map<String, dynamic>>>(
                stream: _dashboardStream(
                  supabase,
                  table: 'expenses',
                  farmColumn: 'farmId',
                  activeFarmId: activeFarmId,
                  orderBy: 'expense_date',
                ),
                builder: (context, snapshot) {
                  final rows = snapshot.data ?? const <Map<String, dynamic>>[];
                  return _DashboardKpiCard(
                    isLoading: _isLoading(snapshot),
                    error: snapshot.error,
                    icon: Icons.account_balance_wallet_outlined,
                    color: const Color(0xff27364a),
                    metric: _money(_sumDouble(rows, const ['amount'])),
                    label: 'Operating Costs',
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 22),
          Text(
            'Transaction Logs',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _UniversalColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 12),
          _DashboardActivityStream(
            title: 'Sales Ledgers',
            icon: Icons.receipt_long_outlined,
            color: const Color(0xff16845c),
            stream:
                _dashboardStream(
                  supabase,
                  table: 'financial_transactions',
                  farmColumn: 'farm_id',
                  activeFarmId: activeFarmId,
                  orderBy: 'transaction_date',
                  limit: 5,
                ).map(
                  (rows) => rows
                      .where(_includeRevenueTransaction)
                      .toList(growable: false),
                ),
            titleFor: (row) => _money(_double(row, const ['amount'])),
            subtitleFor: (row) =>
                _text(row, const ['description'], 'Sales ledger entry'),
          ),
          const SizedBox(height: 10),
          _DashboardActivityStream(
            title: 'Expense Register',
            icon: Icons.account_balance_wallet_outlined,
            color: const Color(0xff27364a),
            stream: _dashboardStream(
              supabase,
              table: 'expenses',
              farmColumn: 'farmId',
              activeFarmId: activeFarmId,
              orderBy: 'expense_date',
              limit: 5,
            ),
            titleFor: (row) => _money(_double(row, const ['amount'])),
            subtitleFor: (row) =>
                _text(row, const ['description', 'category'], 'Expense'),
          ),
        ],
      ),
    );
  }
}

class _PermissionStatusBanner extends StatelessWidget {
  const _PermissionStatusBanner({required this.isLoading, this.error});

  final bool isLoading;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    if (!isLoading && error == null) {
      return const SizedBox.shrink();
    }

    final hasError = error != null;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: hasError ? const Color(0xfffff4f4) : const Color(0xffeef6ff),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: hasError ? const Color(0xffffcccc) : const Color(0xffcfe6ff),
          ),
        ),
        child: Text(
          hasError
              ? 'Data Sync Interrupted: $error'
              : 'Loading permission matrix...',
          style: TextStyle(
            color: hasError ? const Color(0xff9f2626) : const Color(0xff25527a),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
  }
}

class _DashboardWelcomeBanner extends StatelessWidget {
  const _DashboardWelcomeBanner({
    required this.displayName,
    required this.activeFarmId,
  });

  final String displayName;
  final String activeFarmId;

  @override
  Widget build(BuildContext context) {
    final name = displayName.trim().isEmpty ? 'HatchLog User' : displayName;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _UniversalColors.ink,
        borderRadius: BorderRadius.circular(8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1a546570),
            blurRadius: 22,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.monitor_heart_outlined,
            color: Colors.white,
            size: 32,
          ),
          const SizedBox(height: 12),
          Text(
            'Hello, $name',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            activeFarmId.isEmpty
                ? 'Active Farm Monitor'
                : 'Active Farm Monitor - $activeFarmId',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white70,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _DashboardKpiCard extends StatelessWidget {
  const _DashboardKpiCard({
    required this.isLoading,
    required this.icon,
    required this.color,
    required this.metric,
    required this.label,
    this.error,
  });

  final bool isLoading;
  final IconData icon;
  final Color color;
  final String metric;
  final String label;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: color.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: color.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: color, size: 32),
            const SizedBox(height: 10),
            if (error != null)
              const Icon(Icons.sync_problem_outlined, color: Colors.redAccent)
            else if (isLoading)
              SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            else
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  metric,
                  maxLines: 1,
                  style: const TextStyle(
                    color: _UniversalColors.ink,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            const SizedBox(height: 7),
            Text(
              error == null ? label : 'Data Sync Interrupted',
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _UniversalColors.muted,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardActivityStream extends StatelessWidget {
  const _DashboardActivityStream({
    required this.title,
    required this.icon,
    required this.color,
    required this.stream,
    required this.titleFor,
    required this.subtitleFor,
  });

  final String title;
  final IconData icon;
  final Color color;
  final Stream<List<Map<String, dynamic>>> stream;
  final String Function(Map<String, dynamic> row) titleFor;
  final String Function(Map<String, dynamic> row) subtitleFor;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        final rows = (snapshot.data ?? const <Map<String, dynamic>>[])
            .take(5)
            .toList(growable: false);
        return Container(
          decoration: _panelDecoration(),
          child: Column(
            children: [
              ListTile(
                leading: CircleAvatar(
                  backgroundColor: color.withValues(alpha: 0.12),
                  foregroundColor: color,
                  child: Icon(icon),
                ),
                title: Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                subtitle: Text(
                  snapshot.hasError
                      ? 'Unable to load this activity stream.'
                      : '${rows.length} recent entries',
                ),
              ),
              if (_isLoading(snapshot))
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                )
              else if (rows.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'No recent entries for this farm.',
                      style: TextStyle(
                        color: _UniversalColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                )
              else
                for (final row in rows)
                  ListTile(
                    dense: true,
                    title: Text(titleFor(row)),
                    subtitle: Text(subtitleFor(row)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => showHatchLogDetailsPopup(
                      context,
                      row,
                      '$title Details',
                    ),
                  ),
            ],
          ),
        );
      },
    );
  }
}

Stream<List<Map<String, dynamic>>> _dashboardStream(
  SupabaseClient? supabase, {
  required String table,
  required String farmColumn,
  required String activeFarmId,
  required String orderBy,
  int limit = 100,
}) {
  if (supabase == null || activeFarmId.isEmpty) {
    return Stream<List<Map<String, dynamic>>>.value(
      const <Map<String, dynamic>>[],
    );
  }
  return supabase
      .from(table)
      .stream(primaryKey: ['id'])
      .eq(farmColumn, activeFarmId)
      .order(orderBy, ascending: false)
      .limit(limit);
}

bool _isLoading(AsyncSnapshot<Object?> snapshot) {
  return snapshot.connectionState == ConnectionState.waiting &&
      !snapshot.hasData;
}

bool _isToday(Object? value) {
  final parsed = value is DateTime
      ? value
      : DateTime.tryParse(value?.toString() ?? '');
  if (parsed == null) {
    return false;
  }
  final now = DateTime.now();
  final local = parsed.toLocal();
  return local.year == now.year &&
      local.month == now.month &&
      local.day == now.day;
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

        final members = (membersSnapshot.data ?? const <Map<String, dynamic>>[])
            .map(_TeamMemberVm.fromRow)
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
              subtitle: Text(permission.column),
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

  static _TeamMemberVm fromRow(Map<String, dynamic> row) {
    final userId = _text(row, const ['userId', 'user_id']);
    final role = UserRole.fromString(_text(row, const ['role']));
    return _TeamMemberVm(
      userId: userId,
      roleLabel: role.label,
      label: userId.isEmpty ? 'Team member' : 'Operator $userId',
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
    required this.onSignOut,
  });

  final AppUser currentUser;
  final List<_HatchModuleConfig> modules;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
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
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 10),
                itemCount: modules.length,
                itemBuilder: (context, index) {
                  final module = modules[index];
                  return ListTile(
                    selected: index == selectedIndex,
                    leading: Icon(module.icon),
                    title: Text(module.title),
                    subtitle: Text(module.subtitle),
                    onTap: () => onSelected(index),
                  );
                },
              ),
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

class _ModuleDataView extends StatelessWidget {
  const _ModuleDataView({
    super.key,
    required this.module,
    required this.stream,
  });

  final _HatchModuleConfig module;
  final Stream<List<Map<String, dynamic>>> stream;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return _StatePanel(
            icon: Icons.error_outline,
            title: '${module.title} stream failed',
            message: snapshot.error.toString(),
          );
        }

        final rows = (snapshot.data ?? const <Map<String, dynamic>>[])
            .where(module.includeRow)
            .toList(growable: false);

        return RefreshIndicator(
          onRefresh: () async {
            await Future<void>.delayed(const Duration(milliseconds: 300));
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 104),
            children: [
              _SummaryCard(module: module, rows: rows),
              const SizedBox(height: 14),
              if (rows.isEmpty)
                _StatePanel(
                  icon: module.icon,
                  title: 'No ${module.shortLabel.toLowerCase()} records yet',
                  message: module.emptyText,
                )
              else
                for (final row in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: _RecordCard(module: module, row: row),
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
      color: module.color,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
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
  const _ModuleEntrySheet({required this.module, required this.onSubmit});

  final _HatchModuleConfig module;
  final Future<void> Function(Map<String, dynamic> payload) onSubmit;

  @override
  State<_ModuleEntrySheet> createState() => _ModuleEntrySheetState();
}

class _ModuleEntrySheetState extends State<_ModuleEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final Map<String, TextEditingController> _controllers = {};
  final Map<String, String> _dropdownValues = {};
  final Map<String, DateTime> _dateValues = {};
  final Map<String, Set<String>> _checklistValues = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final field in widget.module.fields) {
      if (field.type == _FieldType.dropdown) {
        _dropdownValues[field.key] = field.options.first;
      } else if (field.type == _FieldType.date) {
        _dateValues[field.key] = DateTime.now();
      } else if (field.type == _FieldType.checklist) {
        _checklistValues[field.key] = <String>{};
      } else {
        _controllers[field.key] = TextEditingController();
      }
    }
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
          payload[field.key] =
              num.tryParse(_controllers[field.key]!.text.trim()) ?? 0;
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
      }
    }
    return payload;
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
                  for (final field in widget.module.fields) ...[
                    _fieldFor(field),
                    const SizedBox(height: 12),
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
        return DropdownButtonFormField<String>(
          initialValue: _dropdownValues[field.key],
          decoration: _decoration(field),
          items: field.options
              .map(
                (option) =>
                    DropdownMenuItem(value: option, child: Text(option)),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) {
              setState(() => _dropdownValues[field.key] = value);
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
    this.tenantColumn,
    this.creatorColumn,
    this.viewPermissionKey,
    this.editPermissionKey,
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
  final String? tenantColumn;
  final String? creatorColumn;
  final String? viewPermissionKey;
  final String? editPermissionKey;
  final String Function(List<Map<String, dynamic>> rows) summaryValue;
  final _RecordVm Function(Map<String, dynamic> row) record;
  final bool Function(Map<String, dynamic> row) includeRow;
  final double? Function(Map<String, dynamic> row)? progress;
  final List<_FieldSpec> fields;
  final Map<String, dynamic> Function(Map<String, dynamic> payload) toRow;
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

enum _FieldType { text, number, money, dropdown, date, multiline, checklist }

List<_HatchModuleConfig> _buildModules() {
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
      subtitle: 'Bird batches, strains, age, and population',
      formSubtitle: 'Create a batch with strain, hatch date, and bird count.',
      table: 'batches',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_batches',
      editPermissionKey: 'can_edit_batches',
      icon: Icons.groups_3_outlined,
      color: const Color(0xff1f7a4d),
      emptyText: 'Add a livestock batch to begin tracking flock movement.',
      summaryTitle: 'Total Birds',
      successMessage: 'Livestock batch saved successfully!',
      summaryValue: (rows) =>
          '${_sumInt(rows, const ['currentCount', 'current_population', 'current_count', 'population'])}',
      record: (row) {
        final hatchDate = _dateText(
          _first(row, const [
            'arrivalDate',
            'date_hatched',
            'hatched_at',
            'hatch_date',
          ]),
        );
        return _RecordVm(
          title: _text(row, const [
            'batchName',
            'batch_name',
            'name',
          ], 'Unnamed batch'),
          subtitle:
              '${_text(row, const ['breedType', 'bird_strain', 'strain'], 'Unknown strain')} | ${_ageWeeks(row)} weeks | Hatched $hatchDate',
          metric:
              '${_int(row, const ['currentCount', 'current_population', 'current_count', 'population'])} birds',
          status: _text(row, const ['status'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'batch_name',
          label: 'Batch Name',
          icon: Icons.badge_outlined,
        ),
        _FieldSpec(
          key: 'initial_count',
          label: 'Initial Bird Count',
          icon: Icons.pin_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'bird_strain',
          label: 'Bird Strain',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: ['Layer', 'Broiler', 'Noiler', 'Sasso', 'Cockerel'],
        ),
        _FieldSpec(
          key: 'date_hatched',
          label: 'Date Hatched',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
        _FieldSpec(
          key: 'house_id',
          label: 'Assigned House ID',
          icon: Icons.home_work_outlined,
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        final livestockType = payload['bird_strain'].toString().toUpperCase();
        return {
          'batchName': payload['batch_name'],
          'initialCount': payload['initial_count'],
          'currentCount': payload['initial_count'],
          'breedType': payload['bird_strain'],
          'arrivalDate': payload['date_hatched'],
          'houseId': payload['house_id'],
          'status': 'ACTIVE',
          'type': livestockType,
          'isolationCount': 0,
          'createdAt': now,
          'updatedAt': now,
          'is_deleted': false,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Houses',
      shortLabel: 'Houses',
      subtitle: 'Capacity and ambient conditions',
      formSubtitle: 'Register a house and its latest environment reading.',
      table: 'houses',
      orderBy: 'createdAt',
      tenantColumn: 'farmId',
      creatorColumn: 'userId',
      viewPermissionKey: 'can_view_houses',
      editPermissionKey: 'can_edit_houses',
      icon: Icons.home_work_outlined,
      color: const Color(0xff2f5f8f),
      emptyText: 'Add poultry houses to monitor capacity and temperature.',
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
        return _RecordVm(
          title: _text(row, const ['house_number', 'name'], 'Unnamed house'),
          subtitle:
              'Capacity ${_int(row, const ['capacity'])} | ${_int(row, const ['currentPopulation', 'current_population', 'occupied'])} occupied',
          metric:
              '${_double(row, const ['currentTemperature', 'ambient_temperature', 'current_temperature']).toStringAsFixed(1)}C',
          status: _text(row, const ['status', 'environmental_state'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'house_number',
          label: 'House Number',
          icon: Icons.home_outlined,
        ),
        _FieldSpec(
          key: 'capacity',
          label: 'Capacity',
          icon: Icons.groups_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'ambient_temperature',
          label: 'Ambient Temperature',
          icon: Icons.thermostat_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'status',
          label: 'Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['Active', 'Cleaning', 'Maintenance', 'Empty'],
        ),
      ],
      toRow: (payload) {
        final now = DateTime.now().toIso8601String();
        return {
          'name': payload['house_number'],
          'capacity': payload['capacity'],
          'currentTemperature': payload['ambient_temperature'],
          'currentHumidity': 0,
          'isIsolation': false,
          'createdAt': now,
          'updatedAt': now,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Eggs',
      shortLabel: 'Eggs',
      subtitle: 'Collection, grading, cracked, and dirty counts',
      formSubtitle: 'Capture crates, broken eggs, time slot, and house.',
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
          '${_sumInt(rows, const ['cratesCollected', 'crates_collected', 'large_crates', 'crates'])} crates',
      record: (row) {
        return _RecordVm(
          title: _dateText(
            _first(row, const [
              'logDate',
              'collection_date',
              'createdAt',
              'created_at',
            ]),
          ),
          subtitle:
              'Batch ${_text(row, const ['batchId', 'batch_id'], 'Unassigned')} | ${_text(row, const ['collection_slot', 'time_slot'], 'Any time')}',
          metric:
              '${_int(row, const ['cratesCollected', 'crates_collected', 'large_crates', 'crates'])} crates',
          status:
              '${_int(row, const ['unusableCount', 'dirty_count', 'dirt_count'])} damaged',
        );
      },
      fields: const [
        _FieldSpec(
          key: 'crates_collected',
          label: 'Crates Collected',
          icon: Icons.inventory_2_outlined,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'dirty_count',
          label: 'Dirty Eggs',
          icon: Icons.blur_on_outlined,
          type: _FieldType.number,
          required: false,
        ),
        _FieldSpec(
          key: 'cracked_count',
          label: 'Cracked or Broken Eggs',
          icon: Icons.warning_amber_outlined,
          type: _FieldType.number,
          required: false,
        ),
        _FieldSpec(
          key: 'collection_slot',
          label: 'Collection Time Slot',
          icon: Icons.schedule_outlined,
          type: _FieldType.dropdown,
          options: ['Morning', 'Afternoon', 'Evening'],
        ),
        _FieldSpec(
          key: 'house_id',
          label: 'Assigned House',
          icon: Icons.home_work_outlined,
        ),
        _FieldSpec(
          key: 'collection_date',
          label: 'Collection Date',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) {
        final crates = _numPayload(payload, 'crates_collected');
        final unusable =
            (_numPayload(payload, 'dirty_count') +
                    _numPayload(payload, 'cracked_count'))
                .round();
        final eggsCollected = (crates * 30).round();
        return {
          'batchId': payload['house_id'],
          'eggsCollected': eggsCollected,
          'cratesCollected': crates,
          'eggsRemaining': eggsCollected,
          'unusableCount': unusable,
          'largeCount': eggsCollected,
          'mediumCount': 0,
          'smallCount': 0,
          'isSorted': false,
          'logDate': payload['collection_date'],
          'createdAt': DateTime.now().toIso8601String(),
          'is_deleted': false,
        };
      },
    ),
    _HatchModuleConfig(
      title: 'Feeding',
      shortLabel: 'Feeding',
      subtitle: 'Feed stock depletion and usage history',
      formSubtitle: 'Log sacks used, feed variant, and feed timestamp.',
      table: 'daily_feeding_logs',
      orderBy: 'log_date',
      tenantColumn: 'farmId',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_feeding',
      editPermissionKey: 'can_edit_feeding',
      icon: Icons.inventory_2_outlined,
      color: const Color(0xff7a5c1f),
      emptyText: 'Add feed usage records to monitor depletion.',
      summaryTitle: 'Feed Sacks Used',
      successMessage: 'Feed log saved successfully!',
      summaryValue: (rows) => _sumDouble(rows, const [
        'sacks_used',
        'amount_consumed',
      ]).toStringAsFixed(1),
      progress: (row) {
        final remaining = _double(row, const ['sacks_remaining', 'stock_left']);
        final used = _double(row, const ['sacks_used', 'amount_consumed']);
        final total = remaining + used;
        if (total <= 0) {
          return null;
        }
        return remaining / total;
      },
      record: (row) {
        return _RecordVm(
          title: _text(row, const ['feed_variant', 'feed_brand'], 'Feed log'),
          subtitle:
              '${_dateText(_first(row, const ['log_date', 'logged_at', 'created_at']))} | Batch ${_text(row, const ['batch_id', 'batchId'], 'Unassigned')}',
          metric:
              '${_double(row, const ['sacks_used', 'amount_consumed']).toStringAsFixed(1)} sacks',
          status: _text(row, const ['sacks_remaining', 'stock_left'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'sacks_used',
          label: 'Sacks Used',
          icon: Icons.remove_circle_outline,
          type: _FieldType.number,
        ),
        _FieldSpec(
          key: 'feed_variant',
          label: 'Feed Variant',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: ['Starter', 'Grower', 'Layer Mash', 'Finisher'],
        ),
        _FieldSpec(
          key: 'house_id',
          label: 'Assigned House',
          icon: Icons.home_work_outlined,
        ),
        _FieldSpec(
          key: 'logged_at',
          label: 'Timestamp',
          icon: Icons.event_outlined,
          type: _FieldType.date,
        ),
      ],
      toRow: (payload) => {
        'batch_id': payload['house_id'],
        'amount_consumed': payload['sacks_used'],
        'log_date': payload['logged_at'],
        'is_deleted': false,
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
          metric: 'Batch ${_text(row, const ['batchId', 'batch_id'], '-')}',
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
          key: 'house_id',
          label: 'House Origin',
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
        'batchId': payload['house_id'],
        'count': payload['dead_count'],
        'reason': payload['suspected_cause'],
        'logDate': payload['loss_date'],
        'type': 'DEAD',
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
        'batchId': payload['batch_id'],
        'count': payload['isolated_count'],
        'reason': payload['symptoms'],
        'category': payload['progress_update'],
        'sub_category': (payload['treatment_checklist'] as List).join(', '),
        'logDate': payload['isolation_date'],
        'type': 'SICK',
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
        return {
          'type': 'SALE',
          'category': 'SALES',
          'amount': total,
          'payment_status': received >= total ? 'PAID' : 'PARTIALLY_PAID',
          'payment_method': payload['payment_method'],
          'reference_num': _newTextId('sale_ref'),
          'transaction_date': DateTime.now().toIso8601String(),
          'created_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
          'is_deleted': false,
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
      formSubtitle: 'Create expenses, deposits, credits, and finance notes.',
      table: 'expenses',
      orderBy: 'expense_date',
      tenantColumn: 'farmId',
      creatorColumn: 'user_id',
      viewPermissionKey: 'can_view_finance',
      editPermissionKey: 'can_edit_finance',
      icon: Icons.account_balance_wallet_outlined,
      color: const Color(0xff27364a),
      emptyText: 'Add finance entries to monitor expenses and cash flow.',
      summaryTitle: 'Expense Outlay',
      successMessage: 'Finance entry saved successfully!',
      summaryValue: (rows) =>
          _money(_sumDouble(rows, const ['amount', 'expense_outlay'])),
      record: (row) {
        return _RecordVm(
          title: _text(row, const ['category', 'type'], 'Finance entry'),
          subtitle:
              '${_text(row, const ['description'], 'No description')} | ${_dateText(_first(row, const ['expense_date', 'transaction_date', 'created_at']))}',
          metric: _money(_double(row, const ['amount', 'expense_outlay'])),
          status: _text(row, const ['payment_status', 'status'], ''),
        );
      },
      fields: const [
        _FieldSpec(
          key: 'amount',
          label: 'Amount',
          icon: Icons.payments_outlined,
          type: _FieldType.money,
        ),
        _FieldSpec(
          key: 'category',
          label: 'Category',
          icon: Icons.category_outlined,
          type: _FieldType.dropdown,
          options: ['Feed', 'Medication', 'Payroll', 'Utilities', 'Transport'],
        ),
        _FieldSpec(
          key: 'type',
          label: 'Ledger Type',
          icon: Icons.swap_vert_outlined,
          type: _FieldType.dropdown,
          options: ['EXPENSE', 'REVENUE', 'CREDIT', 'DEPOSIT'],
        ),
        _FieldSpec(
          key: 'payment_status',
          label: 'Payment Status',
          icon: Icons.fact_check_outlined,
          type: _FieldType.dropdown,
          options: ['PAID', 'PENDING', 'PARTIALLY_PAID'],
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
        return {
          'amount': payload['amount'],
          'category': payload['category'],
          'description': payload['description'],
          'expense_date': payload['transaction_date'],
          'created_at': now,
          'updated_at': now,
          'is_deleted': false,
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
        title: _text(row, const ['customerId'], 'Walk-in customer'),
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
        title: 'Batch ${_text(row, const ['batchId'], '-')}',
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
            'Batch ${_text(row, const ['batchId'], '-')} | ${_dateText(row['scheduledDate'])}',
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
          options: ['PENDING', 'DONE', 'MISSED'],
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
            'Batch ${_text(row, const ['batchId'], '-')} | ${_dateText(row['scheduledDate'])}',
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
          options: ['PENDING', 'DONE', 'MISSED'],
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

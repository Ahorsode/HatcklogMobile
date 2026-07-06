import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../core/storage/local_database.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/sales/sale_entry_screen.dart';
import '../../utils/mortality_log_utils.dart';
import '../shared/session_mode_badge.dart';

class WorkerDashboard extends StatefulWidget {
  const WorkerDashboard({
    super.key,
    required this.currentUser,
    required this.connectionChanges,
    required this.isOnline,
    required this.inputSink,
    required this.onSignOut,
    this.localSalesQueue,
    this.pdfInvoiceService,
  });

  final dynamic localSalesQueue;
  final dynamic pdfInvoiceService;
  final AppUser currentUser;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final WorkerInputSink inputSink;
  final Future<void> Function() onSignOut;

  @override
  State<WorkerDashboard> createState() => _WorkerDashboardState();
}

class _WorkerDashboardState extends State<WorkerDashboard> {
  final LocalDatabase _localDatabase = LocalDatabase();
  StreamSubscription<bool>? _connectionSubscription;
  StreamSubscription<WorkerDashboardSnapshot>? _dashboardSubscription;

  bool _isOnline = false;
  int _pendingCount = 0;
  List<RecentWorkerLog> _recentLogs = const [];
  List<WorkerUnitOption> _unitOptions = const [];

  @override
  void initState() {
    super.initState();
    _connectionSubscription = widget.connectionChanges.listen((isOnline) {
      if (!mounted) {
        return;
      }
      setState(() => _isOnline = isOnline);
    });
    _dashboardSubscription = widget.inputSink
        .watchDashboardState(user: widget.currentUser)
        .listen((snapshot) {
          if (!mounted) {
            return;
          }
          setState(() {
            _pendingCount = snapshot.pendingCount;
            _recentLogs = snapshot.recentLogs;
            _unitOptions = snapshot.unitOptions;
          });
        });

    _refreshDashboardState();
  }

  @override
  void dispose() {
    _connectionSubscription?.cancel();
    _dashboardSubscription?.cancel();
    super.dispose();
  }

  Future<void> _refreshDashboardState() async {
    final isOnline = await widget.isOnline();
    final pendingCount = await widget.inputSink.pendingCount();
    final recentLogs = await widget.inputSink.recentLogs(
      user: widget.currentUser,
    );

    if (!mounted) {
      return;
    }

    setState(() {
      _isOnline = isOnline;
      _pendingCount = pendingCount;
      _recentLogs = recentLogs;
    });
  }

  Future<void> _saveLog({
    required WorkerInputType type,
    required Map<String, dynamic> payload,
  }) async {
    await widget.inputSink.enqueueWorkerInput(
      user: widget.currentUser,
      type: type,
      payload: payload,
    );
    await _refreshDashboardState();
  }

  Future<void> _openEggTracker() async {
    HapticFeedback.lightImpact();
    final saved = await Navigator.of(context).push<bool>(
      _PremiumOverlayRoute(
        child: _EggCollectionOverlay(
          heroTag: _HeroTags.egg,
          unitOptions: _availableUnitOptions,
          onSave: (payload) =>
              _saveLog(type: WorkerInputType.eggCollection, payload: payload),
        ),
      ),
    );
    _handleOverlayResult(saved);
  }

  Future<void> _openFeedTracker() async {
    HapticFeedback.lightImpact();
    final saved = await Navigator.of(context).push<bool>(
      _PremiumOverlayRoute(
        child: _FeedDistributionOverlay(
          heroTag: _HeroTags.feed,
          unitOptions: _availableUnitOptions,
          onSave: (payload) =>
              _saveLog(type: WorkerInputType.feedUsage, payload: payload),
        ),
      ),
    );
    _handleOverlayResult(saved);
  }

  Future<void> _openMortalityTracker() async {
    HapticFeedback.lightImpact();
    final saved = await Navigator.of(context).push<bool>(
      _PremiumOverlayRoute(
        child: _MortalityOverlay(
          heroTag: _HeroTags.mortality,
          unitOptions: _availableUnitOptions,
          localDatabase: _localDatabase,
          onSave: (payload) =>
              _saveLog(type: WorkerInputType.mortality, payload: payload),
        ),
      ),
    );
    _handleOverlayResult(saved);
  }

  void _handleOverlayResult(bool? saved) {
    if (!mounted || saved != true) {
      return;
    }

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

  Future<void> _openSaleEntry() async {
    HapticFeedback.lightImpact();
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => SaleEntryScreen(
          queue: widget.localSalesQueue,
          pdfService: widget.pdfInvoiceService,
          currentUser: widget.currentUser,
          localDatabase: LocalDatabase(),
          canOverridePrices:
              widget.currentUser.role == UserRole.owner ||
              widget.currentUser.role == UserRole.admin ||
              widget.currentUser.role == UserRole.manager,
        ),
      ),
    );
    _refreshDashboardState();
  }

  List<WorkerUnitOption> get _availableUnitOptions {
    if (_unitOptions.isNotEmpty) {
      return _unitOptions;
    }
    if (widget.currentUser.activeBatchId.trim().isEmpty) {
      return const [];
    }
    return [
      WorkerUnitOption(
        batchId: widget.currentUser.activeBatchId,
        batchLabel: widget.currentUser.batchLabel,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _WorkerColors.background,
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openSaleEntry,
        icon: const Icon(Icons.point_of_sale),
        label: const Text('Farm-Gate Sale'),
      ),
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _QuickGlanceHeader(
              workerName: widget.currentUser.displayName,
              batchId: _availableUnitOptions.isEmpty
                  ? 'No batch/unit cached'
                  : '${_availableUnitOptions.length} batch/unit${_availableUnitOptions.length == 1 ? '' : 's'} available',
              isOnline: _isOnline,
              pendingCount: _pendingCount,
              authenticatedOffline: widget.currentUser.authenticatedOffline,
              onSignOut: _signOut,
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 120),
                children: [
                  _LoggingCard(
                    heroTag: _HeroTags.egg,
                    title: 'Egg Collection Tracker',
                    subtitle: 'Crates and single eggs',
                    icon: Icons.egg_alt_outlined,
                    accentColor: _WorkerColors.forest,
                    onTap: _openEggTracker,
                  ),
                  const SizedBox(height: 14),
                  _LoggingCard(
                    heroTag: _HeroTags.feed,
                    title: 'Feed Distribution Tracker',
                    subtitle: 'Starter, grower, or layer feed',
                    icon: Icons.inventory_2_outlined,
                    accentColor: _WorkerColors.amber,
                    onTap: _openFeedTracker,
                  ),
                  const SizedBox(height: 14),
                  _LoggingCard(
                    heroTag: _HeroTags.mortality,
                    title: 'Mortality / Bird Losses',
                    subtitle: 'Rapid bird-loss entry',
                    icon: Icons.warning_amber_rounded,
                    accentColor: _WorkerColors.alert,
                    isAlert: true,
                    onTap: _openMortalityTracker,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: _RecentLogsTray(logs: _recentLogs),
      ),
    );
  }
}

class _QuickGlanceHeader extends StatelessWidget {
  const _QuickGlanceHeader({
    required this.workerName,
    required this.batchId,
    required this.isOnline,
    required this.pendingCount,
    required this.authenticatedOffline,
    required this.onSignOut,
  });

  final String workerName;
  final String batchId;
  final bool isOnline;
  final int pendingCount;
  final bool authenticatedOffline;
  final VoidCallback onSignOut;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
      decoration: const BoxDecoration(
        color: _WorkerColors.forest,
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(28),
          bottomRight: Radius.circular(28),
        ),
        boxShadow: [
          BoxShadow(
            color: Color(0x33235143),
            blurRadius: 24,
            offset: Offset(0, 12),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'HatchLog Worker',
                  style: textTheme.titleMedium?.copyWith(
                    color: Colors.white70,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0,
                  ),
                ),
              ),
              IconButton.filledTonal(
                tooltip: 'Sign out',
                onPressed: onSignOut,
                icon: const Icon(Icons.logout),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.12),
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            workerName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _HeaderChip(icon: Icons.workspaces_outline, label: batchId),
              SessionModeBadge(
                isOnline: isOnline,
                authenticatedOffline: authenticatedOffline,
                pendingCount: pendingCount,
                foregroundOnDark: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _HeaderChip extends StatelessWidget {
  const _HeaderChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final maxLabelWidth = MediaQuery.sizeOf(context).width - 120;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxLabelWidth),
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LoggingCard extends StatefulWidget {
  const _LoggingCard({
    required this.heroTag,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.onTap,
    this.isAlert = false,
  });

  final String heroTag;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final VoidCallback onTap;
  final bool isAlert;

  @override
  State<_LoggingCard> createState() => _LoggingCardState();
}

class _LoggingCardState extends State<_LoggingCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final tint = widget.isAlert
        ? widget.accentColor.withValues(alpha: 0.1)
        : widget.accentColor.withValues(alpha: 0.08);

    return AnimatedScale(
      scale: _pressed ? 0.985 : 1,
      duration: const Duration(milliseconds: 120),
      child: Hero(
        tag: widget.heroTag,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapCancel: () => setState(() => _pressed = false),
            onTapUp: (_) => setState(() => _pressed = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              height: 148,
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: widget.accentColor.withValues(alpha: 0.16),
                ),
                boxShadow: [
                  const BoxShadow(
                    color: Color(0x1a5c6b62),
                    blurRadius: 22,
                    offset: Offset(10, 14),
                  ),
                  const BoxShadow(
                    color: Colors.white,
                    blurRadius: 18,
                    offset: Offset(-8, -8),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      widget.icon,
                      color: widget.accentColor,
                      size: 42,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleLarge
                              ?.copyWith(
                                color: _WorkerColors.ink,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                              ),
                        ),
                        const SizedBox(height: 7),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: _WorkerColors.muted,
                                fontWeight: FontWeight.w700,
                              ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.chevron_right,
                    color: widget.accentColor,
                    size: 34,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EggCollectionOverlay extends StatefulWidget {
  const _EggCollectionOverlay({
    required this.heroTag,
    required this.unitOptions,
    required this.onSave,
  });

  final String heroTag;
  final List<WorkerUnitOption> unitOptions;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_EggCollectionOverlay> createState() => _EggCollectionOverlayState();
}

class _EggCollectionOverlayState extends State<_EggCollectionOverlay> {
  int _crates = 0;
  int _singleEggs = 0;
  WorkerUnitOption? _selectedUnit;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedUnit = widget.unitOptions.isEmpty
        ? null
        : widget.unitOptions.first;
  }

  Future<void> _save() async {
    final unit = _selectedUnit;
    if (_isSaving || unit == null || (_crates == 0 && _singleEggs == 0)) {
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _isSaving = true);
    await widget.onSave({
      'batch_id': unit.batchId,
      'house_id': unit.houseId,
      'crates': _crates,
      'single_eggs': _singleEggs,
      'device_logged_at': DateTime.now().toIso8601String(),
    });

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _OverlayScaffold(
      heroTag: widget.heroTag,
      title: 'Egg Collection Tracker',
      subtitle: 'Count crates and loose eggs quickly.',
      icon: Icons.egg_alt_outlined,
      accentColor: _WorkerColors.forest,
      isSaving: _isSaving,
      canSave: _selectedUnit != null && (_crates > 0 || _singleEggs > 0),
      onSave: _save,
      children: [
        _WorkerUnitPicker(
          options: widget.unitOptions,
          selectedBatchId: _selectedUnit?.batchId,
          accentColor: _WorkerColors.forest,
          onChanged: (unit) {
            HapticFeedback.lightImpact();
            setState(() => _selectedUnit = unit);
          },
        ),
        const SizedBox(height: 14),
        _CounterPanel(
          label: 'Crates',
          value: _crates,
          accentColor: _WorkerColors.forest,
          onMinus: () => _changeCrates(-1),
          onPlus: () => _changeCrates(1),
        ),
        const SizedBox(height: 14),
        _CounterPanel(
          label: 'Single Eggs',
          value: _singleEggs,
          accentColor: _WorkerColors.amber,
          onMinus: () => _changeSingleEggs(-1),
          onPlus: () => _changeSingleEggs(1),
        ),
      ],
    );
  }

  void _changeCrates(int delta) {
    HapticFeedback.lightImpact();
    setState(() => _crates = (_crates + delta).clamp(0, 999));
  }

  void _changeSingleEggs(int delta) {
    HapticFeedback.lightImpact();
    setState(() => _singleEggs = (_singleEggs + delta).clamp(0, 999));
  }
}

class _FeedDistributionOverlay extends StatefulWidget {
  const _FeedDistributionOverlay({
    required this.heroTag,
    required this.unitOptions,
    required this.onSave,
  });

  final String heroTag;
  final List<WorkerUnitOption> unitOptions;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_FeedDistributionOverlay> createState() =>
      _FeedDistributionOverlayState();
}

class _FeedDistributionOverlayState extends State<_FeedDistributionOverlay> {
  final _formKey = GlobalKey<FormState>();
  final _bagsController = TextEditingController();
  final _noteController = TextEditingController();

  String _feedType = 'Layer';
  WorkerUnitOption? _selectedUnit;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedUnit = widget.unitOptions.isEmpty
        ? null
        : widget.unitOptions.first;
  }

  @override
  void dispose() {
    _bagsController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final unit = _selectedUnit;
    if (!_formKey.currentState!.validate() || _isSaving || unit == null) {
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _isSaving = true);
    await widget.onSave({
      'batch_id': unit.batchId,
      'house_id': unit.houseId,
      'feed_type': _feedType,
      'bags': _bagsController.text.trim(),
      'note': _noteController.text.trim(),
      'device_logged_at': DateTime.now().toIso8601String(),
    });

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _OverlayScaffold(
      heroTag: widget.heroTag,
      title: 'Feed Distribution Tracker',
      subtitle: 'Select feed type and enter bags.',
      icon: Icons.inventory_2_outlined,
      accentColor: _WorkerColors.amber,
      isSaving: _isSaving,
      canSave: _selectedUnit != null,
      onSave: _save,
      children: [
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _WorkerUnitPicker(
                options: widget.unitOptions,
                selectedBatchId: _selectedUnit?.batchId,
                accentColor: _WorkerColors.amber,
                onChanged: (unit) {
                  HapticFeedback.lightImpact();
                  setState(() => _selectedUnit = unit);
                },
              ),
              const SizedBox(height: 18),
              Text(
                'Feed Type',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: _WorkerColors.ink,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final type in const ['Starter', 'Grower', 'Layer'])
                    _FeedTypePill(
                      label: type,
                      selected: _feedType == type,
                      onTap: () {
                        HapticFeedback.lightImpact();
                        setState(() => _feedType = type);
                      },
                    ),
                ],
              ),
              const SizedBox(height: 22),
              TextFormField(
                controller: _bagsController,
                autofocus: true,
                keyboardType: TextInputType.number,
                style: const TextStyle(
                  fontSize: 40,
                  fontWeight: FontWeight.w900,
                  color: _WorkerColors.ink,
                ),
                decoration: InputDecoration(
                  labelText: 'Bags Distributed',
                  hintText: '0',
                  suffixText: 'bags',
                  filled: true,
                  fillColor: Colors.white,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 22,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter bags distributed.';
                  }
                  final parsed = num.tryParse(value.trim());
                  if (parsed == null || parsed <= 0) {
                    return 'Enter a number above zero.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _noteController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: 'Note',
                  prefixIcon: Icon(Icons.notes_outlined),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _MortalityOverlay extends StatefulWidget {
  const _MortalityOverlay({
    required this.heroTag,
    required this.unitOptions,
    required this.localDatabase,
    required this.onSave,
  });

  final String heroTag;
  final List<WorkerUnitOption> unitOptions;
  final LocalDatabase localDatabase;
  final Future<void> Function(Map<String, dynamic> payload) onSave;

  @override
  State<_MortalityOverlay> createState() => _MortalityOverlayState();
}

class _MortalityOverlayState extends State<_MortalityOverlay> {
  int _count = 0;
  WorkerUnitOption? _selectedUnit;
  bool _isSaving = false;
  final Map<String, int> _batchCurrentCounts = {};

  @override
  void initState() {
    super.initState();
    _selectedUnit = widget.unitOptions.isEmpty
        ? null
        : widget.unitOptions.first;
    _loadBatchCounts();
  }

  Future<void> _loadBatchCounts() async {
    final batchIds = widget.unitOptions
        .map((option) => option.batchId)
        .where((id) => id.isNotEmpty)
        .toSet();
    if (batchIds.isEmpty) {
      return;
    }

    final placeholders = List.filled(batchIds.length, '?').join(', ');
    final rows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, current_count
      from batches
      where id in ($placeholders)
      ''',
      batchIds.toList(),
    );

    final counts = <String, int>{};
    for (final row in rows) {
      final id = row['id']?.toString() ?? '';
      if (id.isEmpty) {
        continue;
      }
      counts[id] = int.tryParse(row['current_count']?.toString() ?? '') ?? 0;
    }

    if (!mounted) {
      return;
    }
    setState(() => _batchCurrentCounts.addAll(counts));
  }

  int get _currentCount =>
      _batchCurrentCounts[_selectedUnit?.batchId ?? ''] ?? 0;

  String? get _validationError => validateHealthLog(
        count: _count,
        currentCount: _currentCount,
        healthType: 'DEAD',
      );

  Future<void> _save() async {
    final unit = _selectedUnit;
    if (_isSaving || unit == null || _validationError != null) {
      return;
    }

    HapticFeedback.lightImpact();
    setState(() => _isSaving = true);
    await widget.onSave(
      buildHealthLogPayload(
        batchId: unit.batchId,
        count: _count,
        healthType: 'DEAD',
        category: 'Unknown',
        subCategory: 'Unknown cause yet',
        logDate: DateTime.now(),
      ),
    );

    if (mounted) {
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return _OverlayScaffold(
      heroTag: widget.heroTag,
      title: 'Mortality / Bird Losses',
      subtitle: 'Record losses for this batch immediately.',
      icon: Icons.warning_amber_rounded,
      accentColor: _WorkerColors.alert,
      isSaving: _isSaving,
      canSave: _selectedUnit != null && _validationError == null,
      onSave: _save,
      children: [
        _WorkerUnitPicker(
          options: widget.unitOptions,
          selectedBatchId: _selectedUnit?.batchId,
          accentColor: _WorkerColors.alert,
          onChanged: (unit) {
            HapticFeedback.lightImpact();
            setState(() => _selectedUnit = unit);
          },
        ),
        const SizedBox(height: 14),
        _CounterPanel(
          label: 'Bird Losses',
          value: _count,
          accentColor: _WorkerColors.alert,
          onMinus: () => _changeCount(-1),
          onPlus: () => _changeCount(1),
        ),
        if (_validationError != null) ...[
          const SizedBox(height: 12),
          Text(
            _validationError!,
            style: const TextStyle(
              color: Color(0xffb83b3b),
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ],
    );
  }

  void _changeCount(int delta) {
    HapticFeedback.lightImpact();
    setState(
      () => _count = (_count + delta).clamp(0, _currentCount > 0 ? _currentCount : 999),
    );
  }
}

class _OverlayScaffold extends StatelessWidget {
  const _OverlayScaffold({
    required this.heroTag,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accentColor,
    required this.isSaving,
    required this.canSave,
    required this.onSave,
    required this.children,
  });

  final String heroTag;
  final String title;
  final String subtitle;
  final IconData icon;
  final Color accentColor;
  final bool isSaving;
  final bool canSave;
  final VoidCallback onSave;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _WorkerColors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  IconButton.filledTonal(
                    tooltip: 'Close',
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      Navigator.of(context).pop(false);
                    },
                    icon: const Icon(Icons.close),
                  ),
                  const Spacer(),
                  FilledButton.icon(
                    onPressed: isSaving || !canSave ? null : onSave,
                    icon: isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: const Text('Save Log'),
                    style: FilledButton.styleFrom(
                      backgroundColor: accentColor,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(138, 50),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
                children: [
                  Hero(
                    tag: heroTag,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x1a5c6b62),
                              blurRadius: 24,
                              offset: Offset(10, 16),
                            ),
                          ],
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 72,
                              height: 72,
                              decoration: BoxDecoration(
                                color: accentColor.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Icon(icon, color: accentColor, size: 42),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleLarge
                                        ?.copyWith(
                                          color: _WorkerColors.ink,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0,
                                        ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    subtitle,
                                    style: Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(
                                          color: _WorkerColors.muted,
                                          fontWeight: FontWeight.w700,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 22),
                  ...children,
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WorkerUnitPicker extends StatelessWidget {
  const _WorkerUnitPicker({
    required this.options,
    required this.selectedBatchId,
    required this.accentColor,
    required this.onChanged,
  });

  final List<WorkerUnitOption> options;
  final String? selectedBatchId;
  final Color accentColor;
  final ValueChanged<WorkerUnitOption> onChanged;

  @override
  Widget build(BuildContext context) {
    if (options.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _WorkerColors.alert.withValues(alpha: 0.2)),
        ),
        child: const Row(
          children: [
            Icon(Icons.info_outline, color: _WorkerColors.alert),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'No batch/unit is cached on this device yet.',
                style: TextStyle(
                  color: _WorkerColors.ink,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return DropdownButtonFormField<String>(
      initialValue: selectedBatchId,
      decoration: InputDecoration(
        labelText: 'Batch / Unit',
        prefixIcon: Icon(Icons.workspaces_outline, color: accentColor),
        filled: true,
        fillColor: Colors.white,
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(
            value: option.batchId,
            child: Text(
              option.displayLabel,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: (batchId) {
        if (batchId == null) {
          return;
        }
        final selected = options.firstWhere(
          (option) => option.batchId == batchId,
          orElse: () => options.first,
        );
        onChanged(selected);
      },
    );
  }
}

class _CounterPanel extends StatelessWidget {
  const _CounterPanel({
    required this.label,
    required this.value,
    required this.accentColor,
    required this.onMinus,
    required this.onPlus,
  });

  final String label;
  final int value;
  final Color accentColor;
  final VoidCallback onMinus;
  final VoidCallback onPlus;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accentColor.withValues(alpha: 0.16)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x175c6b62),
            blurRadius: 22,
            offset: Offset(8, 14),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: _WorkerColors.ink,
              fontWeight: FontWeight.w900,
              letterSpacing: 0,
            ),
          ),
          const SizedBox(height: 10),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            transitionBuilder: (child, animation) {
              return ScaleTransition(scale: animation, child: child);
            },
            child: Text(
              '$value',
              key: ValueKey(value),
              style: TextStyle(
                color: accentColor,
                fontSize: 88,
                height: 1,
                fontWeight: FontWeight.w900,
                letterSpacing: 0,
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _CounterButton(
                  icon: Icons.remove,
                  color: _WorkerColors.ink,
                  onPressed: value == 0 ? null : onMinus,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: _CounterButton(
                  icon: Icons.add,
                  color: accentColor,
                  onPressed: onPlus,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CounterButton extends StatelessWidget {
  const _CounterButton({
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final IconData icon;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(78),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      child: Icon(icon, size: 42),
    );
  }
}

class _FeedTypePill extends StatelessWidget {
  const _FeedTypePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        decoration: BoxDecoration(
          color: selected ? _WorkerColors.amber : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? _WorkerColors.amber
                : _WorkerColors.amber.withValues(alpha: 0.24),
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: _WorkerColors.amber.withValues(alpha: 0.24),
                    blurRadius: 16,
                    offset: const Offset(0, 8),
                  ),
                ]
              : null,
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : _WorkerColors.ink,
            fontSize: 17,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }
}

class _RecentLogsTray extends StatefulWidget {
  const _RecentLogsTray({required this.logs});

  final List<RecentWorkerLog> logs;

  @override
  State<_RecentLogsTray> createState() => _RecentLogsTrayState();
}

class _RecentLogsTrayState extends State<_RecentLogsTray> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final hasLogs = widget.logs.isNotEmpty;
    final height = !hasLogs
        ? 82.0
        : _expanded
        ? 188.0
        : 74.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      height: height,
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe1e7e3)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x255c6b62),
            blurRadius: 26,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: hasLogs
                ? () {
                    HapticFeedback.lightImpact();
                    setState(() => _expanded = !_expanded);
                  }
                : null,
            child: Row(
              children: [
                const Icon(Icons.history_rounded, color: _WorkerColors.forest),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Recent Logs',
                    style: TextStyle(
                      color: _WorkerColors.ink,
                      fontWeight: FontWeight.w900,
                      fontSize: 16,
                    ),
                  ),
                ),
                if (hasLogs)
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_up,
                    color: _WorkerColors.muted,
                  ),
              ],
            ),
          ),
          if (!hasLogs) ...[
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'No entries saved today.',
                style: TextStyle(
                  color: _WorkerColors.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ] else if (_expanded) ...[
            const SizedBox(height: 8),
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: ListView.separated(
                  key: ValueKey(widget.logs.map((log) => log.createdAt).join()),
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: widget.logs.length,
                  separatorBuilder: (context, index) =>
                      const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    return _RecentLogRow(log: widget.logs[index]);
                  },
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RecentLogRow extends StatelessWidget {
  const _RecentLogRow({required this.log});

  final RecentWorkerLog log;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: log.isSynced ? _WorkerColors.synced : _WorkerColors.amber,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            '${_timeAgo(log.createdAt)}: ${log.summary}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: _WorkerColors.ink,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }

  String _timeAgo(DateTime createdAt) {
    final difference = DateTime.now().difference(createdAt);
    if (difference.inMinutes < 1) {
      return 'Just now';
    }
    if (difference.inMinutes < 60) {
      return '${difference.inMinutes} mins ago';
    }
    if (difference.inHours == 1) {
      return '1 hour ago';
    }
    return '${difference.inHours} hours ago';
  }
}

class _PremiumOverlayRoute<T> extends PageRouteBuilder<T> {
  _PremiumOverlayRoute({required Widget child})
    : super(
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        pageBuilder: (context, animation, secondaryAnimation) => child,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
          );
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.045),
                end: Offset.zero,
              ).animate(curved),
              child: child,
            ),
          );
        },
      );
}

class _HeroTags {
  static const egg = 'worker-egg-tracker';
  static const feed = 'worker-feed-tracker';
  static const mortality = 'worker-mortality-tracker';
}

class _WorkerColors {
  static const background = Color(0xfff8f9fa);
  static const forest = Color(0xff145f3b);
  static const amber = Color(0xffd99025);
  static const alert = Color(0xffb83b3b);
  static const synced = Color(0xff1aa66a);
  static const ink = Color(0xff17231d);
  static const muted = Color(0xff66736c);
}

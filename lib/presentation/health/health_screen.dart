import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../features/health/data/health_schedule_repository.dart';
import '../../utils/health_constants.dart';

class HealthScreen extends StatefulWidget {
  const HealthScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    this.canEdit = true,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final bool canEdit;

  @override
  State<HealthScreen> createState() => _HealthScreenState();
}

class _HealthScreenState extends State<HealthScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  late final HealthScheduleRepository _repository;
  late Future<HealthSchedulesSnapshot> _snapshotFuture;
  late Future<
    ({List<HealthInventoryOption> vaccine, List<HealthInventoryOption> medicine})
  > _inventoryFuture;
  late Future<List<Map<String, Object?>>> _batchesFuture;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _repository = HealthScheduleRepository(widget.localDatabase);
    _reload();
  }

  void _reload() {
    final farmId = widget.currentUser.activeFarmId;
    _snapshotFuture = _repository.loadSchedules(farmId);
    _inventoryFuture = _repository.loadHealthInventory(farmId);
    _batchesFuture = _repository.loadActiveBatches(farmId);
    setState(() {});
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openCreateSheet() async {
    if (!widget.canEdit) {
      return;
    }
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _HealthScheduleFormSheet(
          farmId: widget.currentUser.activeFarmId,
          repository: _repository,
          batchesFuture: _batchesFuture,
          inventoryFuture: _inventoryFuture,
          initialKind: _tabController.index == 0
              ? HealthScheduleKind.vaccination
              : HealthScheduleKind.medication,
        );
      },
    );
    if (saved == true) {
      _reload();
    }
  }

  Future<void> _updateStatus({
    required HealthScheduleKind kind,
    required String id,
    required String status,
  }) async {
    try {
      await _repository.updateScheduleStatus(
        farmId: widget.currentUser.activeFarmId,
        kind: kind,
        id: id,
        status: status,
      );
      _reload();
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.toString())),
      );
    }
  }

  Future<void> _deleteSchedule({
    required HealthScheduleKind kind,
    required String id,
  }) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete schedule?'),
        content: const Text('This removes the schedule from your farm.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) {
      return;
    }
    await _repository.deleteSchedule(
      farmId: widget.currentUser.activeFarmId,
      kind: kind,
      id: id,
    );
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Vaccination & Medication'),
        bottom: TabBar(
          controller: _tabController,
          tabs: const [
            Tab(text: 'Vaccinations'),
            Tab(text: 'Medications'),
          ],
        ),
      ),
      floatingActionButton: widget.canEdit
          ? FloatingActionButton.extended(
              onPressed: _openCreateSheet,
              icon: const Icon(Icons.add),
              label: const Text('Schedule'),
            )
          : null,
      body: FutureBuilder<HealthSchedulesSnapshot>(
        future: _snapshotFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('Failed to load: ${snapshot.error}'));
          }
          final data = snapshot.data!;
          return Column(
            children: [
              _PendingBanner(pendingCount: data.pendingCount),
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _ScheduleList(
                      records: data.vaccinations,
                      kind: HealthScheduleKind.vaccination,
                      canEdit: widget.canEdit,
                      batchesFuture: _batchesFuture,
                      onStatusChanged: _updateStatus,
                      onDelete: _deleteSchedule,
                    ),
                    _ScheduleList(
                      records: data.medications,
                      kind: HealthScheduleKind.medication,
                      canEdit: widget.canEdit,
                      batchesFuture: _batchesFuture,
                      onStatusChanged: _updateStatus,
                      onDelete: _deleteSchedule,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PendingBanner extends StatelessWidget {
  const _PendingBanner({required this.pendingCount});

  final int pendingCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: const Color(0xffecfdf3),
      child: Row(
        children: [
          const Icon(Icons.pending_actions, color: Color(0xff1f7a4d)),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '$pendingCount pending schedule${pendingCount == 1 ? '' : 's'}',
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScheduleList extends StatelessWidget {
  const _ScheduleList({
    required this.records,
    required this.kind,
    required this.canEdit,
    required this.batchesFuture,
    required this.onStatusChanged,
    required this.onDelete,
  });

  final List<Map<String, Object?>> records;
  final HealthScheduleKind kind;
  final bool canEdit;
  final Future<List<Map<String, Object?>>> batchesFuture;
  final Future<void> Function({
    required HealthScheduleKind kind,
    required String id,
    required String status,
  }) onStatusChanged;
  final Future<void> Function({
    required HealthScheduleKind kind,
    required String id,
  }) onDelete;

  @override
  Widget build(BuildContext context) {
    if (records.isEmpty) {
      return Center(
        child: Text(
          kind == HealthScheduleKind.vaccination
              ? 'No vaccinations scheduled yet.'
              : 'No medications scheduled yet.',
        ),
      );
    }

    return FutureBuilder<List<Map<String, Object?>>>(
      future: batchesFuture,
      builder: (context, batchSnapshot) {
        final batchNames = {
          for (final batch in batchSnapshot.data ?? [])
            batch['id']?.toString() ?? '': batch['batch_name']?.toString() ?? '',
        };
        final today = DateTime.now();
        final dayStart = DateTime(today.year, today.month, today.day);

        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: records.length,
          separatorBuilder: (context, index) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final row = records[index];
            final id = row['id']?.toString() ?? '';
            final name = kind == HealthScheduleKind.vaccination
                ? row['vaccine_name']?.toString() ?? 'Vaccine'
                : row['medication_name']?.toString() ?? 'Medication';
            final batchId = row['batch_id']?.toString() ?? '';
            final batchName = batchNames[batchId]?.isNotEmpty == true
                ? batchNames[batchId]!
                : 'Unknown batch';
            final scheduledDate =
                DateTime.tryParse(row['scheduled_date']?.toString() ?? '') ??
                DateTime.now();
            final status = row['status']?.toString().toUpperCase() ?? 'PENDING';
            final isDone = isHealthScheduleCompleted(status);
            final isCancelled = status == 'CANCELLED';
            final isOverdue =
                scheduledDate.isBefore(dayStart) && !isDone && !isCancelled;
            final usageType = normalizeHealthUsageType(
              row['usage_type']?.toString(),
            );
            final quantity = row['quantity'];
            final unit = row['unit']?.toString() ?? 'unit';
            final usageLabel = usageType == HealthUsageType.quantity
                ? '$quantity $unit'
                : 'One-time';

            return Card(
              child: ListTile(
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('$batchName · ${_formatDate(scheduledDate)}'),
                    Text('$usageLabel${isOverdue ? ' · Overdue' : ''}'),
                    if ((row['notes']?.toString() ?? '').isNotEmpty)
                      Text(
                        row['notes']!.toString(),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                  ],
                ),
                trailing: canEdit
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: healthScheduleStatuses.contains(status)
                                  ? status
                                  : 'PENDING',
                              items: healthScheduleStatuses
                                  .map(
                                    (value) => DropdownMenuItem(
                                      value: value,
                                      child: Text(value),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (value) {
                                if (value == null) {
                                  return;
                                }
                                onStatusChanged(
                                  kind: kind,
                                  id: id,
                                  status: value,
                                );
                              },
                            ),
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            onPressed: () => onDelete(kind: kind, id: id),
                            icon: const Icon(Icons.delete_outline),
                          ),
                        ],
                      )
                    : Chip(label: Text(status)),
              ),
            );
          },
        );
      },
    );
  }
}

class _HealthScheduleFormSheet extends StatefulWidget {
  const _HealthScheduleFormSheet({
    required this.farmId,
    required this.repository,
    required this.batchesFuture,
    required this.inventoryFuture,
    required this.initialKind,
  });

  final String farmId;
  final HealthScheduleRepository repository;
  final Future<List<Map<String, Object?>>> batchesFuture;
  final Future<
    ({List<HealthInventoryOption> vaccine, List<HealthInventoryOption> medicine})
  > inventoryFuture;
  final HealthScheduleKind initialKind;

  @override
  State<_HealthScheduleFormSheet> createState() =>
      _HealthScheduleFormSheetState();
}

class _HealthScheduleFormSheetState extends State<_HealthScheduleFormSheet> {
  final _formKey = GlobalKey<FormState>();
  final _customNameController = TextEditingController();
  final _quantityController = TextEditingController(text: '1');
  final _notesController = TextEditingController();

  late HealthScheduleKind _kind;
  String? _batchId;
  String? _inventorySelection;
  HealthUsageType _newUsageType = HealthUsageType.oneTime;
  String _unit = 'dose';
  String _status = 'PENDING';
  DateTime _scheduledDate = DateTime.now();
  bool _saving = false;

  static const _customInventoryValue = '__custom__';

  @override
  void initState() {
    super.initState();
    _kind = widget.initialKind;
  }

  @override
  void dispose() {
    _customNameController.dispose();
    _quantityController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  bool get _isCustomItem => _inventorySelection == _customInventoryValue;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _saving) {
      return;
    }
    setState(() => _saving = true);
    try {
      final inventory = await widget.inventoryFuture;
      final options = _kind == HealthScheduleKind.vaccination
          ? inventory.vaccine
          : inventory.medicine;
      HealthInventoryOption? selected;
      for (final item in options) {
        if (item.itemName == _inventorySelection) {
          selected = item;
          break;
        }
      }
      final name = _isCustomItem
          ? _customNameController.text.trim()
          : _inventorySelection ?? '';
      final usageType = _isCustomItem
          ? _newUsageType
          : normalizeHealthUsageType(selected?.usageType);
      final quantity = usageType == HealthUsageType.quantity
          ? double.tryParse(_quantityController.text.trim()) ?? 0
          : 1;
      if (usageType == HealthUsageType.quantity && quantity <= 0) {
        throw StateError('Enter a valid quantity.');
      }

      await widget.repository.createSchedulesBulk(
        farmId: widget.farmId,
        entries: [
          HealthScheduleEntry(
            kind: _kind,
            batchId: _batchId!,
            name: name,
            scheduledDate: _scheduledDate,
            status: _status,
            usageType: usageType,
            quantity: quantity.toDouble(),
            unit: _isCustomItem ? _unit : (selected?.unit ?? _unit),
            notes: _notesController.text.trim().isEmpty
                ? null
                : _notesController.text.trim(),
            isNewItem: _isCustomItem,
            inventoryId: selected?.id,
          ),
        ],
      );
      if (mounted) {
        Navigator.pop(context, true);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(error.toString())),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'New Health Schedule',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 16),
                SegmentedButton<HealthScheduleKind>(
                  segments: const [
                    ButtonSegment(
                      value: HealthScheduleKind.vaccination,
                      label: Text('Vaccination'),
                      icon: Icon(Icons.vaccines_outlined),
                    ),
                    ButtonSegment(
                      value: HealthScheduleKind.medication,
                      label: Text('Medication'),
                      icon: Icon(Icons.medication_outlined),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (values) {
                    setState(() {
                      _kind = values.first;
                      _inventorySelection = null;
                    });
                  },
                ),
                const SizedBox(height: 16),
                FutureBuilder<List<Map<String, Object?>>>(
                  future: widget.batchesFuture,
                  builder: (context, snapshot) {
                    final batches = snapshot.data ?? [];
                    return DropdownButtonFormField<String>(
                      key: ValueKey('batch-$_batchId-${batches.length}'),
                      initialValue: _batchId,
                      decoration: const InputDecoration(labelText: 'Batch'),
                      items: batches
                          .map(
                            (batch) => DropdownMenuItem(
                              value: batch['id']?.toString(),
                              child: Text(
                                batch['batch_name']?.toString() ?? 'Batch',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) => setState(() => _batchId = value),
                      validator: (value) =>
                          value == null ? 'Select a batch.' : null,
                    );
                  },
                ),
                const SizedBox(height: 12),
                FutureBuilder<
                  ({
                    List<HealthInventoryOption> vaccine,
                    List<HealthInventoryOption> medicine,
                  })
                >(
                  future: widget.inventoryFuture,
                  builder: (context, snapshot) {
                    final options = _kind == HealthScheduleKind.vaccination
                        ? snapshot.data?.vaccine ?? []
                        : snapshot.data?.medicine ?? [];
                    return DropdownButtonFormField<String>(
                      key: ValueKey('inventory-$_inventorySelection-$_kind'),
                      initialValue: _inventorySelection,
                      decoration: InputDecoration(
                        labelText: _kind == HealthScheduleKind.vaccination
                            ? 'Vaccine'
                            : 'Medication',
                      ),
                      items: [
                        ...options.map(
                          (item) => DropdownMenuItem(
                            value: item.itemName,
                            child: Text(
                              '${item.itemName} — ${item.stockLevel} ${item.unit}',
                            ),
                          ),
                        ),
                        const DropdownMenuItem(
                          value: _customInventoryValue,
                          child: Text('Add new item'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _inventorySelection = value),
                      validator: (value) =>
                          value == null ? 'Select an item.' : null,
                    );
                  },
                ),
                if (_isCustomItem) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _customNameController,
                    decoration: InputDecoration(
                      labelText: _kind == HealthScheduleKind.vaccination
                          ? 'New vaccine name'
                          : 'New medication name',
                    ),
                    validator: (value) =>
                        value == null || value.trim().isEmpty ? 'Required.' : null,
                  ),
                  const SizedBox(height: 12),
                  SegmentedButton<HealthUsageType>(
                    segments: const [
                      ButtonSegment(
                        value: HealthUsageType.oneTime,
                        label: Text('One-time'),
                      ),
                      ButtonSegment(
                        value: HealthUsageType.quantity,
                        label: Text('Quantity'),
                      ),
                    ],
                    selected: {_newUsageType},
                    onSelectionChanged: (values) {
                      setState(() => _newUsageType = values.first);
                    },
                  ),
                ],
                if (_isCustomItem && _newUsageType == HealthUsageType.quantity) ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _quantityController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(labelText: 'Quantity'),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    key: ValueKey('unit-$_unit'),
                    initialValue: _unit,
                    decoration: const InputDecoration(labelText: 'Unit'),
                    items: healthUnitOptions
                        .map(
                          (unit) => DropdownMenuItem(
                            value: unit,
                            child: Text(unit),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _unit = value);
                      }
                    },
                  ),
                ],
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Scheduled date'),
                  subtitle: Text(_formatDate(_scheduledDate)),
                  trailing: const Icon(Icons.calendar_today_outlined),
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                      initialDate: _scheduledDate,
                    );
                    if (picked != null) {
                      setState(() => _scheduledDate = picked);
                    }
                  },
                ),
                DropdownButtonFormField<String>(
                  key: ValueKey('status-$_status'),
                  initialValue: _status,
                  decoration: const InputDecoration(labelText: 'Status'),
                  items: healthScheduleStatuses
                      .map(
                        (status) => DropdownMenuItem(
                          value: status,
                          child: Text(status),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _status = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notesController,
                  decoration: const InputDecoration(labelText: 'Notes'),
                  maxLines: 2,
                ),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: const Text('Save schedule'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDate(DateTime date) {
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

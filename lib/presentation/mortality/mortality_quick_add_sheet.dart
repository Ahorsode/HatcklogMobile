import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../core/storage/local_database.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/sync/data/worker_log_mutator.dart';
import '../../utils/mortality_log_utils.dart';
import '../worker/widgets/quick_add_batch_grid.dart';

enum MortalityHealthType {
  dead('DEAD', 'Dead', Icons.dangerous_outlined),
  sick('SICK', 'Sick', Icons.healing_outlined);

  const MortalityHealthType(this.storageValue, this.label, this.icon);

  final String storageValue;
  final String label;
  final IconData icon;
}

class MortalityQuickAddSheet extends StatefulWidget {
  const MortalityQuickAddSheet({
    super.key,
    required this.currentUser,
    required this.batch,
    required this.inputSink,
    required this.localDatabase,
    this.defaultHealthType,
    this.editConfig,
    this.initialRow,
  });

  final AppUser currentUser;
  final BatchSummary batch;
  final WorkerInputSink inputSink;
  final LocalDatabase localDatabase;
  final MortalityHealthType? defaultHealthType;
  final WorkerLogEditConfig? editConfig;
  final Map<String, Object?>? initialRow;

  @override
  State<MortalityQuickAddSheet> createState() => _MortalityQuickAddSheetState();
}

class _MortalityQuickAddSheetState extends State<MortalityQuickAddSheet> {
  static const _addRoomValue = '__add_new_room__';

  final _countController = TextEditingController();
  final _newRoomNameController = TextEditingController();
  final _newRoomCapacityController = TextEditingController();

  late MortalityHealthType _healthType;
  bool _loadingRooms = true;
  bool _isSaving = false;
  DateTime _logDate = DateTime.now();
  String _category = mortalityReasons.keys.first;
  String _specificCause = mortalityReasons.values.first.first;
  String? _selectedRoomId;
  List<_IsolationRoomOption> _rooms = const [];

  int get _count => int.tryParse(_countController.text.trim()) ?? 0;
  bool get _isLocked =>
      widget.defaultHealthType != null && widget.editConfig == null;
  bool get _isAddingRoom =>
      _healthType == MortalityHealthType.sick &&
      _selectedRoomId == _addRoomValue;
  int get _effectiveCurrentCount {
    final row = widget.initialRow;
    if (row == null) {
      return widget.batch.currentCount;
    }
    final oldCount = int.tryParse(row['count']?.toString() ?? '') ?? 0;
    final oldType = resolveHealthType(row['type']?.toString());
    final deltas = healthLogBatchDeltas(healthType: oldType, count: oldCount);
    return widget.batch.currentCount - deltas.currentCountDelta;
  }

  String? get _validationError {
    return validateHealthLog(
      count: _count,
      currentCount: _effectiveCurrentCount,
      healthType: _healthType.storageValue,
      requireIsolationRoom: _healthType == MortalityHealthType.sick,
      isolationRoomId: _selectedRoomId,
      isAddingRoom: _isAddingRoom,
      newRoomName: _newRoomNameController.text,
      newRoomCapacity: int.tryParse(_newRoomCapacityController.text.trim()) ?? 0,
    );
  }

  bool get _canSubmit =>
      !_loadingRooms && !_isSaving && _validationError == null;

  @override
  void initState() {
    super.initState();
    _healthType = widget.defaultHealthType ?? MortalityHealthType.dead;
    _hydrateFromInitialRow();
    _loadRooms();
  }

  void _hydrateFromInitialRow() {
    final row = widget.initialRow;
    if (row == null) {
      return;
    }
    final type = resolveHealthType(row['type']?.toString());
    _healthType = type == 'SICK'
        ? MortalityHealthType.sick
        : MortalityHealthType.dead;
    _countController.text = row['count']?.toString() ?? '';
    final category = row['category']?.toString();
    if (category != null && mortalityReasons.containsKey(category)) {
      _category = category;
    }
    final subCategory = row['sub_category']?.toString();
    if (subCategory != null && subCategory.isNotEmpty) {
      _specificCause = subCategory;
    }
    _selectedRoomId = row['isolation_room_id']?.toString();
    final logDate = DateTime.tryParse(row['log_date']?.toString() ?? '');
    if (logDate != null) {
      _logDate = logDate;
    }
  }

  @override
  void dispose() {
    _countController.dispose();
    _newRoomNameController.dispose();
    _newRoomCapacityController.dispose();
    super.dispose();
  }

  Future<void> _loadRooms() async {
    final rows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, name, capacity
      from isolation_rooms
      where farm_id = ?
      order by name asc
      ''',
      [widget.currentUser.activeFarmId],
    );
    final rooms = [
      for (final row in rows)
        _IsolationRoomOption(
          id: row['id']?.toString() ?? '',
          name: row['name']?.toString() ?? 'Isolation room',
          capacity: _asInt(row['capacity']),
        ),
    ].where((room) => room.id.isNotEmpty).toList(growable: false);
    if (!mounted) {
      return;
    }
    setState(() {
      _rooms = rooms;
      _selectedRoomId = rooms.isEmpty ? _addRoomValue : rooms.first.id;
      _loadingRooms = false;
    });
  }

  Future<String?> _createRoomIfNeeded() async {
    if (!_isAddingRoom) {
      return _selectedRoomId == _addRoomValue ? null : _selectedRoomId;
    }
    final id = 'local_room_${DateTime.now().microsecondsSinceEpoch}';
    await widget.localDatabase.insertLocalRecord('isolation_rooms', {
      'id': id,
      'farm_id': widget.currentUser.activeFarmId,
      'name': _newRoomNameController.text.trim(),
      'capacity': int.tryParse(_newRoomCapacityController.text.trim()) ?? 0,
      'user_id': widget.currentUser.id,
      'updated_at': DateTime.now().toIso8601String(),
    });
    return id;
  }

  Future<void> _save() async {
    if (!_canSubmit) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      final isolationRoomId = _healthType == MortalityHealthType.sick
          ? await _createRoomIfNeeded()
          : null;
      final payload = buildHealthLogPayload(
        batchId: widget.batch.id,
        count: _count,
        healthType: _healthType.storageValue,
        category: _category,
        subCategory: _specificCause,
        isolationRoomId: isolationRoomId,
        logDate: _logDate,
      );
      final editConfig = widget.editConfig;
      if (editConfig != null) {
        await editConfig.mutator.updateWorkerLog(
          user: widget.currentUser,
          module: editConfig.module,
          recordId: editConfig.recordId,
          payload: payload,
        );
      } else {
        await widget.inputSink.enqueueWorkerInput(
          user: widget.currentUser,
          type: WorkerInputType.mortality,
          payload: payload,
        );
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _logDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() {
      _logDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _logDate.hour,
        _logDate.minute,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _validationError;
    final causes = mortalityReasons[_category] ?? const ['Other'];
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.9,
      minChildSize: 0.54,
      maxChildSize: 0.96,
      builder: (context, scrollController) {
        return Material(
          color: const Color(0xfff8faf7),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          child: SafeArea(
            top: false,
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 22),
              children: [
                _SheetHeader(
                  title: _healthType == MortalityHealthType.dead
                      ? 'Log Mortality'
                      : 'Log Sickness',
                  subtitle: widget.batch.batchLabel,
                  icon: _healthType.icon,
                  color: _healthType == MortalityHealthType.dead
                      ? const Color(0xffb83b3b)
                      : const Color(0xffd99025),
                ),
                const SizedBox(height: 16),
                if (!_isLocked) ...[
                  SegmentedButton<MortalityHealthType>(
                    segments: const [
                      ButtonSegment(
                        value: MortalityHealthType.dead,
                        label: Text('Dead'),
                        icon: Icon(Icons.dangerous_outlined),
                      ),
                      ButtonSegment(
                        value: MortalityHealthType.sick,
                        label: Text('Sick'),
                        icon: Icon(Icons.healing_outlined),
                      ),
                    ],
                    selected: {_healthType},
                    onSelectionChanged: (values) {
                      setState(() => _healthType = values.first);
                    },
                  ),
                  const SizedBox(height: 14),
                ],
                TextField(
                  controller: _countController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: _healthType == MortalityHealthType.dead
                        ? 'Mortality Count'
                        : 'Sickness Count',
                    helperText: '${widget.batch.currentCount} birds remaining',
                    prefixIcon: const Icon(Icons.pin_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                if (_healthType == MortalityHealthType.sick) ...[
                  const SizedBox(height: 14),
                  if (_loadingRooms)
                    const Center(child: CircularProgressIndicator())
                  else ...[
                    DropdownButtonFormField<String>(
                      initialValue: _selectedRoomId,
                      decoration: const InputDecoration(
                        labelText: 'Isolation Room',
                        prefixIcon: Icon(Icons.meeting_room_outlined),
                        filled: true,
                        fillColor: Colors.white,
                      ),
                      items: [
                        for (final room in _rooms)
                          DropdownMenuItem(
                            value: room.id,
                            child: Text('${room.name} (${room.capacity})'),
                          ),
                        const DropdownMenuItem(
                          value: _addRoomValue,
                          child: Text('Add New Room'),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() => _selectedRoomId = value);
                      },
                    ),
                    if (_isAddingRoom) ...[
                      const SizedBox(height: 10),
                      TextField(
                        controller: _newRoomNameController,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'New Room Name',
                          prefixIcon: Icon(Icons.label_outline),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: _newRoomCapacityController,
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: 'New Room Capacity',
                          prefixIcon: Icon(Icons.groups_outlined),
                          filled: true,
                          fillColor: Colors.white,
                        ),
                      ),
                    ],
                  ],
                ],
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    prefixIcon: Icon(Icons.category_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: [
                    for (final key in mortalityReasons.keys)
                      DropdownMenuItem(value: key, child: Text(key)),
                  ],
                  onChanged: (value) {
                    if (value == null) {
                      return;
                    }
                    setState(() {
                      _category = value;
                      _specificCause = mortalityReasons[value]!.first;
                    });
                  },
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: causes.contains(_specificCause)
                      ? _specificCause
                      : causes.first,
                  decoration: const InputDecoration(
                    labelText: 'Specific Cause',
                    prefixIcon: Icon(Icons.fact_check_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: [
                    for (final cause in causes)
                      DropdownMenuItem(value: cause, child: Text(cause)),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _specificCause = value);
                    }
                  },
                ),
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: _pickDate,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(_dateLabel(_logDate)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: const TextStyle(
                      color: Color(0xffb83b3b),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                FilledButton.icon(
                  onPressed: _canSubmit ? _save : null,
                  icon: _isSaving
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline),
                  label: Text(
                    _healthType == MortalityHealthType.dead
                        ? 'Save Mortality Log'
                        : 'Save Sickness Log',
                  ),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: _healthType == MortalityHealthType.dead
                        ? const Color(0xffb83b3b)
                        : const Color(0xffd99025),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _IsolationRoomOption {
  const _IsolationRoomOption({
    required this.id,
    required this.name,
    required this.capacity,
  });

  final String id;
  final String name;
  final int capacity;
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          backgroundColor: color.withValues(alpha: 0.14),
          foregroundColor: color,
          child: Icon(icon),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0,
                ),
              ),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Color(0xff66736c),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(false),
          icon: const Icon(Icons.close),
        ),
      ],
    );
  }
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

String _dateLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

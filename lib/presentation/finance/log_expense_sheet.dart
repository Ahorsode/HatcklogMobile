import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../core/storage/local_database.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../worker/widgets/quick_add_batch_grid.dart';

enum ExpenseAllocationMode { percentage, amount }

class LogExpenseSheet extends StatefulWidget {
  const LogExpenseSheet({
    super.key,
    required this.currentUser,
    required this.inputSink,
    required this.localDatabase,
  });

  final AppUser currentUser;
  final WorkerInputSink inputSink;
  final LocalDatabase localDatabase;

  @override
  State<LogExpenseSheet> createState() => _LogExpenseSheetState();
}

class _LogExpenseSheetState extends State<LogExpenseSheet> {
  final _amountController = TextEditingController();
  final _referenceController = TextEditingController();
  final _descriptionController = TextEditingController();

  String _category = 'FEED';
  DateTime _expenseDate = DateTime.now();
  bool _allocateAcrossBatches = false;
  bool _isSaving = false;
  ExpenseAllocationMode _allocationMode = ExpenseAllocationMode.percentage;
  List<BatchSummary> _batches = const [];
  final List<_AllocationRowState> _rows = [];

  double get _amount => double.tryParse(_amountController.text.trim()) ?? 0;

  bool get _hasDuplicateBatch {
    final selected = _rows
        .map((row) => row.batchId)
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toList();
    return selected.toSet().length != selected.length;
  }

  bool get _hasIncompleteRows {
    return _rows.any(
      (row) => row.batchId == null || row.batchId!.isEmpty || row.value <= 0,
    );
  }

  double get _allocationSum => _rows.fold(0, (sum, row) => sum + row.value);

  bool get _isBalanced {
    if (!_allocateAcrossBatches) {
      return true;
    }
    if (_allocationMode == ExpenseAllocationMode.percentage) {
      return (_allocationSum - 100).abs() <= 0.01;
    }
    return (_allocationSum - _amount).abs() <= 0.01;
  }

  String get _balanceMessage {
    if (!_allocateAcrossBatches) {
      return '';
    }
    if (_hasIncompleteRows) {
      return 'Complete every allocation row';
    }
    if (_hasDuplicateBatch) {
      return 'Duplicate batch selected';
    }
    if (_allocationMode == ExpenseAllocationMode.percentage) {
      final delta = 100 - _allocationSum;
      if (delta.abs() <= 0.01) {
        return 'Balanced at 100%';
      }
      final prefix = delta >= 0 ? '+' : '';
      return '$prefix${delta.toStringAsFixed(2)}% remaining';
    }
    final delta = _amount - _allocationSum;
    if (delta.abs() <= 0.01) {
      return 'Balanced at GHS ${_amount.toStringAsFixed(2)}';
    }
    final label = delta >= 0 ? 'remaining' : 'over';
    return 'GHS ${delta.abs().toStringAsFixed(2)} $label';
  }

  Color get _balanceColor {
    if (!_allocateAcrossBatches) {
      return const Color(0xff66736c);
    }
    if (_hasIncompleteRows || _hasDuplicateBatch) {
      return const Color(0xffb83b3b);
    }
    return _isBalanced ? const Color(0xff1f7a4d) : const Color(0xffd99025);
  }

  bool get _canSubmit {
    if (_isSaving || _amount <= 0) {
      return false;
    }
    if (!_allocateAcrossBatches) {
      return true;
    }
    return !_hasIncompleteRows && !_hasDuplicateBatch && _isBalanced;
  }

  @override
  void initState() {
    super.initState();
    _rows.addAll([_AllocationRowState(), _AllocationRowState()]);
    _loadBatches();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _referenceController.dispose();
    _descriptionController.dispose();
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _loadBatches() async {
    final rows = await widget.localDatabase.rawLocalQuery(
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
    final batches = rows
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
    if (mounted) {
      setState(() => _batches = batches);
    }
  }

  Future<void> _pickDateTime() async {
    final date = await showDatePicker(
      context: context,
      initialDate: _expenseDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (date == null || !mounted) {
      return;
    }
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_expenseDate),
    );
    if (time == null || !mounted) {
      return;
    }
    setState(() {
      _expenseDate = DateTime(
        date.year,
        date.month,
        date.day,
        time.hour,
        time.minute,
      );
    });
  }

  void _addRow() {
    setState(() => _rows.add(_AllocationRowState()));
  }

  void _removeRow(int index) {
    if (_rows.length == 1) {
      return;
    }
    final row = _rows.removeAt(index);
    row.dispose();
    setState(() {});
  }

  Future<void> _save() async {
    if (!_canSubmit) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      await widget.inputSink.enqueueWorkerInput(
        user: widget.currentUser,
        type: WorkerInputType.expenseAllocation,
        payload: {
          'amount': _amount,
          'category': _category,
          'description': _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          'expense_date': _expenseDate.toIso8601String(),
          'expenseDate': _expenseDate.toIso8601String(),
          'reference': _referenceController.text.trim().isEmpty
              ? null
              : _referenceController.text.trim(),
          'allocationMode': _allocateAcrossBatches
              ? _allocationMode.name.toUpperCase()
              : null,
          'allocation_mode': _allocateAcrossBatches
              ? _allocationMode.name.toUpperCase()
              : null,
          'allocations': _allocateAcrossBatches
              ? _rows.map(_allocationPayload).toList()
              : <Map<String, Object?>>[],
        },
      );
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  Map<String, Object?> _allocationPayload(_AllocationRowState row) {
    final batch = _batches.firstWhere(
      (batch) => batch.id == row.batchId,
      orElse: () => BatchSummary(
        id: row.batchId ?? '',
        batchLabel: row.batchId ?? '',
        livestockType: '',
        currentCount: 0,
      ),
    );
    if (_allocationMode == ExpenseAllocationMode.percentage) {
      final percentage = row.value;
      return {
        'batchId': row.batchId,
        'batch_id': row.batchId,
        'batch_label': batch.batchLabel,
        'percentage': percentage,
        'percent': percentage / 100,
        'amount': _amount * (percentage / 100),
      };
    }
    final allocatedAmount = row.value;
    final percentage = _amount <= 0 ? 0.0 : (allocatedAmount / _amount) * 100;
    return {
      'batchId': row.batchId,
      'batch_id': row.batchId,
      'batch_label': batch.batchLabel,
      'percentage': percentage,
      'percent': percentage / 100,
      'amount': allocatedAmount,
    };
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.94,
      minChildSize: 0.64,
      maxChildSize: 0.98,
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
                Row(
                  children: [
                    const CircleAvatar(
                      backgroundColor: Color(0xffe8f4ed),
                      foregroundColor: Color(0xff1f7a4d),
                      child: Icon(Icons.receipt_long_outlined),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Log Expense',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w900,
                          letterSpacing: 0,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close',
                      onPressed: () => Navigator.of(context).pop(false),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    prefixIcon: Icon(Icons.category_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'FEED', child: Text('FEED')),
                    DropdownMenuItem(
                      value: 'MEDICATION',
                      child: Text('MEDICATION'),
                    ),
                    DropdownMenuItem(
                      value: 'EQUIPMENT',
                      child: Text('EQUIPMENT'),
                    ),
                    DropdownMenuItem(value: 'LABOR', child: Text('LABOR')),
                    DropdownMenuItem(
                      value: 'UTILITIES',
                      child: Text('UTILITIES'),
                    ),
                    DropdownMenuItem(
                      value: 'TRANSPORT',
                      child: Text('TRANSPORT'),
                    ),
                    DropdownMenuItem(
                      value: 'MAINTENANCE',
                      child: Text('MAINTENANCE'),
                    ),
                    DropdownMenuItem(value: 'OTHER', child: Text('OTHER')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _category = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^\d*\.?\d{0,2}'),
                    ),
                  ],
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Amount (GHS)',
                    prefixIcon: Icon(Icons.payments_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _pickDateTime,
                  icon: const Icon(Icons.event_outlined),
                  label: Text(_dateTimeLabel(_expenseDate)),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _referenceController,
                  decoration: const InputDecoration(
                    labelText: 'Reference / Receipt',
                    hintText: 'Ref-001',
                    prefixIcon: Icon(Icons.tag_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _descriptionController,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Description',
                    prefixIcon: Icon(Icons.notes_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                SwitchListTile(
                  value: _allocateAcrossBatches,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'Allocate this expense across multiple batches',
                    style: TextStyle(fontWeight: FontWeight.w900),
                  ),
                  subtitle: Text('${_batches.length} active batches available'),
                  onChanged: (value) {
                    setState(() => _allocateAcrossBatches = value);
                  },
                ),
                if (_allocateAcrossBatches) ...[
                  const SizedBox(height: 8),
                  SegmentedButton<ExpenseAllocationMode>(
                    segments: const [
                      ButtonSegment(
                        value: ExpenseAllocationMode.percentage,
                        label: Text('Percentage'),
                      ),
                      ButtonSegment(
                        value: ExpenseAllocationMode.amount,
                        label: Text('Amount'),
                      ),
                    ],
                    selected: {_allocationMode},
                    onSelectionChanged: (values) {
                      setState(() => _allocationMode = values.first);
                    },
                  ),
                  const SizedBox(height: 12),
                  for (var index = 0; index < _rows.length; index += 1) ...[
                    _AllocationRow(
                      row: _rows[index],
                      index: index,
                      batches: _batches,
                      disabledBatchIds: _selectedBatchIdsExcept(index),
                      suffix:
                          _allocationMode == ExpenseAllocationMode.percentage
                          ? '%'
                          : 'GHS',
                      canDelete: _rows.length > 1,
                      onChanged: () => setState(() {}),
                      onDelete: () => _removeRow(index),
                    ),
                    const SizedBox(height: 10),
                  ],
                  OutlinedButton.icon(
                    onPressed: _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('Add Batch Allocation'),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Chip(
                      label: Text(_balanceMessage),
                      backgroundColor: _balanceColor.withValues(alpha: 0.13),
                      labelStyle: TextStyle(
                        color: _balanceColor,
                        fontWeight: FontWeight.w900,
                      ),
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
                  label: const Text('Save Expense'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: const Color(0xff1f7a4d),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Set<String> _selectedBatchIdsExcept(int index) {
    final selected = <String>{};
    for (var i = 0; i < _rows.length; i += 1) {
      if (i == index) {
        continue;
      }
      final batchId = _rows[i].batchId;
      if (batchId != null && batchId.isNotEmpty) {
        selected.add(batchId);
      }
    }
    return selected;
  }
}

class _AllocationRowState {
  final TextEditingController controller = TextEditingController();
  String? batchId;

  double get value => double.tryParse(controller.text.trim()) ?? 0;

  void dispose() {
    controller.dispose();
  }
}

class _AllocationRow extends StatelessWidget {
  const _AllocationRow({
    required this.row,
    required this.index,
    required this.batches,
    required this.disabledBatchIds,
    required this.suffix,
    required this.canDelete,
    required this.onChanged,
    required this.onDelete,
  });

  final _AllocationRowState row;
  final int index;
  final List<BatchSummary> batches;
  final Set<String> disabledBatchIds;
  final String suffix;
  final bool canDelete;
  final VoidCallback onChanged;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe2e8e4)),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              initialValue: row.batchId,
              decoration: InputDecoration(labelText: 'Batch ${index + 1}'),
              items: [
                for (final batch in batches)
                  DropdownMenuItem(
                    value: batch.id,
                    enabled:
                        !disabledBatchIds.contains(batch.id) ||
                        row.batchId == batch.id,
                    child: Text(
                      batch.batchLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (value) {
                row.batchId = value;
                onChanged();
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: row.controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              onChanged: (_) => onChanged(),
              decoration: InputDecoration(labelText: suffix),
            ),
          ),
          IconButton(
            tooltip: 'Delete allocation',
            onPressed: canDelete ? onDelete : null,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
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

String _dateTimeLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  final hour = date.hour.toString().padLeft(2, '0');
  final minute = date.minute.toString().padLeft(2, '0');
  return '${date.year}-$month-$day $hour:$minute';
}

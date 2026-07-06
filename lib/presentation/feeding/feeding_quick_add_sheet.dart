import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../core/storage/local_database.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/sync/data/worker_log_mutator.dart';
import '../../utils/feed_source_utils.dart';
import '../worker/widgets/quick_add_batch_grid.dart';

class FeedingQuickAddSheet extends StatefulWidget {
  const FeedingQuickAddSheet({
    super.key,
    required this.currentUser,
    required this.batch,
    required this.inputSink,
    required this.localDatabase,
    this.onOpenInventory,
    this.onCreateFormulation,
    this.editConfig,
    this.initialRow,
  });

  final AppUser currentUser;
  final BatchSummary batch;
  final WorkerInputSink inputSink;
  final LocalDatabase localDatabase;
  final VoidCallback? onOpenInventory;
  final VoidCallback? onCreateFormulation;
  final WorkerLogEditConfig? editConfig;
  final Map<String, Object?>? initialRow;

  @override
  State<FeedingQuickAddSheet> createState() => _FeedingQuickAddSheetState();
}

class _FeedingQuickAddSheetState extends State<FeedingQuickAddSheet> {
  final _amountController = TextEditingController();

  bool _loading = true;
  bool _isSaving = false;
  DateTime _logDate = DateTime.now();
  List<_FeedOption> _options = const [];
  String? _selectedValue;

  double get _amount => double.tryParse(_amountController.text.trim()) ?? 0;
  bool get _canSubmit =>
      !_loading && !_isSaving && _selectedValue != null && _amount > 0;

  @override
  void initState() {
    super.initState();
    _loadOptions();
  }

  @override
  void dispose() {
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _loadOptions() async {
    final inventoryRows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, item_name, unit
      from inventory
      where farm_id = ?
        and is_deleted = 0
        and (lower(coalesce(category, '')) = 'feed'
          or lower(coalesce(item_group, '')) = 'feed')
      order by item_name asc
      ''',
      [widget.currentUser.activeFarmId],
    );
    final formulationRows = await widget.localDatabase.rawLocalQuery(
      '''
      select id, name
      from feed_formulations
      where farm_id = ?
      order by name asc
      ''',
      [widget.currentUser.activeFarmId],
    );

    final options = [
      for (final row in inventoryRows)
        _FeedOption(
          value: 'inv_${row['id']}',
          label: '[Inventory] ${row['item_name']}',
          id: row['id']?.toString() ?? '',
          kind: _FeedOptionKind.inventory,
        ),
      for (final row in formulationRows)
        _FeedOption(
          value: 'form_${row['id']}',
          label: '[Formulation] ${row['name']}',
          id: row['id']?.toString() ?? '',
          kind: _FeedOptionKind.formulation,
        ),
    ];
    if (!mounted) {
      return;
    }
    setState(() {
      _options = options;
      if (widget.initialRow != null) {
        final feedTypeId = widget.initialRow!['feed_type_id']?.toString() ?? '';
        final formulationId =
            widget.initialRow!['formulation_id']?.toString() ?? '';
        if (feedTypeId.isNotEmpty) {
          _selectedValue = 'inv_$feedTypeId';
        } else if (formulationId.isNotEmpty) {
          _selectedValue = 'form_$formulationId';
        } else {
          _selectedValue = options.isEmpty ? null : options.first.value;
        }
        final amount = widget.initialRow!['amount_consumed'];
        if (amount != null) {
          _amountController.text = amount.toString();
        }
        final logDate = DateTime.tryParse(
          widget.initialRow!['log_date']?.toString() ?? '',
        );
        if (logDate != null) {
          _logDate = logDate;
        }
      } else {
        _selectedValue = options.isEmpty ? null : options.first.value;
      }
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (!_canSubmit || _selectedValue == null) {
      return;
    }
    final selected = _options
        .where((option) => option.value == _selectedValue)
        .firstOrNull;
    if (selected == null) {
      return;
    }
    final feedSource = parseFeedSource(
      selected.value,
      label: selected.label,
    );
    setState(() => _isSaving = true);
    try {
      final payload = {
        'batch_id': widget.batch.id,
        'feed_type_id': feedSource.feedTypeId,
        'formulation_id': feedSource.formulationId,
        'feed_type': feedSource.label,
        'amount_consumed': _amount,
        'bags': _amount,
        'log_date': _logDate.toIso8601String(),
      };
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
          type: WorkerInputType.feedUsage,
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

  void _setAmount(double amount) {
    _amountController.text = amount.toStringAsFixed(
      amount.truncateToDouble() == amount ? 0 : 2,
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.84,
      minChildSize: 0.48,
      maxChildSize: 0.94,
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
                  title: 'Log Feeding',
                  subtitle: widget.batch.batchLabel,
                  icon: Icons.grass_outlined,
                  color: const Color(0xff1f7a4d),
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_options.isEmpty)
                  _EmptyFeedState(
                    onOpenInventory: widget.onOpenInventory,
                    onCreateFormulation: widget.onCreateFormulation,
                  )
                else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _selectedValue,
                    decoration: const InputDecoration(
                      labelText: 'Feed Type',
                      prefixIcon: Icon(Icons.inventory_2_outlined),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: [
                      for (final option in _options)
                        DropdownMenuItem(
                          value: option.value,
                          child: Text(
                            option.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() => _selectedValue = value);
                    },
                  ),
                  const SizedBox(height: 14),
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
                      labelText: 'Amount Consumed (Bags)',
                      prefixIcon: Icon(Icons.scale_outlined),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _AmountChip(
                        label: '1/4 Bag',
                        onTap: () => _setAmount(0.25),
                      ),
                      _AmountChip(
                        label: '1/2 Bag',
                        onTap: () => _setAmount(0.5),
                      ),
                      _AmountChip(
                        label: '3/4 Bag',
                        onTap: () => _setAmount(0.75),
                      ),
                      _AmountChip(label: '1 Bag', onTap: () => _setAmount(1)),
                    ],
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
                  const SizedBox(height: 18),
                  FilledButton.icon(
                    onPressed: _canSubmit ? _save : null,
                    icon: _isSaving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: const Text('Save Feeding Log'),
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(54),
                      backgroundColor: const Color(0xff1f7a4d),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

enum _FeedOptionKind { inventory, formulation }

class _FeedOption {
  const _FeedOption({
    required this.value,
    required this.label,
    required this.id,
    required this.kind,
  });

  final String value;
  final String label;
  final String id;
  final _FeedOptionKind kind;
}

class _EmptyFeedState extends StatelessWidget {
  const _EmptyFeedState({this.onOpenInventory, this.onCreateFormulation});

  final VoidCallback? onOpenInventory;
  final VoidCallback? onCreateFormulation;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xffe2e8e4)),
      ),
      child: Column(
        children: [
          const Icon(
            Icons.inventory_2_outlined,
            size: 42,
            color: Color(0xff66736c),
          ),
          const SizedBox(height: 10),
          const Text(
            'No Feed Inventory or Formulations!',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.w900, fontSize: 17),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onOpenInventory == null
                      ? null
                      : () {
                          Navigator.of(context).pop(false);
                          onOpenInventory!();
                        },
                  child: const Text('Go to Inventory'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  onPressed: onCreateFormulation == null
                      ? null
                      : () {
                          Navigator.of(context).pop(false);
                          onCreateFormulation!();
                        },
                  child: const Text('Create Formulation'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AmountChip extends StatelessWidget {
  const _AmountChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      label: Text(label),
      avatar: const Icon(Icons.add, size: 18),
      onPressed: onTap,
      backgroundColor: const Color(0xffe8f4ed),
      labelStyle: const TextStyle(fontWeight: FontWeight.w800),
    );
  }
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

String _dateLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../worker/widgets/quick_add_batch_grid.dart';

class EggQuickAddSheet extends StatefulWidget {
  const EggQuickAddSheet({
    super.key,
    required this.currentUser,
    required this.batch,
    required this.inputSink,
  });

  final AppUser currentUser;
  final BatchSummary batch;
  final WorkerInputSink inputSink;

  @override
  State<EggQuickAddSheet> createState() => _EggQuickAddSheetState();
}

class _EggQuickAddSheetState extends State<EggQuickAddSheet> {
  final _totalEggsController = TextEditingController();
  final _cratesController = TextEditingController();
  final _remainderController = TextEditingController();
  final _smallController = TextEditingController();
  final _mediumController = TextEditingController();
  final _largeController = TextEditingController();
  final _unusableController = TextEditingController();

  bool _useCrates = false;
  bool _isSorted = false;
  bool _isSaving = false;
  DateTime _logDate = DateTime.now();
  String _qualityGrade = 'MEDIUM';

  int get _eggsCollected {
    if (_useCrates) {
      return (_intValue(_cratesController) * 30) +
          _intValue(_remainderController).clamp(0, 29);
    }
    return _intValue(_totalEggsController);
  }

  int get _allocated =>
      _intValue(_smallController) +
      _intValue(_mediumController) +
      _intValue(_largeController);

  int get _unusable => _intValue(_unusableController);

  String? get _validationError {
    if (_eggsCollected <= 0) {
      return 'Eggs collected is required.';
    }
    if (_isSorted && _allocated > _eggsCollected) {
      return 'Sum of sizes exceeds total eggs collected';
    }
    if (_unusable > _eggsCollected) {
      return 'Unusable eggs cannot exceed total eggs collected.';
    }
    return null;
  }

  bool get _canSubmit => !_isSaving && _validationError == null;

  @override
  void dispose() {
    _totalEggsController.dispose();
    _cratesController.dispose();
    _remainderController.dispose();
    _smallController.dispose();
    _mediumController.dispose();
    _largeController.dispose();
    _unusableController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_canSubmit) {
      return;
    }
    setState(() => _isSaving = true);
    try {
      await widget.inputSink.enqueueWorkerInput(
        user: widget.currentUser,
        type: WorkerInputType.eggCollection,
        payload: {
          'batch_id': widget.batch.id,
          'eggs_collected': _eggsCollected,
          'unusable_count': _unusable,
          'quality_grade': _isSorted ? null : _qualityGrade,
          'is_sorted': _isSorted,
          'small_count': _isSorted ? _intValue(_smallController) : 0,
          'medium_count': _isSorted ? _intValue(_mediumController) : 0,
          'large_count': _isSorted ? _intValue(_largeController) : 0,
          'log_date': _logDate.toIso8601String(),
          'crates': _useCrates ? _intValue(_cratesController) : 0,
          'single_eggs': _useCrates
              ? _intValue(_remainderController).clamp(0, 29)
              : _eggsCollected,
          'eggs_per_crate': 30,
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
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.92,
      minChildSize: 0.55,
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
                  title: 'Log Eggs',
                  subtitle: widget.batch.batchLabel,
                  icon: Icons.egg_alt_outlined,
                  color: const Color(0xffc7851f),
                ),
                const SizedBox(height: 16),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(
                      value: false,
                      label: Text('Individual Eggs'),
                      icon: Icon(Icons.egg_alt_outlined),
                    ),
                    ButtonSegment(
                      value: true,
                      label: Text('Crates (30/ea)'),
                      icon: Icon(Icons.inventory_2_outlined),
                    ),
                  ],
                  selected: {_useCrates},
                  onSelectionChanged: (values) {
                    setState(() => _useCrates = values.first);
                  },
                ),
                const SizedBox(height: 14),
                if (_useCrates)
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          controller: _cratesController,
                          label: 'Number of Crates',
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _NumberField(
                          controller: _remainderController,
                          label: 'Remainder Eggs',
                          maxValue: 29,
                          onChanged: () => setState(() {}),
                        ),
                      ),
                    ],
                  )
                else
                  _NumberField(
                    controller: _totalEggsController,
                    label: 'Total Eggs Collected',
                    onChanged: () => setState(() {}),
                  ),
                const SizedBox(height: 14),
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: false, label: Text('Unsorted')),
                    ButtonSegment(value: true, label: Text('Sorted')),
                  ],
                  selected: {_isSorted},
                  onSelectionChanged: (values) {
                    setState(() => _isSorted = values.first);
                  },
                ),
                const SizedBox(height: 14),
                if (!_isSorted)
                  DropdownButtonFormField<String>(
                    initialValue: _qualityGrade,
                    decoration: const InputDecoration(
                      labelText: 'General Egg Size',
                      prefixIcon: Icon(Icons.tune_outlined),
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: const [
                      DropdownMenuItem(value: 'SMALL', child: Text('Small')),
                      DropdownMenuItem(value: 'MEDIUM', child: Text('Medium')),
                      DropdownMenuItem(value: 'LARGE', child: Text('Large')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() => _qualityGrade = value);
                      }
                    },
                  )
                else ...[
                  Row(
                    children: [
                      Expanded(
                        child: _NumberField(
                          controller: _smallController,
                          label: 'Small',
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _NumberField(
                          controller: _mediumController,
                          label: 'Medium',
                          onChanged: () => setState(() {}),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _NumberField(
                          controller: _largeController,
                          label: 'Large',
                          onChanged: () => setState(() {}),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Chip(
                      label: Text('Allocated: $_allocated / $_eggsCollected'),
                      backgroundColor: _allocated <= _eggsCollected
                          ? const Color(0xffe8f4ed)
                          : const Color(0xffffeeee),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                _NumberField(
                  controller: _unusableController,
                  label: 'Unusable Eggs (Damaged/Cracked)',
                  onChanged: () => setState(() {}),
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
                  label: const Text('Save Egg Log'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(54),
                    backgroundColor: const Color(0xffc7851f),
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

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.maxValue,
  });

  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;
  final int? maxValue;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      onChanged: (_) {
        final max = maxValue;
        if (max != null) {
          final parsed = int.tryParse(controller.text);
          if (parsed != null && parsed > max) {
            controller.text = '$max';
            controller.selection = TextSelection.collapsed(
              offset: controller.text.length,
            );
          }
        }
        onChanged();
      },
      decoration: InputDecoration(
        labelText: label,
        filled: true,
        fillColor: Colors.white,
      ),
    );
  }
}

int _intValue(TextEditingController controller) {
  return int.tryParse(controller.text.trim()) ?? 0;
}

String _dateLabel(DateTime date) {
  final month = date.month.toString().padLeft(2, '0');
  final day = date.day.toString().padLeft(2, '0');
  return '${date.year}-$month-$day';
}

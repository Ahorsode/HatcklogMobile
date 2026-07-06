import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../features/sync/data/worker_input_sink.dart';
import '../../features/sync/data/worker_log_mutator.dart';
import '../../utils/egg_log_utils.dart';
import '../worker/widgets/quick_add_batch_grid.dart';

class EggQuickAddSheet extends StatefulWidget {
  const EggQuickAddSheet({
    super.key,
    required this.currentUser,
    required this.batch,
    required this.inputSink,
    this.editConfig,
    this.initialRow,
  });

  final AppUser currentUser;
  final BatchSummary batch;
  final WorkerInputSink inputSink;
  final WorkerLogEditConfig? editConfig;
  final Map<String, Object?>? initialRow;

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

  int get _eggsCollected => calculateEggsCollected(
    useCrates: _useCrates,
    crates: _intValue(_cratesController),
    remainder: _intValue(_remainderController),
    individualTotal: _intValue(_totalEggsController),
  );

  int get _allocated =>
      _intValue(_smallController) +
      _intValue(_mediumController) +
      _intValue(_largeController);

  int get _unusable => _intValue(_unusableController);

  String? get _validationError => validateEggLog(
    eggsCollected: _eggsCollected,
    unusableCount: _unusable,
    isSorted: _isSorted,
    smallCount: _intValue(_smallController),
    mediumCount: _intValue(_mediumController),
    largeCount: _intValue(_largeController),
  );

  bool get _canSubmit => !_isSaving && _validationError == null;

  @override
  void initState() {
    super.initState();
    _hydrateFromInitialRow();
  }

  void _hydrateFromInitialRow() {
    final row = widget.initialRow;
    if (row == null) {
      return;
    }
    final eggsCollected = _rowInt(row['eggs_collected']);
    final crates = _rowDouble(row['crates_collected']);
    if (crates > 0) {
      _useCrates = true;
      _cratesController.text = crates.toString();
      final remainder = eggsCollected - (crates * defaultEggsPerCrate).round();
      if (remainder > 0) {
        _remainderController.text = remainder.toString();
      }
    } else {
      _totalEggsController.text = eggsCollected.toString();
    }
    _unusableController.text = _rowInt(row['unusable_count']).toString();
    _isSorted = _rowBool(row['is_sorted']);
    _qualityGrade = normalizeQualityGrade(row['quality_grade']?.toString());
    _smallController.text = _rowInt(row['small_count']).toString();
    _mediumController.text = _rowInt(row['medium_count']).toString();
    _largeController.text = _rowInt(row['large_count']).toString();
    final logDate = DateTime.tryParse(row['log_date']?.toString() ?? '');
    if (logDate != null) {
      _logDate = logDate;
    }
  }

  int _rowInt(Object? value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.round();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  double _rowDouble(Object? value) {
    if (value is double) {
      return value;
    }
    if (value is num) {
      return value.toDouble();
    }
    return double.tryParse(value?.toString() ?? '') ?? 0;
  }

  bool _rowBool(Object? value) {
    if (value is bool) {
      return value;
    }
    if (value is num) {
      return value != 0;
    }
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text == 'true' || text == '1';
  }

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
      final payload = buildEggLogPayload(
        batchId: widget.batch.id,
        eggsCollected: _eggsCollected,
        unusableCount: _unusable,
        isSorted: _isSorted,
        qualityGrade: _qualityGrade,
        smallCount: _intValue(_smallController),
        mediumCount: _intValue(_mediumController),
        largeCount: _intValue(_largeController),
        logDate: _logDate,
        useCrates: _useCrates,
        crates: _intValue(_cratesController),
        remainder: _intValue(_remainderController),
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
          type: WorkerInputType.eggCollection,
          payload: payload,
        );
      }
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save egg log: $error')),
        );
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
                    setState(() {
                      _isSorted = values.first;
                      if (!_isSorted) {
                        _smallController.clear();
                        _mediumController.clear();
                        _largeController.clear();
                      }
                    });
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

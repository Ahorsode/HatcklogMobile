import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../features/livestock/data/livestock_models.dart';
import '../../../features/livestock/services/livestock_service.dart';

class QuarantineActionsSheet extends StatefulWidget {
  const QuarantineActionsSheet({
    super.key,
    required this.batch,
    required this.onRecover,
    required this.onLogMortality,
  });

  final LivestockBatchRecord batch;
  final Future<LivestockOperationResult> Function(int count) onRecover;
  final Future<LivestockOperationResult> Function(int count) onLogMortality;

  @override
  State<QuarantineActionsSheet> createState() => _QuarantineActionsSheetState();
}

class _QuarantineActionsSheetState extends State<QuarantineActionsSheet> {
  final _countController = TextEditingController();
  var _mode = _QuarantineMode.recover;
  var _saving = false;

  int get _count => int.tryParse(_countController.text.trim()) ?? 0;

  @override
  void dispose() {
    _countController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_count <= 0 || _count > widget.batch.isolationCount) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Enter a count between 1 and ${widget.batch.isolationCount}',
          ),
        ),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final result = _mode == _QuarantineMode.recover
          ? await widget.onRecover(_count)
          : await widget.onLogMortality(_count);
      if (!mounted) {
        return;
      }
      if (result.success) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Operation failed')),
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
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Isolation: ${widget.batch.batchName}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          Text(
            '${widget.batch.isolationCount} birds currently isolated',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          SegmentedButton<_QuarantineMode>(
            segments: const [
              ButtonSegment(
                value: _QuarantineMode.recover,
                label: Text('Recover'),
                icon: Icon(Icons.check_circle_outline),
              ),
              ButtonSegment(
                value: _QuarantineMode.mortality,
                label: Text('Log death'),
                icon: Icon(Icons.dangerous_outlined),
              ),
            ],
            selected: {_mode},
            onSelectionChanged: (value) => setState(() => _mode = value.first),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _countController,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: _mode == _QuarantineMode.recover
                  ? 'Birds to recover'
                  : 'Birds lost in isolation',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(
                    _mode == _QuarantineMode.recover
                        ? 'Recover birds'
                        : 'Log isolation mortality',
                  ),
          ),
        ],
      ),
    );
  }
}

enum _QuarantineMode { recover, mortality }

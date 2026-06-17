import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/models/worker_input_type.dart';
import '../../features/sync/data/worker_input_sink.dart';

class InventoryQuickAddSheet extends StatefulWidget {
  const InventoryQuickAddSheet({
    super.key,
    required this.currentUser,
    required this.inputSink,
  });

  final AppUser currentUser;
  final WorkerInputSink inputSink;

  @override
  State<InventoryQuickAddSheet> createState() => _InventoryQuickAddSheetState();
}

class _InventoryQuickAddSheetState extends State<InventoryQuickAddSheet> {
  final _nameController = TextEditingController();
  final _stockController = TextEditingController();
  final _unitController = TextEditingController(text: 'bags');

  String _category = 'feed';
  bool _isSaving = false;

  double get _stock => double.tryParse(_stockController.text.trim()) ?? -1;
  bool get _canSubmit =>
      !_isSaving && _nameController.text.trim().isNotEmpty && _stock >= 0;

  @override
  void dispose() {
    _nameController.dispose();
    _stockController.dispose();
    _unitController.dispose();
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
        type: WorkerInputType.inventoryItem,
        payload: {
          'item_name': _nameController.text.trim(),
          'stock_level': _stock,
          'unit': _unitController.text.trim().isEmpty
              ? 'bags'
              : _unitController.text.trim(),
          'category': _category,
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

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.68,
      minChildSize: 0.44,
      maxChildSize: 0.88,
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
                      child: Icon(Icons.inventory_2_outlined),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Add Inventory',
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
                TextField(
                  controller: _nameController,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Item Name',
                    prefixIcon: Icon(Icons.label_outline),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _stockController,
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
                    labelText: 'Stock Level',
                    prefixIcon: Icon(Icons.scale_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _unitController,
                  decoration: const InputDecoration(
                    labelText: 'Unit',
                    prefixIcon: Icon(Icons.straighten_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _category,
                  decoration: const InputDecoration(
                    labelText: 'Category',
                    prefixIcon: Icon(Icons.category_outlined),
                    filled: true,
                    fillColor: Colors.white,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'feed', child: Text('Feed')),
                    DropdownMenuItem(
                      value: 'medicine',
                      child: Text('Medicine'),
                    ),
                    DropdownMenuItem(
                      value: 'equipment',
                      child: Text('Equipment'),
                    ),
                    DropdownMenuItem(value: 'other', child: Text('Other')),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setState(() => _category = value);
                    }
                  },
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
                  label: const Text('Save Inventory Item'),
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
}

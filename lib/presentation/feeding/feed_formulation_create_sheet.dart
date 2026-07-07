import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';
import '../../services/feed_formulation_service.dart';

const _feedTypes = [
  'PRE_STARTER',
  'STARTER',
  'GROWER',
  'FINISHER',
  'BREEDER',
  'CUSTOM',
];

const _livestockTypes = [
  'POULTRY_BROILER',
  'POULTRY_LAYER',
  'CATTLE',
  'SHEEP_GOAT',
  'PIG',
];

class FeedFormulationCreateSheet extends StatefulWidget {
  const FeedFormulationCreateSheet({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    this.supabase,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final SupabaseClient? supabase;

  @override
  State<FeedFormulationCreateSheet> createState() =>
      _FeedFormulationCreateSheetState();
}

class _FeedFormulationCreateSheetState extends State<FeedFormulationCreateSheet> {
  final _nameController = TextEditingController();
  late final FeedFormulationService _service;
  final List<_IngredientRow> _ingredients = [];
  var _selectedType = _feedTypes[1];
  var _selectedLivestock = _livestockTypes[0];
  var _loading = true;
  var _saving = false;
  List<Map<String, Object?>> _inventory = const [];

  @override
  void initState() {
    super.initState();
    _service = FeedFormulationService(widget.localDatabase);
    _loadInventory();
  }

  @override
  void dispose() {
    _nameController.dispose();
    for (final row in _ingredients) {
      row.bagsController.dispose();
    }
    super.dispose();
  }

  Future<void> _loadInventory() async {
    final rows = await _service.loadFeedInventory(widget.currentUser.activeFarmId);
    if (!mounted) {
      return;
    }
    setState(() {
      _inventory = rows;
      _loading = false;
      if (_ingredients.isEmpty && rows.isNotEmpty) {
        _ingredients.add(
          _IngredientRow(inventoryId: rows.first['id']?.toString() ?? ''),
        );
      }
    });
  }

  double get _totalBags => _ingredients.fold(
    0,
    (sum, row) => sum + (double.tryParse(row.bagsController.text.trim()) ?? 0),
  );

  List<Map<String, Object?>> _availableForRow(int index) {
    final currentId = _ingredients[index].inventoryId;
    final otherIds = <String>{
      for (var i = 0; i < _ingredients.length; i++)
        if (i != index) _ingredients[i].inventoryId,
    }..remove('');
    return _inventory
        .where(
          (row) =>
              row['id']?.toString() == currentId ||
              !otherIds.contains(row['id']?.toString()),
        )
        .toList();
  }

  Future<void> _save() async {
    if (_saving) {
      return;
    }
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      _showMessage('Please name this formulation');
      return;
    }
    if (_ingredients.isEmpty) {
      _showMessage('Add at least one ingredient');
      return;
    }

    final payload = <FeedFormulationIngredientInput>[];
    for (final row in _ingredients) {
      final bags = double.tryParse(row.bagsController.text.trim()) ?? 0;
      if (row.inventoryId.isEmpty || bags <= 0) {
        _showMessage('Each ingredient needs a source and bag count');
        return;
      }
      payload.add(
        FeedFormulationIngredientInput(inventoryId: row.inventoryId, bags: bags),
      );
    }

    setState(() => _saving = true);
    try {
      await _service.createFormulation(
        farmId: widget.currentUser.activeFarmId,
        name: name,
        type: _selectedType,
        targetLivestock: _selectedLivestock,
        ingredients: payload,
        supabase: widget.supabase,
      );
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop('Feed formulation saved successfully!');
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _showMessage('Save failed: $error');
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        initialChildSize: 0.9,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        expand: false,
        builder: (context, scrollController) {
          return Material(
            color: const Color(0xfff4f7f5),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
              children: [
                Row(
                  children: [
                    IconButton.filledTonal(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: _saving || _loading ? null : _save,
                      icon: _saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline),
                      label: const Text('Save'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Create Feed Formulation',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900),
                ),
                const SizedBox(height: 16),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_inventory.isEmpty)
                  const Text(
                    'No feed inventory items available. Add feed stock in inventory first.',
                  )
                else ...[
                  TextField(
                    controller: _nameController,
                    decoration: const InputDecoration(
                      labelText: 'Formulation Name',
                      filled: true,
                      fillColor: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedType,
                    decoration: const InputDecoration(
                      labelText: 'Feed Type',
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: [
                      for (final type in _feedTypes)
                        DropdownMenuItem(
                          value: type,
                          child: Text(type.replaceAll('_', ' ')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _selectedType = value);
                    },
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: _selectedLivestock,
                    decoration: const InputDecoration(
                      labelText: 'Target Livestock',
                      filled: true,
                      fillColor: Colors.white,
                    ),
                    items: [
                      for (final type in _livestockTypes)
                        DropdownMenuItem(
                          value: type,
                          child: Text(type.replaceAll('_', ' ')),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) {
                        return;
                      }
                      setState(() => _selectedLivestock = value);
                    },
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Ingredients (bags from inventory)',
                          style: TextStyle(fontWeight: FontWeight.w800),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _ingredients.length >= _inventory.length
                            ? null
                            : () {
                                final used = _ingredients
                                    .map((row) => row.inventoryId)
                                    .toSet();
                                final next = _inventory
                                    .where(
                                      (row) =>
                                          !used.contains(row['id']?.toString()),
                                    )
                                    .firstOrNull;
                                if (next == null) {
                                  return;
                                }
                                setState(() {
                                  _ingredients.add(
                                    _IngredientRow(
                                      inventoryId:
                                          next['id']?.toString() ?? '',
                                    ),
                                  );
                                });
                              },
                        icon: const Icon(Icons.add),
                        label: const Text('Add'),
                      ),
                    ],
                  ),
                  for (var index = 0; index < _ingredients.length; index++) ...[
                    const SizedBox(height: 8),
                    _IngredientEditor(
                      options: _availableForRow(index),
                      row: _ingredients[index],
                      onChanged: () => setState(() {}),
                      onDelete: _ingredients.length <= 1
                          ? null
                          : () {
                              setState(() {
                                _ingredients[index].bagsController.dispose();
                                _ingredients.removeAt(index);
                              });
                            },
                    ),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    'Final batch size: ${_totalBags.toStringAsFixed(1)} bags',
                    style: const TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Color(0xff1f7a4d),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _IngredientRow {
  _IngredientRow({required this.inventoryId})
    : bagsController = TextEditingController();

  String inventoryId;
  final TextEditingController bagsController;
}

class _IngredientEditor extends StatelessWidget {
  const _IngredientEditor({
    required this.options,
    required this.row,
    required this.onChanged,
    this.onDelete,
  });

  final List<Map<String, Object?>> options;
  final _IngredientRow row;
  final VoidCallback onChanged;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final selected = options
        .where((item) => item['id']?.toString() == row.inventoryId)
        .firstOrNull;
    final maxStock = selected == null
        ? 0.0
        : double.tryParse(selected['stock_level']?.toString() ?? '') ?? 0;

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: DropdownButtonFormField<String>(
            initialValue: row.inventoryId.isEmpty ? null : row.inventoryId,
            decoration: const InputDecoration(
              labelText: 'Ingredient',
              filled: true,
              fillColor: Colors.white,
            ),
            items: [
              for (final item in options)
                DropdownMenuItem(
                  value: item['id']?.toString() ?? '',
                  child: Text(item['item_name']?.toString() ?? 'Ingredient'),
                ),
            ],
            onChanged: (value) {
              if (value == null) {
                return;
              }
              row.inventoryId = value;
              onChanged();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: TextField(
            controller: row.bagsController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*')),
            ],
            onChanged: (_) => onChanged(),
            decoration: InputDecoration(
              labelText: 'Bags',
              helperText: maxStock > 0 ? 'Max ${maxStock.toStringAsFixed(0)}' : null,
              filled: true,
              fillColor: Colors.white,
            ),
          ),
        ),
        IconButton(
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
        ),
      ],
    );
  }
}

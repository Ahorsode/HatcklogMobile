import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../features/livestock/data/livestock_models.dart';
import '../../../features/livestock/services/livestock_service.dart';
import '../../../utils/livestock_breed_options.dart';
import 'widgets/livestock_batch_card.dart';

class EditLivestockSheet extends StatefulWidget {
  const EditLivestockSheet({
    super.key,
    required this.batch,
    required this.houses,
    required this.onSubmit,
  });

  final LivestockBatchRecord batch;
  final List<HouseOption> houses;
  final Future<LivestockOperationResult> Function(UpdateLivestockDraft draft)
      onSubmit;

  @override
  State<EditLivestockSheet> createState() => _EditLivestockSheetState();
}

class _EditLivestockSheetState extends State<EditLivestockSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _countController;
  late final TextEditingController _growthTargetController;
  late String _category;
  late String _breedKey;
  late String? _houseId;
  late DateTime _arrivalDate;
  late String _status;
  var _saving = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.batch.batchName);
    _countController =
        TextEditingController(text: widget.batch.initialCount.toString());
    _growthTargetController = TextEditingController(
      text: widget.batch.growthTargetOverride,
    );
    _category = widget.batch.categoryLabel;
    _breedKey = LivestockBreedCatalog.normalizeBreedKey(widget.batch.breedType);
    _houseId = widget.batch.houseId;
    _arrivalDate = widget.batch.arrivalDate;
    _status = widget.batch.status;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _countController.dispose();
    _growthTargetController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _houseId == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final draft = UpdateLivestockDraft(
        batchName: _nameController.text.trim(),
        category: _category,
        breedKey: _breedKey,
        houseId: _houseId!,
        initialCount: int.parse(_countController.text.trim()),
        arrivalDate: _arrivalDate,
        status: _status,
        growthTargetOverride: _growthTargetController.text.trim(),
      );
      final result = await widget.onSubmit(draft);
      if (!mounted) {
        return;
      }
      if (result.success) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Failed to update unit')),
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
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Edit Livestock Unit',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Unit name'),
                validator: (value) =>
                    (value ?? '').trim().length < 2 ? 'Enter a unit name' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final category in LivestockBreedCatalog.categories)
                    DropdownMenuItem(value: category, child: Text(category)),
                ],
                onChanged: (value) {
                  if (value == null) {
                    return;
                  }
                  setState(() {
                    _category = value;
                    final breeds =
                        LivestockBreedCatalog.optionsForCategory(value);
                    _breedKey = breeds.isNotEmpty ? breeds.first.key : '';
                  });
                },
              ),
              const SizedBox(height: 12),
              BreedPicker(
                category: _category,
                selectedKey: _breedKey,
                onChanged: (value) => setState(() => _breedKey = value),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _houseId,
                decoration: const InputDecoration(labelText: 'House'),
                items: [
                  for (final house in widget.houses)
                    DropdownMenuItem(
                      value: house.id,
                      child: Text(house.name),
                    ),
                ],
                onChanged: (value) => setState(() => _houseId = value),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _countController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Initial quantity'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _status,
                decoration: const InputDecoration(labelText: 'Status'),
                items: const [
                  DropdownMenuItem(value: 'active', child: Text('Active')),
                  DropdownMenuItem(
                    value: 'completed',
                    child: Text('Completed'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _status = value);
                  }
                },
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _growthTargetController,
                decoration: const InputDecoration(
                  labelText: 'Growth target override (optional)',
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
                    : const Text('Save changes'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class DeleteLivestockSheet extends StatefulWidget {
  const DeleteLivestockSheet({
    super.key,
    required this.batchName,
    required this.onConfirm,
  });

  final String batchName;
  final Future<LivestockOperationResult> Function(String reason) onConfirm;

  @override
  State<DeleteLivestockSheet> createState() => _DeleteLivestockSheetState();
}

class _DeleteLivestockSheetState extends State<DeleteLivestockSheet> {
  final _reasonController = TextEditingController();
  var _saving = false;

  @override
  void dispose() {
    _reasonController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final reason = _reasonController.text.trim();
    if (reason.length < 5) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reason must be at least 5 characters')),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await widget.onConfirm(reason);
      if (!mounted) {
        return;
      }
      if (result.success) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Delete failed')),
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
            'Delete ${widget.batchName}?',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 8),
          const Text(
            'This soft-deletes the unit. Provide a reason for the audit trail.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _reasonController,
            maxLines: 3,
            decoration: const InputDecoration(
              labelText: 'Deletion reason',
            ),
          ),
          const SizedBox(height: 16),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: _saving ? null : _submit,
            child: _saving
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Delete unit'),
          ),
        ],
      ),
    );
  }
}

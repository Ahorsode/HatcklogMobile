import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/models/app_user.dart';
import '../../../features/livestock/data/livestock_models.dart';
import '../../../features/livestock/services/livestock_service.dart';
import '../../../services/local_house_service.dart';
import '../../../utils/livestock_breed_options.dart';
import 'widgets/livestock_batch_card.dart';

const _newHouseSentinel = '__NEW_HOUSE__';

class RegisterLivestockSheet extends StatefulWidget {
  const RegisterLivestockSheet({
    super.key,
    required this.service,
    required this.currentUser,
    required this.houses,
    required this.onSubmit,
    required this.onHouseCreated,
  });

  final LivestockService service;
  final AppUser currentUser;
  final List<HouseOption> houses;
  final Future<LivestockOperationResult> Function(CreateLivestockDraft draft)
      onSubmit;
  final Future<void> Function() onHouseCreated;

  @override
  State<RegisterLivestockSheet> createState() => _RegisterLivestockSheetState();
}

class _RegisterLivestockSheetState extends State<RegisterLivestockSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _countController = TextEditingController(text: '1000');
  final _vaccineNameController = TextEditingController();
  final _houseNameController = TextEditingController();
  final _houseCapacityController = TextEditingController();

  var _category = LivestockBreedCatalog.categories.first;
  var _breedKey = 'ross_308';
  String? _houseId;
  DateTime _arrivalDate = DateTime.now();
  DateTime? _vaccinationDate;
  var _saving = false;
  var _creatingHouse = false;
  late List<HouseOption> _houses;

  @override
  void initState() {
    super.initState();
    _houses = List<HouseOption>.from(widget.houses);
    if (_houses.isNotEmpty) {
      _houseId = _houses.first.id;
    }
    _syncBreedForCategory();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _countController.dispose();
    _vaccineNameController.dispose();
    _houseNameController.dispose();
    _houseCapacityController.dispose();
    super.dispose();
  }

  void _syncBreedForCategory() {
    final breeds = LivestockBreedCatalog.optionsForCategory(_category);
    _breedKey = breeds.isNotEmpty ? breeds.first.key : '';
  }

  Future<void> _reloadHouses() async {
    final farmId = widget.currentUser.activeFarmId;
    final houses = await widget.service.loadHouses(farmId);
    if (!mounted) {
      return;
    }
    setState(() {
      _houses = houses;
      if (_houseId == null && houses.isNotEmpty) {
        _houseId = houses.last.id;
      }
    });
  }

  Future<void> _createHouse() async {
    final name = _houseNameController.text.trim();
    final capacity = int.tryParse(_houseCapacityController.text.trim()) ?? 0;
    if (name.isEmpty || capacity < 1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter house name and capacity (at least 1).'),
        ),
      );
      return;
    }

    setState(() => _creatingHouse = true);
    try {
      final houseService = LocalHouseService(widget.service.repository.database);
      final id = await houseService.createHouse(
        farmId: widget.currentUser.activeFarmId,
        userId: widget.currentUser.id,
        name: name,
        capacity: capacity,
      );
      await widget.onHouseCreated();
      await _reloadHouses();
      if (!mounted) {
        return;
      }
      setState(() {
        _houseId = id;
        _houseNameController.clear();
        _houseCapacityController.clear();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('House created successfully')),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create house: $error')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _creatingHouse = false);
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _houseId == null) {
      return;
    }
    setState(() => _saving = true);
    try {
      final draft = CreateLivestockDraft(
        batchName: _nameController.text.trim(),
        category: _category,
        breedKey: _breedKey,
        houseId: _houseId!,
        initialCount: int.parse(_countController.text.trim()),
        arrivalDate: _arrivalDate,
        vaccinationDate: _vaccinationDate,
        vaccineName: _vaccineNameController.text.trim().isEmpty
            ? null
            : _vaccineNameController.text.trim(),
      );
      final result = await widget.onSubmit(draft);
      if (!mounted) {
        return;
      }
      if (result.success) {
        Navigator.of(context).pop(result);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(result.error ?? 'Failed to register unit')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _pickDate({
    required DateTime initial,
    required ValueChanged<DateTime> onPicked,
    DateTime? firstDate,
    DateTime? lastDate,
  }) async {
    final picked = await showDatePicker(
      context: context,
      firstDate: firstDate ?? DateTime(2020),
      lastDate: lastDate ?? DateTime.now().add(const Duration(days: 365 * 2)),
      initialDate: initial,
    );
    if (picked != null) {
      onPicked(picked);
    }
  }

  Future<void> _openHouseDialog() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create New Farm House'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _houseNameController,
              enabled: !_creatingHouse,
              decoration: const InputDecoration(
                labelText: 'House Name / Number',
                hintText: 'e.g. House Alpha, Pen 1',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _houseCapacityController,
              enabled: !_creatingHouse,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Total Capacity (Birds/Heads)',
                hintText: 'e.g. 500',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _creatingHouse ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _creatingHouse
                ? null
                : () async {
                    await _createHouse();
                    if (context.mounted) {
                      Navigator.of(context).pop();
                    }
                  },
            child: _creatingHouse
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create House'),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: bottomInset + 16,
      ),
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Register Livestock Unit',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (_houses.isEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'You need at least one farm house before registering a unit.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.error,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saving ? null : _openHouseDialog,
                  icon: const Icon(Icons.add_home_work_outlined),
                  label: const Text('Add New House First'),
                ),
              ] else ...[
                const SizedBox(height: 8),
                TextFormField(
                  controller: _nameController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Unit Name / Identity',
                    hintText: 'e.g., Q1-Broiler-Alpha',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (value) =>
                      (value ?? '').trim().length < 2 ? 'Unit name is required' : null,
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _category,
                  decoration: const InputDecoration(
                    labelText: 'Livestock Category',
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  items: [
                    for (final category in LivestockBreedCatalog.categories)
                      DropdownMenuItem(value: category, child: Text(category)),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            _category = value;
                            _syncBreedForCategory();
                          });
                        },
                ),
                const SizedBox(height: 12),
                const Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Primary Breed / Specie',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 8),
                BreedPicker(
                  category: _category,
                  selectedKey: _breedKey,
                  onChanged: _saving ? (_) {} : (value) => setState(() => _breedKey = value),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _countController,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: 'Initial Quantity',
                    hintText: '1000',
                    prefixIcon: Icon(Icons.pin_outlined),
                  ),
                  validator: (value) {
                    final count = int.tryParse(value ?? '') ?? 0;
                    return count < 1 ? 'Quantity must be at least 1' : null;
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: _houseId,
                  decoration: const InputDecoration(
                    labelText: 'Farm House',
                    prefixIcon: Icon(Icons.home_work_outlined),
                  ),
                  items: [
                    for (final house in _houses)
                      DropdownMenuItem(
                        value: house.id,
                        child: Text(house.name),
                      ),
                    const DropdownMenuItem(
                      value: _newHouseSentinel,
                      child: Text('➕ Add New House'),
                    ),
                  ],
                  onChanged: _saving
                      ? null
                      : (value) {
                          if (value == _newHouseSentinel) {
                            _openHouseDialog();
                            return;
                          }
                          setState(() => _houseId = value);
                        },
                  validator: (value) =>
                      value == null || value == _newHouseSentinel
                          ? 'House selection is required'
                          : null,
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.event_outlined),
                  title: const Text('Arrival / Hatch Date'),
                  subtitle: Text(_formatDate(_arrivalDate)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _saving
                      ? null
                      : () => _pickDate(
                            initial: _arrivalDate,
                            onPicked: (date) => setState(() => _arrivalDate = date),
                          ),
                ),
                const Divider(height: 28),
                Text(
                  'OPTIONAL INITIAL SCHEDULE',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: const Color(0xffd97706),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.vaccines_outlined),
                  title: const Text('1st Vaccination Date'),
                  subtitle: Text(
                    _vaccinationDate == null
                        ? 'Not set'
                        : _formatDate(_vaccinationDate!),
                  ),
                  trailing: _vaccinationDate == null
                      ? const Icon(Icons.chevron_right)
                      : IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: _saving
                              ? null
                              : () => setState(() => _vaccinationDate = null),
                        ),
                  onTap: _saving
                      ? null
                      : () => _pickDate(
                            initial: _vaccinationDate ?? DateTime.now(),
                            onPicked: (date) =>
                                setState(() => _vaccinationDate = date),
                          ),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _vaccineNameController,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Vaccine Name',
                    hintText: 'e.g., Gumboro',
                    prefixIcon: Icon(Icons.medical_services_outlined),
                  ),
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _saving ? null : _submit,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: const Color(0xff10b981),
                    foregroundColor: const Color(0xff064e3b),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text(
                          'Register Unit & Continue',
                          style: TextStyle(fontWeight: FontWeight.w900),
                        ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

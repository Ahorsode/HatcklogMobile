import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/settings/settings_profile_contract.dart';
import '../../core/storage/local_database.dart';
import '../../services/farm_settings_service.dart';
import 'trash_screen.dart';

enum _SettingsTab { farm, reminders, stock, security }

class SettingsHubScreen extends StatefulWidget {
  const SettingsHubScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    this.onOpenProfile,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final VoidCallback? onOpenProfile;

  @override
  State<SettingsHubScreen> createState() => _SettingsHubScreenState();
}

class _SettingsHubScreenState extends State<SettingsHubScreen> {
  late final FarmSettingsService _service;
  _SettingsTab _tab = _SettingsTab.farm;
  FarmSettingsData? _settings;
  SalesSettingsData? _salesSettings;
  List<FeedReorderItem> _feedItems = const [];
  final Map<String, TextEditingController> _reorderControllers = {};
  bool _loading = true;
  bool _saving = false;
  String? _message;

  final _nameController = TextEditingController();
  final _locationController = TextEditingController();
  final _capacityController = TextEditingController();
  final _eggsPerCrateController = TextEditingController();
  String _currency = SettingsProfileContract.defaultCurrency;
  final _eggReminderController = TextEditingController();
  final _feedReminderController = TextEditingController();
  int? _growthTarget;
  String _defaultEggUnit = SettingsProfileContract.defaultEggUnit;
  bool _allowEggUnitChange = false;
  String _defaultEggSortMode = SettingsProfileContract.defaultEggSortMode;
  bool _allowEggSortModeChange = false;
  bool _allowBatchOverride = false;
  bool _allowWorkerDiscounts = false;
  String _defaultDiscountType = SettingsProfileContract.defaultDiscountType;

  @override
  void initState() {
    super.initState();
    _service = FarmSettingsService(widget.localDatabase);
    _load();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _locationController.dispose();
    _capacityController.dispose();
    _eggsPerCrateController.dispose();
    _eggReminderController.dispose();
    _feedReminderController.dispose();
    for (final controller in _reorderControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final farmId = widget.currentUser.activeFarmId;
    final settings = await _service.load(farmId);
    final salesSettings = await _service.loadSalesSettings(farmId);
    final feedItems = await _service.loadFeedReorderItems(farmId);
    for (final controller in _reorderControllers.values) {
      controller.dispose();
    }
    _reorderControllers.clear();
    for (final item in feedItems) {
      _reorderControllers[item.id] = TextEditingController(
        text: item.reorderLevel.toStringAsFixed(0),
      );
    }
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _salesSettings = salesSettings;
      _feedItems = feedItems;
      _nameController.text = settings.farmName;
      _locationController.text = settings.farmLocation;
      _capacityController.text = settings.farmCapacity.toString();
      _eggsPerCrateController.text = settings.eggsPerCrate.toString();
      _currency = settings.currency;
      _eggReminderController.text = settings.eggRecordReminderTime;
      _feedReminderController.text = settings.feedRecordReminderTime;
      _growthTarget = settings.growthTargetStandard;
      _defaultEggUnit = settings.defaultEggUnit;
      _allowEggUnitChange = settings.allowEggUnitChange;
      _defaultEggSortMode = settings.defaultEggSortMode;
      _allowEggSortModeChange = settings.allowEggSortModeChange;
      _allowBatchOverride = salesSettings.allowBatchOverride;
      _allowWorkerDiscounts = salesSettings.allowWorkerDiscounts;
      _defaultDiscountType = salesSettings.defaultDiscountType;
      _loading = false;
    });
  }

  Future<void> _savePreferences() async {
    if (_saving || _settings == null) return;
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final data = FarmSettingsData(
        farmId: _settings!.farmId,
        farmName: _nameController.text,
        farmLocation: _locationController.text,
        farmCapacity: int.tryParse(_capacityController.text.trim()) ?? 0,
        currency: _currency,
        eggsPerCrate: int.tryParse(_eggsPerCrateController.text.trim()) ??
            SettingsProfileContract.defaultEggsPerCrate,
        eggRecordReminderTime: _eggReminderController.text.trim(),
        feedRecordReminderTime: _feedReminderController.text.trim(),
        growthTargetStandard: _growthTarget,
        defaultEggUnit: _defaultEggUnit,
        allowEggUnitChange: _allowEggUnitChange,
        defaultEggSortMode: _defaultEggSortMode,
        allowEggSortModeChange: _allowEggSortModeChange,
      );
      final salesData = SalesSettingsData(
        farmId: _settings!.farmId,
        allowBatchOverride: _allowBatchOverride,
        allowWorkerDiscounts: _allowWorkerDiscounts,
        defaultDiscountType: _defaultDiscountType,
      );
      await _service.saveFarmSettings(user: widget.currentUser, data: data);
      await _service.saveSalesSettings(
        user: widget.currentUser,
        data: salesData,
      );
      if (!mounted) return;
      setState(() {
        _settings = data;
        _salesSettings = salesData;
        _message = 'Settings saved.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveReorder(String inventoryId) async {
    final controller = _reorderControllers[inventoryId];
    if (controller == null) return;
    final value = double.tryParse(controller.text.trim()) ??
        SettingsProfileContract.defaultReorderLevelKg;
    await _service.saveReorderLevel(
      user: widget.currentUser,
      farmId: widget.currentUser.activeFarmId,
      inventoryId: inventoryId,
      reorderLevel: value,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reorder level saved.')),
    );
  }

  Future<void> _openTrash() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (context) => TrashScreen(
          currentUser: widget.currentUser,
          localDatabase: widget.localDatabase,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Farm Settings'),
        actions: [
          if (!_loading)
            TextButton.icon(
              onPressed: _saving ? null : _savePreferences,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: const Text('Save'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_message != null)
                  MaterialBanner(
                    content: Text(_message!),
                    actions: [
                      TextButton(
                        onPressed: () => setState(() => _message = null),
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                  child: Row(
                    children: _SettingsTab.values.map((tab) {
                      final selected = _tab == tab;
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ChoiceChip(
                          label: Text(_tabLabel(tab)),
                          selected: selected,
                          onSelected: (_) {
                            HapticFeedback.lightImpact();
                            setState(() => _tab = tab);
                          },
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (_tab == _SettingsTab.farm) ...[
                        _sectionTitle('Farm Information'),
                        _textField('Farm Name', _nameController),
                        _textField('Location', _locationController),
                        _textField('Total Capacity', _capacityController,
                            keyboard: TextInputType.number),
                        const SizedBox(height: 12),
                        OutlinedButton.icon(
                          onPressed: _openTrash,
                          icon: const Icon(Icons.restore_from_trash_outlined),
                          label: const Text('Data Recovery Center'),
                        ),
                      ],
                      if (_tab == _SettingsTab.reminders) ...[
                        _sectionTitle('Daily Record Reminders'),
                        _textField(
                          'Egg Collection Reminder (HH:MM)',
                          _eggReminderController,
                        ),
                        _textField(
                          'Feed Log Reminder (HH:MM)',
                          _feedReminderController,
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('Farm Currency'),
                        DropdownButtonFormField<String>(
                          key: ValueKey('currency-$_currency'),
                          initialValue: _currency,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                          ),
                          items: SettingsProfileContract.currencyOptions.entries
                              .map(
                                (entry) => DropdownMenuItem(
                                  value: entry.key,
                                  child: Text(entry.value),
                                ),
                              )
                              .toList(),
                          onChanged: (value) {
                            if (value != null) setState(() => _currency = value);
                          },
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('Eggs per Crate'),
                        _textField(
                          'Standard crate size',
                          _eggsPerCrateController,
                          keyboard: TextInputType.number,
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('Egg Logging Defaults'),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow changing egg unit'),
                          subtitle: const Text(
                            'Workers can switch between crates and individual eggs',
                          ),
                          value: _allowEggUnitChange,
                          onChanged: (value) =>
                              setState(() => _allowEggUnitChange = value),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _defaultEggUnit,
                          decoration: const InputDecoration(
                            labelText: 'Default logging unit',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'crate',
                              child: Text('Crates'),
                            ),
                            DropdownMenuItem(
                              value: 'individual',
                              child: Text('Individual eggs'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _defaultEggUnit = value);
                            }
                          },
                        ),
                        const SizedBox(height: 8),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow changing sort mode'),
                          subtitle: const Text(
                            'Workers can switch between sorted and unsorted',
                          ),
                          value: _allowEggSortModeChange,
                          onChanged: (value) =>
                              setState(() => _allowEggSortModeChange = value),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _defaultEggSortMode,
                          decoration: const InputDecoration(
                            labelText: 'Default sort mode',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'unsorted',
                              child: Text('Unsorted'),
                            ),
                            DropdownMenuItem(
                              value: 'sorted',
                              child: Text('Sorted'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _defaultEggSortMode = value);
                            }
                          },
                        ),
                        const SizedBox(height: 12),
                        _sectionTitle('Sales Settings'),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow worker batch override'),
                          subtitle: const Text(
                            'Workers can choose FIFO vs specific batch',
                          ),
                          value: _allowBatchOverride,
                          onChanged: (value) =>
                              setState(() => _allowBatchOverride = value),
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Allow worker line discounts'),
                          subtitle: const Text(
                            'Workers can apply line discounts / free crates',
                          ),
                          value: _allowWorkerDiscounts,
                          onChanged: (value) =>
                              setState(() => _allowWorkerDiscounts = value),
                        ),
                        DropdownButtonFormField<String>(
                          initialValue: _defaultDiscountType,
                          decoration: const InputDecoration(
                            labelText: 'Worker default discount type',
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'item',
                              child: Text('Free items (giveaway)'),
                            ),
                            DropdownMenuItem(
                              value: 'flat',
                              child: Text('Flat amount'),
                            ),
                            DropdownMenuItem(
                              value: 'percent',
                              child: Text('Percent'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value != null) {
                              setState(() => _defaultDiscountType = value);
                            }
                          },
                        ),
                      ],
                      if (_tab == _SettingsTab.stock) ...[
                        _sectionTitle('Feed Reorder Levels'),
                        if (_feedItems.isEmpty)
                          const Text(
                            'No feed inventory items found. Add inventory first.',
                            style: TextStyle(color: Color(0xff66736c)),
                          )
                        else
                          ..._feedItems.map((item) {
                            final controller = _reorderControllers[item.id]!;
                            return Card(
                              margin: const EdgeInsets.only(bottom: 10),
                              child: ListTile(
                                title: Text(
                                  item.itemName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w900,
                                  ),
                                ),
                                subtitle: Text(
                                  'Current stock: ${item.stockLevel} ${item.unit}',
                                ),
                                trailing: SizedBox(
                                  width: 130,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: TextField(
                                          controller: controller,
                                          keyboardType: TextInputType.number,
                                          decoration: const InputDecoration(
                                            labelText: 'kg',
                                            isDense: true,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        tooltip: 'Save threshold',
                                        onPressed: () => _saveReorder(item.id),
                                        icon: const Icon(Icons.save_outlined),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                      ],
                      if (_tab == _SettingsTab.security) ...[
                        _sectionTitle('Security'),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Password and account security are managed from your personal profile.',
                                  style: TextStyle(color: Color(0xff66736c)),
                                ),
                                const SizedBox(height: 12),
                                if (widget.onOpenProfile != null)
                                  FilledButton(
                                    onPressed: widget.onOpenProfile,
                                    child: const Text('Go to Profile'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  String _tabLabel(_SettingsTab tab) {
    switch (tab) {
      case _SettingsTab.farm:
        return 'Farm Info';
      case _SettingsTab.reminders:
        return 'Reminders';
      case _SettingsTab.stock:
        return 'Stock Levels';
      case _SettingsTab.security:
        return 'Security';
    }
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, top: 4),
      child: Text(
        title,
        style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
      ),
    );
  }

  Widget _textField(
    String label,
    TextEditingController controller, {
    TextInputType keyboard = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        keyboardType: keyboard,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

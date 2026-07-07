import 'package:flutter/material.dart';

import '../../core/models/app_user.dart';
import '../../core/storage/local_database.dart';

class QuickAddCustomerSheet extends StatefulWidget {
  const QuickAddCustomerSheet({
    super.key,
    required this.localDatabase,
    required this.currentUser,
  });

  final LocalDatabase localDatabase;
  final AppUser currentUser;

  static Future<Map<String, Object?>?> show(
    BuildContext context, {
    required LocalDatabase localDatabase,
    required AppUser currentUser,
  }) {
    return showModalBottomSheet<Map<String, Object?>>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: QuickAddCustomerSheet(
          localDatabase: localDatabase,
          currentUser: currentUser,
        ),
      ),
    );
  }

  @override
  State<QuickAddCustomerSheet> createState() => _QuickAddCustomerSheetState();
}

class _QuickAddCustomerSheetState extends State<QuickAddCustomerSheet> {
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _saving) {
      return;
    }

    setState(() {
      _saving = true;
      _error = null;
    });

    try {
      final farmId = widget.currentUser.activeFarmId.trim();
      if (farmId.isEmpty) {
        throw StateError('No active farm selected.');
      }
      final now = DateTime.now().toUtc().toIso8601String();
      final id = 'customer_${DateTime.now().millisecondsSinceEpoch}';
      final row = <String, Object?>{
        'id': id,
        'farm_id': farmId,
        'name': name,
        'phone': _phoneController.text.trim(),
        'email': '',
        'address': '',
        'balance_owed': 0,
        'is_active': 1,
        'created_at': now,
        'updated_at': now,
      };
      await widget.localDatabase.insertLocalRecord('customers', row);
      if (!mounted) {
        return;
      }
      Navigator.of(context).pop(row);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Add customer',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
            ),
            const SizedBox(height: 4),
            Text(
              'Create a customer without leaving this sale.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _nameController,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Full name / company *',
                prefixIcon: Icon(Icons.person_outline),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: FilledButton.icon(
                    onPressed: _saving || _nameController.text.trim().isEmpty
                        ? null
                        : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.person_add_alt_1_outlined),
                    label: Text(_saving ? 'Saving...' : 'Save customer'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

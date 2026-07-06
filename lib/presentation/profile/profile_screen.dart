import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/app_user.dart';
import '../../core/settings/settings_profile_contract.dart';
import '../../core/storage/local_database.dart';
import '../../services/profile_update_service.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({
    super.key,
    required this.currentUser,
    required this.localDatabase,
    this.onProfileUpdated,
  });

  final AppUser currentUser;
  final LocalDatabase localDatabase;
  final ValueChanged<AppUser>? onProfileUpdated;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final ProfileUpdateService _service;
  late AppUser _user;
  final _firstNameController = TextEditingController();
  final _middleNameController = TextEditingController();
  final _surnameController = TextEditingController();
  bool _editing = false;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _service = ProfileUpdateService(widget.localDatabase);
    _user = widget.currentUser;
    _bindFields(_user);
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _middleNameController.dispose();
    _surnameController.dispose();
    super.dispose();
  }

  void _bindFields(AppUser user) {
    _firstNameController.text = user.firstName;
    _middleNameController.text = user.middleName;
    _surnameController.text = user.lastName;
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final updated = await _service.saveProfile(
        user: _user,
        firstName: _firstNameController.text,
        middleName: _middleNameController.text,
        surname: _surnameController.text,
      );
      if (!mounted) return;
      setState(() {
        _user = updated;
        _editing = false;
      });
      widget.onProfileUpdated?.call(updated);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile updated.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayName = SettingsProfileContract.buildDisplayName(
      firstName: _user.firstName,
      middleName: _user.middleName,
      surname: _user.lastName,
    );

    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      appBar: AppBar(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.white,
        title: const Text('Profile'),
        actions: [
          if (!_editing)
            IconButton(
              tooltip: 'Edit profile',
              onPressed: () {
                HapticFeedback.lightImpact();
                setState(() => _editing = true);
              },
              icon: const Icon(Icons.edit_outlined),
            )
          else
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Save'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xffe1e7e3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: const Color(0xff16845c),
                  child: Text(
                    displayName.isEmpty ? 'U' : displayName[0].toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  displayName.isEmpty ? 'Farm User' : displayName,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 6),
                Chip(
                  label: Text(_user.role.label),
                  avatar: const Icon(Icons.shield_outlined, size: 16),
                ),
                if (_user.email.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Icon(Icons.mail_outline, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_user.email)),
                    ],
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          _sectionCard(
            title: 'Personal Identity',
            child: _editing
                ? Column(
                    children: [
                      _textField('First Name', _firstNameController),
                      _textField('Middle Name (Optional)', _middleNameController),
                      _textField('Surname / Last Name', _surnameController),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () {
                                _bindFields(_user);
                                setState(() => _editing = false);
                              },
                        child: const Text('Cancel'),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _readRow('First Name', _user.firstName),
                      _readRow('Middle Name', _user.middleName),
                      _readRow('Surname', _user.lastName),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          _sectionCard(
            title: 'Farm Organization',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _readRow(
                  'Active Farm',
                  _user.activeFarmName.trim().isNotEmpty
                      ? _user.activeFarmName
                      : 'Not assigned',
                ),
                _readRow('Phone', _user.phoneNumber),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionCard({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xffe1e7e3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }

  Widget _readRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xff667085),
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.trim().isEmpty ? 'Not specified' : value,
              style: const TextStyle(fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }

  Widget _textField(String label, TextEditingController controller) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

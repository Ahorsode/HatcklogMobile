import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../data/auth_repository.dart';

class InitialSetupDialog extends StatefulWidget {
  const InitialSetupDialog({
    super.key,
    required this.authRepository,
    required this.pendingResult,
  });

  final AuthRepository authRepository;
  final AuthResult pendingResult;

  @override
  State<InitialSetupDialog> createState() => _InitialSetupDialogState();
}

class _InitialSetupDialogState extends State<InitialSetupDialog> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isSaving = false;
  bool _allowClose = false;
  String? _errorText;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate() || _isSaving) {
      return;
    }

    setState(() {
      _isSaving = true;
      _errorText = null;
    });

    try {
      final user = await widget.authRepository.completeInitialSetup(
        pendingResult: widget.pendingResult,
        newPassword: _passwordController.text,
        firstName: _firstNameController.text,
        lastName: _lastNameController.text,
      );

      if (!mounted) {
        return;
      }

      _allowClose = true;
      Navigator.of(context).pop<AppUser>(user);
    } on AuthFailure catch (error) {
      setState(() => _errorText = error.message);
    } catch (_) {
      setState(() => _errorText = 'Setup could not be saved.');
    } finally {
      if (mounted) {
        setState(() => _isSaving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return PopScope(
      canPop: _allowClose,
      child: AlertDialog(
        title: const Text('Initial Setup'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Create your personal login before using this device offline.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 18),
                TextFormField(
                  controller: _firstNameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'First Name',
                    prefixIcon: Icon(Icons.badge_outlined),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Enter your first name.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _lastNameController,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'Last Name',
                    prefixIcon: Icon(Icons.badge),
                  ),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Enter your last name.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _passwordController,
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: 'New Password',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  validator: (value) {
                    if (value == null || value.length < 8) {
                      return 'Use at least 8 characters.';
                    }
                    if (value == AuthRepository.defaultPassword) {
                      return 'Choose a personal password.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirmPasswordController,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  onFieldSubmitted: (_) => _save(),
                  decoration: const InputDecoration(
                    labelText: 'Confirm Password',
                    prefixIcon: Icon(Icons.verified_user_outlined),
                  ),
                  validator: (value) {
                    if (value != _passwordController.text) {
                      return 'Passwords do not match.';
                    }
                    return null;
                  },
                ),
                if (_errorText != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _errorText!,
                    style: TextStyle(
                      color: colorScheme.error,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton.icon(
            onPressed: _isSaving ? null : _save,
            icon: _isSaving
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: const Text('Save Setup'),
          ),
        ],
      ),
    );
  }
}

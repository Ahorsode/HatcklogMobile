import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../data/auth_repository.dart';

class MobileSocialPasscodeOverlay extends StatefulWidget {
  const MobileSocialPasscodeOverlay({
    super.key,
    required this.authRepository,
    required this.pendingResult,
  });

  final AuthRepository authRepository;
  final AuthResult pendingResult;

  @override
  State<MobileSocialPasscodeOverlay> createState() =>
      _MobileSocialPasscodeOverlayState();
}

class _MobileSocialPasscodeOverlayState
    extends State<MobileSocialPasscodeOverlay> {
  final _formKey = GlobalKey<FormState>();
  final _offlineKeyController = TextEditingController();
  final _confirmOfflineKeyController = TextEditingController();

  bool _obscureKey = true;
  bool _isSaving = false;
  bool _allowClose = false;
  String? _errorText;

  @override
  void dispose() {
    _offlineKeyController.dispose();
    _confirmOfflineKeyController.dispose();
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
      final user = await widget.authRepository
          .completeMobileSocialPasscodeSetup(
            pendingResult: widget.pendingResult,
            offlineKey: _offlineKeyController.text,
          );
      if (!mounted) {
        return;
      }
      _allowClose = true;
      Navigator.of(context).pop<AppUser>(user);
    } on AuthFailure catch (error) {
      setState(() => _errorText = error.message);
    } catch (_) {
      setState(() => _errorText = 'Offline key setup could not be saved.');
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
      child: Scaffold(
        backgroundColor: const Color(0xfff8faf7),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(
                        Icons.enhanced_encryption_outlined,
                        color: colorScheme.primary,
                        size: 56,
                      ),
                      const SizedBox(height: 18),
                      Text(
                        'Local Passcode Configuration',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: colorScheme.primary.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: colorScheme.primary.withValues(alpha: 0.2),
                          ),
                        ),
                        child: const Text(
                          'Welcome to HatchLog Mobile! Since you logged in with Google, please set a secondary 6-digit PIN or custom password. This ensures you can unlock your app and log farm data even when you are deep inside the coops with no internet.',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            height: 1.35,
                          ),
                        ),
                      ),
                      const SizedBox(height: 22),
                      TextFormField(
                        controller: _offlineKeyController,
                        obscureText: _obscureKey,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.next,
                        decoration: InputDecoration(
                          labelText: 'Mobile Offline Key',
                          prefixIcon: const Icon(Icons.pin_outlined),
                          suffixIcon: IconButton(
                            tooltip: _obscureKey
                                ? 'Show offline key'
                                : 'Hide offline key',
                            onPressed: () {
                              setState(() => _obscureKey = !_obscureKey);
                            },
                            icon: Icon(
                              _obscureKey
                                  ? Icons.visibility_outlined
                                  : Icons.visibility_off_outlined,
                            ),
                          ),
                        ),
                        validator: (value) {
                          if (value == null || value.length < 6) {
                            return 'Use at least 6 digits or characters.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 14),
                      TextFormField(
                        controller: _confirmOfflineKeyController,
                        obscureText: _obscureKey,
                        keyboardType: TextInputType.visiblePassword,
                        textInputAction: TextInputAction.done,
                        onFieldSubmitted: (_) => _save(),
                        decoration: const InputDecoration(
                          labelText: 'Confirm Mobile Offline Key',
                          prefixIcon: Icon(Icons.verified_user_outlined),
                        ),
                        validator: (value) {
                          if (value != _offlineKeyController.text) {
                            return 'Offline keys do not match.';
                          }
                          return null;
                        },
                      ),
                      if (_errorText != null) ...[
                        const SizedBox(height: 14),
                        Text(
                          _errorText!,
                          style: TextStyle(
                            color: colorScheme.error,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                      const SizedBox(height: 24),
                      FilledButton.icon(
                        onPressed: _isSaving ? null : _save,
                        icon: _isSaving
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.security_outlined),
                        label: const Text('Save Offline Key'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(54),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

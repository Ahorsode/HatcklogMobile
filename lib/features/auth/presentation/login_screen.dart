import 'package:flutter/material.dart';

import '../../../core/models/app_user.dart';
import '../data/auth_repository.dart';
import 'initial_setup_dialog.dart';
import 'mobile_social_passcode_overlay.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({
    super.key,
    required this.authRepository,
    required this.onAuthenticated,
  });

  final AuthRepository authRepository;
  final ValueChanged<AppUser> onAuthenticated;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _identifierController = TextEditingController();
  final _passwordController = TextEditingController();

  late Future<bool> _onlineFuture;
  _CredentialRoute _credentialRoute = _CredentialRoute.signIn;
  bool _isLoading = false;
  bool _isGoogleLoading = false;
  bool _obscurePassword = true;
  bool _isNewMobileSocialRegistrant = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _onlineFuture = widget.authRepository.isOnline;
  }

  @override
  void dispose() {
    _identifierController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _isLoading || _isGoogleLoading) {
      return;
    }

    setState(() {
      _isLoading = true;
      _errorText = null;
      _isNewMobileSocialRegistrant = false;
    });

    try {
      final result = _credentialRoute == _CredentialRoute.signUp
          ? await widget.authRepository.signUp(
              identifier: _identifierController.text,
              password: _passwordController.text,
            )
          : await widget.authRepository.signIn(
              identifier: _identifierController.text,
              password: _passwordController.text,
            );

      if (!mounted) {
        return;
      }

      await _handleAuthResult(result);
    } on AuthFailure catch (error) {
      _showAuthError(error.message);
    } catch (_) {
      _showAuthError('Unable to sign in right now.');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _onlineFuture = widget.authRepository.isOnline;
        });
      }
    }
  }

  Future<void> _authenticateWithGoogle() async {
    if (_isLoading || _isGoogleLoading) {
      return;
    }

    setState(() {
      _isGoogleLoading = true;
      _errorText = null;
      _isNewMobileSocialRegistrant = false;
    });

    try {
      final result = await widget.authRepository.authenticateMobileWithGoogle();
      if (!mounted) {
        return;
      }
      setState(() {
        _isNewMobileSocialRegistrant = result.requiresSocialRegistration;
      });
      await _handleAuthResult(result);
    } on AuthFailure catch (error) {
      _showAuthError(error.message);
    } catch (_) {
      _showAuthError('Google sign-in could not be completed.');
    } finally {
      if (mounted) {
        setState(() {
          _isGoogleLoading = false;
          _onlineFuture = widget.authRepository.isOnline;
        });
      }
    }
  }

  Future<void> _handleAuthResult(AuthResult result) async {
    if (result.requiresInitialSetup) {
      final setupUser = await showDialog<AppUser>(
        context: context,
        barrierDismissible: false,
        builder: (context) => InitialSetupDialog(
          authRepository: widget.authRepository,
          pendingResult: result,
        ),
      );

      if (!mounted || setupUser == null) {
        return;
      }

      widget.onAuthenticated(setupUser);
      return;
    }

    if (result.requiresSocialRegistration) {
      final setupUser = await showGeneralDialog<AppUser>(
        context: context,
        barrierDismissible: false,
        barrierLabel: 'Local passcode setup',
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (context, animation, secondaryAnimation) {
          return MobileSocialPasscodeOverlay(
            authRepository: widget.authRepository,
            pendingResult: result,
          );
        },
        transitionBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(opacity: animation, child: child);
        },
      );

      if (!mounted || setupUser == null) {
        return;
      }

      setState(() => _isNewMobileSocialRegistrant = false);
      widget.onAuthenticated(setupUser);
      return;
    }

    widget.onAuthenticated(result.user);
  }

  void _showAuthError(String message) {
    if (!mounted) {
      return;
    }
    setState(() => _errorText = message);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final busy = _isLoading || _isGoogleLoading;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.egg_alt_outlined,
                      color: colorScheme.primary,
                      size: 54,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'HatchLog Mobile',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Sign in with Google or your farm credentials.',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 18),
                    FutureBuilder<bool>(
                      future: _onlineFuture,
                      builder: (context, snapshot) {
                        final online = snapshot.data ?? true;
                        return _AuthModeBanner(online: online);
                      },
                    ),
                    if (_isNewMobileSocialRegistrant) ...[
                      const SizedBox(height: 12),
                      _InlineNotice(
                        icon: Icons.security_outlined,
                        text:
                            'Local passcode setup is required for this device.',
                        color: colorScheme.primary,
                      ),
                    ],
                    const SizedBox(height: 20),
                    OutlinedButton.icon(
                      onPressed: busy ? null : _authenticateWithGoogle,
                      icon: _isGoogleLoading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.account_circle_outlined),
                      label: const Text('Native Google Sign-In'),
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        const Expanded(child: Divider()),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Text(
                            'Email / Phone',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                        ),
                        const Expanded(child: Divider()),
                      ],
                    ),
                    const SizedBox(height: 18),
                    SegmentedButton<_CredentialRoute>(
                      segments: const [
                        ButtonSegment(
                          value: _CredentialRoute.signIn,
                          icon: Icon(Icons.login),
                          label: Text('Log In'),
                        ),
                        ButtonSegment(
                          value: _CredentialRoute.signUp,
                          icon: Icon(Icons.person_add_alt_1_outlined),
                          label: Text('Sign Up'),
                        ),
                      ],
                      selected: {_credentialRoute},
                      onSelectionChanged: busy
                          ? null
                          : (selection) {
                              setState(() {
                                _credentialRoute = selection.first;
                                _errorText = null;
                              });
                            },
                    ),
                    const SizedBox(height: 18),
                    TextFormField(
                      controller: _identifierController,
                      autofillHints: const [
                        AutofillHints.email,
                        AutofillHints.telephoneNumber,
                      ],
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: 'Email or Phone Number',
                        prefixIcon: Icon(Icons.alternate_email_outlined),
                      ),
                      validator: (value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter your email or phone number.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      autofillHints: const [AutofillHints.password],
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => _submit(),
                      decoration: InputDecoration(
                        labelText: 'Master Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _obscurePassword
                              ? 'Show password'
                              : 'Hide password',
                          onPressed: () {
                            setState(() {
                              _obscurePassword = !_obscurePassword;
                            });
                          },
                          icon: Icon(
                            _obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                          ),
                        ),
                      ),
                      validator: (value) {
                        if (value == null || value.isEmpty) {
                          return 'Enter your password.';
                        }
                        if (_credentialRoute == _CredentialRoute.signUp &&
                            value.length < 8) {
                          return 'Use at least 8 characters.';
                        }
                        return null;
                      },
                    ),
                    if (_errorText != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _errorText!,
                        style: TextStyle(
                          color: colorScheme.error,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      onPressed: busy ? null : _submit,
                      icon: _isLoading
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Icon(
                              _credentialRoute == _CredentialRoute.signUp
                                  ? Icons.person_add_alt_1_outlined
                                  : Icons.login,
                            ),
                      label: Text(
                        _credentialRoute == _CredentialRoute.signUp
                            ? 'Create Account'
                            : 'Unlock HatchLog',
                      ),
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
    );
  }
}

enum _CredentialRoute { signIn, signUp }

class _AuthModeBanner extends StatelessWidget {
  const _AuthModeBanner({required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online
        ? Theme.of(context).colorScheme.primary
        : const Color(0xffb7791f);
    final text = online
        ? 'Cloud Synchronized Mode'
        : 'Local Offline Validation Mode';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.09),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            online ? Icons.cloud_done_outlined : Icons.security_outlined,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: color, fontWeight: FontWeight.w900),
            ),
          ),
        ],
      ),
    );
  }
}

class _InlineNotice extends StatelessWidget {
  const _InlineNotice({
    required this.icon,
    required this.text,
    required this.color,
  });

  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }
}

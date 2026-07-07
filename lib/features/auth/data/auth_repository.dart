import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/connectivity/connectivity_service.dart';
import '../../../core/config/google_auth_config.dart';
import '../../../core/license/device_fingerprint.dart';
import '../../../core/license/license_service.dart';
import '../../../core/models/app_user.dart';
import '../../../core/permissions/local_effective_farm_role_resolver.dart';
import '../../../core/storage/local_database.dart';
import '../../../core/storage/secure_credential_store.dart';
import 'supabase_remote_api.dart';

enum AuthMode {
  cloud,
  offline,
  initialSetupRequired,
  socialRegistrationRequired,
}

class AuthResult {
  const AuthResult({
    required this.user,
    required this.mode,
    this.isNewMobileSocialRegistrant = false,
  });

  final AppUser user;
  final AuthMode mode;
  final bool isNewMobileSocialRegistrant;

  bool get requiresInitialSetup => mode == AuthMode.initialSetupRequired;
  bool get requiresSocialRegistration =>
      mode == AuthMode.socialRegistrationRequired;
}

class AuthFailure implements Exception {
  const AuthFailure(this.message);

  final String message;

  @override
  String toString() => message;
}

class AuthRepository {
  AuthRepository({
    required ConnectivityService connectivityService,
    required CredentialStore credentialStore,
    required LicenseService licenseService,
    required LocalDatabase localDatabase,
    required SupabaseRemoteApi remoteApi,
  }) : _connectivityService = connectivityService,
       _credentialStore = credentialStore,
       _licenseService = licenseService,
       _localDatabase = localDatabase,
       _remoteApi = remoteApi;

  static const defaultPassword = '123456';

  final ConnectivityService _connectivityService;
  final CredentialStore _credentialStore;
  final LicenseService _licenseService;
  final LocalDatabase _localDatabase;
  final SupabaseRemoteApi _remoteApi;
  final GoogleSignIn _googleSignIn = GoogleSignIn.instance;
  final ValueNotifier<bool> isNewMobileSocialRegistrant = ValueNotifier(false);

  static const _googleScopes = <String>['openid', 'email', 'profile'];

  bool _googleInitialized = false;

  Future<bool> get isOnline => _connectivityService.isOnline;

  Future<AppUser?> restoreActiveSession() async {
    final localRestored = await _restoreLocalSession();
    if (localRestored != null) {
      if (await _connectivityService.isOnline) {
        await _initTrialForUser(localRestored);
      }
      return localRestored;
    }

    if (_remoteApi.isConfigured && await _connectivityService.isOnline) {
      try {
        final cloudUser = await _remoteApi.currentAuthenticatedUser();
        if (cloudUser != null) {
          await _persistSession(cloudUser);
          await _initTrialForUser(cloudUser);
          return cloudUser.copyWith(
            authenticatedOffline: false,
            requiresInitialSetup: false,
          );
        }
      } on Object {
        // No saved session on this device.
      }
    }

    return null;
  }

  Future<AppUser?> _restoreLocalSession() async {
    final session = await _localDatabase.readSessionContext();
    final sessionUserId = session.userId?.trim() ?? '';
    if (sessionUserId.isEmpty) {
      return null;
    }

    final localUser = await _localDatabase.readUserById(sessionUserId);
    if (localUser == null) {
      return null;
    }

    final sessionFarmId = session.farmId?.trim() ?? '';
    var resolvedUser = localUser;
    if (sessionFarmId.isNotEmpty &&
        resolvedUser.activeFarmId.trim() != sessionFarmId) {
      resolvedUser = resolvedUser.copyWith(activeFarmId: sessionFarmId);
    }

    resolvedUser = await LocalEffectiveFarmRoleResolver(
      _localDatabase,
    ).applyToUser(resolvedUser);

    final online = await _connectivityService.isOnline;
    var authenticatedOffline = true;
    if (online && _remoteApi.isConfigured) {
      try {
        final cloudUser = await _remoteApi.currentAuthenticatedUser();
        if (cloudUser != null && cloudUser.id == resolvedUser.id) {
          resolvedUser = sessionFarmId.isNotEmpty
              ? cloudUser.copyWith(activeFarmId: sessionFarmId)
              : cloudUser;
          authenticatedOffline = false;
          await _persistSession(resolvedUser);
        }
      } on Object {
        // Keep the cached local session when cloud auth is unavailable.
      }
    } else {
      await _localDatabase.upsertUser(resolvedUser);
    }

    return resolvedUser.copyWith(
      authenticatedOffline: authenticatedOffline,
      requiresInitialSetup: false,
    );
  }

  Future<void> _persistSession(AppUser user) async {
    final resolvedUser = await LocalEffectiveFarmRoleResolver(
      _localDatabase,
    ).applyToUser(
      user.copyWith(requiresInitialSetup: false),
    );
    await _localDatabase.upsertUser(resolvedUser);
    await _localDatabase.writeSessionContext(
      userId: resolvedUser.id,
      farmId: resolvedUser.activeFarmId,
    );
  }

  Future<AuthResult> signIn({
    String? phoneNumber,
    String? identifier,
    required String password,
  }) async {
    final submittedIdentifier = identifier ?? phoneNumber ?? '';
    final normalizedIdentifier = normalizeLoginIdentifier(submittedIdentifier);

    if (normalizedIdentifier.isEmpty || password.isEmpty) {
      throw const AuthFailure('Email/phone and password are required.');
    }

    if (!await _connectivityService.isOnline) {
      return _signInOffline(
        submittedIdentifier: submittedIdentifier,
        normalizedIdentifier: normalizedIdentifier,
        password: password,
      );
    }

    if (password == defaultPassword) {
      return _signInForInitialSetup(
        authIdentifier: submittedIdentifier,
        localIdentifier: normalizedIdentifier,
        password: password,
      );
    }

    if (!_remoteApi.isConfigured) {
      throw const AuthFailure(
        'Supabase is not configured for this build. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY or SUPABASE_ANON_KEY.',
      );
    }

    try {
      final cloudUser = await _remoteApi.signInWithCredentials(
        identifier: submittedIdentifier,
        fallbackIdentifier: normalizedIdentifier,
        password: password,
      );

      if (cloudUser.requiresInitialSetup) {
        return AuthResult(
          user: cloudUser,
          mode: AuthMode.initialSetupRequired,
        );
      }

      await _cacheUserCredentials(cloudUser, password);
      return AuthResult(user: cloudUser, mode: AuthMode.cloud);
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } on Object {
      throw const AuthFailure(
        'Could not reach HatchLog cloud. Check your connection and try again.',
      );
    }
  }

  Future<AuthResult> signUp({
    required String identifier,
    required String password,
  }) async {
    final submittedIdentifier = identifier;
    final normalizedIdentifier = normalizeLoginIdentifier(identifier);
    if (normalizedIdentifier.isEmpty || password.length < 8) {
      throw const AuthFailure(
        'Use an email or phone number and a password with at least 8 characters.',
      );
    }
    if (!await _connectivityService.isOnline) {
      throw const AuthFailure(
        'An internet connection is required to create an account.',
      );
    }
    if (!_remoteApi.isConfigured) {
      throw const AuthFailure(
        'Supabase is not configured for this build. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY or SUPABASE_ANON_KEY.',
      );
    }

    try {
      final cloudUser = await _remoteApi.signUpWithCredentials(
        identifier: submittedIdentifier,
        fallbackIdentifier: normalizedIdentifier,
        password: password,
      );
      await _cacheUserCredentials(cloudUser, password);
      return AuthResult(user: cloudUser, mode: AuthMode.cloud);
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } on Object {
      throw const AuthFailure(
        'Could not reach HatchLog cloud for registration. Your device may be on a captive or blocked network.',
      );
    }
  }

  Future<AuthResult> authenticateMobileWithGoogle() async {
    if (!await _connectivityService.isOnline) {
      throw const AuthFailure(
        'An internet connection is required to sign in with Google.',
      );
    }
    if (!_remoteApi.isConfigured) {
      throw const AuthFailure(
        'Supabase is not configured for this build. Add SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY or SUPABASE_ANON_KEY.',
      );
    }

    await _ensureGoogleInitialized();
    if (!_googleSignIn.supportsAuthenticate()) {
      throw const AuthFailure(
        'Native Google account selection is not available on this platform.',
      );
    }

    try {
      final googleUser = await _googleSignIn.authenticate(
        scopeHint: _googleScopes,
      );
      final googleAuth = googleUser.authentication;
      final idToken = googleAuth.idToken;
      if (idToken == null || idToken.isEmpty) {
        throw const AuthFailure('Google did not return an ID token.');
      }

      var authorization = await googleUser.authorizationClient
          .authorizationForScopes(_googleScopes);
      authorization ??= await googleUser.authorizationClient.authorizeScopes(
        _googleScopes,
      );
      final accessToken = authorization.accessToken;
      if (accessToken.isEmpty) {
        throw const AuthFailure('Google did not return an access token.');
      }

      final socialResult = await _remoteApi.signInWithGoogleTokens(
        idToken: idToken,
        accessToken: accessToken,
        email: googleUser.email,
      );
      isNewMobileSocialRegistrant.value = false;
      await _persistSession(socialResult.user);
      await _initTrialForUser(socialResult.user);
      return AuthResult(user: socialResult.user, mode: AuthMode.cloud);
    } on AuthFailure {
      rethrow;
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } on Object {
      throw const AuthFailure('Google sign-in could not be completed.');
    }
  }

  Future<AppUser> completeMobileSocialPasscodeSetup({
    required AuthResult pendingResult,
    required String offlineKey,
  }) async {
    if (!pendingResult.requiresSocialRegistration) {
      throw const AuthFailure('No Google passcode setup is pending.');
    }
    if (offlineKey.length < 6) {
      throw const AuthFailure('Use at least 6 digits or characters.');
    }

    final cacheableUser = pendingResult.user.copyWith(
      authenticatedOffline: false,
      requiresInitialSetup: false,
    );
    await _cacheUserCredentials(cacheableUser, offlineKey);
    isNewMobileSocialRegistrant.value = false;
    return cacheableUser;
  }

  Future<AppUser> completeInitialSetup({
    required AuthResult pendingResult,
    required String newPassword,
    required String firstName,
    required String lastName,
  }) async {
    final trimmedFirstName = firstName.trim();
    final trimmedLastName = lastName.trim();

    if (!pendingResult.requiresInitialSetup) {
      throw const AuthFailure('This user is not waiting for initial setup.');
    }
    if (trimmedFirstName.isEmpty || trimmedLastName.isEmpty) {
      throw const AuthFailure('First name and last name are required.');
    }
    if (newPassword == defaultPassword || newPassword.length < 8) {
      throw const AuthFailure(
        'Choose a personal password with at least 8 characters.',
      );
    }
    if (!_remoteApi.isConfigured) {
      throw const AuthFailure(
        'Supabase is not configured for this build. Initial setup cannot be saved.',
      );
    }

    final updatedUser = await _remoteApi.completeInitialSetup(
      user: pendingResult.user,
      newPassword: newPassword,
      firstName: trimmedFirstName,
      lastName: trimmedLastName,
    );

    await _cacheUserCredentials(updatedUser, newPassword);
    return updatedUser;
  }

  Future<void> signOut() async {
    isNewMobileSocialRegistrant.value = false;
    await _localDatabase.clearOperationalFarmCache();
    await _localDatabase.clearFarmSyncCursors();
    await _localDatabase.clearSessionContext();
    if (await _connectivityService.isOnline) {
      await _remoteApi.signOut();
    }
  }

  static String normalizeLoginIdentifier(String value) {
    final trimmed = value.trim();
    if (trimmed.contains('@')) {
      return trimmed.toLowerCase();
    }
    return normalizePhoneNumber(trimmed);
  }

  static String normalizePhoneNumber(String value) {
    final digits = value.trim().replaceAll(RegExp(r'[^\d]'), '');
    if (digits.isEmpty) {
      return '';
    }

    var cleaned = digits;
    if (cleaned.startsWith('0')) {
      cleaned = '233${cleaned.substring(1)}';
    }
    if (cleaned.length >= 9) {
      cleaned = '+$cleaned';
    }
    return cleaned;
  }

  Future<AuthResult> _signInOffline({
    required String submittedIdentifier,
    required String normalizedIdentifier,
    required String password,
  }) async {
    CachedCredential? credential;
    for (final identifier in [
      submittedIdentifier.trim(),
      normalizedIdentifier,
    ]) {
      if (identifier.isEmpty) {
        continue;
      }
      credential = await _credentialStore.read(identifier);
      if (credential != null) {
        break;
      }
    }

    if (credential == null) {
      throw const AuthFailure(
        'No saved login found on this device. Connect to the internet and sign in once.',
      );
    }

    if (!await credential.matches(password)) {
      throw const AuthFailure('Incorrect password for the saved account.');
    }

    final localUser =
        await _localDatabase.readUserByIdentifier(submittedIdentifier) ??
        await _localDatabase.readUserByIdentifier(normalizedIdentifier) ??
        credential.user;

    final resolvedUser = await LocalEffectiveFarmRoleResolver(
      _localDatabase,
    ).applyToUser(
      localUser.copyWith(
        authenticatedOffline: true,
        requiresInitialSetup: false,
      ),
    );
    await _localDatabase.upsertUser(resolvedUser);
    await _localDatabase.writeSessionContext(
      userId: resolvedUser.id,
      farmId: resolvedUser.activeFarmId,
    );
    await _credentialStore.save(
      user: resolvedUser,
      password: password,
    );

    return AuthResult(user: resolvedUser, mode: AuthMode.offline);
  }

  Future<AuthResult> _signInForInitialSetup({
    required String authIdentifier,
    required String localIdentifier,
    required String password,
  }) async {
    if (!_remoteApi.isConfigured) {
      throw const AuthFailure(
        'Supabase is not configured for this build. The default password cannot be verified.',
      );
    }

    final AppUser cloudUser;
    try {
      cloudUser = await _remoteApi.signInWithCredentials(
        identifier: authIdentifier,
        fallbackIdentifier: localIdentifier,
        password: password,
      );
    } on AuthException catch (error) {
      throw AuthFailure(error.message);
    } on Object {
      throw const AuthFailure(
        'Could not reach HatchLog cloud for initial setup. Check your connection and try again.',
      );
    }

    return AuthResult(
      user: cloudUser.copyWith(requiresInitialSetup: true),
      mode: AuthMode.initialSetupRequired,
    );
  }

  Future<void> _cacheUserCredentials(AppUser user, String password) async {
    final cacheableUser = user.copyWith(
      authenticatedOffline: false,
      requiresInitialSetup: false,
    );
    await _persistSession(cacheableUser);
    await _credentialStore.save(user: cacheableUser, password: password);
    await _initTrialForUser(cacheableUser);
  }

  Future<void> _initTrialForUser(AppUser user) async {
    final userId = user.id.trim();
    final farmId = user.activeFarmId.trim();
    if (userId.isEmpty || farmId.isEmpty) {
      return;
    }

    final hardwareId = await getDeviceHardwareId();
    final error = await _licenseService.initTrialFromCloud(
      userId: userId,
      farmId: farmId,
      hardwareId: hardwareId,
    );
    if (error != null) {
      debugPrint('[License] Trial init warning: $error');
    }
  }

  Future<void> _ensureGoogleInitialized() async {
    if (_googleInitialized) {
      return;
    }
    final config = await GoogleAuthConfig.load();
    if (!config.isConfigured) {
      throw const AuthFailure(
        'GOOGLE_WEB_CLIENT_ID must be configured for native Google sign-in.',
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android &&
        config.androidClientId.isEmpty) {
      throw const AuthFailure(
        'GOOGLE_ANDROID_CLIENT_ID must be configured for native Android Google sign-in.',
      );
    }

    final platformClientId = switch (defaultTargetPlatform) {
      TargetPlatform.android => config.androidClientId,
      TargetPlatform.iOS => config.iosClientId,
      _ => '',
    };
    await _googleSignIn.initialize(
      clientId: platformClientId.isEmpty ? null : platformClientId,
      serverClientId: config.webClientId,
    );
    debugPrint(
      'INFO: Native Google Sign-In initialized with '
      '${GoogleAuthConfig.webClientIdKey} as serverClientId and '
      '${GoogleAuthConfig.androidClientIdKey} as Android clientId.',
    );
    _googleInitialized = true;
  }
}

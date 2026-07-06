import 'dart:async';

import 'package:flutter/material.dart';

import '../core/license/device_fingerprint.dart';
import '../core/license/license_service.dart';
import '../core/license/license_status.dart';
import '../core/license/license_upgrade_launcher.dart';
import '../core/models/app_user.dart';
import '../core/permissions/farm_permissions.dart';
import '../core/session_watcher.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/role_gateway/presentation/role_gateway.dart';
import '../presentation/license/lockout_screen.dart';
import 'app_services.dart';

class HatchLogApp extends StatefulWidget {
  const HatchLogApp({super.key, required this.services});

  final AppServices services;

  @override
  State<HatchLogApp> createState() => _HatchLogAppState();
}

class _HatchLogAppState extends State<HatchLogApp> {
  AppUser? _currentUser;
  FarmPermissions? _currentPermissions;
  LicenseStatus? _licenseStatus;
  SessionWatcher? _sessionWatcher;
  Timer? _subscriptionCheckTimer;
  final _scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  bool _isBootstrapping = true;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    _subscriptionCheckTimer?.cancel();
    _sessionWatcher?.dispose();
    widget.services.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    try {
      final status = await _refreshLicenseStatus(renewFromCloud: true);
      if (!mounted || _isBlockingLicenseStatus(status)) {
        return;
      }
      await _restoreActiveSession();
    } finally {
      if (mounted) {
        setState(() => _isBootstrapping = false);
      }
    }
  }

  Future<LicenseStatus> _refreshLicenseStatus({
    bool renewFromCloud = false,
  }) async {
    if (renewFromCloud) {
      await _renewLicenseFromCloudIfPossible();
    }

    LicenseStatus status;
    try {
      status = await widget.services.licenseService.checkLicense();
    } on Object {
      status = LicenseStatus.firstLaunch;
    }

    if (mounted) {
      setState(() => _licenseStatus = status);
    }
    return status;
  }

  Future<void> _renewLicenseFromCloudIfPossible() async {
    if (!await widget.services.connectivityService.isOnline) {
      return;
    }
    final config = await widget.services.licenseService.getConfig();
    final hardwareId = config?.hardwareId;
    if (hardwareId == null || hardwareId.isEmpty) {
      return;
    }
    await widget.services.licenseService.renewFromCloud(hardwareId);
  }

  bool _isBlockingLicenseStatus(LicenseStatus status) {
    return status == LicenseStatus.hardLocked ||
        status == LicenseStatus.clockTampered;
  }

  Future<void> _restoreActiveSession() async {
    final restoredUser = await widget.services.authRepository
        .restoreActiveSession();
    if (!mounted || restoredUser == null) {
      return;
    }
    await _activateUser(restoredUser);
  }

  Future<void> _activateUser(AppUser user) async {
    final licenseStatus = await _refreshLicenseStatus(renewFromCloud: true);
    if (!mounted || _isBlockingLicenseStatus(licenseStatus)) {
      _clearActiveUser();
      return;
    }

    final userId = user.id.trim();
    final farmId = user.activeFarmId.trim();
    final online = await widget.services.connectivityService.isOnline;

    if (userId.isNotEmpty && farmId.isNotEmpty) {
      await widget.services.localDatabase.prepareSessionForUser(
        userId: userId,
        farmId: farmId,
      );
      await widget.services.localDatabase.upsertUser(user);
      await widget.services.localDatabase.writeSessionContext(
        userId: userId,
        farmId: farmId,
      );
    }

    if (online && !user.authenticatedOffline && userId.isNotEmpty && farmId.isNotEmpty) {
      final hardwareId = await getDeviceHardwareId();
      final trialError = await widget.services.licenseService
          .initTrialFromCloud(
            userId: userId,
            farmId: farmId,
            hardwareId: hardwareId,
          );

      if (!mounted) {
        return;
      }

      if (trialError == LicenseService.trialExhaustedErrorCode) {
        final status = await widget.services.licenseService.checkLicense();
        if (mounted) {
          setState(() => _licenseStatus = status);
        }
        return;
      }
    }

    _sessionWatcher?.dispose();
    widget.services.syncRepository.setActiveUser(user);
    setState(() {
      _currentUser = user;
      _currentPermissions = null;
    });

    if (online && !user.authenticatedOffline) {
      await widget.services.syncRepository.syncWithCloud(user);
    }
    final permissions = await widget.services.permissionsRepository.loadForUser(
      user,
    );
    if (!mounted) {
      return;
    }
    widget.services.syncRunner.syncWhenOnline();
    setState(() => _currentPermissions = permissions);
    _sessionWatcher = SessionWatcher(
      authRepository: widget.services.authRepository,
      remoteApi: widget.services.remoteApi,
      localDatabase: widget.services.localDatabase,
      permissionsRepository: widget.services.permissionsRepository,
      currentUser: user,
      connectivityService: widget.services.connectivityService,
      onForcedSignOut: _handleForcedSignOut,
      onPermissionsChanged: (permissions) {
        if (!mounted) {
          return;
        }
        setState(() => _currentPermissions = permissions);
      },
    );
    _sessionWatcher?.start();
    _startSubscriptionWatcher();
  }

  void _handleForcedSignOut() {
    if (!mounted) {
      return;
    }
    _clearActiveUser();
  }

  Future<void> _signOut() async {
    await widget.services.authRepository.signOut();
    if (!mounted) {
      return;
    }
    _clearActiveUser();
  }

  void _clearActiveUser() {
    _subscriptionCheckTimer?.cancel();
    _subscriptionCheckTimer = null;
    _sessionWatcher?.dispose();
    _sessionWatcher = null;
    widget.services.syncRepository.setActiveUser(null);
    setState(() {
      _currentUser = null;
      _currentPermissions = null;
    });
  }

  void _startSubscriptionWatcher() {
    _subscriptionCheckTimer?.cancel();
    _subscriptionCheckTimer = Timer.periodic(const Duration(hours: 6), (_) {
      unawaited(_runSubscriptionCheck());
    });
  }

  Future<void> _runSubscriptionCheck() async {
    await _renewLicenseFromCloudIfPossible();
    final status = await _refreshLicenseStatus();
    if (!mounted) {
      return;
    }

    if (_isBlockingLicenseStatus(status)) {
      _clearActiveUser();
      return;
    }

    if (status == LicenseStatus.softLocked) {
      _scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text(
            'Subscription expiring soon. Upgrade to keep access.',
          ),
          backgroundColor: const Color(0xffef4444),
          action: SnackBarAction(
            label: 'Upgrade',
            textColor: Colors.white,
            onPressed: () {
              unawaited(openLicenseUpgrade());
            },
          ),
          duration: const Duration(seconds: 10),
        ),
      );
    }
  }

  Future<void> _handleLicenseUnlocked(LicenseStatus status) async {
    if (!mounted) {
      return;
    }
    setState(() => _licenseStatus = status);
    await _restoreActiveSession();
  }

  @override
  Widget build(BuildContext context) {
    final licenseStatus = _licenseStatus;
    return MaterialApp(
      scaffoldMessengerKey: _scaffoldMessengerKey,
      debugShowCheckedModeBanner: false,
      title: 'HatchLog Mobile',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff1f7a4d),
          primary: const Color(0xff1f7a4d),
          secondary: const Color(0xffd99025),
          surface: const Color(0xfff8faf7),
        ),
        scaffoldBackgroundColor: const Color(0xfff8faf7),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
        useMaterial3: true,
      ),
      home: _isBootstrapping || licenseStatus == null
          ? const _BootstrappingSessionScreen(
              message: 'Restoring your session...',
            )
          : licenseStatus == LicenseStatus.hardLocked
          ? LockoutScreen(
              reason: LockoutReason.trialExpired,
              licenseService: widget.services.licenseService,
              onUnlocked: (status) {
                unawaited(_handleLicenseUnlocked(status));
              },
            )
          : licenseStatus == LicenseStatus.clockTampered
          ? LockoutScreen(
              reason: LockoutReason.clockTampered,
              licenseService: widget.services.licenseService,
              onUnlocked: (status) {
                unawaited(_handleLicenseUnlocked(status));
              },
            )
          : _currentUser == null
          ? LoginScreen(
              authRepository: widget.services.authRepository,
              onAuthenticated: (user) {
                unawaited(_activateUser(user));
              },
            )
          : _currentPermissions == null
          ? const _BootstrappingSessionScreen(
              message: 'Loading your farm...',
            )
          : RoleGateway(
              currentUser: _currentUser!,
              permissions: _currentPermissions!,
              connectionChanges:
                  widget.services.connectivityService.onOnlineChanged,
              isOnline: () => widget.services.connectivityService.isOnline,
              inputSink: widget.services.syncRepository,
              managementRepository: widget.services.managementRepository,
              localDatabase: widget.services.localDatabase,
              showSoftLockBanner: licenseStatus == LicenseStatus.softLocked,
              onSignOut: _signOut,
              localSalesQueue: widget.services.localSalesQueue,
              pdfInvoiceService: widget.services.pdfInvoiceService,
              onRefreshFromCloud: () => widget.services.syncRepository
                  .syncWithCloud(_currentUser!, forceFullRefresh: true),
              remoteApi: widget.services.remoteApi,
            ),
    );
  }
}

class _BootstrappingSessionScreen extends StatelessWidget {
  const _BootstrappingSessionScreen({this.message = 'Loading HatchLog...'});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 34,
              child: CircularProgressIndicator(strokeWidth: 3),
            ),
            const SizedBox(height: 18),
            Text(
              message,
              style: const TextStyle(
                color: Color(0xff66736c),
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

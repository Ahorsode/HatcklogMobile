import 'package:flutter/material.dart';

import '../core/models/app_user.dart';
import '../features/auth/presentation/login_screen.dart';
import '../features/role_gateway/presentation/role_gateway.dart';
import 'app_services.dart';
import '../core/session_watcher.dart';

class HatchLogApp extends StatefulWidget {
  const HatchLogApp({super.key, required this.services});

  final AppServices services;

  @override
  State<HatchLogApp> createState() => _HatchLogAppState();
}

class _HatchLogAppState extends State<HatchLogApp> {
  AppUser? _currentUser;
  SessionWatcher? _sessionWatcher;

  @override
  void initState() {
    super.initState();
    _restoreActiveSession();
  }

  @override
  void dispose() {
    _sessionWatcher?.dispose();
    widget.services.dispose();
    super.dispose();
  }

  Future<void> _restoreActiveSession() async {
    final restoredUser = await widget.services.authRepository
        .restoreActiveSession();
    if (!mounted || restoredUser == null) {
      return;
    }
    _activateUser(restoredUser);
  }

  void _activateUser(AppUser user) {
    _sessionWatcher?.dispose();
    widget.services.syncRepository.setActiveUser(user);
    widget.services.syncRunner.syncWhenOnline();
    setState(() => _currentUser = user);
    _sessionWatcher = SessionWatcher(
      authRepository: widget.services.authRepository,
      remoteApi: widget.services.remoteApi,
      localDatabase: widget.services.localDatabase,
      currentUser: user,
      connectivityService: widget.services.connectivityService,
    );
    _sessionWatcher?.start();
  }

  Future<void> _signOut() async {
    await widget.services.authRepository.signOut();
    if (!mounted) {
      return;
    }
    _sessionWatcher?.dispose();
    _sessionWatcher = null;
    widget.services.syncRepository.setActiveUser(null);
    setState(() => _currentUser = null);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
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
      home: _currentUser == null
          ? LoginScreen(
              authRepository: widget.services.authRepository,
              onAuthenticated: _activateUser,
            )
          : RoleGateway(
              currentUser: _currentUser!,
              connectionChanges:
                  widget.services.connectivityService.onOnlineChanged,
              isOnline: () => widget.services.connectivityService.isOnline,
              inputSink: widget.services.syncRepository,
              managementRepository: widget.services.managementRepository,
              onSignOut: _signOut,
              localSalesQueue: widget.services.localSalesQueue,
              pdfInvoiceService: widget.services.pdfInvoiceService,
            ),
    );
  }
}

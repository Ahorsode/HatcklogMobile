import 'package:flutter/material.dart';

import '../../core/license/license_service.dart';
import '../../core/license/license_status.dart';
import '../../core/license/license_upgrade_launcher.dart';

enum LockoutReason { trialExpired, clockTampered }

class LockoutScreen extends StatefulWidget {
  const LockoutScreen({
    super.key,
    required this.reason,
    required this.licenseService,
    required this.onUnlocked,
  });

  final LockoutReason reason;
  final LicenseService licenseService;
  final ValueChanged<LicenseStatus> onUnlocked;

  @override
  State<LockoutScreen> createState() => _LockoutScreenState();
}

class _LockoutScreenState extends State<LockoutScreen> {
  bool _isChecking = false;

  bool get _isClockTampered => widget.reason == LockoutReason.clockTampered;

  Future<void> _openUpgrade() async {
    final opened = await openLicenseUpgrade();
    if (!mounted || opened) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Upgrade URL is not configured for this build.'),
      ),
    );
  }

  Future<void> _checkAgain() async {
    setState(() => _isChecking = true);
    try {
      final config = await widget.licenseService.getConfig();
      final hardwareId = config?.hardwareId;
      if (!_isClockTampered && hardwareId != null && hardwareId.isNotEmpty) {
        await widget.licenseService.renewFromCloud(hardwareId);
      }
      final status = await widget.licenseService.checkLicense();
      if (!mounted) {
        return;
      }
      if (_canUnlock(status)) {
        widget.onUnlocked(status);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _isClockTampered
                ? 'Clock anomaly is still detected.'
                : 'Subscription is still expired.',
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isChecking = false);
      }
    }
  }

  bool _canUnlock(LicenseStatus status) {
    if (_isClockTampered) {
      return status != LicenseStatus.clockTampered &&
          status != LicenseStatus.hardLocked;
    }
    return status == LicenseStatus.valid || status == LicenseStatus.softLocked;
  }

  @override
  Widget build(BuildContext context) {
    final color = _isClockTampered
        ? const Color(0xffb7791f)
        : const Color(0xffdc2626);
    final icon = _isClockTampered
        ? Icons.schedule_outlined
        : Icons.vpn_key_outlined;
    final heading = _isClockTampered
        ? 'System Clock Anomaly Detected'
        : 'Subscription Required';
    final body = _isClockTampered
        ? "Your device clock appears to have been set to a time in the past. This security measure prevents license tampering.\n\nPlease correct your device's date & time settings, then tap Retry below."
        : 'Your free trial or subscription has expired. Upgrade your plan to continue accessing your farm data.';

    return Scaffold(
      backgroundColor: const Color(0xfff8faf7),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CircleAvatar(
                    radius: 38,
                    backgroundColor: color.withValues(alpha: 0.12),
                    foregroundColor: color,
                    child: Icon(icon, size: 38),
                  ),
                  const SizedBox(height: 22),
                  Text(
                    heading,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: const Color(0xff172130),
                      fontWeight: FontWeight.w900,
                      letterSpacing: 0,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    body,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xff4b5563),
                      fontSize: 16,
                      height: 1.45,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 28),
                  if (!_isClockTampered) ...[
                    ElevatedButton.icon(
                      onPressed: _openUpgrade,
                      icon: const Icon(Icons.open_in_new),
                      label: const Text('Upgrade Now'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                        minimumSize: const Size.fromHeight(52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                  ],
                  OutlinedButton.icon(
                    onPressed: _isChecking ? null : _checkAgain,
                    icon: _isChecking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            _isClockTampered
                                ? Icons.refresh
                                : Icons.sync_outlined,
                          ),
                    label: Text(
                      _isClockTampered
                          ? 'Retry Clock Check'
                          : 'I Just Paid - Check Again',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: color,
                      side: BorderSide(color: color.withValues(alpha: 0.45)),
                      minimumSize: const Size.fromHeight(52),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  if (!_isClockTampered) ...[
                    const SizedBox(height: 18),
                    const Text(
                      'Pay on the web or contact your administrator for in-person payment assistance.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xff667085),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

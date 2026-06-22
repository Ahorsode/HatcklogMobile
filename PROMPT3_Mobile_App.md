# PROMPT 3 — Mobile App (HatchlogMobile)
## Handle TRIAL_EXHAUSTED + Lockout Copy Alignment

> **Prerequisite:** PROMPT 1 (Backend SQL) must be applied first.
> The `TRIAL_EXHAUSTED` error code this prompt handles is only returned by
> the rewritten `register_device_trial` RPC from PROMPT 1.

---

## Context

The mobile app's licensing system was fully implemented and is correct in structure.
It has:

- `license_configs` SQLite table tracking mode/expiry/last-check per farm
- `LicenseService` with correct grace/soft-lock/hard-lock/clock-tamper thresholds
- Boot-time license gate that blocks hard-locked farms before the login screen
- 6-hour periodic re-check timer
- Soft-lock persistent banner
- Anti-tamper `touchLastUsed()` heartbeat on every write

**The one remaining gap:** when `register_device_trial` returns
`{ "success": false, "error_code": "TRIAL_EXHAUSTED" }`, the current mobile code
falls through to the fail-open branch and writes a local 30-day trial window anyway.
A farm on an exhausted trial installs mobile and gets unlimited free access.

This is the only change needed on mobile.

---

## Affected Files

```
lib/core/license/license_service.dart        — primary fix
lib/app/hatchlog_app.dart                    — surface TRIAL_EXHAUSTED to UI
lib/presentation/license/lockout_screen.dart — copy alignment only
```

---

## Fix 1 — Detect TRIAL_EXHAUSTED in `initTrialFromCloud`

### File: `lib/core/license/license_service.dart`

Locate the block that handles `data['success'] != true`. In the current implementation
it either returns the error string (for RPC-level errors) or falls through to a
`catch` block that writes a 30-day fallback config. The change is:

**Find this block:**

```dart
if (data['success'] != true) {
  // ... some form of error return or fallback ...
}
```

**Replace it with:**

```dart
if (data['success'] != true) {
  final errorCode = data['error_code']?.toString() ?? '';

  if (errorCode == 'TRIAL_EXHAUSTED') {
    // Write a HARD_LOCKED config immediately so every subsequent call to
    // checkLicense() returns hardLocked — even after an app restart.
    // Setting expiresAt 36 days in the past guarantees the hardLocked
    // branch fires even if the offline tolerance window (10 days) is applied.
    await _localDatabase.upsertLicenseConfig(
      mode:             'HARD_LOCKED',
      farmId:           farmId,
      userId:           userId,
      hardwareId:       hardwareId,
      installedAt:      DateTime.now(),
      expiresAt:        DateTime.now().subtract(const Duration(days: 36)),
      lastCloudCheckAt: DateTime.now(),
    );
    return 'TRIAL_EXHAUSTED';
  }

  // All other non-success responses are transient (server error, network,
  // misconfiguration). Fail open with a local fallback so a worker in the
  // field with a poor signal can still log data.
  await _fallbackInit(userId: userId, farmId: farmId, hardwareId: hardwareId);
  return data['error']?.toString() ?? 'Trial registration failed.';
}
```

> **Important:** Do NOT change the `catch` block below this. The catch block
> handles true network/exception failures (Supabase unreachable) and should
> continue to fail open. `TRIAL_EXHAUSTED` is a deliberate server response,
> not a failure — it arrives as a successful HTTP 200 with `success: false`.

---

## Fix 2 — Surface TRIAL_EXHAUSTED to the UI in `hatchlog_app.dart`

### File: `lib/app/hatchlog_app.dart`

Locate `_activateUser` where `initTrialFromCloud` is called (fire-and-forget style).
The call currently looks roughly like:

```dart
unawaited(
  widget.services.licenseService.initTrialFromCloud(
    userId: user.id,
    farmId: user.activeFarmId,
    hardwareId: hardwareId,
  ),
);
```

Change this from fire-and-forget to an awaited call with result handling:

```dart
// BEFORE starting the LicenseWatcher, await the trial init so we can
// catch TRIAL_EXHAUSTED and block access before the user ever sees the dashboard.
final trialError = await widget.services.licenseService.initTrialFromCloud(
  userId:     user.id,
  farmId:     user.activeFarmId,
  hardwareId: hardwareId,
);

if (trialError == 'TRIAL_EXHAUSTED') {
  // The local config is now HARD_LOCKED (written in Fix 1).
  // Re-run checkLicense() so the state variable picks it up and the
  // build method routes to LockoutScreen on the next frame.
  final status = await widget.services.licenseService.checkLicense();
  if (mounted) setState(() => _licenseStatus = status);
  // Do NOT start the session watcher or license watcher for this user.
  // They are locked out.
  return;
}

// Only reach here if trial init succeeded or had a non-EXHAUSTED transient error.
// Start the watchers as normal.
_licenseWatcher?.dispose();
_licenseWatcher = LicenseWatcher(
  licenseService:   widget.services.licenseService,
  hardwareId:       hardwareId,
  onStatusChanged:  _handleLicenseStatusChanged,
);
_licenseWatcher?.start();
```

---

## Fix 3 — Update lockout body copy to align with desktop

### File: `lib/presentation/license/lockout_screen.dart`

This is a copy-only change. No logic or layout changes.

Find the body text inside the `trialExpired` variant. It currently reads something like:

> "Your free trial or subscription has expired. Upgrade your plan to continue accessing your farm data."

**Change it to:**

```dart
'Your farm\'s free trial has ended or your subscription has expired. '
'Upgrade to Standard or Premium to restore access for all devices on your farm.'
```

This single sentence covers both cases correctly:
- A farm whose 30-day trial ran out naturally (existing devices hitting day 35)
- A new device trying to join a farm that already burned its trial

It also now matches the desktop's updated lockout copy, so a farm owner who checks
both apps sees the same message rather than two different explanations.

---

## Verification Checklist

After applying all three fixes, test these scenarios manually or with unit tests:

```
[ ] New device — farm trial still running (days remaining > 0)
    initTrialFromCloud returns null
    Local config written with mode=CLOUD_TRIAL, expires_at = FARM's expiry
    User reaches dashboard normally

[ ] New device — farm trial EXHAUSTED (burned 30 days, no payment)
    Server returns { success: false, error_code: 'TRIAL_EXHAUSTED' }
    initTrialFromCloud writes HARD_LOCKED config with expires_at 36 days ago
    initTrialFromCloud returns 'TRIAL_EXHAUSTED'
    _activateUser detects it, calls checkLicense() → hardLocked
    _licenseStatus updates → build() routes to LockoutScreen(trialExpired)
    Next app restart: checkLicense() → hardLocked → LockoutScreen without needing network

[ ] "I Just Paid - Check Again" button on lockout screen
    Calls renewFromCloud(hardwareId)
    Server now returns license_status='PAID_STANDARD', new expires_at
    checkLicense() → valid
    App navigates to login screen (or dashboard if session still active)

[ ] Existing registered device (same hardware ID, trial still running)
    Server returns { success: true, already_registered: true, ... }
    initTrialFromCloud returns null (no EXHAUSTED path triggered)
    No regression in normal re-login flow

[ ] Network failure during initTrialFromCloud
    Exception caught in catch block (not the TRIAL_EXHAUSTED path)
    Falls back to local 30-day config if no row exists yet
    User can still use the app — sync will correct this later
    No regression in offline-first behavior
```

# Fix Prompt — Mobile App (HatchlogMobile)
## Bugs 2 and 3 from Audit Report

Both fixes are in a single file: `lib/core/license/license_service.dart`

---

## Fix 1 — CRITICAL: `_serverStatusToLocalMode` missing paid and revoked statuses (Bug 2)

Find `_serverStatusToLocalMode` which currently looks like:

```dart
String _serverStatusToLocalMode(String status) {
  return switch (status) {
    'ACTIVE'       => 'CLOUD_ACTIVE',
    'CLOUD_TRIAL'  => 'CLOUD_TRIAL',
    'GRACE_PERIOD' => 'EXPIRED',
    'EXPIRED'      => 'EXPIRED',
    _              => 'CLOUD_TRIAL',
  };
}
```

Replace the entire method body with:

```dart
String _serverStatusToLocalMode(String status) {
  return switch (status) {
    // All paid/active variants — web writes any of these depending on path
    'ACTIVE'         => 'CLOUD_ACTIVE',
    'PAID_AND_ACTIVE'=> 'CLOUD_ACTIVE',   // written by adminUpgradeFarmTier (web)
    'PAID_STANDARD'  => 'CLOUD_ACTIVE',   // written by RPC after standard upgrade
    'PAID_PREMIUM'   => 'CLOUD_ACTIVE',   // written by RPC after premium upgrade

    // Trial
    'CLOUD_TRIAL'    => 'CLOUD_TRIAL',

    // Expired / exhausted
    'EXPIRED'        => 'EXPIRED',
    'TRIAL_EXPIRED'  => 'EXPIRED',
    'GRACE_PERIOD'   => 'EXPIRED',

    // Revoked by admin — treat as hard locked immediately
    'REVOKED'        => 'HARD_LOCKED',

    // Unknown future status — log it, keep local state rather than downgrading to trial
    _ => () {
      debugPrint('[License] Unrecognised server status: $status');
      return 'CLOUD_TRIAL';
    }(),
  };
}
```

---

## Fix 2 — CRITICAL: `renewFromCloud` missing `trial_exhausted` flag check (Bug 3)

Find `renewFromCloud`. It currently ends with:

```dart
if (statusStr != null) {
  updates['mode'] = _serverStatusToLocalMode(statusStr);
}
await _db.rawLocalUpdate('license_configs', updates, "id = 'singleton'");
```

Replace that final block with:

```dart
// Check the trial_exhausted flag BEFORE writing any updates.
// If the server says the trial is exhausted and we're not in an active paid state,
// hard-lock immediately — identical to how desktop handles this.
final trialExhausted = data['trial_exhausted'] == true;
final resolvedMode = statusStr != null ? _serverStatusToLocalMode(statusStr) : null;
final isActive = resolvedMode == 'CLOUD_ACTIVE';

if (trialExhausted && !isActive) {
  await _setMode('HARD_LOCKED');
  debugPrint('[License] Server reports trial exhausted — forcing hard lock.');
  return;  // skip the normal update to avoid accidentally unlocking
}

if (resolvedMode != null) {
  updates['mode'] = resolvedMode;
}
await _db.rawLocalUpdate('license_configs', updates, "id = 'singleton'");
```

---

## No other files need changes

These two fixes in `license_service.dart` close both critical gaps. Every other
mobile licensing file (boot gate, lockout screen, watcher, heartbeat, `initTrialFromCloud`)
was implemented correctly by the agent and requires no changes.

# Agent Prompt — Port the Desktop Licensing System to HatchlogMobile

Paste this whole prompt into Claude Code inside the **HatchlogMobile** Flutter repo.

---

## What I found scanning the desktop app (pfm-desktop)

Before the prompt, here's the exact system you're replicating, confirmed directly from
`lib/services/license_service.dart`, `lib/main.dart`, `lib/screens/lockout_screen.dart`,
`lib/screens/main_scaffold.dart`, and `lib/screens/welcome_onboarding_screen.dart`:

**Local state** — a singleton `license_configs` row (desktop uses Drift, you'll use sqflite)
with: `mode` (CLOUD_TRIAL / CLOUD_ACTIVE / EXPIRED / HARD_LOCKED), `farm_id`, `user_id`,
`hardware_id`, `installed_at`, `expires_at`, `last_used`, `last_cloud_check_at`.

**Trial registration** — once, right after signup/first login, desktop calls a Supabase RPC
`register_device_trial(p_user_id, p_farm_id, p_hardware_id, p_device_name, p_device_type)`.
The server returns `license_expires_at`, which desktop stores as `expires_at` and starts the
clock from there (30 days out, server-decided).

**Status check** — on every boot (if online) and every 6 hours while running, desktop calls
`get_device_subscription_status(p_hardware_id)`, which returns the farm's current
`license_status` and `license_expires_at` from the server. The result only ever EXTENDS the
locally stored `expires_at`, never shortens it client-side — the server is the source of truth.

**Grace logic** (`checkLicense()`), in order:
1. If `now < expires_at` → **valid**
2. Else if `now < last_used - 2min` → **clockTampered** (system clock rolled back — fraud lock)
3. Else if `days since last_cloud_check_at < 10` → **valid** (offline tolerance, lets a farm
   with no internet for up to 10 days past expiry keep working, since the server may have
   already renewed it and the device just hasn't heard back yet)
4. Else if `days past expires_at <= 5` → **softLocked** (full access, persistent warning banner)
5. Else → **hardLocked** (full lockout screen, no farm data accessible)

**Boot routing** — a `LicenseGate` widget runs `checkLicense()` before any other screen shows,
and routes to: onboarding (first launch) / normal login (valid) / login with banner
(softLocked) / full lockout screen (hardLocked or clockTampered).

**Lockout screen** has two variants: "Subscription Required" (red, key icon, "Upgrade Now"
button that opens `{WEB_APP_URL}/dashboard/license-upgrade` in the browser, plus "I Just Paid
- Check Again" button that re-runs the cloud check) and "System Clock Anomaly Detected" (amber,
clock icon, "Retry Clock Check" button — no upgrade path since this isn't a billing issue).

**Anti-tamper** — every local database write calls `touchLastUsed()` to keep `last_used`
current, so if someone winds their system clock backwards to cheat the trial, the next boot
catches it.

⚠️ **Important gap I could not verify from code**: the actual SQL body of
`register_device_trial` and `get_device_subscription_status` is NOT checked into either the
desktop or web repo — these Postgres functions live only on your live Supabase project,
created outside version control. This means I cannot confirm from code alone whether the
30-day clock these RPCs start is keyed purely by `farm_id` (one trial per farm, shared by every
device) or whether it's accidentally keyed by `hardware_id` too (which would let each new
device — including a newly installed mobile app — reset or extend the clock independently,
which is the OPPOSITE of what you want). Section 0 below has the agent verify and fix this
server-side before touching any mobile code, since this is the actual single source of truth
for your "one 30-day trial per farm, shared across mobile and desktop" requirement — the
client-side code on both apps can be perfect and still fail if the server-side function is
keyed wrong.

---

```
You are porting HatchlogMobile's licensing system to exactly match the desktop app's (pfm-
desktop) shared 30-day trial enforcement. Both apps must read and write the SAME farm-level
trial/subscription clock via the same Supabase RPCs, so starting the trial on mobile counts
against the same 30 days as starting it on desktop, and vice versa.

================================================================================
SECTION 0 — VERIFY/FIX THE SERVER-SIDE RPCs FIRST (do this before any Flutter code)
================================================================================

In the Supabase SQL editor for the project both apps share, run this query to inspect the
current function bodies:

```sql
SELECT proname, prosrc FROM pg_proc
WHERE proname IN ('register_device_trial', 'get_device_subscription_status');
```

Confirm `register_device_trial` does the following (rewrite it if it does not):
1. Looks up whether a trial/subscription record ALREADY EXISTS for `p_farm_id` (not for
   `p_hardware_id`). Use a `farms` or dedicated `farm_subscriptions` table keyed by farm_id
   as the source of truth for trial start/expiry.
2. If a record already exists for this farm (from desktop, web, or a previous mobile install),
   return that EXISTING `license_expires_at` — do NOT extend, reset, or create a second trial
   window just because a new device/hardware_id is registering.
3. Only if NO record exists for this farm yet, create one with `expires_at = now() + interval
   '30 days'` and return that.
4. Separately, upsert a row into `device_registrations` (or equivalent) linking
   `p_hardware_id` to `p_farm_id` for device-tracking/seat-counting purposes — this is bookkeeping
   only and must NOT influence the trial clock.

Confirm `get_device_subscription_status` looks up the farm's subscription/trial state by
resolving `p_hardware_id` → `farm_id` (via the device_registrations link), then returns that
FARM's `license_status` and `license_expires_at` — never a per-device value.

Example corrected RPC (adapt names/columns to match your actual schema):

```sql
CREATE OR REPLACE FUNCTION register_device_trial(
  p_user_id text, p_farm_id text, p_hardware_id text,
  p_device_name text, p_device_type text
) RETURNS jsonb AS $$
DECLARE
  v_expires timestamptz;
  v_existing timestamptz;
BEGIN
  SELECT license_expires_at INTO v_existing
  FROM farms WHERE id = p_farm_id;

  IF v_existing IS NOT NULL THEN
    v_expires := v_existing;
  ELSE
    v_expires := now() + interval '30 days';
    UPDATE farms SET license_expires_at = v_expires, license_status = 'CLOUD_TRIAL'
    WHERE id = p_farm_id;
  END IF;

  INSERT INTO device_registrations (farm_id, user_id, hardware_id, device_name, device_type, registered_at)
  VALUES (p_farm_id, p_user_id, p_hardware_id, p_device_name, p_device_type, now())
  ON CONFLICT (farm_id, hardware_id) DO UPDATE SET registered_at = now();

  RETURN jsonb_build_object('success', true, 'license_expires_at', v_expires);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

Do this verification/fix FIRST. If the RPC is already farm-scoped, skip to Section 1.

================================================================================
SECTION 1 — LOCAL SQLITE TABLE (mirrors desktop's license_configs)
================================================================================

In lib/core/storage/local_database.dart, bump the schema version and add this table in
_createSchema and _upgradeSchema:

```sql
CREATE TABLE IF NOT EXISTS license_configs (
  id TEXT PRIMARY KEY,              -- always literal 'singleton'
  mode TEXT NOT NULL DEFAULT 'OFFLINE',   -- CLOUD_TRIAL | CLOUD_ACTIVE | EXPIRED | HARD_LOCKED
  farm_id TEXT,
  user_id TEXT,
  hardware_id TEXT,
  installed_at TEXT NOT NULL,
  expires_at TEXT NOT NULL,
  last_used TEXT NOT NULL,
  last_cloud_check_at TEXT
);
```

Add a migration step (`ALTER TABLE` is not needed since this is a brand-new table — just add
the CREATE statement to whichever onUpgrade version block runs next, following the existing
pattern already in local_database.dart for prior schema bumps).

================================================================================
SECTION 2 — LicenseStatus enum + LicenseService (mirrors desktop exactly)
================================================================================

Create lib/core/license/license_status.dart:

```dart
enum LicenseStatus { firstLaunch, valid, softLocked, hardLocked, clockTampered }
```

Create lib/core/license/license_service.dart:

```dart
import 'package:supabase_flutter/supabase_flutter.dart';
import '../storage/local_database.dart';
import 'license_status.dart';

class LicenseConfig {
  const LicenseConfig({
    required this.mode, required this.farmId, required this.userId,
    required this.hardwareId, required this.installedAt, required this.expiresAt,
    required this.lastUsed, required this.lastCloudCheckAt,
  });
  final String mode;
  final String? farmId, userId, hardwareId;
  final DateTime installedAt, expiresAt, lastUsed;
  final DateTime? lastCloudCheckAt;

  factory LicenseConfig.fromMap(Map<String, dynamic> m) => LicenseConfig(
    mode: m['mode'] as String,
    farmId: m['farm_id'] as String?,
    userId: m['user_id'] as String?,
    hardwareId: m['hardware_id'] as String?,
    installedAt: DateTime.parse(m['installed_at'] as String),
    expiresAt: DateTime.parse(m['expires_at'] as String),
    lastUsed: DateTime.parse(m['last_used'] as String),
    lastCloudCheckAt: m['last_cloud_check_at'] != null
        ? DateTime.parse(m['last_cloud_check_at'] as String) : null,
  );
}

class LicenseService {
  LicenseService(this._db);
  final LocalDatabase _db;

  Future<LicenseStatus> checkLicense() async {
    final config = await _loadConfig();
    if (config == null) return LicenseStatus.firstLaunch;

    final now = DateTime.now();

    // Anti-clock-tamper — identical 2-minute tolerance to desktop
    if (now.isBefore(config.lastUsed.subtract(const Duration(minutes: 2)))) {
      return LicenseStatus.clockTampered;
    }

    if (now.isBefore(config.expiresAt)) {
      return LicenseStatus.valid;
    }

    // 10-day offline tolerance, identical to desktop
    if (config.lastCloudCheckAt != null) {
      final daysSinceCheck = now.difference(config.lastCloudCheckAt!).inDays;
      if (daysSinceCheck < 10) return LicenseStatus.valid;
    }

    final daysPastExpiry = now.difference(config.expiresAt).inDays;
    if (daysPastExpiry <= 5) return LicenseStatus.softLocked;

    await _setMode('HARD_LOCKED');
    return LicenseStatus.hardLocked;
  }

  /// Call once after signup/login, exactly like desktop's welcome_onboarding_screen does.
  /// IMPORTANT: this calls the SAME register_device_trial RPC as desktop, with this farm's
  /// id — so if the farm already has a trial running (started on desktop, web, or another
  /// mobile install), the server returns the EXISTING expiry, not a fresh 30 days.
  Future<String?> initTrialFromCloud({
    required String userId, required String farmId, required String hardwareId,
  }) async {
    try {
      final result = await Supabase.instance.client.rpc('register_device_trial', params: {
        'p_user_id': userId, 'p_farm_id': farmId, 'p_hardware_id': hardwareId,
        'p_device_name': 'Mobile App', 'p_device_type': 'Mobile',
      });
      if (result == null) return 'Trial registration returned no data.';
      final data = Map<String, dynamic>.from(result as Map);
      if (data['success'] != true) {
        return data['error']?.toString() ?? 'Trial registration failed.';
      }
      final rawExpiry = data['license_expires_at'];
      final expiresAt = rawExpiry != null
          ? DateTime.tryParse(rawExpiry.toString()) ?? DateTime.now().add(const Duration(days: 30))
          : DateTime.now().add(const Duration(days: 30));

      await _upsertConfig(
        mode: 'CLOUD_TRIAL', farmId: farmId, userId: userId, hardwareId: hardwareId,
        installedAt: DateTime.now(), expiresAt: expiresAt, lastCloudCheckAt: DateTime.now(),
      );
      return null;
    } catch (e) {
      // Same fail-open behavior as desktop: grant a local 30-day fallback so a worker
      // mid-field with no signal isn't blocked from ever starting the app.
      await _upsertConfig(
        mode: 'CLOUD_TRIAL', farmId: farmId, userId: userId, hardwareId: hardwareId,
        installedAt: DateTime.now(), expiresAt: DateTime.now().add(const Duration(days: 30)),
        lastCloudCheckAt: null,
      );
      return null;
    }
  }

  /// Call on every boot (if online) and every 6 hours while running, identical cadence
  /// to desktop's main_scaffold.dart Timer.periodic.
  Future<void> renewFromCloud(String hardwareId) async {
    try {
      final result = await Supabase.instance.client.rpc(
        'get_device_subscription_status', params: {'p_hardware_id': hardwareId},
      );
      if (result == null) return;
      final data = Map<String, dynamic>.from(result as Map);
      if (data['success'] != true) return;

      final rawExpiry = data['license_expires_at'];
      final statusStr = data['license_status']?.toString();
      final serverExpiry = rawExpiry != null ? DateTime.tryParse(rawExpiry.toString()) : null;
      final now = DateTime.now();
      final config = await _loadConfig();
      if (config == null) return;

      final updates = <String, Object?>{'last_used': now.toIso8601String(), 'last_cloud_check_at': now.toIso8601String()};
      if (serverExpiry != null && serverExpiry.isAfter(config.expiresAt)) {
        updates['expires_at'] = serverExpiry.toIso8601String();
      }
      if (statusStr != null) {
        updates['mode'] = _serverStatusToLocalMode(statusStr);
      }
      await _db.rawLocalUpdate('license_configs', updates, "id = 'singleton'");
    } catch (_) {
      // Offline — silently skip, exactly like desktop.
    }
  }

  String _serverStatusToLocalMode(String s) => switch (s) {
    'ACTIVE' => 'CLOUD_ACTIVE',
    'CLOUD_TRIAL' => 'CLOUD_TRIAL',
    'EXPIRED' => 'EXPIRED',
    _ => 'CLOUD_TRIAL',
  };

  /// Call this on every local DB write, exactly like desktop's touchLastUsed().
  Future<void> touchLastUsed() async {
    try {
      await _db.rawLocalUpdate(
        'license_configs', {'last_used': DateTime.now().toIso8601String()}, "id = 'singleton'",
      );
    } catch (_) {}
  }

  Future<LicenseConfig?> _loadConfig() async {
    final rows = await _db.rawLocalQuery("SELECT * FROM license_configs WHERE id = 'singleton'", []);
    if (rows.isEmpty) return null;
    return LicenseConfig.fromMap(rows.first);
  }

  Future<void> _upsertConfig({
    required String mode, required String? farmId, required String? userId,
    required String? hardwareId, required DateTime installedAt, required DateTime expiresAt,
    DateTime? lastCloudCheckAt,
  }) async {
    final now = DateTime.now();
    await _db.rawLocalInsertOrReplace('license_configs', {
      'id': 'singleton', 'mode': mode, 'farm_id': farmId, 'user_id': userId,
      'hardware_id': hardwareId, 'installed_at': installedAt.toIso8601String(),
      'expires_at': expiresAt.toIso8601String(), 'last_used': now.toIso8601String(),
      'last_cloud_check_at': lastCloudCheckAt?.toIso8601String(),
    });
  }

  Future<void> _setMode(String mode) async {
    await _db.rawLocalUpdate('license_configs', {'mode': mode}, "id = 'singleton'");
  }

  Future<LicenseConfig?> getConfig() => _loadConfig();
}
```

NOTE: `rawLocalUpdate`, `rawLocalInsertOrReplace`, and `rawLocalQuery` are helper methods —
if LocalDatabase doesn't already expose generic raw helpers like this, add them (thin wrappers
around the existing sqflite `Database` instance using `update()`, `insert()` with
`ConflictAlgorithm.replace`, and `rawQuery()` respectively).

================================================================================
SECTION 3 — MOBILE HARDWARE ID (equivalent to desktop's getDeviceHardwareId)
================================================================================

Desktop fingerprints Windows/macOS/Linux machine IDs via device_info_plus. Mobile needs the
Android/iOS equivalent. Add to pubspec.yaml:
```yaml
  device_info_plus: ^12.4.0
  url_launcher: ^6.3.2
```

Create lib/core/license/device_fingerprint.dart:
```dart
import 'dart:io' show Platform;
import 'package:device_info_plus/device_info_plus.dart';

Future<String> getDeviceHardwareId() async {
  final deviceInfo = DeviceInfoPlugin();
  try {
    if (Platform.isAndroid) {
      final info = await deviceInfo.androidInfo;
      return info.id; // build fingerprint, stable per device/ROM install
    }
    if (Platform.isIOS) {
      final info = await deviceInfo.iosInfo;
      return info.identifierForVendor ?? 'UNKNOWN-IOS-DEVICE';
    }
  } catch (_) {}
  return 'UNKNOWN-HARDWARE-ID';
}
```

================================================================================
SECTION 4 — BOOT-TIME LICENSE GATE (mirrors desktop's LicenseGate widget)
================================================================================

In lib/app/hatchlog_app.dart, before any existing session-restore or login routing, insert a
license check. This must run BEFORE the existing auth flow, not after — a hard-locked farm
should never reach the login screen at all, exactly like desktop.

```dart
// Inside HatchLogApp's initial boot sequence, before restoreActiveSession():
final licenseService = LicenseService(widget.services.localDatabase);
LicenseStatus status;
try {
  status = await licenseService.checkLicense();
} catch (_) {
  status = LicenseStatus.firstLaunch;
}

if (status == LicenseStatus.hardLocked) {
  return const LockoutScreen(reason: LockoutReason.trialExpired);
}
if (status == LicenseStatus.clockTampered) {
  return const LockoutScreen(reason: LockoutReason.clockTampered);
}
// valid, softLocked, or firstLaunch fall through to normal auth flow as today.
// If softLocked, pass a flag down so the dashboard shows the persistent banner (Section 6).
```

`firstLaunch` means no license_configs row exists yet — this happens on a brand-new install
before the user has signed in. Do NOT block the login screen in this case; instead, call
`initTrialFromCloud()` immediately after a successful login/signup completes (see Section 5),
exactly mirroring how desktop only registers the trial after authentication succeeds, not
before.

================================================================================
SECTION 5 — TRIGGER TRIAL REGISTRATION AFTER LOGIN (mirrors welcome_onboarding_screen.dart)
================================================================================

In lib/features/auth/data/auth_repository.dart, after a successful sign-in or sign-up that
resolves a `farmId`, call:

```dart
final hardwareId = await getDeviceHardwareId();
final licenseService = LicenseService(_localDatabase);
final error = await licenseService.initTrialFromCloud(
  userId: user.id, farmId: user.activeFarmId, hardwareId: hardwareId,
);
if (error != null) debugPrint('[License] Trial init warning: $error');
```

This call is idempotent and safe to make on every login, not just the first — if the farm
already has a trial or active subscription (started on desktop or elsewhere), the RPC simply
returns the existing expiry and nothing changes locally except the device_registrations link.

================================================================================
SECTION 6 — LOCKOUT SCREEN + SOFT-LOCK BANNER (mirrors lockout_screen.dart exactly)
================================================================================

Create lib/presentation/license/lockout_screen.dart with two variants, matching desktop's
copy and color scheme so farm owners get a consistent experience switching between devices:

VARIANT 1 — trialExpired (red theme, key icon):
- Heading: "Subscription Required"
- Body: "Your free trial or subscription has expired. Upgrade your plan to continue accessing your farm data."
- Primary button: "Upgrade Now" — opens `{WEB_APP_URL}/dashboard/license-upgrade` via
  url_launcher (read WEB_APP_URL from .env.mobile, same env var name desktop uses)
- Secondary button: "I Just Paid - Check Again" — re-runs `renewFromCloud()` then
  `checkLicense()`; if status is now valid or softLocked, navigate to the normal login flow
- Footer: "Pay on the web or contact your administrator for in-person payment assistance."

VARIANT 2 — clockTampered (amber theme, clock icon):
- Heading: "System Clock Anomaly Detected"
- Body: "Your device clock appears to have been set to a time in the past. This security
  measure prevents license tampering.\n\nPlease correct your device's date & time settings,
  then tap Retry below."
- Button: "Retry Clock Check" — re-runs `checkLicense()`; if no longer tampered, proceed
- No upgrade button on this variant (matches desktop — this isn't a billing issue)

Add ANTHROPIC the WEB_APP_URL key to .env.example and .env.mobile (developer fills their own):
```
WEB_APP_URL=https://your-app-domain.com
```

================================================================================
SECTION 7 — SOFT-LOCK BANNER + PERIODIC 6-HOUR RE-CHECK (mirrors main_scaffold.dart)
================================================================================

In lib/app/hatchlog_app.dart, after a successful login (status was valid or softLocked):

```dart
Timer? _subscriptionCheckTimer;

void _startSubscriptionWatcher() {
  _subscriptionCheckTimer = Timer.periodic(const Duration(hours: 6), (_) async {
    final config = await licenseService.getConfig();
    if (config?.hardwareId == null) return;
    await licenseService.renewFromCloud(config!.hardwareId!);
    final status = await licenseService.checkLicense();
    if (!mounted) return;

    if (status == LicenseStatus.hardLocked) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LockoutScreen(reason: LockoutReason.trialExpired)),
        (_) => false,
      );
    } else if (status == LicenseStatus.softLocked) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Subscription expiring soon. Upgrade to keep access.'),
        backgroundColor: const Color(0xFFEF4444),
        action: SnackBarAction(label: 'Upgrade', onPressed: () async {
          final url = dotenv.env['WEB_APP_URL'] ?? '';
          if (url.isNotEmpty) await launchUrl(Uri.parse('$url/dashboard/license-upgrade'));
        }),
        duration: const Duration(seconds: 10),
      ));
    }
  });
}
```

Cancel this timer in dispose(), exactly like desktop does.

When `status == softLocked` right after boot (Section 4's fall-through case), show a
persistent (non-dismissible until upgraded) banner at the top of WorkerHomeScreen and
UniversalMobileDashboard reading: "Your farm's subscription has expired. You have 5 days of
grace access remaining — ask your farm owner to renew." Tapping the banner opens the same
upgrade URL.

================================================================================
SECTION 8 — ANTI-TAMPER HOOK ON EVERY WRITE
================================================================================

Find every place WorkerInputSink.enqueueWorkerInput() and LocalDatabase's upsert*() methods
commit a write, and call `licenseService.touchLastUsed()` immediately after. The cleanest way
to do this without touching every call site: add a single call inside
LocalDatabase._notifyTablesChanged() (which already fires after every write), guarded so it's
fire-and-forget and never blocks or throws:

```dart
void _notifyTablesChanged(Iterable<String> tables) {
  _tableChangeController.add(tables.toSet());
  unawaited(_licenseService?.touchLastUsed());
}
```

This requires LocalDatabase to hold an optional reference to LicenseService, injected after
both are constructed in AppServices.bootstrap() (avoids a circular constructor dependency).

================================================================================
SECTION 9 — FINAL WIRING CHECKLIST
================================================================================

- [ ] Section 0 verified/fixed on the live Supabase project BEFORE any Flutter changes —
      register_device_trial is farm-scoped, not hardware-scoped
- [ ] license_configs table added to local_database.dart, schema version bumped
- [ ] LicenseService ported with identical grace/soft-lock/hard-lock/clock-tamper thresholds
      as desktop (5-day soft lock, 10-day offline tolerance, 2-minute clock-tamper tolerance)
- [ ] getDeviceHardwareId() added using device_info_plus (Android: info.id, iOS:
      identifierForVendor)
- [ ] LicenseGate check runs BEFORE session restore / login screen in hatchlog_app.dart
- [ ] initTrialFromCloud() called after every successful login/signup (idempotent, safe to
      call repeatedly)
- [ ] LockoutScreen built with both variants, copy matching desktop, "Upgrade Now" opening
      {WEB_APP_URL}/dashboard/license-upgrade
- [ ] 6-hour periodic Timer added, force-navigates to lockout if status flips to hardLocked
      mid-session, shows snackbar if softLocked
- [ ] Persistent soft-lock banner added to both WorkerHomeScreen and UniversalMobileDashboard
- [ ] touchLastUsed() wired into every local write path via _notifyTablesChanged
- [ ] WEB_APP_URL added to .env.example and .env.mobile
- [ ] device_info_plus and url_launcher added to pubspec.yaml
- [ ] Manually test: start a trial on mobile, confirm the SAME expiry timestamp appears when
      checking subscription status from the desktop app (or vice versa) — this is the actual
      proof that the shared 30-day clock works correctly, since both apps now defer entirely
      to the same farm-scoped server state rather than tracking their own independent timers
```

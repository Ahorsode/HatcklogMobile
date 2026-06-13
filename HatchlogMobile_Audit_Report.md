# HatchlogMobile — Full Code Audit Report
**Repository:** https://github.com/Ahorsode/HatcklogMobile.git  
**Date:** June 2026  
**Auditor:** Claude Sonnet 4.6  
**Stack:** Flutter / Dart · Supabase · SQLite (sqflite) · Google Sign-In

---

## Executive Summary

7 bugs were found across 3 severity levels. One is a **critical security vulnerability** (real API credentials committed to the repo). Two are **high-severity logic bugs** (silent session logout that doesn't update UI, and service dependencies silently dropped by RoleGateway). Four are **medium/low bugs** including a non-persistent device ID, a crash-on-startup path, a division-by-zero risk, and a false-positive environment log condition.

---

## Bug Index

| # | Severity | File | Description |
|---|----------|------|-------------|
| 1 | 🔴 CRITICAL | `.env.mobile` | Real API credentials committed to repo |
| 2 | 🔴 HIGH | `session_watcher.dart` | Auto-signout doesn't notify parent — UI stuck in logged-in state |
| 3 | 🟠 HIGH | `role_gateway.dart` | Services (inputSink, managementRepository, etc.) silently dropped |
| 4 | 🟡 MEDIUM | `app_services.dart` | Device ID regenerated every boot — breaks transaction deduplication |
| 5 | 🟡 MEDIUM | `supabase_config.dart` | Throws Exception instead of returning unconfigured state |
| 6 | 🟡 MEDIUM | `local_sales_queue.dart` | Division-by-zero risk when `quantityCrates == 0` |
| 7 | 🟡 LOW | `supabase_remote_api.dart` | `_hasEnvironmentState` returns true for houses with 0°C / 0% humidity |

---

## Bug #1 — CRITICAL: Real API Credentials Committed to Repository

**File:** `.env.mobile`  
**Lines:** 1–5

### What's Wrong
The `.env.mobile` file contains live production credentials and is **tracked by Git**. The `.gitignore` file has the pattern `.env.*` but explicitly re-includes `.env.mobile` via `!.env.mobile`, meaning this file is committed on every push. Anyone with access to the repository can read the Supabase URL, publishable key, anon key, Google Web OAuth client ID, and Google Android OAuth client ID.

```
SUPABASE_URL=https://ufawukwbfnhvjwvmqeuo.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_g6ON3VqsL7LBHlOyC2q1ig_42bP64_u
SUPABASE_ANON_KEY=sb_publishable_g6ON3VqsL7LBHlOyC2q1ig_42bP64_u
GOOGLE_WEB_CLIENT_ID=1090499090810-uvt46f0jd23mcvjl0geved52dkss7u3v.apps.googleusercontent.com
GOOGLE_ANDROID_CLIENT_ID=1090499090810-mpi3oh1hsgmh32r00h8jfvtfo2o3v9tq.apps.googleusercontent.com
```

### Impact
Supabase publishable/anon keys are designed to be public-ish, but Supabase URL combined with the key gives anyone the ability to query your database subject only to your Row Level Security policies. If RLS is misconfigured on any table, data is exposed. Google OAuth client IDs allow an attacker to build a spoofed OAuth flow against your app.

### Agent Prompt

```
You are fixing a critical security issue in the HatchlogMobile Flutter project.

PROBLEM: The file `.env.mobile` contains real API credentials and is committed to the Git repository. The `.gitignore` has `.env.*` but re-includes `.env.mobile` with `!.env.mobile`, so secrets are tracked.

WHAT TO DO:

1. Immediately rotate the exposed credentials:
   - In Supabase Dashboard: generate a new anon key and update SUPABASE_ANON_KEY / SUPABASE_PUBLISHABLE_KEY
   - In Google Cloud Console: revoke and regenerate the OAuth Web client ID (1090499090810-...) and Android client ID

2. Create a `.env.example` file at the project root with placeholder values and NO real secrets:
   ```
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_PUBLISHABLE_KEY=your_supabase_publishable_key
   SUPABASE_ANON_KEY=your_supabase_anon_key
   GOOGLE_WEB_CLIENT_ID=your_web_client_id.apps.googleusercontent.com
   GOOGLE_ANDROID_CLIENT_ID=your_android_client_id.apps.googleusercontent.com
   ```

3. Change `.gitignore` so `.env.mobile` is EXCLUDED:
   - Remove the line `!.env.mobile` from `.gitignore`
   - The existing `.env.*` pattern will then correctly ignore `.env.mobile`
   - Keep `!.env.example` to track the example file

4. Remove `.env.mobile` from git history:
   Run these commands from the repo root:
   ```bash
   git rm --cached .env.mobile
   git commit -m "security: remove .env.mobile from tracking — rotate credentials"
   git push
   ```
   Optionally use `git filter-repo` or BFG Repo Cleaner to scrub it from full history if the repo is public.

5. Update the README to instruct developers to copy `.env.example` → `.env.mobile` and fill in their own values.

6. In `pubspec.yaml`, the asset is already declared:
   ```yaml
   assets:
     - .env.mobile
   ```
   This is fine for bundling at build time, but the source file must NOT contain real values in version control. Developers fill it locally; CI/CD injects it from secrets at build time.

Do NOT change any Dart code — this is a repository/secrets management fix only.
```

---

## Bug #2 — HIGH: Auto-Signout in `SessionWatcher` Doesn't Update the UI

**File:** `lib/core/session_watcher.dart`  
**Lines:** 44–55  
**Related File:** `lib/app/hatchlog_app.dart` — `_HatchLogAppState`

### What's Wrong
`SessionWatcher._check()` detects when a user's role has been changed remotely and calls `authRepository.signOut()`. However, `SessionWatcher` has no callback or notification mechanism to tell `HatchLogApp` that this happened. `_HatchLogAppState._currentUser` remains non-null, so the app continues to render the authenticated dashboard instead of redirecting to the login screen.

```dart
// session_watcher.dart — _check()
if (remoteUserRole != UserRole.unknown && remoteUserRole != currentUser.role) {
  // Role changed remotely — force logout
  await authRepository.signOut();
  // ❌ Nothing happens after this — parent HatchLogApp is never notified
}
```

```dart
// hatchlog_app.dart — _activateUser()
_sessionWatcher = SessionWatcher(
  authRepository: widget.services.authRepository,
  remoteApi: widget.services.remoteApi,
  localDatabase: widget.services.localDatabase,
  currentUser: user,
  connectivityService: widget.services.connectivityService,
  // ❌ No onSignOut callback passed here
);
_sessionWatcher?.start();
```

### Impact
A user whose role is demoted or revoked by a farm owner remains logged into the mobile app indefinitely. Supabase session tokens might still work, giving them continued access until token expiry.

### Agent Prompt

```
You are fixing a logic bug in the HatchlogMobile Flutter project where session auto-signout does not update the UI.

AFFECTED FILES:
- lib/core/session_watcher.dart
- lib/app/hatchlog_app.dart

PROBLEM:
SessionWatcher calls `authRepository.signOut()` when it detects a remote role change, but HatchLogApp is never notified. The _currentUser stays set and the UI never navigates back to LoginScreen.

FIX — Step 1: Add an onSignOut callback to SessionWatcher

In `lib/core/session_watcher.dart`, update the class to accept and call a VoidCallback:

```dart
class SessionWatcher {
  SessionWatcher({
    required this.authRepository,
    required this.remoteApi,
    required this.localDatabase,
    required this.currentUser,
    required this.connectivityService,
    required this.onForcedSignOut,          // ← ADD THIS
    this.pollInterval = const Duration(seconds: 12),
  });

  // ... existing fields ...
  final VoidCallback onForcedSignOut;       // ← ADD THIS

  Future<void> _check() async {
    try {
      if (!remoteApi.isConfigured) return;
      if (!await connectivityService.isOnline) return;

      final remoteRole = await remoteApi.fetchUserRoleByIdentifier(
        currentUser.loginIdentifier,
      );
      final remoteUserRole = UserRole.fromString(remoteRole);
      if (remoteUserRole != UserRole.unknown &&
          remoteUserRole != currentUser.role) {
        await authRepository.signOut();
        onForcedSignOut();                  // ← ADD THIS CALL
      }
    } catch (_) {
      // ignore network errors
    }
  }
}
```

FIX — Step 2: Pass the callback when creating SessionWatcher in HatchLogApp

In `lib/app/hatchlog_app.dart`, inside `_activateUser()`:

```dart
_sessionWatcher = SessionWatcher(
  authRepository: widget.services.authRepository,
  remoteApi: widget.services.remoteApi,
  localDatabase: widget.services.localDatabase,
  currentUser: user,
  connectivityService: widget.services.connectivityService,
  onForcedSignOut: _handleForcedSignOut,   // ← ADD THIS
);
_sessionWatcher?.start();
```

Then add the handler method to `_HatchLogAppState`:

```dart
void _handleForcedSignOut() {
  if (!mounted) return;
  _sessionWatcher?.dispose();
  _sessionWatcher = null;
  widget.services.syncRepository.setActiveUser(null);
  setState(() => _currentUser = null);
}
```

IMPORTANT: `_handleForcedSignOut` does NOT call `authRepository.signOut()` again because `SessionWatcher._check()` already called it. It only clears the in-memory state and resets the UI.

Also add the import at the top of session_watcher.dart if it's missing:
```dart
import 'package:flutter/foundation.dart';
```
(`VoidCallback` is defined in `dart:ui` via `flutter/foundation.dart`)
```

---

## Bug #3 — HIGH: RoleGateway Silently Drops Critical Service Dependencies

**File:** `lib/features/role_gateway/presentation/role_gateway.dart`  
**Lines:** All of `build()`

### What's Wrong
`RoleGateway` is constructed with four service parameters (`inputSink`, `managementRepository`, `localSalesQueue`, `pdfInvoiceService`) that are accepted but never forwarded to `UniversalMobileDashboard`. The dashboard gets `currentUser`, `connectionChanges`, `isOnline`, and `onSignOut` — but the services are silently discarded.

```dart
// role_gateway.dart — build()
return UniversalMobileDashboard(
  currentUser: currentUser,
  connectionChanges: connectionChanges,
  isOnline: isOnline,
  onSignOut: onSignOut,
  // ❌ inputSink is accepted by RoleGateway but never passed here
  // ❌ managementRepository is accepted but never passed here
  // ❌ localSalesQueue is accepted but never passed here
  // ❌ pdfInvoiceService is accepted but never passed here
);
```

`UniversalMobileDashboard` currently reads from Supabase directly (`Supabase.instance.client`) which bypasses the service layer, the local cache, and the offline sync queue entirely.

### Impact
Any action taken inside the dashboard (recording operations, expense logging, etc.) bypasses the `WorkerInputSink` queue. Offline-first capability is broken for operations performed through the dashboard — data goes straight to Supabase only and won't queue locally when offline.

### Agent Prompt

```
You are fixing a dependency injection bug in the HatchlogMobile Flutter project.

AFFECTED FILES:
- lib/features/role_gateway/presentation/role_gateway.dart
- lib/presentation/universal/universal_mobile_dashboard.dart

PROBLEM:
RoleGateway accepts inputSink, managementRepository, localSalesQueue, and pdfInvoiceService but drops them when constructing UniversalMobileDashboard. The dashboard bypasses these services and reads from Supabase directly, breaking offline support.

FIX — Step 1: Add the missing fields to UniversalMobileDashboard

In `lib/presentation/universal/universal_mobile_dashboard.dart`, update the widget constructor:

```dart
class UniversalMobileDashboard extends StatefulWidget {
  const UniversalMobileDashboard({
    super.key,
    required this.currentUser,
    required this.connectionChanges,
    required this.isOnline,
    required this.onSignOut,
    required this.inputSink,              // ← ADD
    required this.managementRepository,   // ← ADD
    this.localSalesQueue,                 // ← ADD (nullable — worker feature)
    this.pdfInvoiceService,               // ← ADD (nullable — worker feature)
  });

  final AppUser currentUser;
  final Stream<bool> connectionChanges;
  final Future<bool> Function() isOnline;
  final Future<void> Function() onSignOut;
  final WorkerInputSink inputSink;                   // ← ADD
  final ManagementDataSource managementRepository;   // ← ADD
  final dynamic localSalesQueue;                     // ← ADD
  final dynamic pdfInvoiceService;                   // ← ADD
```

Add the required imports at the top of `universal_mobile_dashboard.dart`:
```dart
import '../../features/management/data/management_repository.dart';
import '../../features/sync/data/worker_input_sink.dart';
```

FIX — Step 2: Pass the services in RoleGateway

In `lib/features/role_gateway/presentation/role_gateway.dart`:

```dart
return UniversalMobileDashboard(
  currentUser: currentUser,
  connectionChanges: connectionChanges,
  isOnline: isOnline,
  onSignOut: onSignOut,
  inputSink: inputSink,                         // ← ADD
  managementRepository: managementRepository,   // ← ADD
  localSalesQueue: localSalesQueue,             // ← ADD
  pdfInvoiceService: pdfInvoiceService,         // ← ADD
);
```

FIX — Step 3: Use inputSink in UniversalMobileDashboard for write operations

Inside `_UniversalMobileDashboardState`, locate any direct Supabase `.insert()` / `.upsert()` / `.update()` calls used for operational data entry (egg collection, feeding logs, mortality, etc.).

Replace these direct Supabase calls with calls through `widget.inputSink.enqueueWorkerInput(...)` for worker-type operations, and `widget.managementRepository.logExpense(...)` / `widget.managementRepository.createInvoice(...)` for management-type operations.

For the SaleEntry feature, pass `widget.localSalesQueue` and `widget.pdfInvoiceService` to the `SaleEntryScreen` widget when navigating to it, instead of reading these from a global or constructing new instances.

NOTE: Keep the existing Supabase streaming (`.stream()` calls used in `_streamFor()`) for reading/display only. Only replace write-path calls.
```

---

## Bug #4 — MEDIUM: Device ID Regenerated on Every App Boot

**File:** `lib/app/app_services.dart`  
**Line:** ~64

### What's Wrong
A new device ID is computed from the current timestamp every time `AppServices.bootstrap()` runs:

```dart
final deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
```

`EncryptionService.transactionHash()` uses this `deviceId` to generate transaction hashes stored in `LocalSalesQueue`. Since the ID changes on every restart, the same physical device produces different hashes across sessions, breaking the deduplication and tamper-detection logic entirely.

### Agent Prompt

```
You are fixing a device ID persistence bug in the HatchlogMobile Flutter project.

AFFECTED FILES:
- lib/app/app_services.dart
- lib/core/storage/local_database.dart (may need a new helper)

PROBLEM:
`AppServices.bootstrap()` generates `deviceId` as `'device-${DateTime.now().millisecondsSinceEpoch}'`.
This means the device ID changes every time the app restarts. The device ID is used by
`EncryptionService.transactionHash()` to create deterministic hashes for offline sales.
A rotating device ID makes these hashes non-deterministic across sessions, breaking deduplication.

FIX — Option A: Store the device ID in flutter_secure_storage (recommended)

Add a helper method to `SecureCredentialStore` or create a new `DeviceIdentityStore` class:

```dart
// lib/core/storage/device_identity_store.dart
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:math';

class DeviceIdentityStore {
  static const _storage = FlutterSecureStorage();
  static const _key = 'hatchlog.mobile.device_id.v1';

  static Future<String> getOrCreate() async {
    final existing = await _storage.read(key: _key);
    if (existing != null && existing.isNotEmpty) {
      return existing;
    }
    final newId = _generateDeviceId();
    await _storage.write(key: _key, value: newId);
    return newId;
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return 'device-${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
}
```

Then in `lib/app/app_services.dart`, update `bootstrap()`:

```dart
import '../core/storage/device_identity_store.dart';

// Inside bootstrap():
// REMOVE:
//   final deviceId = 'device-${DateTime.now().millisecondsSinceEpoch}';
// REPLACE WITH:
final deviceId = await DeviceIdentityStore.getOrCreate();
```

This generates a random 16-byte hex device ID once and stores it permanently in the secure keychain.
Subsequent app launches reuse the same ID.

IMPORTANT: Do not change `EncryptionService` or `LocalSalesQueue` — only fix where deviceId comes from.
```

---

## Bug #5 — MEDIUM: `SupabaseConfig.load()` Throws Instead of Returning Unconfigured State

**File:** `lib/core/config/supabase_config.dart`  
**Lines:** Last 4 lines of `load()`

### What's Wrong
`SupabaseRemoteApi` is designed to handle a "not configured" state gracefully via `SupabaseRemoteApi._(null)`. However, `SupabaseConfig.load()` throws an unhandled `Exception` when credentials are not found instead of returning an empty config. `SupabaseRemoteApi.fromEnvironment()` never catches this exception, so the unreachable `if (!config.isConfigured)` guard is dead code. A developer who hasn't set up `.env.mobile` will get a crash instead of a graceful "configure your credentials" flow.

```dart
// supabase_config.dart — load()
throw Exception(
  'CRITICAL FATAL ERROR: Configuration tokens are unresolvable via Asset Vault or Engine Environment.',
);
// This propagates through SupabaseRemoteApi.fromEnvironment() and crashes bootstrap()
```

### Agent Prompt

```
You are fixing an error-handling inconsistency in the HatchlogMobile Flutter project.

AFFECTED FILE: lib/core/config/supabase_config.dart

PROBLEM:
`SupabaseConfig.load()` throws an `Exception` when credentials are missing, but
`SupabaseRemoteApi.fromEnvironment()` is designed to return `SupabaseRemoteApi._(null)`
(an unconfigured state) when config is absent. The throw prevents the graceful
unconfigured path from ever being reached.

FIX: Replace the throw with a return of an empty/unconfigured config:

In `lib/core/config/supabase_config.dart`, find the end of `static Future<SupabaseConfig> load()`:

CURRENT CODE (remove this):
```dart
throw Exception(
  'CRITICAL FATAL ERROR: Configuration tokens are unresolvable via Asset Vault or Engine Environment.',
);
```

REPLACE WITH:
```dart
debugPrint(
  'WARN: Supabase credentials not found in packed asset or compile-time tokens. '
  'App will operate in offline-only mode.',
);
return const SupabaseConfig(
  url: '',
  clientKey: '',
  source: SupabaseConfigSource.packedAsset,
);
```

This allows `SupabaseRemoteApi.fromEnvironment()` to reach its `if (!config.isConfigured)` check
and return `SupabaseRemoteApi._(null)`, enabling the app to boot in offline/unconfigured mode
instead of crashing — which is the intended design.

VERIFY: After making this change, confirm that `SupabaseRemoteApi.isConfigured` returns `false`
when credentials are absent, and that `AuthRepository.signIn()` correctly throws
`AuthFailure('Supabase is not configured...')` rather than crashing.
```

---

## Bug #6 — MEDIUM: Division-by-Zero Risk in `LocalSalesQueue.enqueueSale`

**File:** `lib/services/local_sales_queue.dart`  
**Line:** ~57 (inside `enqueueSale`)

### What's Wrong
The sale item record inserts `unit_price` as `amountReceived / quantityCrates`. There is no guard against `quantityCrates == 0` inside the service itself. While `SaleEntryScreen` validates `qty > 0`, the queue service is public API and could be called from other callers (or tests) without that guard.

```dart
await localDatabase.insertLocalRecord('sale_items', {
  // ...
  'unit_price': amountReceived / quantityCrates,  // ❌ DivisionByZeroException if quantityCrates == 0
```

### Agent Prompt

```
You are fixing a potential division-by-zero bug in the HatchlogMobile Flutter project.

AFFECTED FILE: lib/services/local_sales_queue.dart

PROBLEM:
In `LocalSalesQueue.enqueueSale()`, the sale item record writes:
  `'unit_price': amountReceived / quantityCrates`

If `quantityCrates` is 0, this throws an unhandled `IntegerDivisionByZeroException`.
The UI validates qty > 0, but the service itself has no guard.

FIX:
Add parameter validation at the top of `enqueueSale()`, BEFORE the recent-inputs check:

```dart
Future<int> enqueueSale({
  required String userId,
  required String farmId,
  required int quantityCrates,
  required double amountReceived,
  required String unit,
  String paymentMethod = 'CASH',
}) async {
  // ← ADD THESE GUARDS
  if (quantityCrates <= 0) {
    throw ArgumentError.value(
      quantityCrates,
      'quantityCrates',
      'Quantity must be greater than zero.',
    );
  }
  if (amountReceived <= 0) {
    throw ArgumentError.value(
      amountReceived,
      'amountReceived',
      'Amount received must be greater than zero.',
    );
  }
  // existing code continues...
  final deviceTimestamp = DateTime.now().toUtc();
```

This makes the service self-validating. The UI will still catch the error via the existing
`catch (e)` in `SaleEntryScreen._submit()` and display it in a SnackBar.
```

---

## Bug #7 — LOW: `_hasEnvironmentState` Returns True for Exactly Zero Values

**File:** `lib/features/auth/data/supabase_remote_api.dart`  
**Method:** `_hasEnvironmentState`

### What's Wrong
The method converts temperature and humidity to strings to check if they are present:

```dart
bool _hasEnvironmentState(Map<String, dynamic> row) {
  return _asString(row['currentTemperature']).isNotEmpty ||
      _asString(row['currentHumidity']).isNotEmpty;
}
```

If a house has `currentTemperature = 0` or `currentHumidity = 0` (numeric zero), `_asString(0)` returns `"0"` which is non-empty. This causes a spurious `house_environment_logs` row to be generated for every house that has a zero reading, filling up the local database with meaningless entries.

### Agent Prompt

```
You are fixing a false-positive bug in environment log generation in the HatchlogMobile Flutter project.

AFFECTED FILE: lib/features/auth/data/supabase_remote_api.dart

PROBLEM:
`_hasEnvironmentState()` uses string conversion to check for presence of temperature/humidity:
  `_asString(row['currentTemperature']).isNotEmpty`

The value `0` (numeric zero) converts to `"0"` which is non-empty, so houses with exactly
0°C temperature or 0% humidity generate an environment log entry even though these are
null/absent values in practice.

FIX: Replace the string-based check with a numeric comparison.

Find `_hasEnvironmentState` in the file and replace it:

CURRENT:
```dart
bool _hasEnvironmentState(Map<String, dynamic> row) {
  return _asString(row['currentTemperature']).isNotEmpty ||
      _asString(row['currentHumidity']).isNotEmpty;
}
```

REPLACE WITH:
```dart
bool _hasEnvironmentState(Map<String, dynamic> row) {
  final temperature = row['currentTemperature'];
  final humidity = row['currentHumidity'];
  // Only generate an environment log if at least one value is explicitly
  // a non-null, non-zero numeric reading from the server
  final hasTemp = temperature != null && _asDouble(temperature) != 0.0;
  final hasHumidity = humidity != null && _asDouble(humidity) != 0.0;
  return hasTemp || hasHumidity;
}
```

This checks that the value is both non-null AND numerically non-zero before treating it as
a valid environmental reading worth logging.
```

---

## Testing Checklist for Agents

After applying each fix, verify:

| Fix | Test to Run |
|-----|------------|
| Bug #1 | `git status` — `.env.mobile` should appear as untracked |
| Bug #2 | Change a user's role in Supabase → verify app navigates to LoginScreen within 12 seconds |
| Bug #3 | Record an egg collection offline → verify a `pending_sync_inputs` row is created locally |
| Bug #4 | Kill and relaunch the app → verify `DeviceIdentityStore.getOrCreate()` returns the same ID |
| Bug #5 | Remove `.env.mobile`, cold-start → verify app shows login screen instead of crashing |
| Bug #6 | Call `enqueueSale(quantityCrates: 0, ...)` in a unit test → verify `ArgumentError` is thrown |
| Bug #7 | Insert a house with `currentTemperature: 0` in Supabase → verify no spurious env log is created |

Run existing tests with `flutter test` after all fixes to confirm no regressions.

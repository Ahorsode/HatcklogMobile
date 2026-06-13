# HatchlogMobile — Enterprise Feature Report
**Repository:** https://github.com/Ahorsode/HatcklogMobile.git  
**Date:** June 2026  
**Stack:** Flutter 3 · Dart · Supabase (PostgreSQL) · SQLite (sqflite) · Google Sign-In · fl_chart · pdf/printing

---

## Part 1 — Current Project Workflow

### What HatchlogMobile Is

HatchlogMobile is an **offline-first, role-gated poultry farm management system** for Android/iOS. A farm owner uses a companion web dashboard (HatchLog Web) to create the farm and invite staff. Workers, managers, and accountants use this mobile app to log daily operations. All data syncs bidirectionally with a Supabase (PostgreSQL) backend when connectivity is available, and falls back to a local SQLite database when offline.

---

### Step-by-Step App Flow

```
App Launch
  │
  ├─ 1. Load .env.mobile (Supabase URL + Google OAuth keys)
  │
  ├─ 2. GoogleAuthConfig.load() — validate OAuth keys exist
  │
  ├─ 3. AppServices.bootstrap()
  │       ├─ Init local SQLite (sqflite)
  │       ├─ Init Supabase client
  │       ├─ Init SecureCredentialStore (flutter_secure_storage)
  │       ├─ Init ConnectivityService
  │       ├─ Init SyncRunner (starts polling timer every 2 mins)
  │       └─ Assemble: AuthRepository, SyncRepository, ManagementRepository, LocalSalesQueue
  │
  └─ 4. HatchLogApp (StatefulWidget)
          │
          ├─ Attempt to restore previous session from Supabase token
          │       ├─ Session found → _activateUser(user)
          │       └─ No session → show LoginScreen
          │
          ├─ LoginScreen
          │       ├─ Email/phone + password → AuthRepository.signIn()
          │       │       ├─ Default password "123456" → InitialSetup flow (change name + password)
          │       │       ├─ Online → Supabase auth → fetch user profile + role
          │       │       └─ Offline → PBKDF2 hash check from SecureCredentialStore
          │       └─ Google Sign-In → OAuth flow → check invitation table → link farm
          │
          └─ _activateUser(user)
                  ├─ Start SessionWatcher (polls every 12s for role changes)
                  ├─ Set activeUser on SyncRepository
                  ├─ SyncRunner.syncWhenOnline()
                  └─ Route to RoleGateway → UniversalMobileDashboard
```

---

### Role System

| Role | Access Level | Primary Use |
|------|-------------|-------------|
| **Owner** | All 19 modules + Permissions Matrix | Full farm control, invoicing, team management |
| **Admin** | All 19 modules | Operations-level owner equivalent |
| **Manager** | Most modules (permission-gated) | Day-to-day operations oversight |
| **Accountant** | Finance, Sales, Customers, Suppliers | Financial oversight only |
| **Worker** | Egg collection, feed logging, mortality, sales | Field data entry |

Permissions are enforced via a `farm_member_permissions` Supabase table with 20+ boolean columns (can_view_finance, can_edit_batches, etc.), all controlled by the owner via the Permissions Matrix module in-app.

---

### Sync Engine

```
Online write path:
  User action → UniversalMobileDashboard._insertRow()
              → Supabase.from(table).insert() [direct]

Worker offline write path:
  Worker tap → WorkerInputSink.enqueueWorkerInput()
             → pending_sync_inputs (SQLite)
             → SyncRunner fires (2min or connectivity restore)
             → SyncRepository.flushPendingInputs()
             → Supabase upsert
             → Mark local row is_synced = 1

Inbound sync path (cloud → local cache):
  SyncRepository.flushPendingInputs()
  → _activeUser != null
  → syncEngineService.syncWebEntitiesToLocalCache(user)
  → Fetch: farms, batches, houses, egg_production, daily_feeding_logs,
           mortality, quarantine, inventory, sales, customers, suppliers,
           financial_transactions, expenses, farm_members, local_users
  → Upsert all into local SQLite
```

---

### 19 Current Modules

| # | Module | Tables | Who Can Access |
|---|--------|--------|---------------|
| 1 | HatchLog Central Dashboard | — (aggregation) | All privileged roles |
| 2 | Permissions Matrix | farm_member_permissions | Owner only |
| 3 | Livestock | batches | All |
| 4 | Houses | houses | All |
| 5 | Eggs | egg_production | All |
| 6 | Feeding | daily_feeding_logs | All |
| 7 | Mortality | mortality | All |
| 8 | Quarantine | quarantine | All |
| 9 | Sales | sales + sale_items | All |
| 10 | Inventory | inventory | All |
| 11 | Customers | customers | All |
| 12 | Finance Control | financial_transactions | Finance roles |
| 13 | Orders | orders + order_items | All |
| 14 | Suppliers | suppliers | All |
| 15 | Feed Formulations | feed_formulations + ingredients | All |
| 16 | Egg Categories | egg_categories | All |
| 17 | Weight Records | weight_records | All |
| 18 | Vaccination Schedules | vaccination_schedules | All |
| 19 | Medication Schedules | medication_schedules | All |

---

### PDF & Sharing

- **Farm-gate sales** → `PdfInvoiceService.buildInvoiceBytes()` → `share_plus` (WhatsApp or any app)
- **Management invoices** → `InvoicePdfService.buildInvoice()` → single-page branded PDF

---

### What Already Exists But Is Unused

| Asset | Status | Note |
|-------|--------|------|
| `fl_chart` package | Installed, zero uses | No charts rendered anywhere in the app |
| `delete_logs` table | Schema exists | Not read or displayed in mobile |
| `insert_logs` table | Schema exists | Not read or displayed in mobile |
| `weight_records` module | Module built | No trend chart rendered |
| `growth_standards` table | Schema exists | Not connected to any mobile view |
| `device_registrations.license_*` columns | Schema exists | License enforcement not implemented in mobile |

---

## Part 2 — Enterprise Features

> Each feature is explained first, then followed by a detailed agent prompt you can paste directly into Claude Code or any coding agent.

---

### Feature 1 — Live Analytics Dashboard with fl_chart

**What it is and why it matters**

Right now `fl_chart` is installed but the app has zero charts. The only numbers a user sees are raw list rows. An enterprise farm operator needs to see trends at a glance: is my mortality rate rising? Is daily egg production declining as the flock ages? Is feed spend spiking? These questions are answered poorly by scrolling a list and very well by a line chart. This feature adds a "Farm Pulse" analytics screen that renders 4 charts from data already in the local SQLite database — no new backend work needed.

**Charts to build:**
1. **Egg Production trend** (7-day rolling line chart) — eggs_collected per day
2. **Mortality trend** (7-day bar chart) — dead count per day, threshold line at 1%
3. **Feed Consumption** (7-day area chart) — sacks used per day per batch
4. **Revenue vs Expenses** (14-day bar chart) — stacked bars comparing income and spend

---

**Agent Prompt — Feature 1**

```
You are adding a Live Analytics Dashboard to HatchlogMobile, a Flutter poultry farm app.

CONTEXT:
- fl_chart ^1.2.0 is already in pubspec.yaml but has zero usages
- Local SQLite data is accessible via LocalDatabase (lib/core/storage/local_database.dart)
- ManagementRepository already queries: egg_production, daily_feeding_logs, mortality, financial_transactions
- The app uses a dark-green brand color #145F3B and white backgrounds
- The universal dashboard is in lib/presentation/universal/universal_mobile_dashboard.dart

WHAT TO BUILD:
Create lib/presentation/analytics/farm_analytics_screen.dart — a new screen with 4 fl_chart charts.

STEP 1: Create the data model lib/presentation/analytics/analytics_models.dart

```dart
class DailyDataPoint {
  const DailyDataPoint({required this.date, required this.value});
  final DateTime date;
  final double value;
}

class FarmAnalyticsSnapshot {
  const FarmAnalyticsSnapshot({
    required this.eggProduction7d,   // List<DailyDataPoint>
    required this.mortality7d,       // List<DailyDataPoint>
    required this.feedUsage7d,       // List<DailyDataPoint>
    required this.revenue14d,        // List<DailyDataPoint>
    required this.expenses14d,       // List<DailyDataPoint>
    required this.peakEggDay,
    required this.avgDailyMortality,
    required this.totalFeedUsed7d,
    required this.netProfit14d,
  });

  final List<DailyDataPoint> eggProduction7d;
  final List<DailyDataPoint> mortality7d;
  final List<DailyDataPoint> feedUsage7d;
  final List<DailyDataPoint> revenue14d;
  final List<DailyDataPoint> expenses14d;
  final int peakEggDay;
  final double avgDailyMortality;
  final double totalFeedUsed7d;
  final double netProfit14d;
}
```

STEP 2: Add a data loader method to ManagementRepository (lib/features/management/data/management_repository.dart)

```dart
Future<FarmAnalyticsSnapshot> loadAnalytics(AppUser user) async {
  final farmId = user.activeFarmId;
  final now = DateTime.now();
  final sevenDaysAgo = now.subtract(const Duration(days: 7));
  final fourteenDaysAgo = now.subtract(const Duration(days: 14));

  // Egg production: 7 days
  final eggRows = await _localDatabase.rawLocalQuery(
    "SELECT date(log_date) as day, coalesce(sum(eggs_collected), 0) as total "
    "FROM egg_production WHERE farm_id = ? AND log_date >= ? AND is_deleted = 0 "
    "GROUP BY date(log_date) ORDER BY day ASC",
    [farmId, sevenDaysAgo.toIso8601String()],
  );

  // Mortality: 7 days
  final mortalityRows = await _localDatabase.rawLocalQuery(
    "SELECT date(log_date) as day, coalesce(sum(count), 0) as total "
    "FROM mortality WHERE farm_id = ? AND log_date >= ? AND is_deleted = 0 AND upper(type) = 'DEAD' "
    "GROUP BY date(log_date) ORDER BY day ASC",
    [farmId, sevenDaysAgo.toIso8601String()],
  );

  // Feed: 7 days
  final feedRows = await _localDatabase.rawLocalQuery(
    "SELECT date(log_date) as day, coalesce(sum(amount_consumed), 0) as total "
    "FROM daily_feeding_logs WHERE farm_id = ? AND log_date >= ? AND is_deleted = 0 "
    "GROUP BY date(log_date) ORDER BY day ASC",
    [farmId, sevenDaysAgo.toIso8601String()],
  );

  // Revenue: 14 days
  final revenueRows = await _localDatabase.rawLocalQuery(
    "SELECT date(transaction_date) as day, coalesce(sum(amount), 0) as total "
    "FROM financial_transactions WHERE farm_id = ? AND transaction_date >= ? AND is_deleted = 0 AND type = 'REVENUE' "
    "GROUP BY date(transaction_date) ORDER BY day ASC",
    [farmId, fourteenDaysAgo.toIso8601String()],
  );

  // Expenses: 14 days
  final expenseRows = await _localDatabase.rawLocalQuery(
    "SELECT date(transaction_date) as day, coalesce(sum(amount), 0) as total "
    "FROM financial_transactions WHERE farm_id = ? AND transaction_date >= ? AND is_deleted = 0 AND type = 'EXPENSE' "
    "GROUP BY date(transaction_date) ORDER BY day ASC",
    [farmId, fourteenDaysAgo.toIso8601String()],
  );

  List<DailyDataPoint> _toPoints(List<Map<String, dynamic>> rows) => rows
      .map((r) => DailyDataPoint(
            date: DateTime.parse(r['day'].toString()),
            value: double.tryParse(r['total'].toString()) ?? 0,
          ))
      .toList();

  final eggPoints = _toPoints(eggRows);
  final rev = _toPoints(revenueRows);
  final exp = _toPoints(expenseRows);

  final totalRev = rev.fold(0.0, (s, p) => s + p.value);
  final totalExp = exp.fold(0.0, (s, p) => s + p.value);

  return FarmAnalyticsSnapshot(
    eggProduction7d: eggPoints,
    mortality7d: _toPoints(mortalityRows),
    feedUsage7d: _toPoints(feedRows),
    revenue14d: rev,
    expenses14d: exp,
    peakEggDay: eggPoints.isEmpty ? 0 : eggPoints.map((p) => p.value.toInt()).reduce((a, b) => a > b ? a : b),
    avgDailyMortality: _toPoints(mortalityRows).isEmpty ? 0 : _toPoints(mortalityRows).fold(0.0, (s, p) => s + p.value) / 7,
    totalFeedUsed7d: _toPoints(feedRows).fold(0.0, (s, p) => s + p.value),
    netProfit14d: totalRev - totalExp,
  );
}
```

STEP 3: Create lib/presentation/analytics/farm_analytics_screen.dart

The screen layout should be a SingleChildScrollView with these sections in order:
1. KPI summary row — 4 stat cards: Peak Egg Day, Avg Daily Mortality, Feed Used (7d), Net Profit (14d)
2. Section header: "Egg Production — Last 7 Days" + LineChart
3. Section header: "Bird Losses — Last 7 Days" + BarChart with a red threshold line at the average
4. Section header: "Feed Consumption — Last 7 Days" + AreaChart (LineChartData with belowBarData)
5. Section header: "Revenue vs Expenses — Last 14 Days" + BarChart with grouped bars (green = revenue, red = expense)

CHART IMPLEMENTATION RULES for fl_chart:
- Use LineChart for egg production: lineBarsData with color Color(0xff145F3B), dotData shown, gridData enabled
- Use BarChart for mortality: barGroups with red bars Color(0xffb83b3b), add a horizontal ExtraLinesData at avgDailyMortality
- Use LineChart with belowBarData for feed area: gradient from Color(0xff145F3B).withOpacity(0.3) to transparent
- Use BarChart with two BarChartGroupData per day for revenue/expenses
- All charts: minX = 0, maxX = days.length - 1.0, bottomTitles show day abbreviations (Mon, Tue...), titlesData enabled
- Chart height: 200 for all charts
- Wrap each chart in a Card with rounded corners (8px radius) and 12px padding

STEP 4: Add analytics route to UniversalMobileDashboard

In lib/presentation/universal/universal_mobile_dashboard.dart, add a drawer item "Farm Analytics" with icon Icons.bar_chart. When tapped, push a route to FarmAnalyticsScreen, passing widget.currentUser and widget.managementRepository.

The FarmAnalyticsScreen loads data in initState() via FutureBuilder<FarmAnalyticsSnapshot>. Show a shimmer loading state while loading. Show a centered error widget with a retry button on failure.

DO NOT add any new packages. Use only fl_chart which is already installed.
```

---

### Feature 2 — AI Farm Intelligence (Claude-Powered Insight Engine)

**What it is and why it matters**

Enterprise farm operators make hundreds of decisions per week: which feed to switch to, whether a mortality spike is random or systemic, when to cull a batch, how to price eggs by grade. Right now HatchlogMobile gives them raw data but no interpretation. This feature adds an in-app AI assistant powered by the Anthropic Claude API that can answer questions like "Why is mortality in House 3 above average this week?" or "Generate a weekly summary report for me." The AI has access to the farm's local data so its answers are specific, not generic.

**Key capabilities:**
- Natural language farm Q&A ("Is my feed conversion ratio good?")
- Auto-generated weekly summary report (narrated, not just numbers)
- Anomaly explanation ("Your mortality spiked on Tuesday — here's what the data shows")
- Batch comparison ("Compare Batch A vs Batch B profitability")

---

**Agent Prompt — Feature 2**

```
You are adding an AI Farm Intelligence feature to HatchlogMobile using the Anthropic Claude API.

CONTEXT:
- This is a Flutter app for poultry farm management in Ghana
- The app already has local SQLite data (eggs, feed, mortality, sales, batches, inventory)
- ManagementRepository already loads ManagementSnapshot with all farm data
- The Anthropic API key will be stored in .env.mobile as ANTHROPIC_API_KEY
- Stack: Flutter/Dart, http package (add to pubspec.yaml: http: ^1.2.0)

WHAT TO BUILD:
Create an AI chat screen where the farmer types a question and gets an AI answer grounded in their actual farm data.

STEP 1: Add http to pubspec.yaml dependencies:
  http: ^1.2.0

STEP 2: Create lib/services/farm_ai_service.dart

```dart
import 'dart:convert';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;

import '../features/management/data/management_models.dart';

class FarmAiService {
  static const _endpoint = 'https://api.anthropic.com/v1/messages';
  static const _model = 'claude-sonnet-4-6';

  Future<String> askAboutFarm({
    required String question,
    required ManagementSnapshot snapshot,
    List<Map<String, String>> conversationHistory = const [],
  }) async {
    final apiKey = dotenv.env['ANTHROPIC_API_KEY'] ?? '';
    if (apiKey.isEmpty) {
      return 'AI assistant is not configured. Add ANTHROPIC_API_KEY to .env.mobile.';
    }

    final systemPrompt = '''
You are a poultry farm management expert assistant for HatchLog, a farm management system used in Ghana.
You have access to the farm's current operational data. Analyze it and answer the farmer's questions
with specific, actionable insights. Always ground your answers in the actual numbers provided.
Be concise but thorough. Use GHS for currency. Reference specific batches and houses by name.

CURRENT FARM DATA:
- Total Revenue (period): GHS ${snapshot.totalRevenue.toStringAsFixed(2)}
- Total Expenses (period): GHS ${snapshot.totalExpenses.toStringAsFixed(2)}
- Net Profit: GHS ${snapshot.netProfit.toStringAsFixed(2)}
- Active Batches: ${snapshot.batches.length}
- Pending Sync Records: ${snapshot.pendingSyncCount}

BATCH ANALYTICS:
${snapshot.analytics.map((a) => '''
  Batch: ${a.batchLabel}
  - Current Count: ${a.currentCount} birds
  - Initial Count: ${a.initialCount} birds
  - Mortality: ${a.mortalityCount} birds (${(a.mortalityRate * 100).toStringAsFixed(1)}%)
  - Eggs Collected: ${a.eggsCollected}
  - Feed Consumed: ${a.feedConsumed.toStringAsFixed(1)} sacks
  - FCR Proxy: ${a.fcrProxy.toStringAsFixed(2)} (feed sacks per egg)
''').join('\n')}

RECENT EGG RECORDS:
${snapshot.eggRecords.take(7).map((r) => '  ${r.title} — ${r.subtitle} [${r.metric}]').join('\n')}

RECENT MORTALITY:
${snapshot.mortalityRecords.take(7).map((r) => '  ${r.title} — ${r.subtitle}').join('\n')}

INVENTORY STATUS:
${snapshot.inventoryRecords.where((r) => r.status == 'REORDER').take(5).map((r) => '  REORDER NEEDED: ${r.title} — ${r.metric} remaining').join('\n')}
${snapshot.inventoryRecords.where((r) => r.status != 'REORDER').take(10).map((r) => '  ${r.title}: ${r.metric}').join('\n')}
''';

    final messages = [
      ...conversationHistory.map((m) => {'role': m['role']!, 'content': m['content']!}),
      {'role': 'user', 'content': question},
    ];

    try {
      final response = await http.post(
        Uri.parse(_endpoint),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: jsonEncode({
          'model': _model,
          'max_tokens': 1024,
          'system': systemPrompt,
          'messages': messages,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final content = data['content'] as List<dynamic>;
        return content
            .whereType<Map<String, dynamic>>()
            .where((block) => block['type'] == 'text')
            .map((block) => block['text'] as String)
            .join('\n');
      } else {
        return 'AI request failed (${response.statusCode}). Check your API key.';
      }
    } catch (e) {
      return 'Could not reach AI service. Check your internet connection.';
    }
  }

  Future<String> generateWeeklyReport(ManagementSnapshot snapshot) async {
    return askAboutFarm(
      question: 'Generate a concise weekly farm performance summary. '
          'Include: overall financial health, top performing batch, any mortality concerns, '
          'inventory items needing reorder, and 2-3 recommended actions for next week. '
          'Format it as a professional farm report, not bullet points.',
      snapshot: snapshot,
    );
  }
}
```

STEP 3: Create lib/presentation/ai/farm_ai_screen.dart

Build a chat-style screen with:
- An AppBar titled "Farm AI Assistant" with a sparkle icon
- A scrollable message list (user messages right-aligned in green bubbles, AI messages left-aligned in white cards)
- A bottom text field with a send button and a "Weekly Report" action chip above it
- Loading indicator (3 animated dots) while waiting for AI response
- The conversation history is maintained in _HatchLogAiScreenState as List<Map<String, String>>

State management:
```dart
class _FarmAiScreenState extends State<FarmAiScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _aiService = FarmAiService();
  final List<Map<String, String>> _messages = [];  // {role: user|assistant, content: ...}
  bool _isLoading = false;
  late Future<ManagementSnapshot> _snapshotFuture;

  @override
  void initState() {
    super.initState();
    _snapshotFuture = widget.managementRepository.loadSnapshot(widget.currentUser);
    // Add a welcome message
    _messages.add({
      'role': 'assistant',
      'content': 'Hello! I\'m your HatchLog farm assistant. Ask me anything about your farm — mortality trends, feed efficiency, profit analysis, or get a weekly report.',
    });
  }

  Future<void> _send(String text, ManagementSnapshot snapshot) async {
    if (text.trim().isEmpty || _isLoading) return;
    _controller.clear();
    setState(() {
      _messages.add({'role': 'user', 'content': text.trim()});
      _isLoading = true;
    });
    _scrollToBottom();

    final reply = await _aiService.askAboutFarm(
      question: text.trim(),
      snapshot: snapshot,
      conversationHistory: _messages.sublist(0, _messages.length - 1),
    );

    setState(() {
      _messages.add({'role': 'assistant', 'content': reply});
      _isLoading = false;
    });
    _scrollToBottom();
  }
}
```

STEP 4: Add navigation to FarmAiScreen

In the universal dashboard drawer or action bar, add a "Farm AI" menu item with icon Icons.auto_awesome. When tapped, push FarmAiScreen with the currentUser and managementRepository.

Add ANTHROPIC_API_KEY=your_key_here to .env.example with instructions.
Add ANTHROPIC_API_KEY to the .env.mobile file (developer fills in their own key).
```

---

### Feature 3 — Push Notifications (FCM Alert System)

**What it is and why it matters**

A farm manager sleeping at night has no idea if a worker just logged 30 dead birds or if the temperature sensor in House 2 just went offline. Push notifications turn HatchlogMobile from a passive log book into an active alert system. Enterprise farms run 24/7 and need instant notification for: mortality spikes, low inventory, sync failures, upcoming vaccination dates, and overdue payments. The backend infrastructure (Supabase + PostgreSQL) already supports webhooks and triggers to power this.

**Key alerts:**
- 🔴 Mortality spike (>5 birds in one entry, or daily rate >2%)
- 🟡 Inventory reorder threshold crossed
- 🟡 Vaccination due in 24 hours
- 🔵 Successful sync after offline period
- 🔴 Payment overdue (customer balance > 30 days)

---

**Agent Prompt — Feature 3**

```
You are adding Firebase Cloud Messaging (FCM) push notifications to HatchlogMobile.

CONTEXT:
- Flutter app with Supabase backend
- firebase_messaging package needs to be added
- Supabase Edge Functions (Deno) will trigger the FCM messages
- The app targets Android 13+ (API 33) and iOS 16+

WHAT TO BUILD:

STEP 1: Add Firebase dependencies to pubspec.yaml
```yaml
  firebase_core: ^3.6.0
  firebase_messaging: ^15.1.3
  flutter_local_notifications: ^17.2.4
```

STEP 2: Create lib/services/push_notification_service.dart

```dart
import 'dart:convert';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PushNotificationService {
  static final _localNotifs = FlutterLocalNotificationsPlugin();
  static final _fcm = FirebaseMessaging.instance;

  static Future<void> initialize({required String farmId, required String userId}) async {
    // Request permission (iOS + Android 13)
    await _fcm.requestPermission(alert: true, badge: true, sound: true);

    // Initialize local notifications for foreground display
    await _localNotifs.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    // Get FCM token and register with Supabase
    final token = await _fcm.getToken();
    if (token != null) {
      await _registerToken(token: token, farmId: farmId, userId: userId);
    }

    // Listen for token refresh
    _fcm.onTokenRefresh.listen((newToken) {
      _registerToken(token: newToken, farmId: farmId, userId: userId);
    });

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((message) {
      _showLocalNotification(message);
    });

    // Background message handler (must be top-level function)
    FirebaseMessaging.onBackgroundMessage(_backgroundHandler);
  }

  static Future<void> _registerToken({
    required String token,
    required String farmId,
    required String userId,
  }) async {
    await Supabase.instance.client.from('device_push_tokens').upsert({
      'user_id': userId,
      'farm_id': farmId,
      'fcm_token': token,
      'platform': 'mobile',
      'updated_at': DateTime.now().toIso8601String(),
    }, onConflict: 'user_id,farm_id');
  }

  static Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;

    await _localNotifs.show(
      notification.hashCode,
      notification.title,
      notification.body,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'hatchlog_alerts',
          'Farm Alerts',
          channelDescription: 'Critical farm alerts from HatchLog',
          importance: Importance.high,
          priority: Priority.high,
          color: Color(0xff145F3B),
        ),
        iOS: DarwinNotificationDetails(presentAlert: true, presentBadge: true, presentSound: true),
      ),
    );
  }
}

@pragma('vm:entry-point')
Future<void> _backgroundHandler(RemoteMessage message) async {
  // Background messages are auto-displayed by FCM on Android
  // iOS: ensure firebase_messaging is initialized before handling
}
```

STEP 3: Call PushNotificationService.initialize() in HatchLogApp._activateUser()

After starting the session watcher, add:
```dart
await PushNotificationService.initialize(
  farmId: user.activeFarmId,
  userId: user.id,
);
```

STEP 4: Add the device_push_tokens table to Supabase

Run this SQL migration in Supabase:
```sql
CREATE TABLE IF NOT EXISTS device_push_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id text NOT NULL,
  farm_id text NOT NULL,
  fcm_token text NOT NULL,
  platform text NOT NULL DEFAULT 'mobile',
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now(),
  UNIQUE (user_id, farm_id)
);
```

STEP 5: Create Supabase Edge Function supabase/functions/mortality-alert/index.ts

```typescript
import { serve } from "https://deno.land/std@0.177.0/http/server.ts"
import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

serve(async (req) => {
  const payload = await req.json()
  const record = payload.record  // from Supabase DB webhook

  if (!record || record.count < 5) {
    return new Response("OK", { status: 200 })
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  )

  // Get all FCM tokens for this farm
  const { data: tokens } = await supabase
    .from('device_push_tokens')
    .select('fcm_token')
    .eq('farm_id', record.farm_id)

  if (!tokens?.length) return new Response("No tokens", { status: 200 })

  const fcmKey = Deno.env.get('FCM_SERVER_KEY')!
  for (const { fcm_token } of tokens) {
    await fetch("https://fcm.googleapis.com/fcm/send", {
      method: "POST",
      headers: { "Authorization": `key=${fcmKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        to: fcm_token,
        notification: {
          title: "⚠️ Mortality Alert",
          body: `${record.count} birds logged dead — check House ${record.house_id ?? 'Unknown'}`,
        },
        data: { type: "mortality", farm_id: record.farm_id, record_id: record.id }
      })
    })
  }

  return new Response("Sent", { status: 200 })
})
```

STEP 6: In Supabase Dashboard → Database → Webhooks, create:
- Name: mortality_spike_alert
- Table: mortality
- Events: INSERT
- URL: https://[your-project].supabase.co/functions/v1/mortality-alert

Create similar edge functions and webhooks for:
- inventory_reorder_alert (fires when stock_level <= reorder_level on UPDATE)
- vaccination_due_alert (run on a scheduled cron, check next 24 hours)

Add android/app/google-services.json (from Firebase Console) and ios/Runner/GoogleService-Info.plist as documented in the FlutterFire setup guide at https://firebase.flutter.dev/docs/overview.
```

---

### Feature 4 — Full Payroll & Labour Management Module

**What it is and why it matters**

HatchlogMobile already tracks who the workers are (`farm_members` table) but has no concept of their pay. For an enterprise farm with 5–20 staff, wage management is as important as egg production. Workers do daily tasks — feeding, collection, cleaning — and earn daily or weekly wages. The owner needs to track: who worked each day, how many days they worked this cycle, what advances have been paid, and how much net payroll is owed at month end. This module adds attendance check-in/check-out, wage configuration, advance tracking, and a PDF payslip generator.

---

**Agent Prompt — Feature 4**

```
You are adding a Payroll & Labour Management module to HatchlogMobile.

CONTEXT:
- farm_members table exists in Supabase with: id, user_id, farm_id, role, joined_at
- local_users table exists in SQLite with: id, first_name, last_name, phone_number
- ManagementRepository already loads team members via _loadTeamMembers()
- PDF generation uses the pdf package (^3.12.0) — already installed
- App brand color: #145F3B

STEP 1: Create Supabase migration SQL (run manually in Supabase dashboard)

```sql
-- Worker wage configuration
CREATE TABLE IF NOT EXISTS worker_wage_config (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  farm_id text NOT NULL REFERENCES farms(id),
  user_id text NOT NULL REFERENCES users(id),
  daily_rate numeric NOT NULL DEFAULT 0,
  currency text NOT NULL DEFAULT 'GHS',
  pay_cycle text NOT NULL DEFAULT 'MONTHLY',  -- WEEKLY | BIWEEKLY | MONTHLY
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  UNIQUE (farm_id, user_id)
);

-- Daily attendance records
CREATE TABLE IF NOT EXISTS attendance_logs (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  farm_id text NOT NULL REFERENCES farms(id),
  user_id text NOT NULL REFERENCES users(id),
  log_date date NOT NULL,
  check_in_time timestamptz,
  check_out_time timestamptz,
  status text NOT NULL DEFAULT 'PRESENT',  -- PRESENT | ABSENT | HALF_DAY | LEAVE
  notes text,
  recorded_by text REFERENCES users(id),
  created_at timestamp NOT NULL DEFAULT now(),
  UNIQUE (farm_id, user_id, log_date)
);

-- Advance payments
CREATE TABLE IF NOT EXISTS payroll_advances (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  farm_id text NOT NULL REFERENCES farms(id),
  user_id text NOT NULL REFERENCES users(id),
  amount numeric NOT NULL,
  advance_date date NOT NULL,
  notes text,
  is_repaid bool NOT NULL DEFAULT false,
  repaid_at timestamp,
  created_at timestamp NOT NULL DEFAULT now()
);
```

STEP 2: Add SQLite migration in lib/core/storage/local_database.dart

In the _migrations list, add new migration entries for the three tables above with identical column structure using INTEGER/TEXT/REAL types. Mark them with is_synced INTEGER DEFAULT 0 and is_deleted INTEGER DEFAULT 0 for offline sync compatibility.

STEP 3: Create lib/features/payroll/data/payroll_models.dart

```dart
class WorkerWageConfig {
  const WorkerWageConfig({
    required this.userId, required this.farmId,
    required this.workerName, required this.dailyRate, required this.currency,
    required this.payCycle,
  });
  final String userId, farmId, workerName, currency, payCycle;
  final double dailyRate;
}

class AttendanceLog {
  const AttendanceLog({
    required this.id, required this.userId, required this.farmId,
    required this.logDate, required this.status, this.notes = '',
  });
  final String id, userId, farmId, status, notes;
  final DateTime logDate;
}

class PayrollAdvance {
  const PayrollAdvance({
    required this.id, required this.userId, required this.farmId,
    required this.amount, required this.advanceDate, this.notes = '', this.isRepaid = false,
  });
  final String id, userId, farmId, notes;
  final double amount;
  final DateTime advanceDate;
  final bool isRepaid;
}

class WorkerPayrollSummary {
  const WorkerPayrollSummary({
    required this.config,
    required this.daysWorked,
    required this.absentDays,
    required this.grossPay,
    required this.totalAdvances,
    required this.netPay,
    required this.attendanceLogs,
    required this.advances,
  });
  final WorkerWageConfig config;
  final int daysWorked, absentDays;
  final double grossPay, totalAdvances, netPay;
  final List<AttendanceLog> attendanceLogs;
  final List<PayrollAdvance> advances;
}
```

STEP 4: Create lib/features/payroll/data/payroll_repository.dart

Implement:
- Future<List<WorkerPayrollSummary>> loadPayrollForCycle(String farmId, DateTime periodStart, DateTime periodEnd)
- Future<void> recordAttendance(AttendanceLog log)
- Future<void> recordAdvance(PayrollAdvance advance)
- Future<void> saveWageConfig(WorkerWageConfig config)
- All methods write to local SQLite first, then queue for cloud sync

STEP 5: Create lib/presentation/payroll/payroll_screen.dart

Layout:
1. Period selector at top (DateRangePickerButton — default to current month)
2. Team list: each card shows worker name, days worked/total days, gross pay, advances deducted, net pay owed
3. Each card expands to show: attendance calendar, advance list, "Record Advance" button, "Print Payslip" button
4. FAB: "Mark Today's Attendance" — opens a bottom sheet with a list of all workers and PRESENT/ABSENT/HALF_DAY toggles

STEP 6: Create lib/features/payroll/data/payslip_pdf_service.dart

Generate a PDF payslip using the pdf package with:
- Header: farm name, "PAYSLIP", period dates
- Employee info: name, role, pay cycle
- Earnings table: days worked × daily rate = gross pay
- Deductions table: advances taken this period
- Net Pay section (bold, large font)
- Footer: "Generated by HatchLog Mobile"
- Share via share_plus

STEP 7: Add Payroll to the navigation

In UniversalMobileDashboard or ManagementDashboard, add a "Payroll" drawer item visible only to owner and manager roles (check widget.currentUser.role == UserRole.owner || UserRole.manager).
```

---

### Feature 5 — Procurement & Purchase Order Workflow

**What it is and why it matters**

The `suppliers` table exists, inventory exists, but there is currently no formal purchasing process. When a farm needs 50 bags of feed, an accountant either calls the supplier and manually enters an expense later, or simply forgets to update stock until it runs out. A Purchase Order (PO) workflow adds: create a PO → supplier delivers → receive goods (auto-update inventory) → generate supplier payment. This closes the loop between suppliers, inventory, and finance — which is critical for enterprise farms that spend millions of GHS per year on feed and medicine.

---

**Agent Prompt — Feature 5**

```
You are adding a Purchase Order (PO) and Procurement workflow to HatchlogMobile.

CONTEXT:
- suppliers table exists: id, farmId, name, phone, email, balanceOwed
- inventory table exists: id, farmId, itemName, stockLevel, unit, reorderLevel, costPerUnit
- financial_transactions table exists for recording payments
- App already has invoice PDF generation (InvoicePdfService) as a pattern to follow
- ManagementRepository pattern is the standard for data layer

STEP 1: Supabase SQL migration (run in Supabase dashboard)

```sql
CREATE TABLE IF NOT EXISTS purchase_orders (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  farm_id text NOT NULL REFERENCES farms(id),
  supplier_id text NOT NULL REFERENCES suppliers(id),
  po_number text NOT NULL,
  status text NOT NULL DEFAULT 'DRAFT',  -- DRAFT | SENT | PARTIAL | RECEIVED | CANCELLED
  order_date date NOT NULL,
  expected_date date,
  total_amount numeric NOT NULL DEFAULT 0,
  amount_paid numeric NOT NULL DEFAULT 0,
  notes text,
  created_by text REFERENCES users(id),
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  is_deleted bool NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS purchase_order_items (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  po_id text NOT NULL REFERENCES purchase_orders(id),
  inventory_id text REFERENCES inventory(id),
  description text NOT NULL,
  quantity_ordered numeric NOT NULL,
  quantity_received numeric NOT NULL DEFAULT 0,
  unit text NOT NULL,
  unit_cost numeric NOT NULL,
  total_cost numeric GENERATED ALWAYS AS (quantity_ordered * unit_cost) STORED
);

CREATE TABLE IF NOT EXISTS goods_receipts (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  po_id text NOT NULL REFERENCES purchase_orders(id),
  farm_id text NOT NULL,
  receipt_date date NOT NULL,
  received_by text REFERENCES users(id),
  notes text,
  created_at timestamp NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS goods_receipt_items (
  id text PRIMARY KEY DEFAULT gen_random_uuid()::text,
  receipt_id text NOT NULL REFERENCES goods_receipts(id),
  po_item_id text NOT NULL REFERENCES purchase_order_items(id),
  inventory_id text REFERENCES inventory(id),
  quantity_received numeric NOT NULL,
  batch_reference text
);
```

STEP 2: Add local SQLite tables

Mirror all 4 tables in LocalDatabase._migrations with identical columns + is_synced INTEGER DEFAULT 0.

STEP 3: Create lib/features/procurement/data/procurement_models.dart

Define: PurchaseOrderStatus enum, PurchaseOrderItem, PurchaseOrder, GoodsReceiptItem, GoodsReceipt. Each PurchaseOrder has: a computed amountDue = totalAmount - amountPaid, a computed isFullyReceived = allItems.every(i => i.quantityReceived >= i.quantityOrdered).

STEP 4: Create lib/features/procurement/data/procurement_repository.dart

Implement:
- Future<List<PurchaseOrder>> loadOpenOrders(String farmId)
- Future<PurchaseOrder> createPurchaseOrder(PurchaseOrder draft) — auto-generates po_number as "PO-{farmId.substring(0,4).toUpperCase()}-{DateTime.now().millisecondsSinceEpoch}"
- Future<void> receiveGoods(GoodsReceipt receipt) — this method does 4 things atomically:
  (a) Insert goods_receipt record
  (b) Insert goods_receipt_items records
  (c) UPDATE inventory.stockLevel += quantity_received for each item WHERE inventory_id is not null
  (d) UPDATE purchase_order.status = 'RECEIVED' if all items fully received, else 'PARTIAL'
  (e) UPDATE supplier.balanceOwed += purchase_order.amountDue
- Future<void> recordSupplierPayment(String poId, double amount) — decrements supplier.balanceOwed, inserts financial_transaction of type EXPENSE

STEP 5: Create lib/presentation/procurement/procurement_screen.dart

3-tab layout:
- Tab "Open POs": list of DRAFT/SENT/PARTIAL orders with status badges, supplier name, total, expected date. Tap to view detail. FAB: "New PO"
- Tab "Receive Goods": list of SENT/PARTIAL orders. Tap to open receive dialog where you enter actual received quantities per line item and tap "Confirm Receipt" which calls receiveGoods()
- Tab "Supplier Balances": list of suppliers sorted by balanceOwed descending, with "Record Payment" button on each

STEP 6: Add "Procurement" to navigation

Add to UniversalMobileDashboard drawer after Suppliers, visible to owner, manager, accountant roles.

STEP 7: Add reorder alert integration

After receiveGoods() completes, check if any inventory item's updated stockLevel is still <= reorderLevel. If so, show a SnackBar: "⚠️ ${itemName} is still below reorder level after receipt. Consider another PO."

Generate a PDF purchase order using the pdf package following the same pattern as InvoicePdfService, sharable via share_plus.
```

---

### Feature 6 — Export & Compliance Reporting Suite

**What it is and why it matters**

Ghana's poultry sector is subject to VAT (15%), NHIL (2.5%), and GetFund Levy (2.5%) on taxable supplies, plus PAYE on worker wages. Enterprise farms also need monthly management reports for bank loan compliance, investor reporting, and internal performance reviews. Right now the only exportable document is a single invoice. This feature adds a scheduled reporting engine that produces: Monthly P&L Statement (PDF), Inventory Audit Report (PDF), Batch Cost Ledger (PDF), and a Ghana Tax Summary (VAT/NHIL/GetFund) — all shareable via WhatsApp or email in one tap.

---

**Agent Prompt — Feature 6**

```
You are adding an Export & Compliance Reporting Suite to HatchlogMobile.

CONTEXT:
- pdf ^3.12.0 and printing ^5.14.3 are already installed
- share_plus ^13.1.0 is already installed
- ManagementRepository.loadSnapshot() provides all data needed
- ManagementRepository.loadAnalytics() (Feature 1) provides time-series data
- Ghana tax context: VAT = 15%, NHIL = 2.5%, GetFund = 2.5% (total 20% on taxable supplies)
- Currency: GHS, date format: DD-MM-YYYY

WHAT TO BUILD:

STEP 1: Create lib/features/reporting/report_models.dart

```dart
enum ReportType { monthlyPnl, inventoryAudit, batchCostLedger, taxSummary }

class ReportRequest {
  const ReportRequest({
    required this.type, required this.farmName,
    required this.periodStart, required this.periodEnd,
    required this.generatedBy,
  });
  final ReportType type;
  final String farmName, generatedBy;
  final DateTime periodStart, periodEnd;
}
```

STEP 2: Create lib/features/reporting/report_generator.dart

Implement a ReportGenerator class with method Future<Uint8List> generate(ReportRequest request, ManagementSnapshot snapshot).

Inside, switch on request.type and call private methods:

_buildMonthlyPnl(request, snapshot):
  - Page 1: Cover — Farm name, "Monthly P&L Statement", period, generated date, generated by
  - Page 2: Income section — table of all sales by payment method (CASH, MOMO, BANK TRANSFER) with subtotals
  - Page 3: Expenses section — table of expenses by category with subtotals
  - Page 4: Summary — Revenue, Expenses, Gross Profit, Net Profit, Profit Margin %

_buildInventoryAudit(request, snapshot):
  - Table with columns: Item Name, Category, Unit, Opening Stock (N/A), Closing Stock, Reorder Level, Status
  - Highlight REORDER rows in light red
  - Footer: total inventory items count, items below reorder level count

_buildBatchCostLedger(request, snapshot):
  - One section per batch from snapshot.analytics
  - Per batch: Bird count (initial → current), mortality rate, feed consumed, eggs collected, FCR proxy
  - Financial: Revenue allocated, expenses allocated (from snapshot.profitability), net profit per batch

_buildTaxSummary(request, snapshot):
  - Section: "Taxable Revenue" — list all sales with taxes
  - VAT = totalRevenue * 0.15
  - NHIL = totalRevenue * 0.025
  - GetFund = totalRevenue * 0.025
  - Total Tax Liability = totalRevenue * 0.20
  - Section: "Input Tax Credits" (not calculated — show note "Contact your tax advisor for input credits")
  - Section: "Net Tax Payable" — totalRevenue * 0.20
  - Disclaimer: "This is an estimated summary. Consult a qualified Ghana Revenue Authority-registered tax advisor."

Use brand color #145F3B for headers. Use PDF A4 format. Add page numbers to footer.

STEP 3: Create lib/presentation/reporting/reports_screen.dart

Layout: grid of 4 report cards. Each card shows:
- Report icon
- Report name
- Description (1 line)
- "Generate" button

Above the grid: a DateRangePicker for period selection (default: first day of current month to today).

On "Generate":
1. Show a CircularProgressIndicator overlay
2. Call ReportGenerator.generate()
3. On success: show a share sheet via Printing.sharePdf() (from printing package)
4. On error: show SnackBar with error message

STEP 4: Add Reports to navigation

In UniversalMobileDashboard drawer, add "Reports & Export" with icon Icons.summarize, visible only to owner, manager, accountant roles.

STEP 5: Connect the existing monthly P&L data

In ManagementRepository, add:

```dart
Future<Map<String, double>> loadRevenueByMethod(String farmId, DateTime from, DateTime to) async {
  final rows = await _localDatabase.rawLocalQuery(
    "SELECT payment_method, coalesce(sum(amount), 0) as total "
    "FROM financial_transactions WHERE farm_id = ? AND type = 'REVENUE' "
    "AND transaction_date BETWEEN ? AND ? AND is_deleted = 0 "
    "GROUP BY payment_method",
    [farmId, from.toIso8601String(), to.toIso8601String()],
  );
  return {for (final r in rows) r['payment_method'].toString(): _double(r['total'])};
}

Future<Map<String, double>> loadExpenseByCategory(String farmId, DateTime from, DateTime to) async {
  final rows = await _localDatabase.rawLocalQuery(
    "SELECT category, coalesce(sum(amount), 0) as total "
    "FROM financial_transactions WHERE farm_id = ? AND type = 'EXPENSE' "
    "AND transaction_date BETWEEN ? AND ? AND is_deleted = 0 "
    "GROUP BY category",
    [farmId, from.toIso8601String(), to.toIso8601String()],
  );
  return {for (final r in rows) r['category'].toString(): _double(r['total'])};
}
```

Use these in _buildMonthlyPnl() for accurate categorized breakdowns.
```

---

## Part 3 — Implementation Priority

| Priority | Feature | Why First |
|----------|---------|-----------|
| **1 — Do Now** | Analytics Dashboard (fl_chart) | Package already installed. Zero new dependencies. Data already exists in SQLite. Immediate visible value. |
| **2 — Do Next** | Export & Reporting Suite | pdf/printing/share_plus all already installed. No new backend. High demand from enterprise users. |
| **3 — Medium Term** | AI Farm Intelligence | Requires ANTHROPIC_API_KEY setup + http package. High value. Low complexity given the service wrapper above. |
| **4 — Medium Term** | Push Notifications | Requires Firebase project setup. Medium effort. Critical for enterprise operations. |
| **5 — Longer Term** | Procurement & PO Workflow | Requires 4 new Supabase tables + migrations. High complexity but critical for multi-supplier farms. |
| **6 — Longer Term** | Payroll & Labour | Requires 3 new tables + PDF payslips. High complexity, high value for farms with 10+ staff. |

---

## Part 4 — Database Additions Summary

| Feature | New Tables |
|---------|-----------|
| Push Notifications | `device_push_tokens` |
| Payroll | `worker_wage_config`, `attendance_logs`, `payroll_advances` |
| Procurement | `purchase_orders`, `purchase_order_items`, `goods_receipts`, `goods_receipt_items` |
| AI Intelligence | None (uses existing data) |
| Analytics Dashboard | None (uses existing data) |
| Reporting Suite | None (uses existing data) |

The first two enterprise features (Analytics + Reporting) require **zero new tables and zero new packages** — they use what is already there.


# Agent Prompt — HatchlogMobile Worker-First Dashboard Rebuild

Paste this whole prompt into Claude Code (or your coding agent) inside the **HatchlogMobile** Flutter repo.

---

```
You are rebuilding the mobile dashboard for HatchlogMobile, a Flutter offline-first poultry
farm app. The web companion app (PMS_HOST_V1_AB, Next.js + Prisma + Supabase) already has
mature data-entry forms, quick-add patterns, and a permission system. Your job is to:

1. Port the web's exact form fields, dropdown options, and quick-add UX patterns into mobile.
2. Build the finance "Log Expense" popup with batch-allocation logic, matching web exactly.
3. Build a permission-driven worker dashboard where every tab/module is filtered by the
   farm_member_permissions table — workers should only ever see what they're allowed to touch.
4. Add the web-only features that mobile is missing: Climate Control cards, Trash/Restore,
   license/subscription awareness, and a comprehensive farm report screen.

Read every section below fully before writing code. Field names, option lists, and validation
rules are taken directly from the web app's source — do not invent your own field names or
guess at dropdown values.

================================================================================
SECTION 1 — THE PERMISSION MODEL (filter every tab and page through this)
================================================================================

The web app's `UserPermission` table (mirrored in mobile's `farm_member_permissions` SQLite/
Supabase table) has this exact shape — 10 modules, each with a separate view/edit boolean:

  canViewFinance,   canEditFinance
  canViewInventory, canEditInventory
  canViewBatches,   canEditBatches      (= Livestock module)
  canViewSales,     canEditSales
  canViewEggs,      canEditEggs
  canViewFeeding,   canEditFeeding
  canViewHouses,    canEditHouses
  canViewMortality, canEditMortality
  canViewCustomers, canEditCustomers
  canViewTeam,      canEditTeam

RULE: a "view" flag controls whether the module/tab appears at all in the dashboard navigation.
An "edit" flag controls whether the "+" / quick-add / save buttons are rendered inside that
module. A worker with canViewEggs=true, canEditEggs=false sees the Eggs tab and can browse
records, but no "+" button appears anywhere on that screen.

STEP 1.1 — Create lib/core/permissions/farm_permissions.dart

```dart
class FarmPermissions {
  const FarmPermissions({
    this.canViewFinance = false, this.canEditFinance = false,
    this.canViewInventory = false, this.canEditInventory = false,
    this.canViewBatches = false, this.canEditBatches = false,
    this.canViewSales = false, this.canEditSales = false,
    this.canViewEggs = false, this.canEditEggs = false,
    this.canViewFeeding = false, this.canEditFeeding = false,
    this.canViewHouses = false, this.canEditHouses = false,
    this.canViewMortality = false, this.canEditMortality = false,
    this.canViewCustomers = false, this.canEditCustomers = false,
    this.canViewTeam = false, this.canEditTeam = false,
  });

  final bool canViewFinance, canEditFinance;
  final bool canViewInventory, canEditInventory;
  final bool canViewBatches, canEditBatches;
  final bool canViewSales, canEditSales;
  final bool canViewEggs, canEditEggs;
  final bool canViewFeeding, canEditFeeding;
  final bool canViewHouses, canEditHouses;
  final bool canViewMortality, canEditMortality;
  final bool canViewCustomers, canEditCustomers;
  final bool canViewTeam, canEditTeam;

  // Owner/Admin roles bypass permission checks entirely (full access)
  factory FarmPermissions.fullAccess() => const FarmPermissions(
    canViewFinance: true, canEditFinance: true,
    canViewInventory: true, canEditInventory: true,
    canViewBatches: true, canEditBatches: true,
    canViewSales: true, canEditSales: true,
    canViewEggs: true, canEditEggs: true,
    canViewFeeding: true, canEditFeeding: true,
    canViewHouses: true, canEditHouses: true,
    canViewMortality: true, canEditMortality: true,
    canViewCustomers: true, canEditCustomers: true,
    canViewTeam: true, canEditTeam: true,
  );

  factory FarmPermissions.fromMap(Map<String, dynamic> row) => FarmPermissions(
    canViewFinance: row['can_view_finance'] == 1 || row['can_view_finance'] == true,
    canEditFinance: row['can_edit_finance'] == 1 || row['can_edit_finance'] == true,
    canViewInventory: row['can_view_inventory'] == 1 || row['can_view_inventory'] == true,
    canEditInventory: row['can_edit_inventory'] == 1 || row['can_edit_inventory'] == true,
    canViewBatches: row['can_view_batches'] == 1 || row['can_view_batches'] == true,
    canEditBatches: row['can_edit_batches'] == 1 || row['can_edit_batches'] == true,
    canViewSales: row['can_view_sales'] == 1 || row['can_view_sales'] == true,
    canEditSales: row['can_edit_sales'] == 1 || row['can_edit_sales'] == true,
    canViewEggs: row['can_view_eggs'] == 1 || row['can_view_eggs'] == true,
    canEditEggs: row['can_edit_eggs'] == 1 || row['can_edit_eggs'] == true,
    canViewFeeding: row['can_view_feeding'] == 1 || row['can_view_feeding'] == true,
    canEditFeeding: row['can_edit_feeding'] == 1 || row['can_edit_feeding'] == true,
    canViewHouses: row['can_view_houses'] == 1 || row['can_view_houses'] == true,
    canEditHouses: row['can_edit_houses'] == 1 || row['can_edit_houses'] == true,
    canViewMortality: row['can_view_mortality'] == 1 || row['can_view_mortality'] == true,
    canEditMortality: row['can_edit_mortality'] == 1 || row['can_edit_mortality'] == true,
    canViewCustomers: row['can_view_customers'] == 1 || row['can_view_customers'] == true,
    canEditCustomers: row['can_edit_customers'] == 1 || row['can_edit_customers'] == true,
    canViewTeam: row['can_view_team'] == 1 || row['can_view_team'] == true,
    canEditTeam: row['can_edit_team'] == 1 || row['can_edit_team'] == true,
  );
}
```

STEP 1.2 — Create lib/core/permissions/permissions_repository.dart

```dart
class PermissionsRepository {
  PermissionsRepository({required LocalDatabase localDatabase}) : _localDatabase = localDatabase;
  final LocalDatabase _localDatabase;

  Future<FarmPermissions> loadForUser(AppUser user) async {
    if (user.role == UserRole.owner || user.role == UserRole.admin) {
      return FarmPermissions.fullAccess();
    }
    final rows = await _localDatabase.rawLocalQuery(
      'SELECT * FROM farm_member_permissions WHERE user_id = ? AND farm_id = ? LIMIT 1',
      [user.id, user.activeFarmId],
    );
    if (rows.isEmpty) return const FarmPermissions(); // deny-by-default
    return FarmPermissions.fromMap(rows.first);
  }
}
```

This repository must be wired into AppServices.bootstrap() and passed down to the dashboard,
exactly the way ManagementRepository is passed today.

STEP 1.3 — Define the module-to-permission map

Create lib/presentation/worker/worker_module_definitions.dart with a single source of truth
listing every module, its permission keys, icon, route, and a short worker-facing label:

```dart
enum WorkerModule {
  eggs, feeding, mortality, houses, sales, inventory, finance, customers, team,
}

class WorkerModuleDef {
  const WorkerModuleDef({
    required this.module, required this.label, required this.icon,
    required this.canView, required this.canEdit,
  });
  final WorkerModule module;
  final String label;
  final IconData icon;
  final bool canView;
  final bool canEdit;
}

List<WorkerModuleDef> buildVisibleModules(FarmPermissions p) => [
  WorkerModuleDef(module: WorkerModule.eggs, label: 'Eggs', icon: Icons.egg,
      canView: p.canViewEggs, canEdit: p.canEditEggs),
  WorkerModuleDef(module: WorkerModule.feeding, label: 'Feeding', icon: Icons.grass,
      canView: p.canViewFeeding, canEdit: p.canEditFeeding),
  WorkerModuleDef(module: WorkerModule.mortality, label: 'Mortality', icon: Icons.healing,
      canView: p.canViewMortality, canEdit: p.canEditMortality),
  WorkerModuleDef(module: WorkerModule.houses, label: 'Houses', icon: Icons.home_work,
      canView: p.canViewHouses, canEdit: p.canEditHouses),
  WorkerModuleDef(module: WorkerModule.sales, label: 'Sales', icon: Icons.point_of_sale,
      canView: p.canViewSales, canEdit: p.canEditSales),
  WorkerModuleDef(module: WorkerModule.inventory, label: 'Inventory', icon: Icons.inventory_2,
      canView: p.canViewInventory, canEdit: p.canEditInventory),
  WorkerModuleDef(module: WorkerModule.finance, label: 'Finance', icon: Icons.attach_money,
      canView: p.canViewFinance, canEdit: p.canEditFinance),
  WorkerModuleDef(module: WorkerModule.customers, label: 'Customers', icon: Icons.people,
      canView: p.canViewCustomers, canEdit: p.canEditCustomers),
  WorkerModuleDef(module: WorkerModule.team, label: 'Team', icon: Icons.groups,
      canView: p.canViewTeam, canEdit: p.canEditTeam),
].where((m) => m.canView).toList();
```

================================================================================
SECTION 2 — BUILD THE WORKER'S OWN DAILY DASHBOARD
================================================================================

The current UniversalMobileDashboard tries to serve every role from one screen. Replace this
with a dedicated WorkerHomeScreen built specifically for daily field use — fast taps, big
buttons, minimal scrolling, nothing the worker isn't permitted to see.

STEP 2.1 — Create lib/presentation/worker/worker_home_screen.dart

Layout, top to bottom:
1. AppBar: farm name + worker's first name + a connectivity dot (green = online, grey = offline,
   amber = syncing). Tapping the dot shows pending sync count from WorkerInputSink.
2. "Today" summary strip — 3 stat chips computed from local SQLite for TODAY only: Eggs
   Collected, Feed Used (bags), Mortality Count. Only show a chip if the corresponding
   canViewX permission is true.
3. A responsive grid of module cards built from `buildVisibleModules(permissions)`. Each card
   shows the module icon, label, and (if canEdit is true) a "+" quick-add affordance baked
   directly into the card — tapping the card body navigates to the module's list screen,
   tapping the "+" corner opens the quick-add bottom sheet immediately without an extra screen.
4. Bottom: a single persistent FAB labeled "Quick Log" that opens a bottom sheet listing only
   the editable modules (canEdit == true) as big tappable rows — this is the fastest path for
   a worker who just wants to log something without browsing.

STEP 2.2 — Route HatchLogApp to this screen for non-privileged roles

In lib/app/hatchlog_app.dart, after loading permissions:
```dart
final permissions = await widget.services.permissionsRepository.loadForUser(user);
final isPrivileged = user.role == UserRole.owner || user.role == UserRole.admin || user.role == UserRole.manager;

Widget homeScreen = isPrivileged
    ? UniversalMobileDashboard(currentUser: user, permissions: permissions, ...)
    : WorkerHomeScreen(currentUser: user, permissions: permissions, ...);
```

Accountants get UniversalMobileDashboard too, but with finance/sales/customers/suppliers
modules only, driven by the same permission filtering — do not hardcode role checks inside
UniversalMobileDashboard anymore; drive everything off `buildVisibleModules(permissions)`.

================================================================================
SECTION 3 — QUICK-ADD PATTERNS (ported exactly from web)
================================================================================

The web app's quick-add pattern (see QuickMortalityLogger.tsx) is: show a grid of cards (one
per active batch), each card has a small "+" button, tapping it opens a Dialog pre-scoped to
that batch. Replicate this exactly for Eggs, Feeding, and Mortality.

STEP 3.1 — Create lib/presentation/worker/widgets/quick_add_batch_grid.dart

A reusable widget:
```dart
class QuickAddBatchGrid extends StatelessWidget {
  const QuickAddBatchGrid({
    super.key, required this.batches, required this.accentColor,
    required this.icon, required this.onTapAdd, required this.emptyMessage,
  });
  final List<BatchSummary> batches; // {id, batchLabel, livestockType, currentCount}
  final Color accentColor;
  final IconData icon;
  final void Function(BatchSummary batch) onTapAdd;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (batches.isEmpty) {
      return Center(child: Text(emptyMessage, style: TextStyle(color: Colors.grey, fontStyle: FontStyle.italic)));
    }
    return GridView.builder(
      shrinkWrap: true,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2, childAspectRatio: 1.3, crossAxisSpacing: 10, mainAxisSpacing: 10,
      ),
      itemCount: batches.length,
      itemBuilder: (context, index) {
        final batch = batches[index];
        return Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text(batch.batchLabel, style: const TextStyle(fontWeight: FontWeight.bold)),
                  InkWell(
                    onTap: () => onTapAdd(batch),
                    child: CircleAvatar(radius: 16, backgroundColor: accentColor.withOpacity(0.15),
                      child: Icon(Icons.add, size: 18, color: accentColor)),
                  ),
                ]),
                const Spacer(),
                Text('${batch.currentCount} birds', style: const TextStyle(fontSize: 13, color: Colors.grey)),
              ],
            ),
          ),
        );
      },
    );
  }
}
```

Use this same widget for Eggs (accentColor amber, icon Icons.egg), Feeding (accentColor green,
icon Icons.grass), and Mortality (accentColor red, icon Icons.dangerous).

================================================================================
SECTION 4 — EGG ENTRY FORM (exact fields from web's EggForm.tsx)
================================================================================

Create lib/presentation/eggs/egg_quick_add_sheet.dart as a DraggableScrollableSheet with
these EXACT fields and behaviors (copied from web):

FIELDS:
- batchId — pre-filled from the tapped batch card, not user-editable in quick-add mode
- Logging Mode toggle (2-button segmented control): "Individual Eggs" | "Crates (30/ea)"
  - Individual mode: single numeric input "Total Eggs Collected"
  - Crates mode: two numeric inputs "Number of Crates" and "Remainder Eggs" (remainder capped
    at 29, max value, since 30 remainder = 1 more crate); eggsCollected = crates*30 + remainder
- Sorting Status toggle (2-button): "Unsorted" | "Sorted"
  - If Unsorted: show "General Egg Size" dropdown with options Small / Medium / Large
    (maps to qualityGrade field: SMALL, MEDIUM, LARGE)
  - If Sorted: show 3 numeric inputs — Small, Medium, Large — with a running "Allocated: X / Y"
    badge against eggsCollected. Block submission if sum exceeds eggsCollected (validation
    error: "Sum of sizes exceeds total eggs collected").
- Unusable Eggs (Damaged/Cracked) — numeric input, capped at eggsCollected, optional
- Log Date — date picker, defaults to today

VALIDATION (must match web):
- eggsCollected required, > 0
- if isSorted, smallCount+mediumCount+largeCount must not exceed eggsCollected
- unusableCount must not exceed eggsCollected

DATA WRITE: call WorkerInputSink.enqueueWorkerInput() with type EGG_PRODUCTION and a payload
matching the Supabase egg_production columns: batch_id, eggs_collected, unusable_count,
quality_grade, is_sorted, small_count, medium_count, large_count, log_date.

================================================================================
SECTION 5 — FEEDING ENTRY FORM (exact fields from web's FeedForm.tsx)
================================================================================

Create lib/presentation/feeding/feeding_quick_add_sheet.dart:

FIELDS:
- Batch — pre-filled from tapped card (not editable in quick-add)
- Feed Type dropdown — a COMBINED list built from two sources, exactly like web:
  - Inventory items prefixed "[Inventory] {itemName}" → value tag `inv_{id}`
  - Feed formulations prefixed "[Formulation] {name}" → value tag `form_{id}`
  This lets a worker pick either a raw inventory feed bag OR a custom mixed formulation.
  If both lists are empty, show the same fallback the web does: a message "No Feed Inventory
  or Formulations!" with two buttons — "Go to Inventory" and "Create Formulation" — routing
  to those respective screens instead of showing a broken form.
- Amount Consumed (Bags) — numeric input, step 0.01
  - BELOW the input, render 4 quick-tap chips exactly like web: "1/4 Bag", "1/2 Bag",
    "3/4 Bag", "1 Bag" mapping to values 0.25, 0.5, 0.75, 1.0 — tapping one fills the field
    instantly without typing. This is the single most important quick-add detail to replicate;
    workers feed multiple houses per day and should never have to type a decimal.
- Log Date — date picker, defaults to today

DATA WRITE: enqueueWorkerInput() type FEEDING with payload: batch_id, feed_type_id (nullable,
only if inv_ prefix), formulation_id (nullable, only if form_ prefix), amount_consumed, log_date.

================================================================================
SECTION 6 — MORTALITY / QUARANTINE ENTRY FORM (exact fields + reason taxonomy from web)
================================================================================

Create lib/presentation/mortality/mortality_quick_add_sheet.dart:

FIELDS:
- Batch — pre-filled from tapped card
- Health Type toggle (2-button): "Dead" (red, Icons.dangerous) | "Sick" (amber, Icons.healing)
  This toggle is HIDDEN if the parent screen already locked a default type (e.g. the
  Mortality tab always opens with Dead pre-selected and hidden, the Quarantine tab opens with
  Sick pre-selected and hidden) — matching web's defaultHealthType behavior exactly.
- Count — numeric input, label changes to "Mortality Count" (Dead) or "Sickness Count" (Sick).
  Validate against batch.currentCount — block if count exceeds birds remaining in that batch
  ("Cannot exceed current bird count").
- IF Health Type == Sick: show "Isolation Room" dropdown populated from existing isolation
  rooms, PLUS an "Add New Room" option at the bottom of the list. If selected, reveal two
  inline fields: "New Room Name" and "New Room Capacity" to create it inline before saving.
- Cause Category dropdown — use this EXACT taxonomy from web (do not invent your own):

```dart
const Map<String, List<String>> mortalityReasons = {
  'Disease': ['Newcastle disease', 'Avian influenza', 'Gumboro', "Marek's disease",
              'Salmonellosis', 'Fowl cholera', 'Colibacillosis', 'Coccidiosis', 'Worm infestation'],
  'Environmental': ['Heat stress', 'Cold stress', 'Poor ventilation', 'High ammonia', 'Overcrowding'],
  'Nutrition': ['Malnutrition', 'Vitamin deficiency', 'Moldy feed', 'Poor-quality feed'],
  'Water Issues': ['Dirty water', 'Dehydration', 'Water system failure'],
  'Parasites': ['Mites', 'Lice', 'Ticks', 'Worms'],
  'Management Error': ['Poor vaccination', 'Mixing age groups', 'Rough handling', 'Poor biosecurity'],
  'Toxicity': ['Aflatoxin', 'Chemical poisoning', 'Drug overdose'],
  'Predators': ['Dog attack', 'Snake attack', 'Bird attack'],
  'Stress': ['Transport stress', 'Noise stress', 'Environmental change'],
  'Brooding': ['Wrong temperature', 'Weak chicks', 'Poor brooding care'],
  'Genetic': ['Weak breed', 'Birth defect'],
  'Injury/Accident': ['Cannibalism', 'Trampling', 'Equipment injury'],
  'Unknown': ['Unknown cause yet'],
  'Other': ['Other'],
};
```
  Render as TWO chained dropdowns: first "Category" (the map's keys), then "Specific Cause"
  (the chosen category's value list) — this cascading-select pattern is what web does, and
  it's far faster for a worker than typing free text.

DATA WRITE: enqueueWorkerInput() type MORTALITY with payload: batch_id, count, health_type
(DEAD/SICK), category, sub_category, isolation_room_id (nullable), log_date.

================================================================================
SECTION 7 — INVENTORY QUICK-ADD (exact fields from web's InventoryForm.tsx)
================================================================================

Create lib/presentation/inventory/inventory_quick_add_sheet.dart:

FIELDS:
- Item Name — text input, required
- Stock Level — numeric, step 0.01, min 0
- Unit — text input (free text, web default is "bags")
- Category dropdown — EXACT options from web: Feed, Medicine, Equipment, Other
  (values: feed, medicine, equipment, other)

This is a simple create/edit form, no batch context needed.

================================================================================
SECTION 8 — FINANCE "LOG EXPENSE" POPUP (exact fields + allocation logic from web's
ExpenseForm.tsx — this is the most complex form in the whole app, build it carefully)
================================================================================

Create lib/presentation/finance/log_expense_sheet.dart, opened from a "Log Expense" button
visible only when canEditFinance == true. This is a full-screen modal sheet, not a small
popup, because of the allocation table below.

CORE FIELDS:
- Category dropdown — EXACT options from web: FEED, MEDICATION, EQUIPMENT, LABOR, UTILITIES,
  TRANSPORT, MAINTENANCE, OTHER. Default: FEED.
- Amount (GHS) — numeric input, step 0.01, min 0, required
- Date — datetime picker (date AND time, web uses datetime-local), defaults to now
- Reference / Receipt — optional text input, placeholder "Ref-001"
- Description — optional text input

BATCH ALLOCATION TOGGLE (this is the unique web pattern — replicate exactly):
A toggle switch labeled "Allocate this expense across multiple batches" with helper text
showing "{N} active batches available". When OFF, the expense is logged as a single farm-wide
cost. When ON, reveal:

1. A 2-button mode selector: "Percentage" | "Amount"
2. A dynamic list of allocation rows, starting with 2 empty rows. Each row has:
   - A batch dropdown (cannot select the same batch twice — disable already-selected batches
     in other rows' dropdowns)
   - A numeric value input (suffixed with "%" in Percentage mode, "₵" in Amount mode)
   - A delete button (disabled if it's the only remaining row)
3. An "Add Batch Allocation" button to append more rows
4. A live balance badge showing one of:
   - "Balanced at 100%" (green, percentage mode, sum == 100)
   - "Balanced at GH₵ {amount}" (green, amount mode, sum == total expense amount)
   - "{+/-}{delta}% remaining" (amber, percentage mode, not yet balanced)
   - "GH₵ {delta} {remaining|over}" (amber, amount mode, not yet balanced)
   - "Duplicate batch selected" (red, if any batch appears in 2+ rows)
   - "Complete every allocation row" (red, if any row missing batch or value)

SUBMIT VALIDATION (must match web exactly):
- amount > 0 required
- if allocation toggle is ON: every row must have a batch selected AND a value > 0, no
  duplicate batches, and the allocation must be balanced (100% total in Percentage mode,
  or exactly equal to the expense amount in Amount mode, within 1 cent / 0.01% tolerance)
- the submit button must be disabled until canSubmit is true — do not allow a tap-through
  that silently fails

DATA SHAPE TO WRITE (matches web's createExpense() call and Supabase Expense/ExpenseAllocation
tables):
```
{
  amount: double,
  category: String,            // one of the 8 enum values above
  description: String?,
  expenseDate: DateTime,
  reference: String?,
  allocationMode: 'PERCENTAGE' | 'AMOUNT' | null,
  allocations: [
    { batchId: String, percentage: double? /* if PERCENTAGE mode */, amount: double? /* if AMOUNT mode */ }
  ]
}
```
Write the parent expense row to local `expenses` table (financial_transactions equivalent),
then write each allocation row to a local `expense_allocations` table, then queue both for
sync via WorkerInputSink. If the expense_allocations table doesn't exist yet in
local_database.dart migrations, add it with columns matching the Expense/ExpenseAllocation
Prisma models: id, expense_id, batch_id, farm_id, allocated_amount, allocation_percentage,
created_at, is_synced.

================================================================================
SECTION 9 — SALES ENTRY FORM (multi-line cart pattern from web's SalesForm.tsx)
================================================================================

Mobile's current SaleEntryScreen is a single-product, single-line form. Web supports a
multi-line cart with mixed product types. Upgrade mobile's sale screen to match:

FIELDS:
- Customer dropdown — options: "Walk-in Customer" (empty value) + all saved customers
- Sale Date & Time — datetime picker, defaults to now
- Line items (repeatable, start with 1 row), each row has:
  - Product Type selector (3 options): Inventory | Livestock | Custom
    - Custom is ONLY available if the worker has price-override rights (canEditSales should
      map here — workers without override rights cannot select Custom or change unit price)
  - Product dropdown — populated from inventory OR livestock depending on type selected;
    selecting a product auto-fills description and unit price from that product's base price
    (sellingPrice for inventory, or initialCostActual/initialCount for livestock)
  - Quantity — integer input, must not exceed available stock (inventory.stockLevel) or
    available birds (livestock.currentCount) — validate and show inline error referencing
    the exact product name and remaining quantity, e.g. "Layer Mash only has 12 available"
  - Unit Price — read-only for workers without override rights (locked to base price);
    editable for managers/owners with override rights
  - Remove row button (disabled if it's the last row)
- "Add Item" button to append another line
- Discount — only visible/editable if price-override rights are present; flat or percentage
  toggle, same balance-style UX as the expense allocation
- Total Cash Received — numeric input. If the worker has no override rights, this MUST equal
  the computed total exactly (locked-price till), surfaced as a validation error otherwise:
  "Cash received must equal the locked sale total"

DATA WRITE: build the order/sale + sale_items payload matching web's createOrder() call:
customerId (nullable), discountAmount, totalCashReceived, orderDate, items: [{ description,
quantity, unitPrice, inventoryId?, livestockId? }]. Queue through WorkerInputSink as today,
but extend LocalSalesQueue to support multiple line items per sale instead of one.

================================================================================
SECTION 10 — PORT THE WEB-ONLY FEATURES MOBILE IS MISSING
================================================================================

10.1 — Climate Control cards (web: src/app/dashboard/climate/page.tsx)

Create lib/presentation/houses/climate_control_screen.dart. For every house, render a card
with two stat tiles side by side: Temperature (°C, amber theme, thermometer icon) and
Humidity (%, blue theme, droplet icon), pulled from the houses table's currentTemperature
and currentHumidity columns (already present in local SQLite per the schema). Below the
tiles, show capacity info. This requires zero new backend work — the columns already exist,
they're simply not rendered anywhere in mobile today. Gate this screen behind canViewHouses.

10.2 — Trash / Data Recovery Center (web: src/app/dashboard/settings/trash/page.tsx)

Create lib/presentation/settings/trash_screen.dart, visible ONLY to Owner/Manager roles
(matching web's exact restriction — do not show this to workers or accountants). Query every
local table for rows where is_deleted = 1, grouped by table/module, and list them with a
"Restore" button per row that flips is_deleted back to 0 and re-queues the row for sync.
Add this as a Settings sub-page, not a main dashboard tab.

10.3 — Subscription/License Awareness

Mobile currently has zero concept of the web app's SubscriptionTier (BASIC/STANDARD/PREMIUM)
or DeviceRegistration table. At minimum, add a read-only check: on app boot, query the
farm's subscriptionTier and the device's registration status from Supabase (when online), and
if the subscription is expired or the device isn't registered, show a non-dismissible banner
("Your farm's subscription needs renewal — contact your farm owner") rather than silently
continuing to operate. Do not block offline functionality entirely — this is a soft warning,
not a hard lockout, since workers in the field with no signal must still be able to log data.

10.4 — Comprehensive Farm Report screen (web: generateComprehensiveFarmReport)

Create lib/presentation/reports/farm_report_screen.dart with a date-range picker (default:
last 30 days, matching web's default) and a "Generate Report" button producing a PDF
comparable to web's comprehensive report — covering revenue, expenses, batch performance,
and inventory status for the selected period. Gate behind canViewFinance. Use the existing
pdf/printing packages already in pubspec.yaml; no new dependencies needed.

================================================================================
SECTION 11 — FINAL WIRING CHECKLIST
================================================================================

- [ ] AppServices.bootstrap() constructs and exposes PermissionsRepository
- [ ] HatchLogApp loads FarmPermissions immediately after user activation, before routing
- [ ] WorkerHomeScreen renders only modules where canView* is true
- [ ] Every quick-add "+" button is hidden when the matching canEdit* is false
- [ ] UniversalMobileDashboard (for owner/admin/manager/accountant) now derives its module
      list from buildVisibleModules(permissions) instead of hardcoded role checks
- [ ] SessionWatcher re-fetches permissions (not just role) on its poll cycle, so a permission
      change made on web reflects in the mobile UI within one poll interval without requiring
      a full logout — call PermissionsRepository.loadForUser() inside SessionWatcher._check()
      and notify the dashboard to rebuild its module list if permissions changed, even if the
      role itself didn't change
- [ ] All new quick-add sheets write through WorkerInputSink so offline queuing still works
- [ ] expense_allocations table added to local_database.dart migrations
- [ ] Climate Control, Trash, and Farm Report screens added to navigation, permission-gated
- [ ] Run flutter test after wiring to confirm no regressions in existing sync/auth tests
```

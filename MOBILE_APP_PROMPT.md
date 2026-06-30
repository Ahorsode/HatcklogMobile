# MOBILE APP PARITY PROMPT — Poultry PMS (Flutter)

> **Purpose:** Mirror the web app features implemented in the latest finance, inventory, health, and executive dashboard work. Use Supabase/Prisma-backed tables with the same business rules.

---

## 1. Executive Summary Dashboard (Premium Owner)

**Web files:** `src/components/dashboard/ExecutiveDashboard.tsx`, `src/lib/analytics/executive-metrics.ts`, `src/lib/actions/dashboard-actions.ts`

### What changed
Static placeholder cards were replaced with live farm data.

### API / data shape
Extend the mobile dashboard payload (or create `getExecutiveDashboard()`) to return:

```typescript
{
  executiveStats: {
    totalProfit: number        // last 7d revenue - last 7d expenses
    profitTrend: number        // % change vs previous 7d revenue
    globalFcr: number          // average FCR across active batches with data
    totalDebt: number
    supplierDebt: number
    customerDebt: number
    activeLivestock: number
    mortalityRate: number
  },
  strategicPriorities: Array<{
    title: string
    detail: string
    type: 'finance' | 'stock' | 'performance'
  }>,
  revenueVelocityData: Array<{
    date: string               // YYYY-MM-DD
    revenue: number            // daily sales + orders
    target: number             // rolling average of non-zero days in window
  }>
}
```

### Strategic Priorities logic

| Priority | Source | Rule |
|----------|--------|------|
| **Supplier Payment Due** | `suppliers` | Highest `balance_owed > 0`. Detail: `Debt to {name} — {amount} outstanding` |
| **Inventory Shortfall** | `inventory` + `daily_feeding_logs` | Feed items (`category` in feed/FEED/FEEDS/FEED_RAW/FEED_FINISHED). Sum consumption last 7 days per `feed_type_id`. If `stock_level < avg_daily * 2` (or `< 500` when no logs), flag. Sort by lowest hours-of-reserve. |
| **Batch Optimization** | `livestock` + logs | Active batches only. Compute FCR per batch (see below). Pick worst batch where `fcr > target`. Detail: `{batchName} FCR {fcr} (Target {target})` |

### FCR calculation (reuse web logic)
**File:** `src/lib/analytics/batch-performance.ts`

- **Layers:** FCR = total feed / total eggs collected
- **Broilers/others:** FCR = total feed / biomass gain  
  Biomass gain = `(latest_avg_weight - initial_avg_weight) * current_count`
- **Targets:** Layer 1.70, Broiler 1.80, default 2.00

### Revenue Velocity chart
- Bar chart: daily revenue (sales + orders) for last 7 days
- Line overlay: average of non-zero revenue days in that window
- Empty state when no finance activity in period

### Permissions
- Finance metrics require `can_view_finance`
- Inventory shortfall requires `can_view_inventory`
- FCR batch priority requires `can_view_batches`
- Screen visible only for **OWNER** with **PREMIUM** subscription (match web)

---

## 2. Batch Finance Allocation Rules

**Web files:** `src/lib/analytics/batch-finance.ts`, `src/lib/analytics/batch-consumption-finance.ts`

### Allocation layers (in order)

1. **Initial investment** — 100% to owning batch (`initial_cost_actual`, `initial_cost_carriage`, `initial_cost_other` on `livestock`)
2. **Direct expenses** — expenses with `batch_id` set → 100% to that batch
3. **Allocated expenses** — rows in `expense_allocations` → 100% to listed batch
4. **Consumption (feed & medication)** — from actual usage, not headcount:
   - Parse expenses whose description starts with `Inventory Purchase:` or `Health stock cost:`
   - Match to feeding logs (`feed_type_id`, `amount_consumed`) and completed health schedules (`vaccination_schedules`, `medication_schedules` with `status = COMPLETED`)
   - Batch share = `(batch usage / total farm usage for that item) * expense amount`
5. **General (headcount split)** — remaining farm-wide expenses (`batch_id` null, no allocations, not consumption-tagged) split by `current_count / total_active_headcount`

### Mobile UI
Flock/batch finance charts should show stacked layers:
**Initial | Operating | Consumption | General | Revenue**

**Important:** Feeding logs must set `batch_id` for accurate feed allocation. Without it, consumption falls back to headcount.

---

## 3. Inventory — Active vs Used Up + Usage History

**Web files:** `src/lib/actions/inventory-actions.ts`, `src/app/dashboard/inventory/[id]/`, `InventoryView.tsx`

### List filters
```typescript
getAllInventory({ filter: 'active' | 'used_up' })
getUsedUpInventoryCount()
```

- **active:** `stock_level > 0` AND not depleted
- **used_up:** `stock_level <= 0` OR one-time health item fully consumed

### Usage history page (`/dashboard/inventory/[id]`)
```typescript
getInventoryItemWithUsage(id) → {
  item: Inventory,
  usageEvents: Array<{
    date: Date
    batchName: string
    amount: number
    source: 'feeding_log' | 'vaccination' | 'medication'
  }>
}
```

Sources:
- `daily_feeding_logs` where `feed_type_id = item.id`
- Completed `vaccination_schedules` / `medication_schedules` matching inventory item name

### Mobile UX
- Tabs: **In stock** | **Used up** (badge count on Used up)
- Tap row → detail screen with usage timeline
- Hide used-up items from health/vaccination pickers

---

## 4. Health — ONE_TIME Item Depletion

**Web file:** `src/lib/actions/health-actions.ts`

### Rules
When a vaccination/medication schedule is marked **COMPLETED**:

| `usage_type` | Stock behavior |
|--------------|----------------|
| `ONE_TIME` | Set inventory `stock_level = 0` immediately (single-use vial) |
| `QUANTITY` | Decrement `stock_level` by schedule `quantity` |

### Additional rules
- Block scheduling if ONE_TIME item already completed or stock is 0
- `getHealthInventory()` excludes used-up ONE_TIME items
- Reverting COMPLETED → PENDING/CANCELLED restores stock
- Create/update inventory: ONE_TIME health items capped at **stock = 1**

---

## 5. Database Tables Reference

| Feature | Tables |
|---------|--------|
| Executive debt | `suppliers.balance_owed`, `customers.balance_owed` |
| Revenue trend | `sales`, `orders` (last 7 days by date) |
| Feed shortfall | `inventory`, `daily_feeding_logs` |
| FCR | `livestock`, `daily_feeding_logs`, `egg_production`, `weight_records` |
| Batch finance | `expenses`, `expense_allocations`, `livestock`, feeding + health logs |
| Inventory usage | `inventory`, `daily_feeding_logs`, `vaccination_schedules`, `medication_schedules` |

All queries must scope by `farm_id` and respect RLS / `$withFarmContext` patterns from web.

---

## 6. Suggested Mobile Implementation Order

1. Batch finance allocation engine (shared Dart service mirroring `batch-finance.ts`)
2. Inventory active/used-up tabs + usage detail screen
3. ONE_TIME health depletion on schedule completion
4. Executive Summary with Strategic Priorities + Revenue Velocity chart
5. Wire finance charts on flock detail and analytics compare screens

---

## 7. Web Reference Map

| Mobile feature | Primary web reference |
|----------------|----------------------|
| Executive dashboard | `ExecutiveDashboard.tsx`, `executive-metrics.ts` |
| Batch P&L | `batch-finance.ts`, `FlockCharts.tsx` |
| Analytics compare | `analytics-actions.ts`, `BatchComparison.tsx` |
| Inventory tabs | `inventory-actions.ts`, `InventoryView.tsx` |
| Health depletion | `health-actions.ts` |

---

## 8. Testing Checklist

- [ ] Supplier with highest debt appears in Strategic Priorities
- [ ] Feed item below 48h reserve (from 7-day consumption) triggers Inventory Shortfall
- [ ] Worst FCR batch above target appears in Batch Optimization
- [ ] Revenue Velocity bars match daily sales+orders totals
- [ ] ONE_TIME vaccine depletes to 0 after one completed use
- [ ] Used-up inventory hidden from health picker but visible in Used up tab
- [ ] Batch finance: feed logged to batch A allocates 100% of that feed cost to batch A

# HatchLog Mobile Mapping

This mobile project was mapped against the web repository at
`C:/Users/ahors/hosting_pfms/poultry-pms`.

## Web Schema Sources

- Prisma schema: `prisma/schema.prisma`
- Worker web UI: `src/components/dashboard/WorkerDashboard.tsx`
- Egg writes: `src/lib/actions/egg-actions.ts`
- Feed writes: `src/lib/actions/feed-actions.ts`
- Mortality writes: `src/lib/actions/batch-actions.ts`
- Finance writes: `src/lib/actions/expense-actions.ts` and
  `src/lib/actions/financial-transaction-actions.ts`

## Core Web Tables

| Domain | Prisma model | Supabase table |
| --- | --- | --- |
| Users | `User` | `users` |
| Farms | `Farm` | `farms` |
| Team roles | `FarmMember` | `farm_members` |
| Permissions | `UserPermission` | `user_permissions` |
| Houses | `House` | `houses` |
| Batches/livestock | `Livestock` | `batches` |
| Inventory/feed stock | `Inventory` | `inventory` |
| Egg logs | `EggProduction` | `egg_production` |
| Feed logs | `FeedingLog` | `daily_feeding_logs` |
| Mortality | `HealthMortality` | `mortality` |
| Expenses | `Expense` | `expenses` |
| Ledger | `FinancialTransaction` | `financial_transactions` |

## Mobile Local Cache

The SQLite database in `lib/core/storage/local_database.dart` mirrors the
core tables above for offline reads and reconciliation. Worker writes go into
`pending_sync_inputs` immediately with `is_synced = 0`, then the sync runner
dispatches them to the canonical web tables:

- `egg_collection` -> `egg_production`
- `feed_usage` -> `daily_feeding_logs`
- `mortality` -> `mortality`

Each queued payload is stamped with:

- `farm_id`
- `batch_id`
- `user_id`
- `created_at`

## Security Notes

The mobile app reads only `SUPABASE_URL` and `SUPABASE_ANON_KEY` or
`SUPABASE_PUBLISHABLE_KEY` from the local mobile `.env`. Server-only values
such as `DATABASE_URL`, `DIRECT_URL`, and auth secrets must never be shipped
inside the mobile app bundle.

The current web app uses NextAuth plus Prisma, with farm isolation applied
through Prisma transaction context (`app.current_user_id` and
`app.current_farm_id`). Direct Supabase mobile writes require Supabase Data API
access and RLS policies that authorize authenticated mobile users by their web
`users.id`, farm membership, and target batch. For production, prefer a
transactional Supabase RPC or Edge Function that performs the same side effects
as the web actions, especially:

- Egg logs increment inventory.
- Feed logs decrement inventory or formulation stock.
- Mortality logs decrement batch `currentCount`.

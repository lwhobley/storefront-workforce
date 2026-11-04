# Storefront Workforce

Workforce management for arena concessions: who works which storefront, when, how
they are tracked and paid, and how the workforce performs. No sales, inventory, or POS.

Built multi-tenant from the start (company → venues). Each venue's data is isolated in
the database, and each venue has its own rules, roles, pay settings, and branding. The
first venue is in Texas; Texas rules are the defaults, stored as settings.

## Status: Phase 1 (event night basics)

| Area | State |
|---|---|
| Data model, tenancy, scoped roles, audit log | Built |
| Event calendar (synced from Premium Command, or manual) | Built; sync needs a one-time connection (below) |
| Schedule and assignment builder (open storefronts, headcount by role, assign with rule checks) | Built |
| Live event view with arena map (who is assigned, in, missing, open positions) | Built |
| Mid-event moves, early release with recorded order, undo | Built |
| Employee clock-in by phone (PIN + photo, optional geofence), offline queue | Built |
| Shared kiosk clock-in (PIN + photo), offline queue | Built |
| Lateness, breaks, minors, overtime, certifications (rules engine + tests) | Built |
| PIN sign-in for everyone; managers issue PINs from the staff list | Built |
| English / Spanish on employee screens | Built (manager screens English for now) |
| Pay, Paycom export, tips, NPO payouts, temp invoices | Phase 2 |
| Open shifts, swaps, availability, onboarding, notifications, portals | Phase 3 |
| KPIs, reports, reliability, rankings, staffing suggestions, checklists, incidents | Phase 4 |
| Company/venue admin, branding editor, retention and deletion tools | Phase 5 |

## Run it

Demo mode (no backend; the fictional Pecan Valley Arena runs in memory, with a game
live right now):

```bash
flutter run -d chrome
```

Connected to Supabase:

```bash
flutter run -d chrome --dart-define=SUPABASE_URL=https://dhmxrojpkjuhhmpqyljp.supabase.co --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key>
```

Only the publishable key goes in the app, never the service-role key.

## Tests

```bash
cd packages/workforce_core && dart test     # labor rules (178) and sample data (29)
flutter test                                  # schedule, live board, demo flows
supabase/tests/run_local.sh                   # database: isolation, scopes, schedule, punches, sync (38)
deno test --allow-env supabase/functions/_shared/pin_test.ts
```

`run_local.sh` needs a local Postgres (set `PGHOST`, `PGPORT`, `PGUSER`).

## Stack and why

| Piece | Choice | Why |
|---|---|---|
| App | Flutter: web, iPhone, Android from one codebase | Same stack as Premium Command; one small team ships everywhere |
| Backend | Supabase (Postgres, sign-in, storage, live updates, edge functions) | About $25/month to start; row level security enforces venue isolation in the database itself; standard Postgres, so no lock-in |
| Rules | `packages/workforce_core`, pure Dart | Pay-sensitive math written once, tested hard, used by the app and tests |
| Offline | Device outbox; each punch gets its id on the device | A retried punch is stored once; nothing lost, nothing doubled |

## Layout

```
lib/                      Flutter app
  app/                    providers, router, shell
  data/                   repository interface, Supabase and demo implementations
  features/               auth, events, schedule, live (map), clock, kiosk, staff
packages/workforce_core/  domain models, labor rules, sample arena generator
supabase/migrations/      schema, policies, functions (0001–0008)
supabase/functions/       pin-login, kiosk-punch, staff-admin, event-sync
supabase/tests/           SQL behavior tests and a local runner
supabase/seed/            generated sample arena (40 storefronts, 300 staff, 8 NPO groups)
```

## Data model (Phase 1)

- **Tenancy and access:** `organizations` → `venues` (time zone, `settings` = labor rules,
  `branding`), `venue_rule_versions` (history), `user_profiles`, `venue_memberships`,
  `venue_roles` (per venue, editable), `role_assignments` (role + scope: venue, level,
  storefront, NPO group, or agency), `audit_logs` (append-only, written by triggers).
- **Layout:** `venue_levels`, `storefronts` (kind, section, map position), `stations`,
  `job_roles` (required certifications, minimum age, tipped), `certification_types`,
  `storefront_staffing_needs`.
- **People:** `workers` (regular, temp, or NPO), `worker_job_roles`,
  `worker_certifications`, `temp_agencies`, `npo_groups`, `user_pins`, `login_locks`.
  No SSNs, bank details, I-9s, or W-4s: those stay in Paycom.
- **Events and schedule:** `event_types`, `events` (source + external id for sync),
  `event_storefronts`, `event_staffing_needs`, `shifts` (one per position; open when no
  worker), `assignment_changes` (every assign, move, release, with reason), `event_sources`.
- **Time:** `punches` (device id, device time and server time, source, GPS, geofence
  result, photo, review status). Never deleted; corrections in Phase 2 void and replace
  with an approval and reason.

Every schedule change goes through a database function that checks the person's scope,
applies the hard rules (minimum age, required certification, one position per event),
and logs the change.

## Decisions and tradeoffs

- **PIN-only sign-in for everyone** (your call). PINs are system-assigned, 6 digits,
  never stored (only a keyed fingerprint), and attempts are limited per device and per
  network address. Tradeoff: a PIN alone is weaker than a password plus code, and the
  more people share one system, the easier a random PIN guess becomes. Recommendation
  for later: a second step for admin accounts that can see pay.
- **PIN key location.** The fingerprint key lives in a private database schema so
  setup needed no dashboard step. Moving it to an edge function secret (`PIN_SECRET`)
  keeps it out of database backups; doing so means reissuing every PIN.
- **Offline clock-in** uses the phone's clock. Both times are stored; punches sent more
  than 12 hours late, or with a clock ahead of the server, are kept and flagged for review.
- **Kiosk offline:** the kiosk keeps the typed PIN with the queued punch until the server
  can match it, then drops it.
- **Certification enforcement** defaults to "block". A venue can switch to "warn".
- **Minor hour and time limits** warn (with a required reason) rather than block, so a
  manager can schedule an early release. Minimum working age and prohibited roles block.
- **Arena map** is a schematic bowl until floor plans arrive; storefront positions are
  stored (0–1 on each level), so a real plan can be placed underneath later.

## Confirm with HR or an employment attorney

- **Minors:** defaults use federal limits for ages 14–15 (3 hours on a school day,
  18 per school week, 7am–7pm, 9pm from June 1 to Labor Day), which are stricter than
  Texas Labor Code ch. 51. Most night events rule out 14–15-year-olds. Bartending is 18+.
  The school year is a setting (Aug 15 – May 31); holidays are not yet modeled.
- **Breaks:** Texas has no adult break law; the defaults (10-minute paid rest after
  4 hours, 30-minute unpaid meal after 6) are placeholders for your written policy.
  Federal rule: breaks of 20 minutes or less are paid.
- **Overtime:** federal, after 40 hours in the workweek (Monday start by default).
- **Tip pool (Phase 2):** with full minimum wage paid, back-of-house can share, but
  managers and supervisors may not keep pooled tips. Decide whether "lead" counts as a
  supervisor.
- **Final pay (Phase 2):** within 6 days if discharged, next regular payday if the person
  quits. Decide how season end is treated.
- **NPO volunteers** working a for-profit concession: confirm the arrangement, especially
  for minors.
- **Photo and location at clock-in:** give staff written notice. Photos are not used for
  face matching, so the Texas biometric law (CUBI) is not triggered.

## Paycom

- Paycom stays the payroll system of record. Phase 2 exports approved hours, earnings
  codes, and tips as CSV, with configurable columns so the file matches your Paycom
  import template without code changes. Needed before Phase 2: your Paycom time-import
  template and earnings codes (including tips).
- Paycom has a REST API (punch, hours, and earnings import; employee and earnings-code
  reads), enabled by your Paycom rep, with credentials per client and IP allowlisting.
  Worth adding later to pull new hires automatically. The export is a pluggable module
  so another venue can use a different payroll provider.

## Connecting Premium Command (event calendar)

Events sync from Premium Command, so they are entered once. One-time setup:

1. In Premium Command, create a read-only sync account with the `view_operations`
   permission at the venue.
2. Set edge function secrets on this project: `PC_SUPABASE_URL`, `PC_PUBLISHABLE_KEY`,
   `PC_SYNC_EMAIL`, `PC_SYNC_PASSWORD` (and `CRON_SECRET` for scheduled syncs).
3. Add an `event_sources` row for the venue with
   `config = {"remote_venue_id": "<Premium Command venue id>"}`.
4. Press **Sync from Premium Command** on the Events screen.

Name, type, start, and end follow Premium Command. Call and doors times are set from the
venue's defaults (doors 60 minutes before start, call 90 minutes before doors) unless a
manager edits them. Attendance stays local. Premium Command's start is its service
start; adjust the defaults if that differs from game time.

## Sample data

`dart run packages/workforce_core/bin/generate_seed.dart supabase/seed/sample_arena.sql --now=<ISO time>`
regenerates the fictional arena so the live game is happening at that time.

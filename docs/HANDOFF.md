# Storefront Workforce: handoff

Written November 4, 2026. For whoever picks this up next, person or AI session. The
README covers running the app, the stack, and the data model. This note covers where
things stand, what was decided, and what to do next.

## What this is

A workforce app for arena concessions ("storefronts"): who works where and when,
clock-in, pay to Paycom, tips, NPO payouts, temp agency billing, and communication.
No sales, inventory, or POS. Flutter (web, iOS, Android) on Supabase. Multi-tenant
from the start (company → venues). The first venue is CUTX (Credit Union of Texas Event
Center, Allen, TX). It is a sister product to Premium Command (`lwhobley/premiumcommand`),
which shares the Flutter + Supabase stack and its look.

## Where everything lives

| Thing | Location |
|---|---|
| Code | `lwhobley/storefront-workforce`, branch `main` (deploys on push) |
| Backend | Supabase project **Storefront Workforce**, ref `dhmxrojpkjuhhmpqyljp`, us-east-1 |
| Web app | Cloudflare Pages project `storefront-workforce` → `storefront-workforce.pages.dev`, deployed by `.github/workflows/deploy-web.yml` |
| Event calendar source | Premium Command's Supabase project (`tloxfuuzyadgkaejfhzx`), synced by the `event-sync` function (not yet connected) |
| Snapshot branch | `phase-3-wip`: an old in-progress snapshot; safe to delete |

## Status by phase

| Phase | State |
|---|---|
| 1. Event night basics | Done: schedule builder, live view with the CUTX concourse map, phone and kiosk clock-in (PIN + photo, offline), moves and early release, rules engine |
| 2. Pay | Done: pay engine, time corrections, pay periods with approve/lock, Paycom entry sheet and CSV, tips, NPO payouts, agency invoices |
| 3. Self-service and communication | Done (shift trading and availability, messages and alerts, onboarding, partner portals, own hours and tips). Live database updated; `notify-dispatch` not deployed |
| 4. Performance and reports | Started in another working copy (report targets, ratings, do-not-rehire in the database); app code not on GitHub yet |
| 5. Multi-venue admin | Not started (tenant isolation itself is built and tested) |

### Phase 3 notes

All three areas are built and tested (each in its own files; see "Code map").

- **Communication:** messages and alerts, announcements and policy acknowledgments,
  inbox, scheduled reminders, and the `notify-dispatch` function (push via FCM, opt-in
  email via Resend). Migration 0013.
- **Shifts:** open shifts, pickups, drops (24-hour cutoff, reason required), swaps to a
  coworker who accepts in the app, availability per event and date ranges off, the
  manager Requests queue (shows the rules check; approving over warnings needs a note),
  and availability tags in the schedule builder. Settings live in
  `venues.settings.self_service`, with no editing screen yet (Phase 5). Migration 0012.
- **People:** onboarding checklist per worker type (documents signed by typed name,
  card photos reviewed by a manager, training items, Paycom done), the onboarding
  board, Add person, roster CSV import with checks, the NPO coordinator and agency
  contact portals, and employees' own hours and tips (no wages). Migration 0014.
- **Fixes in 0018:** agency and NPO contacts no longer read staff records directly
  (only through their portal, so no birth dates), and an uploaded card photo does not
  count for scheduling until a manager verifies it.

0014 is live, so decide soon:
- **Backfill:** existing staff show "not finished" because nobody has onboarding
  records yet. Mark returning staff complete, or let them work through it.
- **Documents:** the seeded documents are inactive drafts. The venue writes the real
  text, and counsel reviews the volunteer waiver. Confirm that a typed name is enough as
  a signature (including a parent's for a minor) and that a home address may be kept.

Not done yet: no roster file picker on phones (people paste the CSV), documents are text
only (no PDF upload), and managers are not notified when a card photo is uploaded (they
see it on the board).

## Decisions the venue made (do not reverse without asking)

- **Sign-in is a 6-digit PIN only**, assigned by the system, for everyone (no phone or
  email sign-in). Attempts are rate-limited per device and per network address.
- **No text messages (SMS).** Alerts go to the in-app inbox and push; email is opt-in.
- **Employees never see wages or pay rates** (enforced in the database by migration
  0011). They see their own hours and tips.
- **Paycom stays the payroll system.** Hours are keyed in by hand from the entry sheet,
  and there is no Paycom template yet. SSNs, bank details, I-9 and W-4 stay in Paycom
  and never enter this app.
- **NPO groups are paid per hour**, with a minimum headcount, through accounts payable
  (not payroll).
- **Tips:** bartenders, pooled, full wage plus tips (no tip credit).
- **Pay periods are every two weeks.** The workweek starts Monday. Not union.
- **Everyone has their own phone.** The photo at clock-in is a snapshot only, with no face
  matching (so the Texas biometric law does not apply).
- **Events come from Premium Command**, not entered twice.
- **The real CUTX lineup** (used as sample data): stands La Cantina Roja (106), Allen
  Station Grill (103), Slice (101), Eb's BBQ (117), All American Dog (114); bars
  Southside (115), Destination (105), Westside (west concourse); kiosks Grab & Go
  (south concourse) and Sweet Station (coming soon, inactive). The map is drawn from the
  CUTX plan traced in Premium Command, concourse first; the premium level is not drawn.

## Backend state (live Supabase project)

- **Migrations applied: 0001–0020.** 0011–0014 (Phase 3) match this repo function for
  function. **0015–0017** (report targets, ratings, do-not-rehire) were applied from
  another working copy whose app code is not on GitHub yet; the SQL was copied into this
  repo from the live project's migration history, and 0017 was checked to match the live
  function exactly. **0018** (partner privacy, card review) was applied November 4 and
  builds on 0017's `assignment_block_reason`, keeping the do-not-rehire check.
- **0019 and 0020** (applied November 4) fix what a three-way code review of Phase 3 found:
  coworker details no longer leak through swap errors, closed storefronts' positions
  can't be picked up, partners can't read punch GPS or photo paths, a minor's waiver
  needs a guardian, ratings and do-not-rehire flags are audited, failed notifications
  stop after 5 attempts, and one venue's bad setting can't stop other venues' reminders.
  Every public function on the live project was checked against the tested code after
  applying. Known gap left on purpose: `events.labor_budget` is still readable by any
  venue member from the table itself, because the app selects events with `*`; fix by
  listing columns in the app, then revoking that column.
- **Two working copies:** whoever pushes the Phase 4 app code must rebase onto `main` and
  keep these migration numbers. New migrations start at 0021.
- **Edge functions deployed:** `pin-login`, `kiosk-punch`, `staff-admin`, `event-sync`.
  Not deployed: `notify-dispatch`. `setup-sql` is a disabled loader (returns 410) and
  can be deleted.
- **Applying migrations:** the MCP `apply_migration` tool works for small files. For
  large files, Supabase's Cloudflare firewall blocked a raw SQL request body once; the
  loader worked when the SQL was sent base64-encoded. Record each migration in
  `supabase_migrations.schema_migrations` (version = the 4-digit prefix) so
  `supabase db push` stays in sync.
- **Data:** the CUTX sample (fictional staff and events, real storefronts), loaded with
  the live game timed at load. Reloading means truncating the venue data, deleting the
  auth users, regenerating the seed with
  `dart run packages/workforce_core/bin/generate_seed.dart <file> --now=<ISO time>`, and
  recreating sample sign-ins. The sample PINs were given to the owner in chat and are
  **not** stored in the repo. An Admin can issue new PINs from the Staff screen.
- **PIN key:** kept in the database's private schema (migration 0007). Moving it to an
  edge function secret `PIN_SECRET` is stronger, but requires reissuing every PIN.

## Waiting on the owner

1. **Cloudflare deploy:** add the GitHub Actions secrets `CLOUDFLARE_API_TOKEN` (with
   Account → Cloudflare Pages → Edit) and `CLOUDFLARE_ACCOUNT_ID`, then confirm the
   *Deploy web* run passes.
2. **Premium Command sync:** create a read-only sync login in Premium Command and set
   the `PC_*` secrets plus an `event_sources` row (steps in the README).
3. **Real data:** roster, pay rates by role, Paycom employee and earnings codes (incl.
   tips), the NPO rate and minimum headcount, and agency bill rates.
4. **Push and email:** reuse Premium Command's Firebase project for push, and create a
   Resend account for email. Secrets: `CRON_SECRET`, `FCM_PROJECT_ID`,
   `FCM_SERVICE_ACCOUNT`, `RESEND_API_KEY`, `EMAIL_FROM`, optional `APP_URL`. Then
   deploy `notify-dispatch` and schedule it about every minute.
5. **Floor plans for other levels** if storefronts are ever added off the concourse.
6. **HR or attorney confirmations** (also in the README):
   - Hour limits for 14- and 15-year-olds.
   - Whether leads are supervisors (they are excluded from the tip pool).
   - How final pay works at season end.
   - The NPO deduction rule.
   - Agency overtime billing.
   - The written break policy (the defaults are placeholders).

## Next steps, in order

1. Decide the onboarding backfill and write the real onboarding documents (see Phase 3 notes).
2. Deploy `notify-dispatch` once
   secrets exist. Smoke-test the connected app with the sample PINs.
3. Push registration in the app: add `firebase_messaging`, register tokens with
   `registerPushToken`, and wire the `unreadCountProvider` badge in the nav.
4. Run one real event alongside the current process. Enter one real pay period from the
   entry sheet and compare it with the usual method.
5. Phase 4 (reports, KPIs with targets, CSV/PDF exports, reliability scores, staffing
   suggestions, checklists, incidents), then Phase 5.

## How to verify

```bash
export PATH=/opt/sdk/flutter/bin:$PATH        # in the cloud container; locally use your Flutter
flutter analyze                                # must say "No issues found!" (CI treats warnings as failures)
flutter test                                   # 42 tests
(cd packages/workforce_core && dart test)
supabase/tests/run_local.sh                    # needs a local Postgres; runs every supabase/tests/*.sql
deno test --allow-env supabase/functions       # PIN helpers and notify-dispatch helpers
```

UI checks: `flutter build web --release --no-web-resources-cdn`, serve `build/web`, and
drive it with Playwright. Flutter draws to a canvas, so click by coordinates. Type the
PIN on the keyboard about 3 seconds after load. Demo PINs: 100001 Admin, 200002
Concessions Manager, 300003 Storefront Lead, 400004 Employee, 400005 Empleado,
500005 Kiosk, 600006 NPO Coordinator, 700007 Agency Contact.

## Code map

```
lib/app/            router (role-based nav), providers, shell
lib/data/           repository interface + Supabase and demo implementations
  demo/, supabase/  one part file per Phase 3 area (shift_market, comms, people)
lib/features/       auth, events, schedule, live (CUTX map), clock, kiosk, staff, pay,
                    shift_market, comms, people
packages/workforce_core/
  lib/src/rules/    time and attendance rules (lateness, breaks, minors, overtime, certs)
  lib/src/pay/      pay engine (earnings, tips, NPO, agency, pay periods, Paycom export)
  lib/src/layout/   CUTX plan geometry (from Premium Command)
  lib/src/sample/   sample arena and sample pay setup
supabase/migrations 0001–0018;  supabase/tests;  supabase/functions
```

## Gotchas learned the hard way

- The Supabase Dart client sorts **newest-first by default**: always pass
  `ascending: true` to `.order(...)`.
- Supabase returns at most 1,000 rows per request. Use the `_all` pager in the Supabase
  repository for punches, shifts and pay lines.
- Show event dates in **venue time** (`atVenue`, `localDateOf`), never `toLocal()`. A
  7 pm game is the next day in UTC.
- Pay data loads a week either side of a period, for overtime. Filter problems, tips and
  people back to the period's own dates.
- `flutter analyze` warnings fail CI and block the Cloudflare deploy.
- The local test Postgres sometimes stops when the container idles. Restart it with
  `pg_ctl`.

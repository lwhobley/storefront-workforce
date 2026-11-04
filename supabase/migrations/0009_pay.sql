-- Phase 2: time corrections, pay rates, pay periods and approval, the Paycom entry sheet
-- and export, tips, temp agency billing, NPO payouts, and labor budgets.
--
-- Money math (overtime regular rate, tip pools, NPO payouts) runs in the shared Dart rules
-- engine and is tested there. When a manager approves a pay period, the calculated lines
-- are stored here as a locked snapshot together with the rules version they used, so an
-- export or a later report always shows exactly what was approved.

-- ---------------------------------------------------------------------------
-- Earnings codes (what Paycom calls each kind of pay)
-- ---------------------------------------------------------------------------
create table public.pay_codes (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[A-Z0-9_]{1,20}$'),
  name text not null,
  kind text not null check (kind in ('regular', 'overtime', 'tips', 'differential', 'bonus', 'tip_credit_makeup', 'other')),
  -- The code to use in Paycom. Empty until the venue enters it.
  paycom_code text not null default '',
  sort integer not null default 0,
  primary key (venue_id, code)
);

create or replace function public.seed_venue_pay_codes()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into pay_codes (venue_id, code, name, kind, sort) values
    (new.id, 'REG', 'Regular', 'regular', 1),
    (new.id, 'OT', 'Overtime', 'overtime', 2),
    (new.id, 'TIPS', 'Tips (pooled)', 'tips', 3),
    (new.id, 'LEAD', 'Lead differential', 'differential', 4),
    (new.id, 'BONUS', 'Bonus', 'bonus', 5),
    (new.id, 'TIPMU', 'Tip credit make-up', 'tip_credit_makeup', 6)
  on conflict do nothing;
  return new;
end $$;

create trigger venues_seed_pay_codes after insert on public.venues
for each row execute function public.seed_venue_pay_codes();

insert into public.pay_codes (venue_id, code, name, kind, sort)
select v.id, c.code, c.name, c.kind, c.sort
from public.venues v
cross join (values ('REG', 'Regular', 'regular', 1), ('OT', 'Overtime', 'overtime', 2),
                   ('TIPS', 'Tips (pooled)', 'tips', 3), ('LEAD', 'Lead differential', 'differential', 4),
                   ('BONUS', 'Bonus', 'bonus', 5), ('TIPMU', 'Tip credit make-up', 'tip_credit_makeup', 6)) as c(code, name, kind, sort)
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- Pay rates. The most specific active rate wins:
--   worker + role + event type > worker + role > worker > role + event type > role > venue default
-- ---------------------------------------------------------------------------
create table public.pay_rates (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  worker_id uuid,
  job_role_code text,
  event_type_code text,
  hourly_rate numeric(8,2) not null check (hourly_rate >= 0),
  effective_from date not null,
  effective_to date,
  note text not null default '',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code),
  foreign key (venue_id, event_type_code) references public.event_types(venue_id, code),
  check (effective_to is null or effective_to >= effective_from)
);
create index pay_rates_venue_idx on public.pay_rates(venue_id, worker_id);

-- Extra pay on top of the rate: per hour (lead pay) or per shift (a bonus).
create table public.pay_differentials (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null,
  pay_code text not null,
  job_role_code text,
  worker_id uuid,
  event_type_code text,
  per_hour numeric(8,2) not null default 0 check (per_hour >= 0),
  per_shift numeric(8,2) not null default 0 check (per_shift >= 0),
  effective_from date not null,
  effective_to date,
  created_at timestamptz not null default now(),
  foreign key (venue_id, pay_code) references public.pay_codes(venue_id, code),
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  check (per_hour > 0 or per_shift > 0)
);

-- ---------------------------------------------------------------------------
-- Time corrections: a manager proposes, another person with approve_time approves.
-- Approved corrections void the old punch and add a new one; nothing is deleted.
-- ---------------------------------------------------------------------------
create table public.time_corrections (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  worker_id uuid not null,
  event_id uuid,
  -- add: a missed punch; void: a punch that should not count; replace: wrong time.
  action text not null check (action in ('add', 'void', 'replace')),
  punch_id uuid references public.punches(id),
  new_kind text check (new_kind in ('clock_in', 'clock_out', 'break_start', 'break_end')),
  new_break_kind text check (new_break_kind in ('meal', 'rest')),
  new_occurred_at timestamptz,
  reason text not null check (length(btrim(reason)) between 3 and 500),
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  requested_by uuid default auth.uid(),
  requested_at timestamptz not null default now(),
  decided_by uuid,
  decided_at timestamptz,
  decision_note text not null default '',
  -- The punch created when approved.
  result_punch_id uuid references public.punches(id),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id),
  check ((action = 'add') = (punch_id is null)),
  check ((action = 'void') = (new_occurred_at is null))
);
create index time_corrections_venue_idx on public.time_corrections(venue_id, status);

-- ---------------------------------------------------------------------------
-- Pay periods and approved lines
-- ---------------------------------------------------------------------------
create table public.pay_periods (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  pay_date date not null,
  status text not null default 'open' check (status in ('open', 'approved', 'exported')),
  approved_by uuid,
  approved_at timestamptz,
  -- Rules version the approved lines were calculated with.
  rules_version integer,
  created_at timestamptz not null default now(),
  unique (venue_id, starts_on),
  unique (venue_id, id),
  check (ends_on >= starts_on and pay_date >= ends_on)
);

-- One approved earnings line: a person, a day, an earnings code.
create table public.pay_period_lines (
  id bigint generated always as identity primary key,
  venue_id uuid not null,
  pay_period_id uuid not null,
  worker_id uuid not null,
  work_date date not null,
  event_id uuid,
  storefront_id uuid,
  job_role_code text,
  pay_code text not null,
  hours numeric(8,2) not null default 0,
  rate numeric(8,4),
  amount numeric(10,2) not null default 0,
  foreign key (venue_id, pay_period_id) references public.pay_periods(venue_id, id) on delete cascade,
  foreign key (venue_id, worker_id) references public.workers(venue_id, id)
);
create index pay_period_lines_period_idx on public.pay_period_lines(pay_period_id, worker_id);

-- "Entered in Paycom" ticks on the entry sheet, so two people can split the list.
create table public.pay_entry_marks (
  pay_period_id uuid not null references public.pay_periods(id) on delete cascade,
  worker_id uuid not null references public.workers(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  entered_by uuid default auth.uid(),
  entered_at timestamptz not null default now(),
  primary key (pay_period_id, worker_id)
);

-- Every export or printed sheet, with what it contained.
create table public.payroll_exports (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  pay_period_id uuid not null references public.pay_periods(id) on delete cascade,
  provider text not null default 'paycom',
  format text not null check (format in ('entry_sheet_pdf', 'entry_sheet_csv', 'import_csv')),
  file_name text not null,
  row_count integer not null,
  total_hours numeric(10,2) not null,
  total_amount numeric(12,2) not null,
  sha256 text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Tips
-- ---------------------------------------------------------------------------
create table public.tip_pools (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  event_id uuid not null,
  -- One pool per storefront by default; null = an event-wide pool.
  storefront_id uuid,
  amount numeric(10,2) not null check (amount >= 0),
  source text not null default 'manual' check (source in ('manual', 'import', 'declared')),
  method text not null default 'hours' check (method in ('hours', 'role_points', 'equal')),
  -- For role_points: {"bartender": 1.0, "runner": 0.5}. Roles not listed are not in the pool.
  role_points jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'final')),
  note text not null default '',
  entered_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id)
);
create unique index tip_pools_one_per_storefront on public.tip_pools(event_id, coalesce(storefront_id, '00000000-0000-0000-0000-000000000000'::uuid));

create table public.tip_allocations (
  pool_id uuid not null,
  venue_id uuid not null,
  worker_id uuid not null,
  hours numeric(8,2) not null default 0,
  points numeric(8,3) not null default 0,
  amount numeric(10,2) not null check (amount >= 0),
  primary key (pool_id, worker_id),
  foreign key (venue_id, pool_id) references public.tip_pools(venue_id, id) on delete cascade,
  foreign key (venue_id, worker_id) references public.workers(venue_id, id)
);

-- ---------------------------------------------------------------------------
-- Temp agencies: bill rates
-- ---------------------------------------------------------------------------
create table public.agency_bill_rates (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  agency_id uuid not null,
  job_role_code text not null,
  bill_rate numeric(8,2) not null check (bill_rate >= 0),
  -- Billed for a temp's hours over 40 in a workweek at this venue. Null = same as bill_rate.
  overtime_bill_rate numeric(8,2) check (overtime_bill_rate is null or overtime_bill_rate >= 0),
  effective_from date not null,
  effective_to date,
  foreign key (venue_id, agency_id) references public.temp_agencies(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code)
);

-- ---------------------------------------------------------------------------
-- NPO groups: payout agreements and per-event payouts
-- ---------------------------------------------------------------------------
create table public.npo_agreements (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  -- Null = the venue's standard agreement for every group.
  npo_group_id uuid,
  hourly_rate numeric(8,2) not null check (hourly_rate >= 0),
  -- Members the group commits to send to each event it is scheduled for.
  min_headcount integer not null default 0 check (min_headcount >= 0),
  -- Deducted for each committed member who does not come.
  shortfall_deduction numeric(8,2) not null default 0 check (shortfall_deduction >= 0),
  -- Deducted for each scheduled member who is a no-show (no call, no arrival).
  no_show_deduction numeric(8,2) not null default 0 check (no_show_deduction >= 0),
  effective_from date not null,
  effective_to date,
  foreign key (venue_id, npo_group_id) references public.npo_groups(venue_id, id) on delete cascade
);

create table public.npo_payouts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  event_id uuid not null,
  npo_group_id uuid not null,
  members_scheduled integer not null default 0,
  members_worked integer not null default 0,
  no_shows integer not null default 0,
  hours numeric(8,2) not null default 0,
  hourly_rate numeric(8,2) not null default 0,
  gross numeric(10,2) not null default 0,
  deductions numeric(10,2) not null default 0,
  -- Manual adjustment with a reason (positive or negative).
  adjustment numeric(10,2) not null default 0,
  adjustment_reason text not null default '',
  total numeric(10,2) not null default 0,
  status text not null default 'pending' check (status in ('pending', 'approved', 'paid')),
  approved_by uuid,
  approved_at timestamptz,
  paid_at timestamptz,
  payment_reference text not null default '',
  -- Per-member hours at approval: [{"worker_id": ..., "hours": ...}].
  detail jsonb not null default '[]'::jsonb,
  unique (event_id, npo_group_id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, npo_group_id) references public.npo_groups(venue_id, id),
  check (adjustment = 0 or length(btrim(adjustment_reason)) > 0)
);

-- ---------------------------------------------------------------------------
-- Labor budgets
-- ---------------------------------------------------------------------------
alter table public.events add column labor_budget numeric(10,2) check (labor_budget is null or labor_budget >= 0);
alter table public.event_storefronts add column labor_budget numeric(10,2) check (labor_budget is null or labor_budget >= 0);
grant update (labor_budget) on public.events to authenticated;

-- ---------------------------------------------------------------------------
-- Audit and access
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array['pay_codes','pay_rates','pay_differentials','time_corrections','pay_periods',
                           'pay_entry_marks','payroll_exports','tip_pools','tip_allocations',
                           'agency_bill_rates','npo_agreements','npo_payouts'] loop
    execute format('create trigger %1$s_audit after insert or update or delete on public.%1$s for each row execute function public.audit_row_change()', t);
    execute format('alter table public.%1$s enable row level security', t);
    execute format('revoke all on public.%1$s from anon', t);
  end loop;
end $$;
alter table public.pay_period_lines enable row level security;
revoke all on public.pay_period_lines from anon;

-- Pay is visible only to view_pay at venue scope; each person also sees their own.
create or replace function public.is_own_worker(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from workers w where w.id = p_worker and w.user_id = (select auth.uid()));
$$;
revoke execute on function public.is_own_worker(uuid) from public, anon;
grant execute on function public.is_own_worker(uuid) to authenticated;

create policy pay_codes_read on public.pay_codes for select to authenticated using (public.is_venue_member(venue_id));
create policy pay_codes_write on public.pay_codes for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings')) with check (public.has_venue_permission(venue_id, 'manage_settings'));

create policy pay_rates_read on public.pay_rates for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') or (worker_id is not null and public.is_own_worker(worker_id)));
create policy pay_rates_write on public.pay_rates for all to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'approve_time'))
  with check (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'approve_time'));

create policy pay_differentials_read on public.pay_differentials for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay'));
create policy pay_differentials_write on public.pay_differentials for all to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'approve_time'))
  with check (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'approve_time'));

create policy time_corrections_read on public.time_corrections for select to authenticated
  using (public.has_venue_permission(venue_id, 'edit_time') or public.has_venue_permission(venue_id, 'approve_time') or public.is_own_worker(worker_id));
revoke insert, update, delete on public.time_corrections from authenticated;

create policy pay_periods_read on public.pay_periods for select to authenticated using (public.is_venue_member(venue_id));
revoke insert, update, delete on public.pay_periods from authenticated;

create policy pay_period_lines_read on public.pay_period_lines for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') or public.is_own_worker(worker_id));
revoke insert, update, delete on public.pay_period_lines from authenticated;

create policy pay_entry_marks_read on public.pay_entry_marks for select to authenticated using (public.has_venue_permission(venue_id, 'export_payroll'));
create policy pay_entry_marks_write on public.pay_entry_marks for all to authenticated
  using (public.has_venue_permission(venue_id, 'export_payroll')) with check (public.has_venue_permission(venue_id, 'export_payroll'));

create policy payroll_exports_read on public.payroll_exports for select to authenticated using (public.has_venue_permission(venue_id, 'export_payroll'));
create policy payroll_exports_insert on public.payroll_exports for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'export_payroll')
              and exists (select 1 from public.pay_periods p where p.id = pay_period_id and p.status in ('approved', 'exported')));
revoke update, delete on public.payroll_exports from authenticated;

create policy tip_pools_read on public.tip_pools for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay'));
create policy tip_pools_write on public.tip_pools for all to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'edit_time'))
  with check (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'edit_time'));
create policy tip_allocations_read on public.tip_allocations for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') or public.is_own_worker(worker_id));
create policy tip_allocations_write on public.tip_allocations for all to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'edit_time'))
  with check (public.has_venue_permission(venue_id, 'view_pay') and public.has_venue_permission(venue_id, 'edit_time'));

create policy agency_bill_rates_read on public.agency_bill_rates for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') or agency_id in (select public.permission_scope_ids(venue_id, 'agency_portal', 'agency')));
create policy agency_bill_rates_write on public.agency_bill_rates for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings')) with check (public.has_venue_permission(venue_id, 'manage_settings'));

create policy npo_agreements_read on public.npo_agreements for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay')
         or npo_group_id in (select public.permission_scope_ids(venue_id, 'npo_portal', 'npo_group'))
         or (npo_group_id is null and exists (select 1 from public.permission_scope_ids(venue_id, 'npo_portal', 'npo_group'))));
create policy npo_agreements_write on public.npo_agreements for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings')) with check (public.has_venue_permission(venue_id, 'manage_settings'));

create policy npo_payouts_read on public.npo_payouts for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay') or npo_group_id in (select public.permission_scope_ids(venue_id, 'npo_portal', 'npo_group')));
revoke insert, update, delete on public.npo_payouts from authenticated;

-- Labor budgets are pay information.
create policy event_storefronts_budget on public.event_storefronts for update to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay')) with check (public.has_venue_permission(venue_id, 'view_pay'));
grant update (labor_budget) on public.event_storefronts to authenticated;

-- ---------------------------------------------------------------------------
-- Functions
-- ---------------------------------------------------------------------------

-- A manager proposes a time correction.
create or replace function public.request_time_correction(p jsonb)
returns time_corrections language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype;
  v_row time_corrections%rowtype;
  v_punch punches%rowtype;
begin
  select * into w from workers where id = (p ->> 'worker_id')::uuid;
  if not found then raise exception 'Person not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(w.venue_id, 'edit_time') then
    raise exception 'Not authorized to correct time' using errcode = '42501';
  end if;
  if nullif(p ->> 'punch_id', '') is not null then
    select * into v_punch from punches where id = (p ->> 'punch_id')::uuid and worker_id = w.id;
    if not found then raise exception 'That punch is not this person''s' using errcode = '22023'; end if;
  end if;
  if exists (select 1 from pay_periods pp where pp.venue_id = w.venue_id and pp.status <> 'open'
             and public.venue_local_date(w.venue_id, coalesce((p ->> 'new_occurred_at')::timestamptz, v_punch.occurred_at))
                 between pp.starts_on and pp.ends_on) then
    raise exception 'That pay period is approved. Reopen it before correcting time.' using errcode = '22023';
  end if;
  insert into time_corrections (venue_id, worker_id, event_id, action, punch_id, new_kind, new_break_kind, new_occurred_at, reason)
  values (w.venue_id, w.id, coalesce(nullif(p ->> 'event_id', '')::uuid, v_punch.event_id), p ->> 'action',
          nullif(p ->> 'punch_id', '')::uuid, nullif(p ->> 'new_kind', ''), nullif(p ->> 'new_break_kind', ''),
          nullif(p ->> 'new_occurred_at', '')::timestamptz, p ->> 'reason')
  returning * into v_row;
  return v_row;
end $$;

-- Approves or rejects a correction. The person who asked cannot approve their own.
create or replace function public.decide_time_correction(p_id uuid, p_approve boolean, p_note text default '')
returns time_corrections language plpgsql security definer set search_path = public as $$
declare
  c time_corrections%rowtype;
  old punches%rowtype;
  v_new uuid;
begin
  select * into c from time_corrections where id = p_id for update;
  if not found then raise exception 'Correction not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(c.venue_id, 'approve_time') then
    raise exception 'Not authorized to approve time' using errcode = '42501';
  end if;
  if c.status <> 'pending' then raise exception 'Already decided' using errcode = '22023'; end if;
  if c.requested_by = (select auth.uid()) then
    raise exception 'Another manager must approve your own correction' using errcode = '42501';
  end if;
  perform set_config('app.audit_reason', c.reason, true);
  if p_approve then
    if c.punch_id is not null then
      select * into old from punches where id = c.punch_id for update;
      update punches set status = 'voided', review_note = 'Corrected: ' || c.reason where id = c.punch_id;
    end if;
    if c.action in ('add', 'replace') then
      v_new := gen_random_uuid();
      insert into punches (id, venue_id, worker_id, event_id, shift_id, kind, break_kind, occurred_at, source, status, review_note, entered_by)
      values (v_new, c.venue_id, c.worker_id, c.event_id, old.shift_id,
              coalesce(c.new_kind, old.kind), coalesce(c.new_break_kind, old.break_kind),
              c.new_occurred_at, 'manager', 'accepted', 'Correction: ' || c.reason, c.requested_by);
    end if;
  end if;
  update time_corrections set status = case when p_approve then 'approved' else 'rejected' end,
         decided_by = (select auth.uid()), decided_at = now(), decision_note = coalesce(p_note, ''),
         result_punch_id = v_new
   where id = p_id returning * into c;
  return c;
end $$;

-- Creates the pay periods covering a date range from the venue's pay period rule.
create or replace function public.ensure_pay_periods(p_venue uuid, p_through date)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_settings jsonb;
  v_anchor date;
  v_freq text;
  v_lag integer;
  v_start date;
  v_end date;
  v_created integer := 0;
begin
  if not public.has_venue_permission(p_venue, 'view_pay') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select settings into v_settings from venues where id = p_venue;
  v_anchor := coalesce((v_settings -> 'pay_period' ->> 'anchor_date')::date, date '2026-01-05');
  v_freq := coalesce(v_settings -> 'pay_period' ->> 'frequency', 'biweekly');
  -- Same lookup as the Dart PayRules: settings.pay first, then settings.pay_period.
  v_lag := coalesce((v_settings -> 'pay' ->> 'payday_days_after_end')::integer,
                    (v_settings -> 'pay_period' ->> 'payday_days_after_end')::integer, 5);
  if v_freq not in ('weekly', 'biweekly') then
    raise exception 'Only weekly and every-two-weeks periods are supported so far' using errcode = '22023';
  end if;
  v_start := v_anchor;
  while v_start <= p_through loop
    v_end := v_start + case v_freq when 'weekly' then 6 else 13 end;
    if v_end >= p_through - 120 then
      insert into pay_periods (venue_id, starts_on, ends_on, pay_date)
      values (p_venue, v_start, v_end, v_end + v_lag)
      on conflict (venue_id, starts_on) do nothing;
      if found then v_created := v_created + 1; end if;
    end if;
    v_start := v_end + 1;
  end loop;
  return v_created;
end $$;

-- Approves a pay period with the lines the rules engine calculated, and locks it.
create or replace function public.approve_pay_period(p_period uuid, p_lines jsonb, p_rules_version integer)
returns pay_periods language plpgsql security definer set search_path = public as $$
declare
  pp pay_periods%rowtype;
begin
  select * into pp from pay_periods where id = p_period for update;
  if not found then raise exception 'Pay period not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(pp.venue_id, 'approve_time') or not public.has_venue_permission(pp.venue_id, 'view_pay') then
    raise exception 'Not authorized to approve pay' using errcode = '42501';
  end if;
  if pp.status <> 'open' then raise exception 'Already approved' using errcode = '22023'; end if;
  if exists (select 1 from time_corrections c join workers w on w.id = c.worker_id
             where c.venue_id = pp.venue_id and c.status = 'pending'
               and public.venue_local_date(pp.venue_id, coalesce(c.new_occurred_at, (select occurred_at from punches where id = c.punch_id)))
                   between pp.starts_on and pp.ends_on) then
    raise exception 'Decide the pending time corrections in this period first' using errcode = '22023';
  end if;
  insert into pay_period_lines (venue_id, pay_period_id, worker_id, work_date, event_id, storefront_id, job_role_code, pay_code, hours, rate, amount)
  select pp.venue_id, pp.id, (l ->> 'worker_id')::uuid, (l ->> 'work_date')::date, nullif(l ->> 'event_id', '')::uuid,
         nullif(l ->> 'storefront_id', '')::uuid, nullif(l ->> 'job_role_code', ''), l ->> 'pay_code',
         coalesce((l ->> 'hours')::numeric, 0), (l ->> 'rate')::numeric, coalesce((l ->> 'amount')::numeric, 0)
  from jsonb_array_elements(p_lines) l;
  if exists (select 1 from pay_period_lines l where l.pay_period_id = pp.id
             and (l.work_date < pp.starts_on or l.work_date > pp.ends_on)) then
    raise exception 'A line falls outside the pay period' using errcode = '22023';
  end if;
  update pay_periods set status = 'approved', approved_by = (select auth.uid()), approved_at = now(), rules_version = p_rules_version
   where id = pp.id returning * into pp;
  return pp;
end $$;

-- Reopens an approved period (for a late correction). The lines are removed and the
-- reopening is logged; exported periods stay exported in the export history.
create or replace function public.reopen_pay_period(p_period uuid, p_reason text)
returns pay_periods language plpgsql security definer set search_path = public as $$
declare
  pp pay_periods%rowtype;
begin
  select * into pp from pay_periods where id = p_period for update;
  if not found then raise exception 'Pay period not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(pp.venue_id, 'approve_time') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then raise exception 'Give a reason' using errcode = '22023'; end if;
  perform set_config('app.audit_reason', p_reason, true);
  delete from pay_period_lines where pay_period_id = pp.id;
  delete from pay_entry_marks where pay_period_id = pp.id;
  update pay_periods set status = 'open', approved_by = null, approved_at = null, rules_version = null
   where id = pp.id returning * into pp;
  return pp;
end $$;

-- Records an export or printed entry sheet and marks the period exported.
create or replace function public.record_payroll_export(p_period uuid, p_format text, p_file text, p_rows integer, p_hours numeric, p_amount numeric, p_sha256 text)
returns payroll_exports language plpgsql security definer set search_path = public as $$
declare
  pp pay_periods%rowtype;
  v_row payroll_exports%rowtype;
begin
  select * into pp from pay_periods where id = p_period;
  if not found then raise exception 'Pay period not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(pp.venue_id, 'export_payroll') then
    raise exception 'Not authorized to export payroll' using errcode = '42501';
  end if;
  if pp.status = 'open' then raise exception 'Approve the pay period first' using errcode = '22023'; end if;
  insert into payroll_exports (venue_id, pay_period_id, format, file_name, row_count, total_hours, total_amount, sha256)
  values (pp.venue_id, pp.id, p_format, p_file, p_rows, p_hours, p_amount, p_sha256)
  returning * into v_row;
  update pay_periods set status = 'exported' where id = pp.id;
  return v_row;
end $$;

-- Saves an NPO payout calculated by the rules engine (pending until approved).
create or replace function public.save_npo_payout(p jsonb)
returns npo_payouts language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid;
  v_row npo_payouts%rowtype;
begin
  select venue_id into v_venue from events where id = (p ->> 'event_id')::uuid;
  if v_venue is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(v_venue, 'approve_time') or not public.has_venue_permission(v_venue, 'view_pay') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if exists (select 1 from npo_payouts where event_id = (p ->> 'event_id')::uuid
             and npo_group_id = (p ->> 'npo_group_id')::uuid and status <> 'pending') then
    raise exception 'This payout is already approved' using errcode = '22023';
  end if;
  insert into npo_payouts (venue_id, event_id, npo_group_id, members_scheduled, members_worked, no_shows, hours,
    hourly_rate, gross, deductions, adjustment, adjustment_reason, total, detail)
  values (v_venue, (p ->> 'event_id')::uuid, (p ->> 'npo_group_id')::uuid,
    (p ->> 'members_scheduled')::integer, (p ->> 'members_worked')::integer, (p ->> 'no_shows')::integer,
    (p ->> 'hours')::numeric, (p ->> 'hourly_rate')::numeric, (p ->> 'gross')::numeric, (p ->> 'deductions')::numeric,
    coalesce((p ->> 'adjustment')::numeric, 0), coalesce(p ->> 'adjustment_reason', ''), (p ->> 'total')::numeric,
    coalesce(p -> 'detail', '[]'::jsonb))
  on conflict (event_id, npo_group_id) do update set
    members_scheduled = excluded.members_scheduled, members_worked = excluded.members_worked,
    no_shows = excluded.no_shows, hours = excluded.hours, hourly_rate = excluded.hourly_rate,
    gross = excluded.gross, deductions = excluded.deductions, adjustment = excluded.adjustment,
    adjustment_reason = excluded.adjustment_reason, total = excluded.total, detail = excluded.detail
  returning * into v_row;
  return v_row;
end $$;

create or replace function public.set_npo_payout_status(p_id uuid, p_status text, p_reference text default '')
returns npo_payouts language plpgsql security definer set search_path = public as $$
declare
  v_row npo_payouts%rowtype;
begin
  select * into v_row from npo_payouts where id = p_id for update;
  if not found then raise exception 'Payout not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(v_row.venue_id, 'approve_time') or not public.has_venue_permission(v_row.venue_id, 'view_pay') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not ((v_row.status = 'pending' and p_status = 'approved') or (v_row.status = 'approved' and p_status in ('paid', 'pending'))) then
    raise exception 'Cannot go from % to %', v_row.status, p_status using errcode = '22023';
  end if;
  update npo_payouts set status = p_status,
         approved_by = case when p_status = 'approved' then (select auth.uid()) when p_status = 'pending' then null else approved_by end,
         approved_at = case when p_status = 'approved' then now() when p_status = 'pending' then null else approved_at end,
         paid_at = case when p_status = 'paid' then now() else null end,
         payment_reference = case when p_status = 'paid' then coalesce(p_reference, '') else payment_reference end
   where id = p_id returning * into v_row;
  return v_row;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.request_time_correction(jsonb)',
    'public.decide_time_correction(uuid, boolean, text)',
    'public.ensure_pay_periods(uuid, date)',
    'public.approve_pay_period(uuid, jsonb, integer)',
    'public.reopen_pay_period(uuid, text)',
    'public.record_payroll_export(uuid, text, text, integer, numeric, numeric, text)',
    'public.save_npo_payout(jsonb)',
    'public.set_npo_payout_status(uuid, text, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
revoke execute on function public.seed_venue_pay_codes() from public, anon, authenticated;

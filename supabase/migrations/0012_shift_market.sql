-- Phase 3: open shifts, pickups, drops, swaps, availability, and the manager approval
-- queue.
--
-- Employees never write these tables directly. Every request goes through a function
-- below that checks who is asking, applies the same hard rules as assign_shift
-- (assignment_block_reason: minimum age, certifications, one position per event), logs
-- schedule changes to assignment_changes, and notifies the people involved.
--
-- Venue settings (venues.settings -> 'self_service'), with these defaults:
--   allow_pickups          true   employees may ask for open shifts
--   allow_drops            true   employees may ask to give a shift back
--   allow_swaps            true   employees may offer a shift to a coworker
--   drop_cutoff_hours      24     no drop requests closer than this to call time
--   pickups_need_approval  true   false = an eligible pickup is assigned right away

create or replace function public.self_service_settings(p_venue uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select '{"allow_pickups": true, "allow_drops": true, "allow_swaps": true,
           "drop_cutoff_hours": 24, "pickups_need_approval": true}'::jsonb
         || coalesce((select settings -> 'self_service' from venues where id = p_venue), '{}'::jsonb);
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.shift_requests (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  kind text not null check (kind in ('pickup', 'drop', 'swap')),
  shift_id uuid not null,
  -- Who asked: the person picking up, dropping, or giving the shift away.
  requester_worker_id uuid not null,
  -- Swaps only: the coworker who takes the shift.
  target_worker_id uuid,
  -- offered = a swap waiting for the coworker; pending = waiting for a manager.
  status text not null default 'pending'
    check (status in ('pending', 'offered', 'approved', 'denied', 'cancelled', 'expired')),
  note text not null default '' check (length(note) <= 500),
  -- Rules-engine warnings the manager saw and accepted when approving.
  warnings text[] not null default '{}',
  decided_by uuid references auth.users(id),
  decided_at timestamptz,
  decision_note text not null default '' check (length(decision_note) <= 500),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, shift_id) references public.shifts(venue_id, id) on delete cascade,
  foreign key (venue_id, requester_worker_id) references public.workers(venue_id, id) on delete cascade,
  foreign key (venue_id, target_worker_id) references public.workers(venue_id, id) on delete cascade,
  check ((kind = 'swap') = (target_worker_id is not null)),
  check (target_worker_id is distinct from requester_worker_id)
);
create index shift_requests_shift_idx on public.shift_requests(shift_id);
create index shift_requests_venue_status_idx on public.shift_requests(venue_id, status, created_at desc);
create index shift_requests_requester_idx on public.shift_requests(requester_worker_id, created_at desc);
create index shift_requests_target_idx on public.shift_requests(target_worker_id, created_at desc) where target_worker_id is not null;
-- One open request per person per shift.
create unique index shift_requests_one_open on public.shift_requests(shift_id, requester_worker_id)
  where status in ('pending', 'offered');

-- A person's answer for one event: can work, or cannot.
create table public.event_availability (
  venue_id uuid not null,
  event_id uuid not null,
  worker_id uuid not null,
  status text not null check (status in ('available', 'unavailable')),
  note text not null default '' check (length(note) <= 300),
  updated_at timestamptz not null default now(),
  primary key (event_id, worker_id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade
);
create index event_availability_worker_idx on public.event_availability(worker_id);

-- Dates a person cannot work at all (vacation, school trip), inclusive, venue-local dates.
create table public.worker_blackouts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  worker_id uuid not null,
  starts_on date not null,
  ends_on date not null,
  note text not null default '' check (length(note) <= 300),
  created_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  check (ends_on >= starts_on and ends_on - starts_on <= 366)
);
create index worker_blackouts_worker_idx on public.worker_blackouts(worker_id, starts_on);

create trigger shift_requests_touch before update on public.shift_requests
for each row execute function public.touch_updated_at();
create trigger event_availability_touch before update on public.event_availability
for each row execute function public.touch_updated_at();

create trigger shift_requests_audit after insert or update or delete on public.shift_requests
for each row execute function public.audit_row_change();
create trigger event_availability_audit after insert or update or delete on public.event_availability
for each row execute function public.audit_row_change();
create trigger worker_blackouts_audit after insert or update or delete on public.worker_blackouts
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Access: read through policies, write only through the functions below.
-- ---------------------------------------------------------------------------
alter table public.shift_requests enable row level security;
alter table public.event_availability enable row level security;
alter table public.worker_blackouts enable row level security;
revoke all on public.shift_requests, public.event_availability, public.worker_blackouts from anon;
revoke insert, update, delete on public.shift_requests, public.event_availability, public.worker_blackouts from authenticated;

create policy shift_requests_read on public.shift_requests for select to authenticated
  using (
    exists (select 1 from public.workers w
            where w.id in (shift_requests.requester_worker_id, shift_requests.target_worker_id)
              and w.user_id = (select auth.uid()))
    or exists (select 1 from public.shifts s
               where s.id = shift_requests.shift_id and public.can_on_storefront(s.storefront_id, 'manage_schedule'))
  );

create policy event_availability_read on public.event_availability for select to authenticated
  using (
    exists (select 1 from public.workers w where w.id = event_availability.worker_id and w.user_id = (select auth.uid()))
    or public.has_venue_permission(venue_id, 'manage_schedule')
    or public.has_venue_permission(venue_id, 'view_workers')
  );

create policy worker_blackouts_read on public.worker_blackouts for select to authenticated
  using (
    exists (select 1 from public.workers w where w.id = worker_blackouts.worker_id and w.user_id = (select auth.uid()))
    or public.has_venue_permission(venue_id, 'manage_schedule')
    or public.has_venue_permission(venue_id, 'view_workers')
  );

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable through the API)
-- ---------------------------------------------------------------------------

-- The signed-in person's active staff record, or an error.
create or replace function public.current_worker()
returns workers language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where user_id = (select auth.uid());
  if not found then
    raise exception 'No staff record is linked to this sign-in' using errcode = '42501';
  end if;
  if w.status <> 'active' or not public.is_venue_member(w.venue_id) then
    raise exception 'Your staff record is not active' using errcode = '42501';
  end if;
  return w;
end $$;

create or replace function public.worker_name(p_worker uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(preferred_name), ''), first_name) || ' ' || last_name from workers where id = p_worker;
$$;

-- "Fri Nov 6, 5:30 PM" at the venue.
create or replace function public.venue_time_label(p_venue uuid, p_at timestamptz)
returns text language sql stable security definer set search_path = public as $$
  select to_char(p_at at time zone v.time_zone, 'Dy Mon FMDD, FMHH12:MI AM') from venues v where v.id = p_venue;
$$;

-- "Stampede vs Lynx · Stand 101 · Cashier · Fri Nov 6, 5:30 PM"
create or replace function public.shift_label(p_shift uuid)
returns text language sql stable security definer set search_path = public as $$
  select e.name || ' · ' || f.name || ' · ' || r.name || ' · ' || public.venue_time_label(s.venue_id, s.call_time)
  from shifts s
  join events e on e.id = s.event_id
  join storefronts f on f.id = s.storefront_id
  join job_roles r on r.venue_id = s.venue_id and r.code = s.job_role_code
  where s.id = p_shift;
$$;

-- Tells everyone who can schedule this storefront that a request is waiting.
create or replace function public.notify_schedulers(p_shift uuid, p_kind text, p_title text, p_body text, p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  v_level uuid;
  u uuid;
begin
  select * into s from shifts where id = p_shift;
  select level_id into v_level from storefronts where id = s.storefront_id;
  for u in
    select distinct ra.user_id
    from role_assignments ra
    join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
    join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
    where ra.venue_id = s.venue_id
      and 'manage_schedule' = any (r.permissions)
      and (ra.scope_type = 'venue'
           or (ra.scope_type = 'storefront' and ra.scope_id = s.storefront_id)
           or (ra.scope_type = 'level' and ra.scope_id = v_level))
      and ra.user_id is distinct from (select auth.uid())
  loop
    perform public.notify_user(s.venue_id, u, p_kind, p_title, p_body, '/requests', '{in_app}', p_data);
  end loop;
end $$;

-- Staff fields the app's rules engine needs (age on the event date, trained roles,
-- certifications). Never the birth date or contact details.
create or replace function public.rules_worker_json(p_worker uuid, p_day date)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
      'id', w.id, 'venue_id', w.venue_id, 'worker_type', w.worker_type,
      'employee_number', w.employee_number, 'first_name', w.first_name, 'last_name', w.last_name,
      'preferred_name', w.preferred_name, 'photo_path', w.photo_path, 'hire_date', w.hire_date,
      'agency_id', w.agency_id, 'npo_group_id', w.npo_group_id, 'status', w.status,
      'age_on_event', case when w.date_of_birth is null then null
                           else extract(year from age(p_day, w.date_of_birth))::integer end,
      'job_roles', coalesce((select jsonb_agg(r.job_role_code) from worker_job_roles r where r.worker_id = w.id), '[]'::jsonb),
      'certifications', coalesce((select jsonb_agg(jsonb_build_object(
          'id', c.id, 'worker_id', c.worker_id, 'cert_type_code', c.cert_type_code, 'expires_on', c.expires_on))
          from worker_certifications c where c.worker_id = w.id), '[]'::jsonb))
  from workers w where w.id = p_worker;
$$;

-- Requests whose shift has started are no longer actionable.
create or replace function public.expire_shift_requests(p_venue uuid)
returns void language sql security definer set search_path = public as $$
  update shift_requests q set status = 'expired', decision_note = 'The shift started before a decision.'
  from shifts s
  where s.id = q.shift_id and q.venue_id = p_venue and q.status in ('pending', 'offered') and s.call_time <= now();
$$;

-- Assigns or clears a position on behalf of the shift market (scope already checked by
-- the caller), and logs it like assign_shift / unassign_shift.
create or replace function public.market_set_worker(p_shift uuid, p_worker uuid, p_reason text, p_warnings text[])
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
begin
  select * into s from shifts where id = p_shift for update;
  before := s;
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  if before.worker_id is not null then
    update shifts set worker_id = null, status = 'open', version = version + 1 where id = p_shift returning * into s;
    perform public.log_assignment_change(s, 'unassigned', before.worker_id, before, p_reason, '{}');
    before := s;
  end if;
  if p_worker is not null then
    update shifts set worker_id = p_worker, status = 'assigned', version = version + 1 where id = p_shift returning * into s;
    perform public.log_assignment_change(s, 'assigned', p_worker, before, p_reason, p_warnings);
  end if;
  return s;
end $$;

create or replace function public.has_event_punches(p_worker uuid, p_event uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from punches p where p.event_id = p_event and p.worker_id = p_worker and p.status <> 'voided');
$$;

-- One request as the app shows it: the shift, event, storefront and role names, and the
-- people's names. p_rules adds the requester's and target's rules-engine fields
-- (managers only).
create or replace function public.shift_request_json(p_request uuid, p_rules boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(q) || jsonb_build_object(
      'shift', to_jsonb(s),
      'event', to_jsonb(e),
      'storefront_name', f.name,
      'role_name', r.name,
      'requester_name', public.worker_name(q.requester_worker_id),
      'target_name', public.worker_name(q.target_worker_id),
      'decided_by_name', (select display_name from user_profiles p where p.id = q.decided_by),
      'shift_worker_name', case when p_rules then public.worker_name(s.worker_id) end,
      'requester', case when p_rules then public.rules_worker_json(q.requester_worker_id, public.venue_local_date(q.venue_id, s.call_time)) end,
      'target', case when p_rules and q.target_worker_id is not null
                     then public.rules_worker_json(q.target_worker_id, public.venue_local_date(q.venue_id, s.call_time)) end)
  from shift_requests q
  join shifts s on s.id = q.shift_id
  join events e on e.id = s.event_id
  join storefronts f on f.id = s.storefront_id
  join job_roles r on r.venue_id = s.venue_id and r.code = s.job_role_code
  where q.id = p_request;
$$;

-- ---------------------------------------------------------------------------
-- Employee functions
-- ---------------------------------------------------------------------------

-- Open positions the caller could pick up: future, event not cancelled, a role they are
-- trained for, at events where they do not already work. "blocked" explains why one
-- cannot be picked up (age, certification...).
create or replace function public.open_shifts_for_me()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
begin
  return coalesce((
    select jsonb_agg(jsonb_build_object(
        'shift', to_jsonb(s),
        'event', to_jsonb(e),
        'storefront_name', f.name,
        'storefront_code', f.code,
        'section', f.section,
        'role_name', r.name,
        'blocked', public.assignment_block_reason(w.id, s.event_id, s.job_role_code, s.id),
        'my_request_id', (select q.id from shift_requests q where q.shift_id = s.id and q.requester_worker_id = w.id
                            and q.kind = 'pickup' and q.status = 'pending'),
        'availability', (select a.status from event_availability a where a.event_id = e.id and a.worker_id = w.id))
        order by s.call_time, f.name, r.sort)
    from shifts s
    join events e on e.id = s.event_id
    join storefronts f on f.id = s.storefront_id
    join job_roles r on r.venue_id = s.venue_id and r.code = s.job_role_code
    where s.venue_id = w.venue_id
      and s.status = 'open'
      and s.call_time > now()
      and e.status in ('scheduled', 'live')
      and exists (select 1 from worker_job_roles j where j.worker_id = w.id and j.job_role_code = s.job_role_code)
      and not exists (select 1 from shifts x where x.event_id = s.event_id and x.worker_id = w.id
                      and x.status in ('assigned', 'released'))), '[]'::jsonb);
end $$;

-- Asks for an open position. With pickups_need_approval off, an eligible pickup is
-- assigned right away and logged as "Picked up by employee".
create or replace function public.request_pickup(p_shift uuid, p_note text default '')
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  s shifts%rowtype;
  ev events%rowtype;
  cfg jsonb := public.self_service_settings(w.venue_id);
  v_block text;
  q shift_requests%rowtype;
begin
  select * into s from shifts where id = p_shift and venue_id = w.venue_id for update;
  if not found then raise exception 'Shift not found' using errcode = 'P0002'; end if;
  select * into ev from events where id = s.event_id;
  if not (cfg ->> 'allow_pickups')::boolean then
    raise exception 'Picking up shifts is turned off at this venue' using errcode = '42501';
  end if;
  if s.status <> 'open' then raise exception 'This shift is already filled' using errcode = '23505'; end if;
  if s.call_time <= now() or ev.status not in ('scheduled', 'live') then
    raise exception 'This shift is no longer available' using errcode = '22023';
  end if;
  if not exists (select 1 from worker_job_roles j where j.worker_id = w.id and j.job_role_code = s.job_role_code) then
    raise exception 'You are not trained for this role' using errcode = '42501';
  end if;
  v_block := public.assignment_block_reason(w.id, s.event_id, s.job_role_code, s.id);
  if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
  if exists (select 1 from shift_requests x where x.shift_id = s.id and x.requester_worker_id = w.id
             and x.status in ('pending', 'offered')) then
    raise exception 'You already asked for this shift' using errcode = '23505';
  end if;

  if (cfg ->> 'pickups_need_approval')::boolean then
    insert into shift_requests (venue_id, kind, shift_id, requester_worker_id, note)
    values (w.venue_id, 'pickup', s.id, w.id, left(coalesce(p_note, ''), 500)) returning * into q;
    perform public.notify_schedulers(s.id, 'shift_request', 'Pickup request: ' || public.worker_name(w.id),
      public.shift_label(s.id), jsonb_build_object('request_id', q.id));
  else
    insert into shift_requests (venue_id, kind, shift_id, requester_worker_id, note, status, decided_at, decision_note)
    values (w.venue_id, 'pickup', s.id, w.id, left(coalesce(p_note, ''), 500), 'approved', now(), 'Approved automatically')
    returning * into q;
    perform public.market_set_worker(s.id, w.id, 'Picked up by employee', '{}');
    perform public.notify_schedulers(s.id, 'schedule_changed', 'Shift picked up: ' || public.worker_name(w.id),
      public.shift_label(s.id), jsonb_build_object('request_id', q.id));
  end if;
  return q;
end $$;

-- Asks to give back an assigned shift. Closes drop_cutoff_hours before call time.
create or replace function public.request_drop(p_shift uuid, p_reason text default '')
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  s shifts%rowtype;
  cfg jsonb := public.self_service_settings(w.venue_id);
  v_hours numeric := coalesce((cfg ->> 'drop_cutoff_hours')::numeric, 24);
  q shift_requests%rowtype;
begin
  select * into s from shifts where id = p_shift and worker_id = w.id for update;
  if not found or s.status <> 'assigned' then raise exception 'This is not one of your shifts' using errcode = 'P0002'; end if;
  if not (cfg ->> 'allow_drops')::boolean then
    raise exception 'Dropping shifts is turned off at this venue. Talk to your manager.' using errcode = '42501';
  end if;
  if public.has_event_punches(w.id, s.event_id) then
    raise exception 'You have already clocked in for this event' using errcode = '22023';
  end if;
  if now() > s.call_time - make_interval(secs => (v_hours * 3600)::double precision) then
    raise exception 'Drops close % hours before call time. Talk to your manager.', v_hours using errcode = '22023';
  end if;
  if exists (select 1 from shift_requests x where x.shift_id = s.id and x.requester_worker_id = w.id
             and x.status in ('pending', 'offered')) then
    raise exception 'You already have a request open for this shift' using errcode = '23505';
  end if;
  insert into shift_requests (venue_id, kind, shift_id, requester_worker_id, note)
  values (w.venue_id, 'drop', s.id, w.id, left(coalesce(p_reason, ''), 500)) returning * into q;
  perform public.notify_schedulers(s.id, 'shift_request', 'Drop request: ' || public.worker_name(w.id),
    public.shift_label(s.id), jsonb_build_object('request_id', q.id));
  return q;
end $$;

-- Coworkers who could take the caller's shift: trained, eligible under the hard rules,
-- and able to answer in the app. Names only.
create or replace function public.my_swap_candidates(p_shift uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  s shifts%rowtype;
begin
  select * into s from shifts where id = p_shift and worker_id = w.id and status = 'assigned';
  if not found then raise exception 'This is not one of your shifts' using errcode = 'P0002'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', c.id, 'name', public.worker_name(c.id),
                       'availability', (select a.status from event_availability a where a.event_id = s.event_id and a.worker_id = c.id))
                     order by public.worker_name(c.id))
    from workers c
    where c.venue_id = w.venue_id and c.id <> w.id and c.status = 'active' and c.user_id is not null
      and exists (select 1 from worker_job_roles j where j.worker_id = c.id and j.job_role_code = s.job_role_code)
      and public.assignment_block_reason(c.id, s.event_id, s.job_role_code, s.id) is null), '[]'::jsonb);
end $$;

-- Offers the caller's shift to a coworker, who accepts or declines; a manager then
-- approves.
create or replace function public.offer_swap(p_shift uuid, p_to_worker uuid, p_note text default '')
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  s shifts%rowtype;
  t workers%rowtype;
  cfg jsonb := public.self_service_settings(w.venue_id);
  v_block text;
  q shift_requests%rowtype;
begin
  select * into s from shifts where id = p_shift and worker_id = w.id for update;
  if not found or s.status <> 'assigned' then raise exception 'This is not one of your shifts' using errcode = 'P0002'; end if;
  if not (cfg ->> 'allow_swaps')::boolean then
    raise exception 'Swapping shifts is turned off at this venue' using errcode = '42501';
  end if;
  if s.call_time <= now() or public.has_event_punches(w.id, s.event_id) then
    raise exception 'This shift has already started' using errcode = '22023';
  end if;
  select * into t from workers where id = p_to_worker and venue_id = w.venue_id;
  if not found or t.id = w.id then raise exception 'Choose a coworker' using errcode = '22023'; end if;
  if t.user_id is null then raise exception 'This coworker cannot answer in the app yet' using errcode = '22023'; end if;
  if not exists (select 1 from worker_job_roles j where j.worker_id = t.id and j.job_role_code = s.job_role_code) then
    raise exception 'This coworker is not trained for this role' using errcode = '22023';
  end if;
  v_block := public.assignment_block_reason(t.id, s.event_id, s.job_role_code, s.id);
  if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
  if exists (select 1 from shift_requests x where x.shift_id = s.id and x.requester_worker_id = w.id
             and x.status in ('pending', 'offered')) then
    raise exception 'You already have a request open for this shift' using errcode = '23505';
  end if;
  insert into shift_requests (venue_id, kind, shift_id, requester_worker_id, target_worker_id, note, status)
  values (w.venue_id, 'swap', s.id, w.id, t.id, left(coalesce(p_note, ''), 500), 'offered') returning * into q;
  perform public.notify_worker(t.id, 'shift_offered', public.worker_name(w.id) || ' offered you a shift',
    public.shift_label(s.id), '/schedule', '{in_app,push}', jsonb_build_object('request_id', q.id));
  return q;
end $$;

-- The coworker accepts (it goes to a manager) or declines an offered swap.
create or replace function public.respond_swap(p_request uuid, p_accept boolean)
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  q shift_requests%rowtype;
  s shifts%rowtype;
  v_block text;
begin
  select * into q from shift_requests where id = p_request for update;
  if not found or q.target_worker_id is distinct from w.id then
    raise exception 'This offer is not for you' using errcode = '42501';
  end if;
  if q.status <> 'offered' then raise exception 'This offer is no longer open' using errcode = '22023'; end if;
  select * into s from shifts where id = q.shift_id;
  if p_accept then
    if s.worker_id is distinct from q.requester_worker_id or s.status <> 'assigned' or s.call_time <= now() then
      raise exception 'This offer is no longer open' using errcode = '22023';
    end if;
    v_block := public.assignment_block_reason(w.id, s.event_id, s.job_role_code, s.id);
    if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
    update shift_requests set status = 'pending' where id = q.id returning * into q;
    perform public.notify_worker(q.requester_worker_id, 'request_update',
      public.worker_name(w.id) || ' accepted your swap. A manager will approve it.', public.shift_label(s.id), '/schedule');
    perform public.notify_schedulers(s.id, 'shift_request',
      'Swap request: ' || public.worker_name(q.requester_worker_id) || ' → ' || public.worker_name(w.id),
      public.shift_label(s.id), jsonb_build_object('request_id', q.id));
  else
    update shift_requests set status = 'denied', decided_by = (select auth.uid()), decided_at = now(),
           decision_note = 'Declined by coworker'
     where id = q.id returning * into q;
    perform public.notify_worker(q.requester_worker_id, 'request_update',
      public.worker_name(w.id) || ' declined your swap', public.shift_label(s.id), '/schedule');
  end if;
  return q;
end $$;

-- The requester withdraws a request that is still open.
create or replace function public.cancel_shift_request(p_request uuid)
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  q shift_requests%rowtype;
  v_was text;
begin
  select * into q from shift_requests where id = p_request for update;
  if not found or q.requester_worker_id <> w.id then
    raise exception 'This is not your request' using errcode = '42501';
  end if;
  if q.status not in ('pending', 'offered') then
    raise exception 'This request was already decided' using errcode = '22023';
  end if;
  v_was := q.status;
  update shift_requests set status = 'cancelled' where id = q.id returning * into q;
  if q.target_worker_id is not null then
    perform public.notify_worker(q.target_worker_id, 'request_update',
      public.worker_name(w.id) || ' withdrew the shift offer', public.shift_label(q.shift_id), '/schedule');
  end if;
  return q;
end $$;

-- The caller's requests and offers made to them, newest first.
create or replace function public.my_shift_requests()
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
begin
  perform public.expire_shift_requests(w.venue_id);
  return coalesce((
    select jsonb_agg(public.shift_request_json(q.id, false) order by q.created_at desc)
    from (select id, created_at from shift_requests
          where (requester_worker_id = w.id or target_worker_id = w.id)
            and (status in ('pending', 'offered') or created_at > now() - interval '60 days')
          order by created_at desc limit 100) q), '[]'::jsonb);
end $$;

-- Sets (or clears, with p_status null) the caller's answer for one upcoming event.
create or replace function public.set_event_availability(p_event uuid, p_status text, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  ev events%rowtype;
begin
  select * into ev from events where id = p_event and venue_id = w.venue_id;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if ev.status not in ('scheduled', 'live') or ev.call_time <= now() then
    raise exception 'This event has already started' using errcode = '22023';
  end if;
  if p_status is null then
    delete from event_availability where event_id = p_event and worker_id = w.id;
    return;
  end if;
  if p_status not in ('available', 'unavailable') then
    raise exception 'Unknown availability' using errcode = '22023';
  end if;
  insert into event_availability (venue_id, event_id, worker_id, status, note)
  values (w.venue_id, p_event, w.id, p_status, left(coalesce(p_note, ''), 300))
  on conflict (event_id, worker_id) do update set status = excluded.status, note = excluded.note;
end $$;

-- Adds a blackout (or changes one, with p_id) for the caller.
create or replace function public.set_blackout(p_starts date, p_ends date, p_note text default '', p_id uuid default null)
returns worker_blackouts language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  b worker_blackouts%rowtype;
begin
  if p_starts is null or p_ends is null or p_ends < p_starts then
    raise exception 'The end date must be on or after the start date' using errcode = '22023';
  end if;
  if p_ends - p_starts > 366 then raise exception 'A blackout can be at most a year' using errcode = '22023'; end if;
  if p_ends < public.venue_local_date(w.venue_id, now()) then
    raise exception 'These dates are in the past' using errcode = '22023';
  end if;
  if p_id is null then
    insert into worker_blackouts (venue_id, worker_id, starts_on, ends_on, note)
    values (w.venue_id, w.id, p_starts, p_ends, left(coalesce(p_note, ''), 300)) returning * into b;
  else
    update worker_blackouts set starts_on = p_starts, ends_on = p_ends, note = left(coalesce(p_note, ''), 300)
     where id = p_id and worker_id = w.id returning * into b;
    if not found then raise exception 'Blackout not found' using errcode = 'P0002'; end if;
  end if;
  return b;
end $$;

create or replace function public.delete_blackout(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
begin
  delete from worker_blackouts where id = p_id and worker_id = w.id;
  if not found then raise exception 'Blackout not found' using errcode = 'P0002'; end if;
end $$;

-- Upcoming events (next 90 days) with the caller's answer and whether they work it, and
-- their blackouts that have not ended.
create or replace function public.my_availability()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype := public.current_worker();
  v_today date := public.venue_local_date(w.venue_id, now());
begin
  return jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
          'event', to_jsonb(e),
          'status', a.status,
          'note', coalesce(a.note, ''),
          'scheduled', exists (select 1 from shifts s where s.event_id = e.id and s.worker_id = w.id and s.status in ('assigned', 'released')))
          order by e.call_time)
      from events e
      left join event_availability a on a.event_id = e.id and a.worker_id = w.id
      where e.venue_id = w.venue_id and e.status in ('scheduled', 'live')
        and e.call_time > now() and e.call_time < now() + interval '90 days'), '[]'::jsonb),
    'blackouts', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.starts_on)
      from worker_blackouts b where b.worker_id = w.id and b.ends_on >= v_today), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Manager functions
-- ---------------------------------------------------------------------------

-- Requests at storefronts where the caller can schedule. Open ones (pending, and swaps
-- waiting for the coworker), or with p_history the most recent decided ones.
create or replace function public.review_shift_requests(p_history boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid;
begin
  select m.venue_id into v_venue from venue_memberships m
   where m.user_id = (select auth.uid()) and m.status = 'active' and public.has_permission(m.venue_id, 'manage_schedule')
   limit 1;
  if v_venue is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  perform public.expire_shift_requests(v_venue);
  return coalesce((
    select jsonb_agg(public.shift_request_json(q.id, true) order by q.sort_at)
    from (select x.id, case when p_history then -extract(epoch from coalesce(x.decided_at, x.updated_at))
                            else extract(epoch from s.call_time) end as sort_at
          from shift_requests x join shifts s on s.id = x.shift_id
          where x.venue_id = v_venue
            and s.storefront_id in (select public.storefronts_in_scope(v_venue, 'manage_schedule'))
            and (case when p_history then x.status not in ('pending', 'offered') else x.status in ('pending', 'offered') end)
          order by sort_at limit 200) q), '[]'::jsonb);
end $$;

-- Approves or denies a pending request. Pickup: the requester gets the position. Drop:
-- the position opens again. Swap: the coworker takes the position. The hard rules are
-- checked again, warnings accepted need a note, and everyone involved is notified.
create or replace function public.decide_shift_request(p_request uuid, p_approve boolean, p_note text default '', p_warnings text[] default '{}')
returns shift_requests language plpgsql security definer set search_path = public as $$
declare
  q shift_requests%rowtype;
  s shifts%rowtype;
  v_block text;
  v_note text := btrim(coalesce(p_note, ''));
  v_label text;
  v_title text;
  v_kind text;
  other record;
begin
  select * into q from shift_requests where id = p_request for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  select * into s from shifts where id = q.shift_id for update;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if q.status = 'offered' then
    raise exception 'The coworker has not accepted this swap yet' using errcode = '22023';
  end if;
  if q.status <> 'pending' then raise exception 'This request was already decided' using errcode = '22023'; end if;
  v_label := public.shift_label(s.id);
  v_kind := case q.kind when 'pickup' then 'Pickup' when 'drop' then 'Drop' else 'Swap' end;

  if p_approve then
    if s.call_time <= now() then raise exception 'This shift has already started' using errcode = '22023'; end if;
    if cardinality(coalesce(p_warnings, '{}')) > 0 and length(v_note) = 0 then
      raise exception 'Give a reason to approve despite warnings' using errcode = '22023';
    end if;
    if q.kind = 'pickup' then
      if s.status <> 'open' then raise exception 'This position is already filled. Deny the request.' using errcode = '23505'; end if;
      v_block := public.assignment_block_reason(q.requester_worker_id, s.event_id, s.job_role_code, s.id);
      if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
      perform public.market_set_worker(s.id, q.requester_worker_id,
        'Pickup approved' || case when v_note = '' then '' else ': ' || v_note end, p_warnings);
      -- Anyone else who asked for this position hears it was filled.
      for other in
        update shift_requests set status = 'expired', decision_note = 'Filled by someone else'
         where shift_id = s.id and id <> q.id and status in ('pending', 'offered')
        returning requester_worker_id
      loop
        perform public.notify_worker(other.requester_worker_id, 'request_decided', 'Shift filled', v_label, '/schedule');
      end loop;
    else
      if s.worker_id is distinct from q.requester_worker_id or s.status <> 'assigned' then
        raise exception 'This person no longer holds this position' using errcode = '22023';
      end if;
      if public.has_event_punches(q.requester_worker_id, s.event_id) then
        raise exception 'This person has already clocked in. Move or release them instead.' using errcode = '22023';
      end if;
      if q.kind = 'drop' then
        perform public.market_set_worker(s.id, null,
          'Drop approved' || case when v_note = '' then '' else ': ' || v_note end
          || case when q.note = '' then '' else ' (employee: ' || q.note || ')' end, '{}');
      else
        v_block := public.assignment_block_reason(q.target_worker_id, s.event_id, s.job_role_code, s.id);
        if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
        perform public.market_set_worker(s.id, q.target_worker_id,
          'Swap approved: ' || public.worker_name(q.requester_worker_id) || ' → ' || public.worker_name(q.target_worker_id)
          || case when v_note = '' then '' else ': ' || v_note end, p_warnings);
      end if;
    end if;
  end if;

  update shift_requests set status = case when p_approve then 'approved' else 'denied' end,
         decided_by = (select auth.uid()), decided_at = now(), decision_note = v_note,
         warnings = case when p_approve then coalesce(p_warnings, '{}') else '{}' end
   where id = q.id returning * into q;

  v_title := v_kind || case when p_approve then ' approved' else ' denied' end;
  perform public.notify_worker(q.requester_worker_id, 'request_decided', v_title,
    v_label || case when v_note = '' then '' else E'\n' || v_note end, '/schedule');
  if q.target_worker_id is not null then
    perform public.notify_worker(q.target_worker_id, 'request_decided', v_title,
      v_label || case when v_note = '' then '' else E'\n' || v_note end, '/schedule');
  end if;
  return q;
end $$;

-- ---------------------------------------------------------------------------
-- Assignment candidates now carry each person's answer for the event and whether the
-- event falls in one of their blackouts.
-- ---------------------------------------------------------------------------
create or replace function public.assignment_candidates(p_event uuid, p_role text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  ev events%rowtype;
  v_day date;
begin
  select * into ev from events where id = p_event;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.has_permission(ev.venue_id, 'manage_schedule') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  v_day := public.venue_local_date(ev.venue_id, ev.call_time);
  return coalesce((
    select jsonb_agg(public.rules_worker_json(w.id, v_day) || jsonb_build_object(
        'availability', (select a.status from event_availability a where a.event_id = p_event and a.worker_id = w.id),
        'availability_note', (select a.note from event_availability a where a.event_id = p_event and a.worker_id = w.id),
        'blackout', exists (select 1 from worker_blackouts b where b.worker_id = w.id and v_day between b.starts_on and b.ends_on))
      order by w.last_name, w.first_name)
    from workers w
    where w.venue_id = ev.venue_id and w.status = 'active'
      and exists (select 1 from worker_job_roles r where r.worker_id = w.id and r.job_role_code = p_role)
      and not exists (select 1 from shifts s where s.event_id = p_event and s.worker_id = w.id
                      and s.status in ('assigned', 'released'))), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  -- Internal helpers: not part of the API.
  foreach f in array array[
    'public.self_service_settings(uuid)',
    'public.current_worker()',
    'public.worker_name(uuid)',
    'public.venue_time_label(uuid, timestamp with time zone)',
    'public.shift_label(uuid)',
    'public.notify_schedulers(uuid, text, text, text, jsonb)',
    'public.rules_worker_json(uuid, date)',
    'public.expire_shift_requests(uuid)',
    'public.market_set_worker(uuid, uuid, text, text[])',
    'public.has_event_punches(uuid, uuid)',
    'public.shift_request_json(uuid, boolean)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;

  foreach f in array array[
    'public.open_shifts_for_me()',
    'public.request_pickup(uuid, text)',
    'public.request_drop(uuid, text)',
    'public.my_swap_candidates(uuid)',
    'public.offer_swap(uuid, uuid, text)',
    'public.respond_swap(uuid, boolean)',
    'public.cancel_shift_request(uuid)',
    'public.my_shift_requests()',
    'public.set_event_availability(uuid, text, text)',
    'public.set_blackout(date, date, text, uuid)',
    'public.delete_blackout(uuid)',
    'public.my_availability()',
    'public.review_shift_requests(boolean)',
    'public.decide_shift_request(uuid, boolean, text, text[])',
    'public.assignment_candidates(uuid, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

alter publication supabase_realtime add table public.shift_requests;

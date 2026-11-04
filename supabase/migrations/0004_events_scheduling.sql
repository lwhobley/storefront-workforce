-- Events, open storefronts, staffing needs, shifts (positions), and the assignment log.

create table public.event_types (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null,
  primary key (venue_id, code)
);

create or replace function public.seed_venue_event_types()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into event_types (venue_id, code, name) values
    (new.id, 'hockey', 'Hockey game'),
    (new.id, 'basketball', 'Basketball game'),
    (new.id, 'concert', 'Concert'),
    (new.id, 'family_show', 'Family show'),
    (new.id, 'other', 'Other event')
  on conflict do nothing;
  return new;
end $$;

create trigger venues_seed_event_types after insert on public.venues
for each row execute function public.seed_venue_event_types();

create table public.events (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  event_type_code text not null,
  start_time timestamptz not null,
  call_time timestamptz not null,
  doors_time timestamptz not null,
  end_time timestamptz,
  expected_attendance integer not null default 0 check (expected_attendance >= 0),
  actual_attendance integer check (actual_attendance is null or actual_attendance >= 0),
  status text not null default 'scheduled' check (status in ('scheduled', 'live', 'completed', 'cancelled')),
  -- Where the event came from. Imported events keep their source id so a re-sync
  -- updates the same row instead of creating a duplicate.
  source text not null default 'manual' check (source in ('manual', 'premium_command', 'csv')),
  external_id text,
  -- Set when a manager edits call or doors time, so a re-sync does not overwrite it.
  times_overridden boolean not null default false,
  source_synced_at timestamptz,
  notes text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, event_type_code) references public.event_types(venue_id, code),
  check (call_time <= doors_time and doors_time <= start_time),
  check (end_time is null or end_time > start_time)
);
create unique index events_source_unique on public.events(venue_id, source, external_id) where external_id is not null;
create index events_venue_start_idx on public.events(venue_id, start_time);

-- Storefronts open for an event.
create table public.event_storefronts (
  venue_id uuid not null,
  event_id uuid not null,
  storefront_id uuid not null,
  is_open boolean not null default true,
  primary key (event_id, storefront_id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id) on delete cascade
);

-- Headcount by role for one storefront at one event.
create table public.event_staffing_needs (
  venue_id uuid not null,
  event_id uuid not null,
  storefront_id uuid not null,
  job_role_code text not null,
  count integer not null check (count between 0 and 50),
  primary key (event_id, storefront_id, job_role_code),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code)
);

-- One position at one storefront for one event. worker_id null = open position.
create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  event_id uuid not null,
  storefront_id uuid not null,
  station_id uuid,
  job_role_code text not null,
  worker_id uuid,
  call_time timestamptz not null,
  scheduled_end timestamptz,
  status text not null default 'open' check (status in ('open', 'assigned', 'released', 'cancelled')),
  released_at timestamptz,
  -- 1 for the first person sent home at this event, 2 for the next...
  release_order integer check (release_order is null or release_order > 0),
  release_reason text not null default '',
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id),
  foreign key (venue_id, station_id) references public.stations(venue_id, id) on delete set null (station_id),
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id),
  check ((status = 'open') = (worker_id is null) or status = 'cancelled'),
  check ((status = 'released') = (released_at is not null))
);
create index shifts_event_idx on public.shifts(event_id, storefront_id);
create index shifts_worker_idx on public.shifts(worker_id, call_time) where worker_id is not null;
-- A person holds at most one live position per event.
create unique index shifts_one_per_worker_event on public.shifts(event_id, worker_id)
  where worker_id is not null and status in ('assigned', 'released');
create unique index shifts_release_order_unique on public.shifts(event_id, release_order)
  where release_order is not null;

-- Every assignment, move, and early release, with who did it and why.
create table public.assignment_changes (
  id bigint generated always as identity primary key,
  venue_id uuid not null references public.venues(id) on delete cascade,
  event_id uuid not null,
  shift_id uuid not null,
  action text not null check (action in ('assigned', 'unassigned', 'moved', 'released', 'unreleased')),
  worker_id uuid,
  from_storefront_id uuid,
  to_storefront_id uuid,
  from_station_id uuid,
  to_station_id uuid,
  from_job_role_code text,
  to_job_role_code text,
  reason text not null default '',
  -- Warnings the manager saw and accepted (minor hours, expiring certification...).
  acknowledged_warnings text[] not null default '{}',
  changed_by uuid default auth.uid(),
  changed_at timestamptz not null default now()
);
create index assignment_changes_event_idx on public.assignment_changes(event_id, changed_at);

create trigger events_touch before update on public.events
for each row execute function public.touch_updated_at();
create trigger shifts_touch before update on public.shifts
for each row execute function public.touch_updated_at();

create trigger events_audit after insert or update or delete on public.events
for each row execute function public.audit_row_change();
create trigger event_storefronts_audit after insert or update or delete on public.event_storefronts
for each row execute function public.audit_row_change();
create trigger event_staffing_needs_audit after insert or update or delete on public.event_staffing_needs
for each row execute function public.audit_row_change();
create trigger shifts_audit after insert or update or delete on public.shifts
for each row execute function public.audit_row_change();

-- Times for imported events: manager edits mark them overridden.
create or replace function public.mark_event_times_overridden()
returns trigger language plpgsql set search_path = public as $$
begin
  if (new.call_time is distinct from old.call_time or new.doors_time is distinct from old.doors_time)
     and coalesce(current_setting('app.event_sync', true), '') <> 'on' then
    new.times_overridden := true;
  end if;
  return new;
end $$;

create trigger events_mark_overridden before update on public.events
for each row execute function public.mark_event_times_overridden();

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table public.event_types enable row level security;
alter table public.events enable row level security;
alter table public.event_storefronts enable row level security;
alter table public.event_staffing_needs enable row level security;
alter table public.shifts enable row level security;
alter table public.assignment_changes enable row level security;
revoke all on public.event_types, public.events, public.event_storefronts, public.event_staffing_needs,
  public.shifts, public.assignment_changes from anon;

create policy event_types_read on public.event_types for select to authenticated
  using (public.is_venue_member(venue_id));
create policy event_types_write on public.event_types for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings'))
  with check (public.has_venue_permission(venue_id, 'manage_settings'));

create policy events_read on public.events for select to authenticated
  using (public.is_venue_member(venue_id));
create policy events_insert on public.events for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_events') and source = 'manual');
create policy events_update on public.events for update to authenticated
  using (public.has_venue_permission(venue_id, 'manage_events'))
  with check (public.has_venue_permission(venue_id, 'manage_events'));
revoke update on public.events from authenticated;
grant update (name, event_type_code, start_time, call_time, doors_time, end_time,
  expected_attendance, actual_attendance, status, notes) on public.events to authenticated;

create policy event_storefronts_read on public.event_storefronts for select to authenticated
  using (public.is_venue_member(venue_id));
create policy event_staffing_needs_read on public.event_staffing_needs for select to authenticated
  using (public.is_venue_member(venue_id));
revoke insert, update, delete on public.event_storefronts, public.event_staffing_needs from authenticated;

create policy shifts_read on public.shifts for select to authenticated
  using (
    public.has_venue_permission(venue_id, 'manage_schedule')
    or public.can_on_storefront(storefront_id, 'view_live')
    or public.can_on_storefront(storefront_id, 'manage_schedule')
    or (worker_id is not null and exists (
      select 1 from public.workers w where w.id = shifts.worker_id and w.user_id = (select auth.uid())))
    -- Agency contacts and NPO coordinators see their own people's shifts.
    or (worker_id is not null and public.can_view_worker(worker_id))
  );
-- Shifts change only through the functions below, which check scope and log each change.
revoke insert, update, delete on public.shifts from authenticated;

create policy assignment_changes_read on public.assignment_changes for select to authenticated
  using (
    public.has_venue_permission(venue_id, 'view_audit')
    or public.has_venue_permission(venue_id, 'manage_schedule')
    or (from_storefront_id is not null and public.can_on_storefront(from_storefront_id, 'manage_schedule'))
    or (to_storefront_id is not null and public.can_on_storefront(to_storefront_id, 'manage_schedule'))
  );
revoke insert, update, delete on public.assignment_changes from authenticated;

-- ---------------------------------------------------------------------------
-- Schedule functions
-- ---------------------------------------------------------------------------

-- The venue-local calendar date of an instant.
create or replace function public.venue_local_date(p_venue uuid, p_at timestamptz)
returns date language sql stable security definer set search_path = public as $$
  select (p_at at time zone v.time_zone)::date from venues v where v.id = p_venue;
$$;

-- Opens exactly the given storefronts for the event and copies their default headcount
-- the first time each is opened.
create or replace function public.set_event_storefronts(p_event uuid, p_storefronts uuid[])
returns void language plpgsql security definer set search_path = public as $$
declare
  ev events%rowtype;
begin
  select * into ev from events where id = p_event;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(ev.venue_id, 'manage_events') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if exists (select 1 from unnest(p_storefronts) s
             where not exists (select 1 from storefronts f where f.id = s and f.venue_id = ev.venue_id)) then
    raise exception 'Unknown storefront' using errcode = '22023';
  end if;

  update event_storefronts set is_open = (storefront_id = any (p_storefronts))
   where event_id = p_event and is_open is distinct from (storefront_id = any (p_storefronts));

  insert into event_storefronts (venue_id, event_id, storefront_id, is_open)
  select ev.venue_id, p_event, s, true from unnest(p_storefronts) s
  on conflict (event_id, storefront_id) do nothing;

  insert into event_staffing_needs (venue_id, event_id, storefront_id, job_role_code, count)
  select ev.venue_id, p_event, n.storefront_id, n.job_role_code, n.count
  from storefront_staffing_needs n
  where n.storefront_id = any (p_storefronts)
    and not exists (select 1 from event_staffing_needs e where e.event_id = p_event and e.storefront_id = n.storefront_id)
  on conflict do nothing;
end $$;

create or replace function public.set_event_staffing_need(p_event uuid, p_storefront uuid, p_role text, p_count integer)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid;
begin
  select venue_id into v_venue from events where id = p_event;
  if v_venue is null then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.can_on_storefront(p_storefront, 'manage_schedule') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  insert into event_staffing_needs (venue_id, event_id, storefront_id, job_role_code, count)
  values (v_venue, p_event, p_storefront, p_role, p_count)
  on conflict (event_id, storefront_id, job_role_code) do update set count = excluded.count;
end $$;

-- Creates open positions so each open storefront has one shift per needed person.
-- Never removes positions. Returns how many were created.
create or replace function public.generate_open_shifts(p_event uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  ev events%rowtype;
  v_created integer := 0;
  n record;
  v_have integer;
begin
  select * into ev from events where id = p_event;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  if not public.has_permission(ev.venue_id, 'manage_schedule') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  for n in
    select e.storefront_id, e.job_role_code, e.count
    from event_staffing_needs e
    join event_storefronts s on s.event_id = e.event_id and s.storefront_id = e.storefront_id and s.is_open
    where e.event_id = p_event
      and e.storefront_id in (select public.storefronts_in_scope(ev.venue_id, 'manage_schedule'))
  loop
    select count(*) into v_have from shifts
     where event_id = p_event and storefront_id = n.storefront_id and job_role_code = n.job_role_code
       and status <> 'cancelled';
    if v_have < n.count then
      insert into shifts (venue_id, event_id, storefront_id, job_role_code, call_time, scheduled_end, status)
      select ev.venue_id, p_event, n.storefront_id, n.job_role_code,
             case when n.job_role_code = 'lead' then ev.call_time - interval '30 minutes' else ev.call_time end,
             coalesce(ev.end_time, ev.start_time + interval '3 hours') + interval '45 minutes',
             'open'
      from generate_series(1, n.count - v_have);
      v_created := v_created + (n.count - v_have);
    end if;
  end loop;
  return v_created;
end $$;

-- Hard checks that block an assignment no matter what. Returns null when allowed,
-- otherwise the reason. Warnings (minor hour limits, expiring certifications) are
-- computed by the app's rules engine and recorded as acknowledged warnings.
create or replace function public.assignment_block_reason(p_worker uuid, p_event uuid, p_role text, p_shift uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
  ev events%rowtype;
  r job_roles%rowtype;
  v_day date;
  v_age integer;
  v_cert text;
  v_enforcement text;
begin
  select * into w from workers where id = p_worker;
  select * into ev from events where id = p_event;
  select * into r from job_roles where venue_id = ev.venue_id and code = p_role;
  if w.id is null or w.venue_id <> ev.venue_id then return 'This person is not on this venue''s staff.'; end if;
  if w.status <> 'active' then return 'This person is inactive.'; end if;
  if exists (select 1 from shifts s where s.event_id = p_event and s.worker_id = p_worker
             and s.status in ('assigned', 'released') and s.id <> p_shift) then
    return 'This person already has a position at this event.';
  end if;

  v_day := public.venue_local_date(ev.venue_id, ev.call_time);
  if w.date_of_birth is not null then
    v_age := extract(year from age(v_day, w.date_of_birth))::integer;
    if r.minimum_age is not null and v_age < r.minimum_age then
      return format('%s must be at least %s; this person is %s.', r.name, r.minimum_age, v_age);
    end if;
    if v_age < coalesce((select (settings -> 'minors' ->> 'minimum_working_age')::integer from venues where id = ev.venue_id), 14) then
      return 'This person is under the minimum working age.';
    end if;
  elsif r.minimum_age is not null then
    return format('%s needs a birth date on file to check the minimum age of %s.', r.name, r.minimum_age);
  end if;

  select coalesce(settings -> 'certifications' ->> 'enforcement', 'block') into v_enforcement
    from venues where id = ev.venue_id;
  if v_enforcement = 'block' then
    foreach v_cert in array r.required_certifications loop
      if not exists (
        select 1 from worker_certifications c
        where c.worker_id = p_worker and c.cert_type_code = v_cert
          and (c.expires_on is null or c.expires_on >= v_day)
      ) then
        return format('%s needs a current %s.', r.name,
          coalesce((select name from certification_types where venue_id = ev.venue_id and code = v_cert), v_cert));
      end if;
    end loop;
  end if;
  return null;
end $$;

create or replace function public.log_assignment_change(
  p_shift shifts, p_action text, p_worker uuid, p_from shifts, p_reason text, p_warnings text[])
returns void language sql security definer set search_path = public as $$
  insert into assignment_changes (venue_id, event_id, shift_id, action, worker_id,
    from_storefront_id, to_storefront_id, from_station_id, to_station_id,
    from_job_role_code, to_job_role_code, reason, acknowledged_warnings)
  values (p_shift.venue_id, p_shift.event_id, p_shift.id, p_action, p_worker,
    p_from.storefront_id, p_shift.storefront_id, p_from.station_id, p_shift.station_id,
    p_from.job_role_code, p_shift.job_role_code, coalesce(p_reason, ''), coalesce(p_warnings, '{}'));
$$;

-- Puts a person in an open position. p_warnings lists the warnings the manager accepted.
create or replace function public.assign_shift(p_shift uuid, p_worker uuid, p_reason text default '', p_warnings text[] default '{}')
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
  v_block text;
begin
  select * into s from shifts where id = p_shift for update;
  if not found then raise exception 'Position not found' using errcode = 'P0002'; end if;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if s.status <> 'open' then
    raise exception 'This position is already filled' using errcode = '23505';
  end if;
  v_block := public.assignment_block_reason(p_worker, s.event_id, s.job_role_code, s.id);
  if v_block is not null then
    raise exception '%', v_block using errcode = 'P0001';
  end if;
  if cardinality(coalesce(p_warnings, '{}')) > 0 and length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Give a reason to assign despite warnings' using errcode = '22023';
  end if;
  before := s;
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  update shifts set worker_id = p_worker, status = 'assigned', version = version + 1
   where id = p_shift returning * into s;
  perform public.log_assignment_change(s, 'assigned', p_worker, before, p_reason, p_warnings);
  return s;
end $$;

create or replace function public.unassign_shift(p_shift uuid, p_reason text default '')
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
begin
  select * into s from shifts where id = p_shift for update;
  if not found then raise exception 'Position not found' using errcode = 'P0002'; end if;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if s.status <> 'assigned' then
    raise exception 'Only an assigned position can be cleared' using errcode = '22023';
  end if;
  if exists (select 1 from punches p where p.event_id = s.event_id and p.worker_id = s.worker_id and p.status <> 'voided') then
    raise exception 'This person has already clocked in. Move or release them instead.' using errcode = '22023';
  end if;
  before := s;
  perform set_config('app.audit_reason', coalesce(p_reason, ''), true);
  update shifts set worker_id = null, status = 'open', version = version + 1
   where id = p_shift returning * into s;
  perform public.log_assignment_change(s, 'unassigned', before.worker_id, before, p_reason, '{}');
  return s;
end $$;

-- Moves a person to another storefront, station, or role during an event. When the
-- destination has an open position for the same role, the person takes it and their old
-- position becomes open, so headcount stays accurate on both sides.
create or replace function public.move_shift(
  p_shift uuid, p_storefront uuid, p_station uuid default null, p_role text default null,
  p_reason text default '', p_warnings text[] default '{}')
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
  target shifts%rowtype;
  v_role text;
  v_block text;
  v_worker uuid;
begin
  select * into s from shifts where id = p_shift for update;
  if not found then raise exception 'Position not found' using errcode = 'P0002'; end if;
  if s.status <> 'assigned' then raise exception 'Only an assigned person can be moved' using errcode = '22023'; end if;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule')
     or not public.can_on_storefront(p_storefront, 'manage_schedule') then
    raise exception 'Not authorized for both storefronts' using errcode = '42501';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Give a reason for the move' using errcode = '22023';
  end if;
  if not exists (select 1 from storefronts f where f.id = p_storefront and f.venue_id = s.venue_id) then
    raise exception 'Unknown storefront' using errcode = '22023';
  end if;
  if p_station is not null and not exists (select 1 from stations t where t.id = p_station and t.storefront_id = p_storefront) then
    raise exception 'That station is not at the destination storefront' using errcode = '22023';
  end if;
  v_role := coalesce(p_role, s.job_role_code);
  v_worker := s.worker_id;
  if v_role <> s.job_role_code then
    v_block := public.assignment_block_reason(v_worker, s.event_id, v_role, s.id);
    if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
  end if;

  before := s;
  perform set_config('app.audit_reason', p_reason, true);

  select * into target from shifts
   where event_id = s.event_id and storefront_id = p_storefront and job_role_code = v_role and status = 'open'
   order by call_time, created_at limit 1 for update skip locked;

  if target.id is not null and target.id <> s.id then
    update shifts set worker_id = null, status = 'open', version = version + 1 where id = s.id;
    update shifts set worker_id = v_worker, status = 'assigned',
           station_id = coalesce(p_station, station_id), version = version + 1
     where id = target.id returning * into s;
  else
    update shifts set storefront_id = p_storefront, station_id = p_station, job_role_code = v_role,
           version = version + 1
     where id = s.id returning * into s;
  end if;
  perform public.log_assignment_change(s, 'moved', v_worker, before, p_reason, p_warnings);
  return s;
end $$;

-- Sends a person home early. The release order is kept per event so cuts are documented.
create or replace function public.release_shift(p_shift uuid, p_reason text)
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
  v_order integer;
begin
  select * into s from shifts where id = p_shift for update;
  if not found then raise exception 'Position not found' using errcode = 'P0002'; end if;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if s.status <> 'assigned' then raise exception 'Only an assigned person can be sent home' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Give a reason for sending this person home' using errcode = '22023';
  end if;
  -- Serialize release numbering per event.
  perform pg_advisory_xact_lock(hashtext('release:' || s.event_id::text));
  select coalesce(max(release_order), 0) + 1 into v_order from shifts where event_id = s.event_id;
  before := s;
  perform set_config('app.audit_reason', p_reason, true);
  update shifts set status = 'released', released_at = now(), release_order = v_order,
         release_reason = p_reason, version = version + 1
   where id = p_shift returning * into s;
  perform public.log_assignment_change(s, 'released', s.worker_id, before, p_reason, '{}');
  return s;
end $$;

-- Reverses a release made by mistake. The release number stays used, so the record of
-- the original order is not rewritten.
create or replace function public.unrelease_shift(p_shift uuid, p_reason text)
returns shifts language plpgsql security definer set search_path = public as $$
declare
  s shifts%rowtype;
  before shifts%rowtype;
begin
  select * into s from shifts where id = p_shift for update;
  if not found then raise exception 'Position not found' using errcode = 'P0002'; end if;
  if not public.can_on_storefront(s.storefront_id, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if s.status <> 'released' then raise exception 'This person was not sent home' using errcode = '22023'; end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Give a reason' using errcode = '22023';
  end if;
  before := s;
  perform set_config('app.audit_reason', p_reason, true);
  update shifts set status = 'assigned', released_at = null, release_order = null, version = version + 1
   where id = p_shift returning * into s;
  perform public.log_assignment_change(s, 'unreleased', s.worker_id, before, p_reason, '{}');
  return s;
end $$;

revoke execute on function public.assignment_block_reason(uuid, uuid, text, uuid) from public, anon;
revoke execute on function public.log_assignment_change(shifts, text, uuid, shifts, text, text[]) from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'public.set_event_storefronts(uuid, uuid[])',
    'public.set_event_staffing_need(uuid, uuid, text, integer)',
    'public.generate_open_shifts(uuid)',
    'public.assign_shift(uuid, uuid, text, text[])',
    'public.unassign_shift(uuid, text)',
    'public.move_shift(uuid, uuid, uuid, text, text, text[])',
    'public.release_shift(uuid, text)',
    'public.unrelease_shift(uuid, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

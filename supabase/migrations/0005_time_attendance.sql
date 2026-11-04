-- Time and attendance: punches (clock in/out and breaks), photo storage, and the live
-- event board.
--
-- Offline rule: the device creates each punch's id. Sending the same punch twice stores
-- it once, so a sync that retries never duplicates time. The device clock time
-- (occurred_at) and the server time (received_at) are both kept; large gaps are flagged
-- for review instead of being rejected, so no time is lost.

create table public.punches (
  id uuid primary key,
  venue_id uuid not null,
  worker_id uuid not null,
  event_id uuid,
  shift_id uuid,
  kind text not null check (kind in ('clock_in', 'clock_out', 'break_start', 'break_end')),
  break_kind text check (break_kind in ('meal', 'rest')),
  occurred_at timestamptz not null,
  received_at timestamptz not null default now(),
  source text not null check (source in ('phone', 'kiosk', 'manager')),
  device_id text not null default '' check (length(device_id) <= 64),
  latitude double precision check (latitude is null or latitude between -90 and 90),
  longitude double precision check (longitude is null or longitude between -180 and 180),
  accuracy_m double precision check (accuracy_m is null or accuracy_m >= 0),
  within_geofence boolean,
  photo_path text,
  status text not null default 'accepted' check (status in ('accepted', 'needs_review', 'voided')),
  review_note text not null default '',
  entered_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id),
  foreign key (venue_id, event_id) references public.events(venue_id, id),
  foreign key (venue_id, shift_id) references public.shifts(venue_id, id) on delete set null (shift_id),
  check ((kind = 'break_start') = (break_kind is not null) or kind = 'break_end')
);
create index punches_worker_time_idx on public.punches(worker_id, occurred_at);
create index punches_event_idx on public.punches(event_id, worker_id);

-- Punch records are never deleted. Corrections (phase 2) void a punch and add a new one,
-- each with an approval and a reason.
create trigger punches_audit after insert or update on public.punches
for each row execute function public.audit_row_change();

create or replace function public.can_view_punches_of(p_worker uuid, p_shift uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.can_view_worker(p_worker)
      or exists (select 1 from workers w where w.id = p_worker and public.has_venue_permission(w.venue_id, 'view_live'))
      or (p_shift is not null and exists (
            select 1 from shifts s where s.id = p_shift and public.can_on_storefront(s.storefront_id, 'view_live')));
$$;

alter table public.punches enable row level security;
revoke all on public.punches from anon;
revoke insert, update, delete on public.punches from authenticated;

create policy punches_read on public.punches for select to authenticated
  using (public.can_view_punches_of(worker_id, shift_id));

-- Shared validation and insert for every punch path.
create or replace function public.insert_punch(p_worker workers, p_punch jsonb, p_source text)
returns punches language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p_punch ->> 'id')::uuid;
  v_existing punches%rowtype;
  v_row punches%rowtype;
  v_event uuid := nullif(p_punch ->> 'event_id', '')::uuid;
  v_shift uuid := nullif(p_punch ->> 'shift_id', '')::uuid;
  v_occurred timestamptz := (p_punch ->> 'occurred_at')::timestamptz;
  v_status text := 'accepted';
  v_note text := '';
  v_geo jsonb;
begin
  if v_id is null or v_occurred is null then
    raise exception 'A punch needs an id and a time' using errcode = '22023';
  end if;

  -- Same id again: return what is stored. A different person reusing the id is refused.
  select * into v_existing from punches where id = v_id;
  if found then
    if v_existing.worker_id <> p_worker.id then
      raise exception 'Punch id already used' using errcode = '23505';
    end if;
    return v_existing;
  end if;

  if p_worker.status <> 'active' then
    raise exception 'This person is inactive' using errcode = '42501';
  end if;
  if v_event is not null and not exists (select 1 from events e where e.id = v_event and e.venue_id = p_worker.venue_id) then
    raise exception 'Unknown event' using errcode = '22023';
  end if;
  if v_shift is not null and not exists (
      select 1 from shifts s where s.id = v_shift and s.worker_id = p_worker.id and s.event_id is not distinct from v_event) then
    -- The person may have been moved to another position while offline; keep the punch,
    -- drop the stale position link.
    v_shift := null;
  end if;

  if v_occurred > now() + interval '5 minutes' then
    v_status := 'needs_review';
    v_note := 'Device clock is ahead of the server.';
  elsif v_occurred < now() - interval '12 hours' then
    v_status := 'needs_review';
    v_note := 'Sent more than 12 hours after it was recorded.';
  end if;

  select settings -> 'clock' -> 'geofence' into v_geo from venues where id = p_worker.venue_id;
  if coalesce((v_geo ->> 'enabled')::boolean, false) and p_source = 'phone'
     and coalesce((p_punch ->> 'within_geofence')::boolean, false) is false then
    v_status := 'needs_review';
    v_note := trim(v_note || ' Outside the venue area.');
  end if;

  insert into punches (id, venue_id, worker_id, event_id, shift_id, kind, break_kind, occurred_at,
    source, device_id, latitude, longitude, accuracy_m, within_geofence, photo_path, status, review_note)
  values (v_id, p_worker.venue_id, p_worker.id, v_event, v_shift, p_punch ->> 'kind',
    nullif(p_punch ->> 'break_kind', ''), v_occurred, p_source,
    coalesce(p_punch ->> 'device_id', ''),
    (p_punch ->> 'latitude')::double precision, (p_punch ->> 'longitude')::double precision,
    (p_punch ->> 'accuracy_m')::double precision, (p_punch ->> 'within_geofence')::boolean,
    nullif(p_punch ->> 'photo_path', ''), v_status, v_note)
  on conflict (id) do nothing
  returning * into v_row;

  if v_row.id is null then
    select * into v_row from punches where id = v_id;
  end if;
  return v_row;
end $$;

-- A signed-in person clocking themselves.
create or replace function public.record_punch(p_punch jsonb)
returns punches language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where user_id = (select auth.uid()) and status = 'active'
   and (nullif(p_punch ->> 'venue_id', '') is null or venue_id = (p_punch ->> 'venue_id')::uuid)
   limit 1;
  if not found then
    raise exception 'No staff record is linked to this sign-in' using errcode = '42501';
  end if;
  if not public.has_permission(w.venue_id, 'punch_self') then
    raise exception 'Not allowed to clock in' using errcode = '42501';
  end if;
  if not coalesce((select (settings -> 'clock' ->> 'allow_phone')::boolean from venues where id = w.venue_id), true) then
    raise exception 'Clock in at the kiosk' using errcode = '42501';
  end if;
  return public.insert_punch(w, p_punch, 'phone');
end $$;

-- A kiosk clocking someone who entered their PIN. Called only by the kiosk-punch
-- function after it has matched the PIN (service role).
create or replace function public.record_kiosk_punch(p_kiosk_user uuid, p_worker_user uuid, p_punch jsonb)
returns punches language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype;
  v_venue uuid;
  v_row punches%rowtype;
begin
  -- The kiosk's venue: where its account holds kiosk_punch.
  select ra.venue_id into v_venue
    from role_assignments ra join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
   where ra.user_id = p_kiosk_user and 'kiosk_punch' = any (r.permissions) limit 1;
  if v_venue is null then
    raise exception 'This device is not a kiosk' using errcode = '42501';
  end if;
  select * into w from workers where user_id = p_worker_user and venue_id = v_venue;
  if not found then
    raise exception 'That PIN is not on this venue''s staff' using errcode = '42501';
  end if;
  v_row := public.insert_punch(w, p_punch, 'kiosk');
  update punches set entered_by = p_kiosk_user where id = v_row.id and entered_by is null;
  return v_row;
end $$;

revoke execute on function public.insert_punch(workers, jsonb, text) from public, anon, authenticated;
revoke execute on function public.record_kiosk_punch(uuid, uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.record_punch(jsonb) from public, anon;
grant execute on function public.record_punch(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Live event board: everything the live view and arena map need for the caller's
-- scope, in one call. Leads get only their storefronts; birth dates are reduced to
-- age on the event date.
-- ---------------------------------------------------------------------------
create or replace function public.event_board(p_event uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  ev events%rowtype;
  v_tz text;
  v_settings jsonb;
  v_storefronts uuid[];
  v_day date;
  v_week_start timestamptz;
  v_start_day integer;
  v_workers uuid[];
begin
  select * into ev from events where id = p_event;
  if not found then raise exception 'Event not found' using errcode = 'P0002'; end if;
  select time_zone, settings into v_tz, v_settings from venues where id = ev.venue_id;

  select array_agg(distinct id) into v_storefronts from (
    select public.storefronts_in_scope(ev.venue_id, 'view_live') as id
    union select public.storefronts_in_scope(ev.venue_id, 'manage_schedule')
  ) s;
  if v_storefronts is null then
    raise exception 'Not authorized' using errcode = '42501';
  end if;

  select array_agg(distinct worker_id) into v_workers
    from shifts where event_id = p_event and storefront_id = any (v_storefronts) and worker_id is not null;
  v_workers := coalesce(v_workers, '{}');

  -- Start of the workweek containing the event, at local midnight.
  v_day := (ev.call_time at time zone v_tz)::date;
  v_start_day := coalesce((v_settings -> 'overtime' ->> 'workweek_start_day')::integer, 1);
  v_week_start := ((v_day - ((extract(isodow from v_day)::integer - v_start_day + 7) % 7))::timestamp) at time zone v_tz;

  return jsonb_build_object(
    'event', to_jsonb(ev),
    'time_zone', v_tz,
    'week_start', v_week_start,
    'can_manage_all', public.has_venue_permission(ev.venue_id, 'manage_schedule'),
    'storefront_ids', to_jsonb(v_storefronts),
    'event_storefronts', coalesce((
      select jsonb_agg(to_jsonb(es)) from event_storefronts es
      where es.event_id = p_event and es.storefront_id = any (v_storefronts)), '[]'::jsonb),
    'needs', coalesce((
      select jsonb_agg(to_jsonb(n)) from event_staffing_needs n
      where n.event_id = p_event and n.storefront_id = any (v_storefronts)), '[]'::jsonb),
    'shifts', coalesce((
      select jsonb_agg(to_jsonb(s) order by s.storefront_id, s.job_role_code) from shifts s
      where s.event_id = p_event and s.storefront_id = any (v_storefronts) and s.status <> 'cancelled'), '[]'::jsonb),
    'workers', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', w.id, 'venue_id', w.venue_id, 'worker_type', w.worker_type,
        'employee_number', w.employee_number, 'first_name', w.first_name, 'last_name', w.last_name,
        'preferred_name', w.preferred_name, 'photo_path', w.photo_path, 'hire_date', w.hire_date,
        'agency_id', w.agency_id, 'npo_group_id', w.npo_group_id, 'phone',
          case when public.has_venue_permission(ev.venue_id, 'view_workers') then w.phone else '' end,
        'age_on_event', case when w.date_of_birth is null then null
                             else extract(year from age(v_day, w.date_of_birth))::integer end,
        'job_roles', coalesce((select jsonb_agg(r.job_role_code) from worker_job_roles r where r.worker_id = w.id), '[]'::jsonb),
        'certifications', coalesce((select jsonb_agg(jsonb_build_object(
            'id', c.id, 'worker_id', c.worker_id, 'cert_type_code', c.cert_type_code, 'expires_on', c.expires_on))
            from worker_certifications c where c.worker_id = w.id), '[]'::jsonb)))
      from workers w where w.id = any (v_workers)), '[]'::jsonb),
    -- This event's punches plus earlier punches in the same workweek (for overtime).
    'punches', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.occurred_at) from punches p
      where p.worker_id = any (v_workers) and p.status <> 'voided'
        and (p.event_id = p_event or (p.occurred_at >= v_week_start and p.occurred_at < ev.call_time))), '[]'::jsonb),
    'changes', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', c.id, 'event_id', c.event_id, 'shift_id', c.shift_id, 'action', c.action,
        'worker_id', c.worker_id, 'from_storefront_id', c.from_storefront_id, 'to_storefront_id', c.to_storefront_id,
        'from_job_role_code', c.from_job_role_code, 'to_job_role_code', c.to_job_role_code,
        'reason', c.reason, 'changed_at', c.changed_at,
        'changed_by_name', coalesce((select display_name from user_profiles u where u.id = c.changed_by), ''))
        order by c.changed_at desc)
      from assignment_changes c
      where c.event_id = p_event
        and (c.from_storefront_id = any (v_storefronts) or c.to_storefront_id = any (v_storefronts))), '[]'::jsonb)
  );
end $$;

revoke execute on function public.event_board(uuid) from public, anon;
grant execute on function public.event_board(uuid) to authenticated;

-- Workers available to fill a position: active, trained for the role, not already at
-- the event. Returned with age and certifications so the app can show warnings.
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
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'venue_id', w.venue_id, 'worker_type', w.worker_type,
      'employee_number', w.employee_number, 'first_name', w.first_name, 'last_name', w.last_name,
      'preferred_name', w.preferred_name, 'photo_path', w.photo_path, 'hire_date', w.hire_date,
      'agency_id', w.agency_id, 'npo_group_id', w.npo_group_id,
      'age_on_event', case when w.date_of_birth is null then null
                           else extract(year from age(v_day, w.date_of_birth))::integer end,
      'job_roles', (select jsonb_agg(r.job_role_code) from worker_job_roles r where r.worker_id = w.id),
      'certifications', coalesce((select jsonb_agg(jsonb_build_object(
          'id', c.id, 'worker_id', c.worker_id, 'cert_type_code', c.cert_type_code, 'expires_on', c.expires_on))
          from worker_certifications c where c.worker_id = w.id), '[]'::jsonb))
      order by w.last_name, w.first_name)
    from workers w
    where w.venue_id = ev.venue_id and w.status = 'active'
      and exists (select 1 from worker_job_roles r where r.worker_id = w.id and r.job_role_code = p_role)
      and not exists (select 1 from shifts s where s.event_id = p_event and s.worker_id = w.id
                      and s.status in ('assigned', 'released'))), '[]'::jsonb);
end $$;

revoke execute on function public.assignment_candidates(uuid, text) from public, anon;
grant execute on function public.assignment_candidates(uuid, text) to authenticated;

-- Realtime for the live view (row level security still applies to each subscriber).
alter publication supabase_realtime add table public.punches, public.shifts;

-- ---------------------------------------------------------------------------
-- Photo storage. Private buckets; paths start with the venue id.
--   punch-photos/<venue_id>/<worker_id>/<punch_id>.jpg
--   worker-photos/<venue_id>/<worker_id>.jpg
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('punch-photos', 'punch-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('worker-photos', 'worker-photos', false, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create or replace function public.storage_venue(p_name text)
returns uuid language sql immutable as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-f-]{36}$' then split_part(p_name, '/', 1)::uuid end;
$$;

create or replace function public.storage_worker(p_name text)
returns uuid language sql immutable as $$
  select case when split_part(p_name, '/', 2) ~ '^[0-9a-f-]{36}' then left(split_part(p_name, '/', 2), 36)::uuid end;
$$;

create policy punch_photos_insert_own on storage.objects for insert to authenticated
  with check (
    bucket_id = 'punch-photos'
    and exists (select 1 from public.workers w
                where w.id = public.storage_worker(name) and w.venue_id = public.storage_venue(name)
                  and w.user_id = (select auth.uid()))
  );

create policy punch_photos_read on storage.objects for select to authenticated
  using (
    bucket_id = 'punch-photos'
    and (public.has_venue_permission(public.storage_venue(name), 'view_live')
         or exists (select 1 from public.workers w
                    where w.id = public.storage_worker(name) and w.user_id = (select auth.uid())))
  );

create policy worker_photos_read on storage.objects for select to authenticated
  using (bucket_id = 'worker-photos' and public.is_venue_member(public.storage_venue(name)));

create policy worker_photos_write on storage.objects for insert to authenticated
  with check (bucket_id = 'worker-photos' and public.has_venue_permission(public.storage_venue(name), 'manage_workers'));

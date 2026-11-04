-- Two fixes found while finishing Phase 3:
--
-- 1. Agency contacts and NPO coordinators could read their people's full staff records
--    (birth dates, addresses, emergency contacts) straight from the workers table. They
--    now see people only through npo_portal() / agency_portal(), which return just what
--    each portal needs. Their access to shifts, roles and cards (can_view_worker) is
--    unchanged.
-- 2. A card photo an employee uploads during onboarding is stored as a certification
--    with document_path set and no verifier. Until a manager verifies it, it no longer
--    counts for scheduling (hard block, live board, request rules). Cards a manager
--    enters directly (no document_path) count as before.

drop policy if exists workers_read on public.workers;
create policy workers_read on public.workers for select to authenticated
  using (user_id = (select auth.uid()) or public.has_venue_permission(venue_id, 'view_workers'));

-- True when a card counts toward scheduling rules.
create or replace function public.cert_accepted(p_document_path text, p_verified_by uuid)
returns boolean language sql immutable set search_path = public as $$
  select p_document_path is null or p_verified_by is not null;
$$;

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
          and public.cert_accepted(c.document_path, c.verified_by)
      ) then
        return format('%s needs a current %s.', r.name,
          coalesce((select name from certification_types where venue_id = ev.venue_id and code = v_cert), v_cert));
      end if;
    end loop;
  end if;
  return null;
end $$;

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
            from worker_certifications c where c.worker_id = w.id and public.cert_accepted(c.document_path, c.verified_by)), '[]'::jsonb)))
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
          from worker_certifications c where c.worker_id = w.id and public.cert_accepted(c.document_path, c.verified_by)), '[]'::jsonb))
  from workers w where w.id = p_worker;
$$;

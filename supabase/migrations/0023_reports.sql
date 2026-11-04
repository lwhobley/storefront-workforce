-- Reports (Phase 4): labor budgets for pay viewers, seasons worked for turnover and
-- retention, and closing the labor budget privacy gap.
--
-- 1. events.labor_budget and event_storefronts.labor_budget are pay information. Until
--    now any venue member could read them from the tables (the app selected events with
--    `*`). The app now lists its columns, so the budget columns are taken out of the
--    table-level read grant here, and pay viewers read budgets through
--    report_labor_budgets(). Writing budgets is unchanged (0009: view_pay).
-- 2. event_board() returned the event row and its storefront rows with the budget in
--    them; it now leaves the budget out.
-- 3. report_worker_seasons(): how many events each person clocked in at, per season, so
--    the app can show turnover and retention without reading every punch ever.

-- ---------------------------------------------------------------------------
-- 1. Budget columns: not readable from the tables
-- ---------------------------------------------------------------------------
revoke select on public.events from authenticated, anon;
grant select (id, venue_id, name, event_type_code, start_time, call_time, doors_time, end_time,
  expected_attendance, actual_attendance, status, source, external_id, times_overridden,
  source_synced_at, notes, created_at, updated_at) on public.events to authenticated;

revoke select on public.event_storefronts from authenticated, anon;
grant select (venue_id, event_id, storefront_id, is_open) on public.event_storefronts to authenticated;

-- Budgets for events starting in [p_from, p_to): one row per event (storefront_id null)
-- and one per storefront that has a budget. view_pay for the whole venue.
create or replace function public.report_labor_budgets(p_venue uuid, p_from timestamptz, p_to timestamptz)
returns table (event_id uuid, storefront_id uuid, labor_budget numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_venue_permission(p_venue, 'view_pay') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return query
    select e.id, null::uuid, e.labor_budget
    from events e
    where e.venue_id = p_venue and e.start_time >= p_from and e.start_time < p_to and e.labor_budget is not null
    union all
    select es.event_id, es.storefront_id, es.labor_budget
    from event_storefronts es
    join events e on e.id = es.event_id
    where e.venue_id = p_venue and e.start_time >= p_from and e.start_time < p_to and es.labor_budget is not null;
end $$;
revoke execute on function public.report_labor_budgets(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.report_labor_budgets(uuid, timestamptz, timestamptz) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. The live board without budgets (otherwise as in 0018)
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
    'event', to_jsonb(ev) - 'labor_budget',
    'time_zone', v_tz,
    'week_start', v_week_start,
    'can_manage_all', public.has_venue_permission(ev.venue_id, 'manage_schedule'),
    'storefront_ids', to_jsonb(v_storefronts),
    'event_storefronts', coalesce((
      select jsonb_agg(to_jsonb(es) - 'labor_budget') from event_storefronts es
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

-- ---------------------------------------------------------------------------
-- 3. Seasons worked, for turnover and retention
-- ---------------------------------------------------------------------------
-- A season starts on the first of p_start_month (venue setting
-- reports.season_start_month, default August) in venue time. "Worked" means a clock-in
-- (not voided) at an event that was not cancelled. Same rule as the app's
-- workerSeasonsFromPunches(). view_reports for the whole venue.
create or replace function public.report_worker_seasons(p_venue uuid, p_start_month integer default 8)
returns table (worker_id uuid, season integer, events_worked integer)
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text;
begin
  if not public.has_venue_permission(p_venue, 'view_reports') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_start_month is null or p_start_month not between 1 and 12 then
    raise exception 'The season start month must be 1 to 12' using errcode = '22023';
  end if;
  select time_zone into v_tz from venues where id = p_venue;
  return query
    select p.worker_id,
           (extract(year from (e.start_time at time zone v_tz))::integer
             - case when extract(month from (e.start_time at time zone v_tz))::integer < p_start_month then 1 else 0 end) as season,
           count(distinct e.id)::integer
    from punches p
    join events e on e.id = p.event_id
    where p.venue_id = p_venue and e.venue_id = p_venue
      and p.kind = 'clock_in' and p.status <> 'voided' and e.status <> 'cancelled'
    group by 1, 2
    order by 2, 1;
end $$;
revoke execute on function public.report_worker_seasons(uuid, integer) from public, anon;
grant execute on function public.report_worker_seasons(uuid, integer) to authenticated;

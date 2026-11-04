-- Fixes from the code review of the shift market, onboarding, punches and ratings
-- (0005, 0012, 0014, 0016). 0001-0018 are live; this file only adds or redefines.
--
--  1. Coworker privacy. Employee functions never say why a coworker can't take a shift
--     (age, missing card, do-not-rehire); they say "This coworker can't take this
--     shift." A person's own do-not-rehire flag shows as a neutral message. Manager
--     functions keep the detailed reasons.
--  2. review_shift_requests lists requests from every venue where the caller schedules,
--     not one venue picked at random.
--  3. decide_shift_request locks the shift before the requests (same order as the
--     other shift functions), so two approvals at once cannot deadlock.
--  4. Positions at a storefront that is closed for the event cannot be picked up or
--     approved as pickups, and are not listed as open shifts.
--  5. Labor budgets no longer appear in the event and shift JSON that employees get.
--     (The column itself stays readable: the app selects events with "*", so a column
--     revoke would break it.)
--  6. Notifications: when a pickup fills a position, the other open requests on it are
--     closed with a message that fits each one (pickup, drop, swap requester and swap
--     target). An automatic pickup closes other pending pickups too. Withdrawing a
--     request that was waiting for a manager tells the schedulers.
--  7. Agency contacts and NPO coordinators no longer read punches (GPS, photo paths)
--     from the punches table. They get times from npo_portal() / agency_portal().
--  8. A minor's waiver acknowledgment without a guardian's name does not count.
--  9. complete_onboarding_step refuses document and card steps (they finish from the
--     person's own acknowledgments and cards) and steps waiting for review.
-- 10. Sending a card again removes the previous, still unverified, card records.
-- 11. Ratings and do-not-rehire flags are audited; only a flag's reason can be edited.
-- 12. Assistant managers (view_workers) can open the onboarding uploads they already
--     see listed.

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable through the API)
-- ---------------------------------------------------------------------------

-- assignment_block_reason for the person asking about themself: their own age and card
-- reasons as they are, a do-not-rehire flag as a neutral message.
create or replace function public.self_block_reason(p_worker uuid, p_event uuid, p_role text, p_shift uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_reason text := public.assignment_block_reason(p_worker, p_event, p_role, p_shift);
begin
  if v_reason is not null and exists (
       select 1 from rehire_flags f join workers w on w.venue_id = f.venue_id and w.id = f.worker_id
        where w.id = p_worker) then
    return 'You can''t pick up shifts right now. Talk to a manager.';
  end if;
  return v_reason;
end $$;

-- True when the position's storefront is open for its event.
create or replace function public.shift_storefront_open(p_shift uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from shifts s
    join event_storefronts es on es.event_id = s.event_id and es.storefront_id = s.storefront_id
    where s.id = p_shift and es.is_open);
$$;

-- Closes every other open request on a position that was just filled, and tells each
-- person what happened to their request. The caller holds the shift row lock.
create or replace function public.close_other_shift_requests(p_shift uuid, p_keep uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_label text := public.shift_label(p_shift);
  r record;
begin
  for r in
    update shift_requests
       set status = 'expired',
           decision_note = case when kind = 'pickup' then 'Filled by someone else'
                                else 'The position was given to someone else' end
     where shift_id = p_shift and id is distinct from p_keep and status in ('pending', 'offered')
    returning kind, requester_worker_id, target_worker_id
  loop
    if r.kind = 'pickup' then
      perform public.notify_worker(r.requester_worker_id, 'request_decided', 'Shift filled', v_label, '/schedule');
    elsif r.kind = 'drop' then
      perform public.notify_worker(r.requester_worker_id, 'request_decided', 'Drop request closed',
        v_label || E'\nA manager changed this position. Check your schedule.', '/schedule');
    else
      perform public.notify_worker(r.requester_worker_id, 'request_decided', 'Swap closed',
        v_label || E'\nA manager changed this position. Check your schedule.', '/schedule');
      perform public.notify_worker(r.target_worker_id, 'request_decided', 'Shift offer closed',
        v_label || E'\nThis shift is no longer available.', '/schedule');
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Shift market (latest definitions from 0012)
-- ---------------------------------------------------------------------------

-- One request as the app shows it: the shift, event, storefront and role names, and the
-- people's names. p_rules adds the requester's and target's rules-engine fields
-- (managers only).
create or replace function public.shift_request_json(p_request uuid, p_rules boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(q) || jsonb_build_object(
      'shift', to_jsonb(s),
      'event', to_jsonb(e) - 'labor_budget',
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
        'event', to_jsonb(e) - 'labor_budget',
        'storefront_name', f.name,
        'storefront_code', f.code,
        'section', f.section,
        'role_name', r.name,
        'blocked', public.self_block_reason(w.id, s.event_id, s.job_role_code, s.id),
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
      and exists (select 1 from event_storefronts es where es.event_id = s.event_id and es.storefront_id = s.storefront_id and es.is_open)
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
  if s.call_time <= now() or ev.status not in ('scheduled', 'live') or not public.shift_storefront_open(s.id) then
    raise exception 'This shift is no longer available' using errcode = '22023';
  end if;
  if not exists (select 1 from worker_job_roles j where j.worker_id = w.id and j.job_role_code = s.job_role_code) then
    raise exception 'You are not trained for this role' using errcode = '42501';
  end if;
  v_block := public.self_block_reason(w.id, s.event_id, s.job_role_code, s.id);
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
    perform public.close_other_shift_requests(s.id, q.id);
    perform public.notify_schedulers(s.id, 'schedule_changed', 'Shift picked up: ' || public.worker_name(w.id),
      public.shift_label(s.id), jsonb_build_object('request_id', q.id));
  end if;
  return q;
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
  -- Never say why: the reason (age, cards, do-not-rehire) is the coworker's business.
  v_block := public.assignment_block_reason(t.id, s.event_id, s.job_role_code, s.id);
  if v_block is not null then raise exception 'This coworker can''t take this shift.' using errcode = 'P0001'; end if;
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
    v_block := public.self_block_reason(w.id, s.event_id, s.job_role_code, s.id);
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
  -- A request in the manager queue: the schedulers hear it was withdrawn.
  if v_was = 'pending' then
    perform public.notify_schedulers(q.shift_id, 'request_update',
      case q.kind when 'pickup' then 'Pickup' when 'drop' then 'Drop' else 'Swap' end
        || ' request withdrawn: ' || public.worker_name(w.id),
      public.shift_label(q.shift_id), jsonb_build_object('request_id', q.id));
  end if;
  return q;
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
          'event', to_jsonb(e) - 'labor_budget',
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

-- Requests at storefronts where the caller can schedule. Open ones (pending, and swaps
-- waiting for the coworker), or with p_history the most recent decided ones.
create or replace function public.review_shift_requests(p_history boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_venues uuid[];
  v_storefronts uuid[];
  v uuid;
begin
  -- Every venue where the caller schedules (any scope).
  select array_agg(m.venue_id) into v_venues from venue_memberships m
   where m.user_id = (select auth.uid()) and m.status = 'active' and public.has_permission(m.venue_id, 'manage_schedule');
  if v_venues is null then raise exception 'Not authorized' using errcode = '42501'; end if;
  foreach v in array v_venues loop
    perform public.expire_shift_requests(v);
  end loop;
  select array_agg(f) into v_storefronts
    from unnest(v_venues) u(venue_id), lateral public.storefronts_in_scope(u.venue_id, 'manage_schedule') f;
  return coalesce((
    select jsonb_agg(public.shift_request_json(q.id, true) order by q.sort_at)
    from (select x.id, case when p_history then -extract(epoch from coalesce(x.decided_at, x.updated_at))
                            else extract(epoch from s.call_time) end as sort_at
          from shift_requests x join shifts s on s.id = x.shift_id
          where x.venue_id = any (v_venues)
            and s.storefront_id = any (coalesce(v_storefronts, '{}'))
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
  v_shift uuid;
begin
  -- Lock order: the shift, then its open requests by id, then this request. The other
  -- shift functions lock the shift first too, so concurrent decisions cannot deadlock.
  select shift_id into v_shift from shift_requests where id = p_request;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  select * into s from shifts where id = v_shift for update;
  perform 1 from shift_requests where shift_id = v_shift and status in ('pending', 'offered') order by id for update;
  select * into q from shift_requests where id = p_request for update;
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
      if not public.shift_storefront_open(s.id) then
        raise exception 'This storefront is closed for this event. Deny the request.' using errcode = '22023';
      end if;
      v_block := public.assignment_block_reason(q.requester_worker_id, s.event_id, s.job_role_code, s.id);
      if v_block is not null then raise exception '%', v_block using errcode = 'P0001'; end if;
      perform public.market_set_worker(s.id, q.requester_worker_id,
        'Pickup approved' || case when v_note = '' then '' else ': ' || v_note end, p_warnings);
      -- Everyone else with an open request on this position hears what happened to it.
      perform public.close_other_shift_requests(s.id, q.id);
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
-- Punches: partner scope (agency, NPO) no longer reads punch rows. Own punches,
-- view_workers or view_live at the venue, and view_live on the shift's storefront stay.
-- ---------------------------------------------------------------------------
create or replace function public.can_view_punches_of(p_worker uuid, p_shift uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
           select 1 from workers w
           where w.id = p_worker
             and (w.user_id = (select auth.uid())
                  or public.has_venue_permission(w.venue_id, 'view_workers')
                  or public.has_venue_permission(w.venue_id, 'view_live')))
      or (p_shift is not null and exists (
            select 1 from shifts s where s.id = p_shift and public.can_on_storefront(s.storefront_id, 'view_live')));
$$;

-- ---------------------------------------------------------------------------
-- Onboarding (latest definitions from 0014)
-- ---------------------------------------------------------------------------

-- Where one person stands: every step that applies to them with its status, plus
-- totals. p_detail adds answers, files, documents and items (for the person and for
-- managers); without it, only what the overview needs.
create or replace function public.onboarding_state(p_worker uuid, p_detail boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
  v venues%rowtype;
  s onboarding_steps%rowtype;
  p onboarding_progress%rowtype;
  v_today date;
  v_adult integer;
  v_minor boolean;
  v_roles text[];
  v_req_certs text[];
  v_missing_certs text[];
  v_status text;
  v_extra jsonb;
  v_docs jsonb;
  v_missing_docs jsonb;
  v_items jsonb;
  v_items_done integer;
  v_steps jsonb := '[]'::jsonb;
  v_missing jsonb := '[]'::jsonb;
  v_done integer := 0;
  v_required integer := 0;
  v_review boolean := false;
  v_last timestamptz;
  v_finished timestamptz;
  -- When the earliest outstanding requirement became outstanding: when the person was
  -- added, or later when a document they signed was changed or a card expired.
  v_moment timestamptz;
  v_open_since timestamptz;
  v_is_done boolean;
  v_guardian boolean;
begin
  select * into w from workers where id = p_worker;
  if not found then
    return null;
  end if;
  select * into v from venues where id = w.venue_id;
  v_today := (now() at time zone v.time_zone)::date;
  v_adult := coalesce((v.settings -> 'minors' ->> 'adult_age')::integer, 18);
  v_minor := w.date_of_birth is not null and extract(year from age(v_today, w.date_of_birth)) < v_adult;
  select coalesce(array_agg(job_role_code order by job_role_code), '{}') into v_roles
    from worker_job_roles where worker_id = w.id;
  select coalesce(array_agg(distinct c order by c), '{}') into v_req_certs
    from job_roles r cross join lateral unnest(r.required_certifications) c
   where r.venue_id = w.venue_id and r.code = any (v_roles);

  for s in
    select * from onboarding_steps
     where venue_id = w.venue_id and active and w.worker_type = any (applies_to)
     order by sort, code
  loop
    p := null;
    select * into p from onboarding_progress where worker_id = w.id and step_code = s.code;
    v_status := coalesce(p.status, 'not_started');
    v_extra := '{}'::jsonb;

    if s.kind = 'document' then
      select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'title', d.title, 'version', d.version)
                                order by d.sort, d.title), '[]'::jsonb)
        into v_docs
        from onboarding_documents d
       where d.venue_id = w.venue_id and d.step_code = s.code and d.active and w.worker_type = any (d.applies_to);
      -- Nothing to acknowledge: the step does not apply.
      continue when jsonb_array_length(v_docs) = 0;
      -- A minor's acknowledgment counts only with a parent's or guardian's name, even if
      -- it was given before the birth date was on file.
      v_guardian := coalesce((s.config ->> 'guardian_for_minors')::boolean, false) and v_minor;
      select coalesce(jsonb_agg(x), '[]'::jsonb) into v_missing_docs
        from jsonb_array_elements(v_docs) x
       where not exists (
         select 1 from jsonb_array_elements(coalesce(p.data -> 'acknowledgments', '[]'::jsonb)) a
          where a ->> 'document_id' = x ->> 'id'
            and coalesce((a ->> 'version')::integer, 1) >= (x ->> 'version')::integer
            and (not v_guardian or length(btrim(coalesce(a ->> 'guardian_name', ''))) >= 3));
      if jsonb_array_length(v_missing_docs) = 0 then
        v_status := 'complete';
      elsif v_status in ('complete', 'approved') then
        v_status := 'not_started';
      end if;
      select min(case when exists (
                 select 1 from jsonb_array_elements(coalesce(p.data -> 'acknowledgments', '[]'::jsonb)) a
                  where a ->> 'document_id' = d.id::text) then greatest(d.updated_at, w.created_at) else w.created_at end)
        into v_moment
        from onboarding_documents d
       where d.id::text in (select x ->> 'id' from jsonb_array_elements(v_missing_docs) x);
      v_extra := jsonb_build_object(
        'documents', v_docs,
        'missing_documents', v_missing_docs,
        'guardian_required', v_guardian,
        'birth_date_on_file', w.date_of_birth is not null);

    elsif s.kind = 'upload' then
      -- Only for people whose trained roles need a card.
      continue when cardinality(v_req_certs) = 0;
      -- A card counts when it is current and not an upload waiting for a manager.
      select coalesce(array_agg(c order by c), '{}') into v_missing_certs
        from unnest(v_req_certs) c
       where not exists (
         select 1 from worker_certifications wc
          where wc.worker_id = w.id and wc.cert_type_code = c
            and (wc.verified_by is not null or wc.document_path is null)
            and (wc.expires_on is null or wc.expires_on >= v_today));
      if cardinality(v_missing_certs) = 0 then
        v_status := 'complete';
      elsif v_status in ('complete', 'approved') then
        v_status := 'not_started';
      end if;
      select min(coalesce(
               (select greatest(((max(wc.expires_on) + 1)::timestamp at time zone v.time_zone), w.created_at)
                  from worker_certifications wc
                 where wc.worker_id = w.id and wc.cert_type_code = c and wc.expires_on < v_today),
               w.created_at))
        into v_moment
        from unnest(v_missing_certs) c;
      v_extra := jsonb_build_object(
        'required_certs', to_jsonb(v_req_certs),
        'missing_certs', to_jsonb(v_missing_certs),
        'pending_certs', (
          select coalesce(jsonb_agg(jsonb_build_object('id', wc.id, 'cert_type_code', wc.cert_type_code, 'number', wc.number,
                   'issued_on', wc.issued_on, 'expires_on', wc.expires_on, 'document_path', wc.document_path)
                   order by wc.created_at), '[]'::jsonb)
            from worker_certifications wc
           where wc.worker_id = w.id and wc.verified_by is null and wc.document_path is not null));

    elsif s.kind = 'checklist' then
      select coalesce(jsonb_agg(i), '[]'::jsonb) into v_items
        from jsonb_array_elements(coalesce(s.config -> 'items', '[]'::jsonb)) i
       where not (i ? 'roles')
          or exists (select 1 from jsonb_array_elements_text(i -> 'roles') r where r = any (v_roles));
      continue when jsonb_array_length(v_items) = 0;
      select count(*) into v_items_done
        from jsonb_array_elements(v_items) i
       where coalesce(p.data -> 'items', '{}'::jsonb) ? (i ->> 'code');
      if v_items_done = jsonb_array_length(v_items) then
        v_status := 'complete';
      elsif v_status in ('complete', 'approved') then
        v_status := 'not_started';
      end if;
      v_extra := jsonb_build_object('items', v_items, 'items_done', v_items_done);

    elsif s.config ->> 'auto_complete_when' = 'date_of_birth' then
      if w.date_of_birth is not null then
        v_status := 'complete';
      end if;
      v_extra := jsonb_build_object('birth_date_on_file', w.date_of_birth is not null);
    end if;

    v_is_done := v_status in ('complete', 'approved');
    if s.required and not v_is_done then
      v_open_since := least(v_open_since, coalesce(case when s.kind in ('document', 'upload') then v_moment end, w.created_at));
    end if;
    v_moment := null;
    if s.required then
      v_required := v_required + 1;
      if v_is_done then
        v_done := v_done + 1;
      else
        v_missing := v_missing || to_jsonb(s.name);
      end if;
    end if;
    if v_status = 'submitted' then
      v_review := true;
    end if;
    if v_is_done and p.id is not null then
      v_last := greatest(v_last, coalesce(p.reviewed_at, p.submitted_at, p.updated_at));
    end if;

    v_steps := v_steps || (
      jsonb_build_object('code', s.code, 'name', s.name, 'kind', s.kind, 'required', s.required, 'sort', s.sort,
        'status', v_status, 'done', v_is_done, 'note', coalesce(p.note, ''),
        'submitted_at', p.submitted_at, 'reviewed_at', p.reviewed_at)
      || case when p_detail then
           jsonb_build_object('description', s.description, 'config', s.config,
             'data', coalesce(p.data, '{}'::jsonb), 'file_paths', to_jsonb(coalesce(p.file_paths, '{}'::text[])))
           || v_extra
         else '{}'::jsonb end);
  end loop;

  if v_done = v_required then
    v_finished := coalesce(v_last, w.created_at);
  end if;

  return jsonb_build_object(
    'worker_id', w.id,
    'venue_id', w.venue_id,
    'first_name', w.first_name,
    'last_name', w.last_name,
    'preferred_name', w.preferred_name,
    'employee_number', w.employee_number,
    'worker_type', w.worker_type,
    'has_login', w.user_id is not null,
    'minor', v_minor,
    'started_at', w.created_at,
    'finished_at', v_finished,
    'open_since', v_open_since,
    -- Open: days since the earliest outstanding requirement. Finished: days it took.
    'days_open', floor(extract(epoch from (case when v_finished is null then now() - coalesce(v_open_since, w.created_at)
                                                 else v_finished - w.created_at end)) / 86400)::integer,
    'done', v_done,
    'required', v_required,
    'percent', case when v_required = 0 then 100 else floor(100.0 * v_done / v_required)::integer end,
    'missing', v_missing,
    'needs_review', v_review,
    'steps', v_steps);
end $$;

-- A person fills in one of their own steps.
--   application: {address, phone, email, emergency_contact_name, emergency_contact_phone,
--                 uniform_size, preferred_language, notes}. Contact fields update the
--                 staff record; pay, type, roles and number are never touched.
--   policies / waiver: {"acknowledgments": [{document_id, typed_name, guardian_name?}],
--                 "adult_confirmed"?: true}
--   age_confirmation: {date_of_birth} (a manager confirms it)
--   certifications: {"certs": [{cert_type_code, number, issued_on, expires_on, file_path}]}
--                 with p_files the uploaded paths. Creates unverified card records.
create or replace function public.submit_onboarding_step(p_step text, p_data jsonb, p_files text[] default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.my_worker();
  s onboarding_steps%rowtype;
  p onboarding_progress%rowtype;
  v_today date;
  v_adult integer;
  v_minor boolean;
  v_status text;
  v_data jsonb := '{}'::jsonb;
  v_files text[] := coalesce(p_files, '{}');
  v_prefix text := w.venue_id::text || '/' || w.id::text || '/';
  v_lang text;
  v_dob date;
  d record;
  a jsonb;
  c jsonb;
  v_acks jsonb;
  v_guardian text;
  v_cert_id uuid;
  v_certs jsonb := '[]'::jsonb;
  v_path text;
  v_expires date;
  f text;
begin
  select * into s from onboarding_steps
   where venue_id = w.venue_id and code = p_step and active and w.worker_type = any (applies_to);
  if not found then
    raise exception 'Unknown onboarding step' using errcode = '22023';
  end if;
  if s.kind in ('checklist', 'external') or coalesce((s.config ->> 'manager_only')::boolean, false) then
    raise exception 'A manager completes this step' using errcode = '42501';
  end if;
  foreach f in array v_files loop
    if left(f, length(v_prefix)) <> v_prefix or f like '%..%' then
      raise exception 'Upload files to your own folder' using errcode = '42501';
    end if;
  end loop;
  select * into p from onboarding_progress where worker_id = w.id and step_code = s.code;
  select (now() at time zone time_zone)::date,
         coalesce((settings -> 'minors' ->> 'adult_age')::integer, 18)
    into v_today, v_adult from venues where id = w.venue_id;
  v_minor := w.date_of_birth is not null and extract(year from age(v_today, w.date_of_birth)) < v_adult;
  p_data := coalesce(p_data, '{}'::jsonb);

  if s.kind = 'form' and s.config -> 'fields' ? 'date_of_birth' then
    begin
      v_dob := (p_data ->> 'date_of_birth')::date;
    exception when others then
      v_dob := null;
    end;
    if v_dob is null or v_dob > v_today or v_dob < date '1900-01-01' then
      raise exception 'Enter a valid birth date' using errcode = '22023';
    end if;
    v_data := jsonb_build_object('date_of_birth', v_dob);
    v_status := 'submitted';

  elsif s.kind = 'form' then
    if btrim(coalesce(p_data ->> 'phone', '')) = '' then
      raise exception 'Enter a phone number' using errcode = '22023';
    end if;
    if btrim(coalesce(p_data ->> 'emergency_contact_name', '')) = ''
       or btrim(coalesce(p_data ->> 'emergency_contact_phone', '')) = '' then
      raise exception 'Enter an emergency contact and their phone' using errcode = '22023';
    end if;
    v_lang := case when p_data ->> 'preferred_language' = 'es' then 'es' else 'en' end;
    select coalesce(jsonb_object_agg(k, left(btrim(p_data ->> k), 300)), '{}'::jsonb) into v_data
      from unnest(array['address', 'phone', 'email', 'emergency_contact_name', 'emergency_contact_phone',
                        'uniform_size', 'notes']) k
     where p_data ? k and jsonb_typeof(p_data -> k) = 'string';
    v_data := v_data || jsonb_build_object('preferred_language', v_lang);
    update workers set
      phone = left(btrim(p_data ->> 'phone'), 40),
      email = coalesce(left(btrim(p_data ->> 'email'), 200), email),
      emergency_contact_name = left(btrim(p_data ->> 'emergency_contact_name'), 120),
      emergency_contact_phone = left(btrim(p_data ->> 'emergency_contact_phone'), 40),
      uniform_size = coalesce(left(btrim(p_data ->> 'uniform_size'), 10), uniform_size),
      preferred_language = v_lang
    where id = w.id;
    update user_profiles set preferred_language = v_lang where id = (select auth.uid());
    v_status := 'complete';

  elsif s.kind = 'document' then
    -- Keep earlier acknowledgments; add or replace the ones sent now.
    v_acks := coalesce(p.data -> 'acknowledgments', '[]'::jsonb);
    for a in select * from jsonb_array_elements(coalesce(p_data -> 'acknowledgments', '[]'::jsonb)) loop
      select * into d from onboarding_documents
       where id = nullif(a ->> 'document_id', '')::uuid and venue_id = w.venue_id and step_code = s.code
         and active and w.worker_type = any (applies_to);
      if not found then
        raise exception 'Unknown document' using errcode = '22023';
      end if;
      if not public.typed_name_matches(w.id, a ->> 'typed_name') then
        raise exception 'Type your full name as it appears on your record to sign "%"', d.title using errcode = '22023';
      end if;
      v_guardian := btrim(coalesce(a ->> 'guardian_name', ''));
      if coalesce((s.config ->> 'guardian_for_minors')::boolean, false) then
        if (v_minor or (w.date_of_birth is null and not coalesce((p_data ->> 'adult_confirmed')::boolean, false)))
           and (length(v_guardian) < 3 or public.normalize_name(v_guardian) = public.normalize_name(a ->> 'typed_name')) then
          raise exception 'A parent or guardian must also type their name for volunteers under %', v_adult using errcode = '22023';
        end if;
      end if;
      select coalesce(jsonb_agg(x), '[]'::jsonb) into v_acks
        from jsonb_array_elements(v_acks) x where x ->> 'document_id' <> d.id::text;
      v_acks := v_acks || jsonb_build_array(jsonb_build_object(
        'document_id', d.id, 'title', d.title, 'version', d.version,
        'typed_name', left(btrim(a ->> 'typed_name'), 120), 'at', now())
        || case when v_guardian <> '' then jsonb_build_object('guardian_name', left(v_guardian, 120)) else '{}'::jsonb end
        || case when (p_data ->> 'adult_confirmed')::boolean then jsonb_build_object('adult_confirmed', true) else '{}'::jsonb end);
    end loop;
    v_data := jsonb_build_object('acknowledgments', v_acks);
    v_status := case when exists (
        select 1 from onboarding_documents d2
         where d2.venue_id = w.venue_id and d2.step_code = s.code and d2.active and w.worker_type = any (d2.applies_to)
           and not exists (select 1 from jsonb_array_elements(v_acks) x
                            where x ->> 'document_id' = d2.id::text and (x ->> 'version')::integer >= d2.version
                              and not (coalesce((s.config ->> 'guardian_for_minors')::boolean, false) and v_minor
                                       and length(btrim(coalesce(x ->> 'guardian_name', ''))) < 3)))
      then 'not_started' else 'complete' end;

  elsif s.kind = 'upload' then
    if jsonb_array_length(coalesce(p_data -> 'certs', '[]'::jsonb)) = 0 then
      raise exception 'Add a photo of your card' using errcode = '22023';
    end if;
    -- Sending cards again replaces the previous submission's cards that no manager has
    -- verified yet; verified ones stay.
    if p.id is not null then
      perform set_config('app.audit_reason', 'Card sent again in onboarding', true);
      delete from worker_certifications
       where worker_id = w.id and verified_by is null
         and id in (select (x ->> 'id')::uuid from jsonb_array_elements(coalesce(p.data -> 'certs', '[]'::jsonb)) x
                     where x ->> 'id' is not null);
    end if;
    for c in select * from jsonb_array_elements(p_data -> 'certs') loop
      if not exists (select 1 from certification_types t where t.venue_id = w.venue_id and t.code = c ->> 'cert_type_code') then
        raise exception 'Unknown certification' using errcode = '22023';
      end if;
      v_path := c ->> 'file_path';
      if v_path is null or not (v_path = any (v_files)) then
        raise exception 'Add a photo of your card' using errcode = '22023';
      end if;
      v_expires := nullif(c ->> 'expires_on', '')::date;
      if v_expires is not null and v_expires < v_today then
        raise exception 'This card has expired' using errcode = '22023';
      end if;
      insert into worker_certifications (venue_id, worker_id, cert_type_code, number, issued_on, expires_on, document_path)
      values (w.venue_id, w.id, c ->> 'cert_type_code', left(btrim(coalesce(c ->> 'number', '')), 40),
              nullif(c ->> 'issued_on', '')::date, v_expires, v_path)
      returning id into v_cert_id;
      v_certs := v_certs || jsonb_build_object('id', v_cert_id, 'cert_type_code', c ->> 'cert_type_code',
        'number', left(btrim(coalesce(c ->> 'number', '')), 40), 'expires_on', v_expires, 'file_path', v_path);
    end loop;
    v_data := jsonb_build_object('certs', v_certs);
    v_status := 'submitted';
  else
    raise exception 'A manager completes this step' using errcode = '42501';
  end if;

  insert into onboarding_progress (venue_id, worker_id, step_code, status, data, file_paths, submitted_at)
  values (w.venue_id, w.id, s.code, v_status, v_data, v_files, now())
  on conflict (worker_id, step_code) do update
    set status = excluded.status, data = excluded.data, file_paths = excluded.file_paths,
        submitted_at = excluded.submitted_at, reviewed_by = null, reviewed_at = null, note = '';
  return public.onboarding_state(w.id, true);
end $$;

-- A manager completes a step: ticks training items, marks Paycom onboarding done with a
-- date, or records a step done on paper.
--   training: {"items": ["cash_handling", ...]} (the full ticked set)
--   paycom:   {"completed_on": "yyyy-mm-dd"}
create or replace function public.complete_onboarding_step(p_worker uuid, p_step text, p_data jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.require_onboarding_manager(p_worker);
  s onboarding_steps%rowtype;
  p onboarding_progress%rowtype;
  v_today date;
  v_data jsonb;
  v_status text := 'complete';
  v_items jsonb := '{}'::jsonb;
  v_code text;
  v_on date;
begin
  select * into s from onboarding_steps
   where venue_id = w.venue_id and code = p_step and active and w.worker_type = any (applies_to);
  if not found then
    raise exception 'Unknown onboarding step' using errcode = '22023';
  end if;
  select * into p from onboarding_progress where worker_id = w.id and step_code = s.code;
  -- Documents finish when the person signs them and cards when they hold current ones;
  -- marking them done here would not count.
  if s.kind = 'document' then
    raise exception 'The person signs this step themself in the app' using errcode = '22023';
  end if;
  if s.kind = 'upload' then
    raise exception 'This step finishes when the person''s cards are on file. Add or verify the cards instead.' using errcode = '22023';
  end if;
  if p.status = 'submitted' then
    raise exception 'This step is waiting for review. Approve it or send it back instead.' using errcode = '22023';
  end if;
  select (now() at time zone time_zone)::date into v_today from venues where id = w.venue_id;
  p_data := coalesce(p_data, '{}'::jsonb);

  if s.kind = 'checklist' then
    for v_code in select jsonb_array_elements_text(coalesce(p_data -> 'items', '[]'::jsonb)) loop
      if not exists (select 1 from jsonb_array_elements(coalesce(s.config -> 'items', '[]'::jsonb)) i where i ->> 'code' = v_code) then
        raise exception 'Unknown training item %', v_code using errcode = '22023';
      end if;
      v_items := v_items || jsonb_build_object(v_code,
        coalesce(p.data -> 'items' -> v_code, jsonb_build_object('at', now(), 'by', (select auth.uid()))));
    end loop;
    v_data := jsonb_build_object('items', v_items);
    -- Partly ticked stays open; onboarding_state() works out complete.
    v_status := 'not_started';
  elsif s.kind = 'external' then
    begin
      v_on := coalesce(nullif(p_data ->> 'completed_on', '')::date, v_today);
    exception when others then
      raise exception 'Enter a valid date' using errcode = '22023';
    end;
    if v_on > v_today then
      raise exception 'The date cannot be in the future' using errcode = '22023';
    end if;
    v_data := jsonb_build_object('completed_on', v_on, 'by', (select auth.uid()));
  else
    v_data := coalesce(p.data, '{}'::jsonb) || jsonb_build_object('completed_by_manager', true,
      'note', left(coalesce(p_data ->> 'note', ''), 300));
  end if;

  insert into onboarding_progress (venue_id, worker_id, step_code, status, data, submitted_at, reviewed_by, reviewed_at)
  values (w.venue_id, w.id, s.code, v_status, v_data, now(), (select auth.uid()), now())
  on conflict (worker_id, step_code) do update
    set status = excluded.status, data = excluded.data,
        reviewed_by = excluded.reviewed_by, reviewed_at = excluded.reviewed_at, note = '';
  return public.onboarding_state(w.id, true);
end $$;

-- ---------------------------------------------------------------------------
-- Onboarding uploads: whoever sees the checklist (view_workers) can open its files.
-- ---------------------------------------------------------------------------
drop policy if exists onboarding_docs_read on storage.objects;
create policy onboarding_docs_read on storage.objects for select to authenticated
  using (
    bucket_id = 'onboarding-docs'
    and (exists (select 1 from public.workers w
                 where w.id = public.storage_worker(name) and w.venue_id = public.storage_venue(name)
                   and w.user_id = (select auth.uid()))
         or public.has_venue_permission(public.storage_venue(name), 'manage_workers')
         or public.has_venue_permission(public.storage_venue(name), 'view_workers')
         or (split_part(name, '/', 2) = 'documents' and public.is_venue_member(public.storage_venue(name))))
  );

-- ---------------------------------------------------------------------------
-- Ratings and do-not-rehire flags: audited; a flag's reason is the only editable field.
-- ---------------------------------------------------------------------------
create trigger worker_ratings_audit after insert or update or delete on public.worker_ratings
for each row execute function public.audit_row_change();
create trigger rehire_flags_audit after insert or update or delete on public.rehire_flags
for each row execute function public.audit_row_change();

revoke update on public.rehire_flags from authenticated;
grant update (reason) on public.rehire_flags to authenticated;

-- ---------------------------------------------------------------------------
-- Grants: the new helpers are internal. Redefined functions keep their grants.
-- ---------------------------------------------------------------------------
revoke execute on function public.self_block_reason(uuid, uuid, text, uuid) from public, anon, authenticated;
revoke execute on function public.shift_storefront_open(uuid) from public, anon, authenticated;
revoke execute on function public.close_other_shift_requests(uuid, uuid) from public, anon, authenticated;

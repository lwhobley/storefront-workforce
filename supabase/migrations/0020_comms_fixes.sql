-- Communication fixes from code review (0013 is live; this changes it in place).
--
-- 1. A notification that failed to send is no longer sent again forever. Each claim
--    counts as a delivery attempt; after 5 attempts the notification is marked failed.
--    Claimed rows that were never written back expire after a day like the rest, and
--    only notifications from the last day are handed out. notify-dispatch can ask for a
--    retry after a backoff for temporary provider failures, keeping the channels that
--    already went out so they are not sent twice.
-- 2. One venue can no longer stop the scheduled reminders for every venue: each venue is
--    processed on its own, number settings that are not whole numbers fall back to the
--    defaults, an unknown time zone falls back to the default zone, and venues.time_zone
--    must be a real time zone name from now on (checked when it is set or changed).
-- 3. NPO coordinators and temp agency contacts are not staff: they no longer get staff
--    messages to everyone, venue-wide announcements and policies, and are not listed as
--    missing acknowledgments. A person at the venue now needs a staff record there or a
--    role with some permission other than the partner portals (managers without a staff
--    record, such as the Admin / GM, are still included).
-- 4. Delivery results are written only by the dispatcher that still holds the claim, so
--    a late, stale run cannot overwrite a newer one.
-- 5. An announcement's document can be opened only by people who can see that
--    announcement, and by the people who manage announcements.

-- ---------------------------------------------------------------------------
-- 3. Who reads messages at the venue
-- ---------------------------------------------------------------------------

-- A person who reads messages at the venue: an active member who is not a kiosk, with a
-- staff record at the venue or a role that is not only a partner portal.
create or replace function public.comms_is_person(p_venue uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from venue_memberships m
    where m.venue_id = p_venue and m.user_id = p_user and m.status = 'active'
  )
  and not exists (select 1 from user_profiles up where up.id = p_user and up.kind = 'kiosk')
  and not exists (select 1 from role_assignments ra where ra.venue_id = p_venue and ra.user_id = p_user and ra.role_code = 'kiosk')
  and (
    exists (select 1 from workers w where w.venue_id = p_venue and w.user_id = p_user)
    or exists (
      select 1
      from role_assignments ra
      join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
      where ra.venue_id = p_venue and ra.user_id = p_user
        and exists (select 1 from unnest(r.permissions) p where p not in ('npo_portal', 'agency_portal', 'kiosk_punch'))
    )
  );
$$;

-- ---------------------------------------------------------------------------
-- 5. Announcement documents
-- ---------------------------------------------------------------------------
drop policy if exists comms_documents_read on storage.objects;
create policy comms_documents_read on storage.objects for select to authenticated
  using (bucket_id = 'documents' and split_part(name, '/', 2) = 'announcements'
         and (public.can_manage_announcements(public.storage_venue(name))
              or exists (select 1 from public.announcements a
                         where a.venue_id = public.storage_venue(objects.name) and a.document_path = objects.name
                           and public.can_see_announcement(a.id))));

-- ---------------------------------------------------------------------------
-- 2. Venue time zones
-- ---------------------------------------------------------------------------

-- Only checked when the zone is set or changed, so an existing row never blocks other edits.
create or replace function public.check_venue_time_zone()
returns trigger language plpgsql set search_path = public as $$
begin
  if tg_op = 'UPDATE' and new.time_zone is not distinct from old.time_zone then
    return new;
  end if;
  if not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.time_zone) then
    raise exception 'Unknown time zone "%". Use a name such as America/Chicago.', new.time_zone using errcode = '22023';
  end if;
  return new;
end $$;

drop trigger if exists venues_check_time_zone on public.venues;
create trigger venues_check_time_zone before insert or update of time_zone on public.venues
for each row execute function public.check_venue_time_zone();

-- The zone to use for a venue: its own, or the default when Postgres does not know it.
create or replace function public.comms_venue_zone(p_zone text)
returns text language plpgsql stable set search_path = public as $$
begin
  perform now() at time zone p_zone;
  return p_zone;
exception when others then
  return 'America/Chicago';
end $$;

-- A whole-number venue setting (settings -> section -> key), or the default when it is
-- missing or not a whole number.
create or replace function public.comms_setting_int(p_settings jsonb, p_section text, p_key text, p_default integer)
returns integer language sql immutable set search_path = public as $$
  select case when jsonb_typeof(p_settings) = 'object' and jsonb_typeof(p_settings -> p_section) = 'object'
                   and (p_settings -> p_section ->> p_key) ~ '^[0-9]{1,5}$'
              then (p_settings -> p_section ->> p_key)::integer
              else p_default end;
$$;

-- ---------------------------------------------------------------------------
-- 1 and 4. Delivery (notify-dispatch, service role)
-- ---------------------------------------------------------------------------
-- notifications.sent while a notification is still being delivered:
--   {}                                              waiting for its first attempt
--   {"_claimed_at", "_claim", "_done"}              claimed by a dispatcher
--   {"_pending": true, "_done": {...}}              waiting to be sent again
-- "_done" holds the channels already finished. Once delivery is over, sent holds only
-- the per-channel results ({"push": "sent", "email": "failed: ..."}).
alter table public.notifications add column if not exists delivery_attempts integer not null default 0;
create index if not exists notifications_pending_idx on public.notifications(created_at)
  where channels <> '{in_app}' and sent ? '_pending';

-- Claims up to p_limit notifications that still need push or email, with everything
-- the sender needs: contact details, preferences, quiet hours, device tokens, the claim
-- token to write results back with, the attempt number, and the channels already done.
-- Claimed rows are marked so a second dispatcher skips them; a claim not finished in 10
-- minutes is released. Notifications not delivered within a day are marked expired;
-- ones that used up their attempts are marked failed.
create or replace function public.claim_notification_batch(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
  v_max constant integer := 5;
  v_claim uuid := gen_random_uuid();
begin
  -- Still open: never tried, waiting to be retried, or claimed by a run that went away.
  update notifications n
     set sent = coalesce(n.sent -> '_done', '{}'::jsonb)
                || coalesce((select jsonb_object_agg(c, 'expired') from unnest(n.channels) c
                             where c <> 'in_app' and not coalesce(n.sent -> '_done', '{}'::jsonb) ? c), '{}'::jsonb)
                || jsonb_build_object('expired', true)
   where n.channels <> '{in_app}' and n.created_at < now() - interval '1 day'
     and (n.sent = '{}'::jsonb or n.sent ? '_pending'
          or (n.sent ? '_claimed_at' and (n.sent ->> '_claimed_at')::timestamptz < now() - interval '10 minutes'));

  update notifications n
     set sent = coalesce(n.sent -> '_done', '{}'::jsonb)
                || coalesce((select jsonb_object_agg(c, 'failed: gave up after ' || n.delivery_attempts || ' attempts')
                             from unnest(n.channels) c
                             where c <> 'in_app' and not coalesce(n.sent -> '_done', '{}'::jsonb) ? c), '{}'::jsonb)
   where n.channels <> '{in_app}' and n.delivery_attempts >= v_max
     and (n.sent = '{}'::jsonb or n.sent ? '_pending'
          or (n.sent ? '_claimed_at' and (n.sent ->> '_claimed_at')::timestamptz < now() - interval '10 minutes'));

  update notifications n
     set sent = jsonb_build_object('_pending', true, '_done', coalesce(n.sent -> '_done', '{}'::jsonb))
   where n.sent ? '_claimed_at' and (n.sent ->> '_claimed_at')::timestamptz < now() - interval '10 minutes';

  with picked as (
    select id from notifications
    where channels <> '{in_app}' and (sent = '{}'::jsonb or sent ? '_pending')
      and (deliver_after is null or deliver_after <= now())
      and created_at > now() - interval '1 day'
      and delivery_attempts < v_max
    order by created_at
    limit least(greatest(coalesce(p_limit, 50), 1), 500)
    for update skip locked
  ), claimed as (
    update notifications n
       set sent = jsonb_build_object('_claimed_at', now(), '_claim', v_claim, '_done', coalesce(n.sent -> '_done', '{}'::jsonb)),
           delivery_attempts = n.delivery_attempts + 1
    from picked where n.id = picked.id
    returning n.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', c.id, 'venue_id', c.venue_id, 'user_id', c.user_id, 'kind', c.kind, 'title', c.title, 'body', c.body,
      'link', c.link, 'channels', to_jsonb(c.channels), 'data', c.data, 'created_at', c.created_at,
      'urgent', coalesce((c.data ->> 'urgent')::boolean, false),
      'venue_name', v.name, 'time_zone', v.time_zone,
      'language', coalesce(w.preferred_language, up.preferred_language, 'en'),
      'email', coalesce(nullif(w.email, ''), up.contact_email, ''),
      'prefs', jsonb_build_object('push', coalesce(p.push, true), 'email', coalesce(p.email, false),
                                  'quiet_start', to_char(p.quiet_start, 'HH24:MI'), 'quiet_end', to_char(p.quiet_end, 'HH24:MI')),
      'push_tokens', coalesce((select jsonb_agg(jsonb_build_object('token', t.token, 'platform', t.platform))
                               from push_tokens t where t.user_id = c.user_id), '[]'::jsonb),
      'claim', v_claim, 'attempt', c.delivery_attempts, 'max_attempts', v_max,
      'done', coalesce(c.sent -> '_done', '{}'::jsonb))
      order by c.created_at), '[]'::jsonb)
  into v
  from claimed c
  join venues v on v.id = c.venue_id
  left join user_profiles up on up.id = c.user_id
  left join notification_prefs p on p.user_id = c.user_id
  left join lateral (select * from workers x where x.user_id = c.user_id and x.venue_id = c.venue_id limit 1) w on true;
  return v;
end $$;

-- Writes delivery results, each with the claim token claim_notification_batch() gave:
--   final:        {"id", "claim", "sent": {"push": "sent", "email": "opted_out"}}
--   quiet hours:  {"id", "claim", "deliver_after": "<timestamp>"}  (not counted as an attempt)
--   retry:        {"id", "claim", "retry": {"email": "retry: ..."}, "done": {"push": "sent"},
--                  "deliver_after": "<timestamp>"}
-- Rows no longer held by that claim (released and claimed again) are left alone.
create or replace function public.record_notification_results(p_results jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  update notifications t
     set sent = case when jsonb_typeof(r -> 'sent') = 'object'
                     then coalesce(t.sent -> '_done', '{}'::jsonb) || (r -> 'sent')
                     else jsonb_build_object('_pending', true, '_done',
                            coalesce(t.sent -> '_done', '{}'::jsonb)
                            || case when jsonb_typeof(r -> 'done') = 'object' then r -> 'done' else '{}'::jsonb end) end,
         deliver_after = case when jsonb_typeof(r -> 'sent') = 'object' then t.deliver_after
                              else coalesce(nullif(r ->> 'deliver_after', '')::timestamptz, now() + interval '2 minutes') end,
         delivery_attempts = case when jsonb_typeof(r -> 'sent') is distinct from 'object'
                                       and jsonb_typeof(r -> 'retry') is distinct from 'object'
                                  then greatest(t.delivery_attempts - 1, 0)
                                  else t.delivery_attempts end
    from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) r
   where t.id = (r ->> 'id')::uuid
     and t.sent ? '_claim' and t.sent ->> '_claim' = r ->> 'claim';
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Scheduled reminders, one venue at a time
-- ---------------------------------------------------------------------------
create or replace function public.queue_scheduled_notifications(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  ven record;
  r record;
  u record;
  v_call integer := 0;
  v_missed integer := 0;
  v_cert integer := 0;
  v_digest integer := 0;
  v_failed integer := 0;
  c_call integer;
  c_missed integer;
  c_cert integer;
  c_digest integer;
  v_tz text;
  v_today date;
  v_reminder integer;
  v_after_call integer;
  v_time text;
  v_any boolean;
  v_list text;
  v_week text;
begin
  for ven in select id, time_zone, settings from venues order by id loop
    c_call := 0;
    c_missed := 0;
    c_cert := 0;
    c_digest := 0;
    begin
      v_tz := public.comms_venue_zone(ven.time_zone);
      v_today := (p_now at time zone v_tz)::date;
      v_week := to_char(p_now at time zone v_tz, 'IYYY-IW');
      v_reminder := public.comms_setting_int(ven.settings, 'notifications', 'call_reminder_minutes', 120);
      v_after_call := public.comms_setting_int(ven.settings, 'attendance', 'late_grace_minutes', 5)
                    + public.comms_setting_int(ven.settings, 'notifications', 'missed_clock_in_minutes', 15);

      -- Call-time reminders.
      for r in
        select s.id as shift_id, s.call_time, s.venue_id, w.id as worker_id, w.user_id, w.preferred_language as lang,
               e.name as event_name, f.name as storefront_name
        from shifts s
        join workers w on w.id = s.worker_id
        join events e on e.id = s.event_id
        join storefronts f on f.id = s.storefront_id
        where s.venue_id = ven.id and s.status = 'assigned' and e.status in ('scheduled', 'live')
          and w.user_id is not null and w.status = 'active'
          and s.call_time > p_now + interval '10 minutes'
          and s.call_time <= p_now + make_interval(mins => v_reminder)
      loop
        v_time := to_char(r.call_time at time zone v_tz, 'FMHH12:MI AM');
        if public.notify_once('call_time:' || r.shift_id || ':' || r.worker_id || ':' || extract(epoch from r.call_time)::bigint,
            r.venue_id, r.user_id, 'call_time',
            case when r.lang = 'es' then 'Llegada ' || v_time || ' en ' || r.storefront_name
                 else 'Call time ' || v_time || ' at ' || r.storefront_name end,
            case when r.lang = 'es' then r.event_name || '. Marque su entrada al llegar.'
                 else r.event_name || '. Clock in when you arrive.' end,
            '/clock', array['in_app', 'push'], jsonb_build_object('shift_id', r.shift_id)) then
          c_call := c_call + 1;
        end if;
      end loop;

      -- Missed clock-ins.
      for r in
        select s.id as shift_id, s.call_time, s.venue_id, s.storefront_id, s.job_role_code, w.id as worker_id, w.user_id,
               w.preferred_language as lang, coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name as worker_name,
               f.name as storefront_name
        from shifts s
        join workers w on w.id = s.worker_id
        join events e on e.id = s.event_id
        join storefronts f on f.id = s.storefront_id
        where s.venue_id = ven.id and s.status = 'assigned' and e.status in ('scheduled', 'live')
          and s.call_time > p_now - interval '6 hours'
          and p_now >= s.call_time + make_interval(mins => v_after_call)
          and not exists (select 1 from punches p where p.worker_id = s.worker_id and p.event_id = s.event_id
                          and p.kind = 'clock_in' and p.status <> 'voided')
      loop
        v_time := to_char(r.call_time at time zone v_tz, 'FMHH12:MI AM');
        if r.user_id is not null and public.notify_once('missed_clock_in:' || r.shift_id || ':' || r.worker_id,
            r.venue_id, r.user_id, 'missed_clock_in',
            case when r.lang = 'es' then 'No ha marcado su entrada' else 'You have not clocked in' end,
            case when r.lang = 'es' then 'Su hora de llegada en ' || r.storefront_name || ' era ' || v_time || '. Marque su entrada ahora o avise a su líder.'
                 else 'Your call time at ' || r.storefront_name || ' was ' || v_time || '. Clock in now, or tell your lead if you cannot make it.' end,
            '/clock', array['in_app', 'push'], jsonb_build_object('shift_id', r.shift_id)) then
          c_missed := c_missed + 1;
        end if;

        v_any := exists (select 1 from public.storefront_supervisors(r.storefront_id) x where x is distinct from r.user_id);
        for u in
          select x as user_id from public.storefront_supervisors(r.storefront_id) x where x is distinct from r.user_id
          union
          select ra.user_id from role_assignments ra
          join venue_roles vr on vr.venue_id = ra.venue_id and vr.code = ra.role_code
          join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
          where not v_any and ra.venue_id = r.venue_id and ra.scope_type = 'venue'
            and 'manage_schedule' = any (vr.permissions) and ra.role_code <> 'kiosk'
        loop
          if public.notify_once('missed_clock_in:' || r.shift_id || ':' || r.worker_id || ':' || u.user_id,
              r.venue_id, u.user_id, 'missed_clock_in',
              case when public.comms_language(r.venue_id, u.user_id) = 'es' then 'Sin marcar entrada: ' else 'Not clocked in: ' end || r.worker_name,
              r.storefront_name || ' · ' || r.job_role_code || ' · ' || v_time,
              '/live', array['in_app', 'push'], jsonb_build_object('shift_id', r.shift_id, 'worker_id', r.worker_id)) then
            c_missed := c_missed + 1;
          end if;
        end loop;
      end loop;

      -- Certifications expiring within 30 days (the newest of each type per person).
      for r in
        select c.id as cert_id, c.expires_on, c.venue_id, w.user_id, w.preferred_language as lang,
               coalesce(t.name, c.cert_type_code) as cert_name
        from worker_certifications c
        join workers w on w.id = c.worker_id
        left join certification_types t on t.venue_id = c.venue_id and t.code = c.cert_type_code
        where c.venue_id = ven.id and w.status = 'active' and w.user_id is not null and c.expires_on is not null
          and c.expires_on >= v_today
          and c.expires_on <= v_today + 30
          and not exists (select 1 from worker_certifications n
                          where n.worker_id = c.worker_id and n.cert_type_code = c.cert_type_code and n.id <> c.id
                            and (n.expires_on is null or n.expires_on > c.expires_on))
      loop
        if public.notify_once('cert_expiring:' || r.cert_id || ':' || v_week, r.venue_id, r.user_id, 'cert_expiring',
            case when r.lang = 'es' then 'Su ' || r.cert_name || ' vence el ' || to_char(r.expires_on, 'DD/MM/YYYY')
                 else 'Your ' || r.cert_name || ' expires ' || to_char(r.expires_on, 'FMMon FMDD, YYYY') end,
            case when r.lang = 'es' then 'Renuévela y entregue la nueva a su gerente para seguir en este puesto.'
                 else 'Renew it and give the new one to your manager to keep working this role.' end,
            '/me', array['in_app', 'push', 'email'], jsonb_build_object('certification_id', r.cert_id)) then
          c_cert := c_cert + 1;
        end if;
      end loop;

      -- One weekly list for the people who manage staff.
      for r in
        select count(*) as n,
               string_agg(coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name || ' (' ||
                          coalesce(t.name, c.cert_type_code) || ', ' || to_char(c.expires_on, 'FMMon FMDD') || ')',
                          '; ' order by c.expires_on, w.last_name) as list
        from worker_certifications c
        join workers w on w.id = c.worker_id
        left join certification_types t on t.venue_id = c.venue_id and t.code = c.cert_type_code
        where c.venue_id = ven.id and w.status = 'active' and c.expires_on is not null
          and c.expires_on >= v_today
          and c.expires_on <= v_today + 30
          and not exists (select 1 from worker_certifications n
                          where n.worker_id = c.worker_id and n.cert_type_code = c.cert_type_code and n.id <> c.id
                            and (n.expires_on is null or n.expires_on > c.expires_on))
        having count(*) > 0
      loop
        v_list := left(r.list, 1900);
        for u in
          select distinct ra.user_id from role_assignments ra
          join venue_roles vr on vr.venue_id = ra.venue_id and vr.code = ra.role_code
          join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
          where ra.venue_id = ven.id and ra.scope_type = 'venue' and 'manage_workers' = any (vr.permissions)
        loop
          if public.notify_once('cert_digest:' || ven.id || ':' || u.user_id || ':' || v_week, ven.id, u.user_id, 'cert_expiring',
              r.n || case when r.n = 1 then ' certification expires' else ' certifications expire' end || ' within 30 days',
              v_list, '/staff', array['in_app', 'email'], jsonb_build_object('count', r.n)) then
            c_digest := c_digest + 1;
          end if;
        end loop;
      end loop;

      v_call := v_call + c_call;
      v_missed := v_missed + c_missed;
      v_cert := v_cert + c_cert;
      v_digest := v_digest + c_digest;
    exception when others then
      -- This venue's reminders roll back; the other venues still get theirs.
      v_failed := v_failed + 1;
      raise warning 'queue_scheduled_notifications: venue % skipped: % (%)', ven.id, sqlerrm, sqlstate;
    end;
  end loop;

  delete from notification_keys where created_at < p_now - interval '90 days';

  return jsonb_build_object('call_time', v_call, 'missed_clock_in', v_missed, 'cert_expiring', v_cert,
                            'cert_digest', v_digest, 'venues_failed', v_failed);
end $$;

-- ---------------------------------------------------------------------------
-- Function access
-- ---------------------------------------------------------------------------
-- Internal helpers: not part of the API.
do $$
declare f text;
begin
  foreach f in array array[
    'public.comms_is_person(uuid, uuid)',
    'public.check_venue_time_zone()',
    'public.comms_venue_zone(text)',
    'public.comms_setting_int(jsonb, text, text, integer)',
    'public.claim_notification_batch(integer)',
    'public.record_notification_results(jsonb)',
    'public.queue_scheduled_notifications(timestamp with time zone)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- The notify-dispatch function and the scheduler (service role).
grant execute on function
  public.claim_notification_batch(integer),
  public.record_notification_results(jsonb),
  public.queue_scheduled_notifications(timestamp with time zone)
to service_role;

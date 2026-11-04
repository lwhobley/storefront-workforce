-- Communication: messages and alerts, announcements and policy acknowledgments, the
-- notification inbox, delivery preferences and device tokens, and scheduled reminders.
--
-- Every message and announcement goes to the notifications table (0011) for each
-- recipient. In-app is immediate; push and email are sent by the notify-dispatch
-- edge function, which claims undelivered rows with claim_notification_batch() and
-- writes per-channel results back with record_notification_results(). There are no
-- text messages (SMS): channels are in_app, push, and email. Email is opt-in.

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- A person who reads messages at the venue: an active member who is not a kiosk.
create or replace function public.comms_is_person(p_venue uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from venue_memberships m
    where m.venue_id = p_venue and m.user_id = p_user and m.status = 'active'
  )
  and not exists (select 1 from user_profiles up where up.id = p_user and up.kind = 'kiosk')
  and not exists (select 1 from role_assignments ra where ra.venue_id = p_venue and ra.user_id = p_user and ra.role_code = 'kiosk');
$$;

-- True when the user holds any of the permissions at the venue, in any scope.
create or replace function public.user_has_any_permission(p_venue uuid, p_user uuid, p_permissions text[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from role_assignments ra
    join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
    join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
    where ra.venue_id = p_venue and ra.user_id = p_user and r.permissions && p_permissions
  );
$$;

-- The language to write to a person in: their staff record first, then their profile.
create or replace function public.comms_language(p_venue uuid, p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select w.preferred_language from workers w where w.venue_id = p_venue and w.user_id = p_user limit 1),
    (select up.preferred_language from user_profiles up where up.id = p_user),
    'en');
$$;

-- The event in progress at the venue (from 4 hours before call to 2 hours after the end).
create or replace function public.comms_current_event(p_venue uuid, p_now timestamptz default now())
returns uuid language sql stable security definer set search_path = public as $$
  select e.id from events e
  where e.venue_id = p_venue and e.status in ('scheduled', 'live')
    and p_now >= e.call_time - interval '4 hours'
    and p_now <= coalesce(e.end_time, e.start_time + interval '3 hours') + interval '2 hours'
  order by e.call_time
  limit 1;
$$;

-- Leads and managers scoped to one storefront (by storefront or by its level).
create or replace function public.storefront_supervisors(p_storefront uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select distinct ra.user_id
  from storefronts s
  join role_assignments ra on ra.venue_id = s.venue_id
  join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
  join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
  where s.id = p_storefront
    and r.permissions && array['view_live', 'manage_schedule']
    and ((ra.scope_type = 'storefront' and ra.scope_id = s.id)
         or (ra.scope_type = 'level' and ra.scope_id = s.level_id));
$$;

-- An email address for people without a staff record (managers, partners). Staff contact
-- details stay on the workers table.
alter table public.user_profiles add column if not exists contact_email text not null default ''
  check (length(contact_email) <= 200);

-- Delivery scheduling for notify-dispatch: quiet hours push a notification to later.
alter table public.notifications add column if not exists deliver_after timestamptz;
create index if not exists notifications_claimed_idx on public.notifications(created_at) where sent ? '_claimed_at';
create index if not exists notifications_message_idx on public.notifications(user_id, (data ->> 'message_id')) where kind = 'message';

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
create table public.messages (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  sender_id uuid references auth.users(id) on delete set null,
  sender_name text not null default '',
  -- everyone: the whole venue; managers: anyone holding view_live or manage_schedule;
  -- level / storefront: people working there at event_id, plus its leads and managers;
  -- worker: one person.
  audience text not null check (audience in ('everyone', 'managers', 'level', 'storefront', 'worker')),
  audience_id uuid,
  audience_label text not null default '',
  event_id uuid,
  body text not null check (length(btrim(body)) between 1 and 1000),
  urgent boolean not null default false,
  recipient_count integer not null default 0,
  created_at timestamptz not null default now(),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  check ((audience in ('everyone', 'managers')) = (audience_id is null))
);
create index messages_venue_created_idx on public.messages(venue_id, created_at desc);
create index messages_sender_idx on public.messages(sender_id, created_at desc);

create table public.message_reads (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id, user_id)
);
create index message_reads_user_idx on public.message_reads(user_id);

-- Who sees a message. Internal: called with any user id by the functions below.
create or replace function public.message_visible_to(p_message uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from messages m
    where m.id = p_message
      and public.comms_is_person(m.venue_id, p_user)
      and (
        m.sender_id = p_user
        or m.audience = 'everyone'
        or (m.audience = 'managers'
            and public.user_has_any_permission(m.venue_id, p_user, array['view_live', 'manage_schedule']))
        or (m.audience = 'worker'
            and exists (select 1 from workers w where w.id = m.audience_id and w.user_id = p_user))
        or (m.audience in ('level', 'storefront') and (
              -- Working there at that event.
              exists (
                select 1 from shifts s
                join workers w on w.id = s.worker_id
                join storefronts f on f.id = s.storefront_id
                where s.event_id = m.event_id and w.user_id = p_user and s.status in ('assigned', 'released')
                  and case when m.audience = 'storefront' then s.storefront_id = m.audience_id
                           else f.level_id = m.audience_id end)
              -- Leads and managers whose scope covers it.
              or exists (
                select 1
                from role_assignments ra
                join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
                where ra.venue_id = m.venue_id and ra.user_id = p_user
                  and r.permissions && array['view_live', 'manage_schedule']
                  and (ra.scope_type = 'venue'
                       or (ra.scope_type = 'level' and m.audience = 'level' and ra.scope_id = m.audience_id)
                       or (ra.scope_type = 'level' and m.audience = 'storefront'
                           and ra.scope_id = (select f.level_id from storefronts f where f.id = m.audience_id))
                       or (ra.scope_type = 'storefront' and m.audience = 'storefront' and ra.scope_id = m.audience_id)
                       or (ra.scope_type = 'storefront' and m.audience = 'level'
                           and exists (select 1 from storefronts f where f.id = ra.scope_id and f.level_id = m.audience_id))))))
      )
  );
$$;

-- The caller's view, for row level security.
create or replace function public.can_see_message(p_message uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.message_visible_to(p_message, (select auth.uid()));
$$;

-- Everyone who should be told about a message (never the sender).
create or replace function public.message_recipients(p_message uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select m.user_id
  from messages msg
  join venue_memberships m on m.venue_id = msg.venue_id and m.status = 'active'
  where msg.id = p_message
    and m.user_id is distinct from msg.sender_id
    and public.message_visible_to(msg.id, m.user_id);
$$;

alter table public.messages enable row level security;
alter table public.message_reads enable row level security;
revoke all on public.messages, public.message_reads from anon;
revoke insert, update, delete on public.messages, public.message_reads from authenticated;

create policy messages_read on public.messages for select to authenticated
  using (public.can_see_message(id));
create policy message_reads_read_own on public.message_reads for select to authenticated
  using (user_id = (select auth.uid()));

alter publication supabase_realtime add table public.messages;

-- Sends a message. Managers (view_live or manage_schedule) reach any audience in their
-- scope; leads reach their own storefront, its people, and the managers; employees
-- cannot send. Each recipient gets an in-app and push notification; urgent ones are also
-- emailed to people who opted in to email.
--   p: {venue_id, audience, audience_id?, event_id?, body, urgent?}
create or replace function public.send_message(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := (select auth.uid());
  v_venue uuid := nullif(p ->> 'venue_id', '')::uuid;
  v_audience text := coalesce(p ->> 'audience', '');
  v_target uuid := nullif(p ->> 'audience_id', '')::uuid;
  v_event uuid := nullif(p ->> 'event_id', '')::uuid;
  v_body text := btrim(coalesce(p ->> 'body', ''));
  v_urgent boolean := coalesce((p ->> 'urgent')::boolean, false);
  v_venue_wide boolean;
  v_label text;
  v_sender text;
  v_row messages%rowtype;
  v_count integer := 0;
  r record;
begin
  if v_me is null or v_venue is null or not public.is_venue_member(v_venue) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not (public.has_permission(v_venue, 'view_live') or public.has_permission(v_venue, 'manage_schedule')) then
    raise exception 'Only managers and leads can send messages' using errcode = '42501';
  end if;
  if length(v_body) = 0 then
    raise exception 'Write a message' using errcode = '22023';
  end if;
  if length(v_body) > 1000 then
    raise exception 'Messages are limited to 1,000 characters' using errcode = '22023';
  end if;
  if v_event is not null and not exists (select 1 from events e where e.id = v_event and e.venue_id = v_venue) then
    raise exception 'Unknown event' using errcode = '22023';
  end if;
  v_venue_wide := public.has_venue_permission(v_venue, 'view_live') or public.has_venue_permission(v_venue, 'manage_schedule');

  if v_audience = 'everyone' then
    if not v_venue_wide then
      raise exception 'Only venue managers can message everyone' using errcode = '42501';
    end if;
    v_target := null;
    v_label := 'Everyone';
  elsif v_audience = 'managers' then
    v_target := null;
    v_label := 'Managers and leads';
  elsif v_audience = 'level' then
    select 'Level: ' || l.name into v_label from venue_levels l where l.id = v_target and l.venue_id = v_venue;
    if v_label is null then raise exception 'Unknown level' using errcode = '22023'; end if;
    if not (v_venue_wide
            or v_target in (select public.permission_scope_ids(v_venue, 'view_live', 'level'))
            or v_target in (select public.permission_scope_ids(v_venue, 'manage_schedule', 'level'))) then
      raise exception 'You can only message storefronts in your area' using errcode = '42501';
    end if;
  elsif v_audience = 'storefront' then
    select s.name into v_label from storefronts s where s.id = v_target and s.venue_id = v_venue;
    if v_label is null then raise exception 'Unknown storefront' using errcode = '22023'; end if;
    if not (public.can_on_storefront(v_target, 'view_live') or public.can_on_storefront(v_target, 'manage_schedule')) then
      raise exception 'You can only message storefronts in your area' using errcode = '42501';
    end if;
  elsif v_audience = 'worker' then
    select coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name into v_label
      from workers w where w.id = v_target and w.venue_id = v_venue;
    if v_label is null then raise exception 'Unknown person' using errcode = '22023'; end if;
    if not (v_venue_wide or public.has_venue_permission(v_venue, 'view_workers')
            or exists (select 1 from shifts s
                       where s.worker_id = v_target and s.status = 'assigned' and s.call_time > now() - interval '1 day'
                         and (public.can_on_storefront(s.storefront_id, 'view_live')
                              or public.can_on_storefront(s.storefront_id, 'manage_schedule')))) then
      raise exception 'You can only message people working in your area' using errcode = '42501';
    end if;
    if not exists (select 1 from workers w where w.id = v_target and w.user_id is not null and w.status = 'active') then
      raise exception 'This person has not signed in to the app yet' using errcode = '22023';
    end if;
  else
    raise exception 'Unknown audience' using errcode = '22023';
  end if;

  -- Storefront and level messages reach the people working the current event.
  if v_audience in ('level', 'storefront') then
    v_event := coalesce(v_event, public.comms_current_event(v_venue));
    if v_event is not null then
      v_label := v_label || ' · ' || (select e.name from events e where e.id = v_event);
    end if;
  elsif v_audience <> 'worker' then
    v_event := null;
  end if;

  select coalesce(nullif(display_name, ''), 'A manager') into v_sender from user_profiles where id = v_me;
  insert into messages (venue_id, sender_id, sender_name, audience, audience_id, audience_label, event_id, body, urgent)
  values (v_venue, v_me, coalesce(v_sender, 'A manager'), v_audience, v_target, v_label, v_event, v_body, v_urgent)
  returning * into v_row;

  for r in select u as user_id, public.comms_language(v_venue, u) as lang from public.message_recipients(v_row.id) u loop
    perform public.notify_user(v_venue, r.user_id, 'message',
      case when v_urgent then (case when r.lang = 'es' then 'Urgente de ' else 'Urgent from ' end)
           else (case when r.lang = 'es' then 'Mensaje de ' else 'Message from ' end) end || v_row.sender_name,
      v_body, '/inbox',
      case when v_urgent then array['in_app', 'push', 'email'] else array['in_app', 'push'] end,
      jsonb_build_object('message_id', v_row.id, 'urgent', v_urgent));
    v_count := v_count + 1;
  end loop;
  update messages set recipient_count = v_count where id = v_row.id returning * into v_row;

  return to_jsonb(v_row) || jsonb_build_object('read_count', 0, 'read_at', null);
end $$;

-- Messages to me (not the ones I sent), newest first, with my read time.
create or replace function public.my_messages(p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object('read_at', r.read_at) order by m.created_at desc), '[]'::jsonb)
  from (
    select * from messages msg
    where msg.venue_id in (select vm.venue_id from venue_memberships vm where vm.user_id = (select auth.uid()) and vm.status = 'active')
      and msg.sender_id is distinct from (select auth.uid())
      and msg.created_at > now() - interval '30 days'
      and public.message_visible_to(msg.id, (select auth.uid()))
    order by msg.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) m
  left join message_reads r on r.message_id = m.id and r.user_id = (select auth.uid());
$$;

-- Marks messages read (and their notifications). Ignores messages the caller cannot see.
create or replace function public.mark_messages_read(p_ids uuid[])
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := (select auth.uid());
  n integer;
begin
  insert into message_reads (message_id, user_id)
  select m.id, v_me from messages m
  where m.id = any (coalesce(p_ids, '{}')) and public.message_visible_to(m.id, v_me)
  on conflict do nothing;
  get diagnostics n = row_count;
  update notifications set read_at = now()
   where user_id = v_me and kind = 'message' and read_at is null
     and (data ->> 'message_id') = any (select unnest(coalesce(p_ids, '{}'))::text);
  return n;
end $$;

create or replace function public.mark_message_read(p_id uuid)
returns void language sql security definer set search_path = public as $$
  select public.mark_messages_read(array[p_id]);
$$;

-- Sender view: messages I sent (venue managers see every message at the venue), with
-- how many recipients have read each one.
create or replace function public.sent_messages(p_venue uuid, p_limit integer default 50)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(m) || jsonb_build_object(
      'read_count', (select count(*) from message_reads r where r.message_id = m.id and r.user_id is distinct from m.sender_id),
      'mine', m.sender_id = (select auth.uid()))
    order by m.created_at desc), '[]'::jsonb)
  from (
    select * from messages msg
    where msg.venue_id = p_venue
      and (msg.sender_id = (select auth.uid()) or public.has_venue_permission(p_venue, 'manage_schedule'))
    order by msg.created_at desc
    limit least(greatest(coalesce(p_limit, 50), 1), 200)
  ) m;
$$;

-- ---------------------------------------------------------------------------
-- Announcements and policy acknowledgments
-- ---------------------------------------------------------------------------
create table public.announcements (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  title text not null check (length(btrim(title)) between 1 and 200),
  body text not null default '' check (length(body) <= 5000),
  -- {} is everyone. Otherwise every listed filter must match:
  --   {"worker_types": ["regular", "temp", "npo"], "job_roles": ["bartender", "lead"],
  --    "roles": ["storefront_lead"]}   (roles are venue role codes)
  audience jsonb not null default '{}'::jsonb check (jsonb_typeof(audience) = 'object'),
  requires_ack boolean not null default false,
  -- A policy needs the person's typed name to acknowledge.
  is_policy boolean not null default false,
  -- documents/<venue_id>/announcements/<file>
  document_path text check (document_path is null or length(document_path) <= 500),
  published_at timestamptz not null default now(),
  expires_at timestamptz,
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  check (expires_at is null or expires_at > published_at),
  check (not is_policy or requires_ack)
);
create index announcements_venue_idx on public.announcements(venue_id, published_at desc);

create table public.announcement_acks (
  announcement_id uuid not null references public.announcements(id) on delete cascade,
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  worker_id uuid references public.workers(id) on delete set null,
  acked_at timestamptz not null default now(),
  typed_name text not null default '' check (length(typed_name) <= 120),
  primary key (announcement_id, user_id)
);

create trigger announcements_audit after insert or update or delete on public.announcements
for each row execute function public.audit_row_change();
create trigger announcement_acks_audit after insert or update or delete on public.announcement_acks
for each row execute function public.audit_row_change();

-- True when the person matches the audience filters.
create or replace function public.announcement_audience_has(p_venue uuid, p_audience jsonb, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  with w as (
    select * from workers where venue_id = p_venue and user_id = p_user and status = 'active' limit 1
  ), f as (
    select
      coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p_audience -> 'worker_types') = 'array' then p_audience -> 'worker_types' else '[]' end) x), '{}') as types,
      coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p_audience -> 'job_roles') = 'array' then p_audience -> 'job_roles' else '[]' end) x), '{}') as jobs,
      coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p_audience -> 'roles') = 'array' then p_audience -> 'roles' else '[]' end) x), '{}') as roles
  )
  select public.comms_is_person(p_venue, p_user)
    and (cardinality(f.types) = 0 or exists (select 1 from w where w.worker_type = any (f.types)))
    and (cardinality(f.jobs) = 0 or exists (select 1 from w join worker_job_roles j on j.worker_id = w.id where j.job_role_code = any (f.jobs)))
    and (cardinality(f.roles) = 0 or exists (select 1 from role_assignments ra
                                             where ra.venue_id = p_venue and ra.user_id = p_user and ra.role_code = any (f.roles)))
  from f;
$$;

-- People who manage announcements at the venue.
create or replace function public.can_manage_announcements(p_venue uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_venue_permission(p_venue, 'manage_workers') or public.has_venue_permission(p_venue, 'manage_settings');
$$;

create or replace function public.announcement_visible_to(p_id uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from announcements a
    where a.id = p_id
      and a.published_at <= now() and (a.expires_at is null or a.expires_at > now())
      and public.announcement_audience_has(a.venue_id, a.audience, p_user)
  );
$$;

create or replace function public.can_see_announcement(p_id uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.announcement_visible_to(p_id, (select auth.uid()))
      or exists (select 1 from announcements a where a.id = p_id and public.can_manage_announcements(a.venue_id));
$$;

-- Everyone an announcement is for (user ids).
create or replace function public.announcement_audience(p_id uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select m.user_id
  from announcements a
  join venue_memberships m on m.venue_id = a.venue_id and m.status = 'active'
  where a.id = p_id and public.announcement_audience_has(a.venue_id, a.audience, m.user_id);
$$;

alter table public.announcements enable row level security;
alter table public.announcement_acks enable row level security;
revoke all on public.announcements, public.announcement_acks from anon;
revoke insert, update, delete on public.announcements, public.announcement_acks from authenticated;

create policy announcements_read on public.announcements for select to authenticated
  using (public.can_see_announcement(id));
create policy announcement_acks_read on public.announcement_acks for select to authenticated
  using (user_id = (select auth.uid()) or public.can_manage_announcements(venue_id));

-- Publishes an announcement and tells its audience.
--   p: {venue_id, title, body, audience?, requires_ack?, is_policy?, document_path?, expires_at?}
create or replace function public.publish_announcement(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid := nullif(p ->> 'venue_id', '')::uuid;
  v_policy boolean := coalesce((p ->> 'is_policy')::boolean, false);
  v_ack boolean := coalesce((p ->> 'requires_ack')::boolean, false) or v_policy;
  v_doc text := nullif(btrim(coalesce(p ->> 'document_path', '')), '');
  v_audience jsonb := coalesce(p -> 'audience', '{}'::jsonb);
  v_row announcements%rowtype;
  v_count integer := 0;
  r record;
begin
  if v_venue is null or not public.can_manage_announcements(v_venue) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(v_audience) <> 'object' then
    raise exception 'Audience must be an object' using errcode = '22023';
  end if;
  if v_doc is not null and (split_part(v_doc, '/', 1) <> v_venue::text or split_part(v_doc, '/', 2) <> 'announcements') then
    raise exception 'The document must be uploaded for this venue' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p ->> 'title', ''))) = 0 then
    raise exception 'Give the announcement a title' using errcode = '22023';
  end if;

  insert into announcements (venue_id, title, body, audience, requires_ack, is_policy, document_path, expires_at)
  values (v_venue, btrim(p ->> 'title'), coalesce(p ->> 'body', ''), v_audience, v_ack, v_policy, v_doc,
          nullif(p ->> 'expires_at', '')::timestamptz)
  returning * into v_row;

  for r in select u as user_id, public.comms_language(v_venue, u) as lang
           from public.announcement_audience(v_row.id) u where u is distinct from (select auth.uid()) loop
    perform public.notify_user(v_venue, r.user_id, 'announcement',
      case when v_ack then (case when r.lang = 'es' then 'Lea y confirme: ' else 'Please read and acknowledge: ' end)
           else (case when r.lang = 'es' then 'Nuevo aviso: ' else 'New announcement: ' end) end || v_row.title,
      left(v_row.body, 300), '/inbox',
      case when v_policy then array['in_app', 'push', 'email'] else array['in_app', 'push'] end,
      jsonb_build_object('announcement_id', v_row.id));
    v_count := v_count + 1;
  end loop;

  return to_jsonb(v_row) || jsonb_build_object('audience_count', v_count, 'ack_count', 0);
end $$;

-- Announcements for me: ones I still need to acknowledge first (policies first), then newest.
create or replace function public.my_announcements()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(a) || jsonb_build_object('acked_at', k.acked_at, 'typed_name', k.typed_name)
      order by (a.requires_ack and k.acked_at is null) desc,
               (a.is_policy and k.acked_at is null) desc, a.published_at desc), '[]'::jsonb)
  from announcements a
  left join announcement_acks k on k.announcement_id = a.id and k.user_id = (select auth.uid())
  where a.venue_id in (select vm.venue_id from venue_memberships vm where vm.user_id = (select auth.uid()) and vm.status = 'active')
    and public.announcement_visible_to(a.id, (select auth.uid()));
$$;

-- "I have read this." A policy also needs the person's typed name. The first
-- acknowledgment is kept.
create or replace function public.acknowledge_announcement(p_id uuid, p_typed_name text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := (select auth.uid());
  a announcements%rowtype;
  v_name text := btrim(coalesce(p_typed_name, ''));
  v_row announcement_acks%rowtype;
begin
  select * into a from announcements where id = p_id;
  if not found or not public.announcement_visible_to(p_id, v_me) then
    raise exception 'Announcement not found' using errcode = 'P0002';
  end if;
  if not a.requires_ack then
    raise exception 'This announcement does not need an acknowledgment' using errcode = '22023';
  end if;
  if a.is_policy and length(v_name) < 2 then
    raise exception 'Type your full name to acknowledge this policy' using errcode = '22023';
  end if;
  insert into announcement_acks (announcement_id, venue_id, user_id, worker_id, typed_name)
  values (p_id, a.venue_id, v_me,
          (select w.id from workers w where w.venue_id = a.venue_id and w.user_id = v_me limit 1), left(v_name, 120))
  on conflict (announcement_id, user_id) do nothing;
  select * into v_row from announcement_acks where announcement_id = p_id and user_id = v_me;
  update notifications set read_at = now()
   where user_id = v_me and kind = 'announcement' and read_at is null and data ->> 'announcement_id' = p_id::text;
  return to_jsonb(v_row);
end $$;

-- For managers: every announcement with its audience size and acknowledgments.
create or replace function public.announcement_summaries(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.can_manage_announcements(p_venue) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(to_jsonb(a) || jsonb_build_object(
        'audience_count', (select count(*) from public.announcement_audience(a.id)),
        'ack_count', (select count(*) from announcement_acks k where k.announcement_id = a.id
                      and k.user_id in (select public.announcement_audience(a.id))),
        'created_by_name', coalesce((select display_name from user_profiles u where u.id = a.created_by), ''))
      order by a.published_at desc)
    from (select * from announcements where venue_id = p_venue order by published_at desc limit 100) a), '[]'::jsonb);
end $$;

-- Who has acknowledged and who has not.
create or replace function public.announcement_ack_report(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a announcements%rowtype;
begin
  select * into a from announcements where id = p_id;
  if not found or not public.can_manage_announcements(a.venue_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'announcement', to_jsonb(a),
    'people', coalesce((
      select jsonb_agg(jsonb_build_object(
          'user_id', u.user_id, 'worker_id', w.id,
          'name', coalesce(case when w.id is not null then coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name end,
                           up.display_name, 'Unnamed'),
          'employee_number', coalesce(w.employee_number, ''), 'worker_type', w.worker_type,
          'acked_at', k.acked_at, 'typed_name', coalesce(k.typed_name, ''))
        order by (k.acked_at is not null), coalesce(w.last_name, up.display_name), w.first_name)
      from (select public.announcement_audience(p_id) as user_id) u
      left join workers w on w.venue_id = a.venue_id and w.user_id = u.user_id
      left join user_profiles up on up.id = u.user_id
      left join announcement_acks k on k.announcement_id = p_id and k.user_id = u.user_id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- Notification dedupe keys (scheduled reminders, reminders to acknowledge)
-- ---------------------------------------------------------------------------
create table public.notification_keys (
  key text primary key check (length(key) between 1 and 300),
  created_at timestamptz not null default now()
);
alter table public.notification_keys enable row level security;
revoke all on public.notification_keys from anon, authenticated;

-- Queues a notification once per key. Returns true when it was queued now.
create or replace function public.notify_once(p_key text, p_venue uuid, p_user uuid, p_kind text, p_title text,
  p_body text default '', p_link text default '', p_channels text[] default '{in_app,push}', p_data jsonb default '{}')
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return false; end if;
  insert into notification_keys (key) values (p_key) on conflict do nothing;
  if not found then return false; end if;
  perform public.notify_user(p_venue, p_user, p_kind, p_title, p_body, p_link, p_channels, p_data);
  return true;
end $$;

-- Reminds everyone who has not acknowledged yet. At most once an hour per person.
create or replace function public.remind_unacknowledged(p_id uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  a announcements%rowtype;
  v_count integer := 0;
  r record;
begin
  select * into a from announcements where id = p_id;
  if not found or not public.can_manage_announcements(a.venue_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if not a.requires_ack then
    raise exception 'This announcement does not need an acknowledgment' using errcode = '22023';
  end if;
  for r in
    select u as user_id, public.comms_language(a.venue_id, u) as lang
    from public.announcement_audience(p_id) u
    where not exists (select 1 from announcement_acks k where k.announcement_id = p_id and k.user_id = u)
  loop
    if public.notify_once('ack_reminder:' || p_id || ':' || r.user_id || ':' || to_char(now(), 'YYYYMMDDHH24'),
        a.venue_id, r.user_id, 'announcement',
        case when r.lang = 'es' then 'Recordatorio: lea y confirme ' else 'Reminder: please read and acknowledge ' end || a.title,
        left(a.body, 300), '/inbox',
        case when a.is_policy then array['in_app', 'push', 'email'] else array['in_app', 'push'] end,
        jsonb_build_object('announcement_id', a.id, 'reminder', true)) then
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

-- ---------------------------------------------------------------------------
-- Documents (policy PDFs): documents/<venue_id>/announcements/<file>
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('documents', 'documents', false, 10485760,
        array['application/pdf', 'image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy comms_documents_read on storage.objects for select to authenticated
  using (bucket_id = 'documents' and split_part(name, '/', 2) = 'announcements'
         and public.is_venue_member(public.storage_venue(name)));
create policy comms_documents_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'documents' and split_part(name, '/', 2) = 'announcements'
              and public.can_manage_announcements(public.storage_venue(name)));
create policy comms_documents_update on storage.objects for update to authenticated
  using (bucket_id = 'documents' and split_part(name, '/', 2) = 'announcements'
         and public.can_manage_announcements(public.storage_venue(name)));
create policy comms_documents_delete on storage.objects for delete to authenticated
  using (bucket_id = 'documents' and split_part(name, '/', 2) = 'announcements'
         and public.can_manage_announcements(public.storage_venue(name)));

-- ---------------------------------------------------------------------------
-- Delivery preferences and device tokens
-- ---------------------------------------------------------------------------
create table public.notification_prefs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  push boolean not null default true,
  -- Email is opt-in.
  email boolean not null default false,
  -- Venue local time. Non-urgent push and email wait until the quiet hours end.
  quiet_start time,
  quiet_end time,
  updated_at timestamptz not null default now(),
  check ((quiet_start is null) = (quiet_end is null))
);
alter table public.notification_prefs enable row level security;
revoke all on public.notification_prefs from anon;
revoke insert, update, delete on public.notification_prefs from authenticated;
create policy notification_prefs_read_own on public.notification_prefs for select to authenticated
  using (user_id = (select auth.uid()));

create table public.push_tokens (
  token text primary key check (length(token) between 1 and 4096),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('ios', 'android', 'web')),
  updated_at timestamptz not null default now()
);
create index push_tokens_user_idx on public.push_tokens(user_id);
alter table public.push_tokens enable row level security;
revoke all on public.push_tokens from anon;
revoke insert, update, delete on public.push_tokens from authenticated;
create policy push_tokens_read_own on public.push_tokens for select to authenticated
  using (user_id = (select auth.uid()));

-- My delivery settings (defaults on) and where they go. Staff contact details come
-- from the staff record and are changed by a manager.
create or replace function public.my_notification_prefs()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'push', coalesce(p.push, true), 'email', coalesce(p.email, false),
    'quiet_start', to_char(p.quiet_start, 'HH24:MI'), 'quiet_end', to_char(p.quiet_end, 'HH24:MI'),
    'has_staff_record', w.id is not null,
    'email_address', coalesce(nullif(w.email, ''), up.contact_email, ''))
  from (select (select auth.uid()) as id) me
  left join notification_prefs p on p.user_id = me.id
  left join user_profiles up on up.id = me.id
  left join lateral (select * from workers x where x.user_id = me.id limit 1) w on true;
$$;

--   p: {push?, email?, quiet_start?: 'HH:MM' | null, quiet_end?, email_address?}
-- email_address applies only to people without a staff record.
create or replace function public.set_notification_prefs(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := (select auth.uid());
  v_start time := nullif(p ->> 'quiet_start', '')::time;
  v_end time := nullif(p ->> 'quiet_end', '')::time;
begin
  if v_me is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  if (v_start is null) <> (v_end is null) then
    raise exception 'Give both a start and an end for quiet hours' using errcode = '22023';
  end if;
  insert into notification_prefs (user_id, push, email, quiet_start, quiet_end, updated_at)
  values (v_me, coalesce((p ->> 'push')::boolean, true), coalesce((p ->> 'email')::boolean, false),
          v_start, v_end, now())
  on conflict (user_id) do update set
    push = coalesce((p ->> 'push')::boolean, notification_prefs.push),
    email = coalesce((p ->> 'email')::boolean, notification_prefs.email),
    quiet_start = case when p ? 'quiet_start' then v_start else notification_prefs.quiet_start end,
    quiet_end = case when p ? 'quiet_end' then v_end else notification_prefs.quiet_end end,
    updated_at = now();
  if not exists (select 1 from workers w where w.user_id = v_me) then
    if p ? 'email_address' then
      if coalesce(p ->> 'email_address', '') !~ '^([^@\s]+@[^@\s]+\.[^@\s]+)?$' then
        raise exception 'Enter a valid email address' using errcode = '22023';
      end if;
      update user_profiles set contact_email = btrim(coalesce(p ->> 'email_address', '')) where id = v_me;
    end if;
  end if;
  return public.my_notification_prefs();
end $$;

-- A device token for push (Firebase Cloud Messaging). A token moves to whoever signed
-- in on the device last.
create or replace function public.register_push_token(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select auth.uid()) is null then raise exception 'Not signed in' using errcode = '42501'; end if;
  insert into push_tokens (token, user_id, platform, updated_at)
  values (p_token, (select auth.uid()), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;

create or replace function public.remove_push_token(p_token text)
returns void language sql security definer set search_path = public as $$
  delete from push_tokens where token = p_token and user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------------
-- Delivery (notify-dispatch, service role)
-- ---------------------------------------------------------------------------

-- Claims up to p_limit notifications that still need push or email, with everything
-- the sender needs: contact details, preferences, quiet hours, device tokens. Claimed
-- rows are marked so a second dispatcher skips them; a claim not finished in 10 minutes
-- is released. Notifications not delivered within a day are marked expired.
create or replace function public.claim_notification_batch(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v jsonb;
begin
  update notifications n
     set sent = coalesce((select jsonb_object_agg(c, 'expired') from unnest(n.channels) c where c <> 'in_app'), '{}'::jsonb)
                || jsonb_build_object('expired', true)
   where n.channels <> '{in_app}' and n.sent = '{}'::jsonb and n.created_at < now() - interval '1 day';

  update notifications set sent = '{}'::jsonb
   where sent ? '_claimed_at' and (sent ->> '_claimed_at')::timestamptz < now() - interval '10 minutes';

  with picked as (
    select id from notifications
    where channels <> '{in_app}' and sent = '{}'::jsonb and (deliver_after is null or deliver_after <= now())
    order by created_at
    limit least(greatest(coalesce(p_limit, 50), 1), 500)
    for update skip locked
  ), claimed as (
    update notifications n set sent = jsonb_build_object('_claimed_at', now())
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
                               from push_tokens t where t.user_id = c.user_id), '[]'::jsonb))
      order by c.created_at), '[]'::jsonb)
  into v
  from claimed c
  join venues v on v.id = c.venue_id
  left join user_profiles up on up.id = c.user_id
  left join notification_prefs p on p.user_id = c.user_id
  left join lateral (select * from workers x where x.user_id = c.user_id and x.venue_id = c.venue_id limit 1) w on true;
  return v;
end $$;

-- Writes delivery results: [{"id": ..., "sent": {"push": "sent", "email": "opted_out"}}] or,
-- to retry later (quiet hours), [{"id": ..., "deliver_after": "<timestamp>"}].
create or replace function public.record_notification_results(p_results jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  update notifications t
     set sent = case when jsonb_typeof(r -> 'sent') = 'object' then r -> 'sent' else '{}'::jsonb end,
         deliver_after = case when jsonb_typeof(r -> 'sent') = 'object' then t.deliver_after
                              else nullif(r ->> 'deliver_after', '')::timestamptz end
    from jsonb_array_elements(coalesce(p_results, '[]'::jsonb)) r
   where t.id = (r ->> 'id')::uuid;
  get diagnostics n = row_count;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- Scheduled reminders (every 10 minutes; service role)
--   * call time: about 2 hours before call, to each assigned person
--   * missed clock-in: no clock-in some minutes after call + grace, to the person and
--     the storefront's leads (or the venue's schedulers when it has none), once
--   * certifications expiring within 30 days: weekly, to the person, and one weekly
--     list to the venue's staff managers
-- Venue settings (optional): notifications.call_reminder_minutes (120),
-- notifications.missed_clock_in_minutes (15, after attendance.late_grace_minutes).
-- ---------------------------------------------------------------------------
create index if not exists shifts_assigned_call_idx on public.shifts(call_time) where status = 'assigned';

create or replace function public.queue_scheduled_notifications(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r record;
  u record;
  v_call integer := 0;
  v_missed integer := 0;
  v_cert integer := 0;
  v_digest integer := 0;
  v_time text;
  v_any boolean;
  v_list text;
  v_week text;
begin
  -- Call-time reminders.
  for r in
    select s.id as shift_id, s.call_time, s.venue_id, w.id as worker_id, w.user_id, w.preferred_language as lang,
           e.name as event_name, f.name as storefront_name, v.time_zone
    from shifts s
    join workers w on w.id = s.worker_id
    join events e on e.id = s.event_id
    join storefronts f on f.id = s.storefront_id
    join venues v on v.id = s.venue_id
    where s.status = 'assigned' and e.status in ('scheduled', 'live')
      and w.user_id is not null and w.status = 'active'
      and s.call_time > p_now + interval '10 minutes'
      and s.call_time <= p_now + make_interval(mins => coalesce((v.settings -> 'notifications' ->> 'call_reminder_minutes')::integer, 120))
  loop
    v_time := to_char(r.call_time at time zone r.time_zone, 'FMHH12:MI AM');
    if public.notify_once('call_time:' || r.shift_id || ':' || r.worker_id || ':' || extract(epoch from r.call_time)::bigint,
        r.venue_id, r.user_id, 'call_time',
        case when r.lang = 'es' then 'Llegada ' || v_time || ' en ' || r.storefront_name
             else 'Call time ' || v_time || ' at ' || r.storefront_name end,
        case when r.lang = 'es' then r.event_name || '. Marque su entrada al llegar.'
             else r.event_name || '. Clock in when you arrive.' end,
        '/clock', array['in_app', 'push'], jsonb_build_object('shift_id', r.shift_id)) then
      v_call := v_call + 1;
    end if;
  end loop;

  -- Missed clock-ins.
  for r in
    select s.id as shift_id, s.call_time, s.venue_id, s.storefront_id, s.job_role_code, w.id as worker_id, w.user_id,
           w.preferred_language as lang, coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name as worker_name,
           f.name as storefront_name, v.time_zone
    from shifts s
    join workers w on w.id = s.worker_id
    join events e on e.id = s.event_id
    join storefronts f on f.id = s.storefront_id
    join venues v on v.id = s.venue_id
    where s.status = 'assigned' and e.status in ('scheduled', 'live')
      and s.call_time > p_now - interval '6 hours'
      and p_now >= s.call_time + make_interval(mins =>
            coalesce((v.settings -> 'attendance' ->> 'late_grace_minutes')::integer, 5)
          + coalesce((v.settings -> 'notifications' ->> 'missed_clock_in_minutes')::integer, 15))
      and not exists (select 1 from punches p where p.worker_id = s.worker_id and p.event_id = s.event_id
                      and p.kind = 'clock_in' and p.status <> 'voided')
  loop
    v_time := to_char(r.call_time at time zone r.time_zone, 'FMHH12:MI AM');
    if r.user_id is not null and public.notify_once('missed_clock_in:' || r.shift_id || ':' || r.worker_id,
        r.venue_id, r.user_id, 'missed_clock_in',
        case when r.lang = 'es' then 'No ha marcado su entrada' else 'You have not clocked in' end,
        case when r.lang = 'es' then 'Su hora de llegada en ' || r.storefront_name || ' era ' || v_time || '. Marque su entrada ahora o avise a su líder.'
             else 'Your call time at ' || r.storefront_name || ' was ' || v_time || '. Clock in now, or tell your lead if you cannot make it.' end,
        '/clock', array['in_app', 'push'], jsonb_build_object('shift_id', r.shift_id)) then
      v_missed := v_missed + 1;
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
        v_missed := v_missed + 1;
      end if;
    end loop;
  end loop;

  -- Certifications expiring within 30 days (the newest of each type per person).
  for r in
    select c.id as cert_id, c.expires_on, c.venue_id, w.user_id, w.preferred_language as lang,
           coalesce(t.name, c.cert_type_code) as cert_name, v.time_zone
    from worker_certifications c
    join workers w on w.id = c.worker_id
    join venues v on v.id = c.venue_id
    left join certification_types t on t.venue_id = c.venue_id and t.code = c.cert_type_code
    where w.status = 'active' and w.user_id is not null and c.expires_on is not null
      and c.expires_on >= (p_now at time zone v.time_zone)::date
      and c.expires_on <= (p_now at time zone v.time_zone)::date + 30
      and not exists (select 1 from worker_certifications n
                      where n.worker_id = c.worker_id and n.cert_type_code = c.cert_type_code and n.id <> c.id
                        and (n.expires_on is null or n.expires_on > c.expires_on))
  loop
    v_week := to_char(p_now at time zone r.time_zone, 'IYYY-IW');
    if public.notify_once('cert_expiring:' || r.cert_id || ':' || v_week, r.venue_id, r.user_id, 'cert_expiring',
        case when r.lang = 'es' then 'Su ' || r.cert_name || ' vence el ' || to_char(r.expires_on, 'DD/MM/YYYY')
             else 'Your ' || r.cert_name || ' expires ' || to_char(r.expires_on, 'FMMon FMDD, YYYY') end,
        case when r.lang = 'es' then 'Renuévela y entregue la nueva a su gerente para seguir en este puesto.'
             else 'Renew it and give the new one to your manager to keep working this role.' end,
        '/me', array['in_app', 'push', 'email'], jsonb_build_object('certification_id', r.cert_id)) then
      v_cert := v_cert + 1;
    end if;
  end loop;

  -- One weekly list per venue for the people who manage staff.
  for r in
    select c.venue_id, v.time_zone, count(*) as n,
           string_agg(coalesce(nullif(w.preferred_name, ''), w.first_name) || ' ' || w.last_name || ' (' ||
                      coalesce(t.name, c.cert_type_code) || ', ' || to_char(c.expires_on, 'FMMon FMDD') || ')',
                      '; ' order by c.expires_on, w.last_name) as list
    from worker_certifications c
    join workers w on w.id = c.worker_id
    join venues v on v.id = c.venue_id
    left join certification_types t on t.venue_id = c.venue_id and t.code = c.cert_type_code
    where w.status = 'active' and c.expires_on is not null
      and c.expires_on >= (p_now at time zone v.time_zone)::date
      and c.expires_on <= (p_now at time zone v.time_zone)::date + 30
      and not exists (select 1 from worker_certifications n
                      where n.worker_id = c.worker_id and n.cert_type_code = c.cert_type_code and n.id <> c.id
                        and (n.expires_on is null or n.expires_on > c.expires_on))
    group by c.venue_id, v.time_zone
  loop
    v_week := to_char(p_now at time zone r.time_zone, 'IYYY-IW');
    v_list := left(r.list, 1900);
    for u in
      select distinct ra.user_id from role_assignments ra
      join venue_roles vr on vr.venue_id = ra.venue_id and vr.code = ra.role_code
      join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
      where ra.venue_id = r.venue_id and ra.scope_type = 'venue' and 'manage_workers' = any (vr.permissions)
    loop
      if public.notify_once('cert_digest:' || r.venue_id || ':' || u.user_id || ':' || v_week, r.venue_id, u.user_id, 'cert_expiring',
          r.n || case when r.n = 1 then ' certification expires' else ' certifications expire' end || ' within 30 days',
          v_list, '/staff', array['in_app', 'email'], jsonb_build_object('count', r.n)) then
        v_digest := v_digest + 1;
      end if;
    end loop;
  end loop;

  delete from notification_keys where created_at < p_now - interval '90 days';

  return jsonb_build_object('call_time', v_call, 'missed_clock_in', v_missed, 'cert_expiring', v_cert, 'cert_digest', v_digest);
end $$;

-- Every 10 minutes where pg_cron is available (Supabase); local test databases skip it.
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    if exists (select 1 from cron.job where jobname = 'queue-scheduled-notifications') then
      perform cron.unschedule('queue-scheduled-notifications');
    end if;
    perform cron.schedule('queue-scheduled-notifications', '*/10 * * * *', 'select public.queue_scheduled_notifications()');
  end if;
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
    'public.user_has_any_permission(uuid, uuid, text[])',
    'public.comms_language(uuid, uuid)',
    'public.comms_current_event(uuid, timestamp with time zone)',
    'public.storefront_supervisors(uuid)',
    'public.message_visible_to(uuid, uuid)',
    'public.message_recipients(uuid)',
    'public.announcement_audience_has(uuid, jsonb, uuid)',
    'public.announcement_visible_to(uuid, uuid)',
    'public.announcement_audience(uuid)',
    'public.notify_once(text, uuid, uuid, text, text, text, text, text[], jsonb)',
    'public.claim_notification_batch(integer)',
    'public.record_notification_results(jsonb)',
    'public.queue_scheduled_notifications(timestamp with time zone)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
end $$;

-- Row level security helpers and the app's functions.
do $$
declare f text;
begin
  foreach f in array array[
    'public.can_see_message(uuid)',
    'public.can_see_announcement(uuid)',
    'public.can_manage_announcements(uuid)',
    'public.send_message(jsonb)',
    'public.my_messages(integer)',
    'public.mark_messages_read(uuid[])',
    'public.mark_message_read(uuid)',
    'public.sent_messages(uuid, integer)',
    'public.publish_announcement(jsonb)',
    'public.my_announcements()',
    'public.acknowledge_announcement(uuid, text)',
    'public.announcement_summaries(uuid)',
    'public.announcement_ack_report(uuid)',
    'public.remind_unacknowledged(uuid)',
    'public.my_notification_prefs()',
    'public.set_notification_prefs(jsonb)',
    'public.register_push_token(text, text)',
    'public.remove_push_token(text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;

-- The notify-dispatch function and the scheduler (service role).
grant execute on function
  public.claim_notification_batch(integer),
  public.record_notification_results(jsonb),
  public.queue_scheduled_notifications(timestamp with time zone)
to service_role;

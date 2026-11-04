-- Employees do not see wages: no pay rates and no pay-period lines (hours times rate,
-- amounts). Only people with view_pay at the venue read them. Employees still see their
-- own hours (from their punches) and their own tips (tip_allocations).

drop policy if exists pay_rates_read on public.pay_rates;
create policy pay_rates_read on public.pay_rates for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay'));

drop policy if exists pay_period_lines_read on public.pay_period_lines;
create policy pay_period_lines_read on public.pay_period_lines for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_pay'));

-- Tips a person received, with the event and storefront, for their own "My tips" screen.
-- Only their own rows; no rates or wages.
create or replace function public.my_tips(p_from date default null, p_to date default null)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
      'event_id', e.id, 'event_name', e.name, 'start_time', e.start_time,
      'storefront_name', coalesce(s.name, ''), 'hours', a.hours, 'amount', a.amount)
      order by e.start_time desc), '[]'::jsonb)
  from tip_allocations a
  join tip_pools t on t.id = a.pool_id
  join events e on e.id = t.event_id
  left join storefronts s on s.id = t.storefront_id
  join workers w on w.id = a.worker_id
  where w.user_id = (select auth.uid())
    and t.status = 'final'
    and (p_from is null or (e.start_time at time zone (select time_zone from venues v where v.id = e.venue_id))::date >= p_from)
    and (p_to is null or (e.start_time at time zone (select time_zone from venues v where v.id = e.venue_id))::date <= p_to);
$$;
revoke execute on function public.my_tips(date, date) from public, anon;
grant execute on function public.my_tips(date, date) to authenticated;

-- ---------------------------------------------------------------------------
-- Notifications: the shared inbox every Phase 3 feature writes to. In-app always;
-- push, SMS, and email are sent by the notify-dispatch function when the venue has
-- those providers configured (see `channels` and `sent`).
-- ---------------------------------------------------------------------------
create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  -- shift_offered, request_decided, schedule_changed, call_time, missed_clock_in,
  -- cert_expiring, onboarding_reminder, message, announcement ...
  kind text not null check (kind ~ '^[a-z][a-z0-9_]{1,39}$'),
  title text not null check (length(title) between 1 and 200),
  body text not null default '' check (length(body) <= 2000),
  -- In-app route to open, for example '/schedule'.
  link text not null default '',
  data jsonb not null default '{}'::jsonb,
  channels text[] not null default '{in_app}',
  -- Delivery results per channel, written by notify-dispatch: {"sms": "sent", ...}.
  sent jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index notifications_user_idx on public.notifications(user_id, created_at desc);
create index notifications_unsent_idx on public.notifications(created_at) where channels <> '{in_app}' and sent = '{}'::jsonb;

alter table public.notifications enable row level security;
revoke all on public.notifications from anon;
revoke insert, update, delete on public.notifications from authenticated;
create policy notifications_read_own on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
alter publication supabase_realtime add table public.notifications;

-- Queue a notification for one sign-in account. Called only by other database functions.
create or replace function public.notify_user(p_venue uuid, p_user uuid, p_kind text, p_title text,
  p_body text default '', p_link text default '', p_channels text[] default '{in_app,push}', p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_user is null then return; end if;
  insert into notifications (venue_id, user_id, kind, title, body, link, channels, data)
  values (p_venue, p_user, p_kind, left(p_title, 200), left(coalesce(p_body, ''), 2000), coalesce(p_link, ''),
          coalesce(p_channels, '{in_app}'), coalesce(p_data, '{}'));
end $$;

-- Same, addressed to a staff record (no-op when the person has no sign-in).
create or replace function public.notify_worker(p_worker uuid, p_kind text, p_title text,
  p_body text default '', p_link text default '', p_channels text[] default '{in_app,push}', p_data jsonb default '{}')
returns void language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where id = p_worker;
  if w.user_id is null then return; end if;
  perform public.notify_user(w.venue_id, w.user_id, p_kind, p_title, p_body, p_link, p_channels, p_data);
end $$;

create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = public as $$
declare
  n integer;
begin
  update notifications set read_at = now()
   where user_id = (select auth.uid()) and read_at is null and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

revoke execute on function public.notify_user(uuid, uuid, text, text, text, text, text[], jsonb) from public, anon, authenticated;
revoke execute on function public.notify_worker(uuid, text, text, text, text, text[], jsonb) from public, anon, authenticated;
revoke execute on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;

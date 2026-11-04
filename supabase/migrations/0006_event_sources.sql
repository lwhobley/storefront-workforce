-- Event calendar sources. The first venue pulls its event list from Premium Command, so
-- events are entered once. Sources are pluggable: premium_command now; csv import and
-- other calendars later.

create table public.event_sources (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  kind text not null check (kind in ('premium_command', 'csv')),
  -- Non-secret settings, for example {"remote_venue_id": "..."}. Credentials are kept as
  -- edge function secrets, never in the database.
  config jsonb not null default '{}'::jsonb,
  -- Map of source event types to this venue's event type codes.
  type_map jsonb not null default '{"hockey_game": "hockey", "concert": "concert", "sporting_event": "other"}'::jsonb,
  active boolean not null default true,
  last_synced_at timestamptz,
  last_result jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (venue_id, kind)
);

alter table public.event_sources enable row level security;
revoke all on public.event_sources from anon;
create policy event_sources_read on public.event_sources for select to authenticated
  using (public.has_venue_permission(venue_id, 'manage_events'));
create policy event_sources_write on public.event_sources for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings'))
  with check (public.has_venue_permission(venue_id, 'manage_settings'));

-- Creates or updates events from a source. Called by the event-sync function (service
-- role). Name, type, start, and end follow the source. Call and doors times follow the
-- venue's defaults unless a manager has changed them. Attendance and notes stay local.
-- An event cancelled in the source is cancelled here; events are never deleted.
create or replace function public.upsert_source_events(p_venue uuid, p_source text, p_events jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e jsonb;
  v_settings jsonb;
  v_doors_min integer;
  v_call_min integer;
  v_type_map jsonb;
  v_type text;
  v_start timestamptz;
  v_doors timestamptz;
  v_call timestamptz;
  v_status text;
  v_created integer := 0;
  v_updated integer := 0;
  v_existing events%rowtype;
begin
  select settings into v_settings from venues where id = p_venue;
  if v_settings is null then raise exception 'Venue not found' using errcode = 'P0002'; end if;
  v_doors_min := coalesce((v_settings -> 'event_defaults' ->> 'doors_before_start_minutes')::integer, 60);
  v_call_min := coalesce((v_settings -> 'event_defaults' ->> 'call_before_doors_minutes')::integer, 90);
  select type_map into v_type_map from event_sources where venue_id = p_venue and kind = p_source;
  v_type_map := coalesce(v_type_map, '{}'::jsonb);

  perform set_config('app.event_sync', 'on', true);
  perform set_config('app.audit_reason', 'Synced from ' || p_source, true);

  for e in select * from jsonb_array_elements(p_events) loop
    v_start := (e ->> 'start_time')::timestamptz;
    v_doors := v_start - make_interval(mins => v_doors_min);
    v_call := v_doors - make_interval(mins => v_call_min);
    v_type := coalesce(v_type_map ->> (e ->> 'event_type'), e ->> 'event_type');
    if not exists (select 1 from event_types where venue_id = p_venue and code = v_type) then
      v_type := 'other';
    end if;
    v_status := case when e ->> 'status' = 'cancelled' then 'cancelled' end;

    select * into v_existing from events
     where venue_id = p_venue and source = p_source and external_id = e ->> 'external_id';

    if not found then
      insert into events (venue_id, name, event_type_code, start_time, doors_time, call_time, end_time,
        expected_attendance, status, source, external_id, source_synced_at)
      values (p_venue, e ->> 'name', v_type, v_start, v_doors, v_call, (e ->> 'end_time')::timestamptz,
        coalesce((e ->> 'expected_attendance')::integer, 0), coalesce(v_status, 'scheduled'),
        p_source, e ->> 'external_id', now());
      v_created := v_created + 1;
    else
      update events set
        name = e ->> 'name',
        event_type_code = v_type,
        start_time = v_start,
        end_time = (e ->> 'end_time')::timestamptz,
        doors_time = case when times_overridden then least(doors_time, v_start) else v_doors end,
        call_time = case when times_overridden then least(call_time, least(doors_time, v_start)) else v_call end,
        status = case when v_status = 'cancelled' then 'cancelled'
                      when status = 'cancelled' and v_status is null then 'scheduled'
                      else status end,
        source_synced_at = now()
      where id = v_existing.id
        and (
          (name, event_type_code, start_time, end_time) is distinct from
            (e ->> 'name', v_type, v_start, (e ->> 'end_time')::timestamptz)
          or coalesce(v_status = 'cancelled', false) is distinct from (v_existing.status = 'cancelled')
        );
      if found then v_updated := v_updated + 1; end if;
    end if;
  end loop;

  update event_sources set last_synced_at = now(),
         last_result = jsonb_build_object('created', v_created, 'updated', v_updated, 'received', jsonb_array_length(p_events))
   where venue_id = p_venue and kind = p_source;

  perform set_config('app.event_sync', 'off', true);
  perform set_config('app.audit_reason', '', true);
  return jsonb_build_object('created', v_created, 'updated', v_updated);
end $$;

revoke execute on function public.upsert_source_events(uuid, text, jsonb) from public, anon, authenticated;

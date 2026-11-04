-- Phase 4 operations: opening and closing checklists per storefront, and incidents.
--
-- Checklists: each venue has templates (opening, closing, or custom) whose items are
-- staffing tasks (uniforms checked, stations assigned, who is on site). A run is one
-- template at one storefront for one event; it copies the items that apply to the
-- storefront's kind when it starts, so later template edits never change a run in
-- progress. Leads (their storefront) and managers tick items, add notes and photos; a
-- manager whose scope is the venue or the storefront's level signs off, and can reopen
-- a signed-off run with a reason.
--
-- Works offline: every change to an item carries an id made on the device. The server
-- keeps each id once (checklist_item_changes), so a change resent after a dropped
-- connection is not applied twice. When two devices change the same item, the change
-- made later on the device wins; photos are only ever added.
--
-- Incidents: injuries, safety issues, employee incidents (discipline) and other, with
-- people involved, photos, a follow-up timeline, an owner and a closing note. Leads and
-- managers log incidents for their scope; employee incidents are seen only by people who
-- manage staff for the whole venue (and whoever reported it). Employees and partners
-- never see incidents. The incident id is made on the device too, so a report logged
-- offline is stored once.
--
-- No new permissions: checklists use view_live (see) and manage_schedule (tick, sign
-- off); incidents use view_live (log and see in scope) and manage_workers (employee
-- incidents).

-- ---------------------------------------------------------------------------
-- Checklist templates
-- ---------------------------------------------------------------------------
create table public.checklist_templates (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  kind text not null check (kind in ('opening', 'closing', 'custom')),
  name text not null check (length(btrim(name)) between 1 and 80),
  active boolean not null default true,
  sort integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id)
);
create unique index checklist_templates_name_idx on public.checklist_templates(venue_id, lower(name));

create table public.checklist_template_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  template_id uuid not null,
  label text not null check (length(btrim(label)) between 1 and 120),
  help text not null default '' check (length(help) <= 300),
  photo_required boolean not null default false,
  -- Storefront kinds the item is for; empty means every storefront.
  storefront_kinds text[] not null default '{}'
    check (storefront_kinds <@ array['permanent_stand', 'portable_cart', 'bar', 'kiosk']::text[]),
  sort integer not null default 0,
  active boolean not null default true,
  unique (venue_id, id),
  foreign key (venue_id, template_id) references public.checklist_templates(venue_id, id) on delete cascade
);
create index checklist_template_items_template_idx on public.checklist_template_items(template_id, sort);

-- ---------------------------------------------------------------------------
-- Runs, their items, and the log of changes from devices
-- ---------------------------------------------------------------------------
create table public.checklist_runs (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  event_id uuid not null,
  storefront_id uuid not null,
  template_id uuid not null,
  -- in_progress until every item is done; complete; signed_off by a manager.
  status text not null default 'in_progress' check (status in ('in_progress', 'complete', 'signed_off')),
  started_by uuid references auth.users(id),
  started_at timestamptz not null default now(),
  signed_off_by uuid references auth.users(id),
  signed_off_at timestamptz,
  sign_off_note text not null default '' check (length(sign_off_note) <= 500),
  reopened_by uuid references auth.users(id),
  reopened_at timestamptz,
  reopen_reason text not null default '' check (length(reopen_reason) <= 500),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  unique (event_id, storefront_id, template_id),
  foreign key (venue_id, event_id) references public.events(venue_id, id) on delete cascade,
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id) on delete cascade,
  foreign key (venue_id, template_id) references public.checklist_templates(venue_id, id),
  check ((status = 'signed_off') = (signed_off_at is not null))
);
create index checklist_runs_event_idx on public.checklist_runs(venue_id, event_id);

create table public.checklist_run_items (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  run_id uuid not null,
  template_item_id uuid not null,
  -- Copied from the template when the run started.
  label text not null,
  help text not null default '',
  photo_required boolean not null default false,
  sort integer not null default 0,
  done boolean not null default false,
  done_by uuid references auth.users(id),
  done_at timestamptz,
  note text not null default '' check (length(note) <= 500),
  -- checklist-photos/<venue_id>/<run_id>/<file>
  photo_paths text[] not null default '{}' check (cardinality(photo_paths) <= 6),
  -- Device time of the change now shown; an older change arriving later does not win.
  last_change_at timestamptz,
  updated_at timestamptz not null default now(),
  unique (run_id, template_item_id),
  foreign key (venue_id, run_id) references public.checklist_runs(venue_id, id) on delete cascade,
  foreign key (venue_id, template_item_id) references public.checklist_template_items(venue_id, id)
);

-- One row per change sent from a device, by the id the device made.
create table public.checklist_item_changes (
  id uuid primary key,
  venue_id uuid not null,
  run_id uuid not null,
  run_item_id uuid not null,
  done boolean not null,
  note text,
  photo_paths text[] not null default '{}',
  occurred_at timestamptz not null,
  recorded_at timestamptz not null default now(),
  actor_id uuid not null default auth.uid() references auth.users(id),
  -- False when a later change from another device was already shown.
  applied boolean not null default true,
  foreign key (venue_id, run_id) references public.checklist_runs(venue_id, id) on delete cascade
);
create index checklist_item_changes_run_idx on public.checklist_item_changes(run_id, occurred_at);

create trigger checklist_templates_touch before update on public.checklist_templates
for each row execute function public.touch_updated_at();
create trigger checklist_runs_touch before update on public.checklist_runs
for each row execute function public.touch_updated_at();
create trigger checklist_run_items_touch before update on public.checklist_run_items
for each row execute function public.touch_updated_at();

create trigger checklist_templates_audit after insert or update or delete on public.checklist_templates
for each row execute function public.audit_row_change();
create trigger checklist_template_items_audit after insert or update or delete on public.checklist_template_items
for each row execute function public.audit_row_change();
create trigger checklist_runs_audit after insert or update or delete on public.checklist_runs
for each row execute function public.audit_row_change();
create trigger checklist_run_items_audit after insert or update or delete on public.checklist_run_items
for each row execute function public.audit_row_change();
create trigger checklist_item_changes_audit after insert or update or delete on public.checklist_item_changes
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Incidents
-- ---------------------------------------------------------------------------
create table public.incidents (
  -- Made on the device, so a report sent twice is stored once.
  id uuid primary key,
  venue_id uuid not null references public.venues(id) on delete cascade,
  kind text not null check (kind in ('injury', 'safety', 'employee', 'other')),
  severity text not null default 'low' check (severity in ('low', 'medium', 'high')),
  event_id uuid,
  storefront_id uuid,
  occurred_at timestamptz not null,
  description text not null check (length(btrim(description)) between 1 and 4000),
  -- incident-photos/<venue_id>/<incident_id>/<file>
  photo_paths text[] not null default '{}' check (cardinality(photo_paths) <= 12),
  status text not null default 'open' check (status in ('open', 'following_up', 'closed')),
  assigned_to uuid references auth.users(id),
  closing_note text not null default '' check (length(closing_note) <= 2000),
  closed_by uuid references auth.users(id),
  closed_at timestamptz,
  reported_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, event_id) references public.events(venue_id, id),
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id),
  check ((status = 'closed') = (closed_at is not null))
);
create index incidents_venue_idx on public.incidents(venue_id, occurred_at desc);

create table public.incident_people (
  venue_id uuid not null,
  incident_id uuid not null,
  worker_id uuid not null,
  primary key (incident_id, worker_id),
  foreign key (venue_id, incident_id) references public.incidents(venue_id, id) on delete cascade,
  foreign key (venue_id, worker_id) references public.workers(venue_id, id)
);

-- The follow-up timeline: notes people add, and entries written by the functions below
-- when the status or owner changes.
create table public.incident_notes (
  -- Made on the device for notes; generated for status and owner entries.
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  incident_id uuid not null,
  kind text not null default 'note' check (kind in ('note', 'status', 'assigned', 'photos')),
  body text not null check (length(body) between 1 and 2000),
  author_id uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  foreign key (venue_id, incident_id) references public.incidents(venue_id, id) on delete cascade
);
create index incident_notes_incident_idx on public.incident_notes(incident_id, created_at);

create trigger incidents_touch before update on public.incidents
for each row execute function public.touch_updated_at();
create trigger incidents_audit after insert or update or delete on public.incidents
for each row execute function public.audit_row_change();
create trigger incident_people_audit after insert or update or delete on public.incident_people
for each row execute function public.audit_row_change();
create trigger incident_notes_audit after insert or update or delete on public.incident_notes
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Defaults for every venue
-- ---------------------------------------------------------------------------
create or replace function public.seed_checklist_defaults(p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_open uuid;
  v_close uuid;
begin
  if exists (select 1 from checklist_templates where venue_id = p_venue) then
    return;
  end if;
  insert into checklist_templates (venue_id, kind, name, sort) values (p_venue, 'opening', 'Opening', 10)
  returning id into v_open;
  insert into checklist_templates (venue_id, kind, name, sort) values (p_venue, 'closing', 'Closing', 20)
  returning id into v_close;

  insert into checklist_template_items (venue_id, template_id, label, help, photo_required, storefront_kinds, sort) values
    (p_venue, v_open, 'All staff clocked in', 'Anyone missing is reported to a manager.', false, '{}', 10),
    (p_venue, v_open, 'Uniforms checked', 'Shirt, hat or visor, name badge. Photo of the crew.', true, '{}', 20),
    (p_venue, v_open, 'Stations assigned', 'Everyone knows their station for the event.', false, '{}', 30),
    (p_venue, v_open, 'Lead briefing done', 'Event, menu changes, break order.', false, '{}', 40),
    (p_venue, v_open, 'TABC cards on hand', 'Every bartender and server has a current card.', true, '{bar}', 50),
    (p_venue, v_open, 'Food handler cards on hand', 'Every food worker has a current card.', false, '{permanent_stand,portable_cart,kiosk}', 60),
    (p_venue, v_close, 'Breaks taken', 'Everyone got the breaks they were due.', false, '{}', 10),
    (p_venue, v_close, 'Staff sent home in order', 'Follow the send-home order on the live view.', false, '{}', 20),
    (p_venue, v_close, 'Station clean-up assigned', 'Each station has someone on clean-up.', false, '{}', 30),
    (p_venue, v_close, 'Clean-up checked', 'Photo of the finished stand.', true, '{}', 40),
    (p_venue, v_close, 'All clocked out', 'No one left on the clock.', false, '{}', 50);
end $$;

create or replace function public.seed_venue_checklists()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_checklist_defaults(new.id);
  return new;
end $$;

create trigger venues_seed_checklists after insert on public.venues
for each row execute function public.seed_venue_checklists();

do $$ begin perform public.seed_checklist_defaults(v.id) from public.venues v; end $$;

-- ---------------------------------------------------------------------------
-- Access helpers
-- ---------------------------------------------------------------------------

-- Storefronts whose checklists the user can see: live view or schedule rights.
create or replace function public.checklist_storefronts(p_venue uuid)
returns setof uuid language sql stable security definer set search_path = public as $$
  select public.storefronts_in_scope(p_venue, 'view_live')
  union
  select public.storefronts_in_scope(p_venue, 'manage_schedule');
$$;

-- True when the user may sign off (and reopen) checklists at a storefront: schedule
-- rights for the whole venue or for the storefront's level. A lead scoped to one
-- storefront cannot sign off their own checklist.
create or replace function public.can_sign_off_checklist(p_storefront uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from storefronts s
    where s.id = p_storefront
      and (public.has_venue_permission(s.venue_id, 'manage_schedule')
           or s.level_id in (select public.permission_scope_ids(s.venue_id, 'manage_schedule', 'level')))
  );
$$;

-- True when the run's storefront is in the user's checklist scope.
create or replace function public.can_see_checklist_run(p_run uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from checklist_runs r
    where r.id = p_run and r.storefront_id in (select public.checklist_storefronts(r.venue_id))
  );
$$;

-- Whether one user can see one incident. Employees and partners never can (they hold
-- no view_live). Employee incidents: people who manage staff for the whole venue, and
-- the person who reported it. Others: venue-wide live view, a scope covering the
-- incident's storefront, or the reporter.
create or replace function public.incident_visible_to(p_incident uuid, p_user uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare
  i incidents%rowtype;
  s storefronts%rowtype;
begin
  select * into i from incidents where id = p_incident;
  if not found or p_user is null then
    return false;
  end if;
  if not public.user_has_any_permission(i.venue_id, p_user, array['view_live', 'manage_workers']) then
    return false;
  end if;
  if i.reported_by = p_user then
    return true;
  end if;
  if i.kind = 'employee' then
    return exists (
      select 1 from role_assignments ra
      join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
      join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
      where ra.venue_id = i.venue_id and ra.user_id = p_user and ra.scope_type = 'venue'
        and 'manage_workers' = any (r.permissions));
  end if;
  select * into s from storefronts where id = i.storefront_id;
  return exists (
    select 1 from role_assignments ra
    join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
    join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
    where ra.venue_id = i.venue_id and ra.user_id = p_user
      and r.permissions && array['view_live']
      and (ra.scope_type = 'venue'
           or (s.id is not null and ra.scope_type = 'storefront' and ra.scope_id = s.id)
           or (s.id is not null and ra.scope_type = 'level' and ra.scope_id = s.level_id)));
end $$;

create or replace function public.can_see_incident(p_incident uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.incident_visible_to(p_incident, (select auth.uid()));
$$;

-- Status, owner and closing: venue-wide live view (employee incidents: venue-wide
-- manage_workers). Leads add notes and photos to what they can see.
create or replace function public.can_manage_incident(p_incident uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from incidents i
    where i.id = p_incident
      and public.can_see_incident(i.id)
      and case when i.kind = 'employee' then public.has_venue_permission(i.venue_id, 'manage_workers')
               else public.has_venue_permission(i.venue_id, 'view_live') end
  );
$$;

-- A display name for a sign-in.
create or replace function public.ops_user_name(p_user uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select display_name from user_profiles where id = p_user), '');
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.checklist_templates enable row level security;
alter table public.checklist_template_items enable row level security;
alter table public.checklist_runs enable row level security;
alter table public.checklist_run_items enable row level security;
alter table public.checklist_item_changes enable row level security;
alter table public.incidents enable row level security;
alter table public.incident_people enable row level security;
alter table public.incident_notes enable row level security;

revoke all on public.checklist_templates, public.checklist_template_items, public.checklist_runs,
  public.checklist_run_items, public.checklist_item_changes, public.incidents, public.incident_people,
  public.incident_notes from anon;
-- Every change goes through the functions below.
revoke insert, update, delete, truncate on public.checklist_templates, public.checklist_template_items,
  public.checklist_runs, public.checklist_run_items, public.checklist_item_changes, public.incidents,
  public.incident_people, public.incident_notes from authenticated;

create policy checklist_templates_read on public.checklist_templates for select to authenticated
  using (public.has_permission(venue_id, 'view_live') or public.has_permission(venue_id, 'manage_schedule'));
create policy checklist_template_items_read on public.checklist_template_items for select to authenticated
  using (public.has_permission(venue_id, 'view_live') or public.has_permission(venue_id, 'manage_schedule'));
create policy checklist_runs_read on public.checklist_runs for select to authenticated
  using (storefront_id in (select public.checklist_storefronts(venue_id)));
create policy checklist_run_items_read on public.checklist_run_items for select to authenticated
  using (public.can_see_checklist_run(run_id));
create policy checklist_item_changes_read on public.checklist_item_changes for select to authenticated
  using (public.can_see_checklist_run(run_id));

create policy incidents_read on public.incidents for select to authenticated
  using (public.can_see_incident(id));
create policy incident_people_read on public.incident_people for select to authenticated
  using (public.can_see_incident(incident_id));
create policy incident_notes_read on public.incident_notes for select to authenticated
  using (public.can_see_incident(incident_id));

-- ---------------------------------------------------------------------------
-- Photos: private buckets, one folder per run and per incident.
--   checklist-photos/<venue_id>/<run_id>/<file>
--   incident-photos/<venue_id>/<incident_id>/<file>
-- Photos are proof: no one updates or deletes them through the API.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('checklist-photos', 'checklist-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
       ('incident-photos', 'incident-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

create policy checklist_photos_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'checklist-photos'
    and exists (select 1 from public.checklist_runs r
                where r.id::text = split_part(name, '/', 2) and r.venue_id = public.storage_venue(name)
                  and r.status <> 'signed_off'
                  and public.can_on_storefront(r.storefront_id, 'manage_schedule'))
  );

create policy checklist_photos_read on storage.objects for select to authenticated
  using (
    bucket_id = 'checklist-photos'
    and exists (select 1 from public.checklist_runs r
                where r.id::text = split_part(name, '/', 2) and r.venue_id = public.storage_venue(name)
                  and r.storefront_id in (select public.checklist_storefronts(r.venue_id)))
  );

create policy incident_photos_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'incident-photos'
    and exists (select 1 from public.incidents i
                where i.id::text = split_part(name, '/', 2) and i.venue_id = public.storage_venue(name)
                  and i.status <> 'closed' and public.can_see_incident(i.id))
  );

create policy incident_photos_read on storage.objects for select to authenticated
  using (
    bucket_id = 'incident-photos'
    and exists (select 1 from public.incidents i
                where i.id::text = split_part(name, '/', 2) and i.venue_id = public.storage_venue(name)
                  and public.can_see_incident(i.id))
  );

-- ---------------------------------------------------------------------------
-- Checklists: internal helpers
-- ---------------------------------------------------------------------------

-- Finds or starts the run for one template at one storefront and event, copying the
-- template's items that apply to the storefront. The caller has checked access.
create or replace function public.ensure_checklist_run(p_event uuid, p_storefront uuid, p_template uuid)
returns checklist_runs language plpgsql security definer set search_path = public as $$
declare
  s storefronts%rowtype;
  v_run checklist_runs%rowtype;
begin
  select * into v_run from checklist_runs
   where event_id = p_event and storefront_id = p_storefront and template_id = p_template;
  if found then
    return v_run;
  end if;
  select * into s from storefronts where id = p_storefront;
  if not exists (select 1 from events e where e.id = p_event and e.venue_id = s.venue_id and e.status <> 'cancelled') then
    raise exception 'Unknown event' using errcode = '22023';
  end if;
  if not exists (select 1 from checklist_templates t where t.id = p_template and t.venue_id = s.venue_id and t.active) then
    raise exception 'Unknown checklist' using errcode = '22023';
  end if;
  insert into checklist_runs (venue_id, event_id, storefront_id, template_id, started_by)
  values (s.venue_id, p_event, p_storefront, p_template, (select auth.uid()))
  on conflict (event_id, storefront_id, template_id) do nothing
  returning * into v_run;
  if v_run.id is null then
    select * into v_run from checklist_runs
     where event_id = p_event and storefront_id = p_storefront and template_id = p_template;
    return v_run;
  end if;
  insert into checklist_run_items (venue_id, run_id, template_item_id, label, help, photo_required, sort)
  select s.venue_id, v_run.id, ti.id, ti.label, ti.help, ti.photo_required, ti.sort
    from checklist_template_items ti
   where ti.template_id = p_template and ti.active
     and (cardinality(ti.storefront_kinds) = 0 or s.kind = any (ti.storefront_kinds));
  return v_run;
end $$;

-- Recomputes in_progress / complete (a signed-off run stays signed off).
create or replace function public.refresh_checklist_status(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_open integer;
begin
  select count(*) into v_open from checklist_run_items
   where run_id = p_run and (not done or (photo_required and cardinality(photo_paths) = 0));
  update checklist_runs set status = case when v_open = 0 then 'complete' else 'in_progress' end
   where id = p_run and status <> 'signed_off'
     and status is distinct from case when v_open = 0 then 'complete' else 'in_progress' end;
end $$;

create or replace function public.checklist_run_json(p_run uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', r.id, 'venue_id', r.venue_id, 'event_id', r.event_id, 'storefront_id', r.storefront_id,
    'template_id', r.template_id, 'template_name', t.name, 'template_kind', t.kind, 'status', r.status,
    'started_at', r.started_at,
    'signed_off_by_name', public.ops_user_name(r.signed_off_by), 'signed_off_at', r.signed_off_at,
    'sign_off_note', r.sign_off_note,
    'reopened_by_name', public.ops_user_name(r.reopened_by), 'reopened_at', r.reopened_at,
    'reopen_reason', r.reopen_reason, 'updated_at', r.updated_at,
    'items', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', i.id, 'template_item_id', i.template_item_id, 'label', i.label, 'help', i.help,
               'photo_required', i.photo_required, 'sort', i.sort, 'done', i.done,
               'done_by_name', public.ops_user_name(i.done_by), 'done_at', i.done_at, 'note', i.note,
               'photo_paths', to_jsonb(i.photo_paths), 'last_change_at', i.last_change_at)
               order by i.sort, i.label), '[]'::jsonb)
        from checklist_run_items i where i.run_id = r.id))
  from checklist_runs r join checklist_templates t on t.id = r.template_id
  where r.id = p_run;
$$;

-- ---------------------------------------------------------------------------
-- Checklists: the API
-- ---------------------------------------------------------------------------

-- Everything the Checklists screen needs for one event, limited to the caller's scope:
-- active templates with items, open storefronts in scope, runs so far, and where the
-- caller can tick items and sign off.
create or replace function public.event_checklists(p_event uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  e events%rowtype;
  v_scope uuid[];
begin
  select * into e from events where id = p_event;
  if not found or not public.is_venue_member(e.venue_id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select coalesce(array_agg(x), '{}') into v_scope from public.checklist_storefronts(e.venue_id) x;
  if cardinality(v_scope) = 0 then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'event_id', e.id,
    'storefront_ids', (
      select coalesce(jsonb_agg(es.storefront_id order by s.code), '[]'::jsonb)
        from event_storefronts es join storefronts s on s.id = es.storefront_id
       where es.event_id = e.id and es.is_open and s.active and es.storefront_id = any (v_scope)),
    'templates', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', t.id, 'kind', t.kind, 'name', t.name, 'sort', t.sort, 'active', t.active,
               'items', (select coalesce(jsonb_agg(jsonb_build_object(
                           'id', ti.id, 'label', ti.label, 'help', ti.help, 'photo_required', ti.photo_required,
                           'storefront_kinds', to_jsonb(ti.storefront_kinds), 'sort', ti.sort, 'active', ti.active)
                           order by ti.sort, ti.label), '[]'::jsonb)
                           from checklist_template_items ti where ti.template_id = t.id and ti.active))
               order by t.sort, t.name), '[]'::jsonb)
        from checklist_templates t where t.venue_id = e.venue_id and t.active),
    'runs', (
      select coalesce(jsonb_agg(public.checklist_run_json(r.id) order by r.started_at), '[]'::jsonb)
        from checklist_runs r where r.event_id = e.id and r.storefront_id = any (v_scope)),
    'edit_storefront_ids', (
      select coalesce(jsonb_agg(x), '[]'::jsonb) from public.storefronts_in_scope(e.venue_id, 'manage_schedule') x),
    'sign_off_storefront_ids', (
      select coalesce(jsonb_agg(s.id), '[]'::jsonb) from storefronts s
       where s.venue_id = e.venue_id and s.id = any (v_scope) and public.can_sign_off_checklist(s.id)));
end $$;

-- Starts a run (or returns the one already started). Photos go in the run's folder, so
-- a device starts the run before uploading.
create or replace function public.start_checklist_run(p_event uuid, p_storefront uuid, p_template uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_run checklist_runs%rowtype;
begin
  if not public.can_on_storefront(p_storefront, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  v_run := public.ensure_checklist_run(p_event, p_storefront, p_template);
  return public.checklist_run_json(v_run.id);
end $$;

-- Ticks or unticks one item, with an optional note and photos. p:
--   {id (made on the device), event_id, storefront_id, template_id, template_item_id,
--    done, note?, photo_paths?, occurred_at}
-- Sending the same id again changes nothing and returns the run.
create or replace function public.record_checklist_item(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p ->> 'id')::uuid;
  v_storefront uuid := (p ->> 'storefront_id')::uuid;
  v_done boolean := coalesce((p ->> 'done')::boolean, false);
  v_note text := case when p ? 'note' and jsonb_typeof(p -> 'note') = 'string' then left(btrim(p ->> 'note'), 500) end;
  v_paths text[];
  v_occurred timestamptz := least(coalesce((p ->> 'occurred_at')::timestamptz, now()), now());
  v_existing checklist_item_changes%rowtype;
  v_run checklist_runs%rowtype;
  v_item checklist_run_items%rowtype;
  v_applied boolean;
  v_all text[];
begin
  if v_id is null then
    raise exception 'A change id is required' using errcode = '22023';
  end if;
  select * into v_existing from checklist_item_changes where id = v_id;
  if found then
    if v_existing.actor_id is distinct from (select auth.uid()) then
      raise exception 'Change id already used' using errcode = '23505';
    end if;
    return public.checklist_run_json(v_existing.run_id);
  end if;

  if v_storefront is null or not public.can_on_storefront(v_storefront, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  v_run := public.ensure_checklist_run((p ->> 'event_id')::uuid, v_storefront, (p ->> 'template_id')::uuid);
  if v_run.status = 'signed_off' then
    raise exception 'This checklist is signed off. A manager can reopen it.' using errcode = '22023';
  end if;
  select * into v_item from checklist_run_items
   where run_id = v_run.id and template_item_id = (p ->> 'template_item_id')::uuid
   for update;
  if not found then
    raise exception 'This item is not on this checklist' using errcode = '22023';
  end if;

  select coalesce(array_agg(x), '{}') into v_paths
    from jsonb_array_elements_text(coalesce(p -> 'photo_paths', '[]'::jsonb)) x;
  if exists (select 1 from unnest(v_paths) x where x not like v_run.venue_id || '/' || v_run.id || '/%' or x like '%..%') then
    raise exception 'Photos must be in this checklist''s folder' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_all
    from unnest(v_item.photo_paths || v_paths) x;
  if cardinality(v_all) > 6 then
    raise exception 'Up to 6 photos per item' using errcode = '22023';
  end if;
  if v_done and v_item.photo_required and cardinality(v_all) = 0 then
    raise exception 'Add a photo for "%" first', v_item.label using errcode = '22023';
  end if;

  -- The change made last on a device wins; photos are always kept.
  v_applied := v_item.last_change_at is null or v_occurred >= v_item.last_change_at;
  insert into checklist_item_changes (id, venue_id, run_id, run_item_id, done, note, photo_paths, occurred_at, applied)
  values (v_id, v_run.venue_id, v_run.id, v_item.id, v_done, v_note, v_paths, v_occurred, v_applied);

  update checklist_run_items set
    done = case when v_applied then v_done else done end,
    done_by = case when v_applied then case when v_done then (select auth.uid()) end else done_by end,
    done_at = case when v_applied then case when v_done then v_occurred end else done_at end,
    note = case when v_applied and v_note is not null then v_note else note end,
    photo_paths = v_all,
    last_change_at = case when v_applied then v_occurred else last_change_at end
   where id = v_item.id;

  perform public.refresh_checklist_status(v_run.id);
  return public.checklist_run_json(v_run.id);
end $$;

-- A manager for the venue or the storefront's level signs off a finished run.
create or replace function public.sign_off_checklist(p_run uuid, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r checklist_runs%rowtype;
begin
  select * into r from checklist_runs where id = p_run for update;
  if not found or not public.can_sign_off_checklist(r.storefront_id) then
    raise exception 'Only a manager can sign off' using errcode = '42501';
  end if;
  perform public.refresh_checklist_status(r.id);
  select * into r from checklist_runs where id = p_run;
  if r.status = 'signed_off' then
    raise exception 'Already signed off' using errcode = '22023';
  end if;
  if r.status <> 'complete' then
    raise exception 'Finish every item (and its photos) before signing off' using errcode = '22023';
  end if;
  perform set_config('app.audit_reason', left(coalesce(p_note, ''), 500), true);
  update checklist_runs set status = 'signed_off', signed_off_by = (select auth.uid()), signed_off_at = now(),
         sign_off_note = left(btrim(coalesce(p_note, '')), 500)
   where id = r.id;
  return public.checklist_run_json(r.id);
end $$;

create or replace function public.reopen_checklist(p_run uuid, p_reason text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r checklist_runs%rowtype;
begin
  select * into r from checklist_runs where id = p_run for update;
  if not found or not public.can_sign_off_checklist(r.storefront_id) then
    raise exception 'Only a manager can reopen' using errcode = '42501';
  end if;
  if r.status <> 'signed_off' then
    raise exception 'This checklist is not signed off' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_reason, ''))) = 0 then
    raise exception 'Give a reason' using errcode = '22023';
  end if;
  perform set_config('app.audit_reason', left(btrim(p_reason), 500), true);
  update checklist_runs set status = 'in_progress', signed_off_by = null, signed_off_at = null, sign_off_note = '',
         reopened_by = (select auth.uid()), reopened_at = now(), reopen_reason = left(btrim(p_reason), 500)
   where id = r.id;
  perform public.refresh_checklist_status(r.id);
  return public.checklist_run_json(r.id);
end $$;

-- The venue's templates (active and not), for the template editor.
create or replace function public.checklist_templates_list(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.has_permission(p_venue, 'view_live') or public.has_permission(p_venue, 'manage_schedule')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', t.id, 'kind', t.kind, 'name', t.name, 'sort', t.sort, 'active', t.active,
             'items', (select coalesce(jsonb_agg(jsonb_build_object(
                         'id', ti.id, 'label', ti.label, 'help', ti.help, 'photo_required', ti.photo_required,
                         'storefront_kinds', to_jsonb(ti.storefront_kinds), 'sort', ti.sort, 'active', ti.active)
                         order by ti.sort, ti.label), '[]'::jsonb)
                       from checklist_template_items ti where ti.template_id = t.id and ti.active))
             order by t.sort, t.name), '[]'::jsonb)
      from checklist_templates t where t.venue_id = p_venue);
end $$;

-- Creates or updates a template and its items (venue-wide schedule rights). Items left
-- out are turned off, not deleted, so past runs keep their history. p:
--   {id?, venue_id, kind, name, active, sort, items: [{id?, label, help, photo_required,
--    storefront_kinds, sort}]}
create or replace function public.save_checklist_template(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_venue uuid := (p ->> 'venue_id')::uuid;
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_item jsonb;
  v_item_id uuid;
  v_keep uuid[] := '{}';
  v_sort integer := 0;
begin
  if v_venue is null or not public.has_venue_permission(v_venue, 'manage_schedule') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if jsonb_typeof(coalesce(p -> 'items', '[]'::jsonb)) <> 'array' or jsonb_array_length(coalesce(p -> 'items', '[]'::jsonb)) = 0 then
    raise exception 'Add at least one item' using errcode = '22023';
  end if;
  if jsonb_array_length(p -> 'items') > 40 then
    raise exception 'Up to 40 items' using errcode = '22023';
  end if;
  if v_id is null then
    insert into checklist_templates (venue_id, kind, name, active, sort)
    values (v_venue, coalesce(p ->> 'kind', 'custom'), btrim(p ->> 'name'), coalesce((p ->> 'active')::boolean, true),
            coalesce((p ->> 'sort')::integer, 100))
    returning id into v_id;
  else
    update checklist_templates set kind = coalesce(p ->> 'kind', kind), name = btrim(coalesce(p ->> 'name', name)),
           active = coalesce((p ->> 'active')::boolean, active), sort = coalesce((p ->> 'sort')::integer, sort)
     where id = v_id and venue_id = v_venue;
    if not found then
      raise exception 'Unknown checklist' using errcode = '22023';
    end if;
  end if;

  for v_item in select * from jsonb_array_elements(p -> 'items') loop
    v_sort := v_sort + 10;
    v_item_id := nullif(v_item ->> 'id', '')::uuid;
    if v_item_id is not null and exists (select 1 from checklist_template_items where id = v_item_id and template_id = v_id) then
      update checklist_template_items set label = btrim(v_item ->> 'label'), help = btrim(coalesce(v_item ->> 'help', '')),
             photo_required = coalesce((v_item ->> 'photo_required')::boolean, false),
             storefront_kinds = array(select jsonb_array_elements_text(coalesce(v_item -> 'storefront_kinds', '[]'::jsonb))),
             sort = v_sort, active = true
       where id = v_item_id;
    else
      insert into checklist_template_items (venue_id, template_id, label, help, photo_required, storefront_kinds, sort)
      values (v_venue, v_id, btrim(v_item ->> 'label'), btrim(coalesce(v_item ->> 'help', '')),
              coalesce((v_item ->> 'photo_required')::boolean, false),
              array(select jsonb_array_elements_text(coalesce(v_item -> 'storefront_kinds', '[]'::jsonb))), v_sort)
      returning id into v_item_id;
    end if;
    v_keep := v_keep || v_item_id;
  end loop;
  update checklist_template_items set active = false where template_id = v_id and active and not (id = any (v_keep));
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Incidents: internal helpers
-- ---------------------------------------------------------------------------

-- Managers to tell about an incident: venue-wide live view, or for employee incidents
-- venue-wide manage_workers. Not kiosks.
create or replace function public.incident_managers(p_venue uuid, p_kind text)
returns setof uuid language sql stable security definer set search_path = public as $$
  select distinct ra.user_id
  from role_assignments ra
  join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
  join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id and m.status = 'active'
  where ra.venue_id = p_venue and ra.scope_type = 'venue'
    and (case when p_kind = 'employee' then 'manage_workers' else 'view_live' end) = any (r.permissions)
    and public.comms_is_person(p_venue, ra.user_id);
$$;

create or replace function public.incident_kind_label(p_kind text)
returns text language sql immutable set search_path = '' as $$
  select case p_kind when 'injury' then 'Injury' when 'safety' then 'Safety issue'
                     when 'employee' then 'Employee incident' else 'Incident' end;
$$;

create or replace function public.incident_json(p_incident uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', i.id, 'venue_id', i.venue_id, 'kind', i.kind, 'severity', i.severity, 'event_id', i.event_id,
    'event_name', (select e.name from events e where e.id = i.event_id),
    'storefront_id', i.storefront_id, 'occurred_at', i.occurred_at, 'description', i.description,
    'photo_paths', to_jsonb(i.photo_paths), 'status', i.status,
    'assigned_to', i.assigned_to, 'assigned_to_name', public.ops_user_name(i.assigned_to),
    'closing_note', i.closing_note, 'closed_at', i.closed_at, 'closed_by_name', public.ops_user_name(i.closed_by),
    'reported_by', i.reported_by, 'reported_by_name', public.ops_user_name(i.reported_by),
    'created_at', i.created_at, 'updated_at', i.updated_at,
    'people', (
      select coalesce(jsonb_agg(jsonb_build_object('id', w.id,
               'name', coalesce(nullif(btrim(w.preferred_name), ''), w.first_name) || ' ' || w.last_name,
               'employee_number', w.employee_number) order by w.last_name, w.first_name), '[]'::jsonb)
        from incident_people ip join workers w on w.id = ip.worker_id where ip.incident_id = i.id),
    'notes', (
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'kind', n.kind, 'body', n.body,
               'author_name', public.ops_user_name(n.author_id), 'created_at', n.created_at)
               order by n.created_at, n.id), '[]'::jsonb)
        from incident_notes n where n.incident_id = i.id))
  from incidents i where i.id = p_incident;
$$;

-- ---------------------------------------------------------------------------
-- Incidents: the API
-- ---------------------------------------------------------------------------

-- Logs an incident. p: {id (made on the device), venue_id, kind, severity, event_id?,
-- storefront_id?, occurred_at, description, worker_ids?}. Sending the same id again
-- returns the stored report. Managers hear about injuries and high-severity incidents.
create or replace function public.log_incident(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p ->> 'id')::uuid;
  v_venue uuid := (p ->> 'venue_id')::uuid;
  v_storefront uuid := nullif(p ->> 'storefront_id', '')::uuid;
  v_event uuid := nullif(p ->> 'event_id', '')::uuid;
  v_kind text := coalesce(p ->> 'kind', 'other');
  v_severity text := coalesce(p ->> 'severity', 'low');
  v_occurred timestamptz := least(coalesce((p ->> 'occurred_at')::timestamptz, now()), now());
  v_existing incidents%rowtype;
  v_workers uuid[];
  v_where text;
  v_user uuid;
begin
  if v_id is null or v_venue is null then
    raise exception 'An incident id and venue are required' using errcode = '22023';
  end if;
  select * into v_existing from incidents where id = v_id;
  if found then
    if v_existing.reported_by is distinct from (select auth.uid()) then
      raise exception 'Incident id already used' using errcode = '23505';
    end if;
    return public.incident_json(v_id);
  end if;

  if v_storefront is null then
    if not public.has_venue_permission(v_venue, 'view_live') then
      raise exception 'Choose your storefront' using errcode = '42501';
    end if;
  elsif not exists (select 1 from storefronts s where s.id = v_storefront and s.venue_id = v_venue)
        or not public.can_on_storefront(v_storefront, 'view_live') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  if v_event is not null and not exists (select 1 from events e where e.id = v_event and e.venue_id = v_venue) then
    raise exception 'Unknown event' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct x::uuid), '{}') into v_workers
    from jsonb_array_elements_text(coalesce(p -> 'worker_ids', '[]'::jsonb)) x;
  if exists (select 1 from unnest(v_workers) w where not exists (select 1 from workers x where x.id = w and x.venue_id = v_venue)) then
    raise exception 'Unknown person' using errcode = '22023';
  end if;
  if v_occurred < now() - interval '1 year' then
    raise exception 'Choose when it happened' using errcode = '22023';
  end if;

  insert into incidents (id, venue_id, kind, severity, event_id, storefront_id, occurred_at, description)
  values (v_id, v_venue, v_kind, v_severity, v_event, v_storefront, v_occurred, btrim(coalesce(p ->> 'description', '')));
  insert into incident_people (venue_id, incident_id, worker_id)
  select v_venue, v_id, w from unnest(v_workers) w;

  if v_kind = 'injury' or v_severity = 'high' then
    v_where := coalesce((select ' at ' || s.name from storefronts s where s.id = v_storefront), '');
    -- No details in the alert: they can show on a locked phone. The app shows the rest.
    for v_user in select public.incident_managers(v_venue, v_kind) loop
      continue when v_user = (select auth.uid());
      perform public.notify_user(v_venue, v_user, 'incident',
        public.incident_kind_label(v_kind) || ' reported' || v_where,
        case when v_severity = 'high' then 'High severity. ' else '' end || 'Open Incidents for details.',
        '/incidents', '{in_app,push}', jsonb_build_object('incident_id', v_id));
    end loop;
  end if;
  return public.incident_json(v_id);
end $$;

-- Adds photos already uploaded to the incident's folder. Sending the same paths again
-- changes nothing.
create or replace function public.add_incident_photos(p_incident uuid, p_paths text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i incidents%rowtype;
  v_all text[];
  v_new integer;
begin
  select * into i from incidents where id = p_incident for update;
  if not found or not public.can_see_incident(i.id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if exists (select 1 from unnest(coalesce(p_paths, '{}')) x where x not like i.venue_id || '/' || i.id || '/%' or x like '%..%') then
    raise exception 'Photos must be in this incident''s folder' using errcode = '22023';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_all from unnest(i.photo_paths || coalesce(p_paths, '{}')) x;
  v_new := cardinality(v_all) - cardinality(i.photo_paths);
  if v_new = 0 then
    return public.incident_json(i.id);
  end if;
  if i.status = 'closed' then
    raise exception 'This incident is closed' using errcode = '22023';
  end if;
  if cardinality(v_all) > 12 then
    raise exception 'Up to 12 photos per incident' using errcode = '22023';
  end if;
  update incidents set photo_paths = v_all where id = i.id;
  insert into incident_notes (venue_id, incident_id, kind, body)
  values (i.venue_id, i.id, 'photos', case when v_new = 1 then 'Added a photo' else 'Added ' || v_new || ' photos' end);
  return public.incident_json(i.id);
end $$;

-- Adds a follow-up note. p: {id (made on the device), incident_id, body}.
create or replace function public.add_incident_note(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p ->> 'id')::uuid;
  i incidents%rowtype;
  v_existing incident_notes%rowtype;
begin
  if v_id is null then
    raise exception 'A note id is required' using errcode = '22023';
  end if;
  select * into v_existing from incident_notes where id = v_id;
  if found then
    if v_existing.author_id is distinct from (select auth.uid()) then
      raise exception 'Note id already used' using errcode = '23505';
    end if;
    return public.incident_json(v_existing.incident_id);
  end if;
  select * into i from incidents where id = (p ->> 'incident_id')::uuid;
  if not found or not public.can_see_incident(i.id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if i.status = 'closed' then
    raise exception 'This incident is closed. Reopen it to add notes.' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p ->> 'body', ''))) = 0 then
    raise exception 'Write a note' using errcode = '22023';
  end if;
  insert into incident_notes (id, venue_id, incident_id, kind, body)
  values (v_id, i.venue_id, i.id, 'note', left(btrim(p ->> 'body'), 2000));
  update incidents set status = 'following_up' where id = i.id and status = 'open';
  return public.incident_json(i.id);
end $$;

-- Status, follow-up owner and closing note (managers). Closing needs a note; each
-- change is written to the timeline. Null arguments leave a field as it is; pass
-- p_unassign to clear the owner.
create or replace function public.update_incident(p_incident uuid, p_status text default null,
  p_assigned_to uuid default null, p_closing_note text default null, p_unassign boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  i incidents%rowtype;
  v_label text;
begin
  select * into i from incidents where id = p_incident for update;
  if not found or not public.can_manage_incident(i.id) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_status is not null and p_status not in ('open', 'following_up', 'closed') then
    raise exception 'Unknown status' using errcode = '22023';
  end if;

  if p_assigned_to is not null and p_assigned_to is distinct from i.assigned_to then
    if not public.incident_visible_to(i.id, p_assigned_to) or not public.comms_is_person(i.venue_id, p_assigned_to) then
      raise exception 'That person cannot see this incident' using errcode = '22023';
    end if;
    update incidents set assigned_to = p_assigned_to where id = i.id;
    insert into incident_notes (venue_id, incident_id, kind, body)
    values (i.venue_id, i.id, 'assigned', 'Follow-up: ' || coalesce(nullif(public.ops_user_name(p_assigned_to), ''), 'assigned'));
    if p_assigned_to <> (select auth.uid()) then
      perform public.notify_user(i.venue_id, p_assigned_to, 'incident',
        'You own the follow-up on an incident', public.incident_kind_label(i.kind) || '. Open Incidents for details.',
        '/incidents', '{in_app,push}', jsonb_build_object('incident_id', i.id));
    end if;
  elsif p_unassign and i.assigned_to is not null then
    update incidents set assigned_to = null where id = i.id;
    insert into incident_notes (venue_id, incident_id, kind, body) values (i.venue_id, i.id, 'assigned', 'No follow-up owner');
  end if;

  if p_status is not null and p_status <> i.status then
    if p_status = 'closed' then
      if length(btrim(coalesce(p_closing_note, ''))) = 0 then
        raise exception 'Add a closing note' using errcode = '22023';
      end if;
      perform set_config('app.audit_reason', left(btrim(p_closing_note), 500), true);
      update incidents set status = 'closed', closing_note = left(btrim(p_closing_note), 2000),
             closed_by = (select auth.uid()), closed_at = now()
       where id = i.id;
    else
      update incidents set status = p_status, closed_by = null, closed_at = null where id = i.id;
    end if;
    v_label := case p_status when 'open' then 'Open' when 'following_up' then 'Following up' else 'Closed' end;
    insert into incident_notes (venue_id, incident_id, kind, body)
    values (i.venue_id, i.id, 'status',
            case when i.status = 'closed' then 'Reopened: ' || v_label else 'Status: ' || v_label end);
  end if;
  return public.incident_json(i.id);
end $$;

-- Incidents the caller can see, newest first.
create or replace function public.incidents_list(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_permission(p_venue, 'view_live') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(public.incident_json(i.id) order by i.occurred_at desc, i.id), '[]'::jsonb)
      from incidents i where i.venue_id = p_venue and public.can_see_incident(i.id));
end $$;

-- People who can own the follow-up on an incident of this kind: venue managers (venue-
-- wide manage_workers for employee incidents).
create or replace function public.incident_assignees(p_venue uuid, p_kind text default 'other')
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.has_venue_permission(p_venue, 'view_live') and not public.has_venue_permission(p_venue, 'manage_workers') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object('user_id', u, 'name', public.ops_user_name(u))
                              order by public.ops_user_name(u)), '[]'::jsonb)
      from public.incident_managers(p_venue, p_kind) u);
end $$;

-- ---------------------------------------------------------------------------
-- Function access
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  -- Internal: triggers and helpers used by the functions above.
  foreach f in array array[
    'public.seed_checklist_defaults(uuid)',
    'public.seed_venue_checklists()',
    'public.ensure_checklist_run(uuid, uuid, uuid)',
    'public.refresh_checklist_status(uuid)',
    'public.checklist_run_json(uuid)',
    'public.incident_visible_to(uuid, uuid)',
    'public.incident_managers(uuid, text)',
    'public.incident_kind_label(text)',
    'public.incident_json(uuid)',
    'public.ops_user_name(uuid)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  -- Row level security and storage policy helpers, and the API.
  foreach f in array array[
    'public.checklist_storefronts(uuid)',
    'public.can_sign_off_checklist(uuid)',
    'public.can_see_checklist_run(uuid)',
    'public.can_see_incident(uuid)',
    'public.can_manage_incident(uuid)',
    'public.event_checklists(uuid)',
    'public.start_checklist_run(uuid, uuid, uuid)',
    'public.record_checklist_item(jsonb)',
    'public.sign_off_checklist(uuid, text)',
    'public.reopen_checklist(uuid, text)',
    'public.checklist_templates_list(uuid)',
    'public.save_checklist_template(jsonb)',
    'public.log_incident(jsonb)',
    'public.add_incident_photos(uuid, text[])',
    'public.add_incident_note(jsonb)',
    'public.update_incident(uuid, text, uuid, text, boolean)',
    'public.incidents_list(uuid)',
    'public.incident_assignees(uuid, text)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.seed_checklist_defaults(uuid) to service_role;

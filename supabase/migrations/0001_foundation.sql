-- Storefront Workforce: foundation.
-- Tenancy (organization -> venue), users, configurable roles with scopes, permissions,
-- and an append-only audit log written by triggers.
--
-- Isolation rule: every venue-owned table carries venue_id, every policy checks it, and
-- cross-table references include venue_id in the foreign key so a row can never point
-- at another venue's data.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Tenancy
-- ---------------------------------------------------------------------------
create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 200),
  created_at timestamptz not null default now()
);

create table public.venues (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 200),
  time_zone text not null default 'America/Chicago',
  -- Labor rules (attendance, overtime, breaks, minors, certifications, clock, pay period).
  -- Read by the app through VenueRules.fromJson. Every change is versioned below.
  settings jsonb not null default '{}'::jsonb,
  -- White-label: app_name, primary_color, logo_path.
  branding jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index venues_organization_idx on public.venues(organization_id);

-- History of venue rules, so a past pay period can be recalculated under the rules
-- that applied at the time.
create table public.venue_rule_versions (
  id bigint generated always as identity primary key,
  venue_id uuid not null references public.venues(id) on delete cascade,
  version integer not null,
  rules jsonb not null,
  effective_from timestamptz not null default now(),
  created_by uuid default auth.uid(),
  unique (venue_id, version)
);

create table public.user_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  -- 'person' signs in with a PIN; 'kiosk' is a shared clock-in tablet.
  kind text not null default 'person' check (kind in ('person', 'kiosk')),
  preferred_language text not null default 'en' check (preferred_language in ('en', 'es')),
  created_at timestamptz not null default now()
);

create table public.venue_memberships (
  venue_id uuid not null references public.venues(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'suspended')),
  created_at timestamptz not null default now(),
  primary key (venue_id, user_id)
);
create index venue_memberships_user_idx on public.venue_memberships(user_id);

-- ---------------------------------------------------------------------------
-- Permissions and roles
-- ---------------------------------------------------------------------------
-- The permission catalog is fixed by the app. Roles are per venue and editable.
create table public.permissions (
  code text primary key,
  description text not null
);

insert into public.permissions (code, description) values
  ('view_live',        'See the live event board and arena map for the role''s scope'),
  ('manage_events',    'Create and edit events and choose open storefronts'),
  ('manage_schedule',  'Build the schedule, assign, move, and send home staff in scope'),
  ('view_workers',     'See staff profiles and contact details in scope'),
  ('manage_workers',   'Add and edit staff, roles, certifications, and PINs'),
  ('punch_self',       'Clock in and out for yourself'),
  ('kiosk_punch',      'Run a shared clock-in kiosk'),
  ('edit_time',        'Propose corrections to time records'),
  ('approve_time',     'Approve time corrections and pay periods'),
  ('view_pay',         'See pay rates and earnings'),
  ('export_payroll',   'Export approved hours to payroll'),
  ('view_reports',     'See KPIs and reports'),
  ('view_audit',       'See the audit log'),
  ('manage_settings',  'Change venue rules, layout, roles, and branding'),
  ('manage_users',     'Give people access and assign roles'),
  ('npo_portal',       'See one nonprofit group''s members, hours, and payouts'),
  ('agency_portal',    'See one temp agency''s placed workers and hours');

create table public.venue_roles (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null,
  permissions text[] not null default '{}',
  -- System roles can be edited but not deleted.
  is_system boolean not null default false,
  primary key (venue_id, code)
);

create or replace function public.check_role_permissions()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists (select 1 from unnest(new.permissions) p where p not in (select code from permissions)) then
    raise exception 'Unknown permission in role %', new.code using errcode = '22023';
  end if;
  return new;
end $$;

create trigger venue_roles_check before insert or update on public.venue_roles
for each row execute function public.check_role_permissions();

-- A role given to a user, limited to a scope:
--   venue      everything at the venue
--   level      storefronts on one level (scope_id = venue_levels.id)
--   storefront one storefront (scope_id = storefronts.id)
--   npo_group  one nonprofit group (scope_id = npo_groups.id)
--   agency     one temp agency (scope_id = temp_agencies.id)
create table public.role_assignments (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_code text not null,
  scope_type text not null default 'venue'
    check (scope_type in ('venue', 'level', 'storefront', 'npo_group', 'agency')),
  scope_id uuid,
  created_at timestamptz not null default now(),
  foreign key (venue_id, role_code) references public.venue_roles(venue_id, code) on delete cascade,
  foreign key (venue_id, user_id) references public.venue_memberships(venue_id, user_id) on delete cascade,
  check ((scope_type = 'venue') = (scope_id is null))
);
create unique index role_assignments_unique
  on public.role_assignments(venue_id, user_id, role_code, scope_type, coalesce(scope_id, '00000000-0000-0000-0000-000000000000'::uuid));
create index role_assignments_user_idx on public.role_assignments(user_id);

-- ---------------------------------------------------------------------------
-- Audit log (append-only). Written by triggers and security definer functions.
-- ---------------------------------------------------------------------------
create table public.audit_logs (
  id bigint generated always as identity primary key,
  venue_id uuid references public.venues(id) on delete cascade,
  actor_id uuid default auth.uid(),
  action text not null,
  entity text not null,
  entity_id text,
  -- Optional reason given by the person making the change.
  reason text not null default '',
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);
create index audit_logs_venue_created_idx on public.audit_logs(venue_id, created_at desc);
create index audit_logs_entity_idx on public.audit_logs(entity, entity_id);

-- Generic row audit. Records only the columns that changed. A function that wants a
-- reason recorded calls set_config('app.audit_reason', <reason>, true) first.
create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_before jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  k text;
begin
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if k not in ('updated_at', 'version') and (v_old -> k) is distinct from (v_new -> k) then
        v_before := v_before || jsonb_build_object(k, v_old -> k);
        v_after := v_after || jsonb_build_object(k, v_new -> k);
      end if;
    end loop;
    if v_after = '{}'::jsonb then
      return new;
    end if;
  else
    v_before := v_old;
    v_after := v_new;
  end if;

  insert into audit_logs (venue_id, action, entity, entity_id, reason, before, after)
  values (
    coalesce((v_new ->> 'venue_id')::uuid, (v_old ->> 'venue_id')::uuid),
    tg_table_name || '.' || lower(tg_op),
    tg_table_name,
    coalesce(v_new ->> 'id', v_old ->> 'id'),
    coalesce(nullif(current_setting('app.audit_reason', true), ''), ''),
    v_before,
    v_after
  );
  return coalesce(new, old);
end $$;

-- ---------------------------------------------------------------------------
-- Venue defaults
-- ---------------------------------------------------------------------------
create or replace function public.seed_venue_roles()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into venue_roles (venue_id, code, name, permissions, is_system) values
    (new.id, 'admin', 'Admin / General Manager', array(select code from permissions), true),
    (new.id, 'concessions_manager', 'Concessions Manager',
      array['view_live','manage_events','manage_schedule','view_workers','manage_workers','edit_time',
            'approve_time','view_pay','export_payroll','view_reports','view_audit','punch_self'], true),
    (new.id, 'assistant_manager', 'Assistant Manager',
      array['view_live','manage_events','manage_schedule','view_workers','edit_time','view_reports','punch_self'], true),
    (new.id, 'storefront_lead', 'Storefront Lead / Supervisor',
      array['view_live','manage_schedule','punch_self'], true),
    (new.id, 'employee', 'Employee', array['punch_self'], true),
    (new.id, 'npo_coordinator', 'NPO Coordinator', array['npo_portal'], true),
    (new.id, 'agency_contact', 'Temp Agency Contact', array['agency_portal'], true),
    (new.id, 'kiosk', 'Clock-in Kiosk', array['kiosk_punch'], true)
  on conflict do nothing;

  insert into venue_rule_versions (venue_id, version, rules) values (new.id, 1, new.settings);
  return new;
end $$;

create trigger venues_seed_roles after insert on public.venues
for each row execute function public.seed_venue_roles();

create or replace function public.version_venue_rules()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.settings is distinct from old.settings then
    insert into venue_rule_versions (venue_id, version, rules)
    select new.id, coalesce(max(version), 0) + 1, new.settings
    from venue_rule_versions where venue_id = new.id;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger venues_version_rules before update on public.venues
for each row execute function public.version_venue_rules();

create trigger venues_audit after insert or update on public.venues
for each row execute function public.audit_row_change();
create trigger venue_roles_audit after insert or update or delete on public.venue_roles
for each row execute function public.audit_row_change();
create trigger role_assignments_audit after insert or update or delete on public.role_assignments
for each row execute function public.audit_row_change();
create trigger venue_memberships_audit after insert or update or delete on public.venue_memberships
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Authorization helpers (security definer so policies do not recurse)
-- ---------------------------------------------------------------------------
create or replace function public.is_venue_member(p_venue uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from venue_memberships m
    where m.venue_id = p_venue and m.user_id = (select auth.uid()) and m.status = 'active'
  );
$$;

-- True when the user holds the permission in any scope at the venue.
create or replace function public.has_permission(p_venue uuid, p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from role_assignments ra
    join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
    join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id
    where ra.venue_id = p_venue
      and ra.user_id = (select auth.uid())
      and m.status = 'active'
      and p_permission = any (r.permissions)
  );
$$;

-- True when the user holds the permission for the whole venue.
create or replace function public.has_venue_permission(p_venue uuid, p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1
    from role_assignments ra
    join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
    join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id
    where ra.venue_id = p_venue
      and ra.user_id = (select auth.uid())
      and m.status = 'active'
      and ra.scope_type = 'venue'
      and p_permission = any (r.permissions)
  );
$$;

-- Scope ids (of one scope type) where the user holds the permission.
create or replace function public.permission_scope_ids(p_venue uuid, p_permission text, p_scope_type text)
returns setof uuid language sql stable security definer set search_path = public as $$
  select ra.scope_id
  from role_assignments ra
  join venue_roles r on r.venue_id = ra.venue_id and r.code = ra.role_code
  join venue_memberships m on m.venue_id = ra.venue_id and m.user_id = ra.user_id
  where ra.venue_id = p_venue
    and ra.user_id = (select auth.uid())
    and m.status = 'active'
    and ra.scope_type = p_scope_type
    and p_permission = any (r.permissions);
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.venues enable row level security;
alter table public.venue_rule_versions enable row level security;
alter table public.user_profiles enable row level security;
alter table public.venue_memberships enable row level security;
alter table public.permissions enable row level security;
alter table public.venue_roles enable row level security;
alter table public.role_assignments enable row level security;
alter table public.audit_logs enable row level security;

create policy organizations_read on public.organizations for select to authenticated
  using (exists (select 1 from public.venues v where v.organization_id = organizations.id and public.is_venue_member(v.id)));

create policy venues_read on public.venues for select to authenticated
  using (public.is_venue_member(id));
create policy venues_update on public.venues for update to authenticated
  using (public.has_venue_permission(id, 'manage_settings'))
  with check (public.has_venue_permission(id, 'manage_settings'));

create policy venue_rule_versions_read on public.venue_rule_versions for select to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings') or public.has_venue_permission(venue_id, 'approve_time'));

create policy user_profiles_read on public.user_profiles for select to authenticated
  using (
    id = (select auth.uid())
    or exists (
      select 1 from public.venue_memberships mine
      join public.venue_memberships theirs on theirs.venue_id = mine.venue_id
      where mine.user_id = (select auth.uid()) and theirs.user_id = user_profiles.id
        and public.has_venue_permission(mine.venue_id, 'manage_users')
    )
  );
create policy user_profiles_update_own on public.user_profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy venue_memberships_read on public.venue_memberships for select to authenticated
  using (user_id = (select auth.uid()) or public.has_venue_permission(venue_id, 'manage_users'));

create policy permissions_read on public.permissions for select to authenticated using (true);

create policy venue_roles_read on public.venue_roles for select to authenticated
  using (public.is_venue_member(venue_id));
create policy venue_roles_write on public.venue_roles for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings'))
  with check (public.has_venue_permission(venue_id, 'manage_settings'));

create policy role_assignments_read on public.role_assignments for select to authenticated
  using (user_id = (select auth.uid()) or public.has_venue_permission(venue_id, 'manage_users'));

create policy audit_logs_read on public.audit_logs for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_audit'));

-- Clients never write audit rows, venues, memberships, or role assignments directly
-- except through the policies above and the security definer functions in later files.
revoke insert, update, delete on public.audit_logs from anon, authenticated;
revoke all on public.venue_rule_versions from anon;
revoke insert, update, delete on public.venue_rule_versions from authenticated;
revoke insert, delete on public.venues from anon, authenticated;
revoke update on public.venues from anon, authenticated;
grant update (name, time_zone, settings, branding) on public.venues to authenticated;
revoke insert, update, delete on public.venue_memberships, public.role_assignments, public.permissions from anon, authenticated;
revoke all on public.organizations, public.venues, public.user_profiles, public.venue_roles from anon;

-- Venue layout: levels, storefronts, stations, job roles, certifications, default staffing.

create table public.venue_levels (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 80),
  sort integer not null default 0,
  -- Optional uploaded floor plan for this level (storage path). Without one the app
  -- draws a schematic bowl.
  map_image_path text,
  unique (venue_id, id)
);

create table public.storefronts (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  level_id uuid not null,
  code text not null check (length(btrim(code)) between 1 and 20),
  name text not null check (length(btrim(name)) between 1 and 120),
  kind text not null default 'permanent_stand'
    check (kind in ('permanent_stand', 'portable_cart', 'bar', 'kiosk')),
  section text not null default '',
  -- Position on the level map, 0..1 from the left and top.
  map_x numeric(5,4) not null default 0.5 check (map_x between 0 and 1),
  map_y numeric(5,4) not null default 0.5 check (map_y between 0 and 1),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (venue_id, code),
  unique (venue_id, id),
  foreign key (venue_id, level_id) references public.venue_levels(venue_id, id)
);
create index storefronts_level_idx on public.storefronts(level_id);

create table public.certification_types (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null,
  validity_months integer check (validity_months is null or validity_months > 0),
  primary key (venue_id, code)
);

create table public.job_roles (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null,
  required_certifications text[] not null default '{}',
  minimum_age integer check (minimum_age is null or minimum_age between 14 and 25),
  tipped boolean not null default false,
  sort integer not null default 0,
  primary key (venue_id, code)
);

create table public.stations (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  storefront_id uuid not null,
  name text not null check (length(btrim(name)) between 1 and 80),
  job_role_code text,
  unique (venue_id, id),
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code)
);
create index stations_storefront_idx on public.stations(storefront_id);

-- Default headcount by role for a storefront. Copied into each event and adjusted there.
create table public.storefront_staffing_needs (
  venue_id uuid not null,
  storefront_id uuid not null,
  job_role_code text not null,
  count integer not null check (count between 0 and 50),
  primary key (storefront_id, job_role_code),
  foreign key (venue_id, storefront_id) references public.storefronts(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code)
);

-- Starting job roles and certifications for a new venue (Texas defaults).
create or replace function public.seed_venue_job_defaults(p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.has_venue_permission(p_venue, 'manage_settings') and (select auth.role()) <> 'service_role' then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  insert into certification_types (venue_id, code, name, validity_months) values
    (p_venue, 'food_handler', 'Food Handler Card', 24),
    (p_venue, 'tabc', 'TABC Seller-Server', 24)
  on conflict do nothing;
  insert into job_roles (venue_id, code, name, required_certifications, minimum_age, tipped, sort) values
    (p_venue, 'lead', 'Lead', '{food_handler}', 18, false, 1),
    (p_venue, 'cashier', 'Cashier', '{}', null, false, 2),
    (p_venue, 'cook', 'Cook', '{food_handler}', 16, false, 3),
    (p_venue, 'bartender', 'Bartender', '{tabc}', 18, true, 4),
    (p_venue, 'runner', 'Runner', '{}', null, false, 5)
  on conflict do nothing;
end $$;

-- Required certifications must exist at the venue.
create or replace function public.check_job_role_certs()
returns trigger language plpgsql set search_path = public as $$
begin
  if exists (
    select 1 from unnest(new.required_certifications) c
    where not exists (select 1 from certification_types t where t.venue_id = new.venue_id and t.code = c)
  ) then
    raise exception 'Unknown certification type for role %', new.code using errcode = '22023';
  end if;
  return new;
end $$;

create trigger job_roles_check before insert or update on public.job_roles
for each row execute function public.check_job_role_certs();

create trigger storefronts_audit after insert or update or delete on public.storefronts
for each row execute function public.audit_row_change();
create trigger job_roles_audit after insert or update or delete on public.job_roles
for each row execute function public.audit_row_change();

alter table public.venue_levels enable row level security;
alter table public.storefronts enable row level security;
alter table public.certification_types enable row level security;
alter table public.job_roles enable row level security;
alter table public.stations enable row level security;
alter table public.storefront_staffing_needs enable row level security;

-- Every member can read the layout; only settings managers change it.
do $$
declare t text;
begin
  foreach t in array array['venue_levels','storefronts','certification_types','job_roles','stations','storefront_staffing_needs'] loop
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using (public.is_venue_member(venue_id))', t);
    execute format('create policy %1$s_write on public.%1$s for all to authenticated using (public.has_venue_permission(venue_id, ''manage_settings'')) with check (public.has_venue_permission(venue_id, ''manage_settings''))', t);
    execute format('revoke all on public.%1$s from anon', t);
  end loop;
end $$;

-- Storefronts a user may act on for a permission: all of them with venue scope,
-- the storefronts on a level with level scope, or one storefront with storefront scope.
create or replace function public.storefronts_in_scope(p_venue uuid, p_permission text)
returns setof uuid language sql stable security definer set search_path = public as $$
  select s.id from storefronts s
  where s.venue_id = p_venue
    and (
      public.has_venue_permission(p_venue, p_permission)
      or s.id in (select public.permission_scope_ids(p_venue, p_permission, 'storefront'))
      or s.level_id in (select public.permission_scope_ids(p_venue, p_permission, 'level'))
    );
$$;

create or replace function public.can_on_storefront(p_storefront uuid, p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from storefronts s
    where s.id = p_storefront
      and (
        public.has_venue_permission(s.venue_id, p_permission)
        or s.id in (select public.permission_scope_ids(s.venue_id, p_permission, 'storefront'))
        or s.level_id in (select public.permission_scope_ids(s.venue_id, p_permission, 'level'))
      )
  );
$$;

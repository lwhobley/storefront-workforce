-- Workforce: temp agencies, NPO groups, workers, trained roles, certifications, PIN sign-in.
--
-- SSNs, bank details, I-9 documents and W-4s are NOT stored here. They stay in Paycom.

create table public.temp_agencies (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  name text not null check (length(btrim(name)) between 1 and 160),
  contact_name text not null default '',
  contact_email text not null default '',
  contact_phone text not null default '',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (venue_id, id)
);

create table public.npo_groups (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  legal_name text not null check (length(btrim(legal_name)) between 1 and 200),
  display_name text not null check (length(btrim(display_name)) between 1 and 120),
  coordinator_name text not null default '',
  coordinator_email text not null default '',
  coordinator_phone text not null default '',
  w9_on_file boolean not null default false,
  w9_document_path text,
  -- How accounts payable pays the group (ACH, check). No account numbers are stored here.
  payment_method text not null default 'check' check (payment_method in ('ach', 'check', 'other')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (venue_id, id)
);

create table public.workers (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  worker_type text not null check (worker_type in ('regular', 'temp', 'npo')),
  employee_number text not null check (employee_number ~ '^[A-Z0-9-]{2,20}$'),
  first_name text not null check (length(btrim(first_name)) between 1 and 80),
  last_name text not null check (length(btrim(last_name)) between 1 and 80),
  preferred_name text not null default '',
  date_of_birth date,
  phone text not null default '',
  email text not null default '',
  photo_path text,
  uniform_size text not null default '',
  emergency_contact_name text not null default '',
  emergency_contact_phone text not null default '',
  preferred_language text not null default 'en' check (preferred_language in ('en', 'es')),
  agency_id uuid,
  npo_group_id uuid,
  paycom_employee_code text not null default '',
  hire_date date,
  status text not null default 'active' check (status in ('active', 'inactive')),
  -- Sign-in account, when the person uses the app.
  user_id uuid unique references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, employee_number),
  unique (venue_id, id),
  foreign key (venue_id, agency_id) references public.temp_agencies(venue_id, id),
  foreign key (venue_id, npo_group_id) references public.npo_groups(venue_id, id),
  check ((worker_type = 'temp') = (agency_id is not null)),
  check ((worker_type = 'npo') = (npo_group_id is not null))
);
create index workers_venue_idx on public.workers(venue_id, last_name);
create index workers_agency_idx on public.workers(agency_id) where agency_id is not null;
create index workers_npo_idx on public.workers(npo_group_id) where npo_group_id is not null;

create table public.worker_job_roles (
  venue_id uuid not null,
  worker_id uuid not null,
  job_role_code text not null,
  primary key (worker_id, job_role_code),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  foreign key (venue_id, job_role_code) references public.job_roles(venue_id, code) on delete cascade
);

create table public.worker_certifications (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  worker_id uuid not null,
  cert_type_code text not null,
  number text not null default '',
  issued_on date,
  expires_on date,
  document_path text,
  verified_by uuid references auth.users(id),
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  foreign key (venue_id, cert_type_code) references public.certification_types(venue_id, code),
  check (expires_on is null or issued_on is null or expires_on >= issued_on)
);
create index worker_certifications_worker_idx on public.worker_certifications(worker_id);

-- ---------------------------------------------------------------------------
-- PIN sign-in. Every person and kiosk signs in with a 6-digit PIN assigned by the
-- system. The PIN itself is never stored: the edge functions keep a secret key and
-- store only a keyed fingerprint (HMAC-SHA256). Fingerprints are unique, so a PIN
-- identifies one account by itself.
-- ---------------------------------------------------------------------------
create table public.user_pins (
  user_id uuid primary key references auth.users(id) on delete cascade,
  pin_fingerprint text not null unique check (pin_fingerprint ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz not null default now()
);

-- Failed attempts per device and per network address (hashed). Written only by the
-- sign-in function.
create table public.login_locks (
  lock_key text primary key check (lock_key ~ '^(device|ip):[0-9a-f]{64}$'),
  failures integer not null default 0 check (failures >= 0),
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

alter table public.temp_agencies enable row level security;
alter table public.npo_groups enable row level security;
alter table public.workers enable row level security;
alter table public.worker_job_roles enable row level security;
alter table public.worker_certifications enable row level security;
alter table public.user_pins enable row level security;
alter table public.login_locks enable row level security;
revoke all on public.user_pins, public.login_locks from anon, authenticated;
revoke all on public.temp_agencies, public.npo_groups, public.workers, public.worker_job_roles, public.worker_certifications from anon;

-- Who may see a worker's record:
--   venue-wide view_workers; the worker themself; the worker's agency contact;
--   the worker's NPO coordinator. Leads see their own storefront's people through
--   event_board(), which returns only what the live view needs.
create or replace function public.can_view_worker(p_worker uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from workers w
    where w.id = p_worker
      and (
        w.user_id = (select auth.uid())
        or public.has_venue_permission(w.venue_id, 'view_workers')
        or (w.agency_id is not null and w.agency_id in (select public.permission_scope_ids(w.venue_id, 'agency_portal', 'agency')))
        or (w.npo_group_id is not null and w.npo_group_id in (select public.permission_scope_ids(w.venue_id, 'npo_portal', 'npo_group')))
      )
  );
$$;

create policy temp_agencies_read on public.temp_agencies for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers')
         or id in (select public.permission_scope_ids(venue_id, 'agency_portal', 'agency')));
create policy temp_agencies_write on public.temp_agencies for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

create policy npo_groups_read on public.npo_groups for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers')
         or id in (select public.permission_scope_ids(venue_id, 'npo_portal', 'npo_group')));
create policy npo_groups_write on public.npo_groups for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

create policy workers_read on public.workers for select to authenticated
  using (public.can_view_worker(id));
create policy workers_insert on public.workers for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
create policy workers_update on public.workers for update to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
-- user_id links a sign-in account; only the staff-admin function sets it. A table-wide
-- grant would override a column revoke, so grant the other columns explicitly.
revoke insert, update, delete on public.workers from authenticated;
grant insert (id, venue_id, worker_type, employee_number, first_name, last_name, preferred_name,
  date_of_birth, phone, email, photo_path, uniform_size, emergency_contact_name,
  emergency_contact_phone, preferred_language, agency_id, npo_group_id, paycom_employee_code,
  hire_date, status) on public.workers to authenticated;
grant update (worker_type, employee_number, first_name, last_name, preferred_name,
  date_of_birth, phone, email, photo_path, uniform_size, emergency_contact_name,
  emergency_contact_phone, preferred_language, agency_id, npo_group_id, paycom_employee_code,
  hire_date, status) on public.workers to authenticated;

create policy worker_job_roles_read on public.worker_job_roles for select to authenticated
  using (public.can_view_worker(worker_id));
create policy worker_job_roles_write on public.worker_job_roles for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

create policy worker_certifications_read on public.worker_certifications for select to authenticated
  using (public.can_view_worker(worker_id));
create policy worker_certifications_write on public.worker_certifications for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

create or replace function public.touch_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger workers_touch before update on public.workers
for each row execute function public.touch_updated_at();

create trigger workers_audit after insert or update or delete on public.workers
for each row execute function public.audit_row_change();
create trigger worker_job_roles_audit after insert or update or delete on public.worker_job_roles
for each row execute function public.audit_row_change();
create trigger worker_certifications_audit after insert or update or delete on public.worker_certifications
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Sign-in attempt limiting (called only by the pin-login function, service role)
-- ---------------------------------------------------------------------------
create or replace function public.login_take_attempt(p_key text, p_max integer, p_lock_minutes integer)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v login_locks%rowtype;
begin
  insert into login_locks (lock_key) values (p_key) on conflict (lock_key) do nothing;
  select * into v from login_locks where lock_key = p_key for update;
  if v.locked_until is not null and v.locked_until > now() then
    return false;
  end if;
  if v.locked_until is not null or v.updated_at < now() - make_interval(mins => p_lock_minutes) then
    v.failures := 0;
  end if;
  v.failures := v.failures + 1;
  update login_locks
     set failures = v.failures,
         locked_until = case when v.failures >= p_max then now() + make_interval(mins => p_lock_minutes) end,
         updated_at = now()
   where lock_key = p_key;
  return v.failures <= p_max;
end $$;

create or replace function public.login_release(p_key text, p_clear boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_clear then
    delete from login_locks where lock_key = p_key;
  else
    update login_locks set failures = greatest(failures - 1, 0), updated_at = now() where lock_key = p_key;
  end if;
end $$;

revoke execute on function public.login_take_attempt(text, integer, integer) from public, anon, authenticated;
revoke execute on function public.login_release(text, boolean) from public, anon, authenticated;

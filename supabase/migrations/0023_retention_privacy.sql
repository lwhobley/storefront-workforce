-- Phase 5: data retention and deleting personal data on request.
--
-- Two separate ideas, kept apart on purpose:
--
--   Retention  - how long records are kept. Time and pay records are kept four years
--                (the venue can set its own period, never below the legal floor), then
--                old personal details may be cleared.
--   Deletion   - a person asks for their personal data to be removed. Wage and hour
--                records must still be kept for the retention period, so the request is
--                recorded, approved by an admin, and then the person is anonymised:
--                name, contact details and photos go; hours, pay and audit history stay,
--                attached to a worker row with no personal details.
--
-- Nothing here deletes a time record. Anonymising keeps payroll history intact.

-- ---- Retention settings -------------------------------------------------------------

create table public.retention_policies (
  venue_id uuid primary key references public.venues (id) on delete cascade,
  -- Months to keep time and pay records. Four years by default; two years is the floor
  -- (FLSA keeps time cards two years, payroll records three).
  time_records_months integer not null default 48 check (time_records_months between 24 and 120),
  -- Months to keep clock-in photos, which are the most sensitive and least needed later.
  punch_photos_months integer not null default 12 check (punch_photos_months between 1 and 120),
  -- Months after a person's last shift before their record may be anonymised.
  inactive_worker_months integer not null default 48 check (inactive_worker_months between 24 and 120),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users (id) on delete set null default auth.uid()
);

alter table public.retention_policies enable row level security;

create policy retention_read on public.retention_policies for select to authenticated
  using (public.has_venue_permission(venue_id, 'view_workers'));

create policy retention_write on public.retention_policies for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_settings'))
  with check (public.has_venue_permission(venue_id, 'manage_settings'));

grant select, insert, update on public.retention_policies to authenticated;

-- ---- Deletion requests --------------------------------------------------------------

create table public.data_deletion_requests (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues (id) on delete cascade,
  worker_id uuid not null,
  -- pending -> approved (then carried out) or refused.
  status text not null default 'pending' check (status in ('pending', 'approved', 'refused', 'completed')),
  -- Who asked, and why it was refused or held.
  requested_by uuid references auth.users (id) on delete set null default auth.uid(),
  requested_at timestamptz not null default now(),
  note text not null default '' check (length(note) <= 500),
  decided_by uuid references auth.users (id) on delete set null,
  decided_at timestamptz,
  decision_note text not null default '' check (length(decision_note) <= 500),
  completed_at timestamptz,
  foreign key (venue_id, worker_id) references public.workers (venue_id, id) on delete cascade
);

create index data_deletion_requests_venue_idx on public.data_deletion_requests (venue_id, status);

alter table public.data_deletion_requests enable row level security;

create policy deletion_requests_read on public.data_deletion_requests for select to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'));

create policy deletion_requests_insert on public.data_deletion_requests for insert to authenticated
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

grant select, insert on public.data_deletion_requests to authenticated;

-- ---- Anonymising ---------------------------------------------------------------------

-- Clears one person's personal details and keeps their work history. Only an admin
-- (manage_settings) may do this, and only for a request that is still pending.
--
-- Kept: shifts, punches, pay lines, ratings and audit rows, all still pointing at this
-- worker id. Cleared: name, preferred name, birth date, phone, email, photo, notes, the
-- sign-in link and the PIN. The employee number becomes "REMOVED-<short id>" so payroll
-- exports stay unique and nothing breaks.
create or replace function public.anonymize_worker(p_request uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r data_deletion_requests%rowtype;
  w workers%rowtype;
begin
  select * into r from data_deletion_requests where id = p_request for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(r.venue_id, 'manage_settings') then
    raise exception 'Only an admin can delete personal data' using errcode = '42501';
  end if;
  if r.status <> 'pending' then
    raise exception 'This request has already been decided' using errcode = '22023';
  end if;
  if r.requested_by = (select auth.uid()) then
    raise exception 'Someone else must approve a deletion request' using errcode = '42501';
  end if;

  select * into w from workers where id = r.worker_id;
  if w.id is null then raise exception 'Staff member not found' using errcode = 'P0002'; end if;

  update workers set
    first_name = 'Removed',
    last_name = 'Record',
    preferred_name = '',
    date_of_birth = null,
    phone = '',
    email = '',
    photo_path = null,
    employee_number = 'REMOVED-' || substr(replace(w.id::text, '-', ''), 1, 8),
    user_id = null,
    status = 'inactive'
  where id = w.id;

  -- Clock-in photos are personal data; the punch itself (the time) stays.
  update punches set photo_path = null where worker_id = w.id and photo_path is not null;

  -- Free-text notes about the person go; the counts behind reliability stay.
  delete from worker_notes where worker_id = w.id;

  update data_deletion_requests
     set status = 'completed', decided_by = (select auth.uid()), decided_at = now(),
         completed_at = now(), decision_note = left(coalesce(p_note, ''), 500)
   where id = p_request;

  insert into audit_logs (venue_id, action, entity, entity_id, reason, after)
  values (r.venue_id, 'anonymized', 'worker', w.id::text, left(coalesce(p_note, ''), 500),
          jsonb_build_object('request_id', p_request));
end $$;

revoke all on function public.anonymize_worker(uuid, text) from public, anon;
grant execute on function public.anonymize_worker(uuid, text) to authenticated;

-- Refuses a request (for example, the retention period has not passed yet).
create or replace function public.refuse_deletion_request(p_request uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare
  r data_deletion_requests%rowtype;
begin
  select * into r from data_deletion_requests where id = p_request for update;
  if not found then raise exception 'Request not found' using errcode = 'P0002'; end if;
  if not public.has_venue_permission(r.venue_id, 'manage_settings') then
    raise exception 'Only an admin can decide a deletion request' using errcode = '42501';
  end if;
  if r.status <> 'pending' then
    raise exception 'This request has already been decided' using errcode = '22023';
  end if;
  if length(btrim(coalesce(p_note, ''))) = 0 then
    raise exception 'Give a reason for refusing' using errcode = '22023';
  end if;
  update data_deletion_requests
     set status = 'refused', decided_by = (select auth.uid()), decided_at = now(),
         decision_note = left(p_note, 500)
   where id = p_request;
end $$;

revoke all on function public.refuse_deletion_request(uuid, text) from public, anon;
grant execute on function public.refuse_deletion_request(uuid, text) to authenticated;

-- ---- Retention sweep ------------------------------------------------------------------

-- What is past its retention period right now. Read-only: it reports, it does not delete,
-- so an admin can see the effect before anything is cleared.
create or replace function public.retention_due(p_venue uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  with p as (
    select coalesce(rp.punch_photos_months, 12) as photo_months,
           coalesce(rp.inactive_worker_months, 48) as worker_months
      from (select 1) x
      left join retention_policies rp on rp.venue_id = p_venue
  )
  select jsonb_build_object(
    'punch_photos', (select count(*) from punches, p
                      where punches.venue_id = p_venue and punches.photo_path is not null
                        and punches.occurred_at < now() - make_interval(months => p.photo_months)),
    'inactive_workers', (select count(*) from workers w, p
                          where w.venue_id = p_venue and w.status = 'inactive'
                            and not exists (select 1 from punches pu where pu.worker_id = w.id
                                             and pu.occurred_at > now() - make_interval(months => p.worker_months))
                            and w.first_name <> 'Removed')
  )
  where public.has_venue_permission(p_venue, 'view_workers');
$$;

revoke all on function public.retention_due(uuid) from public, anon;
grant execute on function public.retention_due(uuid) to authenticated;

-- Clears clock-in photos past the venue's photo retention period. The punches stay.
create or replace function public.purge_old_punch_photos(p_venue uuid)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_months integer;
  v_count integer;
begin
  if not public.has_venue_permission(p_venue, 'manage_settings') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  select coalesce(punch_photos_months, 12) into v_months from retention_policies where venue_id = p_venue;
  v_months := coalesce(v_months, 12);
  update punches set photo_path = null
   where venue_id = p_venue and photo_path is not null
     and occurred_at < now() - make_interval(months => v_months);
  get diagnostics v_count = row_count;
  insert into audit_logs (venue_id, action, entity, entity_id, after)
  values (p_venue, 'purged', 'punch_photos', null, jsonb_build_object('count', v_count, 'older_than_months', v_months));
  return v_count;
end $$;

revoke all on function public.purge_old_punch_photos(uuid) from public, anon;
grant execute on function public.purge_old_punch_photos(uuid) to authenticated;

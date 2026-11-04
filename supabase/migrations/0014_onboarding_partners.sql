-- Phase 3: onboarding and partner portals.
--
-- Onboarding: each venue has a list of steps (seeded with defaults, editable), its own
-- documents to acknowledge, and one progress row per person and step. People fill in
-- their own steps through submit_onboarding_step(); managers review uploads, tick
-- training and mark Paycom onboarding done. Some steps finish themselves: a document
-- step is complete when every current document is acknowledged, the card step when the
-- person holds a current card for every role they are trained in, the age step when a
-- birth date is on file.
--
-- No SSNs, bank details, I-9s or W-4s here. The Paycom step is a tick with a date that a
-- manager sets after the person finished Paycom's own onboarding.
--
-- Partner portals: npo_portal() and agency_portal() return one NPO group's or one temp
-- agency's people, shifts, time records and money owed to the partner (payouts, bill
-- rates). No venue pay rates, no birth dates; see each function for what is included.

-- ---------------------------------------------------------------------------
-- Steps, documents, progress
-- ---------------------------------------------------------------------------
create table public.onboarding_steps (
  venue_id uuid not null references public.venues(id) on delete cascade,
  code text not null check (code ~ '^[a-z][a-z0-9_]{1,39}$'),
  name text not null check (length(btrim(name)) between 1 and 120),
  description text not null default '',
  kind text not null check (kind in ('form', 'document', 'upload', 'checklist', 'external')),
  -- Worker types the step is for.
  applies_to text[] not null default '{regular,temp,npo}'
    check (cardinality(applies_to) > 0 and applies_to <@ array['regular', 'temp', 'npo']::text[]),
  required boolean not null default true,
  sort integer not null default 0,
  -- form: {"fields": [...]}; checklist: {"items": [{"code", "label", "roles"?}]};
  -- document: {"guardian_for_minors": true}; external: {"label": ...}.
  config jsonb not null default '{}'::jsonb,
  active boolean not null default true,
  primary key (venue_id, code)
);

-- Venue documents a person acknowledges by typing their name (handbook, uniform policy,
-- NPO waiver). The text lives in body, or in a file in the onboarding-docs bucket under
-- <venue_id>/documents/. Editing the text raises the version, so people acknowledge
-- the new text.
create table public.onboarding_documents (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null references public.venues(id) on delete cascade,
  step_code text not null default 'policies',
  title text not null check (length(btrim(title)) between 1 and 200),
  body text not null default '' check (length(body) <= 50000),
  document_path text,
  applies_to text[] not null default '{regular,temp}'
    check (cardinality(applies_to) > 0 and applies_to <@ array['regular', 'temp', 'npo']::text[]),
  active boolean not null default true,
  sort integer not null default 0,
  version integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (venue_id, id),
  foreign key (venue_id, step_code) references public.onboarding_steps(venue_id, code) on delete cascade
);

-- One row per person and step, created when the person or a manager first acts on it.
--   data: form answers; {"acknowledgments": [{document_id, title, version, typed_name,
--   guardian_name?, at}]}; {"certs": [...]}; {"items": {"<code>": {"at", "by"}}};
--   {"completed_on": "yyyy-mm-dd"}.
create table public.onboarding_progress (
  id uuid primary key default gen_random_uuid(),
  venue_id uuid not null,
  worker_id uuid not null,
  step_code text not null,
  status text not null default 'not_started'
    check (status in ('not_started', 'submitted', 'approved', 'needs_changes', 'complete')),
  data jsonb not null default '{}'::jsonb,
  file_paths text[] not null default '{}',
  submitted_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  note text not null default '' check (length(note) <= 1000),
  updated_at timestamptz not null default now(),
  unique (worker_id, step_code),
  foreign key (venue_id, worker_id) references public.workers(venue_id, id) on delete cascade,
  foreign key (venue_id, step_code) references public.onboarding_steps(venue_id, code) on delete cascade
);
create index onboarding_progress_venue_idx on public.onboarding_progress(venue_id, status);

create or replace function public.bump_onboarding_document_version()
returns trigger language plpgsql set search_path = public as $$
begin
  if new.title is distinct from old.title or new.body is distinct from old.body
     or new.document_path is distinct from old.document_path then
    new.version := old.version + 1;
  else
    new.version := old.version;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger onboarding_documents_version before update on public.onboarding_documents
for each row execute function public.bump_onboarding_document_version();
create trigger onboarding_progress_touch before update on public.onboarding_progress
for each row execute function public.touch_updated_at();

create trigger onboarding_steps_audit after insert or update or delete on public.onboarding_steps
for each row execute function public.audit_row_change();
create trigger onboarding_documents_audit after insert or update or delete on public.onboarding_documents
for each row execute function public.audit_row_change();
create trigger onboarding_progress_audit after insert or update or delete on public.onboarding_progress
for each row execute function public.audit_row_change();

-- ---------------------------------------------------------------------------
-- Defaults for every venue
-- ---------------------------------------------------------------------------
create or replace function public.seed_onboarding_defaults(p_venue uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into onboarding_steps (venue_id, code, name, description, kind, applies_to, required, sort, config) values
    (p_venue, 'application', 'Application', 'Contact details, emergency contact, uniform size, language.', 'form',
      '{regular}', true, 10,
      '{"fields": ["address", "phone", "email", "emergency_contact_name", "emergency_contact_phone", "uniform_size", "preferred_language", "notes"]}'),
    (p_venue, 'policies', 'Policies', 'Read and acknowledge the venue''s policies.', 'document',
      '{regular,temp}', true, 20, '{}'),
    (p_venue, 'waiver', 'Volunteer waiver', 'Read and sign the volunteer waiver. Volunteers under 18 also need a parent or guardian.', 'document',
      '{npo}', true, 25, '{"guardian_for_minors": true}'),
    (p_venue, 'age_confirmation', 'Age confirmation', 'A birth date on file, so the schedule follows the rules for minors.', 'form',
      '{npo}', true, 30, '{"fields": ["date_of_birth"], "auto_complete_when": "date_of_birth", "review": true}'),
    (p_venue, 'certifications', 'Certification cards', 'A photo of each card your roles need (food handler, TABC).', 'upload',
      '{regular,temp,npo}', true, 40, '{"review": true}'),
    (p_venue, 'training', 'Training', 'Your trainer checks these off as you finish them.', 'checklist',
      '{regular,temp,npo}', true, 50,
      '{"items": [
         {"code": "cash_handling", "label": "Cash handling"},
         {"code": "food_safety", "label": "Food safety at the stand"},
         {"code": "alcohol_service", "label": "Alcohol service (bartenders)", "roles": ["bartender"]},
         {"code": "emergency_exits", "label": "Emergency exits"}]}'),
    (p_venue, 'paycom', 'Paycom onboarding', 'Paycom onboarding (I-9, W-4, direct deposit) complete. Done in Paycom, marked here by a manager.', 'external',
      '{regular}', true, 60, '{"label": "Paycom onboarding (I-9, W-4, direct deposit) complete", "manager_only": true}')
  on conflict do nothing;

  -- Starting documents are drafts (inactive) until the venue puts in its own text.
  insert into onboarding_documents (venue_id, step_code, title, body, applies_to, active, sort)
  select p_venue, d.step_code, d.title, d.body, d.applies_to, false, d.sort
  from (values
    ('policies', 'Employee handbook acknowledgment',
      'Draft: replace with the venue''s handbook acknowledgment before turning it on.', '{regular,temp}'::text[], 1),
    ('policies', 'Uniform and appearance policy',
      'Draft: replace with the venue''s uniform and appearance policy before turning it on.', '{regular,temp}'::text[], 2),
    ('waiver', 'Volunteer waiver and release',
      'Draft: replace with the venue''s volunteer waiver (reviewed by counsel) before turning it on.', '{npo}'::text[], 1)
  ) as d(step_code, title, body, applies_to, sort)
  where not exists (select 1 from onboarding_documents x where x.venue_id = p_venue and x.title = d.title);
end $$;

create or replace function public.seed_venue_onboarding()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_onboarding_defaults(new.id);
  return new;
end $$;

create trigger venues_seed_onboarding after insert on public.venues
for each row execute function public.seed_venue_onboarding();

do $$ begin perform public.seed_onboarding_defaults(v.id) from public.venues v; end $$;

-- ---------------------------------------------------------------------------
-- Access
-- ---------------------------------------------------------------------------
alter table public.onboarding_steps enable row level security;
alter table public.onboarding_documents enable row level security;
alter table public.onboarding_progress enable row level security;
revoke all on public.onboarding_steps, public.onboarding_documents, public.onboarding_progress from anon;

create policy onboarding_steps_read on public.onboarding_steps for select to authenticated
  using (public.is_venue_member(venue_id));
create policy onboarding_steps_write on public.onboarding_steps for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));

create policy onboarding_documents_read on public.onboarding_documents for select to authenticated
  using (public.is_venue_member(venue_id));
create policy onboarding_documents_write on public.onboarding_documents for all to authenticated
  using (public.has_venue_permission(venue_id, 'manage_workers'))
  with check (public.has_venue_permission(venue_id, 'manage_workers'));
revoke update on public.onboarding_documents from authenticated;
grant update (step_code, title, body, document_path, applies_to, active, sort) on public.onboarding_documents to authenticated;

-- A person reads their own; managers who see staff read everyone's. Changes go through
-- the functions below.
create policy onboarding_progress_read on public.onboarding_progress for select to authenticated
  using (public.is_own_worker(worker_id) or public.has_venue_permission(venue_id, 'view_workers'));
revoke insert, update, delete on public.onboarding_progress from authenticated;

-- ---------------------------------------------------------------------------
-- Uploads: onboarding-docs/<venue_id>/<worker_id>/<file> (cards, signed forms) and
-- onboarding-docs/<venue_id>/documents/<file> (venue documents).
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('onboarding-docs', 'onboarding-docs', false, 5242880,
        array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do nothing;

create policy onboarding_docs_insert on storage.objects for insert to authenticated
  with check (
    bucket_id = 'onboarding-docs'
    and (exists (select 1 from public.workers w
                 where w.id = public.storage_worker(name) and w.venue_id = public.storage_venue(name)
                   and w.user_id = (select auth.uid()))
         or public.has_venue_permission(public.storage_venue(name), 'manage_workers'))
  );

create policy onboarding_docs_read on storage.objects for select to authenticated
  using (
    bucket_id = 'onboarding-docs'
    and (exists (select 1 from public.workers w
                 where w.id = public.storage_worker(name) and w.venue_id = public.storage_venue(name)
                   and w.user_id = (select auth.uid()))
         or public.has_venue_permission(public.storage_venue(name), 'manage_workers')
         or (split_part(name, '/', 2) = 'documents' and public.is_venue_member(public.storage_venue(name))))
  );

create policy onboarding_docs_manage on storage.objects for update to authenticated
  using (bucket_id = 'onboarding-docs' and public.has_venue_permission(public.storage_venue(name), 'manage_workers'))
  with check (bucket_id = 'onboarding-docs' and public.has_venue_permission(public.storage_venue(name), 'manage_workers'));

create policy onboarding_docs_delete on storage.objects for delete to authenticated
  using (bucket_id = 'onboarding-docs' and public.has_venue_permission(public.storage_venue(name), 'manage_workers'));

-- ---------------------------------------------------------------------------
-- Internal helpers (not callable through the API)
-- ---------------------------------------------------------------------------

-- Spaces collapsed, lower case.
create or replace function public.normalize_name(p text)
returns text language sql immutable set search_path = '' as $$
  select lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'));
$$;

-- A typed signature matches the person's legal or preferred first name plus last name.
create or replace function public.typed_name_matches(p_worker uuid, p_typed text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from workers w
    where w.id = p_worker
      and public.normalize_name(p_typed) <> ''
      and public.normalize_name(p_typed) in (
        public.normalize_name(w.first_name || ' ' || w.last_name),
        public.normalize_name(nullif(btrim(w.preferred_name), '') || ' ' || w.last_name)));
$$;

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
      select coalesce(jsonb_agg(x), '[]'::jsonb) into v_missing_docs
        from jsonb_array_elements(v_docs) x
       where not exists (
         select 1 from jsonb_array_elements(coalesce(p.data -> 'acknowledgments', '[]'::jsonb)) a
          where a ->> 'document_id' = x ->> 'id'
            and coalesce((a ->> 'version')::integer, 1) >= (x ->> 'version')::integer);
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
        'guardian_required', coalesce((s.config ->> 'guardian_for_minors')::boolean, false) and v_minor,
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

-- The signed-in person's staff record.
create or replace function public.my_worker()
returns workers language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where user_id = (select auth.uid()) and status = 'active' limit 1;
  if not found then
    raise exception 'No staff record is linked to this sign-in' using errcode = '42501';
  end if;
  return w;
end $$;

create or replace function public.require_onboarding_manager(p_worker uuid)
returns workers language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where id = p_worker;
  if not found or not public.has_venue_permission(w.venue_id, 'manage_workers') then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return w;
end $$;

-- ---------------------------------------------------------------------------
-- Onboarding functions
-- ---------------------------------------------------------------------------

-- The signed-in person's checklist, with the documents to read and their own details.
create or replace function public.my_onboarding()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype := public.my_worker();
begin
  return public.onboarding_state(w.id, true) || jsonb_build_object(
    'documents', (
      select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'step_code', d.step_code, 'title', d.title, 'body', d.body,
               'document_path', d.document_path, 'version', d.version) order by d.step_code, d.sort, d.title), '[]'::jsonb)
        from onboarding_documents d
       where d.venue_id = w.venue_id and d.active and w.worker_type = any (d.applies_to)),
    'profile', jsonb_build_object(
      'phone', w.phone, 'email', w.email, 'uniform_size', w.uniform_size,
      'emergency_contact_name', w.emergency_contact_name, 'emergency_contact_phone', w.emergency_contact_phone,
      'preferred_language', w.preferred_language, 'date_of_birth', w.date_of_birth));
end $$;

-- One person's checklist for a manager, with answers and uploads.
create or replace function public.worker_onboarding(p_worker uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
begin
  select * into w from workers where id = p_worker;
  if not found or not (public.has_venue_permission(w.venue_id, 'manage_workers')
                       or public.has_venue_permission(w.venue_id, 'view_workers')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return public.onboarding_state(w.id, true) || jsonb_build_object(
    'documents', (
      select coalesce(jsonb_agg(jsonb_build_object('id', d.id, 'step_code', d.step_code, 'title', d.title, 'body', d.body,
               'document_path', d.document_path, 'version', d.version) order by d.step_code, d.sort, d.title), '[]'::jsonb)
        from onboarding_documents d
       where d.venue_id = w.venue_id and d.active and w.worker_type = any (d.applies_to)));
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
                            where x ->> 'document_id' = d2.id::text and (x ->> 'version')::integer >= d2.version))
      then 'not_started' else 'complete' end;

  elsif s.kind = 'upload' then
    if jsonb_array_length(coalesce(p_data -> 'certs', '[]'::jsonb)) = 0 then
      raise exception 'Add a photo of your card' using errcode = '22023';
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

-- A manager approves a submitted step, or sends it back with a note.
--   certifications: approving verifies the uploaded cards; sending back removes them.
--   age_confirmation: approving puts the birth date on the staff record.
create or replace function public.review_onboarding_step(p_worker uuid, p_step text, p_approve boolean, p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.require_onboarding_manager(p_worker);
  s onboarding_steps%rowtype;
  p onboarding_progress%rowtype;
  v_ids uuid[];
  v_dob date;
  v_es boolean := w.preferred_language = 'es';
begin
  select * into s from onboarding_steps where venue_id = w.venue_id and code = p_step;
  select * into p from onboarding_progress where worker_id = w.id and step_code = p_step for update;
  if not found or p.status <> 'submitted' then
    raise exception 'Nothing to review for this step' using errcode = '22023';
  end if;
  if not p_approve and btrim(coalesce(p_note, '')) = '' then
    raise exception 'Say what needs to change' using errcode = '22023';
  end if;
  select coalesce(array_agg((x ->> 'id')::uuid), '{}') into v_ids
    from jsonb_array_elements(coalesce(p.data -> 'certs', '[]'::jsonb)) x;

  if p_approve then
    if s.kind = 'upload' then
      update worker_certifications set verified_by = (select auth.uid()), verified_at = now()
       where worker_id = w.id and id = any (v_ids) and verified_by is null;
    end if;
    if p.data ? 'date_of_birth' then
      v_dob := (p.data ->> 'date_of_birth')::date;
      perform set_config('app.audit_reason', 'Birth date confirmed in onboarding', true);
      update workers set date_of_birth = v_dob where id = w.id;
    end if;
  elsif s.kind = 'upload' then
    perform set_config('app.audit_reason', 'Card sent back in onboarding: ' || left(p_note, 200), true);
    delete from worker_certifications where worker_id = w.id and id = any (v_ids) and verified_by is null;
  end if;

  update onboarding_progress
     set status = case when p_approve then 'approved' else 'needs_changes' end,
         reviewed_by = (select auth.uid()), reviewed_at = now(), note = left(coalesce(p_note, ''), 1000)
   where id = p.id;

  if not p_approve then
    perform public.notify_worker(w.id, 'onboarding_review',
      case when v_es then 'Revise su incorporación: ' else 'Onboarding needs a change: ' end || s.name,
      p_note, '/me');
  end if;
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

-- Everyone at the venue with where they stand, for the onboarding board.
create or replace function public.onboarding_overview(p_venue uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not (public.has_venue_permission(p_venue, 'manage_workers') or public.has_venue_permission(p_venue, 'view_workers')) then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  return (
    select coalesce(jsonb_agg(public.onboarding_state(w.id, false) order by w.last_name, w.first_name), '[]'::jsonb)
      from workers w
     where w.venue_id = p_venue and w.status = 'active');
end $$;

-- Reminds a person what is left, in their language.
create or replace function public.send_onboarding_reminder(p_worker uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  w workers%rowtype := public.require_onboarding_manager(p_worker);
  v_state jsonb := public.onboarding_state(p_worker, false);
  v_missing text;
begin
  if (v_state ->> 'finished_at') is not null then
    raise exception 'Onboarding is already complete' using errcode = '22023';
  end if;
  if w.user_id is null then
    raise exception 'This person has no sign-in yet. Create a PIN first.' using errcode = '22023';
  end if;
  select string_agg(x, ', ') into v_missing from jsonb_array_elements_text(v_state -> 'missing') x;
  perform public.notify_worker(w.id, 'onboarding_reminder',
    case when w.preferred_language = 'es' then 'Termine su incorporación' else 'Finish your onboarding' end,
    case when w.preferred_language = 'es' then 'Falta: ' else 'Still to do: ' end || coalesce(v_missing, ''),
    '/me');
  return jsonb_build_object('sent', true, 'missing', v_state -> 'missing');
end $$;

-- ---------------------------------------------------------------------------
-- Partner portals
-- ---------------------------------------------------------------------------

-- Shifts, events and time records for a set of people at one venue. Times only: no GPS,
-- photos or devices. Punches start a week before p_from so weekly overtime (agency
-- billing) sees whole workweeks.
create or replace function public.partner_activity(p_venue uuid, p_workers uuid[], p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text;
  v_from timestamptz;
  v_to timestamptz;
begin
  select time_zone into v_tz from venues where id = p_venue;
  v_from := (p_from::timestamp at time zone v_tz);
  v_to := ((p_to + 1)::timestamp at time zone v_tz);
  return jsonb_build_object(
    'shifts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'venue_id', s.venue_id, 'event_id', s.event_id,
               'storefront_id', s.storefront_id, 'storefront_name', f.name, 'job_role_code', s.job_role_code,
               'worker_id', s.worker_id, 'call_time', s.call_time, 'scheduled_end', s.scheduled_end,
               'status', s.status, 'released_at', s.released_at) order by s.call_time), '[]'::jsonb)
        from shifts s
        join events e on e.id = s.event_id
        join storefronts f on f.id = s.storefront_id
       where s.venue_id = p_venue and s.worker_id = any (p_workers)
         and s.status in ('assigned', 'released')
         and ((e.start_time >= v_from - interval '7 days' and e.start_time < v_to)
              or (e.start_time >= now() - interval '12 hours' and e.status in ('scheduled', 'live')))),
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'venue_id', e.venue_id, 'name', e.name,
               'event_type_code', e.event_type_code, 'start_time', e.start_time, 'call_time', e.call_time,
               'doors_time', e.doors_time, 'end_time', e.end_time, 'status', e.status) order by e.start_time), '[]'::jsonb)
        from events e
       where e.venue_id = p_venue
         and ((e.start_time >= v_from - interval '7 days' and e.start_time < v_to)
              or (e.start_time >= now() - interval '12 hours' and e.status in ('scheduled', 'live')))
         and (exists (select 1 from shifts s where s.event_id = e.id and s.worker_id = any (p_workers))
              or exists (select 1 from punches p where p.event_id = e.id and p.worker_id = any (p_workers)))),
    'punches', (
      select coalesce(jsonb_agg(jsonb_build_object('id', p.id, 'venue_id', p.venue_id, 'worker_id', p.worker_id,
               'event_id', p.event_id, 'shift_id', p.shift_id, 'kind', p.kind, 'break_kind', p.break_kind,
               'occurred_at', p.occurred_at, 'source', p.source, 'status', p.status) order by p.occurred_at), '[]'::jsonb)
        from punches p
       where p.venue_id = p_venue and p.worker_id = any (p_workers) and p.status <> 'voided'
         and p.occurred_at >= v_from - interval '7 days' and p.occurred_at < v_to + interval '12 hours'));
end $$;

-- An NPO coordinator's group.
--   Members: names, employee number, trained roles, a minor flag (volunteers under 18
--   need a guardian on the waiver and closer supervision), phone (the coordinator is
--   who calls a missing volunteer on event night), onboarding progress and waiver
--   status. No birth dates, addresses or emergency contacts.
--   Payouts: what the venue owes the group per event, with status and payment reference.
-- p_group picks one group when the person coordinates several.
create or replace function public.npo_portal(p_from date, p_to date, p_group uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  g npo_groups%rowtype;
  v_ids uuid[];
  v_tz text;
begin
  select * into g from npo_groups n
   where (p_group is null or n.id = p_group)
     and n.id in (select public.permission_scope_ids(n.venue_id, 'npo_portal', 'npo_group'))
   order by n.display_name limit 1;
  if not found then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 400 then
    raise exception 'Choose a range of up to a year' using errcode = '22023';
  end if;
  select time_zone into v_tz from venues where id = g.venue_id;
  select coalesce(array_agg(id), '{}') into v_ids from workers where npo_group_id = g.id;

  return jsonb_build_object(
    'group', jsonb_build_object('id', g.id, 'venue_id', g.venue_id, 'display_name', g.display_name,
      'legal_name', g.legal_name, 'coordinator_name', g.coordinator_name, 'w9_on_file', g.w9_on_file),
    'groups', (
      select jsonb_agg(jsonb_build_object('id', n.id, 'display_name', n.display_name) order by n.display_name)
        from npo_groups n where n.id in (select public.permission_scope_ids(n.venue_id, 'npo_portal', 'npo_group'))),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', w.id, 'first_name', w.first_name, 'last_name', w.last_name, 'preferred_name', w.preferred_name,
               'employee_number', w.employee_number, 'status', w.status, 'phone', w.phone,
               'minor', (st ->> 'minor')::boolean,
               'roles', (select coalesce(jsonb_agg(r.job_role_code order by r.job_role_code), '[]'::jsonb)
                           from worker_job_roles r where r.worker_id = w.id),
               'onboarding_percent', (st ->> 'percent')::integer,
               'onboarding_missing', st -> 'missing',
               'waiver_status', coalesce((select x ->> 'status' from jsonb_array_elements(st -> 'steps') x
                                           where x ->> 'code' = 'waiver'), 'not_required'))
               order by w.last_name, w.first_name), '[]'::jsonb)
        from workers w cross join lateral public.onboarding_state(w.id, false) as o(st)
       where w.npo_group_id = g.id),
    'payouts', (
      select coalesce(jsonb_agg(jsonb_build_object('id', o.id, 'event_id', o.event_id, 'event_name', e.name,
               'start_time', e.start_time, 'members_scheduled', o.members_scheduled, 'members_worked', o.members_worked,
               'no_shows', o.no_shows, 'hours', o.hours, 'hourly_rate', o.hourly_rate, 'gross', o.gross,
               'deductions', o.deductions, 'adjustment', o.adjustment, 'adjustment_reason', o.adjustment_reason,
               'total', o.total, 'status', o.status, 'approved_at', o.approved_at, 'paid_at', o.paid_at,
               'payment_reference', o.payment_reference) order by e.start_time), '[]'::jsonb)
        from npo_payouts o join events e on e.id = o.event_id
       where o.npo_group_id = g.id
         and (e.start_time at time zone v_tz)::date between p_from and p_to),
    'season', (
      select jsonb_build_object(
               'events', count(*),
               'hours', coalesce(sum(o.hours), 0),
               'paid', coalesce(sum(o.total) filter (where o.status = 'paid'), 0),
               'approved', coalesce(sum(o.total) filter (where o.status = 'approved'), 0),
               'pending', coalesce(sum(o.total) filter (where o.status = 'pending'), 0))
        from npo_payouts o join events e on e.id = o.event_id
       where o.npo_group_id = g.id
         and (e.start_time at time zone v_tz)::date between p_from and p_to))
  || public.partner_activity(g.venue_id, v_ids, p_from, p_to);
end $$;

-- A temp agency contact's placed workers.
--   Workers: names, employee number, trained roles, onboarding progress. No phone, birth
--   date or address: the agency keeps its own employee records.
--   Bill rates: only this agency's rates with the venue. The app multiplies hours by
--   them with the same billing engine as the venue's invoices.
create or replace function public.agency_portal(p_from date, p_to date, p_agency uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  a temp_agencies%rowtype;
  v_ids uuid[];
begin
  select * into a from temp_agencies t
   where (p_agency is null or t.id = p_agency)
     and t.id in (select public.permission_scope_ids(t.venue_id, 'agency_portal', 'agency'))
   order by t.name limit 1;
  if not found then
    raise exception 'Not authorized' using errcode = '42501';
  end if;
  if p_to < p_from or p_to - p_from > 400 then
    raise exception 'Choose a range of up to a year' using errcode = '22023';
  end if;
  select coalesce(array_agg(id), '{}') into v_ids from workers where agency_id = a.id;

  return jsonb_build_object(
    'agency', jsonb_build_object('id', a.id, 'venue_id', a.venue_id, 'name', a.name, 'contact_name', a.contact_name),
    'agencies', (
      select jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) order by t.name)
        from temp_agencies t where t.id in (select public.permission_scope_ids(t.venue_id, 'agency_portal', 'agency'))),
    'members', (
      select coalesce(jsonb_agg(jsonb_build_object(
               'id', w.id, 'first_name', w.first_name, 'last_name', w.last_name, 'preferred_name', w.preferred_name,
               'employee_number', w.employee_number, 'status', w.status,
               'roles', (select coalesce(jsonb_agg(r.job_role_code order by r.job_role_code), '[]'::jsonb)
                           from worker_job_roles r where r.worker_id = w.id),
               'onboarding_percent', (st ->> 'percent')::integer,
               'onboarding_missing', st -> 'missing')
               order by w.last_name, w.first_name), '[]'::jsonb)
        from workers w cross join lateral public.onboarding_state(w.id, false) as o(st)
       where w.agency_id = a.id),
    'bill_rates', (
      select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'venue_id', r.venue_id, 'agency_id', r.agency_id,
               'job_role_code', r.job_role_code, 'bill_rate', r.bill_rate, 'overtime_bill_rate', r.overtime_bill_rate,
               'effective_from', r.effective_from, 'effective_to', r.effective_to) order by r.job_role_code, r.effective_from), '[]'::jsonb)
        from agency_bill_rates r where r.agency_id = a.id))
  || public.partner_activity(a.venue_id, v_ids, p_from, p_to);
end $$;

-- ---------------------------------------------------------------------------
-- Function access
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  -- Internal: triggers and helpers used by the functions below.
  foreach f in array array[
    'public.bump_onboarding_document_version()',
    'public.seed_venue_onboarding()',
    'public.seed_onboarding_defaults(uuid)',
    'public.normalize_name(text)',
    'public.typed_name_matches(uuid, text)',
    'public.onboarding_state(uuid, boolean)',
    'public.my_worker()',
    'public.require_onboarding_manager(uuid)',
    'public.partner_activity(uuid, uuid[], date, date)'] loop
    execute format('revoke execute on function %s from public, anon, authenticated', f);
  end loop;
  -- The API.
  foreach f in array array[
    'public.my_onboarding()',
    'public.worker_onboarding(uuid)',
    'public.submit_onboarding_step(text, jsonb, text[])',
    'public.review_onboarding_step(uuid, text, boolean, text)',
    'public.complete_onboarding_step(uuid, text, jsonb)',
    'public.onboarding_overview(uuid)',
    'public.send_onboarding_reminder(uuid)',
    'public.npo_portal(date, date, uuid)',
    'public.agency_portal(date, date, uuid)'] loop
    execute format('revoke execute on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated', f);
  end loop;
end $$;
grant execute on function public.seed_onboarding_defaults(uuid) to service_role;

-- Review fixes, round 2 (0001-0024 are live and unchanged). In plain words:
--
--  1. Photos: a photo path sent with a checklist tick or added to an incident must be a
--     file that really exists in the right storage bucket. A photo-required item can no
--     longer be ticked with a path nobody uploaded. (The app already uploads first and
--     sends the change after; a missing photo is refused with code WF404, which the app
--     treats as "try again later" rather than "refused for good".) Owner-of-file is not
--     checked: the platform's storage owner column is not in the local test stub, and
--     the folder policies already limit who can upload into a run or incident.
--  2. Resent change ids: when an id was already stored, the caller is re-checked. If
--     they can no longer see the checklist run or incident, they get only
--     {id, stored: true} so the app's queue clears, not the current content.
--  3. Deleting a person: anonymize_worker also blanks the person's name, contact and
--     birth date, and the note text, in the audit log, and no longer writes them again.
--     Free text of incidents (description, closing note, note bodies) is kept out of
--     the audit log, and an employee incident's closing note is not copied into the
--     audit "reason". Old audit rows for incidents are scrubbed the same way.
--  4. Ticking an item locks the run first, so a sign-off cannot slip in between.
--  5. Two copies of one change id at the same moment no longer fail with a raw
--     duplicate-key error; the second takes the "already stored" path.
--  6. A checklist with no items cannot be signed off.
--  7. events.labor_budget can only be set or changed by someone with view_pay.
--  8. The audit log no longer records labor_budget for events and event_storefronts
--     (old rows are scrubbed). A change to it is logged as "redacted_fields".

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------
create or replace function public.photo_uploaded(p_bucket text, p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from storage.objects o where o.bucket_id = p_bucket and o.name = p_path);
$$;

create or replace function public.audit_blank_keys(j jsonb, keys text[])
returns jsonb language sql immutable set search_path = '' as $$
  select case when j is null then null
    else coalesce((select jsonb_object_agg(e.key, case when e.key = any (keys) then '""'::jsonb else e.value end)
                     from jsonb_each(j) e), '{}'::jsonb) end;
$$;

-- Answers for a change id that is already stored: null when it is not stored.
create or replace function public.checklist_change_ack(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  c checklist_item_changes%rowtype;
begin
  select * into c from checklist_item_changes where id = p_id;
  if not found then return null; end if;
  if c.actor_id is distinct from (select auth.uid()) then
    raise exception 'Change id already used' using errcode = '23505';
  end if;
  if not public.can_see_checklist_run(c.run_id) then
    return jsonb_build_object('id', p_id, 'stored', true);
  end if;
  return public.checklist_run_json(c.run_id);
end $$;

create or replace function public.incident_ack(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  i incidents%rowtype;
begin
  select * into i from incidents where id = p_id;
  if not found then return null; end if;
  if i.reported_by is distinct from (select auth.uid()) then
    raise exception 'Incident id already used' using errcode = '23505';
  end if;
  if not public.can_see_incident(i.id) then
    return jsonb_build_object('id', p_id, 'stored', true);
  end if;
  return public.incident_json(i.id);
end $$;

create or replace function public.incident_note_ack(p_id uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  n incident_notes%rowtype;
begin
  select * into n from incident_notes where id = p_id;
  if not found then return null; end if;
  if n.author_id is distinct from (select auth.uid()) then
    raise exception 'Note id already used' using errcode = '23505';
  end if;
  if not public.can_see_incident(n.incident_id) then
    return jsonb_build_object('id', p_id, 'stored', true);
  end if;
  return public.incident_json(n.incident_id);
end $$;

revoke execute on function public.photo_uploaded(text, text), public.audit_blank_keys(jsonb, text[]),
  public.checklist_change_ack(uuid), public.incident_ack(uuid), public.incident_note_ack(uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Fixes 1, 2, 4, 5: record_checklist_item
-- ---------------------------------------------------------------------------
create or replace function public.record_checklist_item(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p ->> 'id')::uuid;
  v_storefront uuid := (p ->> 'storefront_id')::uuid;
  v_done boolean := coalesce((p ->> 'done')::boolean, false);
  v_note text := case when p ? 'note' and jsonb_typeof(p -> 'note') = 'string' then left(btrim(p ->> 'note'), 500) end;
  v_paths text[];
  v_occurred timestamptz := least(coalesce((p ->> 'occurred_at')::timestamptz, now()), now());
  v_run checklist_runs%rowtype;
  v_item checklist_run_items%rowtype;
  v_applied boolean;
  v_all text[];
  v_ack jsonb;
begin
  if v_id is null then
    raise exception 'A change id is required' using errcode = '22023';
  end if;
  v_ack := public.checklist_change_ack(v_id);
  if v_ack is not null then
    return v_ack;
  end if;

  if v_storefront is null or not public.can_on_storefront(v_storefront, 'manage_schedule') then
    raise exception 'Not authorized for this storefront' using errcode = '42501';
  end if;
  v_run := public.ensure_checklist_run((p ->> 'event_id')::uuid, v_storefront, (p ->> 'template_id')::uuid);
  -- Lock the run so a sign-off cannot commit between this check and the write.
  select * into v_run from checklist_runs where id = v_run.id for update;
  if v_run.status = 'signed_off' then
    raise exception 'This checklist is signed off. A manager can reopen it.' using errcode = '22023';
  end if;
  -- A copy of this change may have been stored while we waited for the lock.
  v_ack := public.checklist_change_ack(v_id);
  if v_ack is not null then
    return v_ack;
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
  if exists (select 1 from unnest(v_paths) x
              where x <> all (v_item.photo_paths) and not public.photo_uploaded('checklist-photos', x)) then
    raise exception 'A photo has not finished uploading. Your change is saved on this device and will be sent again.'
      using errcode = 'WF404';
  end if;
  select coalesce(array_agg(distinct x order by x), '{}') into v_all
    from unnest(v_item.photo_paths || v_paths) x;
  if cardinality(v_all) > 6 then
    raise exception 'Up to 6 photos per item' using errcode = '22023';
  end if;
  if v_done and v_item.photo_required
     and not exists (select 1 from unnest(v_all) x where public.photo_uploaded('checklist-photos', x)) then
    raise exception 'Add a photo for "%" first', v_item.label using errcode = '22023';
  end if;

  -- The change made last on a device wins; photos are always kept.
  v_applied := v_item.last_change_at is null or v_occurred >= v_item.last_change_at;
  begin
    insert into checklist_item_changes (id, venue_id, run_id, run_item_id, done, note, photo_paths, occurred_at, applied)
    values (v_id, v_run.venue_id, v_run.id, v_item.id, v_done, v_note, v_paths, v_occurred, v_applied);
  exception when unique_violation then
    v_ack := public.checklist_change_ack(v_id);
    if v_ack is null then raise; end if;
    return v_ack;
  end;

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

-- ---------------------------------------------------------------------------
-- Fix 6: sign_off_checklist refuses a run with no items
-- ---------------------------------------------------------------------------
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
  if not exists (select 1 from checklist_run_items where run_id = r.id) then
    raise exception 'This checklist has no items to sign off' using errcode = '22023';
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

-- ---------------------------------------------------------------------------
-- Fixes 2, 5: log_incident
-- ---------------------------------------------------------------------------
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
  v_workers uuid[];
  v_where text;
  v_user uuid;
  v_ack jsonb;
begin
  if v_id is null or v_venue is null then
    raise exception 'An incident id and venue are required' using errcode = '22023';
  end if;
  v_ack := public.incident_ack(v_id);
  if v_ack is not null then
    return v_ack;
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

  begin
    insert into incidents (id, venue_id, kind, severity, event_id, storefront_id, occurred_at, description)
    values (v_id, v_venue, v_kind, v_severity, v_event, v_storefront, v_occurred, btrim(coalesce(p ->> 'description', '')));
    insert into incident_people (venue_id, incident_id, worker_id)
    select v_venue, v_id, w from unnest(v_workers) w;
  exception when unique_violation then
    v_ack := public.incident_ack(v_id);
    if v_ack is null then raise; end if;
    return v_ack;
  end;

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

-- ---------------------------------------------------------------------------
-- Fix 1: add_incident_photos
-- ---------------------------------------------------------------------------
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
  if exists (select 1 from unnest(coalesce(p_paths, '{}')) x
              where x <> all (i.photo_paths) and not public.photo_uploaded('incident-photos', x)) then
    raise exception 'A photo has not finished uploading. Your change is saved on this device and will be sent again.'
      using errcode = 'WF404';
  end if;
  if cardinality(v_all) > 12 then
    raise exception 'Up to 12 photos per incident' using errcode = '22023';
  end if;
  update incidents set photo_paths = v_all where id = i.id;
  insert into incident_notes (venue_id, incident_id, kind, body)
  values (i.venue_id, i.id, 'photos', case when v_new = 1 then 'Added a photo' else 'Added ' || v_new || ' photos' end);
  return public.incident_json(i.id);
end $$;

-- ---------------------------------------------------------------------------
-- Fixes 2, 5: add_incident_note
-- ---------------------------------------------------------------------------
create or replace function public.add_incident_note(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := (p ->> 'id')::uuid;
  i incidents%rowtype;
  v_ack jsonb;
begin
  if v_id is null then
    raise exception 'A note id is required' using errcode = '22023';
  end if;
  v_ack := public.incident_note_ack(v_id);
  if v_ack is not null then
    return v_ack;
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
  begin
    insert into incident_notes (id, venue_id, incident_id, kind, body)
    values (v_id, i.venue_id, i.id, 'note', left(btrim(p ->> 'body'), 2000));
  exception when unique_violation then
    v_ack := public.incident_note_ack(v_id);
    if v_ack is null then raise; end if;
    return v_ack;
  end;
  update incidents set status = 'following_up' where id = i.id and status = 'open';
  return public.incident_json(i.id);
end $$;

-- ---------------------------------------------------------------------------
-- Fixes 3, 8: the audit trigger leaves sensitive fields out
-- ---------------------------------------------------------------------------
create or replace function public.audit_row_change()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  v_old jsonb := case when tg_op in ('UPDATE', 'DELETE') then to_jsonb(old) end;
  v_new jsonb := case when tg_op in ('INSERT', 'UPDATE') then to_jsonb(new) end;
  v_before jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  v_anon boolean := coalesce(current_setting('app.audit_anonymizing', true), '') = 'on';
  v_redact text[] := case tg_table_name
    when 'events' then array['labor_budget']
    when 'event_storefronts' then array['labor_budget']
    when 'incidents' then array['description', 'closing_note']
    when 'incident_notes' then array['body']
    when 'workers' then case when v_anon then array['first_name', 'last_name', 'preferred_name', 'date_of_birth',
      'phone', 'email', 'photo_path', 'emergency_contact_name', 'emergency_contact_phone'] else '{}'::text[] end
    when 'worker_notes' then case when v_anon then array['body'] else '{}'::text[] end
    else '{}'::text[] end;
  v_hidden text[] := '{}';
  v_reason text := coalesce(nullif(current_setting('app.audit_reason', true), ''), '');
  k text;
begin
  if tg_table_name in ('incident_notes', 'incident_people')
     or (tg_table_name = 'incidents' and coalesce(v_new ->> 'kind', v_old ->> 'kind') = 'employee') then
    -- The reason can hold an employee incident's closing note.
    v_reason := '';
  end if;
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(v_new) loop
      if k not in ('updated_at', 'version') and (v_old -> k) is distinct from (v_new -> k) then
        if k = any (v_redact) then
          v_hidden := v_hidden || k;
        else
          v_before := v_before || jsonb_build_object(k, v_old -> k);
          v_after := v_after || jsonb_build_object(k, v_new -> k);
        end if;
      end if;
    end loop;
    if cardinality(v_hidden) > 0 then
      v_after := v_after || jsonb_build_object('redacted_fields', to_jsonb(v_hidden));
    end if;
    if v_after = '{}'::jsonb then
      return new;
    end if;
  else
    v_before := v_old - v_redact;
    v_after := v_new - v_redact;
  end if;

  insert into audit_logs (venue_id, action, entity, entity_id, reason, before, after)
  values (
    coalesce((v_new ->> 'venue_id')::uuid, (v_old ->> 'venue_id')::uuid),
    tg_table_name || '.' || lower(tg_op),
    tg_table_name,
    coalesce(v_new ->> 'id', v_old ->> 'id'),
    v_reason,
    v_before,
    v_after
  );
  return coalesce(new, old);
end $$;

-- Scrub rows written before this change.
update public.audit_logs
   set before = before - 'labor_budget', after = after - 'labor_budget'
 where entity in ('events', 'event_storefronts')
   and (before ? 'labor_budget' or after ? 'labor_budget');
update public.audit_logs
   set before = before - array['description', 'closing_note', 'body'],
       after = after - array['description', 'closing_note', 'body']
 where entity in ('incidents', 'incident_notes')
   and (before ?| array['description', 'closing_note', 'body'] or after ?| array['description', 'closing_note', 'body']);
update public.audit_logs a set reason = ''
 where a.reason <> '' and (a.entity in ('incident_notes', 'incident_people')
    or (a.entity = 'incidents' and exists (select 1 from public.incidents i where i.id::text = a.entity_id and i.kind = 'employee')));

-- ---------------------------------------------------------------------------
-- Fix 3: anonymize_worker also clears the audit trail's copies
-- ---------------------------------------------------------------------------
create or replace function public.anonymize_worker(p_request uuid, p_note text default '')
returns void language plpgsql security definer set search_path = public as $$
declare
  r data_deletion_requests%rowtype;
  w workers%rowtype;
  v_personal text[] := array['first_name', 'last_name', 'preferred_name', 'date_of_birth', 'phone', 'email',
    'photo_path', 'emergency_contact_name', 'emergency_contact_phone'];
  v_rows_w integer;
  v_rows_n integer;
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

  -- The audit trigger leaves personal fields and note text out of the rows written below.
  perform set_config('app.audit_anonymizing', 'on', true);

  update workers set
    first_name = 'Removed',
    last_name = 'Record',
    preferred_name = '',
    date_of_birth = null,
    phone = '',
    email = '',
    photo_path = null,
    emergency_contact_name = '',
    emergency_contact_phone = '',
    employee_number = 'REMOVED-' || substr(replace(w.id::text, '-', ''), 1, 8),
    user_id = null,
    status = 'inactive'
  where id = w.id;

  -- Clock-in photos are personal data; the punch itself (the time) stays.
  update punches set photo_path = null where worker_id = w.id and photo_path is not null;

  -- Free-text notes about the person go; the counts behind reliability stay.
  delete from worker_notes where worker_id = w.id;

  -- Earlier audit rows still hold the old details: blank them, keep the rows.
  update audit_logs set before = public.audit_blank_keys(before, v_personal),
                        after = public.audit_blank_keys(after, v_personal)
   where entity = 'workers' and entity_id = w.id::text;
  get diagnostics v_rows_w = row_count;
  update audit_logs set before = public.audit_blank_keys(before, array['body']),
                        after = public.audit_blank_keys(after, array['body'])
   where entity = 'worker_notes' and (before ->> 'worker_id' = w.id::text or after ->> 'worker_id' = w.id::text);
  get diagnostics v_rows_n = row_count;

  perform set_config('app.audit_anonymizing', '', true);

  update data_deletion_requests
     set status = 'completed', decided_by = (select auth.uid()), decided_at = now(),
         completed_at = now(), decision_note = left(coalesce(p_note, ''), 500)
   where id = p_request;

  insert into audit_logs (venue_id, action, entity, entity_id, reason, after)
  values (r.venue_id, 'anonymized', 'worker', w.id::text, left(coalesce(p_note, ''), 500),
          jsonb_build_object('request_id', p_request, 'audit_rows_redacted', v_rows_w + v_rows_n));
end $$;

-- ---------------------------------------------------------------------------
-- Fix 7: events.labor_budget needs view_pay to set or change
-- ---------------------------------------------------------------------------
create or replace function public.guard_event_labor_budget()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if (select auth.uid()) is null then
    return new;  -- the platform itself (service role, migrations, internal jobs)
  end if;
  if (tg_op = 'INSERT' and new.labor_budget is not null)
     or (tg_op = 'UPDATE' and new.labor_budget is distinct from old.labor_budget) then
    if not public.has_venue_permission(new.venue_id, 'view_pay') then
      raise exception 'Only someone who can see pay can set a labor budget' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.guard_event_labor_budget() from public, anon, authenticated;

create trigger events_labor_budget_guard before insert or update on public.events
for each row execute function public.guard_event_labor_budget();

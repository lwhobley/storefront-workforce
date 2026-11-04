-- Checklists and incidents (0021). Self-contained; everything rolls back.
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0000-0000-0000002100a1', 'Org O');
insert into venues (id, organization_id, name, time_zone) values
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-0000002100a1', 'Ops Arena A', 'America/Chicago'),
  ('00000000-0000-0000-0000-00000021bb01', '00000000-0000-0000-0000-0000002100a1', 'Ops Arena B', 'America/Chicago');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000002111'), -- manager A (concessions manager, venue)
  ('00000000-0000-0000-0000-000000002112'), -- lead A (storefront S1)
  ('00000000-0000-0000-0000-000000002113'), -- level manager A (assistant manager, level L1)
  ('00000000-0000-0000-0000-000000002114'), -- assistant manager A (venue, no manage_workers)
  ('00000000-0000-0000-0000-000000002115'), -- employee A
  ('00000000-0000-0000-0000-000000002116'), -- manager B
  ('00000000-0000-0000-0000-000000002117'); -- NPO coordinator A
insert into user_profiles (id, display_name) values
  ('00000000-0000-0000-0000-000000002111', 'Mona Manager'),
  ('00000000-0000-0000-0000-000000002112', 'Lee Lead'),
  ('00000000-0000-0000-0000-000000002113', 'Lev Level'),
  ('00000000-0000-0000-0000-000000002114', 'Asa Assistant'),
  ('00000000-0000-0000-0000-000000002115', 'Emi Employee'),
  ('00000000-0000-0000-0000-000000002116', 'Bob B'),
  ('00000000-0000-0000-0000-000000002117', 'Nia Npo');

insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002111'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002112'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002113'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002114'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002115'),
  ('00000000-0000-0000-0000-00000021bb01', '00000000-0000-0000-0000-000000002116'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002117');

insert into venue_levels (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000002101a1', '00000000-0000-0000-0000-00000021aa01', 'Concourse'),
  ('00000000-0000-0000-0000-0000002101a2', '00000000-0000-0000-0000-00000021aa01', 'Suites'),
  ('00000000-0000-0000-0000-0000002101b1', '00000000-0000-0000-0000-00000021bb01', 'Main');
insert into storefronts (id, venue_id, level_id, code, name, kind) values
  ('00000000-0000-0000-0000-000000210101', '00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-0000002101a1', '115', 'Southside Bar', 'bar'),
  ('00000000-0000-0000-0000-000000210102', '00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-0000002101a1', '103', 'Grill', 'permanent_stand'),
  ('00000000-0000-0000-0000-000000210103', '00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-0000002101a2', '301', 'Suite Kitchen', 'permanent_stand'),
  ('00000000-0000-0000-0000-0000002101b1', '00000000-0000-0000-0000-00000021bb01', '00000000-0000-0000-0000-0000002101b1', '101', 'B Stand', 'permanent_stand');

insert into npo_groups (id, venue_id, legal_name, display_name) values
  ('00000000-0000-0000-0000-0000002114d1', '00000000-0000-0000-0000-00000021aa01', 'Boosters Inc.', 'Boosters');

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002111', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002112', 'storefront_lead', 'storefront', '00000000-0000-0000-0000-000000210101'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002112', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002113', 'assistant_manager', 'level', '00000000-0000-0000-0000-0000002101a1'),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002114', 'assistant_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002115', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000021bb01', '00000000-0000-0000-0000-000000002116', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000002117', 'npo_coordinator', 'npo_group', '00000000-0000-0000-0000-0000002114d1');

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, user_id) values
  ('00000000-0000-0000-0000-00000021c001', '00000000-0000-0000-0000-00000021aa01', 'regular', 'E2101', 'Emi', 'Employee', '00000000-0000-0000-0000-000000002115'),
  ('00000000-0000-0000-0000-00000021c002', '00000000-0000-0000-0000-00000021aa01', 'regular', 'E2102', 'Lee', 'Lead', '00000000-0000-0000-0000-000000002112'),
  ('00000000-0000-0000-0000-00000021c0b1', '00000000-0000-0000-0000-00000021bb01', 'regular', 'E2101', 'Zed', 'Other', null);

insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time, status) values
  ('00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-00000021aa01', 'Tonight', 'hockey',
   now() + interval '1 hour', now(), now() - interval '90 minutes', now() + interval '4 hours', 'live'),
  ('00000000-0000-0000-0000-000000210eb1', '00000000-0000-0000-0000-00000021bb01', 'B Tonight', 'hockey',
   now() + interval '1 hour', now(), now() - interval '90 minutes', now() + interval '4 hours', 'live');
insert into event_storefronts (venue_id, event_id, storefront_id, is_open) values
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-000000210101', true),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-000000210102', true),
  ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-000000210103', false),
  ('00000000-0000-0000-0000-00000021bb01', '00000000-0000-0000-0000-000000210eb1', '00000000-0000-0000-0000-0000002101b1', true);

create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, true), set_config('role', 'authenticated', true);
$$;
create or replace function pg_temp.as_owner() returns void language sql as $$
  select set_config('role', 'postgres', true), set_config('request.jwt.claim.sub', '', true);
$$;
create or replace function pg_temp.expect(ok boolean, what text) returns void language plpgsql as $$
begin
  if not coalesce(ok, false) then raise exception 'FAILED: %', what; end if;
  raise notice 'ok - %', what;
end $$;
create or replace function pg_temp.expect_error(sql text, what text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    raise notice 'ok - % (%)', what, sqlerrm;
    return;
  end;
  raise exception 'FAILED (no error): %', what;
end $$;
-- Template and item ids by name, for venue A.
create or replace function pg_temp.tpl(p_name text) returns uuid language sql as $$
  select id from checklist_templates where venue_id = '00000000-0000-0000-0000-00000021aa01' and name = p_name;
$$;
create or replace function pg_temp.item(p_tpl text, p_label text) returns uuid language sql as $$
  select ti.id from checklist_template_items ti join checklist_templates t on t.id = ti.template_id
   where t.venue_id = '00000000-0000-0000-0000-00000021aa01' and t.name = p_tpl and ti.label = p_label;
$$;
-- A checklist change as the app sends it.
create or replace function pg_temp.change(p_id text, p_storefront text, p_tpl text, p_label text, p_done boolean,
  p_photos text[] default '{}', p_at timestamptz default now(), p_note text default null) returns jsonb language sql as $$
  select jsonb_build_object('id', p_id, 'event_id', '00000000-0000-0000-0000-000000210e01', 'storefront_id', p_storefront,
    'template_id', pg_temp.tpl(p_tpl), 'template_item_id', pg_temp.item(p_tpl, p_label), 'done', p_done,
    'photo_paths', to_jsonb(p_photos), 'occurred_at', p_at) || case when p_note is null then '{}'::jsonb else jsonb_build_object('note', p_note) end;
$$;
create or replace function pg_temp.run_s1() returns uuid language sql as $$
  select id from checklist_runs where storefront_id = '00000000-0000-0000-0000-000000210101' and template_id = pg_temp.tpl('Opening');
$$;

-- ---- Defaults ---------------------------------------------------------------
select pg_temp.expect((select string_agg(name, ',' order by sort) from checklist_templates where venue_id = '00000000-0000-0000-0000-00000021aa01') = 'Opening,Closing',
  'a new venue gets Opening and Closing checklists');
select pg_temp.expect((select count(*) from checklist_templates where venue_id = '00000000-0000-0000-0000-00000021bb01') = 2,
  'every venue gets its own copy');
select pg_temp.expect((select count(*) from checklist_template_items where template_id = pg_temp.tpl('Opening')) = 6
  and (select count(*) from checklist_template_items where template_id = pg_temp.tpl('Closing')) = 5,
  'opening has 6 items, closing 5');
select pg_temp.expect((select storefront_kinds from checklist_template_items where id = pg_temp.item('Opening', 'TABC cards on hand')) = '{bar}',
  'TABC cards apply to bars only');

-- ---- Checklists: who sees what -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002115');
select pg_temp.expect_error($$select event_checklists('00000000-0000-0000-0000-000000210e01')$$, 'employees cannot open checklists');
select pg_temp.expect((select count(*) from checklist_templates) = 0, 'employees read no checklist templates');
select pg_temp.as_user('00000000-0000-0000-0000-000000002117');
select pg_temp.expect_error($$select event_checklists('00000000-0000-0000-0000-000000210e01')$$, 'partners cannot open checklists');
select pg_temp.as_user('00000000-0000-0000-0000-000000002116');
select pg_temp.expect_error($$select event_checklists('00000000-0000-0000-0000-000000210e01')$$, 'another venue''s manager cannot open them');

select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect((select event_checklists('00000000-0000-0000-0000-000000210e01') -> 'storefront_ids') = '["00000000-0000-0000-0000-000000210101"]'::jsonb,
  'a lead sees only their own storefront');
select pg_temp.expect((select event_checklists('00000000-0000-0000-0000-000000210e01') -> 'sign_off_storefront_ids') = '[]'::jsonb,
  'a lead cannot sign off');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect(jsonb_array_length(event_checklists('00000000-0000-0000-0000-000000210e01') -> 'storefront_ids') = 2,
  'a manager sees every open storefront (not closed ones)');

-- ---- Checklists: ticking items ------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c0', '00000000-0000-0000-0000-000000210102', 'Opening', 'All staff clocked in', true))$$,
  'a lead cannot tick another storefront''s checklist');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c1', '00000000-0000-0000-0000-000000210101', 'Opening', 'All staff clocked in', true)) ->> 'status') = 'in_progress',
  'a lead ticks an item; the run starts');
select pg_temp.expect((select count(*) from checklist_run_items where run_id = pg_temp.run_s1()) = 5,
  'a bar''s opening run has the 5 items for bars (no food handler cards)');
select pg_temp.expect((select count(*) from checklist_run_items where run_id = pg_temp.run_s1() and label = 'TABC cards on hand') = 1,
  'and it includes TABC cards');

-- Offline: the same change sent twice is stored once.
select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c1', '00000000-0000-0000-0000-000000210101', 'Opening', 'All staff clocked in', true));
select pg_temp.expect((select count(*) from checklist_item_changes where id = '00000000-0000-0000-0000-0000002100c1') = 1
  and (select count(*) from checklist_runs where storefront_id = '00000000-0000-0000-0000-000000210101') = 1,
  'a change resent from the device is stored once (one change, one run)');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c1', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true))$$,
  'another person cannot reuse a change id');

select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c2', '00000000-0000-0000-0000-000000210101', 'Opening', 'Uniforms checked', true))$$,
  'a photo item cannot be ticked without a photo');
select pg_temp.expect_error(format($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c3', '00000000-0000-0000-0000-000000210101', 'Opening', 'Uniforms checked', true, array['%s/other/x.jpg']))$$,
  '00000000-0000-0000-0000-00000021aa01'), 'photos must be in the run''s folder');

-- Photo storage: the run's folder, the run's storefront.
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021bb01/' || pg_temp.run_s1() || '/x.jpg')$$,
  'a photo cannot be filed under another venue');
insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s1() || '/uniforms.jpg');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'checklist-photos') = 1, 'the lead uploads and reads their run''s photo');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c4', '00000000-0000-0000-0000-000000210101', 'Opening', 'Uniforms checked', true,
  array['00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s1() || '/uniforms.jpg'], now(), 'All in black')) -> 'items' -> 1 ->> 'done') = 'true',
  'with the photo, the item is ticked');
select pg_temp.expect((select note from checklist_run_items where run_id = pg_temp.run_s1() and label = 'Uniforms checked') = 'All in black',
  'the note is kept');

-- Two devices: the change made later wins, even if it arrives first.
select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c5', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true, '{}', now() - interval '1 minute'));
select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c6', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', false, '{}', now() - interval '10 minutes'));
select pg_temp.expect((select done from checklist_run_items where run_id = pg_temp.run_s1() and label = 'Stations assigned')
  and not (select applied from checklist_item_changes where id = '00000000-0000-0000-0000-0000002100c6'),
  'an older change that arrives late does not undo a newer one (kept in the log)');

select pg_temp.as_user('00000000-0000-0000-0000-000000002115');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c7', '00000000-0000-0000-0000-000000210101', 'Opening', 'Lead briefing done', true))$$,
  'employees cannot tick items');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'checklist-photos') = 0, 'employees cannot see checklist photos');
select pg_temp.expect((select count(*) from checklist_runs) = 0, 'employees read no runs');
select pg_temp.as_user('00000000-0000-0000-0000-000000002116');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'checklist-photos') = 0
  and (select count(*) from checklist_runs) = 0 and (select count(*) from checklist_run_items) = 0,
  'another venue sees no runs or photos');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021aa01/' || (select id from checklist_runs limit 1) || '/x.jpg')$$,
  'another venue cannot upload into a run');

-- ---- Sign-off ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect_error($$select sign_off_checklist(pg_temp.run_s1(), '')$$, 'a lead cannot sign off');
select pg_temp.as_user('00000000-0000-0000-0000-000000002113');
select pg_temp.expect_error($$select sign_off_checklist(pg_temp.run_s1(), '')$$, 'an unfinished checklist cannot be signed off');
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c8', '00000000-0000-0000-0000-000000210101', 'Opening', 'Lead briefing done', true));
insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s1() || '/tabc.jpg');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100c9', '00000000-0000-0000-0000-000000210101', 'Opening', 'TABC cards on hand', true,
  array['00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s1() || '/tabc.jpg'])) ->> 'status') = 'complete',
  'every item done: the checklist is complete');
select pg_temp.as_user('00000000-0000-0000-0000-000000002113');
select pg_temp.expect(can_sign_off_checklist('00000000-0000-0000-0000-000000210101') and not can_sign_off_checklist('00000000-0000-0000-0000-000000210103'),
  'a level manager signs off on their level only');
select pg_temp.expect((sign_off_checklist(pg_temp.run_s1(), 'Looks good') ->> 'signed_off_by_name') = 'Lev Level',
  'a level manager signs off');
select pg_temp.expect_error($$select sign_off_checklist(pg_temp.run_s1(), '')$$, 'it cannot be signed off twice');
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100ca', '00000000-0000-0000-0000-000000210101', 'Opening', 'Lead briefing done', false))$$,
  'a signed-off checklist cannot be changed');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s1() || '/late.jpg')$$,
  'no new photos after sign-off');
select pg_temp.expect_error($$select reopen_checklist(pg_temp.run_s1(), 'Missed one')$$, 'a lead cannot reopen');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$select reopen_checklist(pg_temp.run_s1(), '  ')$$, 'reopening needs a reason');
select pg_temp.expect((reopen_checklist(pg_temp.run_s1(), 'Bartender swapped in') ->> 'status') = 'complete',
  'a manager reopens with a reason (items stay done)');
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from audit_logs where entity = 'checklist_runs' and reason = 'Bartender swapped in') >= 1
  and (select count(*) from audit_logs where entity = 'checklist_runs' and reason = 'Looks good') >= 1,
  'sign-off and reopen are audited with their reasons');
select pg_temp.expect((select count(*) from audit_logs where entity = 'checklist_run_items' and action = 'checklist_run_items.update') >= 5,
  'item changes are audited');

-- ---- Templates -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect_error($$select save_checklist_template(jsonb_build_object('venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'custom', 'name', 'Halftime', 'items', '[{"label": "Restock"}]'::jsonb))$$,
  'a lead cannot edit checklists');
select pg_temp.as_user('00000000-0000-0000-0000-000000002116');
select pg_temp.expect_error($$select save_checklist_template(jsonb_build_object('venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'custom', 'name', 'Halftime', 'items', '[{"label": "Restock"}]'::jsonb))$$,
  'another venue cannot edit them');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select save_checklist_template(jsonb_build_object('id', pg_temp.tpl('Opening'), 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'opening', 'name', 'Opening',
  'items', jsonb_build_array(jsonb_build_object('id', pg_temp.item('Opening', 'All staff clocked in'), 'label', 'Everyone clocked in'),
                             jsonb_build_object('label', 'Radios handed out', 'photo_required', true))));
select pg_temp.expect((select count(*) from checklist_template_items where template_id = pg_temp.tpl('Opening') and active) = 2,
  'a manager edits a template; dropped items are turned off');
select pg_temp.expect((select count(*) from checklist_run_items where run_id = pg_temp.run_s1()) = 5
  and exists (select 1 from checklist_run_items where run_id = pg_temp.run_s1() and label = 'All staff clocked in'),
  'a run already started keeps its items');

-- ---- Incidents: logging ------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a1', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'safety', 'severity', 'low',
  'event_id', '00000000-0000-0000-0000-000000210e01', 'storefront_id', '00000000-0000-0000-0000-000000210101', 'occurred_at', now() - interval '5 minutes',
  'description', 'Ice on the floor behind the bar'));
select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a1', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'safety', 'severity', 'low',
  'storefront_id', '00000000-0000-0000-0000-000000210101', 'description', 'Ice on the floor behind the bar'));
select pg_temp.expect((select count(*) from incidents where id = '00000000-0000-0000-0000-0000002110a1') = 1,
  'a lead logs an incident; sent twice from the device it is stored once');
select pg_temp.expect_error($$select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a2', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'safety', 'storefront_id', '00000000-0000-0000-0000-000000210102', 'description', 'x'))$$,
  'a lead cannot log for another storefront');
select pg_temp.expect_error($$select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a3', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'safety', 'description', 'x'))$$,
  'a lead picks their storefront');
select pg_temp.expect_error($$select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a4', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'other', 'storefront_id', '00000000-0000-0000-0000-000000210101', 'description', 'x', 'worker_ids', jsonb_build_array('00000000-0000-0000-0000-00000021c0b1')))$$,
  'people involved must be this venue''s staff');

select pg_temp.as_user('00000000-0000-0000-0000-000000002115');
select pg_temp.expect_error($$select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110a5', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'safety', 'storefront_id', '00000000-0000-0000-0000-000000210101', 'description', 'x'))$$,
  'employees cannot log incidents');
select pg_temp.expect_error($$select incidents_list('00000000-0000-0000-0000-00000021aa01')$$, 'employees cannot list incidents');
select pg_temp.expect((select count(*) from incidents) = 0, 'employees read no incidents');

-- A manager logs an injury: the other venue managers are told, without details.
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110b1', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'injury', 'severity', 'medium',
  'event_id', '00000000-0000-0000-0000-000000210e01', 'description', 'Guest services: cook burned hand on fryer',
  'worker_ids', jsonb_build_array('00000000-0000-0000-0000-00000021c001')));
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where kind = 'incident' and user_id = '00000000-0000-0000-0000-000000002114') = 1,
  'an injury notifies venue managers');
select pg_temp.expect((select count(*) from notifications where kind = 'incident' and user_id in ('00000000-0000-0000-0000-000000002111', '00000000-0000-0000-0000-000000002112', '00000000-0000-0000-0000-000000002115')) = 0,
  'not the reporter, leads or employees');
select pg_temp.expect((select body from notifications where kind = 'incident' limit 1) not like '%fryer%',
  'the alert carries no details');
select pg_temp.expect((select count(*) from notifications where kind = 'incident') = 1, 'a low-severity safety note notifies no one');

-- Employee incident (discipline): only venue-wide staff managers and the reporter.
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110c1', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'employee', 'severity', 'high',
  'storefront_id', '00000000-0000-0000-0000-000000210101', 'description', 'No call, no show for the second time', 'worker_ids', jsonb_build_array('00000000-0000-0000-0000-00000021c001')));
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110c2', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'employee', 'severity', 'low',
  'storefront_id', '00000000-0000-0000-0000-000000210101', 'description', 'Argument with a coworker'));
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where kind = 'incident' and user_id = '00000000-0000-0000-0000-000000002114') = 1,
  'a high-severity employee incident does not notify managers without staff rights');

select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect((select string_agg(id::text, ',' order by id) from incidents) = '00000000-0000-0000-0000-0000002110a1,00000000-0000-0000-0000-0000002110c2',
  'a lead sees their storefront''s incidents and their own reports, not the injury elsewhere or the manager''s employee incident');
select pg_temp.as_user('00000000-0000-0000-0000-000000002113');
select pg_temp.expect((select string_agg(id::text, ',' order by id) from incidents) = '00000000-0000-0000-0000-0000002110a1',
  'a level manager sees their level''s incidents, not employee incidents');
select pg_temp.as_user('00000000-0000-0000-0000-000000002114');
select pg_temp.expect((select string_agg(id::text, ',' order by id) from incidents) = '00000000-0000-0000-0000-0000002110a1,00000000-0000-0000-0000-0000002110b1',
  'a venue-wide assistant sees all but employee incidents');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect(jsonb_array_length(incidents_list('00000000-0000-0000-0000-00000021aa01')) = 4,
  'a manager with staff rights sees all four');
select pg_temp.expect((select incidents_list('00000000-0000-0000-0000-00000021aa01') -> 0 -> 'people' -> 0 ->> 'name') is not null,
  'the list names the people involved');
select pg_temp.as_user('00000000-0000-0000-0000-000000002116');
select pg_temp.expect((select count(*) from incidents) = 0 and jsonb_array_length(incidents_list('00000000-0000-0000-0000-00000021bb01')) = 0,
  'another venue sees none');
select pg_temp.expect_error($$select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110d1', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'other', 'description', 'x'))$$,
  'another venue cannot log here');
select pg_temp.expect_error($$select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110d2', 'incident_id', '00000000-0000-0000-0000-0000002110a1', 'body', 'x'))$$,
  'or add notes');
select pg_temp.as_user('00000000-0000-0000-0000-000000002117');
select pg_temp.expect((select count(*) from incidents) = 0 and (select count(*) from incident_notes) = 0, 'partners see no incidents');

-- ---- Incidents: follow-up -----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110e1', 'incident_id', '00000000-0000-0000-0000-0000002110a1', 'body', 'Mopped and put out a sign'));
select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110e1', 'incident_id', '00000000-0000-0000-0000-0000002110a1', 'body', 'Mopped and put out a sign'));
select pg_temp.expect((select count(*) from incident_notes where incident_id = '00000000-0000-0000-0000-0000002110a1' and kind = 'note') = 1
  and (select status from incidents where id = '00000000-0000-0000-0000-0000002110a1') = 'following_up',
  'a lead adds a note (once, even if resent); the incident moves to following up');
select pg_temp.expect_error($$select update_incident('00000000-0000-0000-0000-0000002110a1', 'closed', null, 'done')$$,
  'a lead cannot close an incident');
select pg_temp.expect_error($$select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110e2', 'incident_id', '00000000-0000-0000-0000-0000002110b1', 'body', 'x'))$$,
  'a lead cannot add to an incident they cannot see');

-- Photos in the incident's folder.
insert into storage.objects (bucket_id, name) values ('incident-photos', '00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110a1/floor.jpg');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('incident-photos', '00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110b1/x.jpg')$$,
  'a lead cannot add photos to an incident they cannot see');
select pg_temp.expect_error($$select add_incident_photos('00000000-0000-0000-0000-0000002110a1', array['00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110b1/x.jpg'])$$,
  'photo paths must be in the incident''s folder');
select add_incident_photos('00000000-0000-0000-0000-0000002110a1', array['00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110a1/floor.jpg']);
select add_incident_photos('00000000-0000-0000-0000-0000002110a1', array['00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110a1/floor.jpg']);
select pg_temp.expect((select cardinality(photo_paths) from incidents where id = '00000000-0000-0000-0000-0000002110a1') = 1
  and (select count(*) from incident_notes where incident_id = '00000000-0000-0000-0000-0000002110a1' and kind = 'photos') = 1,
  'photos added twice are kept once');
select pg_temp.as_user('00000000-0000-0000-0000-000000002115');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'incident-photos') = 0, 'employees cannot see incident photos');
select pg_temp.as_user('00000000-0000-0000-0000-000000002116');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'incident-photos') = 0, 'other venues cannot see incident photos');
select pg_temp.as_user('00000000-0000-0000-0000-000000002114');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'incident-photos') = 1, 'venue managers can');

-- Owner and closing.
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$select update_incident('00000000-0000-0000-0000-0000002110b1', null, '00000000-0000-0000-0000-000000002112')$$,
  'the follow-up owner must be able to see the incident');
select pg_temp.expect((update_incident('00000000-0000-0000-0000-0000002110b1', 'following_up', '00000000-0000-0000-0000-000000002114') ->> 'assigned_to_name') = 'Asa Assistant',
  'a manager assigns the follow-up');
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where kind = 'incident' and user_id = '00000000-0000-0000-0000-000000002114') = 2,
  'the owner is told');
select pg_temp.as_user('00000000-0000-0000-0000-000000002114');
select pg_temp.expect_error($$select update_incident('00000000-0000-0000-0000-0000002110c1', 'closed', null, 'x')$$,
  'a manager without staff rights cannot touch an employee incident');
select pg_temp.expect_error($$select update_incident('00000000-0000-0000-0000-0000002110b1', 'closed', null, '  ')$$,
  'closing needs a note');
select pg_temp.expect((update_incident('00000000-0000-0000-0000-0000002110b1', 'closed', null, 'Reported to HR, back next shift') ->> 'status') = 'closed',
  'the owner closes it with a note');
select pg_temp.expect_error($$select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110e3', 'incident_id', '00000000-0000-0000-0000-0000002110b1', 'body', 'x'))$$,
  'a closed incident takes no notes');
select pg_temp.expect((update_incident('00000000-0000-0000-0000-0000002110b1', 'following_up') ->> 'status') = 'following_up',
  'and can be reopened');
-- Order is not checked: inside one transaction every row shares created_at (now() is
-- fixed), and the id tiebreak is a random uuid, so the order here is not stable.
select pg_temp.expect(
  (select count(*) filter (where kind = 'assigned') = 1 and count(*) filter (where kind = 'status') = 3
     from incident_notes where incident_id = '00000000-0000-0000-0000-0000002110b1'),
  'owner and status changes are on the timeline');
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from audit_logs where entity = 'incidents' and reason = 'Reported to HR, back next shift') >= 1,
  'closing is audited with the note');

-- ---- Direct writes and internal functions ---------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$insert into incidents (id, venue_id, kind, occurred_at, description) values (gen_random_uuid(), '00000000-0000-0000-0000-00000021aa01', 'other', now(), 'x')$$,
  'no direct writes to incidents');
select pg_temp.expect_error($$update checklist_run_items set done = false$$, 'no direct writes to checklist items');
select pg_temp.expect_error($$update checklist_runs set status = 'signed_off', signed_off_at = now()$$, 'no direct sign-off');
select pg_temp.as_owner();
select pg_temp.expect(not has_function_privilege('authenticated', 'public.ensure_checklist_run(uuid, uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.incident_visible_to(uuid, uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.incident_json(uuid)', 'execute')
  and not has_function_privilege('authenticated', 'public.notify_user(uuid, uuid, text, text, text, text, text[], jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.log_incident(jsonb)', 'execute')
  and not has_function_privilege('anon', 'public.record_checklist_item(jsonb)', 'execute'),
  'internal helpers stay closed to the app, and anonymous callers get nothing');

-- ---- 0025: photos must exist, resent ids re-check access, no empty sign-off -------
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select start_checklist_run('00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-000000210102', pg_temp.tpl('Closing'));
select pg_temp.as_owner();
create or replace function pg_temp.run_s2() returns uuid language sql as $$
  select id from checklist_runs where storefront_id = '00000000-0000-0000-0000-000000210102' and template_id = pg_temp.tpl('Closing');
$$;
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error(format($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d1', '00000000-0000-0000-0000-000000210102', 'Closing', 'Clean-up checked', true, array['00000000-0000-0000-0000-00000021aa01/%s/never.jpg']))$$, pg_temp.run_s2()),
  'a photo path nobody uploaded is refused, so a photo item cannot be ticked with it');
select pg_temp.expect((select not done from checklist_run_items where run_id = pg_temp.run_s2() and label = 'Clean-up checked')
  and not exists (select 1 from checklist_item_changes where id = '00000000-0000-0000-0000-0000002100d1'),
  'and nothing was stored');
do $$ begin
  perform record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d1', '00000000-0000-0000-0000-000000210102', 'Closing', 'Clean-up checked', true,
    array['00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s2() || '/never.jpg']));
  raise exception 'FAILED: should have been refused';
exception when sqlstate 'WF404' then raise notice 'ok - a missing photo is refused with WF404 so the app retries it';
end $$;
insert into storage.objects (bucket_id, name) values ('checklist-photos', '00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s2() || '/real.jpg');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d1', '00000000-0000-0000-0000-000000210102', 'Closing', 'Clean-up checked', true,
  array['00000000-0000-0000-0000-00000021aa01/' || pg_temp.run_s2() || '/real.jpg'])) ->> 'id') = pg_temp.run_s2()::text,
  'once the photo is uploaded, the same change goes through');

-- Incident photos must exist too.
select pg_temp.expect_error($$select add_incident_photos('00000000-0000-0000-0000-0000002110b1', array['00000000-0000-0000-0000-00000021aa01/00000000-0000-0000-0000-0000002110b1/ghost.jpg'])$$,
  'an incident photo that was never uploaded is refused');
select pg_temp.expect((select cardinality(photo_paths) from incidents where id = '00000000-0000-0000-0000-0000002110b1') = 0,
  'and not attached');

-- A run with no items cannot be signed off.
select pg_temp.as_owner();
insert into checklist_runs (venue_id, event_id, storefront_id, template_id)
values ('00000000-0000-0000-0000-00000021aa01', '00000000-0000-0000-0000-000000210e01', '00000000-0000-0000-0000-000000210102', pg_temp.tpl('Opening'));
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$select sign_off_checklist((select id from checklist_runs where storefront_id = '00000000-0000-0000-0000-000000210102' and template_id = pg_temp.tpl('Opening')), '')$$,
  'a checklist with no items cannot be signed off');

-- Resending an old change id after losing access returns only an acknowledgement.
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d2', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true)) ? 'items'),
  'while the lead has access, a stored id returns the run');
select pg_temp.expect((record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d2', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true)) ? 'items'),
  'resending it still returns the run');
select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110f1', 'incident_id', '00000000-0000-0000-0000-0000002110c2', 'body', 'Spoke to both'));
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select update_incident('00000000-0000-0000-0000-0000002110c2', 'closed', null, 'Secret closing note');
select pg_temp.as_owner();
delete from role_assignments where user_id = '00000000-0000-0000-0000-000000002112';
select pg_temp.as_user('00000000-0000-0000-0000-000000002112');
select pg_temp.expect((select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d2', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true)))
    = jsonb_build_object('id', '00000000-0000-0000-0000-0000002100d2', 'stored', true),
  'a lead who lost their role gets only {id, stored} for an old checklist change');
select pg_temp.expect((select log_incident(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110c2', 'venue_id', '00000000-0000-0000-0000-00000021aa01', 'kind', 'employee', 'description', 'x')))
    = jsonb_build_object('id', '00000000-0000-0000-0000-0000002110c2', 'stored', true),
  'and for an old incident report (no closing note leaks)');
select pg_temp.expect((select add_incident_note(jsonb_build_object('id', '00000000-0000-0000-0000-0000002110f1', 'incident_id', '00000000-0000-0000-0000-0000002110c2', 'body', 'x')))
    = jsonb_build_object('id', '00000000-0000-0000-0000-0000002110f1', 'stored', true),
  'and for an old incident note');
select pg_temp.as_user('00000000-0000-0000-0000-000000002111');
select pg_temp.expect_error($$select record_checklist_item(pg_temp.change('00000000-0000-0000-0000-0000002100d2', '00000000-0000-0000-0000-000000210101', 'Opening', 'Stations assigned', true))$$,
  'another person still cannot reuse the id');

-- Audit log: incident free text is not copied in; employee closing notes stay out of reasons.
select pg_temp.as_owner();
select pg_temp.expect(not exists (select 1 from audit_logs where entity in ('incidents', 'incident_notes')
    and (before ?| array['description', 'closing_note', 'body'] or after ?| array['description', 'closing_note', 'body'])),
  'the audit log holds no incident description, closing note or note body');
select pg_temp.expect(not exists (select 1 from audit_logs where entity in ('incidents', 'incident_notes') and reason = 'Secret closing note'),
  'an employee incident''s closing note is not in the audit reason');

rollback;

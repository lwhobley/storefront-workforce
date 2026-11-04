-- Performance (0016 ratings and flags, 0022 notes): who can read and write what about
-- a person. Self-contained; everything rolls back.
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0000-0000-0000002200a1', 'Org Perf');
insert into venues (id, organization_id, name, time_zone) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-0000002200a1', 'Perf Arena A', 'America/Chicago'),
  ('00000000-0000-0000-0000-00000022bb01', '00000000-0000-0000-0000-0000002200a1', 'Perf Arena B', 'America/Chicago');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000002211'), -- concessions manager A
  ('00000000-0000-0000-0000-000000002212'), -- assistant manager A (view_workers, not manage_workers)
  ('00000000-0000-0000-0000-000000002213'), -- employee A (W1, the person rated and flagged)
  ('00000000-0000-0000-0000-000000002214'), -- storefront lead A
  ('00000000-0000-0000-0000-000000002215'), -- NPO coordinator A
  ('00000000-0000-0000-0000-000000002216'); -- concessions manager B

insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002211'),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002212'),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002213'),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002214'),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002215'),
  ('00000000-0000-0000-0000-00000022bb01', '00000000-0000-0000-0000-000000002216');

insert into venue_levels (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000002201a1', '00000000-0000-0000-0000-00000022aa01', 'Main');
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0000-0000-000000220101', '00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-0000002201a1', '101', 'Stand 101');
insert into npo_groups (id, venue_id, legal_name, display_name) values
  ('00000000-0000-0000-0000-0000002214d1', '00000000-0000-0000-0000-00000022aa01', 'Band Boosters Inc.', 'Band Boosters');

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002211', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002212', 'assistant_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002213', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002214', 'storefront_lead', 'storefront', '00000000-0000-0000-0000-000000220101'),
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-000000002215', 'npo_coordinator', 'npo_group', '00000000-0000-0000-0000-0000002214d1'),
  ('00000000-0000-0000-0000-00000022bb01', '00000000-0000-0000-0000-000000002216', 'concessions_manager', 'venue', null);

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, user_id, npo_group_id) values
  ('00000000-0000-0000-0000-00000022c001', '00000000-0000-0000-0000-00000022aa01', 'regular', 'E1001', 'Ana', 'Reyes', '00000000-0000-0000-0000-000000002213', null),
  ('00000000-0000-0000-0000-00000022c002', '00000000-0000-0000-0000-00000022aa01', 'npo', 'N3001', 'Eve', 'Park', null, '00000000-0000-0000-0000-0000002214d1'),
  ('00000000-0000-0000-0000-00000022c0b1', '00000000-0000-0000-0000-00000022bb01', 'regular', 'E1001', 'Zed', 'Other', null, null);

insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time, status) values
  ('00000000-0000-0000-0000-000000220e01', '00000000-0000-0000-0000-00000022aa01', 'Past Game', 'hockey',
   '2026-10-10 01:00+00', '2026-10-10 00:00+00', '2026-10-09 22:30+00', '2026-10-10 04:00+00', 'completed'),
  ('00000000-0000-0000-0000-000000220eb1', '00000000-0000-0000-0000-00000022bb01', 'Other Venue Game', 'hockey',
   '2026-10-10 01:00+00', '2026-10-10 00:00+00', '2026-10-09 22:30+00', '2026-10-10 04:00+00', 'completed');

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

-- ---- A manager rates, notes and flags -----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002211');
insert into worker_ratings (venue_id, worker_id, event_id, stars, note)
values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', '00000000-0000-0000-0000-000000220e01', 4, 'Quick on the register');
insert into worker_notes (venue_id, worker_id, body)
values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 'Asked about lead shifts next season.');
insert into rehire_flags (venue_id, worker_id, reason)
values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 'Two no-shows');
select pg_temp.expect((select written_by = '00000000-0000-0000-0000-000000002211' from worker_notes), 'a note records who wrote it');
select pg_temp.expect((select rated_by = '00000000-0000-0000-0000-000000002211' from worker_ratings), 'a rating records who gave it');
select pg_temp.expect_error($$insert into worker_ratings (venue_id, worker_id, stars, rated_by)
  values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 5, '00000000-0000-0000-0000-000000002212')$$,
  'a manager cannot sign a rating as someone else');
select pg_temp.expect_error($$insert into worker_ratings (venue_id, worker_id, stars, rated_at)
  values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 5, now() - interval '1 year')$$,
  'nor backdate it');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body, written_at)
  values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 'x', now() - interval '1 year')$$,
  'nor backdate a note');
select pg_temp.expect_error($$insert into rehire_flags (venue_id, worker_id, reason, flagged_by)
  values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c002', 'x', '00000000-0000-0000-0000-000000002212')$$,
  'nor flag someone in another manager''s name');
select pg_temp.expect_error($$insert into worker_ratings (venue_id, worker_id, event_id, stars)
  values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', '00000000-0000-0000-0000-000000220eb1', 3)$$,
  'a rating cannot point at another venue''s event');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', '   ')$$, 'an empty note is refused');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', repeat('x', 1001))$$, 'a note over 1,000 characters is refused');
select pg_temp.expect_error($$update worker_notes set body = 'rewritten'$$, 'notes cannot be edited');
select pg_temp.expect((select count(*) from worker_notes) = 1, 'the note is still there');
select pg_temp.expect_error($$delete from worker_notes$$, 'notes cannot be deleted');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body) values
  ('00000000-0000-0000-0000-00000022bb01', '00000000-0000-0000-0000-00000022c0b1', 'other venue')$$, 'a manager cannot write notes at another venue');

-- ---- Assistant manager: reads, cannot write ------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002212');
select pg_temp.expect((select count(*) from worker_ratings) = 1 and (select count(*) from worker_notes) = 1
  and (select count(*) from rehire_flags) = 1, 'view_workers reads ratings, notes and flags');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 'hi')$$, 'without manage_workers no notes');
select pg_temp.expect_error($$insert into worker_ratings (venue_id, worker_id, stars) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 5)$$, 'nor ratings');
select pg_temp.expect_error($$insert into rehire_flags (venue_id, worker_id, reason) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c002', 'x')$$, 'nor flags');

-- ---- Nobody else sees any of it, not even the person ---------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002213');
select pg_temp.expect((select count(*) from worker_ratings) = 0 and (select count(*) from worker_notes) = 0
  and (select count(*) from rehire_flags) = 0, 'an employee sees no ratings, notes or flags, including their own');
select pg_temp.expect_error($$insert into worker_notes (venue_id, worker_id, body) values
  ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', 'about me')$$, 'an employee cannot add notes');
select pg_temp.as_user('00000000-0000-0000-0000-000000002214');
select pg_temp.expect((select count(*) from worker_ratings) = 0 and (select count(*) from worker_notes) = 0
  and (select count(*) from rehire_flags) = 0, 'a storefront lead sees none of it');
select pg_temp.as_user('00000000-0000-0000-0000-000000002215');
select pg_temp.expect((select count(*) from worker_ratings) = 0 and (select count(*) from worker_notes) = 0
  and (select count(*) from rehire_flags) = 0, 'an NPO coordinator sees none of it');
select pg_temp.as_user('00000000-0000-0000-0000-000000002216');
select pg_temp.expect((select count(*) from worker_ratings) = 0 and (select count(*) from worker_notes) = 0
  and (select count(*) from rehire_flags) = 0, 'another venue''s manager sees none of it');

-- ---- No function an employee can call reads these tables ----------------------------
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and (p.prosrc ilike '%rehire_flags%' or p.prosrc ilike '%worker_ratings%' or p.prosrc ilike '%worker_notes%')
    and has_function_privilege('authenticated', p.oid, 'execute')) = 0,
  'no function callable by signed-in users reads ratings, notes or flags directly');
select pg_temp.expect(not has_table_privilege('anon', 'public.worker_notes', 'select'), 'anon cannot read notes');

-- ---- Audit -----------------------------------------------------------------------------
select pg_temp.expect((select count(*) from audit_logs where entity = 'worker_notes' and action = 'worker_notes.insert'
  and actor_id = '00000000-0000-0000-0000-000000002211') = 1, 'adding a note is audited with who did it');

-- ---- Deleting an event keeps the rating and note, without the event -----------------
insert into worker_notes (venue_id, worker_id, event_id, body)
values ('00000000-0000-0000-0000-00000022aa01', '00000000-0000-0000-0000-00000022c001', '00000000-0000-0000-0000-000000220e01', 'Event note');
delete from events where id = '00000000-0000-0000-0000-000000220e01';
select pg_temp.expect((select count(*) from worker_ratings where event_id is null) = 1, 'the rating stays when its event is deleted');
select pg_temp.expect((select count(*) from worker_notes where body = 'Event note' and event_id is null
  and venue_id = '00000000-0000-0000-0000-00000022aa01') = 1, 'so does the note, still at its venue');

rollback;

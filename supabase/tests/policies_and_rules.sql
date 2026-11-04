-- Behavior tests for tenant isolation, scoped roles, scheduling functions, and punches.
-- Run against a database with the migrations applied; everything rolls back.
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/policies_and_rules.sql
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values
  ('00000000-0000-0000-0000-0000000000a1', 'Org A'),
  ('00000000-0000-0000-0000-0000000000b1', 'Org B');
insert into venues (id, organization_id, name, time_zone, settings) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-0000000000a1', 'Arena A', 'America/Chicago', '{}'),
  ('00000000-0000-0000-0000-00000000bb01', '00000000-0000-0000-0000-0000000000b1', 'Arena B', 'America/Chicago', '{}');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000000001'), -- manager A
  ('00000000-0000-0000-0000-000000000002'), -- lead A, storefront 101 only
  ('00000000-0000-0000-0000-000000000003'), -- employee A (worker W1)
  ('00000000-0000-0000-0000-000000000004'), -- agency contact A
  ('00000000-0000-0000-0000-000000000005'), -- manager B
  ('00000000-0000-0000-0000-000000000006'); -- kiosk A

insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000001'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000002'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000003'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000004'),
  ('00000000-0000-0000-0000-00000000bb01', '00000000-0000-0000-0000-000000000005'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000006');

insert into venue_levels (id, venue_id, name, sort) values
  ('00000000-0000-0000-0000-0000000001a1', '00000000-0000-0000-0000-00000000aa01', 'Main', 1),
  ('00000000-0000-0000-0000-0000000001b1', '00000000-0000-0000-0000-00000000bb01', 'Main', 1);
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-0000000001a1', '101', 'Stand 101'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-0000000001a1', '102', 'Stand 102'),
  ('00000000-0000-0000-0000-000000000b01', '00000000-0000-0000-0000-00000000bb01', '00000000-0000-0000-0000-0000000001b1', '101', 'B Stand 101');

select set_config('request.jwt.claim.role', 'service_role', true);
select seed_venue_job_defaults('00000000-0000-0000-0000-00000000aa01');
select seed_venue_job_defaults('00000000-0000-0000-0000-00000000bb01');
select set_config('request.jwt.claim.role', '', true);

insert into storefront_staffing_needs (venue_id, storefront_id, job_role_code, count) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000101', 'cashier', 2),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000101', 'bartender', 1),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000102', 'cashier', 1);

insert into temp_agencies (id, venue_id, name) values
  ('00000000-0000-0000-0000-00000000ac01', '00000000-0000-0000-0000-00000000aa01', 'Agency One');

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000001', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000002', 'storefront_lead', 'storefront', '00000000-0000-0000-0000-000000000101'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000003', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000004', 'agency_contact', 'agency', '00000000-0000-0000-0000-00000000ac01'),
  ('00000000-0000-0000-0000-00000000bb01', '00000000-0000-0000-0000-000000000005', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-000000000006', 'kiosk', 'venue', null);

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, date_of_birth, user_id, agency_id) values
  ('00000000-0000-0000-0000-00000000c001', '00000000-0000-0000-0000-00000000aa01', 'regular', 'E1001', 'Ana', 'Reyes', '1995-04-02', '00000000-0000-0000-0000-000000000003', null),
  ('00000000-0000-0000-0000-00000000c002', '00000000-0000-0000-0000-00000000aa01', 'regular', 'E1002', 'Ben', 'Young', '2010-06-01', null, null),
  ('00000000-0000-0000-0000-00000000c003', '00000000-0000-0000-0000-00000000aa01', 'temp', 'T2001', 'Cara', 'Diaz', '1990-01-01', null, '00000000-0000-0000-0000-00000000ac01'),
  ('00000000-0000-0000-0000-00000000c004', '00000000-0000-0000-0000-00000000aa01', 'regular', 'E1003', 'Dev', 'Patel', '1988-01-01', null, null),
  ('00000000-0000-0000-0000-00000000c0b1', '00000000-0000-0000-0000-00000000bb01', 'regular', 'E1001', 'Zed', 'Other', '1990-01-01', null, null);
insert into worker_job_roles (venue_id, worker_id, job_role_code) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c001', 'cashier'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c001', 'bartender'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c002', 'cashier'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c002', 'bartender'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c003', 'cashier'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c004', 'bartender');
insert into worker_certifications (venue_id, worker_id, cert_type_code, expires_on) values
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c001', 'tabc', '2027-06-01'),
  ('00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c004', 'tabc', '2026-01-01'); -- expired

insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time) values
  ('00000000-0000-0000-0000-0000000e0001', '00000000-0000-0000-0000-00000000aa01', 'Game 1', 'hockey',
   '2026-11-20 01:00+00', '2026-11-20 00:00+00', '2026-11-19 22:30+00', '2026-11-20 04:00+00'),
  ('00000000-0000-0000-0000-0000000e00b1', '00000000-0000-0000-0000-00000000bb01', 'B Game', 'hockey',
   '2026-11-20 01:00+00', '2026-11-20 00:00+00', '2026-11-19 22:30+00', '2026-11-20 04:00+00');

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

-- ---- Venue isolation --------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000005');
select pg_temp.expect((select count(*) from workers) = 1, 'manager B sees only venue B workers');
select pg_temp.expect((select count(*) from events) = 1, 'manager B sees only venue B events');
select pg_temp.expect((select count(*) from storefronts) = 1, 'manager B sees only venue B storefronts');
select pg_temp.expect_error($$select set_event_storefronts('00000000-0000-0000-0000-0000000e0001', array['00000000-0000-0000-0000-000000000101'::uuid])$$,
  'manager B cannot open storefronts at venue A');
select pg_temp.expect_error($$select event_board('00000000-0000-0000-0000-0000000e0001')$$, 'manager B cannot read venue A board');
select pg_temp.expect_error($$insert into workers (venue_id, worker_type, employee_number, first_name, last_name)
  values ('00000000-0000-0000-0000-00000000aa01', 'regular', 'X1', 'X', 'Y')$$, 'manager B cannot add workers to venue A');

-- ---- Manager A builds the schedule -----------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select set_event_storefronts('00000000-0000-0000-0000-0000000e0001',
  array['00000000-0000-0000-0000-000000000101'::uuid, '00000000-0000-0000-0000-000000000102'::uuid]);
select pg_temp.expect(generate_open_shifts('00000000-0000-0000-0000-0000000e0001') = 4, 'four open positions created from defaults');
select pg_temp.expect(generate_open_shifts('00000000-0000-0000-0000-0000000e0001') = 0, 'generating again creates none');

select pg_temp.expect_error($$select assign_shift((select id from shifts where job_role_code = 'bartender' limit 1),
  '00000000-0000-0000-0000-00000000c002')$$, 'a 16-year-old cannot be a bartender');
select pg_temp.expect_error($$select assign_shift((select id from shifts where job_role_code = 'bartender' limit 1),
  '00000000-0000-0000-0000-00000000c004')$$, 'expired TABC blocks a bartender assignment');
select pg_temp.expect_error($$select assign_shift((select id from shifts where job_role_code = 'bartender' limit 1),
  '00000000-0000-0000-0000-00000000c0b1')$$, 'a venue B worker cannot be assigned at venue A');
select assign_shift((select id from shifts where job_role_code = 'bartender' limit 1), '00000000-0000-0000-0000-00000000c001');
select pg_temp.expect_error($$select assign_shift((select id from shifts where job_role_code = 'cashier' and status = 'open' limit 1),
  '00000000-0000-0000-0000-00000000c001')$$, 'a person cannot hold two positions at one event');
select pg_temp.expect_error($$select assign_shift((select id from shifts where job_role_code = 'cashier' and status = 'open' limit 1),
  '00000000-0000-0000-0000-00000000c002', '', array['minor_late_shift'])$$, 'accepting warnings requires a reason');
select assign_shift((select id from shifts where job_role_code = 'cashier' and status = 'open'
  and storefront_id = '00000000-0000-0000-0000-000000000101' limit 1),
  '00000000-0000-0000-0000-00000000c002', 'Approved by GM for early exit at 7pm', array['minor_late_shift']);
select assign_shift((select id from shifts where job_role_code = 'cashier' and status = 'open'
  and storefront_id = '00000000-0000-0000-0000-000000000101' limit 1), '00000000-0000-0000-0000-00000000c003');
select pg_temp.expect((select count(*) from assignment_changes where action = 'assigned') = 3, 'three assignments logged');
select pg_temp.expect((select acknowledged_warnings from assignment_changes where worker_id = '00000000-0000-0000-0000-00000000c002') = array['minor_late_shift'],
  'accepted warnings are recorded');

-- ---- Lead scope -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000002');
select pg_temp.expect((select count(*) from workers) = 0, 'lead cannot browse the staff directory');
select pg_temp.expect(jsonb_array_length(event_board('00000000-0000-0000-0000-0000000e0001') -> 'shifts') = 3,
  'lead board shows only storefront 101 positions');
select pg_temp.expect((select bool_and((w ->> 'age_on_event') is not null and not (w ? 'date_of_birth')) from
  jsonb_array_elements(event_board('00000000-0000-0000-0000-0000000e0001') -> 'workers') w), 'board gives age, never birth date');
select pg_temp.expect_error($$select move_shift((select id from shifts where worker_id = '00000000-0000-0000-0000-00000000c003'),
  '00000000-0000-0000-0000-000000000102', null, null, 'busy')$$, 'lead cannot move someone to a storefront outside scope');

-- ---- Mid-event move and early release (manager) ------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000001');
select pg_temp.expect_error($$select move_shift((select id from shifts where worker_id = '00000000-0000-0000-0000-00000000c003'),
  '00000000-0000-0000-0000-000000000102', null, null, '')$$, 'a move needs a reason');
select move_shift((select id from shifts where worker_id = '00000000-0000-0000-0000-00000000c003'),
  '00000000-0000-0000-0000-000000000102', null, null, '102 has a line');
select pg_temp.expect((select storefront_id from shifts where worker_id = '00000000-0000-0000-0000-00000000c003') = '00000000-0000-0000-0000-000000000102',
  'moved person now holds the open 102 position');
select pg_temp.expect((select count(*) from shifts where storefront_id = '00000000-0000-0000-0000-000000000101' and status = 'open') = 1,
  'their old 101 position is open again');
select release_shift((select id from shifts where worker_id = '00000000-0000-0000-0000-00000000c002'), 'Slow stand');
select release_shift((select id from shifts where worker_id = '00000000-0000-0000-0000-00000000c003'), 'Slow stand');
select pg_temp.expect((select release_order from shifts where worker_id = '00000000-0000-0000-0000-00000000c002') = 1
  and (select release_order from shifts where worker_id = '00000000-0000-0000-0000-00000000c003') = 2, 'release order recorded 1, 2');
select pg_temp.expect((select count(*) from audit_logs where entity = 'shifts' and reason = 'Slow stand') = 2, 'releases audited with reason');

-- ---- Agency contact ---------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000004');
select pg_temp.expect((select count(*) from workers) = 1 and (select employee_number from workers) = 'T2001', 'agency contact sees only their placed worker');
select pg_temp.expect((select count(*) from shifts) = 1, 'agency contact sees only their worker''s shift');

-- ---- Punches: idempotent, own only --------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000000003');
select record_punch(jsonb_build_object('id', '00000000-0000-0000-0000-00000000f001', 'kind', 'clock_in',
  'event_id', '00000000-0000-0000-0000-0000000e0001', 'occurred_at', now()));
select record_punch(jsonb_build_object('id', '00000000-0000-0000-0000-00000000f001', 'kind', 'clock_in',
  'event_id', '00000000-0000-0000-0000-0000000e0001', 'occurred_at', now()));
select pg_temp.expect((select count(*) from punches) = 1, 'the same punch sent twice is stored once');
select record_punch(jsonb_build_object('id', '00000000-0000-0000-0000-00000000f002', 'kind', 'break_start', 'break_kind', 'rest',
  'event_id', '00000000-0000-0000-0000-0000000e0001', 'occurred_at', now() - interval '13 hours'));
select pg_temp.expect((select status from punches where id = '00000000-0000-0000-0000-00000000f002') = 'needs_review',
  'a punch sent much later is kept and flagged for review');
select pg_temp.expect((select count(*) from workers) = 1, 'employee sees only themself');
select pg_temp.expect_error($$insert into punches (id, venue_id, worker_id, kind, occurred_at, source)
  values (gen_random_uuid(), '00000000-0000-0000-0000-00000000aa01', '00000000-0000-0000-0000-00000000c004', 'clock_in', now(), 'phone')$$,
  'nobody writes punches directly');
select pg_temp.expect_error($$select assign_shift((select id from shifts where status = 'open' limit 1), '00000000-0000-0000-0000-00000000c001')$$,
  'an employee cannot change the schedule');

-- ---- Kiosk path ---------------------------------------------------------------
select pg_temp.as_owner();
select set_config('request.jwt.claim.role', 'service_role', true);
select record_kiosk_punch('00000000-0000-0000-0000-000000000006', '00000000-0000-0000-0000-000000000003',
  jsonb_build_object('id', '00000000-0000-0000-0000-00000000f003', 'kind', 'clock_out', 'occurred_at', now()));
select pg_temp.expect((select source from punches where id = '00000000-0000-0000-0000-00000000f003') = 'kiosk', 'kiosk punch recorded');
select pg_temp.expect_error($$select record_kiosk_punch('00000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000003',
  jsonb_build_object('id', gen_random_uuid(), 'kind', 'clock_out', 'occurred_at', now()))$$, 'a manager account is not a kiosk');

-- ---- Event sync --------------------------------------------------------------
insert into event_sources (venue_id, kind) values ('00000000-0000-0000-0000-00000000aa01', 'premium_command');
select upsert_source_events('00000000-0000-0000-0000-00000000aa01', 'premium_command', $$[
  {"external_id": "pc-1", "name": "Stampede vs Rivals", "event_type": "hockey_game",
   "start_time": "2026-12-01T01:00:00Z", "end_time": "2026-12-01T04:00:00Z", "status": "planning"}]$$);
select pg_temp.expect((select call_time from events where external_id = 'pc-1') = '2026-11-30 22:30+00', 'synced event gets default doors and call times');
update events set call_time = '2026-11-30 22:00+00' where external_id = 'pc-1';
select upsert_source_events('00000000-0000-0000-0000-00000000aa01', 'premium_command', $$[
  {"external_id": "pc-1", "name": "Stampede vs Rivals (rescheduled)", "event_type": "hockey_game",
   "start_time": "2026-12-01T01:30:00Z", "end_time": "2026-12-01T04:30:00Z", "status": "cancelled"}]$$);
select pg_temp.expect((select count(*) from events where external_id = 'pc-1') = 1, 're-sync updates instead of duplicating');
select pg_temp.expect((select call_time from events where external_id = 'pc-1') = '2026-11-30 22:00+00', 'manager call time survives a re-sync');
select pg_temp.expect((select status from events where external_id = 'pc-1') = 'cancelled', 'cancellation flows from the source');
select pg_temp.expect((select count(*) from events where venue_id = '00000000-0000-0000-0000-00000000bb01') = 1, 'sync did not touch venue B');

rollback;

-- Behavior tests for open shifts, pickups, drops, swaps, availability, and the manager
-- approval queue (0012_shift_market.sql). Self-contained fixtures; everything rolls back.
--   psql -v ON_ERROR_STOP=1 -f supabase/tests/shift_market.sql
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0012-0000-0000000000a1', 'Market Org');
insert into venues (id, organization_id, name, time_zone, settings) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-0000000000a1', 'Market Arena A', 'America/Chicago', '{}'),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-0000000000a1', 'Market Arena B', 'America/Chicago', '{}');

insert into auth.users (id) values
  ('00000000-0000-0012-0000-000000000001'), -- manager A (venue-wide)
  ('00000000-0000-0012-0000-000000000002'), -- lead A, storefront F1 only
  ('00000000-0000-0012-0000-000000000003'), -- Ana (adult, cashier + bartender, TABC)
  ('00000000-0000-0012-0000-000000000004'), -- Ben (16, cashier + bartender)
  ('00000000-0000-0012-0000-000000000005'), -- Cara (adult, cashier + bartender, no TABC)
  ('00000000-0000-0012-0000-000000000006'), -- Dev (adult, cashier)
  ('00000000-0000-0012-0000-000000000007'), -- manager B
  ('00000000-0000-0012-0000-000000000008'); -- Zed, employee at venue B
insert into user_profiles (id, display_name) values
  ('00000000-0000-0012-0000-000000000001', 'Manager A');

insert into venue_memberships (venue_id, user_id)
select '00000000-0000-0012-0000-00000000aa01', u from unnest(array[
  '00000000-0000-0012-0000-000000000001', '00000000-0000-0012-0000-000000000002', '00000000-0000-0012-0000-000000000003',
  '00000000-0000-0012-0000-000000000004', '00000000-0000-0012-0000-000000000005', '00000000-0000-0012-0000-000000000006']::uuid[]) u;
insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-000000000007'),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-000000000008');

insert into venue_levels (id, venue_id, name, sort) values
  ('00000000-0000-0012-0000-0000000001a1', '00000000-0000-0012-0000-00000000aa01', 'Main', 1),
  ('00000000-0000-0012-0000-0000000001b1', '00000000-0000-0012-0000-00000000bb01', 'Main', 1);
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0012-0000-000000000f01', '00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-0000000001a1', 'F1', 'Stand F1'),
  ('00000000-0000-0012-0000-000000000f02', '00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-0000000001a1', 'F2', 'Stand F2'),
  ('00000000-0000-0012-0000-000000000fb1', '00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-0000000001b1', 'B1', 'B Stand');

select set_config('request.jwt.claim.role', 'service_role', true);
select seed_venue_job_defaults('00000000-0000-0012-0000-00000000aa01');
select seed_venue_job_defaults('00000000-0000-0012-0000-00000000bb01');
select set_config('request.jwt.claim.role', '', true);

insert into storefront_staffing_needs (venue_id, storefront_id, job_role_code, count) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000f01', 'cashier', 2),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000f01', 'bartender', 1),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000f02', 'cashier', 2),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-000000000fb1', 'cashier', 1);

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000001', 'concessions_manager', 'venue', null),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000002', 'storefront_lead', 'storefront', '00000000-0000-0012-0000-000000000f01'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000003', 'employee', 'venue', null),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000004', 'employee', 'venue', null),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000005', 'employee', 'venue', null),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-000000000006', 'employee', 'venue', null),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-000000000007', 'concessions_manager', 'venue', null),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-000000000008', 'employee', 'venue', null);

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, date_of_birth, user_id) values
  ('00000000-0000-0012-0000-00000000c001', '00000000-0000-0012-0000-00000000aa01', 'regular', 'M1001', 'Ana', 'Reyes', '1995-04-02', '00000000-0000-0012-0000-000000000003'),
  ('00000000-0000-0012-0000-00000000c002', '00000000-0000-0012-0000-00000000aa01', 'regular', 'M1002', 'Ben', 'Young', current_date - interval '16 years 2 months', '00000000-0000-0012-0000-000000000004'),
  ('00000000-0000-0012-0000-00000000c003', '00000000-0000-0012-0000-00000000aa01', 'regular', 'M1003', 'Cara', 'Diaz', '1990-01-01', '00000000-0000-0012-0000-000000000005'),
  ('00000000-0000-0012-0000-00000000c004', '00000000-0000-0012-0000-00000000aa01', 'regular', 'M1004', 'Dev', 'Patel', '1988-01-01', '00000000-0000-0012-0000-000000000006'),
  ('00000000-0000-0012-0000-00000000c005', '00000000-0000-0012-0000-00000000aa01', 'regular', 'M1005', 'Eli', 'Nash', '1985-01-01', null),
  ('00000000-0000-0012-0000-00000000c0b1', '00000000-0000-0012-0000-00000000bb01', 'regular', 'M1001', 'Zed', 'Other', '1990-01-01', '00000000-0000-0012-0000-000000000008');
insert into worker_job_roles (venue_id, worker_id, job_role_code) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c001', 'cashier'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c001', 'bartender'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c002', 'cashier'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c002', 'bartender'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c003', 'cashier'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c003', 'bartender'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c004', 'cashier'),
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c005', 'cashier'),
  ('00000000-0000-0012-0000-00000000bb01', '00000000-0000-0012-0000-00000000c0b1', 'cashier');
insert into worker_certifications (venue_id, worker_id, cert_type_code, expires_on) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-00000000c001', 'tabc', current_date + 400);

-- E1 in 5 days, E2 in 10 hours (inside the 24-hour drop cutoff), E3 in 7 days,
-- EX cancelled, EB at venue B.
insert into events (id, venue_id, name, event_type_code, call_time, doors_time, start_time, end_time, status) values
  ('00000000-0000-0012-0000-0000000e0001', '00000000-0000-0012-0000-00000000aa01', 'Game 1', 'hockey',
   now() + interval '5 days', now() + interval '5 days 1 hour', now() + interval '5 days 2 hours', now() + interval '5 days 5 hours', 'scheduled'),
  ('00000000-0000-0012-0000-0000000e0002', '00000000-0000-0012-0000-00000000aa01', 'Game 2', 'hockey',
   now() + interval '10 hours', now() + interval '11 hours', now() + interval '12 hours', now() + interval '15 hours', 'scheduled'),
  ('00000000-0000-0012-0000-0000000e0003', '00000000-0000-0012-0000-00000000aa01', 'Concert 3', 'concert',
   now() + interval '7 days', now() + interval '7 days 1 hour', now() + interval '7 days 2 hours', now() + interval '7 days 5 hours', 'scheduled'),
  ('00000000-0000-0012-0000-0000000e00cc', '00000000-0000-0012-0000-00000000aa01', 'Cancelled', 'hockey',
   now() + interval '6 days', now() + interval '6 days 1 hour', now() + interval '6 days 2 hours', now() + interval '6 days 5 hours', 'scheduled'),
  ('00000000-0000-0012-0000-0000000e00b1', '00000000-0000-0012-0000-00000000bb01', 'B Game', 'hockey',
   now() + interval '5 days', now() + interval '5 days 1 hour', now() + interval '5 days 2 hours', now() + interval '5 days 5 hours', 'scheduled');

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

-- Manager A opens storefronts and creates positions for every event.
select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select set_event_storefronts(e, array['00000000-0000-0012-0000-000000000f01'::uuid, '00000000-0000-0012-0000-000000000f02'::uuid]),
       generate_open_shifts(e)
from unnest(array['00000000-0000-0012-0000-0000000e0001', '00000000-0000-0012-0000-0000000e0002',
                  '00000000-0000-0012-0000-0000000e0003', '00000000-0000-0012-0000-0000000e00cc']::uuid[]) e;
select pg_temp.as_user('00000000-0000-0012-0000-000000000007');
select set_event_storefronts('00000000-0000-0012-0000-0000000e00b1', array['00000000-0000-0012-0000-000000000fb1'::uuid]),
       generate_open_shifts('00000000-0000-0012-0000-0000000e00b1');
select pg_temp.as_owner();
update events set status = 'cancelled' where id = '00000000-0000-0012-0000-0000000e00cc';

-- Position ids by event / storefront / role.
select
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0001' and storefront_id = '00000000-0000-0012-0000-000000000f01' and job_role_code = 'cashier' order by id limit 1) as e1_f1_cash,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0001' and storefront_id = '00000000-0000-0012-0000-000000000f01' and job_role_code = 'bartender' limit 1) as e1_f1_bar,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0001' and storefront_id = '00000000-0000-0012-0000-000000000f02' and job_role_code = 'cashier' order by id limit 1) as e1_f2_cash,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0002' and storefront_id = '00000000-0000-0012-0000-000000000f01' and job_role_code = 'cashier' order by id limit 1) as e2_f1_cash,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0003' and storefront_id = '00000000-0000-0012-0000-000000000f01' and job_role_code = 'cashier' order by id limit 1) as e3_f1_cash,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e0003' and storefront_id = '00000000-0000-0012-0000-000000000f02' and job_role_code = 'cashier' order by id limit 1) as e3_f2_cash,
  (select id from shifts where event_id = '00000000-0000-0012-0000-0000000e00b1' limit 1) as eb_cash
\gset

-- ---- Open shifts: only eligible ones ----------------------------------------
select pg_temp.as_user('00000000-0000-0012-0000-000000000006'); -- Dev, cashier only
select pg_temp.expect(jsonb_array_length(open_shifts_for_me()) > 0
  and (select bool_and(x -> 'shift' ->> 'job_role_code' = 'cashier') from jsonb_array_elements(open_shifts_for_me()) x),
  'an employee sees only open shifts in roles they are trained for');
select pg_temp.expect((select count(*) from jsonb_array_elements(open_shifts_for_me()) x
  where x -> 'event' ->> 'id' = '00000000-0000-0012-0000-0000000e00cc') = 0, 'cancelled events are not offered');
select pg_temp.expect((select bool_and(x ->> 'storefront_name' is not null and x -> 'event' ->> 'name' is not null)
  from jsonb_array_elements(open_shifts_for_me()) x), 'open shifts carry event and storefront names');
select pg_temp.expect((select count(*) from shifts) = 0, 'employees still cannot read open positions directly');

select pg_temp.as_user('00000000-0000-0012-0000-000000000004'); -- Ben, 16
select pg_temp.expect((select bool_and(x ->> 'blocked' like 'Bartender must be at least 18%') from jsonb_array_elements(open_shifts_for_me()) x
  where x -> 'shift' ->> 'job_role_code' = 'bartender'), 'a minor sees why a bartender shift is blocked');

select pg_temp.as_user('00000000-0000-0012-0000-000000000008'); -- Zed, venue B
select pg_temp.expect((select bool_and(x -> 'shift' ->> 'venue_id' = '00000000-0000-0012-0000-00000000bb01') from jsonb_array_elements(open_shifts_for_me()) x),
  'a venue B employee sees only venue B open shifts');
select pg_temp.expect_error(format('select request_pickup(%L)', :'e1_f1_cash'), 'a venue B employee cannot pick up a venue A shift');

select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select pg_temp.expect_error('select open_shifts_for_me()', 'a manager without a staff record has no open-shift list');

-- ---- Pickup -> manager approval ------------------------------------------------
select pg_temp.as_user('00000000-0000-0012-0000-000000000003'); -- Ana
select pg_temp.expect((request_pickup(:'e1_f1_cash', 'Can stay late')).status = 'pending', 'a pickup creates a pending request');
select pg_temp.expect_error(format('select request_pickup(%L)', :'e1_f1_cash'), 'asking twice for the same shift is refused');
select pg_temp.expect((select count(*) from shift_requests) = 1, 'the requester sees their own request');
select pg_temp.expect((select x ->> 'my_request_id' from jsonb_array_elements(open_shifts_for_me()) x
  where x -> 'shift' ->> 'id' = :'e1_f1_cash') is not null, 'the open shift shows that it was requested');
select pg_temp.expect_error($$insert into shift_requests (venue_id, kind, shift_id, requester_worker_id)
  values ('00000000-0000-0012-0000-00000000aa01', 'pickup', (select id from shifts limit 1), '00000000-0000-0012-0000-00000000c001')$$,
  'nobody writes requests directly');
select pg_temp.expect_error('select decide_shift_request((select id from shift_requests limit 1), true)', 'an employee cannot approve requests');

select pg_temp.as_user('00000000-0000-0012-0000-000000000004'); -- Ben, 16
select pg_temp.expect_error(format('select request_pickup(%L)', :'e1_f1_bar'), 'the minimum age still blocks a pickup');
select pg_temp.as_user('00000000-0000-0012-0000-000000000005'); -- Cara, no TABC
select pg_temp.expect_error(format('select request_pickup(%L)', :'e1_f1_bar'), 'a missing certification still blocks a pickup');
select pg_temp.as_user('00000000-0000-0012-0000-000000000006'); -- Dev
select pg_temp.expect_error(format('select request_pickup(%L)', :'e1_f1_bar'), 'a pickup in an untrained role is refused');
select request_pickup(:'e1_f2_cash');
select request_pickup(:'e1_f1_cash');
select pg_temp.expect((select count(*) from shift_requests) = 2, 'a coworker does not see Ana''s request');

select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000001' and kind = 'shift_request') = 3,
  'the manager is notified of each new request');
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000002' and kind = 'shift_request') = 2,
  'the lead is notified only for their storefront');
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000007') = 0,
  'the other venue''s manager hears nothing');

select id as dev_f2_pickup from shift_requests where shift_id = :'e1_f2_cash' \gset
select pg_temp.as_user('00000000-0000-0012-0000-000000000002'); -- lead, F1 only
select pg_temp.expect(jsonb_array_length(review_shift_requests()) = 2, 'the lead''s queue shows only their storefront');
select pg_temp.expect((select bool_and(x -> 'requester' ? 'age_on_event' and not (x -> 'requester' ? 'date_of_birth') and not (x -> 'requester' ? 'phone'))
  from jsonb_array_elements(review_shift_requests()) x), 'the queue gives rules fields (age, certifications), not birth dates or contacts');
select pg_temp.expect_error(format('select decide_shift_request(%L, true)', :'dev_f2_pickup'),
  'a lead cannot decide a request outside their storefront');

select pg_temp.as_user('00000000-0000-0012-0000-000000000007'); -- manager B
select pg_temp.expect(jsonb_array_length(review_shift_requests()) = 0 and (select count(*) from shift_requests) = 0,
  'manager B sees no venue A requests');
select pg_temp.as_owner();
select id as ana_pickup from shift_requests where requester_worker_id = '00000000-0000-0012-0000-00000000c001' \gset
select pg_temp.as_user('00000000-0000-0012-0000-000000000007');
select pg_temp.expect_error(format('select decide_shift_request(%L, true)', :'ana_pickup'), 'manager B cannot decide a venue A request');

select pg_temp.as_user('00000000-0000-0012-0000-000000000001'); -- manager A
select pg_temp.expect_error(format('select decide_shift_request(%L, true, '''', array[''minor_late_shift''])', :'ana_pickup'),
  'approving despite warnings needs a note');
select pg_temp.expect((decide_shift_request(:'ana_pickup', true, 'Good fit')).status = 'approved', 'the manager approves the pickup');
select pg_temp.expect((select worker_id from shifts where id = :'e1_f1_cash') = '00000000-0000-0012-0000-00000000c001', 'approval assigns the shift');
select pg_temp.expect((select reason from assignment_changes where shift_id = :'e1_f1_cash' and action = 'assigned') = 'Pickup approved: Good fit',
  'the assignment is logged with the reason');
select pg_temp.expect((select status from shift_requests where shift_id = :'e1_f1_cash' and requester_worker_id = '00000000-0000-0012-0000-00000000c004') = 'expired',
  'other requests for the filled shift close');
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000003' and kind = 'request_decided') = 1,
  'the requester is notified of the decision');
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000006' and kind = 'request_decided') = 1,
  'a coworker whose request closed is told the shift was filled');

select pg_temp.as_user('00000000-0000-0012-0000-000000000003'); -- Ana
select pg_temp.expect((select count(*) from jsonb_array_elements(open_shifts_for_me()) x
  where x -> 'event' ->> 'id' = '00000000-0000-0012-0000-0000000e0001') = 0, 'no open shifts at an event where you already work');

-- The manager denies Dev's F2 request.
select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select decide_shift_request((select id from shift_requests where shift_id = :'e1_f2_cash'), false, 'Covered');
select pg_temp.expect((select status from shifts where id = :'e1_f2_cash') = 'open', 'a denied pickup leaves the shift open');
select pg_temp.expect_error(format('select decide_shift_request((select id from shift_requests where shift_id = %L), true)', :'e1_f2_cash'),
  'a decided request cannot be decided again');

-- ---- Drops ---------------------------------------------------------------------
select assign_shift(:'e2_f1_cash', '00000000-0000-0012-0000-00000000c001');
select pg_temp.as_user('00000000-0000-0012-0000-000000000003'); -- Ana
select pg_temp.expect_error(format('select request_drop(%L, ''Sick'')', :'e2_f1_cash'), 'a drop inside the cutoff is refused');
select pg_temp.expect_error(format('select request_drop(%L, ''Sick'')', :'e1_f2_cash'), 'you cannot drop a shift that is not yours');
select pg_temp.expect((request_drop(:'e1_f1_cash', 'Family event')).status = 'pending', 'a drop request is pending');
select pg_temp.as_user('00000000-0000-0012-0000-000000000002'); -- lead approves (F1 is in scope)
select decide_shift_request((select id from shift_requests where kind = 'drop'), true);
select pg_temp.expect((select status from shifts where id = :'e1_f1_cash') = 'open', 'an approved drop opens the shift again');
select pg_temp.expect((select count(*) from assignment_changes where shift_id = :'e1_f1_cash' and action = 'unassigned'
  and reason like 'Drop approved%Family event%') = 1, 'the drop is logged with the employee''s reason');

-- ---- Swaps ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select assign_shift(:'e3_f1_cash', '00000000-0000-0012-0000-00000000c001');
select pg_temp.as_user('00000000-0000-0012-0000-000000000003'); -- Ana
select pg_temp.expect((select bool_and(not (c ? 'date_of_birth') and not (c ? 'phone') and not (c ? 'email'))
  from jsonb_array_elements(my_swap_candidates(:'e3_f1_cash')) c), 'swap candidates are names only');
select pg_temp.expect(my_swap_candidates(:'e3_f1_cash') @> '[{"name": "Dev Patel"}]'
  and not my_swap_candidates(:'e3_f1_cash') @> '[{"name": "Eli Nash"}]', 'swap candidates can answer in the app');
select pg_temp.expect_error(format('select offer_swap(%L, %L)', :'e3_f1_cash', '00000000-0000-0012-0000-00000000c0b1'),
  'a shift cannot be offered to another venue''s worker');
select pg_temp.expect((offer_swap(:'e3_f1_cash', '00000000-0000-0012-0000-00000000c004', 'Can you cover?')).status = 'offered',
  'a swap offer waits for the coworker');
select id as swap_id from shift_requests where kind = 'swap' \gset

select pg_temp.as_user('00000000-0000-0012-0000-000000000005'); -- Cara
select pg_temp.expect_error(format('select respond_swap(%L, true)', :'swap_id'), 'a coworker cannot accept someone else''s offer');
select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select pg_temp.expect_error(format('select decide_shift_request(%L, true)', :'swap_id'), 'a manager cannot approve before the coworker accepts');

select pg_temp.as_user('00000000-0000-0012-0000-000000000006'); -- Dev
select pg_temp.expect((select count(*) from shift_requests where id = :'swap_id') = 1, 'the swap target sees the offer');
select pg_temp.expect((select count(*) from jsonb_array_elements(my_shift_requests()) x where x ->> 'id' = :'swap_id'
  and x ->> 'requester_name' = 'Ana Reyes') = 1, 'the offer shows who made it');
select pg_temp.expect((respond_swap(:'swap_id', true)).status = 'pending', 'accepting sends the swap to a manager');
select pg_temp.as_user('00000000-0000-0012-0000-000000000001');
select pg_temp.expect((decide_shift_request(:'swap_id', true)).status = 'approved', 'the manager approves the swap');
select pg_temp.expect((select worker_id from shifts where id = :'e3_f1_cash') = '00000000-0000-0012-0000-00000000c004', 'the swap moves the shift to the coworker');
select pg_temp.expect((select count(*) from assignment_changes where shift_id = :'e3_f1_cash' and reason like 'Swap approved%') = 2,
  'the swap is logged as unassign and assign');
select pg_temp.as_owner();
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0012-0000-000000000006' and kind = 'shift_offered') = 1,
  'the coworker was notified of the offer');
select pg_temp.expect((select count(*) from notifications where user_id in ('00000000-0000-0012-0000-000000000003', '00000000-0000-0012-0000-000000000006')
  and kind = 'request_decided' and title = 'Swap approved') = 2, 'both people hear the swap was approved');

-- Declines and cancels.
select pg_temp.as_user('00000000-0000-0012-0000-000000000006'); -- Dev offers back to Ana; Ana declines
select offer_swap(:'e3_f1_cash', '00000000-0000-0012-0000-00000000c001');
select pg_temp.as_user('00000000-0000-0012-0000-000000000003');
select pg_temp.expect((respond_swap((select id from shift_requests where status = 'offered'), false)).status = 'denied', 'a coworker can decline an offer');
select pg_temp.as_user('00000000-0000-0012-0000-000000000005'); -- Cara
select request_pickup(:'e3_f2_cash');
select pg_temp.as_user('00000000-0000-0012-0000-000000000006');
select pg_temp.expect_error(format('select cancel_shift_request((select id from shift_requests where shift_id = %L limit 1))', :'e3_f2_cash'),
  'you cannot cancel someone else''s request');
select pg_temp.as_user('00000000-0000-0012-0000-000000000005');
select pg_temp.expect((cancel_shift_request((select id from shift_requests where shift_id = :'e3_f2_cash'))).status = 'cancelled',
  'the requester can cancel while pending');

-- ---- Pickups without approval -------------------------------------------------
select pg_temp.as_owner();
update venues set settings = settings || '{"self_service": {"pickups_need_approval": false}}' where id = '00000000-0000-0012-0000-00000000aa01';
select pg_temp.as_user('00000000-0000-0012-0000-000000000005');
select pg_temp.expect((request_pickup(:'e3_f2_cash')).status = 'approved', 'with approval off, a pickup is approved at once');
select pg_temp.as_owner();
select pg_temp.expect((select worker_id from shifts where id = :'e3_f2_cash') = '00000000-0000-0012-0000-00000000c003'
  and (select reason from assignment_changes where shift_id = :'e3_f2_cash') = 'Picked up by employee', 'and assigned, logged as picked up');
update venues set settings = settings || '{"self_service": {"allow_drops": false}}' where id = '00000000-0000-0012-0000-00000000aa01';
select pg_temp.as_user('00000000-0000-0012-0000-000000000005');
select pg_temp.expect_error(format('select request_drop(%L, ''x'')', :'e3_f2_cash'), 'drops can be turned off');

-- ---- Availability and blackouts -----------------------------------------------
select pg_temp.as_user('00000000-0000-0012-0000-000000000006'); -- Dev
select set_event_availability('00000000-0000-0012-0000-0000000e0002', 'unavailable', 'Exam');
select set_event_availability('00000000-0000-0012-0000-0000000e0003', 'available');
select pg_temp.expect_error($$select set_event_availability('00000000-0000-0012-0000-0000000e00b1', 'available')$$,
  'availability only for your own venue''s events');
select pg_temp.expect((select a ->> 'status' from jsonb_array_elements(my_availability() -> 'events') a
  where a -> 'event' ->> 'id' = '00000000-0000-0012-0000-0000000e0002') = 'unavailable', 'the employee sees their answer');
select pg_temp.as_user('00000000-0000-0012-0000-000000000004'); -- Ben
select set_blackout((now() + interval '10 hours')::date - 1, (now() + interval '10 hours')::date + 1, 'Band trip');
select pg_temp.expect_error($$select set_blackout(current_date + 5, current_date + 1)$$, 'a blackout must end after it starts');
select pg_temp.expect(jsonb_array_length(my_availability() -> 'blackouts') = 1, 'the blackout is listed');
select pg_temp.expect_error($$insert into event_availability (venue_id, event_id, worker_id, status) values
  ('00000000-0000-0012-0000-00000000aa01', '00000000-0000-0012-0000-0000000e0002', '00000000-0000-0012-0000-00000000c004', 'available')$$,
  'nobody writes availability directly');
select pg_temp.expect((select count(*) from event_availability) = 0, 'an employee does not see coworkers'' availability');
select pg_temp.as_user('00000000-0000-0012-0000-000000000006');
select pg_temp.expect_error($$select delete_blackout((select id from worker_blackouts limit 1))$$, 'you cannot delete someone else''s blackout');

select pg_temp.as_user('00000000-0000-0012-0000-000000000001'); -- manager A
select pg_temp.expect((select count(*) from event_availability) = 2 and (select count(*) from worker_blackouts) = 1,
  'the manager sees availability and blackouts');
select pg_temp.expect((select c ->> 'availability' from jsonb_array_elements(assignment_candidates('00000000-0000-0012-0000-0000000e0002', 'cashier')) c
  where c ->> 'id' = '00000000-0000-0012-0000-00000000c004') = 'unavailable', 'assignment candidates show who said unavailable');
select pg_temp.expect((select (c ->> 'blackout')::boolean from jsonb_array_elements(assignment_candidates('00000000-0000-0012-0000-0000000e0002', 'cashier')) c
  where c ->> 'id' = '00000000-0000-0012-0000-00000000c002'), 'assignment candidates show blackouts');
select pg_temp.expect((select bool_and(not (c ? 'date_of_birth')) from jsonb_array_elements(assignment_candidates('00000000-0000-0012-0000-0000000e0002', 'cashier')) c),
  'candidates still never include birth dates');
select pg_temp.as_user('00000000-0000-0012-0000-000000000002'); -- lead
select pg_temp.expect((select count(*) from event_availability) = 0, 'a storefront lead does not browse availability');
select pg_temp.expect((select count(*) from jsonb_array_elements(assignment_candidates('00000000-0000-0012-0000-0000000e0002', 'cashier')) c
  where c ->> 'availability' = 'unavailable') = 1, 'but sees it when filling a position');
select pg_temp.as_user('00000000-0000-0012-0000-000000000007'); -- manager B
select pg_temp.expect((select count(*) from event_availability) = 0 and (select count(*) from worker_blackouts) = 0,
  'manager B sees no venue A availability');

-- ---- Function access -------------------------------------------------------------
select pg_temp.as_owner();
select pg_temp.expect(not has_function_privilege('anon', 'public.request_pickup(uuid, text)', 'execute')
  and not has_function_privilege('anon', 'public.decide_shift_request(uuid, boolean, text, text[])', 'execute')
  and not has_function_privilege('authenticated', 'public.market_set_worker(uuid, uuid, text, text[])', 'execute')
  and not has_function_privilege('authenticated', 'public.notify_schedulers(uuid, text, text, text, jsonb)', 'execute')
  and has_function_privilege('authenticated', 'public.open_shifts_for_me()', 'execute'),
  'anonymous callers get nothing; internal helpers are not exposed');

rollback;

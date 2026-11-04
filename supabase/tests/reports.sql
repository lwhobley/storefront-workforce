-- Reports (0015 targets, 0024 budgets and seasons). Self-contained; everything rolls back.
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0000-0000-0000000230a1', 'Org R');
insert into venues (id, organization_id, name, time_zone) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-0000000230a1', 'Reports Arena A', 'America/Chicago'),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-0000000230a1', 'Reports Arena B', 'America/Chicago');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000002311'), -- concessions manager A (view_pay)
  ('00000000-0000-0000-0000-000000002312'), -- assistant manager A (reports, no pay)
  ('00000000-0000-0000-0000-000000002313'), -- employee A
  ('00000000-0000-0000-0000-000000002314'), -- admin A (manage_settings)
  ('00000000-0000-0000-0000-000000002315'); -- manager B
insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002311'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002312'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002313'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002314'),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-000000002315');
insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002311', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002312', 'assistant_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002313', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002314', 'admin', 'venue', null),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-000000002315', 'concessions_manager', 'venue', null);

insert into venue_levels (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000002301a1', '00000000-0000-0000-0000-00000023aa01', 'Main');
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0000-0000-000000230101', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-0000002301a1', '101', 'Stand 101');

select set_config('request.jwt.claim.role', 'service_role', true);
select seed_venue_job_defaults('00000000-0000-0000-0000-00000023aa01');
select seed_venue_job_defaults('00000000-0000-0000-0000-00000023bb01');
select set_config('request.jwt.claim.role', '', true);

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, user_id) values
  ('00000000-0000-0000-0000-00000023c001', '00000000-0000-0000-0000-00000023aa01', 'regular', 'E1', 'Ana', 'Reyes', '00000000-0000-0000-0000-000000002313'),
  ('00000000-0000-0000-0000-00000023c002', '00000000-0000-0000-0000-00000023aa01', 'regular', 'E2', 'Ben', 'Young', null);
insert into worker_job_roles (venue_id, worker_id, job_role_code) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-00000023c001', 'cashier'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-00000023c002', 'cashier');

-- Season boundary in venue time: e01 starts July 31 at 8 pm in Chicago (Aug 1 UTC), so it
-- is the 2025 season; e02 is Aug 1 local (2026 season); e03 is cancelled.
insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time, status, labor_budget) values
  ('00000000-0000-0000-0000-000000230e01', '00000000-0000-0000-0000-00000023aa01', 'July Game', 'hockey',
   '2026-08-01 01:00+00', '2026-08-01 00:00+00', '2026-07-31 22:30+00', '2026-08-01 04:00+00', 'completed', 4500.00),
  ('00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-00000023aa01', 'August Game', 'hockey',
   '2026-08-02 01:00+00', '2026-08-02 00:00+00', '2026-08-01 22:30+00', '2026-08-02 04:00+00', 'completed', null),
  ('00000000-0000-0000-0000-000000230e03', '00000000-0000-0000-0000-00000023aa01', 'Rained Out', 'hockey',
   '2026-08-03 01:00+00', '2026-08-03 00:00+00', '2026-08-02 22:30+00', '2026-08-03 04:00+00', 'cancelled', null);
insert into event_storefronts (venue_id, event_id, storefront_id, is_open, labor_budget) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230e01', '00000000-0000-0000-0000-000000230101', true, 1200.50),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-000000230101', true, null);
insert into shifts (id, venue_id, event_id, storefront_id, job_role_code, worker_id, call_time, status) values
  ('00000000-0000-0000-0000-0000002305a1', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230e01', '00000000-0000-0000-0000-000000230101', 'cashier', '00000000-0000-0000-0000-00000023c001', '2026-07-31 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000002305a2', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-000000230101', 'cashier', '00000000-0000-0000-0000-00000023c001', '2026-08-01 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000002305a3', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-000000230101', 'cashier', '00000000-0000-0000-0000-00000023c002', '2026-08-01 22:30+00', 'assigned');
insert into punches (id, venue_id, worker_id, event_id, shift_id, kind, occurred_at, source, status) values
  ('00000000-0000-0000-0000-0000002310f1', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-00000023c001', '00000000-0000-0000-0000-000000230e01', '00000000-0000-0000-0000-0000002305a1', 'clock_in', '2026-07-31 22:30+00', 'phone', 'accepted'),
  ('00000000-0000-0000-0000-0000002310f2', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-00000023c001', '00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-0000002305a2', 'clock_in', '2026-08-01 22:30+00', 'phone', 'accepted'),
  ('00000000-0000-0000-0000-0000002310f3', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-00000023c002', '00000000-0000-0000-0000-000000230e02', '00000000-0000-0000-0000-0000002305a3', 'clock_in', '2026-08-01 22:31+00', 'phone', 'voided');

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

-- ---- Labor budgets are pay information --------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002312');
select pg_temp.expect((select count(*) from events where venue_id = '00000000-0000-0000-0000-00000023aa01') = 3,
  'a manager without pay still reads events (listed columns)');
select pg_temp.expect((select name from events where id = '00000000-0000-0000-0000-000000230e01') = 'July Game',
  'event names, times and attendance stay readable');
select pg_temp.expect((select count(*) from event_storefronts where venue_id = '00000000-0000-0000-0000-00000023aa01' and is_open) = 2,
  'which storefronts are open stays readable');
select pg_temp.expect_error($$select labor_budget from events limit 1$$, 'events.labor_budget is not readable from the table');
select pg_temp.expect_error($$select * from events limit 1$$, 'select * on events is refused (the app lists columns)');
select pg_temp.expect_error($$select labor_budget from event_storefronts limit 1$$, 'event_storefronts.labor_budget is not readable from the table');
select pg_temp.expect_error($$select * from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')$$,
  'budgets need view_pay');
select pg_temp.expect(not ((event_board('00000000-0000-0000-0000-000000230e01') -> 'event') ? 'labor_budget'),
  'the live board leaves the event budget out');
select pg_temp.expect(not exists (select 1 from jsonb_array_elements(event_board('00000000-0000-0000-0000-000000230e01') -> 'event_storefronts') x
                                  where x ? 'labor_budget'),
  'the live board leaves storefront budgets out');
select pg_temp.expect((event_board('00000000-0000-0000-0000-000000230e01') -> 'event' ->> 'name') = 'July Game',
  'the live board still returns the event');

select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
select pg_temp.expect_error($$select labor_budget from events limit 1$$, 'an employee cannot read budgets either');
select pg_temp.expect((select count(*) from events where venue_id = '00000000-0000-0000-0000-00000023aa01') = 3,
  'an employee still sees the event calendar');

select pg_temp.as_user('00000000-0000-0000-0000-000000002311');
select pg_temp.expect((select labor_budget from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')
                       where event_id = '00000000-0000-0000-0000-000000230e01' and storefront_id is null) = 4500.00,
  'a pay viewer gets the event budget');
select pg_temp.expect((select labor_budget from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')
                       where storefront_id = '00000000-0000-0000-0000-000000230101') = 1200.50,
  'and storefront budgets');
select pg_temp.expect((select count(*) from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')) = 2,
  'events and storefronts with no budget are left out');
select pg_temp.expect((select count(*) from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-08-01 02:00+00', '2026-09-01')) = 0,
  'only events starting in the range');
update events set labor_budget = 5000 where id = '00000000-0000-0000-0000-000000230e01';
select pg_temp.expect((select labor_budget from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')
                       where storefront_id is null) = 5000,
  'a pay viewer can still set a budget');
select pg_temp.as_user('00000000-0000-0000-0000-000000002315');
select pg_temp.expect_error($$select * from report_labor_budgets('00000000-0000-0000-0000-00000023aa01', '2026-07-01', '2026-09-01')$$,
  'another venue''s manager gets no budgets');

-- ---- Seasons worked ------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002312');
select pg_temp.expect((select string_agg(season || ':' || events_worked, ',' order by season)
                       from report_worker_seasons('00000000-0000-0000-0000-00000023aa01')
                       where worker_id = '00000000-0000-0000-0000-00000023c001') = '2025:1,2026:1',
  'seasons split on August 1 in venue time');
select pg_temp.expect(not exists (select 1 from report_worker_seasons('00000000-0000-0000-0000-00000023aa01')
                                  where worker_id = '00000000-0000-0000-0000-00000023c002'),
  'a voided clock-in does not count as working');
select pg_temp.expect((select count(*) from report_worker_seasons('00000000-0000-0000-0000-00000023aa01', 1)
                       where worker_id = '00000000-0000-0000-0000-00000023c001' and season = 2026) = 1
                  and (select events_worked from report_worker_seasons('00000000-0000-0000-0000-00000023aa01', 1)
                       where worker_id = '00000000-0000-0000-0000-00000023c001') = 2,
  'a January season puts both games in 2026');
select pg_temp.expect_error($$select * from report_worker_seasons('00000000-0000-0000-0000-00000023aa01', 13)$$, 'the start month must be 1 to 12');
select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
select pg_temp.expect_error($$select * from report_worker_seasons('00000000-0000-0000-0000-00000023aa01')$$, 'seasons need view_reports');
select pg_temp.as_user('00000000-0000-0000-0000-000000002315');
select pg_temp.expect_error($$select * from report_worker_seasons('00000000-0000-0000-0000-00000023aa01')$$, 'not for another venue');

-- ---- Targets (0015) -------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000002314');
insert into report_targets (venue_id, fill_green, fill_yellow, attendance_green, attendance_yellow)
  values ('00000000-0000-0000-0000-00000023aa01', 0.97, 0.9, 0.93, 0.8);
select pg_temp.expect((select fill_green from report_targets where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0.97,
  'an admin (manage_settings) saves targets');
select pg_temp.expect_error($$update report_targets set fill_yellow = 0.99 where venue_id = '00000000-0000-0000-0000-00000023aa01'$$,
  'yellow above green is refused');
select pg_temp.as_user('00000000-0000-0000-0000-000000002312');
select pg_temp.expect((select attendance_green from report_targets where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0.93,
  'a report viewer reads the targets');
update report_targets set fill_green = 0.5 where venue_id = '00000000-0000-0000-0000-00000023aa01';
select pg_temp.as_owner();
select pg_temp.expect((select fill_green from report_targets where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0.97,
  'without manage_settings an update changes nothing');
select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
select pg_temp.expect(not exists (select 1 from report_targets), 'an employee sees no targets');

rollback;

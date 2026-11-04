-- Data retention and removing personal data (0023). Self-contained; everything rolls back.
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0000-0000-0000000230a1', 'Org R');
insert into venues (id, organization_id, name, time_zone) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-0000000230a1', 'Retention Arena', 'America/Chicago'),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-0000000230a1', 'Other Arena', 'America/Chicago');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000002311'), -- admin A
  ('00000000-0000-0000-0000-000000002312'), -- second admin A
  ('00000000-0000-0000-0000-000000002313'), -- manager A (manage_workers, no manage_settings)
  ('00000000-0000-0000-0000-000000002314'), -- employee A
  ('00000000-0000-0000-0000-000000002315'); -- admin of the other venue

insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002311'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002312'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002313'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002314'),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-000000002315');

insert into role_assignments (venue_id, user_id, role_code, scope_type) values
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002311', 'admin', 'venue'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002312', 'admin', 'venue'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002313', 'concessions_manager', 'venue'),
  ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000002314', 'employee', 'venue'),
  ('00000000-0000-0000-0000-00000023bb01', '00000000-0000-0000-0000-000000002315', 'admin', 'venue');

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, phone, email, date_of_birth, status)
values
  ('00000000-0000-0000-0000-000000230001', '00000000-0000-0000-0000-00000023aa01', 'regular', 'E9001',
   'Dana', 'Reyes', '555-0100', 'dana@example.com', date '1995-04-02', 'active'),
  ('00000000-0000-0000-0000-000000230002', '00000000-0000-0000-0000-00000023bb01', 'regular', 'E9002',
   'Sam', 'Cole', '555-0200', 'sam@example.com', date '1990-01-01', 'active');

-- Two punches with photos: one old enough to clear, one recent.
insert into punches (id, venue_id, worker_id, kind, occurred_at, photo_path) values
  ('00000000-0000-0000-0000-000000230101', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230001',
   'clock_in', now() - interval '20 months', 'photos/old.jpg'),
  ('00000000-0000-0000-0000-000000230102', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230001',
   'clock_in', now() - interval '2 months', 'photos/recent.jpg');

-- ---- Helpers ---------------------------------------------------------------
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

-- ---- Retention settings ----------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-000000002311');

-- Defaults apply with no row: four years for time records.
select pg_temp.expect((select count(*) from retention_policies where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0,
  'a venue starts with no saved retention row');

insert into retention_policies (venue_id, punch_photos_months) values ('00000000-0000-0000-0000-00000023aa01', 12);
select pg_temp.expect(
  (select time_records_months from retention_policies where venue_id = '00000000-0000-0000-0000-00000023aa01') = 48,
  'time records default to four years');

-- The floor is two years; a shorter period is refused by the check.
select pg_temp.expect_error(
  $$update retention_policies set time_records_months = 12 where venue_id = '00000000-0000-0000-0000-00000023aa01'$$,
  'wage and hour records cannot be kept less than two years');

select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
select pg_temp.expect_error(
  $$update retention_policies set punch_photos_months = 3 where venue_id = '00000000-0000-0000-0000-00000023aa01'$$,
  'a manager without manage_settings cannot change retention');

select pg_temp.as_user('00000000-0000-0000-0000-000000002315');
select pg_temp.expect(
  (select count(*) from retention_policies where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0,
  'another venue cannot read these retention settings');

-- ---- What is past its period, and clearing photos ---------------------------

select pg_temp.as_user('00000000-0000-0000-0000-000000002311');
select pg_temp.expect(
  (retention_due('00000000-0000-0000-0000-00000023aa01') ->> 'punch_photos')::int = 1,
  'one clock-in photo is past the twelve-month period');

select pg_temp.expect(purge_old_punch_photos('00000000-0000-0000-0000-00000023aa01') = 1, 'one photo is cleared');
select pg_temp.expect(
  (select count(*) from punches where venue_id = '00000000-0000-0000-0000-00000023aa01') = 2,
  'the clock-in times stay; only the photos go');
select pg_temp.expect(
  (select photo_path from punches where id = '00000000-0000-0000-0000-000000230102') = 'photos/recent.jpg',
  'a recent photo is left alone');

select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
select pg_temp.expect_error($$select purge_old_punch_photos('00000000-0000-0000-0000-00000023aa01')$$,
  'only an admin clears photos');

-- ---- Removing personal data -------------------------------------------------

select pg_temp.as_user('00000000-0000-0000-0000-000000002313');
insert into data_deletion_requests (id, venue_id, worker_id, note) values
  ('00000000-0000-0000-0000-000000230201', '00000000-0000-0000-0000-00000023aa01',
   '00000000-0000-0000-0000-000000230001', 'Asked by email');

select pg_temp.expect_error($$select anonymize_worker('00000000-0000-0000-0000-000000230201')$$,
  'a manager without manage_settings cannot approve');

select pg_temp.as_user('00000000-0000-0000-0000-000000002314');
select pg_temp.expect(
  (select count(*) from data_deletion_requests where venue_id = '00000000-0000-0000-0000-00000023aa01') = 0,
  'an employee cannot see deletion requests');

-- Whoever asked cannot approve their own request.
select pg_temp.as_user('00000000-0000-0000-0000-000000002311');
insert into data_deletion_requests (id, venue_id, worker_id) values
  ('00000000-0000-0000-0000-000000230202', '00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230001');
select pg_temp.expect_error($$select anonymize_worker('00000000-0000-0000-0000-000000230202')$$,
  'nobody approves their own deletion request');

-- A different admin carries out the first request.
select pg_temp.as_user('00000000-0000-0000-0000-000000002312');
select anonymize_worker('00000000-0000-0000-0000-000000230201', 'Verified by phone');

select pg_temp.expect(
  (select first_name = 'Removed' and last_name = 'Record' and phone = '' and email = ''
          and date_of_birth is null and photo_path is null and user_id is null and status = 'inactive'
     from workers where id = '00000000-0000-0000-0000-000000230001'),
  'the personal details are gone');
select pg_temp.expect(
  (select employee_number like 'REMOVED-%' from workers where id = '00000000-0000-0000-0000-000000230001'),
  'the employee number is replaced, so payroll exports stay unique');
select pg_temp.expect(
  (select count(*) from punches where worker_id = '00000000-0000-0000-0000-000000230001') = 2,
  'the hours are kept for payroll');
select pg_temp.expect(
  (select status = 'completed' and decision_note = 'Verified by phone'
     from data_deletion_requests where id = '00000000-0000-0000-0000-000000230201'),
  'the request is recorded as completed');
select pg_temp.expect(
  (select count(*) from audit_logs where entity = 'worker' and action = 'anonymized'
     and entity_id = '00000000-0000-0000-0000-000000230001') = 1,
  'the removal is in the audit log');

-- A request that is already decided cannot be decided again.
select pg_temp.expect_error($$select anonymize_worker('00000000-0000-0000-0000-000000230201')$$,
  'a completed request cannot be carried out twice');

-- Refusing needs a reason.
select pg_temp.expect_error($$select refuse_deletion_request('00000000-0000-0000-0000-000000230202', '  ')$$,
  'refusing needs a reason');
select refuse_deletion_request('00000000-0000-0000-0000-000000230202', 'Still inside the retention period');
select pg_temp.expect(
  (select status = 'refused' from data_deletion_requests where id = '00000000-0000-0000-0000-000000230202'),
  'the request is recorded as refused');

-- Another venue's admin cannot touch this venue's people.
select pg_temp.as_user('00000000-0000-0000-0000-000000002315');
select pg_temp.expect_error(
  $$insert into data_deletion_requests (venue_id, worker_id) values
      ('00000000-0000-0000-0000-00000023aa01', '00000000-0000-0000-0000-000000230001')$$,
  'another venue cannot ask for a deletion here');

select pg_temp.as_owner();
rollback;

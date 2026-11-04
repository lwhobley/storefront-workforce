-- Onboarding and partner portals (0014). Self-contained; everything rolls back.
begin;

-- ---- Fixtures (as the platform owner) --------------------------------------
insert into organizations (id, name) values ('00000000-0000-0000-0000-0000000140a1', 'Org P');
insert into venues (id, organization_id, name, time_zone) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-0000000140a1', 'People Arena A', 'America/Chicago'),
  ('00000000-0000-0000-0000-00000014bb01', '00000000-0000-0000-0000-0000000140a1', 'People Arena B', 'America/Chicago');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-000000001411'), -- manager A
  ('00000000-0000-0000-0000-000000001412'), -- employee A (W1, cashier + bartender)
  ('00000000-0000-0000-0000-000000001413'), -- employee A (W2, cashier)
  ('00000000-0000-0000-0000-000000001414'), -- NPO coordinator, group G1
  ('00000000-0000-0000-0000-000000001415'), -- agency contact, agency AG1
  ('00000000-0000-0000-0000-000000001416'), -- manager B
  ('00000000-0000-0000-0000-000000001417'); -- NPO volunteer W5 (a minor)

insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001411'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001412'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001413'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001414'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001415'),
  ('00000000-0000-0000-0000-00000014bb01', '00000000-0000-0000-0000-000000001416'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001417');

insert into venue_levels (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000001401a1', '00000000-0000-0000-0000-00000014aa01', 'Main');
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0000-0000-000000140101', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-0000001401a1', '101', 'Stand 101');

select set_config('request.jwt.claim.role', 'service_role', true);
select seed_venue_job_defaults('00000000-0000-0000-0000-00000014aa01');
select seed_venue_job_defaults('00000000-0000-0000-0000-00000014bb01');
select set_config('request.jwt.claim.role', '', true);

insert into temp_agencies (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000001414c1', '00000000-0000-0000-0000-00000014aa01', 'Agency One'),
  ('00000000-0000-0000-0000-0000001414c2', '00000000-0000-0000-0000-00000014aa01', 'Agency Two');
insert into npo_groups (id, venue_id, legal_name, display_name) values
  ('00000000-0000-0000-0000-0000001414d1', '00000000-0000-0000-0000-00000014aa01', 'Band Boosters Inc.', 'Band Boosters'),
  ('00000000-0000-0000-0000-0000001414d2', '00000000-0000-0000-0000-00000014aa01', 'Swim Club Inc.', 'Swim Club');

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001411', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001412', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001413', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001414', 'npo_coordinator', 'npo_group', '00000000-0000-0000-0000-0000001414d1'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001415', 'agency_contact', 'agency', '00000000-0000-0000-0000-0000001414c1'),
  ('00000000-0000-0000-0000-00000014bb01', '00000000-0000-0000-0000-000000001416', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000001417', 'employee', 'venue', null);

insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, preferred_name, date_of_birth,
                     phone, user_id, agency_id, npo_group_id, paycom_employee_code) values
  ('00000000-0000-0000-0000-00000014c001', '00000000-0000-0000-0000-00000014aa01', 'regular', 'E1001', 'Ana', 'Reyes', 'Annie', '1995-04-02', '', '00000000-0000-0000-0000-000000001412', null, null, 'PC-1'),
  ('00000000-0000-0000-0000-00000014c002', '00000000-0000-0000-0000-00000014aa01', 'regular', 'E1002', 'Ben', 'Young', '', '1990-06-01', '', '00000000-0000-0000-0000-000000001413', null, null, 'PC-2'),
  ('00000000-0000-0000-0000-00000014c003', '00000000-0000-0000-0000-00000014aa01', 'temp', 'T2001', 'Cara', 'Diaz', '', '1990-01-01', '555-0103', null, '00000000-0000-0000-0000-0000001414c1', null, ''),
  ('00000000-0000-0000-0000-00000014c004', '00000000-0000-0000-0000-00000014aa01', 'temp', 'T2002', 'Dan', 'Ortiz', '', '1991-01-01', '555-0104', null, '00000000-0000-0000-0000-0000001414c2', null, ''),
  ('00000000-0000-0000-0000-00000014c005', '00000000-0000-0000-0000-00000014aa01', 'npo', 'N3001', 'Eve', 'Park', '', '2010-03-03', '555-0105', '00000000-0000-0000-0000-000000001417', null, '00000000-0000-0000-0000-0000001414d1', ''),
  ('00000000-0000-0000-0000-00000014c006', '00000000-0000-0000-0000-00000014aa01', 'npo', 'N3002', 'Fay', 'Lee', '', '1980-01-01', '555-0106', null, null, '00000000-0000-0000-0000-0000001414d2', ''),
  ('00000000-0000-0000-0000-00000014c0b1', '00000000-0000-0000-0000-00000014bb01', 'regular', 'E1001', 'Zed', 'Other', '', '1990-01-01', '', null, null, null, '');
insert into worker_job_roles (venue_id, worker_id, job_role_code) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c001', 'cashier'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c001', 'bartender'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c002', 'cashier'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c003', 'cashier'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c004', 'cook'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c005', 'cashier'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c006', 'cashier');

insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time, status) values
  ('00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-00000014aa01', 'Past Game', 'hockey',
   '2026-10-10 01:00+00', '2026-10-10 00:00+00', '2026-10-09 22:30+00', '2026-10-10 04:00+00', 'completed'),
  ('00000000-0000-0000-0000-000000140e02', '00000000-0000-0000-0000-00000014aa01', 'Next Game', 'hockey',
   now() + interval '3 days', now() + interval '3 days' - interval '1 hour', now() + interval '3 days' - interval '150 minutes', null, 'scheduled');
insert into shifts (id, venue_id, event_id, storefront_id, job_role_code, worker_id, call_time, status) values
  ('00000000-0000-0000-0000-0000001405a1', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-000000140101', 'cashier', '00000000-0000-0000-0000-00000014c003', '2026-10-09 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000001405a2', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-000000140101', 'cook', '00000000-0000-0000-0000-00000014c004', '2026-10-09 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000001405a3', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-000000140101', 'cashier', '00000000-0000-0000-0000-00000014c005', '2026-10-09 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000001405a4', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-000000140101', 'cashier', '00000000-0000-0000-0000-00000014c006', '2026-10-09 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000001405b1', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e02', '00000000-0000-0000-0000-000000140101', 'cashier', '00000000-0000-0000-0000-00000014c003', now() + interval '3 days' - interval '150 minutes', 'assigned'),
  ('00000000-0000-0000-0000-0000001405b2', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e02', '00000000-0000-0000-0000-000000140101', 'cashier', '00000000-0000-0000-0000-00000014c005', now() + interval '3 days' - interval '150 minutes', 'assigned');
insert into punches (id, venue_id, worker_id, event_id, shift_id, kind, occurred_at, source, latitude, longitude, photo_path) values
  ('00000000-0000-0000-0000-0000001410f1', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c003', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a1', 'clock_in', '2026-10-09 22:30+00', 'phone', 30.1, -97.1, 'secret/photo.jpg'),
  ('00000000-0000-0000-0000-0000001410f2', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c003', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a1', 'clock_out', '2026-10-10 04:30+00', 'phone', null, null, null),
  ('00000000-0000-0000-0000-0000001410f3', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c004', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a2', 'clock_in', '2026-10-09 22:30+00', 'phone', null, null, null),
  ('00000000-0000-0000-0000-0000001410f4', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c005', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a3', 'clock_in', '2026-10-09 22:30+00', 'kiosk', null, null, null),
  ('00000000-0000-0000-0000-0000001410f5', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c005', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a3', 'clock_out', '2026-10-10 03:00+00', 'kiosk', null, null, null),
  ('00000000-0000-0000-0000-0000001410f6', '00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-00000014c006', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001405a4', 'clock_in', '2026-10-09 22:30+00', 'kiosk', null, null, null);

insert into pay_rates (venue_id, job_role_code, hourly_rate, effective_from) values
  ('00000000-0000-0000-0000-00000014aa01', 'cashier', 13.37, '2026-01-01');
insert into agency_bill_rates (venue_id, agency_id, job_role_code, bill_rate, effective_from) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-0000001414c1', 'cashier', 22.50, '2026-01-01'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-0000001414c2', 'cook', 25.75, '2026-01-01');
insert into npo_payouts (venue_id, event_id, npo_group_id, members_scheduled, members_worked, hours, hourly_rate, gross, total, status, paid_at, payment_reference) values
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001414d1', 1, 1, 4.50, 10.00, 45.00, 45.00, 'paid', now(), 'CHK-1001'),
  ('00000000-0000-0000-0000-00000014aa01', '00000000-0000-0000-0000-000000140e01', '00000000-0000-0000-0000-0000001414d2', 1, 1, 6.00, 10.00, 60.00, 60.00, 'pending', null, '');

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
-- Status of one step in an onboarding state.
create or replace function pg_temp.step(st jsonb, code text) returns jsonb language sql as $$
  select x from jsonb_array_elements(st -> 'steps') x where x ->> 'code' = code;
$$;
create or replace function pg_temp.codes(st jsonb) returns text language sql as $$
  select string_agg(x ->> 'code', ',' order by (x ->> 'sort')::int) from jsonb_array_elements(st -> 'steps') x;
$$;

-- ---- Defaults ---------------------------------------------------------------
select pg_temp.expect((select count(*) from onboarding_steps where venue_id = '00000000-0000-0000-0000-00000014aa01') = 7,
  'a new venue gets the seven default onboarding steps');
select pg_temp.expect((select count(*) from onboarding_steps where venue_id = '00000000-0000-0000-0000-00000014bb01') = 7,
  'every venue gets its own copy');
select pg_temp.expect((select string_agg(code, ',' order by sort) from onboarding_steps
   where venue_id = '00000000-0000-0000-0000-00000014aa01' and 'regular' = any (applies_to)) = 'application,policies,certifications,training,paycom',
  'regular staff: application, policies, cards, training, Paycom');
select pg_temp.expect((select string_agg(code, ',' order by sort) from onboarding_steps
   where venue_id = '00000000-0000-0000-0000-00000014aa01' and 'temp' = any (applies_to)) = 'policies,certifications,training',
  'temps: policies, cards, training');
select pg_temp.expect((select string_agg(code, ',' order by sort) from onboarding_steps
   where venue_id = '00000000-0000-0000-0000-00000014aa01' and 'npo' = any (applies_to)) = 'waiver,age_confirmation,certifications,training',
  'NPO volunteers: waiver, age, cards (only if their roles need one), training; no payroll steps');
select pg_temp.expect((select count(*) from onboarding_documents where venue_id = '00000000-0000-0000-0000-00000014aa01' and not active) = 3,
  'starting documents are inactive drafts');

-- ---- Documents: managers edit, employees read ----------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001412');
update onboarding_documents set active = true where venue_id = '00000000-0000-0000-0000-00000014aa01';
select pg_temp.expect((select count(*) from onboarding_documents where active) = 0, 'an employee cannot turn on documents');
select pg_temp.as_user('00000000-0000-0000-0000-000000001411');
update onboarding_documents set active = true, body = 'Be on time. Wear your badge.' where venue_id = '00000000-0000-0000-0000-00000014aa01';
select pg_temp.expect((select count(*) from onboarding_documents where active and version = 2) = 3, 'manager turns documents on; new text raises the version');

-- ---- The employee's own checklist -------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001412');
select pg_temp.expect(pg_temp.codes(my_onboarding()) = 'application,policies,certifications,training,paycom',
  'a bartender sees application, policies, cards, training, Paycom');
select pg_temp.expect((my_onboarding() ->> 'percent')::int = 0 and (my_onboarding() ->> 'required')::int = 5, 'nothing done yet: 0 of 5');
select pg_temp.expect((pg_temp.step(my_onboarding(), 'certifications') -> 'missing_certs') = '["tabc"]', 'cards needed by trained roles: TABC');
select pg_temp.expect(jsonb_array_length(pg_temp.step(my_onboarding(), 'training') -> 'items') = 4, 'bartenders get the alcohol service item');

select submit_onboarding_step('application', jsonb_build_object(
  'address', '12 Elm St', 'phone', '555-0101', 'email', 'ana@example.com',
  'emergency_contact_name', 'Rosa Reyes', 'emergency_contact_phone', '555-0199', 'uniform_size', 'M',
  'preferred_language', 'es', 'notes', 'Prefers weekends',
  'worker_type', 'temp', 'paycom_employee_code', 'HACK', 'employee_number', 'X9', 'hourly_rate', 99));
select pg_temp.expect((pg_temp.step(my_onboarding(), 'application') ->> 'status') = 'complete', 'application submitted is complete');
select pg_temp.as_owner();
select pg_temp.expect((select phone = '555-0101' and emergency_contact_name = 'Rosa Reyes' and uniform_size = 'M' and preferred_language = 'es'
   from workers where id = '00000000-0000-0000-0000-00000014c001'), 'application answers update the contact fields');
select pg_temp.expect((select worker_type = 'regular' and paycom_employee_code = 'PC-1' and employee_number = 'E1001'
   from workers where id = '00000000-0000-0000-0000-00000014c001'), 'type, Paycom code and number are untouched');
select pg_temp.expect((select not (data ? 'paycom_employee_code') and not (data ? 'hourly_rate') and data ->> 'address' = '12 Elm St'
   from onboarding_progress where worker_id = '00000000-0000-0000-0000-00000014c001' and step_code = 'application'),
  'only the allowed answers are stored');

select pg_temp.as_user('00000000-0000-0000-0000-000000001412');
select pg_temp.expect_error($$select submit_onboarding_step('paycom', '{}')$$, 'an employee cannot mark Paycom done');
select pg_temp.expect_error($$select submit_onboarding_step('training', '{"items": ["cash_handling"]}')$$, 'an employee cannot tick their own training');
select pg_temp.expect_error($$select submit_onboarding_step('application', '{"phone": "", "emergency_contact_name": "x", "emergency_contact_phone": "1"}')$$,
  'the application needs a phone');
select pg_temp.expect_error(format($$select submit_onboarding_step('policies', jsonb_build_object('acknowledgments', jsonb_build_array(
  jsonb_build_object('document_id', %L, 'typed_name', 'Someone Else'))))$$,
  (select id from onboarding_documents where title = 'Employee handbook acknowledgment' and venue_id = '00000000-0000-0000-0000-00000014aa01')),
  'a typed name must match the person');
select submit_onboarding_step('policies', jsonb_build_object('acknowledgments', (
  select jsonb_agg(jsonb_build_object('document_id', id, 'typed_name', '  annie   REYES ')) from onboarding_documents
   where venue_id = '00000000-0000-0000-0000-00000014aa01' and step_code = 'policies')));
select pg_temp.expect((pg_temp.step(my_onboarding(), 'policies') ->> 'status') = 'complete', 'both policies acknowledged with the preferred name');

-- Card upload
select pg_temp.expect_error($$select submit_onboarding_step('certifications', '{"certs": [{"cert_type_code": "tabc", "file_path": "00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/x.jpg"}]}',
  array['00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/x.jpg'])$$, 'uploads go only to your own folder');
insert into storage.objects (bucket_id, name) values ('onboarding-docs', '00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c001/tabc.jpg');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('onboarding-docs', '00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/tabc.jpg')$$,
  'storage refuses a file in someone else''s folder');
select pg_temp.expect_error($$select submit_onboarding_step('certifications', '{"certs": [{"cert_type_code": "tabc", "expires_on": "2020-01-01", "file_path": "00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c001/tabc.jpg"}]}',
  array['00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c001/tabc.jpg'])$$, 'an expired card is refused');
select submit_onboarding_step('certifications', jsonb_build_object('certs', jsonb_build_array(jsonb_build_object(
  'cert_type_code', 'tabc', 'number', 'TABC-1234567', 'expires_on', (current_date + 500)::text,
  'file_path', '00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c001/tabc.jpg'))),
  array['00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c001/tabc.jpg']);
select pg_temp.expect((select count(*) from worker_certifications where cert_type_code = 'tabc' and verified_by is null
   and document_path like '%/tabc.jpg') = 1, 'a card upload creates an unverified certification');
select pg_temp.expect((pg_temp.step(my_onboarding(), 'certifications') ->> 'status') = 'submitted'
   and (my_onboarding() ->> 'needs_review')::boolean, 'the upload waits for a manager');
select pg_temp.expect((select count(*) from onboarding_progress) = 3, 'the employee reads only their own progress');
select pg_temp.as_owner();
select pg_temp.expect(not (rules_worker_json('00000000-0000-0000-0000-00000014c001', current_date) -> 'certifications' @> '[{"cert_type_code": "tabc"}]'),
  'an unverified card upload does not count for scheduling');

-- ---- Another employee cannot read it ----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001413');
select pg_temp.expect((select count(*) from onboarding_progress) = 0, 'another employee sees none of it');
select pg_temp.expect_error($$select worker_onboarding('00000000-0000-0000-0000-00000014c001')$$, 'another employee cannot open their checklist');
select pg_temp.expect_error($$select onboarding_overview('00000000-0000-0000-0000-00000014aa01')$$, 'an employee cannot see the overview');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'onboarding-docs') = 0, 'nor their uploaded card');
select pg_temp.expect_error($$select review_onboarding_step('00000000-0000-0000-0000-00000014c001', 'certifications', true)$$,
  'an employee cannot approve');

-- ---- Venue isolation ----------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001416');
select pg_temp.expect_error($$select worker_onboarding('00000000-0000-0000-0000-00000014c001')$$, 'manager B cannot open a venue A checklist');
select pg_temp.expect_error($$select onboarding_overview('00000000-0000-0000-0000-00000014aa01')$$, 'manager B cannot see venue A onboarding');
select pg_temp.expect_error($$select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'paycom', '{}')$$, 'manager B cannot complete venue A steps');
select pg_temp.expect((select count(*) from onboarding_progress) = 0 and (select count(*) from onboarding_documents) = 3,
  'manager B sees only venue B rows');

-- ---- Manager review and completion -------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001411');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'onboarding-docs') = 1, 'the manager can open the uploaded card');
select pg_temp.expect((pg_temp.step(worker_onboarding('00000000-0000-0000-0000-00000014c001'), 'application') -> 'data' ->> 'address') = '12 Elm St',
  'the manager sees the answers');
select review_onboarding_step('00000000-0000-0000-0000-00000014c001', 'certifications', true, '');
select pg_temp.expect((select verified_by = '00000000-0000-0000-0000-000000001411' from worker_certifications where cert_type_code = 'tabc'
   and worker_id = '00000000-0000-0000-0000-00000014c001'), 'approving verifies the card');
select pg_temp.as_owner();
select pg_temp.expect(rules_worker_json('00000000-0000-0000-0000-00000014c001', current_date) -> 'certifications' @> '[{"cert_type_code": "tabc"}]',
  'once verified, the card counts for scheduling');
select pg_temp.as_user('00000000-0000-0000-0000-000000001411');
select pg_temp.expect((pg_temp.step(worker_onboarding('00000000-0000-0000-0000-00000014c001'), 'certifications') ->> 'done')::boolean,
  'the card step is done');
select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'training', '{"items": ["cash_handling", "emergency_exits"]}');
select pg_temp.expect((pg_temp.step(worker_onboarding('00000000-0000-0000-0000-00000014c001'), 'training') ->> 'items_done')::int = 2
   and not (pg_temp.step(worker_onboarding('00000000-0000-0000-0000-00000014c001'), 'training') ->> 'done')::boolean, 'two of four training items');
select pg_temp.expect_error($$select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'training', '{"items": ["juggling"]}')$$,
  'unknown training items are refused');
select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'training', '{"items": ["cash_handling", "emergency_exits", "food_safety", "alcohol_service"]}');
select pg_temp.expect_error($$select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'paycom', jsonb_build_object('completed_on', (current_date + 5)::text))$$,
  'Paycom cannot be marked done in the future');
select complete_onboarding_step('00000000-0000-0000-0000-00000014c001', 'paycom', jsonb_build_object('completed_on', current_date::text));
select pg_temp.expect((select (x ->> 'percent')::int = 100 and (x ->> 'finished_at') is not null and jsonb_array_length(x -> 'missing') = 0
   from jsonb_array_elements(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) x where x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c001'),
  'overview: Ana is 100% and finished');
select complete_onboarding_step('00000000-0000-0000-0000-00000014c002', 'paycom', '{}');
select pg_temp.expect((select (x ->> 'percent')::int = 25 and (x ->> 'required')::int = 4 and (x ->> 'finished_at') is null
   from jsonb_array_elements(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) x where x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c002'),
  'overview: a cashier needs 4 steps (no card) and is 25% after Paycom');
select pg_temp.expect((select (x ->> 'percent')::int = 0 and (x ->> 'required')::int = 2 and x -> 'missing' = '["Policies", "Training"]'
   from jsonb_array_elements(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) x where x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c003'),
  'overview: a temp cashier needs policies and training, nothing for cards');
select pg_temp.expect((select (x ->> 'required')::int = 3 and (x ->> 'done')::int = 1
   from jsonb_array_elements(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) x where x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c005'),
  'overview: an NPO volunteer with a birth date on file has the age step done');
select pg_temp.expect(jsonb_array_length(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) = 6, 'overview lists venue A''s six people');
select pg_temp.expect_error($$select send_onboarding_reminder('00000000-0000-0000-0000-00000014c001')$$, 'no reminder once finished');
select pg_temp.expect_error($$select send_onboarding_reminder('00000000-0000-0000-0000-00000014c003')$$, 'no reminder without a sign-in');
select send_onboarding_reminder('00000000-0000-0000-0000-00000014c002');
update onboarding_documents set body = 'Be on time. Wear your badge. New: no phones at the register.'
 where title = 'Employee handbook acknowledgment' and venue_id = '00000000-0000-0000-0000-00000014aa01';
select pg_temp.expect((select (x ->> 'finished_at') is null and x -> 'missing' = '["Policies"]' and (x ->> 'days_open')::int = 0
   from jsonb_array_elements(onboarding_overview('00000000-0000-0000-0000-00000014aa01')) x where x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c001'),
  'changing a document reopens it for people who signed the old text, counted from the change');

-- Sending a card back
select pg_temp.as_user('00000000-0000-0000-0000-000000001413');
insert into storage.objects (bucket_id, name) values ('onboarding-docs', '00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/fh.jpg');
select submit_onboarding_step('certifications', '{"certs": [{"cert_type_code": "food_handler", "file_path": "00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/fh.jpg"}]}',
  array['00000000-0000-0000-0000-00000014aa01/00000000-0000-0000-0000-00000014c002/fh.jpg']) is null;
select pg_temp.expect((select count(*) from notifications where kind = 'onboarding_reminder') = 1, 'the reminder reached Ben');
select pg_temp.as_user('00000000-0000-0000-0000-000000001411');
select pg_temp.expect_error($$select review_onboarding_step('00000000-0000-0000-0000-00000014c002', 'certifications', false, '  ')$$,
  'sending back needs a note');
select review_onboarding_step('00000000-0000-0000-0000-00000014c002', 'certifications', false, 'Photo is blurry');
select pg_temp.as_owner();
select pg_temp.expect((select status = 'needs_changes' and note = 'Photo is blurry' from onboarding_progress
   where worker_id = '00000000-0000-0000-0000-00000014c002' and step_code = 'certifications'), 'step marked needs changes with the note');
select pg_temp.expect((select count(*) from worker_certifications where worker_id = '00000000-0000-0000-0000-00000014c002') = 0,
  'the sent-back card is removed');
select pg_temp.expect((select count(*) from notifications where user_id = '00000000-0000-0000-0000-000000001413' and kind = 'onboarding_review') = 1,
  'Ben is told what to fix');

-- ---- NPO waiver: a minor needs a guardian ----------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001417');
select pg_temp.expect((pg_temp.step(my_onboarding(), 'waiver') ->> 'guardian_required')::boolean, 'a 16-year-old volunteer needs a guardian on the waiver');
select pg_temp.expect_error(format($$select submit_onboarding_step('waiver', jsonb_build_object('acknowledgments', jsonb_build_array(
  jsonb_build_object('document_id', %L, 'typed_name', 'Eve Park'))))$$,
  (select id from onboarding_documents where step_code = 'waiver' and venue_id = '00000000-0000-0000-0000-00000014aa01')),
  'a minor cannot sign the waiver alone');
select submit_onboarding_step('waiver', jsonb_build_object('acknowledgments', jsonb_build_array(jsonb_build_object(
  'document_id', (select id from onboarding_documents where step_code = 'waiver' and venue_id = '00000000-0000-0000-0000-00000014aa01'),
  'typed_name', 'Eve Park', 'guardian_name', 'Grace Park'))));
select pg_temp.expect((pg_temp.step(my_onboarding(), 'waiver') ->> 'status') = 'complete', 'waiver signed with a guardian');
select pg_temp.expect((pg_temp.step(my_onboarding(), 'waiver') -> 'data' -> 'acknowledgments' -> 0 ->> 'guardian_name') = 'Grace Park',
  'the guardian''s typed name is kept with a time');

-- ---- NPO coordinator portal --------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001414');
create temp table npo as select npo_portal('2026-08-01', current_date + 30) as r;
grant select on npo to authenticated;
select pg_temp.expect((select jsonb_array_length(r -> 'members') = 1 and r -> 'members' -> 0 ->> 'employee_number' = 'N3001' from npo),
  'coordinator sees only their group''s members');
select pg_temp.expect((select (r -> 'members' -> 0 ->> 'minor')::boolean and r -> 'members' -> 0 ->> 'waiver_status' = 'complete' from npo),
  'members show a minor flag and waiver status');
select pg_temp.expect((select position('date_of_birth' in r::text) = 0 and position('1980-01-01' in r::text) = 0
   and position('2010-03-03' in r::text) = 0 and position('emergency' in r::text) = 0 from npo), 'no birth dates or emergency contacts');
select pg_temp.expect((select position('13.37' in r::text) = 0 and position('latitude' in r::text) = 0 and position('photo' in r::text) = 0 from npo),
  'no wages, GPS or photos');
select pg_temp.expect((select jsonb_array_length(r -> 'payouts') = 1 and r -> 'payouts' -> 0 ->> 'payment_reference' = 'CHK-1001'
   and (r -> 'season' ->> 'paid')::numeric = 45 from npo), 'their payouts and season totals only');
select pg_temp.expect((select bool_and(x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c005') and count(*) = 2
   from npo, jsonb_array_elements(r -> 'punches') x), 'time records of their members only');
select pg_temp.expect((select count(*) = 2 from npo, jsonb_array_elements(r -> 'shifts') x), 'past and upcoming shifts of their members');
select pg_temp.expect_error($$select npo_portal('2026-08-01', current_date, '00000000-0000-0000-0000-0000001414d2')$$, 'another group is refused');
select pg_temp.expect_error($$select agency_portal('2026-08-01', current_date)$$, 'a coordinator has no agency portal');
select pg_temp.expect((select count(*) from workers) = 0, 'a coordinator cannot read staff records directly (birth dates stay hidden)');

-- ---- Agency contact portal -----------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-000000001415');
create temp table ag as select agency_portal('2026-08-01', current_date + 30) as r;
grant select on ag to authenticated;
select pg_temp.expect((select jsonb_array_length(r -> 'members') = 1 and r -> 'members' -> 0 ->> 'employee_number' = 'T2001' from ag),
  'agency contact sees only their placed temps');
select pg_temp.expect((select jsonb_array_length(r -> 'bill_rates') = 1 and (r -> 'bill_rates' -> 0 ->> 'bill_rate')::numeric = 22.50 from ag),
  'and only their own bill rates');
select pg_temp.expect((select position('13.37' in r::text) = 0 and position('25.75' in r::text) = 0 and position('555-0103' in r::text) = 0
   and position('1990-01-01' in r::text) = 0 from ag), 'no venue pay rates, other agencies'' rates, phones or birth dates');
select pg_temp.expect((select count(*) = 2 and bool_and(x ->> 'worker_id' = '00000000-0000-0000-0000-00000014c003')
   from ag, jsonb_array_elements(r -> 'punches') x), 'time records of their temps only');
select pg_temp.expect((select count(*) = 1 from ag, jsonb_array_elements(r -> 'events') x where x ->> 'name' = 'Past Game'), 'events their temps worked');
select pg_temp.expect_error($$select npo_portal('2026-08-01', current_date)$$, 'an agency contact has no NPO portal');
select pg_temp.expect_error($$select agency_portal('2026-08-01', current_date, '00000000-0000-0000-0000-0000001414c2')$$, 'another agency is refused');

select pg_temp.as_user('00000000-0000-0000-0000-000000001412');
select pg_temp.expect_error($$select npo_portal('2026-08-01', current_date)$$, 'an employee has no partner portal');
select pg_temp.expect_error($$select onboarding_state('00000000-0000-0000-0000-00000014c002')$$, 'the internal state function is not callable');

rollback;

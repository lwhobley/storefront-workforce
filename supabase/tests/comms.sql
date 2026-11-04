-- Communication: message visibility by audience, who may send, read marks, announcements
-- and acknowledgments, preferences, push tokens, scheduled reminders, and delivery claims.
-- Self-contained; everything rolls back.
begin;

-- ---- Fixtures ---------------------------------------------------------------
insert into organizations (id, name) values
  ('00000000-0000-0000-0000-00000000c0a1', 'Comms Org A'),
  ('00000000-0000-0000-0000-00000000c0b1', 'Comms Org B');
insert into venues (id, organization_id, name, time_zone, settings) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-00000000c0a1', 'Comms Arena A', 'America/Chicago', '{}'),
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-00000000c0b1', 'Comms Arena B', 'America/Chicago', '{}');

insert into auth.users (id) values
  ('00000000-0000-0000-0000-0000000c0001'), -- manager A (venue)
  ('00000000-0000-0000-0000-0000000c0002'), -- lead A, storefront 101
  ('00000000-0000-0000-0000-0000000c0003'), -- employee A, works 101 (bartender)
  ('00000000-0000-0000-0000-0000000c0004'), -- employee A, works 102 (cashier)
  ('00000000-0000-0000-0000-0000000c0005'), -- manager B
  ('00000000-0000-0000-0000-0000000c0006'), -- kiosk A
  ('00000000-0000-0000-0000-0000000c0007'), -- lead A, storefront 102
  ('00000000-0000-0000-0000-0000000c0008'), -- employee A, temp bartender, not working
  ('00000000-0000-0000-0000-0000000c0009'); -- employee B
insert into user_profiles (id, display_name, kind, preferred_language) values
  ('00000000-0000-0000-0000-0000000c0001', 'Marcus Bell', 'person', 'en'),
  ('00000000-0000-0000-0000-0000000c0002', 'Lia Lead', 'person', 'en'),
  ('00000000-0000-0000-0000-0000000c0003', 'Ana Reyes', 'person', 'es'),
  ('00000000-0000-0000-0000-0000000c0006', 'Kiosk', 'kiosk', 'en');

insert into venue_memberships (venue_id, user_id)
select '00000000-0000-0000-0000-0000000ca001', u::uuid from unnest(array[
  '00000000-0000-0000-0000-0000000c0001', '00000000-0000-0000-0000-0000000c0002', '00000000-0000-0000-0000-0000000c0003',
  '00000000-0000-0000-0000-0000000c0004', '00000000-0000-0000-0000-0000000c0006', '00000000-0000-0000-0000-0000000c0007',
  '00000000-0000-0000-0000-0000000c0008']) u;
insert into venue_memberships (venue_id, user_id) values
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000c0005'),
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000c0009');

insert into venue_levels (id, venue_id, name, sort) values
  ('00000000-0000-0000-0000-0000000c1a01', '00000000-0000-0000-0000-0000000ca001', 'Main', 1),
  ('00000000-0000-0000-0000-0000000c1a02', '00000000-0000-0000-0000-0000000ca001', 'Upper', 2),
  ('00000000-0000-0000-0000-0000000c1b01', '00000000-0000-0000-0000-0000000cb001', 'Main', 1);
insert into storefronts (id, venue_id, level_id, code, name) values
  ('00000000-0000-0000-0000-0000000c0101', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c1a01', '101', 'Stand 101'),
  ('00000000-0000-0000-0000-0000000c0102', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c1a01', '102', 'Stand 102'),
  ('00000000-0000-0000-0000-0000000c0201', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c1a02', '201', 'Stand 201'),
  ('00000000-0000-0000-0000-0000000c0b01', '00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000c1b01', '101', 'B Stand 101');

select set_config('request.jwt.claim.role', 'service_role', true);
select seed_venue_job_defaults('00000000-0000-0000-0000-0000000ca001');
select seed_venue_job_defaults('00000000-0000-0000-0000-0000000cb001');
select set_config('request.jwt.claim.role', '', true);

insert into role_assignments (venue_id, user_id, role_code, scope_type, scope_id) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0001', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0002', 'storefront_lead', 'storefront', '00000000-0000-0000-0000-0000000c0101'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0003', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0004', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000c0005', 'concessions_manager', 'venue', null),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0006', 'kiosk', 'venue', null),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0007', 'storefront_lead', 'storefront', '00000000-0000-0000-0000-0000000c0102'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000c0008', 'employee', 'venue', null),
  ('00000000-0000-0000-0000-0000000cb001', '00000000-0000-0000-0000-0000000c0009', 'employee', 'venue', null);

insert into temp_agencies (id, venue_id, name) values
  ('00000000-0000-0000-0000-0000000cac01', '00000000-0000-0000-0000-0000000ca001', 'Agency One');
insert into workers (id, venue_id, worker_type, employee_number, first_name, last_name, date_of_birth, user_id, agency_id, phone, email, preferred_language) values
  ('00000000-0000-0000-0000-0000000cc001', '00000000-0000-0000-0000-0000000ca001', 'regular', 'E1', 'Ana', 'Reyes', '1995-04-02', '00000000-0000-0000-0000-0000000c0003', null, '(512) 555-0101', 'ana@example.com', 'es'),
  ('00000000-0000-0000-0000-0000000cc002', '00000000-0000-0000-0000-0000000ca001', 'regular', 'E2', 'Ben', 'Young', '1990-06-01', '00000000-0000-0000-0000-0000000c0004', null, '', '', 'en'),
  ('00000000-0000-0000-0000-0000000cc003', '00000000-0000-0000-0000-0000000ca001', 'regular', 'E3', 'Lia', 'Lead', '1985-01-01', '00000000-0000-0000-0000-0000000c0002', null, '', '', 'en'),
  ('00000000-0000-0000-0000-0000000cc004', '00000000-0000-0000-0000-0000000ca001', 'temp', 'T1', 'Cara', 'Diaz', '1990-01-01', '00000000-0000-0000-0000-0000000c0008', '00000000-0000-0000-0000-0000000cac01', '', '', 'en'),
  ('00000000-0000-0000-0000-0000000cc005', '00000000-0000-0000-0000-0000000ca001', 'regular', 'E5', 'Dev', 'Nolink', '1990-01-01', null, null, '', '', 'en'),
  ('00000000-0000-0000-0000-0000000cc0b1', '00000000-0000-0000-0000-0000000cb001', 'regular', 'E1', 'Zed', 'Other', '1990-01-01', '00000000-0000-0000-0000-0000000c0009', null, '', '', 'en');
insert into worker_job_roles (venue_id, worker_id, job_role_code) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc001', 'bartender'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc002', 'cashier'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc003', 'lead'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc004', 'bartender');
insert into worker_certifications (venue_id, worker_id, cert_type_code, expires_on) values
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc001', 'tabc', '2026-12-01'),  -- expiring
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc004', 'tabc', '2026-12-05'),  -- renewed below
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc004', 'tabc', '2028-12-05'),
  ('00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc002', 'food_handler', '2027-06-01');

insert into events (id, venue_id, name, event_type_code, start_time, doors_time, call_time, end_time) values
  ('00000000-0000-0000-0000-0000000ce001', '00000000-0000-0000-0000-0000000ca001', 'Game 1', 'hockey',
   '2026-11-20 01:00+00', '2026-11-20 00:00+00', '2026-11-19 22:30+00', '2026-11-20 04:00+00'),
  ('00000000-0000-0000-0000-0000000ce0b1', '00000000-0000-0000-0000-0000000cb001', 'B Game', 'hockey',
   '2026-11-20 01:00+00', '2026-11-20 00:00+00', '2026-11-19 22:30+00', '2026-11-20 04:00+00');
insert into shifts (id, venue_id, event_id, storefront_id, job_role_code, worker_id, call_time, status) values
  ('00000000-0000-0000-0000-0000000cf001', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ce001',
   '00000000-0000-0000-0000-0000000c0101', 'bartender', '00000000-0000-0000-0000-0000000cc001', '2026-11-19 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000000cf002', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ce001',
   '00000000-0000-0000-0000-0000000c0102', 'cashier', '00000000-0000-0000-0000-0000000cc002', '2026-11-19 22:30+00', 'assigned'),
  ('00000000-0000-0000-0000-0000000cf003', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ce001',
   '00000000-0000-0000-0000-0000000c0101', 'lead', '00000000-0000-0000-0000-0000000cc003', '2026-11-19 22:00+00', 'assigned'),
  ('00000000-0000-0000-0000-0000000cf004', '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000ce001',
   '00000000-0000-0000-0000-0000000c0201', 'cashier', null, '2026-11-19 22:30+00', 'open');

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
-- Sends as the current user and returns the new message id.
create or replace function pg_temp.send(p jsonb) returns uuid language sql as $$
  select (public.send_message(p) ->> 'id')::uuid;
$$;
create temp table ids (name text primary key, id uuid);
grant all on ids to authenticated;

-- ---- Who may send ---------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "managers", "body": "hi"}')$$,
  'an employee cannot send messages');
select pg_temp.expect_error($$insert into messages (venue_id, audience, body) values ('00000000-0000-0000-0000-0000000ca001', 'everyone', 'x')$$,
  'nobody writes messages directly');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0002');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "everyone", "body": "hi"}')$$,
  'a lead cannot message everyone');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "storefront",
  "audience_id": "00000000-0000-0000-0000-0000000c0102", "body": "hi"}')$$, 'a lead cannot message another storefront');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "level",
  "audience_id": "00000000-0000-0000-0000-0000000c1a01", "body": "hi"}')$$, 'a storefront lead cannot message a whole level');
insert into ids select 'lead_help', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "managers",
  "body": "Stand 101 needs a runner", "urgent": true}');
insert into ids select 'lead_team', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "storefront",
  "audience_id": "00000000-0000-0000-0000-0000000c0101", "event_id": "00000000-0000-0000-0000-0000000ce001", "body": "Huddle at the register"}');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0005');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "everyone", "body": "hi"}')$$,
  'manager B cannot message venue A');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000cb001", "audience": "storefront",
  "audience_id": "00000000-0000-0000-0000-0000000c0101", "body": "hi"}')$$, 'manager B cannot target a venue A storefront');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
insert into ids select 'everyone', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "everyone", "body": "Doors at 6"}');
insert into ids select 'sf101', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "storefront",
  "audience_id": "00000000-0000-0000-0000-0000000c0101", "event_id": "00000000-0000-0000-0000-0000000ce001", "body": "Restock cups"}');
insert into ids select 'level_main', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "level",
  "audience_id": "00000000-0000-0000-0000-0000000c1a01", "event_id": "00000000-0000-0000-0000-0000000ce001", "body": "Main level: close lines at 9"}');
insert into ids select 'to_ben', pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "worker",
  "audience_id": "00000000-0000-0000-0000-0000000cc002", "body": "See me at the office"}');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "worker",
  "audience_id": "00000000-0000-0000-0000-0000000cc005", "body": "hi"}')$$, 'a person without a sign-in cannot be messaged');
select pg_temp.expect_error($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "everyone", "body": "   "}')$$,
  'an empty message is refused');
select pg_temp.expect_error(format($$select pg_temp.send('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "audience": "everyone", "body": "%s"}')$$, repeat('x', 1001)),
  'a message over 1,000 characters is refused');

-- ---- Visibility per audience -------------------------------------------------------
select pg_temp.as_owner();
select pg_temp.expect((select recipient_count from messages where id = (select id from ids where name = 'everyone')) = 5,
  'everyone reaches the five people at venue A (not the sender, not the kiosk)');
select pg_temp.expect((select recipient_count from messages where id = (select id from ids where name = 'sf101')) = 2,
  'a storefront message reaches its worker and its lead');
select pg_temp.expect((select recipient_count from messages where id = (select id from ids where name = 'level_main')) = 4,
  'a level message reaches people working that level and its leads');
select pg_temp.expect((select recipient_count from messages where id = (select id from ids where name = 'lead_help')) = 2,
  'a lead''s message to managers reaches the manager and the other lead');
select pg_temp.expect((select audience_label from messages where id = (select id from ids where name = 'sf101')) = 'Stand 101 · Game 1',
  'the audience is labeled with the storefront and event');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');  -- works 101
select pg_temp.expect((select count(*) from messages) = 4, 'the 101 worker sees everyone, both Stand 101 messages, and the level message');
select pg_temp.expect(not exists (select 1 from messages where id = (select id from ids where name = 'lead_help')),
  'employees do not see messages to managers');
select pg_temp.expect(jsonb_array_length(my_messages(50)) = 4, 'my_messages lists the same four');
select pg_temp.expect((select bool_and(m ->> 'read_at' is null) from jsonb_array_elements(my_messages(50)) m), 'all unread at first');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0004');  -- works 102
select pg_temp.expect((select count(*) from messages) = 3, 'the 102 worker sees everyone, the level, and the direct message');
select pg_temp.expect(not exists (select 1 from messages where id = (select id from ids where name = 'sf101')),
  'the 102 worker does not see Stand 101 messages');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0008');  -- not working
select pg_temp.expect((select count(*) from messages) = 1, 'someone not working sees only everyone messages');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0007');  -- lead 102
select pg_temp.expect((select count(*) from messages) = 3, 'the 102 lead sees everyone, the level, and messages to managers');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect((select count(*) from messages) = 6, 'the venue manager sees every message at the venue');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0006');
select pg_temp.expect((select count(*) from messages) = 0, 'a kiosk sees no messages');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0005');
select pg_temp.expect((select count(*) from messages) = 0, 'manager B sees no venue A messages');
select pg_temp.expect(jsonb_array_length(my_messages(50)) = 0, 'manager B inbox is empty');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0009');
select pg_temp.expect((select count(*) from messages) = 0, 'employee B sees no venue A messages');

-- ---- Notifications for messages --------------------------------------------------
select pg_temp.as_owner();
select pg_temp.expect((select channels from notifications where user_id = '00000000-0000-0000-0000-0000000c0001' and kind = 'message'
  and data ->> 'message_id' = (select id from ids where name = 'lead_help')::text) = '{in_app,push,email}',
  'an urgent message also goes by email (sent only to people who opted in)');
select pg_temp.expect(not exists (select 1 from notifications where 'sms' = any (channels)), 'nothing is ever queued as a text message');
select pg_temp.expect((select channels from notifications where user_id = '00000000-0000-0000-0000-0000000c0003' and kind = 'message'
  and data ->> 'message_id' = (select id from ids where name = 'sf101')::text) = '{in_app,push}',
  'a normal message goes in-app and by push');
select pg_temp.expect((select title from notifications where user_id = '00000000-0000-0000-0000-0000000c0003' and kind = 'message'
  and data ->> 'message_id' = (select id from ids where name = 'sf101')::text) = 'Mensaje de Marcus Bell',
  'the notification is in the recipient''s language');
select pg_temp.expect(not exists (select 1 from notifications where user_id = '00000000-0000-0000-0000-0000000c0001'
  and data ->> 'message_id' = (select id from ids where name = 'everyone')::text), 'the sender is not notified');
select pg_temp.expect(not exists (select 1 from notifications where user_id = '00000000-0000-0000-0000-0000000c0006'),
  'the kiosk gets no notifications');

-- ---- Read marks ---------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select mark_message_read((select id from ids where name = 'sf101'));
select mark_message_read((select id from ids where name = 'sf101'));
select mark_message_read((select id from ids where name = 'lead_help'));  -- not visible: ignored
select pg_temp.expect((select count(*) from message_reads) = 1, 'a read is stored once; unseen messages are ignored');
select pg_temp.expect((select read_at is not null from notifications where kind = 'message'
  and data ->> 'message_id' = (select id from ids where name = 'sf101')::text), 'reading a message clears its notification');
select pg_temp.expect((select count(*) from jsonb_array_elements(my_messages(50)) m where m ->> 'read_at' is not null) = 1,
  'my_messages shows the read time');
select pg_temp.expect_error($$insert into message_reads (message_id, user_id) values ((select id from ids where name = 'everyone'), '00000000-0000-0000-0000-0000000c0003')$$,
  'read marks are written only through the function');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect((select (m ->> 'read_count')::int from jsonb_array_elements(sent_messages('00000000-0000-0000-0000-0000000ca001', 50)) m
  where m ->> 'id' = (select id from ids where name = 'sf101')::text) = 1, 'the sender sees 1 of 2 read');
select pg_temp.expect(jsonb_array_length(sent_messages('00000000-0000-0000-0000-0000000ca001', 50)) = 6,
  'the venue manager''s sent view includes leads'' messages');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0002');
select pg_temp.expect(jsonb_array_length(sent_messages('00000000-0000-0000-0000-0000000ca001', 50)) = 2, 'a lead''s sent view has only their own');

-- ---- Announcements -------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select pg_temp.expect_error($$select publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "title": "x"}')$$,
  'an employee cannot publish announcements');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0005');
select pg_temp.expect_error($$select publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "title": "x"}')$$,
  'manager B cannot publish at venue A');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect_error($$select publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001", "title": "x",
  "document_path": "00000000-0000-0000-0000-0000000cb001/announcements/a.pdf"}')$$, 'a document from another venue is refused');
insert into ids select 'general', (publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001",
  "title": "Parking changes", "body": "Use lot C."}') ->> 'id')::uuid;
insert into ids select 'policy', (publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001",
  "title": "Alcohol service policy", "body": "Check ID for anyone who looks under 30.", "is_policy": true,
  "audience": {"job_roles": ["bartender"]},
  "document_path": "00000000-0000-0000-0000-0000000ca001/announcements/alcohol.pdf"}') ->> 'id')::uuid;
insert into ids select 'temps', (publish_announcement('{"venue_id": "00000000-0000-0000-0000-0000000ca001",
  "title": "Temp check-in", "requires_ack": true, "audience": {"worker_types": ["temp"]}}') ->> 'id')::uuid;
select pg_temp.expect((select requires_ack from announcements where id = (select id from ids where name = 'policy')),
  'a policy always requires acknowledgment');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');  -- regular bartender
select pg_temp.expect((select count(*) from announcements) = 2, 'a bartender sees the general and the policy announcement');
select pg_temp.expect((my_announcements() -> 0 ->> 'title') = 'Alcohol service policy', 'what needs acknowledgment comes first');
select pg_temp.expect_error($$select acknowledge_announcement((select id from ids where name = 'policy'), '')$$,
  'a policy needs a typed name');
select pg_temp.expect_error($$select acknowledge_announcement((select id from ids where name = 'general'), 'Ana')$$,
  'a plain announcement has nothing to acknowledge');
select pg_temp.expect_error($$select acknowledge_announcement((select id from ids where name = 'temps'), 'Ana')$$,
  'an announcement for someone else cannot be acknowledged');
select acknowledge_announcement((select id from ids where name = 'policy'), 'Ana Reyes');
select pg_temp.expect((select typed_name from announcement_acks) = 'Ana Reyes', 'the typed name is recorded');
select pg_temp.expect((select a ->> 'acked_at' is not null from jsonb_array_elements(my_announcements()) a
  where a ->> 'title' = 'Alcohol service policy'), 'my_announcements shows the acknowledgment');
select pg_temp.expect((select read_at is not null from notifications where kind = 'announcement'
  and data ->> 'announcement_id' = (select id from ids where name = 'policy')::text), 'acknowledging clears its notification');
select pg_temp.expect_error($$select announcement_ack_report((select id from ids where name = 'policy'))$$,
  'an employee cannot see the acknowledgment report');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0004');  -- cashier
select pg_temp.expect((select count(*) from announcements) = 1, 'a cashier sees only the general announcement');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0008');  -- temp bartender
select pg_temp.expect((select count(*) from announcements) = 3, 'a temp bartender sees all three');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0009');
select pg_temp.expect((select count(*) from announcements) = 0, 'venue B staff see no venue A announcements');

select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect((select jsonb_array_length(announcement_ack_report((select id from ids where name = 'policy')) -> 'people')) = 2,
  'the report lists both bartenders');
select pg_temp.expect((select count(*) from jsonb_array_elements(announcement_ack_report((select id from ids where name = 'policy')) -> 'people') p
  where p ->> 'acked_at' is not null and p ->> 'typed_name' = 'Ana Reyes') = 1, 'the report shows who has acknowledged');
select pg_temp.expect((announcement_ack_report((select id from ids where name = 'policy')) -> 'people' -> 0 ->> 'name') = 'Cara Diaz',
  'people still to acknowledge are listed first');
select pg_temp.expect((select (a ->> 'audience_count')::int = 2 and (a ->> 'ack_count')::int = 1
  from jsonb_array_elements(announcement_summaries('00000000-0000-0000-0000-0000000ca001')) a
  where a ->> 'id' = (select id from ids where name = 'policy')::text), 'the summary counts 1 of 2 acknowledged');
select pg_temp.expect(remind_unacknowledged((select id from ids where name = 'policy')) = 1, 'a reminder goes to the one who has not acknowledged');
select pg_temp.expect(remind_unacknowledged((select id from ids where name = 'policy')) = 0, 'a second reminder in the same hour is not sent');
select pg_temp.expect_error($$select remind_unacknowledged((select id from ids where name = 'general'))$$,
  'reminders are only for announcements that need acknowledgment');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0005');
select pg_temp.expect_error($$select announcement_ack_report((select id from ids where name = 'policy'))$$,
  'manager B cannot see venue A acknowledgments');
select pg_temp.expect((select count(*) from announcement_acks) = 0, 'manager B reads no venue A acknowledgments');

select pg_temp.as_owner();
select pg_temp.expect((select channels from notifications where kind = 'announcement' and user_id = '00000000-0000-0000-0000-0000000c0008'
  and data ->> 'announcement_id' = (select id from ids where name = 'policy')::text and not data ? 'reminder') = '{in_app,push,email}',
  'a policy is also emailed');

-- ---- Documents ------------------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('documents', '00000000-0000-0000-0000-0000000ca001/announcements/x.pdf')$$,
  'an employee cannot upload documents');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
insert into storage.objects (bucket_id, name) values ('documents', '00000000-0000-0000-0000-0000000ca001/announcements/alcohol.pdf');
select pg_temp.expect_error($$insert into storage.objects (bucket_id, name) values ('documents', '00000000-0000-0000-0000-0000000cb001/announcements/x.pdf')$$,
  'a manager cannot upload to another venue');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'documents') = 1, 'members can open the venue''s documents');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0009');
select pg_temp.expect((select count(*) from storage.objects where bucket_id = 'documents') = 0, 'other venues cannot');

-- ---- Preferences and push tokens -----------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0003');
select pg_temp.expect((my_notification_prefs() ->> 'push')::boolean and not (my_notification_prefs() ->> 'email')::boolean
  and (my_notification_prefs() ->> 'email_address') = 'ana@example.com',
  'push is on and email is off by default; the address comes from the staff record');
select pg_temp.expect(not (my_notification_prefs() ? 'sms') and not (my_notification_prefs() ? 'phone'), 'there is no text-message setting');
select set_notification_prefs('{"email": true, "push": false, "quiet_start": "23:00", "quiet_end": "07:00"}');
select pg_temp.expect((my_notification_prefs() ->> 'email')::boolean and not (my_notification_prefs() ->> 'push')::boolean
  and (my_notification_prefs() ->> 'quiet_start') = '23:00',
  'preferences are saved');
select pg_temp.expect_error($$select set_notification_prefs('{"quiet_start": "23:00", "quiet_end": ""}')$$, 'quiet hours need both ends');
select set_notification_prefs('{"email_address": "other@example.com"}');
select pg_temp.expect((my_notification_prefs() ->> 'email_address') = 'ana@example.com', 'staff cannot change their email here');
select register_push_token('tok-ana', 'android');
select pg_temp.expect_error($$insert into push_tokens (token, user_id, platform) values ('x', '00000000-0000-0000-0000-0000000c0003', 'web')$$,
  'push tokens are written only through the function');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select set_notification_prefs('{"email_address": "marcus@example.com"}');
select pg_temp.expect((my_notification_prefs() ->> 'email_address') = 'marcus@example.com', 'a manager without a staff record sets contact details');
select pg_temp.expect_error($$select set_notification_prefs('{"email_address": "not an email"}')$$, 'a bad email address is refused');
select pg_temp.expect((select count(*) from push_tokens) = 0, 'others'' push tokens are private');
select register_push_token('tok-shared', 'web');
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0004');
select register_push_token('tok-shared', 'web');
select remove_push_token('tok-ana');
select pg_temp.as_owner();
select pg_temp.expect((select user_id from push_tokens where token = 'tok-shared') = '00000000-0000-0000-0000-0000000c0004',
  'a token moves to whoever signed in last');
select pg_temp.expect(exists (select 1 from push_tokens where token = 'tok-ana'), 'only the owner removes a token');

-- ---- Scheduled reminders --------------------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect_error($$select queue_scheduled_notifications()$$, 'signed-in users cannot run the scheduler');
select pg_temp.as_owner();
select pg_temp.expect((queue_scheduled_notifications('2026-11-19 20:35+00') ->> 'call_time')::int = 3,
  'call-time reminders go to the three assigned people about 2 hours before');
select pg_temp.expect((queue_scheduled_notifications('2026-11-19 20:50+00') ->> 'call_time')::int = 0, 'call-time reminders are sent once');
select pg_temp.expect((select title from notifications where kind = 'call_time' and user_id = '00000000-0000-0000-0000-0000000c0003') = 'Llegada 4:30 PM en Stand 101',
  'the reminder is in the person''s language and venue time');
select pg_temp.expect((select channels from notifications where kind = 'call_time' and user_id = '00000000-0000-0000-0000-0000000c0004') = '{in_app,push}',
  'call-time reminders go in-app and by push');

insert into punches (id, venue_id, worker_id, event_id, shift_id, kind, occurred_at, source) values
  (gen_random_uuid(), '00000000-0000-0000-0000-0000000ca001', '00000000-0000-0000-0000-0000000cc003', '00000000-0000-0000-0000-0000000ce001',
   '00000000-0000-0000-0000-0000000cf003', 'clock_in', '2026-11-19 21:55+00', 'phone');
select pg_temp.expect((queue_scheduled_notifications('2026-11-19 22:45+00') ->> 'missed_clock_in')::int = 0, 'no missed clock-in alerts inside the grace window');
select pg_temp.expect((queue_scheduled_notifications('2026-11-19 22:55+00') ->> 'missed_clock_in')::int = 4,
  'missed clock-in: both people who are not in, plus each storefront''s lead');
select pg_temp.expect((queue_scheduled_notifications('2026-11-19 23:05+00') ->> 'missed_clock_in')::int = 0, 'missed clock-in alerts are sent once');
select pg_temp.expect(exists (select 1 from notifications where kind = 'missed_clock_in' and user_id = '00000000-0000-0000-0000-0000000c0007'
  and title = 'Not clocked in: Ben Young'), 'the 102 lead hears about their missing cashier');
select pg_temp.expect(not exists (select 1 from notifications where kind = 'missed_clock_in' and user_id = '00000000-0000-0000-0000-0000000c0002'
  and title like '%Ben Young'), 'the 101 lead does not hear about 102');
select pg_temp.expect(not exists (select 1 from notifications where kind = 'missed_clock_in' and user_id = '00000000-0000-0000-0000-0000000c0001'),
  'the venue manager is not paged when the storefront has a lead');

select pg_temp.expect((select count(*) from notifications where kind = 'cert_expiring' and user_id = '00000000-0000-0000-0000-0000000c0003') = 1,
  'an expiring certification is flagged to its holder');
select pg_temp.expect(not exists (select 1 from notifications where kind = 'cert_expiring' and user_id = '00000000-0000-0000-0000-0000000c0008'),
  'a renewed certification is not flagged');
select pg_temp.expect((select title from notifications where kind = 'cert_expiring' and user_id = '00000000-0000-0000-0000-0000000c0001') = '1 certification expires within 30 days',
  'staff managers get one weekly list');
select pg_temp.expect((queue_scheduled_notifications('2026-11-21 12:00+00') ->> 'cert_expiring')::int = 0, 'certification reminders are weekly');
select pg_temp.expect((queue_scheduled_notifications('2026-11-24 12:00+00') ->> 'cert_expiring')::int = 1, 'and come again the next week');
select pg_temp.expect(not exists (select 1 from notifications n where n.venue_id = '00000000-0000-0000-0000-0000000cb001'),
  'nothing is queued for venue B');

-- ---- Delivery claims (notify-dispatch) --------------------------------------------------
select pg_temp.as_user('00000000-0000-0000-0000-0000000c0001');
select pg_temp.expect_error($$select claim_notification_batch(10)$$, 'signed-in users cannot claim deliveries');
select pg_temp.as_owner();
create temp table batch as select b from jsonb_array_elements(claim_notification_batch(500)) b;
select pg_temp.expect((select count(*) from batch) = (select count(*) from notifications where channels <> '{in_app}'),
  'every notification with push or email is claimed');
select pg_temp.expect(jsonb_array_length(claim_notification_batch(500)) = 0, 'claimed notifications are not handed out twice');
select pg_temp.expect((select b ->> 'email' = 'ana@example.com' and (b -> 'prefs' ->> 'email')::boolean
  and not (b -> 'prefs' ->> 'push')::boolean and b ->> 'language' = 'es'
  from batch where b ->> 'user_id' = '00000000-0000-0000-0000-0000000c0003' limit 1), 'a claim carries contact details and preferences');
select pg_temp.expect((select b -> 'push_tokens' -> 0 ->> 'token' = 'tok-shared' from batch
  where b ->> 'user_id' = '00000000-0000-0000-0000-0000000c0004' limit 1), 'a claim carries the person''s device tokens');
select pg_temp.expect((select (b ->> 'urgent')::boolean from batch where b -> 'data' ->> 'message_id' = (select id from ids where name = 'lead_help')::text limit 1),
  'urgent messages are marked urgent for quiet hours');
select record_notification_results((select jsonb_agg(jsonb_build_object('id', b ->> 'id', 'sent', jsonb_build_object('push', 'not_configured'))) from batch));
select pg_temp.expect((select count(*) from notifications where sent = '{"push": "not_configured"}') = (select count(*) from batch),
  'delivery results are recorded per channel');
update notifications set sent = '{}' where id = (select (b ->> 'id')::uuid from batch limit 1);
select record_notification_results(jsonb_build_array(jsonb_build_object('id', (select b ->> 'id' from batch limit 1), 'deliver_after', now() + interval '1 hour')));
select pg_temp.expect(jsonb_array_length(claim_notification_batch(500)) = 0, 'a deferred notification waits for its time');
update notifications set deliver_after = now() - interval '1 minute' where deliver_after is not null;
select pg_temp.expect(jsonb_array_length(claim_notification_batch(500)) = 1, 'and is claimed after it');
update notifications set sent = '{}', created_at = now() - interval '2 days' where deliver_after is not null;
select pg_temp.expect(jsonb_array_length(claim_notification_batch(500)) = 0, 'notifications older than a day are not sent');
select pg_temp.expect((select sent ->> 'expired' from notifications where deliver_after is not null) = 'true', 'they are marked expired');

rollback;

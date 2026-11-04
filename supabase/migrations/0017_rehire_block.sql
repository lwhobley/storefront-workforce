-- The server refuses to put a person flagged do-not-rehire into a position, not only the
-- app's assign sheet. The check goes in assignment_block_reason, which assign_shift and the
-- candidate list both use. Everything else is unchanged from 0004.
--
-- (Applied to the live project from another working copy; recorded here as applied.)

create or replace function public.assignment_block_reason(p_worker uuid, p_event uuid, p_role text, p_shift uuid)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  w workers%rowtype;
  ev events%rowtype;
  r job_roles%rowtype;
  v_day date;
  v_age integer;
  v_cert text;
  v_enforcement text;
begin
  select * into w from workers where id = p_worker;
  select * into ev from events where id = p_event;
  select * into r from job_roles where venue_id = ev.venue_id and code = p_role;
  if w.id is null or w.venue_id <> ev.venue_id then return 'This person is not on this venue''s staff.'; end if;
  if w.status <> 'active' then return 'This person is inactive.'; end if;
  if exists (select 1 from rehire_flags f where f.venue_id = ev.venue_id and f.worker_id = p_worker) then
    return 'This person is flagged do not rehire.';
  end if;
  if exists (select 1 from shifts s where s.event_id = p_event and s.worker_id = p_worker
             and s.status in ('assigned', 'released') and s.id <> p_shift) then
    return 'This person already has a position at this event.';
  end if;

  v_day := public.venue_local_date(ev.venue_id, ev.call_time);
  if w.date_of_birth is not null then
    v_age := extract(year from age(v_day, w.date_of_birth))::integer;
    if r.minimum_age is not null and v_age < r.minimum_age then
      return format('%s must be at least %s; this person is %s.', r.name, r.minimum_age, v_age);
    end if;
    if v_age < coalesce((select (settings -> 'minors' ->> 'minimum_working_age')::integer from venues where id = ev.venue_id), 14) then
      return 'This person is under the minimum working age.';
    end if;
  elsif r.minimum_age is not null then
    return format('%s needs a birth date on file to check the minimum age of %s.', r.name, r.minimum_age);
  end if;

  select coalesce(settings -> 'certifications' ->> 'enforcement', 'block') into v_enforcement
    from venues where id = ev.venue_id;
  if v_enforcement = 'block' then
    foreach v_cert in array r.required_certifications loop
      if not exists (
        select 1 from worker_certifications c
        where c.worker_id = p_worker and c.cert_type_code = v_cert
          and (c.expires_on is null or c.expires_on >= v_day)
      ) then
        return format('%s needs a current %s.', r.name,
          coalesce((select name from certification_types where venue_id = ev.venue_id and code = v_cert), v_cert));
      end if;
    end loop;
  end if;
  return null;
end $$;

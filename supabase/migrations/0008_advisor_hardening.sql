-- Tightens function access after the Supabase security advisor review.
--   * Nothing is callable without signing in (anon).
--   * Trigger functions and internal helpers are not callable through the API at all.
--   * Permission helpers stay callable by signed-in users because row level security
--     policies run them as the caller.
--   * Storage path helpers get a fixed search_path.
--   * user_pins and login_locks keep row level security with no policies on purpose:
--     only the edge functions (service role) read or write them.

create or replace function public.storage_venue(p_name text)
returns uuid language sql immutable set search_path = '' as $$
  select case when split_part(p_name, '/', 1) ~ '^[0-9a-f-]{36}$' then split_part(p_name, '/', 1)::uuid end;
$$;

create or replace function public.storage_worker(p_name text)
returns uuid language sql immutable set search_path = '' as $$
  select case when split_part(p_name, '/', 2) ~ '^[0-9a-f-]{36}' then left(split_part(p_name, '/', 2), 36)::uuid end;
$$;

-- No anonymous access to any function in public.
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
  loop
    execute format('revoke execute on function %s from public, anon', f.sig);
  end loop;
end $$;

-- Trigger functions and internal helpers: not part of the API.
do $$
declare f text;
begin
  foreach f in array array[
    'public.audit_row_change()',
    'public.seed_venue_roles()',
    'public.seed_venue_event_types()',
    'public.version_venue_rules()',
    'public.check_role_permissions()',
    'public.check_job_role_certs()',
    'public.touch_updated_at()',
    'public.mark_event_times_overridden()',
    'public.assignment_block_reason(uuid, uuid, text, uuid)',
    'public.venue_local_date(uuid, timestamp with time zone)'] loop
    execute format('revoke execute on function %s from authenticated', f);
  end loop;
end $$;

-- Helpers used by row level security policies and storage policies.
grant execute on function
  public.is_venue_member(uuid),
  public.has_permission(uuid, text),
  public.has_venue_permission(uuid, text),
  public.permission_scope_ids(uuid, text, text),
  public.storefronts_in_scope(uuid, text),
  public.can_on_storefront(uuid, text),
  public.can_view_worker(uuid),
  public.can_view_punches_of(uuid, uuid),
  public.storage_venue(text),
  public.storage_worker(text)
to authenticated;

-- Functions the edge functions call with the service role.
grant execute on function
  public.login_take_attempt(text, integer, integer),
  public.login_release(text, boolean),
  public.record_kiosk_punch(uuid, uuid, jsonb),
  public.upsert_source_events(uuid, text, jsonb),
  public.pin_hmac_secret(),
  public.seed_venue_job_defaults(uuid)
to service_role;

-- Future functions start closed to anonymous callers.
alter default privileges in schema public revoke execute on functions from public, anon;

-- Key for PIN fingerprints. Kept in a schema the API does not expose, readable only by
-- the edge functions (service role). An edge function secret named PIN_SECRET, when
-- set, takes precedence; changing the key means reissuing every PIN.
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table if not exists private.settings (
  key text primary key,
  value text not null
);
revoke all on private.settings from public, anon, authenticated;

insert into private.settings (key, value)
values ('pin_secret', encode(gen_random_bytes(32), 'hex'))
on conflict (key) do nothing;

create or replace function public.pin_hmac_secret()
returns text language sql stable security definer set search_path = private, public as $$
  select value from private.settings where key = 'pin_secret';
$$;
revoke execute on function public.pin_hmac_secret() from public, anon, authenticated;
grant execute on function public.pin_hmac_secret() to service_role;

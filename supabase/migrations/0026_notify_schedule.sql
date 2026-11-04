-- Runs notify-dispatch every minute, so queued alerts actually leave the building.
--
-- The function checks an x-cron-secret header, so the schedule has to send it. The
-- secret and the function URL live in the vault, not here, because this file is in git
-- and the values differ per project. Set them once per project:
--
--   select vault.create_secret('<the secret>', 'notify_dispatch_cron_secret');
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/notify-dispatch',
--                              'notify_dispatch_url');
--
-- Until both exist the job still runs, finds nothing to call, and does nothing. Local
-- test databases have neither pg_net nor pg_cron, so they skip the whole thing.

do $$
begin
  -- pg_net puts http_post in its own "net" schema.
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    create extension if not exists pg_net;
  end if;

  if not exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    return;
  end if;
  create extension if not exists pg_cron;

  -- Replace the job if it is already there, so this migration can be run again.
  if exists (select 1 from cron.job where jobname = 'notify-dispatch') then
    perform cron.unschedule('notify-dispatch');
  end if;

  perform cron.schedule('notify-dispatch', '* * * * *', $job$
    select net.http_post(
             url := (select decrypted_secret from vault.decrypted_secrets where name = 'notify_dispatch_url'),
             headers := jsonb_build_object(
               'Content-Type', 'application/json',
               'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'notify_dispatch_cron_secret')),
             body := '{}'::jsonb,
             timeout_milliseconds := 50000)
     where exists (select 1 from vault.decrypted_secrets where name = 'notify_dispatch_url')
       and exists (select 1 from vault.decrypted_secrets where name = 'notify_dispatch_cron_secret');
  $job$);
end $$;

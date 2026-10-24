-- Instant push for quote requests, quotations, bookings and payments too.
--
-- 20261020001000 sent urgent pushes (Evenda Now, critical reminders) at once;
-- everything else waited for the once-a-minute cron run, so a new quote request
-- reached the supplier's phone up to a minute late. Booking activity is now sent
-- at once as well. Deliveries held for quiet hours have a later not_before and
-- still wait for the cron run, so quiet hours are respected.

create or replace function public.kick_urgent_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from new_rows d join public.notifications n on n.id = d.notification_id
     where d.channel = 'push' and d.status = 'pending' and d.not_before <= now()
       and (n.category in ('now', 'booking') or coalesce((n.data->>'urgent')::boolean, false))
  ) and exists (select 1 from vault.decrypted_secrets where name = 'project_url') then
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
      body := '{"reason":"instant"}'::jsonb,
      timeout_milliseconds := 25000);
  end if;
  return null;
end $$;

revoke execute on function public.kick_urgent_push() from public, anon, authenticated;

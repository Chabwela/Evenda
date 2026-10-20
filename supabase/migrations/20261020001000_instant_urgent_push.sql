-- Instant push for urgent notifications (Evenda Now requests and offers,
-- critical reminders).
--
-- Before: every push waited for the once-a-minute cron call to send-push, so
-- an Evenda Now offer reached the requester's phone 0–60 s after it was made.
--
-- Now: when an urgent push delivery is queued, send-push is called at once
-- through pg_net. The request is queued with the transaction and sent after it
-- commits, so the delivery row is visible to the function. send-push claims
-- rows with FOR UPDATE SKIP LOCKED, so this and the cron run never send the same
-- row twice. The cron job stays as the backstop for everything else and for
-- retries. Needs the same Vault secrets as the cron job (project_url,
-- push_cron_secret); without them nothing changes.

create or replace function public.kick_urgent_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from new_rows d join public.notifications n on n.id = d.notification_id
     where d.channel = 'push' and d.status = 'pending' and d.not_before <= now()
       and (n.category = 'now' or coalesce((n.data->>'urgent')::boolean, false))
  ) and exists (select 1 from vault.decrypted_secrets where name = 'project_url') then
    perform net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
      body := '{"reason":"urgent"}'::jsonb,
      timeout_milliseconds := 25000);
  end if;
  return null;
end $$;

drop trigger if exists notification_deliveries_kick_urgent on public.notification_deliveries;
create trigger notification_deliveries_kick_urgent
  after insert on public.notification_deliveries
  referencing new table as new_rows
  for each statement execute function public.kick_urgent_push();

-- Trigger-only: nobody calls it directly.
revoke execute on function public.kick_urgent_push() from public, anon, authenticated;

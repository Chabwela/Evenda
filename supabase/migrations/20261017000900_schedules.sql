-- Scheduled jobs (pg_cron). All jobs are idempotent and safe to overlap or retry:
-- reminders and deliveries are claimed with FOR UPDATE SKIP LOCKED and
-- notifications are deduplicated by key.

select cron.schedule('evenda-reminders', '* * * * *', $$ select public.process_due_reminders(); $$);
select cron.schedule('evenda-now-expiry', '*/5 * * * *', $$ select public.expire_now_requests(); $$);
select cron.schedule('evenda-quotation-expiry', '15 * * * *', $$ select public.expire_quotations(); $$);
select cron.schedule('evenda-digests', '0 * * * *', $$ select public.build_digests(); $$);
select cron.schedule('evenda-push-stale', '*/5 * * * *', $$ select public.release_stale_push_claims(); $$);

-- Push delivery: invoke the send-push Edge Function every minute.
-- Requires two Vault secrets (see docs/BACKEND.md):
--   project_url       e.g. https://<ref>.supabase.co
--   push_cron_secret  shared secret checked by the function
select cron.schedule('evenda-push', '* * * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'project_url') || '/functions/v1/send-push',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'push_cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 25000)
  where exists (select 1 from vault.decrypted_secrets where name = 'project_url');
$$);

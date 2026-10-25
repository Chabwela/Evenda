-- App icon badge: each push carries the recipient business's unread count, so
-- the phone can show it on the Evenda icon even when the app is closed
-- (send-push puts it in android.notification.notification_count; the app's
-- call-style alert uses it too). Same signature: `unread` is added to `data`.

create or replace function public.claim_push_deliveries(p_limit int default 100)
returns table (delivery_id uuid, user_id uuid, title text, body text, data jsonb, tokens text[])
language plpgsql security definer set search_path = public as $$
begin
  return query
  with due as (
    select d.id from public.notification_deliveries d
    where d.channel = 'push' and d.status in ('pending', 'failed') and d.attempts < 5
      and d.not_before <= now()
    order by d.not_before
    limit p_limit
    for update skip locked
  ), claimed as (
    update public.notification_deliveries d
       set status = 'sending', attempts = d.attempts + 1
      from due where d.id = due.id
    returning d.id, d.user_id, d.notification_id
  )
  select c.id, c.user_id, n.title, n.body,
         n.data || jsonb_build_object(
           'route', n.action_route, 'notification_id', n.id, 'category', n.category,
           'unread', (select count(*) from public.notifications u
                       where u.recipient_business_id = n.recipient_business_id and u.read_at is null)),
         coalesce(array_agg(t.token) filter (where t.token is not null), '{}')
  from claimed c
  join public.notifications n on n.id = c.notification_id
  left join public.device_tokens t on t.user_id = c.user_id
  group by c.id, c.user_id, n.title, n.body, n.data, n.action_route, n.id, n.category, n.recipient_business_id;
end $$;

-- Lockdown (20261019000100): service role only.
revoke execute on function public.claim_push_deliveries(int) from public, anon, authenticated;

-- Unread counts (this badge and the app's bell) read only unread rows.
create index if not exists notifications_unread_idx on public.notifications (recipient_business_id) where read_at is null;

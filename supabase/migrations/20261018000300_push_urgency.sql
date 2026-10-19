-- Push notifications: urgency.
--
-- notify() records urgency in the notification data, so the send-push
--    Edge Function can use the high-importance Android channel (pop-up and
--    sound) for Evenda Now and critical reminders, and the normal channel for
--    everything else.

create or replace function public.notify(
  p_recipient uuid,
  p_category public.notification_category,
  p_title text,
  p_body text,
  p_dedupe_key text,
  p_action_route text default null,
  p_data jsonb default '{}'::jsonb,
  p_mode public.delivery_mode default 'immediate',
  p_image_path text default null,
  p_urgent boolean default false
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_send_at timestamptz;
begin
  insert into public.notifications (recipient_business_id, category, title, body, image_path, action_route, data, delivery_mode, dedupe_key)
  values (p_recipient, p_category, p_title, p_body, p_image_path, p_action_route,
          case when p_urgent then p_data || jsonb_build_object('urgent', true) else p_data end,
          p_mode, p_dedupe_key)
  on conflict (recipient_business_id, dedupe_key) do nothing
  returning id into v_id;

  if v_id is null then
    return null; -- already notified
  end if;

  if p_mode = 'immediate' then
    v_send_at := case when p_urgent then now() else public.next_allowed_send(p_recipient) end;
    insert into public.notification_deliveries (notification_id, user_id, channel, not_before)
    select v_id, m.user_id, 'push', v_send_at
    from public.business_members m
    where m.business_id = p_recipient and m.status = 'active' and m.user_id is not null
      and (m.role in ('owner', 'manager') or p_category in ('task', 'now'))
    on conflict do nothing;
  elsif p_mode = 'digest' then
    insert into public.notification_deliveries (notification_id, user_id, channel, not_before)
    select v_id, m.user_id, 'digest', now()
    from public.business_members m
    where m.business_id = p_recipient and m.status = 'active' and m.role in ('owner', 'manager')
    on conflict do nothing;
  end if;

  return v_id;
end $$;

revoke execute on function public.notify(uuid, public.notification_category, text, text, text, text, jsonb, public.delivery_mode, text, boolean) from public, anon, authenticated;

-- A phone's push token belongs to whoever signed in on it last. A plain
-- upsert fails RLS when the previous account's row is still there (e.g. it
-- signed out while offline), which would leave the new account without push.
-- This takes the token over for the caller.
create or replace function public.register_device(p_token text, p_platform text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  if p_platform not in ('android', 'ios', 'web') then raise exception 'invalid_platform' using errcode = '22023'; end if;
  insert into public.device_tokens (token, user_id, platform, updated_at)
  values (p_token, auth.uid(), p_platform, now())
  on conflict (token) do update set user_id = excluded.user_id, platform = excluded.platform, updated_at = now();
end $$;

grant execute on function public.register_device(text, text) to authenticated;

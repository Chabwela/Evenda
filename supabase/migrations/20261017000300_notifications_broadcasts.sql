-- Notifications, preferences, subscriptions and inventory broadcasts.
--
-- Delivery pipeline:
--   domain change -> inventory_events (deduplicated) -> fanout to relevant businesses
--   -> notifications (one per recipient business, deduplicated)
--   -> notification_deliveries (one per member device channel, idempotent)
--   -> Edge Function `send-push` claims pending push rows and sends via FCM.
-- Routine updates are delivered as digests; only high-value or explicitly
-- followed updates are pushed immediately.

create type public.notification_category as enum ('inventory', 'booking', 'task', 'now', 'system');
create type public.delivery_mode as enum ('immediate', 'digest', 'in_app');
create type public.pref_level as enum ('off', 'digest', 'immediate');

create table public.notification_preferences (
  business_id uuid primary key references public.businesses (id) on delete cascade,
  inventory_updates public.pref_level not null default 'digest',
  booking_activity public.pref_level not null default 'immediate',
  task_reminders public.pref_level not null default 'immediate',
  now_requests boolean not null default true,
  quiet_start time not null default '21:00',
  quiet_end time not null default '06:30',
  digest_hour int not null default 7 check (digest_hour between 0 and 23),
  preferred_radius_km int not null default 30 check (preferred_radius_km between 1 and 500),
  updated_at timestamptz not null default now()
);

create trigger businesses_owner_membership
  after insert on public.businesses
  for each row execute function public.add_owner_membership();

create table public.category_subscriptions (
  business_id uuid not null references public.businesses (id) on delete cascade,
  category_id text not null references public.categories (id),
  primary key (business_id, category_id)
);

create table public.supplier_follows (
  business_id uuid not null references public.businesses (id) on delete cascade,
  supplier_id uuid not null references public.businesses (id) on delete cascade,
  muted boolean not null default false,
  push_enabled boolean not null default true,
  created_at timestamptz not null default now(),
  primary key (business_id, supplier_id),
  check (business_id <> supplier_id)
);

create table public.device_tokens (
  token text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  platform text not null check (platform in ('android', 'ios', 'web')),
  updated_at timestamptz not null default now()
);

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_business_id uuid not null references public.businesses (id) on delete cascade,
  category public.notification_category not null,
  title text not null,
  body text not null default '',
  image_path text,
  action_route text,
  data jsonb not null default '{}'::jsonb,
  delivery_mode public.delivery_mode not null default 'in_app',
  dedupe_key text not null,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  unique (recipient_business_id, dedupe_key)
);

create index notifications_recipient_idx on public.notifications (recipient_business_id, created_at desc);

create table public.notification_deliveries (
  id uuid primary key default gen_random_uuid(),
  notification_id uuid not null references public.notifications (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  channel text not null check (channel in ('push', 'digest')),
  status text not null default 'pending' check (status in ('pending', 'sending', 'sent', 'failed', 'skipped')),
  attempts int not null default 0,
  last_error text,
  not_before timestamptz not null default now(),
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (notification_id, user_id, channel)
);

create index notification_deliveries_pending_idx on public.notification_deliveries (not_before)
  where status in ('pending', 'failed');

-- ---------------------------------------------------------------------------
-- Quiet hours (evaluated in Lusaka time)
-- ---------------------------------------------------------------------------
create or replace function public.next_allowed_send(p_business uuid, p_at timestamptz default now())
returns timestamptz language plpgsql stable security definer set search_path = public as $$
declare
  p public.notification_preferences;
  local_ts timestamp := p_at at time zone 'Africa/Lusaka';
  t time := local_ts::time;
  in_quiet boolean;
begin
  select * into p from public.notification_preferences where business_id = p_business;
  if not found then return p_at; end if;
  if p.quiet_start > p.quiet_end then
    in_quiet := t >= p.quiet_start or t < p.quiet_end;
  else
    in_quiet := t >= p.quiet_start and t < p.quiet_end;
  end if;
  if not in_quiet then return p_at; end if;
  if t >= p.quiet_end then
    return ((local_ts::date + 1) + p.quiet_end) at time zone 'Africa/Lusaka';
  end if;
  return (local_ts::date + p.quiet_end) at time zone 'Africa/Lusaka';
end $$;

-- ---------------------------------------------------------------------------
-- notify(): the single entry point for creating a notification.
-- Idempotent on (recipient, dedupe_key). Creates push deliveries for active
-- members when the mode is immediate; urgent bypasses quiet hours.
-- ---------------------------------------------------------------------------
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
  values (p_recipient, p_category, p_title, p_body, p_image_path, p_action_route, p_data, p_mode, p_dedupe_key)
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

-- Edge Function claims a batch of due push deliveries (service role only).
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
         n.data || jsonb_build_object('route', n.action_route, 'notification_id', n.id, 'category', n.category),
         coalesce(array_agg(t.token) filter (where t.token is not null), '{}')
  from claimed c
  join public.notifications n on n.id = c.notification_id
  left join public.device_tokens t on t.user_id = c.user_id
  group by c.id, c.user_id, n.title, n.body, n.data, n.action_route, n.id, n.category;
end $$;

create or replace function public.complete_push_delivery(p_delivery uuid, p_ok boolean, p_error text default null)
returns void language sql security definer set search_path = public as $$
  update public.notification_deliveries
     set status = case when p_ok then 'sent' when attempts >= 5 then 'skipped' else 'failed' end,
         sent_at = case when p_ok then now() end,
         last_error = p_error,
         -- exponential backoff for retries
         not_before = case when p_ok then not_before else now() + (interval '1 minute' * power(2, attempts)) end
   where id = p_delivery and status = 'sending';
$$;

-- Stale claims (function crashed mid-send) become retryable.
create or replace function public.release_stale_push_claims()
returns int language sql security definer set search_path = public as $$
  with r as (
    update public.notification_deliveries set status = 'failed', last_error = 'claim_timeout'
     where status = 'sending' and not_before < now() - interval '10 minutes'
    returning 1)
  select count(*)::int from r;
$$;

-- ---------------------------------------------------------------------------
-- Inventory broadcasts
-- ---------------------------------------------------------------------------
create type public.inventory_event_type as enum (
  'listing_published', 'stock_added', 'stock_restored', 'availability_opened',
  'availability_changed', 'listing_paused', 'listing_removed'
);

create table public.inventory_events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  listing_id uuid references public.listings (id) on delete cascade,
  type public.inventory_event_type not null,
  significance text not null check (significance in ('routine', 'high')),
  payload jsonb not null default '{}'::jsonb,
  -- One event per listing, type and day: repeated edits do not create new broadcasts.
  dedupe_key text not null unique,
  recipients_count int,
  created_at timestamptz not null default now()
);

create index inventory_events_feed_idx on public.inventory_events (created_at desc);

-- Who should hear about an event from this supplier? Excludes the supplier,
-- inactive or unfinished businesses, muted follows and anyone who turned updates off.
create or replace function public.inventory_event_recipients(p_event uuid)
returns table (business_id uuid, follows boolean, push_follow boolean)
language sql stable security definer set search_path = public as $$
  with e as (
    select ie.*, l.category_id, s.public_location as supplier_loc
    from public.inventory_events ie
    join public.businesses s on s.id = ie.business_id
    left join public.listings l on l.id = ie.listing_id
    where ie.id = p_event
  )
  select b.id,
         f.business_id is not null and not f.muted,
         coalesce(f.push_enabled and not f.muted, false)
  from e
  join public.businesses b on b.id <> e.business_id
  join public.notification_preferences p on p.business_id = b.id
  left join public.supplier_follows f on f.business_id = b.id and f.supplier_id = e.business_id
  where b.status = 'active' and b.onboarding_completed_at is not null
    and p.inventory_updates <> 'off'
    and coalesce(f.muted, false) = false
    and (
      (f.business_id is not null)
      or (
        exists (select 1 from public.category_subscriptions cs where cs.business_id = b.id and cs.category_id = e.category_id)
        and (e.supplier_loc is null or b.public_location is null
             or extensions.st_dwithin(b.public_location, e.supplier_loc, p.preferred_radius_km * 1000))
      )
    );
$$;

create or replace function public.fanout_inventory_event()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  r record;
  s public.businesses;
  l public.listings;
  v_title text;
  v_body text;
  v_photo text;
  v_count int := 0;
  v_mode public.delivery_mode;
begin
  -- Removals are recorded for the feed but never pushed.
  if new.type in ('listing_paused', 'listing_removed') then
    return new;
  end if;

  select * into s from public.businesses where id = new.business_id;
  select * into l from public.listings where id = new.listing_id;
  select storage_path into v_photo from public.listing_photos where listing_id = new.listing_id order by sort limit 1;

  v_title := case new.type
    when 'listing_published' then s.name || ' listed ' || l.title
    when 'stock_added' then s.name || ' added ' || (new.payload->>'delta') || ' × ' || l.title
    when 'stock_restored' then l.title || ' back in service at ' || s.name
    when 'availability_opened' then s.name || ' opened dates for ' || coalesce(l.title, 'bookings')
    else s.name || ' updated ' || coalesce(l.title, 'availability')
  end;
  v_body := concat_ws(' · ',
    (select name from public.categories where id = l.category_id),
    s.neighbourhood,
    case when new.payload ? 'from' then 'From ' || to_char((new.payload->>'from')::date, 'DD Mon') end,
    'Availability is confirmed only by quotation');

  for r in select * from public.inventory_event_recipients(new.id) loop
    -- Followed suppliers with push on: immediate. Category subscribers who chose
    -- "immediate": only significant updates are pushed, routine ones go to the digest.
    select case
             when r.push_follow then 'immediate'
             when p.inventory_updates = 'immediate' and new.significance = 'high' then 'immediate'
             else 'digest' end::public.delivery_mode
      into v_mode
      from public.notification_preferences p where p.business_id = r.business_id;

    perform public.notify(
      r.business_id, 'inventory', v_title, v_body,
      'inv:' || new.dedupe_key,
      case when new.listing_id is not null then '/listing/' || new.listing_id else '/supplier/' || new.business_id end,
      jsonb_build_object('event_id', new.id, 'listing_id', new.listing_id, 'supplier_id', new.business_id, 'type', new.type),
      v_mode, v_photo);
    v_count := v_count + 1;
  end loop;

  update public.inventory_events set recipients_count = v_count where id = new.id;
  return new;
end $$;

create trigger inventory_events_fanout
  after insert on public.inventory_events
  for each row execute function public.fanout_inventory_event();

create or replace function public.emit_inventory_event(
  p_business uuid, p_listing uuid, p_type public.inventory_event_type,
  p_significance text, p_payload jsonb, p_dedupe_suffix text default null
) returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.inventory_events (business_id, listing_id, type, significance, payload, dedupe_key)
  values (p_business, p_listing, p_type, p_significance, p_payload,
          concat_ws(':', p_type, coalesce(p_listing::text, p_business::text), public.lusaka_today(), p_dedupe_suffix))
  on conflict (dedupe_key) do nothing;
end $$;

-- Listing status transitions.
create or replace function public.listing_inventory_events()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_biz public.businesses;
begin
  select * into v_biz from public.businesses where id = new.business_id;
  if v_biz.onboarding_completed_at is null or new.moderation_status <> 'ok' then
    return new;
  end if;

  if new.status = 'published' and (tg_op = 'INSERT' or old.status <> 'published') then
    perform public.emit_inventory_event(new.business_id, new.id,
      case when tg_op = 'UPDATE' and old.status = 'paused' then 'stock_restored' else 'listing_published' end::public.inventory_event_type,
      'high', jsonb_build_object('quantity', new.total_quantity));
  elsif tg_op = 'UPDATE' and old.status = 'published' and new.status = 'paused' then
    perform public.emit_inventory_event(new.business_id, new.id, 'listing_paused', 'routine', '{}');
  elsif tg_op = 'UPDATE' and old.status = 'published' and new.status = 'archived' then
    perform public.emit_inventory_event(new.business_id, new.id, 'listing_removed', 'routine', '{}');
  elsif tg_op = 'UPDATE' and new.status = 'published' and old.damaged_quantity > new.damaged_quantity
        and old.damaged_quantity - new.damaged_quantity >= greatest(10, new.total_quantity / 10) then
    perform public.emit_inventory_event(new.business_id, new.id, 'stock_restored', 'routine',
      jsonb_build_object('restored', old.damaged_quantity - new.damaged_quantity));
  end if;
  return new;
end $$;

create trigger listings_inventory_events
  after insert or update of status, damaged_quantity on public.listings
  for each row execute function public.listing_inventory_events();

-- Stock increases. Significant = at least 20 units or 25% more stock.
create or replace function public.stock_inventory_events()
returns trigger language plpgsql security definer set search_path = public as $$
declare l public.listings;
begin
  if new.delta <= 0 or new.reason = 'initial' then return new; end if;
  select * into l from public.listings where id = new.listing_id;
  if l.status <> 'published' or l.moderation_status <> 'ok' then return new; end if;
  if new.delta >= 20 or new.delta * 4 >= l.total_quantity then
    perform public.emit_inventory_event(l.business_id, l.id, 'stock_added',
      case when new.delta >= 50 then 'high' else 'routine' end,
      jsonb_build_object('delta', new.delta, 'total', l.total_quantity + new.delta));
  end if;
  return new;
end $$;

create trigger stock_adjustments_events
  after insert on public.stock_adjustments
  for each row execute function public.stock_inventory_events();

-- Reopening dates (deleting a block) tells subscribers those dates are bookable.
create or replace function public.block_inventory_events()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.ends_on >= public.lusaka_today() then
    perform public.emit_inventory_event(old.business_id, old.listing_id, 'availability_opened',
      case when old.ends_on - old.starts_on >= 1 then 'high' else 'routine' end,
      jsonb_build_object('from', greatest(old.starts_on, public.lusaka_today()), 'to', old.ends_on),
      old.starts_on::text);
  end if;
  return old;
end $$;

create trigger availability_blocks_events
  after delete on public.availability_blocks
  for each row execute function public.block_inventory_events();

-- ---------------------------------------------------------------------------
-- Digests: one summary notification per business per day, built at the
-- business's digest hour from undelivered digest rows.
-- ---------------------------------------------------------------------------
create or replace function public.build_digests()
returns int language plpgsql security definer set search_path = public as $$
declare
  b record;
  v_count int := 0;
  v_inv int; v_tasks int;
begin
  for b in
    select p.business_id from public.notification_preferences p
    where p.digest_hour = extract(hour from now() at time zone 'Africa/Lusaka')
  loop
    select count(*) filter (where n.category = 'inventory'), count(*) filter (where n.category = 'task')
      into v_inv, v_tasks
      from public.notification_deliveries d
      join public.notifications n on n.id = d.notification_id
     where n.recipient_business_id = b.business_id and d.channel = 'digest' and d.status = 'pending';

    select v_tasks + count(*) into v_tasks from public.tasks t
     where t.business_id = b.business_id and t.status in ('todo', 'in_progress')
       and (t.due_at at time zone 'Africa/Lusaka')::date = public.lusaka_today();

    if v_inv + v_tasks > 0 then
      perform public.notify(b.business_id, 'system', 'Your day at a glance',
        concat_ws(' · ',
          case when v_tasks > 0 then v_tasks || ' task' || case when v_tasks = 1 then '' else 's' end || ' due today' end,
          case when v_inv > 0 then v_inv || ' supplier update' || case when v_inv = 1 then '' else 's' end end),
        'digest:' || public.lusaka_today(), '/notifications', '{}', 'immediate');
      update public.notification_deliveries d set status = 'sent', sent_at = now()
        from public.notifications n
       where n.id = d.notification_id and n.recipient_business_id = b.business_id
         and d.channel = 'digest' and d.status = 'pending';
      v_count := v_count + 1;
    end if;
  end loop;
  return v_count;
end $$;

-- Security hardening from beta QA (SEC-1, SEC-2, SEC-3).
--
-- SEC-2  Postgres lets PUBLIC execute every new function, so signed-out
--        visitors could call internal functions (e.g. release_stale_push_claims).
--        Now: nobody but the owner and service_role may execute anything in
--        public, except an explicit allow-list for signed-in users.
-- SEC-3  Functions that took an id and trusted the caller now check access.
-- SEC-1  Evenda Now showed requesters distances measured to a supplier's exact
--        pin (10 m resolution). Three requests could pinpoint a vendor who chose
--        "approximate". Requesters now get distances to the public point.

-- ---------------------------------------------------------------------------
-- SEC-2: default deny, then allow-list.
-- Trigger functions need no EXECUTE grant to fire; pg_cron runs as owner;
-- the send-push Edge Function uses service_role.
-- ---------------------------------------------------------------------------
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f'
       and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e') -- skip extension functions
  loop
    execute format('revoke execute on function %s from public, anon, authenticated', f.sig);
    execute format('grant execute on function %s to service_role', f.sig);
  end loop;
end $$;

-- Future functions start closed too.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- What the Flutter app calls (lib/data/supabase/supabase_backend.dart), plus
-- helpers referenced inside RLS and storage policies, which run as the caller.
do $$
declare
  fn text;
  f record;
  allowed text[] := array[
    -- policy helpers
    'is_member', 'can_manage', 'admin_has', 'my_business_ids', 'lusaka_today',
    -- app RPCs
    'accept_quotation', 'adjust_stock', 'availability_calendar', 'available_quantity',
    'broadcast_now_request', 'close_now_request', 'complete_inspection', 'complete_onboarding',
    'confirm_payment', 'create_business', 'create_event_from_booking', 'create_listing',
    'create_now_request', 'create_quote_request', 'decline_now_request', 'decline_quote_request',
    'generate_event_tasks', 'inventory_conflicts', 'move_reservation', 'my_admin_role',
    'my_business_location', 'now_request_map', 'open_dispute', 'post_quote_message',
    'record_manual_reservation', 'record_payment', 'register_device', 'select_now_offer',
    'send_quotation', 'set_business_location', 'set_damaged', 'snooze_task',
    'submit_for_verification', 'submit_now_offer', 'update_booking_status', 'workload',
    -- admin console (each checks admin_has internally)
    'admin_list_businesses', 'admin_moderate_listing', 'admin_platform_stats',
    'admin_resolve_dispute', 'admin_set_business_status', 'admin_set_verification',
    'admin_upsert_category', 'admin_grant_role'
  ];
begin
  foreach fn in array allowed loop
    for f in
      select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = fn
    loop
      execute format('grant execute on function %s to authenticated', f.sig);
    end loop;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- SEC-3: access checks on id-taking functions.
-- ---------------------------------------------------------------------------

create or replace function public.available_quantity(
  p_listing uuid, p_from date, p_to date, p_exclude_booking uuid default null
) returns int language plpgsql stable security definer set search_path = public as $$
declare
  l public.listings;
  v_usable int;
  v_peak int;
begin
  select * into l from public.listings where id = p_listing;
  if not found then return 0; end if;
  if not (public.is_member(l.business_id) or (l.status = 'published' and l.moderation_status = 'ok')) then
    return 0; -- drafts and moderated listings reveal nothing to outsiders
  end if;
  if not l.tracks_stock then return 2147483647; end if;

  if exists (
    select 1 from public.availability_blocks b
    where b.business_id = l.business_id
      and (b.listing_id is null or b.listing_id = l.id)
      and b.starts_on <= p_to and b.ends_on >= p_from
  ) then
    return 0;
  end if;

  v_usable := l.total_quantity - l.damaged_quantity - l.inspection_quantity;

  select coalesce(max(day_total), 0) into v_peak
  from (
    select d::date as day, sum(r.quantity) as day_total
    from generate_series(p_from, p_to, interval '1 day') d
    join public.reservations r
      on r.listing_id = l.id
     and r.status in ('held', 'confirmed', 'dispatched')
     and d::date between r.starts_on and r.ends_on
     and (p_exclude_booking is null or r.booking_id is distinct from p_exclude_booking)
    group by d::date
  ) per_day;

  return greatest(v_usable - v_peak, 0);
end $$;

-- The per-day calendar shows reservation volumes, i.e. how busy a vendor is:
-- members only. Other vendors use available_quantity.
create or replace function public.availability_calendar(p_listing uuid, p_from date, p_to date)
returns table (day date, usable int, reserved int, available int, blocked boolean)
language sql stable security definer set search_path = public as $$
  select d::date,
         (l.total_quantity - l.damaged_quantity - l.inspection_quantity),
         coalesce(sum(r.quantity) filter (where r.id is not null), 0)::int,
         case when bool_or(b.id is not null) then 0
              else greatest(l.total_quantity - l.damaged_quantity - l.inspection_quantity
                            - coalesce(sum(r.quantity) filter (where r.id is not null), 0), 0)::int end,
         bool_or(b.id is not null)
  from public.listings l
  cross join generate_series(p_from, p_to, interval '1 day') d
  left join public.reservations r
    on r.listing_id = l.id and r.status in ('held', 'confirmed', 'dispatched')
   and d::date between r.starts_on and r.ends_on
  left join public.availability_blocks b
    on b.business_id = l.business_id and (b.listing_id is null or b.listing_id = l.id)
   and d::date between b.starts_on and b.ends_on
  where l.id = p_listing and p_to - p_from <= 92 and public.is_member(l.business_id)
  group by d::date, l.total_quantity, l.damaged_quantity, l.inspection_quantity
  order by 1;
$$;

-- Candidate suppliers: only the requester's own business may look.
create or replace function public.now_eligible_suppliers(p_request uuid)
returns table (business_id uuid, listing_id uuid, distance_km numeric, available_quantity int)
language plpgsql stable security definer set search_path = public as $$
declare rq public.now_requests;
begin
  select * into rq from public.now_requests where id = p_request;
  if not found then return; end if;
  perform public.require_member(rq.requester_business_id);
  return query
  select distinct on (b.id)
         b.id, l.id,
         round((extensions.st_distance(b.location, rq.location) / 1000)::numeric, 2),
         public.available_quantity(l.id, rq.needed_from, rq.needed_to)
    from public.businesses b
    join public.notification_preferences p on p.business_id = b.id and p.now_requests
    join public.listings l on l.business_id = b.id and l.category_id = rq.category_id
                          and l.status = 'published' and l.moderation_status = 'ok'
   where b.id <> rq.requester_business_id
     and b.status = 'active' and b.onboarding_completed_at is not null and b.location is not null
     and extensions.st_dwithin(b.location, rq.location, least(rq.radius_km, b.service_radius_km) * 1000)
     and public.available_quantity(l.id, rq.needed_from, rq.needed_to) > 0
   order by b.id, public.available_quantity(l.id, rq.needed_from, rq.needed_to) desc;
end $$;

-- ---------------------------------------------------------------------------
-- SEC-1: requesters see distance to the public point for approximate vendors.
-- (Matching and the radius check still use the exact pin, server-side.)
-- ---------------------------------------------------------------------------
create or replace function public.now_request_map(p_request uuid)
returns table (business_id uuid, name text, logo_path text, category_id text, lat float8, lng float8,
               distance_km numeric, available_quantity int, has_offer boolean, declined boolean, approximate boolean)
language plpgsql stable security definer set search_path = public as $$
declare rq public.now_requests;
begin
  select * into rq from public.now_requests where id = p_request;
  perform public.require_member(rq.requester_business_id);
  return query
  select b.id, b.name, b.logo_path, rq.category_id,
         extensions.st_y(b.public_location::extensions.geometry), extensions.st_x(b.public_location::extensions.geometry),
         case when b.location_precision = 'approximate'
              then round((extensions.st_distance(b.public_location, rq.location) / 1000)::numeric, 1)
              else r.distance_km end,
         r.available_quantity,
         exists (select 1 from public.now_offers o where o.request_id = p_request and o.supplier_business_id = b.id and o.status in ('pending', 'selected')),
         r.declined_at is not null,
         b.location_precision = 'approximate'
    from public.now_request_recipients r
    join public.businesses b on b.id = r.business_id
   where r.request_id = p_request
   order by r.distance_km;
end $$;

-- Re-apply the allow-list to the functions recreated above (create or replace
-- keeps grants, but be explicit so this file is correct on its own).
revoke execute on function public.available_quantity(uuid, date, date, uuid) from public, anon;
revoke execute on function public.availability_calendar(uuid, date, date) from public, anon;
revoke execute on function public.now_eligible_suppliers(uuid) from public, anon, authenticated;
revoke execute on function public.now_request_map(uuid) from public, anon;
grant execute on function public.available_quantity(uuid, date, date, uuid) to authenticated, service_role;
grant execute on function public.availability_calendar(uuid, date, date) to authenticated, service_role;
grant execute on function public.now_eligible_suppliers(uuid) to service_role;
grant execute on function public.now_request_map(uuid) to authenticated, service_role;

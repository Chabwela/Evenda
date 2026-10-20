-- Marketplace quantity: how many of an item a vendor offers to other vendors.
--
-- listings.listed_quantity (null = everything usable). If a vendor owns 300
-- chairs but offers 200, other vendors can never book more than 200 on any
-- day, even when all 300 are free; the rest stay for the vendor's own jobs.
-- The cap counts marketplace commitments only (bookings and Evenda Now);
-- the vendor's own recorded jobs still use the full stock.

alter table public.listings add column if not exists listed_quantity int
  check (listed_quantity is null or listed_quantity >= 0);

drop function if exists public.available_quantity(uuid, date, date, uuid);

-- p_marketplace: apply the offer cap. Default: yes for anyone outside the
-- business (search, quotes, Evenda Now), no for the business itself.
create or replace function public.available_quantity(
  p_listing uuid, p_from date, p_to date, p_exclude_booking uuid default null, p_marketplace boolean default null
) returns int language plpgsql stable security definer set search_path = public as $$
declare
  l public.listings;
  v_member boolean;
  v_usable int;
  v_peak int;
  v_free int;
  v_market_peak int;
begin
  select * into l from public.listings where id = p_listing;
  if not found then return 0; end if;
  v_member := public.is_member(l.business_id);
  if not (v_member or (l.status = 'published' and l.moderation_status = 'ok')) then
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
    select sum(r.quantity) as day_total
    from generate_series(p_from, p_to, interval '1 day') d
    join public.reservations r
      on r.listing_id = l.id
     and r.status in ('held', 'confirmed', 'dispatched')
     and d::date between r.starts_on and r.ends_on
     and (p_exclude_booking is null or r.booking_id is distinct from p_exclude_booking)
    group by d::date
  ) per_day;
  v_free := greatest(v_usable - v_peak, 0);

  if l.listed_quantity is not null and coalesce(p_marketplace, not v_member) then
    select coalesce(max(day_total), 0) into v_market_peak
    from (
      select sum(r.quantity) as day_total
      from generate_series(p_from, p_to, interval '1 day') d
      join public.reservations r
        on r.listing_id = l.id
       and r.source in ('booking', 'now')
       and r.status in ('held', 'confirmed', 'dispatched')
       and d::date between r.starts_on and r.ends_on
       and (p_exclude_booking is null or r.booking_id is distinct from p_exclude_booking)
      group by d::date
    ) per_day;
    v_free := least(v_free, greatest(l.listed_quantity - v_market_peak, 0));
  end if;

  return v_free;
end $$;

revoke execute on function public.available_quantity(uuid, date, date, uuid, boolean) from public, anon;
grant execute on function public.available_quantity(uuid, date, date, uuid, boolean) to authenticated, service_role;

-- Bookings and Evenda Now respect the offer cap; manual jobs do not.
create or replace function public.reserve_stock(
  p_listing uuid, p_quantity int, p_from date, p_to date,
  p_source public.reservation_source, p_booking uuid default null,
  p_client_label text default null, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare
  l public.listings;
  v_available int;
  v_id uuid;
begin
  select * into l from public.listings where id = p_listing for update;
  if not found then
    raise exception 'listing_not_found' using errcode = 'P0002';
  end if;
  if p_to < p_from then
    raise exception 'invalid_dates' using errcode = '22023';
  end if;
  if p_from < public.lusaka_today() then
    raise exception 'dates_in_past' using errcode = '22023';
  end if;

  v_available := public.available_quantity(p_listing, p_from, p_to, null, p_source in ('booking', 'now'));
  if v_available < p_quantity then
    raise exception 'insufficient_availability'
      using errcode = 'P0001',
            detail = json_build_object('listing_id', p_listing, 'requested', p_quantity, 'available', v_available)::text;
  end if;

  insert into public.reservations (listing_id, business_id, quantity, starts_on, ends_on, source, booking_id, client_label, note)
  values (p_listing, l.business_id, p_quantity, p_from, p_to, p_source, p_booking, p_client_label, p_note)
  returning id into v_id;
  return v_id;
end $$;

-- A supplier can only offer what they make available to the marketplace.
create or replace function public.submit_now_offer(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  rq public.now_requests;
  v_supplier uuid := (p->>'supplier_business_id')::uuid;
  v_listing uuid := (p->>'listing_id')::uuid;
  v_qty int := (p->>'quantity')::int;
  v_available int;
  v_id uuid;
  v_name text;
begin
  perform public.require_member(v_supplier, true);
  select * into rq from public.now_requests where id = (p->>'request_id')::uuid for update;
  if not found then raise exception 'request_not_found' using errcode = 'P0002'; end if;
  if not exists (select 1 from public.now_request_recipients where request_id = rq.id and business_id = v_supplier) then
    raise exception 'not_a_recipient' using errcode = '42501';
  end if;
  if rq.status not in ('broadcasting', 'receiving_offers', 'offer_selected') or rq.expires_at < now() then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.listings where id = v_listing and business_id = v_supplier and status = 'published') then
    raise exception 'listing_not_from_supplier' using errcode = '22023';
  end if;
  v_available := public.available_quantity(v_listing, rq.needed_from, rq.needed_to, null, true);
  if v_qty > v_available then
    raise exception 'insufficient_availability' using errcode = 'P0001',
      detail = json_build_object('requested', v_qty, 'available', v_available)::text;
  end if;

  select id into v_id from public.now_offers
   where request_id = rq.id and supplier_business_id = v_supplier and status = 'pending';
  if v_id is not null then
    update public.now_offers
       set listing_id = v_listing, quantity = v_qty, unit_price = (p->>'unit_price')::numeric,
           total = v_qty * (p->>'unit_price')::numeric, can_deliver = coalesce((p->>'can_deliver')::boolean, false),
           note = coalesce(p->>'note', ''), updated_at = now()
     where id = v_id;
  else
    insert into public.now_offers (request_id, supplier_business_id, listing_id, quantity, unit_price, total, can_deliver, note)
    values (rq.id, v_supplier, v_listing, v_qty, (p->>'unit_price')::numeric, v_qty * (p->>'unit_price')::numeric,
            coalesce((p->>'can_deliver')::boolean, false), coalesce(p->>'note', ''))
    returning id into v_id;
  end if;

  if rq.status = 'broadcasting' then
    perform public.now_set_status(rq.id, 'receiving_offers', 'First offer received');
  end if;

  select name into v_name from public.businesses where id = v_supplier;
  perform public.notify(rq.requester_business_id, 'now', v_name || ' can supply ' || v_qty || ' × ' || rq.item_description,
    'ZMW ' || to_char(v_qty * (p->>'unit_price')::numeric, 'FM999,999,990.00') || ' total',
    'now-offer:' || v_id || ':' || extract(epoch from now())::bigint, '/now/' || rq.id,
    jsonb_build_object('request_id', rq.id, 'offer_id', v_id), 'immediate', null, true);
  return v_id;
end $$;

-- Keep internal functions closed (function lockdown, 20261019000100).
revoke execute on function public.reserve_stock(uuid, int, date, date, public.reservation_source, uuid, text, text) from public, anon, authenticated;

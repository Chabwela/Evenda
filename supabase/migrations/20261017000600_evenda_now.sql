-- Evenda Now: urgent vendor-to-vendor requests.
--
-- Eligibility (all server-side):
--   * active, onboarded supplier other than the requester, with a location
--   * a published, unmoderated listing in the requested category
--   * date-aware available quantity > 0 for the requested day(s)
--   * within both the request radius and the supplier's own service radius
--   * supplier has Evenda Now requests switched on
-- Requesters see suppliers at their public (possibly rounded) location only.

create type public.now_status as enum (
  'draft', 'broadcasting', 'receiving_offers', 'offer_selected', 'booking_confirmed',
  'completed', 'cancelled', 'expired'
);
create type public.now_offer_status as enum ('pending', 'selected', 'rejected', 'withdrawn', 'expired');

create table public.now_requests (
  id uuid primary key default gen_random_uuid(),
  requester_business_id uuid not null references public.businesses (id),
  status public.now_status not null default 'draft',
  category_id text not null references public.categories (id),
  item_description text not null check (char_length(item_description) between 2 and 140),
  quantity int not null check (quantity > 0),
  needed_from date not null,
  needed_to date not null,
  needed_by_time time,
  fulfilment public.fulfilment not null default 'pickup',
  location extensions.geography(point, 4326) not null,
  location_label text not null,
  radius_km int not null default 15 check (radius_km between 1 and 100),
  max_budget numeric(12, 2) check (max_budget is null or max_budget >= 0),
  notes text not null default '',
  expires_at timestamptz not null,
  broadcast_at timestamptz,
  recipients_count int not null default 0,
  idempotency_key uuid not null unique,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (needed_to >= needed_from),
  check (needed_to - needed_from <= 14)
);

create index now_requests_requester_idx on public.now_requests (requester_business_id, created_at desc);
create index now_requests_open_idx on public.now_requests (expires_at) where status in ('broadcasting', 'receiving_offers', 'offer_selected');

create table public.now_request_recipients (
  request_id uuid not null references public.now_requests (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  listing_id uuid references public.listings (id),
  distance_km numeric(6, 2) not null,
  available_quantity int not null,
  notified_at timestamptz not null default now(),
  seen_at timestamptz,
  declined_at timestamptz,
  primary key (request_id, business_id)
);

create table public.now_offers (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.now_requests (id) on delete cascade,
  supplier_business_id uuid not null references public.businesses (id),
  listing_id uuid not null references public.listings (id),
  quantity int not null check (quantity > 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  total numeric(12, 2) not null,
  can_deliver boolean not null default false,
  note text not null default '',
  status public.now_offer_status not null default 'pending',
  booking_id uuid references public.bookings (id),
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- One live offer per supplier per request.
create unique index now_offers_one_live_idx on public.now_offers (request_id, supplier_business_id)
  where status in ('pending', 'selected');

alter table public.bookings add constraint bookings_now_offer_fk foreign key (now_offer_id) references public.now_offers (id);

create table public.now_status_history (
  id bigint generated always as identity primary key,
  request_id uuid not null references public.now_requests (id) on delete cascade,
  from_status public.now_status,
  to_status public.now_status not null,
  note text,
  created_at timestamptz not null default now()
);

create or replace function public.now_set_status(p_request uuid, p_to public.now_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_from public.now_status;
begin
  select status into v_from from public.now_requests where id = p_request;
  if v_from = p_to then return; end if;
  update public.now_requests set status = p_to, updated_at = now() where id = p_request;
  insert into public.now_status_history (request_id, from_status, to_status, note) values (p_request, v_from, p_to, p_note);
end $$;

-- Candidate suppliers for a request (also used to preview before broadcasting).
create or replace function public.now_eligible_suppliers(p_request uuid)
returns table (business_id uuid, listing_id uuid, distance_km numeric, available_quantity int)
language sql stable security definer set search_path = public as $$
  with req as (select * from public.now_requests where id = p_request)
  select distinct on (b.id)
         b.id, l.id,
         round((extensions.st_distance(b.location, req.location) / 1000)::numeric, 2),
         public.available_quantity(l.id, req.needed_from, req.needed_to)
    from req
    join public.businesses b on b.id <> req.requester_business_id
    join public.notification_preferences p on p.business_id = b.id and p.now_requests
    join public.listings l on l.business_id = b.id and l.category_id = req.category_id
                          and l.status = 'published' and l.moderation_status = 'ok'
   where b.status = 'active' and b.onboarding_completed_at is not null and b.location is not null
     and extensions.st_dwithin(b.location, req.location, least(req.radius_km, b.service_radius_km) * 1000)
     and public.available_quantity(l.id, req.needed_from, req.needed_to) > 0
   order by b.id, public.available_quantity(l.id, req.needed_from, req.needed_to) desc;
$$;

create or replace function public.create_now_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_business uuid := (p->>'requester_business_id')::uuid;
begin
  perform public.require_member(v_business);
  select id into v_id from public.now_requests where idempotency_key = (p->>'idempotency_key')::uuid;
  if v_id is not null then return v_id; end if;
  if (p->>'needed_from')::date < public.lusaka_today() then
    raise exception 'dates_in_past' using errcode = '22023';
  end if;
  insert into public.now_requests (requester_business_id, category_id, item_description, quantity, needed_from, needed_to,
                                   needed_by_time, fulfilment, location, location_label, radius_km, max_budget, notes,
                                   expires_at, idempotency_key)
  values (v_business, p->>'category_id', p->>'item_description', (p->>'quantity')::int,
          (p->>'needed_from')::date, coalesce((p->>'needed_to')::date, (p->>'needed_from')::date),
          (p->>'needed_by_time')::time, coalesce((p->>'fulfilment')::public.fulfilment, 'pickup'),
          extensions.st_setsrid(extensions.st_makepoint((p->>'lng')::float8, (p->>'lat')::float8), 4326)::extensions.geography,
          p->>'location_label', coalesce((p->>'radius_km')::int, 15), (p->>'max_budget')::numeric, coalesce(p->>'notes', ''),
          -- Expire at the earlier of 6 hours from now or the start of the needed day.
          least(now() + interval '6 hours',
                greatest(now() + interval '1 hour', ((p->>'needed_from')::date + coalesce((p->>'needed_by_time')::time, time '08:00')) at time zone 'Africa/Lusaka')),
          (p->>'idempotency_key')::uuid)
  returning id into v_id;
  insert into public.now_status_history (request_id, to_status) values (v_id, 'draft');
  return v_id;
end $$;

-- Broadcast. Returns number of suppliers notified. If none qualify the request
-- stays in draft so the requester can widen the radius, change the date or quantity.
create or replace function public.broadcast_now_request(p_request uuid, p_radius_km int default null)
returns int language plpgsql security definer set search_path = public as $$
declare
  rq public.now_requests;
  c record;
  v_count int := 0;
  v_name text;
begin
  select * into rq from public.now_requests where id = p_request for update;
  if not found then raise exception 'request_not_found' using errcode = 'P0002'; end if;
  perform public.require_member(rq.requester_business_id);
  if rq.status not in ('draft', 'broadcasting', 'receiving_offers') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if p_radius_km is not null then
    update public.now_requests set radius_km = p_radius_km where id = p_request;
  end if;

  select name into v_name from public.businesses where id = rq.requester_business_id;

  for c in select * from public.now_eligible_suppliers(p_request) order by distance_km limit 30 loop
    insert into public.now_request_recipients (request_id, business_id, listing_id, distance_km, available_quantity)
    values (p_request, c.business_id, c.listing_id, c.distance_km, c.available_quantity)
    on conflict (request_id, business_id) do nothing;
    if found then
      v_count := v_count + 1;
      perform public.notify(c.business_id, 'now',
        'Evenda Now · ' || rq.quantity || ' × ' || rq.item_description,
        v_name || ' needs this ' || to_char(rq.needed_from, 'Dy DD Mon') || ' · ' || c.distance_km || ' km away',
        'now:' || p_request, '/now/respond/' || p_request, jsonb_build_object('request_id', p_request),
        'immediate', null, true);
    end if;
  end loop;

  update public.now_requests
     set recipients_count = (select count(*) from public.now_request_recipients where request_id = p_request),
         broadcast_at = coalesce(broadcast_at, now())
   where id = p_request;

  if (select recipients_count from public.now_requests where id = p_request) > 0 and rq.status = 'draft' then
    perform public.now_set_status(p_request, 'broadcasting');
  end if;
  return v_count;
end $$;

-- What the requester's map shows: public locations only.
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
         r.distance_km, r.available_quantity,
         exists (select 1 from public.now_offers o where o.request_id = p_request and o.supplier_business_id = b.id and o.status in ('pending', 'selected')),
         r.declined_at is not null,
         b.location_precision = 'approximate'
    from public.now_request_recipients r
    join public.businesses b on b.id = r.business_id
   where r.request_id = p_request
   order by r.distance_km;
end $$;

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
  v_available := public.available_quantity(v_listing, rq.needed_from, rq.needed_to);
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

create or replace function public.decline_now_request(p_request uuid, p_supplier uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_member(p_supplier);
  update public.now_request_recipients set declined_at = now()
   where request_id = p_request and business_id = p_supplier;
  update public.now_offers set status = 'withdrawn', updated_at = now()
   where request_id = p_request and supplier_business_id = p_supplier and status = 'pending';
end $$;

-- Requester selects an offer. Rechecks availability by reserving stock and creates
-- a linked booking. Several offers can be selected until the quantity is covered.
create or replace function public.select_now_offer(p_offer uuid, p_idempotency_key uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  o public.now_offers;
  rq public.now_requests;
  v_booking uuid;
  v_covered int;
  v_requester_name text;
  v_title text;
begin
  select id into v_booking from public.bookings where now_offer_id = p_offer or idempotency_key = p_idempotency_key;
  if v_booking is not null then return v_booking; end if;

  select * into o from public.now_offers where id = p_offer for update;
  if not found then raise exception 'offer_not_found' using errcode = 'P0002'; end if;
  select * into rq from public.now_requests where id = o.request_id for update;
  perform public.require_member(rq.requester_business_id, true);
  if o.status <> 'pending' then raise exception 'offer_not_open' using errcode = 'P0001'; end if;
  if rq.status not in ('receiving_offers', 'offer_selected') then raise exception 'request_closed' using errcode = 'P0001'; end if;

  select title into v_title from public.listings where id = o.listing_id;

  insert into public.bookings (source, now_offer_id, requester_business_id, supplier_business_id, starts_on, ends_on,
                               total, fulfilment, delivery_notes, idempotency_key)
  values ('now', o.id, rq.requester_business_id, o.supplier_business_id, rq.needed_from, rq.needed_to, o.total,
          case when o.can_deliver and rq.fulfilment <> 'pickup' then rq.fulfilment else 'pickup' end,
          rq.location_label, p_idempotency_key)
  returning id into v_booking;
  insert into public.booking_items (booking_id, listing_id, description, quantity, unit_price, line_total)
  values (v_booking, o.listing_id, v_title, o.quantity, o.unit_price, o.total);

  select name into v_requester_name from public.businesses where id = rq.requester_business_id;
  perform public.reserve_stock(o.listing_id, o.quantity, rq.needed_from, rq.needed_to, 'now', v_booking, v_requester_name);

  update public.now_offers set status = 'selected', booking_id = v_booking, updated_at = now() where id = o.id;
  insert into public.booking_status_history (booking_id, to_status, note) values (v_booking, 'confirmed', 'Evenda Now offer selected');

  select coalesce(sum(quantity), 0) into v_covered from public.now_offers where request_id = rq.id and status = 'selected';
  if v_covered >= rq.quantity then
    update public.now_offers set status = 'rejected', updated_at = now() where request_id = rq.id and status = 'pending';
    perform public.now_set_status(rq.id, 'booking_confirmed', 'Quantity covered');
  else
    perform public.now_set_status(rq.id, 'offer_selected', v_covered || ' of ' || rq.quantity || ' covered');
  end if;

  perform public.notify(o.supplier_business_id, 'now', v_requester_name || ' selected your offer',
    o.quantity || ' × ' || v_title || ' · booking confirmed and stock reserved',
    'now-sel:' || o.id, '/bookings/' || v_booking, jsonb_build_object('booking_id', v_booking), 'immediate', null, true);
  perform public.generate_booking_tasks(v_booking);
  return v_booking;
end $$;

create or replace function public.close_now_request(p_request uuid, p_to public.now_status)
returns void language plpgsql security definer set search_path = public as $$
declare rq public.now_requests;
begin
  select * into rq from public.now_requests where id = p_request for update;
  perform public.require_member(rq.requester_business_id);
  if p_to not in ('cancelled', 'completed') then raise exception 'invalid_transition' using errcode = '22023'; end if;
  if p_to = 'cancelled' and rq.status in ('booking_confirmed', 'completed') then
    raise exception 'invalid_transition' using errcode = 'P0001', hint = 'Cancel the linked bookings instead.';
  end if;
  update public.now_offers set status = 'expired', updated_at = now() where request_id = p_request and status = 'pending';
  perform public.now_set_status(p_request, p_to);
end $$;

create or replace function public.expire_now_requests()
returns int language plpgsql security definer set search_path = public as $$
declare r record; v_count int := 0;
begin
  for r in select id, status from public.now_requests
            where status in ('draft', 'broadcasting', 'receiving_offers') and expires_at < now()
            for update skip locked loop
    update public.now_offers set status = 'expired', updated_at = now() where request_id = r.id and status = 'pending';
    perform public.now_set_status(r.id, 'expired', 'No selection before expiry');
    v_count := v_count + 1;
  end loop;
  -- Partially covered requests close as confirmed at expiry.
  for r in select id from public.now_requests where status = 'offer_selected' and expires_at < now() for update skip locked loop
    update public.now_offers set status = 'expired', updated_at = now() where request_id = r.id and status = 'pending';
    perform public.now_set_status(r.id, 'booking_confirmed', 'Expired with partial cover');
  end loop;
  return v_count;
end $$;

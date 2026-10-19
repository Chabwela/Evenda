-- Listings, inventory and date-aware availability.
--
-- Model:
--   total_quantity       stock the vendor owns (changed only through stock_adjustments)
--   damaged_quantity     out of service until repaired
--   inspection_quantity  returned from a job, awaiting inspection
--   usable               = total - damaged - inspection
--   reservations         date ranges holding quantity (bookings, manual jobs, Evenda Now)
--   availability_blocks  dates the vendor has closed (whole business or a listing)
--
-- Services use the same machinery with total_quantity = jobs per day (capacity).

create type public.listing_status as enum ('draft', 'published', 'paused', 'archived');
create type public.price_unit as enum (
  'per_item_per_day', 'per_item_per_event', 'per_event', 'per_hour', 'per_package', 'on_quote'
);
create type public.moderation_status as enum ('ok', 'flagged', 'removed');
create type public.reservation_source as enum ('booking', 'manual', 'now');
create type public.reservation_status as enum ('held', 'confirmed', 'dispatched', 'returned', 'cancelled');

create table public.listings (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  kind public.offering_type not null,
  title text not null check (char_length(title) between 2 and 90),
  description text not null default '' check (char_length(description) <= 2000),
  category_id text not null references public.categories (id),
  status public.listing_status not null default 'draft',
  price_amount numeric(12, 2) check (price_amount is null or price_amount >= 0),
  price_unit public.price_unit not null default 'on_quote',
  deposit_amount numeric(12, 2) check (deposit_amount is null or deposit_amount >= 0),
  deposit_note text,
  terms text not null default '',
  condition text check (condition is null or condition in ('new', 'excellent', 'good', 'fair')),
  total_quantity int not null default 0 check (total_quantity >= 0),
  damaged_quantity int not null default 0 check (damaged_quantity >= 0),
  inspection_quantity int not null default 0 check (inspection_quantity >= 0),
  tracks_stock boolean not null default true,
  service_area_km int check (service_area_km is null or service_area_km between 1 and 500),
  package_items jsonb not null default '[]'::jsonb,
  moderation_status public.moderation_status not null default 'ok',
  moderation_reason text,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (damaged_quantity + inspection_quantity <= total_quantity),
  -- A published listing must have a usable price basis and, for stock, a quantity.
  check (status <> 'published' or (price_unit = 'on_quote' or price_amount is not null)),
  check (status <> 'published' or not tracks_stock or total_quantity > 0)
);

create index listings_business_idx on public.listings (business_id);
create index listings_discovery_idx on public.listings (category_id, status) where status = 'published' and moderation_status = 'ok';
create index listings_title_trgm_idx on public.listings using gin (to_tsvector('simple', title || ' ' || description));

create table public.listing_photos (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  storage_path text not null,
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- Every stock change is a ledger row. total_quantity is derived from it.
create table public.stock_adjustments (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  delta int not null check (delta <> 0),
  reason text not null check (reason in ('initial', 'purchase', 'loss', 'write_off', 'correction')),
  note text,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.reservations (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.listings (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  quantity int not null check (quantity > 0),
  starts_on date not null,
  ends_on date not null,
  source public.reservation_source not null,
  booking_id uuid,
  status public.reservation_status not null default 'confirmed',
  client_label text,
  note text,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_on >= starts_on),
  check (ends_on - starts_on <= 60)
);

create index reservations_window_idx on public.reservations (listing_id, starts_on, ends_on)
  where status in ('held', 'confirmed', 'dispatched');

create table public.availability_blocks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  listing_id uuid references public.listings (id) on delete cascade,
  starts_on date not null,
  ends_on date not null,
  reason text,
  created_at timestamptz not null default now(),
  check (ends_on >= starts_on)
);

create index availability_blocks_idx on public.availability_blocks (business_id, starts_on, ends_on);

-- Marks the current transaction as running inside a trusted RPC so guard
-- triggers allow writes to protected columns.
create or replace function public.trust()
returns void language sql as $$ select set_config('evenda.trusted', 'on', true) $$;

-- ---------------------------------------------------------------------------
-- Availability
-- ---------------------------------------------------------------------------

-- Quantity free on every day of [p_from, p_to] (the minimum across the range).
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

-- Per-day breakdown for the availability calendar.
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
  where l.id = p_listing and p_to - p_from <= 92
  group by d::date, l.total_quantity, l.damaged_quantity, l.inspection_quantity
  order by 1;
$$;

-- The only way to hold stock. Locks the listing row so two concurrent
-- reservations cannot both pass the availability check.
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

  v_available := public.available_quantity(p_listing, p_from, p_to);
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

-- Client-callable: record a job taken outside Evenda so availability stays honest.
create or replace function public.record_manual_reservation(
  p_listing uuid, p_quantity int, p_from date, p_to date, p_client_label text, p_note text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare v_business uuid;
begin
  select business_id into v_business from public.listings where id = p_listing;
  perform public.require_member(v_business);
  return public.reserve_stock(p_listing, p_quantity, p_from, p_to, 'manual', null, p_client_label, p_note);
end $$;

-- Movement of physical stock through a job: dispatch, return, inspect.
create or replace function public.move_reservation(p_reservation uuid, p_action text, p_damaged int default 0)
returns void language plpgsql security definer set search_path = public as $$
declare r public.reservations;
begin
  perform public.trust();
  select * into r from public.reservations where id = p_reservation for update;
  if not found then raise exception 'reservation_not_found' using errcode = 'P0002'; end if;
  perform public.require_member(r.business_id);

  if p_action = 'dispatch' and r.status in ('held', 'confirmed') then
    update public.reservations set status = 'dispatched', updated_at = now() where id = r.id;
  elsif p_action = 'return' and r.status = 'dispatched' then
    update public.reservations set status = 'returned', updated_at = now() where id = r.id;
    update public.listings set inspection_quantity = inspection_quantity + r.quantity where id = r.listing_id;
  elsif p_action = 'cancel' and r.status in ('held', 'confirmed') and r.source = 'manual' then
    update public.reservations set status = 'cancelled', updated_at = now() where id = r.id;
  else
    raise exception 'invalid_transition' using errcode = 'P0001',
      detail = format('Cannot %s a reservation that is %s', p_action, r.status);
  end if;
end $$;

-- Close inspection: good units return to service, damaged ones are set aside.
create or replace function public.complete_inspection(p_listing uuid, p_good int, p_damaged int)
returns void language plpgsql security definer set search_path = public as $$
declare l public.listings;
begin
  perform public.trust();
  select * into l from public.listings where id = p_listing for update;
  perform public.require_member(l.business_id);
  if p_good < 0 or p_damaged < 0 or p_good + p_damaged > l.inspection_quantity then
    raise exception 'invalid_inspection_counts' using errcode = '22023';
  end if;
  update public.listings
     set inspection_quantity = inspection_quantity - p_good - p_damaged,
         damaged_quantity = damaged_quantity + p_damaged,
         updated_at = now()
   where id = p_listing;
end $$;

create or replace function public.set_damaged(p_listing uuid, p_damaged int)
returns void language plpgsql security definer set search_path = public as $$
declare l public.listings;
begin
  perform public.trust();
  select * into l from public.listings where id = p_listing for update;
  perform public.require_member(l.business_id, true);
  if p_damaged < 0 or p_damaged + l.inspection_quantity > l.total_quantity then
    raise exception 'invalid_damaged_count' using errcode = '22023';
  end if;
  update public.listings set damaged_quantity = p_damaged, updated_at = now() where id = p_listing;
end $$;

create or replace function public.adjust_stock(p_listing uuid, p_delta int, p_reason text, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare l public.listings; v_total int;
begin
  perform public.trust();
  select * into l from public.listings where id = p_listing for update;
  perform public.require_member(l.business_id, true);
  if l.total_quantity + p_delta < l.damaged_quantity + l.inspection_quantity then
    raise exception 'stock_below_out_of_service' using errcode = '22023';
  end if;
  insert into public.stock_adjustments (listing_id, delta, reason, note) values (p_listing, p_delta, p_reason, p_note);
  update public.listings set total_quantity = total_quantity + p_delta, updated_at = now()
   where id = p_listing returning total_quantity into v_total;
  return v_total;
end $$;

-- Inventory health: future dates where confirmed commitments exceed usable stock
-- (possible after damage or a write-off). Surfaces as a dashboard conflict.
create or replace function public.inventory_conflicts(p_business uuid, p_days int default 60)
returns table (listing_id uuid, title text, day date, usable int, committed int)
language sql stable security definer set search_path = public as $$
  select l.id, l.title, d::date,
         l.total_quantity - l.damaged_quantity - l.inspection_quantity,
         sum(r.quantity)::int
  from public.listings l
  join public.reservations r on r.listing_id = l.id and r.status in ('held', 'confirmed', 'dispatched')
  join generate_series(public.lusaka_today(), public.lusaka_today() + p_days, interval '1 day') d
    on d::date between r.starts_on and r.ends_on
  where l.business_id = p_business and l.tracks_stock and public.is_member(p_business)
  group by l.id, l.title, d::date, l.total_quantity, l.damaged_quantity, l.inspection_quantity
  having sum(r.quantity) > l.total_quantity - l.damaged_quantity - l.inspection_quantity
  order by d::date;
$$;

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$ begin new.updated_at := now(); return new; end $$;

create trigger listings_touch before update on public.listings
  for each row execute function public.touch_updated_at();

create or replace function public.stamp_published_at()
returns trigger language plpgsql as $$
begin
  if new.status = 'published' and (tg_op = 'INSERT' or old.status <> 'published') then
    new.published_at := coalesce(new.published_at, now());
  end if;
  return new;
end $$;

create trigger listings_published_at before insert or update of status on public.listings
  for each row execute function public.stamp_published_at();

-- Direct writes to the stock counters bypass the ledger; only RPCs may change them.
create or replace function public.guard_stock_columns()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('evenda.trusted', true), '') <> 'on'
     and current_setting('role', true) in ('authenticated', 'anon')
     and (new.total_quantity is distinct from old.total_quantity
          or new.damaged_quantity is distinct from old.damaged_quantity
          or new.inspection_quantity is distinct from old.inspection_quantity
          or new.moderation_status is distinct from old.moderation_status) then
    raise exception 'use_inventory_rpc' using errcode = '42501',
      hint = 'Stock and moderation fields change only through dedicated functions.';
  end if;
  return new;
end $$;

create trigger listings_guard_stock before update on public.listings
  for each row execute function public.guard_stock_columns();

-- Creating a listing with stock goes through this RPC so the ledger starts correctly.
create or replace function public.create_listing(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_business uuid := (p->>'business_id')::uuid; v_qty int := coalesce((p->>'total_quantity')::int, 0);
begin
  perform public.trust();
  perform public.require_member(v_business, true);
  insert into public.listings (business_id, kind, title, description, category_id, status, price_amount, price_unit,
                               deposit_amount, deposit_note, terms, condition, tracks_stock, service_area_km, package_items)
  values (v_business, (p->>'kind')::public.offering_type, p->>'title', coalesce(p->>'description', ''), p->>'category_id',
          'draft', (p->>'price_amount')::numeric, coalesce((p->>'price_unit')::public.price_unit, 'on_quote'),
          (p->>'deposit_amount')::numeric, p->>'deposit_note', coalesce(p->>'terms', ''), p->>'condition',
          coalesce((p->>'tracks_stock')::boolean, (p->>'kind') = 'rental'), (p->>'service_area_km')::int,
          coalesce(p->'package_items', '[]'::jsonb))
  returning id into v_id;
  if v_qty > 0 then
    insert into public.stock_adjustments (listing_id, delta, reason) values (v_id, v_qty, 'initial');
    update public.listings set total_quantity = v_qty where id = v_id;
  end if;
  if coalesce(p->>'status', 'draft') <> 'draft' then
    update public.listings set status = (p->>'status')::public.listing_status where id = v_id;
  end if;
  return v_id;
end $$;

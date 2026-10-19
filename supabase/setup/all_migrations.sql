-- Evenda: full schema setup. Generated from supabase/migrations (in order).
-- Paste into Supabase Dashboard -> SQL Editor -> Run, once, on an empty project.

-- ===== 20261017000100_core.sql =====
-- Evenda core schema: profiles, businesses, membership, categories.
-- All money is ZMW. All calendar dates are interpreted in Africa/Lusaka (UTC+2, no DST).

create extension if not exists postgis with schema extensions;
create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.offering_type as enum ('rental', 'service', 'package');
create type public.member_role as enum ('owner', 'manager', 'staff');
create type public.member_status as enum ('active', 'invited', 'removed');
create type public.verification_status as enum ('unverified', 'pending', 'verified', 'rejected');
create type public.business_status as enum ('active', 'suspended');
create type public.location_precision as enum ('exact', 'approximate');

-- ---------------------------------------------------------------------------
-- Profiles (one per auth user; credentials live only in auth.users)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '' check (char_length(full_name) <= 120),
  phone text check (phone ~ '^\+260[0-9]{9}$'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, phone)
  values (new.id, case when new.phone is null or new.phone = '' then null
                       else '+' || ltrim(new.phone, '+') end)
  on conflict (id) do nothing;
  return new;
end $$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Categories (reference data, admin-managed)
-- ---------------------------------------------------------------------------
create table public.categories (
  id text primary key check (id ~ '^[a-z0-9_]+$'),
  name text not null,
  kind public.offering_type not null,
  icon text not null default 'package',
  sort int not null default 100,
  active boolean not null default true
);

insert into public.categories (id, name, kind, icon, sort) values
  ('tents',          'Tents & marquees',        'rental',  'tent',        10),
  ('chairs',         'Chairs',                  'rental',  'armchair',    20),
  ('tables',         'Tables',                  'rental',  'table',       30),
  ('linen',          'Linen & chair covers',    'rental',  'shirt',       40),
  ('decor',          'Décor & backdrops',       'rental',  'sparkles',    50),
  ('centrepieces',   'Centrepieces',            'rental',  'flower',      60),
  ('sound',          'Sound & PA',              'rental',  'speaker',     70),
  ('lighting',       'Lighting',                'rental',  'lightbulb',   80),
  ('staging',        'Staging & flooring',      'rental',  'layers',      90),
  ('catering_equip', 'Catering equipment',      'rental',  'cooking_pot', 100),
  ('styling',        'Event styling',           'service', 'palette',     110),
  ('catering',       'Catering',                'service', 'utensils',    120),
  ('florist',        'Floristry',               'service', 'flower_2',    130),
  ('photo_video',    'Photography & video',     'service', 'camera',      140),
  ('dj_mc',          'DJ & MC',                 'service', 'music',       150),
  ('planning',       'Planning & coordination', 'service', 'clipboard_list', 160);

-- ---------------------------------------------------------------------------
-- Businesses
-- ---------------------------------------------------------------------------
create table public.businesses (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete restrict,
  name text not null check (char_length(name) between 2 and 80),
  description text not null default '' check (char_length(description) <= 1200),
  logo_path text,
  primary_category text references public.categories (id),
  offering_types public.offering_type[] not null default '{}',
  phone text check (phone ~ '^\+260[0-9]{9}$'),
  whatsapp text check (whatsapp ~ '^\+260[0-9]{9}$'),
  email text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  neighbourhood text,
  address_line text,
  -- Exact location is private: column privileges below hide it from clients.
  location extensions.geography(point, 4326),
  location_precision public.location_precision not null default 'approximate',
  -- What other vendors see: exact point, or rounded to roughly 550 m.
  public_location extensions.geography(point, 4326),
  service_radius_km int not null default 25 check (service_radius_km between 1 and 500),
  operating_hours jsonb not null default '{}'::jsonb,
  onboarding_step int not null default 0,
  onboarding_completed_at timestamptz,
  verification_status public.verification_status not null default 'unverified',
  status public.business_status not null default 'active',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index businesses_public_location_idx on public.businesses using gist (public_location);
create index businesses_owner_idx on public.businesses (owner_id);

create or replace function public.derive_public_location()
returns trigger language plpgsql as $$
begin
  if new.location is null then
    new.public_location := null;
  elsif new.location_precision = 'exact' then
    new.public_location := new.location;
  else
    new.public_location := extensions.st_setsrid(extensions.st_makepoint(
      round(extensions.st_x(new.location::extensions.geometry)::numeric, 3)::float8 + 0.0005,
      round(extensions.st_y(new.location::extensions.geometry)::numeric, 3)::float8 + 0.0005
    ), 4326)::extensions.geography;
  end if;
  new.updated_at := now();
  return new;
end $$;

create trigger businesses_public_location
  before insert or update of location, location_precision, name, description on public.businesses
  for each row execute function public.derive_public_location();

create table public.business_categories (
  business_id uuid not null references public.businesses (id) on delete cascade,
  category_id text not null references public.categories (id),
  primary key (business_id, category_id)
);

create table public.business_members (
  business_id uuid not null references public.businesses (id) on delete cascade,
  user_id uuid references auth.users (id) on delete cascade,
  invited_phone text check (invited_phone ~ '^\+260[0-9]{9}$'),
  display_name text not null default '',
  role public.member_role not null,
  status public.member_status not null default 'active',
  created_at timestamptz not null default now(),
  id uuid primary key default gen_random_uuid(),
  unique (business_id, user_id),
  check (user_id is not null or invited_phone is not null)
);

create index business_members_user_idx on public.business_members (user_id) where status = 'active';

-- Owner becomes a member automatically.
create or replace function public.add_owner_membership()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.business_members (business_id, user_id, role, status, display_name)
  values (new.id, new.owner_id, 'owner', 'active',
          coalesce((select full_name from public.profiles where id = new.owner_id), ''))
  on conflict (business_id, user_id) do nothing;
  insert into public.notification_preferences (business_id) values (new.id)
  on conflict do nothing;
  return new;
end $$;

create table public.verification_documents (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  doc_type text not null check (doc_type in ('pacra_certificate', 'tpin', 'national_id', 'other')),
  storage_path text not null,
  status text not null default 'submitted' check (status in ('submitted', 'accepted', 'rejected')),
  reviewed_by uuid references auth.users (id),
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Authorisation helpers (security definer, so RLS policies stay cheap)
-- ---------------------------------------------------------------------------
create or replace function public.is_member(p_business uuid, p_roles public.member_role[] default null)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.business_members m
    where m.business_id = p_business
      and m.user_id = auth.uid()
      and m.status = 'active'
      and (p_roles is null or m.role = any (p_roles))
  );
$$;

create or replace function public.can_manage(p_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select public.is_member(p_business, array['owner', 'manager']::public.member_role[]);
$$;

-- Businesses the current user belongs to.
create or replace function public.my_business_ids()
returns setof uuid language sql stable security definer set search_path = public as $$
  select business_id from public.business_members
  where user_id = auth.uid() and status = 'active';
$$;

create or replace function public.require_member(p_business uuid, p_manage boolean default false)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if (p_manage and not public.can_manage(p_business)) or (not p_manage and not public.is_member(p_business)) then
    raise exception 'forbidden' using errcode = '42501', hint = 'You do not have permission for this business.';
  end if;
end $$;

-- Lusaka "today".
create or replace function public.lusaka_today()
returns date language sql stable as $$ select (now() at time zone 'Africa/Lusaka')::date $$;

-- ===== 20261017000200_listings_inventory.sql =====
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

-- ===== 20261017000300_notifications_broadcasts.sql =====
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

-- ===== 20261017000400_quotes_bookings.sql =====
-- Quote requests, quotations (versioned), bookings, payment records.
-- Booking status and payment status are independent. Evenda records payments;
-- it does not hold or move money.

create type public.fulfilment as enum ('pickup', 'supplier_delivers', 'supplier_sets_up');
create type public.quote_request_status as enum ('open', 'quoted', 'accepted', 'declined', 'cancelled', 'expired');
create type public.quotation_status as enum ('sent', 'superseded', 'accepted', 'declined', 'expired', 'withdrawn');
create type public.booking_status as enum (
  'confirmed', 'preparing', 'dispatched', 'in_progress', 'returned', 'completed', 'cancelled', 'disputed'
);
create type public.payment_status as enum ('unpaid', 'deposit_recorded', 'partially_paid', 'paid', 'refunded');
create type public.booking_source as enum ('quotation', 'now', 'manual');

create table public.quote_requests (
  id uuid primary key default gen_random_uuid(),
  requester_business_id uuid not null references public.businesses (id),
  supplier_business_id uuid not null references public.businesses (id),
  event_id uuid,
  status public.quote_request_status not null default 'open',
  needed_from date not null,
  needed_to date not null,
  fulfilment public.fulfilment not null default 'pickup',
  venue text,
  delivery_notes text,
  message text not null default '' check (char_length(message) <= 2000),
  idempotency_key uuid not null unique,
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (requester_business_id <> supplier_business_id),
  check (needed_to >= needed_from)
);

create index quote_requests_requester_idx on public.quote_requests (requester_business_id, created_at desc);
create index quote_requests_supplier_idx on public.quote_requests (supplier_business_id, created_at desc);

create table public.quote_request_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.quote_requests (id) on delete cascade,
  listing_id uuid references public.listings (id),
  description text not null,
  quantity int not null check (quantity > 0)
);

create table public.quote_messages (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.quote_requests (id) on delete cascade,
  sender_business_id uuid not null references public.businesses (id),
  sender_user_id uuid references auth.users (id) default auth.uid(),
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table public.quotations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references public.quote_requests (id) on delete cascade,
  version int not null,
  status public.quotation_status not null default 'sent',
  currency text not null default 'ZMW' check (currency = 'ZMW'),
  subtotal numeric(12, 2) not null,
  additional_charges jsonb not null default '[]'::jsonb,
  total numeric(12, 2) not null,
  deposit_amount numeric(12, 2) not null default 0,
  deposit_terms text,
  payment_terms text not null default '',
  valid_until date not null,
  conditions text not null default '',
  created_by uuid references auth.users (id) default auth.uid(),
  created_at timestamptz not null default now(),
  unique (request_id, version)
);

create table public.quotation_items (
  id uuid primary key default gen_random_uuid(),
  quotation_id uuid not null references public.quotations (id) on delete cascade,
  listing_id uuid references public.listings (id),
  description text not null,
  quantity int not null check (quantity > 0),
  unit_price numeric(12, 2) not null check (unit_price >= 0),
  days int not null default 1 check (days > 0),
  line_total numeric(12, 2) not null
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default ('EV-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6))),
  source public.booking_source not null,
  quotation_id uuid unique references public.quotations (id),
  request_id uuid references public.quote_requests (id),
  now_offer_id uuid unique,
  requester_business_id uuid not null references public.businesses (id),
  supplier_business_id uuid not null references public.businesses (id),
  event_id uuid,
  starts_on date not null,
  ends_on date not null,
  status public.booking_status not null default 'confirmed',
  payment_status public.payment_status not null default 'unpaid',
  total numeric(12, 2) not null,
  deposit_amount numeric(12, 2) not null default 0,
  fulfilment public.fulfilment not null,
  delivery_notes text,
  idempotency_key uuid unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index bookings_requester_idx on public.bookings (requester_business_id, starts_on);
create index bookings_supplier_idx on public.bookings (supplier_business_id, starts_on);

alter table public.reservations
  add constraint reservations_booking_fk foreign key (booking_id) references public.bookings (id) on delete cascade;

create table public.booking_items (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  listing_id uuid references public.listings (id),
  description text not null,
  quantity int not null,
  unit_price numeric(12, 2) not null,
  line_total numeric(12, 2) not null
);

create table public.booking_status_history (
  id bigint generated always as identity primary key,
  booking_id uuid not null references public.bookings (id) on delete cascade,
  from_status public.booking_status,
  to_status public.booking_status not null,
  changed_by uuid references auth.users (id) default auth.uid(),
  note text,
  created_at timestamptz not null default now()
);

create table public.payment_records (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  amount numeric(12, 2) not null check (amount > 0),
  method text not null check (method in ('mobile_money', 'bank_transfer', 'cash', 'other')),
  reference text,
  kind text not null default 'payment' check (kind in ('deposit', 'payment', 'refund')),
  recorded_by_business uuid not null references public.businesses (id),
  recorded_by_user uuid references auth.users (id) default auth.uid(),
  confirmed_by_counterparty_at timestamptz,
  note text,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Requester creates a request. Retrying with the same idempotency key returns the original.
create or replace function public.create_quote_request(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_requester uuid := (p->>'requester_business_id')::uuid;
  v_supplier uuid := (p->>'supplier_business_id')::uuid;
  v_key uuid := (p->>'idempotency_key')::uuid;
  v_item jsonb;
  v_requester_name text;
begin
  perform public.require_member(v_requester);
  select id into v_id from public.quote_requests where idempotency_key = v_key;
  if v_id is not null then return v_id; end if;

  if not exists (select 1 from public.businesses where id = v_supplier and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'supplier_unavailable' using errcode = 'P0001';
  end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'items_required' using errcode = '22023';
  end if;
  if (p->>'needed_from')::date < public.lusaka_today() then
    raise exception 'dates_in_past' using errcode = '22023';
  end if;

  insert into public.quote_requests (requester_business_id, supplier_business_id, event_id, needed_from, needed_to,
                                     fulfilment, venue, delivery_notes, message, idempotency_key)
  values (v_requester, v_supplier, (p->>'event_id')::uuid, (p->>'needed_from')::date, (p->>'needed_to')::date,
          coalesce((p->>'fulfilment')::public.fulfilment, 'pickup'), p->>'venue', p->>'delivery_notes',
          coalesce(p->>'message', ''), v_key)
  returning id into v_id;

  for v_item in select * from jsonb_array_elements(p->'items') loop
    if (v_item->>'listing_id') is not null and not exists (
      select 1 from public.listings where id = (v_item->>'listing_id')::uuid and business_id = v_supplier and status = 'published'
    ) then
      raise exception 'listing_not_from_supplier' using errcode = '22023';
    end if;
    insert into public.quote_request_items (request_id, listing_id, description, quantity)
    values (v_id, (v_item->>'listing_id')::uuid, v_item->>'description', (v_item->>'quantity')::int);
  end loop;

  select name into v_requester_name from public.businesses where id = v_requester;
  perform public.notify(v_supplier, 'booking', 'New quote request from ' || v_requester_name,
    to_char((p->>'needed_from')::date, 'Dy DD Mon') || ' · ' || jsonb_array_length(p->'items') || ' item(s)',
    'qr:' || v_id, '/bookings/request/' || v_id, jsonb_build_object('request_id', v_id));
  return v_id;
end $$;

create or replace function public.post_quote_message(p_request uuid, p_business uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare q public.quote_requests; v_id uuid; v_other uuid; v_name text;
begin
  perform public.require_member(p_business);
  select * into q from public.quote_requests where id = p_request;
  if p_business not in (q.requester_business_id, q.supplier_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.quote_messages (request_id, sender_business_id, body) values (p_request, p_business, p_body) returning id into v_id;
  v_other := case when p_business = q.requester_business_id then q.supplier_business_id else q.requester_business_id end;
  select name into v_name from public.businesses where id = p_business;
  perform public.notify(v_other, 'booking', v_name || ' sent a message', left(p_body, 140),
    'qm:' || v_id, '/bookings/request/' || p_request, jsonb_build_object('request_id', p_request), 'immediate');
  return v_id;
end $$;

-- Supplier issues (or revises) a quotation. Each revision is a new version;
-- the previous open version is superseded.
create or replace function public.send_quotation(p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  q public.quote_requests;
  v_id uuid;
  v_version int;
  v_item jsonb;
  v_subtotal numeric(12, 2) := 0;
  v_charges numeric(12, 2) := 0;
  v_line numeric(12, 2);
  v_name text;
begin
  select * into q from public.quote_requests where id = (p->>'request_id')::uuid for update;
  if not found then raise exception 'request_not_found' using errcode = 'P0002'; end if;
  perform public.require_member(q.supplier_business_id, true);
  if q.status not in ('open', 'quoted') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if (p->>'valid_until')::date < public.lusaka_today() then
    raise exception 'validity_in_past' using errcode = '22023';
  end if;

  select coalesce(max(version), 0) + 1 into v_version from public.quotations where request_id = q.id;
  update public.quotations set status = 'superseded' where request_id = q.id and status = 'sent';

  select coalesce(sum((c->>'amount')::numeric), 0) into v_charges
    from jsonb_array_elements(coalesce(p->'additional_charges', '[]')) c;

  insert into public.quotations (request_id, version, subtotal, additional_charges, total, deposit_amount,
                                 deposit_terms, payment_terms, valid_until, conditions)
  values (q.id, v_version, 0, coalesce(p->'additional_charges', '[]'), 0, coalesce((p->>'deposit_amount')::numeric, 0),
          p->>'deposit_terms', coalesce(p->>'payment_terms', ''), (p->>'valid_until')::date, coalesce(p->>'conditions', ''))
  returning id into v_id;

  for v_item in select * from jsonb_array_elements(p->'items') loop
    v_line := (v_item->>'quantity')::int * (v_item->>'unit_price')::numeric * coalesce((v_item->>'days')::int, 1);
    v_subtotal := v_subtotal + v_line;
    insert into public.quotation_items (quotation_id, listing_id, description, quantity, unit_price, days, line_total)
    values (v_id, (v_item->>'listing_id')::uuid, v_item->>'description', (v_item->>'quantity')::int,
            (v_item->>'unit_price')::numeric, coalesce((v_item->>'days')::int, 1), v_line);
  end loop;

  update public.quotations set subtotal = v_subtotal, total = v_subtotal + v_charges where id = v_id;
  update public.quote_requests set status = 'quoted', updated_at = now() where id = q.id;

  select name into v_name from public.businesses where id = q.supplier_business_id;
  perform public.notify(q.requester_business_id, 'booking',
    case when v_version = 1 then v_name || ' sent a quotation' else v_name || ' revised their quotation' end,
    'ZMW ' || to_char(v_subtotal + v_charges, 'FM999,999,990.00') || ' · valid until ' || to_char((p->>'valid_until')::date, 'DD Mon'),
    'qt:' || v_id, '/bookings/request/' || q.id, jsonb_build_object('quotation_id', v_id, 'request_id', q.id));
  return v_id;
end $$;

create or replace function public.decline_quote_request(p_request uuid, p_business uuid, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
declare q public.quote_requests; v_name text; v_other uuid;
begin
  select * into q from public.quote_requests where id = p_request for update;
  perform public.require_member(p_business, true);
  if p_business not in (q.requester_business_id, q.supplier_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if q.status not in ('open', 'quoted') then raise exception 'request_closed' using errcode = 'P0001'; end if;
  update public.quote_requests
     set status = case when p_business = q.supplier_business_id then 'declined' else 'cancelled' end::public.quote_request_status,
         updated_at = now()
   where id = p_request;
  update public.quotations
     set status = case when p_business = q.supplier_business_id then 'withdrawn' else 'declined' end::public.quotation_status
   where request_id = p_request and status = 'sent';
  v_other := case when p_business = q.supplier_business_id then q.requester_business_id else q.supplier_business_id end;
  select name into v_name from public.businesses where id = p_business;
  perform public.notify(v_other, 'booking', v_name || ' declined the request', coalesce(p_reason, ''),
    'qd:' || p_request, '/bookings/request/' || p_request, '{}', 'immediate');
end $$;

-- Requester accepts a quotation. Runs in one transaction:
-- validate -> recheck availability by reserving -> create booking -> close quote -> notify.
-- Idempotent: repeating the call returns the booking already created.
create or replace function public.accept_quotation(p_quotation uuid, p_idempotency_key uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  qt public.quotations;
  q public.quote_requests;
  v_booking uuid;
  it public.quotation_items;
  v_requester_name text;
begin
  select id into v_booking from public.bookings where quotation_id = p_quotation or idempotency_key = p_idempotency_key;
  if v_booking is not null then return v_booking; end if;

  select * into qt from public.quotations where id = p_quotation for update;
  if not found then raise exception 'quotation_not_found' using errcode = 'P0002'; end if;
  select * into q from public.quote_requests where id = qt.request_id for update;
  perform public.require_member(q.requester_business_id, true);

  if qt.status <> 'sent' then
    raise exception 'quotation_not_open' using errcode = 'P0001', detail = qt.status::text;
  end if;
  if qt.valid_until < public.lusaka_today() then
    update public.quotations set status = 'expired' where id = qt.id;
    raise exception 'quotation_expired' using errcode = 'P0001';
  end if;

  insert into public.bookings (source, quotation_id, request_id, requester_business_id, supplier_business_id, event_id,
                               starts_on, ends_on, total, deposit_amount, fulfilment, delivery_notes, idempotency_key)
  values ('quotation', qt.id, q.id, q.requester_business_id, q.supplier_business_id, q.event_id,
          q.needed_from, q.needed_to, qt.total, qt.deposit_amount, q.fulfilment, q.delivery_notes, p_idempotency_key)
  returning id into v_booking;

  for it in select * from public.quotation_items where quotation_id = qt.id loop
    insert into public.booking_items (booking_id, listing_id, description, quantity, unit_price, line_total)
    values (v_booking, it.listing_id, it.description, it.quantity, it.unit_price, it.line_total);
    if it.listing_id is not null then
      -- Raises insufficient_availability and rolls back everything above.
      perform public.reserve_stock(it.listing_id, it.quantity, q.needed_from, q.needed_to, 'booking', v_booking,
                                   (select name from public.businesses where id = q.requester_business_id));
    end if;
  end loop;

  update public.quotations set status = 'accepted' where id = qt.id;
  update public.quote_requests set status = 'accepted', updated_at = now() where id = q.id;
  insert into public.booking_status_history (booking_id, to_status, note) values (v_booking, 'confirmed', 'Quotation v' || qt.version || ' accepted');

  select name into v_requester_name from public.businesses where id = q.requester_business_id;
  perform public.notify(q.supplier_business_id, 'booking', v_requester_name || ' accepted your quotation',
    'Booking confirmed for ' || to_char(q.needed_from, 'Dy DD Mon') || '. Stock is now reserved.',
    'bk:' || v_booking || ':supplier', '/bookings/' || v_booking, jsonb_build_object('booking_id', v_booking));
  perform public.notify(q.requester_business_id, 'booking', 'Booking confirmed',
    'Reference ' || (select reference from public.bookings where id = v_booking),
    'bk:' || v_booking || ':requester', '/bookings/' || v_booking, jsonb_build_object('booking_id', v_booking), 'in_app');

  perform public.generate_booking_tasks(v_booking);
  return v_booking;
end $$;

-- Allowed status transitions, enforced on the server.
create or replace function public.update_booking_status(p_booking uuid, p_to public.booking_status, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_actor uuid;
  v_ok boolean;
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'booking_not_found' using errcode = 'P0002'; end if;
  if public.is_member(b.supplier_business_id) then v_actor := b.supplier_business_id;
  elsif public.is_member(b.requester_business_id) then v_actor := b.requester_business_id;
  else raise exception 'forbidden' using errcode = '42501'; end if;

  v_ok := case
    when p_to = 'cancelled' then b.status in ('confirmed', 'preparing')
    when p_to = 'disputed' then b.status not in ('cancelled', 'disputed')
    when v_actor <> b.supplier_business_id then false
    when p_to = 'preparing' then b.status = 'confirmed'
    when p_to = 'dispatched' then b.status in ('confirmed', 'preparing')
    when p_to = 'in_progress' then b.status in ('confirmed', 'preparing', 'dispatched')
    when p_to = 'returned' then b.status in ('dispatched', 'in_progress')
    when p_to = 'completed' then b.status in ('in_progress', 'returned', 'dispatched')
    else false end;
  if not v_ok then
    raise exception 'invalid_transition' using errcode = 'P0001', detail = format('%s -> %s', b.status, p_to);
  end if;

  perform public.trust();
  update public.bookings set status = p_to, updated_at = now() where id = b.id;
  insert into public.booking_status_history (booking_id, from_status, to_status, note) values (b.id, b.status, p_to, p_note);

  if p_to = 'cancelled' then
    update public.reservations set status = 'cancelled', updated_at = now() where booking_id = b.id and status in ('held', 'confirmed');
    update public.tasks set status = 'cancelled' where booking_id = b.id and status in ('todo', 'in_progress');
  elsif p_to = 'dispatched' then
    update public.reservations set status = 'dispatched', updated_at = now() where booking_id = b.id and status in ('held', 'confirmed');
  elsif p_to = 'returned' then
    update public.listings l set inspection_quantity = l.inspection_quantity + r.quantity
      from public.reservations r where r.booking_id = b.id and r.status = 'dispatched' and r.listing_id = l.id;
    update public.reservations set status = 'returned', updated_at = now() where booking_id = b.id and status = 'dispatched';
  end if;

  perform public.notify(
    case when v_actor = b.supplier_business_id then b.requester_business_id else b.supplier_business_id end,
    'booking', 'Booking ' || b.reference || ' is now ' || replace(p_to::text, '_', ' '),
    coalesce(p_note, ''), 'bs:' || b.id || ':' || p_to, '/bookings/' || b.id, jsonb_build_object('booking_id', b.id));
end $$;

-- Payment records are claims by one party; the counterparty can confirm them.
create or replace function public.record_payment(p_booking uuid, p_business uuid, p_amount numeric, p_method text,
                                                 p_kind text, p_reference text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid;
begin
  select * into b from public.bookings where id = p_booking for update;
  perform public.require_member(p_business, true);
  if p_business not in (b.requester_business_id, b.supplier_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.payment_records (booking_id, amount, method, kind, reference, recorded_by_business, note)
  values (p_booking, p_amount, p_method, p_kind, p_reference, p_business, p_note) returning id into v_id;
  perform public.refresh_payment_status(p_booking);
  perform public.notify(case when p_business = b.supplier_business_id then b.requester_business_id else b.supplier_business_id end,
    'booking', 'Payment recorded on ' || b.reference,
    'ZMW ' || to_char(p_amount, 'FM999,999,990.00') || ' · ' || replace(p_method, '_', ' ') || ' · please confirm',
    'pay:' || v_id, '/bookings/' || p_booking, jsonb_build_object('booking_id', p_booking));
  return v_id;
end $$;

create or replace function public.confirm_payment(p_payment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.payment_records; b public.bookings;
begin
  select * into pr from public.payment_records where id = p_payment for update;
  select * into b from public.bookings where id = pr.booking_id;
  -- Only the other party may confirm.
  if not public.can_manage(case when pr.recorded_by_business = b.supplier_business_id
                                then b.requester_business_id else b.supplier_business_id end) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.payment_records set confirmed_by_counterparty_at = now() where id = p_payment and confirmed_by_counterparty_at is null;
  perform public.refresh_payment_status(pr.booking_id);
end $$;

create or replace function public.refresh_payment_status(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_paid numeric; v_refunded numeric;
begin
  select * into b from public.bookings where id = p_booking;
  select coalesce(sum(amount) filter (where kind <> 'refund'), 0), coalesce(sum(amount) filter (where kind = 'refund'), 0)
    into v_paid, v_refunded
    from public.payment_records where booking_id = p_booking and confirmed_by_counterparty_at is not null;
  perform public.trust();
  update public.bookings set payment_status = case
      when v_refunded > 0 and v_refunded >= v_paid then 'refunded'
      when v_paid - v_refunded >= b.total then 'paid'
      when v_paid - v_refunded > 0 and v_paid - v_refunded >= b.deposit_amount and b.deposit_amount > 0
           and v_paid - v_refunded < b.total and v_paid - v_refunded = b.deposit_amount then 'deposit_recorded'
      when v_paid - v_refunded > 0 then 'partially_paid'
      else 'unpaid' end::public.payment_status,
    updated_at = now()
  where id = p_booking;
end $$;

create or replace function public.expire_quotations()
returns int language sql security definer set search_path = public as $$
  with e as (
    update public.quotations set status = 'expired'
     where status = 'sent' and valid_until < public.lusaka_today()
    returning request_id)
  , r as (
    update public.quote_requests q set status = 'expired', updated_at = now()
      from e where q.id = e.request_id and q.status = 'quoted'
       and not exists (select 1 from public.quotations o where o.request_id = q.id and o.status = 'sent')
    returning 1)
  select count(*)::int from e;
$$;

-- Bookings are only written through RPCs.
create or replace function public.guard_booking_writes()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('evenda.trusted', true), '') <> 'on'
     and current_setting('role', true) in ('authenticated', 'anon')
     and (new.status is distinct from old.status or new.payment_status is distinct from old.payment_status
          or new.total is distinct from old.total) then
    raise exception 'use_booking_rpc' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger bookings_guard before update on public.bookings
  for each row execute function public.guard_booking_writes();

-- ===== 20261017000500_events_tasks_reminders.sql =====
-- Events, requirements (responsibility model), tasks, reminders.
--
-- Rules:
--  * Tasks are generated only for requirements the current vendor is responsible for.
--    A decorator whose venue supplies chairs never gets chair-loading tasks.
--  * Generated tasks carry a generated_key, unique per business, so regenerating never duplicates.
--  * Generated tasks store offset_minutes relative to event start; moving an event moves them.
--  * Reminders are rows with a state machine; completing or cancelling a task cancels them.
--  * A scheduled job sends due reminders; sending is idempotent per reminder.

create type public.responsibility as enum ('self', 'venue', 'client', 'other_vendor', 'unassigned');
create type public.event_status as enum ('planning', 'confirmed', 'completed', 'cancelled');
create type public.task_priority as enum ('low', 'normal', 'high', 'critical');
create type public.task_status as enum ('todo', 'in_progress', 'done', 'cancelled');

create table public.events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  event_type text not null default 'other'
    check (event_type in ('wedding', 'kitchen_party', 'corporate', 'funeral', 'birthday', 'graduation', 'church', 'other')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  venue_name text,
  venue_address text,
  client_name text,
  guest_count int check (guest_count is null or guest_count >= 0),
  notes text not null default '',
  status public.event_status not null default 'planning',
  source_booking_id uuid references public.bookings (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at >= starts_at)
);

create index events_business_idx on public.events (business_id, starts_at);
create unique index events_from_booking_idx on public.events (business_id, source_booking_id) where source_booking_id is not null;

alter table public.quote_requests add constraint quote_requests_event_fk foreign key (event_id) references public.events (id) on delete set null;
alter table public.bookings add constraint bookings_event_fk foreign key (event_id) references public.events (id) on delete set null;

create table public.event_requirements (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  label text not null,
  category_id text references public.categories (id),
  quantity int check (quantity is null or quantity > 0),
  responsibility public.responsibility not null default 'unassigned',
  supplier_business_id uuid references public.businesses (id),
  booking_id uuid references public.bookings (id),
  notes text,
  created_at timestamptz not null default now()
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  event_id uuid references public.events (id) on delete cascade,
  booking_id uuid references public.bookings (id) on delete set null,
  requirement_id uuid references public.event_requirements (id) on delete set null,
  title text not null check (char_length(title) between 2 and 160),
  notes text not null default '',
  assignee_user_id uuid references auth.users (id),
  due_at timestamptz not null,
  offset_minutes int,
  priority public.task_priority not null default 'normal',
  status public.task_status not null default 'todo',
  generated_key text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, generated_key)
);

create index tasks_business_due_idx on public.tasks (business_id, due_at) where status in ('todo', 'in_progress');

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  remind_at timestamptz not null,
  kind text not null check (kind in ('advance', 'deadline', 'snoozed')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'cancelled')),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index reminders_due_idx on public.reminders (remind_at) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Task templates: what a vendor should do, keyed by offering and responsibility.
-- offset is minutes relative to event start (negative = before).
-- ---------------------------------------------------------------------------
create table public.task_templates (
  key text primary key,
  title text not null,
  offset_minutes int not null,
  priority public.task_priority not null default 'normal',
  applies_to text not null check (applies_to in ('any', 'rental_supplier', 'service_supplier', 'requester', 'self_requirement')),
  category_kind public.offering_type
);

insert into public.task_templates (key, title, offset_minutes, priority, applies_to, category_kind) values
  ('confirm_venue_access',  'Confirm venue access and setup time',   -4320, 'high',     'any',               null),
  ('confirm_supplier',      'Confirm supplier availability',          -2880, 'high',     'requester',         null),
  ('confirm_payment',       'Confirm deposit or payment',             -4320, 'normal',   'rental_supplier',   null),
  ('check_stock',           'Check and count stock for this job',     -2880, 'high',     'rental_supplier',   null),
  ('prepare_load',          'Prepare and load equipment',              -720, 'high',     'rental_supplier',   null),
  ('prepare_materials',     'Prepare materials',                      -1440, 'normal',   'service_supplier',  null),
  ('complete_setup',        'Complete setup',                           -60, 'critical', 'any',               null),
  ('collect_equipment',     'Collect hired equipment',                  720, 'normal',   'requester',         'rental'),
  ('inspect_returns',       'Inspect returned equipment',              1440, 'normal',   'rental_supplier',   null),
  ('source_requirement',    'Arrange supply',                         -4320, 'high',     'self_requirement',  null);

-- Reminder schedule from priority: critical/high get 24h and 2h; normal 24h; low digest only.
create or replace function public.schedule_task_reminders(p_task uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task;
  update public.reminders set status = 'cancelled' where task_id = p_task and status = 'pending';
  if t.status in ('done', 'cancelled') then return; end if;

  if t.priority in ('normal', 'high', 'critical') and t.due_at - interval '24 hours' > now() then
    insert into public.reminders (task_id, business_id, remind_at, kind) values (t.id, t.business_id, t.due_at - interval '24 hours', 'advance');
  end if;
  if t.priority in ('high', 'critical') and t.due_at - interval '2 hours' > now() then
    insert into public.reminders (task_id, business_id, remind_at, kind) values (t.id, t.business_id, t.due_at - interval '2 hours', 'deadline');
  end if;
end $$;

create or replace function public.tasks_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.due_at is distinct from old.due_at or new.status is distinct from old.status
     or new.priority is distinct from old.priority then
    perform public.schedule_task_reminders(new.id);
  end if;
  return new;
end $$;

create trigger tasks_reminders after insert or update on public.tasks
  for each row execute function public.tasks_after_change();

create or replace function public.tasks_before_change()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then new.completed_at := now(); end if;
  if new.status <> 'done' then new.completed_at := null; end if;
  return new;
end $$;

create trigger tasks_touch before insert or update on public.tasks
  for each row execute function public.tasks_before_change();

-- Moving an event moves its relative tasks (unfinished only).
create or replace function public.events_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.starts_at is distinct from old.starts_at then
    update public.tasks
       set due_at = new.starts_at + make_interval(mins => offset_minutes)
     where event_id = new.id and offset_minutes is not null and status in ('todo', 'in_progress');
  end if;
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update public.tasks set status = 'cancelled' where event_id = new.id and status in ('todo', 'in_progress');
  end if;
  return new;
end $$;

create trigger events_reschedule after update on public.events
  for each row execute function public.events_after_change();

-- Generate tasks for an event for one business. Idempotent through generated_key.
create or replace function public.generate_event_tasks(p_event uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  r public.event_requirements;
  tpl public.task_templates;
  v_count int := 0;
  v_n int;
begin
  select * into e from public.events where id = p_event;
  perform public.require_member(e.business_id);

  -- Generic tasks for any event the vendor works.
  for tpl in select * from public.task_templates where applies_to = 'any' loop
    insert into public.tasks (business_id, event_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, tpl.title, e.starts_at + make_interval(mins => tpl.offset_minutes), tpl.offset_minutes,
            tpl.priority, 'event:' || e.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Requirements the vendor itself must supply but has not booked yet.
  for r in select * from public.event_requirements where event_id = e.id and responsibility = 'self' and booking_id is null loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id,
            'Arrange ' || r.label || coalesce(' (' || r.quantity || ')', ''),
            e.starts_at - interval '3 days', -4320, 'high', 'req:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Unassigned requirements need a decision.
  for r in select * from public.event_requirements where event_id = e.id and responsibility = 'unassigned' loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id, 'Decide who supplies ' || r.label,
            e.starts_at - interval '5 days', -7200, 'normal', 'req-assign:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Requirements other parties handle: one light-touch confirmation, never operational tasks.
  for r in select * from public.event_requirements where event_id = e.id and responsibility in ('venue', 'client', 'other_vendor') loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id,
            'Confirm ' || replace(r.responsibility::text, '_', ' ') || ' is providing ' || r.label,
            e.starts_at - interval '2 days', -2880, 'low', 'req-confirm:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  return v_count;
end $$;

-- Booking tasks for both sides; called inside accept_quotation and select_now_offer.
create or replace function public.generate_booking_tasks(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  tpl public.task_templates;
  v_start timestamptz;
  v_supplier_kind text;
begin
  select * into b from public.bookings where id = p_booking;
  v_start := (b.starts_on + time '08:00') at time zone 'Africa/Lusaka';
  select case when bool_or(l.kind = 'rental' and l.tracks_stock) then 'rental_supplier' else 'service_supplier' end
    into v_supplier_kind
    from public.booking_items bi left join public.listings l on l.id = bi.listing_id
   where bi.booking_id = b.id;

  for tpl in select * from public.task_templates where applies_to = coalesce(v_supplier_kind, 'service_supplier') loop
    insert into public.tasks (business_id, booking_id, title, due_at, priority, generated_key)
    values (b.supplier_business_id, b.id, tpl.title || ' · ' || b.reference,
            greatest(v_start + make_interval(mins => tpl.offset_minutes), now() + interval '1 hour'),
            tpl.priority, 'booking:' || b.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
  end loop;

  for tpl in select * from public.task_templates where applies_to = 'requester'
      and (category_kind is null or v_supplier_kind = 'rental_supplier') loop
    insert into public.tasks (business_id, booking_id, event_id, title, due_at, priority, generated_key)
    values (b.requester_business_id, b.id, b.event_id, tpl.title || ' · ' || b.reference,
            greatest(v_start + make_interval(mins => tpl.offset_minutes), now() + interval '1 hour'),
            tpl.priority, 'booking:' || b.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
  end loop;

  -- Link a requirement on the requester's event to this booking so its "Arrange" task can close.
  if b.event_id is not null then
    update public.tasks set status = 'done'
     where business_id = b.requester_business_id and event_id = b.event_id and status in ('todo', 'in_progress')
       and requirement_id in (select id from public.event_requirements where event_id = b.event_id and booking_id = b.id);
  end if;
end $$;

-- Create an event from an accepted booking (supplier side), then its tasks.
create or replace function public.create_event_from_booking(p_booking uuid, p_business uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid; v_other text;
begin
  perform public.require_member(p_business);
  select * into b from public.bookings where id = p_booking;
  if p_business not in (b.supplier_business_id, b.requester_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select id into v_id from public.events where business_id = p_business and source_booking_id = p_booking;
  if v_id is not null then return v_id; end if;
  select name into v_other from public.businesses
   where id = case when p_business = b.supplier_business_id then b.requester_business_id else b.supplier_business_id end;
  insert into public.events (business_id, name, starts_at, ends_at, client_name, status, source_booking_id)
  values (p_business, 'Job ' || b.reference || ' · ' || v_other,
          (b.starts_on + time '08:00') at time zone 'Africa/Lusaka',
          (b.ends_on + time '22:00') at time zone 'Africa/Lusaka', v_other, 'confirmed', b.id)
  returning id into v_id;
  update public.tasks set event_id = v_id where business_id = p_business and booking_id = p_booking and event_id is null;
  perform public.generate_event_tasks(v_id);
  return v_id;
end $$;

create or replace function public.snooze_task(p_task uuid, p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task;
  perform public.require_member(t.business_id);
  if p_until <= now() then raise exception 'snooze_in_past' using errcode = '22023'; end if;
  update public.reminders set status = 'cancelled' where task_id = p_task and status = 'pending';
  insert into public.reminders (task_id, business_id, remind_at, kind) values (p_task, t.business_id, p_until, 'snoozed');
end $$;

-- Scheduled every minute. Claims due reminders with SKIP LOCKED, so overlapping
-- or retried runs cannot send the same reminder twice; notify() also dedupes.
create or replace function public.process_due_reminders(p_limit int default 500)
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
  v_allowed timestamptz;
  v_mode public.delivery_mode;
begin
  for r in
    select rm.id, rm.business_id, rm.kind, t.id as task_id, t.title, t.due_at, t.priority, t.status as task_status,
           p.task_reminders
      from public.reminders rm
      join public.tasks t on t.id = rm.task_id
      left join public.notification_preferences p on p.business_id = rm.business_id
     where rm.status = 'pending' and rm.remind_at <= now()
     order by rm.remind_at
     limit p_limit
     for update of rm skip locked
  loop
    if r.task_status in ('done', 'cancelled') then
      update public.reminders set status = 'cancelled' where id = r.id;
      continue;
    end if;

    v_allowed := public.next_allowed_send(r.business_id);
    if v_allowed > now() and r.priority <> 'critical' then
      update public.reminders set remind_at = v_allowed where id = r.id;
      continue;
    end if;

    v_mode := case when coalesce(r.task_reminders, 'immediate') = 'off' then 'in_app'
                   when r.task_reminders = 'digest' and r.priority in ('low', 'normal') then 'digest'
                   else 'immediate' end;

    perform public.notify(r.business_id, 'task',
      case r.kind when 'deadline' then 'Due soon: ' else 'Reminder: ' end || r.title,
      'Due ' || to_char(r.due_at at time zone 'Africa/Lusaka', 'Dy DD Mon, HH24:MI'),
      'rem:' || r.id, '/work/task/' || r.task_id, jsonb_build_object('task_id', r.task_id),
      v_mode, null, r.priority = 'critical');
    update public.reminders set status = 'sent', sent_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- Workload: per-day load and scheduling conflicts for the calendar and dashboard.
create or replace function public.workload(p_business uuid, p_from date, p_to date)
returns table (day date, events int, tasks_due int, tasks_overdue int, overlapping_events boolean)
language sql stable security definer set search_path = public as $$
  select d::date,
         (select count(*) from public.events e where e.business_id = p_business and e.status <> 'cancelled'
            and d::date between (e.starts_at at time zone 'Africa/Lusaka')::date and (e.ends_at at time zone 'Africa/Lusaka')::date)::int,
         (select count(*) from public.tasks t where t.business_id = p_business and t.status in ('todo', 'in_progress')
            and (t.due_at at time zone 'Africa/Lusaka')::date = d::date)::int,
         (select count(*) from public.tasks t where t.business_id = p_business and t.status in ('todo', 'in_progress')
            and t.due_at < now() and (t.due_at at time zone 'Africa/Lusaka')::date = d::date)::int,
         exists (select 1 from public.events a join public.events b on a.id < b.id
                  where a.business_id = p_business and b.business_id = p_business
                    and a.status <> 'cancelled' and b.status <> 'cancelled'
                    and a.starts_at < b.ends_at and b.starts_at < a.ends_at
                    and d::date between (a.starts_at at time zone 'Africa/Lusaka')::date and (a.ends_at at time zone 'Africa/Lusaka')::date)
  from generate_series(p_from, p_to, interval '1 day') d
  where public.is_member(p_business) and p_to - p_from <= 92;
$$;

-- ===== 20261017000600_evenda_now.sql =====
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

-- ===== 20261017000700_admin_audit.sql =====
-- Platform administration. Admins are granted only by inserting into
-- platform_admins with the service role (or by a super_admin through the RPC).
-- There is no client path to become an admin.

create type public.admin_role as enum ('super_admin', 'moderator', 'support', 'finance');

create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role public.admin_role not null,
  display_name text not null default '',
  active boolean not null default true,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

-- Permission matrix. Each admin action checks one permission.
create or replace function public.admin_has(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.platform_admins a
    where a.user_id = auth.uid() and a.active and (
      a.role = 'super_admin'
      or (a.role = 'moderator' and p_permission in
          ('business.read', 'business.verify', 'listing.moderate', 'category.manage', 'activity.read', 'now.read', 'audit.read'))
      or (a.role = 'support' and p_permission in
          ('business.read', 'booking.read', 'dispute.manage', 'activity.read', 'now.read'))
      or (a.role = 'finance' and p_permission in
          ('business.read', 'booking.read', 'payment.read', 'report.read'))
    )
  );
$$;

create or replace function public.my_admin_role()
returns public.admin_role language sql stable security definer set search_path = public as $$
  select role from public.platform_admins where user_id = auth.uid() and active;
$$;

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users (id),
  actor_role public.admin_role,
  action text not null,
  target_table text not null,
  target_id text not null,
  reason text,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);

create index audit_logs_target_idx on public.audit_logs (target_table, target_id);
create index audit_logs_created_idx on public.audit_logs (created_at desc);

-- Audit rows are append-only, even for the table owner via the API roles.
create or replace function public.audit_logs_immutable()
returns trigger language plpgsql as $$
begin raise exception 'audit_logs_are_append_only' using errcode = '42501'; end $$;

create trigger audit_logs_no_update before update or delete on public.audit_logs
  for each row execute function public.audit_logs_immutable();

create or replace function public.write_audit(p_action text, p_table text, p_id text, p_reason text, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (actor_user_id, actor_role, action, target_table, target_id, reason, before, after)
  values (auth.uid(), public.my_admin_role(), p_action, p_table, p_id, p_reason, p_before, p_after);
$$;

create or replace function public.require_admin(p_permission text, p_reason text default null, p_reason_required boolean default false)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_has(p_permission) then
    raise exception 'admin_forbidden' using errcode = '42501', detail = p_permission;
  end if;
  if p_reason_required and coalesce(char_length(trim(p_reason)), 0) < 5 then
    raise exception 'reason_required' using errcode = '22023', hint = 'Give a reason of at least 5 characters.';
  end if;
end $$;

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id),
  opened_by_business uuid not null references public.businesses (id),
  reason text not null check (char_length(reason) between 10 and 2000),
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'dismissed')),
  resolution text,
  assigned_admin uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.open_dispute(p_booking uuid, p_business uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid;
begin
  perform public.require_member(p_business, true);
  select * into b from public.bookings where id = p_booking;
  if p_business not in (b.requester_business_id, b.supplier_business_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  insert into public.disputes (booking_id, opened_by_business, reason) values (p_booking, p_business, p_reason) returning id into v_id;
  perform public.update_booking_status(p_booking, 'disputed', 'Dispute opened');
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Admin RPCs: every sensitive action requires a reason and writes an audit row.
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_verification(p_business uuid, p_status public.verification_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.trust();
  perform public.require_admin('business.verify', p_reason, p_status = 'rejected');
  select jsonb_build_object('verification_status', verification_status) into v_before from public.businesses where id = p_business;
  update public.businesses set verification_status = p_status where id = p_business;
  perform public.write_audit('business.verification', 'businesses', p_business::text, p_reason, v_before,
                             jsonb_build_object('verification_status', p_status));
  perform public.notify(p_business, 'system',
    case p_status when 'verified' then 'Your business is verified' when 'rejected' then 'Verification needs attention' else 'Verification updated' end,
    coalesce(p_reason, ''), 'verify:' || p_status || ':' || now()::date, '/business/profile', '{}', 'immediate');
end $$;

create or replace function public.admin_set_business_status(p_business uuid, p_status public.business_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.trust();
  perform public.require_admin('business.verify', p_reason, true);
  select jsonb_build_object('status', status) into v_before from public.businesses where id = p_business;
  update public.businesses set status = p_status where id = p_business;
  perform public.write_audit('business.status', 'businesses', p_business::text, p_reason, v_before, jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_moderate_listing(p_listing uuid, p_status public.moderation_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare l public.listings;
begin
  perform public.require_admin('listing.moderate', p_reason, p_status <> 'ok');
  select * into l from public.listings where id = p_listing for update;
  perform public.trust();
  update public.listings set moderation_status = p_status, moderation_reason = p_reason where id = p_listing;
  perform public.write_audit('listing.moderate', 'listings', p_listing::text, p_reason,
    jsonb_build_object('moderation_status', l.moderation_status), jsonb_build_object('moderation_status', p_status));
  if p_status <> 'ok' then
    perform public.notify(l.business_id, 'system', '“' || l.title || '” was ' || p_status::text || ' by moderation',
      p_reason, 'mod:' || p_listing || ':' || p_status || ':' || now()::date, '/business/listings/' || p_listing, '{}', 'immediate');
  end if;
end $$;

create or replace function public.admin_resolve_dispute(p_dispute uuid, p_status text, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.disputes;
begin
  perform public.require_admin('dispute.manage', p_resolution, true);
  select * into d from public.disputes where id = p_dispute for update;
  update public.disputes set status = p_status, resolution = p_resolution, assigned_admin = auth.uid(), updated_at = now()
   where id = p_dispute;
  perform public.write_audit('dispute.update', 'disputes', p_dispute::text, p_resolution,
    jsonb_build_object('status', d.status), jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_upsert_category(p_id text, p_name text, p_kind public.offering_type, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.require_admin('category.manage', p_reason, false);
  select to_jsonb(c) into v_before from public.categories c where id = p_id;
  insert into public.categories (id, name, kind, active) values (p_id, p_name, p_kind, p_active)
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, active = excluded.active;
  perform public.write_audit('category.upsert', 'categories', p_id, p_reason, v_before,
    jsonb_build_object('name', p_name, 'kind', p_kind, 'active', p_active));
end $$;

create or replace function public.admin_grant_role(p_user uuid, p_role public.admin_role, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_admin_role() is distinct from 'super_admin' then raise exception 'admin_forbidden' using errcode = '42501'; end if;
  perform public.require_admin('admin.manage', p_reason, true);
  insert into public.platform_admins (user_id, role, created_by) values (p_user, p_role, auth.uid())
  on conflict (user_id) do update set role = excluded.role, active = true;
  perform public.write_audit('admin.grant', 'platform_admins', p_user::text, p_reason, null, jsonb_build_object('role', p_role));
end $$;

create or replace function public.admin_platform_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('activity.read');
  return jsonb_build_object(
    'businesses', (select count(*) from public.businesses where onboarding_completed_at is not null),
    'pending_verification', (select count(*) from public.businesses where verification_status = 'pending'),
    'published_listings', (select count(*) from public.listings where status = 'published'),
    'flagged_listings', (select count(*) from public.listings where moderation_status = 'flagged'),
    'open_quote_requests', (select count(*) from public.quote_requests where status in ('open', 'quoted')),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'now_open', (select count(*) from public.now_requests where status in ('broadcasting', 'receiving_offers', 'offer_selected')),
    'open_disputes', (select count(*) from public.disputes where status in ('open', 'investigating')),
    'push_failed_24h', (select count(*) from public.notification_deliveries where status in ('failed', 'skipped') and created_at > now() - interval '1 day')
  );
end $$;

-- Business directory for admins (exact location withheld from non-super admins).
create or replace function public.admin_list_businesses(p_search text default null, p_verification public.verification_status default null)
returns table (id uuid, name text, neighbourhood text, primary_category text, verification_status public.verification_status,
               status public.business_status, created_at timestamptz, listings int, documents int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('business.read');
  return query
  select b.id, b.name, b.neighbourhood, b.primary_category, b.verification_status, b.status, b.created_at,
         (select count(*) from public.listings l where l.business_id = b.id)::int,
         (select count(*) from public.verification_documents d where d.business_id = b.id)::int
    from public.businesses b
   where (p_search is null or b.name ilike '%' || p_search || '%')
     and (p_verification is null or b.verification_status = p_verification)
   order by b.created_at desc
   limit 200;
end $$;

-- ===== 20261017000800_rls_storage.sql =====
-- Row Level Security, column privileges, storage buckets and realtime.
-- Principle: clients read what they are entitled to and write only plain
-- fields on rows they own. Everything with business rules goes through RPCs.

-- ---------------------------------------------------------------------------
-- Business-level RPCs used by onboarding
-- ---------------------------------------------------------------------------
create or replace function public.create_business(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  -- One owned business per account in this release.
  select id into v_id from public.businesses where owner_id = auth.uid();
  if v_id is not null then return v_id; end if;
  insert into public.businesses (owner_id, name) values (auth.uid(), p_name) returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_business_location(p_business uuid, p_lat float8, p_lng float8,
                                                        p_precision public.location_precision, p_neighbourhood text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.trust();
  perform public.require_member(p_business, true);
  -- Zambia bounding box sanity check.
  if p_lat not between -18.2 and -8.1 or p_lng not between 21.9 and 33.8 then
    raise exception 'location_outside_zambia' using errcode = '22023';
  end if;
  update public.businesses
     set location = extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
         location_precision = p_precision, neighbourhood = p_neighbourhood
   where id = p_business;
end $$;

create or replace function public.complete_onboarding(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b public.businesses; v_missing text[] := '{}';
begin
  perform public.trust();
  perform public.require_member(p_business, true);
  select * into b from public.businesses where id = p_business for update;
  if b.primary_category is null then v_missing := v_missing || 'primary_category'; end if;
  if cardinality(b.offering_types) = 0 then v_missing := v_missing || 'offering_types'; end if;
  if b.phone is null then v_missing := v_missing || 'phone'; end if;
  if b.location is null then v_missing := v_missing || 'location'; end if;
  if cardinality(v_missing) > 0 then
    raise exception 'onboarding_incomplete' using errcode = '22023', detail = array_to_string(v_missing, ',');
  end if;
  update public.businesses set onboarding_completed_at = coalesce(onboarding_completed_at, now()) where id = p_business;
  insert into public.category_subscriptions (business_id, category_id)
  select p_business, c.id from public.categories c
   where c.active and c.id <> b.primary_category
     and c.kind = 'rental' and 'rental' = any (b.offering_types)
  on conflict do nothing;
end $$;

create or replace function public.submit_for_verification(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_member(p_business, true);
  if not exists (select 1 from public.verification_documents where business_id = p_business) then
    raise exception 'documents_required' using errcode = '22023';
  end if;
  perform public.trust();
  update public.businesses set verification_status = 'pending'
   where id = p_business and verification_status in ('unverified', 'rejected');
end $$;

create or replace function public.guard_business_columns()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('evenda.trusted', true), '') <> 'on'
     and current_setting('role', true) in ('authenticated', 'anon')
     and (new.verification_status is distinct from old.verification_status
          or new.status is distinct from old.status
          or new.owner_id is distinct from old.owner_id
          or new.onboarding_completed_at is distinct from old.onboarding_completed_at
          or new.location is distinct from old.location
          or new.public_location is distinct from old.public_location) then
    raise exception 'use_business_rpc' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger businesses_guard before update on public.businesses
  for each row execute function public.guard_business_columns();

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'categories', 'businesses', 'business_categories', 'business_members', 'verification_documents',
    'listings', 'listing_photos', 'stock_adjustments', 'reservations', 'availability_blocks',
    'notification_preferences', 'category_subscriptions', 'supplier_follows', 'device_tokens', 'notifications',
    'notification_deliveries', 'inventory_events',
    'quote_requests', 'quote_request_items', 'quote_messages', 'quotations', 'quotation_items',
    'bookings', 'booking_items', 'booking_status_history', 'payment_records',
    'events', 'event_requirements', 'tasks', 'reminders', 'task_templates',
    'now_requests', 'now_request_recipients', 'now_offers', 'now_status_history',
    'platform_admins', 'audit_logs', 'disputes'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Profiles
create policy profiles_self_read on public.profiles for select using (id = auth.uid() or public.admin_has('business.read'));
create policy profiles_self_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- Categories: readable by all signed-in users, changed only by admin RPC.
create policy categories_read on public.categories for select to authenticated using (true);
create policy task_templates_read on public.task_templates for select to authenticated using (true);

-- Businesses: the directory is visible to signed-in users; members see their own drafts.
create policy businesses_read on public.businesses for select to authenticated using (
  (status = 'active' and onboarding_completed_at is not null)
  or public.is_member(id)
  or public.admin_has('business.read')
);
create policy businesses_update on public.businesses for update to authenticated
  using (public.can_manage(id)) with check (public.can_manage(id));

-- Hide the exact location column from API roles. Clients use public_location.
revoke select on public.businesses from anon, authenticated;
grant select (id, owner_id, name, description, logo_path, primary_category, offering_types, phone, whatsapp, email,
              neighbourhood, address_line, location_precision, public_location, service_radius_km, operating_hours,
              onboarding_step, onboarding_completed_at, verification_status, status, created_at, updated_at)
  on public.businesses to authenticated;
revoke update on public.businesses from anon, authenticated;
grant update (name, description, logo_path, primary_category, offering_types, phone, whatsapp, email, address_line,
              service_radius_km, operating_hours, onboarding_step)
  on public.businesses to authenticated;
revoke insert, delete on public.businesses from anon, authenticated;

create policy business_categories_read on public.business_categories for select to authenticated using (true);
create policy business_categories_write on public.business_categories for all to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));

create policy members_read on public.business_members for select to authenticated
  using (public.is_member(business_id) or public.admin_has('business.read'));
create policy members_write on public.business_members for insert to authenticated
  with check (public.is_member(business_id, array['owner']::public.member_role[]) and role <> 'owner');
create policy members_update on public.business_members for update to authenticated
  using (public.is_member(business_id, array['owner']::public.member_role[]) and role <> 'owner')
  with check (role <> 'owner');

create policy verification_docs_member on public.verification_documents for select to authenticated
  using (public.can_manage(business_id) or public.admin_has('business.verify'));
create policy verification_docs_insert on public.verification_documents for insert to authenticated
  with check (public.can_manage(business_id) and status = 'submitted');

-- Listings
create policy listings_read on public.listings for select to authenticated using (
  public.is_member(business_id)
  or public.admin_has('listing.moderate')
  or (status = 'published' and moderation_status = 'ok'
      and exists (select 1 from public.businesses b where b.id = business_id and b.status = 'active'))
);
create policy listings_update on public.listings for update to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));
revoke insert, delete on public.listings from anon, authenticated;

create policy listing_photos_read on public.listing_photos for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id));
create policy listing_photos_write on public.listing_photos for all to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and public.can_manage(l.business_id)))
  with check (exists (select 1 from public.listings l where l.id = listing_id and public.can_manage(l.business_id)));

create policy stock_adjustments_read on public.stock_adjustments for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and public.is_member(l.business_id)));

-- Reservations reveal who a vendor works for: members only.
create policy reservations_read on public.reservations for select to authenticated using (public.is_member(business_id));
revoke insert, update, delete on public.reservations from anon, authenticated;

create policy blocks_read on public.availability_blocks for select to authenticated using (public.is_member(business_id));
create policy blocks_write on public.availability_blocks for all to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));

-- Notifications & preferences
create policy prefs_rw on public.notification_preferences for all to authenticated
  using (public.is_member(business_id)) with check (public.can_manage(business_id));
create policy subs_rw on public.category_subscriptions for all to authenticated
  using (public.is_member(business_id)) with check (public.can_manage(business_id));
create policy follows_rw on public.supplier_follows for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy tokens_rw on public.device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_read on public.notifications for select to authenticated using (public.is_member(recipient_business_id));
create policy notifications_mark_read on public.notifications for update to authenticated
  using (public.is_member(recipient_business_id)) with check (public.is_member(recipient_business_id));
revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy inventory_events_read on public.inventory_events for select to authenticated using (
  type not in ('listing_paused', 'listing_removed') or public.is_member(business_id)
);

-- Quotes & bookings: the two parties only (plus admins with the right permission).
create policy quote_requests_read on public.quote_requests for select to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id) or public.admin_has('booking.read'));
create policy quote_items_read on public.quote_request_items for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quote_messages_read on public.quote_messages for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quotations_read on public.quotations for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quotation_items_read on public.quotation_items for select to authenticated using (
  exists (select 1 from public.quotations q where q.id = quotation_id));
create policy bookings_read on public.bookings for select to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id) or public.admin_has('booking.read'));
create policy bookings_update_notes on public.bookings for update to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id));
revoke update on public.bookings from authenticated;
grant update (delivery_notes, event_id) on public.bookings to authenticated;
create policy booking_items_read on public.booking_items for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id));
create policy booking_history_read on public.booking_status_history for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id));
create policy payments_read on public.payment_records for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id
          and (public.is_member(b.requester_business_id) or public.is_member(b.supplier_business_id)))
  or public.admin_has('payment.read'));

-- Events & tasks: private to the business.
create policy events_rw on public.events for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy requirements_rw on public.event_requirements for all to authenticated
  using (exists (select 1 from public.events e where e.id = event_id and public.is_member(e.business_id)))
  with check (exists (select 1 from public.events e where e.id = event_id and public.is_member(e.business_id)));
create policy tasks_rw on public.tasks for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy reminders_read on public.reminders for select to authenticated using (public.is_member(business_id));

-- Evenda Now
create policy now_requests_read on public.now_requests for select to authenticated using (
  public.is_member(requester_business_id)
  or exists (select 1 from public.now_request_recipients r where r.request_id = id and public.is_member(r.business_id))
  or public.admin_has('now.read'));
create policy now_recipients_read on public.now_request_recipients for select to authenticated using (
  public.is_member(business_id) or public.admin_has('now.read'));
create policy now_offers_read on public.now_offers for select to authenticated using (
  public.is_member(supplier_business_id)
  or exists (select 1 from public.now_requests q where q.id = request_id and public.is_member(q.requester_business_id))
  or public.admin_has('now.read'));
create policy now_history_read on public.now_status_history for select to authenticated using (
  exists (select 1 from public.now_requests q where q.id = request_id));

-- Admin
create policy admins_self on public.platform_admins for select to authenticated
  using (user_id = auth.uid() or public.admin_has('admin.manage'));
create policy audit_read on public.audit_logs for select to authenticated using (public.admin_has('audit.read'));
create policy disputes_read on public.disputes for select to authenticated using (
  public.admin_has('dispute.manage')
  or exists (select 1 from public.bookings b where b.id = booking_id
             and (public.is_member(b.requester_business_id) or public.is_member(b.supplier_business_id))));

-- Internal functions must not be callable from the client.
revoke execute on function public.notify(uuid, public.notification_category, text, text, text, text, jsonb, public.delivery_mode, text, boolean) from public, anon, authenticated;
revoke execute on function public.reserve_stock(uuid, int, date, date, public.reservation_source, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.claim_push_deliveries(int) from public, anon, authenticated;
revoke execute on function public.complete_push_delivery(uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.process_due_reminders(int) from public, anon, authenticated;
revoke execute on function public.build_digests() from public, anon, authenticated;
revoke execute on function public.expire_now_requests() from public, anon, authenticated;
revoke execute on function public.expire_quotations() from public, anon, authenticated;
revoke execute on function public.generate_booking_tasks(uuid) from public, anon, authenticated;
revoke execute on function public.emit_inventory_event(uuid, uuid, public.inventory_event_type, text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.write_audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.now_set_status(uuid, public.now_status, text) from public, anon, authenticated;
revoke execute on function public.refresh_payment_status(uuid) from public, anon, authenticated;
revoke execute on function public.trust() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('listing-photos', 'listing-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('business-logos', 'business-logos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('verification', 'verification', false, 10485760, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

-- Object paths start with the business id: <business_id>/<file>.
create policy storage_public_read on storage.objects for select
  using (bucket_id in ('listing-photos', 'business-logos'));
create policy storage_business_write on storage.objects for insert to authenticated
  with check (bucket_id in ('listing-photos', 'business-logos', 'verification')
              and public.can_manage(((storage.foldername(name))[1])::uuid));
create policy storage_business_delete on storage.objects for delete to authenticated
  using (bucket_id in ('listing-photos', 'business-logos') and public.can_manage(((storage.foldername(name))[1])::uuid));
create policy storage_verification_read on storage.objects for select to authenticated
  using (bucket_id = 'verification'
         and (public.can_manage(((storage.foldername(name))[1])::uuid) or public.admin_has('business.verify')));

-- ---------------------------------------------------------------------------
-- Realtime: rows clients subscribe to (RLS still applies).
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.notifications, public.now_requests, public.now_offers,
  public.now_request_recipients, public.bookings, public.quote_requests, public.quotations, public.tasks;

-- ===== 20261017000900_schedules.sql =====
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

-- ===== 20261018000100_signup_profile_name.sql =====
-- Email sign-up passes the vendor's name as user metadata (full_name).
-- Copy it into the profile so onboarding does not ask for it again.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    left(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), 120),
    case when new.phone is null or new.phone = '' then null
         else '+' || ltrim(new.phone, '+') end
  )
  on conflict (id) do nothing;
  return new;
end $$;

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

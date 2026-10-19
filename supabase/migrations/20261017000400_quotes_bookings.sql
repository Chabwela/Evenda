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

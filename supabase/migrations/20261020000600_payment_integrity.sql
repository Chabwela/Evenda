-- Payment integrity (EV-7AFD36: K3,000 recorded and confirmed against a K300 booking).
--
-- Evenda's payment model: no payment provider. A business records a payment it
-- made or received; the other business confirms it; only confirmed records count.
-- Amounts are ZMW in major units, numeric(12,2).
--
-- Root cause: record_payment accepted any amount, with no check against the
-- booking total or what was already recorded, and no duplicate-reference check.
--
-- This migration:
--   1. Voiding instead of deleting: payment records gain voided_at / voided_by /
--      void_reason. Voided records stay in history and never count.
--   2. record_payment validates on the server, under a row lock on the booking:
--      booking exists, caller is a manager of one party, amount positive with at
--      most 2 decimals, booking not cancelled (refunds excepted), and the amount
--      fits what is still due (recorded = confirmed + awaiting confirmation, so
--      two unconfirmed records cannot together exceed the total). Refunds cannot
--      exceed what has been confirmed as paid. No overpayment: Evenda has no
--      tips or adjustments; extra charges belong in the quotation total.
--   3. A reference (e.g. Airtel Money transaction ID) can only be used once per
--      booking among non-voided records.
--   4. confirm_payment refuses voided records; refresh_payment_status ignores them.
--   5. void_payment: the recording business can void its own UNconfirmed record
--      (typos). admin_void_payment: finance / super admin voids any record, with a
--      reason, audited, both businesses told.

-- 1 ---------------------------------------------------------------------------
alter table public.payment_records
  add column if not exists voided_at timestamptz,
  add column if not exists voided_by uuid references auth.users (id) on delete set null,
  add column if not exists void_reason text;

-- 3 ---------------------------------------------------------------------------
create unique index if not exists payment_records_reference_once
  on public.payment_records (booking_id, lower(btrim(reference)))
  where reference is not null and btrim(reference) <> '' and voided_at is null;

-- 2 ---------------------------------------------------------------------------
create or replace function public.record_payment(p_booking uuid, p_business uuid, p_amount numeric, p_method text,
                                                 p_kind text, p_reference text default null, p_note text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  v_id uuid;
  v_recorded numeric;
  v_confirmed numeric;
  v_ref text := nullif(btrim(coalesce(p_reference, '')), '');
begin
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  perform public.require_member(p_business, true);
  if p_business not in (b.requester_business_id, b.supplier_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind not in ('deposit', 'payment', 'refund') then raise exception 'invalid_payment_kind' using errcode = '22023'; end if;
  if p_method not in ('mobile_money', 'bank_transfer', 'cash', 'other') then raise exception 'invalid_payment_method' using errcode = '22023'; end if;
  if p_amount is null or p_amount <= 0 or p_amount <> round(p_amount, 2) then
    raise exception 'invalid_amount' using errcode = '22023';
  end if;
  if b.status = 'cancelled' and p_kind <> 'refund' then
    raise exception 'booking_cancelled' using errcode = 'P0001';
  end if;

  -- Net of everything not voided: confirmed and awaiting confirmation.
  select coalesce(sum(case when kind = 'refund' then -amount else amount end), 0),
         coalesce(sum(case when kind = 'refund' then -amount else amount end) filter (where confirmed_by_counterparty_at is not null), 0)
    into v_recorded, v_confirmed
    from public.payment_records where booking_id = b.id and voided_at is null;

  if p_kind <> 'refund' and v_recorded + p_amount > b.total then
    raise exception 'payment_exceeds_balance' using errcode = 'P0001',
      detail = json_build_object('total', b.total, 'recorded', v_recorded, 'remaining', greatest(b.total - v_recorded, 0))::text;
  end if;
  if p_kind = 'refund' and p_amount > v_confirmed then
    raise exception 'refund_exceeds_paid' using errcode = 'P0001',
      detail = json_build_object('confirmed', v_confirmed)::text;
  end if;

  begin
    insert into public.payment_records (booking_id, amount, method, kind, reference, recorded_by_business, note)
    values (p_booking, p_amount, p_method, p_kind, v_ref, p_business, p_note) returning id into v_id;
  exception when unique_violation then
    raise exception 'duplicate_payment_reference' using errcode = 'P0001';
  end;

  perform public.refresh_payment_status(p_booking);
  perform public.notify(case when p_business = b.supplier_business_id then b.requester_business_id else b.supplier_business_id end,
    'booking', 'Payment recorded on ' || b.reference,
    'ZMW ' || to_char(p_amount, 'FM999,999,990.00') || ' · ' || replace(p_method, '_', ' ') || ' · please confirm',
    'pay:' || v_id, '/bookings/' || p_booking, jsonb_build_object('booking_id', p_booking));
  return v_id;
end $$;

-- 4 ---------------------------------------------------------------------------
create or replace function public.confirm_payment(p_payment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.payment_records; b public.bookings;
begin
  select * into pr from public.payment_records where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if pr.voided_at is not null then raise exception 'payment_voided' using errcode = 'P0001'; end if;
  select * into b from public.bookings where id = pr.booking_id for update;
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
    from public.payment_records
   where booking_id = p_booking and confirmed_by_counterparty_at is not null and voided_at is null;
  perform public.trust();
  update public.bookings set payment_status = case
      when v_refunded > 0 and v_refunded >= v_paid then 'refunded'
      when v_paid - v_refunded >= b.total then 'paid'
      when v_paid - v_refunded > 0 and b.deposit_amount > 0 and v_paid - v_refunded = b.deposit_amount then 'deposit_recorded'
      when v_paid - v_refunded > 0 then 'partially_paid'
      else 'unpaid' end::public.payment_status,
    updated_at = now()
  where id = p_booking;
end $$;

-- 5 ---------------------------------------------------------------------------
create or replace function public.void_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.payment_records;
begin
  select * into pr from public.payment_records where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  perform public.require_member(pr.recorded_by_business, true);
  if pr.voided_at is not null then return; end if;               -- idempotent
  if pr.confirmed_by_counterparty_at is not null then
    raise exception 'payment_confirmed' using errcode = 'P0001',
      hint = 'A confirmed payment can only be voided by Evenda. Report it from the booking.';
  end if;
  if coalesce(char_length(btrim(p_reason)), 0) < 3 then raise exception 'reason_required' using errcode = '22023'; end if;
  update public.payment_records set voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason) where id = p_payment;
  perform public.refresh_payment_status(pr.booking_id);
end $$;

create or replace function public.admin_void_payment(p_payment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare pr public.payment_records; b public.bookings;
begin
  perform public.require_admin('payment.read', p_reason, true);   -- finance and super admin
  select * into pr from public.payment_records where id = p_payment for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if pr.voided_at is not null then return; end if;               -- idempotent
  select * into b from public.bookings where id = pr.booking_id for update;
  update public.payment_records set voided_at = now(), voided_by = auth.uid(), void_reason = btrim(p_reason) where id = p_payment;
  perform public.refresh_payment_status(pr.booking_id);
  perform public.write_audit('payment.void', 'payment_records', p_payment::text, p_reason,
    jsonb_build_object('booking', b.reference, 'amount', pr.amount, 'kind', pr.kind, 'confirmed', pr.confirmed_by_counterparty_at is not null),
    jsonb_build_object('voided', true));
  perform public.notify(b.supplier_business_id, 'booking', 'Payment record voided on ' || b.reference,
    'ZMW ' || to_char(pr.amount, 'FM999,999,990.00') || ' · ' || btrim(p_reason), 'pay-void:' || p_payment, '/bookings/' || b.id,
    jsonb_build_object('booking_id', b.id), 'immediate');
  perform public.notify(b.requester_business_id, 'booking', 'Payment record voided on ' || b.reference,
    'ZMW ' || to_char(pr.amount, 'FM999,999,990.00') || ' · ' || btrim(p_reason), 'pay-void:' || p_payment, '/bookings/' || b.id,
    jsonb_build_object('booking_id', b.id), 'immediate');
end $$;

-- Function lockdown (20261019000100): new functions start closed.
revoke execute on function public.void_payment(uuid, text) from public, anon;
revoke execute on function public.admin_void_payment(uuid, text) from public, anon;
grant execute on function public.void_payment(uuid, text) to authenticated, service_role;
grant execute on function public.admin_void_payment(uuid, text) to authenticated, service_role;
revoke execute on function public.refresh_payment_status(uuid) from public, anon, authenticated;

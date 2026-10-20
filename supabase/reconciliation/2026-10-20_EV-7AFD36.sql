-- Reconciliation: booking EV-7AFD36 — K3,000 recorded and confirmed against K300.
-- STATUS: PROPOSED. Not executed. Requires the owner's approval.
--
-- Evidence (20 Oct 2026, admin booking file):
--   booking EV-7AFD36, Evenda Now, supplier Feluna Events And Design,
--   hirer Kabwata Party, 10 x Table Linens @ K30 = total K300, completed.
--   One payment record: K3,000, mobile money, no reference, recorded by
--   Kabwata Party 19 Oct 11:01, confirmed by Feluna.
-- There is no provider transaction to verify against (Evenda records payments,
-- it does not process them), so the true amount is unknown. This script does
-- NOT invent one: it voids the record (kept, never deleted). The businesses
-- then record what was really paid, which the other side confirms, under the
-- new server-side checks.
--
-- Preconditions (the script refuses otherwise):
--   * migration 20261020000600_payment_integrity.sql is applied;
--   * exactly one non-voided K3,000 record exists on EV-7AFD36.
-- Recommended before running: confirm with both businesses what was paid,
-- and take a backup (Supabase Dashboard -> Database -> Backups).
-- Safe to re-run: a second run finds nothing to void and changes nothing.
-- Rollback: update public.payment_records set voided_at = null, voided_by = null,
--   void_reason = null where id = '<id printed below>'; then
--   select public.refresh_payment_status('<booking id>');

begin;

do $$
declare
  v_booking public.bookings;
  v_payment public.payment_records;
  v_count int;
begin
  select * into v_booking from public.bookings where reference = 'EV-7AFD36' for update;
  if not found then raise exception 'EV-7AFD36 not found'; end if;

  select count(*) into v_count from public.payment_records
   where booking_id = v_booking.id and voided_at is null and amount = 3000;
  if v_count = 0 then
    raise notice 'Nothing to do: no unvoided K3,000 record on EV-7AFD36 (already reconciled?)';
    return;
  end if;
  if v_count > 1 then raise exception 'Expected one K3,000 record on EV-7AFD36, found %. Stop and inspect.', v_count; end if;

  select * into v_payment from public.payment_records
   where booking_id = v_booking.id and voided_at is null and amount = 3000 for update;

  update public.payment_records
     set voided_at = now(),
         void_reason = 'Reconciliation 2026-10-20: K3,000 recorded against a K300 booking; no transaction reference to verify. Businesses to re-record the actual amount.'
   where id = v_payment.id;

  perform public.refresh_payment_status(v_booking.id);

  insert into public.audit_logs (actor_user_id, actor_role, action, target_table, target_id, reason, before, after)
  values (null, null, 'payment.void', 'payment_records', v_payment.id::text,
          'Reconciliation EV-7AFD36 (approved by owner)',
          jsonb_build_object('booking', v_booking.reference, 'amount', v_payment.amount, 'confirmed_at', v_payment.confirmed_by_counterparty_at),
          jsonb_build_object('voided', true));

  raise notice 'Voided payment % (K%) on % (booking id %). Payment status now: %',
    v_payment.id, v_payment.amount, v_booking.reference, v_booking.id,
    (select payment_status from public.bookings where id = v_booking.id);
end $$;

-- Verify before committing: expect the K3,000 row with voided_at set, and the
-- booking's payment_status recomputed (unpaid until the real amount is re-recorded).
select p.amount, p.kind, p.voided_at is not null as voided, p.void_reason, b.total, b.payment_status
  from public.payment_records p join public.bookings b on b.id = p.booking_id
 where b.reference = 'EV-7AFD36';

commit;

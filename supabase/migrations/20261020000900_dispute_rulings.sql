-- Dispute rulings with consequences.
--
-- Before: admin_resolve_dispute only changed the dispute's status text. It
-- accepted any status (and re-ruled closed disputes), told neither business,
-- and left the booking stuck in 'disputed' forever. open_dispute allowed a
-- second open dispute on the same booking.
--
-- Now:
--   * admin_take_dispute: an admin takes the case ('investigating'); both
--     businesses are told Evenda is looking into it.
--   * admin_rule_dispute: 'resolved' (complaint upheld) or 'dismissed' (not
--     upheld), with a ruling both businesses see, and a booking outcome:
--       'resume'    booking returns to the status it had before the dispute
--       'complete'  booking marked completed
--       'cancel'    booking cancelled; reservations and open tasks released
--     Closed disputes cannot be ruled again. Audited; both parties notified.
--   * admin_resolve_dispute is kept for older app builds but now validates.
--   * open_dispute refuses a second open dispute on the same booking.

create or replace function public.admin_take_dispute(p_dispute uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare d public.disputes; b public.bookings;
begin
  perform public.require_admin('dispute.manage');
  select * into d from public.disputes where id = p_dispute for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if d.status not in ('open', 'investigating') then raise exception 'dispute_closed' using errcode = 'P0001'; end if;
  select * into b from public.bookings where id = d.booking_id;
  update public.disputes set status = 'investigating', assigned_admin = auth.uid(), updated_at = now() where id = p_dispute;
  perform public.write_audit('dispute.take', 'disputes', p_dispute::text, nullif(btrim(coalesce(p_note, '')), ''),
    jsonb_build_object('status', d.status), jsonb_build_object('status', 'investigating'));
  if d.status = 'open' then
    perform public.notify(x, 'booking', 'Evenda is looking into ' || b.reference,
      'An Evenda admin has taken the dispute and may contact you. Keep any receipts or photos ready.',
      'dispute-take:' || p_dispute, '/bookings/' || b.id, jsonb_build_object('booking_id', b.id), 'immediate')
      from unnest(array[b.supplier_business_id, b.requester_business_id]) as x;
  end if;
end $$;

create or replace function public.admin_rule_dispute(p_dispute uuid, p_decision text, p_ruling text, p_booking_outcome text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d public.disputes;
  b public.bookings;
  v_before public.booking_status;
  v_to public.booking_status;
  v_ruling text := btrim(coalesce(p_ruling, ''));
begin
  perform public.require_admin('dispute.manage', v_ruling, true);
  if p_decision not in ('resolved', 'dismissed') then raise exception 'invalid_status' using errcode = '22023'; end if;
  if p_booking_outcome not in ('resume', 'complete', 'cancel') then raise exception 'invalid_outcome' using errcode = '22023'; end if;
  select * into d from public.disputes where id = p_dispute for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if d.status not in ('open', 'investigating') then raise exception 'dispute_closed' using errcode = 'P0001'; end if;
  select * into b from public.bookings where id = d.booking_id for update;

  -- The booking's status before the dispute (latest move into 'disputed').
  select h.from_status into v_before from public.booking_status_history h
   where h.booking_id = b.id and h.to_status = 'disputed' and h.from_status is not null
   order by h.created_at desc limit 1;

  v_to := case p_booking_outcome
            when 'resume' then coalesce(v_before, 'confirmed')
            when 'complete' then 'completed'
            else 'cancelled' end;

  update public.disputes set status = p_decision, resolution = v_ruling, assigned_admin = auth.uid(), updated_at = now()
   where id = p_dispute;

  perform public.trust();
  if b.status <> v_to and b.status not in ('completed', 'cancelled') then
    update public.bookings set status = v_to, updated_at = now() where id = b.id;
    insert into public.booking_status_history (booking_id, from_status, to_status, note)
    values (b.id, b.status, v_to, 'Evenda ruling: ' || v_ruling);
    if v_to = 'cancelled' then
      update public.reservations set status = 'cancelled', updated_at = now()
       where booking_id = b.id and status in ('held', 'confirmed', 'dispatched');
      update public.tasks set status = 'cancelled' where booking_id = b.id and status in ('todo', 'in_progress');
    end if;
  end if;

  perform public.write_audit('dispute.rule', 'disputes', p_dispute::text, v_ruling,
    jsonb_build_object('status', d.status, 'booking_status', b.status, 'reference', b.reference),
    jsonb_build_object('status', p_decision, 'booking_status', v_to, 'outcome', p_booking_outcome));

  perform public.notify(x, 'booking',
    'Evenda ruled on ' || b.reference || case p_decision when 'resolved' then ': complaint upheld' else ': complaint not upheld' end,
    v_ruling || ' · Booking ' || case p_booking_outcome when 'resume' then 'goes ahead' when 'complete' then 'marked completed' else 'cancelled' end || '.',
    'dispute-rule:' || p_dispute, '/bookings/' || b.id, jsonb_build_object('booking_id', b.id), 'immediate', null, true)
    from unnest(array[b.supplier_business_id, b.requester_business_id]) as x;
end $$;

-- Older builds: same checks, booking returns to where it was.
create or replace function public.admin_resolve_dispute(p_dispute uuid, p_status text, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_status = 'investigating' then
    perform public.admin_take_dispute(p_dispute, p_resolution);
  else
    perform public.admin_rule_dispute(p_dispute, p_status, p_resolution, 'resume');
  end if;
end $$;

create or replace function public.open_dispute(p_booking uuid, p_business uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid;
begin
  perform public.require_member(p_business, true);
  select * into b from public.bookings where id = p_booking;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if p_business not in (b.requester_business_id, b.supplier_business_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  if exists (select 1 from public.disputes where booking_id = p_booking and status in ('open', 'investigating')) then
    raise exception 'dispute_already_open' using errcode = 'P0001';
  end if;
  insert into public.disputes (booking_id, opened_by_business, reason) values (p_booking, p_business, p_reason) returning id into v_id;
  perform public.update_booking_status(p_booking, 'disputed', 'Dispute opened');
  return v_id;
end $$;

-- Function lockdown (20261019000100): new functions start closed.
revoke execute on function public.admin_take_dispute(uuid, text) from public, anon;
revoke execute on function public.admin_rule_dispute(uuid, text, text, text) from public, anon;
grant execute on function public.admin_take_dispute(uuid, text) to authenticated, service_role;
grant execute on function public.admin_rule_dispute(uuid, text, text, text) to authenticated, service_role;

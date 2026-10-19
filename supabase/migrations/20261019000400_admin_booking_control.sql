-- Admin authority over bookings: cancel a booking on the platform's behalf
-- (fraud, abandoned job, dispute outcome). Releases reserved stock, cancels
-- open tasks, records history and audit, and tells both businesses why.

create or replace function public.admin_cancel_booking(p_booking uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare b public.bookings;
begin
  perform public.require_admin('dispute.manage', p_reason, true);
  select * into b from public.bookings where id = p_booking for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if b.status in ('completed', 'cancelled') then
    raise exception 'invalid_transition' using errcode = 'P0001', detail = format('%s -> cancelled', b.status);
  end if;

  perform public.trust();
  update public.bookings set status = 'cancelled', updated_at = now() where id = b.id;
  insert into public.booking_status_history (booking_id, from_status, to_status, note)
  values (b.id, b.status, 'cancelled', 'Cancelled by Evenda: ' || btrim(p_reason));
  update public.reservations set status = 'cancelled', updated_at = now()
   where booking_id = b.id and status in ('held', 'confirmed', 'dispatched');
  update public.tasks set status = 'cancelled' where booking_id = b.id and status in ('todo', 'in_progress');

  perform public.write_audit('booking.cancel', 'bookings', b.id::text, p_reason,
    jsonb_build_object('status', b.status, 'reference', b.reference),
    jsonb_build_object('status', 'cancelled'));

  perform public.notify(b.supplier_business_id, 'booking', 'Evenda cancelled booking ' || b.reference, btrim(p_reason),
    'admin-cancel:' || b.id, '/bookings/' || b.id, jsonb_build_object('booking_id', b.id), 'immediate', null, true);
  perform public.notify(b.requester_business_id, 'booking', 'Evenda cancelled booking ' || b.reference, btrim(p_reason),
    'admin-cancel:' || b.id, '/bookings/' || b.id, jsonb_build_object('booking_id', b.id), 'immediate', null, true);
end $$;

revoke execute on function public.admin_cancel_booking(uuid, text) from public, anon;
grant execute on function public.admin_cancel_booking(uuid, text) to authenticated, service_role;

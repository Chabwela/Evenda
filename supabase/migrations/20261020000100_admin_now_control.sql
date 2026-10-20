-- Admin authority over Evenda Now: close a request on the platform's behalf
-- (spam, abuse, wrong category, duplicate). Pending offers expire, the
-- requester is told why, and suppliers who were alerted are told it's closed.
-- Requests with a confirmed booking are not closed here: cancel the booking.

create or replace function public.admin_close_now_request(p_request uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare
  rq public.now_requests;
  r record;
begin
  perform public.require_admin('dispute.manage', p_reason, true);
  select * into rq from public.now_requests where id = p_request for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  if rq.status not in ('draft', 'broadcasting', 'receiving_offers', 'offer_selected') then
    raise exception 'invalid_transition' using errcode = 'P0001', detail = format('%s -> cancelled', rq.status);
  end if;

  update public.now_offers set status = 'expired', updated_at = now() where request_id = rq.id and status = 'pending';
  perform public.now_set_status(rq.id, 'cancelled', 'Closed by Evenda: ' || btrim(p_reason));

  perform public.write_audit('now.close', 'now_requests', rq.id::text, p_reason,
    jsonb_build_object('status', rq.status, 'item', rq.quantity || ' × ' || rq.item_description),
    jsonb_build_object('status', 'cancelled'));

  perform public.notify(rq.requester_business_id, 'now', 'Evenda closed your urgent request',
    rq.quantity || ' × ' || rq.item_description || ' · ' || btrim(p_reason),
    'now-admin-close:' || rq.id, '/now/' || rq.id, jsonb_build_object('request_id', rq.id), 'immediate');

  for r in select business_id from public.now_request_recipients where request_id = rq.id and declined_at is null loop
    perform public.notify(r.business_id, 'now', 'Urgent request closed',
      rq.quantity || ' × ' || rq.item_description || ' is no longer open.',
      'now-admin-close:' || rq.id, '/now', jsonb_build_object('request_id', rq.id), 'in_app');
  end loop;
end $$;

revoke execute on function public.admin_close_now_request(uuid, text) from public, anon;
grant execute on function public.admin_close_now_request(uuid, text) to authenticated, service_role;

-- Admin business review: see everything needed to judge a business, review
-- each verification document, and verify only after a document is accepted.

-- Full picture of one business for admins (business.read). The exact
-- location is included only for super admins and moderators (business.verify),
-- who need it to check an address against documents.
create or replace function public.admin_business_detail(p_business uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  b public.businesses;
  v_can_verify boolean;
begin
  perform public.require_admin('business.read');
  select * into b from public.businesses where id = p_business;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  v_can_verify := public.admin_has('business.verify');

  return jsonb_build_object(
    'id', b.id,
    'name', b.name,
    'description', b.description,
    'logo_path', b.logo_path,
    'primary_category', b.primary_category,
    'offering_types', b.offering_types,
    'phone', b.phone,
    'whatsapp', b.whatsapp,
    'email', b.email,
    'neighbourhood', b.neighbourhood,
    'address_line', b.address_line,
    'location_precision', b.location_precision,
    'lat', case when v_can_verify and b.location is not null then extensions.st_y(b.location::extensions.geometry) end,
    'lng', case when v_can_verify and b.location is not null then extensions.st_x(b.location::extensions.geometry) end,
    'service_radius_km', b.service_radius_km,
    'verification_status', b.verification_status,
    'status', b.status,
    'created_at', b.created_at,
    'onboarding_completed_at', b.onboarding_completed_at,
    'owner', (
      select jsonb_build_object('id', u.id, 'name', coalesce(p.full_name, ''), 'email', u.email,
                                'phone', p.phone, 'joined_at', u.created_at, 'email_confirmed', u.email_confirmed_at is not null)
        from auth.users u left join public.profiles p on p.id = u.id
       where u.id = b.owner_id),
    'documents', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', d.id, 'doc_type', d.doc_type, 'storage_path', d.storage_path, 'status', d.status,
               'created_at', d.created_at, 'reviewed_at', d.reviewed_at, 'review_note', d.review_note,
               'reviewed_by', (select coalesce(a.display_name, '') from public.platform_admins a where a.user_id = d.reviewed_by))
             order by d.created_at desc)
        from public.verification_documents d where d.business_id = b.id), '[]'::jsonb),
    'team', coalesce((
      select jsonb_agg(jsonb_build_object('name', m.display_name, 'role', m.role, 'status', m.status) order by m.created_at)
        from public.business_members m where m.business_id = b.id and m.status <> 'removed'), '[]'::jsonb),
    'counts', jsonb_build_object(
      'listings', (select count(*) from public.listings l where l.business_id = b.id),
      'published_listings', (select count(*) from public.listings l where l.business_id = b.id and l.status = 'published'),
      'bookings_as_supplier', (select count(*) from public.bookings k where k.supplier_business_id = b.id),
      'bookings_as_requester', (select count(*) from public.bookings k where k.requester_business_id = b.id),
      'disputes', (select count(*) from public.disputes d join public.bookings k on k.id = d.booking_id
                    where b.id in (k.supplier_business_id, k.requester_business_id)),
      'flagged_listings', (select count(*) from public.listings l where l.business_id = b.id and l.moderation_status <> 'ok')
    ),
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('action', h.action, 'reason', h.reason, 'after', h.after, 'at', h.created_at,
                                          'by', (select coalesce(a.display_name, '') from public.platform_admins a where a.user_id = h.actor_user_id))
             order by h.created_at desc)
        from (select * from public.audit_logs
               where (target_table = 'businesses' and target_id = b.id::text)
                  or (target_table = 'verification_documents'
                      and target_id in (select d.id::text from public.verification_documents d where d.business_id = b.id))
               order by created_at desc limit 30) h), '[]'::jsonb)
  );
end $$;

-- Accept or reject one document, with a note (required when rejecting).
create or replace function public.admin_review_document(p_document uuid, p_status text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.verification_documents;
begin
  perform public.require_admin('business.verify', p_note, p_status = 'rejected');
  if p_status not in ('accepted', 'rejected') then raise exception 'invalid_status' using errcode = '22023'; end if;
  select * into d from public.verification_documents where id = p_document for update;
  if not found then raise exception 'not_found' using errcode = 'P0002'; end if;
  update public.verification_documents
     set status = p_status, reviewed_by = auth.uid(), reviewed_at = now(), review_note = nullif(btrim(p_note), '')
   where id = p_document;
  perform public.write_audit('document.review', 'verification_documents', p_document::text, p_note,
    jsonb_build_object('status', d.status, 'doc_type', d.doc_type, 'business_id', d.business_id),
    jsonb_build_object('status', p_status));
end $$;

-- Verification now requires at least one accepted document: an admin cannot
-- mark a business verified without having reviewed what it submitted.
create or replace function public.admin_set_verification(p_business uuid, p_status public.verification_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.trust();
  perform public.require_admin('business.verify', p_reason, p_status = 'rejected');
  if p_status = 'verified' and not exists (
    select 1 from public.verification_documents where business_id = p_business and status = 'accepted'
  ) then
    raise exception 'documents_not_reviewed' using errcode = 'P0001',
      hint = 'Accept at least one verification document before verifying the business.';
  end if;
  select jsonb_build_object('verification_status', verification_status) into v_before from public.businesses where id = p_business;
  update public.businesses set verification_status = p_status where id = p_business;
  perform public.write_audit('business.verification', 'businesses', p_business::text, p_reason, v_before,
                             jsonb_build_object('verification_status', p_status));
  perform public.notify(p_business, 'system',
    case p_status when 'verified' then 'Your business is verified' when 'rejected' then 'Verification needs attention' else 'Verification updated' end,
    coalesce(p_reason, ''), 'verify:' || p_status || ':' || now()::date, '/business/profile', '{}', 'immediate');
end $$;

-- Function lockdown (20261019000100): new functions start closed.
grant execute on function public.admin_business_detail(uuid) to authenticated, service_role;
grant execute on function public.admin_review_document(uuid, text, text) to authenticated, service_role;
grant execute on function public.admin_set_verification(uuid, public.verification_status, text) to authenticated, service_role;

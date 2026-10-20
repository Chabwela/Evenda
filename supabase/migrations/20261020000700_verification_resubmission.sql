-- Verification resubmission: tell the vendor what to fix, let them fix it.
--
-- Before: the admin's reason for rejecting a business went only into a
-- notification and the staff audit log (which vendors cannot read); rejecting a
-- single document told the vendor nothing at all.
--
-- This migration:
--   1. businesses.verification_note: the reason shown on the vendor's profile
--      while the business is rejected. Set by admin_set_verification, cleared
--      when the vendor sends it again. Vendors cannot edit it (guard trigger).
--   2. verification_feedback(p_business): members read the note (the business
--      row is selected with an explicit column list in the app, so a separate
--      call keeps older builds working).
--   3. admin_review_document notifies the business when a document is not
--      accepted, with the reason, linking to the profile where it can be replaced.
--   4. submit_for_verification clears the note and tells the business it is
--      back in review.

-- 1 ---------------------------------------------------------------------------
alter table public.businesses add column if not exists verification_note text;

create or replace function public.guard_business_columns()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('evenda.trusted', true), '') <> 'on'
     and current_setting('role', true) in ('authenticated', 'anon')
     and (new.verification_status is distinct from old.verification_status
          or new.verification_note is distinct from old.verification_note
          or new.status is distinct from old.status
          or new.owner_id is distinct from old.owner_id
          or new.onboarding_completed_at is distinct from old.onboarding_completed_at
          or new.location is distinct from old.location
          or new.public_location is distinct from old.public_location) then
    raise exception 'use_business_rpc' using errcode = '42501';
  end if;
  return new;
end $$;

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
  update public.businesses
     set verification_status = p_status,
         verification_note = case when p_status = 'rejected' then nullif(btrim(p_reason), '') end
   where id = p_business;
  perform public.write_audit('business.verification', 'businesses', p_business::text, p_reason, v_before,
                             jsonb_build_object('verification_status', p_status));
  perform public.notify(p_business, 'system',
    case p_status when 'verified' then 'Your business is verified' when 'rejected' then 'Verification needs attention' else 'Verification updated' end,
    case when p_status = 'rejected' then coalesce(nullif(btrim(p_reason), '') || ' · ', '') || 'Upload a new document and send it again.'
         else coalesce(p_reason, '') end,
    'verify:' || p_status || ':' || now()::date, '/business/profile', '{}', 'immediate');
end $$;

-- 2 ---------------------------------------------------------------------------
create or replace function public.verification_feedback(p_business uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_member(p_business);
  return (select verification_note from public.businesses where id = p_business and verification_status = 'rejected');
end $$;

-- 3 ---------------------------------------------------------------------------
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
  if p_status = 'rejected' and d.status is distinct from 'rejected' then
    perform public.notify(d.business_id, 'system', 'A document needs replacing',
      coalesce(nullif(btrim(p_note), '') || ' · ', '') || 'Upload a new one from your business profile.',
      'doc-reject:' || p_document, '/business/profile', '{}', 'immediate');
  end if;
end $$;

-- 4 ---------------------------------------------------------------------------
create or replace function public.submit_for_verification(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_changed int;
begin
  perform public.require_member(p_business, true);
  if not exists (select 1 from public.verification_documents where business_id = p_business) then
    raise exception 'documents_required' using errcode = '22023';
  end if;
  perform public.trust();
  update public.businesses set verification_status = 'pending', verification_note = null
   where id = p_business and verification_status in ('unverified', 'rejected');
  get diagnostics v_changed = row_count;
  if v_changed > 0 then
    perform public.notify(p_business, 'system', 'Sent for review',
      'The Evenda team will check your documents. We’ll let you know here.',
      'verify:pending:' || now(), '/business/profile', '{}', 'immediate');
  end if;
end $$;

-- Function lockdown (20261019000100): new functions start closed.
revoke execute on function public.verification_feedback(uuid) from public, anon;
grant execute on function public.verification_feedback(uuid) to authenticated, service_role;

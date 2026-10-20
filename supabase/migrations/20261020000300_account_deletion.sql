-- Account deletion (Google Play User Data policy: in-app and web deletion).
--
-- What happens when a vendor deletes their account:
--   * Their login (auth.users), profile, memberships and device tokens are
--     deleted.
--   * A business they own is anonymised, not deleted: the other party in a
--     past booking keeps a record that the booking happened ("Deleted
--     business"), with no name, contact details, logo, location or documents.
--     Listings are archived and their photos removed; verification documents,
--     events, tasks, follows, subscriptions and notifications are deleted.
--   * Shared records (bookings, quotations, payments, status history) keep
--     amounts and dates for the counterparty's books; links to the deleted
--     person are cleared.
-- Refused (with a clear reason) when the owner still has team members, active
-- bookings, or is a platform admin.

-- 1. Links to auth.users that would block deletion now clear themselves.
--    audit_logs is excluded on purpose: it is append-only, and only admins
--    (who cannot self-delete) appear in it.
do $$
declare c record; col text;
begin
  for c in
    select con.conname, con.conrelid::regclass as tbl, con.conkey
      from pg_constraint con
     where con.contype = 'f'
       and con.confrelid = 'auth.users'::regclass
       and con.connamespace = 'public'::regnamespace
       and con.confdeltype in ('a', 'r')
       and con.conrelid <> 'public.audit_logs'::regclass
  loop
    select attname into col from pg_attribute where attrelid = c.tbl and attnum = c.conkey[1];
    execute format('alter table %s alter column %I drop not null', c.tbl, col);
    execute format('alter table %s drop constraint %I', c.tbl, c.conname);
    execute format('alter table %s add constraint %I foreign key (%I) references auth.users (id) on delete set null',
                   c.tbl, c.conname, col);
  end loop;
end $$;

-- 2. A business you have traded with stays readable even when it is
--    suspended or deleted, so booking and quote screens can still show the
--    other party (they embed it; a hidden row would break them).
create or replace function public.is_counterparty(p_business uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.bookings k
                  where p_business in (k.supplier_business_id, k.requester_business_id)
                    and (k.supplier_business_id in (select public.my_business_ids())
                         or k.requester_business_id in (select public.my_business_ids())))
      or exists (select 1 from public.quote_requests q
                  where p_business in (q.supplier_business_id, q.requester_business_id)
                    and (q.supplier_business_id in (select public.my_business_ids())
                         or q.requester_business_id in (select public.my_business_ids())));
$$;
revoke execute on function public.is_counterparty(uuid) from public, anon;
grant execute on function public.is_counterparty(uuid) to authenticated, service_role;

create policy businesses_read_counterparty on public.businesses for select to authenticated
  using (public.is_counterparty(id));

-- 3. Owners may delete their own business's verification documents (storage).
create policy storage_verification_delete on storage.objects for delete to authenticated
  using (bucket_id = 'verification' and public.can_manage(((storage.foldername(name))[1])::uuid));

-- 4. What would block deletion, so the app can explain before trying.
create or replace function public.account_deletion_check()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_biz uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  select id into v_biz from public.businesses where owner_id = v_uid;
  return jsonb_build_object(
    'is_admin', exists (select 1 from public.platform_admins where user_id = v_uid and active),
    'business_id', v_biz,
    'team_members', (select count(*) from public.business_members
                      where business_id = v_biz and status <> 'removed' and user_id is distinct from v_uid),
    'active_bookings', (select count(*) from public.bookings
                         where v_biz in (supplier_business_id, requester_business_id)
                           and status in ('confirmed', 'preparing', 'dispatched', 'in_progress', 'returned', 'disputed'))
  );
end $$;

-- 5. Delete the caller's account.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_check jsonb;
  v_biz uuid;
begin
  if v_uid is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  v_check := public.account_deletion_check();
  if (v_check ->> 'is_admin')::boolean then
    raise exception 'admin_cannot_self_delete' using errcode = 'P0001';
  end if;
  if (v_check ->> 'team_members')::int > 0 then
    raise exception 'owner_has_team' using errcode = 'P0001';
  end if;
  if (v_check ->> 'active_bookings')::int > 0 then
    raise exception 'has_active_bookings' using errcode = 'P0001';
  end if;
  v_biz := (v_check ->> 'business_id')::uuid;

  perform public.trust();
  if v_biz is not null then
    -- Open business with other vendors: close it politely.
    update public.quote_requests set status = 'cancelled', updated_at = now()
     where v_biz in (requester_business_id, supplier_business_id) and status in ('open', 'quoted');
    update public.quotations q set status = 'withdrawn'
      from public.quote_requests r where r.id = q.request_id and q.status = 'sent' and v_biz in (r.requester_business_id, r.supplier_business_id);
    update public.now_offers set status = 'withdrawn', updated_at = now() where supplier_business_id = v_biz and status = 'pending';
    update public.now_requests set status = 'cancelled', updated_at = now()
     where requester_business_id = v_biz and status in ('draft', 'broadcasting', 'receiving_offers', 'offer_selected');

    -- Private business data.
    delete from public.events where business_id = v_biz;
    delete from public.availability_blocks where business_id = v_biz;
    delete from public.verification_documents where business_id = v_biz;
    delete from public.listing_photos p using public.listings l where l.id = p.listing_id and l.business_id = v_biz;
    update public.listings set status = 'archived', description = '', terms = '' where business_id = v_biz;
    delete from public.category_subscriptions where business_id = v_biz;
    delete from public.supplier_follows where business_id = v_biz or supplier_id = v_biz;
    delete from public.notifications where recipient_business_id = v_biz;
    delete from public.business_categories where business_id = v_biz;

    -- Keep the row for counterparties' history, without identity.
    update public.businesses
       set name = 'Deleted business', description = '', logo_path = null, phone = null, whatsapp = null, email = null,
           neighbourhood = null, address_line = null, location = null, public_location = null,
           status = 'suspended', verification_status = 'unverified', owner_id = null
     where id = v_biz;
  end if;

  -- Login, profile, memberships and device tokens (cascade).
  delete from auth.users where id = v_uid;
end $$;

revoke execute on function public.account_deletion_check() from public, anon;
revoke execute on function public.delete_my_account() from public, anon;
grant execute on function public.account_deletion_check() to authenticated, service_role;
grant execute on function public.delete_my_account() to authenticated, service_role;

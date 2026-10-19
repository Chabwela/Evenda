-- Row Level Security, column privileges, storage buckets and realtime.
-- Principle: clients read what they are entitled to and write only plain
-- fields on rows they own. Everything with business rules goes through RPCs.

-- ---------------------------------------------------------------------------
-- Business-level RPCs used by onboarding
-- ---------------------------------------------------------------------------
create or replace function public.create_business(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated' using errcode = '28000'; end if;
  -- One owned business per account in this release.
  select id into v_id from public.businesses where owner_id = auth.uid();
  if v_id is not null then return v_id; end if;
  insert into public.businesses (owner_id, name) values (auth.uid(), p_name) returning id into v_id;
  return v_id;
end $$;

create or replace function public.set_business_location(p_business uuid, p_lat float8, p_lng float8,
                                                        p_precision public.location_precision, p_neighbourhood text)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.trust();
  perform public.require_member(p_business, true);
  -- Zambia bounding box sanity check.
  if p_lat not between -18.2 and -8.1 or p_lng not between 21.9 and 33.8 then
    raise exception 'location_outside_zambia' using errcode = '22023';
  end if;
  update public.businesses
     set location = extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography,
         location_precision = p_precision, neighbourhood = p_neighbourhood
   where id = p_business;
end $$;

create or replace function public.complete_onboarding(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
declare b public.businesses; v_missing text[] := '{}';
begin
  perform public.trust();
  perform public.require_member(p_business, true);
  select * into b from public.businesses where id = p_business for update;
  if b.primary_category is null then v_missing := v_missing || 'primary_category'; end if;
  if cardinality(b.offering_types) = 0 then v_missing := v_missing || 'offering_types'; end if;
  if b.phone is null then v_missing := v_missing || 'phone'; end if;
  if b.location is null then v_missing := v_missing || 'location'; end if;
  if cardinality(v_missing) > 0 then
    raise exception 'onboarding_incomplete' using errcode = '22023', detail = array_to_string(v_missing, ',');
  end if;
  update public.businesses set onboarding_completed_at = coalesce(onboarding_completed_at, now()) where id = p_business;
  insert into public.category_subscriptions (business_id, category_id)
  select p_business, c.id from public.categories c
   where c.active and c.id <> b.primary_category
     and c.kind = 'rental' and 'rental' = any (b.offering_types)
  on conflict do nothing;
end $$;

create or replace function public.submit_for_verification(p_business uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public.require_member(p_business, true);
  if not exists (select 1 from public.verification_documents where business_id = p_business) then
    raise exception 'documents_required' using errcode = '22023';
  end if;
  perform public.trust();
  update public.businesses set verification_status = 'pending'
   where id = p_business and verification_status in ('unverified', 'rejected');
end $$;

create or replace function public.guard_business_columns()
returns trigger language plpgsql as $$
begin
  if coalesce(current_setting('evenda.trusted', true), '') <> 'on'
     and current_setting('role', true) in ('authenticated', 'anon')
     and (new.verification_status is distinct from old.verification_status
          or new.status is distinct from old.status
          or new.owner_id is distinct from old.owner_id
          or new.onboarding_completed_at is distinct from old.onboarding_completed_at
          or new.location is distinct from old.location
          or new.public_location is distinct from old.public_location) then
    raise exception 'use_business_rpc' using errcode = '42501';
  end if;
  return new;
end $$;

create trigger businesses_guard before update on public.businesses
  for each row execute function public.guard_business_columns();

-- ---------------------------------------------------------------------------
-- Enable RLS everywhere
-- ---------------------------------------------------------------------------
do $$
declare t text;
begin
  foreach t in array array[
    'profiles', 'categories', 'businesses', 'business_categories', 'business_members', 'verification_documents',
    'listings', 'listing_photos', 'stock_adjustments', 'reservations', 'availability_blocks',
    'notification_preferences', 'category_subscriptions', 'supplier_follows', 'device_tokens', 'notifications',
    'notification_deliveries', 'inventory_events',
    'quote_requests', 'quote_request_items', 'quote_messages', 'quotations', 'quotation_items',
    'bookings', 'booking_items', 'booking_status_history', 'payment_records',
    'events', 'event_requirements', 'tasks', 'reminders', 'task_templates',
    'now_requests', 'now_request_recipients', 'now_offers', 'now_status_history',
    'platform_admins', 'audit_logs', 'disputes'
  ] loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end $$;

-- Profiles
create policy profiles_self_read on public.profiles for select using (id = auth.uid() or public.admin_has('business.read'));
create policy profiles_self_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());

-- Categories: readable by all signed-in users, changed only by admin RPC.
create policy categories_read on public.categories for select to authenticated using (true);
create policy task_templates_read on public.task_templates for select to authenticated using (true);

-- Businesses: the directory is visible to signed-in users; members see their own drafts.
create policy businesses_read on public.businesses for select to authenticated using (
  (status = 'active' and onboarding_completed_at is not null)
  or public.is_member(id)
  or public.admin_has('business.read')
);
create policy businesses_update on public.businesses for update to authenticated
  using (public.can_manage(id)) with check (public.can_manage(id));

-- Hide the exact location column from API roles. Clients use public_location.
revoke select on public.businesses from anon, authenticated;
grant select (id, owner_id, name, description, logo_path, primary_category, offering_types, phone, whatsapp, email,
              neighbourhood, address_line, location_precision, public_location, service_radius_km, operating_hours,
              onboarding_step, onboarding_completed_at, verification_status, status, created_at, updated_at)
  on public.businesses to authenticated;
revoke update on public.businesses from anon, authenticated;
grant update (name, description, logo_path, primary_category, offering_types, phone, whatsapp, email, address_line,
              service_radius_km, operating_hours, onboarding_step)
  on public.businesses to authenticated;
revoke insert, delete on public.businesses from anon, authenticated;

create policy business_categories_read on public.business_categories for select to authenticated using (true);
create policy business_categories_write on public.business_categories for all to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));

create policy members_read on public.business_members for select to authenticated
  using (public.is_member(business_id) or public.admin_has('business.read'));
create policy members_write on public.business_members for insert to authenticated
  with check (public.is_member(business_id, array['owner']::public.member_role[]) and role <> 'owner');
create policy members_update on public.business_members for update to authenticated
  using (public.is_member(business_id, array['owner']::public.member_role[]) and role <> 'owner')
  with check (role <> 'owner');

create policy verification_docs_member on public.verification_documents for select to authenticated
  using (public.can_manage(business_id) or public.admin_has('business.verify'));
create policy verification_docs_insert on public.verification_documents for insert to authenticated
  with check (public.can_manage(business_id) and status = 'submitted');

-- Listings
create policy listings_read on public.listings for select to authenticated using (
  public.is_member(business_id)
  or public.admin_has('listing.moderate')
  or (status = 'published' and moderation_status = 'ok'
      and exists (select 1 from public.businesses b where b.id = business_id and b.status = 'active'))
);
create policy listings_update on public.listings for update to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));
revoke insert, delete on public.listings from anon, authenticated;

create policy listing_photos_read on public.listing_photos for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id));
create policy listing_photos_write on public.listing_photos for all to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and public.can_manage(l.business_id)))
  with check (exists (select 1 from public.listings l where l.id = listing_id and public.can_manage(l.business_id)));

create policy stock_adjustments_read on public.stock_adjustments for select to authenticated
  using (exists (select 1 from public.listings l where l.id = listing_id and public.is_member(l.business_id)));

-- Reservations reveal who a vendor works for: members only.
create policy reservations_read on public.reservations for select to authenticated using (public.is_member(business_id));
revoke insert, update, delete on public.reservations from anon, authenticated;

create policy blocks_read on public.availability_blocks for select to authenticated using (public.is_member(business_id));
create policy blocks_write on public.availability_blocks for all to authenticated
  using (public.can_manage(business_id)) with check (public.can_manage(business_id));

-- Notifications & preferences
create policy prefs_rw on public.notification_preferences for all to authenticated
  using (public.is_member(business_id)) with check (public.can_manage(business_id));
create policy subs_rw on public.category_subscriptions for all to authenticated
  using (public.is_member(business_id)) with check (public.can_manage(business_id));
create policy follows_rw on public.supplier_follows for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy tokens_rw on public.device_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy notifications_read on public.notifications for select to authenticated using (public.is_member(recipient_business_id));
create policy notifications_mark_read on public.notifications for update to authenticated
  using (public.is_member(recipient_business_id)) with check (public.is_member(recipient_business_id));
revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;
create policy inventory_events_read on public.inventory_events for select to authenticated using (
  type not in ('listing_paused', 'listing_removed') or public.is_member(business_id)
);

-- Quotes & bookings: the two parties only (plus admins with the right permission).
create policy quote_requests_read on public.quote_requests for select to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id) or public.admin_has('booking.read'));
create policy quote_items_read on public.quote_request_items for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quote_messages_read on public.quote_messages for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quotations_read on public.quotations for select to authenticated using (
  exists (select 1 from public.quote_requests q where q.id = request_id));
create policy quotation_items_read on public.quotation_items for select to authenticated using (
  exists (select 1 from public.quotations q where q.id = quotation_id));
create policy bookings_read on public.bookings for select to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id) or public.admin_has('booking.read'));
create policy bookings_update_notes on public.bookings for update to authenticated using (
  public.is_member(requester_business_id) or public.is_member(supplier_business_id));
revoke update on public.bookings from authenticated;
grant update (delivery_notes, event_id) on public.bookings to authenticated;
create policy booking_items_read on public.booking_items for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id));
create policy booking_history_read on public.booking_status_history for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id));
create policy payments_read on public.payment_records for select to authenticated using (
  exists (select 1 from public.bookings b where b.id = booking_id
          and (public.is_member(b.requester_business_id) or public.is_member(b.supplier_business_id)))
  or public.admin_has('payment.read'));

-- Events & tasks: private to the business.
create policy events_rw on public.events for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy requirements_rw on public.event_requirements for all to authenticated
  using (exists (select 1 from public.events e where e.id = event_id and public.is_member(e.business_id)))
  with check (exists (select 1 from public.events e where e.id = event_id and public.is_member(e.business_id)));
create policy tasks_rw on public.tasks for all to authenticated
  using (public.is_member(business_id)) with check (public.is_member(business_id));
create policy reminders_read on public.reminders for select to authenticated using (public.is_member(business_id));

-- Evenda Now
create policy now_requests_read on public.now_requests for select to authenticated using (
  public.is_member(requester_business_id)
  or exists (select 1 from public.now_request_recipients r where r.request_id = id and public.is_member(r.business_id))
  or public.admin_has('now.read'));
create policy now_recipients_read on public.now_request_recipients for select to authenticated using (
  public.is_member(business_id) or public.admin_has('now.read'));
create policy now_offers_read on public.now_offers for select to authenticated using (
  public.is_member(supplier_business_id)
  or exists (select 1 from public.now_requests q where q.id = request_id and public.is_member(q.requester_business_id))
  or public.admin_has('now.read'));
create policy now_history_read on public.now_status_history for select to authenticated using (
  exists (select 1 from public.now_requests q where q.id = request_id));

-- Admin
create policy admins_self on public.platform_admins for select to authenticated
  using (user_id = auth.uid() or public.admin_has('admin.manage'));
create policy audit_read on public.audit_logs for select to authenticated using (public.admin_has('audit.read'));
create policy disputes_read on public.disputes for select to authenticated using (
  public.admin_has('dispute.manage')
  or exists (select 1 from public.bookings b where b.id = booking_id
             and (public.is_member(b.requester_business_id) or public.is_member(b.supplier_business_id))));

-- Internal functions must not be callable from the client.
revoke execute on function public.notify(uuid, public.notification_category, text, text, text, text, jsonb, public.delivery_mode, text, boolean) from public, anon, authenticated;
revoke execute on function public.reserve_stock(uuid, int, date, date, public.reservation_source, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.claim_push_deliveries(int) from public, anon, authenticated;
revoke execute on function public.complete_push_delivery(uuid, boolean, text) from public, anon, authenticated;
revoke execute on function public.process_due_reminders(int) from public, anon, authenticated;
revoke execute on function public.build_digests() from public, anon, authenticated;
revoke execute on function public.expire_now_requests() from public, anon, authenticated;
revoke execute on function public.expire_quotations() from public, anon, authenticated;
revoke execute on function public.generate_booking_tasks(uuid) from public, anon, authenticated;
revoke execute on function public.emit_inventory_event(uuid, uuid, public.inventory_event_type, text, jsonb, text) from public, anon, authenticated;
revoke execute on function public.write_audit(text, text, text, text, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.now_set_status(uuid, public.now_status, text) from public, anon, authenticated;
revoke execute on function public.refresh_payment_status(uuid) from public, anon, authenticated;
revoke execute on function public.trust() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('listing-photos', 'listing-photos', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('business-logos', 'business-logos', true, 2097152, array['image/jpeg', 'image/png', 'image/webp']),
  ('verification', 'verification', false, 10485760, array['image/jpeg', 'image/png', 'application/pdf'])
on conflict (id) do nothing;

-- Object paths start with the business id: <business_id>/<file>.
create policy storage_public_read on storage.objects for select
  using (bucket_id in ('listing-photos', 'business-logos'));
create policy storage_business_write on storage.objects for insert to authenticated
  with check (bucket_id in ('listing-photos', 'business-logos', 'verification')
              and public.can_manage(((storage.foldername(name))[1])::uuid));
create policy storage_business_delete on storage.objects for delete to authenticated
  using (bucket_id in ('listing-photos', 'business-logos') and public.can_manage(((storage.foldername(name))[1])::uuid));
create policy storage_verification_read on storage.objects for select to authenticated
  using (bucket_id = 'verification'
         and (public.can_manage(((storage.foldername(name))[1])::uuid) or public.admin_has('business.verify')));

-- ---------------------------------------------------------------------------
-- Realtime: rows clients subscribe to (RLS still applies).
-- ---------------------------------------------------------------------------
alter publication supabase_realtime add table public.notifications, public.now_requests, public.now_offers,
  public.now_request_recipients, public.bookings, public.quote_requests, public.quotations, public.tasks;

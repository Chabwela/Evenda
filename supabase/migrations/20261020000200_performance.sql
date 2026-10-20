-- Performance and concurrency (beta hardening).
--
-- 1. available_quantities(): date-aware availability for many listings in one
--    call. Supplier search with dates called available_quantity once per
--    result (up to 60 sequential round trips, ~370 ms each measured from
--    Lusaka on 2026-10-20, i.e. up to ~22 s).
-- 2. businesses.updated_at now changes on every update, so the app can detect
--    that someone else saved the profile in between (optimistic concurrency).
--    Before, only name/description/location edits touched it.
-- 3. Indexes on foreign keys the app filters or embeds by. Postgres does not
--    index referencing columns automatically; every embedded select
--    (listing_photos, booking_items, payment_records, quotations, ...) and
--    several RLS policies look rows up by these columns.

-- 1 ---------------------------------------------------------------------------
create or replace function public.available_quantities(p_listings uuid[], p_from date, p_to date)
returns table (listing_id uuid, available int)
language sql stable security definer set search_path = public as $$
  -- available_quantity applies the same visibility rule per listing
  -- (own business, or published and not moderated).
  select l, public.available_quantity(l, p_from, p_to)
    from unnest(p_listings[1:100]) as l
   where p_to - p_from <= 92;
$$;

revoke execute on function public.available_quantities(uuid[], date, date) from public, anon;
grant execute on function public.available_quantities(uuid[], date, date) to authenticated, service_role;

-- 2 ---------------------------------------------------------------------------
drop trigger if exists businesses_touch on public.businesses;
create trigger businesses_touch before update on public.businesses
  for each row execute function public.touch_updated_at();

-- 3 ---------------------------------------------------------------------------
create index if not exists listing_photos_listing_idx       on public.listing_photos (listing_id, sort);
create index if not exists booking_items_booking_idx        on public.booking_items (booking_id);
create index if not exists booking_history_booking_idx      on public.booking_status_history (booking_id, created_at);
create index if not exists payment_records_booking_idx      on public.payment_records (booking_id);
create index if not exists quote_request_items_request_idx  on public.quote_request_items (request_id);
create index if not exists quote_messages_request_idx       on public.quote_messages (request_id, created_at);
create index if not exists reservations_booking_idx         on public.reservations (booking_id) where booking_id is not null;
create index if not exists reservations_business_idx        on public.reservations (business_id, starts_on);
create index if not exists tasks_booking_idx                on public.tasks (booking_id) where booking_id is not null;
create index if not exists tasks_event_idx                  on public.tasks (event_id) where event_id is not null;
create index if not exists reminders_task_idx               on public.reminders (task_id);
create index if not exists event_requirements_event_idx     on public.event_requirements (event_id);
create index if not exists stock_adjustments_listing_idx    on public.stock_adjustments (listing_id, created_at);
create index if not exists verification_documents_biz_idx   on public.verification_documents (business_id);
create index if not exists device_tokens_user_idx           on public.device_tokens (user_id);
create index if not exists now_recipients_business_idx      on public.now_request_recipients (business_id);
create index if not exists now_offers_request_idx           on public.now_offers (request_id, created_at);
create index if not exists now_history_request_idx          on public.now_status_history (request_id, created_at);
create index if not exists inventory_events_business_idx    on public.inventory_events (business_id, created_at desc);
create index if not exists disputes_booking_idx             on public.disputes (booking_id);
create index if not exists business_members_business_idx    on public.business_members (business_id) where status = 'active';

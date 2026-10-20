-- Review queue: count only the businesses where it's the admin's move.
--
-- Before: every business with verification 'pending' counted as "needs your
-- decision", including ones whose only document had been rejected and that
-- were waiting for the vendor to upload a replacement.
--
-- Now:
--   * admin_list_businesses also returns, per business, how many documents are
--     still unreviewed and how many are accepted (so the list can say "To
--     review", "Ready to verify" or "Waiting for vendor").
--   * admin_platform_stats.pending_verification counts pending businesses with
--     something to decide (an unreviewed or an accepted document);
--     waiting_vendor counts the rest.

drop function if exists public.admin_list_businesses(text, public.verification_status);
create function public.admin_list_businesses(p_search text default null, p_verification public.verification_status default null)
returns table (id uuid, name text, neighbourhood text, primary_category text, verification_status public.verification_status,
               status public.business_status, created_at timestamptz, listings int, documents int,
               documents_to_review int, documents_accepted int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('business.read');
  return query
  select b.id, b.name, b.neighbourhood, b.primary_category, b.verification_status, b.status, b.created_at,
         (select count(*) from public.listings l where l.business_id = b.id)::int,
         (select count(*) from public.verification_documents d where d.business_id = b.id)::int,
         (select count(*) from public.verification_documents d where d.business_id = b.id and d.status = 'submitted')::int,
         (select count(*) from public.verification_documents d where d.business_id = b.id and d.status = 'accepted')::int
    from public.businesses b
   where (p_search is null or b.name ilike '%' || p_search || '%')
     and (p_verification is null or b.verification_status = p_verification)
   order by b.created_at desc
   limit 200;
end $$;

create or replace function public.admin_platform_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('activity.read');
  return jsonb_build_object(
    'businesses', (select count(*) from public.businesses where onboarding_completed_at is not null),
    'pending_verification', (select count(*) from public.businesses b where b.verification_status = 'pending'
                               and exists (select 1 from public.verification_documents d
                                            where d.business_id = b.id and d.status in ('submitted', 'accepted'))),
    'waiting_vendor', (select count(*) from public.businesses b where b.verification_status = 'pending'
                         and not exists (select 1 from public.verification_documents d
                                          where d.business_id = b.id and d.status in ('submitted', 'accepted'))),
    'published_listings', (select count(*) from public.listings where status = 'published'),
    'flagged_listings', (select count(*) from public.listings where moderation_status = 'flagged'),
    'open_quote_requests', (select count(*) from public.quote_requests where status in ('open', 'quoted')),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'now_open', (select count(*) from public.now_requests where status in ('broadcasting', 'receiving_offers', 'offer_selected')),
    'open_disputes', (select count(*) from public.disputes where status in ('open', 'investigating')),
    'push_failed_24h', (select count(*) from public.notification_deliveries where status in ('failed', 'skipped') and created_at > now() - interval '1 day')
  );
end $$;

-- Function lockdown (20261019000100): a re-created function starts closed.
revoke execute on function public.admin_list_businesses(text, public.verification_status) from public, anon;
grant execute on function public.admin_list_businesses(text, public.verification_status) to authenticated, service_role;

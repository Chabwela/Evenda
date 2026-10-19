-- Platform administration. Admins are granted only by inserting into
-- platform_admins with the service role (or by a super_admin through the RPC).
-- There is no client path to become an admin.

create type public.admin_role as enum ('super_admin', 'moderator', 'support', 'finance');

create table public.platform_admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  role public.admin_role not null,
  display_name text not null default '',
  active boolean not null default true,
  created_by uuid references auth.users (id),
  created_at timestamptz not null default now()
);

-- Permission matrix. Each admin action checks one permission.
create or replace function public.admin_has(p_permission text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.platform_admins a
    where a.user_id = auth.uid() and a.active and (
      a.role = 'super_admin'
      or (a.role = 'moderator' and p_permission in
          ('business.read', 'business.verify', 'listing.moderate', 'category.manage', 'activity.read', 'now.read', 'audit.read'))
      or (a.role = 'support' and p_permission in
          ('business.read', 'booking.read', 'dispute.manage', 'activity.read', 'now.read'))
      or (a.role = 'finance' and p_permission in
          ('business.read', 'booking.read', 'payment.read', 'report.read'))
    )
  );
$$;

create or replace function public.my_admin_role()
returns public.admin_role language sql stable security definer set search_path = public as $$
  select role from public.platform_admins where user_id = auth.uid() and active;
$$;

create table public.audit_logs (
  id bigint generated always as identity primary key,
  actor_user_id uuid references auth.users (id),
  actor_role public.admin_role,
  action text not null,
  target_table text not null,
  target_id text not null,
  reason text,
  before jsonb,
  after jsonb,
  created_at timestamptz not null default now()
);

create index audit_logs_target_idx on public.audit_logs (target_table, target_id);
create index audit_logs_created_idx on public.audit_logs (created_at desc);

-- Audit rows are append-only, even for the table owner via the API roles.
create or replace function public.audit_logs_immutable()
returns trigger language plpgsql as $$
begin raise exception 'audit_logs_are_append_only' using errcode = '42501'; end $$;

create trigger audit_logs_no_update before update or delete on public.audit_logs
  for each row execute function public.audit_logs_immutable();

create or replace function public.write_audit(p_action text, p_table text, p_id text, p_reason text, p_before jsonb, p_after jsonb)
returns void language sql security definer set search_path = public as $$
  insert into public.audit_logs (actor_user_id, actor_role, action, target_table, target_id, reason, before, after)
  values (auth.uid(), public.my_admin_role(), p_action, p_table, p_id, p_reason, p_before, p_after);
$$;

create or replace function public.require_admin(p_permission text, p_reason text default null, p_reason_required boolean default false)
returns void language plpgsql stable security definer set search_path = public as $$
begin
  if not public.admin_has(p_permission) then
    raise exception 'admin_forbidden' using errcode = '42501', detail = p_permission;
  end if;
  if p_reason_required and coalesce(char_length(trim(p_reason)), 0) < 5 then
    raise exception 'reason_required' using errcode = '22023', hint = 'Give a reason of at least 5 characters.';
  end if;
end $$;

create table public.disputes (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id),
  opened_by_business uuid not null references public.businesses (id),
  reason text not null check (char_length(reason) between 10 and 2000),
  status text not null default 'open' check (status in ('open', 'investigating', 'resolved', 'dismissed')),
  resolution text,
  assigned_admin uuid references auth.users (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.open_dispute(p_booking uuid, p_business uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid;
begin
  perform public.require_member(p_business, true);
  select * into b from public.bookings where id = p_booking;
  if p_business not in (b.requester_business_id, b.supplier_business_id) then raise exception 'forbidden' using errcode = '42501'; end if;
  insert into public.disputes (booking_id, opened_by_business, reason) values (p_booking, p_business, p_reason) returning id into v_id;
  perform public.update_booking_status(p_booking, 'disputed', 'Dispute opened');
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Admin RPCs: every sensitive action requires a reason and writes an audit row.
-- ---------------------------------------------------------------------------
create or replace function public.admin_set_verification(p_business uuid, p_status public.verification_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.trust();
  perform public.require_admin('business.verify', p_reason, p_status = 'rejected');
  select jsonb_build_object('verification_status', verification_status) into v_before from public.businesses where id = p_business;
  update public.businesses set verification_status = p_status where id = p_business;
  perform public.write_audit('business.verification', 'businesses', p_business::text, p_reason, v_before,
                             jsonb_build_object('verification_status', p_status));
  perform public.notify(p_business, 'system',
    case p_status when 'verified' then 'Your business is verified' when 'rejected' then 'Verification needs attention' else 'Verification updated' end,
    coalesce(p_reason, ''), 'verify:' || p_status || ':' || now()::date, '/business/profile', '{}', 'immediate');
end $$;

create or replace function public.admin_set_business_status(p_business uuid, p_status public.business_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.trust();
  perform public.require_admin('business.verify', p_reason, true);
  select jsonb_build_object('status', status) into v_before from public.businesses where id = p_business;
  update public.businesses set status = p_status where id = p_business;
  perform public.write_audit('business.status', 'businesses', p_business::text, p_reason, v_before, jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_moderate_listing(p_listing uuid, p_status public.moderation_status, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare l public.listings;
begin
  perform public.require_admin('listing.moderate', p_reason, p_status <> 'ok');
  select * into l from public.listings where id = p_listing for update;
  perform public.trust();
  update public.listings set moderation_status = p_status, moderation_reason = p_reason where id = p_listing;
  perform public.write_audit('listing.moderate', 'listings', p_listing::text, p_reason,
    jsonb_build_object('moderation_status', l.moderation_status), jsonb_build_object('moderation_status', p_status));
  if p_status <> 'ok' then
    perform public.notify(l.business_id, 'system', '“' || l.title || '” was ' || p_status::text || ' by moderation',
      p_reason, 'mod:' || p_listing || ':' || p_status || ':' || now()::date, '/business/listings/' || p_listing, '{}', 'immediate');
  end if;
end $$;

create or replace function public.admin_resolve_dispute(p_dispute uuid, p_status text, p_resolution text)
returns void language plpgsql security definer set search_path = public as $$
declare d public.disputes;
begin
  perform public.require_admin('dispute.manage', p_resolution, true);
  select * into d from public.disputes where id = p_dispute for update;
  update public.disputes set status = p_status, resolution = p_resolution, assigned_admin = auth.uid(), updated_at = now()
   where id = p_dispute;
  perform public.write_audit('dispute.update', 'disputes', p_dispute::text, p_resolution,
    jsonb_build_object('status', d.status), jsonb_build_object('status', p_status));
end $$;

create or replace function public.admin_upsert_category(p_id text, p_name text, p_kind public.offering_type, p_active boolean, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_before jsonb;
begin
  perform public.require_admin('category.manage', p_reason, false);
  select to_jsonb(c) into v_before from public.categories c where id = p_id;
  insert into public.categories (id, name, kind, active) values (p_id, p_name, p_kind, p_active)
  on conflict (id) do update set name = excluded.name, kind = excluded.kind, active = excluded.active;
  perform public.write_audit('category.upsert', 'categories', p_id, p_reason, v_before,
    jsonb_build_object('name', p_name, 'kind', p_kind, 'active', p_active));
end $$;

create or replace function public.admin_grant_role(p_user uuid, p_role public.admin_role, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if public.my_admin_role() is distinct from 'super_admin' then raise exception 'admin_forbidden' using errcode = '42501'; end if;
  perform public.require_admin('admin.manage', p_reason, true);
  insert into public.platform_admins (user_id, role, created_by) values (p_user, p_role, auth.uid())
  on conflict (user_id) do update set role = excluded.role, active = true;
  perform public.write_audit('admin.grant', 'platform_admins', p_user::text, p_reason, null, jsonb_build_object('role', p_role));
end $$;

create or replace function public.admin_platform_stats()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('activity.read');
  return jsonb_build_object(
    'businesses', (select count(*) from public.businesses where onboarding_completed_at is not null),
    'pending_verification', (select count(*) from public.businesses where verification_status = 'pending'),
    'published_listings', (select count(*) from public.listings where status = 'published'),
    'flagged_listings', (select count(*) from public.listings where moderation_status = 'flagged'),
    'open_quote_requests', (select count(*) from public.quote_requests where status in ('open', 'quoted')),
    'bookings_30d', (select count(*) from public.bookings where created_at > now() - interval '30 days'),
    'now_open', (select count(*) from public.now_requests where status in ('broadcasting', 'receiving_offers', 'offer_selected')),
    'open_disputes', (select count(*) from public.disputes where status in ('open', 'investigating')),
    'push_failed_24h', (select count(*) from public.notification_deliveries where status in ('failed', 'skipped') and created_at > now() - interval '1 day')
  );
end $$;

-- Business directory for admins (exact location withheld from non-super admins).
create or replace function public.admin_list_businesses(p_search text default null, p_verification public.verification_status default null)
returns table (id uuid, name text, neighbourhood text, primary_category text, verification_status public.verification_status,
               status public.business_status, created_at timestamptz, listings int, documents int)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_admin('business.read');
  return query
  select b.id, b.name, b.neighbourhood, b.primary_category, b.verification_status, b.status, b.created_at,
         (select count(*) from public.listings l where l.business_id = b.id)::int,
         (select count(*) from public.verification_documents d where d.business_id = b.id)::int
    from public.businesses b
   where (p_search is null or b.name ilike '%' || p_search || '%')
     and (p_verification is null or b.verification_status = p_verification)
   order by b.created_at desc
   limit 200;
end $$;

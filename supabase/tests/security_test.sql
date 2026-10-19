-- Evenda database security tests (beta QA, phase 3).
--
-- Run in Supabase SQL Editor (as postgres) AFTER the migrations, ideally on a
-- staging project. The whole script runs in one transaction and ends with
-- ROLLBACK: the fictional users, businesses and listings it creates are never
-- kept, and no email is sent (users are inserted directly, not via sign-up).
--
-- Output: a NOTICE per check. Any failure raises an exception and stops.

begin;

create temporary table qa_ids (k text primary key, v uuid) on commit drop;
grant all on qa_ids to authenticated, anon;

-- Helpers ---------------------------------------------------------------------
create or replace function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  execute 'reset role'; -- back to postgres first: anon may not switch to authenticated
  if p_user is null then
    perform set_config('request.jwt.claims', '{"role":"anon"}', true);
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
  end if;
end $$;

create or replace function pg_temp.as_admin() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

create or replace function pg_temp.id(p text) returns uuid language sql as $$ select v from qa_ids where k = p $$;

create or replace function pg_temp.ok(p_name text) returns void language plpgsql as $$
begin raise notice 'PASS  %', p_name; end $$;

-- Expect a statement to be refused (any error, or zero rows affected for writes).
create or replace function pg_temp.denied(p_name text, p_sql text) returns void language plpgsql as $$
declare n int;
begin
  begin
    execute p_sql;
    get diagnostics n = row_count;
  exception when others then
    perform pg_temp.ok(p_name || '  [' || sqlerrm || ']');
    return;
  end;
  if n = 0 then
    perform pg_temp.ok(p_name || '  [0 rows]');
  else
    raise exception 'FAIL  % — statement succeeded (% rows): %', p_name, n, p_sql;
  end if;
end $$;


-- Fixtures (as postgres) ----------------------------------------------------------
insert into qa_ids values ('userA', gen_random_uuid()), ('userB', gen_random_uuid());
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
select v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'qa-' || k || '-' || left(v::text, 8) || '@example.invalid', '', now(),
       json_build_object('full_name', 'QA ' || k)::jsonb, now(), now()
  from qa_ids;

-- Vendor A: rental business with an exact pin hidden as "approximate".
select pg_temp.act_as(pg_temp.id('userA'));
insert into qa_ids select 'bizA', public.create_business('QA Rentals A');
select public.set_business_location(pg_temp.id('bizA'), -15.41672, 28.28330, 'approximate', 'Kabwata');
insert into qa_ids select 'draftA', public.create_listing(jsonb_build_object(
  'business_id', pg_temp.id('bizA'), 'kind', 'rental', 'title', 'QA draft chairs', 'category_id', 'chairs',
  'price_amount', 10, 'price_unit', 'per_item_per_day', 'total_quantity', 50));
insert into public.events (business_id, name, starts_at, ends_at) values (pg_temp.id('bizA'), 'QA private event', now() + interval '10 days', now() + interval '10 days 6 hours');

-- Vendor B: an unrelated business.
select pg_temp.act_as(pg_temp.id('userB'));
insert into qa_ids select 'bizB', public.create_business('QA Decor B');

-- 1. Signed-out visitors ---------------------------------------------------------
select pg_temp.act_as(null);
select pg_temp.denied('anon cannot run internal release_stale_push_claims', 'select public.release_stale_push_claims()');
select pg_temp.denied('anon cannot run now_eligible_suppliers', format('select * from public.now_eligible_suppliers(%L)', pg_temp.id('bizA')));
select pg_temp.denied('anon cannot run available_quantity', format('select public.available_quantity(%L, current_date, current_date)', pg_temp.id('draftA')));
select pg_temp.denied('anon cannot read businesses', 'select * from public.businesses');
do $$ begin
  if (select count(*) from public.listings) <> 0 then raise exception 'FAIL anon can read listings'; end if;
  perform pg_temp.ok('anon sees no listings');
exception when insufficient_privilege then perform pg_temp.ok('anon sees no listings  [permission denied]');
end $$;

-- 2. Vendor B against Vendor A ----------------------------------------------------
select pg_temp.act_as(pg_temp.id('userB'));
do $$ begin
  if exists (select 1 from public.listings where id = pg_temp.id('draftA')) then raise exception 'FAIL B can see A''s draft listing'; end if;
  perform pg_temp.ok('B cannot see A''s draft listing');
  if exists (select 1 from public.events where business_id = pg_temp.id('bizA')) then raise exception 'FAIL B can see A''s events'; end if;
  perform pg_temp.ok('B cannot see A''s events');
  if exists (select 1 from public.reservations where business_id = pg_temp.id('bizA')) then raise exception 'FAIL B can see A''s reservations'; end if;
  perform pg_temp.ok('B cannot see A''s reservations');
  if exists (select 1 from public.businesses where id = pg_temp.id('bizA')) then raise exception 'FAIL B can see A''s unfinished business'; end if;
  perform pg_temp.ok('B cannot see A''s business before onboarding is complete');
  if public.available_quantity(pg_temp.id('draftA'), current_date, current_date) <> 0 then raise exception 'FAIL B learns stock of A''s draft'; end if;
  perform pg_temp.ok('available_quantity reveals nothing about A''s draft to B');
  if exists (select 1 from public.availability_calendar(pg_temp.id('draftA'), current_date, current_date + 7)) then raise exception 'FAIL B reads A''s calendar'; end if;
  perform pg_temp.ok('B cannot read A''s availability calendar');
end $$;
select pg_temp.denied('B cannot read A''s exact location', format('select * from public.my_business_location(%L)', pg_temp.id('bizA')));
select pg_temp.denied('B cannot edit A''s listing', format('update public.listings set price_amount = 1 where id = %L', pg_temp.id('draftA')));
select pg_temp.denied('B cannot adjust A''s stock', format('select public.adjust_stock(%L, 100, ''purchase'')', pg_temp.id('draftA')));
select pg_temp.denied('B cannot add itself to A''s team', format('insert into public.business_members (business_id, user_id, role) values (%L, %L, ''manager'')', pg_temp.id('bizA'), pg_temp.id('userB')));
select pg_temp.denied('B cannot move A''s location', format('select public.set_business_location(%L, -15.4, 28.3, ''exact'', ''Roma'')', pg_temp.id('bizA')));
select pg_temp.denied('B cannot run internal notify()', format('select public.notify(%L, ''system'', ''x'', ''x'', ''qa'')', pg_temp.id('bizA')));
select pg_temp.denied('B cannot reserve stock directly', format('select public.reserve_stock(%L, 1, current_date, current_date, ''manual'')', pg_temp.id('draftA')));
select pg_temp.denied('B cannot run now_eligible_suppliers', format('select * from public.now_eligible_suppliers(%L)', pg_temp.id('bizA')));

-- 3. Privilege escalation ----------------------------------------------------------
select pg_temp.denied('B cannot make itself a platform admin', format('insert into public.platform_admins (user_id, role) values (%L, ''super_admin'')', pg_temp.id('userB')));
select pg_temp.denied('B cannot verify its own business', format('update public.businesses set verification_status = ''verified'' where id = %L', pg_temp.id('bizB')));
select pg_temp.denied('B cannot mark onboarding complete by hand', format('update public.businesses set onboarding_completed_at = now() where id = %L', pg_temp.id('bizB')));
select pg_temp.denied('B cannot run admin functions', format('select public.admin_set_verification(%L, ''verified'', ''qa test'')', pg_temp.id('bizB')));
select pg_temp.denied('B cannot read audit logs', 'select * from public.audit_logs where true');
do $$ begin
  if exists (select 1 from public.audit_logs) then raise exception 'FAIL B reads audit logs'; end if;
end $$;

-- 4. Vendor A's own access still works (no over-locking) --------------------------
select pg_temp.act_as(pg_temp.id('userA'));
do $$
declare r record;
begin
  if not exists (select 1 from public.listings where id = pg_temp.id('draftA')) then raise exception 'FAIL A cannot see own draft'; end if;
  perform pg_temp.ok('A sees its own draft listing');
  if public.available_quantity(pg_temp.id('draftA'), current_date, current_date) <> 50 then raise exception 'FAIL A stock wrong'; end if;
  perform pg_temp.ok('A sees its own stock (50)');
  select * into r from public.my_business_location(pg_temp.id('bizA'));
  if abs(r.lat - (-15.41672)) > 0.00001 then raise exception 'FAIL A exact pin wrong: %', r.lat; end if;
  perform pg_temp.ok('A reads back its exact pin');
end $$;

-- 5. Approximate location is really approximate ------------------------------------
select pg_temp.as_admin();
do $$
declare d float8;
begin
  select extensions.st_distance(location, public_location) into d from public.businesses where id = pg_temp.id('bizA');
  if d < 50 then raise exception 'FAIL public point is only % m from the exact pin', round(d); end if;
  perform pg_temp.ok(format('approximate public point is %s m from the exact pin', round(d)));
end $$;

do $$ begin raise notice 'ALL SECURITY CHECKS PASSED'; end $$;
rollback;

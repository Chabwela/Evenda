-- Payment integrity tests (migration 20261020000600). Run in the Supabase SQL
-- Editor after the migration, ideally on staging. Everything runs in one
-- transaction and ends with ROLLBACK: the fictional users, businesses, booking
-- and payments are never kept and no email is sent.
-- Output: a NOTICE per check; any failure raises and stops.
--
-- Not covered here (and why):
--   * provider transaction verification / repeated webhooks: Evenda has no
--     payment provider; payments are manual records confirmed by the other party.
--   * two truly concurrent requests: needs two database sessions. record_payment
--     locks the booking row (FOR UPDATE) before checking the balance, so
--     concurrent records are serialised; the duplicate-reference unique index
--     backs this up.

begin;

create temporary table qa (k text primary key, v uuid) on commit drop;
grant all on qa to authenticated, anon;

create or replace function pg_temp.act_as(p_user uuid) returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;
create or replace function pg_temp.id(p text) returns uuid language sql as $$ select v from qa where k = p $$;
create or replace function pg_temp.ok(p text) returns void language plpgsql as $$ begin raise notice 'PASS  %', p; end $$;
create or replace function pg_temp.expect_error(p_name text, p_code text, p_sql text) returns void language plpgsql as $$
begin
  execute p_sql;
  raise exception 'FAIL  % — expected %, but it succeeded', p_name, p_code;
exception when others then
  if sqlerrm like 'FAIL%' then raise; end if;
  if sqlerrm <> p_code then raise exception 'FAIL  % — expected %, got %', p_name, p_code, sqlerrm; end if;
  perform pg_temp.ok(p_name || '  [' || sqlerrm || ']');
end $$;
create or replace function pg_temp.rec(p_who text, p_amount numeric, p_kind text default 'payment', p_ref text default null) returns uuid language sql as $$
  select public.record_payment(pg_temp.id('booking'), pg_temp.id(p_who), p_amount, 'mobile_money', p_kind, p_ref);
$$;

-- Fixtures: supplier S, hirer H, unrelated vendor X; one K300 booking S -> H.
insert into qa values ('uS', gen_random_uuid()), ('uH', gen_random_uuid()), ('uX', gen_random_uuid());
insert into auth.users (id, instance_id, aud, role, email, encrypted_password, email_confirmed_at, raw_user_meta_data, created_at, updated_at)
select v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
       'qa-pay-' || k || '-' || left(v::text, 8) || '@example.invalid', '', now(), '{}'::jsonb, now(), now()
  from qa;
select pg_temp.act_as(pg_temp.id('uS')); insert into qa select 'S', public.create_business('QA Supplier');
select pg_temp.act_as(pg_temp.id('uH')); insert into qa select 'H', public.create_business('QA Hirer');
select pg_temp.act_as(pg_temp.id('uX')); insert into qa select 'X', public.create_business('QA Outsider');
reset role;
insert into qa select 'booking', id from (
  insert into public.bookings (source, requester_business_id, supplier_business_id, starts_on, ends_on, total, fulfilment)
  values ('manual', pg_temp.id('H'), pg_temp.id('S'), current_date + 30, current_date + 30, 300.00, 'pickup') returning id) b;

-- Validation ------------------------------------------------------------------
select pg_temp.act_as(pg_temp.id('uH'));
select pg_temp.expect_error('amount above the total is refused (EV-7AFD36)', 'payment_exceeds_balance', 'select pg_temp.rec(''H'', 3000)');
select pg_temp.expect_error('zero amount refused', 'invalid_amount', 'select pg_temp.rec(''H'', 0)');
select pg_temp.expect_error('negative amount refused', 'invalid_amount', 'select pg_temp.rec(''H'', -5)');
select pg_temp.expect_error('more than two decimals refused', 'invalid_amount', 'select pg_temp.rec(''H'', 10.005)');
select pg_temp.expect_error('unknown kind refused', 'invalid_payment_kind', 'select pg_temp.rec(''H'', 10, ''tip'')');
select pg_temp.expect_error('non-existent booking refused', 'not_found',
  format('select public.record_payment(%L, %L, 10, ''cash'', ''payment'')', gen_random_uuid(), pg_temp.id('H')));
select pg_temp.expect_error('recording as a business you are not in is refused', 'forbidden',
  format('select public.record_payment(%L, %L, 10, ''cash'', ''payment'')', pg_temp.id('booking'), pg_temp.id('S')));

select pg_temp.act_as(pg_temp.id('uX'));
select pg_temp.expect_error('an outsider business cannot record on the booking', 'forbidden', 'select pg_temp.rec(''X'', 10)');

-- Partial payments, pending double-record, duplicates ---------------------------
select pg_temp.act_as(pg_temp.id('uH'));
insert into qa select 'p1', pg_temp.rec('H', 100, 'deposit', 'AIRTEL-123');
select pg_temp.ok('deposit K100 recorded');
select pg_temp.expect_error('same transaction reference twice is refused', 'duplicate_payment_reference', 'select pg_temp.rec(''H'', 50, ''payment'', '' airtel-123 '')');
insert into qa select 'p2', pg_temp.rec('H', 200, 'payment', 'AIRTEL-456');
select pg_temp.ok('payment K200 recorded: K300 recorded in total (awaiting confirmation)');
select pg_temp.expect_error('unconfirmed records count against the balance (no double-recording)', 'payment_exceeds_balance', 'select pg_temp.rec(''H'', 1)');
select pg_temp.expect_error('refund before anything is confirmed is refused', 'refund_exceeds_paid', 'select pg_temp.rec(''H'', 10, ''refund'')');

-- Confirmation and voiding ----------------------------------------------------
select pg_temp.expect_error('the recorder cannot confirm its own record', 'forbidden', format('select public.confirm_payment(%L)', pg_temp.id('p1')));
select public.void_payment(pg_temp.id('p2'), 'typed the wrong amount');
select pg_temp.ok('recorder voided its own unconfirmed record');
select pg_temp.act_as(pg_temp.id('uS'));
select pg_temp.expect_error('a voided record cannot be confirmed', 'payment_voided', format('select public.confirm_payment(%L)', pg_temp.id('p2')));
select public.confirm_payment(pg_temp.id('p1'));
do $$ begin
  if (select payment_status from public.bookings where id = pg_temp.id('booking')) <> 'partially_paid' then
    raise exception 'FAIL status after K100 confirmed: %', (select payment_status from public.bookings where id = pg_temp.id('booking'));
  end if;
  perform pg_temp.ok('voided K200 ignored; K100 confirmed -> partially_paid');
end $$;
select pg_temp.act_as(pg_temp.id('uH'));
select pg_temp.expect_error('a confirmed record cannot be voided by a vendor', 'payment_confirmed', format('select public.void_payment(%L, ''changed my mind'')', pg_temp.id('p1')));
select pg_temp.expect_error('refund larger than confirmed paid is refused', 'refund_exceeds_paid', 'select pg_temp.rec(''H'', 150, ''refund'')');
insert into qa select 'p3', pg_temp.rec('H', 200, 'payment', 'AIRTEL-456');
select pg_temp.ok('voided reference may be reused for the corrected record (K200)');
select pg_temp.act_as(pg_temp.id('uS'));
select public.confirm_payment(pg_temp.id('p3'));
do $$ begin
  if (select payment_status from public.bookings where id = pg_temp.id('booking')) <> 'paid' then
    raise exception 'FAIL status after K300 confirmed: %', (select payment_status from public.bookings where id = pg_temp.id('booking'));
  end if;
  perform pg_temp.ok('K100 + K200 confirmed on K300 -> paid');
end $$;

-- Admin void ------------------------------------------------------------------
select pg_temp.expect_error('a vendor cannot use the admin void', 'admin_forbidden', format('select public.admin_void_payment(%L, ''reconcile'')', pg_temp.id('p3')));

-- Direct writes are impossible (RLS: payment_records is read-only to clients).
do $$
declare n int;
begin
  update public.payment_records set amount = 1, confirmed_by_counterparty_at = now() where booking_id = pg_temp.id('booking');
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL direct update changed % rows', n; end if;
  perform pg_temp.ok('direct UPDATE of payment records changes nothing');
exception when insufficient_privilege then perform pg_temp.ok('direct UPDATE of payment records refused');
end $$;
select pg_temp.expect_error('direct INSERT of a confirmed payment is refused',
  'new row violates row-level security policy for table "payment_records"',
  format('insert into public.payment_records (booking_id, amount, method, kind, recorded_by_business, confirmed_by_counterparty_at) values (%L, 999, ''cash'', ''payment'', %L, now())',
         pg_temp.id('booking'), pg_temp.id('S')));

do $$ begin raise notice 'ALL PAYMENT CHECKS PASSED'; end $$;
rollback;

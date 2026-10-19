-- Events, requirements (responsibility model), tasks, reminders.
--
-- Rules:
--  * Tasks are generated only for requirements the current vendor is responsible for.
--    A decorator whose venue supplies chairs never gets chair-loading tasks.
--  * Generated tasks carry a generated_key, unique per business, so regenerating never duplicates.
--  * Generated tasks store offset_minutes relative to event start; moving an event moves them.
--  * Reminders are rows with a state machine; completing or cancelling a task cancels them.
--  * A scheduled job sends due reminders; sending is idempotent per reminder.

create type public.responsibility as enum ('self', 'venue', 'client', 'other_vendor', 'unassigned');
create type public.event_status as enum ('planning', 'confirmed', 'completed', 'cancelled');
create type public.task_priority as enum ('low', 'normal', 'high', 'critical');
create type public.task_status as enum ('todo', 'in_progress', 'done', 'cancelled');

create table public.events (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  name text not null check (char_length(name) between 2 and 120),
  event_type text not null default 'other'
    check (event_type in ('wedding', 'kitchen_party', 'corporate', 'funeral', 'birthday', 'graduation', 'church', 'other')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  venue_name text,
  venue_address text,
  client_name text,
  guest_count int check (guest_count is null or guest_count >= 0),
  notes text not null default '',
  status public.event_status not null default 'planning',
  source_booking_id uuid references public.bookings (id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at >= starts_at)
);

create index events_business_idx on public.events (business_id, starts_at);
create unique index events_from_booking_idx on public.events (business_id, source_booking_id) where source_booking_id is not null;

alter table public.quote_requests add constraint quote_requests_event_fk foreign key (event_id) references public.events (id) on delete set null;
alter table public.bookings add constraint bookings_event_fk foreign key (event_id) references public.events (id) on delete set null;

create table public.event_requirements (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  label text not null,
  category_id text references public.categories (id),
  quantity int check (quantity is null or quantity > 0),
  responsibility public.responsibility not null default 'unassigned',
  supplier_business_id uuid references public.businesses (id),
  booking_id uuid references public.bookings (id),
  notes text,
  created_at timestamptz not null default now()
);

create table public.tasks (
  id uuid primary key default gen_random_uuid(),
  business_id uuid not null references public.businesses (id) on delete cascade,
  event_id uuid references public.events (id) on delete cascade,
  booking_id uuid references public.bookings (id) on delete set null,
  requirement_id uuid references public.event_requirements (id) on delete set null,
  title text not null check (char_length(title) between 2 and 160),
  notes text not null default '',
  assignee_user_id uuid references auth.users (id),
  due_at timestamptz not null,
  offset_minutes int,
  priority public.task_priority not null default 'normal',
  status public.task_status not null default 'todo',
  generated_key text,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (business_id, generated_key)
);

create index tasks_business_due_idx on public.tasks (business_id, due_at) where status in ('todo', 'in_progress');

create table public.reminders (
  id uuid primary key default gen_random_uuid(),
  task_id uuid not null references public.tasks (id) on delete cascade,
  business_id uuid not null references public.businesses (id) on delete cascade,
  remind_at timestamptz not null,
  kind text not null check (kind in ('advance', 'deadline', 'snoozed')),
  status text not null default 'pending' check (status in ('pending', 'sent', 'cancelled')),
  sent_at timestamptz,
  created_at timestamptz not null default now()
);

create index reminders_due_idx on public.reminders (remind_at) where status = 'pending';

-- ---------------------------------------------------------------------------
-- Task templates: what a vendor should do, keyed by offering and responsibility.
-- offset is minutes relative to event start (negative = before).
-- ---------------------------------------------------------------------------
create table public.task_templates (
  key text primary key,
  title text not null,
  offset_minutes int not null,
  priority public.task_priority not null default 'normal',
  applies_to text not null check (applies_to in ('any', 'rental_supplier', 'service_supplier', 'requester', 'self_requirement')),
  category_kind public.offering_type
);

insert into public.task_templates (key, title, offset_minutes, priority, applies_to, category_kind) values
  ('confirm_venue_access',  'Confirm venue access and setup time',   -4320, 'high',     'any',               null),
  ('confirm_supplier',      'Confirm supplier availability',          -2880, 'high',     'requester',         null),
  ('confirm_payment',       'Confirm deposit or payment',             -4320, 'normal',   'rental_supplier',   null),
  ('check_stock',           'Check and count stock for this job',     -2880, 'high',     'rental_supplier',   null),
  ('prepare_load',          'Prepare and load equipment',              -720, 'high',     'rental_supplier',   null),
  ('prepare_materials',     'Prepare materials',                      -1440, 'normal',   'service_supplier',  null),
  ('complete_setup',        'Complete setup',                           -60, 'critical', 'any',               null),
  ('collect_equipment',     'Collect hired equipment',                  720, 'normal',   'requester',         'rental'),
  ('inspect_returns',       'Inspect returned equipment',              1440, 'normal',   'rental_supplier',   null),
  ('source_requirement',    'Arrange supply',                         -4320, 'high',     'self_requirement',  null);

-- Reminder schedule from priority: critical/high get 24h and 2h; normal 24h; low digest only.
create or replace function public.schedule_task_reminders(p_task uuid)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task;
  update public.reminders set status = 'cancelled' where task_id = p_task and status = 'pending';
  if t.status in ('done', 'cancelled') then return; end if;

  if t.priority in ('normal', 'high', 'critical') and t.due_at - interval '24 hours' > now() then
    insert into public.reminders (task_id, business_id, remind_at, kind) values (t.id, t.business_id, t.due_at - interval '24 hours', 'advance');
  end if;
  if t.priority in ('high', 'critical') and t.due_at - interval '2 hours' > now() then
    insert into public.reminders (task_id, business_id, remind_at, kind) values (t.id, t.business_id, t.due_at - interval '2 hours', 'deadline');
  end if;
end $$;

create or replace function public.tasks_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.due_at is distinct from old.due_at or new.status is distinct from old.status
     or new.priority is distinct from old.priority then
    perform public.schedule_task_reminders(new.id);
  end if;
  return new;
end $$;

create trigger tasks_reminders after insert or update on public.tasks
  for each row execute function public.tasks_after_change();

create or replace function public.tasks_before_change()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.status = 'done' and (tg_op = 'INSERT' or old.status <> 'done') then new.completed_at := now(); end if;
  if new.status <> 'done' then new.completed_at := null; end if;
  return new;
end $$;

create trigger tasks_touch before insert or update on public.tasks
  for each row execute function public.tasks_before_change();

-- Moving an event moves its relative tasks (unfinished only).
create or replace function public.events_after_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.starts_at is distinct from old.starts_at then
    update public.tasks
       set due_at = new.starts_at + make_interval(mins => offset_minutes)
     where event_id = new.id and offset_minutes is not null and status in ('todo', 'in_progress');
  end if;
  if new.status = 'cancelled' and old.status <> 'cancelled' then
    update public.tasks set status = 'cancelled' where event_id = new.id and status in ('todo', 'in_progress');
  end if;
  return new;
end $$;

create trigger events_reschedule after update on public.events
  for each row execute function public.events_after_change();

-- Generate tasks for an event for one business. Idempotent through generated_key.
create or replace function public.generate_event_tasks(p_event uuid)
returns int language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  r public.event_requirements;
  tpl public.task_templates;
  v_count int := 0;
  v_n int;
begin
  select * into e from public.events where id = p_event;
  perform public.require_member(e.business_id);

  -- Generic tasks for any event the vendor works.
  for tpl in select * from public.task_templates where applies_to = 'any' loop
    insert into public.tasks (business_id, event_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, tpl.title, e.starts_at + make_interval(mins => tpl.offset_minutes), tpl.offset_minutes,
            tpl.priority, 'event:' || e.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Requirements the vendor itself must supply but has not booked yet.
  for r in select * from public.event_requirements where event_id = e.id and responsibility = 'self' and booking_id is null loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id,
            'Arrange ' || r.label || coalesce(' (' || r.quantity || ')', ''),
            e.starts_at - interval '3 days', -4320, 'high', 'req:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Unassigned requirements need a decision.
  for r in select * from public.event_requirements where event_id = e.id and responsibility = 'unassigned' loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id, 'Decide who supplies ' || r.label,
            e.starts_at - interval '5 days', -7200, 'normal', 'req-assign:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  -- Requirements other parties handle: one light-touch confirmation, never operational tasks.
  for r in select * from public.event_requirements where event_id = e.id and responsibility in ('venue', 'client', 'other_vendor') loop
    insert into public.tasks (business_id, event_id, requirement_id, title, due_at, offset_minutes, priority, generated_key)
    values (e.business_id, e.id, r.id,
            'Confirm ' || replace(r.responsibility::text, '_', ' ') || ' is providing ' || r.label,
            e.starts_at - interval '2 days', -2880, 'low', 'req-confirm:' || r.id)
    on conflict (business_id, generated_key) do nothing;
    get diagnostics v_n = row_count; v_count := v_count + v_n;
  end loop;

  return v_count;
end $$;

-- Booking tasks for both sides; called inside accept_quotation and select_now_offer.
create or replace function public.generate_booking_tasks(p_booking uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  b public.bookings;
  tpl public.task_templates;
  v_start timestamptz;
  v_supplier_kind text;
begin
  select * into b from public.bookings where id = p_booking;
  v_start := (b.starts_on + time '08:00') at time zone 'Africa/Lusaka';
  select case when bool_or(l.kind = 'rental' and l.tracks_stock) then 'rental_supplier' else 'service_supplier' end
    into v_supplier_kind
    from public.booking_items bi left join public.listings l on l.id = bi.listing_id
   where bi.booking_id = b.id;

  for tpl in select * from public.task_templates where applies_to = coalesce(v_supplier_kind, 'service_supplier') loop
    insert into public.tasks (business_id, booking_id, title, due_at, priority, generated_key)
    values (b.supplier_business_id, b.id, tpl.title || ' · ' || b.reference,
            greatest(v_start + make_interval(mins => tpl.offset_minutes), now() + interval '1 hour'),
            tpl.priority, 'booking:' || b.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
  end loop;

  for tpl in select * from public.task_templates where applies_to = 'requester'
      and (category_kind is null or v_supplier_kind = 'rental_supplier') loop
    insert into public.tasks (business_id, booking_id, event_id, title, due_at, priority, generated_key)
    values (b.requester_business_id, b.id, b.event_id, tpl.title || ' · ' || b.reference,
            greatest(v_start + make_interval(mins => tpl.offset_minutes), now() + interval '1 hour'),
            tpl.priority, 'booking:' || b.id || ':' || tpl.key)
    on conflict (business_id, generated_key) do nothing;
  end loop;

  -- Link a requirement on the requester's event to this booking so its "Arrange" task can close.
  if b.event_id is not null then
    update public.tasks set status = 'done'
     where business_id = b.requester_business_id and event_id = b.event_id and status in ('todo', 'in_progress')
       and requirement_id in (select id from public.event_requirements where event_id = b.event_id and booking_id = b.id);
  end if;
end $$;

-- Create an event from an accepted booking (supplier side), then its tasks.
create or replace function public.create_event_from_booking(p_booking uuid, p_business uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare b public.bookings; v_id uuid; v_other text;
begin
  perform public.require_member(p_business);
  select * into b from public.bookings where id = p_booking;
  if p_business not in (b.supplier_business_id, b.requester_business_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select id into v_id from public.events where business_id = p_business and source_booking_id = p_booking;
  if v_id is not null then return v_id; end if;
  select name into v_other from public.businesses
   where id = case when p_business = b.supplier_business_id then b.requester_business_id else b.supplier_business_id end;
  insert into public.events (business_id, name, starts_at, ends_at, client_name, status, source_booking_id)
  values (p_business, 'Job ' || b.reference || ' · ' || v_other,
          (b.starts_on + time '08:00') at time zone 'Africa/Lusaka',
          (b.ends_on + time '22:00') at time zone 'Africa/Lusaka', v_other, 'confirmed', b.id)
  returning id into v_id;
  update public.tasks set event_id = v_id where business_id = p_business and booking_id = p_booking and event_id is null;
  perform public.generate_event_tasks(v_id);
  return v_id;
end $$;

create or replace function public.snooze_task(p_task uuid, p_until timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare t public.tasks;
begin
  select * into t from public.tasks where id = p_task;
  perform public.require_member(t.business_id);
  if p_until <= now() then raise exception 'snooze_in_past' using errcode = '22023'; end if;
  update public.reminders set status = 'cancelled' where task_id = p_task and status = 'pending';
  insert into public.reminders (task_id, business_id, remind_at, kind) values (p_task, t.business_id, p_until, 'snoozed');
end $$;

-- Scheduled every minute. Claims due reminders with SKIP LOCKED, so overlapping
-- or retried runs cannot send the same reminder twice; notify() also dedupes.
create or replace function public.process_due_reminders(p_limit int default 500)
returns int language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_count int := 0;
  v_allowed timestamptz;
  v_mode public.delivery_mode;
begin
  for r in
    select rm.id, rm.business_id, rm.kind, t.id as task_id, t.title, t.due_at, t.priority, t.status as task_status,
           p.task_reminders
      from public.reminders rm
      join public.tasks t on t.id = rm.task_id
      left join public.notification_preferences p on p.business_id = rm.business_id
     where rm.status = 'pending' and rm.remind_at <= now()
     order by rm.remind_at
     limit p_limit
     for update of rm skip locked
  loop
    if r.task_status in ('done', 'cancelled') then
      update public.reminders set status = 'cancelled' where id = r.id;
      continue;
    end if;

    v_allowed := public.next_allowed_send(r.business_id);
    if v_allowed > now() and r.priority <> 'critical' then
      update public.reminders set remind_at = v_allowed where id = r.id;
      continue;
    end if;

    v_mode := case when coalesce(r.task_reminders, 'immediate') = 'off' then 'in_app'
                   when r.task_reminders = 'digest' and r.priority in ('low', 'normal') then 'digest'
                   else 'immediate' end;

    perform public.notify(r.business_id, 'task',
      case r.kind when 'deadline' then 'Due soon: ' else 'Reminder: ' end || r.title,
      'Due ' || to_char(r.due_at at time zone 'Africa/Lusaka', 'Dy DD Mon, HH24:MI'),
      'rem:' || r.id, '/work/task/' || r.task_id, jsonb_build_object('task_id', r.task_id),
      v_mode, null, r.priority = 'critical');
    update public.reminders set status = 'sent', sent_at = now() where id = r.id;
    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

-- Workload: per-day load and scheduling conflicts for the calendar and dashboard.
create or replace function public.workload(p_business uuid, p_from date, p_to date)
returns table (day date, events int, tasks_due int, tasks_overdue int, overlapping_events boolean)
language sql stable security definer set search_path = public as $$
  select d::date,
         (select count(*) from public.events e where e.business_id = p_business and e.status <> 'cancelled'
            and d::date between (e.starts_at at time zone 'Africa/Lusaka')::date and (e.ends_at at time zone 'Africa/Lusaka')::date)::int,
         (select count(*) from public.tasks t where t.business_id = p_business and t.status in ('todo', 'in_progress')
            and (t.due_at at time zone 'Africa/Lusaka')::date = d::date)::int,
         (select count(*) from public.tasks t where t.business_id = p_business and t.status in ('todo', 'in_progress')
            and t.due_at < now() and (t.due_at at time zone 'Africa/Lusaka')::date = d::date)::int,
         exists (select 1 from public.events a join public.events b on a.id < b.id
                  where a.business_id = p_business and b.business_id = p_business
                    and a.status <> 'cancelled' and b.status <> 'cancelled'
                    and a.starts_at < b.ends_at and b.starts_at < a.ends_at
                    and d::date between (a.starts_at at time zone 'Africa/Lusaka')::date and (a.ends_at at time zone 'Africa/Lusaka')::date)
  from generate_series(p_from, p_to, interval '1 day') d
  where public.is_member(p_business) and p_to - p_from <= 92;
$$;

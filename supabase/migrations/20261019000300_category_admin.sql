-- Category management: admins choose the icon and position, and hiding a
-- category needs a reason (vendors using it stop seeing it in pickers).
-- The app now loads categories from this table instead of a built-in list.

drop function if exists public.admin_upsert_category(text, text, public.offering_type, boolean, text);

create or replace function public.admin_upsert_category(
  p_id text, p_name text, p_kind public.offering_type, p_active boolean, p_reason text,
  p_icon text default null, p_sort int default null
) returns void language plpgsql security definer set search_path = public as $$
declare
  v_before jsonb;
  v_icon text;
  v_sort int;
begin
  perform public.require_admin('category.manage', p_reason, not p_active);
  if p_id !~ '^[a-z0-9_]{2,40}$' then
    raise exception 'invalid_category_id' using errcode = '22023', hint = 'Use 2-40 lowercase letters, numbers or underscores.';
  end if;
  if char_length(btrim(p_name)) not between 2 and 60 then
    raise exception 'invalid_category_name' using errcode = '22023', hint = 'Name must be 2-60 characters.';
  end if;

  select to_jsonb(c) into v_before from public.categories c where id = p_id;
  v_icon := coalesce(p_icon, v_before ->> 'icon', 'package');
  if v_icon not in ('tent', 'armchair', 'table', 'shirt', 'sparkles', 'flower', 'speaker', 'lightbulb', 'layers',
                    'cooking_pot', 'palette', 'utensils', 'flower_2', 'camera', 'music', 'clipboard_list', 'package',
                    'cake', 'car', 'mic', 'baby', 'gift', 'video', 'scissors', 'paintbrush') then
    raise exception 'invalid_category_icon' using errcode = '22023';
  end if;
  v_sort := coalesce(p_sort, (v_before ->> 'sort')::int, (select coalesce(max(sort), 0) + 10 from public.categories));

  insert into public.categories (id, name, kind, icon, sort, active)
  values (p_id, btrim(p_name), p_kind, v_icon, v_sort, p_active)
  on conflict (id) do update
    set name = excluded.name, kind = excluded.kind, icon = excluded.icon, sort = excluded.sort, active = excluded.active;

  perform public.write_audit(case when v_before is null then 'category.create' else 'category.update' end,
    'categories', p_id, p_reason, v_before,
    jsonb_build_object('name', btrim(p_name), 'kind', p_kind, 'icon', v_icon, 'sort', v_sort, 'active', p_active));
end $$;

revoke execute on function public.admin_upsert_category(text, text, public.offering_type, boolean, text, text, int) from public, anon;
grant execute on function public.admin_upsert_category(text, text, public.offering_type, boolean, text, text, int) to authenticated, service_role;

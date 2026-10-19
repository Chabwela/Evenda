-- Precise business locations.
--
-- 1. Members can read their own business's exact pin. The `location` column
--    stays hidden from the API roles, so other vendors still only ever see
--    public_location. Without this the app could only read back the rounded
--    point and would save it over the exact one when a profile was edited.
-- 2. "Approximate" now really means about 500 m, as the app promises: the
--    public point snaps to the centre of a 0.005° grid cell (~550 m), instead
--    of the previous 0.001° (~110 m), which was close to an exact address.

create or replace function public.my_business_location(p_business uuid)
returns table (lat float8, lng float8, location_precision public.location_precision)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.require_member(p_business);
  return query
  select extensions.st_y(b.location::extensions.geometry),
         extensions.st_x(b.location::extensions.geometry),
         b.location_precision
    from public.businesses b
   where b.id = p_business and b.location is not null;
end $$;

grant execute on function public.my_business_location(uuid) to authenticated;

create or replace function public.derive_public_location()
returns trigger language plpgsql as $$
begin
  if new.location is null then
    new.public_location := null;
  elsif new.location_precision = 'exact' then
    new.public_location := new.location;
  else
    new.public_location := extensions.st_setsrid(extensions.st_makepoint(
      floor(extensions.st_x(new.location::extensions.geometry) / 0.005) * 0.005 + 0.0025,
      floor(extensions.st_y(new.location::extensions.geometry) / 0.005) * 0.005 + 0.0025
    ), 4326)::extensions.geography;
  end if;
  new.updated_at := now();
  return new;
end $$;

-- Recompute existing approximate points with the new grid (the trigger fires
-- on "update of location"; this runs as the migration owner, so the column
-- guard does not apply).
update public.businesses set location = location where location is not null and location_precision = 'approximate';

-- Email sign-up passes the vendor's name as user metadata (full_name).
-- Copy it into the profile so onboarding does not ask for it again.

create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, full_name, phone)
  values (
    new.id,
    left(btrim(coalesce(new.raw_user_meta_data ->> 'full_name', '')), 120),
    case when new.phone is null or new.phone = '' then null
         else '+' || ltrim(new.phone, '+') end
  )
  on conflict (id) do nothing;
  return new;
end $$;

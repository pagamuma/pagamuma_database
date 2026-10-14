-- ═══════════════════════════════════════════════════════════════════════════
-- 0003 — THE CLINIC'S CITY (and country, and postal code)
--
-- dev & prod: "apliquei"
--
-- Decision of 2026-10-08 (decision 0009).
--
-- The join form confirms a clinic code with its name AND its city:
-- "✓ Absolute Care · Quezon City". Two clinics can share a name; the city is
-- what tells a parent they found the right one.
--
-- The manager gives them at sign-up. The country defaults to the Philippines.
-- The postal code suggests the city in the form (a lookup in the browser);
-- the database stores what the manager confirms.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.clinics
  add column country text not null default 'PH' check (country ~ '^[A-Z]{2}$'),
  add column city text check (city is null or char_length(btrim(city)) between 1 and 80),
  add column postal_code text check (postal_code is null or char_length(btrim(postal_code)) between 2 and 12);

-- The creation takes the place now. The old signatures go, so nothing calls
-- them without it.
drop function if exists public.create_clinic(text);
drop function if exists public.clinic_create_for(uuid, text);

create or replace function public.clinic_create_for(
  p_user uuid,
  p_name text,
  p_city text,
  p_country text default 'PH',
  p_postal_code text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_code text;
begin
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 80 then
    raise exception 'clinic:name';
  end if;
  if char_length(btrim(coalesce(p_city, ''))) not between 1 and 80 then
    raise exception 'clinic:city';
  end if;
  lock table public.clinics in share row exclusive mode;
  v_code := public.clinic_code_for(p_name);
  insert into public.clinics (name, slug, plan, access_source, subscription_status, country, city, postal_code)
  values (btrim(p_name), v_code, 'free', 'manual', 'none',
          upper(coalesce(nullif(btrim(p_country), ''), 'PH')),
          btrim(p_city),
          nullif(btrim(coalesce(p_postal_code, '')), ''))
  returning id into v_id;
  insert into public.memberships (clinic_id, user_id, role) values (v_id, p_user, 'manager');
  return v_code;
end;
$$;

create or replace function public.create_clinic(
  p_name text,
  p_city text,
  p_country text default 'PH',
  p_postal_code text default null
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  return public.clinic_create_for(auth.uid(), p_name, p_city, p_country, p_postal_code);
end;
$$;

-- The code lookup returns the name and the place now.
drop function if exists public.clinic_by_code(text);
create or replace function public.clinic_by_code(p_code text)
returns table (name text, city text, country text)
language sql
stable
security definer
set search_path = ''
as $$
  select c.name, c.city, c.country from public.clinics c where c.slug = lower(btrim(p_code));
$$;

-- The sign-up trigger passes the place along.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  m jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
begin
  insert into public.profiles (id, display_name)
  values (new.id, btrim(coalesce(nullif(m ->> 'display_name', ''), split_part(new.email, '@', 1))));

  if m ->> 'intent' = 'create_clinic' then
    perform public.clinic_create_for(
      new.id, m ->> 'clinic_name', m ->> 'clinic_city', m ->> 'clinic_country', m ->> 'clinic_postal_code');
  elsif m ->> 'intent' = 'join' then
    begin
      perform public.join_request_for(new.id, m ->> 'clinic', m ->> 'role');
    exception when others then null;
    end;
  end if;
  return new;
end;
$$;

revoke all on function public.clinic_create_for(uuid, text, text, text, text) from public, anon, authenticated;
revoke all on function public.create_clinic(text, text, text, text) from public, anon;
revoke all on function public.clinic_by_code(text) from public;
grant execute on function public.create_clinic(text, text, text, text) to authenticated;
grant execute on function public.clinic_by_code(text) to anon, authenticated;

-- ═══════════════════════════════════════════════════════════════════════════
-- 0002 — SIGN-UP BY ROLE: clinic codes, join requests, the free plan
--
-- dev & prod = "apliquei"
--
-- Decision of 2026-10-08 (decision 0009, which revises 0002, 0006, 0007).
--
-- 1) NO USERNAMES. Pag-amuma isn't a social network. People are their name;
--    `profiles.username`, `username_available` and `find_user` are gone.
--
-- 2) A MANAGER CREATES THE CLINIC AT SIGN-UP. The clinic gets a CODE
--    (`clinics.slug`) made from its name: `absolute-care`, and if taken
--    `absolute-care-002`, `-003`… (Gmail-style). The code is claimed on the
--    server at creation, so two clinics with the same name never collide.
--
-- 3) GUARDIANS AND STAFF JOIN WITH THE CODE, AS A REQUEST. The code isn't a
--    secret (it comes from the clinic's name and circulates in parents'
--    groups), so it only opens a `join_request`. The manager approves it and
--    confirms the role; the role in the invite link is just a suggestion.
--
-- 4) THE FREE PLAN. A self-made clinic starts on `plan = 'free'`: active,
--    limited to `plan_limits.max_children` children (5). `pro` has no limit.
--    Stripe, later, writes `plan` and the subscription columns; nothing else
--    changes. A `pro` clinic whose subscription ends goes back to `free`.
--
-- The sign-up form passes its intent in the user metadata, and the profile
-- trigger acts on it, so it works with or without email confirmation:
--   { display_name, intent: 'create_clinic', clinic_name }
--   { display_name, intent: 'join', clinic: '<code>', role: 'parent'|'therapist' }
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists unaccent with schema extensions;

-- ─────────────────────────────────────────────────────────────
-- 1) No usernames
-- ─────────────────────────────────────────────────────────────
drop function if exists public.find_user(uuid, text);
drop function if exists public.username_available(text);
drop function if exists public.admin_create_clinic(text, text, text);
alter table public.profiles drop column username;

-- ─────────────────────────────────────────────────────────────
-- 2) Plans
-- ─────────────────────────────────────────────────────────────
create table public.plan_limits (
  plan         text primary key,
  max_children int  -- null = no limit
);
insert into public.plan_limits (plan, max_children) values ('free', 5), ('pro', null);

alter table public.plan_limits enable row level security;
revoke all on public.plan_limits from public, anon, authenticated;
grant select on public.plan_limits to authenticated;
grant all on public.plan_limits to service_role;
create policy plan_limits_read on public.plan_limits for select to authenticated using (true);

alter table public.clinics
  add column plan text not null default 'free' references public.plan_limits(plan);

-- The first clinics were granted by hand as paying ones: they become `pro`.
update public.clinics set plan = 'pro' where access_source = 'manual' and subscription_status = 'active';

-- Free is always open (within its limit). Pro needs an active subscription,
-- or a week of grace on past_due.
create or replace function public.clinic_active(p_clinic uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clinics c
     where c.id = p_clinic
       and (c.plan = 'free'
            or c.subscription_status = 'active'
            or (c.subscription_status = 'past_due'
                and c.current_period_end + interval '7 days' > now()))
  );
$$;

-- ─────────────────────────────────────────────────────────────
-- 3) Clinic codes
-- ─────────────────────────────────────────────────────────────

-- "Absolute Care!" → "absolute-care". Accents dropped, 34 chars max (room
-- for "-002").
create or replace function public.clinic_code_base(p_name text)
returns text
language sql
immutable
set search_path = ''
as $$
  select left(
    trim(both '-' from regexp_replace(
      lower(extensions.unaccent('extensions.unaccent'::regdictionary, coalesce(p_name, ''))),
      '[^a-z0-9]+', '-', 'g')),
    34);
$$;

-- The first free code for a name: the base, then base-002, base-003…
create or replace function public.clinic_code_for(p_name text)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_base text := public.clinic_code_base(p_name);
  v_code text;
  v_n int := 1;
begin
  if char_length(v_base) < 2 then v_base := 'clinic'; end if;
  v_code := v_base;
  while exists (select 1 from public.clinics where slug = v_code) loop
    v_n := v_n + 1;
    v_code := v_base || '-' || lpad(v_n::text, 3, '0');
  end loop;
  return v_code;
end;
$$;

-- What the code would be, for the live preview under "Clinic name".
create or replace function public.clinic_code_preview(p_name text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select public.clinic_code_for(p_name);
$$;

-- The clinic's NAME for an exact code: the "Joining Absolute Care" check on
-- the join form. Exact match only, and only the name.
create or replace function public.clinic_by_code(p_code text)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select name from public.clinics where slug = lower(btrim(p_code));
$$;

-- A clinic for a person, with them as its manager. Called by the sign-up
-- trigger and by `create_clinic`.
create or replace function public.clinic_create_for(p_user uuid, p_name text)
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
  -- One clinic created at a time: the lock makes the code claim race-free.
  lock table public.clinics in share row exclusive mode;
  v_code := public.clinic_code_for(p_name);
  insert into public.clinics (name, slug, plan, access_source, subscription_status)
  values (btrim(p_name), v_code, 'free', 'manual', 'none')
  returning id into v_id;
  insert into public.memberships (clinic_id, user_id, role) values (v_id, p_user, 'manager');
  return v_code;
end;
$$;

-- For someone already signed in who sets up (another) clinic.
create or replace function public.create_clinic(p_name text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  return public.clinic_create_for(auth.uid(), p_name);
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- 4) Join requests
-- ─────────────────────────────────────────────────────────────
create table public.join_requests (
  id         uuid primary key default gen_random_uuid(),
  clinic_id  uuid not null references public.clinics(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('parent', 'therapist')),
  status     text not null default 'pending' check (status in ('pending', 'approved', 'declined')),
  created_at timestamptz not null default now(),
  decided_at timestamptz,
  decided_by uuid references auth.users(id) on delete set null
);
create unique index join_requests_one_pending on public.join_requests (clinic_id, user_id) where status = 'pending';
create index idx_join_requests_user on public.join_requests (user_id);

alter table public.join_requests enable row level security;
revoke all on public.join_requests from public, anon, authenticated;
grant select on public.join_requests to authenticated;
grant all on public.join_requests to service_role;
create policy join_requests_read on public.join_requests for select to authenticated
  using (user_id = auth.uid() or public.has_role(clinic_id, array['manager']));

-- A request from a person to a clinic, by code. Quiet when it already exists
-- or the person is already a member: asking twice is not an error.
create or replace function public.join_request_for(p_user uuid, p_code text, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_clinic uuid;
begin
  select id into v_clinic from public.clinics where slug = lower(btrim(p_code));
  if v_clinic is null then raise exception 'clinic:code'; end if;
  if p_role not in ('parent', 'therapist') then p_role := 'parent'; end if;
  if exists (select 1 from public.memberships where clinic_id = v_clinic and user_id = p_user) then return; end if;
  insert into public.join_requests (clinic_id, user_id, role)
  values (v_clinic, p_user, p_role)
  on conflict do nothing;
end;
$$;

create or replace function public.request_join(p_code text, p_role text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not signed in'; end if;
  perform public.join_request_for(auth.uid(), p_code, p_role);
end;
$$;

-- The manager decides, and confirms (or changes) the role.
create or replace function public.decide_join(p_request uuid, p_approve boolean, p_role text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  r public.join_requests;
begin
  select * into r from public.join_requests where id = p_request and status = 'pending' for update;
  if r.id is null then raise exception 'join:gone'; end if;
  if not public.has_role(r.clinic_id, array['manager']) then raise exception 'not a manager'; end if;
  if p_approve then
    insert into public.memberships (clinic_id, user_id, role)
    values (r.clinic_id, r.user_id, coalesce(p_role, r.role))
    on conflict do nothing;
  end if;
  update public.join_requests
     set status = case when p_approve then 'approved' else 'declined' end,
         role = coalesce(p_role, r.role),
         decided_at = now(),
         decided_by = auth.uid()
   where id = r.id;
end;
$$;

-- My own requests, with the clinic's name: someone still waiting can't read
-- `clinics` (members only), so the name comes through here.
create or replace function public.my_join_requests()
returns table (id uuid, clinic_name text, clinic_code text, role text, status text, created_at timestamptz)
language sql
stable
security definer
set search_path = ''
as $$
  select jr.id, c.name, c.slug, jr.role, jr.status, jr.created_at
    from public.join_requests jr
    join public.clinics c on c.id = jr.clinic_id
   where jr.user_id = auth.uid()
   order by jr.created_at desc;
$$;

-- A manager sees the names of the people asking to join their clinic.
create or replace function public.can_see_profile(p_profile uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select p_profile = auth.uid()
    or exists (
      select 1 from public.memberships mine
        join public.memberships theirs on theirs.clinic_id = mine.clinic_id
       where mine.user_id = auth.uid()
         and theirs.user_id = p_profile
         and public.clinic_active(mine.clinic_id)
         and (mine.role in ('manager', 'therapist') or theirs.role in ('manager', 'therapist'))
    )
    or exists (
      select 1 from public.client_guardians me
        join public.client_guardians other on other.client_id = me.client_id
       where me.user_id = auth.uid() and other.user_id = p_profile
    )
    or exists (
      select 1 from public.join_requests jr
       where jr.user_id = p_profile and jr.status = 'pending'
         and public.has_role(jr.clinic_id, array['manager'])
    );
$$;

-- ─────────────────────────────────────────────────────────────
-- 5) The sign-up trigger: the profile, then the intent
-- ─────────────────────────────────────────────────────────────
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
    perform public.clinic_create_for(new.id, m ->> 'clinic_name');
  elsif m ->> 'intent' = 'join' then
    -- A wrong code must not fail the sign-up: the person can ask again from
    -- the app. The form checks the code before submitting anyway.
    begin
      perform public.join_request_for(new.id, m ->> 'clinic', m ->> 'role');
    exception when others then null;
    end;
  end if;
  return new;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- 6) The free plan's limit, on creating a child
-- ─────────────────────────────────────────────────────────────
create or replace function public.create_client(
  p_clinic uuid,
  p_first_name text,
  p_last_name text,
  p_birthday date default null,
  p_place_of_birth text default null,
  p_address text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_max int;
begin
  if not public.has_role(p_clinic, array['manager']) then raise exception 'not a manager'; end if;
  select l.max_children into v_max
    from public.clinics c join public.plan_limits l on l.plan = c.plan
   where c.id = p_clinic;
  if v_max is not null and (
    select count(*) from public.clients where clinic_id = p_clinic and archived_at is null
  ) >= v_max then
    raise exception 'plan:limit';
  end if;
  insert into public.clients (clinic_id, first_name, last_name, birthday, place_of_birth, address)
  values (p_clinic, btrim(p_first_name), btrim(p_last_name), p_birthday,
          nullif(btrim(p_place_of_birth), ''), nullif(btrim(p_address), ''))
  returning id into v_id;
  insert into public.threads (clinic_id, client_id) values (p_clinic, v_id);
  return v_id;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- 7) Ours (SQL editor): set a clinic's plan by hand, until Stripe
-- ─────────────────────────────────────────────────────────────
create or replace function public.admin_set_plan(p_code text, p_plan text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.clinics
     set plan = p_plan,
         access_source = 'manual',
         subscription_status = case when p_plan = 'pro' then 'active' else 'none' end
   where slug = lower(btrim(p_code));
  if not found then raise exception 'no clinic %', p_code; end if;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- 8) Grants
-- ─────────────────────────────────────────────────────────────
revoke all on function public.clinic_code_for(text) from public, anon, authenticated;
revoke all on function public.clinic_create_for(uuid, text) from public, anon, authenticated;
revoke all on function public.join_request_for(uuid, text, text) from public, anon, authenticated;
revoke all on function public.admin_set_plan(text, text) from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;

revoke all on function public.clinic_code_preview(text) from public;
revoke all on function public.clinic_by_code(text) from public;
revoke all on function public.create_clinic(text) from public, anon;
revoke all on function public.request_join(text, text) from public, anon;
revoke all on function public.decide_join(uuid, boolean, text) from public, anon;
revoke all on function public.my_join_requests() from public, anon;

grant execute on function public.clinic_code_base(text) to anon, authenticated;
grant execute on function public.clinic_code_preview(text) to anon, authenticated;
grant execute on function public.clinic_by_code(text) to anon, authenticated;
grant execute on function public.create_clinic(text) to authenticated;
grant execute on function public.request_join(text, text) to authenticated;
grant execute on function public.decide_join(uuid, boolean, text) to authenticated;
grant execute on function public.my_join_requests() to authenticated;
grant execute on function public.can_see_profile(uuid) to authenticated;
grant execute on function public.clinic_active(uuid) to authenticated;

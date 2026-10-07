-- ═══════════════════════════════════════════════════════════════════════════
-- 0001 — THE BASE: people, clinics, children, schedule, daily notes, chat
--
-- Privacy frame: the Philippine Data Privacy Act of 2012 (RA 10173). Daily
-- notes and demographics of minors are SENSITIVE PERSONAL INFORMATION, so:
--   · every table has RLS, and every policy is scoped to a clinic the user
--     belongs to, and inside it to the children the user is linked to;
--   · parents never see other families (not their names, not their threads);
--   · the user directory cannot be listed: a manager finds a person only by
--     the exact @username the person gave them;
--   · opening a child's record is logged (`access_log`).
--
-- Billing is ready for Stripe and not wired: the clinic carries the
-- subscription columns, and `clinic_active` is what every policy checks. The
-- first clinic is granted by hand (`access_source = 'manual'`).
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- 1) People
-- ─────────────────────────────────────────────────────────────
create table public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  username     text not null unique check (username ~ '^[a-z0-9._]{3,30}$'),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 80),
  created_at   timestamptz not null default now()
);

-- The profile is born with the account. Username and name come from the
-- sign-up metadata; an invalid or taken username fails the sign-up itself.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, username, display_name)
  values (
    new.id,
    lower(btrim(new.raw_user_meta_data ->> 'username')),
    btrim(coalesce(new.raw_user_meta_data ->> 'display_name', new.raw_user_meta_data ->> 'username'))
  );
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Sign-up asks before submitting. It says only "taken or not".
create or replace function public.username_available(p_username text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select not exists (select 1 from public.profiles where username = lower(btrim(p_username)));
$$;

-- ─────────────────────────────────────────────────────────────
-- 2) Clinics and memberships
-- ─────────────────────────────────────────────────────────────
create table public.clinics (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null,
  slug                   text not null unique check (slug ~ '^[a-z0-9-]{2,40}$'),
  timezone               text not null default 'Asia/Manila',
  -- Billing, ready for Stripe. Today we write these by hand; later a webhook.
  access_source          text not null default 'manual' check (access_source in ('manual', 'stripe')),
  subscription_status    text not null default 'none'
                         check (subscription_status in ('active', 'past_due', 'canceled', 'none')),
  stripe_customer_id     text unique,
  stripe_subscription_id text unique,
  current_period_end     timestamptz,
  created_at             timestamptz not null default now()
);

create table public.memberships (
  clinic_id  uuid not null references public.clinics(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('manager', 'therapist', 'parent')),
  created_at timestamptz not null default now(),
  primary key (clinic_id, user_id, role)
);
create index idx_memberships_user on public.memberships (user_id);

-- ─────────────────────────────────────────────────────────────
-- 3) Children and their people
-- ─────────────────────────────────────────────────────────────
create table public.clients (
  id             uuid primary key default gen_random_uuid(),
  clinic_id      uuid not null references public.clinics(id) on delete cascade,
  first_name     text not null,
  last_name      text not null,
  -- No age column: age is derived from the birthday.
  birthday       date,
  place_of_birth text,
  address        text,
  notes          text,
  created_at     timestamptz not null default now(),
  archived_at    timestamptz
);
create index idx_clients_clinic on public.clients (clinic_id);

create table public.client_guardians (
  client_id      uuid not null references public.clients(id) on delete cascade,
  user_id        uuid not null references auth.users(id) on delete cascade,
  relationship   text,
  contact_number text,
  primary key (client_id, user_id)
);
create index idx_client_guardians_user on public.client_guardians (user_id);

create table public.client_therapists (
  client_id uuid not null references public.clients(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  primary key (client_id, user_id)
);
create index idx_client_therapists_user on public.client_therapists (user_id);

-- ─────────────────────────────────────────────────────────────
-- 4) Schedule and daily notes
-- ─────────────────────────────────────────────────────────────
create table public.sessions (
  id           uuid primary key default gen_random_uuid(),
  clinic_id    uuid not null references public.clinics(id) on delete cascade,
  client_id    uuid not null references public.clients(id) on delete cascade,
  therapist_id uuid not null references auth.users(id),
  starts_at    timestamptz not null,
  ends_at      timestamptz not null,
  status       text not null default 'scheduled'
               check (status in ('scheduled', 'done', 'canceled', 'no_show')),
  created_by   uuid references auth.users(id) default auth.uid(),
  created_at   timestamptz not null default now(),
  check (ends_at > starts_at)
);
create index idx_sessions_clinic_time on public.sessions (clinic_id, starts_at);
create index idx_sessions_client on public.sessions (client_id);

-- ⚠️ THE ID COMES FROM THE PHONE. A note written offline waits in the outbox
-- with its uuid; a retried sync is an upsert on that id, never a duplicate.
create table public.daily_notes (
  id                  uuid primary key,
  clinic_id           uuid not null references public.clinics(id) on delete cascade,
  client_id           uuid not null references public.clients(id) on delete cascade,
  session_id          uuid references public.sessions(id) on delete set null,
  therapist_id        uuid not null references auth.users(id) default auth.uid(),
  body                text not null check (char_length(btrim(body)) between 1 and 10000),
  shared_with_parents boolean not null default true,
  written_at          timestamptz not null default now(), -- when it was written (maybe offline)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);
create index idx_daily_notes_client on public.daily_notes (client_id, written_at desc);

-- ─────────────────────────────────────────────────────────────
-- 5) Chat: one thread per child
-- ─────────────────────────────────────────────────────────────
create table public.threads (
  id        uuid primary key default gen_random_uuid(),
  clinic_id uuid not null references public.clinics(id) on delete cascade,
  client_id uuid not null unique references public.clients(id) on delete cascade
);

create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  thread_id  uuid not null references public.threads(id) on delete cascade,
  sender_id  uuid not null references auth.users(id) default auth.uid(),
  body       text not null check (char_length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now()
);
create index idx_messages_thread on public.messages (thread_id, created_at desc);

create table public.thread_reads (
  thread_id    uuid not null references public.threads(id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade default auth.uid(),
  last_read_at timestamptz not null default now(),
  primary key (thread_id, user_id)
);

-- ─────────────────────────────────────────────────────────────
-- 6) Access log (RA 10173 accountability)
-- ─────────────────────────────────────────────────────────────
create table public.access_log (
  id        bigint generated always as identity primary key,
  clinic_id uuid not null references public.clinics(id) on delete cascade,
  client_id uuid references public.clients(id) on delete set null,
  user_id   uuid references auth.users(id) on delete set null,
  action    text not null,
  at        timestamptz not null default now()
);
create index idx_access_log_clinic on public.access_log (clinic_id, at desc);

-- ─────────────────────────────────────────────────────────────
-- 7) The rules, as functions (security definer: they read past RLS)
-- ─────────────────────────────────────────────────────────────

-- Is the clinic paying (or manually granted)? A week of grace on past_due.
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
       and (c.subscription_status = 'active'
            or (c.subscription_status = 'past_due'
                and c.current_period_end + interval '7 days' > now()))
  );
$$;

create or replace function public.has_role(p_clinic uuid, p_roles text[])
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.clinic_active(p_clinic) and exists (
    select 1 from public.memberships m
     where m.clinic_id = p_clinic and m.user_id = auth.uid() and m.role = any (p_roles)
  );
$$;

create or replace function public.is_therapist_of(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.client_therapists t
      join public.clients c on c.id = t.client_id
     where t.client_id = p_client and t.user_id = auth.uid()
       and public.has_role(c.clinic_id, array['therapist'])
  );
$$;

create or replace function public.is_guardian_of(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.client_guardians g
      join public.clients c on c.id = g.client_id
     where g.client_id = p_client and g.user_id = auth.uid()
       and public.has_role(c.clinic_id, array['parent'])
  );
$$;

create or replace function public.is_manager_of_client(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clients c
     where c.id = p_client and public.has_role(c.clinic_id, array['manager'])
  );
$$;

-- Manager of the clinic, assigned therapist, or guardian.
create or replace function public.can_see_client(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_manager_of_client(p_client)
      or public.is_therapist_of(p_client)
      or public.is_guardian_of(p_client);
$$;

-- Who may write a child's record, sessions and notes: manager or therapist.
create or replace function public.can_care_for(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_manager_of_client(p_client) or public.is_therapist_of(p_client);
$$;

-- ⚠️ WHO SEES WHOSE NAME. Staff (manager, therapist) see the clinic's members.
-- A parent sees the clinic's staff and the other guardians of their own
-- children, and NEVER the other families.
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
    );
$$;

-- The clinic is always the child's: sessions and notes copy it from the child,
-- so a crafted insert cannot point a child at another clinic.
create or replace function public.clinic_from_client()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select clinic_id into new.clinic_id from public.clients where id = new.client_id;
  if new.clinic_id is null then raise exception 'client not found'; end if;
  return new;
end;
$$;

create trigger trg_sessions_clinic before insert or update of client_id on public.sessions
  for each row execute function public.clinic_from_client();
create trigger trg_daily_notes_clinic before insert or update of client_id on public.daily_notes
  for each row execute function public.clinic_from_client();

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_daily_notes_touch before update on public.daily_notes
  for each row execute function public.touch_updated_at();

-- ─────────────────────────────────────────────────────────────
-- 8) RLS and grants
-- ─────────────────────────────────────────────────────────────
alter table public.profiles          enable row level security;
alter table public.clinics           enable row level security;
alter table public.memberships       enable row level security;
alter table public.clients           enable row level security;
alter table public.client_guardians  enable row level security;
alter table public.client_therapists enable row level security;
alter table public.sessions          enable row level security;
alter table public.daily_notes       enable row level security;
alter table public.threads           enable row level security;
alter table public.messages          enable row level security;
alter table public.thread_reads      enable row level security;
alter table public.access_log        enable row level security;

revoke all on public.profiles, public.clinics, public.memberships, public.clients,
  public.client_guardians, public.client_therapists, public.sessions, public.daily_notes,
  public.threads, public.messages, public.thread_reads, public.access_log
  from public, anon, authenticated;

grant all on public.profiles, public.clinics, public.memberships, public.clients,
  public.client_guardians, public.client_therapists, public.sessions, public.daily_notes,
  public.threads, public.messages, public.thread_reads, public.access_log
  to service_role;

-- profiles: read by the rule above; each one edits only their display name.
grant select on public.profiles to authenticated;
grant update (display_name) on public.profiles to authenticated;
create policy profiles_read on public.profiles for select to authenticated
  using (public.can_see_profile(id));
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- clinics: members read their clinic even when it lapsed (the app says why
-- it's paused). Nobody writes from the app: billing columns are ours.
grant select on public.clinics to authenticated;
create policy clinics_read on public.clinics for select to authenticated
  using (exists (select 1 from public.memberships m where m.clinic_id = clinics.id and m.user_id = auth.uid()));

-- memberships: my own rows, and all of them for the clinic's managers.
grant select, insert, delete on public.memberships to authenticated;
create policy memberships_read on public.memberships for select to authenticated
  using (user_id = auth.uid() or public.has_role(clinic_id, array['manager']));
create policy memberships_insert on public.memberships for insert to authenticated
  with check (public.has_role(clinic_id, array['manager']));
create policy memberships_delete on public.memberships for delete to authenticated
  using (public.has_role(clinic_id, array['manager']) and user_id <> auth.uid());

-- clients: created by `create_client` (it also opens the thread); edited by
-- manager or therapist; never deleted from the app, only archived.
grant select on public.clients to authenticated;
grant update (first_name, last_name, birthday, place_of_birth, address, notes, archived_at)
  on public.clients to authenticated;
create policy clients_read on public.clients for select to authenticated
  using (public.can_see_client(id));
create policy clients_update on public.clients for update to authenticated
  using (public.can_care_for(id)) with check (public.can_care_for(id));

-- guardians and therapists of a child: the manager links them, and only
-- people who hold that role in the clinic can be linked.
grant select, insert, update, delete on public.client_guardians to authenticated;
create policy guardians_read on public.client_guardians for select to authenticated
  using (public.can_see_client(client_id));
create policy guardians_write on public.client_guardians for insert to authenticated
  with check (
    public.is_manager_of_client(client_id)
    and exists (select 1 from public.memberships m join public.clients c on c.clinic_id = m.clinic_id
                 where c.id = client_id and m.user_id = client_guardians.user_id and m.role = 'parent')
  );
create policy guardians_update on public.client_guardians for update to authenticated
  using (public.is_manager_of_client(client_id) or user_id = auth.uid())
  with check (public.is_manager_of_client(client_id) or user_id = auth.uid());
create policy guardians_delete on public.client_guardians for delete to authenticated
  using (public.is_manager_of_client(client_id));

grant select, insert, delete on public.client_therapists to authenticated;
create policy therapists_read on public.client_therapists for select to authenticated
  using (public.can_see_client(client_id));
create policy therapists_write on public.client_therapists for insert to authenticated
  with check (
    public.is_manager_of_client(client_id)
    and exists (select 1 from public.memberships m join public.clients c on c.clinic_id = m.clinic_id
                 where c.id = client_id and m.user_id = client_therapists.user_id and m.role = 'therapist')
  );
create policy therapists_delete on public.client_therapists for delete to authenticated
  using (public.is_manager_of_client(client_id));

-- sessions: everyone linked to the child reads; manager or therapist writes.
grant select, insert, update, delete on public.sessions to authenticated;
create policy sessions_read on public.sessions for select to authenticated
  using (public.can_see_client(client_id));
create policy sessions_write on public.sessions for insert to authenticated
  with check (public.can_care_for(client_id));
create policy sessions_update on public.sessions for update to authenticated
  using (public.can_care_for(client_id)) with check (public.can_care_for(client_id));
create policy sessions_delete on public.sessions for delete to authenticated
  using (public.can_care_for(client_id));

-- daily notes: staff read all of the child's notes; parents only the shared
-- ones. The author edits their own; managers can edit any.
grant select, insert, update on public.daily_notes to authenticated;
create policy notes_read on public.daily_notes for select to authenticated
  using (public.can_care_for(client_id)
         or (shared_with_parents and public.is_guardian_of(client_id)));
create policy notes_insert on public.daily_notes for insert to authenticated
  with check (therapist_id = auth.uid() and public.can_care_for(client_id));
create policy notes_update on public.daily_notes for update to authenticated
  using ((therapist_id = auth.uid() and public.can_care_for(client_id)) or public.is_manager_of_client(client_id))
  with check (public.can_care_for(client_id));

-- threads and messages: everyone linked to the child.
grant select on public.threads to authenticated;
create policy threads_read on public.threads for select to authenticated
  using (public.can_see_client(client_id));

grant select, insert on public.messages to authenticated;
create policy messages_read on public.messages for select to authenticated
  using (exists (select 1 from public.threads t where t.id = thread_id and public.can_see_client(t.client_id)));
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = auth.uid()
              and exists (select 1 from public.threads t where t.id = thread_id and public.can_see_client(t.client_id)));

grant select, insert, update on public.thread_reads to authenticated;
create policy reads_own on public.thread_reads for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- access log: written by `log_client_view`; read by the clinic's managers.
grant select on public.access_log to authenticated;
create policy access_log_read on public.access_log for select to authenticated
  using (public.has_role(clinic_id, array['manager']));

-- Chat arrives live.
alter publication supabase_realtime add table public.messages;

-- ─────────────────────────────────────────────────────────────
-- 9) Actions
-- ─────────────────────────────────────────────────────────────

-- ⚠️ EXACT MATCH ONLY, AND ONLY FOR MANAGERS. The person gives the manager
-- their @username; there is no way to browse or guess a list of users.
create or replace function public.find_user(p_clinic uuid, p_username text)
returns table (id uuid, username text, display_name text)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not public.has_role(p_clinic, array['manager']) then raise exception 'not a manager'; end if;
  return query
    select p.id, p.username, p.display_name from public.profiles p
     where p.username = lower(btrim(p_username, '@ '));
end;
$$;

-- A child and their thread, together.
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
begin
  if not public.has_role(p_clinic, array['manager']) then raise exception 'not a manager'; end if;
  insert into public.clients (clinic_id, first_name, last_name, birthday, place_of_birth, address)
  values (p_clinic, btrim(p_first_name), btrim(p_last_name), p_birthday,
          nullif(btrim(p_place_of_birth), ''), nullif(btrim(p_address), ''))
  returning id into v_id;
  insert into public.threads (clinic_id, client_id) values (p_clinic, v_id);
  return v_id;
end;
$$;

-- Opening a child's record leaves a trace.
create or replace function public.log_client_view(p_client uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.can_see_client(p_client) then return; end if;
  insert into public.access_log (clinic_id, client_id, user_id, action)
  select c.clinic_id, c.id, auth.uid(), 'view_client' from public.clients c where c.id = p_client;
end;
$$;

-- The message list: each thread I can see, with its last message and
-- whether I have read it. Runs as the caller, so RLS does the filtering.
create or replace function public.my_threads(p_clinic uuid)
returns table (
  thread_id uuid,
  client_id uuid,
  child_name text,
  last_body text,
  last_at timestamptz,
  unread boolean
)
language sql
stable
set search_path = ''
as $$
  select t.id, c.id, c.first_name || ' ' || c.last_name,
         m.body, m.created_at,
         m.created_at is not null and m.sender_id <> auth.uid()
           and m.created_at > coalesce(r.last_read_at, '-infinity')
    from public.threads t
    join public.clients c on c.id = t.client_id
    left join lateral (
      select body, created_at, sender_id from public.messages
       where thread_id = t.id order by created_at desc limit 1
    ) m on true
    left join public.thread_reads r on r.thread_id = t.id and r.user_id = auth.uid()
   where t.clinic_id = p_clinic and c.archived_at is null
   order by m.created_at desc nulls last;
$$;

-- OURS, run in the SQL editor: a clinic and its first manager, granted by
-- hand (the first clinic) until Stripe is wired.
create or replace function public.admin_create_clinic(p_name text, p_slug text, p_manager_username text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_clinic uuid;
  v_manager uuid;
begin
  select id into v_manager from public.profiles where username = lower(btrim(p_manager_username, '@ '));
  if v_manager is null then raise exception 'no user @%', p_manager_username; end if;
  insert into public.clinics (name, slug, access_source, subscription_status)
  values (p_name, p_slug, 'manual', 'active')
  returning id into v_clinic;
  insert into public.memberships (clinic_id, user_id, role) values (v_clinic, v_manager, 'manager');
  return v_clinic;
end;
$$;

revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.admin_create_clinic(text, text, text) from public, anon, authenticated;
revoke all on function public.find_user(uuid, text) from public, anon;
revoke all on function public.create_client(uuid, text, text, date, text, text) from public, anon;
revoke all on function public.log_client_view(uuid) from public, anon;
revoke all on function public.my_threads(uuid) from public, anon;
grant execute on function public.username_available(text) to anon, authenticated;
grant execute on function public.find_user(uuid, text) to authenticated;
grant execute on function public.create_client(uuid, text, text, date, text, text) to authenticated;
grant execute on function public.log_client_view(uuid) to authenticated;
grant execute on function public.my_threads(uuid) to authenticated;

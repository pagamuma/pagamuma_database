-- ═══════════════════════════════════════════════════════════════════════════
-- 0006 — REPEATING APPOINTMENTS, CONFIRMED BY THE FAMILY; COMMENTS ON DAILY
--         NOTES; PRIVATE CHATS; HOW TO REACH A PERSON OUTSIDE PAG-AMUMA
--
-- dev & prod: "apliquei"
--
-- Decision 0011 (2026-10-15).
--
-- 1) SERIES. A therapist books one or more weekdays at a time, weekly, for 6
--    months. Each occurrence is its own row (moved or canceled alone); the
--    ones booked together share `series_id`, so "cancel this and the
--    following" is one update. The app writes the rows; nothing here expands
--    a rule.
--
-- 2) CONFIRMATION. Any guardian of the child confirms an appointment
--    (`confirm_session`). Guardians have no UPDATE on sessions, so it's a
--    function that touches only the two confirmation columns. Moving the
--    appointment clears the confirmation: they confirmed another time.
--
-- 3) COMMENTS ON DAILY NOTES. The child's guardians comment on the notes
--    shared with them; the staff read and answer. A family never sees another
--    family's child, and never a staff-only note (same rules as the notes).
--
-- 4) PRIVATE CHATS. A thread is now a child's group chat (`kind = 'child'`,
--    as before: the whole clinic team and that child's guardians) or a
--    private chat between ONE staff member and ONE parent (`kind = 'direct'`).
--    Never parent ↔ parent. Only the two people in it see a private chat,
--    managers included.
--
-- 5) CONTACT CHANNELS on the profile: phone (SMS and calls), WhatsApp,
--    Viber, Messenger. Optional, each one. Pag-amuma sends no notifications,
--    so urgent news (a cancellation) must also go where the person will see
--    it: the app points there.
-- ═══════════════════════════════════════════════════════════════════════════

-- ─────────────────────────────────────────────────────────────
-- 1, 2) Sessions: series and confirmation
-- ─────────────────────────────────────────────────────────────
alter table public.sessions
  add column series_id    uuid,
  add column confirmed_by uuid references auth.users(id) on delete set null,
  add column confirmed_at timestamptz;
create index idx_sessions_series on public.sessions (series_id) where series_id is not null;

create or replace function public.confirm_session(p_session uuid, p_confirm boolean)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid;
begin
  select client_id into v_client from public.sessions where id = p_session and status = 'scheduled';
  if v_client is null or not public.is_guardian_of(v_client) then
    raise exception 'session:not_yours';
  end if;
  update public.sessions
     set confirmed_by = case when p_confirm then auth.uid() end,
         confirmed_at = case when p_confirm then now() end
   where id = p_session;
end;
$$;

-- A new time is a new question: the family confirmed the old one.
create or replace function public.session_moved()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.starts_at <> old.starts_at or new.ends_at <> old.ends_at then
    new.confirmed_by := null;
    new.confirmed_at := null;
  end if;
  return new;
end;
$$;

create trigger trg_sessions_moved before update of starts_at, ends_at on public.sessions
  for each row execute function public.session_moved();

-- ─────────────────────────────────────────────────────────────
-- 3) Comments on daily notes
-- ─────────────────────────────────────────────────────────────
create table public.note_comments (
  id          uuid primary key default gen_random_uuid(),
  note_id     uuid not null references public.daily_notes(id) on delete cascade,
  -- Copied from the note by the trigger below, whatever the insert says.
  client_id   uuid not null references public.clients(id) on delete cascade,
  clinic_id   uuid not null references public.clinics(id) on delete cascade,
  author_id   uuid not null references auth.users(id) default auth.uid(),
  from_clinic boolean not null default false,
  body        text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at  timestamptz not null default now()
);
create index idx_note_comments_note on public.note_comments (note_id, created_at);

create or replace function public.note_comment_fill()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select n.client_id, n.clinic_id into new.client_id, new.clinic_id
    from public.daily_notes n where n.id = new.note_id;
  if new.client_id is null then raise exception 'note not found'; end if;
  select exists (
    select 1 from public.memberships m
     where m.clinic_id = new.clinic_id and m.user_id = new.author_id
       and m.role in ('manager', 'therapist')
  ) into new.from_clinic;
  return new;
end;
$$;

create trigger trg_note_comments_fill before insert on public.note_comments
  for each row execute function public.note_comment_fill();

-- Who may read (and write on) a note's comments: the staff, or a guardian of
-- the child when the note is shared with the family.
create or replace function public.can_comment_note(p_note uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.daily_notes n
     where n.id = p_note
       and (public.can_care_for(n.client_id)
            or (n.shared_with_parents and public.is_guardian_of(n.client_id)))
  );
$$;

alter table public.note_comments enable row level security;
revoke all on public.note_comments from public, anon, authenticated;
grant all on public.note_comments to service_role;
grant select, insert, delete on public.note_comments to authenticated;

create policy note_comments_read on public.note_comments for select to authenticated
  using (public.can_comment_note(note_id));
create policy note_comments_insert on public.note_comments for insert to authenticated
  with check (author_id = auth.uid() and public.can_comment_note(note_id));
create policy note_comments_delete on public.note_comments for delete to authenticated
  using (author_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- 4) Private chats
-- ─────────────────────────────────────────────────────────────
alter table public.threads alter column client_id drop not null;
alter table public.threads
  add column kind      text not null default 'child' check (kind in ('child', 'direct')),
  add column staff_id  uuid references auth.users(id) on delete cascade,
  add column parent_id uuid references auth.users(id) on delete cascade,
  add constraint threads_kind_shape check (
    (kind = 'child' and client_id is not null and staff_id is null and parent_id is null)
    or (kind = 'direct' and client_id is null and staff_id is not null and parent_id is not null
        and staff_id <> parent_id)
  );
create unique index threads_direct_pair on public.threads (clinic_id, staff_id, parent_id)
  where kind = 'direct';

-- Who sees a thread: a child's chat, everyone linked to the child (as
-- before); a private chat, ONLY its two people, while they belong to the
-- clinic.
create or replace function public.can_see_thread(p_thread uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.threads t
     where t.id = p_thread
       and ((t.kind = 'child' and public.can_see_client(t.client_id))
            or (t.kind = 'direct' and auth.uid() in (t.staff_id, t.parent_id)
                and public.has_role(t.clinic_id, array['manager', 'therapist', 'parent'])))
  );
$$;

drop policy threads_read on public.threads;
create policy threads_read on public.threads for select to authenticated
  using (public.can_see_thread(id));

drop policy messages_read on public.messages;
drop policy messages_insert on public.messages;
create policy messages_read on public.messages for select to authenticated
  using (public.can_see_thread(thread_id));
create policy messages_insert on public.messages for insert to authenticated
  with check (sender_id = auth.uid() and public.can_see_thread(thread_id));

-- Opens (or finds) the private chat between me and another person of the
-- clinic: one of us staff, the other a parent. Anything else is refused.
create or replace function public.open_direct(p_clinic uuid, p_other uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me_staff     boolean := public.has_role(p_clinic, array['manager', 'therapist']);
  v_me_parent    boolean := public.has_role(p_clinic, array['parent']);
  v_other_staff  boolean;
  v_other_parent boolean;
  v_staff        uuid;
  v_parent       uuid;
  v_id           uuid;
begin
  select coalesce(bool_or(role in ('manager', 'therapist')), false), coalesce(bool_or(role = 'parent'), false)
    into v_other_staff, v_other_parent
    from public.memberships where clinic_id = p_clinic and user_id = p_other;

  if p_other <> auth.uid() and v_me_staff and v_other_parent and not v_other_staff then
    v_staff := auth.uid(); v_parent := p_other;
  elsif p_other <> auth.uid() and v_me_parent and not v_me_staff and v_other_staff then
    v_staff := p_other; v_parent := auth.uid();
  else
    raise exception 'dm:not_allowed';
  end if;

  insert into public.threads (clinic_id, kind, staff_id, parent_id)
  values (p_clinic, 'direct', v_staff, v_parent)
  on conflict (clinic_id, staff_id, parent_id) where kind = 'direct' do nothing;

  select id into v_id from public.threads
   where clinic_id = p_clinic and kind = 'direct' and staff_id = v_staff and parent_id = v_parent;
  return v_id;
end;
$$;

-- The message list, with private chats: the title is the child's name or
-- the other person's. Runs as the caller, so RLS does the filtering.
drop function public.my_threads(uuid);
create function public.my_threads(p_clinic uuid)
returns table (
  thread_id uuid,
  kind text,
  client_id uuid,
  other_id uuid,
  title text,
  last_body text,
  last_at timestamptz,
  unread boolean
)
language sql
stable
set search_path = ''
as $$
  select t.id, t.kind, t.client_id, o.other_id,
         case when t.kind = 'child' then c.first_name || ' ' || c.last_name else p.display_name end,
         m.body, m.created_at,
         m.created_at is not null and m.sender_id <> auth.uid()
           and m.created_at > coalesce(r.last_read_at, '-infinity')
    from public.threads t
    cross join lateral (
      select case when t.kind = 'direct'
                  then case when t.staff_id = auth.uid() then t.parent_id else t.staff_id end
             end as other_id
    ) o
    left join public.clients c on c.id = t.client_id
    left join public.profiles p on p.id = o.other_id
    left join lateral (
      select body, created_at, sender_id from public.messages
       where thread_id = t.id order by created_at desc limit 1
    ) m on true
    left join public.thread_reads r on r.thread_id = t.id and r.user_id = auth.uid()
   where t.clinic_id = p_clinic and (t.kind = 'direct' or c.archived_at is null)
   order by m.created_at desc nulls last;
$$;

-- ─────────────────────────────────────────────────────────────
-- 5) Contact channels
-- ─────────────────────────────────────────────────────────────
-- Numbers as people type them (+63 917 123 4567); the app builds the links.
alter table public.profiles
  add column phone     text check (phone ~ '^\+?[0-9 ()-]{7,20}$'),
  add column whatsapp  text check (whatsapp ~ '^\+?[0-9 ()-]{7,20}$'),
  add column viber     text check (viber ~ '^\+?[0-9 ()-]{7,20}$'),
  add column messenger text check (messenger ~ '^[A-Za-z0-9.]{3,50}$');

-- Each person edits their own (the policy `profiles_update_self` already
-- limits the row; this limits the columns).
grant update (phone, whatsapp, viber, messenger) on public.profiles to authenticated;

-- The people I can start a private chat with, and how to reach them: a
-- parent gets the clinic's staff; staff get the clinic's parents. A parent
-- can't read the clinic's memberships, hence a function.
create or replace function public.clinic_contacts(p_clinic uuid)
returns table (
  id uuid,
  display_name text,
  role text,
  phone text,
  whatsapp text,
  viber text,
  messenger text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_me_staff boolean := public.has_role(p_clinic, array['manager', 'therapist']);
begin
  if not public.has_role(p_clinic, array['manager', 'therapist', 'parent']) then
    raise exception 'not a member';
  end if;
  return query
    select p.id, p.display_name,
           case when bool_or(m.role = 'manager') then 'manager'
                when bool_or(m.role = 'therapist') then 'therapist'
                else 'parent' end,
           p.phone, p.whatsapp, p.viber, p.messenger
      from public.memberships m
      join public.profiles p on p.id = m.user_id
     where m.clinic_id = p_clinic and m.user_id <> auth.uid()
     group by p.id
    having (v_me_staff and not bool_or(m.role in ('manager', 'therapist')))
        or (not v_me_staff and bool_or(m.role in ('manager', 'therapist')))
     order by p.display_name;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Grants on the new functions
-- ─────────────────────────────────────────────────────────────
revoke all on function public.confirm_session(uuid, boolean) from public, anon;
revoke all on function public.session_moved() from public, anon, authenticated;
revoke all on function public.note_comment_fill() from public, anon, authenticated;
revoke all on function public.can_comment_note(uuid) from public, anon;
revoke all on function public.can_see_thread(uuid) from public, anon;
revoke all on function public.open_direct(uuid, uuid) from public, anon;
revoke all on function public.my_threads(uuid) from public, anon;
revoke all on function public.clinic_contacts(uuid) from public, anon;

grant execute on function public.confirm_session(uuid, boolean) to authenticated;
grant execute on function public.can_comment_note(uuid) to authenticated;
grant execute on function public.can_see_thread(uuid) to authenticated;
grant execute on function public.open_direct(uuid, uuid) to authenticated;
grant execute on function public.my_threads(uuid) to authenticated;
grant execute on function public.clinic_contacts(uuid) to authenticated;

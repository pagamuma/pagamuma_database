-- ═══════════════════════════════════════════════════════════════════════════
-- 0008 — ONLY PRIVATE CHATS
--
-- dev & prod: "apliquei"
--
-- Decision 0012 (2026-10-15), revising 0003.
--
-- The chat is now only the private one: one staff member and one parent
-- (0006), and either side starts it. The child's group chat (the whole
-- clinic team and that child's guardians) leaves the app:
--   · new children no longer get a group thread (`create_client`);
--   · the message list shows only private chats (`my_threads`);
--   · nobody writes to a group thread anymore (`messages_insert`).
--
-- ⚠️ NOTHING IS DELETED. The group threads and their messages stay, readable
-- by the same people as before (`can_see_thread`), for the record and in case
-- the decision is revisited. They are just no longer shown or written.
-- ═══════════════════════════════════════════════════════════════════════════

-- New children: no group thread.
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
  return v_id;
end;
$$;

-- The list: private chats only.
create or replace function public.my_threads(p_clinic uuid)
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
  select t.id, t.kind, t.client_id, o.other_id, p.display_name,
         m.body, m.created_at,
         m.created_at is not null and m.sender_id <> auth.uid()
           and m.created_at > coalesce(r.last_read_at, '-infinity')
    from public.threads t
    cross join lateral (
      select case when t.staff_id = auth.uid() then t.parent_id else t.staff_id end as other_id
    ) o
    left join public.profiles p on p.id = o.other_id
    left join lateral (
      select body, created_at, sender_id from public.messages
       where thread_id = t.id order by created_at desc limit 1
    ) m on true
    left join public.thread_reads r on r.thread_id = t.id and r.user_id = auth.uid()
   where t.clinic_id = p_clinic and t.kind = 'direct'
   order by m.created_at desc nulls last;
$$;

-- Writing: private chats only.
drop policy messages_insert on public.messages;
create policy messages_insert on public.messages for insert to authenticated
  with check (
    sender_id = auth.uid()
    and public.can_see_thread(thread_id)
    and exists (select 1 from public.threads t where t.id = thread_id and t.kind = 'direct')
  );

-- ═══════════════════════════════════════════════════════════════════════════
-- 0005 — EVERY THERAPIST SEES EVERY CHILD OF THE CLINIC; THE CHAT SAYS WHO
--         FROM THE CLINIC WROTE
--
-- dev & prod: "apliquei"
--
-- Decision 0010 (2026-10-09).
--
-- 1) ACCESS. A therapist of the clinic now reads and writes every child of
--    that clinic: record, sessions, notes, chat. Before, only the children
--    they were assigned to (`client_therapists`). Only the FAMILIES stay
--    private: a parent still sees only their own children, and never the
--    other families (`is_guardian_of`, `can_see_profile`: unchanged).
--
--    One function changes, and every policy follows: `is_therapist_of`
--    feeds `can_see_client` and `can_care_for`. The name stays (it is used
--    everywhere); what it means is "a therapist of this child's clinic".
--
--    `client_therapists` stays: it says who treats the child (shown on the
--    child's page), no longer who may see them.
--
-- 2) THE CHAT. Still one thread per child (decision 0003). Each message now
--    carries `from_clinic`: true when the sender was staff (manager or
--    therapist) of the thread's clinic when they sent it. The app shows the
--    sender's name above those messages. It's stored, and set by a trigger,
--    because a parent can't read the clinic's memberships, and a later role
--    change must not rewrite history.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1) Access: the clinic's therapists, not only the assigned ones.
create or replace function public.is_therapist_of(p_client uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.clients c
     where c.id = p_client and public.has_role(c.clinic_id, array['therapist'])
  );
$$;

-- 2) The chat: who wrote from the clinic.
alter table public.messages add column from_clinic boolean not null default false;

-- ⚠️ Always set here, whatever the insert says: the column is insertable
-- (the grant is table-wide), so the client can't be trusted with it.
create or replace function public.message_from_clinic()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select exists (
    select 1 from public.threads t
      join public.memberships m on m.clinic_id = t.clinic_id
     where t.id = new.thread_id and m.user_id = new.sender_id
       and m.role in ('manager', 'therapist')
  ) into new.from_clinic;
  return new;
end;
$$;

create trigger trg_messages_from_clinic before insert on public.messages
  for each row execute function public.message_from_clinic();

-- The messages already sent: by the sender's role today.
update public.messages msg
   set from_clinic = true
  from public.threads t
  join public.memberships m on m.clinic_id = t.clinic_id
 where t.id = msg.thread_id and m.user_id = msg.sender_id
   and m.role in ('manager', 'therapist');

-- ═══════════════════════════════════════════════════════════════════════════
-- 0007 — EVERY NAME SAYS THE ROLE ("Maria Santos · Therapist")
--
-- dev & prod: "Apliquei"
--
-- Decision 0011 (2026-10-15).
--
-- The app shows the role next to every name: notes, comments, the chat, the
-- schedule, the urgent card. A parent can't read the clinic's memberships,
-- so the role comes from here, and only for people the caller already sees
-- (`can_see_profile`). One role per person, the most responsible: manager,
-- therapist, parent.
-- ═══════════════════════════════════════════════════════════════════════════

create or replace function public.clinic_people(p_clinic uuid, p_ids uuid[])
returns table (id uuid, display_name text, role text)
language sql
stable
security definer
set search_path = ''
as $$
  select p.id, p.display_name,
         case when bool_or(m.role = 'manager') then 'manager'
              when bool_or(m.role = 'therapist') then 'therapist'
              when bool_or(m.role = 'parent') then 'parent' end
    from public.profiles p
    left join public.memberships m on m.user_id = p.id and m.clinic_id = p_clinic
   where p.id = any (p_ids)
     and public.can_see_profile(p.id)
     and public.has_role(p_clinic, array['manager', 'therapist', 'parent'])
   group by p.id;
$$;

revoke all on function public.clinic_people(uuid, uuid[]) from public, anon;
grant execute on function public.clinic_people(uuid, uuid[]) to authenticated;

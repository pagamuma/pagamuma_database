-- ═══════════════════════════════════════════════════════════════════════════
-- 0004 — MANAGERS CAN BE INVITED TOO
--
-- dev & prod: "apliquei"
--
-- Decision of 2026-10-08 (decision 0009).
--
-- A clinic can have several managers. The third invite link
-- (`/invite?c=<code>&r=manager`) opens a join request for the manager role.
-- It is still a REQUEST: an existing manager approves it, and can change the
-- role. The People screen warns before sharing that link, because a manager
-- sees every child, note and family.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.join_requests drop constraint join_requests_role_check;
alter table public.join_requests
  add constraint join_requests_role_check check (role in ('parent', 'therapist', 'manager'));

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
  if p_role not in ('parent', 'therapist', 'manager') then p_role := 'parent'; end if;
  if exists (select 1 from public.memberships where clinic_id = v_clinic and user_id = p_user) then return; end if;
  insert into public.join_requests (clinic_id, user_id, role)
  values (v_clinic, p_user, p_role)
  on conflict do nothing;
end;
$$;

revoke all on function public.join_request_for(uuid, text, text) from public, anon, authenticated;

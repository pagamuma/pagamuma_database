-- ═══════════════════════════════════════════════════════════════════════════
-- 0009 — ONE MOBILE NUMBER, AND WHERE IT ANSWERS
--
-- dev & prod: "apliquei"
--
-- Decision 0011 (2026-10-15), revised the same day.
--
-- The profile now asks for ONE mobile number (country code + number) and
-- switches for where that number answers: SMS, calls, WhatsApp, Viber.
-- Messenger stays a username.
--
--   · `phone` holds the number, in international form (+639171234567);
--   · `phone_sms` and `phone_call` say whether it takes texts and calls;
--   · `whatsapp` and `viber` keep holding a number, the same one, when their
--     switch is on (null when off): the links and `clinic_contacts` read them
--     as before.
--
-- Existing numbers keep working: a `phone` already saved had texts and calls
-- in mind, so both start on.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.profiles
  add column phone_sms  boolean not null default true,
  add column phone_call boolean not null default true;

grant update (phone_sms, phone_call) on public.profiles to authenticated;

-- The list of people to reach now says which way each number answers.
drop function public.clinic_contacts(uuid);
create function public.clinic_contacts(p_clinic uuid)
returns table (
  id uuid,
  display_name text,
  role text,
  phone text,
  phone_sms boolean,
  phone_call boolean,
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
           p.phone, p.phone_sms, p.phone_call, p.whatsapp, p.viber, p.messenger
      from public.memberships m
      join public.profiles p on p.id = m.user_id
     where m.clinic_id = p_clinic and m.user_id <> auth.uid()
     group by p.id
    having (v_me_staff and not bool_or(m.role in ('manager', 'therapist')))
        or (not v_me_staff and bool_or(m.role in ('manager', 'therapist')))
     order by p.display_name;
end;
$$;

revoke all on function public.clinic_contacts(uuid) from public, anon;
grant execute on function public.clinic_contacts(uuid) to authenticated;

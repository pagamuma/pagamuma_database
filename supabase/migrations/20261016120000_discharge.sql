-- ═══════════════════════════════════════════════════════════════════════════
-- 0010 — DISCHARGE: THE LAST DAY OF A CHILD'S SESSIONS; DELETE FROM ONE ON
--
-- dev & prod: "apliquei"
--
-- Decision 0014 (2026-10-16). Both for MANAGERS only.
--
-- 1) DISCHARGE (`clients.discharge_on`): the last day a child can have a
--    session (the end of the contract, "alta").
--      · setting it deletes the child's SCHEDULED sessions after that day;
--        done, no-show and canceled ones stay, as history;
--      · while it's set, the database refuses any session after that day,
--        from anyone (a trigger, not the app: a series booked by an old
--        phone can't slip past it);
--      · clearing it (null) lifts the limit. The deleted sessions don't
--        come back.
--    "The day" is the clinic's: dates are read in `clinics.timezone`.
--
-- 2) DELETE FROM ONE ON (`delete_sessions_from`): from a session, delete it
--    and every later SCHEDULED session of the same child, in every series.
--    History stays, as above.
-- ═══════════════════════════════════════════════════════════════════════════

alter table public.clients add column discharge_on date;

comment on column public.clients.discharge_on is
  'Discharge: the last day this child can have a session (clinic timezone). Null = no end.';

-- The day of a moment, in the child's clinic.
create or replace function public.clinic_day(p_client uuid, p_at timestamptz)
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select (p_at at time zone c.timezone)::date
    from public.clients cl join public.clinics c on c.id = cl.clinic_id
   where cl.id = p_client;
$$;

-- No session after the discharge day, whoever writes it.
create or replace function public.session_within_discharge()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_last date;
begin
  select discharge_on into v_last from public.clients where id = new.client_id;
  if v_last is not null and public.clinic_day(new.client_id, new.starts_at) > v_last then
    raise exception 'client:discharged %', v_last;
  end if;
  return new;
end;
$$;

create trigger trg_sessions_discharge before insert or update of starts_at, client_id on public.sessions
  for each row execute function public.session_within_discharge();

-- Set (or clear, with null) the discharge day. Returns how many scheduled
-- sessions were deleted.
create or replace function public.discharge_client(p_client uuid, p_last_day date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_count integer := 0;
begin
  if not public.is_manager_of_client(p_client) then raise exception 'not a manager'; end if;
  update public.clients set discharge_on = p_last_day where id = p_client;
  if p_last_day is not null then
    delete from public.sessions
     where client_id = p_client and status = 'scheduled'
       and public.clinic_day(p_client, starts_at) > p_last_day;
    get diagnostics v_count = row_count;
  end if;
  return v_count;
end;
$$;

-- Delete a session and every later scheduled one of the same child.
-- Returns how many were deleted.
create or replace function public.delete_sessions_from(p_session uuid)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_client uuid;
  v_from timestamptz;
  v_count integer;
begin
  select client_id, starts_at into v_client, v_from from public.sessions where id = p_session;
  if v_client is null or not public.is_manager_of_client(v_client) then raise exception 'not a manager'; end if;
  delete from public.sessions
   where client_id = v_client and status = 'scheduled' and starts_at >= v_from;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

revoke all on function public.clinic_day(uuid, timestamptz) from public, anon, authenticated;
revoke all on function public.session_within_discharge() from public, anon, authenticated;
revoke all on function public.discharge_client(uuid, date) from public, anon;
revoke all on function public.delete_sessions_from(uuid) from public, anon;
grant execute on function public.discharge_client(uuid, date) to authenticated;
grant execute on function public.delete_sessions_from(uuid) to authenticated;

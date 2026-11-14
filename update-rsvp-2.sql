-- Handshake update: RSVP invites by phone number.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-rsvp.sql first. Safe to run more than once.
--
-- Decided Nov 14: RSVP invites aren't limited to Handshake people.
--   * The organizer can invite anyone by name and mobile number (when planning, or later with
--     Invite more). A number that already belongs to a Handshake account becomes a normal invite.
--   * Otherwise the organizer texts the invite with Open Messages; when that person signs up (or
--     signs in) with that number, claim_rsvp_invites() turns it into a normal invite.
--   * Phone invitees can also be on the last call; it's claimed the same way.
--   * Everyone in the event sees phone invitees' names; only the organizer sees their numbers.

create table if not exists public.rsvp_phone_invites (
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  phone_digits  text not null check (phone_digits ~ '^[0-9]{8,15}$'),
  name          text not null check (char_length(btrim(name)) between 1 and 30),
  claimed_uid   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  primary key (event_id, phone_digits)
);
create table if not exists public.rsvp_lastcall_phones (
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  phone_digits  text not null,
  name          text not null,
  claimed_uid   uuid references public.profiles (id) on delete set null,
  primary key (event_id, phone_digits)
);

-- The Handshake account with this phone number, if there is one.
create or replace function public._uid_for_phone(p_digits text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select u.id from auth.users u join public.profiles p on p.id = u.id
  where regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') = p_digits limit 1
$$;

create or replace function public.rsvp_can_see(p_event uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = auth.uid())
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_lastcall where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_phone_invites where event_id = p_event and phone_digits = _my_phone())
$$;

alter table public.rsvp_phone_invites enable row level security;
alter table public.rsvp_lastcall_phones enable row level security;
drop policy if exists "rsvp people see phone invitees" on public.rsvp_phone_invites;
create policy "rsvp people see phone invitees" on public.rsvp_phone_invites for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see last call phones" on public.rsvp_lastcall_phones;
create policy "rsvp people see last call phones" on public.rsvp_lastcall_phones for select to authenticated using (public.rsvp_can_see(event_id));
-- names yes, numbers no (the organizer gets numbers from rsvp_phone_numbers())
revoke all on public.rsvp_phone_invites, public.rsvp_lastcall_phones from authenticated;
grant select (event_id, name, claimed_uid, created_at) on public.rsvp_phone_invites to authenticated;
grant select (event_id, name, claimed_uid) on public.rsvp_lastcall_phones to authenticated;
grant all on public.rsvp_phone_invites, public.rsvp_lastcall_phones to service_role;

create or replace function public.rsvp_phone_numbers(p_event uuid)
returns table (name text, phone_digits text, claimed boolean, on_last_call boolean)
language sql stable security definer set search_path = public as $$
  select i.name, i.phone_digits, i.claimed_uid is not null,
    exists (select 1 from rsvp_lastcall_phones l where l.event_id = i.event_id and l.phone_digits = i.phone_digits)
  from rsvp_phone_invites i join rsvp_events e on e.id = i.event_id
  where i.event_id = p_event and e.organizer = auth.uid()
  order by i.created_at
$$;

-- Add one phone invite (or a normal invite if the number is already on Handshake).
create or replace function public._rsvp_add_phone(p_event uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); nm text := btrim(coalesce(p_name, '')); u uuid;
begin
  if char_length(d) = 10 then d := '1' || d; end if;
  if d !~ '^[0-9]{8,15}$' then raise exception 'That phone number doesn''t look right: %', p_phone; end if;
  u := _uid_for_phone(d);
  if u is not null then
    if u <> (select organizer from rsvp_events where id = p_event) then
      insert into rsvp_invitees (event_id, uid) values (p_event, u) on conflict do nothing;
    end if;
    return;
  end if;
  if char_length(nm) not between 1 and 30 then raise exception 'Give each person you text a name.'; end if;
  insert into rsvp_phone_invites (event_id, phone_digits, name) values (p_event, d, nm)
  on conflict (event_id, phone_digits) do update set name = excluded.name;
end $$;

-- Start an event (now with phone invites: p_phones = [{name, phone}]).
drop function if exists public.create_rsvp(text, text, text, jsonb, uuid[]);
create or replace function public.create_rsvp(p_title text, p_venue text, p_notes text, p_options jsonb, p_invitees uuid[], p_phones jsonb default '[]')
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); eid uuid; o jsonb; oid uuid; u uuid; ph jsonb;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Say what it''s for (up to 60 characters).'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) = 0 then raise exception 'Propose at least one date.'; end if;
  if jsonb_array_length(p_options) > 20 then raise exception 'Up to 20 date options.'; end if;
  if coalesce(cardinality(p_invitees), 0) = 0 and coalesce(jsonb_array_length(p_phones), 0) = 0 then raise exception 'Invite at least one person.'; end if;
  insert into rsvp_events (title, venue, notes, organizer)
  values (btrim(p_title), nullif(left(btrim(coalesce(p_venue, '')), 60), ''), left(btrim(coalesce(p_notes, '')), 240), me)
  returning id into eid;
  for o in select * from jsonb_array_elements(p_options) loop
    insert into rsvp_options (event_id, day, end_day, at_time, added_by)
    values (eid, (o->>'day')::date, nullif(o->>'end_day', '')::date, nullif(o->>'at_time', '')::time, me)
    returning id into oid;
    insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, eid, me, 'go');
  end loop;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into rsvp_invitees (event_id, uid) values (eid, u) on conflict do nothing; end if;
  end loop;
  for ph in select * from jsonb_array_elements(coalesce(p_phones, '[]')) loop
    perform _rsvp_add_phone(eid, ph->>'name', ph->>'phone');
  end loop;
  if not exists (select 1 from rsvp_invitees where event_id = eid) and not exists (select 1 from rsvp_phone_invites where event_id = eid) then
    raise exception 'Invite at least one other person.'; end if;
  update rsvp_events set open_count = (select count(*) from rsvp_tally(eid) t where t.works) where id = eid;
  return eid;
end $$;

-- Invite more people while it's still open.
create or replace function public.rsvp_invite(p_event uuid, p_invitees uuid[], p_phones jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare e rsvp_events; u uuid; ph jsonb;
begin
  select * into e from rsvp_events where id = p_event;
  if not found or e.organizer <> auth.uid() then raise exception 'Only the organizer can invite people.'; end if;
  if e.status <> 'open' then raise exception 'This one is locked down already.'; end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> e.organizer and exists (select 1 from profiles where id = u) then insert into rsvp_invitees (event_id, uid) values (p_event, u) on conflict do nothing; end if;
  end loop;
  for ph in select * from jsonb_array_elements(coalesce(p_phones, '[]')) loop
    perform _rsvp_add_phone(p_event, ph->>'name', ph->>'phone');
  end loop;
end $$;

-- Lock it down (now with phone invitees on the last call: p_phones = their digits).
drop function if exists public.rsvp_lock(uuid, uuid, text, uuid[]);
create or replace function public.rsvp_lock(p_event uuid, p_option uuid, p_venue text, p_people uuid[], p_phones text[] default '{}')
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); e rsvp_events; u uuid; d text; pi rsvp_phone_invites; n int := 0;
begin
  select * into e from rsvp_events where id = p_event for update;
  if not found or e.organizer <> me then raise exception 'Only the organizer can lock it down.'; end if;
  if e.status <> 'open' then raise exception 'This one is already locked down.'; end if;
  if not exists (select 1 from rsvp_options where id = p_option and event_id = p_event) then raise exception 'Pick one of the dates.'; end if;
  if char_length(btrim(coalesce(p_venue, ''))) not between 1 and 60 then raise exception 'Pick the venue.'; end if;
  update rsvp_events set status = 'locked', locked_option = p_option, locked_venue = btrim(p_venue), locked_at = now() where id = p_event;
  foreach u in array coalesce(p_people, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_lastcall (event_id, uid) values (p_event, u) on conflict do nothing; n := n + 1;
    end if;
  end loop;
  foreach d in array coalesce(p_phones, '{}') loop
    select * into pi from rsvp_phone_invites where event_id = p_event and phone_digits = d;
    if not found then continue; end if;
    if pi.claimed_uid is not null then
      insert into rsvp_lastcall (event_id, uid) values (p_event, pi.claimed_uid) on conflict do nothing;
    else
      insert into rsvp_lastcall_phones (event_id, phone_digits, name) values (p_event, d, pi.name) on conflict do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- After signing in: turn invites sent to my phone number into normal invites. Returns how many.
create or replace function public.claim_rsvp_invites()
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); d text := _my_phone(); n int := 0; r record;
begin
  if me is null or d is null then return 0; end if;
  for r in select * from rsvp_phone_invites where phone_digits = d and claimed_uid is null loop
    if me <> (select organizer from rsvp_events where id = r.event_id) then
      insert into rsvp_invitees (event_id, uid) values (r.event_id, me) on conflict do nothing;
      n := n + 1;
    end if;
    update rsvp_phone_invites set claimed_uid = me where event_id = r.event_id and phone_digits = d;
  end loop;
  for r in select * from rsvp_lastcall_phones where phone_digits = d and claimed_uid is null loop
    insert into rsvp_lastcall (event_id, uid) values (r.event_id, me) on conflict do nothing;
    update rsvp_lastcall_phones set claimed_uid = me where event_id = r.event_id and phone_digits = d;
  end loop;
  return n;
end $$;

revoke all on function public._uid_for_phone(text), public._rsvp_add_phone(uuid, text, text) from public, anon, authenticated;
revoke all on function public.rsvp_phone_numbers(uuid), public.create_rsvp(text, text, text, jsonb, uuid[], jsonb), public.rsvp_invite(uuid, uuid[], jsonb),
  public.rsvp_lock(uuid, uuid, text, uuid[], text[]), public.claim_rsvp_invites() from public, anon;
grant execute on function public.rsvp_phone_numbers(uuid), public.create_rsvp(text, text, text, jsonb, uuid[], jsonb), public.rsvp_invite(uuid, uuid[], jsonb),
  public.rsvp_lock(uuid, uuid, text, uuid[], text[]), public.claim_rsvp_invites() to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

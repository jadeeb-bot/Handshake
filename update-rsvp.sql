-- Handshake update: RSVP (plan a dinner, a trip, anything).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- How it works (decided Nov 14):
--   * The organizer names the event, sets a venue or asks for venue ideas, proposes date/time
--     options (a day, optional time, optional end day for trips) and invites people.
--   * Everyone marks Go or No-go on each option, can suggest another date/time, and can suggest
--     venues and vote for them. The organizer is marked Go on the options they propose.
--   * An option "still works" until someone says No-go. The app ranks what still works by how
--     many said Go, and venues by votes. The notify function tells everyone when the number of
--     options that still work goes down (rsvp_events.open_count remembers the last count sent).
--   * Lock it down (organizer, any time): picks the option and venue. The organizer reviews the
--     last-call list (everyone who said Go to that option or hasn't answered it, plus anyone they
--     add, minus anyone they take off) and sends it. Those people answer I'm in / Can't make it.
--   * Only the organizer, invitees and last-call people can see an event.

create table if not exists public.rsvp_events (
  id            uuid primary key default gen_random_uuid(),
  title         text not null check (char_length(btrim(title)) between 1 and 60),
  venue         text check (venue is null or char_length(venue) <= 60),   -- null = asking for ideas
  notes         text not null default '' check (char_length(notes) <= 240),
  organizer     uuid not null references public.profiles (id) on delete cascade,
  status        text not null default 'open' check (status in ('open', 'locked', 'canceled')),
  locked_option uuid,
  locked_venue  text,
  locked_at     timestamptz,
  open_count    int,                                 -- options still working at the last notice
  created_at    timestamptz not null default now()
);
create table if not exists public.rsvp_invitees (
  event_id  uuid not null references public.rsvp_events (id) on delete cascade,
  uid       uuid not null references public.profiles (id) on delete cascade,
  primary key (event_id, uid)
);
create table if not exists public.rsvp_options (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.rsvp_events (id) on delete cascade,
  day         date not null,
  end_day     date check (end_day is null or end_day >= day),
  at_time     time,
  added_by    uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.rsvp_answers (
  option_id   uuid not null references public.rsvp_options (id) on delete cascade,
  event_id    uuid not null references public.rsvp_events (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  answer      text not null check (answer in ('go', 'nogo')),
  updated_at  timestamptz not null default now(),
  primary key (option_id, uid)
);
create table if not exists public.rsvp_venues (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  suggested_by  uuid not null references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now()
);
create table if not exists public.rsvp_venue_votes (
  venue_id  uuid not null references public.rsvp_venues (id) on delete cascade,
  event_id  uuid not null references public.rsvp_events (id) on delete cascade,
  uid       uuid not null references public.profiles (id) on delete cascade,
  primary key (venue_id, uid)
);
create table if not exists public.rsvp_lastcall (
  event_id     uuid not null references public.rsvp_events (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'in', 'out')),
  sent_at      timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (event_id, uid)
);

create or replace function public.rsvp_can_see(p_event uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = auth.uid())
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_lastcall where event_id = p_event and uid = auth.uid())
$$;

alter table public.rsvp_events enable row level security;
alter table public.rsvp_invitees enable row level security;
alter table public.rsvp_options enable row level security;
alter table public.rsvp_answers enable row level security;
alter table public.rsvp_venues enable row level security;
alter table public.rsvp_venue_votes enable row level security;
alter table public.rsvp_lastcall enable row level security;
drop policy if exists "rsvp people see events" on public.rsvp_events;
create policy "rsvp people see events" on public.rsvp_events for select to authenticated using (public.rsvp_can_see(id));
drop policy if exists "rsvp people see invitees" on public.rsvp_invitees;
create policy "rsvp people see invitees" on public.rsvp_invitees for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see options" on public.rsvp_options;
create policy "rsvp people see options" on public.rsvp_options for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see answers" on public.rsvp_answers;
create policy "rsvp people see answers" on public.rsvp_answers for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see venues" on public.rsvp_venues;
create policy "rsvp people see venues" on public.rsvp_venues for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see votes" on public.rsvp_venue_votes;
create policy "rsvp people see votes" on public.rsvp_venue_votes for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see last call" on public.rsvp_lastcall;
create policy "rsvp people see last call" on public.rsvp_lastcall for select to authenticated using (public.rsvp_can_see(event_id));
grant select on public.rsvp_events, public.rsvp_invitees, public.rsvp_options, public.rsvp_answers,
  public.rsvp_venues, public.rsvp_venue_votes, public.rsvp_lastcall to authenticated;
grant all on public.rsvp_events, public.rsvp_invitees, public.rsvp_options, public.rsvp_answers,
  public.rsvp_venues, public.rsvp_venue_votes, public.rsvp_lastcall to service_role;

-- Is this person part of the event (organizer or invitee)?
create or replace function public._rsvp_member(p_event uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = p_uid)
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = p_uid)
$$;

-- Options with their tallies, best first. works = nobody said No-go.
create or replace function public.rsvp_tally(p_event uuid)
returns table (option_id uuid, day date, end_day date, at_time time, go int, nogo int, works boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.day, o.end_day, o.at_time,
    count(*) filter (where a.answer = 'go')::int, count(*) filter (where a.answer = 'nogo')::int,
    count(*) filter (where a.answer = 'nogo') = 0
  from rsvp_options o left join rsvp_answers a on a.option_id = o.id
  where o.event_id = p_event and (auth.uid() is null or rsvp_can_see(p_event))
  group by o.id
  order by (count(*) filter (where a.answer = 'nogo') = 0) desc, count(*) filter (where a.answer = 'go') desc, o.day, o.at_time nulls first
$$;

-- Start an event. p_options: [{day, end_day, at_time}], p_invitees: [uid].
create or replace function public.create_rsvp(p_title text, p_venue text, p_notes text, p_options jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); eid uuid; o jsonb; oid uuid; u uuid; n int := 0;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Say what it''s for (up to 60 characters).'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) = 0 then raise exception 'Propose at least one date.'; end if;
  if jsonb_array_length(p_options) > 20 then raise exception 'Up to 20 date options.'; end if;
  if coalesce(cardinality(p_invitees), 0) = 0 then raise exception 'Invite at least one person.'; end if;
  insert into rsvp_events (title, venue, notes, organizer)
  values (btrim(p_title), nullif(left(btrim(coalesce(p_venue, '')), 60), ''), left(btrim(coalesce(p_notes, '')), 240), me)
  returning id into eid;
  for o in select * from jsonb_array_elements(p_options) loop
    insert into rsvp_options (event_id, day, end_day, at_time, added_by)
    values (eid, (o->>'day')::date, nullif(o->>'end_day', '')::date, nullif(o->>'at_time', '')::time, me)
    returning id into oid;
    insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, eid, me, 'go');
  end loop;
  foreach u in array p_invitees loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_invitees (event_id, uid) values (eid, u) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Invite at least one other person.'; end if;
  update rsvp_events set open_count = (select count(*) from rsvp_tally(eid) t where t.works) where id = eid;
  return eid;
end $$;

-- Go / No-go on one option (p_answer null clears it).
create or replace function public.rsvp_answer(p_option uuid, p_answer text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o rsvp_options; e rsvp_events;
begin
  select * into o from rsvp_options where id = p_option;
  if not found then raise exception 'That option is gone.'; end if;
  select * into e from rsvp_events where id = o.event_id;
  if not _rsvp_member(e.id, me) then raise exception 'You''re not invited to this one.'; end if;
  if e.status <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_answer is null then delete from rsvp_answers where option_id = p_option and uid = me;
  elsif p_answer in ('go', 'nogo') then
    insert into rsvp_answers (option_id, event_id, uid, answer) values (p_option, e.id, me, p_answer)
    on conflict (option_id, uid) do update set answer = excluded.answer, updated_at = now();
  else raise exception 'Answer go or no-go.'; end if;
end $$;

-- Suggest another date/time (you're marked Go on it).
create or replace function public.rsvp_add_option(p_event uuid, p_day date, p_end_day date, p_at_time time)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); oid uuid;
begin
  if not _rsvp_member(p_event, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = p_event) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_day is null then raise exception 'Pick a day.'; end if;
  if (select count(*) from rsvp_options where event_id = p_event) >= 30 then raise exception 'That''s plenty of options already.'; end if;
  insert into rsvp_options (event_id, day, end_day, at_time, added_by) values (p_event, p_day, p_end_day, p_at_time, me) returning id into oid;
  insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, p_event, me, 'go');
  return oid;
end $$;

-- Suggest a venue (you're counted as a vote for it).
create or replace function public.rsvp_add_venue(p_event uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); vid uuid; nm text := btrim(coalesce(p_name, ''));
begin
  if not _rsvp_member(p_event, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = p_event) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if char_length(nm) not between 1 and 60 then raise exception 'Name the place (up to 60 characters).'; end if;
  select id into vid from rsvp_venues where event_id = p_event and lower(name) = lower(nm);
  if vid is null then
    insert into rsvp_venues (event_id, name, suggested_by) values (p_event, nm, me) returning id into vid;
  end if;
  insert into rsvp_venue_votes (venue_id, event_id, uid) values (vid, p_event, me) on conflict do nothing;
  return vid;
end $$;

create or replace function public.rsvp_vote_venue(p_venue uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v rsvp_venues;
begin
  select * into v from rsvp_venues where id = p_venue;
  if not found or not _rsvp_member(v.event_id, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = v.event_id) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_on then insert into rsvp_venue_votes (venue_id, event_id, uid) values (p_venue, v.event_id, me) on conflict do nothing;
  else delete from rsvp_venue_votes where venue_id = p_venue and uid = me; end if;
end $$;

-- Lock it down: day/time, venue, and exactly who gets the last call.
create or replace function public.rsvp_lock(p_event uuid, p_option uuid, p_venue text, p_people uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); e rsvp_events; u uuid; n int := 0;
begin
  select * into e from rsvp_events where id = p_event for update;
  if not found or e.organizer <> me then raise exception 'Only the organizer can lock it down.'; end if;
  if e.status <> 'open' then raise exception 'This one is already locked down.'; end if;
  if not exists (select 1 from rsvp_options where id = p_option and event_id = p_event) then raise exception 'Pick one of the dates.'; end if;
  if char_length(btrim(coalesce(p_venue, ''))) not between 1 and 60 then raise exception 'Pick the venue.'; end if;
  update rsvp_events set status = 'locked', locked_option = p_option, locked_venue = btrim(p_venue), locked_at = now() where id = p_event;
  foreach u in array coalesce(p_people, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_lastcall (event_id, uid) values (p_event, u) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Last call answer: I'm in / Can't make it.
create or replace function public.rsvp_lastcall_answer(p_event uuid, p_in boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update rsvp_lastcall set status = case when p_in then 'in' else 'out' end, answered_at = now()
  where event_id = p_event and uid = auth.uid();
  if not found then raise exception 'You weren''t on the last call for this one.'; end if;
end $$;

-- Organizer can call the whole thing off.
create or replace function public.rsvp_cancel(p_event uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update rsvp_events set status = 'canceled' where id = p_event and organizer = auth.uid() and status <> 'canceled';
  if not found then raise exception 'Only the organizer can cancel it.'; end if;
end $$;

revoke all on function public.rsvp_can_see(uuid), public._rsvp_member(uuid, uuid), public.rsvp_tally(uuid),
  public.create_rsvp(text, text, text, jsonb, uuid[]), public.rsvp_answer(uuid, text), public.rsvp_add_option(uuid, date, date, time),
  public.rsvp_add_venue(uuid, text), public.rsvp_vote_venue(uuid, boolean), public.rsvp_lock(uuid, uuid, text, uuid[]),
  public.rsvp_lastcall_answer(uuid, boolean), public.rsvp_cancel(uuid) from public, anon;
grant execute on function public.rsvp_can_see(uuid), public.create_rsvp(text, text, text, jsonb, uuid[]), public.rsvp_answer(uuid, text),
  public.rsvp_add_option(uuid, date, date, time), public.rsvp_add_venue(uuid, text), public.rsvp_vote_venue(uuid, boolean),
  public.rsvp_lock(uuid, uuid, text, uuid[]), public.rsvp_lastcall_answer(uuid, boolean), public.rsvp_cancel(uuid) to authenticated;
grant execute on function public.rsvp_tally(uuid) to authenticated, service_role;
grant execute on function public._rsvp_member(uuid, uuid) to service_role;

-- Live updates while an event is open on screen.
do $$ begin alter publication supabase_realtime add table public.rsvp_answers; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_events; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_venue_votes; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_lastcall; exception when duplicate_object then null; when undefined_object then null; end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

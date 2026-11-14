-- Handshake update: Contests (group predictions with a pot).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- How it works (decided Nov 14):
--   * A sponsor asks a question about something in the future ("Who wins the Super Bowl?"), lists
--     the choices (and can allow write-ins), sets points per entry and the most entries per
--     person, an entry deadline, the invitees, and who can crash:
--       all     = Full Monty: anyone signed in can see it and enter
--       circle  = Circle of Trust: invitees plus anyone the sponsor or an invitee has played
--       invited = invitees only, no crashers
--   * Each entry is one pick and costs the points. Same pick twice by the same person isn't allowed.
--   * After the deadline the sponsor records the result. Entrants have 24 hours to say Prove it!
--     Then the sponsor has 24 hours to post proof (a link) or change the result; no proof means
--     it's called off. The challenger then has 24 hours to accept the proof or say it doesn't hold
--     up, which picks a referee (the other person in the most recent finished prediction involving
--     the sponsor or the challenger who isn't in the contest). The referee has 24 hours to say the
--     result stands or call it off. No referee, or no pick in time: called off (Hopeless).
--   * Payout: winning entries split the pot. Each losing entry's points are split across the
--     winning entries (rounded per pair). Nobody picked the result: everyone's refunded.
--     Points are booked as finished predictions between each pair (marked contest_id), so they
--     count in Standings, Rivals and settle-up.
--   * Timeouts are handled by the pg_cron job handshake-contests (every 10 minutes).

create table if not exists public.contests (
  id              uuid primary key default gen_random_uuid(),
  title           text not null check (char_length(btrim(title)) between 1 and 90),
  choices         text[] not null default '{}',
  allow_writeins  boolean not null default false,
  points          int not null check (points between 1 and 1000),
  max_entries     int not null check (max_entries between 1 and 20),
  deadline        timestamptz not null,
  visibility      text not null default 'invited' check (visibility in ('all', 'circle', 'invited')),
  sponsor         uuid not null references public.profiles (id) on delete cascade,
  stage           text not null default 'open' check (stage in ('open', 'recorded', 'proving', 'proof', 'refereeing', 'settled', 'void', 'canceled')),
  stage_at        timestamptz not null default now(),
  result          text,
  objector        uuid references public.profiles (id) on delete set null,
  objection       text,
  proof_link      text,
  referee         uuid references public.profiles (id) on delete set null,
  outcome_note    text,
  created_at      timestamptz not null default now()
);
create table if not exists public.contest_invitees (
  contest_id  uuid not null references public.contests (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  primary key (contest_id, uid)
);
create table if not exists public.contest_entries (
  id          uuid primary key default gen_random_uuid(),
  contest_id  uuid not null references public.contests (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  choice      text not null check (char_length(btrim(choice)) between 1 and 40),
  created_at  timestamptz not null default now()
);
create unique index if not exists contest_entries_one_each on public.contest_entries (contest_id, uid, lower(choice));
alter table public.predictions add column if not exists contest_id uuid references public.contests (id) on delete set null;

-- Has this person played (any prediction past the invite stage) with any of these people?
create or replace function public._played_any(p_me uuid, p_people uuid[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from predictions q where q.status <> 'proposed'
    and ((q.a_uid = p_me and q.b_uid = any (p_people)) or (q.b_uid = p_me and q.a_uid = any (p_people))))
$$;

create or replace function public.contest_can_see(p_contest uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); c contests;
begin
  if me is null then return false; end if;
  select * into c from contests where id = p_contest;
  if not found then return false; end if;
  if c.visibility = 'all' or c.sponsor = me or c.referee = me then return true; end if;
  if exists (select 1 from contest_invitees where contest_id = p_contest and uid = me)
     or exists (select 1 from contest_entries where contest_id = p_contest and uid = me) then return true; end if;
  if c.visibility = 'circle' then
    return _played_any(me, c.sponsor || array(select uid from contest_invitees where contest_id = p_contest));
  end if;
  return false;
end $$;

alter table public.contests enable row level security;
alter table public.contest_invitees enable row level security;
alter table public.contest_entries enable row level security;
drop policy if exists "contest people see contests" on public.contests;
create policy "contest people see contests" on public.contests for select to authenticated using (public.contest_can_see(id));
drop policy if exists "contest people see invitees" on public.contest_invitees;
create policy "contest people see invitees" on public.contest_invitees for select to authenticated using (public.contest_can_see(contest_id));
drop policy if exists "contest people see entries" on public.contest_entries;
create policy "contest people see entries" on public.contest_entries for select to authenticated using (public.contest_can_see(contest_id));
grant select on public.contests, public.contest_invitees, public.contest_entries to authenticated;
grant all on public.contests, public.contest_invitees, public.contest_entries to service_role;

create or replace function public.create_contest(p_title text, p_choices text[], p_writeins boolean, p_points int, p_max int,
  p_deadline timestamptz, p_visibility text, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid; ch text[]; u uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'Ask the question (up to 90 characters).'; end if;
  select coalesce(array_agg(x order by o), '{}') into ch from (
    select distinct on (lower(btrim(c))) btrim(c) as x, o from unnest(coalesce(p_choices, '{}')) with ordinality t(c, o)
    where btrim(c) <> '' order by lower(btrim(c)), o) d;
  if exists (select 1 from unnest(ch) c where char_length(c) > 40) then raise exception 'Keep each choice to 40 characters.'; end if;
  if cardinality(ch) > 50 then raise exception 'Up to 50 choices.'; end if;
  if cardinality(ch) < 2 and not coalesce(p_writeins, false) then raise exception 'List at least two choices, or allow write-ins.'; end if;
  if p_points is null or p_points not between 1 and 1000 then raise exception 'Points per entry go from 1 to 1000.'; end if;
  if p_max is null or p_max not between 1 and 20 then raise exception 'Entries per person go from 1 to 20.'; end if;
  if p_deadline is null or p_deadline <= now() then raise exception 'Set an entry deadline in the future.'; end if;
  if p_visibility not in ('all', 'circle', 'invited') then raise exception 'Pick who can crash.'; end if;
  insert into contests (title, choices, allow_writeins, points, max_entries, deadline, visibility, sponsor)
  values (btrim(p_title), ch, coalesce(p_writeins, false), p_points, p_max, p_deadline, p_visibility, me) returning id into cid;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into contest_invitees values (cid, u) on conflict do nothing; end if;
  end loop;
  return cid;
end $$;

create or replace function public.contest_enter(p_contest uuid, p_choice text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c contests; pick text := btrim(coalesce(p_choice, '')); canon text; eid uuid;
begin
  select * into c from contests where id = p_contest for update;
  if not found or not contest_can_see(p_contest) then raise exception 'That contest isn''t open to you.'; end if;
  if c.visibility = 'invited' and me <> c.sponsor and not exists (select 1 from contest_invitees where contest_id = p_contest and uid = me) then
    raise exception 'This one is invite only.'; end if;
  if c.stage <> 'open' or now() >= c.deadline then raise exception 'Entries are closed.'; end if;
  if (select count(*) from contest_entries where contest_id = p_contest and uid = me) >= c.max_entries then
    raise exception 'You''ve used all % of your entries.', c.max_entries; end if;
  if pick = '' or char_length(pick) > 40 then raise exception 'Pick a choice (up to 40 characters).'; end if;
  select x into canon from unnest(c.choices) x where lower(x) = lower(pick) limit 1;
  if canon is null then
    select choice into canon from contest_entries where contest_id = p_contest and lower(choice) = lower(pick) limit 1;
  end if;
  if canon is null and not c.allow_writeins then raise exception 'Pick one of the listed choices.'; end if;
  insert into contest_entries (contest_id, uid, choice) values (p_contest, me, coalesce(canon, pick)) returning id into eid;
  return eid;
exception when unique_violation then raise exception 'You already picked that one.';
end $$;

create or replace function public.contest_withdraw(p_entry uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e contest_entries; c contests;
begin
  select * into e from contest_entries where id = p_entry and uid = auth.uid();
  if not found then raise exception 'That entry isn''t yours.'; end if;
  select * into c from contests where id = e.contest_id;
  if c.stage <> 'open' or now() >= c.deadline then raise exception 'Entries are closed.'; end if;
  delete from contest_entries where id = p_entry;
end $$;

-- Book the payout (or refund) and close the contest.
create or replace function public._contest_settle(p_contest uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; total int; wins int; pay numeric[]; amt int; r record; ids uuid[]; nm text[]; i int; j int; n int; title text;
begin
  select * into c from contests where id = p_contest for update;
  if c.stage in ('settled', 'void', 'canceled') then return; end if;
  select count(*), count(*) filter (where lower(choice) = lower(c.result)) into total, wins from contest_entries where contest_id = p_contest;
  if wins = 0 then
    update contests set stage = 'void', stage_at = now(),
      outcome_note = coalesce(p_note || ' ', '') || 'Nobody picked ' || c.result || ', so everyone''s refunded.' where id = p_contest;
    return;
  end if;
  -- people in the contest, and pairwise amounts: each losing entry's points split across winning entries
  select array_agg(uid order by uid), array_agg(pr.name order by uid) into ids, nm
    from (select distinct uid from contest_entries where contest_id = p_contest) e join profiles pr on pr.id = e.uid;
  n := cardinality(ids);
  pay := array_fill(0::numeric, array[n * n]);
  for r in select l.uid as loser, w.uid as winner, count(*) as cnt
           from contest_entries l, contest_entries w
           where l.contest_id = p_contest and w.contest_id = p_contest
             and lower(l.choice) <> lower(c.result) and lower(w.choice) = lower(c.result) and l.uid <> w.uid
           group by l.uid, w.uid loop
    i := array_position(ids, r.loser); j := array_position(ids, r.winner);
    pay[(i - 1) * n + j] := pay[(i - 1) * n + j] + c.points::numeric * r.cnt / wins;
  end loop;
  title := left('Contest · ' || c.title, 90);
  for i in 1..n loop for j in (i + 1)..n loop
    amt := round(pay[(i - 1) * n + j] - pay[(j - 1) * n + i]);   -- > 0: i owes j
    if amt = 0 then continue; end if;
    insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                             status, winner, visibility, auto_notified, decided_at, contest_id, log)
    values (title, 'Contest', 'points', least(abs(amt), 1000), (now() at time zone 'America/Los_Angeles')::date,
            left('Result: ' || c.result || '. ' || wins || ' winning entr' || case when wins = 1 then 'y' else 'ies' end || ' of ' || total || ', ' || c.points || ' pts each.', 240),
            case when amt > 0 then ids[j] else ids[i] end, case when amt > 0 then nm[j] else nm[i] end,
            case when amt > 0 then ids[i] else ids[j] end, case when amt > 0 then nm[i] else nm[j] end,
            case when amt > 0 then ids[i] else ids[j] end,
            'settled', 'a', 'pair', true, now(), p_contest,
            jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'contest counted: ' || c.result)));
  end loop; end loop;
  update contests set stage = 'settled', stage_at = now(), outcome_note = p_note where id = p_contest;
end $$;

create or replace function public._contest_void(p_contest uuid, p_note text)
returns void language sql security definer set search_path = public as $$
  update contests set stage = 'void', stage_at = now(), outcome_note = p_note where id = p_contest and stage not in ('settled', 'void', 'canceled')
$$;

-- Sponsor records the result (after the deadline), or changes it while someone wants proof.
create or replace function public.contest_record(p_contest uuid, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; res text := btrim(coalesce(p_result, ''));
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.sponsor <> auth.uid() then raise exception 'Only the sponsor records the result.'; end if;
  if c.stage not in ('open', 'proving') then raise exception 'The result is already in.'; end if;
  if now() < c.deadline then raise exception 'Wait until entries close.'; end if;
  if res = '' or char_length(res) > 40 then raise exception 'Enter the result (up to 40 characters).'; end if;
  select coalesce((select x from unnest(c.choices) x where lower(x) = lower(res) limit 1),
                  (select choice from contest_entries where contest_id = p_contest and lower(choice) = lower(res) limit 1), res) into res;
  update contests set result = res, stage = 'recorded', stage_at = now(), objector = null, objection = null, proof_link = null where id = p_contest;
end $$;

create or replace function public.contest_prove_it(p_contest uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; me uuid := auth.uid();
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.stage <> 'recorded' then raise exception 'There''s no result waiting right now.'; end if;
  if now() > c.stage_at + interval '24 hours' then raise exception 'The 24 hours are up.'; end if;
  if me = c.sponsor or not exists (select 1 from contest_entries where contest_id = p_contest and uid = me) then
    raise exception 'Only people with an entry can say Prove it!'; end if;
  update contests set stage = 'proving', stage_at = now(), objector = me, objection = left(btrim(coalesce(p_reason, '')), 280) where id = p_contest;
end $$;

create or replace function public.contest_post_proof(p_contest uuid, p_link text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; l text := btrim(coalesce(p_link, ''));
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.sponsor <> auth.uid() then raise exception 'Only the sponsor posts proof.'; end if;
  if c.stage <> 'proving' then raise exception 'Nobody is asking for proof right now.'; end if;
  if l !~* '^https?://\S+$' or char_length(l) > 500 then raise exception 'Paste a link that starts with http.'; end if;
  update contests set stage = 'proof', stage_at = now(), proof_link = l where id = p_contest;
end $$;

create or replace function public.contest_accept_proof(p_contest uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c contests;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.objector <> auth.uid() or c.stage <> 'proof' then raise exception 'There''s no proof waiting for you.'; end if;
  perform _contest_settle(p_contest, null);
end $$;

-- The challenger says the proof doesn't hold up: pick a referee who isn't in the contest.
create or replace function public.contest_doesnt_hold(p_contest uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c contests; ref uuid;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.objector <> auth.uid() or c.stage <> 'proof' then raise exception 'There''s no proof waiting for you.'; end if;
  select x.other into ref from (
    select case when p.a_uid in (c.sponsor, c.objector) then p.b_uid else p.a_uid end as other, p.decided_at
    from predictions p where p.status = 'settled' and p.contest_id is distinct from p_contest
      and (p.a_uid in (c.sponsor, c.objector) or p.b_uid in (c.sponsor, c.objector))) x
  where x.other is not null and x.other not in (c.sponsor, c.objector)
    and not exists (select 1 from contest_entries e where e.contest_id = p_contest and e.uid = x.other)
  order by x.decided_at desc nulls last limit 1;
  update contests set objection = coalesce(nullif(left(btrim(coalesce(p_reason, '')), 280), ''), objection) where id = p_contest;
  if ref is null then
    perform _contest_void(p_contest, 'Hopeless: nobody outside the contest could referee, so it''s called off.');
  else
    update contests set stage = 'refereeing', stage_at = now(), referee = ref where id = p_contest;
  end if;
  return ref;
end $$;

create or replace function public.contest_referee_pick(p_contest uuid, p_stands boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c contests;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.referee <> auth.uid() or c.stage <> 'refereeing' then raise exception 'You''re not refereeing this one.'; end if;
  if p_stands then perform _contest_settle(p_contest, 'The referee said the result stands.');
  else perform _contest_void(p_contest, 'The referee called it off, so everyone''s refunded.'); end if;
end $$;

create or replace function public.contest_cancel(p_contest uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update contests set stage = 'canceled', stage_at = now() where id = p_contest and sponsor = auth.uid() and stage = 'open';
  if not found then raise exception 'Only the sponsor can cancel, and only before the result is in.'; end if;
end $$;

-- Every 10 minutes: move contests whose 24-hour clocks ran out.
create or replace function public.contest_tick()
returns int language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id, stage from contests where stage in ('recorded', 'proving', 'proof', 'refereeing') and stage_at <= now() - interval '24 hours' loop
    if c.stage in ('recorded', 'proof') then perform _contest_settle(c.id, null);
    elsif c.stage = 'proving' then perform _contest_void(c.id, 'No proof was posted in time, so it''s called off.');
    else perform _contest_void(c.id, 'Hopeless: the referee didn''t pick in time, so it''s called off.'); end if;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public._played_any(uuid, uuid[]), public.contest_can_see(uuid), public.create_contest(text, text[], boolean, int, int, timestamptz, text, uuid[]),
  public.contest_enter(uuid, text), public.contest_withdraw(uuid), public._contest_settle(uuid, text), public._contest_void(uuid, text),
  public.contest_record(uuid, text), public.contest_prove_it(uuid, text), public.contest_post_proof(uuid, text), public.contest_accept_proof(uuid),
  public.contest_doesnt_hold(uuid, text), public.contest_referee_pick(uuid, boolean), public.contest_cancel(uuid), public.contest_tick() from public, anon, authenticated;
grant execute on function public.contest_can_see(uuid), public.create_contest(text, text[], boolean, int, int, timestamptz, text, uuid[]),
  public.contest_enter(uuid, text), public.contest_withdraw(uuid), public.contest_record(uuid, text), public.contest_prove_it(uuid, text),
  public.contest_post_proof(uuid, text), public.contest_accept_proof(uuid), public.contest_doesnt_hold(uuid, text),
  public.contest_referee_pick(uuid, boolean), public.contest_cancel(uuid) to authenticated;
grant execute on function public.contest_tick(), public._contest_settle(uuid, text), public._contest_void(uuid, text) to service_role;

-- "Predictions and Counting!" counts calls people made, not points booked by pools, golf or contests.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null and wolf_round is null and contest_id is null
$$;

do $$ begin alter publication supabase_realtime add table public.contests; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.contest_entries; exception when duplicate_object then null; when undefined_object then null; end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-contests') where exists (select 1 from cron.job where jobname = 'handshake-contests');
  perform cron.schedule('handshake-contests', '*/10 * * * *', 'select public.contest_tick()');
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

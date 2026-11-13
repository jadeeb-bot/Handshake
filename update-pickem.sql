-- Handshake update: Pick 'em All! weekly NFL pools for groups.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-vegas-lines.sql first. Safe to run more than once. Fresh installs get the same
-- thing from schema.sql.
--
-- How it works:
--   * Anyone can start a group and name it. Others join with the group's invite code/link.
--   * Each week (Tuesday through Monday night, Pacific time) every member gets one entry:
--     a pick against the Vegas opening spread for every NFL game, plus a guess at the total
--     points in the week's last game (Monday night) as the tiebreaker.
--   * Each pick locks at that game's kickoff. Nobody can see anyone else's pick on a game
--     until it kicks off. A game that lands exactly on the spread counts for nobody.
--   * You're entered for the week once you make any pick. When the week's games are final,
--     grade_pickem() scores it: most right wins; tiebreaker is closest to the Monday night
--     total; still tied = co-winners. Each winner gets +5 for every losing entry and each
--     loser gets -5 for every winner (one winner: +5 per other entry, everyone else -5).
--   * Points are booked as finished predictions between each winner and each loser, so they
--     show up in Standings, Rivals balances, settle-up and the CSV like any other result.
--   * Group cards and standings are visible to everyone signed in (Full Monty).

-- Final scores on the Vegas lines (also in update-vegas-lines.sql).
alter table public.vegas_lines add column if not exists home_score int;
alter table public.vegas_lines add column if not exists away_score int;
alter table public.vegas_lines add column if not exists completed boolean not null default false;
alter table public.vegas_pulls add column if not exists kind text not null default 'lines';

create or replace function public.save_vegas_scores(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update vegas_lines v set home_score = (r->>'home_score')::int, away_score = (r->>'away_score')::int,
         completed = coalesce((r->>'completed')::boolean, false)
  from jsonb_array_elements(p_rows) r
  where v.id = r->>'id' and not v.completed;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.save_vegas_scores(jsonb) from public, anon, authenticated;
grant execute on function public.save_vegas_scores(jsonb) to service_role;

-- The NFL week a game belongs to: the Tuesday (Pacific) that starts it.
create or replace function public.nfl_week(ts timestamptz)
returns date language sql stable set search_path = public as $$
  select (date_trunc('week', (ts at time zone 'America/Los_Angeles') - interval '1 day') + interval '1 day')::date
$$;

-- The tiebreaker game: the week's last game with an over/under (Monday night).
create or replace function public.pickem_tb_game(p_week date)
returns text language sql stable security definer set search_path = public as $$
  select id from vegas_lines where nfl_week(starts_at) = p_week and total is not null
  order by starts_at desc, id limit 1
$$;

create table if not exists public.pickem_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 30),
  code        text not null unique,
  created_by  uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.pickem_members (
  group_id   uuid not null references public.pickem_groups (id) on delete cascade,
  uid        uuid not null references public.profiles (id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (group_id, uid)
);
create table if not exists public.pickem_picks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  game_id     text not null references public.vegas_lines (id) on delete cascade,
  side        text not null check (side in ('home', 'away')),
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, game_id)
);
create table if not exists public.pickem_tiebreaks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  week        date not null,
  guess       int not null check (guess between 0 and 200),
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
create table if not exists public.pickem_weeks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  week        date not null,
  entries     int not null,
  tb_total    int,
  graded_at   timestamptz not null default now(),
  primary key (group_id, week)
);
create table if not exists public.pickem_results (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  week        date not null,
  uid         uuid not null references public.profiles (id) on delete cascade,
  correct     int not null,
  tb_diff     int,
  won         boolean not null default false,
  points      int not null default 0,
  primary key (group_id, week, uid)
);

-- Points booked from a pool are marked so the app can keep them off the Everyone feed.
alter table public.predictions add column if not exists pickem_group uuid references public.pickem_groups (id) on delete set null;

alter table public.pickem_groups enable row level security;
alter table public.pickem_members enable row level security;
alter table public.pickem_picks enable row level security;
alter table public.pickem_tiebreaks enable row level security;
alter table public.pickem_weeks enable row level security;
alter table public.pickem_results enable row level security;

drop policy if exists "signed in can see groups" on public.pickem_groups;
create policy "signed in can see groups" on public.pickem_groups for select to authenticated using (true);
drop policy if exists "signed in can see members" on public.pickem_members;
create policy "signed in can see members" on public.pickem_members for select to authenticated using (true);
drop policy if exists "signed in can see weeks" on public.pickem_weeks;
create policy "signed in can see weeks" on public.pickem_weeks for select to authenticated using (true);
drop policy if exists "signed in can see results" on public.pickem_results;
create policy "signed in can see results" on public.pickem_results for select to authenticated using (true);
-- Your own picks always; everyone else's only once that game has kicked off.
drop policy if exists "picks after kickoff" on public.pickem_picks;
create policy "picks after kickoff" on public.pickem_picks for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = game_id and v.starts_at <= now()));
drop policy if exists "tiebreaks after kickoff" on public.pickem_tiebreaks;
create policy "tiebreaks after kickoff" on public.pickem_tiebreaks for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = public.pickem_tb_game(week) and v.starts_at <= now()));

-- The invite code is only for members. Everyone else reads groups without it.
revoke select on public.pickem_groups from authenticated;
grant select (id, name, created_by, created_at) on public.pickem_groups to authenticated;
grant select on public.pickem_members, public.pickem_picks, public.pickem_tiebreaks, public.pickem_weeks, public.pickem_results to authenticated;
grant all on public.pickem_groups, public.pickem_members, public.pickem_picks, public.pickem_tiebreaks, public.pickem_weeks, public.pickem_results to service_role;

-- Invite codes for the groups you're in.
create or replace function public.my_pickem_codes()
returns table (group_id uuid, code text) language sql stable security definer set search_path = public as $$
  select g.id, g.code from pickem_groups g join pickem_members m on m.group_id = g.id and m.uid = auth.uid()
$$;

create or replace function public.create_pickem_group(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid; c text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 30 then
    raise exception 'Give the group a name (up to 30 characters).'; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from pickem_groups where code = c);
  end loop;
  insert into pickem_groups (name, code, created_by) values (btrim(p_name), c, me) returning id into gid;
  insert into pickem_members (group_id, uid) values (gid, me);
  return gid;
end $$;

create or replace function public.join_pickem_group(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into gid from pickem_groups where code = upper(btrim(coalesce(p_code, '')));
  if gid is null then raise exception 'That invite code doesn''t match any group.'; end if;
  insert into pickem_members (group_id, uid) values (gid, me) on conflict do nothing;
  return gid;
end $$;

-- Pick a side (or p_side null to clear it). Locks at kickoff.
create or replace function public.save_pickem_pick(p_group uuid, p_game text, p_side text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null then raise exception 'That game has no line to pick against.'; end if;
  if g.starts_at <= now() then raise exception 'That game has kicked off. Picks are locked.'; end if;
  if p_side is null then
    delete from pickem_picks where group_id = p_group and uid = me and game_id = p_game;
  elsif p_side in ('home', 'away') then
    insert into pickem_picks (group_id, uid, game_id, side) values (p_group, me, p_game, p_side)
    on conflict (group_id, uid, game_id) do update set side = excluded.side, updated_at = now();
  else raise exception 'Pick home or away.'; end if;
end $$;

-- Tiebreaker: total points in the week's last game. Locks at that game's kickoff.
create or replace function public.save_pickem_tiebreak(p_group uuid, p_week date, p_guess int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); tb vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into tb from vegas_lines where id = pickem_tb_game(p_week);
  if not found then raise exception 'The tiebreaker game isn''t posted yet.'; end if;
  if tb.starts_at <= now() then raise exception 'The tiebreaker game has kicked off. It''s locked.'; end if;
  if p_guess is null then
    delete from pickem_tiebreaks where group_id = p_group and uid = me and week = p_week;
  elsif p_guess between 0 and 200 then
    insert into pickem_tiebreaks (group_id, uid, week, guess) values (p_group, me, p_week, p_guess)
    on conflict (group_id, uid, week) do update set guess = excluded.guess, updated_at = now();
  else raise exception 'Guess a total between 0 and 200.'; end if;
end $$;

-- Score every finished week that hasn't been scored yet. Runs hourly and after each scores pull.
create or replace function public.grade_pickem()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; w record; l record; grp pickem_groups; tbg vegas_lines;
  n int; nw int; nl int; done int := 0; tb_total int; best int; best_diff int; winners text; title text;
begin
  for r in
    select distinct x.group_id, x.week from (
      select p.group_id, nfl_week(v.starts_at) as week from pickem_picks p join vegas_lines v on v.id = p.game_id
      union select t.group_id, t.week from pickem_tiebreaks t) x
    where not exists (select 1 from pickem_weeks k where k.group_id = x.group_id and k.week = x.week)
      and now() >= x.week + 6                                    -- Monday of that week, at the earliest
      and not exists (select 1 from vegas_lines v                  -- every game final (or 3+ days stale)
                      where nfl_week(v.starts_at) = x.week and v.home_spread is not null
                        and not v.completed and v.starts_at > now() - interval '3 days')
  loop
    select * into grp from pickem_groups where id = r.group_id;
    select * into tbg from vegas_lines where id = pickem_tb_game(r.week);
    tb_total := case when tbg.completed then tbg.home_score + tbg.away_score end;

    insert into pickem_results (group_id, week, uid, correct, tb_diff)
    select r.group_id, r.week, e.uid,
      (select count(*) from pickem_picks p join vegas_lines v on v.id = p.game_id
        where p.group_id = r.group_id and p.uid = e.uid and nfl_week(v.starts_at) = r.week and v.completed
          and ((p.side = 'home' and v.home_score - v.away_score + v.home_spread > 0)
            or (p.side = 'away' and v.home_score - v.away_score + v.home_spread < 0))),
      (select abs(t.guess - tb_total) from pickem_tiebreaks t where t.group_id = r.group_id and t.uid = e.uid and t.week = r.week)
    from (select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id
           where p.group_id = r.group_id and nfl_week(v.starts_at) = r.week
          union select t.uid from pickem_tiebreaks t where t.group_id = r.group_id and t.week = r.week) e
    join pickem_members m on m.group_id = r.group_id and m.uid = e.uid
    on conflict do nothing;
    get diagnostics n = row_count;

    if n >= 2 then
      select max(correct) into best from pickem_results where group_id = r.group_id and week = r.week;
      select min(coalesce(tb_diff, 100000)) into best_diff from pickem_results where group_id = r.group_id and week = r.week and correct = best;
      update pickem_results set won = true
        where group_id = r.group_id and week = r.week and correct = best and coalesce(tb_diff, 100000) = best_diff;
      select count(*) filter (where won), count(*) filter (where not won) into nw, nl
        from pickem_results where group_id = r.group_id and week = r.week;
      if nl > 0 then
        update pickem_results set points = case when won then 5 * nl else -5 * nw end
          where group_id = r.group_id and week = r.week;
        select string_agg(pr.name, ' and ' order by pr.name) into winners
          from pickem_results x join profiles pr on pr.id = x.uid where x.group_id = r.group_id and x.week = r.week and x.won;
        title := left('Pick ''em All! · ' || grp.name || ' · week of ' || to_char(r.week, 'Mon FMDD'), 90);
        for w in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                 where x.group_id = r.group_id and x.week = r.week and x.won loop
          for l in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                   where x.group_id = r.group_id and x.week = r.week and not x.won loop
            insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                                     status, winner, visibility, auto_notified, decided_at, pickem_group, log)
            values (title, 'Pick ''em', 'points', 5, r.week + 6,
                    left(winners || ' won the week with ' || best || ' right' || case when best_diff < 100000 and tb_total is not null then ' (tiebreaker off by ' || best_diff || ')' else '' end || '. ' || n || ' entries.', 240),
                    w.uid, w.name, l.uid, l.name, l.uid, 'settled', 'a', 'pair', true, now(), r.group_id,
                    jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake',
                      'what', 'pick ''em All! week counted: ' || winners || ' won (' || grp.name || ')')));
          end loop;
        end loop;
      end if;
    end if;

    insert into pickem_weeks (group_id, week, entries, tb_total) values (r.group_id, r.week, n, tb_total);
    done := done + 1;
  end loop;
  return done;
end $$;

revoke all on function public.my_pickem_codes(), public.create_pickem_group(text), public.join_pickem_group(text),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int), public.grade_pickem(),
  public.pickem_tb_game(date) from public, anon;
grant execute on function public.my_pickem_codes(), public.create_pickem_group(text), public.join_pickem_group(text),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int), public.pickem_tb_game(date) to authenticated;
grant execute on function public.grade_pickem() to service_role;
grant execute on function public.nfl_week(timestamptz) to authenticated, service_role;

-- "Predictions and Counting!" counts calls people made, not points booked by a pool.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null
$$;

-- Check for finished weeks every hour, and call the lines/scores puller every hour.
-- (The puller itself only pulls lines once a day and scores only while games are in progress.)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-pickem-grade') where exists (select 1 from cron.job where jobname = 'handshake-pickem-grade');
  perform cron.schedule('handshake-pickem-grade', '7 * * * *', 'select public.grade_pickem()');
  perform cron.unschedule('handshake-vegas-lines') where exists (select 1 from cron.job where jobname = 'handshake-vegas-lines');
  perform cron.schedule('handshake-vegas-lines', '0 * * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/vegas-lines',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

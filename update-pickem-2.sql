-- Handshake update: Pick 'em All! crash requests, bonus game, and rollovers.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-pickem.sql first. Safe to run more than once. Fresh installs get the same thing
-- from schema.sql.
--
--   * Can I Crash?: anyone who isn't in a group can ask to crash it. The group's creator lets
--     them in or says no. (The crash-request notifications are sent by the notify function.)
--   * Bonus game: each entry can star one game a week. Getting it right counts double. It
--     locks when that game kicks off, and nobody sees anyone's bonus game until then.
--   * Half right or it rolls over: the week's winner must get at least half of the week's
--     games right (games that landed on the number don't count either way). Otherwise no
--     points move and every entry's 5-point ante rolls over. The next week someone wins, each
--     rolled ante is paid to each winner on top of that week's pot (a winner's own rolled
--     antes just come back to them).
--   * Group standings now come from pickem_ledger (one row per person per week that moved
--     points), so rolled antes paid later count too.

-- Bonus game picks
create table if not exists public.pickem_bonus (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  week        date not null,
  game_id     text not null references public.vegas_lines (id) on delete cascade,
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
-- Crash requests
create table if not exists public.pickem_crash_requests (
  group_id     uuid not null references public.pickem_groups (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (group_id, uid)
);
-- Points moved per person per week (what the group card adds up)
create table if not exists public.pickem_ledger (
  group_id  uuid not null references public.pickem_groups (id) on delete cascade,
  week      date not null,
  uid       uuid not null references public.profiles (id) on delete cascade,
  points    int not null,
  primary key (group_id, week, uid)
);
-- Antes waiting in a rolled-over pot (paid_week is set once someone wins)
create table if not exists public.pickem_carry (
  group_id   uuid not null references public.pickem_groups (id) on delete cascade,
  week       date not null,
  uid        uuid not null references public.profiles (id) on delete cascade,
  paid_week  date,
  primary key (group_id, week, uid)
);

alter table public.pickem_results add column if not exists score int not null default 0;
alter table public.pickem_results add column if not exists bonus_right boolean not null default false;
alter table public.pickem_weeks add column if not exists games int;
alter table public.pickem_weeks add column if not exists best int;
alter table public.pickem_weeks add column if not exists rolled boolean not null default false;
alter table public.pickem_weeks add column if not exists pot int not null default 0;

-- Weeks scored before this update: copy their points into the ledger.
update public.pickem_results set score = correct where score = 0 and correct > 0;
insert into public.pickem_ledger (group_id, week, uid, points)
select group_id, week, uid, points from public.pickem_results where points <> 0
on conflict do nothing;

alter table public.pickem_bonus enable row level security;
alter table public.pickem_crash_requests enable row level security;
alter table public.pickem_ledger enable row level security;
alter table public.pickem_carry enable row level security;

drop policy if exists "bonus after kickoff" on public.pickem_bonus;
create policy "bonus after kickoff" on public.pickem_bonus for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = game_id and v.starts_at <= now()));
drop policy if exists "own or my group's requests" on public.pickem_crash_requests;
create policy "own or my group's requests" on public.pickem_crash_requests for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.pickem_groups g where g.id = group_id and g.created_by = auth.uid()));
drop policy if exists "signed in can see ledger" on public.pickem_ledger;
create policy "signed in can see ledger" on public.pickem_ledger for select to authenticated using (true);
drop policy if exists "signed in can see carry" on public.pickem_carry;
create policy "signed in can see carry" on public.pickem_carry for select to authenticated using (true);

grant select on public.pickem_bonus, public.pickem_crash_requests, public.pickem_ledger, public.pickem_carry to authenticated;
grant all on public.pickem_bonus, public.pickem_crash_requests, public.pickem_ledger, public.pickem_carry to service_role;

-- Star one game as your bonus for its week (p_game null clears it). Locks at kickoff.
create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines; cur text;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select b.game_id into cur from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week;
  if cur is not null and exists (select 1 from vegas_lines where id = cur and starts_at <= now()) then
    raise exception 'Your bonus game has kicked off. It''s locked.'; end if;
  if p_game is null then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week;
    return;
  end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null or nfl_week(g.starts_at) <> p_week then raise exception 'That game isn''t in this week''s pool.'; end if;
  if g.starts_at <= now() then raise exception 'That game has kicked off. Pick another bonus game.'; end if;
  insert into pickem_bonus (group_id, uid, week, game_id) values (p_group, me, p_week, p_game)
  on conflict (group_id, uid, week) do update set game_id = excluded.game_id, updated_at = now();
end $$;

-- Ask to crash a group you're not in.
create or replace function public.request_pickem_crash(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from pickem_groups where id = p_group) then raise exception 'That group is gone.'; end if;
  if exists (select 1 from pickem_members where group_id = p_group and uid = me) then raise exception 'You''re already in this group.'; end if;
  insert into pickem_crash_requests (group_id, uid) values (p_group, me)
  on conflict (group_id, uid) do update set status = 'pending', created_at = now(), answered_at = null;
end $$;

-- The group's creator lets them in (or not).
create or replace function public.answer_pickem_crash(p_group uuid, p_uid uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pickem_groups where id = p_group and created_by = auth.uid()) then
    raise exception 'Only the person who started the group can answer.'; end if;
  update pickem_crash_requests set status = case when p_accept then 'accepted' else 'declined' end, answered_at = now()
  where group_id = p_group and uid = p_uid and status = 'pending';
  if not found then raise exception 'That request was already answered.'; end if;
  if p_accept then insert into pickem_members (group_id, uid) values (p_group, p_uid) on conflict do nothing; end if;
end $$;

-- Joining with the code also clears any open crash request.
create or replace function public.join_pickem_group(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into gid from pickem_groups where code = upper(btrim(coalesce(p_code, '')));
  if gid is null then raise exception 'That invite code doesn''t match any group.'; end if;
  insert into pickem_members (group_id, uid) values (gid, me) on conflict do nothing;
  update pickem_crash_requests set status = 'accepted', answered_at = now() where group_id = gid and uid = me and status = 'pending';
  return gid;
end $$;

-- Score every finished week that hasn't been scored yet. Runs hourly and after each scores pull.
create or replace function public.grade_pickem()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; w record; l record; grp pickem_groups; tbg vegas_lines;
  n int; nw int; nl int; done int := 0; tb_total int; best int; best_diff int; games int;
  winners text; title text; pts int; carried int; pot int;
begin
  for r in
    select distinct x.group_id, x.week from (
      select p.group_id, nfl_week(v.starts_at) as week from pickem_picks p join vegas_lines v on v.id = p.game_id
      union select t.group_id, t.week from pickem_tiebreaks t
      union select b.group_id, b.week from pickem_bonus b) x
    where not exists (select 1 from pickem_weeks k where k.group_id = x.group_id and k.week = x.week)
      and now() >= x.week + 6                                    -- Monday of that week, at the earliest
      and not exists (select 1 from vegas_lines v                  -- every game final (or 3+ days stale)
                      where nfl_week(v.starts_at) = x.week and v.home_spread is not null
                        and not v.completed and v.starts_at > now() - interval '3 days')
    order by x.week
  loop
    select * into grp from pickem_groups where id = r.group_id;
    select * into tbg from vegas_lines where id = pickem_tb_game(r.week);
    tb_total := case when tbg.completed then tbg.home_score + tbg.away_score end;
    -- games that count toward "half right": final and not on the number
    select count(*) into games from vegas_lines v
     where nfl_week(v.starts_at) = r.week and v.home_spread is not null and v.completed
       and v.home_score - v.away_score + v.home_spread <> 0;

    insert into pickem_results (group_id, week, uid, correct, bonus_right, score, tb_diff)
    select r.group_id, r.week, e.uid, c.correct, c.bonus_right, c.correct + c.bonus_right::int,
      (select abs(t.guess - tb_total) from pickem_tiebreaks t where t.group_id = r.group_id and t.uid = e.uid and t.week = r.week)
    from (select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id
           where p.group_id = r.group_id and nfl_week(v.starts_at) = r.week
          union select t.uid from pickem_tiebreaks t where t.group_id = r.group_id and t.week = r.week
          union select b.uid from pickem_bonus b where b.group_id = r.group_id and b.week = r.week) e
    join pickem_members m on m.group_id = r.group_id and m.uid = e.uid
    cross join lateral (
      select count(*)::int as correct, coalesce(bool_or(p.game_id = bo.game_id), false) as bonus_right
      from pickem_picks p join vegas_lines v on v.id = p.game_id
      left join pickem_bonus bo on bo.group_id = p.group_id and bo.uid = p.uid and bo.week = r.week
      where p.group_id = r.group_id and p.uid = e.uid and nfl_week(v.starts_at) = r.week and v.completed
        and ((p.side = 'home' and v.home_score - v.away_score + v.home_spread > 0)
          or (p.side = 'away' and v.home_score - v.away_score + v.home_spread < 0))) c
    on conflict do nothing;
    get diagnostics n = row_count;
    pot := 0; best := null;

    if n >= 2 then
      select max(score) into best from pickem_results where group_id = r.group_id and week = r.week;
      select min(coalesce(tb_diff, 100000)) into best_diff from pickem_results where group_id = r.group_id and week = r.week and score = best;
      -- winners: top score, closest tiebreaker, and at least half the games right
      update pickem_results set won = true
        where group_id = r.group_id and week = r.week and score = best and coalesce(tb_diff, 100000) = best_diff
          and correct * 2 >= games;
      select count(*) filter (where won), count(*) filter (where not won) into nw, nl
        from pickem_results where group_id = r.group_id and week = r.week;

      if nw = 0 then
        -- nobody got half right: every entry's ante rolls over
        insert into pickem_carry (group_id, week, uid)
        select group_id, week, uid from pickem_results where group_id = r.group_id and week = r.week
        on conflict do nothing;
        insert into pickem_weeks (group_id, week, entries, tb_total, games, best, rolled)
        values (r.group_id, r.week, n, tb_total, games, best, true);
        done := done + 1;
        continue;
      end if;

      if nl > 0 or exists (select 1 from pickem_carry where group_id = r.group_id and paid_week is null) then
        select string_agg(pr.name, ' and ' order by pr.name) into winners
          from pickem_results x join profiles pr on pr.id = x.uid where x.group_id = r.group_id and x.week = r.week and x.won;
        title := left('Pick ''em All! · ' || grp.name || ' · week of ' || to_char(r.week, 'Mon FMDD'), 90);
        -- everyone who owes: this week's losers, plus rolled antes from anyone who isn't a winner now
        for l in
          select o.uid, pr.name, sum(o.antes)::int as antes, sum(o.rolled)::int as rolled from (
            select x.uid, 1 as antes, 0 as rolled from pickem_results x where x.group_id = r.group_id and x.week = r.week and not x.won
            union all
            select c.uid, 1, 1 from pickem_carry c where c.group_id = r.group_id and c.paid_week is null
              and not exists (select 1 from pickem_results x where x.group_id = r.group_id and x.week = r.week and x.uid = c.uid and x.won)
          ) o join profiles pr on pr.id = o.uid group by o.uid, pr.name
        loop
          pts := 5 * l.antes;
          for w in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                   where x.group_id = r.group_id and x.week = r.week and x.won loop
            insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                                     status, winner, visibility, auto_notified, decided_at, pickem_group, log)
            values (title, 'Pick ''em', 'points', pts, r.week + 6,
                    left(winners || ' won the week: ' || best || ' right counting the bonus game, out of ' || games || ' games (' || n || ' entries)'
                         || case when l.rolled > 0 then '. Includes ' || 5 * l.rolled || ' pts rolled over from earlier weeks' else '' end || '.', 240),
                    w.uid, w.name, l.uid, l.name, l.uid, 'settled', 'a', 'pair', true, now(), r.group_id,
                    jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake',
                      'what', 'pick ''em All! week counted: ' || winners || ' won (' || grp.name || ')')));
            insert into pickem_ledger (group_id, week, uid, points) values (r.group_id, r.week, w.uid, pts)
              on conflict (group_id, week, uid) do update set points = pickem_ledger.points + excluded.points;
            insert into pickem_ledger (group_id, week, uid, points) values (r.group_id, r.week, l.uid, -pts)
              on conflict (group_id, week, uid) do update set points = pickem_ledger.points + excluded.points;
            pot := pot + pts;
          end loop;
        end loop;
        update pickem_carry set paid_week = r.week where group_id = r.group_id and paid_week is null;
        update pickem_results x set points = coalesce((select g.points from pickem_ledger g
                 where g.group_id = x.group_id and g.week = x.week and g.uid = x.uid), 0)
          where x.group_id = r.group_id and x.week = r.week;
      end if;
    end if;

    insert into pickem_weeks (group_id, week, entries, tb_total, games, best, pot) values (r.group_id, r.week, n, tb_total, games, best, pot);
    done := done + 1;
  end loop;
  return done;
end $$;

revoke all on function public.save_pickem_bonus(uuid, date, text), public.request_pickem_crash(uuid),
  public.answer_pickem_crash(uuid, uuid, boolean), public.join_pickem_group(text), public.grade_pickem() from public, anon;
grant execute on function public.save_pickem_bonus(uuid, date, text), public.request_pickem_crash(uuid),
  public.answer_pickem_crash(uuid, uuid, boolean), public.join_pickem_group(text) to authenticated;
grant execute on function public.grade_pickem() to service_role;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: Pick 'em All! 3-point and 2-point picks (Nov 17).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Safe to run more than once.
--
-- Replaces the single bonus game (worth 2) with two weighted picks each week:
--   * one 3-POINT PICK (a game you get right counts as 3 wins) and one 2-POINT PICK (counts as 2),
--     on two different games. Every other game you get right counts as 1.
--   * Submit needs both chosen (plus every open game and the tiebreaker, as before).
--   * They lock like the old bonus game: a choice can't move once its game (or the week) locks.
--   * The .500 rule still counts games right only.
-- Starts with the week of Nov 17: a bonus game already chosen this week becomes the 2-point pick.

alter table public.pickem_bonus add column if not exists weight int not null default 2;
alter table public.pickem_bonus drop constraint if exists pickem_bonus_weight_check;
alter table public.pickem_bonus add constraint pickem_bonus_weight_check check (weight in (2, 3));
alter table public.pickem_bonus drop constraint if exists pickem_bonus_pkey;
alter table public.pickem_bonus add constraint pickem_bonus_pkey primary key (group_id, uid, week, weight);
alter table public.pickem_bonus drop constraint if exists pickem_bonus_one_game;
alter table public.pickem_bonus add constraint pickem_bonus_one_game unique (group_id, uid, week, game_id);
alter table public.pickem_results add column if not exists bonus_extra int not null default 0;
update public.pickem_results set bonus_extra = 1 where bonus_right and bonus_extra = 0;

-- Choose (or clear) your 3-point or 2-point pick. Choosing the game that holds your other weighted
-- pick moves it here.
create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text, p_weight int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines; cur text; other text;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  if p_weight not in (2, 3) then raise exception 'Pick a 3-point or a 2-point game.'; end if;
  select b.game_id into cur from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week and b.weight = p_weight;
  if cur is not null and pickem_lock_at(cur) <= now() then raise exception 'Your %-point pick is locked.', p_weight; end if;
  if p_game is null then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week and weight = p_weight;
    return;
  end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null or nfl_week(g.starts_at) <> p_week then raise exception 'That game isn''t in this week''s pool.'; end if;
  if pickem_lock_at(p_game) <= now() then raise exception 'That game is locked. Pick another game for your %-point pick.', p_weight; end if;
  select b.game_id into other from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week and b.weight <> p_weight;
  if other = p_game then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week and weight <> p_weight;
  end if;
  insert into pickem_bonus (group_id, uid, week, game_id, weight) values (p_group, me, p_week, p_game, p_weight)
  on conflict (group_id, uid, week, weight) do update set game_id = excluded.game_id, updated_at = now();
end $$;
-- older app builds: the old "bonus game" is the 2-point pick
create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text)
returns void language sql security definer set search_path = public as $$
  select public.save_pickem_bonus(p_group, p_week, p_game, 2)
$$;

-- Submit: every open game picked, the tiebreaker, and both the 3-point and 2-point picks.
create or replace function public.submit_pickem_week(p_group uuid, p_week date)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); missing int; t timestamptz; w int;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  if not exists (select 1 from vegas_lines where nfl_week(starts_at) = p_week and home_spread is not null) then
    raise exception 'There are no games for that week yet.'; end if;
  if not exists (select 1 from vegas_lines v where nfl_week(v.starts_at) = p_week and v.home_spread is not null
                 and pickem_lock_at(v.id) > now()) then
    raise exception 'This week''s picks are already locked.'; end if;
  select count(*) into missing from vegas_lines v
   where nfl_week(v.starts_at) = p_week and v.home_spread is not null and pickem_lock_at(v.id) > now()
     and not exists (select 1 from pickem_picks p where p.group_id = p_group and p.uid = me and p.game_id = v.id);
  if missing > 0 then raise exception 'Pick every game first (% still open without a pick).', missing; end if;
  if pickem_tb_lock(p_week) > now() and not exists
     (select 1 from pickem_tiebreaks t where t.group_id = p_group and t.uid = me and t.week = p_week) then
    raise exception 'Add your tiebreaker first.'; end if;
  foreach w in array array[3, 2] loop
    if not exists (select 1 from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week and b.weight = w) then
      raise exception 'Choose your %-point pick first.', w; end if;
  end loop;
  insert into pickem_submissions (group_id, uid, week) values (p_group, me, p_week)
  on conflict (group_id, uid, week) do update set submitted_at = now()
  returning submitted_at into t;
  return t;
end $$;

-- Scoring: games right, plus 2 extra for the 3-point pick and 1 extra for the 2-point pick when right.
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

    insert into pickem_results (group_id, week, uid, correct, bonus_right, bonus_extra, score, tb_diff)
    select r.group_id, r.week, e.uid, c.correct, c.bonus_right, c.extra, c.correct + c.extra,
      (select abs(t.guess - tb_total) from pickem_tiebreaks t where t.group_id = r.group_id and t.uid = e.uid and t.week = r.week)
    from (select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id
           where p.group_id = r.group_id and nfl_week(v.starts_at) = r.week
          union select t.uid from pickem_tiebreaks t where t.group_id = r.group_id and t.week = r.week
          union select b.uid from pickem_bonus b where b.group_id = r.group_id and b.week = r.week) e
    join pickem_members m on m.group_id = r.group_id and m.uid = e.uid
    cross join lateral (
      select count(*)::int as correct, coalesce(sum(bo.weight - 1), 0)::int as extra, count(bo.weight) > 0 as bonus_right
      from pickem_picks p join vegas_lines v on v.id = p.game_id
      left join pickem_bonus bo on bo.group_id = p.group_id and bo.uid = p.uid and bo.week = r.week and bo.game_id = p.game_id
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
                    left(winners || ' won the week: ' || best || ' wins counting the 3- and 2-point picks, out of ' || games || ' games (' || n || ' entries)'
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

revoke all on function public.save_pickem_bonus(uuid, date, text, int), public.save_pickem_bonus(uuid, date, text),
  public.submit_pickem_week(uuid, date), public.grade_pickem() from public, anon;
grant execute on function public.save_pickem_bonus(uuid, date, text, int), public.save_pickem_bonus(uuid, date, text),
  public.submit_pickem_week(uuid, date) to authenticated;
grant execute on function public.grade_pickem() to service_role;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: Pick 'em All! Submit button, "Picks in", and the Sunday lock.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-pickem-2.sql first. Safe to run more than once. Fresh installs get the same thing
-- from schema.sql.
--
--   * Sunday lock: games before Sunday (Thursday night, etc.) still lock at their own kickoff.
--     Every other game, the tiebreaker and the bonus game lock at the week's first Sunday
--     kickoff. (A week with no Sunday games falls back to each game's own kickoff.)
--     Other people's picks show once a pick locks.
--   * Submit: once every game that's still open is picked and the tiebreaker is in, a member
--     can submit their picks for the week. Picks can still be changed after submitting, until
--     they lock. Group cards show a check mark under "Picks in" for everyone who submitted.

-- The week's first Sunday kickoff (Pacific), or null if the week has no Sunday games.
create or replace function public.pickem_week_lock(p_week date)
returns timestamptz language sql stable security definer set search_path = public as $$
  select min(starts_at) from vegas_lines
  where nfl_week(starts_at) = p_week and home_spread is not null
    and extract(dow from starts_at at time zone 'America/Los_Angeles') = 0
$$;

-- When a game's pick locks: its kickoff, or the first Sunday kickoff if that comes first.
create or replace function public.pickem_lock_at(p_game text)
returns timestamptz language sql stable security definer set search_path = public as $$
  select least(v.starts_at, coalesce(pickem_week_lock(nfl_week(v.starts_at)), v.starts_at))
  from vegas_lines v where v.id = p_game
$$;

-- When the tiebreaker locks: the first Sunday kickoff, or the tiebreaker game's own kickoff.
create or replace function public.pickem_tb_lock(p_week date)
returns timestamptz language sql stable security definer set search_path = public as $$
  select pickem_lock_at(pickem_tb_game(p_week))
$$;

create table if not exists public.pickem_submissions (
  group_id      uuid not null references public.pickem_groups (id) on delete cascade,
  uid           uuid not null references public.profiles (id) on delete cascade,
  week          date not null,
  submitted_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
alter table public.pickem_submissions enable row level security;
drop policy if exists "signed in can see submissions" on public.pickem_submissions;
create policy "signed in can see submissions" on public.pickem_submissions for select to authenticated using (true);
grant select on public.pickem_submissions to authenticated;
grant all on public.pickem_submissions to service_role;

-- Others' picks, tiebreakers and bonus games show once they lock.
drop policy if exists "picks after kickoff" on public.pickem_picks;
create policy "picks after kickoff" on public.pickem_picks for select to authenticated using (
  uid = auth.uid() or public.pickem_lock_at(game_id) <= now());
drop policy if exists "tiebreaks after kickoff" on public.pickem_tiebreaks;
create policy "tiebreaks after kickoff" on public.pickem_tiebreaks for select to authenticated using (
  uid = auth.uid() or public.pickem_tb_lock(week) <= now());
drop policy if exists "bonus after kickoff" on public.pickem_bonus;
create policy "bonus after kickoff" on public.pickem_bonus for select to authenticated using (
  uid = auth.uid() or public.pickem_lock_at(game_id) <= now()
  or coalesce(public.pickem_week_lock(week) <= now(), false));

create or replace function public.save_pickem_pick(p_group uuid, p_game text, p_side text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null then raise exception 'That game has no line to pick against.'; end if;
  if pickem_lock_at(p_game) <= now() then raise exception 'That pick is locked.'; end if;
  if p_side is null then
    delete from pickem_picks where group_id = p_group and uid = me and game_id = p_game;
  elsif p_side in ('home', 'away') then
    insert into pickem_picks (group_id, uid, game_id, side) values (p_group, me, p_game, p_side)
    on conflict (group_id, uid, game_id) do update set side = excluded.side, updated_at = now();
  else raise exception 'Pick home or away.'; end if;
end $$;

create or replace function public.save_pickem_tiebreak(p_group uuid, p_week date, p_guess int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  if pickem_tb_game(p_week) is null then raise exception 'The tiebreaker game isn''t posted yet.'; end if;
  if pickem_tb_lock(p_week) <= now() then raise exception 'The tiebreaker is locked.'; end if;
  if p_guess is null then
    delete from pickem_tiebreaks where group_id = p_group and uid = me and week = p_week;
  elsif p_guess between 0 and 200 then
    insert into pickem_tiebreaks (group_id, uid, week, guess) values (p_group, me, p_week, p_guess)
    on conflict (group_id, uid, week) do update set guess = excluded.guess, updated_at = now();
  else raise exception 'Guess a total between 0 and 200.'; end if;
end $$;

create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines; cur text;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select b.game_id into cur from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week;
  if cur is not null and pickem_lock_at(cur) <= now() then raise exception 'Your bonus game is locked.'; end if;
  if p_game is null then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week;
    return;
  end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null or nfl_week(g.starts_at) <> p_week then raise exception 'That game isn''t in this week''s pool.'; end if;
  if pickem_lock_at(p_game) <= now() then raise exception 'That game is locked. Pick another bonus game.'; end if;
  insert into pickem_bonus (group_id, uid, week, game_id) values (p_group, me, p_week, p_game)
  on conflict (group_id, uid, week) do update set game_id = excluded.game_id, updated_at = now();
end $$;

-- Submit your picks for the week: every game that's still open picked, plus the tiebreaker.
create or replace function public.submit_pickem_week(p_group uuid, p_week date)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); missing int; t timestamptz;
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
  insert into pickem_submissions (group_id, uid, week) values (p_group, me, p_week)
  on conflict (group_id, uid, week) do update set submitted_at = now()
  returning submitted_at into t;
  return t;
end $$;

revoke all on function public.pickem_week_lock(date), public.pickem_lock_at(text), public.pickem_tb_lock(date),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int),
  public.save_pickem_bonus(uuid, date, text), public.submit_pickem_week(uuid, date) from public, anon;
grant execute on function public.pickem_week_lock(date), public.pickem_lock_at(text), public.pickem_tb_lock(date),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int),
  public.save_pickem_bonus(uuid, date, text), public.submit_pickem_week(uuid, date) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

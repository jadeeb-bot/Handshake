-- Handshake update: Squares games from the NFL schedule, any week ahead (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run update-squares.sql first.
-- Safe to run more than once.
--
-- Squares used to offer only games with Vegas lines (about a week out). Now the Start a pool form
-- has a week picker, and games come from ESPN's NFL schedule (the squares function fetches the
-- week and saves it in nfl_schedule), so a pool can be set up weeks ahead (Thanksgiving, etc.).
-- Each pool game keeps its own teams and kickoff, so it no longer depends on vegas_lines.

create table if not exists public.nfl_schedule (
  id          text primary key,            -- ESPN's event id
  starts_at   timestamptz not null,
  home        text not null,
  away        text not null,
  updated_at  timestamptz not null default now()
);
create index if not exists nfl_schedule_starts on public.nfl_schedule (starts_at);
alter table public.nfl_schedule enable row level security;
drop policy if exists "signed in can see" on public.nfl_schedule;
create policy "signed in can see" on public.nfl_schedule for select to authenticated using (true);
grant select on public.nfl_schedule to authenticated;
grant all on public.nfl_schedule to service_role;

-- Pool games carry their own teams and kickoff now (ESPN event ids for new pools).
alter table public.squares_games drop constraint if exists squares_games_game_id_fkey;
alter table public.squares_results drop constraint if exists squares_results_game_id_fkey;
alter table public.squares_games add column if not exists starts_at timestamptz;
alter table public.squares_games add column if not exists home text;
alter table public.squares_games add column if not exists away text;
update public.squares_games g set starts_at = v.starts_at, home = v.home, away = v.away
from public.vegas_lines v where v.id = g.game_id and g.starts_at is null;

create or replace function public.create_squares(p_title text, p_price int, p_games jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; g jsonb; s nfl_schedule; total numeric := 0; n int := 0; u uuid; pc numeric[];
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Name the pool (up to 60 characters).'; end if;
  if p_price is null or p_price not between 1 and 1000 then raise exception 'Points per square go from 1 to 1000.'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then raise exception 'Pick at least one game.'; end if;
  if jsonb_array_length(p_games) > 8 then raise exception 'Up to 8 games.'; end if;
  insert into squares_pools (title, originator, price) values (btrim(p_title), me, p_price) returning id into pid;
  for g in select * from jsonb_array_elements(p_games) loop
    select * into s from nfl_schedule where id = g->>'game_id';
    if not found then raise exception 'One of those games isn''t on the schedule. Pick the week again.'; end if;
    if s.starts_at <= now() then raise exception 'One of those games has already started.'; end if;
    pc := array(select (x)::numeric from jsonb_array_elements_text(g->'pct') x);
    if cardinality(pc) <> 4 or exists (select 1 from unnest(pc) x where x < 0 or x > 100) then raise exception 'Give four payout percentages per game.'; end if;
    total := total + (select sum(x) from unnest(pc) x);
    insert into squares_games (pool_id, game_id, ord, pct, starts_at, home, away) values (pid, s.id, n, pc, s.starts_at, s.home, s.away);
    n := n + 1;
  end loop;
  if abs(total - 100) > 0.1 then raise exception '%', format('Payouts have to add up to 100%% of the pot (they add up to %s%%).', round(total, 2)); end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into squares_invitees values (pid, u) on conflict do nothing; end if;
  end loop;
  return pid;
end $$;

create or replace function public.squares_tick()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- keep kickoff times current (the schedule can flex)
  update squares_games g set starts_at = s.starts_at from nfl_schedule s
  where s.id = g.game_id and s.starts_at <> g.starts_at
    and exists (select 1 from squares_pools sp where sp.id = g.pool_id and sp.status in ('open', 'drawn'));
  for r in select sp.id from squares_pools sp where sp.status = 'open'
           and (select min(g.starts_at) from squares_games g where g.pool_id = sp.id) <= now() loop
    perform _squares_draw(r.id); n := n + 1;
  end loop;
  return n;
end $$;

drop function if exists public.squares_pending_games();
create function public.squares_pending_games()
returns table (pool_id uuid, game_id text, home text, away text, starts_at timestamptz, have int)
language sql stable security definer set search_path = public as $$
  select g.pool_id, g.game_id, g.home, g.away, g.starts_at,
    (select count(*)::int from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id)
  from squares_games g join squares_pools p on p.id = g.pool_id
  where p.status = 'drawn' and g.starts_at <= now() and g.starts_at > now() - interval '18 hours'
    and (select count(*) from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id) < 4
$$;
revoke all on function public.squares_pending_games() from public, anon, authenticated;
grant execute on function public.squares_pending_games() to service_role;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

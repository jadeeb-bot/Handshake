-- Handshake update: Squares (football squares pools).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-vegas-lines.sql first (games come from the Vegas lines). Safe to run more than once.
--
-- How it works (decided Nov 14):
--   * A 10x10 grid, squares numbered 1-100 (square = row*10 + column + 1). Columns = home team,
--     rows = visiting team.
--   * The originator picks one or more NFL games (from the Vegas lines), the points per square,
--     the payout per quarter as a percent of the pot (100 squares x price; per game if several),
--     and invitees. Anyone can see a pool; people who aren't invited can ask to crash, and the
--     originator lets them in.
--   * Players claim any open squares (and can release theirs) until the numbers are drawn.
--   * Numbers 0-9 are drawn at random for the columns and rows when the last square is claimed,
--     when the originator taps Draw numbers, or automatically at the first kickoff. Any unsold
--     squares then belong to the originator.
--   * After each quarter the squares function records the score (from ESPN) and the winner: the
--     square where the last digit of the home score (column) meets the last digit of the visiting
--     score (row). Q4 uses the final score, overtime included. The originator can fix a score.
--     Everyone in the pool gets a notification with the score, winner and points.
--   * Separate, like golf: nothing goes into Standings or Rivals. The originator tracks who's paid
--     their buy-in (squares x price).

create table if not exists public.squares_pools (
  id               uuid primary key default gen_random_uuid(),
  title            text not null check (char_length(btrim(title)) between 1 and 60),
  originator       uuid not null references public.profiles (id) on delete cascade,
  price            int not null check (price between 1 and 1000),
  status           text not null default 'open' check (status in ('open', 'drawn', 'done', 'canceled')),
  digits_home      int[],            -- column c shows digits_home[c+1]
  digits_away      int[],            -- row r shows digits_away[r+1]
  drawn_at         timestamptz,
  draw_notified_at timestamptz,
  created_at       timestamptz not null default now()
);
create table if not exists public.squares_games (
  pool_id   uuid not null references public.squares_pools (id) on delete cascade,
  game_id   text not null references public.vegas_lines (id) on delete cascade,
  ord       int not null default 0,
  pct       numeric(6, 2)[] not null check (cardinality(pct) = 4),   -- Q1, Q2, Q3, Final
  primary key (pool_id, game_id)
);
create table if not exists public.squares_invitees (
  pool_id  uuid not null references public.squares_pools (id) on delete cascade,
  uid      uuid not null references public.profiles (id) on delete cascade,
  primary key (pool_id, uid)
);
create table if not exists public.squares_crash (
  pool_id      uuid not null references public.squares_pools (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (pool_id, uid)
);
create table if not exists public.squares_claims (
  pool_id     uuid not null references public.squares_pools (id) on delete cascade,
  square      int not null check (square between 1 and 100),
  uid         uuid not null references public.profiles (id) on delete cascade,
  unsold      boolean not null default false,   -- given to the originator at the draw
  claimed_at  timestamptz not null default now(),
  primary key (pool_id, square)
);
create table if not exists public.squares_paid (
  pool_id  uuid not null references public.squares_pools (id) on delete cascade,
  uid      uuid not null references public.profiles (id) on delete cascade,
  paid_at  timestamptz not null default now(),
  primary key (pool_id, uid)
);
create table if not exists public.squares_results (
  pool_id      uuid not null references public.squares_pools (id) on delete cascade,
  game_id      text not null references public.vegas_lines (id) on delete cascade,
  quarter      int not null check (quarter between 1 and 4),
  home         int not null check (home >= 0),
  away         int not null check (away >= 0),
  square       int not null,
  uid          uuid references public.profiles (id) on delete set null,
  points       int not null,
  source       text not null default 'auto' check (source in ('auto', 'manual')),
  recorded_at  timestamptz not null default now(),
  notified_at  timestamptz,
  primary key (pool_id, game_id, quarter)
);

alter table public.squares_pools enable row level security;
alter table public.squares_games enable row level security;
alter table public.squares_invitees enable row level security;
alter table public.squares_crash enable row level security;
alter table public.squares_claims enable row level security;
alter table public.squares_paid enable row level security;
alter table public.squares_results enable row level security;
do $$
declare t text;
begin
  foreach t in array array['squares_pools', 'squares_games', 'squares_invitees', 'squares_claims', 'squares_results'] loop
    execute format('drop policy if exists "signed in can see" on public.%I', t);
    execute format('create policy "signed in can see" on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;
drop policy if exists "own or my pool's requests" on public.squares_crash;
create policy "own or my pool's requests" on public.squares_crash for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.squares_pools p where p.id = pool_id and p.originator = auth.uid()));
drop policy if exists "players see paid" on public.squares_paid;
create policy "players see paid" on public.squares_paid for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.squares_pools p where p.id = pool_id and p.originator = auth.uid()));
grant select on public.squares_pools, public.squares_games, public.squares_invitees, public.squares_crash,
  public.squares_claims, public.squares_paid, public.squares_results to authenticated;
grant all on public.squares_pools, public.squares_games, public.squares_invitees, public.squares_crash,
  public.squares_claims, public.squares_paid, public.squares_results to service_role;

create or replace function public._squares_member(p_pool uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from squares_pools where id = p_pool and originator = p_uid)
      or exists (select 1 from squares_invitees where pool_id = p_pool and uid = p_uid)
$$;

create or replace function public.create_squares(p_title text, p_price int, p_games jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; g jsonb; total numeric := 0; n int := 0; u uuid; pc numeric[];
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Name the pool (up to 60 characters).'; end if;
  if p_price is null or p_price not between 1 and 1000 then raise exception 'Points per square go from 1 to 1000.'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then raise exception 'Pick at least one game.'; end if;
  if jsonb_array_length(p_games) > 8 then raise exception 'Up to 8 games.'; end if;
  insert into squares_pools (title, originator, price) values (btrim(p_title), me, p_price) returning id into pid;
  for g in select * from jsonb_array_elements(p_games) loop
    if not exists (select 1 from vegas_lines where id = g->>'game_id' and starts_at > now()) then
      raise exception 'One of those games has already started or isn''t on the list.'; end if;
    pc := array(select (x)::numeric from jsonb_array_elements_text(g->'pct') x);
    if cardinality(pc) <> 4 or exists (select 1 from unnest(pc) x where x < 0 or x > 100) then raise exception 'Give four payout percentages per game.'; end if;
    total := total + (select sum(x) from unnest(pc) x);
    insert into squares_games (pool_id, game_id, ord, pct) values (pid, g->>'game_id', n, pc);
    n := n + 1;
  end loop;
  if abs(total - 100) > 0.1 then raise exception '%', format('Payouts have to add up to 100%% of the pot (they add up to %s%%).', round(total, 2)); end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into squares_invitees values (pid, u) on conflict do nothing; end if;
  end loop;
  return pid;
end $$;

-- Draw the numbers: random 0-9 for columns (home) and rows (visitors). Unsold squares go to the originator.
create or replace function public._squares_draw(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p squares_pools;
begin
  select * into p from squares_pools where id = p_pool for update;
  if p.status <> 'open' then return; end if;
  insert into squares_claims (pool_id, square, uid, unsold)
  select p_pool, s, p.originator, true from generate_series(1, 100) s
  where not exists (select 1 from squares_claims c where c.pool_id = p_pool and c.square = s);
  update squares_pools set status = 'drawn', drawn_at = now(),
    digits_home = array(select x from generate_series(0, 9) x order by random()),
    digits_away = array(select x from generate_series(0, 9) x order by random())
  where id = p_pool;
end $$;

create or replace function public.squares_claim(p_pool uuid, p_squares int[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p squares_pools; s int; taken int;
begin
  select * into p from squares_pools where id = p_pool for update;
  if not found or not _squares_member(p_pool, me) then raise exception 'You''re not in this pool. Ask to crash first.'; end if;
  if p.status <> 'open' then raise exception 'The numbers are drawn; squares are closed.'; end if;
  if coalesce(cardinality(p_squares), 0) = 0 then raise exception 'Pick at least one square.'; end if;
  foreach s in array p_squares loop
    if s not between 1 and 100 then raise exception 'Squares go from 1 to 100.'; end if;
    select count(*) into taken from squares_claims where pool_id = p_pool and square = s;
    if taken > 0 then raise exception 'Square % was just taken. Pick another.', s; end if;
    insert into squares_claims (pool_id, square, uid) values (p_pool, s, me);
  end loop;
  if (select count(*) from squares_claims where pool_id = p_pool) = 100 then perform _squares_draw(p_pool); end if;
  return (select count(*) from squares_claims where pool_id = p_pool and uid = me);
end $$;

create or replace function public.squares_release(p_pool uuid, p_squares int[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'The numbers are drawn; squares are closed.'; end if;
  delete from squares_claims where pool_id = p_pool and uid = auth.uid() and square = any (p_squares);
end $$;

create or replace function public.squares_draw(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can draw the numbers.'; end if;
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'The numbers are already drawn.'; end if;
  perform _squares_draw(p_pool);
end $$;

create or replace function public.squares_request_crash(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if _squares_member(p_pool, auth.uid()) then raise exception 'You''re already in this pool.'; end if;
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'Squares are closed.'; end if;
  insert into squares_crash (pool_id, uid) values (p_pool, auth.uid())
  on conflict (pool_id, uid) do update set status = 'pending', created_at = now(), answered_at = null;
end $$;

create or replace function public.squares_answer_crash(p_pool uuid, p_uid uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can answer.'; end if;
  update squares_crash set status = case when p_accept then 'accepted' else 'declined' end, answered_at = now()
  where pool_id = p_pool and uid = p_uid and status = 'pending';
  if not found then raise exception 'That request was already answered.'; end if;
  if p_accept then insert into squares_invitees values (p_pool, p_uid) on conflict do nothing; end if;
end $$;

create or replace function public.squares_mark_paid(p_pool uuid, p_uid uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator tracks buy-ins.'; end if;
  if p_paid then insert into squares_paid (pool_id, uid) values (p_pool, p_uid) on conflict do nothing;
  else delete from squares_paid where pool_id = p_pool and uid = p_uid; end if;
end $$;

-- Record a quarter's score and its winner. Auto scores never overwrite; manual fixes do (and re-notify).
create or replace function public._squares_record(p_pool uuid, p_game text, p_q int, p_home int, p_away int, p_source text)
returns boolean language plpgsql security definer set search_path = public as $$
declare p squares_pools; g squares_games; c int; r int; sq int; owner uuid; pts int; changed int;
begin
  select * into p from squares_pools where id = p_pool;
  if p.status not in ('drawn', 'done') then return false; end if;
  select * into g from squares_games where pool_id = p_pool and game_id = p_game;
  if not found or p_q not between 1 and 4 or p_home < 0 or p_away < 0 then return false; end if;
  c := array_position(p.digits_home, p_home % 10) - 1;
  r := array_position(p.digits_away, p_away % 10) - 1;
  sq := r * 10 + c + 1;
  select uid into owner from squares_claims where pool_id = p_pool and square = sq;
  pts := round(p.price * 100 * g.pct[p_q] / 100);
  if p_source = 'manual' then
    insert into squares_results (pool_id, game_id, quarter, home, away, square, uid, points, source)
    values (p_pool, p_game, p_q, p_home, p_away, sq, owner, pts, 'manual')
    on conflict (pool_id, game_id, quarter) do update set home = excluded.home, away = excluded.away, square = excluded.square,
      uid = excluded.uid, points = excluded.points, source = 'manual', recorded_at = now(), notified_at = null;
  else
    insert into squares_results (pool_id, game_id, quarter, home, away, square, uid, points, source)
    values (p_pool, p_game, p_q, p_home, p_away, sq, owner, pts, 'auto')
    on conflict do nothing;
  end if;
  get diagnostics changed = row_count;
  -- finished once every game has all four quarters
  if not exists (select 1 from squares_games x where x.pool_id = p_pool
                 and (select count(*) from squares_results y where y.pool_id = p_pool and y.game_id = x.game_id) < 4) then
    update squares_pools set status = 'done' where id = p_pool and status = 'drawn';
  end if;
  return changed > 0;
end $$;

-- The originator fixes (or enters) a quarter's score.
create or replace function public.squares_set_quarter(p_pool uuid, p_game text, p_q int, p_home int, p_away int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can fix a score.'; end if;
  if (select status from squares_pools where id = p_pool) not in ('drawn', 'done') then raise exception 'Draw the numbers first.'; end if;
  if p_home is null or p_away is null or p_home < 0 or p_away < 0 or p_home > 200 or p_away > 200 then raise exception 'Enter both scores.'; end if;
  perform _squares_record(p_pool, p_game, p_q, p_home, p_away, 'manual');
end $$;

create or replace function public.squares_cancel(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update squares_pools set status = 'canceled' where id = p_pool and originator = auth.uid() and status = 'open';
  if not found then raise exception 'Only the originator can cancel, and only before the numbers are drawn.'; end if;
end $$;

-- For the squares function: draw at the first kickoff, and list games still needing quarter scores.
create or replace function public.squares_tick()
returns int language plpgsql security definer set search_path = public as $$
declare p record; n int := 0;
begin
  for p in select sp.id from squares_pools sp where sp.status = 'open'
           and (select min(v.starts_at) from squares_games g join vegas_lines v on v.id = g.game_id where g.pool_id = sp.id) <= now() loop
    perform _squares_draw(p.id); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.squares_pending_games()
returns table (pool_id uuid, game_id text, home text, away text, starts_at timestamptz, have int)
language sql stable security definer set search_path = public as $$
  select g.pool_id, g.game_id, v.home, v.away, v.starts_at,
    (select count(*)::int from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id)
  from squares_games g join squares_pools p on p.id = g.pool_id join vegas_lines v on v.id = g.game_id
  where p.status = 'drawn' and v.starts_at <= now() and v.starts_at > now() - interval '18 hours'
    and (select count(*) from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id) < 4
$$;

create or replace function public.squares_record_auto(p_pool uuid, p_game text, p_q int, p_home int, p_away int)
returns boolean language sql security definer set search_path = public as $$
  select _squares_record(p_pool, p_game, p_q, p_home, p_away, 'auto')
$$;

revoke all on function public._squares_member(uuid, uuid), public._squares_draw(uuid), public._squares_record(uuid, text, int, int, int, text),
  public.squares_tick(), public.squares_pending_games(), public.squares_record_auto(uuid, text, int, int, int) from public, anon, authenticated;
grant execute on function public.squares_tick(), public.squares_pending_games(), public.squares_record_auto(uuid, text, int, int, int) to service_role;
revoke all on function public.create_squares(text, int, jsonb, uuid[]), public.squares_claim(uuid, int[]), public.squares_release(uuid, int[]),
  public.squares_draw(uuid), public.squares_request_crash(uuid), public.squares_answer_crash(uuid, uuid, boolean),
  public.squares_mark_paid(uuid, uuid, boolean), public.squares_set_quarter(uuid, text, int, int, int), public.squares_cancel(uuid) from public, anon;
grant execute on function public.create_squares(text, int, jsonb, uuid[]), public.squares_claim(uuid, int[]), public.squares_release(uuid, int[]),
  public.squares_draw(uuid), public.squares_request_crash(uuid), public.squares_answer_crash(uuid, uuid, boolean),
  public.squares_mark_paid(uuid, uuid, boolean), public.squares_set_quarter(uuid, text, int, int, int), public.squares_cancel(uuid) to authenticated;

do $$ begin alter publication supabase_realtime add table public.squares_claims; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.squares_pools; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.squares_results; exception when duplicate_object then null; when undefined_object then null; end $$;

-- Every 5 minutes: call the squares function (draws at kickoff, quarter scores, notifications).
-- It returns right away when no pool needs anything.
create extension if not exists pg_net;
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-squares') where exists (select 1 from cron.job where jobname = 'handshake-squares');
  perform cron.schedule('handshake-squares', '*/5 * * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/squares',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

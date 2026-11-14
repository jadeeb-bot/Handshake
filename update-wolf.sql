-- Handshake update: Wolf (golf betting game) rounds.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- Rules (decided Nov 13):
--   * Four players in a fixed tee order. The Wolf rotates A, B, C, D, ... and keeps rotating on
--     holes 17 and 18 (so A and B are Wolf five times).
--   * The Wolf takes a partner (2 vs 2), goes Lone Wolf after the drives, or Blind Wolf before.
--   * Hole value = 1 point, plus 1 for every tied hole in a row before it (ties roll over),
--     times 2 for Blind Wolf, times 2 for every press so far.
--     - Team hole: low ball of each team; each loser pays the value to each winner.
--     - Lone Wolf (decided after the drives): Wolf vs the low ball of the other three; the Wolf
--       wins the value from each of the three (3 total) or pays the value to each (1 each).
--     - Blind Wolf (declared before anyone tees off): same, at double stakes (win 6, or pay 2
--       to each player).
--   * Press: before a hole, a player in last place (lowest running total) can press. Stakes
--     double from that hole to the end. Presses stack (another press later = 4x). One per hole.
--   * Bonuses: Greenie, Birdie, Sandy are 1 point from each other player (+3 / -1 each).
--     They never roll over or double. Players tick them; the app doesn't need par.
--   * Gross scores. Players can be Handshake people or guests (a name only).
--   * Finish round: the points each pair owes are booked as finished Just the Two of Us
--     predictions (marked wolf_round), so Standings, Rivals and settle-up include them.
--     Pairs where both are guests aren't booked.

create table if not exists public.wolf_rounds (
  id           uuid primary key default gen_random_uuid(),
  course       text not null default '' check (char_length(course) <= 40),
  players      jsonb not null,             -- [{uid, name}] x4, in tee order (Wolf order)
  created_by   uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'playing' check (status in ('playing', 'finished')),
  created_at   timestamptz not null default now(),
  finished_at  timestamptz
);
create table if not exists public.wolf_holes (
  round_id    uuid not null references public.wolf_rounds (id) on delete cascade,
  hole        int not null check (hole between 1 and 18),
  mode        text check (mode in ('partner', 'lone', 'blind')),
  partner     int check (partner between 0 and 3),
  scores      int[] not null default '{NULL,NULL,NULL,NULL}',
  greenie     int[] not null default '{}',
  birdie      int[] not null default '{}',
  sandy       int[] not null default '{}',
  pressed_by  int check (pressed_by between 0 and 3),
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  primary key (round_id, hole)
);
alter table public.predictions add column if not exists wolf_round uuid references public.wolf_rounds (id) on delete set null;

create or replace function public.wolf_is_player(p_round uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from wolf_rounds r, jsonb_array_elements(r.players) e
                 where r.id = p_round and e->>'uid' = auth.uid()::text)
$$;

alter table public.wolf_rounds enable row level security;
alter table public.wolf_holes enable row level security;
drop policy if exists "players see rounds" on public.wolf_rounds;
create policy "players see rounds" on public.wolf_rounds for select to authenticated using (public.wolf_is_player(id));
drop policy if exists "players see holes" on public.wolf_holes;
create policy "players see holes" on public.wolf_holes for select to authenticated using (public.wolf_is_player(round_id));
grant select on public.wolf_rounds, public.wolf_holes to authenticated;
grant all on public.wolf_rounds, public.wolf_holes to service_role;

-- The scoring engine: one row per hole, in order. pay[i*4+j+1] = points player i pays player j
-- on that hole. d0..d3 = each player's net for the hole. Only complete holes score.
create or replace function public.wolf_compute(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, pay int[], d0 int, d1 int, d2 int, d3 int)
language plpgsql stable security definer set search_path = public as $$
declare
  h wolf_holes; carry int := 0; np int := 0; m int; u int; w int; p int;
  a int; b int; i int; j int; others int[]; team int[]; opp int[]; names text[]; won int[]; lost int[];
  pa int[]; dd int[]; bon int; txt text;
begin
  select array_agg(e->>'name' order by o) into names
    from wolf_rounds r, jsonb_array_elements(r.players) with ordinality x(e, o) where r.id = p_round;
  for h in select * from wolf_holes x where x.round_id = p_round order by x.hole loop
    if h.pressed_by is not null then np := np + 1; end if;
    w := (h.hole - 1) % 4;
    pa := array_fill(0, array[16]); txt := null; u := null;
    complete := h.mode is not null and cardinality(h.scores) = 4 and array_position(h.scores, null) is null
                and (h.mode <> 'partner' or (h.partner is not null and h.partner <> w));
    carry_in := carry;
    if complete then
      m := case h.mode when 'blind' then 2 else 1 end;
      u := (1 + carry) * m * (2 ^ np)::int;
      if h.mode = 'partner' then
        team := array[w, h.partner];
        opp := array(select g from generate_series(0, 3) g where g <> all (team));
        a := least(h.scores[team[1] + 1], h.scores[team[2] + 1]);
        b := least(h.scores[opp[1] + 1], h.scores[opp[2] + 1]);
        if a = b then won := null; else
          if a < b then won := team; lost := opp; else won := opp; lost := team; end if;
          foreach i in array lost loop foreach j in array won loop pa[i * 4 + j + 1] := pa[i * 4 + j + 1] + u; end loop; end loop;
          txt := names[won[1] + 1] || ' & ' || names[won[2] + 1] || ' won';
        end if;
      else
        others := array(select g from generate_series(0, 3) g where g <> w);
        a := h.scores[w + 1];
        b := least(h.scores[others[1] + 1], h.scores[others[2] + 1], h.scores[others[3] + 1]);
        if a < b then
          foreach i in array others loop pa[i * 4 + w + 1] := pa[i * 4 + w + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'Lone' else 'Blind' end || ' Wolf ' || names[w + 1] || ' won';
        elsif a > b then
          foreach j in array others loop pa[w * 4 + j + 1] := pa[w * 4 + j + 1] + u; end loop;
          txt := 'The pack beat ' || case h.mode when 'lone' then 'Lone' else 'Blind' end || ' Wolf ' || names[w + 1];
        end if;
      end if;
      if txt is null then carry := carry + 1; txt := 'Tied: 1 point rolls over'; else carry := 0; end if;
      -- bonuses: 1 from each other player, never multiplied
      foreach bon in array h.greenie || h.birdie || h.sandy loop
        for i in 0..3 loop if i <> bon then pa[i * 4 + bon + 1] := pa[i * 4 + bon + 1] + 1; end if; end loop;
      end loop;
    end if;
    dd := array[0, 0, 0, 0];
    for i in 0..3 loop for j in 0..3 loop
      dd[j + 1] := dd[j + 1] + pa[i * 4 + j + 1]; dd[i + 1] := dd[i + 1] - pa[i * 4 + j + 1];
    end loop; end loop;
    hole := h.hole; wolf := w; mode := h.mode; partner := h.partner; presses := np; unit := u; result := txt; pay := pa;
    d0 := dd[1]; d1 := dd[2]; d2 := dd[3]; d3 := dd[4];
    return next;
  end loop;
end $$;

-- What the app shows (players only).
create or replace function public.wolf_scoreboard(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, d0 int, d1 int, d2 int, d3 int)
language sql stable security definer set search_path = public as $$
  select c.hole, c.wolf, c.mode, c.partner, c.complete, c.carry_in, c.presses, c.unit, c.result, c.d0, c.d1, c.d2, c.d3
  from wolf_compute(p_round) c where wolf_is_player(p_round)
$$;

create or replace function public.create_wolf_round(p_course text, p_players jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); clean jsonb := '[]'; e jsonb; nm text; u uuid; rid uuid; uids uuid[] := '{}';
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if jsonb_typeof(p_players) <> 'array' or jsonb_array_length(p_players) <> 4 then raise exception 'Wolf needs exactly 4 players.'; end if;
  for e in select * from jsonb_array_elements(p_players) loop
    u := nullif(e->>'uid', '')::uuid;
    if u is not null then
      select name into nm from profiles where id = u;
      if nm is null then raise exception 'One of those players isn''t on Handshake.'; end if;
      if u = any (uids) then raise exception 'Each player can only be in the round once.'; end if;
      uids := uids || u;
    else
      nm := btrim(coalesce(e->>'name', ''));
      if nm = '' or char_length(nm) > 30 then raise exception 'Give every guest a name (up to 30 characters).'; end if;
    end if;
    clean := clean || jsonb_build_array(jsonb_build_object('uid', u, 'name', nm));
  end loop;
  if not me = any (uids) then raise exception 'You need to be one of the four players.'; end if;
  insert into wolf_rounds (course, players, created_by) values (left(btrim(coalesce(p_course, '')), 40), clean, me) returning id into rid;
  return rid;
end $$;

-- Save one hole (everything at once). Any Handshake player in the round can enter it.
create or replace function public.save_wolf_hole(p_round uuid, p_hole int, p_mode text, p_partner int, p_scores int[],
  p_greenie int[], p_birdie int[], p_sandy int[], p_pressed_by int)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; old_press int; lowest int; tot int[] := array[0, 0, 0, 0]; c record; w int := (p_hole - 1) % 4;
begin
  select * into r from wolf_rounds where id = p_round;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is finished.'; end if;
  if p_hole not between 1 and 18 then raise exception 'Holes go from 1 to 18.'; end if;
  if p_mode is not null and p_mode not in ('partner', 'lone', 'blind') then raise exception 'Pick a partner, Lone Wolf or Blind Wolf.'; end if;
  if p_mode = 'partner' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick the Wolf''s partner.'; end if;
  if cardinality(coalesce(p_scores, '{}')) <> 4 then raise exception 'Send four scores (blank is fine).'; end if;
  if exists (select 1 from unnest(p_scores) s where s is not null and s not between 1 and 20) then raise exception 'Scores go from 1 to 20.'; end if;
  if exists (select 1 from unnest(coalesce(p_greenie, '{}') || coalesce(p_birdie, '{}') || coalesce(p_sandy, '{}')) x where x not between 0 and 3) then
    raise exception 'Bonus for an unknown player.'; end if;
  select pressed_by into old_press from wolf_holes where round_id = p_round and hole = p_hole;
  if p_pressed_by is not null and p_pressed_by is distinct from old_press then
    if p_pressed_by not between 0 and 3 then raise exception 'Unknown player pressing.'; end if;
    for c in select * from wolf_compute(p_round) x where x.hole < p_hole loop
      tot := array[tot[1] + c.d0, tot[2] + c.d1, tot[3] + c.d2, tot[4] + c.d3];
    end loop;
    select min(t) into lowest from unnest(tot) t;
    if tot[p_pressed_by + 1] <> lowest then raise exception 'Only the player in last place can press.'; end if;
  end if;
  insert into wolf_holes (round_id, hole, mode, partner, scores, greenie, birdie, sandy, pressed_by, updated_by, updated_at)
  values (p_round, p_hole, p_mode, case when p_mode = 'partner' then p_partner end, p_scores,
          coalesce(array(select distinct x from unnest(p_greenie) x), '{}'), coalesce(array(select distinct x from unnest(p_birdie) x), '{}'),
          coalesce(array(select distinct x from unnest(p_sandy) x), '{}'), p_pressed_by, auth.uid(), now())
  on conflict (round_id, hole) do update set mode = excluded.mode, partner = excluded.partner, scores = excluded.scores,
    greenie = excluded.greenie, birdie = excluded.birdie, sandy = excluded.sandy, pressed_by = excluded.pressed_by,
    updated_by = excluded.updated_by, updated_at = now();
end $$;

-- Finish: book what each pair owes as finished predictions. Returns how many were booked.
create or replace function public.finish_wolf_round(p_round uuid)
returns int language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; tot int[] := array_fill(0, array[16]); c record; i int; j int; net int; n int := 0;
  pl jsonb; ui uuid; uj uuid; ni text; nj text; title text; holes int; win_uid uuid; win_name text; lose_uid uuid; lose_name text;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is already finished.'; end if;
  holes := 0;
  for c in select * from wolf_compute(p_round) loop
    if c.complete then holes := holes + 1; end if;
    for i in 1..16 loop tot[i] := tot[i] + c.pay[i]; end loop;
  end loop;
  if holes = 0 then raise exception 'Enter at least one full hole first.'; end if;
  pl := r.players;
  title := left('Wolf' || case when r.course <> '' then ' · ' || r.course else '' end || ' · ' || to_char(now() at time zone 'America/Los_Angeles', 'Mon FMDD'), 90);
  for i in 0..2 loop for j in (i + 1)..3 loop
    net := tot[j * 4 + i + 1] - tot[i * 4 + j + 1];   -- > 0: j owes i
    if net = 0 then continue; end if;
    ui := nullif(pl->i->>'uid', '')::uuid; uj := nullif(pl->j->>'uid', '')::uuid;
    ni := pl->i->>'name'; nj := pl->j->>'name';
    if net > 0 then win_uid := ui; win_name := ni; lose_uid := uj; lose_name := nj;
    else win_uid := uj; win_name := nj; lose_uid := ui; lose_name := ni; net := -net; end if;
    if win_uid is null and lose_uid is null then continue; end if;
    insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                             status, winner, visibility, auto_notified, decided_at, wolf_round, log)
    values (title, 'Golf', 'points', least(net, 1000), (now() at time zone 'America/Los_Angeles')::date,
            left('Wolf, ' || holes || ' holes. ' || win_name || ' won ' || net || case when net = 1 then ' pt' else ' pts' end || ' from ' || lose_name || '.', 240),
            coalesce(win_uid, lose_uid), case when win_uid is not null then win_name else lose_name end,
            case when win_uid is not null then lose_uid else null end,
            case when win_uid is not null then lose_name else win_name end,
            case when win_uid is not null then lose_uid else null end,
            'settled', case when win_uid is not null then 'a' else 'b' end, 'pair', true, now(), p_round,
            jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'wolf round counted: ' || win_name || ' won ' || net || case when net = 1 then ' pt' else ' pts' end || ' from ' || lose_name)));
    n := n + 1;
  end loop; end loop;
  update wolf_rounds set status = 'finished', finished_at = now() where id = p_round;
  return n;
end $$;

-- Delete a round you started (only while it's still being played).
create or replace function public.delete_wolf_round(p_round uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from wolf_rounds where id = p_round and created_by = auth.uid() and status = 'playing';
  if not found then raise exception 'Only the person who started an unfinished round can delete it.'; end if;
end $$;

revoke all on function public.wolf_compute(uuid) from public, anon, authenticated;
grant execute on function public.wolf_compute(uuid) to service_role;
revoke all on function public.wolf_is_player(uuid), public.wolf_scoreboard(uuid), public.create_wolf_round(text, jsonb),
  public.save_wolf_hole(uuid, int, text, int, int[], int[], int[], int[], int), public.finish_wolf_round(uuid),
  public.delete_wolf_round(uuid) from public, anon;
grant execute on function public.wolf_is_player(uuid), public.wolf_scoreboard(uuid), public.create_wolf_round(text, jsonb),
  public.save_wolf_hole(uuid, int, text, int, int[], int[], int[], int[], int), public.finish_wolf_round(uuid),
  public.delete_wolf_round(uuid) to authenticated;

-- "Predictions and Counting!" counts calls people made, not points booked by pools or golf.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null and wolf_round is null
$$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

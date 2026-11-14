-- Handshake update: Wolf invites and live scoring.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-wolf.sql first. Safe to run more than once. Fresh installs get the same thing
-- from schema.sql.
--
--   * Every round gets an invite code (W + 6 characters) and link (?join=CODE, which also opens
--     the iPhone app). Opening it puts that person into one of the round's guest spots, so they
--     can enter and follow scores on their own phone. Handshake players picked when the round
--     starts are already in.
--   * Live scoring: rounds and holes are added to Supabase Realtime, so every player's screen
--     updates as soon as anyone saves a hole. (Realtime respects the same "players only" rule.)

alter table public.wolf_rounds add column if not exists code text;
update public.wolf_rounds set code = 'W' || upper(substr(md5(id::text || random()::text), 1, 6)) where code is null;
create unique index if not exists wolf_rounds_code on public.wolf_rounds (code);

create or replace function public.create_wolf_round(p_course text, p_players jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); clean jsonb := '[]'; e jsonb; nm text; u uuid; rid uuid; uids uuid[] := '{}'; c text;
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
  loop
    c := 'W' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from wolf_rounds where code = c);
  end loop;
  insert into wolf_rounds (course, players, created_by, code) values (left(btrim(coalesce(p_course, '')), 40), clean, me, c) returning id into rid;
  return rid;
end $$;

-- What an invite link shows before joining: the round and its open guest spots.
create or replace function public.wolf_round_preview(p_code text)
returns table (round_id uuid, course text, names text[], guest_slots int[], is_player boolean, finished boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.course,
    array(select e->>'name' from jsonb_array_elements(r.players) with ordinality x(e, o) order by o),
    array(select (o - 1)::int from jsonb_array_elements(r.players) with ordinality x(e, o) where coalesce(e->>'uid', '') = '' order by o),
    exists (select 1 from jsonb_array_elements(r.players) e where e->>'uid' = auth.uid()::text),
    r.status = 'finished'
  from wolf_rounds r where r.code = upper(btrim(coalesce(p_code, '')))
$$;

-- Join a round from its invite: take over a guest spot (p_slot = which one, 0-3).
create or replace function public.join_wolf_round(p_code text, p_slot int)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r wolf_rounds; nm text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select * into r from wolf_rounds where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'That round code doesn''t match any round.'; end if;
  if exists (select 1 from jsonb_array_elements(r.players) e where e->>'uid' = me::text) then return r.id; end if;
  if r.status <> 'playing' then raise exception 'That round is already finished.'; end if;
  if p_slot is null or p_slot not between 0 and 3 or coalesce(r.players->p_slot->>'uid', '') <> '' then
    raise exception 'Pick one of the guest spots.'; end if;
  select name into nm from profiles where id = me;
  update wolf_rounds set players = jsonb_set(players, array[p_slot::text], jsonb_build_object('uid', me, 'name', coalesce(nm, players->p_slot->>'name')))
  where id = r.id;
  return r.id;
end $$;

revoke all on function public.create_wolf_round(text, jsonb), public.wolf_round_preview(text), public.join_wolf_round(text, int) from public, anon;
grant execute on function public.create_wolf_round(text, jsonb), public.wolf_round_preview(text), public.join_wolf_round(text, int) to authenticated;

-- Live updates for players' screens.
do $$ begin alter publication supabase_realtime add table public.wolf_rounds; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.wolf_holes; exception when duplicate_object then null; when undefined_object then null; end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

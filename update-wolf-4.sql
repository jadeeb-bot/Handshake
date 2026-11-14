-- Handshake update: change a Wolf round's tee order after starting it.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-wolf-3.sql first. Safe to run more than once.
--
-- Any player in the round can change the tee order (Wolf rotation) until the first hole is
-- saved. p_order lists the current spots (0-3) in their new order, e.g. {2,0,3,1}.

create or replace function public.reorder_wolf_round(p_round uuid, p_order int[])
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That match is already over.'; end if;
  if exists (select 1 from wolf_holes where round_id = p_round) then
    raise exception 'The tee order is locked once the first hole is saved.'; end if;
  if cardinality(coalesce(p_order, '{}')) <> 4
     or (select array_agg(x order by x) from unnest(p_order) x) is distinct from array[0, 1, 2, 3] then
    raise exception 'Send each of the four spots once.'; end if;
  update wolf_rounds set players = (select jsonb_agg(r.players->x order by o) from unnest(p_order) with ordinality u(x, o))
  where id = p_round;
end $$;

revoke all on function public.reorder_wolf_round(uuid, int[]) from public, anon;
grant execute on function public.reorder_wolf_round(uuid, int[]) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: Wolf "End match" keeps golf separate.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-wolf-2.sql first. Safe to run more than once.
--
-- Decided Nov 13: golf results stay in the round. Ending a match (any time, 18 holes or not)
-- just closes it; the app then shows who pays whom, net of all offsets, in the fewest payments.
-- Nothing is booked into Standings, Rivals or settle-up anymore, and any golf results booked
-- before this change are removed from them (the rounds themselves are kept).

create or replace function public.finish_wolf_round(p_round uuid)
returns int language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; holes int;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That match is already over.'; end if;
  select count(*) into holes from wolf_compute(p_round) c where c.complete;
  if holes = 0 then raise exception 'Enter at least one full hole first.'; end if;
  update wolf_rounds set status = 'finished', finished_at = now() where id = p_round;
  return holes;
end $$;

-- Golf results booked by the old version come back out of Standings and Rivals.
delete from public.predictions where wolf_round is not null;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

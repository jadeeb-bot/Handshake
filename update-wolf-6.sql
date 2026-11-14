-- Handshake update: delete a finished Wolf match, with a 24-hour window to save it.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-wolf-5.sql first. Safe to run more than once.
--
-- Decided Nov 14: any Handshake player in a finished match can ask to delete it. The other
-- players get a notification, and any player can tap Save this round within 24 hours to cancel
-- it. If nobody does, the background job deletes the round (checked every 10 minutes).
-- (Unfinished rounds can still be deleted right away by whoever started them.)

alter table public.wolf_rounds add column if not exists delete_requested_by uuid references public.profiles (id) on delete set null;
alter table public.wolf_rounds add column if not exists delete_requested_at timestamptz;
alter table public.wolf_rounds add column if not exists delete_saved_by uuid references public.profiles (id) on delete set null;
alter table public.wolf_rounds add column if not exists delete_saved_at timestamptz;

create or replace function public.request_wolf_delete(p_round uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'finished' then raise exception 'End the match first (or delete it right away if you started it).'; end if;
  if r.delete_requested_at is not null then raise exception 'Someone already asked to delete this round.'; end if;
  update wolf_rounds set delete_requested_by = auth.uid(), delete_requested_at = now(), delete_saved_by = null, delete_saved_at = null
  where id = p_round;
  return now() + interval '24 hours';
end $$;

create or replace function public.save_wolf_round(p_round uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.delete_requested_at is null then raise exception 'Nobody has asked to delete this round.'; end if;
  update wolf_rounds set delete_requested_by = null, delete_requested_at = null, delete_saved_by = auth.uid(), delete_saved_at = now()
  where id = p_round;
end $$;

-- Delete rounds whose 24 hours ran out. Returns how many were deleted.
create or replace function public.delete_expired_wolf_rounds()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from wolf_rounds where delete_requested_at is not null and delete_requested_at <= now() - interval '24 hours';
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.request_wolf_delete(uuid), public.save_wolf_round(uuid), public.delete_expired_wolf_rounds() from public, anon;
grant execute on function public.request_wolf_delete(uuid), public.save_wolf_round(uuid) to authenticated;
grant execute on function public.delete_expired_wolf_rounds() to service_role;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-wolf-delete') where exists (select 1 from cron.job where jobname = 'handshake-wolf-delete');
  perform cron.schedule('handshake-wolf-delete', '*/10 * * * *', 'select public.delete_expired_wolf_rounds()');
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

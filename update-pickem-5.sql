-- Handshake update: deleting Pick 'em All! groups (Nov 15).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Safe to run more than once.
--
--   * The group's creator can delete it (Delete group, two taps). Its picks go with it; points already
--     won in finished weeks stay in Standings (those predictions are kept).
--   * A group that has never had a week scored is removed automatically if fewer than 2 people have
--     entered (made any pick) by the week's first Sunday kickoff. Groups with history are left alone;
--     a thin week there just moves no points, as before.
--   * Members get a notification either way (sent by the 5-minute squares job from pickem_removed).

create table if not exists public.pickem_removed (
  id          uuid primary key default gen_random_uuid(),
  group_name  text not null,
  members     uuid[] not null default '{}',
  removed_by  uuid references public.profiles (id) on delete set null,   -- null = removed automatically
  reason      text not null check (reason in ('creator', 'no entries')),
  removed_at  timestamptz not null default now(),
  notified_at timestamptz
);
alter table public.pickem_removed enable row level security;
grant all on public.pickem_removed to service_role;

-- Booked Pick 'em predictions keep their "Pick 'em" label after the group is gone.
alter table public.predictions add column if not exists pickem_name text;

create or replace function public._pickem_remove(p_group uuid, p_by uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare g pickem_groups;
begin
  select * into g from pickem_groups where id = p_group for update;
  if not found then return; end if;
  insert into pickem_removed (group_name, members, removed_by, reason)
  values (g.name, array(select uid from pickem_members where group_id = p_group), p_by, p_reason);
  update predictions set pickem_name = g.name where pickem_group = p_group and pickem_name is null;
  delete from pickem_groups where id = p_group;   -- members, picks, invites, weeks go with it
end $$;

create or replace function public.delete_pickem_group(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pickem_groups where id = p_group and created_by = auth.uid()) then
    raise exception 'Only the person who started the group can delete it.'; end if;
  perform _pickem_remove(p_group, auth.uid(), 'creator');
end $$;

-- Remove groups that never got going: fewer than 2 entries by this week's first Sunday kickoff.
create or replace function public.pickem_prune()
returns int language plpgsql security definer set search_path = public as $$
declare wk date := nfl_week(now()); lk timestamptz := pickem_week_lock(nfl_week(now())); g record; n int := 0;
begin
  if lk is null or now() < lk then return 0; end if;
  for g in
    select pg.id from pickem_groups pg
    where pg.created_at < lk
      and not exists (select 1 from pickem_weeks k where k.group_id = pg.id)
      and (select count(*) from (
             select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id where p.group_id = pg.id and nfl_week(v.starts_at) = wk
             union select t.uid from pickem_tiebreaks t where t.group_id = pg.id and t.week = wk
             union select b.uid from pickem_bonus b where b.group_id = pg.id and b.week = wk) e) < 2
  loop
    perform _pickem_remove(g.id, null, 'no entries'); n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public._pickem_remove(uuid, uuid, text), public.pickem_prune() from public, anon, authenticated;
grant execute on function public.pickem_prune() to service_role;
revoke all on function public.delete_pickem_group(uuid) from public, anon;
grant execute on function public.delete_pickem_group(uuid) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

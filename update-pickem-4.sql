-- Handshake update: Pick 'em All! invites by account (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Safe to run more than once.
--
-- Any member can invite Handshake people to their group from the Invite friends panel.
-- An invited person sees "You're invited" with Join / No thanks on the group card (and gets a
-- notification): no code or link needed. Codes and links still work for everyone else.

create table if not exists public.pickem_invites (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  invited_by  uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'joined', 'declined')),
  created_at  timestamptz not null default now(),
  answered_at timestamptz,
  primary key (group_id, uid)
);
alter table public.pickem_invites enable row level security;
drop policy if exists "mine or my group's invites" on public.pickem_invites;
create policy "mine or my group's invites" on public.pickem_invites for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.pickem_members m where m.group_id = pickem_invites.group_id and m.uid = auth.uid()));
grant select on public.pickem_invites to authenticated;
grant all on public.pickem_invites to service_role;

-- A member invites people (returns how many new invites went out).
create or replace function public.pickem_invite(p_group uuid, p_uids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); u uuid; n int := 0;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then raise exception 'Only members can invite people.'; end if;
  foreach u in array coalesce(p_uids, '{}') loop
    continue when u = me or not exists (select 1 from profiles where id = u)
      or exists (select 1 from pickem_members where group_id = p_group and uid = u);
    insert into pickem_invites (group_id, uid, invited_by) values (p_group, u, me)
    on conflict (group_id, uid) do update set invited_by = me, status = 'pending', created_at = now(), answered_at = null
      where pickem_invites.status <> 'pending';
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- The invited person joins (or says no thanks).
create or replace function public.pickem_answer_invite(p_group uuid, p_join boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  update pickem_invites set status = case when p_join then 'joined' else 'declined' end, answered_at = now()
  where group_id = p_group and uid = me and status = 'pending';
  if not found then raise exception 'That invite isn''t open anymore.'; end if;
  if p_join then
    insert into pickem_members (group_id, uid) values (p_group, me) on conflict do nothing;
    update pickem_crash_requests set status = 'accepted', answered_at = now() where group_id = p_group and uid = me and status = 'pending';
  end if;
end $$;

-- Joining any other way (code, link, crash accepted) closes an open invite too.
create or replace function public._pickem_close_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update pickem_invites set status = 'joined', answered_at = now() where group_id = new.group_id and uid = new.uid and status = 'pending';
  return new;
end $$;
drop trigger if exists pickem_close_invite on public.pickem_members;
create trigger pickem_close_invite after insert on public.pickem_members for each row execute function public._pickem_close_invite();

revoke all on function public.pickem_invite(uuid, uuid[]), public.pickem_answer_invite(uuid, boolean), public._pickem_close_invite() from public, anon;
grant execute on function public.pickem_invite(uuid, uuid[]), public.pickem_answer_invite(uuid, boolean) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

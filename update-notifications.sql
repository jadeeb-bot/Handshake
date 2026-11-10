-- Handshake update: activity alerts and push notifications.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

-- Every history entry now records who did it, so alerts can tell your moves from theirs.
create or replace function public._entry(what text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_array(jsonb_build_object('t', now(), 'by', coalesce(_my_name(), 'Someone'), 'uid', auth.uid(), 'what', what))
$$;

-- Devices that asked for push notifications. Each player sees and manages only their own.
create table if not exists public.push_subscriptions (
  endpoint text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  p256dh text not null,
  auth text not null,
  created_at timestamptz not null default now()
);
create index if not exists push_subscriptions_user_idx on public.push_subscriptions (user_id);
alter table public.push_subscriptions enable row level security;

drop policy if exists "Players see their own devices" on public.push_subscriptions;
create policy "Players see their own devices" on public.push_subscriptions
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "Players add their own devices" on public.push_subscriptions;
create policy "Players add their own devices" on public.push_subscriptions
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Players update their own devices" on public.push_subscriptions;
create policy "Players update their own devices" on public.push_subscriptions
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "Players remove their own devices" on public.push_subscriptions;
create policy "Players remove their own devices" on public.push_subscriptions
  for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.push_subscriptions to authenticated;
revoke all on public.push_subscriptions from anon;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

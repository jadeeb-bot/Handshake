-- Handshake update: notifications in the iPhone app, and a notice when a result counts after 24 hours.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

-- iPhones that turned on notifications in the Handshake app (Apple push device tokens).
-- Each player sees and manages only their own.
create table if not exists public.app_push_devices (
  token text primary key,
  user_id uuid not null references public.profiles (id) on delete cascade default auth.uid(),
  platform text not null default 'ios',
  created_at timestamptz not null default now()
);
create index if not exists app_push_devices_user_idx on public.app_push_devices (user_id);
alter table public.app_push_devices enable row level security;

drop policy if exists "Players see their own phones" on public.app_push_devices;
create policy "Players see their own phones" on public.app_push_devices
  for select to authenticated using (user_id = auth.uid());
drop policy if exists "Players add their own phones" on public.app_push_devices;
create policy "Players add their own phones" on public.app_push_devices
  for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "Players update their own phones" on public.app_push_devices;
create policy "Players update their own phones" on public.app_push_devices
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists "Players remove their own phones" on public.app_push_devices;
create policy "Players remove their own phones" on public.app_push_devices
  for delete to authenticated using (user_id = auth.uid());

grant select, insert, update, delete on public.app_push_devices to authenticated;
revoke all on public.app_push_devices from anon;

-- Has the "counted after 24 hours" notice gone out? Existing rows start as done,
-- so nothing old gets announced; new predictions start as not yet.
do $$
begin
  alter table public.predictions add column auto_notified boolean not null default true;
  alter table public.predictions alter column auto_notified set default false;
exception when duplicate_column then null;
end $$;

-- Results that counted on their own and haven't been announced yet. The app asks for these
-- when it opens and hands them to the notify function, which tells both sides once.
create or replace function public.pending_auto_announcements()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from predictions
  where auto_notified = false
    and status in ('settled', 'void')
    and log->-1->>'by' = 'Handshake'
    and log->-1->>'what' like '%after 24 hours%'
  order by decided_at desc nulls last
  limit 20
$$;
revoke all on function public.pending_auto_announcements() from public, anon;
grant execute on function public.pending_auto_announcements() to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: app icon badge on iPhone.
-- Each player gets a count of notifications since they last opened the app. The notify
-- function adds one per notification and puts the number on the app icon; opening the app
-- clears it. Safe to re-run.
alter table public.profiles add column if not exists badge_count int not null default 0;

-- Called by the notify function only: add one for each player, return the new counts.
create or replace function public.bump_badges(p_ids uuid[])
returns table (id uuid, badge int)
language sql security definer set search_path = public as $$
  update public.profiles p set badge_count = least(p.badge_count + 1, 99)
  where p.id = any (p_ids)
  returning p.id, p.badge_count;
$$;
revoke all on function public.bump_badges(uuid[]) from public, anon, authenticated;
grant execute on function public.bump_badges(uuid[]) to service_role;

-- Called by the app when it opens: back to zero.
create or replace function public.clear_badge()
returns void
language sql security definer set search_path = public as $$
  update public.profiles set badge_count = 0 where id = auth.uid() and badge_count <> 0;
$$;
revoke all on function public.clear_badge() from public, anon;
grant execute on function public.clear_badge() to authenticated;

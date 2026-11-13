-- Handshake update: Vegas opening lines for the NFL (spread and over/under).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- Once a day the vegas-lines Edge Function pulls NFL lines from The Odds API and saves them
-- here. The first line saved for a game is kept for good (the opening line we saw). Later
-- pulls only fill in a line that was missing. Everyone signed in can read the lines; only
-- the Edge Function (service_role) writes them.

create table if not exists public.vegas_lines (
  id            text primary key,          -- The Odds API's game id
  league        text not null default 'nfl',
  starts_at     timestamptz not null,
  home          text not null,
  away          text not null,
  home_spread   numeric,                   -- the home team's spread, e.g. -3.5
  total         numeric,                   -- over/under points
  book          text,                      -- sportsbook the line came from
  captured_at   timestamptz not null default now()
);
create index if not exists vegas_lines_starts on public.vegas_lines (starts_at);

-- One row per pull, so the function never pulls more than once a day.
create table if not exists public.vegas_pulls (
  id           bigint generated always as identity primary key,
  pulled_at    timestamptz not null default now(),
  games        int,
  credits_left int,
  note         text
);

alter table public.vegas_lines enable row level security;
alter table public.vegas_pulls enable row level security;
drop policy if exists "signed in can read lines" on public.vegas_lines;
create policy "signed in can read lines" on public.vegas_lines for select to authenticated using (true);

grant select on public.vegas_lines to authenticated;
grant all on public.vegas_lines, public.vegas_pulls to service_role;

-- Save a batch of games. Keeps the first line it ever saw for each game.
create or replace function public.save_vegas_lines(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  insert into vegas_lines as v (id, league, starts_at, home, away, home_spread, total, book)
  select r->>'id', coalesce(r->>'league', 'nfl'), (r->>'starts_at')::timestamptz, r->>'home', r->>'away',
         (r->>'home_spread')::numeric, (r->>'total')::numeric, r->>'book'
  from jsonb_array_elements(p_rows) r
  on conflict (id) do update set
    starts_at   = excluded.starts_at,
    home_spread = coalesce(v.home_spread, excluded.home_spread),
    total       = coalesce(v.total, excluded.total),
    book        = coalesce(v.book, excluded.book);
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.save_vegas_lines(jsonb) from public, anon, authenticated;
grant execute on function public.save_vegas_lines(jsonb) to service_role;

-- Run the pull every morning at 6 AM Pacific (14:00 UTC).
create extension if not exists pg_net;
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-vegas-lines') where exists (select 1 from cron.job where jobname = 'handshake-vegas-lines');
  perform cron.schedule('handshake-vegas-lines', '0 14 * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/vegas-lines',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

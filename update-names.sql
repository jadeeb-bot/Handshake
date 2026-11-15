-- Handshake update: full names (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run update-moderation.sql first.
-- Safe to run more than once.
--
-- Everyone gives a first and last name. Handshake shows "First L." on cards (display_name, worked out
-- automatically) and the full name in pickers. People without a last name are asked for it the next
-- time they open Handshake, before they can do anything else.

alter table public.profiles add column if not exists last_name text;
alter table public.profiles drop constraint if exists profiles_last_name_check;
alter table public.profiles add constraint profiles_last_name_check check (last_name is null or char_length(btrim(last_name)) between 1 and 30);
alter table public.profiles add column if not exists display_name text generated always as (
  case when coalesce(btrim(last_name), '') = '' then btrim(name)
       else btrim(name) || ' ' || upper(left(btrim(last_name), 1)) || '.' end) stored;

-- Names Handshake writes onto new predictions, logs and crashes use "First L."
create or replace function public._my_name()
returns text language sql stable security definer set search_path = public as $$
  select display_name from profiles where id = auth.uid()
$$;

-- The Keep it fun check covers the last name too.
drop trigger if exists keep_it_fun on public.profiles;
create trigger keep_it_fun before insert or update on public.profiles for each row execute function public._keep_it_fun('name', 'last_name');

-- Word list: the worst roots are caught inside longer words too (shithead, dipshit, motherfucking...).
alter table public.blocked_words add column if not exists anywhere boolean not null default false;
insert into public.blocked_words (word, anywhere) select unnest(array['fuck','shit','cunt','bitch','nigg','faggot','whore','pussy','dickhead','asshole','twat','jizz','porn']), true
on conflict (word) do update set anywhere = true;
create or replace function public._mod_bad(t text) returns text language sql stable security definer set search_path = public as $$
  with x as (select ' ' || regexp_replace(translate(lower(coalesce(t, '')), '0134578@$!|', 'oieastbasii'), '[^a-z]+', ' ', 'g') || ' ' as s)
  select w.word from blocked_words w, x
  where (w.anywhere and strpos(x.s, w.word) > 0)
     or x.s ~ ('\m' || replace(w.word, ' ', ' +') || '(s|es|ed|er|ers|ing)?\M')
  limit 1
$$;
revoke all on function public._mod_bad(text) from public, anon, authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

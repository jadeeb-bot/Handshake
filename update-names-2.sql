-- Handshake update: short names that stay unique (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run update-names.sql first.
-- Safe to run more than once.
--
-- display_name uses as few letters of the last name as it takes to tell people with the same first
-- name apart: "Mike L." when there's one, "Mike Le." / "Mike Lo." for Lewis and Lopez, "Mike Lew." /
-- "Mike Leo." for Lewis and Leonard. If two people have the same first and last name, both show the
-- full name. It's recalculated whenever someone's name changes.

-- display_name was a calculated column (always one initial); make it a stored one we keep up to date.
do $$
begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'profiles'
             and column_name = 'display_name' and is_generated = 'ALWAYS') then
    alter table public.profiles drop column display_name;
  end if;
end $$;
alter table public.profiles add column if not exists display_name text;

-- Short name for one person among everyone with the same first name.
create or replace function public._short_name(p_uid uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare me profiles; f text; l text; k int; clash boolean;
begin
  select * into me from profiles where id = p_uid;
  if not found then return null; end if;
  f := btrim(me.name); l := btrim(coalesce(me.last_name, ''));
  if l = '' then return f; end if;
  for k in 1 .. char_length(l) loop
    select exists (select 1 from profiles o where o.id <> me.id and lower(btrim(o.name)) = lower(f)
                   and lower(left(btrim(coalesce(o.last_name, '')), k)) = lower(left(l, k))) into clash;
    if not clash then
      return f || ' ' || upper(left(l, 1)) || lower(substr(l, 2, k - 1)) || '.';
    end if;
  end loop;
  return f || ' ' || l;   -- same first and last name as someone else: show it all
end $$;

-- Recalculate everyone sharing the old or new first name when a name changes.
create or replace function public._refresh_short_names() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update profiles p set display_name = _short_name(p.id)
  where lower(btrim(p.name)) in (lower(btrim(new.name)), lower(btrim(coalesce(case when tg_op = 'UPDATE' then old.name end, new.name))))
    and p.display_name is distinct from _short_name(p.id);
  return null;
end $$;
drop trigger if exists refresh_short_names on public.profiles;
create trigger refresh_short_names after insert or update of name, last_name on public.profiles
  for each row execute function public._refresh_short_names();

-- Fill it in for everyone now.
update public.profiles p set display_name = public._short_name(p.id) where p.display_name is distinct from public._short_name(p.id);

-- Names written onto new predictions use it (same as before, now unique).
create or replace function public._my_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(display_name, name) from profiles where id = auth.uid()
$$;

revoke all on function public._short_name(uuid), public._refresh_short_names() from public, anon, authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: Squares invite links (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Run update-squares.sql first.
-- Safe to run more than once.
--
-- Every pool gets an invite code ("S" + 6 characters) and link ?join=CODE (the same link style as
-- Pick 'em All! and Wolf, so it opens the iPhone app). Anyone with the link or code joins the pool
-- and can claim squares, no crash request needed. Only people in the pool can see its code.

create table if not exists public.squares_codes (
  pool_id  uuid primary key references public.squares_pools (id) on delete cascade,
  code     text not null unique
);
alter table public.squares_codes enable row level security;
drop policy if exists "pool members see the code" on public.squares_codes;
create policy "pool members see the code" on public.squares_codes for select to authenticated using (public._squares_member(pool_id, auth.uid()));
grant select on public.squares_codes to authenticated;
grant all on public.squares_codes to service_role;
grant execute on function public._squares_member(uuid, uuid) to authenticated;

create or replace function public._squares_new_code(p_pool uuid)
returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  select code into c from squares_codes where pool_id = p_pool;
  if c is not null then return c; end if;
  loop
    c := 'S' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    begin
      insert into squares_codes (pool_id, code) values (p_pool, c);
      return c;
    exception when unique_violation then null; -- try another
    end;
  end loop;
end $$;

create or replace function public._squares_code_trigger() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform _squares_new_code(new.id);
  return new;
end $$;
drop trigger if exists squares_code on public.squares_pools;
create trigger squares_code after insert on public.squares_pools for each row execute function public._squares_code_trigger();

-- codes for pools made before this update
select public._squares_new_code(id) from public.squares_pools p where not exists (select 1 from public.squares_codes c where c.pool_id = p.id);

-- Join with a code or link. Returns the pool id.
create or replace function public.squares_join(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; st text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select pool_id into pid from squares_codes where code = upper(btrim(coalesce(p_code, '')));
  if pid is null then raise exception 'That code doesn''t match any Squares pool.'; end if;
  select status into st from squares_pools where id = pid;
  if st = 'canceled' then raise exception 'That pool was canceled.'; end if;
  if not exists (select 1 from squares_pools where id = pid and originator = me) then
    insert into squares_invitees (pool_id, uid) values (pid, me) on conflict do nothing;
  end if;
  update squares_crash set status = 'accepted', answered_at = now() where pool_id = pid and uid = me and status = 'pending';
  return pid;
end $$;

revoke all on function public._squares_new_code(uuid), public._squares_code_trigger() from public, anon, authenticated;
revoke all on function public.squares_join(text) from public, anon;
grant execute on function public.squares_join(text) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

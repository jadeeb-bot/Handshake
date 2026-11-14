-- Handshake update: Venmo handles on settle-ups (and Quanto).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- Decided Nov 14:
--   * Every Settle up / I settled up asks whether to add your Venmo handle; if you do, it rides
--     along in the notification (settlements.venmo / settlement_requests.venmo).
--   * The first time, the app asks "Want me to remember your Venmo handle?". A remembered handle
--     lives in its own table (venmo_handles), readable only by you, and shows on Quanto only to
--     people who have played you (rival_venmos()).

alter table public.settlements add column if not exists venmo text;
alter table public.settlement_requests add column if not exists venmo text;

create table if not exists public.venmo_handles (
  uid         uuid primary key references public.profiles (id) on delete cascade,
  handle      text not null check (handle ~ '^[A-Za-z0-9_-]{2,30}$'),
  updated_at  timestamptz not null default now()
);
alter table public.venmo_handles enable row level security;
drop policy if exists "own venmo" on public.venmo_handles;
create policy "own venmo" on public.venmo_handles for select to authenticated using (uid = auth.uid());
grant select on public.venmo_handles to authenticated;
grant all on public.venmo_handles to service_role;

-- "@Jason-Adeeb", "venmo.com/u/Jason-Adeeb" or "Jason-Adeeb" all become "Jason-Adeeb".
create or replace function public._venmo_clean(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(regexp_replace(btrim(coalesce(p, '')), '^(https?://)?(www\.)?(account\.)?venmo\.com/(u/)?', '', 'i'), '^@', ''), '')
$$;

-- Remember (or forget, with null) my Venmo handle.
create or replace function public.set_my_venmo(p_handle text)
returns text language plpgsql security definer set search_path = public as $$
declare h text := _venmo_clean(p_handle);
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if h is null then delete from venmo_handles where uid = auth.uid(); return null; end if;
  if h !~ '^[A-Za-z0-9_-]{2,30}$' then raise exception 'That doesn''t look like a Venmo handle.'; end if;
  insert into venmo_handles (uid, handle) values (auth.uid(), h)
  on conflict (uid) do update set handle = excluded.handle, updated_at = now();
  return h;
end $$;

-- Add a Venmo handle to a settle-up I just made (within 10 minutes).
create or replace function public.attach_settle_venmo(p_settlement uuid, p_request uuid, p_handle text)
returns text language plpgsql security definer set search_path = public as $$
declare h text := _venmo_clean(p_handle);
begin
  if h is null or h !~ '^[A-Za-z0-9_-]{2,30}$' then raise exception 'That doesn''t look like a Venmo handle.'; end if;
  if p_settlement is not null then
    update settlements set venmo = h where id = p_settlement and user_uid = auth.uid() and created_at > now() - interval '10 minutes';
  else
    update settlement_requests set venmo = h where id = p_request and requester_uid = auth.uid() and created_at > now() - interval '10 minutes';
  end if;
  if not found then raise exception 'That settle-up isn''t yours (or is too old to change).'; end if;
  return h;
end $$;

-- Remembered handles of people I've played (for Quanto's "Pay @handle").
create or replace function public.rival_venmos()
returns table (uid uuid, handle text) language sql stable security definer set search_path = public as $$
  select v.uid, v.handle from venmo_handles v
  where v.uid <> auth.uid() and exists (
    select 1 from predictions p where p.status <> 'proposed'
      and ((p.a_uid = auth.uid() and p.b_uid = v.uid) or (p.b_uid = auth.uid() and p.a_uid = v.uid)))
$$;

revoke all on function public._venmo_clean(text) from public, anon;
revoke all on function public.set_my_venmo(text), public.attach_settle_venmo(uuid, uuid, text), public.rival_venmos() from public, anon;
grant execute on function public._venmo_clean(text), public.set_my_venmo(text), public.attach_settle_venmo(uuid, uuid, text), public.rival_venmos() to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

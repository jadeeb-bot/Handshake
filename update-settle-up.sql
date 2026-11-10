-- Handshake update: settle up with a rival (current balance back to zero; all-time stays).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- How it works:
--   * The player who's up can settle directly (settle_up).
--   * The player who's down can say "I settled up" (request_settlement). The player who's up
--     has 24 hours to confirm or dispute; with no answer it counts, like a result.

-- One row each time a balance is cleared.
create table if not exists public.settlements (
  id uuid primary key default gen_random_uuid(),
  user_uid uuid not null references public.profiles (id) on delete cascade,      -- who was up
  other_uid uuid references public.profiles (id) on delete set null,             -- the rival, if on Handshake
  other_name text not null,                                                       -- the rival's name as played
  points int not null check (points > 0),
  created_at timestamptz not null default now()
);
create index if not exists settlements_user_idx on public.settlements (user_uid);
create index if not exists settlements_other_idx on public.settlements (other_uid);
alter table public.settlements enable row level security;
drop policy if exists "Both sides see their settlements" on public.settlements;
create policy "Both sides see their settlements" on public.settlements
  for select to authenticated using (user_uid = auth.uid() or other_uid = auth.uid());
grant select on public.settlements to authenticated;
revoke all on public.settlements from anon;

-- "I settled up" claims from the player who's down, waiting on the player who's up.
create table if not exists public.settlement_requests (
  id uuid primary key default gen_random_uuid(),
  requester_uid uuid not null references public.profiles (id) on delete cascade,  -- who was down
  creditor_uid uuid not null references public.profiles (id) on delete cascade,   -- who was up
  points int not null check (points > 0),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'disputed')),
  respond_by timestamptz not null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by text check (resolved_by in ('creditor', 'auto')),
  auto_notified boolean not null default false
);
create index if not exists settlement_requests_pair_idx on public.settlement_requests (requester_uid, creditor_uid);
alter table public.settlement_requests enable row level security;
drop policy if exists "Both sides see their settle-up requests" on public.settlement_requests;
create policy "Both sides see their settle-up requests" on public.settlement_requests
  for select to authenticated using (requester_uid = auth.uid() or creditor_uid = auth.uid());
grant select on public.settlement_requests to authenticated;
revoke all on public.settlement_requests from anon;

do $$ begin alter publication supabase_realtime add table public.settlements; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.settlement_requests; exception when duplicate_object then null; end $$;

-- Points p_me is up on a rival right now: everything counted between them, minus what's been
-- settled either way. Positive means the rival owes p_me.
create or replace function public._balance_between(p_me uuid, p_other uuid, p_other_name text)
returns int language sql stable security definer set search_path = public as $$
  with games as (
    select case
             when (p.winner = 'a' and p.a_uid = p_me) or (p.winner = 'b' and p.b_uid = p_me) then p.points
             else -p.points end as delta
    from predictions p
    where p.status = 'settled' and p.winner in ('a', 'b') and p.stake_kind = 'points'
      and (
        (p_other is not null and ((p.a_uid = p_me and p.b_uid = p_other) or (p.b_uid = p_me and p.a_uid = p_other)))
        or (p_other is null and p.a_uid = p_me and p.b_uid is null and lower(btrim(p.b_name)) = lower(btrim(p_other_name)))
      )
  )
  select (coalesce((select sum(delta) from games), 0)
    - coalesce((select sum(points) from settlements s where s.user_uid = p_me
                and ((p_other is not null and s.other_uid = p_other)
                     or (p_other is null and s.other_uid is null and lower(btrim(s.other_name)) = lower(btrim(p_other_name))))), 0)
    + coalesce((select sum(points) from settlements s where p_other is not null and s.user_uid = p_other and s.other_uid = p_me), 0)
  )::int
$$;
create or replace function public._balance_with(p_other uuid, p_other_name text)
returns int language sql stable security definer set search_path = public as $$
  select _balance_between(auth.uid(), p_other, p_other_name)
$$;

-- Turn a confirmed "I settled up" into a settlement. Never clears more than is owed now.
create or replace function public._apply_settlement_request(p_id uuid, p_how text)
returns void language plpgsql security definer set search_path = public as $$
declare q settlement_requests; owed int; amount int;
begin
  select * into q from settlement_requests where id = p_id and status = 'pending' for update;
  if not found then return; end if;
  owed := _balance_between(q.creditor_uid, q.requester_uid, null);
  amount := least(q.points, owed);
  if amount > 0 then
    insert into settlements (user_uid, other_uid, other_name, points)
    values (q.creditor_uid, q.requester_uid, (select name from profiles where id = q.requester_uid), amount);
  end if;
  update settlement_requests set status = 'confirmed', resolved_at = now(), resolved_by = p_how,
    auto_notified = (p_how <> 'auto') where id = p_id;
end $$;

-- The player who's up clears what a rival owes them. Any "I settled up" from that rival counts as answered.
create or replace function public.settle_up(p_other uuid, p_other_name text)
returns int language plpgsql security definer set search_path = public as $$
declare owed int; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_other = auth.uid() then raise exception 'You can''t settle with yourself.'; end if;
  if p_other is null and coalesce(btrim(p_other_name), '') = '' then raise exception 'Pick who you''re settling with.'; end if;
  nm := coalesce((select name from profiles where id = p_other), btrim(p_other_name));
  owed := _balance_with(p_other, p_other_name);
  if owed <= 0 then raise exception 'Only the person who''s up can settle. Right now that isn''t you.'; end if;
  insert into settlements (user_uid, other_uid, other_name, points) values (auth.uid(), p_other, nm, owed);
  if p_other is not null then
    update settlement_requests set status = 'confirmed', resolved_at = now(), resolved_by = 'creditor', auto_notified = true
    where requester_uid = p_other and creditor_uid = auth.uid() and status = 'pending';
  end if;
  return owed;
end $$;

-- The player who's down says they've settled up. The other side has 24 hours to answer.
create or replace function public.request_settlement(p_creditor uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare owed int; new_id uuid; nm text;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_creditor is null or p_creditor = auth.uid() then raise exception 'Pick who you settled up with.'; end if;
  nm := coalesce((select name from profiles where id = p_creditor), 'them');
  owed := -_balance_with(p_creditor, null);
  if owed <= 0 then raise exception 'You don''t owe % anything right now.', nm; end if;
  if exists (select 1 from settlement_requests where requester_uid = auth.uid() and creditor_uid = p_creditor and status = 'pending') then
    raise exception 'You already told % you settled up. Wait for an answer.', nm; end if;
  insert into settlement_requests (requester_uid, creditor_uid, points, respond_by)
  values (auth.uid(), p_creditor, owed, now() + interval '24 hours') returning id into new_id;
  return new_id;
end $$;

-- The player who's up confirms or disputes an "I settled up", inside the 24 hours.
create or replace function public.respond_settlement(p_id uuid, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare q settlement_requests;
begin
  select * into q from settlement_requests where id = p_id for update;
  if not found then raise exception 'That settle-up no longer exists.'; end if;
  if q.creditor_uid <> auth.uid() then raise exception 'Only the person who''s up can answer this.'; end if;
  if q.status <> 'pending' then raise exception 'This settle-up was already answered.'; end if;
  if now() > q.respond_by then
    perform _apply_settlement_request(p_id, 'auto');
    raise exception 'The 24 hours to dispute this are up, so it counts.';
  end if;
  if p_accept then
    perform _apply_settlement_request(p_id, 'creditor');
    return 'confirmed';
  end if;
  update settlement_requests set status = 'disputed', resolved_at = now(), resolved_by = 'creditor', auto_notified = true where id = p_id;
  return 'disputed';
end $$;

-- Results and settle-ups nobody disputed within 24 hours count.
create or replace function public.settle_overdue()
returns int language plpgsql security definer set search_path = public as $$
declare r predictions; q settlement_requests; n int := 0;
begin
  for r in select * from predictions
           where status = 'reported' and dispute_by is not null and dispute_by <= now()
           for update skip locked loop
    if r.report_winner = 'void' then
      update predictions set status = 'void', dispute_by = null,
        log = log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'called off after 24 hours with no dispute'))
      where id = r.id;
    else
      update predictions set status = 'settled', winner = r.report_winner, decided_at = now(), dispute_by = null,
        log = log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'counted after 24 hours with no dispute'))
      where id = r.id;
    end if;
    perform _resolve_crashes(r.id, r.report_winner);
    n := n + 1;
  end loop;
  for q in select * from settlement_requests where status = 'pending' and respond_by <= now() for update skip locked loop
    perform _apply_settlement_request(q.id, 'auto');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Settle-ups that counted on their own and haven't been announced yet (the app hands these to notify).
create or replace function public.pending_settlement_announcements()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from settlement_requests
  where status = 'confirmed' and resolved_by = 'auto' and auto_notified = false
  order by resolved_at desc limit 20
$$;

revoke all on function public._balance_between(uuid, uuid, text), public._balance_with(uuid, text),
  public._apply_settlement_request(uuid, text) from public, anon, authenticated;
revoke all on function public.settle_up(uuid, text), public.request_settlement(uuid),
  public.respond_settlement(uuid, boolean), public.pending_settlement_announcements() from public, anon;
grant execute on function public.settle_up(uuid, text), public.request_settlement(uuid),
  public.respond_settlement(uuid, boolean), public.pending_settlement_announcements(),
  public.settle_overdue() to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

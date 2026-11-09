-- Handshake database setup.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run once on a fresh project.

create extension if not exists pgcrypto;

-- ---------- people ----------
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 30),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

drop policy if exists "Signed-in players can see everyone" on public.profiles;
create policy "Signed-in players can see everyone" on public.profiles
  for select to authenticated using (true);

drop policy if exists "Players create their own profile" on public.profiles;
create policy "Players create their own profile" on public.profiles
  for insert to authenticated with check (id = auth.uid());

drop policy if exists "Players rename themselves" on public.profiles;
create policy "Players rename themselves" on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------- predictions ----------
create table if not exists public.predictions (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 90),
  category text not null default 'Other',
  stake_kind text not null default 'points' check (stake_kind in ('points', 'other')),
  points int not null default 0 check (points between 0 and 1000),
  stake_text text not null default '' check (char_length(stake_text) <= 60),
  due date,
  terms text not null default '' check (char_length(terms) <= 240),
  a_uid uuid not null references public.profiles (id) on delete cascade,
  a_name text not null,
  b_uid uuid references public.profiles (id) on delete set null,
  b_name text not null,
  b_invited uuid references public.profiles (id) on delete set null,
  b_proxy boolean not null default false,
  status text not null default 'proposed'
    check (status in ('proposed', 'open', 'reported', 'disputed', 'settled', 'void')),
  report_winner text check (report_winner in ('a', 'b', 'push', 'void')),
  report_by text check (report_by in ('a', 'b')),
  winner text check (winner in ('a', 'b', 'push')),
  parent_id uuid references public.predictions (id) on delete cascade,
  parent_side text check (parent_side in ('a', 'b')),
  backs_name text,
  log jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  decided_at timestamptz
);

create index if not exists predictions_parent_idx on public.predictions (parent_id);
create index if not exists predictions_created_idx on public.predictions (created_at desc);

alter table public.predictions enable row level security;

-- Everyone signed in can read the board. Nobody writes rows directly:
-- every change goes through the functions below, which enforce the rules.
drop policy if exists "Signed-in players can see the board" on public.predictions;
create policy "Signed-in players can see the board" on public.predictions
  for select to authenticated using (true);

-- Live updates for the board.
do $$
begin
  alter publication supabase_realtime add table public.predictions;
exception when duplicate_object then null;
end $$;

-- ---------- helpers ----------
create or replace function public._my_name()
returns text language sql stable security definer set search_path = public as $$
  select name from profiles where id = auth.uid()
$$;

create or replace function public._side(p predictions)
returns text language sql immutable as $$
  select case when p.a_uid = auth.uid() then 'a'
              when p.b_uid is not null and p.b_uid = auth.uid() then 'b'
              else null end
$$;

create or replace function public._entry(what text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_array(jsonb_build_object('t', now(), 'by', coalesce(_my_name(), 'Someone'), 'what', what))
$$;

create or replace function public._load(p_id uuid)
returns predictions language plpgsql security definer set search_path = public as $$
declare r predictions;
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if _my_name() is null then raise exception 'Add your name first.'; end if;
  select * into r from predictions where id = p_id for update;
  if not found then raise exception 'That prediction no longer exists.'; end if;
  return r;
end $$;

-- Crashes follow their original once it is scored or called off.
create or replace function public._resolve_crashes(p_parent uuid, p_result text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update predictions k set
    status = case
      when k.status <> 'open' or p_result = 'void' then 'void'
      else 'settled' end,
    winner = case
      when k.status <> 'open' or p_result = 'void' then null
      when p_result = 'push' then 'push'
      when p_result = k.parent_side then 'a'
      else 'b' end,
    decided_at = now(),
    log = k.log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what',
      case when p_result = 'void' then 'original was called off'
           when k.status <> 'open' then 'original was scored before this was accepted'
           else 'scored with the original' end))
  where k.parent_id = p_parent and k.status not in ('settled', 'void');
end $$;

-- ---------- actions ----------
create or replace function public.create_prediction(
  p_title text, p_with_name text, p_invited uuid, p_category text,
  p_stake_kind text, p_points int, p_stake_text text, p_due date, p_terms text, p_shook boolean
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; me text := _my_name();
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if me is null then raise exception 'Add your name first.'; end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'Say what you''re predicting.'; end if;
  if coalesce(btrim(p_with_name), '') = '' then raise exception 'Add who''s taking the other side.'; end if;
  if p_invited = auth.uid() or lower(btrim(p_with_name)) = lower(me) then
    raise exception 'You can''t predict against yourself.'; end if;
  if p_stake_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  if p_stake_kind = 'other' and coalesce(btrim(p_stake_text), '') = '' then
    raise exception 'Say what the loser owes.'; end if;
  insert into predictions (title, category, stake_kind, points, stake_text, due, terms,
    a_uid, a_name, b_name, b_invited, b_proxy, status, log)
  values (btrim(p_title), coalesce(nullif(p_category, ''), 'Other'), p_stake_kind,
    case when p_stake_kind = 'points' then p_points else 0 end,
    case when p_stake_kind = 'other' then btrim(p_stake_text) else '' end,
    p_due, coalesce(btrim(p_terms), ''), auth.uid(), me, btrim(p_with_name), p_invited,
    coalesce(p_shook, false), case when p_shook then 'open' else 'proposed' end,
    _entry(case when p_shook then 'made the call, shaken on in person' else 'made the call' end))
  returning id into new_id;
  return new_id;
end $$;

create or replace function public.sign_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.b_uid is not null then raise exception 'This one is already signed.'; end if;
  if r.a_uid = auth.uid() then raise exception 'You can''t sign both sides.'; end if;
  if r.b_invited is not null and r.b_invited <> auth.uid() then
    raise exception 'Only the invited player can sign this one.'; end if;
  update predictions set b_uid = auth.uid(), status = 'open',
    log = log || _entry(case when parent_id is null then 'signed' else 'accepted the crash' end)
  where id = p_id;
end $$;

create or replace function public.decline_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.b_uid is not null or r.a_uid = auth.uid()
     or (r.b_invited is not null and r.b_invited <> auth.uid()) then
    raise exception 'You can''t decline this one.'; end if;
  update predictions set status = 'void', log = log || _entry('declined') where id = p_id;
  perform _resolve_crashes(p_id, 'void');
end $$;

create or replace function public.mark_shook(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.a_uid <> auth.uid() or r.status <> 'proposed' then raise exception 'You can''t do that here.'; end if;
  update predictions set status = 'open', b_proxy = true,
    log = log || _entry('marked it shaken on in person') where id = p_id;
end $$;

create or replace function public.withdraw_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.a_uid <> auth.uid() or r.status <> 'proposed' then
    raise exception 'Only the person who made it can withdraw it before it''s signed.'; end if;
  update predictions set status = 'void', log = log || _entry('withdrew') where id = p_id;
  perform _resolve_crashes(p_id, 'void');
end $$;

create or replace function public.report_result(p_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if s is null then raise exception 'Only the two players can record a result.'; end if;
  if r.parent_id is not null then raise exception 'Crashes score themselves with the original.'; end if;
  if r.status not in ('open', 'reported', 'disputed') then raise exception 'This one can''t take a result right now.'; end if;
  if p_winner not in ('a', 'b', 'push', 'void') then raise exception 'Pick who called it.'; end if;
  update predictions set status = 'reported', report_winner = p_winner, report_by = s,
    log = log || _entry('recorded: ' || case p_winner when 'push' then 'tie' when 'void' then 'call it off'
      when 'a' then a_name || ' won' else b_name || ' won' end)
  where id = p_id;
end $$;

create or replace function public.confirm_result(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r); other_uid uuid;
begin
  if r.status <> 'reported' or s is null then raise exception 'There''s no result for you to confirm.'; end if;
  other_uid := case when r.report_by = 'a' then r.b_uid else r.a_uid end;
  -- The other side confirms. The reporter may confirm only when the other side
  -- shook in person and never signed up.
  if s = r.report_by and other_uid is not null then
    raise exception 'The other side has to confirm this one.'; end if;
  if r.report_winner = 'void' then
    update predictions set status = 'void', log = log || _entry('agreed to call it off') where id = p_id;
  else
    update predictions set status = 'settled', winner = r.report_winner, decided_at = now(),
      log = log || _entry('confirmed the result') where id = p_id;
  end if;
  perform _resolve_crashes(p_id, r.report_winner);
end $$;

create or replace function public.dispute_result(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if r.status <> 'reported' or s is null or s = r.report_by then
    raise exception 'There''s no result for you to dispute.'; end if;
  update predictions set status = 'disputed', log = log || _entry('disputed the result') where id = p_id;
end $$;

create or replace function public.crash_prediction(p_id uuid, p_side text, p_points int)
returns uuid language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); new_id uuid; me text := _my_name(); y text;
begin
  if r.parent_id is not null then raise exception 'You can''t crash a crash.'; end if;
  if r.status not in ('proposed', 'open') then raise exception 'Only pending predictions can be crashed.'; end if;
  if r.a_uid = auth.uid() or r.b_uid = auth.uid() then raise exception 'You''re already in this one.'; end if;
  if p_side not in ('a', 'b') then raise exception 'Pick a side to back.'; end if;
  if exists (select 1 from predictions where parent_id = p_id and a_uid = auth.uid() and status <> 'void') then
    raise exception 'You already crashed this one.'; end if;
  if r.stake_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  y := case when p_side = 'a' then 'b' else 'a' end;
  insert into predictions (title, category, stake_kind, points, stake_text, due, terms,
    a_uid, a_name, b_name, b_invited, status, parent_id, parent_side, backs_name, log)
  values (r.title, r.category, r.stake_kind,
    case when r.stake_kind = 'points' then p_points else 0 end, r.stake_text, r.due, r.terms,
    auth.uid(), me,
    case when y = 'a' then r.a_name else r.b_name end,
    case when y = 'a' then r.a_uid else r.b_uid end,
    'proposed', p_id, p_side,
    case when p_side = 'a' then r.a_name else r.b_name end,
    _entry('crashed in backing ' || case when p_side = 'a' then r.a_name else r.b_name end))
  returning id into new_id;
  return new_id;
end $$;

-- Table access for the app. New tables aren't exposed automatically, so grant exactly
-- what the page needs: signed-in players can read both tables and manage their own
-- profile (row rules above still apply). Predictions change only through the actions.
grant usage on schema public to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select on public.predictions to authenticated;
revoke all on public.profiles, public.predictions from anon;

-- Only signed-in players may call the actions; helpers stay private.
revoke all on function public._my_name(), public._side(predictions), public._entry(text),
  public._load(uuid), public._resolve_crashes(uuid, text) from public, anon, authenticated;
revoke all on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean),
  public.sign_prediction(uuid), public.decline_prediction(uuid), public.mark_shook(uuid),
  public.withdraw_prediction(uuid), public.report_result(uuid, text), public.confirm_result(uuid),
  public.dispute_result(uuid), public.crash_prediction(uuid, text, int) from public, anon;
grant execute on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean),
  public.sign_prediction(uuid), public.decline_prediction(uuid), public.mark_shook(uuid),
  public.withdraw_prediction(uuid), public.report_result(uuid, text), public.confirm_result(uuid),
  public.dispute_result(uuid), public.crash_prediction(uuid, text, int) to authenticated;

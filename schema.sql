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

-- ================================================================
-- Counter stakes (same as update-counter-stakes.sql)
-- ================================================================
alter table public.predictions add column if not exists counter_by text;
alter table public.predictions add column if not exists counter_uid uuid references public.profiles (id) on delete set null;
alter table public.predictions add column if not exists counter_kind text;
alter table public.predictions add column if not exists counter_points int;
alter table public.predictions add column if not exists counter_text text;

do $$
begin
  alter table public.predictions add constraint predictions_counter_by_check check (counter_by in ('a', 'b'));
exception when duplicate_object then null;
end $$;
do $$
begin
  alter table public.predictions add constraint predictions_counter_kind_check check (counter_kind in ('points', 'other'));
exception when duplicate_object then null;
end $$;

-- Offer different stakes on a prediction that hasn't been signed yet.
-- The invitee counters first; after that the two sides can go back and forth.
create or replace function public.counter_offer(p_id uuid, p_kind text, p_points int, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); who text; label text;
begin
  if r.status <> 'proposed' or r.b_uid is not null then
    raise exception 'Stakes can only be countered before both sides sign.'; end if;
  if r.a_uid = auth.uid() then
    if r.counter_by is distinct from 'b' then raise exception 'There''s no counter offer to answer.'; end if;
    who := 'a';
  else
    if r.b_invited is not null and r.b_invited <> auth.uid() then
      raise exception 'Only the invited player can counter this one.'; end if;
    if r.counter_by = 'b' then raise exception 'You already countered. Wait for an answer, or take your counter back.'; end if;
    who := 'b';
  end if;
  if p_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  if p_kind = 'other' and (coalesce(btrim(p_text), '') = '' or char_length(btrim(p_text)) > 60) then
    raise exception 'Say what the loser owes, in 60 characters or less.'; end if;
  if p_kind not in ('points', 'other') then raise exception 'Pick points or other stakes.'; end if;
  if (p_kind = 'points' and r.stake_kind = 'points' and p_points = r.points)
     or (p_kind = 'other' and r.stake_kind = 'other' and lower(btrim(p_text)) = lower(r.stake_text)) then
    raise exception 'Those are the same stakes. Change them to counter.'; end if;
  label := case when p_kind = 'points' then p_points || ' pts' else btrim(p_text) end;
  update predictions set
    counter_by = who,
    counter_uid = case when who = 'b' then auth.uid() else counter_uid end,
    b_invited = case when who = 'b' then auth.uid() else b_invited end,
    counter_kind = p_kind,
    counter_points = case when p_kind = 'points' then p_points else 0 end,
    counter_text = case when p_kind = 'other' then btrim(p_text) else '' end,
    log = log || _entry(case when who = 'b' then 'countered: ' else 'countered back: ' end || label)
  where id = p_id;
end $$;

-- Accept the other side's counter. The prediction is then signed and open.
create or replace function public.accept_counter(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.counter_by is null then raise exception 'There''s no counter offer to accept.'; end if;
  if (r.counter_by = 'b' and r.a_uid <> auth.uid())
     or (r.counter_by = 'a' and r.counter_uid is distinct from auth.uid()) then
    raise exception 'Only the other side can accept this counter.'; end if;
  update predictions set
    stake_kind = counter_kind,
    points = case when counter_kind = 'points' then counter_points else 0 end,
    stake_text = case when counter_kind = 'other' then counter_text else '' end,
    b_uid = counter_uid, status = 'open',
    counter_by = null, counter_uid = null, counter_kind = null, counter_points = null, counter_text = null,
    log = log || _entry('accepted the counter')
  where id = p_id;
end $$;

-- Take back your own counter. The stakes go back to what was on the table before it.
create or replace function public.withdraw_counter(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.counter_by is null then raise exception 'There''s no counter to take back.'; end if;
  if (r.counter_by = 'b' and r.counter_uid is distinct from auth.uid())
     or (r.counter_by = 'a' and r.a_uid <> auth.uid()) then
    raise exception 'You can only take back your own counter.'; end if;
  update predictions set
    counter_by = null, counter_kind = null, counter_points = null, counter_text = null,
    counter_uid = case when r.counter_by = 'a' then counter_uid else null end,
    log = log || _entry('took back the counter')
  where id = p_id;
end $$;

-- Signing while the creator's counter is on the table accepts it.
create or replace function public.sign_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.b_uid is not null then raise exception 'This one is already signed.'; end if;
  if r.a_uid = auth.uid() then raise exception 'You can''t sign both sides.'; end if;
  if r.b_invited is not null and r.b_invited <> auth.uid() then
    raise exception 'Only the invited player can sign this one.'; end if;
  if r.counter_by = 'b' then
    raise exception 'You countered this one. Wait for an answer, or take your counter back first.'; end if;
  if r.counter_by = 'a' then
    perform accept_counter(p_id);
    return;
  end if;
  update predictions set b_uid = auth.uid(), status = 'open',
    log = log || _entry(case when parent_id is null then 'signed' else 'accepted the crash' end)
  where id = p_id;
end $$;

create or replace function public.mark_shook(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.a_uid <> auth.uid() or r.status <> 'proposed' then raise exception 'You can''t do that here.'; end if;
  if r.counter_by is not null then raise exception 'Answer the counter offer first.'; end if;
  update predictions set status = 'open', b_proxy = true,
    log = log || _entry('marked it shaken on in person') where id = p_id;
end $$;

revoke all on function public.counter_offer(uuid, text, int, text), public.accept_counter(uuid),
  public.withdraw_counter(uuid) from public, anon;
grant execute on function public.counter_offer(uuid, text, int, text), public.accept_counter(uuid),
  public.withdraw_counter(uuid), public.sign_prediction(uuid), public.mark_shook(uuid) to authenticated;

-- ================================================================
-- Only the invited person can shake (same as update-invite-by-phone.sql)
-- ================================================================
-- Phone numbers of invitees who aren't on Handshake yet. Private: no player can read
-- this table directly; only the actions below look numbers up.
create table if not exists public.prediction_invites (
  prediction_id uuid primary key references public.predictions (id) on delete cascade,
  phone_digits text not null check (phone_digits ~ '^[0-9]{8,15}$')
);
alter table public.prediction_invites enable row level security;
revoke all on public.prediction_invites from anon, authenticated;

create or replace function public._my_phone()
returns text language sql stable security definer set search_path = public, auth as $$
  select nullif(regexp_replace(coalesce(phone, ''), '\D', '', 'g'), '') from auth.users where id = auth.uid()
$$;

-- Is the signed-in player the one person allowed to take the other side?
create or replace function public._is_invitee(r predictions)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(r.a_uid <> auth.uid() and (
    r.b_invited = auth.uid()
    or (r.b_invited is null and exists (
          select 1 from prediction_invites i
          where i.prediction_id = r.id and i.phone_digits = _my_phone()))
  ), false)
$$;

-- Predictions waiting on the signed-in player because of their phone number.
create or replace function public.my_invites()
returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from predictions p join prediction_invites i on i.prediction_id = p.id
  where p.b_uid is null and p.b_invited is null and p.status = 'proposed' and i.phone_digits = _my_phone()
$$;

drop function if exists public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean);
create or replace function public.create_prediction(
  p_title text, p_with_name text, p_invited uuid, p_category text,
  p_stake_kind text, p_points int, p_stake_text text, p_due date, p_terms text, p_shook boolean,
  p_invited_phone text default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; me text := _my_name(); digits text := nullif(regexp_replace(coalesce(p_invited_phone, ''), '\D', '', 'g'), '');
begin
  if length(digits) = 10 and btrim(p_invited_phone) not like '+%' then digits := '1' || digits; end if;  -- US number without +1
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if me is null then raise exception 'Add your name first.'; end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'Say what you''re predicting.'; end if;
  if coalesce(btrim(p_with_name), '') = '' then raise exception 'Add who''s taking the other side.'; end if;
  if p_invited = auth.uid() then raise exception 'You can''t predict against yourself.'; end if;
  if p_invited is null and not coalesce(p_shook, false) then
    if digits is null or digits !~ '^[0-9]{8,15}$' then
      raise exception 'Add their mobile number so only they can shake on it.'; end if;
    if digits = _my_phone() then raise exception 'That''s your own number. Add theirs.'; end if;
  end if;
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
  if p_invited is null and digits is not null then
    insert into prediction_invites (prediction_id, phone_digits) values (new_id, digits);
  end if;
  return new_id;
end $$;

create or replace function public.sign_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.b_uid is not null then raise exception 'This one is already booked.'; end if;
  if r.a_uid = auth.uid() then raise exception 'You can''t shake on both sides.'; end if;
  if not _is_invitee(r) then raise exception 'Only the invited player can shake on this one.'; end if;
  if r.counter_by = 'b' then
    raise exception 'You countered this one. Wait for an answer, or take your counter back first.'; end if;
  if r.counter_by = 'a' then
    perform accept_counter(p_id);
    return;
  end if;
  update predictions set b_uid = auth.uid(), b_invited = auth.uid(), status = 'open',
    log = log || _entry(case when parent_id is null then 'shook on it' else 'accepted the crash' end)
  where id = p_id;
end $$;

create or replace function public.decline_prediction(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'proposed' or r.b_uid is not null or not _is_invitee(r) then
    raise exception 'You can''t decline this one.'; end if;
  update predictions set status = 'void', log = log || _entry('declined') where id = p_id;
  perform _resolve_crashes(p_id, 'void');
end $$;

create or replace function public.counter_offer(p_id uuid, p_kind text, p_points int, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); who text; label text;
begin
  if r.status <> 'proposed' or r.b_uid is not null then
    raise exception 'Stakes can only be countered before both sides shake.'; end if;
  if r.a_uid = auth.uid() then
    if r.counter_by is distinct from 'b' then raise exception 'There''s no counter offer to answer.'; end if;
    who := 'a';
  else
    if not _is_invitee(r) then raise exception 'Only the invited player can counter this one.'; end if;
    if r.counter_by = 'b' then raise exception 'You already countered. Wait for an answer, or take your counter back.'; end if;
    who := 'b';
  end if;
  if p_kind not in ('points', 'other') then raise exception 'Pick points or other stakes.'; end if;
  if p_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  if p_kind = 'other' and (coalesce(btrim(p_text), '') = '' or char_length(btrim(p_text)) > 60) then
    raise exception 'Say what the loser owes, in 60 characters or less.'; end if;
  if (p_kind = 'points' and r.stake_kind = 'points' and p_points = r.points)
     or (p_kind = 'other' and r.stake_kind = 'other' and lower(btrim(p_text)) = lower(r.stake_text)) then
    raise exception 'Those are the same stakes. Change them to counter.'; end if;
  label := case when p_kind = 'points' then p_points || ' pts' else btrim(p_text) end;
  update predictions set
    counter_by = who,
    counter_uid = case when who = 'b' then auth.uid() else counter_uid end,
    b_invited = case when who = 'b' then auth.uid() else b_invited end,
    counter_kind = p_kind,
    counter_points = case when p_kind = 'points' then p_points else 0 end,
    counter_text = case when p_kind = 'other' then btrim(p_text) else '' end,
    log = log || _entry(case when who = 'b' then 'countered: ' else 'countered back: ' end || label)
  where id = p_id;
end $$;

-- Crash offers go to the player on the other side; if that player shook in person
-- and never joined, the offer goes to their invited phone number.
create or replace function public.crash_prediction(p_id uuid, p_side text, p_points int)
returns uuid language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); new_id uuid; me text := _my_name(); y text; y_uid uuid; y_phone text;
begin
  if r.parent_id is not null then raise exception 'You can''t crash a crash.'; end if;
  if r.status not in ('proposed', 'open') then raise exception 'Only pending predictions can be crashed.'; end if;
  if r.a_uid = auth.uid() or r.b_uid = auth.uid() or _is_invitee(r) then raise exception 'You''re already in this one.'; end if;
  if p_side not in ('a', 'b') then raise exception 'Pick a side to back.'; end if;
  if exists (select 1 from predictions where parent_id = p_id and a_uid = auth.uid() and status <> 'void') then
    raise exception 'You already crashed this one.'; end if;
  if r.stake_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  y := case when p_side = 'a' then 'b' else 'a' end;
  y_uid := case when y = 'a' then r.a_uid else coalesce(r.b_uid, r.b_invited) end;
  if y_uid is null then select phone_digits into y_phone from prediction_invites where prediction_id = p_id; end if;
  if y_uid is null and y_phone is null then
    raise exception 'The other side isn''t on Handshake yet, so there''s no one to accept a crash.'; end if;
  insert into predictions (title, category, stake_kind, points, stake_text, due, terms,
    a_uid, a_name, b_name, b_invited, status, parent_id, parent_side, backs_name, log)
  values (r.title, r.category, r.stake_kind,
    case when r.stake_kind = 'points' then p_points else 0 end, r.stake_text, r.due, r.terms,
    auth.uid(), me, case when y = 'a' then r.a_name else r.b_name end, y_uid,
    'proposed', p_id, p_side,
    case when p_side = 'a' then r.a_name else r.b_name end,
    _entry('crashed in backing ' || case when p_side = 'a' then r.a_name else r.b_name end))
  returning id into new_id;
  if y_uid is null then insert into prediction_invites (prediction_id, phone_digits) values (new_id, y_phone); end if;
  return new_id;
end $$;

revoke all on function public._my_phone(), public._is_invitee(predictions) from public, anon, authenticated;
revoke all on function public.my_invites(),
  public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text) from public, anon;
grant execute on function public.my_invites(),
  public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text),
  public.sign_prediction(uuid), public.decline_prediction(uuid), public.counter_offer(uuid, text, int, text),
  public.crash_prediction(uuid, text, int) to authenticated;

-- Tell the API to pick up the new and changed actions right away.
notify pgrst, 'reload schema';

-- ================================================================
-- Fix a typo in who a prediction is for (same as update-fix-invite.sql)
-- ================================================================
-- The person who made a prediction can correct the other person's name and mobile
-- number until someone shakes on it or counters.
create or replace function public.fix_invite(p_id uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
  digits text := nullif(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), '');
begin
  if r.a_uid <> auth.uid() then raise exception 'Only the person who made this prediction can change who it''s for.'; end if;
  if r.status <> 'proposed' or r.b_uid is not null then raise exception 'It''s already booked, so it can''t be changed.'; end if;
  if r.counter_by is not null then raise exception 'They already answered with a counter, so the invite can''t be changed.'; end if;
  if r.parent_id is not null then raise exception 'Crash offers go to the player on the other side and can''t be redirected.'; end if;
  if coalesce(btrim(p_name), '') = '' then raise exception 'Add their name.'; end if;
  if length(digits) = 10 and btrim(p_phone) not like '+%' then digits := '1' || digits; end if;
  if digits is null or digits !~ '^[0-9]{8,15}$' then raise exception 'Enter their full mobile number.'; end if;
  if digits = _my_phone() then raise exception 'That''s your own number. Add theirs.'; end if;
  update predictions set b_name = btrim(p_name), b_invited = null,
    log = log || _entry('fixed who it''s for')
  where id = p_id;
  insert into prediction_invites (prediction_id, phone_digits) values (p_id, digits)
  on conflict (prediction_id) do update set phone_digits = excluded.phone_digits;
end $$;

revoke all on function public.fix_invite(uuid, text, text) from public, anon;
grant execute on function public.fix_invite(uuid, text, text) to authenticated;

-- Tell the API to pick up the new action right away.
notify pgrst, 'reload schema';

-- ================================================================
-- Activity alerts and push notifications (same as update-notifications.sql)
-- ================================================================
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

-- ================================================================
-- Shake-by deadline on invites (same as update-shake-deadline.sql)
-- ================================================================
alter table public.predictions add column if not exists shake_by timestamptz;

-- New predictions carry their shake-by deadline.
drop function if exists public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text);
create or replace function public.create_prediction(
  p_title text, p_with_name text, p_invited uuid, p_category text,
  p_stake_kind text, p_points int, p_stake_text text, p_due date, p_terms text, p_shook boolean,
  p_invited_phone text default null, p_shake_by timestamptz default null
) returns uuid language plpgsql security definer set search_path = public as $$
declare new_id uuid; me text := _my_name(); digits text := nullif(regexp_replace(coalesce(p_invited_phone, ''), '\D', '', 'g'), '');
begin
  if length(digits) = 10 and btrim(p_invited_phone) not like '+%' then digits := '1' || digits; end if;  -- US number without +1
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if me is null then raise exception 'Add your name first.'; end if;
  if coalesce(btrim(p_title), '') = '' then raise exception 'Say what you''re predicting.'; end if;
  if coalesce(btrim(p_with_name), '') = '' then raise exception 'Add who''s taking the other side.'; end if;
  if p_invited = auth.uid() then raise exception 'You can''t predict against yourself.'; end if;
  if p_invited is null and not coalesce(p_shook, false) then
    if digits is null or digits !~ '^[0-9]{8,15}$' then
      raise exception 'Add their mobile number so only they can shake on it.'; end if;
    if digits = _my_phone() then raise exception 'That''s your own number. Add theirs.'; end if;
  end if;
  if not coalesce(p_shook, false) and p_shake_by is not null and p_shake_by <= now() then
    raise exception 'Pick a shake-by time that hasn''t passed yet.'; end if;
  if p_stake_kind = 'points' and (p_points is null or p_points < 1 or p_points > 1000) then
    raise exception 'Put between 1 and 1,000 points on the line.'; end if;
  if p_stake_kind = 'other' and coalesce(btrim(p_stake_text), '') = '' then
    raise exception 'Say what the loser owes.'; end if;
  insert into predictions (title, category, stake_kind, points, stake_text, due, terms,
    a_uid, a_name, b_name, b_invited, b_proxy, status, shake_by, log)
  values (btrim(p_title), coalesce(nullif(p_category, ''), 'Other'), p_stake_kind,
    case when p_stake_kind = 'points' then p_points else 0 end,
    case when p_stake_kind = 'other' then btrim(p_stake_text) else '' end,
    p_due, coalesce(btrim(p_terms), ''), auth.uid(), me, btrim(p_with_name), p_invited,
    coalesce(p_shook, false), case when p_shook then 'open' else 'proposed' end,
    case when p_shook then null else p_shake_by end,
    _entry(case when p_shook then 'made the call, shaken on in person' else 'made the call' end))
  returning id into new_id;
  if p_invited is null and digits is not null then
    insert into prediction_invites (prediction_id, phone_digits) values (new_id, digits);
  end if;
  return new_id;
end $$;

-- The person who made a prediction can move its deadline, including after it expires.
create or replace function public.set_shake_by(p_id uuid, p_shake_by timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.a_uid <> auth.uid() then raise exception 'Only the person who made this prediction can change its deadline.'; end if;
  if r.status <> 'proposed' or r.b_uid is not null then raise exception 'It''s already booked, so there''s no deadline to change.'; end if;
  if p_shake_by is null or p_shake_by <= now() then raise exception 'Pick a shake-by time that hasn''t passed yet.'; end if;
  update predictions set shake_by = p_shake_by,
    log = log || _entry('set a new shake-by time') where id = p_id;
end $$;

-- After the deadline nobody can shake on it, counter it, or accept a counter.
-- Withdrawing, declining and moving the deadline still work.
create or replace function public._guard_expired()
returns trigger language plpgsql as $$
begin
  if old.status = 'proposed' and old.shake_by is not null and old.shake_by <= now()
     and new.shake_by is not distinct from old.shake_by then
    if new.status = 'open' then
      raise exception 'This invite has expired. Ask them to set a new shake-by time.'; end if;
    if new.counter_by is not null and (new.counter_by is distinct from old.counter_by
       or new.counter_kind is distinct from old.counter_kind or new.counter_points is distinct from old.counter_points
       or new.counter_text is distinct from old.counter_text) then
      raise exception 'This invite expired, so it can''t be countered. Ask them to set a new shake-by time.'; end if;
  end if;
  return new;
end $$;
drop trigger if exists predictions_guard_expired on public.predictions;
create trigger predictions_guard_expired before update on public.predictions
  for each row execute function public._guard_expired();

revoke all on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz),
  public.set_shake_by(uuid, timestamptz) from public, anon;
grant execute on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz),
  public.set_shake_by(uuid, timestamptz) to authenticated;

-- Tell the API to pick up the new and changed actions right away.
notify pgrst, 'reload schema';

-- ================================================================
-- 24 hours to dispute a result (same as update-dispute-window.sql)
-- ================================================================
alter table public.predictions add column if not exists dispute_by timestamptz;

-- Recording a result starts a 24-hour window for the other side to dispute it.
create or replace function public.report_result(p_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if s is null then raise exception 'Only the two players can record a result.'; end if;
  if r.parent_id is not null then raise exception 'Crashes score themselves with the original.'; end if;
  if r.status not in ('open', 'reported', 'disputed') then raise exception 'This one can''t take a result right now.'; end if;
  if p_winner not in ('a', 'b', 'push', 'void') then raise exception 'Pick who called it.'; end if;
  update predictions set status = 'reported', report_winner = p_winner, report_by = s,
    dispute_by = now() + interval '24 hours',
    log = log || _entry('recorded: ' || case p_winner when 'push' then 'tie' when 'void' then 'call it off'
      when 'a' then a_name || ' won' else b_name || ' won' end)
  where id = p_id;
end $$;

-- Disputes only count inside the 24 hours.
create or replace function public.dispute_result(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if r.status <> 'reported' or s is null or s = r.report_by then
    raise exception 'There''s no result for you to dispute.'; end if;
  if r.dispute_by is not null and now() > r.dispute_by then
    raise exception 'The 24 hours to dispute this result are up, so it counts.'; end if;
  update predictions set status = 'disputed', dispute_by = null,
    log = log || _entry('disputed the result') where id = p_id;
end $$;

-- Results nobody disputed within 24 hours count, exactly as if they had been confirmed.
create or replace function public.settle_overdue()
returns int language plpgsql security definer set search_path = public as $$
declare r predictions; n int := 0;
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
  return n;
end $$;

revoke all on function public.settle_overdue() from public, anon;
grant execute on function public.settle_overdue(), public.report_result(uuid, text), public.dispute_result(uuid) to authenticated;

-- Check every 10 minutes in the background when Supabase's scheduler is available.
-- Without it, overdue results still count the next time anyone opens Handshake.
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('handshake-settle-overdue', '*/10 * * * *', 'select public.settle_overdue()');
exception when others then
  raise notice 'Background checks are not available here; results will count when someone opens Handshake.';
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- ================================================================
-- iPhone app notifications and 24-hour announcements (same as update-app-notifications.sql)
-- ================================================================
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

-- ================================================================
-- Settle up with a rival (same as update-settle-up.sql)
-- ================================================================
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

-- The notify function's server key (service_role) needs to read players, predictions and
-- devices, and remove dead devices. New tables aren't given to any role automatically.
grant usage on schema public to service_role;
grant select, insert, update, delete on
  public.profiles, public.predictions, public.prediction_invites, public.push_subscriptions,
  public.app_push_devices, public.settlements, public.settlement_requests
to service_role;

-- ---------- app icon badge (update-badge.sql) ----------
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

-- ---------- rivals' numbers for Open Messages (update-rival-phones.sql) ----------
create or replace function public.rival_phones()
returns table (prediction_id uuid, phone text)
language sql stable security definer set search_path = public, auth as $$
  with mine as (
    select p.id,
           case when p.a_uid = auth.uid() then coalesce(p.b_uid, p.b_invited) else p.a_uid end as other_uid,
           p.a_uid = auth.uid() as i_made_it
    from public.predictions p
    where auth.uid() in (p.a_uid, p.b_uid, p.b_invited)
  )
  select m.id,
         '+' || coalesce(
           nullif(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'), ''),
           case when m.i_made_it then i.phone_digits end)
  from mine m
  left join auth.users u on u.id = m.other_uid and m.other_uid <> auth.uid()
  left join public.prediction_invites i on i.prediction_id = m.id
  where coalesce(nullif(regexp_replace(coalesce(u.phone, ''), '\D', '', 'g'), ''),
                 case when m.i_made_it then i.phone_digits end) is not null
$$;
revoke all on function public.rival_phones() from public, anon;
grant execute on function public.rival_phones() to authenticated;

-- ================================================================
-- Prove It! (same as update-prove-it.sql)
-- ================================================================
-- How it works:
--   1. A result is recorded. The other side has 24 hours to Confirm or say Prove It!
--   2. Prove It!: the person who recorded the result has 24 hours to post proof
--      (a photo, a video link, or both). No proof in time: the challenger wins.
--   3. Proof posted: the challenger has 24 hours to accept it or say why it doesn't
--      hold up. No answer in time: the result counts.
--   4. It doesn't hold up: a referee is picked automatically — the other person in the
--      most recent done-and-done prediction involving either side (never the two of
--      them, never a name-only rival). The referee has 24 hours to pick the winner.
--      No pick in time, or nobody to referee: the outcome is Hopeless (no points, not
--      counted in anyone's record).

-- ---------- new columns and statuses ----------
alter table public.predictions add column if not exists step_by timestamptz;       -- deadline for the current Prove It! step
alter table public.predictions add column if not exists proof_path text;           -- photo in the "proof" storage bucket
alter table public.predictions add column if not exists proof_link text;           -- video link (iCloud, Google Photos, YouTube...)
alter table public.predictions add column if not exists proof_at timestamptz;
alter table public.predictions add column if not exists objection text;            -- why the proof doesn't hold up
alter table public.predictions add column if not exists referee_uid uuid references public.profiles (id) on delete set null;
alter table public.predictions add column if not exists referee_name text;

alter table public.predictions drop constraint if exists predictions_status_check;
alter table public.predictions add constraint predictions_status_check check (status in
  ('proposed', 'open', 'reported', 'disputed', 'prove', 'proved', 'referee', 'settled', 'void', 'hopeless'));

create index if not exists predictions_step_idx on public.predictions (status, step_by) where step_by is not null;

-- ---------- helpers ----------
-- Who referees: the other person in the most recent done-and-done prediction that
-- involves either side, skipping the two of them and anyone not on Handshake.
create or replace function public._pick_referee(r predictions)
returns uuid language sql stable security definer set search_path = public as $$
  select x.other_uid from (
    select case when p.a_uid in (r.a_uid, r.b_uid) then p.b_uid else p.a_uid end as other_uid, p.decided_at
    from predictions p
    where p.status = 'settled' and p.id <> r.id
      and (p.a_uid in (r.a_uid, r.b_uid) or p.b_uid in (r.a_uid, r.b_uid))
  ) x
  where x.other_uid is not null and x.other_uid <> r.a_uid and x.other_uid is distinct from r.b_uid
  order by x.decided_at desc nulls last
  limit 1
$$;

-- Finish a prediction with a winner (or call it off), and score its crashes the same way.
create or replace function public._finish(p_id uuid, p_result text, p_what text, p_by_handshake boolean)
returns void language plpgsql security definer set search_path = public as $$
declare e jsonb := case when p_by_handshake
    then jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', p_what))
    else _entry(p_what) end;
begin
  if p_result = 'void' then
    update predictions set status = 'void', step_by = null, dispute_by = null, log = log || e where id = p_id;
  else
    update predictions set status = 'settled', winner = p_result, decided_at = now(), step_by = null, dispute_by = null,
      log = log || e where id = p_id;
  end if;
  perform _resolve_crashes(p_id, p_result);
end $$;

-- "Mike won" / "it's a tie" / "call it off", for history lines.
create or replace function public._claim_text(r predictions, w text)
returns text language sql stable as $$
  select case w when 'push' then 'tie' when 'void' then 'call it off' when 'a' then r.a_name || ' won' else r.b_name || ' won' end
$$;

-- ---------- 1. Prove It! ----------
create or replace function public.prove_it(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if r.status <> 'reported' or s is null or s = r.report_by then
    raise exception 'There''s no result for you to challenge.'; end if;
  if r.dispute_by is not null and now() > r.dispute_by then
    raise exception 'The 24 hours to challenge this result are up, so it counts.'; end if;
  if r.report_winner = s then
    raise exception 'This result says you won. Confirm it, or ask them to change it.'; end if;
  update predictions set status = 'prove', dispute_by = null, step_by = now() + interval '24 hours',
    proof_path = null, proof_link = null, proof_at = null, objection = null, referee_uid = null, referee_name = null,
    log = log || _entry('said prove it') where id = p_id;
end $$;

-- Older app builds still call dispute_result; it now starts Prove It!
create or replace function public.dispute_result(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform prove_it(p_id);
end $$;

-- ---------- 2. Post proof ----------
create or replace function public.submit_proof(p_id uuid, p_path text, p_link text)
returns void language plpgsql security definer set search_path = public, storage as $$
declare r predictions := _load(p_id); s text := _side(r);
  path text := nullif(btrim(coalesce(p_path, '')), '');
  link text := nullif(btrim(coalesce(p_link, '')), '');
begin
  if r.status <> 'prove' or s is null or s <> r.report_by then
    raise exception 'There''s no proof for you to post here.'; end if;
  if r.step_by is not null and now() > r.step_by then
    raise exception 'The 24 hours to post proof are up.'; end if;
  if path is null and link is null then raise exception 'Add a photo or a video link.'; end if;
  if path is not null then
    if left(path, 37) <> p_id::text || '/' then raise exception 'That photo isn''t for this prediction.'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'proof' and o.name = path) then
      raise exception 'The photo didn''t finish uploading. Try again.'; end if;
  end if;
  if link is not null and (link !~* '^https?://[^\s/]+\.[^\s]+$' or char_length(link) > 500) then
    raise exception 'That video link doesn''t look right. Paste the full link, starting with https://'; end if;
  update predictions set status = 'proved', proof_path = path, proof_link = link, proof_at = now(),
    step_by = now() + interval '24 hours',
    log = log || _entry('posted proof') where id = p_id;
end $$;

-- ---------- 3. Accept the proof, or say why it doesn't hold up ----------
create or replace function public.answer_proof(p_id uuid, p_accept boolean, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r); why text := btrim(coalesce(p_reason, '')); ref uuid; ref_name text;
begin
  if r.status <> 'proved' or s is null or s = r.report_by then
    raise exception 'There''s no proof for you to answer.'; end if;
  if r.step_by is not null and now() > r.step_by then
    raise exception 'The 24 hours to answer the proof are up, so the result counts.'; end if;
  if p_accept then
    perform _finish(p_id, r.report_winner, 'accepted the proof', false);
    return 'accepted';
  end if;
  if why = '' then raise exception 'Say why the proof doesn''t hold up.'; end if;
  if char_length(why) > 280 then raise exception 'Keep it to 280 characters.'; end if;
  update predictions set objection = why, log = log || _entry('says the proof doesn''t hold up') where id = p_id;
  ref := _pick_referee(r);
  if ref is null then
    update predictions set status = 'hopeless', step_by = null, decided_at = now(),
      log = log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'hopeless: no one could referee'))
    where id = p_id;
    perform _resolve_crashes(p_id, 'void');
    return 'hopeless';
  end if;
  select name into ref_name from profiles where id = ref;
  update predictions set status = 'referee', referee_uid = ref, referee_name = ref_name,
    step_by = now() + interval '24 hours',
    log = log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'picked ' || ref_name || ' to referee'))
  where id = p_id;
  return 'referee';
end $$;

-- ---------- 4. The referee picks ----------
create or replace function public.referee_pick(p_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id);
begin
  if r.status <> 'referee' or r.referee_uid is distinct from auth.uid() then
    raise exception 'You''re not refereeing this one.'; end if;
  if r.step_by is not null and now() > r.step_by then
    raise exception 'The 24 hours to referee are up, so it''s Hopeless.'; end if;
  if p_winner not in ('a', 'b', 'push') then raise exception 'Pick who won, or call it a tie.'; end if;
  perform _finish(p_id, p_winner, 'refereed: ' || _claim_text(r, p_winner), false);
end $$;

-- ---------- the 24-hour clocks ----------
-- Results and settle-ups nobody disputed within 24 hours count, and every Prove It! step
-- that ran out of time moves on.
create or replace function public.settle_overdue()
returns int language plpgsql security definer set search_path = public as $$
declare r predictions; q settlement_requests; n int := 0; challenger text;
begin
  for r in select * from predictions
           where status = 'reported' and dispute_by is not null and dispute_by <= now()
           for update skip locked loop
    if r.report_winner = 'void' then
      perform _finish(r.id, 'void', 'called off after 24 hours with no dispute', true);
    else
      perform _finish(r.id, r.report_winner, 'counted after 24 hours with no dispute', true);
    end if;
    n := n + 1;
  end loop;
  for r in select * from predictions
           where status in ('prove', 'proved', 'referee') and step_by is not null and step_by <= now()
           for update skip locked loop
    challenger := case when r.report_by = 'a' then 'b' else 'a' end;
    if r.status = 'prove' then
      perform _finish(r.id, challenger, 'no proof after 24 hours, so ' || _claim_text(r, challenger), true);
    elsif r.status = 'proved' then
      perform _finish(r.id, r.report_winner, 'proof stood after 24 hours: ' || _claim_text(r, r.report_winner), true);
    else
      update predictions set status = 'hopeless', step_by = null, decided_at = now(),
        log = log || jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'hopeless after 24 hours with no pick from the referee'))
      where id = r.id;
      perform _resolve_crashes(r.id, 'void');
    end if;
    n := n + 1;
  end loop;
  for q in select * from settlement_requests where status = 'pending' and respond_by <= now() for update skip locked loop
    perform _apply_settlement_request(q.id, 'auto');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Predictions finished by a clock and not yet announced (the app hands these to notify).
create or replace function public.pending_auto_announcements()
returns setof uuid language sql stable security definer set search_path = public as $$
  select id from predictions
  where auto_notified = false
    and status in ('settled', 'void', 'hopeless')
    and log->-1->>'by' = 'Handshake'
    and log->-1->>'what' like '%after 24 hours%'
  order by decided_at desc nulls last
  limit 20
$$;

-- The referee's number, for the challenger's "Open Messages" while a referee is deciding.
create or replace function public.referee_phones()
returns table (prediction_id uuid, phone text)
language sql stable security definer set search_path = public, auth as $$
  select p.id, '+' || regexp_replace(u.phone, '\D', '', 'g')
  from public.predictions p
  join auth.users u on u.id = p.referee_uid
  where p.status = 'referee'
    and auth.uid() = case when p.report_by = 'a' then p.b_uid else p.a_uid end
    and coalesce(u.phone, '') <> ''
$$;

-- ---------- proof photos ----------
-- A private bucket. Photos are 5 MB at most (the app shrinks them first).
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proof', 'proof', false, 5242880,
  array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Photos live in a folder named after the prediction.
create or replace function public._proof_prediction(p_folder text)
returns predictions language sql stable security definer set search_path = public as $$
  select p.* from predictions p
  where p.id = case when p_folder ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then p_folder::uuid end
$$;
-- Only the person who recorded the result can upload, and only while proof is due.
create or replace function public.can_post_proof(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.status = 'prove' and auth.uid() = case when p.report_by = 'a' then p.a_uid else p.b_uid end
                   from _proof_prediction(p_folder) p where p.id is not null), false)
$$;
-- The two sides and the referee can see it.
create or replace function public.can_see_proof(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select auth.uid() in (p.a_uid, p.b_uid, p.referee_uid)
                   from _proof_prediction(p_folder) p where p.id is not null), false)
$$;

drop policy if exists "Handshake: post proof" on storage.objects;
create policy "Handshake: post proof" on storage.objects for insert to authenticated
  with check (bucket_id = 'proof' and public.can_post_proof((storage.foldername(name))[1]));
drop policy if exists "Handshake: see proof" on storage.objects;
create policy "Handshake: see proof" on storage.objects for select to authenticated
  using (bucket_id = 'proof' and public.can_see_proof((storage.foldername(name))[1]));

-- ---------- access ----------
revoke all on function public._pick_referee(predictions), public._finish(uuid, text, text, boolean),
  public._claim_text(predictions, text), public._proof_prediction(text) from public, anon, authenticated;
revoke all on function public.prove_it(uuid), public.dispute_result(uuid), public.submit_proof(uuid, text, text),
  public.answer_proof(uuid, boolean, text), public.referee_pick(uuid, text), public.referee_phones(),
  public.can_post_proof(text), public.can_see_proof(text), public.settle_overdue(),
  public.pending_auto_announcements() from public, anon;
grant execute on function public.prove_it(uuid), public.dispute_result(uuid), public.submit_proof(uuid, text, text),
  public.answer_proof(uuid, boolean, text), public.referee_pick(uuid, text), public.referee_phones(),
  public.can_post_proof(text), public.can_see_proof(text), public.settle_overdue(),
  public.pending_auto_announcements() to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- ================================================================
-- Who can see each prediction (same as update-visibility.sql)
-- ================================================================
--   Full Monty (all)          everyone signed in sees it. The default, and what every existing prediction is.
--   Circle of Trust (circle)  the two sides, plus anyone either of them has played before
--                             (a prediction that got past the invite stage).
--   Just the Two of Us (pair) only the two sides.
--
-- The caller picks it when making the call; it can't change after that. Crashes take the
-- original's visibility, and only people who can see a prediction can crash it, so
-- Just the Two of Us can't be crashed. The people in a prediction (including someone invited
-- by phone, and a Prove It! referee) always see it.

alter table public.predictions add column if not exists visibility text not null default 'all';
alter table public.predictions drop constraint if exists predictions_visibility_check;
alter table public.predictions add constraint predictions_visibility_check check (visibility in ('all', 'circle', 'pair'));
create index if not exists predictions_a_uid_idx on public.predictions (a_uid);
create index if not exists predictions_b_uid_idx on public.predictions (b_uid);

-- Can the signed-in player see this prediction?
create or replace function public.can_see_prediction(r predictions)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); par predictions;
begin
  if me is null then return false; end if;
  if r.visibility = 'all' then return true; end if;
  if me in (r.a_uid, r.b_uid, r.b_invited, r.counter_uid, r.referee_uid) then return true; end if;
  if r.b_uid is null and r.b_invited is null and _is_invitee(r) then return true; end if;
  -- a crash is visible to whoever can see the prediction it crashed
  if r.parent_id is not null then
    select * into par from predictions where id = r.parent_id;
    return found and can_see_prediction(par);
  end if;
  if r.visibility = 'circle' then
    return exists (
      select 1 from predictions q
      where q.id <> r.id and q.status <> 'proposed'
        and ((q.a_uid = me and q.b_uid in (r.a_uid, coalesce(r.b_uid, r.b_invited)))
          or (q.b_uid = me and q.a_uid in (r.a_uid, coalesce(r.b_uid, r.b_invited)))));
  end if;
  return false;
end $$;

drop policy if exists "Signed-in players can see the board" on public.predictions;
drop policy if exists "Players see the predictions they're allowed to" on public.predictions;
create policy "Players see the predictions they're allowed to" on public.predictions
  for select to authenticated using (public.can_see_prediction(predictions));

-- New rows: the caller's choice, or the original's for a crash. You can only crash what you can see.
create or replace function public._prediction_visibility()
returns trigger language plpgsql security definer set search_path = public as $$
declare par predictions;
begin
  if new.parent_id is not null then
    select * into par from predictions where id = new.parent_id;
    if found then
      if auth.uid() is not null and not can_see_prediction(par) then
        raise exception 'You can''t crash this one.'; end if;
      new.visibility := par.visibility;
    end if;
  else
    new.visibility := coalesce(nullif(current_setting('handshake.visibility', true), ''), new.visibility, 'all');
  end if;
  return new;
end $$;
drop trigger if exists predictions_visibility on public.predictions;
create trigger predictions_visibility before insert on public.predictions
  for each row execute function public._prediction_visibility();

-- Visibility never changes after the call is made.
create or replace function public._prediction_visibility_locked()
returns trigger language plpgsql as $$
begin
  if new.visibility is distinct from old.visibility then
    raise exception 'Who can see a prediction can''t change after it''s made.'; end if;
  return new;
end $$;
drop trigger if exists predictions_visibility_locked on public.predictions;
create trigger predictions_visibility_locked before update of visibility on public.predictions
  for each row execute function public._prediction_visibility_locked();

-- create_prediction gains a last, optional p_visibility. The previous version keeps doing the
-- work under an internal name, so older app builds (which don't send it) get Full Monty.
do $$
begin
  if to_regprocedure('public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz)') is not null then
    drop function if exists public._create_prediction_core(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz);
    alter function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz)
      rename to _create_prediction_core;
  end if;
end $$;

create or replace function public.create_prediction(
  p_title text, p_with_name text, p_invited uuid, p_category text,
  p_stake_kind text, p_points int, p_stake_text text, p_due date, p_terms text, p_shook boolean,
  p_invited_phone text default null, p_shake_by timestamptz default null, p_visibility text default 'all'
) returns uuid language plpgsql security definer set search_path = public as $$
declare v text := coalesce(nullif(btrim(p_visibility), ''), 'all');
begin
  if v not in ('all', 'circle', 'pair') then raise exception 'Pick who can see it.'; end if;
  perform set_config('handshake.visibility', v, true);
  return _create_prediction_core(p_title, p_with_name, p_invited, p_category, p_stake_kind, p_points,
    p_stake_text, p_due, p_terms, p_shook, p_invited_phone, p_shake_by);
end $$;

revoke all on function public._create_prediction_core(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz),
  public._prediction_visibility(), public._prediction_visibility_locked() from public, anon, authenticated;
revoke all on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz, text),
  public.can_see_prediction(predictions) from public, anon;
grant execute on function public.create_prediction(text, text, uuid, text, text, int, text, date, text, boolean, text, timestamptz, text),
  public.can_see_prediction(predictions) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- ================================================================
-- Standings for everyone + prediction count (same as update-standings.sql)
-- ================================================================
-- Standings are added up here from every finished prediction, including Circle of Trust and
-- Just the Two of Us ones, so everyone sees the same totals. Only the totals come back, never
-- the predictions behind them.

create or replace function public.standings()
returns table (uid uuid, name text, score bigint, w int, l int, t int)
language sql stable security definer set search_path = public as $$
  with sides as (
    select case v.s when 'a' then p.a_uid else coalesce(p.b_uid, p.b_invited) end as uid,
           btrim(case v.s when 'a' then p.a_name else p.b_name end) as nm,
           case when p.winner = 'push' then 't' when p.winner = v.s then 'w' else 'l' end as res,
           case when p.stake_kind = 'points' then greatest(p.points, 0) else 0 end as pts
    from predictions p cross join (values ('a'), ('b')) as v(s)
    where p.status = 'settled' and p.winner is not null
  )
  select s.uid,
         coalesce(max(pr.name), max(s.nm)) as name,
         sum(case s.res when 'w' then s.pts when 'l' then -s.pts else 0 end)::bigint as score,
         count(*) filter (where s.res = 'w')::int as w,
         count(*) filter (where s.res = 'l')::int as l,
         count(*) filter (where s.res = 't')::int as t
  from sides s left join profiles pr on pr.id = s.uid
  group by s.uid, case when s.uid is null then lower(s.nm) end
$$;

-- Every prediction ever made, crashes included. Just a number, so it's fine to show before sign-in.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions
$$;

revoke all on function public.standings(), public.prediction_count() from public;
grant execute on function public.standings() to authenticated;
grant execute on function public.prediction_count() to anon, authenticated;

-- ================================================================
-- Vegas opening lines, NFL (same as update-vegas-lines.sql)
-- ================================================================
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

-- Final scores (filled in by the same function, used to grade Pick 'em All!).
alter table public.vegas_lines add column if not exists home_score int;
alter table public.vegas_lines add column if not exists away_score int;
alter table public.vegas_lines add column if not exists completed boolean not null default false;

-- One row per pull, so the function never pulls more than it should.
create table if not exists public.vegas_pulls (
  id           bigint generated always as identity primary key,
  pulled_at    timestamptz not null default now(),
  games        int,
  credits_left int,
  note         text
);
alter table public.vegas_pulls add column if not exists kind text not null default 'lines';

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

-- Call the puller every hour. It pulls lines once a day (after 6 AM Pacific) and scores only
-- while games are in progress, so most calls do nothing.
create extension if not exists pg_net;
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-vegas-lines') where exists (select 1 from cron.job where jobname = 'handshake-vegas-lines');
  perform cron.schedule('handshake-vegas-lines', '0 * * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/vegas-lines',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;

-- ================================================================
-- Pick 'em All! (same as update-pickem.sql)
-- ================================================================
-- Final scores on the Vegas lines (also in update-vegas-lines.sql).
alter table public.vegas_lines add column if not exists home_score int;
alter table public.vegas_lines add column if not exists away_score int;
alter table public.vegas_lines add column if not exists completed boolean not null default false;
alter table public.vegas_pulls add column if not exists kind text not null default 'lines';

create or replace function public.save_vegas_scores(p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update vegas_lines v set home_score = (r->>'home_score')::int, away_score = (r->>'away_score')::int,
         completed = coalesce((r->>'completed')::boolean, false)
  from jsonb_array_elements(p_rows) r
  where v.id = r->>'id' and not v.completed;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.save_vegas_scores(jsonb) from public, anon, authenticated;
grant execute on function public.save_vegas_scores(jsonb) to service_role;

-- The NFL week a game belongs to: the Tuesday (Pacific) that starts it.
create or replace function public.nfl_week(ts timestamptz)
returns date language sql stable set search_path = public as $$
  select (date_trunc('week', (ts at time zone 'America/Los_Angeles') - interval '1 day') + interval '1 day')::date
$$;

-- The tiebreaker game: the week's last game with an over/under (Monday night).
create or replace function public.pickem_tb_game(p_week date)
returns text language sql stable security definer set search_path = public as $$
  select id from vegas_lines where nfl_week(starts_at) = p_week and total is not null
  order by starts_at desc, id limit 1
$$;

create table if not exists public.pickem_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(btrim(name)) between 1 and 30),
  code        text not null unique,
  created_by  uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.pickem_members (
  group_id   uuid not null references public.pickem_groups (id) on delete cascade,
  uid        uuid not null references public.profiles (id) on delete cascade,
  joined_at  timestamptz not null default now(),
  primary key (group_id, uid)
);
create table if not exists public.pickem_picks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  game_id     text not null references public.vegas_lines (id) on delete cascade,
  side        text not null check (side in ('home', 'away')),
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, game_id)
);
create table if not exists public.pickem_tiebreaks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  week        date not null,
  guess       int not null check (guess between 0 and 200),
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
create table if not exists public.pickem_weeks (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  week        date not null,
  entries     int not null,
  tb_total    int,
  graded_at   timestamptz not null default now(),
  primary key (group_id, week)
);
create table if not exists public.pickem_results (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  week        date not null,
  uid         uuid not null references public.profiles (id) on delete cascade,
  correct     int not null,
  tb_diff     int,
  won         boolean not null default false,
  points      int not null default 0,
  primary key (group_id, week, uid)
);

-- Points booked from a pool are marked so the app can keep them off the Everyone feed.
alter table public.predictions add column if not exists pickem_group uuid references public.pickem_groups (id) on delete set null;

alter table public.pickem_groups enable row level security;
alter table public.pickem_members enable row level security;
alter table public.pickem_picks enable row level security;
alter table public.pickem_tiebreaks enable row level security;
alter table public.pickem_weeks enable row level security;
alter table public.pickem_results enable row level security;

drop policy if exists "signed in can see groups" on public.pickem_groups;
create policy "signed in can see groups" on public.pickem_groups for select to authenticated using (true);
drop policy if exists "signed in can see members" on public.pickem_members;
create policy "signed in can see members" on public.pickem_members for select to authenticated using (true);
drop policy if exists "signed in can see weeks" on public.pickem_weeks;
create policy "signed in can see weeks" on public.pickem_weeks for select to authenticated using (true);
drop policy if exists "signed in can see results" on public.pickem_results;
create policy "signed in can see results" on public.pickem_results for select to authenticated using (true);
-- Your own picks always; everyone else's only once that game has kicked off.
drop policy if exists "picks after kickoff" on public.pickem_picks;
create policy "picks after kickoff" on public.pickem_picks for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = game_id and v.starts_at <= now()));
drop policy if exists "tiebreaks after kickoff" on public.pickem_tiebreaks;
create policy "tiebreaks after kickoff" on public.pickem_tiebreaks for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = public.pickem_tb_game(week) and v.starts_at <= now()));

-- The invite code is only for members. Everyone else reads groups without it.
revoke select on public.pickem_groups from authenticated;
grant select (id, name, created_by, created_at) on public.pickem_groups to authenticated;
grant select on public.pickem_members, public.pickem_picks, public.pickem_tiebreaks, public.pickem_weeks, public.pickem_results to authenticated;
grant all on public.pickem_groups, public.pickem_members, public.pickem_picks, public.pickem_tiebreaks, public.pickem_weeks, public.pickem_results to service_role;

-- Invite codes for the groups you're in.
create or replace function public.my_pickem_codes()
returns table (group_id uuid, code text) language sql stable security definer set search_path = public as $$
  select g.id, g.code from pickem_groups g join pickem_members m on m.group_id = g.id and m.uid = auth.uid()
$$;

create or replace function public.create_pickem_group(p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid; c text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_name, ''))) not between 1 and 30 then
    raise exception 'Give the group a name (up to 30 characters).'; end if;
  loop
    c := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from pickem_groups where code = c);
  end loop;
  insert into pickem_groups (name, code, created_by) values (btrim(p_name), c, me) returning id into gid;
  insert into pickem_members (group_id, uid) values (gid, me);
  return gid;
end $$;

create or replace function public.join_pickem_group(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into gid from pickem_groups where code = upper(btrim(coalesce(p_code, '')));
  if gid is null then raise exception 'That invite code doesn''t match any group.'; end if;
  insert into pickem_members (group_id, uid) values (gid, me) on conflict do nothing;
  return gid;
end $$;

-- Pick a side (or p_side null to clear it). Locks at kickoff.
create or replace function public.save_pickem_pick(p_group uuid, p_game text, p_side text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null then raise exception 'That game has no line to pick against.'; end if;
  if g.starts_at <= now() then raise exception 'That game has kicked off. Picks are locked.'; end if;
  if p_side is null then
    delete from pickem_picks where group_id = p_group and uid = me and game_id = p_game;
  elsif p_side in ('home', 'away') then
    insert into pickem_picks (group_id, uid, game_id, side) values (p_group, me, p_game, p_side)
    on conflict (group_id, uid, game_id) do update set side = excluded.side, updated_at = now();
  else raise exception 'Pick home or away.'; end if;
end $$;

-- Tiebreaker: total points in the week's last game. Locks at that game's kickoff.
create or replace function public.save_pickem_tiebreak(p_group uuid, p_week date, p_guess int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); tb vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into tb from vegas_lines where id = pickem_tb_game(p_week);
  if not found then raise exception 'The tiebreaker game isn''t posted yet.'; end if;
  if tb.starts_at <= now() then raise exception 'The tiebreaker game has kicked off. It''s locked.'; end if;
  if p_guess is null then
    delete from pickem_tiebreaks where group_id = p_group and uid = me and week = p_week;
  elsif p_guess between 0 and 200 then
    insert into pickem_tiebreaks (group_id, uid, week, guess) values (p_group, me, p_week, p_guess)
    on conflict (group_id, uid, week) do update set guess = excluded.guess, updated_at = now();
  else raise exception 'Guess a total between 0 and 200.'; end if;
end $$;

-- Score every finished week that hasn't been scored yet. Runs hourly and after each scores pull.
create or replace function public.grade_pickem()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; w record; l record; grp pickem_groups; tbg vegas_lines;
  n int; nw int; nl int; done int := 0; tb_total int; best int; best_diff int; winners text; title text;
begin
  for r in
    select distinct x.group_id, x.week from (
      select p.group_id, nfl_week(v.starts_at) as week from pickem_picks p join vegas_lines v on v.id = p.game_id
      union select t.group_id, t.week from pickem_tiebreaks t) x
    where not exists (select 1 from pickem_weeks k where k.group_id = x.group_id and k.week = x.week)
      and now() >= x.week + 6                                    -- Monday of that week, at the earliest
      and not exists (select 1 from vegas_lines v                  -- every game final (or 3+ days stale)
                      where nfl_week(v.starts_at) = x.week and v.home_spread is not null
                        and not v.completed and v.starts_at > now() - interval '3 days')
  loop
    select * into grp from pickem_groups where id = r.group_id;
    select * into tbg from vegas_lines where id = pickem_tb_game(r.week);
    tb_total := case when tbg.completed then tbg.home_score + tbg.away_score end;

    insert into pickem_results (group_id, week, uid, correct, tb_diff)
    select r.group_id, r.week, e.uid,
      (select count(*) from pickem_picks p join vegas_lines v on v.id = p.game_id
        where p.group_id = r.group_id and p.uid = e.uid and nfl_week(v.starts_at) = r.week and v.completed
          and ((p.side = 'home' and v.home_score - v.away_score + v.home_spread > 0)
            or (p.side = 'away' and v.home_score - v.away_score + v.home_spread < 0))),
      (select abs(t.guess - tb_total) from pickem_tiebreaks t where t.group_id = r.group_id and t.uid = e.uid and t.week = r.week)
    from (select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id
           where p.group_id = r.group_id and nfl_week(v.starts_at) = r.week
          union select t.uid from pickem_tiebreaks t where t.group_id = r.group_id and t.week = r.week) e
    join pickem_members m on m.group_id = r.group_id and m.uid = e.uid
    on conflict do nothing;
    get diagnostics n = row_count;

    if n >= 2 then
      select max(correct) into best from pickem_results where group_id = r.group_id and week = r.week;
      select min(coalesce(tb_diff, 100000)) into best_diff from pickem_results where group_id = r.group_id and week = r.week and correct = best;
      update pickem_results set won = true
        where group_id = r.group_id and week = r.week and correct = best and coalesce(tb_diff, 100000) = best_diff;
      select count(*) filter (where won), count(*) filter (where not won) into nw, nl
        from pickem_results where group_id = r.group_id and week = r.week;
      if nl > 0 then
        update pickem_results set points = case when won then 5 * nl else -5 * nw end
          where group_id = r.group_id and week = r.week;
        select string_agg(pr.name, ' and ' order by pr.name) into winners
          from pickem_results x join profiles pr on pr.id = x.uid where x.group_id = r.group_id and x.week = r.week and x.won;
        title := left('Pick ''em All! · ' || grp.name || ' · week of ' || to_char(r.week, 'Mon FMDD'), 90);
        for w in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                 where x.group_id = r.group_id and x.week = r.week and x.won loop
          for l in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                   where x.group_id = r.group_id and x.week = r.week and not x.won loop
            insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                                     status, winner, visibility, auto_notified, decided_at, pickem_group, log)
            values (title, 'Pick ''em', 'points', 5, r.week + 6,
                    left(winners || ' won the week with ' || best || ' right' || case when best_diff < 100000 and tb_total is not null then ' (tiebreaker off by ' || best_diff || ')' else '' end || '. ' || n || ' entries.', 240),
                    w.uid, w.name, l.uid, l.name, l.uid, 'settled', 'a', 'pair', true, now(), r.group_id,
                    jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake',
                      'what', 'pick ''em All! week counted: ' || winners || ' won (' || grp.name || ')')));
          end loop;
        end loop;
      end if;
    end if;

    insert into pickem_weeks (group_id, week, entries, tb_total) values (r.group_id, r.week, n, tb_total);
    done := done + 1;
  end loop;
  return done;
end $$;

revoke all on function public.my_pickem_codes(), public.create_pickem_group(text), public.join_pickem_group(text),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int), public.grade_pickem(),
  public.pickem_tb_game(date) from public, anon;
grant execute on function public.my_pickem_codes(), public.create_pickem_group(text), public.join_pickem_group(text),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int), public.pickem_tb_game(date) to authenticated;
grant execute on function public.grade_pickem() to service_role;
grant execute on function public.nfl_week(timestamptz) to authenticated, service_role;

-- "Predictions and Counting!" counts calls people made, not points booked by a pool.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null
$$;

-- Check for finished weeks every hour, and call the lines/scores puller every hour.
-- (The puller itself only pulls lines once a day and scores only while games are in progress.)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-pickem-grade') where exists (select 1 from cron.job where jobname = 'handshake-pickem-grade');
  perform cron.schedule('handshake-pickem-grade', '7 * * * *', 'select public.grade_pickem()');
  perform cron.unschedule('handshake-vegas-lines') where exists (select 1 from cron.job where jobname = 'handshake-vegas-lines');
  perform cron.schedule('handshake-vegas-lines', '0 * * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/vegas-lines',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;

-- ================================================================
-- Pick 'em All! crash requests, bonus game, rollovers (same as update-pickem-2.sql)
-- ================================================================
-- Bonus game picks
create table if not exists public.pickem_bonus (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  week        date not null,
  game_id     text not null references public.vegas_lines (id) on delete cascade,
  updated_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
-- Crash requests
create table if not exists public.pickem_crash_requests (
  group_id     uuid not null references public.pickem_groups (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (group_id, uid)
);
-- Points moved per person per week (what the group card adds up)
create table if not exists public.pickem_ledger (
  group_id  uuid not null references public.pickem_groups (id) on delete cascade,
  week      date not null,
  uid       uuid not null references public.profiles (id) on delete cascade,
  points    int not null,
  primary key (group_id, week, uid)
);
-- Antes waiting in a rolled-over pot (paid_week is set once someone wins)
create table if not exists public.pickem_carry (
  group_id   uuid not null references public.pickem_groups (id) on delete cascade,
  week       date not null,
  uid        uuid not null references public.profiles (id) on delete cascade,
  paid_week  date,
  primary key (group_id, week, uid)
);

alter table public.pickem_results add column if not exists score int not null default 0;
alter table public.pickem_results add column if not exists bonus_right boolean not null default false;
alter table public.pickem_weeks add column if not exists games int;
alter table public.pickem_weeks add column if not exists best int;
alter table public.pickem_weeks add column if not exists rolled boolean not null default false;
alter table public.pickem_weeks add column if not exists pot int not null default 0;

-- Weeks scored before this update: copy their points into the ledger.
update public.pickem_results set score = correct where score = 0 and correct > 0;
insert into public.pickem_ledger (group_id, week, uid, points)
select group_id, week, uid, points from public.pickem_results where points <> 0
on conflict do nothing;

alter table public.pickem_bonus enable row level security;
alter table public.pickem_crash_requests enable row level security;
alter table public.pickem_ledger enable row level security;
alter table public.pickem_carry enable row level security;

drop policy if exists "bonus after kickoff" on public.pickem_bonus;
create policy "bonus after kickoff" on public.pickem_bonus for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.vegas_lines v where v.id = game_id and v.starts_at <= now()));
drop policy if exists "own or my group's requests" on public.pickem_crash_requests;
create policy "own or my group's requests" on public.pickem_crash_requests for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.pickem_groups g where g.id = group_id and g.created_by = auth.uid()));
drop policy if exists "signed in can see ledger" on public.pickem_ledger;
create policy "signed in can see ledger" on public.pickem_ledger for select to authenticated using (true);
drop policy if exists "signed in can see carry" on public.pickem_carry;
create policy "signed in can see carry" on public.pickem_carry for select to authenticated using (true);

grant select on public.pickem_bonus, public.pickem_crash_requests, public.pickem_ledger, public.pickem_carry to authenticated;
grant all on public.pickem_bonus, public.pickem_crash_requests, public.pickem_ledger, public.pickem_carry to service_role;

-- Star one game as your bonus for its week (p_game null clears it). Locks at kickoff.
create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines; cur text;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select b.game_id into cur from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week;
  if cur is not null and exists (select 1 from vegas_lines where id = cur and starts_at <= now()) then
    raise exception 'Your bonus game has kicked off. It''s locked.'; end if;
  if p_game is null then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week;
    return;
  end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null or nfl_week(g.starts_at) <> p_week then raise exception 'That game isn''t in this week''s pool.'; end if;
  if g.starts_at <= now() then raise exception 'That game has kicked off. Pick another bonus game.'; end if;
  insert into pickem_bonus (group_id, uid, week, game_id) values (p_group, me, p_week, p_game)
  on conflict (group_id, uid, week) do update set game_id = excluded.game_id, updated_at = now();
end $$;

-- Ask to crash a group you're not in.
create or replace function public.request_pickem_crash(p_group uuid)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from pickem_groups where id = p_group) then raise exception 'That group is gone.'; end if;
  if exists (select 1 from pickem_members where group_id = p_group and uid = me) then raise exception 'You''re already in this group.'; end if;
  insert into pickem_crash_requests (group_id, uid) values (p_group, me)
  on conflict (group_id, uid) do update set status = 'pending', created_at = now(), answered_at = null;
end $$;

-- The group's creator lets them in (or not).
create or replace function public.answer_pickem_crash(p_group uuid, p_uid uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from pickem_groups where id = p_group and created_by = auth.uid()) then
    raise exception 'Only the person who started the group can answer.'; end if;
  update pickem_crash_requests set status = case when p_accept then 'accepted' else 'declined' end, answered_at = now()
  where group_id = p_group and uid = p_uid and status = 'pending';
  if not found then raise exception 'That request was already answered.'; end if;
  if p_accept then insert into pickem_members (group_id, uid) values (p_group, p_uid) on conflict do nothing; end if;
end $$;

-- Joining with the code also clears any open crash request.
create or replace function public.join_pickem_group(p_code text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); gid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select id into gid from pickem_groups where code = upper(btrim(coalesce(p_code, '')));
  if gid is null then raise exception 'That invite code doesn''t match any group.'; end if;
  insert into pickem_members (group_id, uid) values (gid, me) on conflict do nothing;
  update pickem_crash_requests set status = 'accepted', answered_at = now() where group_id = gid and uid = me and status = 'pending';
  return gid;
end $$;

-- Score every finished week that hasn't been scored yet. Runs hourly and after each scores pull.
create or replace function public.grade_pickem()
returns int language plpgsql security definer set search_path = public as $$
declare
  r record; w record; l record; grp pickem_groups; tbg vegas_lines;
  n int; nw int; nl int; done int := 0; tb_total int; best int; best_diff int; games int;
  winners text; title text; pts int; carried int; pot int;
begin
  for r in
    select distinct x.group_id, x.week from (
      select p.group_id, nfl_week(v.starts_at) as week from pickem_picks p join vegas_lines v on v.id = p.game_id
      union select t.group_id, t.week from pickem_tiebreaks t
      union select b.group_id, b.week from pickem_bonus b) x
    where not exists (select 1 from pickem_weeks k where k.group_id = x.group_id and k.week = x.week)
      and now() >= x.week + 6                                    -- Monday of that week, at the earliest
      and not exists (select 1 from vegas_lines v                  -- every game final (or 3+ days stale)
                      where nfl_week(v.starts_at) = x.week and v.home_spread is not null
                        and not v.completed and v.starts_at > now() - interval '3 days')
    order by x.week
  loop
    select * into grp from pickem_groups where id = r.group_id;
    select * into tbg from vegas_lines where id = pickem_tb_game(r.week);
    tb_total := case when tbg.completed then tbg.home_score + tbg.away_score end;
    -- games that count toward "half right": final and not on the number
    select count(*) into games from vegas_lines v
     where nfl_week(v.starts_at) = r.week and v.home_spread is not null and v.completed
       and v.home_score - v.away_score + v.home_spread <> 0;

    insert into pickem_results (group_id, week, uid, correct, bonus_right, score, tb_diff)
    select r.group_id, r.week, e.uid, c.correct, c.bonus_right, c.correct + c.bonus_right::int,
      (select abs(t.guess - tb_total) from pickem_tiebreaks t where t.group_id = r.group_id and t.uid = e.uid and t.week = r.week)
    from (select p.uid from pickem_picks p join vegas_lines v on v.id = p.game_id
           where p.group_id = r.group_id and nfl_week(v.starts_at) = r.week
          union select t.uid from pickem_tiebreaks t where t.group_id = r.group_id and t.week = r.week
          union select b.uid from pickem_bonus b where b.group_id = r.group_id and b.week = r.week) e
    join pickem_members m on m.group_id = r.group_id and m.uid = e.uid
    cross join lateral (
      select count(*)::int as correct, coalesce(bool_or(p.game_id = bo.game_id), false) as bonus_right
      from pickem_picks p join vegas_lines v on v.id = p.game_id
      left join pickem_bonus bo on bo.group_id = p.group_id and bo.uid = p.uid and bo.week = r.week
      where p.group_id = r.group_id and p.uid = e.uid and nfl_week(v.starts_at) = r.week and v.completed
        and ((p.side = 'home' and v.home_score - v.away_score + v.home_spread > 0)
          or (p.side = 'away' and v.home_score - v.away_score + v.home_spread < 0))) c
    on conflict do nothing;
    get diagnostics n = row_count;
    pot := 0; best := null;

    if n >= 2 then
      select max(score) into best from pickem_results where group_id = r.group_id and week = r.week;
      select min(coalesce(tb_diff, 100000)) into best_diff from pickem_results where group_id = r.group_id and week = r.week and score = best;
      -- winners: top score, closest tiebreaker, and at least half the games right
      update pickem_results set won = true
        where group_id = r.group_id and week = r.week and score = best and coalesce(tb_diff, 100000) = best_diff
          and correct * 2 >= games;
      select count(*) filter (where won), count(*) filter (where not won) into nw, nl
        from pickem_results where group_id = r.group_id and week = r.week;

      if nw = 0 then
        -- nobody got half right: every entry's ante rolls over
        insert into pickem_carry (group_id, week, uid)
        select group_id, week, uid from pickem_results where group_id = r.group_id and week = r.week
        on conflict do nothing;
        insert into pickem_weeks (group_id, week, entries, tb_total, games, best, rolled)
        values (r.group_id, r.week, n, tb_total, games, best, true);
        done := done + 1;
        continue;
      end if;

      if nl > 0 or exists (select 1 from pickem_carry where group_id = r.group_id and paid_week is null) then
        select string_agg(pr.name, ' and ' order by pr.name) into winners
          from pickem_results x join profiles pr on pr.id = x.uid where x.group_id = r.group_id and x.week = r.week and x.won;
        title := left('Pick ''em All! · ' || grp.name || ' · week of ' || to_char(r.week, 'Mon FMDD'), 90);
        -- everyone who owes: this week's losers, plus rolled antes from anyone who isn't a winner now
        for l in
          select o.uid, pr.name, sum(o.antes)::int as antes, sum(o.rolled)::int as rolled from (
            select x.uid, 1 as antes, 0 as rolled from pickem_results x where x.group_id = r.group_id and x.week = r.week and not x.won
            union all
            select c.uid, 1, 1 from pickem_carry c where c.group_id = r.group_id and c.paid_week is null
              and not exists (select 1 from pickem_results x where x.group_id = r.group_id and x.week = r.week and x.uid = c.uid and x.won)
          ) o join profiles pr on pr.id = o.uid group by o.uid, pr.name
        loop
          pts := 5 * l.antes;
          for w in select x.uid, pr.name from pickem_results x join profiles pr on pr.id = x.uid
                   where x.group_id = r.group_id and x.week = r.week and x.won loop
            insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                                     status, winner, visibility, auto_notified, decided_at, pickem_group, log)
            values (title, 'Pick ''em', 'points', pts, r.week + 6,
                    left(winners || ' won the week: ' || best || ' right counting the bonus game, out of ' || games || ' games (' || n || ' entries)'
                         || case when l.rolled > 0 then '. Includes ' || 5 * l.rolled || ' pts rolled over from earlier weeks' else '' end || '.', 240),
                    w.uid, w.name, l.uid, l.name, l.uid, 'settled', 'a', 'pair', true, now(), r.group_id,
                    jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake',
                      'what', 'pick ''em All! week counted: ' || winners || ' won (' || grp.name || ')')));
            insert into pickem_ledger (group_id, week, uid, points) values (r.group_id, r.week, w.uid, pts)
              on conflict (group_id, week, uid) do update set points = pickem_ledger.points + excluded.points;
            insert into pickem_ledger (group_id, week, uid, points) values (r.group_id, r.week, l.uid, -pts)
              on conflict (group_id, week, uid) do update set points = pickem_ledger.points + excluded.points;
            pot := pot + pts;
          end loop;
        end loop;
        update pickem_carry set paid_week = r.week where group_id = r.group_id and paid_week is null;
        update pickem_results x set points = coalesce((select g.points from pickem_ledger g
                 where g.group_id = x.group_id and g.week = x.week and g.uid = x.uid), 0)
          where x.group_id = r.group_id and x.week = r.week;
      end if;
    end if;

    insert into pickem_weeks (group_id, week, entries, tb_total, games, best, pot) values (r.group_id, r.week, n, tb_total, games, best, pot);
    done := done + 1;
  end loop;
  return done;
end $$;

revoke all on function public.save_pickem_bonus(uuid, date, text), public.request_pickem_crash(uuid),
  public.answer_pickem_crash(uuid, uuid, boolean), public.join_pickem_group(text), public.grade_pickem() from public, anon;
grant execute on function public.save_pickem_bonus(uuid, date, text), public.request_pickem_crash(uuid),
  public.answer_pickem_crash(uuid, uuid, boolean), public.join_pickem_group(text) to authenticated;
grant execute on function public.grade_pickem() to service_role;

-- ================================================================
-- Pick 'em All! Submit, Picks in, Sunday lock (same as update-pickem-3.sql)
-- ================================================================
-- The week's first Sunday kickoff (Pacific), or null if the week has no Sunday games.
create or replace function public.pickem_week_lock(p_week date)
returns timestamptz language sql stable security definer set search_path = public as $$
  select min(starts_at) from vegas_lines
  where nfl_week(starts_at) = p_week and home_spread is not null
    and extract(dow from starts_at at time zone 'America/Los_Angeles') = 0
$$;

-- When a game's pick locks: its kickoff, or the first Sunday kickoff if that comes first.
create or replace function public.pickem_lock_at(p_game text)
returns timestamptz language sql stable security definer set search_path = public as $$
  select least(v.starts_at, coalesce(pickem_week_lock(nfl_week(v.starts_at)), v.starts_at))
  from vegas_lines v where v.id = p_game
$$;

-- When the tiebreaker locks: the first Sunday kickoff, or the tiebreaker game's own kickoff.
create or replace function public.pickem_tb_lock(p_week date)
returns timestamptz language sql stable security definer set search_path = public as $$
  select pickem_lock_at(pickem_tb_game(p_week))
$$;

create table if not exists public.pickem_submissions (
  group_id      uuid not null references public.pickem_groups (id) on delete cascade,
  uid           uuid not null references public.profiles (id) on delete cascade,
  week          date not null,
  submitted_at  timestamptz not null default now(),
  primary key (group_id, uid, week)
);
alter table public.pickem_submissions enable row level security;
drop policy if exists "signed in can see submissions" on public.pickem_submissions;
create policy "signed in can see submissions" on public.pickem_submissions for select to authenticated using (true);
grant select on public.pickem_submissions to authenticated;
grant all on public.pickem_submissions to service_role;

-- Others' picks, tiebreakers and bonus games show once they lock.
drop policy if exists "picks after kickoff" on public.pickem_picks;
create policy "picks after kickoff" on public.pickem_picks for select to authenticated using (
  uid = auth.uid() or public.pickem_lock_at(game_id) <= now());
drop policy if exists "tiebreaks after kickoff" on public.pickem_tiebreaks;
create policy "tiebreaks after kickoff" on public.pickem_tiebreaks for select to authenticated using (
  uid = auth.uid() or public.pickem_tb_lock(week) <= now());
drop policy if exists "bonus after kickoff" on public.pickem_bonus;
create policy "bonus after kickoff" on public.pickem_bonus for select to authenticated using (
  uid = auth.uid() or public.pickem_lock_at(game_id) <= now()
  or coalesce(public.pickem_week_lock(week) <= now(), false));

create or replace function public.save_pickem_pick(p_group uuid, p_game text, p_side text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null then raise exception 'That game has no line to pick against.'; end if;
  if pickem_lock_at(p_game) <= now() then raise exception 'That pick is locked.'; end if;
  if p_side is null then
    delete from pickem_picks where group_id = p_group and uid = me and game_id = p_game;
  elsif p_side in ('home', 'away') then
    insert into pickem_picks (group_id, uid, game_id, side) values (p_group, me, p_game, p_side)
    on conflict (group_id, uid, game_id) do update set side = excluded.side, updated_at = now();
  else raise exception 'Pick home or away.'; end if;
end $$;

create or replace function public.save_pickem_tiebreak(p_group uuid, p_week date, p_guess int)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  if pickem_tb_game(p_week) is null then raise exception 'The tiebreaker game isn''t posted yet.'; end if;
  if pickem_tb_lock(p_week) <= now() then raise exception 'The tiebreaker is locked.'; end if;
  if p_guess is null then
    delete from pickem_tiebreaks where group_id = p_group and uid = me and week = p_week;
  elsif p_guess between 0 and 200 then
    insert into pickem_tiebreaks (group_id, uid, week, guess) values (p_group, me, p_week, p_guess)
    on conflict (group_id, uid, week) do update set guess = excluded.guess, updated_at = now();
  else raise exception 'Guess a total between 0 and 200.'; end if;
end $$;

create or replace function public.save_pickem_bonus(p_group uuid, p_week date, p_game text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g vegas_lines; cur text;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  select b.game_id into cur from pickem_bonus b where b.group_id = p_group and b.uid = me and b.week = p_week;
  if cur is not null and pickem_lock_at(cur) <= now() then raise exception 'Your bonus game is locked.'; end if;
  if p_game is null then
    delete from pickem_bonus where group_id = p_group and uid = me and week = p_week;
    return;
  end if;
  select * into g from vegas_lines where id = p_game;
  if not found or g.home_spread is null or nfl_week(g.starts_at) <> p_week then raise exception 'That game isn''t in this week''s pool.'; end if;
  if pickem_lock_at(p_game) <= now() then raise exception 'That game is locked. Pick another bonus game.'; end if;
  insert into pickem_bonus (group_id, uid, week, game_id) values (p_group, me, p_week, p_game)
  on conflict (group_id, uid, week) do update set game_id = excluded.game_id, updated_at = now();
end $$;

-- Submit your picks for the week: every game that's still open picked, plus the tiebreaker.
create or replace function public.submit_pickem_week(p_group uuid, p_week date)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); missing int; t timestamptz;
begin
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then
    raise exception 'Join the group to make picks.'; end if;
  if not exists (select 1 from vegas_lines where nfl_week(starts_at) = p_week and home_spread is not null) then
    raise exception 'There are no games for that week yet.'; end if;
  if not exists (select 1 from vegas_lines v where nfl_week(v.starts_at) = p_week and v.home_spread is not null
                 and pickem_lock_at(v.id) > now()) then
    raise exception 'This week''s picks are already locked.'; end if;
  select count(*) into missing from vegas_lines v
   where nfl_week(v.starts_at) = p_week and v.home_spread is not null and pickem_lock_at(v.id) > now()
     and not exists (select 1 from pickem_picks p where p.group_id = p_group and p.uid = me and p.game_id = v.id);
  if missing > 0 then raise exception 'Pick every game first (% still open without a pick).', missing; end if;
  if pickem_tb_lock(p_week) > now() and not exists
     (select 1 from pickem_tiebreaks t where t.group_id = p_group and t.uid = me and t.week = p_week) then
    raise exception 'Add your tiebreaker first.'; end if;
  insert into pickem_submissions (group_id, uid, week) values (p_group, me, p_week)
  on conflict (group_id, uid, week) do update set submitted_at = now()
  returning submitted_at into t;
  return t;
end $$;

revoke all on function public.pickem_week_lock(date), public.pickem_lock_at(text), public.pickem_tb_lock(date),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int),
  public.save_pickem_bonus(uuid, date, text), public.submit_pickem_week(uuid, date) from public, anon;
grant execute on function public.pickem_week_lock(date), public.pickem_lock_at(text), public.pickem_tb_lock(date),
  public.save_pickem_pick(uuid, text, text), public.save_pickem_tiebreak(uuid, date, int),
  public.save_pickem_bonus(uuid, date, text), public.submit_pickem_week(uuid, date) to authenticated;

-- ================================================================
-- Golf: Wolf (same as update-wolf.sql)
-- ================================================================
create table if not exists public.wolf_rounds (
  id           uuid primary key default gen_random_uuid(),
  course       text not null default '' check (char_length(course) <= 40),
  players      jsonb not null,             -- [{uid, name}] x4, in tee order (Wolf order)
  created_by   uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'playing' check (status in ('playing', 'finished')),
  created_at   timestamptz not null default now(),
  finished_at  timestamptz
);
create table if not exists public.wolf_holes (
  round_id    uuid not null references public.wolf_rounds (id) on delete cascade,
  hole        int not null check (hole between 1 and 18),
  mode        text check (mode in ('partner', 'lone', 'blind')),
  partner     int check (partner between 0 and 3),
  scores      int[] not null default '{NULL,NULL,NULL,NULL}',
  greenie     int[] not null default '{}',
  birdie      int[] not null default '{}',
  sandy       int[] not null default '{}',
  pressed_by  int check (pressed_by between 0 and 3),
  updated_by  uuid,
  updated_at  timestamptz not null default now(),
  primary key (round_id, hole)
);
alter table public.predictions add column if not exists wolf_round uuid references public.wolf_rounds (id) on delete set null;

create or replace function public.wolf_is_player(p_round uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from wolf_rounds r, jsonb_array_elements(r.players) e
                 where r.id = p_round and e->>'uid' = auth.uid()::text)
$$;

alter table public.wolf_rounds enable row level security;
alter table public.wolf_holes enable row level security;
drop policy if exists "players see rounds" on public.wolf_rounds;
create policy "players see rounds" on public.wolf_rounds for select to authenticated using (public.wolf_is_player(id));
drop policy if exists "players see holes" on public.wolf_holes;
create policy "players see holes" on public.wolf_holes for select to authenticated using (public.wolf_is_player(round_id));
grant select on public.wolf_rounds, public.wolf_holes to authenticated;
grant all on public.wolf_rounds, public.wolf_holes to service_role;

-- The scoring engine: one row per hole, in order. pay[i*4+j+1] = points player i pays player j
-- on that hole. d0..d3 = each player's net for the hole. Only complete holes score.
create or replace function public.wolf_compute(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, pay int[], d0 int, d1 int, d2 int, d3 int)
language plpgsql stable security definer set search_path = public as $$
declare
  h wolf_holes; carry int := 0; np int := 0; m int; u int; w int; p int;
  a int; b int; i int; j int; others int[]; team int[]; opp int[]; names text[]; won int[]; lost int[];
  pa int[]; dd int[]; bon int; txt text;
begin
  select array_agg(e->>'name' order by o) into names
    from wolf_rounds r, jsonb_array_elements(r.players) with ordinality x(e, o) where r.id = p_round;
  for h in select * from wolf_holes x where x.round_id = p_round order by x.hole loop
    if h.pressed_by is not null then np := np + 1; end if;
    w := (h.hole - 1) % 4;
    pa := array_fill(0, array[16]); txt := null; u := null;
    complete := h.mode is not null and cardinality(h.scores) = 4 and array_position(h.scores, null) is null
                and (h.mode <> 'partner' or (h.partner is not null and h.partner <> w));
    carry_in := carry;
    if complete then
      m := case h.mode when 'blind' then 2 else 1 end;
      u := (1 + carry) * m * (2 ^ np)::int;
      if h.mode = 'partner' then
        team := array[w, h.partner];
        opp := array(select g from generate_series(0, 3) g where g <> all (team));
        a := least(h.scores[team[1] + 1], h.scores[team[2] + 1]);
        b := least(h.scores[opp[1] + 1], h.scores[opp[2] + 1]);
        if a = b then won := null; else
          if a < b then won := team; lost := opp; else won := opp; lost := team; end if;
          foreach i in array lost loop foreach j in array won loop pa[i * 4 + j + 1] := pa[i * 4 + j + 1] + u; end loop; end loop;
          txt := names[won[1] + 1] || ' & ' || names[won[2] + 1] || ' won';
        end if;
      else
        others := array(select g from generate_series(0, 3) g where g <> w);
        a := h.scores[w + 1];
        b := least(h.scores[others[1] + 1], h.scores[others[2] + 1], h.scores[others[3] + 1]);
        if a < b then
          foreach i in array others loop pa[i * 4 + w + 1] := pa[i * 4 + w + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'Lone' else 'Blind' end || ' Wolf ' || names[w + 1] || ' won';
        elsif a > b then
          foreach j in array others loop pa[w * 4 + j + 1] := pa[w * 4 + j + 1] + u; end loop;
          txt := 'The pack beat ' || case h.mode when 'lone' then 'Lone' else 'Blind' end || ' Wolf ' || names[w + 1];
        end if;
      end if;
      if txt is null then carry := carry + 1; txt := 'Tied: 1 point rolls over'; else carry := 0; end if;
      -- bonuses: 1 from each other player, never multiplied
      foreach bon in array h.greenie || h.birdie || h.sandy loop
        for i in 0..3 loop if i <> bon then pa[i * 4 + bon + 1] := pa[i * 4 + bon + 1] + 1; end if; end loop;
      end loop;
    end if;
    dd := array[0, 0, 0, 0];
    for i in 0..3 loop for j in 0..3 loop
      dd[j + 1] := dd[j + 1] + pa[i * 4 + j + 1]; dd[i + 1] := dd[i + 1] - pa[i * 4 + j + 1];
    end loop; end loop;
    hole := h.hole; wolf := w; mode := h.mode; partner := h.partner; presses := np; unit := u; result := txt; pay := pa;
    d0 := dd[1]; d1 := dd[2]; d2 := dd[3]; d3 := dd[4];
    return next;
  end loop;
end $$;

-- What the app shows (players only).
create or replace function public.wolf_scoreboard(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, d0 int, d1 int, d2 int, d3 int)
language sql stable security definer set search_path = public as $$
  select c.hole, c.wolf, c.mode, c.partner, c.complete, c.carry_in, c.presses, c.unit, c.result, c.d0, c.d1, c.d2, c.d3
  from wolf_compute(p_round) c where wolf_is_player(p_round)
$$;

create or replace function public.create_wolf_round(p_course text, p_players jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); clean jsonb := '[]'; e jsonb; nm text; u uuid; rid uuid; uids uuid[] := '{}';
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if jsonb_typeof(p_players) <> 'array' or jsonb_array_length(p_players) <> 4 then raise exception 'Wolf needs exactly 4 players.'; end if;
  for e in select * from jsonb_array_elements(p_players) loop
    u := nullif(e->>'uid', '')::uuid;
    if u is not null then
      select name into nm from profiles where id = u;
      if nm is null then raise exception 'One of those players isn''t on Handshake.'; end if;
      if u = any (uids) then raise exception 'Each player can only be in the round once.'; end if;
      uids := uids || u;
    else
      nm := btrim(coalesce(e->>'name', ''));
      if nm = '' or char_length(nm) > 30 then raise exception 'Give every guest a name (up to 30 characters).'; end if;
    end if;
    clean := clean || jsonb_build_array(jsonb_build_object('uid', u, 'name', nm));
  end loop;
  if not me = any (uids) then raise exception 'You need to be one of the four players.'; end if;
  insert into wolf_rounds (course, players, created_by) values (left(btrim(coalesce(p_course, '')), 40), clean, me) returning id into rid;
  return rid;
end $$;

-- Save one hole (everything at once). Any Handshake player in the round can enter it.
create or replace function public.save_wolf_hole(p_round uuid, p_hole int, p_mode text, p_partner int, p_scores int[],
  p_greenie int[], p_birdie int[], p_sandy int[], p_pressed_by int)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; old_press int; lowest int; tot int[] := array[0, 0, 0, 0]; c record; w int := (p_hole - 1) % 4;
begin
  select * into r from wolf_rounds where id = p_round;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is finished.'; end if;
  if p_hole not between 1 and 18 then raise exception 'Holes go from 1 to 18.'; end if;
  if p_mode is not null and p_mode not in ('partner', 'lone', 'blind') then raise exception 'Pick a partner, Lone Wolf or Blind Wolf.'; end if;
  if p_mode = 'partner' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick the Wolf''s partner.'; end if;
  if cardinality(coalesce(p_scores, '{}')) <> 4 then raise exception 'Send four scores (blank is fine).'; end if;
  if exists (select 1 from unnest(p_scores) s where s is not null and s not between 1 and 20) then raise exception 'Scores go from 1 to 20.'; end if;
  if exists (select 1 from unnest(coalesce(p_greenie, '{}') || coalesce(p_birdie, '{}') || coalesce(p_sandy, '{}')) x where x not between 0 and 3) then
    raise exception 'Bonus for an unknown player.'; end if;
  select pressed_by into old_press from wolf_holes where round_id = p_round and hole = p_hole;
  if p_pressed_by is not null and p_pressed_by is distinct from old_press then
    if p_pressed_by not between 0 and 3 then raise exception 'Unknown player pressing.'; end if;
    for c in select * from wolf_compute(p_round) x where x.hole < p_hole loop
      tot := array[tot[1] + c.d0, tot[2] + c.d1, tot[3] + c.d2, tot[4] + c.d3];
    end loop;
    select min(t) into lowest from unnest(tot) t;
    if tot[p_pressed_by + 1] <> lowest then raise exception 'Only the player in last place can press.'; end if;
  end if;
  insert into wolf_holes (round_id, hole, mode, partner, scores, greenie, birdie, sandy, pressed_by, updated_by, updated_at)
  values (p_round, p_hole, p_mode, case when p_mode = 'partner' then p_partner end, p_scores,
          coalesce(array(select distinct x from unnest(p_greenie) x), '{}'), coalesce(array(select distinct x from unnest(p_birdie) x), '{}'),
          coalesce(array(select distinct x from unnest(p_sandy) x), '{}'), p_pressed_by, auth.uid(), now())
  on conflict (round_id, hole) do update set mode = excluded.mode, partner = excluded.partner, scores = excluded.scores,
    greenie = excluded.greenie, birdie = excluded.birdie, sandy = excluded.sandy, pressed_by = excluded.pressed_by,
    updated_by = excluded.updated_by, updated_at = now();
end $$;

-- Finish: book what each pair owes as finished predictions. Returns how many were booked.
create or replace function public.finish_wolf_round(p_round uuid)
returns int language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; tot int[] := array_fill(0, array[16]); c record; i int; j int; net int; n int := 0;
  pl jsonb; ui uuid; uj uuid; ni text; nj text; title text; holes int; win_uid uuid; win_name text; lose_uid uuid; lose_name text;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is already finished.'; end if;
  holes := 0;
  for c in select * from wolf_compute(p_round) loop
    if c.complete then holes := holes + 1; end if;
    for i in 1..16 loop tot[i] := tot[i] + c.pay[i]; end loop;
  end loop;
  if holes = 0 then raise exception 'Enter at least one full hole first.'; end if;
  pl := r.players;
  title := left('Wolf' || case when r.course <> '' then ' · ' || r.course else '' end || ' · ' || to_char(now() at time zone 'America/Los_Angeles', 'Mon FMDD'), 90);
  for i in 0..2 loop for j in (i + 1)..3 loop
    net := tot[j * 4 + i + 1] - tot[i * 4 + j + 1];   -- > 0: j owes i
    if net = 0 then continue; end if;
    ui := nullif(pl->i->>'uid', '')::uuid; uj := nullif(pl->j->>'uid', '')::uuid;
    ni := pl->i->>'name'; nj := pl->j->>'name';
    if net > 0 then win_uid := ui; win_name := ni; lose_uid := uj; lose_name := nj;
    else win_uid := uj; win_name := nj; lose_uid := ui; lose_name := ni; net := -net; end if;
    if win_uid is null and lose_uid is null then continue; end if;
    insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                             status, winner, visibility, auto_notified, decided_at, wolf_round, log)
    values (title, 'Golf', 'points', least(net, 1000), (now() at time zone 'America/Los_Angeles')::date,
            left('Wolf, ' || holes || ' holes. ' || win_name || ' won ' || net || case when net = 1 then ' pt' else ' pts' end || ' from ' || lose_name || '.', 240),
            coalesce(win_uid, lose_uid), case when win_uid is not null then win_name else lose_name end,
            case when win_uid is not null then lose_uid else null end,
            case when win_uid is not null then lose_name else win_name end,
            case when win_uid is not null then lose_uid else null end,
            'settled', case when win_uid is not null then 'a' else 'b' end, 'pair', true, now(), p_round,
            jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'wolf round counted: ' || win_name || ' won ' || net || case when net = 1 then ' pt' else ' pts' end || ' from ' || lose_name)));
    n := n + 1;
  end loop; end loop;
  update wolf_rounds set status = 'finished', finished_at = now() where id = p_round;
  return n;
end $$;

-- Delete a round you started (only while it's still being played).
create or replace function public.delete_wolf_round(p_round uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from wolf_rounds where id = p_round and created_by = auth.uid() and status = 'playing';
  if not found then raise exception 'Only the person who started an unfinished round can delete it.'; end if;
end $$;

revoke all on function public.wolf_compute(uuid) from public, anon, authenticated;
grant execute on function public.wolf_compute(uuid) to service_role;
revoke all on function public.wolf_is_player(uuid), public.wolf_scoreboard(uuid), public.create_wolf_round(text, jsonb),
  public.save_wolf_hole(uuid, int, text, int, int[], int[], int[], int[], int), public.finish_wolf_round(uuid),
  public.delete_wolf_round(uuid) from public, anon;
grant execute on function public.wolf_is_player(uuid), public.wolf_scoreboard(uuid), public.create_wolf_round(text, jsonb),
  public.save_wolf_hole(uuid, int, text, int, int[], int[], int[], int[], int), public.finish_wolf_round(uuid),
  public.delete_wolf_round(uuid) to authenticated;

-- "Predictions and Counting!" counts calls people made, not points booked by pools or golf.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null and wolf_round is null
$$;

-- ================================================================
-- Wolf invites and live scoring (same as update-wolf-2.sql)
-- ================================================================
alter table public.wolf_rounds add column if not exists code text;
update public.wolf_rounds set code = 'W' || upper(substr(md5(id::text || random()::text), 1, 6)) where code is null;
create unique index if not exists wolf_rounds_code on public.wolf_rounds (code);

create or replace function public.create_wolf_round(p_course text, p_players jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); clean jsonb := '[]'; e jsonb; nm text; u uuid; rid uuid; uids uuid[] := '{}'; c text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if jsonb_typeof(p_players) <> 'array' or jsonb_array_length(p_players) <> 4 then raise exception 'Wolf needs exactly 4 players.'; end if;
  for e in select * from jsonb_array_elements(p_players) loop
    u := nullif(e->>'uid', '')::uuid;
    if u is not null then
      select name into nm from profiles where id = u;
      if nm is null then raise exception 'One of those players isn''t on Handshake.'; end if;
      if u = any (uids) then raise exception 'Each player can only be in the round once.'; end if;
      uids := uids || u;
    else
      nm := btrim(coalesce(e->>'name', ''));
      if nm = '' or char_length(nm) > 30 then raise exception 'Give every guest a name (up to 30 characters).'; end if;
    end if;
    clean := clean || jsonb_build_array(jsonb_build_object('uid', u, 'name', nm));
  end loop;
  if not me = any (uids) then raise exception 'You need to be one of the four players.'; end if;
  loop
    c := 'W' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from wolf_rounds where code = c);
  end loop;
  insert into wolf_rounds (course, players, created_by, code) values (left(btrim(coalesce(p_course, '')), 40), clean, me, c) returning id into rid;
  return rid;
end $$;

-- What an invite link shows before joining: the round and its open guest spots.
create or replace function public.wolf_round_preview(p_code text)
returns table (round_id uuid, course text, names text[], guest_slots int[], is_player boolean, finished boolean)
language sql stable security definer set search_path = public as $$
  select r.id, r.course,
    array(select e->>'name' from jsonb_array_elements(r.players) with ordinality x(e, o) order by o),
    array(select (o - 1)::int from jsonb_array_elements(r.players) with ordinality x(e, o) where coalesce(e->>'uid', '') = '' order by o),
    exists (select 1 from jsonb_array_elements(r.players) e where e->>'uid' = auth.uid()::text),
    r.status = 'finished'
  from wolf_rounds r where r.code = upper(btrim(coalesce(p_code, '')))
$$;

-- Join a round from its invite: take over a guest spot (p_slot = which one, 0-3).
create or replace function public.join_wolf_round(p_code text, p_slot int)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r wolf_rounds; nm text;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  select * into r from wolf_rounds where code = upper(btrim(coalesce(p_code, ''))) for update;
  if not found then raise exception 'That round code doesn''t match any round.'; end if;
  if exists (select 1 from jsonb_array_elements(r.players) e where e->>'uid' = me::text) then return r.id; end if;
  if r.status <> 'playing' then raise exception 'That round is already finished.'; end if;
  if p_slot is null or p_slot not between 0 and 3 or coalesce(r.players->p_slot->>'uid', '') <> '' then
    raise exception 'Pick one of the guest spots.'; end if;
  select name into nm from profiles where id = me;
  update wolf_rounds set players = jsonb_set(players, array[p_slot::text], jsonb_build_object('uid', me, 'name', coalesce(nm, players->p_slot->>'name')))
  where id = r.id;
  return r.id;
end $$;

revoke all on function public.create_wolf_round(text, jsonb), public.wolf_round_preview(text), public.join_wolf_round(text, int) from public, anon;
grant execute on function public.create_wolf_round(text, jsonb), public.wolf_round_preview(text), public.join_wolf_round(text, int) to authenticated;

-- Live updates for players' screens.
do $$ begin alter publication supabase_realtime add table public.wolf_rounds; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.wolf_holes; exception when duplicate_object then null; when undefined_object then null; end $$;

-- ================================================================
-- Wolf End match keeps golf separate (same as update-wolf-3.sql)
-- ================================================================
create or replace function public.finish_wolf_round(p_round uuid)
returns int language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; holes int;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That match is already over.'; end if;
  select count(*) into holes from wolf_compute(p_round) c where c.complete;
  if holes = 0 then raise exception 'Enter at least one full hole first.'; end if;
  update wolf_rounds set status = 'finished', finished_at = now() where id = p_round;
  return holes;
end $$;

-- ================================================================
-- Wolf: change tee order before the first hole (same as update-wolf-4.sql)
-- ================================================================
create or replace function public.reorder_wolf_round(p_round uuid, p_order int[])
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That match is already over.'; end if;
  if exists (select 1 from wolf_holes where round_id = p_round) then
    raise exception 'The tee order is locked once the first hole is saved.'; end if;
  if cardinality(coalesce(p_order, '{}')) <> 4
     or (select array_agg(x order by x) from unnest(p_order) x) is distinct from array[0, 1, 2, 3] then
    raise exception 'Send each of the four spots once.'; end if;
  update wolf_rounds set players = (select jsonb_agg(r.players->x order by o) from unnest(p_order) with ordinality u(x, o))
  where id = p_round;
end $$;

revoke all on function public.reorder_wolf_round(uuid, int[]) from public, anon;
grant execute on function public.reorder_wolf_round(uuid, int[]) to authenticated;

-- ================================================================
-- Wolf Dump (same as update-wolf-5.sql)
-- ================================================================
alter table public.wolf_holes drop constraint if exists wolf_holes_mode_check;
alter table public.wolf_holes add constraint wolf_holes_mode_check check (mode in ('partner', 'lone', 'blind', 'dump'));

create or replace function public.wolf_compute(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, pay int[], d0 int, d1 int, d2 int, d3 int)
language plpgsql stable security definer set search_path = public as $$
declare
  h wolf_holes; carry int := 0; np int := 0; m int; u int; w int; p int;
  a int; b int; i int; j int; others int[]; team int[]; opp int[]; names text[]; won int[]; lost int[];
  pa int[]; dd int[]; bon int; txt text;
begin
  select array_agg(e->>'name' order by o) into names
    from wolf_rounds r, jsonb_array_elements(r.players) with ordinality x(e, o) where r.id = p_round;
  for h in select * from wolf_holes x where x.round_id = p_round order by x.hole loop
    if h.pressed_by is not null then np := np + 1; end if;
    w := (h.hole - 1) % 4;
    pa := array_fill(0, array[16]); txt := null; u := null;
    complete := h.mode is not null and cardinality(h.scores) = 4 and array_position(h.scores, null) is null
                and (h.mode not in ('partner', 'dump') or (h.partner is not null and h.partner <> w));
    carry_in := carry;
    if complete then
      m := case h.mode when 'blind' then 2 else 1 end;
      u := (1 + carry) * m * (2 ^ np)::int;
      if h.mode = 'partner' then
        team := array[w, h.partner];
        opp := array(select g from generate_series(0, 3) g where g <> all (team));
        a := least(h.scores[team[1] + 1], h.scores[team[2] + 1]);
        b := least(h.scores[opp[1] + 1], h.scores[opp[2] + 1]);
        if a = b then won := null; else
          if a < b then won := team; lost := opp; else won := opp; lost := team; end if;
          foreach i in array lost loop foreach j in array won loop pa[i * 4 + j + 1] := pa[i * 4 + j + 1] + u; end loop; end loop;
          txt := names[won[1] + 1] || ' & ' || names[won[2] + 1] || ' won';
        end if;
      else
        -- Lone Wolf, Blind Wolf, or a Dump (the player who dumped the Wolf plays it alone)
        p := case when h.mode = 'dump' then h.partner else w end;
        others := array(select g from generate_series(0, 3) g where g <> p);
        a := h.scores[p + 1];
        b := least(h.scores[others[1] + 1], h.scores[others[2] + 1], h.scores[others[3] + 1]);
        if a < b then
          foreach i in array others loop pa[i * 4 + p + 1] := pa[i * 4 + p + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'Lone Wolf ' || names[w + 1] || ' won'
                             when 'blind' then 'Blind Wolf ' || names[w + 1] || ' won'
                             else names[p + 1] || ' dumped ' || names[w + 1] || ' and won' end;
        elsif a > b then
          foreach j in array others loop pa[p * 4 + j + 1] := pa[p * 4 + j + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'The pack beat Lone Wolf ' || names[w + 1]
                             when 'blind' then 'The pack beat Blind Wolf ' || names[w + 1]
                             else names[p + 1] || ' dumped ' || names[w + 1] || ' and lost' end;
        end if;
      end if;
      if txt is null then carry := carry + 1; txt := 'Tied: 1 point rolls over'; else carry := 0; end if;
      -- bonuses: 1 from each other player, never multiplied
      foreach bon in array h.greenie || h.birdie || h.sandy loop
        for i in 0..3 loop if i <> bon then pa[i * 4 + bon + 1] := pa[i * 4 + bon + 1] + 1; end if; end loop;
      end loop;
    end if;
    dd := array[0, 0, 0, 0];
    for i in 0..3 loop for j in 0..3 loop
      dd[j + 1] := dd[j + 1] + pa[i * 4 + j + 1]; dd[i + 1] := dd[i + 1] - pa[i * 4 + j + 1];
    end loop; end loop;
    hole := h.hole; wolf := w; mode := h.mode; partner := h.partner; presses := np; unit := u; result := txt; pay := pa;
    d0 := dd[1]; d1 := dd[2]; d2 := dd[3]; d3 := dd[4];
    return next;
  end loop;
end $$;

create or replace function public.save_wolf_hole(p_round uuid, p_hole int, p_mode text, p_partner int, p_scores int[],
  p_greenie int[], p_birdie int[], p_sandy int[], p_pressed_by int)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; old_press int; lowest int; tot int[] := array[0, 0, 0, 0]; c record; w int := (p_hole - 1) % 4;
begin
  select * into r from wolf_rounds where id = p_round;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is finished.'; end if;
  if p_hole not between 1 and 18 then raise exception 'Holes go from 1 to 18.'; end if;
  if p_mode is not null and p_mode not in ('partner', 'lone', 'blind', 'dump') then raise exception 'Pick a partner, a Dump, Lone Wolf or Blind Wolf.'; end if;
  if p_mode = 'dump' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick who dumped the Wolf.'; end if;
  if p_mode = 'partner' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick the Wolf''s partner.'; end if;
  if cardinality(coalesce(p_scores, '{}')) <> 4 then raise exception 'Send four scores (blank is fine).'; end if;
  if exists (select 1 from unnest(p_scores) s where s is not null and s not between 1 and 20) then raise exception 'Scores go from 1 to 20.'; end if;
  if exists (select 1 from unnest(coalesce(p_greenie, '{}') || coalesce(p_birdie, '{}') || coalesce(p_sandy, '{}')) x where x not between 0 and 3) then
    raise exception 'Bonus for an unknown player.'; end if;
  select pressed_by into old_press from wolf_holes where round_id = p_round and hole = p_hole;
  if p_pressed_by is not null and p_pressed_by is distinct from old_press then
    if p_pressed_by not between 0 and 3 then raise exception 'Unknown player pressing.'; end if;
    for c in select * from wolf_compute(p_round) x where x.hole < p_hole loop
      tot := array[tot[1] + c.d0, tot[2] + c.d1, tot[3] + c.d2, tot[4] + c.d3];
    end loop;
    select min(t) into lowest from unnest(tot) t;
    if tot[p_pressed_by + 1] <> lowest then raise exception 'Only the player in last place can press.'; end if;
  end if;
  insert into wolf_holes (round_id, hole, mode, partner, scores, greenie, birdie, sandy, pressed_by, updated_by, updated_at)
  values (p_round, p_hole, p_mode, case when p_mode in ('partner', 'dump') then p_partner end, p_scores,
          coalesce(array(select distinct x from unnest(p_greenie) x), '{}'), coalesce(array(select distinct x from unnest(p_birdie) x), '{}'),
          coalesce(array(select distinct x from unnest(p_sandy) x), '{}'), p_pressed_by, auth.uid(), now())
  on conflict (round_id, hole) do update set mode = excluded.mode, partner = excluded.partner, scores = excluded.scores,
    greenie = excluded.greenie, birdie = excluded.birdie, sandy = excluded.sandy, pressed_by = excluded.pressed_by,
    updated_by = excluded.updated_by, updated_at = now();
end $$;

-- ================================================================
-- Wolf: delete a finished match with 24 hours to save it (same as update-wolf-6.sql)
-- ================================================================
alter table public.wolf_rounds add column if not exists delete_requested_by uuid references public.profiles (id) on delete set null;
alter table public.wolf_rounds add column if not exists delete_requested_at timestamptz;
alter table public.wolf_rounds add column if not exists delete_saved_by uuid references public.profiles (id) on delete set null;
alter table public.wolf_rounds add column if not exists delete_saved_at timestamptz;

create or replace function public.request_wolf_delete(p_round uuid)
returns timestamptz language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'finished' then raise exception 'End the match first (or delete it right away if you started it).'; end if;
  if r.delete_requested_at is not null then raise exception 'Someone already asked to delete this round.'; end if;
  update wolf_rounds set delete_requested_by = auth.uid(), delete_requested_at = now(), delete_saved_by = null, delete_saved_at = null
  where id = p_round;
  return now() + interval '24 hours';
end $$;

create or replace function public.save_wolf_round(p_round uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds;
begin
  select * into r from wolf_rounds where id = p_round for update;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.delete_requested_at is null then raise exception 'Nobody has asked to delete this round.'; end if;
  update wolf_rounds set delete_requested_by = null, delete_requested_at = null, delete_saved_by = auth.uid(), delete_saved_at = now()
  where id = p_round;
end $$;

-- Delete rounds whose 24 hours ran out. Returns how many were deleted.
create or replace function public.delete_expired_wolf_rounds()
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  delete from wolf_rounds where delete_requested_at is not null and delete_requested_at <= now() - interval '24 hours';
  get diagnostics n = row_count;
  return n;
end $$;

revoke all on function public.request_wolf_delete(uuid), public.save_wolf_round(uuid), public.delete_expired_wolf_rounds() from public, anon;
grant execute on function public.request_wolf_delete(uuid), public.save_wolf_round(uuid) to authenticated;
grant execute on function public.delete_expired_wolf_rounds() to service_role;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-wolf-delete') where exists (select 1 from cron.job where jobname = 'handshake-wolf-delete');
  perform cron.schedule('handshake-wolf-delete', '*/10 * * * *', 'select public.delete_expired_wolf_rounds()');
end $$;

-- ================================================================
-- RSVP (same as update-rsvp.sql)
-- ================================================================
create table if not exists public.rsvp_events (
  id            uuid primary key default gen_random_uuid(),
  title         text not null check (char_length(btrim(title)) between 1 and 60),
  venue         text check (venue is null or char_length(venue) <= 60),   -- null = asking for ideas
  notes         text not null default '' check (char_length(notes) <= 240),
  organizer     uuid not null references public.profiles (id) on delete cascade,
  status        text not null default 'open' check (status in ('open', 'locked', 'canceled')),
  locked_option uuid,
  locked_venue  text,
  locked_at     timestamptz,
  open_count    int,                                 -- options still working at the last notice
  created_at    timestamptz not null default now()
);
create table if not exists public.rsvp_invitees (
  event_id  uuid not null references public.rsvp_events (id) on delete cascade,
  uid       uuid not null references public.profiles (id) on delete cascade,
  primary key (event_id, uid)
);
create table if not exists public.rsvp_options (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.rsvp_events (id) on delete cascade,
  day         date not null,
  end_day     date check (end_day is null or end_day >= day),
  at_time     time,
  added_by    uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now()
);
create table if not exists public.rsvp_answers (
  option_id   uuid not null references public.rsvp_options (id) on delete cascade,
  event_id    uuid not null references public.rsvp_events (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  answer      text not null check (answer in ('go', 'nogo')),
  updated_at  timestamptz not null default now(),
  primary key (option_id, uid)
);
create table if not exists public.rsvp_venues (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  name          text not null check (char_length(btrim(name)) between 1 and 60),
  suggested_by  uuid not null references public.profiles (id) on delete cascade,
  created_at    timestamptz not null default now()
);
create table if not exists public.rsvp_venue_votes (
  venue_id  uuid not null references public.rsvp_venues (id) on delete cascade,
  event_id  uuid not null references public.rsvp_events (id) on delete cascade,
  uid       uuid not null references public.profiles (id) on delete cascade,
  primary key (venue_id, uid)
);
create table if not exists public.rsvp_lastcall (
  event_id     uuid not null references public.rsvp_events (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'in', 'out')),
  sent_at      timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (event_id, uid)
);

create or replace function public.rsvp_can_see(p_event uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = auth.uid())
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_lastcall where event_id = p_event and uid = auth.uid())
$$;

alter table public.rsvp_events enable row level security;
alter table public.rsvp_invitees enable row level security;
alter table public.rsvp_options enable row level security;
alter table public.rsvp_answers enable row level security;
alter table public.rsvp_venues enable row level security;
alter table public.rsvp_venue_votes enable row level security;
alter table public.rsvp_lastcall enable row level security;
drop policy if exists "rsvp people see events" on public.rsvp_events;
create policy "rsvp people see events" on public.rsvp_events for select to authenticated using (public.rsvp_can_see(id));
drop policy if exists "rsvp people see invitees" on public.rsvp_invitees;
create policy "rsvp people see invitees" on public.rsvp_invitees for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see options" on public.rsvp_options;
create policy "rsvp people see options" on public.rsvp_options for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see answers" on public.rsvp_answers;
create policy "rsvp people see answers" on public.rsvp_answers for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see venues" on public.rsvp_venues;
create policy "rsvp people see venues" on public.rsvp_venues for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see votes" on public.rsvp_venue_votes;
create policy "rsvp people see votes" on public.rsvp_venue_votes for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see last call" on public.rsvp_lastcall;
create policy "rsvp people see last call" on public.rsvp_lastcall for select to authenticated using (public.rsvp_can_see(event_id));
grant select on public.rsvp_events, public.rsvp_invitees, public.rsvp_options, public.rsvp_answers,
  public.rsvp_venues, public.rsvp_venue_votes, public.rsvp_lastcall to authenticated;
grant all on public.rsvp_events, public.rsvp_invitees, public.rsvp_options, public.rsvp_answers,
  public.rsvp_venues, public.rsvp_venue_votes, public.rsvp_lastcall to service_role;

-- Is this person part of the event (organizer or invitee)?
create or replace function public._rsvp_member(p_event uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = p_uid)
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = p_uid)
$$;

-- Options with their tallies, best first. works = nobody said No-go.
create or replace function public.rsvp_tally(p_event uuid)
returns table (option_id uuid, day date, end_day date, at_time time, go int, nogo int, works boolean)
language sql stable security definer set search_path = public as $$
  select o.id, o.day, o.end_day, o.at_time,
    count(*) filter (where a.answer = 'go')::int, count(*) filter (where a.answer = 'nogo')::int,
    count(*) filter (where a.answer = 'nogo') = 0
  from rsvp_options o left join rsvp_answers a on a.option_id = o.id
  where o.event_id = p_event and (auth.uid() is null or rsvp_can_see(p_event))
  group by o.id
  order by (count(*) filter (where a.answer = 'nogo') = 0) desc, count(*) filter (where a.answer = 'go') desc, o.day, o.at_time nulls first
$$;

-- Start an event. p_options: [{day, end_day, at_time}], p_invitees: [uid].
create or replace function public.create_rsvp(p_title text, p_venue text, p_notes text, p_options jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); eid uuid; o jsonb; oid uuid; u uuid; n int := 0;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Say what it''s for (up to 60 characters).'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) = 0 then raise exception 'Propose at least one date.'; end if;
  if jsonb_array_length(p_options) > 20 then raise exception 'Up to 20 date options.'; end if;
  if coalesce(cardinality(p_invitees), 0) = 0 then raise exception 'Invite at least one person.'; end if;
  insert into rsvp_events (title, venue, notes, organizer)
  values (btrim(p_title), nullif(left(btrim(coalesce(p_venue, '')), 60), ''), left(btrim(coalesce(p_notes, '')), 240), me)
  returning id into eid;
  for o in select * from jsonb_array_elements(p_options) loop
    insert into rsvp_options (event_id, day, end_day, at_time, added_by)
    values (eid, (o->>'day')::date, nullif(o->>'end_day', '')::date, nullif(o->>'at_time', '')::time, me)
    returning id into oid;
    insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, eid, me, 'go');
  end loop;
  foreach u in array p_invitees loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_invitees (event_id, uid) values (eid, u) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  if n = 0 then raise exception 'Invite at least one other person.'; end if;
  update rsvp_events set open_count = (select count(*) from rsvp_tally(eid) t where t.works) where id = eid;
  return eid;
end $$;

-- Go / No-go on one option (p_answer null clears it).
create or replace function public.rsvp_answer(p_option uuid, p_answer text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o rsvp_options; e rsvp_events;
begin
  select * into o from rsvp_options where id = p_option;
  if not found then raise exception 'That option is gone.'; end if;
  select * into e from rsvp_events where id = o.event_id;
  if not _rsvp_member(e.id, me) then raise exception 'You''re not invited to this one.'; end if;
  if e.status <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_answer is null then delete from rsvp_answers where option_id = p_option and uid = me;
  elsif p_answer in ('go', 'nogo') then
    insert into rsvp_answers (option_id, event_id, uid, answer) values (p_option, e.id, me, p_answer)
    on conflict (option_id, uid) do update set answer = excluded.answer, updated_at = now();
  else raise exception 'Answer go or no-go.'; end if;
end $$;

-- Suggest another date/time (you're marked Go on it).
create or replace function public.rsvp_add_option(p_event uuid, p_day date, p_end_day date, p_at_time time)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); oid uuid;
begin
  if not _rsvp_member(p_event, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = p_event) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_day is null then raise exception 'Pick a day.'; end if;
  if (select count(*) from rsvp_options where event_id = p_event) >= 30 then raise exception 'That''s plenty of options already.'; end if;
  insert into rsvp_options (event_id, day, end_day, at_time, added_by) values (p_event, p_day, p_end_day, p_at_time, me) returning id into oid;
  insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, p_event, me, 'go');
  return oid;
end $$;

-- Suggest a venue (you're counted as a vote for it).
create or replace function public.rsvp_add_venue(p_event uuid, p_name text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); vid uuid; nm text := btrim(coalesce(p_name, ''));
begin
  if not _rsvp_member(p_event, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = p_event) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if char_length(nm) not between 1 and 60 then raise exception 'Name the place (up to 60 characters).'; end if;
  select id into vid from rsvp_venues where event_id = p_event and lower(name) = lower(nm);
  if vid is null then
    insert into rsvp_venues (event_id, name, suggested_by) values (p_event, nm, me) returning id into vid;
  end if;
  insert into rsvp_venue_votes (venue_id, event_id, uid) values (vid, p_event, me) on conflict do nothing;
  return vid;
end $$;

create or replace function public.rsvp_vote_venue(p_venue uuid, p_on boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v rsvp_venues;
begin
  select * into v from rsvp_venues where id = p_venue;
  if not found or not _rsvp_member(v.event_id, me) then raise exception 'You''re not invited to this one.'; end if;
  if (select status from rsvp_events where id = v.event_id) <> 'open' then raise exception 'This one is locked down already.'; end if;
  if p_on then insert into rsvp_venue_votes (venue_id, event_id, uid) values (p_venue, v.event_id, me) on conflict do nothing;
  else delete from rsvp_venue_votes where venue_id = p_venue and uid = me; end if;
end $$;

-- Lock it down: day/time, venue, and exactly who gets the last call.
create or replace function public.rsvp_lock(p_event uuid, p_option uuid, p_venue text, p_people uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); e rsvp_events; u uuid; n int := 0;
begin
  select * into e from rsvp_events where id = p_event for update;
  if not found or e.organizer <> me then raise exception 'Only the organizer can lock it down.'; end if;
  if e.status <> 'open' then raise exception 'This one is already locked down.'; end if;
  if not exists (select 1 from rsvp_options where id = p_option and event_id = p_event) then raise exception 'Pick one of the dates.'; end if;
  if char_length(btrim(coalesce(p_venue, ''))) not between 1 and 60 then raise exception 'Pick the venue.'; end if;
  update rsvp_events set status = 'locked', locked_option = p_option, locked_venue = btrim(p_venue), locked_at = now() where id = p_event;
  foreach u in array coalesce(p_people, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_lastcall (event_id, uid) values (p_event, u) on conflict do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Last call answer: I'm in / Can't make it.
create or replace function public.rsvp_lastcall_answer(p_event uuid, p_in boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  update rsvp_lastcall set status = case when p_in then 'in' else 'out' end, answered_at = now()
  where event_id = p_event and uid = auth.uid();
  if not found then raise exception 'You weren''t on the last call for this one.'; end if;
end $$;

-- Organizer can call the whole thing off.
create or replace function public.rsvp_cancel(p_event uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update rsvp_events set status = 'canceled' where id = p_event and organizer = auth.uid() and status <> 'canceled';
  if not found then raise exception 'Only the organizer can cancel it.'; end if;
end $$;

revoke all on function public.rsvp_can_see(uuid), public._rsvp_member(uuid, uuid), public.rsvp_tally(uuid),
  public.create_rsvp(text, text, text, jsonb, uuid[]), public.rsvp_answer(uuid, text), public.rsvp_add_option(uuid, date, date, time),
  public.rsvp_add_venue(uuid, text), public.rsvp_vote_venue(uuid, boolean), public.rsvp_lock(uuid, uuid, text, uuid[]),
  public.rsvp_lastcall_answer(uuid, boolean), public.rsvp_cancel(uuid) from public, anon;
grant execute on function public.rsvp_can_see(uuid), public.create_rsvp(text, text, text, jsonb, uuid[]), public.rsvp_answer(uuid, text),
  public.rsvp_add_option(uuid, date, date, time), public.rsvp_add_venue(uuid, text), public.rsvp_vote_venue(uuid, boolean),
  public.rsvp_lock(uuid, uuid, text, uuid[]), public.rsvp_lastcall_answer(uuid, boolean), public.rsvp_cancel(uuid) to authenticated;
grant execute on function public.rsvp_tally(uuid) to authenticated, service_role;
grant execute on function public._rsvp_member(uuid, uuid) to service_role;

-- Live updates while an event is open on screen.
do $$ begin alter publication supabase_realtime add table public.rsvp_answers; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_events; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_venue_votes; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.rsvp_lastcall; exception when duplicate_object then null; when undefined_object then null; end $$;

-- ================================================================
-- Contests (same as update-contests.sql)
-- ================================================================
create table if not exists public.contests (
  id              uuid primary key default gen_random_uuid(),
  title           text not null check (char_length(btrim(title)) between 1 and 90),
  choices         text[] not null default '{}',
  allow_writeins  boolean not null default false,
  points          int not null check (points between 1 and 1000),
  max_entries     int not null check (max_entries between 1 and 20),
  deadline        timestamptz not null,
  visibility      text not null default 'invited' check (visibility in ('all', 'circle', 'invited')),
  sponsor         uuid not null references public.profiles (id) on delete cascade,
  stage           text not null default 'open' check (stage in ('open', 'recorded', 'proving', 'proof', 'refereeing', 'settled', 'void', 'canceled')),
  stage_at        timestamptz not null default now(),
  result          text,
  objector        uuid references public.profiles (id) on delete set null,
  objection       text,
  proof_link      text,
  referee         uuid references public.profiles (id) on delete set null,
  outcome_note    text,
  created_at      timestamptz not null default now()
);
create table if not exists public.contest_invitees (
  contest_id  uuid not null references public.contests (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  primary key (contest_id, uid)
);
create table if not exists public.contest_entries (
  id          uuid primary key default gen_random_uuid(),
  contest_id  uuid not null references public.contests (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  choice      text not null check (char_length(btrim(choice)) between 1 and 40),
  created_at  timestamptz not null default now()
);
create unique index if not exists contest_entries_one_each on public.contest_entries (contest_id, uid, lower(choice));
alter table public.predictions add column if not exists contest_id uuid references public.contests (id) on delete set null;

-- Has this person played (any prediction past the invite stage) with any of these people?
create or replace function public._played_any(p_me uuid, p_people uuid[])
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from predictions q where q.status <> 'proposed'
    and ((q.a_uid = p_me and q.b_uid = any (p_people)) or (q.b_uid = p_me and q.a_uid = any (p_people))))
$$;

create or replace function public.contest_can_see(p_contest uuid)
returns boolean language plpgsql stable security definer set search_path = public as $$
declare me uuid := auth.uid(); c contests;
begin
  if me is null then return false; end if;
  select * into c from contests where id = p_contest;
  if not found then return false; end if;
  if c.visibility = 'all' or c.sponsor = me or c.referee = me then return true; end if;
  if exists (select 1 from contest_invitees where contest_id = p_contest and uid = me)
     or exists (select 1 from contest_entries where contest_id = p_contest and uid = me) then return true; end if;
  if c.visibility = 'circle' then
    return _played_any(me, c.sponsor || array(select uid from contest_invitees where contest_id = p_contest));
  end if;
  return false;
end $$;

alter table public.contests enable row level security;
alter table public.contest_invitees enable row level security;
alter table public.contest_entries enable row level security;
drop policy if exists "contest people see contests" on public.contests;
create policy "contest people see contests" on public.contests for select to authenticated using (public.contest_can_see(id));
drop policy if exists "contest people see invitees" on public.contest_invitees;
create policy "contest people see invitees" on public.contest_invitees for select to authenticated using (public.contest_can_see(contest_id));
drop policy if exists "contest people see entries" on public.contest_entries;
create policy "contest people see entries" on public.contest_entries for select to authenticated using (public.contest_can_see(contest_id));
grant select on public.contests, public.contest_invitees, public.contest_entries to authenticated;
grant all on public.contests, public.contest_invitees, public.contest_entries to service_role;

create or replace function public.create_contest(p_title text, p_choices text[], p_writeins boolean, p_points int, p_max int,
  p_deadline timestamptz, p_visibility text, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); cid uuid; ch text[]; u uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 90 then raise exception 'Ask the question (up to 90 characters).'; end if;
  select coalesce(array_agg(x order by o), '{}') into ch from (
    select distinct on (lower(btrim(c))) btrim(c) as x, o from unnest(coalesce(p_choices, '{}')) with ordinality t(c, o)
    where btrim(c) <> '' order by lower(btrim(c)), o) d;
  if exists (select 1 from unnest(ch) c where char_length(c) > 40) then raise exception 'Keep each choice to 40 characters.'; end if;
  if cardinality(ch) > 50 then raise exception 'Up to 50 choices.'; end if;
  if cardinality(ch) < 2 and not coalesce(p_writeins, false) then raise exception 'List at least two choices, or allow write-ins.'; end if;
  if p_points is null or p_points not between 1 and 1000 then raise exception 'Points per entry go from 1 to 1000.'; end if;
  if p_max is null or p_max not between 1 and 20 then raise exception 'Entries per person go from 1 to 20.'; end if;
  if p_deadline is null or p_deadline <= now() then raise exception 'Set an entry deadline in the future.'; end if;
  if p_visibility not in ('all', 'circle', 'invited') then raise exception 'Pick who can crash.'; end if;
  insert into contests (title, choices, allow_writeins, points, max_entries, deadline, visibility, sponsor)
  values (btrim(p_title), ch, coalesce(p_writeins, false), p_points, p_max, p_deadline, p_visibility, me) returning id into cid;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into contest_invitees values (cid, u) on conflict do nothing; end if;
  end loop;
  return cid;
end $$;

create or replace function public.contest_enter(p_contest uuid, p_choice text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c contests; pick text := btrim(coalesce(p_choice, '')); canon text; eid uuid;
begin
  select * into c from contests where id = p_contest for update;
  if not found or not contest_can_see(p_contest) then raise exception 'That contest isn''t open to you.'; end if;
  if c.visibility = 'invited' and me <> c.sponsor and not exists (select 1 from contest_invitees where contest_id = p_contest and uid = me) then
    raise exception 'This one is invite only.'; end if;
  if c.stage <> 'open' or now() >= c.deadline then raise exception 'Entries are closed.'; end if;
  if (select count(*) from contest_entries where contest_id = p_contest and uid = me) >= c.max_entries then
    raise exception 'You''ve used all % of your entries.', c.max_entries; end if;
  if pick = '' or char_length(pick) > 40 then raise exception 'Pick a choice (up to 40 characters).'; end if;
  select x into canon from unnest(c.choices) x where lower(x) = lower(pick) limit 1;
  if canon is null then
    select choice into canon from contest_entries where contest_id = p_contest and lower(choice) = lower(pick) limit 1;
  end if;
  if canon is null and not c.allow_writeins then raise exception 'Pick one of the listed choices.'; end if;
  insert into contest_entries (contest_id, uid, choice) values (p_contest, me, coalesce(canon, pick)) returning id into eid;
  return eid;
exception when unique_violation then raise exception 'You already picked that one.';
end $$;

create or replace function public.contest_withdraw(p_entry uuid)
returns void language plpgsql security definer set search_path = public as $$
declare e contest_entries; c contests;
begin
  select * into e from contest_entries where id = p_entry and uid = auth.uid();
  if not found then raise exception 'That entry isn''t yours.'; end if;
  select * into c from contests where id = e.contest_id;
  if c.stage <> 'open' or now() >= c.deadline then raise exception 'Entries are closed.'; end if;
  delete from contest_entries where id = p_entry;
end $$;

-- Book the payout (or refund) and close the contest.
create or replace function public._contest_settle(p_contest uuid, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; total int; wins int; pay numeric[]; amt int; r record; ids uuid[]; nm text[]; i int; j int; n int; title text;
begin
  select * into c from contests where id = p_contest for update;
  if c.stage in ('settled', 'void', 'canceled') then return; end if;
  select count(*), count(*) filter (where lower(choice) = lower(c.result)) into total, wins from contest_entries where contest_id = p_contest;
  if wins = 0 then
    update contests set stage = 'void', stage_at = now(),
      outcome_note = coalesce(p_note || ' ', '') || 'Nobody picked ' || c.result || ', so everyone''s refunded.' where id = p_contest;
    return;
  end if;
  -- people in the contest, and pairwise amounts: each losing entry's points split across winning entries
  select array_agg(uid order by uid), array_agg(pr.name order by uid) into ids, nm
    from (select distinct uid from contest_entries where contest_id = p_contest) e join profiles pr on pr.id = e.uid;
  n := cardinality(ids);
  pay := array_fill(0::numeric, array[n * n]);
  for r in select l.uid as loser, w.uid as winner, count(*) as cnt
           from contest_entries l, contest_entries w
           where l.contest_id = p_contest and w.contest_id = p_contest
             and lower(l.choice) <> lower(c.result) and lower(w.choice) = lower(c.result) and l.uid <> w.uid
           group by l.uid, w.uid loop
    i := array_position(ids, r.loser); j := array_position(ids, r.winner);
    pay[(i - 1) * n + j] := pay[(i - 1) * n + j] + c.points::numeric * r.cnt / wins;
  end loop;
  title := left('Contest · ' || c.title, 90);
  for i in 1..n loop for j in (i + 1)..n loop
    amt := round(pay[(i - 1) * n + j] - pay[(j - 1) * n + i]);   -- > 0: i owes j
    if amt = 0 then continue; end if;
    insert into predictions (title, category, stake_kind, points, due, terms, a_uid, a_name, b_uid, b_name, b_invited,
                             status, winner, visibility, auto_notified, decided_at, contest_id, log)
    values (title, 'Contest', 'points', least(abs(amt), 1000), (now() at time zone 'America/Los_Angeles')::date,
            left('Result: ' || c.result || '. ' || wins || ' winning entr' || case when wins = 1 then 'y' else 'ies' end || ' of ' || total || ', ' || c.points || ' pts each.', 240),
            case when amt > 0 then ids[j] else ids[i] end, case when amt > 0 then nm[j] else nm[i] end,
            case when amt > 0 then ids[i] else ids[j] end, case when amt > 0 then nm[i] else nm[j] end,
            case when amt > 0 then ids[i] else ids[j] end,
            'settled', 'a', 'pair', true, now(), p_contest,
            jsonb_build_array(jsonb_build_object('t', now(), 'by', 'Handshake', 'what', 'contest counted: ' || c.result)));
  end loop; end loop;
  update contests set stage = 'settled', stage_at = now(), outcome_note = p_note where id = p_contest;
end $$;

create or replace function public._contest_void(p_contest uuid, p_note text)
returns void language sql security definer set search_path = public as $$
  update contests set stage = 'void', stage_at = now(), outcome_note = p_note where id = p_contest and stage not in ('settled', 'void', 'canceled')
$$;

-- Sponsor records the result (after the deadline), or changes it while someone wants proof.
create or replace function public.contest_record(p_contest uuid, p_result text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; res text := btrim(coalesce(p_result, ''));
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.sponsor <> auth.uid() then raise exception 'Only the sponsor records the result.'; end if;
  if c.stage not in ('open', 'proving') then raise exception 'The result is already in.'; end if;
  if now() < c.deadline then raise exception 'Wait until entries close.'; end if;
  if res = '' or char_length(res) > 40 then raise exception 'Enter the result (up to 40 characters).'; end if;
  select coalesce((select x from unnest(c.choices) x where lower(x) = lower(res) limit 1),
                  (select choice from contest_entries where contest_id = p_contest and lower(choice) = lower(res) limit 1), res) into res;
  update contests set result = res, stage = 'recorded', stage_at = now(), objector = null, objection = null, proof_link = null where id = p_contest;
end $$;

create or replace function public.contest_prove_it(p_contest uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; me uuid := auth.uid();
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.stage <> 'recorded' then raise exception 'There''s no result waiting right now.'; end if;
  if now() > c.stage_at + interval '24 hours' then raise exception 'The 24 hours are up.'; end if;
  if me = c.sponsor or not exists (select 1 from contest_entries where contest_id = p_contest and uid = me) then
    raise exception 'Only people with an entry can say Prove it!'; end if;
  update contests set stage = 'proving', stage_at = now(), objector = me, objection = left(btrim(coalesce(p_reason, '')), 280) where id = p_contest;
end $$;

create or replace function public.contest_post_proof(p_contest uuid, p_link text)
returns void language plpgsql security definer set search_path = public as $$
declare c contests; l text := btrim(coalesce(p_link, ''));
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.sponsor <> auth.uid() then raise exception 'Only the sponsor posts proof.'; end if;
  if c.stage <> 'proving' then raise exception 'Nobody is asking for proof right now.'; end if;
  if l !~* '^https?://\S+$' or char_length(l) > 500 then raise exception 'Paste a link that starts with http.'; end if;
  update contests set stage = 'proof', stage_at = now(), proof_link = l where id = p_contest;
end $$;

create or replace function public.contest_accept_proof(p_contest uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c contests;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.objector <> auth.uid() or c.stage <> 'proof' then raise exception 'There''s no proof waiting for you.'; end if;
  perform _contest_settle(p_contest, null);
end $$;

-- The challenger says the proof doesn't hold up: pick a referee who isn't in the contest.
create or replace function public.contest_doesnt_hold(p_contest uuid, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c contests; ref uuid;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.objector <> auth.uid() or c.stage <> 'proof' then raise exception 'There''s no proof waiting for you.'; end if;
  select x.other into ref from (
    select case when p.a_uid in (c.sponsor, c.objector) then p.b_uid else p.a_uid end as other, p.decided_at
    from predictions p where p.status = 'settled' and p.contest_id is distinct from p_contest
      and (p.a_uid in (c.sponsor, c.objector) or p.b_uid in (c.sponsor, c.objector))) x
  where x.other is not null and x.other not in (c.sponsor, c.objector)
    and not exists (select 1 from contest_entries e where e.contest_id = p_contest and e.uid = x.other)
  order by x.decided_at desc nulls last limit 1;
  update contests set objection = coalesce(nullif(left(btrim(coalesce(p_reason, '')), 280), ''), objection) where id = p_contest;
  if ref is null then
    perform _contest_void(p_contest, 'Hopeless: nobody outside the contest could referee, so it''s called off.');
  else
    update contests set stage = 'refereeing', stage_at = now(), referee = ref where id = p_contest;
  end if;
  return ref;
end $$;

create or replace function public.contest_referee_pick(p_contest uuid, p_stands boolean)
returns void language plpgsql security definer set search_path = public as $$
declare c contests;
begin
  select * into c from contests where id = p_contest for update;
  if not found or c.referee <> auth.uid() or c.stage <> 'refereeing' then raise exception 'You''re not refereeing this one.'; end if;
  if p_stands then perform _contest_settle(p_contest, 'The referee said the result stands.');
  else perform _contest_void(p_contest, 'The referee called it off, so everyone''s refunded.'); end if;
end $$;

create or replace function public.contest_cancel(p_contest uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update contests set stage = 'canceled', stage_at = now() where id = p_contest and sponsor = auth.uid() and stage = 'open';
  if not found then raise exception 'Only the sponsor can cancel, and only before the result is in.'; end if;
end $$;

-- Every 10 minutes: move contests whose 24-hour clocks ran out.
create or replace function public.contest_tick()
returns int language plpgsql security definer set search_path = public as $$
declare c record; n int := 0;
begin
  for c in select id, stage from contests where stage in ('recorded', 'proving', 'proof', 'refereeing') and stage_at <= now() - interval '24 hours' loop
    if c.stage in ('recorded', 'proof') then perform _contest_settle(c.id, null);
    elsif c.stage = 'proving' then perform _contest_void(c.id, 'No proof was posted in time, so it''s called off.');
    else perform _contest_void(c.id, 'Hopeless: the referee didn''t pick in time, so it''s called off.'); end if;
    n := n + 1;
  end loop;
  return n;
end $$;

revoke all on function public._played_any(uuid, uuid[]), public.contest_can_see(uuid), public.create_contest(text, text[], boolean, int, int, timestamptz, text, uuid[]),
  public.contest_enter(uuid, text), public.contest_withdraw(uuid), public._contest_settle(uuid, text), public._contest_void(uuid, text),
  public.contest_record(uuid, text), public.contest_prove_it(uuid, text), public.contest_post_proof(uuid, text), public.contest_accept_proof(uuid),
  public.contest_doesnt_hold(uuid, text), public.contest_referee_pick(uuid, boolean), public.contest_cancel(uuid), public.contest_tick() from public, anon, authenticated;
grant execute on function public.contest_can_see(uuid), public.create_contest(text, text[], boolean, int, int, timestamptz, text, uuid[]),
  public.contest_enter(uuid, text), public.contest_withdraw(uuid), public.contest_record(uuid, text), public.contest_prove_it(uuid, text),
  public.contest_post_proof(uuid, text), public.contest_accept_proof(uuid), public.contest_doesnt_hold(uuid, text),
  public.contest_referee_pick(uuid, boolean), public.contest_cancel(uuid) to authenticated;
grant execute on function public.contest_tick(), public._contest_settle(uuid, text), public._contest_void(uuid, text) to service_role;

-- "Predictions and Counting!" counts calls people made, not points booked by pools, golf or contests.
create or replace function public.prediction_count()
returns bigint language sql stable security definer set search_path = public as $$
  select count(*) from predictions where pickem_group is null and wolf_round is null and contest_id is null
$$;

do $$ begin alter publication supabase_realtime add table public.contests; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.contest_entries; exception when duplicate_object then null; when undefined_object then null; end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-contests') where exists (select 1 from cron.job where jobname = 'handshake-contests');
  perform cron.schedule('handshake-contests', '*/10 * * * *', 'select public.contest_tick()');
end $$;

-- ================================================================
-- RSVP invites by phone (same as update-rsvp-2.sql)
-- ================================================================
create table if not exists public.rsvp_phone_invites (
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  phone_digits  text not null check (phone_digits ~ '^[0-9]{8,15}$'),
  name          text not null check (char_length(btrim(name)) between 1 and 30),
  claimed_uid   uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  primary key (event_id, phone_digits)
);
create table if not exists public.rsvp_lastcall_phones (
  event_id      uuid not null references public.rsvp_events (id) on delete cascade,
  phone_digits  text not null,
  name          text not null,
  claimed_uid   uuid references public.profiles (id) on delete set null,
  primary key (event_id, phone_digits)
);

-- The Handshake account with this phone number, if there is one.
create or replace function public._uid_for_phone(p_digits text)
returns uuid language sql stable security definer set search_path = public, auth as $$
  select u.id from auth.users u join public.profiles p on p.id = u.id
  where regexp_replace(coalesce(u.phone, ''), '\D', '', 'g') = p_digits limit 1
$$;

create or replace function public.rsvp_can_see(p_event uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from rsvp_events where id = p_event and organizer = auth.uid())
      or exists (select 1 from rsvp_invitees where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_lastcall where event_id = p_event and uid = auth.uid())
      or exists (select 1 from rsvp_phone_invites where event_id = p_event and phone_digits = _my_phone())
$$;

alter table public.rsvp_phone_invites enable row level security;
alter table public.rsvp_lastcall_phones enable row level security;
drop policy if exists "rsvp people see phone invitees" on public.rsvp_phone_invites;
create policy "rsvp people see phone invitees" on public.rsvp_phone_invites for select to authenticated using (public.rsvp_can_see(event_id));
drop policy if exists "rsvp people see last call phones" on public.rsvp_lastcall_phones;
create policy "rsvp people see last call phones" on public.rsvp_lastcall_phones for select to authenticated using (public.rsvp_can_see(event_id));
-- names yes, numbers no (the organizer gets numbers from rsvp_phone_numbers())
revoke all on public.rsvp_phone_invites, public.rsvp_lastcall_phones from authenticated;
grant select (event_id, name, claimed_uid, created_at) on public.rsvp_phone_invites to authenticated;
grant select (event_id, name, claimed_uid) on public.rsvp_lastcall_phones to authenticated;
grant all on public.rsvp_phone_invites, public.rsvp_lastcall_phones to service_role;

create or replace function public.rsvp_phone_numbers(p_event uuid)
returns table (name text, phone_digits text, claimed boolean, on_last_call boolean)
language sql stable security definer set search_path = public as $$
  select i.name, i.phone_digits, i.claimed_uid is not null,
    exists (select 1 from rsvp_lastcall_phones l where l.event_id = i.event_id and l.phone_digits = i.phone_digits)
  from rsvp_phone_invites i join rsvp_events e on e.id = i.event_id
  where i.event_id = p_event and e.organizer = auth.uid()
  order by i.created_at
$$;

-- Add one phone invite (or a normal invite if the number is already on Handshake).
create or replace function public._rsvp_add_phone(p_event uuid, p_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare d text := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'); nm text := btrim(coalesce(p_name, '')); u uuid;
begin
  if char_length(d) = 10 then d := '1' || d; end if;
  if d !~ '^[0-9]{8,15}$' then raise exception 'That phone number doesn''t look right: %', p_phone; end if;
  u := _uid_for_phone(d);
  if u is not null then
    if u <> (select organizer from rsvp_events where id = p_event) then
      insert into rsvp_invitees (event_id, uid) values (p_event, u) on conflict do nothing;
    end if;
    return;
  end if;
  if char_length(nm) not between 1 and 30 then raise exception 'Give each person you text a name.'; end if;
  insert into rsvp_phone_invites (event_id, phone_digits, name) values (p_event, d, nm)
  on conflict (event_id, phone_digits) do update set name = excluded.name;
end $$;

-- Start an event (now with phone invites: p_phones = [{name, phone}]).
drop function if exists public.create_rsvp(text, text, text, jsonb, uuid[]);
create or replace function public.create_rsvp(p_title text, p_venue text, p_notes text, p_options jsonb, p_invitees uuid[], p_phones jsonb default '[]')
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); eid uuid; o jsonb; oid uuid; u uuid; ph jsonb;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Say what it''s for (up to 60 characters).'; end if;
  if jsonb_typeof(p_options) <> 'array' or jsonb_array_length(p_options) = 0 then raise exception 'Propose at least one date.'; end if;
  if jsonb_array_length(p_options) > 20 then raise exception 'Up to 20 date options.'; end if;
  if coalesce(cardinality(p_invitees), 0) = 0 and coalesce(jsonb_array_length(p_phones), 0) = 0 then raise exception 'Invite at least one person.'; end if;
  insert into rsvp_events (title, venue, notes, organizer)
  values (btrim(p_title), nullif(left(btrim(coalesce(p_venue, '')), 60), ''), left(btrim(coalesce(p_notes, '')), 240), me)
  returning id into eid;
  for o in select * from jsonb_array_elements(p_options) loop
    insert into rsvp_options (event_id, day, end_day, at_time, added_by)
    values (eid, (o->>'day')::date, nullif(o->>'end_day', '')::date, nullif(o->>'at_time', '')::time, me)
    returning id into oid;
    insert into rsvp_answers (option_id, event_id, uid, answer) values (oid, eid, me, 'go');
  end loop;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into rsvp_invitees (event_id, uid) values (eid, u) on conflict do nothing; end if;
  end loop;
  for ph in select * from jsonb_array_elements(coalesce(p_phones, '[]')) loop
    perform _rsvp_add_phone(eid, ph->>'name', ph->>'phone');
  end loop;
  if not exists (select 1 from rsvp_invitees where event_id = eid) and not exists (select 1 from rsvp_phone_invites where event_id = eid) then
    raise exception 'Invite at least one other person.'; end if;
  update rsvp_events set open_count = (select count(*) from rsvp_tally(eid) t where t.works) where id = eid;
  return eid;
end $$;

-- Invite more people while it's still open.
create or replace function public.rsvp_invite(p_event uuid, p_invitees uuid[], p_phones jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare e rsvp_events; u uuid; ph jsonb;
begin
  select * into e from rsvp_events where id = p_event;
  if not found or e.organizer <> auth.uid() then raise exception 'Only the organizer can invite people.'; end if;
  if e.status <> 'open' then raise exception 'This one is locked down already.'; end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> e.organizer and exists (select 1 from profiles where id = u) then insert into rsvp_invitees (event_id, uid) values (p_event, u) on conflict do nothing; end if;
  end loop;
  for ph in select * from jsonb_array_elements(coalesce(p_phones, '[]')) loop
    perform _rsvp_add_phone(p_event, ph->>'name', ph->>'phone');
  end loop;
end $$;

-- Lock it down (now with phone invitees on the last call: p_phones = their digits).
drop function if exists public.rsvp_lock(uuid, uuid, text, uuid[]);
create or replace function public.rsvp_lock(p_event uuid, p_option uuid, p_venue text, p_people uuid[], p_phones text[] default '{}')
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); e rsvp_events; u uuid; d text; pi rsvp_phone_invites; n int := 0;
begin
  select * into e from rsvp_events where id = p_event for update;
  if not found or e.organizer <> me then raise exception 'Only the organizer can lock it down.'; end if;
  if e.status <> 'open' then raise exception 'This one is already locked down.'; end if;
  if not exists (select 1 from rsvp_options where id = p_option and event_id = p_event) then raise exception 'Pick one of the dates.'; end if;
  if char_length(btrim(coalesce(p_venue, ''))) not between 1 and 60 then raise exception 'Pick the venue.'; end if;
  update rsvp_events set status = 'locked', locked_option = p_option, locked_venue = btrim(p_venue), locked_at = now() where id = p_event;
  foreach u in array coalesce(p_people, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then
      insert into rsvp_lastcall (event_id, uid) values (p_event, u) on conflict do nothing; n := n + 1;
    end if;
  end loop;
  foreach d in array coalesce(p_phones, '{}') loop
    select * into pi from rsvp_phone_invites where event_id = p_event and phone_digits = d;
    if not found then continue; end if;
    if pi.claimed_uid is not null then
      insert into rsvp_lastcall (event_id, uid) values (p_event, pi.claimed_uid) on conflict do nothing;
    else
      insert into rsvp_lastcall_phones (event_id, phone_digits, name) values (p_event, d, pi.name) on conflict do nothing;
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- After signing in: turn invites sent to my phone number into normal invites. Returns how many.
create or replace function public.claim_rsvp_invites()
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); d text := _my_phone(); n int := 0; r record;
begin
  if me is null or d is null then return 0; end if;
  for r in select * from rsvp_phone_invites where phone_digits = d and claimed_uid is null loop
    if me <> (select organizer from rsvp_events where id = r.event_id) then
      insert into rsvp_invitees (event_id, uid) values (r.event_id, me) on conflict do nothing;
      n := n + 1;
    end if;
    update rsvp_phone_invites set claimed_uid = me where event_id = r.event_id and phone_digits = d;
  end loop;
  for r in select * from rsvp_lastcall_phones where phone_digits = d and claimed_uid is null loop
    insert into rsvp_lastcall (event_id, uid) values (r.event_id, me) on conflict do nothing;
    update rsvp_lastcall_phones set claimed_uid = me where event_id = r.event_id and phone_digits = d;
  end loop;
  return n;
end $$;

revoke all on function public._uid_for_phone(text), public._rsvp_add_phone(uuid, text, text) from public, anon, authenticated;
revoke all on function public.rsvp_phone_numbers(uuid), public.create_rsvp(text, text, text, jsonb, uuid[], jsonb), public.rsvp_invite(uuid, uuid[], jsonb),
  public.rsvp_lock(uuid, uuid, text, uuid[], text[]), public.claim_rsvp_invites() from public, anon;
grant execute on function public.rsvp_phone_numbers(uuid), public.create_rsvp(text, text, text, jsonb, uuid[], jsonb), public.rsvp_invite(uuid, uuid[], jsonb),
  public.rsvp_lock(uuid, uuid, text, uuid[], text[]), public.claim_rsvp_invites() to authenticated;

-- ================================================================
-- Venmo handles on settle-ups and Quanto (same as update-venmo.sql)
-- ================================================================
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

-- ================================================================
-- A loss recorded by the loser counts right away (same as update-concede.sql)
-- ================================================================
create or replace function public.report_result(p_id uuid, p_winner text)
returns void language plpgsql security definer set search_path = public as $$
declare r predictions := _load(p_id); s text := _side(r);
begin
  if s is null then raise exception 'Only the two players can record a result.'; end if;
  if r.parent_id is not null then raise exception 'Crashes score themselves with the original.'; end if;
  if r.status not in ('open', 'reported', 'disputed') then raise exception 'This one can''t take a result right now.'; end if;
  if p_winner not in ('a', 'b', 'push', 'void') then raise exception 'Pick who called it.'; end if;
  if p_winner in ('a', 'b') and p_winner <> s then
    -- conceding: counts now
    update predictions set status = 'settled', winner = p_winner, decided_at = now(),
      report_winner = p_winner, report_by = s, dispute_by = null,
      log = log || _entry('conceded: ' || case p_winner when 'a' then a_name else b_name end || ' won')
    where id = p_id;
    perform _resolve_crashes(p_id, p_winner);
    return;
  end if;
  update predictions set status = 'reported', report_winner = p_winner, report_by = s,
    dispute_by = now() + interval '24 hours',
    log = log || _entry('recorded: ' || case p_winner when 'push' then 'tie' when 'void' then 'call it off'
      when 'a' then a_name || ' won' else b_name || ' won' end)
  where id = p_id;
end $$;

-- ============ Squares (update-squares.sql) ============
--
-- How it works (decided Nov 14):
--   * A 10x10 grid, squares numbered 1-100 (square = row*10 + column + 1). Columns = home team,
--     rows = visiting team.
--   * The originator picks one or more NFL games (from the Vegas lines), the points per square,
--     the payout per quarter as a percent of the pot (100 squares x price; per game if several),
--     and invitees. Anyone can see a pool; people who aren't invited can ask to crash, and the
--     originator lets them in.
--   * Players claim any open squares (and can release theirs) until the numbers are drawn.
--   * Numbers 0-9 are drawn at random for the columns and rows when the last square is claimed,
--     when the originator taps Draw numbers, or automatically at the first kickoff. Any unsold
--     squares then belong to the originator.
--   * After each quarter the squares function records the score (from ESPN) and the winner: the
--     square where the last digit of the home score (column) meets the last digit of the visiting
--     score (row). Q4 uses the final score, overtime included. The originator can fix a score.
--     Everyone in the pool gets a notification with the score, winner and points.
--   * Separate, like golf: nothing goes into Standings or Rivals. The originator tracks who's paid
--     their buy-in (squares x price).

create table if not exists public.squares_pools (
  id               uuid primary key default gen_random_uuid(),
  title            text not null check (char_length(btrim(title)) between 1 and 60),
  originator       uuid not null references public.profiles (id) on delete cascade,
  price            int not null check (price between 1 and 1000),
  status           text not null default 'open' check (status in ('open', 'drawn', 'done', 'canceled')),
  digits_home      int[],            -- column c shows digits_home[c+1]
  digits_away      int[],            -- row r shows digits_away[r+1]
  drawn_at         timestamptz,
  draw_notified_at timestamptz,
  created_at       timestamptz not null default now()
);
create table if not exists public.squares_games (
  pool_id   uuid not null references public.squares_pools (id) on delete cascade,
  game_id   text not null references public.vegas_lines (id) on delete cascade,
  ord       int not null default 0,
  pct       numeric(6, 2)[] not null check (cardinality(pct) = 4),   -- Q1, Q2, Q3, Final
  primary key (pool_id, game_id)
);
create table if not exists public.squares_invitees (
  pool_id  uuid not null references public.squares_pools (id) on delete cascade,
  uid      uuid not null references public.profiles (id) on delete cascade,
  primary key (pool_id, uid)
);
create table if not exists public.squares_crash (
  pool_id      uuid not null references public.squares_pools (id) on delete cascade,
  uid          uuid not null references public.profiles (id) on delete cascade,
  status       text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at   timestamptz not null default now(),
  answered_at  timestamptz,
  primary key (pool_id, uid)
);
create table if not exists public.squares_claims (
  pool_id     uuid not null references public.squares_pools (id) on delete cascade,
  square      int not null check (square between 1 and 100),
  uid         uuid not null references public.profiles (id) on delete cascade,
  unsold      boolean not null default false,   -- given to the originator at the draw
  claimed_at  timestamptz not null default now(),
  primary key (pool_id, square)
);
create table if not exists public.squares_paid (
  pool_id  uuid not null references public.squares_pools (id) on delete cascade,
  uid      uuid not null references public.profiles (id) on delete cascade,
  paid_at  timestamptz not null default now(),
  primary key (pool_id, uid)
);
create table if not exists public.squares_results (
  pool_id      uuid not null references public.squares_pools (id) on delete cascade,
  game_id      text not null references public.vegas_lines (id) on delete cascade,
  quarter      int not null check (quarter between 1 and 4),
  home         int not null check (home >= 0),
  away         int not null check (away >= 0),
  square       int not null,
  uid          uuid references public.profiles (id) on delete set null,
  points       int not null,
  source       text not null default 'auto' check (source in ('auto', 'manual')),
  recorded_at  timestamptz not null default now(),
  notified_at  timestamptz,
  primary key (pool_id, game_id, quarter)
);

alter table public.squares_pools enable row level security;
alter table public.squares_games enable row level security;
alter table public.squares_invitees enable row level security;
alter table public.squares_crash enable row level security;
alter table public.squares_claims enable row level security;
alter table public.squares_paid enable row level security;
alter table public.squares_results enable row level security;
do $$
declare t text;
begin
  foreach t in array array['squares_pools', 'squares_games', 'squares_invitees', 'squares_claims', 'squares_results'] loop
    execute format('drop policy if exists "signed in can see" on public.%I', t);
    execute format('create policy "signed in can see" on public.%I for select to authenticated using (true)', t);
  end loop;
end $$;
drop policy if exists "own or my pool's requests" on public.squares_crash;
create policy "own or my pool's requests" on public.squares_crash for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.squares_pools p where p.id = pool_id and p.originator = auth.uid()));
drop policy if exists "players see paid" on public.squares_paid;
create policy "players see paid" on public.squares_paid for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.squares_pools p where p.id = pool_id and p.originator = auth.uid()));
grant select on public.squares_pools, public.squares_games, public.squares_invitees, public.squares_crash,
  public.squares_claims, public.squares_paid, public.squares_results to authenticated;
grant all on public.squares_pools, public.squares_games, public.squares_invitees, public.squares_crash,
  public.squares_claims, public.squares_paid, public.squares_results to service_role;

create or replace function public._squares_member(p_pool uuid, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from squares_pools where id = p_pool and originator = p_uid)
      or exists (select 1 from squares_invitees where pool_id = p_pool and uid = p_uid)
$$;

create or replace function public.create_squares(p_title text, p_price int, p_games jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; g jsonb; total numeric := 0; n int := 0; u uuid; pc numeric[];
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Name the pool (up to 60 characters).'; end if;
  if p_price is null or p_price not between 1 and 1000 then raise exception 'Points per square go from 1 to 1000.'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then raise exception 'Pick at least one game.'; end if;
  if jsonb_array_length(p_games) > 8 then raise exception 'Up to 8 games.'; end if;
  insert into squares_pools (title, originator, price) values (btrim(p_title), me, p_price) returning id into pid;
  for g in select * from jsonb_array_elements(p_games) loop
    if not exists (select 1 from vegas_lines where id = g->>'game_id' and starts_at > now()) then
      raise exception 'One of those games has already started or isn''t on the list.'; end if;
    pc := array(select (x)::numeric from jsonb_array_elements_text(g->'pct') x);
    if cardinality(pc) <> 4 or exists (select 1 from unnest(pc) x where x < 0 or x > 100) then raise exception 'Give four payout percentages per game.'; end if;
    total := total + (select sum(x) from unnest(pc) x);
    insert into squares_games (pool_id, game_id, ord, pct) values (pid, g->>'game_id', n, pc);
    n := n + 1;
  end loop;
  if abs(total - 100) > 0.1 then raise exception '%', format('Payouts have to add up to 100%% of the pot (they add up to %s%%).', round(total, 2)); end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into squares_invitees values (pid, u) on conflict do nothing; end if;
  end loop;
  return pid;
end $$;

-- Draw the numbers: random 0-9 for columns (home) and rows (visitors). Unsold squares go to the originator.
create or replace function public._squares_draw(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
declare p squares_pools;
begin
  select * into p from squares_pools where id = p_pool for update;
  if p.status <> 'open' then return; end if;
  insert into squares_claims (pool_id, square, uid, unsold)
  select p_pool, s, p.originator, true from generate_series(1, 100) s
  where not exists (select 1 from squares_claims c where c.pool_id = p_pool and c.square = s);
  update squares_pools set status = 'drawn', drawn_at = now(),
    digits_home = array(select x from generate_series(0, 9) x order by random()),
    digits_away = array(select x from generate_series(0, 9) x order by random())
  where id = p_pool;
end $$;

create or replace function public.squares_claim(p_pool uuid, p_squares int[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); p squares_pools; s int; taken int;
begin
  select * into p from squares_pools where id = p_pool for update;
  if not found or not _squares_member(p_pool, me) then raise exception 'You''re not in this pool. Ask to crash first.'; end if;
  if p.status <> 'open' then raise exception 'The numbers are drawn; squares are closed.'; end if;
  if coalesce(cardinality(p_squares), 0) = 0 then raise exception 'Pick at least one square.'; end if;
  foreach s in array p_squares loop
    if s not between 1 and 100 then raise exception 'Squares go from 1 to 100.'; end if;
    select count(*) into taken from squares_claims where pool_id = p_pool and square = s;
    if taken > 0 then raise exception 'Square % was just taken. Pick another.', s; end if;
    insert into squares_claims (pool_id, square, uid) values (p_pool, s, me);
  end loop;
  if (select count(*) from squares_claims where pool_id = p_pool) = 100 then perform _squares_draw(p_pool); end if;
  return (select count(*) from squares_claims where pool_id = p_pool and uid = me);
end $$;

create or replace function public.squares_release(p_pool uuid, p_squares int[])
returns void language plpgsql security definer set search_path = public as $$
begin
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'The numbers are drawn; squares are closed.'; end if;
  delete from squares_claims where pool_id = p_pool and uid = auth.uid() and square = any (p_squares);
end $$;

create or replace function public.squares_draw(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can draw the numbers.'; end if;
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'The numbers are already drawn.'; end if;
  perform _squares_draw(p_pool);
end $$;

create or replace function public.squares_request_crash(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if _squares_member(p_pool, auth.uid()) then raise exception 'You''re already in this pool.'; end if;
  if (select status from squares_pools where id = p_pool) <> 'open' then raise exception 'Squares are closed.'; end if;
  insert into squares_crash (pool_id, uid) values (p_pool, auth.uid())
  on conflict (pool_id, uid) do update set status = 'pending', created_at = now(), answered_at = null;
end $$;

create or replace function public.squares_answer_crash(p_pool uuid, p_uid uuid, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can answer.'; end if;
  update squares_crash set status = case when p_accept then 'accepted' else 'declined' end, answered_at = now()
  where pool_id = p_pool and uid = p_uid and status = 'pending';
  if not found then raise exception 'That request was already answered.'; end if;
  if p_accept then insert into squares_invitees values (p_pool, p_uid) on conflict do nothing; end if;
end $$;

create or replace function public.squares_mark_paid(p_pool uuid, p_uid uuid, p_paid boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator tracks buy-ins.'; end if;
  if p_paid then insert into squares_paid (pool_id, uid) values (p_pool, p_uid) on conflict do nothing;
  else delete from squares_paid where pool_id = p_pool and uid = p_uid; end if;
end $$;

-- Record a quarter's score and its winner. Auto scores never overwrite; manual fixes do (and re-notify).
create or replace function public._squares_record(p_pool uuid, p_game text, p_q int, p_home int, p_away int, p_source text)
returns boolean language plpgsql security definer set search_path = public as $$
declare p squares_pools; g squares_games; c int; r int; sq int; owner uuid; pts int; changed int;
begin
  select * into p from squares_pools where id = p_pool;
  if p.status not in ('drawn', 'done') then return false; end if;
  select * into g from squares_games where pool_id = p_pool and game_id = p_game;
  if not found or p_q not between 1 and 4 or p_home < 0 or p_away < 0 then return false; end if;
  c := array_position(p.digits_home, p_home % 10) - 1;
  r := array_position(p.digits_away, p_away % 10) - 1;
  sq := r * 10 + c + 1;
  select uid into owner from squares_claims where pool_id = p_pool and square = sq;
  pts := round(p.price * 100 * g.pct[p_q] / 100);
  if p_source = 'manual' then
    insert into squares_results (pool_id, game_id, quarter, home, away, square, uid, points, source)
    values (p_pool, p_game, p_q, p_home, p_away, sq, owner, pts, 'manual')
    on conflict (pool_id, game_id, quarter) do update set home = excluded.home, away = excluded.away, square = excluded.square,
      uid = excluded.uid, points = excluded.points, source = 'manual', recorded_at = now(), notified_at = null;
  else
    insert into squares_results (pool_id, game_id, quarter, home, away, square, uid, points, source)
    values (p_pool, p_game, p_q, p_home, p_away, sq, owner, pts, 'auto')
    on conflict do nothing;
  end if;
  get diagnostics changed = row_count;
  -- finished once every game has all four quarters
  if not exists (select 1 from squares_games x where x.pool_id = p_pool
                 and (select count(*) from squares_results y where y.pool_id = p_pool and y.game_id = x.game_id) < 4) then
    update squares_pools set status = 'done' where id = p_pool and status = 'drawn';
  end if;
  return changed > 0;
end $$;

-- The originator fixes (or enters) a quarter's score.
create or replace function public.squares_set_quarter(p_pool uuid, p_game text, p_q int, p_home int, p_away int)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not exists (select 1 from squares_pools where id = p_pool and originator = auth.uid()) then raise exception 'Only the originator can fix a score.'; end if;
  if (select status from squares_pools where id = p_pool) not in ('drawn', 'done') then raise exception 'Draw the numbers first.'; end if;
  if p_home is null or p_away is null or p_home < 0 or p_away < 0 or p_home > 200 or p_away > 200 then raise exception 'Enter both scores.'; end if;
  perform _squares_record(p_pool, p_game, p_q, p_home, p_away, 'manual');
end $$;

create or replace function public.squares_cancel(p_pool uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  update squares_pools set status = 'canceled' where id = p_pool and originator = auth.uid() and status = 'open';
  if not found then raise exception 'Only the originator can cancel, and only before the numbers are drawn.'; end if;
end $$;

-- For the squares function: draw at the first kickoff, and list games still needing quarter scores.
create or replace function public.squares_tick()
returns int language plpgsql security definer set search_path = public as $$
declare p record; n int := 0;
begin
  for p in select sp.id from squares_pools sp where sp.status = 'open'
           and (select min(v.starts_at) from squares_games g join vegas_lines v on v.id = g.game_id where g.pool_id = sp.id) <= now() loop
    perform _squares_draw(p.id); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.squares_pending_games()
returns table (pool_id uuid, game_id text, home text, away text, starts_at timestamptz, have int)
language sql stable security definer set search_path = public as $$
  select g.pool_id, g.game_id, v.home, v.away, v.starts_at,
    (select count(*)::int from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id)
  from squares_games g join squares_pools p on p.id = g.pool_id join vegas_lines v on v.id = g.game_id
  where p.status = 'drawn' and v.starts_at <= now() and v.starts_at > now() - interval '18 hours'
    and (select count(*) from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id) < 4
$$;

create or replace function public.squares_record_auto(p_pool uuid, p_game text, p_q int, p_home int, p_away int)
returns boolean language sql security definer set search_path = public as $$
  select _squares_record(p_pool, p_game, p_q, p_home, p_away, 'auto')
$$;

revoke all on function public._squares_member(uuid, uuid), public._squares_draw(uuid), public._squares_record(uuid, text, int, int, int, text),
  public.squares_tick(), public.squares_pending_games(), public.squares_record_auto(uuid, text, int, int, int) from public, anon, authenticated;
grant execute on function public.squares_tick(), public.squares_pending_games(), public.squares_record_auto(uuid, text, int, int, int) to service_role;
revoke all on function public.create_squares(text, int, jsonb, uuid[]), public.squares_claim(uuid, int[]), public.squares_release(uuid, int[]),
  public.squares_draw(uuid), public.squares_request_crash(uuid), public.squares_answer_crash(uuid, uuid, boolean),
  public.squares_mark_paid(uuid, uuid, boolean), public.squares_set_quarter(uuid, text, int, int, int), public.squares_cancel(uuid) from public, anon;
grant execute on function public.create_squares(text, int, jsonb, uuid[]), public.squares_claim(uuid, int[]), public.squares_release(uuid, int[]),
  public.squares_draw(uuid), public.squares_request_crash(uuid), public.squares_answer_crash(uuid, uuid, boolean),
  public.squares_mark_paid(uuid, uuid, boolean), public.squares_set_quarter(uuid, text, int, int, int), public.squares_cancel(uuid) to authenticated;

do $$ begin alter publication supabase_realtime add table public.squares_claims; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.squares_pools; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.squares_results; exception when duplicate_object then null; when undefined_object then null; end $$;

-- Every 5 minutes: call the squares function (draws at kickoff, quarter scores, notifications).
-- It returns right away when no pool needs anything.
create extension if not exists pg_net;
do $$
begin
  create extension if not exists pg_cron;
  perform cron.unschedule('handshake-squares') where exists (select 1 from cron.job where jobname = 'handshake-squares');
  perform cron.schedule('handshake-squares', '*/5 * * * *',
    $job$select net.http_post(url := 'https://akgrilycmjrskuqelhju.supabase.co/functions/v1/squares',
                              headers := '{"Content-Type": "application/json"}'::jsonb, body := '{}'::jsonb)$job$);
end $$;


-- ============ Pick 'em invites by account (update-pickem-4.sql) ============
--
-- Any member can invite Handshake people to their group from the Invite friends panel.
-- An invited person sees "You're invited" with Join / No thanks on the group card (and gets a
-- notification): no code or link needed. Codes and links still work for everyone else.

create table if not exists public.pickem_invites (
  group_id    uuid not null references public.pickem_groups (id) on delete cascade,
  uid         uuid not null references public.profiles (id) on delete cascade,
  invited_by  uuid not null references public.profiles (id) on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'joined', 'declined')),
  created_at  timestamptz not null default now(),
  answered_at timestamptz,
  primary key (group_id, uid)
);
alter table public.pickem_invites enable row level security;
drop policy if exists "mine or my group's invites" on public.pickem_invites;
create policy "mine or my group's invites" on public.pickem_invites for select to authenticated using (
  uid = auth.uid() or exists (select 1 from public.pickem_members m where m.group_id = pickem_invites.group_id and m.uid = auth.uid()));
grant select on public.pickem_invites to authenticated;
grant all on public.pickem_invites to service_role;

-- A member invites people (returns how many new invites went out).
create or replace function public.pickem_invite(p_group uuid, p_uids uuid[])
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); u uuid; n int := 0;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if not exists (select 1 from pickem_members where group_id = p_group and uid = me) then raise exception 'Only members can invite people.'; end if;
  foreach u in array coalesce(p_uids, '{}') loop
    continue when u = me or not exists (select 1 from profiles where id = u)
      or exists (select 1 from pickem_members where group_id = p_group and uid = u);
    insert into pickem_invites (group_id, uid, invited_by) values (p_group, u, me)
    on conflict (group_id, uid) do update set invited_by = me, status = 'pending', created_at = now(), answered_at = null
      where pickem_invites.status <> 'pending';
    if found then n := n + 1; end if;
  end loop;
  return n;
end $$;

-- The invited person joins (or says no thanks).
create or replace function public.pickem_answer_invite(p_group uuid, p_join boolean)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  update pickem_invites set status = case when p_join then 'joined' else 'declined' end, answered_at = now()
  where group_id = p_group and uid = me and status = 'pending';
  if not found then raise exception 'That invite isn''t open anymore.'; end if;
  if p_join then
    insert into pickem_members (group_id, uid) values (p_group, me) on conflict do nothing;
    update pickem_crash_requests set status = 'accepted', answered_at = now() where group_id = p_group and uid = me and status = 'pending';
  end if;
end $$;

-- Joining any other way (code, link, crash accepted) closes an open invite too.
create or replace function public._pickem_close_invite() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update pickem_invites set status = 'joined', answered_at = now() where group_id = new.group_id and uid = new.uid and status = 'pending';
  return new;
end $$;
drop trigger if exists pickem_close_invite on public.pickem_members;
create trigger pickem_close_invite after insert on public.pickem_members for each row execute function public._pickem_close_invite();

revoke all on function public.pickem_invite(uuid, uuid[]), public.pickem_answer_invite(uuid, boolean), public._pickem_close_invite() from public, anon;
grant execute on function public.pickem_invite(uuid, uuid[]), public.pickem_answer_invite(uuid, boolean) to authenticated;


-- ============ Squares games from the NFL schedule (update-squares-2.sql) ============
--
-- Squares used to offer only games with Vegas lines (about a week out). Now the Start a pool form
-- has a week picker, and games come from ESPN's NFL schedule (the squares function fetches the
-- week and saves it in nfl_schedule), so a pool can be set up weeks ahead (Thanksgiving, etc.).
-- Each pool game keeps its own teams and kickoff, so it no longer depends on vegas_lines.

create table if not exists public.nfl_schedule (
  id          text primary key,            -- ESPN's event id
  starts_at   timestamptz not null,
  home        text not null,
  away        text not null,
  updated_at  timestamptz not null default now()
);
create index if not exists nfl_schedule_starts on public.nfl_schedule (starts_at);
alter table public.nfl_schedule enable row level security;
drop policy if exists "signed in can see" on public.nfl_schedule;
create policy "signed in can see" on public.nfl_schedule for select to authenticated using (true);
grant select on public.nfl_schedule to authenticated;
grant all on public.nfl_schedule to service_role;

-- Pool games carry their own teams and kickoff now (ESPN event ids for new pools).
alter table public.squares_games drop constraint if exists squares_games_game_id_fkey;
alter table public.squares_results drop constraint if exists squares_results_game_id_fkey;
alter table public.squares_games add column if not exists starts_at timestamptz;
alter table public.squares_games add column if not exists home text;
alter table public.squares_games add column if not exists away text;
update public.squares_games g set starts_at = v.starts_at, home = v.home, away = v.away
from public.vegas_lines v where v.id = g.game_id and g.starts_at is null;

create or replace function public.create_squares(p_title text, p_price int, p_games jsonb, p_invitees uuid[])
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); pid uuid; g jsonb; s nfl_schedule; total numeric := 0; n int := 0; u uuid; pc numeric[];
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 1 and 60 then raise exception 'Name the pool (up to 60 characters).'; end if;
  if p_price is null or p_price not between 1 and 1000 then raise exception 'Points per square go from 1 to 1000.'; end if;
  if jsonb_typeof(p_games) <> 'array' or jsonb_array_length(p_games) = 0 then raise exception 'Pick at least one game.'; end if;
  if jsonb_array_length(p_games) > 8 then raise exception 'Up to 8 games.'; end if;
  insert into squares_pools (title, originator, price) values (btrim(p_title), me, p_price) returning id into pid;
  for g in select * from jsonb_array_elements(p_games) loop
    select * into s from nfl_schedule where id = g->>'game_id';
    if not found then raise exception 'One of those games isn''t on the schedule. Pick the week again.'; end if;
    if s.starts_at <= now() then raise exception 'One of those games has already started.'; end if;
    pc := array(select (x)::numeric from jsonb_array_elements_text(g->'pct') x);
    if cardinality(pc) <> 4 or exists (select 1 from unnest(pc) x where x < 0 or x > 100) then raise exception 'Give four payout percentages per game.'; end if;
    total := total + (select sum(x) from unnest(pc) x);
    insert into squares_games (pool_id, game_id, ord, pct, starts_at, home, away) values (pid, s.id, n, pc, s.starts_at, s.home, s.away);
    n := n + 1;
  end loop;
  if abs(total - 100) > 0.1 then raise exception '%', format('Payouts have to add up to 100%% of the pot (they add up to %s%%).', round(total, 2)); end if;
  foreach u in array coalesce(p_invitees, '{}') loop
    if u <> me and exists (select 1 from profiles where id = u) then insert into squares_invitees values (pid, u) on conflict do nothing; end if;
  end loop;
  return pid;
end $$;

create or replace function public.squares_tick()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  -- keep kickoff times current (the schedule can flex)
  update squares_games g set starts_at = s.starts_at from nfl_schedule s
  where s.id = g.game_id and s.starts_at <> g.starts_at
    and exists (select 1 from squares_pools sp where sp.id = g.pool_id and sp.status in ('open', 'drawn'));
  for r in select sp.id from squares_pools sp where sp.status = 'open'
           and (select min(g.starts_at) from squares_games g where g.pool_id = sp.id) <= now() loop
    perform _squares_draw(r.id); n := n + 1;
  end loop;
  return n;
end $$;

drop function if exists public.squares_pending_games();
create function public.squares_pending_games()
returns table (pool_id uuid, game_id text, home text, away text, starts_at timestamptz, have int)
language sql stable security definer set search_path = public as $$
  select g.pool_id, g.game_id, g.home, g.away, g.starts_at,
    (select count(*)::int from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id)
  from squares_games g join squares_pools p on p.id = g.pool_id
  where p.status = 'drawn' and g.starts_at <= now() and g.starts_at > now() - interval '18 hours'
    and (select count(*) from squares_results r where r.pool_id = g.pool_id and r.game_id = g.game_id) < 4
$$;
revoke all on function public.squares_pending_games() from public, anon, authenticated;
grant execute on function public.squares_pending_games() to service_role;


-- ============ Squares invite links (update-squares-3.sql) ============
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


-- ============ Keep it fun, Report, Block (update-moderation.sql) ============
--
-- Handshake is for fun: no profanity, sexual content, violence, hate, or politics.
--   1. Word list (always on, instant): every typed field is checked against blocked_words, with
--      common letter swaps (sh1t, @ss...) caught. Blocked text is refused with a "Keep it fun" message.
--   2. AI check (Claude): the app sends typed text to the "screen" Edge Function first; text that
--      passes is remembered in screened_text. Once the screen function has worked once, it switches
--      on moderation_settings.require_screen, and from then on the database refuses typed text that
--      wasn't checked. Everything that existed before this update counts as checked.
--   3. Report: anyone can report a prediction, contest, plan, pool, group, golf round or a person.
--      Moderators (app_admins) get a notification, see the Reports list in the app, and can Remove
--      the content (its text is replaced with "Removed by Handshake"), Dismiss, or Suspend the person
--      (a suspended account can't post or change anything with text).
--   4. Block: you can block a person. You won't see their predictions on Everyone or their pools,
--      contests, groups or plans; neither of you can make a prediction with the other, and invites
--      between you are skipped.

/* ---------- settings and the word list ---------- */
create table if not exists public.moderation_settings (
  id              int primary key default 1 check (id = 1),
  require_screen  boolean not null default false,
  turned_on_at    timestamptz
);
insert into public.moderation_settings (id) values (1) on conflict do nothing;
alter table public.moderation_settings enable row level security;
grant all on public.moderation_settings to service_role;

create table if not exists public.blocked_words (word text primary key);
alter table public.blocked_words enable row level security;
grant all on public.blocked_words to service_role;
insert into public.blocked_words (word) select unnest(array[
  -- profanity
  'fuck','fucker','fucking','fuk','fck','motherfucker','shit','shitty','bullshit','bitch','bitches','asshole','ass','dumbass','jackass',
  'bastard','dickhead','cock','cocksucker','pussy','cunt','twat','prick','piss','pissed','damnit','goddamn','wtf','stfu',
  -- sexual
  'sex','sexy','porn','porno','nude','nudes','naked','boobs','boob','tits','titties','penis','vagina','dildo','orgasm','horny','blowjob',
  'handjob','jizz','anal','milf','slut','whore','hooker','stripper','threesome','erection','boner','masturbate','onlyfans','nsfw',
  -- hate (slurs)
  'nigger','nigga','niggas','chink','gook','spic','wetback','kike','faggot','fag','dyke','tranny','retard','retarded','raghead','towelhead',
  'beaner','coon','honky','paki','nazi','kkk','heil',
  -- violence and threats
  'kys','rape','rapist','shoot up','school shooting','terrorist','bomb threat',
  -- politics
  'trump','biden','kamala','obama','maga','democrat','democrats','republican','republicans','gop','dnc','rnc','liberals','conservatives',
  'newsom','desantis','pelosi','aoc','election','elections','impeach','impeachment','abortion','congress','senate race','ballot',
  'antifa','socialist','communist','fascist','left wing','right wing','pro life','pro choice','gun control','immigration'
]) on conflict do nothing;

-- Same normalizing as the screen function: lowercase, single spaces, trimmed.
create or replace function public._mod_norm(t text) returns text language sql immutable as $$
  select lower(regexp_replace(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g'), '^ | $', '', 'g'))
$$;

-- The blocked word found in a text (or null). Catches common letter swaps and simple endings.
create or replace function public._mod_bad(t text) returns text language sql stable security definer set search_path = public as $$
  with x as (select ' ' || regexp_replace(translate(lower(coalesce(t, '')), '0134578@$!|', 'oieastbasii'), '[^a-z]+', ' ', 'g') || ' ' as s)
  select w.word from blocked_words w, x
  where x.s ~ ('\m' || replace(w.word, ' ', ' +') || '(s|es|ed|er|ers|ing)?\M')
  limit 1
$$;

create table if not exists public.screened_text (
  t           text primary key,          -- _mod_norm(text) that passed
  source      text not null default 'ai', -- ai | existing | unchecked | system
  checked_at  timestamptz not null default now()
);
alter table public.screened_text enable row level security;
grant all on public.screened_text to service_role;

-- The screen function stores text that passed.
create or replace function public.screen_store(p_texts text[], p_source text default 'ai', p_turn_on boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into screened_text (t, source) select distinct _mod_norm(x), p_source from unnest(coalesce(p_texts, '{}')) x where _mod_norm(x) <> ''
  on conflict (t) do nothing;
  if p_turn_on then update moderation_settings set require_screen = true, turned_on_at = coalesce(turned_on_at, now()) where id = 1 and not require_screen; end if;
end $$;
revoke all on function public.screen_store(text[], text, boolean) from public, anon, authenticated;
grant execute on function public.screen_store(text[], text, boolean) to service_role;
create or replace function public.mod_word_check(p_texts text[]) returns table (t text, word text)
language sql stable security definer set search_path = public as $$
  select x, _mod_bad(x) from unnest(coalesce(p_texts, '{}')) x where _mod_bad(x) is not null
$$;
grant execute on function public.mod_word_check(text[]) to service_role;

/* ---------- moderators, suspensions, blocks, reports ---------- */
create table if not exists public.app_admins (uid uuid primary key references public.profiles (id) on delete cascade);
alter table public.app_admins enable row level security;
drop policy if exists "see own" on public.app_admins;
create policy "see own" on public.app_admins for select to authenticated using (uid = auth.uid());
grant select on public.app_admins to authenticated;
grant all on public.app_admins to service_role;
create or replace function public._is_admin(u uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where uid = u)
$$;

alter table public.profiles add column if not exists suspended boolean not null default false;

create table if not exists public.user_blocks (
  blocker     uuid not null references public.profiles (id) on delete cascade,
  blocked     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker, blocked)
);
alter table public.user_blocks enable row level security;
drop policy if exists "own blocks" on public.user_blocks;
create policy "own blocks" on public.user_blocks for select to authenticated using (blocker = auth.uid());
grant select on public.user_blocks to authenticated;
grant all on public.user_blocks to service_role;
create or replace function public._blocked_pair(a uuid, b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select a is not null and b is not null and exists (select 1 from user_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;
create or replace function public.block_user(p_uid uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_uid = auth.uid() then raise exception 'You can''t block yourself.'; end if;
  if p_on then insert into user_blocks (blocker, blocked) values (auth.uid(), p_uid) on conflict do nothing;
  else delete from user_blocks where blocker = auth.uid() and blocked = p_uid; end if;
end $$;

create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter     uuid not null references public.profiles (id) on delete cascade,
  kind         text not null check (kind in ('prediction', 'contest', 'rsvp', 'squares', 'pickem', 'wolf', 'profile')),
  item_id      text not null,
  item_uid     uuid references public.profiles (id) on delete set null,   -- who posted it
  excerpt      text not null default '',
  reason       text not null default '',
  status       text not null default 'open' check (status in ('open', 'removed', 'dismissed')),
  created_at   timestamptz not null default now(),
  handled_by   uuid references public.profiles (id) on delete set null,
  handled_at   timestamptz,
  note         text
);
alter table public.reports enable row level security;
drop policy if exists "reporter or moderator" on public.reports;
create policy "reporter or moderator" on public.reports for select to authenticated using (reporter = auth.uid() or public._is_admin(auth.uid()));
grant select on public.reports to authenticated;
grant all on public.reports to service_role;

create or replace function public.report_content(p_kind text, p_id text, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); who uuid; what text; rid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if p_kind = 'prediction' then select a_uid, title into who, what from predictions where id::text = p_id;
  elsif p_kind = 'contest' then select sponsor, title into who, what from contests where id::text = p_id;
  elsif p_kind = 'rsvp' then select organizer, title || coalesce(' · ' || nullif(notes, ''), '') into who, what from rsvp_events where id::text = p_id;
  elsif p_kind = 'squares' then select originator, title into who, what from squares_pools where id::text = p_id;
  elsif p_kind = 'pickem' then select created_by, name into who, what from pickem_groups where id::text = p_id;
  elsif p_kind = 'wolf' then select created_by, coalesce(nullif(course, ''), 'Wolf round') into who, what from wolf_rounds where id::text = p_id;
  elsif p_kind = 'profile' then select id, name into who, what from profiles where id::text = p_id;
  else raise exception 'Can''t report that.'; end if;
  if what is null then raise exception 'That''s already gone.'; end if;
  if exists (select 1 from reports where reporter = me and kind = p_kind and item_id = p_id and status = 'open') then
    raise exception 'You already reported this. A moderator will look at it.'; end if;
  insert into reports (reporter, kind, item_id, item_uid, excerpt, reason)
  values (me, p_kind, p_id, who, left(what, 300), left(btrim(coalesce(p_reason, '')), 300)) returning id into rid;
  return rid;
end $$;

-- A moderator handles a report: remove (replace the text), dismiss, or suspend the poster (also removes).
create or replace function public.resolve_report(p_report uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare r reports; gone text := 'Removed by Handshake'; old text; owner uuid;
begin
  if not _is_admin(auth.uid()) then raise exception 'Only moderators can do that.'; end if;
  select * into r from reports where id = p_report;
  if not found then raise exception 'That report is gone.'; end if;
  if p_action not in ('remove', 'dismiss', 'suspend') then raise exception 'Pick remove, dismiss or suspend.'; end if;
  if p_action in ('remove', 'suspend') then
    if r.kind = 'prediction' then
      select title, a_uid into old, owner from predictions where id::text = r.item_id;
      update predictions set title = gone, terms = '' where id::text = r.item_id or (title = old and a_uid = owner);
    elsif r.kind = 'contest' then
      update contests set title = gone, stage = case when stage = 'open' then 'canceled' else stage end, stage_at = case when stage = 'open' then now() else stage_at end where id::text = r.item_id;
    elsif r.kind = 'rsvp' then
      update rsvp_events set title = gone, notes = '', status = case when status = 'open' then 'canceled' else status end where id::text = r.item_id;
    elsif r.kind = 'squares' then
      update squares_pools set title = gone, status = case when status = 'open' then 'canceled' else status end where id::text = r.item_id;
    elsif r.kind = 'pickem' then update pickem_groups set name = gone where id::text = r.item_id;
    elsif r.kind = 'wolf' then update wolf_rounds set course = '' where id::text = r.item_id;
    elsif r.kind = 'profile' then update profiles set name = 'Player ' || upper(left(id::text, 4)) where id::text = r.item_id;
    end if;
  end if;
  if p_action = 'suspend' and r.item_uid is not null then update profiles set suspended = true where id = r.item_uid; end if;
  -- close every open report on the same item
  update reports set status = case when p_action = 'dismiss' then 'dismissed' else 'removed' end, handled_by = auth.uid(), handled_at = now(),
    note = case when p_action = 'suspend' then 'poster suspended' else null end
  where kind = r.kind and item_id = r.item_id and status = 'open';
end $$;
create or replace function public.admin_suspend(p_uid uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(auth.uid()) then raise exception 'Only moderators can do that.'; end if;
  update profiles set suspended = p_on where id = p_uid;
end $$;

/* ---------- the checks on every typed field ---------- */
-- One trigger for every table with typed text. Arguments are the column names; a name starting
-- with "!" gets the word list only (no AI check needed).
create or replace function public._keep_it_fun() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid(); nj jsonb := to_jsonb(new); oj jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  col text; words_only boolean; v jsonb; e jsonb; s text; bad text; need boolean;
  strict_on boolean := (select require_screen from moderation_settings where id = 1);
  vals text[];
begin
  if me is not null and exists (select 1 from profiles where id = me and suspended) then
    raise exception 'Your Handshake account is suspended. Contact the organizer if you think that''s a mistake.';
  end if;
  -- rows Handshake makes itself (Pick 'em, contests, golf) are built from text that was already checked
  need := me is not null and coalesce(strict_on, false)
          and not (tg_table_name = 'predictions' and (nj->>'pickem_group' is not null or nj->>'contest_id' is not null or nj->>'wolf_round' is not null));
  foreach col in array tg_argv loop
    words_only := left(col, 1) = '!';
    col := ltrim(col, '!');
    v := nj -> col;
    continue when v is null or jsonb_typeof(v) = 'null';
    continue when oj is not null and (oj -> col) is not distinct from v;
    vals := '{}';
    if col = 'log' then
      -- only the entries added now
      for e in select x from jsonb_array_elements(v) with ordinality t(x, n)
               where n > coalesce(jsonb_array_length(case when jsonb_typeof(oj -> 'log') = 'array' then oj -> 'log' end), 0) loop
        vals := vals || coalesce(e ->> 'what', '');
      end loop;
    elsif jsonb_typeof(v) = 'array' then
      for e in select * from jsonb_array_elements(v) loop
        vals := vals || case when jsonb_typeof(e) = 'object' then coalesce(e ->> 'name', '') when jsonb_typeof(e) = 'string' then e #>> '{}' else '' end;
      end loop;
    else
      vals := array[v #>> '{}'];
    end if;
    foreach s in array vals loop
      continue when _mod_norm(s) = '';
      bad := _mod_bad(s);
      if bad is not null then
        raise exception 'Keep it fun: "%" isn''t allowed on Handshake (no profanity, sexual, violent, hateful or political content).', s;
      end if;
      if need and not words_only and not exists (select 1 from screened_text where t = _mod_norm(s)) then
        raise exception 'Keep it fun: Handshake couldn''t check "%". Update Handshake (or reload the page) and try again.', s;
      end if;
    end loop;
  end loop;
  return new;
end $$;

do $$
declare spec text[]; t text; cols text[];
begin
  foreach spec slice 1 in array array[
    array['profiles', 'name'], array['predictions', 'title,terms,stake_text,b_name,!log'], array['pickem_groups', 'name'],
    array['wolf_rounds', 'course,players'], array['rsvp_events', 'title,notes,venue,locked_venue'], array['rsvp_venues', 'name'],
    array['rsvp_phone_invites', 'name'], array['rsvp_lastcall_phones', 'name'], array['contests', 'title,choices,result,objection'],
    array['contest_entries', 'choice'], array['squares_pools', 'title']
  ] loop
    t := spec[1]; cols := string_to_array(spec[2], ',');
    execute format('drop trigger if exists keep_it_fun on public.%I', t);
    execute format('create trigger keep_it_fun before insert or update on public.%I for each row execute function public._keep_it_fun(%s)',
                   t, (select string_agg(quote_literal(c), ', ') from unnest(cols) c));
  end loop;
end $$;

-- Everything already in Handshake counts as checked (nothing old gets blocked by the AI rule).
do $$
begin
  perform screen_store(array(
    select name from profiles union select title from predictions union select terms from predictions union select stake_text from predictions
    union select b_name from predictions union select name from pickem_groups union select course from wolf_rounds
    union select p ->> 'name' from wolf_rounds, jsonb_array_elements(players) p union select title from rsvp_events union select notes from rsvp_events
    union select venue from rsvp_events union select locked_venue from rsvp_events union select name from rsvp_venues union select name from rsvp_phone_invites
    union select name from rsvp_lastcall_phones union select title from contests union select unnest(choices) from contests union select result from contests
    union select objection from contests union select choice from contest_entries union select title from squares_pools
    union select 'Removed by Handshake'), 'existing');
end $$;

/* ---------- blocks: no predictions between blocked people; invites skipped ---------- */
create or replace function public._no_blocked_prediction() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if _blocked_pair(new.a_uid, coalesce(new.b_uid, new.b_invited)) then
    raise exception 'You can''t make a prediction with that person.'; end if;
  return new;
end $$;
drop trigger if exists no_blocked on public.predictions;
create trigger no_blocked before insert on public.predictions for each row execute function public._no_blocked_prediction();

create or replace function public._skip_blocked_invite() returns trigger language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  if tg_table_name = 'squares_invitees' then select originator into host from squares_pools where id = new.pool_id;
  elsif tg_table_name = 'contest_invitees' then select sponsor into host from contests where id = new.contest_id;
  elsif tg_table_name = 'rsvp_invitees' then select organizer into host from rsvp_events where id = new.event_id;
  elsif tg_table_name = 'pickem_invites' then host := new.invited_by;
  end if;
  if _blocked_pair(host, new.uid) then return null; end if;  -- quietly skip
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['squares_invitees', 'contest_invitees', 'rsvp_invitees', 'pickem_invites'] loop
    execute format('drop trigger if exists skip_blocked on public.%I', t);
    execute format('create trigger skip_blocked before insert on public.%I for each row execute function public._skip_blocked_invite()', t);
  end loop;
end $$;

revoke all on function public._mod_bad(text), public._is_admin(uuid), public._blocked_pair(uuid, uuid), public._keep_it_fun(),
  public._no_blocked_prediction(), public._skip_blocked_invite(), public.mod_word_check(text[]) from public, anon, authenticated;
grant execute on function public._is_admin(uuid) to authenticated;  -- used by the reports policy
revoke all on function public.block_user(uuid, boolean), public.report_content(text, text, text), public.resolve_report(uuid, text),
  public.admin_suspend(uuid, boolean) from public, anon;
grant execute on function public.block_user(uuid, boolean), public.report_content(text, text, text), public.resolve_report(uuid, text),
  public.admin_suspend(uuid, boolean) to authenticated;


-- ============ Full names (update-names.sql) ============
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


-- ============ Unique short names (update-names-2.sql) ============
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

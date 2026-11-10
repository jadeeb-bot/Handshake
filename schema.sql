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

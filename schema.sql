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

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

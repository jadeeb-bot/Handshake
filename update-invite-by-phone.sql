-- Handshake update: only the invited person can shake on a prediction.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

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

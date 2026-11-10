-- Handshake update: a "shake by" deadline on every invite.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

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

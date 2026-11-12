-- Handshake update: who can see each prediction.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
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

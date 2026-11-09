-- Handshake update: counter stakes.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

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

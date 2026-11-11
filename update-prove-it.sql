-- Handshake update: "Prove It!" replaces "Dispute" on results.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
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

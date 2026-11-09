-- Handshake update: fix a typo in who a prediction is for.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

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

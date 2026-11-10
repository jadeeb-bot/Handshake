-- Handshake update: 24 hours to dispute a result.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.

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

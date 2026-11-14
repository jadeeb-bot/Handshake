-- Handshake update: a loss recorded by the loser counts right away.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
-- Decided Nov 14: when a player records that the OTHER side won, they're conceding, so there's
-- nothing to confirm: it's done and done immediately (crashes on it settle too). Recording a win
-- for yourself, a tie, or call it off still gives the other side 24 hours to confirm or say
-- prove it, as before.

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

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

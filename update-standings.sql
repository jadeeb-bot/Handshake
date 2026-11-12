-- Handshake update: one set of standings for everyone, and the "Predictions and Counting!" total.
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Safe to run more than once. Fresh installs get the same thing from schema.sql.
--
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

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

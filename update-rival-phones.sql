-- Handshake update: people who have a prediction together can see each other's number,
-- so "Open Messages" fills in the recipient. Nobody else's number is ever returned.
-- Safe to re-run.
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

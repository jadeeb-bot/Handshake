-- Handshake update: Wolf "Dump".
-- Paste this whole file into Supabase → SQL Editor → New query, then Run.
-- Run update-wolf-4.sql first. Safe to run more than once.
--
-- Decided Nov 14: when the Wolf picks a partner, that player can dump the Wolf and go alone.
-- The player who dumps scores exactly like a Lone Wolf: against the low ball of the other three
-- (the Wolf included), winning the hole value from each of them or paying it to each.
-- Stored as mode 'dump' with partner = the player who dumped.

alter table public.wolf_holes drop constraint if exists wolf_holes_mode_check;
alter table public.wolf_holes add constraint wolf_holes_mode_check check (mode in ('partner', 'lone', 'blind', 'dump'));

create or replace function public.wolf_compute(p_round uuid)
returns table (hole int, wolf int, mode text, partner int, complete boolean, carry_in int, presses int,
               unit int, result text, pay int[], d0 int, d1 int, d2 int, d3 int)
language plpgsql stable security definer set search_path = public as $$
declare
  h wolf_holes; carry int := 0; np int := 0; m int; u int; w int; p int;
  a int; b int; i int; j int; others int[]; team int[]; opp int[]; names text[]; won int[]; lost int[];
  pa int[]; dd int[]; bon int; txt text;
begin
  select array_agg(e->>'name' order by o) into names
    from wolf_rounds r, jsonb_array_elements(r.players) with ordinality x(e, o) where r.id = p_round;
  for h in select * from wolf_holes x where x.round_id = p_round order by x.hole loop
    if h.pressed_by is not null then np := np + 1; end if;
    w := (h.hole - 1) % 4;
    pa := array_fill(0, array[16]); txt := null; u := null;
    complete := h.mode is not null and cardinality(h.scores) = 4 and array_position(h.scores, null) is null
                and (h.mode not in ('partner', 'dump') or (h.partner is not null and h.partner <> w));
    carry_in := carry;
    if complete then
      m := case h.mode when 'blind' then 2 else 1 end;
      u := (1 + carry) * m * (2 ^ np)::int;
      if h.mode = 'partner' then
        team := array[w, h.partner];
        opp := array(select g from generate_series(0, 3) g where g <> all (team));
        a := least(h.scores[team[1] + 1], h.scores[team[2] + 1]);
        b := least(h.scores[opp[1] + 1], h.scores[opp[2] + 1]);
        if a = b then won := null; else
          if a < b then won := team; lost := opp; else won := opp; lost := team; end if;
          foreach i in array lost loop foreach j in array won loop pa[i * 4 + j + 1] := pa[i * 4 + j + 1] + u; end loop; end loop;
          txt := names[won[1] + 1] || ' & ' || names[won[2] + 1] || ' won';
        end if;
      else
        -- Lone Wolf, Blind Wolf, or a Dump (the player who dumped the Wolf plays it alone)
        p := case when h.mode = 'dump' then h.partner else w end;
        others := array(select g from generate_series(0, 3) g where g <> p);
        a := h.scores[p + 1];
        b := least(h.scores[others[1] + 1], h.scores[others[2] + 1], h.scores[others[3] + 1]);
        if a < b then
          foreach i in array others loop pa[i * 4 + p + 1] := pa[i * 4 + p + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'Lone Wolf ' || names[w + 1] || ' won'
                             when 'blind' then 'Blind Wolf ' || names[w + 1] || ' won'
                             else names[p + 1] || ' dumped ' || names[w + 1] || ' and won' end;
        elsif a > b then
          foreach j in array others loop pa[p * 4 + j + 1] := pa[p * 4 + j + 1] + u; end loop;
          txt := case h.mode when 'lone' then 'The pack beat Lone Wolf ' || names[w + 1]
                             when 'blind' then 'The pack beat Blind Wolf ' || names[w + 1]
                             else names[p + 1] || ' dumped ' || names[w + 1] || ' and lost' end;
        end if;
      end if;
      if txt is null then carry := carry + 1; txt := 'Tied: 1 point rolls over'; else carry := 0; end if;
      -- bonuses: 1 from each other player, never multiplied
      foreach bon in array h.greenie || h.birdie || h.sandy loop
        for i in 0..3 loop if i <> bon then pa[i * 4 + bon + 1] := pa[i * 4 + bon + 1] + 1; end if; end loop;
      end loop;
    end if;
    dd := array[0, 0, 0, 0];
    for i in 0..3 loop for j in 0..3 loop
      dd[j + 1] := dd[j + 1] + pa[i * 4 + j + 1]; dd[i + 1] := dd[i + 1] - pa[i * 4 + j + 1];
    end loop; end loop;
    hole := h.hole; wolf := w; mode := h.mode; partner := h.partner; presses := np; unit := u; result := txt; pay := pa;
    d0 := dd[1]; d1 := dd[2]; d2 := dd[3]; d3 := dd[4];
    return next;
  end loop;
end $$;

create or replace function public.save_wolf_hole(p_round uuid, p_hole int, p_mode text, p_partner int, p_scores int[],
  p_greenie int[], p_birdie int[], p_sandy int[], p_pressed_by int)
returns void language plpgsql security definer set search_path = public as $$
declare r wolf_rounds; old_press int; lowest int; tot int[] := array[0, 0, 0, 0]; c record; w int := (p_hole - 1) % 4;
begin
  select * into r from wolf_rounds where id = p_round;
  if not found or not wolf_is_player(p_round) then raise exception 'That round isn''t yours.'; end if;
  if r.status <> 'playing' then raise exception 'That round is finished.'; end if;
  if p_hole not between 1 and 18 then raise exception 'Holes go from 1 to 18.'; end if;
  if p_mode is not null and p_mode not in ('partner', 'lone', 'blind', 'dump') then raise exception 'Pick a partner, a Dump, Lone Wolf or Blind Wolf.'; end if;
  if p_mode = 'dump' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick who dumped the Wolf.'; end if;
  if p_mode = 'partner' and (p_partner is null or p_partner not between 0 and 3 or p_partner = w) then raise exception 'Pick the Wolf''s partner.'; end if;
  if cardinality(coalesce(p_scores, '{}')) <> 4 then raise exception 'Send four scores (blank is fine).'; end if;
  if exists (select 1 from unnest(p_scores) s where s is not null and s not between 1 and 20) then raise exception 'Scores go from 1 to 20.'; end if;
  if exists (select 1 from unnest(coalesce(p_greenie, '{}') || coalesce(p_birdie, '{}') || coalesce(p_sandy, '{}')) x where x not between 0 and 3) then
    raise exception 'Bonus for an unknown player.'; end if;
  select pressed_by into old_press from wolf_holes where round_id = p_round and hole = p_hole;
  if p_pressed_by is not null and p_pressed_by is distinct from old_press then
    if p_pressed_by not between 0 and 3 then raise exception 'Unknown player pressing.'; end if;
    for c in select * from wolf_compute(p_round) x where x.hole < p_hole loop
      tot := array[tot[1] + c.d0, tot[2] + c.d1, tot[3] + c.d2, tot[4] + c.d3];
    end loop;
    select min(t) into lowest from unnest(tot) t;
    if tot[p_pressed_by + 1] <> lowest then raise exception 'Only the player in last place can press.'; end if;
  end if;
  insert into wolf_holes (round_id, hole, mode, partner, scores, greenie, birdie, sandy, pressed_by, updated_by, updated_at)
  values (p_round, p_hole, p_mode, case when p_mode in ('partner', 'dump') then p_partner end, p_scores,
          coalesce(array(select distinct x from unnest(p_greenie) x), '{}'), coalesce(array(select distinct x from unnest(p_birdie) x), '{}'),
          coalesce(array(select distinct x from unnest(p_sandy) x), '{}'), p_pressed_by, auth.uid(), now())
  on conflict (round_id, hole) do update set mode = excluded.mode, partner = excluded.partner, scores = excluded.scores,
    greenie = excluded.greenie, birdie = excluded.birdie, sandy = excluded.sandy, pressed_by = excluded.pressed_by,
    updated_by = excluded.updated_by, updated_at = now();
end $$;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

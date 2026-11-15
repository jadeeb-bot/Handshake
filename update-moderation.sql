-- Handshake update: Keep it fun (content filter), Report, Block, and moderator tools (Nov 14).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Safe to run more than once.
--
-- Handshake is for fun: no profanity, sexual content, violence, hate, or politics.
--   1. Word list (always on, instant): every typed field is checked against blocked_words, with
--      common letter swaps (sh1t, @ss...) caught. Blocked text is refused with a "Keep it fun" message.
--   2. AI check (Claude): the app sends typed text to the "screen" Edge Function first; text that
--      passes is remembered in screened_text. Once the screen function has worked once, it switches
--      on moderation_settings.require_screen, and from then on the database refuses typed text that
--      wasn't checked. Everything that existed before this update counts as checked.
--   3. Report: anyone can report a prediction, contest, plan, pool, group, golf round or a person.
--      Moderators (app_admins) get a notification, see the Reports list in the app, and can Remove
--      the content (its text is replaced with "Removed by Handshake"), Dismiss, or Suspend the person
--      (a suspended account can't post or change anything with text).
--   4. Block: you can block a person. You won't see their predictions on Everyone or their pools,
--      contests, groups or plans; neither of you can make a prediction with the other, and invites
--      between you are skipped.

/* ---------- settings and the word list ---------- */
create table if not exists public.moderation_settings (
  id              int primary key default 1 check (id = 1),
  require_screen  boolean not null default false,
  turned_on_at    timestamptz
);
insert into public.moderation_settings (id) values (1) on conflict do nothing;
alter table public.moderation_settings enable row level security;
grant all on public.moderation_settings to service_role;

create table if not exists public.blocked_words (word text primary key);
alter table public.blocked_words enable row level security;
grant all on public.blocked_words to service_role;
insert into public.blocked_words (word) select unnest(array[
  -- profanity
  'fuck','fucker','fucking','fuk','fck','motherfucker','shit','shitty','bullshit','bitch','bitches','asshole','ass','dumbass','jackass',
  'bastard','dickhead','cock','cocksucker','pussy','cunt','twat','prick','piss','pissed','damnit','goddamn','wtf','stfu',
  -- sexual
  'sex','sexy','porn','porno','nude','nudes','naked','boobs','boob','tits','titties','penis','vagina','dildo','orgasm','horny','blowjob',
  'handjob','jizz','anal','milf','slut','whore','hooker','stripper','threesome','erection','boner','masturbate','onlyfans','nsfw',
  -- hate (slurs)
  'nigger','nigga','niggas','chink','gook','spic','wetback','kike','faggot','fag','dyke','tranny','retard','retarded','raghead','towelhead',
  'beaner','coon','honky','paki','nazi','kkk','heil',
  -- violence and threats
  'kys','rape','rapist','shoot up','school shooting','terrorist','bomb threat',
  -- politics
  'trump','biden','kamala','obama','maga','democrat','democrats','republican','republicans','gop','dnc','rnc','liberals','conservatives',
  'newsom','desantis','pelosi','aoc','election','elections','impeach','impeachment','abortion','congress','senate race','ballot',
  'antifa','socialist','communist','fascist','left wing','right wing','pro life','pro choice','gun control','immigration'
]) on conflict do nothing;

-- Same normalizing as the screen function: lowercase, single spaces, trimmed.
create or replace function public._mod_norm(t text) returns text language sql immutable as $$
  select lower(regexp_replace(regexp_replace(coalesce(t, ''), '\s+', ' ', 'g'), '^ | $', '', 'g'))
$$;

-- The blocked word found in a text (or null). Catches common letter swaps and simple endings.
create or replace function public._mod_bad(t text) returns text language sql stable security definer set search_path = public as $$
  with x as (select ' ' || regexp_replace(translate(lower(coalesce(t, '')), '0134578@$!|', 'oieastbasii'), '[^a-z]+', ' ', 'g') || ' ' as s)
  select w.word from blocked_words w, x
  where x.s ~ ('\m' || replace(w.word, ' ', ' +') || '(s|es|ed|er|ers|ing)?\M')
  limit 1
$$;

create table if not exists public.screened_text (
  t           text primary key,          -- _mod_norm(text) that passed
  source      text not null default 'ai', -- ai | existing | unchecked | system
  checked_at  timestamptz not null default now()
);
alter table public.screened_text enable row level security;
grant all on public.screened_text to service_role;

-- The screen function stores text that passed.
create or replace function public.screen_store(p_texts text[], p_source text default 'ai', p_turn_on boolean default false)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into screened_text (t, source) select distinct _mod_norm(x), p_source from unnest(coalesce(p_texts, '{}')) x where _mod_norm(x) <> ''
  on conflict (t) do nothing;
  if p_turn_on then update moderation_settings set require_screen = true, turned_on_at = coalesce(turned_on_at, now()) where id = 1 and not require_screen; end if;
end $$;
revoke all on function public.screen_store(text[], text, boolean) from public, anon, authenticated;
grant execute on function public.screen_store(text[], text, boolean) to service_role;
create or replace function public.mod_word_check(p_texts text[]) returns table (t text, word text)
language sql stable security definer set search_path = public as $$
  select x, _mod_bad(x) from unnest(coalesce(p_texts, '{}')) x where _mod_bad(x) is not null
$$;
grant execute on function public.mod_word_check(text[]) to service_role;

/* ---------- moderators, suspensions, blocks, reports ---------- */
create table if not exists public.app_admins (uid uuid primary key references public.profiles (id) on delete cascade);
alter table public.app_admins enable row level security;
drop policy if exists "see own" on public.app_admins;
create policy "see own" on public.app_admins for select to authenticated using (uid = auth.uid());
grant select on public.app_admins to authenticated;
grant all on public.app_admins to service_role;
create or replace function public._is_admin(u uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from app_admins where uid = u)
$$;

alter table public.profiles add column if not exists suspended boolean not null default false;

create table if not exists public.user_blocks (
  blocker     uuid not null references public.profiles (id) on delete cascade,
  blocked     uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (blocker, blocked)
);
alter table public.user_blocks enable row level security;
drop policy if exists "own blocks" on public.user_blocks;
create policy "own blocks" on public.user_blocks for select to authenticated using (blocker = auth.uid());
grant select on public.user_blocks to authenticated;
grant all on public.user_blocks to service_role;
create or replace function public._blocked_pair(a uuid, b uuid) returns boolean language sql stable security definer set search_path = public as $$
  select a is not null and b is not null and exists (select 1 from user_blocks where (blocker = a and blocked = b) or (blocker = b and blocked = a))
$$;
create or replace function public.block_user(p_uid uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign in first.'; end if;
  if p_uid = auth.uid() then raise exception 'You can''t block yourself.'; end if;
  if p_on then insert into user_blocks (blocker, blocked) values (auth.uid(), p_uid) on conflict do nothing;
  else delete from user_blocks where blocker = auth.uid() and blocked = p_uid; end if;
end $$;

create table if not exists public.reports (
  id           uuid primary key default gen_random_uuid(),
  reporter     uuid not null references public.profiles (id) on delete cascade,
  kind         text not null check (kind in ('prediction', 'contest', 'rsvp', 'squares', 'pickem', 'wolf', 'profile')),
  item_id      text not null,
  item_uid     uuid references public.profiles (id) on delete set null,   -- who posted it
  excerpt      text not null default '',
  reason       text not null default '',
  status       text not null default 'open' check (status in ('open', 'removed', 'dismissed')),
  created_at   timestamptz not null default now(),
  handled_by   uuid references public.profiles (id) on delete set null,
  handled_at   timestamptz,
  note         text
);
alter table public.reports enable row level security;
drop policy if exists "reporter or moderator" on public.reports;
create policy "reporter or moderator" on public.reports for select to authenticated using (reporter = auth.uid() or public._is_admin(auth.uid()));
grant select on public.reports to authenticated;
grant all on public.reports to service_role;

create or replace function public.report_content(p_kind text, p_id text, p_reason text)
returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); who uuid; what text; rid uuid;
begin
  if me is null then raise exception 'Sign in first.'; end if;
  if p_kind = 'prediction' then select a_uid, title into who, what from predictions where id::text = p_id;
  elsif p_kind = 'contest' then select sponsor, title into who, what from contests where id::text = p_id;
  elsif p_kind = 'rsvp' then select organizer, title || coalesce(' · ' || nullif(notes, ''), '') into who, what from rsvp_events where id::text = p_id;
  elsif p_kind = 'squares' then select originator, title into who, what from squares_pools where id::text = p_id;
  elsif p_kind = 'pickem' then select created_by, name into who, what from pickem_groups where id::text = p_id;
  elsif p_kind = 'wolf' then select created_by, coalesce(nullif(course, ''), 'Wolf round') into who, what from wolf_rounds where id::text = p_id;
  elsif p_kind = 'profile' then select id, name into who, what from profiles where id::text = p_id;
  else raise exception 'Can''t report that.'; end if;
  if what is null then raise exception 'That''s already gone.'; end if;
  if exists (select 1 from reports where reporter = me and kind = p_kind and item_id = p_id and status = 'open') then
    raise exception 'You already reported this. A moderator will look at it.'; end if;
  insert into reports (reporter, kind, item_id, item_uid, excerpt, reason)
  values (me, p_kind, p_id, who, left(what, 300), left(btrim(coalesce(p_reason, '')), 300)) returning id into rid;
  return rid;
end $$;

-- A moderator handles a report: remove (replace the text), dismiss, or suspend the poster (also removes).
create or replace function public.resolve_report(p_report uuid, p_action text)
returns void language plpgsql security definer set search_path = public as $$
declare r reports; gone text := 'Removed by Handshake'; old text; owner uuid;
begin
  if not _is_admin(auth.uid()) then raise exception 'Only moderators can do that.'; end if;
  select * into r from reports where id = p_report;
  if not found then raise exception 'That report is gone.'; end if;
  if p_action not in ('remove', 'dismiss', 'suspend') then raise exception 'Pick remove, dismiss or suspend.'; end if;
  if p_action in ('remove', 'suspend') then
    if r.kind = 'prediction' then
      select title, a_uid into old, owner from predictions where id::text = r.item_id;
      update predictions set title = gone, terms = '' where id::text = r.item_id or (title = old and a_uid = owner);
    elsif r.kind = 'contest' then
      update contests set title = gone, stage = case when stage = 'open' then 'canceled' else stage end, stage_at = case when stage = 'open' then now() else stage_at end where id::text = r.item_id;
    elsif r.kind = 'rsvp' then
      update rsvp_events set title = gone, notes = '', status = case when status = 'open' then 'canceled' else status end where id::text = r.item_id;
    elsif r.kind = 'squares' then
      update squares_pools set title = gone, status = case when status = 'open' then 'canceled' else status end where id::text = r.item_id;
    elsif r.kind = 'pickem' then update pickem_groups set name = gone where id::text = r.item_id;
    elsif r.kind = 'wolf' then update wolf_rounds set course = '' where id::text = r.item_id;
    elsif r.kind = 'profile' then update profiles set name = 'Player ' || upper(left(id::text, 4)) where id::text = r.item_id;
    end if;
  end if;
  if p_action = 'suspend' and r.item_uid is not null then update profiles set suspended = true where id = r.item_uid; end if;
  -- close every open report on the same item
  update reports set status = case when p_action = 'dismiss' then 'dismissed' else 'removed' end, handled_by = auth.uid(), handled_at = now(),
    note = case when p_action = 'suspend' then 'poster suspended' else null end
  where kind = r.kind and item_id = r.item_id and status = 'open';
end $$;
create or replace function public.admin_suspend(p_uid uuid, p_on boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not _is_admin(auth.uid()) then raise exception 'Only moderators can do that.'; end if;
  update profiles set suspended = p_on where id = p_uid;
end $$;

/* ---------- the checks on every typed field ---------- */
-- One trigger for every table with typed text. Arguments are the column names; a name starting
-- with "!" gets the word list only (no AI check needed).
create or replace function public._keep_it_fun() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid(); nj jsonb := to_jsonb(new); oj jsonb := case when tg_op = 'UPDATE' then to_jsonb(old) else null end;
  col text; words_only boolean; v jsonb; e jsonb; s text; bad text; need boolean;
  strict_on boolean := (select require_screen from moderation_settings where id = 1);
  vals text[];
begin
  if me is not null and exists (select 1 from profiles where id = me and suspended) then
    raise exception 'Your Handshake account is suspended. Contact the organizer if you think that''s a mistake.';
  end if;
  -- rows Handshake makes itself (Pick 'em, contests, golf) are built from text that was already checked
  need := me is not null and coalesce(strict_on, false)
          and not (tg_table_name = 'predictions' and (nj->>'pickem_group' is not null or nj->>'contest_id' is not null or nj->>'wolf_round' is not null));
  foreach col in array tg_argv loop
    words_only := left(col, 1) = '!';
    col := ltrim(col, '!');
    v := nj -> col;
    continue when v is null or jsonb_typeof(v) = 'null';
    continue when oj is not null and (oj -> col) is not distinct from v;
    vals := '{}';
    if col = 'log' then
      -- only the entries added now
      for e in select x from jsonb_array_elements(v) with ordinality t(x, n)
               where n > coalesce(jsonb_array_length(case when jsonb_typeof(oj -> 'log') = 'array' then oj -> 'log' end), 0) loop
        vals := vals || coalesce(e ->> 'what', '');
      end loop;
    elsif jsonb_typeof(v) = 'array' then
      for e in select * from jsonb_array_elements(v) loop
        vals := vals || case when jsonb_typeof(e) = 'object' then coalesce(e ->> 'name', '') when jsonb_typeof(e) = 'string' then e #>> '{}' else '' end;
      end loop;
    else
      vals := array[v #>> '{}'];
    end if;
    foreach s in array vals loop
      continue when _mod_norm(s) = '';
      bad := _mod_bad(s);
      if bad is not null then
        raise exception 'Keep it fun: "%" isn''t allowed on Handshake (no profanity, sexual, violent, hateful or political content).', s;
      end if;
      if need and not words_only and not exists (select 1 from screened_text where t = _mod_norm(s)) then
        raise exception 'Keep it fun: Handshake couldn''t check "%". Update Handshake (or reload the page) and try again.', s;
      end if;
    end loop;
  end loop;
  return new;
end $$;

do $$
declare spec text[]; t text; cols text[];
begin
  foreach spec slice 1 in array array[
    array['profiles', 'name'], array['predictions', 'title,terms,stake_text,b_name,!log'], array['pickem_groups', 'name'],
    array['wolf_rounds', 'course,players'], array['rsvp_events', 'title,notes,venue,locked_venue'], array['rsvp_venues', 'name'],
    array['rsvp_phone_invites', 'name'], array['rsvp_lastcall_phones', 'name'], array['contests', 'title,choices,result,objection'],
    array['contest_entries', 'choice'], array['squares_pools', 'title']
  ] loop
    t := spec[1]; cols := string_to_array(spec[2], ',');
    execute format('drop trigger if exists keep_it_fun on public.%I', t);
    execute format('create trigger keep_it_fun before insert or update on public.%I for each row execute function public._keep_it_fun(%s)',
                   t, (select string_agg(quote_literal(c), ', ') from unnest(cols) c));
  end loop;
end $$;

-- Everything already in Handshake counts as checked (nothing old gets blocked by the AI rule).
do $$
begin
  perform screen_store(array(
    select name from profiles union select title from predictions union select terms from predictions union select stake_text from predictions
    union select b_name from predictions union select name from pickem_groups union select course from wolf_rounds
    union select p ->> 'name' from wolf_rounds, jsonb_array_elements(players) p union select title from rsvp_events union select notes from rsvp_events
    union select venue from rsvp_events union select locked_venue from rsvp_events union select name from rsvp_venues union select name from rsvp_phone_invites
    union select name from rsvp_lastcall_phones union select title from contests union select unnest(choices) from contests union select result from contests
    union select objection from contests union select choice from contest_entries union select title from squares_pools
    union select 'Removed by Handshake'), 'existing');
end $$;

/* ---------- blocks: no predictions between blocked people; invites skipped ---------- */
create or replace function public._no_blocked_prediction() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if _blocked_pair(new.a_uid, coalesce(new.b_uid, new.b_invited)) then
    raise exception 'You can''t make a prediction with that person.'; end if;
  return new;
end $$;
drop trigger if exists no_blocked on public.predictions;
create trigger no_blocked before insert on public.predictions for each row execute function public._no_blocked_prediction();

create or replace function public._skip_blocked_invite() returns trigger language plpgsql security definer set search_path = public as $$
declare host uuid;
begin
  if tg_table_name = 'squares_invitees' then select originator into host from squares_pools where id = new.pool_id;
  elsif tg_table_name = 'contest_invitees' then select sponsor into host from contests where id = new.contest_id;
  elsif tg_table_name = 'rsvp_invitees' then select organizer into host from rsvp_events where id = new.event_id;
  elsif tg_table_name = 'pickem_invites' then host := new.invited_by;
  end if;
  if _blocked_pair(host, new.uid) then return null; end if;  -- quietly skip
  return new;
end $$;
do $$
declare t text;
begin
  foreach t in array array['squares_invitees', 'contest_invitees', 'rsvp_invitees', 'pickem_invites'] loop
    execute format('drop trigger if exists skip_blocked on public.%I', t);
    execute format('create trigger skip_blocked before insert on public.%I for each row execute function public._skip_blocked_invite()', t);
  end loop;
end $$;

revoke all on function public._mod_bad(text), public._is_admin(uuid), public._blocked_pair(uuid, uuid), public._keep_it_fun(),
  public._no_blocked_prediction(), public._skip_blocked_invite(), public.mod_word_check(text[]) from public, anon, authenticated;
grant execute on function public._is_admin(uuid) to authenticated;  -- used by the reports policy
revoke all on function public.block_user(uuid, boolean), public.report_content(text, text, text), public.resolve_report(uuid, text),
  public.admin_suspend(uuid, boolean) from public, anon;
grant execute on function public.block_user(uuid, boolean), public.report_content(text, text, text), public.resolve_report(uuid, text),
  public.admin_suspend(uuid, boolean) to authenticated;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

-- Handshake update: weekly Pick 'em All! result notifications (Nov 15).
-- Paste this whole file into Supabase → SQL Editor → New query, then Run. Safe to run more than once.
--
-- When a week is scored, everyone in the group gets a notification (sent by the 5-minute squares job):
--   * a winner: "Mike L. won the week of Nov 10 with 9 of 14 right (+15 pts). You had 7 right."
--   * nobody hit .500: "You stunk it up, but so did everyone else — rollover in the [group] Pick 'em All! competition."
-- Weeks scored before this update are marked as already sent, so nobody gets old news.

alter table public.pickem_weeks add column if not exists notified_at timestamptz;
update public.pickem_weeks set notified_at = coalesce(notified_at, graded_at) where notified_at is null;

-- Tell the API to pick up the changes right away.
notify pgrst, 'reload schema';

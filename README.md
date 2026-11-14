# Handshake

Friendly predictions with your friends. Make a call, both sides sign it, both sides confirm the result, and the points move. Friends can crash any pending prediction by backing a side.

Anyone can play from a link. Players sign up with their mobile number and a password, and stay signed in on that device. There's no email sign-up. No passwords, and no Claude or ChatGPT account.

## What's in here

| File | What it is |
| --- | --- |
| `index.html` | The page and its styles |
| `app.js` | Everything the page does |
| `config.js` | Your Supabase project address and public key (you fill this in) |
| `supabase.js` | The Supabase library, bundled so the site doesn't depend on another server |
| `schema.sql` | The database: tables, access rules, and every action (sign, counter, report, confirm, crash) |
| `update-*.sql` | Updates for a database that's already set up. Run each new one once in the SQL Editor. |

Updates so far: `update-counter-stakes.sql`, then `update-invite-by-phone.sql`, then `update-fix-invite.sql`, then `update-notifications.sql`, then `update-shake-deadline.sql`, then `update-dispute-window.sql`, then `update-app-notifications.sql`, then `update-settle-up.sql`.

All the rules live in the database, so nobody can edit a prediction except through the normal buttons.

## Setup (about 30 minutes, one time)

### 1. Create the database (Supabase)

1. Go to [supabase.com](https://supabase.com), sign in with GitHub, and create a **New project**. Any name, any region near you. Save the database password somewhere safe.
2. When the project is ready, open **SQL Editor → New query**. Paste in everything from `schema.sql` and press **Run**. It should finish with "Success. No rows returned."
3. Open **Project Settings → API** (on newer projects, **API Keys**) and copy two things:
   - the **Project URL**, which looks like `https://abcdefgh.supabase.co`
   - the **anon public** key (newer projects call it the **publishable** key)

Both are designed to be public. The database rules from step 2 decide what anyone can do.

### 2. Connect the app to the database

Open `config.js` and replace the two placeholders with the values from step 1.3. On GitHub you can do this in the browser: open the file, press the pencil icon, edit, and **Commit changes**.

### 3. Put it online (Vercel)

1. Go to [vercel.com](https://vercel.com) and sign up with your GitHub account.
2. Choose **Add New → Project**, pick the **handshake** repository, and press **Deploy**. Leave every setting as it is; there's no build step.
3. Vercel gives you an address like `handshake-jadeeb-bot.vercel.app`. That's the link you send friends.
4. Back in Supabase, open **Authentication → URL Configuration** and set **Site URL** to that address. The sign-in emails link there, so this step is required.

From now on, every change pushed to GitHub goes live on its own within a minute.

## Sign-in by text (Twilio Verify)

1. Create an account at [twilio.com](https://www.twilio.com). A trial account can only text numbers you've verified with Twilio, so add funds to your account before inviting friends.
2. In the Twilio Console, open **Verify → Services**, create a service named **Handshake**, and turn on the **SMS** channel. Copy its **Service SID** (starts with `VA`).
3. From the Twilio Console home page, copy your **Account SID** (starts with `AC`) and **Auth Token**.
4. In Supabase, open **Authentication → Sign In / Providers → Phone**, turn it on, choose **Twilio Verify** as the SMS provider, paste the three values, and save.

Until this is set up, the sign-in screen tells people to use email instead.

## Push notifications

The site can push a notification when someone shakes on, counters, declines or settles one of your predictions. Players turn it on from the bell at the top. On iPhone it only works after adding Handshake to the Home Screen (Safari: Share, then Add to Home Screen).

Sending happens in a Supabase Edge Function, `supabase/functions/notify/index.ts`:

1. In Supabase, open **Edge Functions**, create a function named exactly `notify`, paste in that file, and deploy it.
2. Under **Edge Functions → Secrets**, add `VAPID_PRIVATE_KEY` with the private key you were given. Keep it secret; anyone with it could send notifications as Handshake. The matching public key is already in `config.js`.
3. For notifications in the iPhone app, also add `APNS_KEY_ID`, `APNS_TEAM_ID` and `APNS_PRIVATE_KEY` (the full text of the Apple push key's .p8 file, including the BEGIN and END lines). The key comes from Apple Developer → Certificates, IDs & Profiles → Keys, with Apple Push Notifications service enabled.

## Vegas lines (NFL)

The **Vegas** tab lists upcoming NFL games with their opening spread and over/under. Tapping a side opens a new prediction with the line, the game date and a shake-by time of kickoff already filled in.

Lines come from [The Odds API](https://the-odds-api.com) (free plan: 500 credits a month; each daily pull costs 2). The Edge Function `supabase/functions/vegas-lines/index.ts` is called hourly by the pg_cron job `handshake-vegas-lines`; it pulls lines once a day after 6 AM Pacific and keeps the first line it saves for each game, never overwriting it.

1. Run `update-vegas-lines.sql` (already in `schema.sql` for fresh installs).
2. Under **Edge Functions → Secrets**, add `ODDS_API_KEY`.
3. Create an Edge Function named exactly `vegas-lines`, paste in that file, turn **Verify JWT** off, and deploy. Its own limits (lines once a day, scores only during games) mean extra calls can't use up the credits.

## Pick 'em All! (weekly NFL pools)

On the **Everyone** tab, anyone can start a named group and invite friends with a link or a 6-letter code. Each week (Tuesday through Monday night, Pacific) every member picks every NFL game against the Vegas opening spread, plus the total points in the Monday night game as the tiebreaker. Picks lock at each game's kickoff, and nobody sees anyone else's pick on a game until it kicks off.

When the week's games are final, `grade_pickem()` scores it (hourly pg_cron job `handshake-pickem-grade`, and after each scores pull). Most right wins; closest tiebreaker breaks a tie; still tied = co-winners. A game that lands on the number counts for nobody. Each winner gets +5 per losing entry and each loser gets −5 per winner. Points are booked as finished predictions between each winner and each loser (marked with `pickem_group`), so Standings, Rivals and settle-up include them; they stay off the Everyone feed and out of the prediction count.

Final scores come from the same `vegas-lines` function: it pulls scores only while a game is in progress (at most every 3 hours, 2 credits each).

**Can I crash?** Anyone outside a group can ask to crash it; the group's creator gets a notification and lets them in or says no.

**Bonus game:** each entry stars one game a week; getting it right counts double. It locks at that game's kickoff and stays hidden until then.

**Half right or it rolls over:** the winner needs at least half of the week's games right (games on the number don't count). Otherwise no points move and every entry's 5-point ante rolls over (`pickem_carry`). The next winner collects each rolled ante from everyone but themselves. Group standings add up `pickem_ledger`.

**Sunday lock and Submit:** games before Sunday lock at their own kickoff; every other game, the tiebreaker and the bonus game lock at the week's first Sunday kickoff (`pickem_lock_at()`). Members press **Submit my picks** once every open game and the tiebreaker are in; they can still change picks until they lock. Group cards show a ✓ under **Picks in** (`pickem_submissions`).

Run `update-pickem.sql` after `update-vegas-lines.sql`, then `update-pickem-2.sql`, then `update-pickem-3.sql`. Redeploy `notify` for the crash-request notifications.

## Golf: Wolf

The **Golf** tab tracks Wolf rounds for a foursome (Handshake people or guests). Players set the tee order; the Wolf rotates and keeps rotating on 17 and 18. Each hole: the Wolf takes a partner (each loser pays each winner 1), goes Lone Wolf (wins 1 from each or pays 1 to each) or Blind Wolf before anyone tees off (2 from/to each). Ties roll 1 point into the next hole. The player in last place can press before a hole: stakes double from there to the end (presses stack). Greenies, Birdies and Sandies are 1 from each other player and never double. Gross scores. Scoring is all in `wolf_compute()`; **Finish round** books what each pair owes as finished predictions (marked `wolf_round`).

**Invites and live scoring:** every round has a code (`W` + 6 characters) and link (`?join=CODE`, opens the app too). Opening it puts the person into a guest's spot (`wolf_round_preview()`, `join_wolf_round()`). Handshake players picked at the start get a "Wolf round started" notification (notify `{wolf_round}`). Rounds and holes are in Supabase Realtime, so every player's screen updates when anyone saves a hole.

Run `update-wolf.sql`, then `update-wolf-2.sql`, and redeploy `notify`.

## Good to know

- **Sign-in emails have a low limit at first.** Supabase's built-in email sender only allows a few emails an hour, which is fine for testing. Before you invite a whole group, add your own email sender with the **Set up SMTP** button under **Authentication → Emails**. [Resend](https://resend.com) has a free plan that works well.
- **Editing the sign-in email.** That only unlocks after you add your own email sender. You could then add a 6-digit code with `{{ .Token }}` in **Magic link or OTP**; the sign-in screen already accepts codes.
- **Everyone who signs in shares one board.** Anyone with the link can sign up and play. If you want an invite code later, that's a small addition.
- **Texts and email.** Each prediction has a "Let them know" button that opens Messages, the phone's share sheet, or email with the message already written. Automatic texts (sent without tapping anything) would need a texting service such as Twilio.
- **Scoring.** When a result is confirmed, the winner gains the points and the other side loses the same amount. "Other" stakes count toward win–loss records but not points. Crashes score themselves when the original prediction is confirmed.
- **Settling up.** On the Rivals tab, each rival shows a current balance and an all-time record. The player who's up can press Settle up to clear the balance. The player who's down can press I settled up; the other side then has 24 hours to confirm or dispute, and with no answer it counts. Settling never changes the all-time points or record.

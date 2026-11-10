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

Updates so far: `update-counter-stakes.sql`, then `update-invite-by-phone.sql`, then `update-fix-invite.sql`, then `update-notifications.sql`, then `update-shake-deadline.sql`, then `update-dispute-window.sql`.

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

## Good to know

- **Sign-in emails have a low limit at first.** Supabase's built-in email sender only allows a few emails an hour, which is fine for testing. Before you invite a whole group, add your own email sender with the **Set up SMTP** button under **Authentication → Emails**. [Resend](https://resend.com) has a free plan that works well.
- **Editing the sign-in email.** That only unlocks after you add your own email sender. You could then add a 6-digit code with `{{ .Token }}` in **Magic link or OTP**; the sign-in screen already accepts codes.
- **Everyone who signs in shares one board.** Anyone with the link can sign up and play. If you want an invite code later, that's a small addition.
- **Texts and email.** Each prediction has a "Let them know" button that opens Messages, the phone's share sheet, or email with the message already written. Automatic texts (sent without tapping anything) would need a texting service such as Twilio.
- **Scoring.** When a result is confirmed, the winner gains the points and the other side loses the same amount. "Other" stakes count toward win–loss records but not points. Crashes score themselves when the original prediction is confirmed.

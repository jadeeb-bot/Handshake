# Handshake

Friendly predictions with your friends. Make a call, both sides sign it, both sides confirm the result, and the points move. Friends can crash any pending prediction by backing a side.

Anyone can play from a link. Players sign in with their email and a 6-digit code. No passwords, and no Claude or ChatGPT account.

## What's in here

| File | What it is |
| --- | --- |
| `index.html` | The page and its styles |
| `app.js` | Everything the page does |
| `config.js` | Your Supabase project address and public key (you fill this in) |
| `supabase/schema.sql` | The database: tables, access rules, and every action (sign, report, confirm, crash) |

All the rules live in the database, so nobody can edit a prediction except through the normal buttons.

## Setup (about 30 minutes, one time)

### 1. Create the database (Supabase)

1. Go to [supabase.com](https://supabase.com), sign in with GitHub, and create a **New project**. Any name, any region near you. Save the database password somewhere safe.
2. When the project is ready, open **SQL Editor → New query**. Paste in everything from `supabase/schema.sql` and press **Run**. It should finish with "Success. No rows returned."
3. Open **Authentication → Emails → Templates**. Players type a code instead of tapping a link, so the emails need to include the code:
   - In **Magic Link**, replace the message body with:
     `<h2>Your Handshake code</h2><p>Enter this code to sign in: <b>{{ .Token }}</b></p>`
   - Do the same in **Confirm signup**, which is what brand-new players receive.
4. Open **Project Settings → API** (on newer projects, **API Keys**) and copy two things:
   - the **Project URL**, which looks like `https://abcdefgh.supabase.co`
   - the **anon public** key (newer projects call it the **publishable** key)

Both are designed to be public. The database rules from step 2 decide what anyone can do.

### 2. Connect the app to the database

Open `config.js` and replace the two placeholders with the values from step 1.4. On GitHub you can do this in the browser: open the file, press the pencil icon, edit, and **Commit changes**.

### 3. Put it online (Vercel)

1. Go to [vercel.com](https://vercel.com) and sign up with your GitHub account.
2. Choose **Add New → Project**, pick the **handshake** repository, and press **Deploy**. Leave every setting as it is; there's no build step.
3. Vercel gives you an address like `handshake-jadeeb-bot.vercel.app`. That's the link you send friends.
4. Back in Supabase, open **Authentication → URL Configuration** and set **Site URL** to that address.

From now on, every change pushed to GitHub goes live on its own within a minute.

## Good to know

- **Sign-in emails have a low limit at first.** Supabase's built-in email sender only allows a few emails an hour, which is fine for testing. Before you invite a whole group, add your own email sender under **Authentication → Emails → SMTP Settings**. [Resend](https://resend.com) has a free plan that works well.
- **Everyone who signs in shares one board.** Anyone with the link can sign up and play. If you want an invite code later, that's a small addition.
- **Texts and email.** Each prediction has a "Let them know" button that opens Messages, the phone's share sheet, or email with the message already written. Automatic texts (sent without tapping anything) would need a texting service such as Twilio.
- **Scoring.** When a result is confirmed, the winner gains the points and the other side loses the same amount. "Other" stakes count toward win–loss records but not points. Crashes score themselves when the original prediction is confirmed.

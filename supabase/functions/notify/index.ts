// Handshake push notifications.
// The site calls this right after a player acts on a prediction (shakes, counters, declines,
// records or confirms a result...). It finds who's on the other side and pushes them a
// notification on every device where they turned notifications on.
//
// Secrets (Supabase > Edge Functions > Secrets): VAPID_PRIVATE_KEY (required),
// VAPID_PUBLIC_KEY and SITE_URL (optional; defaults below). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "BGWmKz-IjaFjdRMQhrlOz1qkp2I96WGJ_2Ev2N0u5l1iAmt1qQEcMCJjXvyEmlbATFJ2myFuXuoaUSO603HcDx0";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://handshake-rho-ten.vercel.app/";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Entry = { t?: string; by?: string; uid?: string; what?: string };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });
  if (!VAPID_PRIVATE) return reply(500, { error: "VAPID_PRIVATE_KEY secret is missing." });

  // Who is asking? Use their own sign-in token.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const { data: who, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !who?.user) return reply(401, { error: "Sign in first." });
  const caller = who.user.id;

  let predictionId = "";
  try { predictionId = String((await req.json())?.prediction_id ?? ""); } catch (_) { /* empty body */ }
  if (!/^[0-9a-f-]{36}$/i.test(predictionId)) return reply(400, { error: "prediction_id is required." });

  const { data: p } = await admin.from("predictions").select("*").eq("id", predictionId).maybeSingle();
  if (!p) return reply(404, { error: "That prediction no longer exists." });

  const involved = [p.a_uid, p.b_uid, p.b_invited, p.counter_uid].includes(caller);
  if (!involved) return reply(403, { error: "You're not part of this prediction." });

  // The newest thing the caller did on this prediction is what we announce.
  const log: Entry[] = Array.isArray(p.log) ? p.log : [];
  const last = [...log].reverse().find((e) => e.uid === caller);
  if (!last) return reply(200, { sent: 0, reason: "nothing new from you on this one" });
  if (last.t && Date.now() - Date.parse(last.t) > 5 * 60_000) return reply(200, { sent: 0, reason: "that was a while ago" });

  // Tell the other side. When an original is decided, its crash players hear about it too.
  const recipients = new Set<string>();
  if (caller === p.a_uid) { if (p.b_uid ?? p.b_invited) recipients.add(p.b_uid ?? p.b_invited); }
  else recipients.add(p.a_uid);
  if (/^(confirmed|agreed to call it off|withdrew|declined)/.test(last.what ?? "")) {
    const { data: kids } = await admin.from("predictions").select("a_uid,b_uid").eq("parent_id", p.id);
    for (const k of kids ?? []) { if (k.a_uid) recipients.add(k.a_uid); if (k.b_uid) recipients.add(k.b_uid); }
  }
  recipients.delete(caller);
  if (!recipients.size) return reply(200, { sent: 0, reason: "no one on Handshake to tell yet" });

  const { data: subs } = await admin.from("push_subscriptions").select("*").in("user_id", [...recipients]);
  if (!subs?.length) return reply(200, { sent: 0, reason: "they haven't turned on notifications" });

  webpush.setVapidDetails(SITE_URL.replace(/\/$/, ""), VAPID_PUBLIC, VAPID_PRIVATE);
  const payload = JSON.stringify({
    title: p.title,
    body: `${last.by ?? "Someone"} ${last.what ?? "made a move"}`
      + (/^recorded:/.test(last.what ?? "") ? ". You have 24 hours to dispute it. After that, it counts." : ""),
    url: SITE_URL,
    tag: p.id,
  });

  let sent = 0;
  await Promise.all(subs.map(async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("endpoint", s.endpoint); // device unsubscribed
    }
  }));
  return reply(200, { sent });
});

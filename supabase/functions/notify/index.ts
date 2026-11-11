// Handshake push notifications.
// The site and app call this right after a player acts on a prediction (shakes, counters,
// declines, records or confirms a result...). It finds who's on the other side and notifies
// them on every device where they turned notifications on: browsers (web push) and the
// iPhone app (Apple Push Notification service). It also announces results that counted on
// their own after 24 hours with no dispute, once, to both sides.
//
// Secrets (Supabase > Edge Functions > Secrets):
//   VAPID_PRIVATE_KEY                       web push (required for browser notifications)
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY  iPhone app notifications (the .p8 key's
//                                           text, Key ID and your Apple Team ID)
//   VAPID_PUBLIC_KEY, SITE_URL, APNS_TOPIC  optional; defaults below
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import webpush from "npm:web-push@3.6.7";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VAPID_PUBLIC = Deno.env.get("VAPID_PUBLIC_KEY") ?? "BGWmKz-IjaFjdRMQhrlOz1qkp2I96WGJ_2Ev2N0u5l1iAmt1qQEcMCJjXvyEmlbATFJ2myFuXuoaUSO603HcDx0";
const VAPID_PRIVATE = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const SITE_URL = Deno.env.get("SITE_URL") ?? "https://handshake-rho-ten.vercel.app/";
const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID") ?? "";
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID") ?? "";
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY") ?? "";
const APNS_TOPIC = Deno.env.get("APNS_TOPIC") ?? "com.jadeeb.handshake";
const APNS_HOST = "https://api.push.apple.com"; // TestFlight and App Store builds use production

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  (status !== 200 || (body as { sent?: number })?.sent !== undefined ? console.log("notify: result", status, JSON.stringify(body)) : null,
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } }));

type Entry = { t?: string; by?: string; uid?: string; what?: string };
type Note = { title: string; body: string; tag: string };
// deno-lint-ignore no-explicit-any
type Admin = any;

/* ---------- Apple push (APNs) ---------- */
const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const textB64url = (s: string) => b64url(new TextEncoder().encode(s));
let apnsJwt: { token: string; at: number } | null = null;

/** Apple wants a short signed token (ES256) that is reused for up to an hour. */
async function apnsToken(keyId: string, teamId: string, pem: string, nowSec = Math.floor(Date.now() / 1000)) {
  if (apnsJwt && nowSec - apnsJwt.at < 50 * 60) return apnsJwt.token;
  const der = Uint8Array.from(atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "")), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = textB64url(JSON.stringify({ alg: "ES256", kid: keyId }));
  const claims = textB64url(JSON.stringify({ iss: teamId, iat: nowSec }));
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${head}.${claims}`)));
  const token = `${head}.${claims}.${b64url(sig)}`;
  apnsJwt = { token, at: nowSec };
  return token;
}

async function sendApple(admin: Admin, userIds: string[], note: Note) {
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY) {
    console.log("notify: Apple push skipped, secrets missing:", [!APNS_KEY_ID && "APNS_KEY_ID", !APNS_TEAM_ID && "APNS_TEAM_ID", !APNS_PRIVATE_KEY && "APNS_PRIVATE_KEY"].filter(Boolean).join(", "));
    return 0;
  }
  const { data: phones, error: phErr } = await admin.from("app_push_devices").select("token,user_id").in("user_id", userIds);
  if (phErr) console.error("notify: couldn't read app_push_devices", phErr.code, phErr.message);
  console.log("notify: iPhones for", userIds.join(","), "=", phones?.length ?? 0);
  if (!phones?.length) return 0;
  // App icon badge: one more for each player with an iPhone (cleared when they open the app).
  const badges = new Map<string, number>();
  const { data: bumped, error: bErr } = await admin.rpc("bump_badges", { p_ids: [...new Set(phones.map((x: { user_id: string }) => x.user_id))] });
  if (bErr) console.error("notify: badge count failed", bErr.code, bErr.message);
  for (const b of bumped ?? []) badges.set(b.id, b.badge);
  const jwt = await apnsToken(APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY);
  let sent = 0;
  await Promise.all(phones.map(async ({ token, user_id }: { token: string; user_id: string }) => {
    const badge = badges.get(user_id);
    try {
      const res = await fetch(`${APNS_HOST}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": APNS_TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-collapse-id": note.tag.slice(0, 64),
          "content-type": "application/json",
        },
        body: JSON.stringify({ aps: { alert: { title: note.title, body: note.body }, sound: "default", ...(badge ? { badge } : {}) }, prediction_id: note.tag }),
      });
      if (res.ok) { sent++; console.log("APNs ok", res.status, "apns-id", res.headers.get("apns-id"), "token", token.slice(0, 8)); return; }
      const why = await res.json().catch(() => ({}));
      console.error("APNs rejected", res.status, why?.reason, "token", token.slice(0, 8));
      if (res.status === 410 || why?.reason === "BadDeviceToken" || why?.reason === "Unregistered") {
        await admin.from("app_push_devices").delete().eq("token", token); // phone uninstalled or turned it off
      } else console.error("APNs", res.status, why?.reason);
    } catch (e) { console.error("APNs send failed", e); }
  }));
  return sent;
}

/* ---------- web push ---------- */
async function sendWeb(admin: Admin, userIds: string[], note: Note) {
  if (!VAPID_PRIVATE) { console.log("notify: web push skipped, VAPID_PRIVATE_KEY missing"); return 0; }
  const { data: subs } = await admin.from("push_subscriptions").select("*").in("user_id", userIds);
  console.log("notify: browsers for", userIds.join(","), "=", subs?.length ?? 0);
  if (!subs?.length) return 0;
  webpush.setVapidDetails(SITE_URL.replace(/\/$/, ""), VAPID_PUBLIC, VAPID_PRIVATE);
  const payload = JSON.stringify({ title: note.title, body: note.body, url: SITE_URL, tag: note.tag });
  let sent = 0;
  await Promise.all(subs.map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 86400 });
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("endpoint", s.endpoint); // browser unsubscribed
    }
  }));
  return sent;
}

const deliver = async (admin: Admin, userIds: string[], note: Note) =>
  (await sendWeb(admin, userIds, note)) + (await sendApple(admin, userIds, note));

/* ---------- settling up ---------- */
const ptsText = (n: number) => `${n} pt${n === 1 ? "" : "s"}`;
const recent = (t?: string | null) => !!t && Date.now() - Date.parse(t) < 5 * 60_000;
const isId = (v: unknown) => /^[0-9a-f-]{36}$/i.test(String(v ?? ""));

async function settleNote(admin: Admin, caller: string, body: { settlement_request_id?: string; settlement_id?: string; auto?: boolean }) {
  const nameOf = async (id: string) =>
    ((await admin.from("profiles").select("name").eq("id", id).maybeSingle()).data?.name as string) || "Your rival";
  const tag = "settle-" + (body.settlement_request_id ?? body.settlement_id);

  // The player who's up cleared the balance directly: tell the other side.
  if (body.settlement_id) {
    if (!isId(body.settlement_id)) return reply(400, { error: "settlement_id is wrong." });
    const { data: s } = await admin.from("settlements").select("*").eq("id", body.settlement_id).maybeSingle();
    if (!s || s.user_uid !== caller) return reply(403, { error: "That isn't your settle-up." });
    if (!s.other_uid || !recent(s.created_at)) return reply(200, { sent: 0 });
    const sent = await deliver(admin, [s.other_uid], {
      title: "Settled up",
      body: `${await nameOf(caller)} settled up: ${ptsText(s.points)} cleared. Your balance is back to zero. The all-time record stays.`,
      tag,
    });
    return reply(200, { sent });
  }

  if (!isId(body.settlement_request_id)) return reply(400, { error: "settlement_request_id is wrong." });
  const { data: q, error: qErr } = await admin.from("settlement_requests").select("*").eq("id", body.settlement_request_id).maybeSingle();
  if (qErr) { console.error("notify: couldn't read settle-up", body.settlement_request_id, qErr.code, qErr.message); return reply(500, { error: qErr.message, code: qErr.code }); }
  if (!q) { console.error("notify: no settle-up with id", body.settlement_request_id, "caller", caller); return reply(404, { error: "That settle-up no longer exists." }); }
  if (![q.requester_uid, q.creditor_uid].includes(caller)) return reply(403, { error: "That isn't your settle-up." });
  const down = await nameOf(q.requester_uid), up = await nameOf(q.creditor_uid);

  // Counted on its own after 24 hours: announce it once, to both sides.
  if (body.auto) {
    const { data: claimed } = await admin.from("settlement_requests").update({ auto_notified: true })
      .eq("id", q.id).eq("auto_notified", false).eq("status", "confirmed").eq("resolved_by", "auto").select("id").maybeSingle();
    if (!claimed) return reply(200, { sent: 0, reason: "already announced" });
    const sent = await deliver(admin, [q.requester_uid, q.creditor_uid], {
      title: "Settled up",
      body: `${down} and ${up} are square. ${ptsText(q.points)} cleared after 24 hours with no dispute.`,
      tag,
    });
    return reply(200, { sent });
  }

  // The player who's down says they settled: the player who's up has 24 hours.
  if (caller === q.requester_uid && q.status === "pending" && recent(q.created_at)) {
    const sent = await deliver(admin, [q.creditor_uid], {
      title: "Settle up?",
      body: `${down} says you're settled up on ${ptsText(q.points)}. You have 24 hours to confirm or dispute it. After that, it counts.`,
      tag,
    });
    return reply(200, { sent });
  }
  // The player who's up answered.
  if (caller === q.creditor_uid && q.resolved_by === "creditor" && recent(q.resolved_at)) {
    const sent = await deliver(admin, [q.requester_uid], {
      title: q.status === "disputed" ? "Settle-up disputed" : "Settled up",
      body: q.status === "disputed"
        ? `${up} disputed your settle-up. The ${ptsText(q.points)} still stands.`
        : `${up} confirmed it. ${ptsText(q.points)} cleared, and your balance is back to zero.`,
      tag,
    });
    return reply(200, { sent });
  }
  return reply(200, { sent: 0, reason: "nothing new" });
}

/* ---------- the request ---------- */
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });

  // Who is asking? Use their own sign-in token.
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const { data: who, error: authErr } = await admin.auth.getUser(token);
  if (authErr || !who?.user) { console.error("notify: sign-in check failed", authErr?.message); return reply(401, { error: "Sign in first." }); }
  const caller = who.user.id;
  console.log("notify: from", caller, "key type", SERVICE_KEY.startsWith("sb_secret_") ? "secret" : SERVICE_KEY.startsWith("eyJ") ? "legacy service_role" : "unknown");

  let body: { prediction_id?: string; auto?: boolean; settlement_request_id?: string; settlement_id?: string } = {};
  try { body = (await req.json()) ?? {}; } catch (_) { /* empty body */ }
  if (body.settlement_request_id || body.settlement_id) return await settleNote(admin, caller, body);
  const predictionId = String(body.prediction_id ?? "");
  if (!/^[0-9a-f-]{36}$/i.test(predictionId)) return reply(400, { error: "prediction_id is required." });

  // A result that counted on its own after 24 hours: announce it once, to both sides.
  if (body.auto) {
    const { data: claimed } = await admin.from("predictions").update({ auto_notified: true })
      .eq("id", predictionId).eq("auto_notified", false).in("status", ["settled", "void"]).select("*").maybeSingle();
    if (!claimed) return reply(200, { sent: 0, reason: "already announced" });
    const p = claimed;
    const last: Entry = Array.isArray(p.log) ? p.log[p.log.length - 1] ?? {} : {};
    if (last.by !== "Handshake" || !/after 24 hours/.test(last.what ?? "")) return reply(200, { sent: 0, reason: "not an automatic result" });
    const pts = p.stake_kind === "points" ? `${p.points} pt${p.points === 1 ? "" : "s"}` : p.stake_text || "the stakes";
    const outcome = p.status === "void" ? "Called off after 24 hours with no dispute."
      : p.winner === "push" ? "Counted as a tie after 24 hours with no dispute."
      : `Counted after 24 hours with no dispute. ${p.winner === "a" ? p.a_name : p.b_name} takes ${pts}.`;
    const people = new Set<string>([p.a_uid, p.b_uid].filter(Boolean));
    const { data: kids } = await admin.from("predictions").select("a_uid,b_uid").eq("parent_id", p.id);
    for (const k of kids ?? []) { if (k.a_uid) people.add(k.a_uid); if (k.b_uid) people.add(k.b_uid); }
    const sent = await deliver(admin, [...people], { title: p.title, body: outcome, tag: p.id });
    return reply(200, { sent });
  }

  const { data: p, error: pErr } = await admin.from("predictions").select("*").eq("id", predictionId).maybeSingle();
  if (pErr) { console.error("notify: couldn't read prediction", predictionId, pErr.code, pErr.message); return reply(500, { error: pErr.message, code: pErr.code }); }
  if (!p) { console.error("notify: no prediction with id", predictionId, "caller", caller); return reply(404, { error: "That prediction no longer exists." }); }

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

  const sent = await deliver(admin, [...recipients], {
    title: p.title,
    body: `${last.by ?? "Someone"} ${last.what ?? "made a move"}`
      + (/^recorded:/.test(last.what ?? "") ? ". You have 24 hours to dispute it. After that, it counts." : ""),
    tag: p.id,
  });
  return reply(200, { sent });
});

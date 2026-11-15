// Handshake push notifications.
// The site and app call this right after a player acts on a prediction (shakes, counters,
// declines, records or confirms a result...). It finds who's on the other side and notifies
// them on every device where they turned notifications on: browsers (web push) and the
// iPhone app (Apple Push Notification service). It also announces results that counted on
// their own when a 24-hour clock ran out (no dispute, no proof, proof unanswered, no
// referee pick), once, to both sides. Prove It! steps also reach the referee.
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
  const venmo = (h?: string | null) => (h ? ` Venmo: @${h} (venmo.com/u/${h})` : "");

  // The player who's up cleared the balance directly: tell the other side.
  if (body.settlement_id) {
    if (!isId(body.settlement_id)) return reply(400, { error: "settlement_id is wrong." });
    const { data: s } = await admin.from("settlements").select("*").eq("id", body.settlement_id).maybeSingle();
    if (!s || s.user_uid !== caller) return reply(403, { error: "That isn't your settle-up." });
    if (!s.other_uid || !recent(s.created_at)) return reply(200, { sent: 0 });
    const sent = await deliver(admin, [s.other_uid], {
      title: "Settled up",
      body: `${await nameOf(caller)} settled up: ${ptsText(s.points)} cleared. Your balance is back to zero. The all-time record stays.${venmo(s.venmo)}`,
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
      body: `${down} says you're settled up on ${ptsText(q.points)}. You have 24 hours to confirm or dispute it. After that, it counts.${venmo(q.venmo)}`,
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

/* ---------- Pick 'em All! crash requests ---------- */
/* ---------- Pick 'em invites by account ---------- */
async function pkInviteNote(admin: Admin, caller: string, body: { pickem_group?: string }) {
  if (!isId(body.pickem_group)) return reply(400, { error: "pickem_group is wrong." });
  const { data: g } = await admin.from("pickem_groups").select("name").eq("id", body.pickem_group).maybeSingle();
  if (!g) return reply(404, { error: "That group is gone." });
  const since = new Date(Date.now() - 5 * 60_000).toISOString();
  const { data: inv } = await admin.from("pickem_invites").select("uid").eq("group_id", body.pickem_group)
    .eq("invited_by", caller).eq("status", "pending").gte("created_at", since);
  const to = (inv || []).map((x: { uid: string }) => x.uid);
  if (!to.length) return reply(200, { sent: 0, reason: "nothing new" });
  const who = ((await admin.from("profiles").select("name").eq("id", caller).maybeSingle()).data?.name as string) || "Someone";
  const sent = await deliver(admin, to, { title: "Pick 'em All! invite",
    body: `${who} invited you to the Pick 'em All! group ${g.name}. Open the Everyone tab and tap Join.`, tag: "pkinvite-" + body.pickem_group });
  return reply(200, { sent });
}

async function crashNote(admin: Admin, caller: string, body: { pickem_group?: string; uid?: string }) {
  if (!isId(body.pickem_group)) return reply(400, { error: "pickem_group is wrong." });
  const uid = isId(body.uid) ? String(body.uid) : caller;
  const { data: q } = await admin.from("pickem_crash_requests").select("*").eq("group_id", body.pickem_group).eq("uid", uid).maybeSingle();
  const { data: g } = await admin.from("pickem_groups").select("name, created_by").eq("id", body.pickem_group).maybeSingle();
  if (!q || !g) return reply(404, { error: "That request no longer exists." });
  const nameOf = async (id: string) =>
    ((await admin.from("profiles").select("name").eq("id", id).maybeSingle()).data?.name as string) || "Someone";
  const tag = "crash-" + body.pickem_group + "-" + uid;
  // Someone asked to crash: tell the group's creator.
  if (caller === uid && q.status === "pending" && recent(q.created_at)) {
    const sent = await deliver(admin, [g.created_by], {
      title: "Can I crash?",
      body: `${await nameOf(uid)} wants to crash your Pick 'em All! group ${g.name}. Open the Everyone tab to let them in or say no.`,
      tag,
    });
    return reply(200, { sent });
  }
  // The creator answered: tell the person who asked.
  if (caller === g.created_by && q.status !== "pending" && recent(q.answered_at)) {
    const sent = await deliver(admin, [uid], {
      title: q.status === "accepted" ? "You're in" : "Not this time",
      body: q.status === "accepted"
        ? `${await nameOf(caller)} let you crash ${g.name}. Make your picks for the week on the Everyone tab.`
        : `${await nameOf(caller)} said no to crashing ${g.name}.`,
      tag,
    });
    return reply(200, { sent });
  }
  return reply(200, { sent: 0, reason: "nothing new" });
}

/* ---------- Wolf: tell the other players a round started ---------- */
async function wolfNote(admin: Admin, caller: string, body: { wolf_round?: string; wolf_delete?: string }) {
  if (!isId(body.wolf_round)) return reply(400, { error: "wolf_round is wrong." });
  const { data: r } = await admin.from("wolf_rounds").select("course, players, created_by, created_at, delete_requested_by, delete_requested_at, delete_saved_by, delete_saved_at").eq("id", body.wolf_round).maybeSingle();
  if (!r) return reply(404, { error: "That round no longer exists." });
  const all = (r.players || []) as { uid: string | null; name: string }[];
  const nameOf = (u: string | null) => all.find((p) => p.uid === u)?.name || "Someone";
  const where = r.course ? " at " + r.course : "";
  // Someone asked to delete a finished match: tell the other players.
  if (body.wolf_delete === "requested") {
    if (r.delete_requested_by !== caller || !recent(r.delete_requested_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const to = all.map((p) => p.uid).filter((u): u is string => !!u && u !== caller);
    const sent = await deliver(admin, to, {
      title: "Delete this Wolf round?",
      body: `${nameOf(caller)} asked to delete the Wolf round${where}. It'll be deleted in 24 hours unless someone opens it and taps Save this round.`,
      tag: "wolf-delete-" + body.wolf_round,
    });
    return reply(200, { sent });
  }
  // Someone saved it: tell whoever asked to delete it.
  if (body.wolf_delete === "saved") {
    if (r.delete_saved_by !== caller || !recent(r.delete_saved_at) || !isId((body as { asker?: string }).asker)) return reply(200, { sent: 0, reason: "nothing new" });
    const asker = String((body as { asker?: string }).asker);
    if (asker === caller || !all.some((p) => p.uid === asker)) return reply(200, { sent: 0, reason: "nothing new" });
    const sent = await deliver(admin, [asker], {
      title: "Wolf round saved",
      body: `${nameOf(caller)} saved the Wolf round${where}, so it won't be deleted.`,
      tag: "wolf-delete-" + body.wolf_round,
    });
    return reply(200, { sent });
  }
  if (r.created_by !== caller || !recent(r.created_at)) return reply(200, { sent: 0, reason: "nothing new" });
  const players = (r.players || []) as { uid: string | null; name: string }[];
  const starter = players.find((p) => p.uid === caller)?.name || "Someone";
  const to = players.map((p) => p.uid).filter((u): u is string => !!u && u !== caller);
  const sent = await deliver(admin, to, {
    title: "Wolf round started",
    body: `${starter} started a Wolf round${r.course ? " at " + r.course : ""} with you. Open the Golf tab to enter and follow scores live.`,
    tag: "wolf-" + body.wolf_round,
  });
  return reply(200, { sent });
}

/* ---------- RSVP ---------- */
const MON = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const DOW = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
function optLabel(o: { day: string; end_day?: string | null; at_time?: string | null }) {
  const d = (x: string) => { const t = new Date(x + "T12:00:00Z"); return `${DOW[t.getUTCDay()]} ${MON[t.getUTCMonth()]} ${t.getUTCDate()}`; };
  let s = d(o.day) + (o.end_day && o.end_day !== o.day ? "–" + d(o.end_day) : "");
  if (o.at_time) { const [h, m] = o.at_time.split(":").map(Number); s += ` ${(h % 12) || 12}:${String(m).padStart(2, "0")} ${h < 12 ? "AM" : "PM"}`; }
  return s;
}
async function rsvpNote(admin: Admin, caller: string, body: { rsvp_event?: string; kind?: string }) {
  if (!isId(body.rsvp_event)) return reply(400, { error: "rsvp_event is wrong." });
  const id = body.rsvp_event;
  const { data: e } = await admin.from("rsvp_events").select("*").eq("id", id).maybeSingle();
  if (!e) return reply(404, { error: "That event no longer exists." });
  const inv = ((await admin.from("rsvp_invitees").select("uid").eq("event_id", id)).data || []).map((x: { uid: string }) => x.uid);
  const members = [e.organizer, ...inv] as string[];
  if (!members.includes(caller) && body.kind !== "lastcall") return reply(403, { error: "Not part of this event." });
  const nameOf = async (u: string) => ((await admin.from("profiles").select("name").eq("id", u).maybeSingle()).data?.name as string) || "Someone";
  const tag = "rsvp-" + id;
  if (body.kind === "invite") {
    if (caller !== e.organizer || !recent(e.created_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const sent = await deliver(admin, inv, { title: "RSVP: " + e.title,
      body: `${await nameOf(caller)} is planning ${e.title}${e.venue ? " at " + e.venue : ""}. Mark which dates work for you${e.venue ? "" : " and suggest a place"}.`, tag });
    return reply(200, { sent });
  }
  if (body.kind === "answer" && e.status === "open") {
    const { data: tally } = await admin.rpc("rsvp_tally", { p_event: id });
    const works = (tally || []).filter((t: { works: boolean }) => t.works);
    if (e.open_count != null && works.length >= e.open_count) return reply(200, { sent: 0, reason: "not narrower" });
    await admin.from("rsvp_events").update({ open_count: works.length }).eq("id", id);
    const { data: vs } = await admin.from("rsvp_venue_votes").select("venue_id").eq("event_id", id);
    let top = "";
    if (vs?.length) {
      const c = new Map<string, number>(); for (const v of vs) c.set(v.venue_id, (c.get(v.venue_id) || 0) + 1);
      const best = [...c.entries()].sort((a, b) => b[1] - a[1])[0][0];
      top = ((await admin.from("rsvp_venues").select("name").eq("id", best).maybeSingle()).data?.name as string) || "";
    }
    const list = works.slice(0, 3).map(optLabel).join(", ");
    const msg = works.length
      ? `${works.length} option${works.length === 1 ? "" : "s"} still work${works.length === 1 ? "s" : ""}: ${list}${works.length > 3 ? "…" : ""}.${top ? " Top venue: " + top + "." : ""}`
      : "No date works for everyone anymore. Open it to suggest another one.";
    const sent = await deliver(admin, members.filter((u) => u !== caller), { title: e.title + ": narrowing down", body: msg, tag });
    return reply(200, { sent });
  }
  if (body.kind === "venue") {
    if (caller === e.organizer) return reply(200, { sent: 0 });
    const sent = await deliver(admin, [e.organizer], { title: e.title + ": new place", body: `${await nameOf(caller)} suggested a place. Open it to see the ideas and votes.`, tag });
    return reply(200, { sent });
  }
  if (body.kind === "lock") {
    if (caller !== e.organizer || e.status !== "locked" || !recent(e.locked_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const { data: o } = await admin.from("rsvp_options").select("day, end_day, at_time").eq("id", e.locked_option).maybeSingle();
    const to = ((await admin.from("rsvp_lastcall").select("uid").eq("event_id", id)).data || []).map((x: { uid: string }) => x.uid);
    const sent = await deliver(admin, to, { title: "Last call: " + e.title,
      body: `Locked: ${o ? optLabel(o) : ""} at ${e.locked_venue}. Are you in? Open it to confirm.`, tag });
    return reply(200, { sent });
  }
  if (body.kind === "lastcall") {
    const { data: lc } = await admin.from("rsvp_lastcall").select("status, answered_at").eq("event_id", id).eq("uid", caller).maybeSingle();
    if (!lc || lc.status === "pending" || !recent(lc.answered_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const sent = await deliver(admin, [e.organizer], { title: e.title,
      body: `${await nameOf(caller)} ${lc.status === "in" ? "is in" : "can't make it"}.`, tag });
    return reply(200, { sent });
  }
  return reply(200, { sent: 0, reason: "nothing new" });
}

/* ---------- Contests ---------- */
async function contestNote(admin: Admin, caller: string, body: { contest_id?: string; kind?: string }) {
  if (!isId(body.contest_id)) return reply(400, { error: "contest_id is wrong." });
  const id = body.contest_id;
  const { data: c } = await admin.from("contests").select("*").eq("id", id).maybeSingle();
  if (!c) return reply(404, { error: "That contest no longer exists." });
  const nameOf = async (u: string) => ((await admin.from("profiles").select("name").eq("id", u).maybeSingle()).data?.name as string) || "Someone";
  const entrants = [...new Set(((await admin.from("contest_entries").select("uid").eq("contest_id", id)).data || []).map((x: { uid: string }) => x.uid))] as string[];
  const tag = "contest-" + id;
  if (body.kind === "new") {
    if (caller !== c.sponsor || !recent(c.created_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const inv = ((await admin.from("contest_invitees").select("uid").eq("contest_id", id)).data || []).map((x: { uid: string }) => x.uid);
    const sent = await deliver(admin, inv, { title: "Contest: " + c.title,
      body: `${await nameOf(caller)} started a contest: ${c.points} pts an entry, up to ${c.max_entries}. Open the Contests tab to enter.`, tag });
    return reply(200, { sent });
  }
  if (!recent(c.stage_at)) return reply(200, { sent: 0, reason: "nothing new" });
  let to: string[] = [], title = c.title, msg = "";
  if (c.stage === "recorded" && caller === c.sponsor) {
    to = entrants.filter((u) => u !== c.sponsor);
    msg = `Result: ${c.result}. You have 24 hours to say Prove it! After that, it counts.`;
  } else if (c.stage === "proving" && caller === c.objector) {
    to = [c.sponsor]; msg = `${await nameOf(caller)} says prove it. Post a link within 24 hours or it's called off.`;
  } else if (c.stage === "proof" && caller === c.sponsor) {
    to = [c.objector]; msg = "Proof posted. You have 24 hours to accept it or say why it doesn't hold up. After that, it counts.";
  } else if (c.stage === "refereeing" && caller === c.objector) {
    to = [c.referee]; title = "You're the referee"; msg = `For the contest "${c.title}": decide within 24 hours whether the result stands.`;
  } else if ((c.stage === "settled" || c.stage === "void") && [c.sponsor, c.objector, c.referee].includes(caller)) {
    to = [...new Set([c.sponsor, ...entrants])].filter((u) => u !== caller);
    msg = c.stage === "settled" ? `Done and done: ${c.result}. Points are in.` : (c.outcome_note || "Called off. Everyone's refunded.");
  } else return reply(200, { sent: 0, reason: "nothing new" });
  const sent = await deliver(admin, to.filter(Boolean), { title, body: msg, tag });
  return reply(200, { sent });
}

/* ---------- Squares (quarter results come from the squares function) ---------- */
async function squaresNote(admin: Admin, caller: string, body: { squares_pool?: string; kind?: string; uid?: string }) {
  if (!isId(body.squares_pool)) return reply(400, { error: "squares_pool is wrong." });
  const id = body.squares_pool;
  const { data: p } = await admin.from("squares_pools").select("*").eq("id", id).maybeSingle();
  if (!p) return reply(404, { error: "That pool no longer exists." });
  const nameOf = async (u: string) => ((await admin.from("profiles").select("name").eq("id", u).maybeSingle()).data?.name as string) || "Someone";
  const tag = "squares-" + id;
  if (body.kind === "new") {
    if (caller !== p.originator || !recent(p.created_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const inv = ((await admin.from("squares_invitees").select("uid").eq("pool_id", id)).data || []).map((x: { uid: string }) => x.uid);
    const sent = await deliver(admin, inv, { title: "Squares: " + p.title,
      body: `${await nameOf(caller)} started a squares pool: ${p.price} pts a square. Open the Squares tab to pick yours.`, tag });
    return reply(200, { sent });
  }
  if (body.kind === "crash") {
    const { data: r } = await admin.from("squares_crash").select("*").eq("pool_id", id).eq("uid", caller).maybeSingle();
    if (!r || r.status !== "pending" || !recent(r.created_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const sent = await deliver(admin, [p.originator], { title: "Squares: " + p.title, body: `${await nameOf(caller)} asks: can I crash? Open Squares to let them in.`, tag });
    return reply(200, { sent });
  }
  if (body.kind === "answer" && caller === p.originator && isId(body.uid)) {
    const { data: r } = await admin.from("squares_crash").select("*").eq("pool_id", id).eq("uid", body.uid).maybeSingle();
    if (!r || r.status === "pending" || !recent(r.answered_at)) return reply(200, { sent: 0, reason: "nothing new" });
    const sent = await deliver(admin, [body.uid!], { title: "Squares: " + p.title,
      body: r.status === "accepted" ? "You're in. Open Squares to pick your squares." : "Not this time.", tag });
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

  let body: { prediction_id?: string; auto?: boolean; settlement_request_id?: string; settlement_id?: string; pickem_group?: string; uid?: string; wolf_round?: string; wolf_delete?: string; asker?: string; rsvp_event?: string; contest_id?: string; kind?: string; squares_pool?: string } = {};
  try { body = (await req.json()) ?? {}; } catch (_) { /* empty body */ }
  if (body.settlement_request_id || body.settlement_id) return await settleNote(admin, caller, body);
  if (body.pickem_group && body.kind === "invite") return await pkInviteNote(admin, caller, body);
  if (body.pickem_group) return await crashNote(admin, caller, body);
  if (body.wolf_round) return await wolfNote(admin, caller, body);
  if (body.rsvp_event) return await rsvpNote(admin, caller, body);
  if (body.contest_id) return await contestNote(admin, caller, body);
  if (body.squares_pool) return await squaresNote(admin, caller, body);
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
    const winnerName = p.winner === "a" ? p.a_name : p.b_name;
    const takes = p.winner === "push" ? "It's a tie, no points move." : `${winnerName} takes ${pts}.`;
    const what = last.what ?? "";
    const outcome = p.status === "hopeless" ? `Hopeless. ${p.referee_name ?? "The referee"} didn't pick a winner in 24 hours, so no points move.`
      : /^no proof/.test(what) ? `No proof came in 24 hours. ${takes}`
      : /^proof stood/.test(what) ? `The proof stood for 24 hours with no answer. ${takes}`
      : p.status === "void" ? "Called off after 24 hours with no dispute."
      : p.winner === "push" ? "Counted as a tie after 24 hours with no dispute."
      : `Counted after 24 hours with no dispute. ${winnerName} takes ${pts}.`;
    const people = new Set<string>([p.a_uid, p.b_uid, p.referee_uid].filter(Boolean));
    const { data: kids } = await admin.from("predictions").select("a_uid,b_uid").eq("parent_id", p.id);
    for (const k of kids ?? []) { if (k.a_uid) people.add(k.a_uid); if (k.b_uid) people.add(k.b_uid); }
    const sent = await deliver(admin, [...people], { title: p.title, body: outcome, tag: p.id });
    return reply(200, { sent });
  }

  const { data: p, error: pErr } = await admin.from("predictions").select("*").eq("id", predictionId).maybeSingle();
  if (pErr) { console.error("notify: couldn't read prediction", predictionId, pErr.code, pErr.message); return reply(500, { error: pErr.message, code: pErr.code }); }
  if (!p) { console.error("notify: no prediction with id", predictionId, "caller", caller); return reply(404, { error: "That prediction no longer exists." }); }

  const involved = [p.a_uid, p.b_uid, p.b_invited, p.counter_uid, p.referee_uid].includes(caller);
  if (!involved) return reply(403, { error: "You're not part of this prediction." });

  // The newest thing the caller did on this prediction is what we announce.
  const log: Entry[] = Array.isArray(p.log) ? p.log : [];
  const last = [...log].reverse().find((e) => e.uid === caller);
  if (!last) return reply(200, { sent: 0, reason: "nothing new from you on this one" });
  if (last.t && Date.now() - Date.parse(last.t) > 5 * 60_000) return reply(200, { sent: 0, reason: "that was a while ago" });

  // Tell the other side (a referee's pick goes to both sides). When an original is decided,
  // its crash players hear about it too.
  const what = last.what ?? "", by = last.by ?? "Someone";
  const recipients = new Set<string>();
  if (p.referee_uid && caller === p.referee_uid) { recipients.add(p.a_uid); if (p.b_uid) recipients.add(p.b_uid); }
  else if (caller === p.a_uid) { if (p.b_uid ?? p.b_invited) recipients.add(p.b_uid ?? p.b_invited); }
  else recipients.add(p.a_uid);
  if (/^(confirmed|conceded|agreed to call it off|withdrew|declined|accepted the proof|refereed)/.test(what) || p.status === "hopeless") {
    const { data: kids } = await admin.from("predictions").select("a_uid,b_uid").eq("parent_id", p.id);
    for (const k of kids ?? []) { if (k.a_uid) recipients.add(k.a_uid); if (k.b_uid) recipients.add(k.b_uid); }
  }
  recipients.delete(caller);

  // The referee hears once, when they're picked.
  let refSent = 0;
  const objected = /^says the proof doesn't hold up/.test(what);
  if (objected && p.status === "referee" && p.referee_uid && p.referee_uid !== caller) {
    recipients.delete(p.referee_uid);
    refSent = await deliver(admin, [p.referee_uid], {
      title: "You're the referee",
      body: `${p.a_name} vs ${p.b_name}: ${p.title}. Look at the proof and pick the winner within 24 hours, or it's Hopeless.`,
      tag: p.id,
    });
  }
  if (!recipients.size) return reply(200, { sent: refSent, reason: refSent ? undefined : "no one on Handshake to tell yet" });

  let text = `${by} ${what || "made a move"}`;
  if (/^recorded:/.test(what)) text += ". You have 24 hours to confirm it or say prove it. After that, it counts.";
  else if (/^said prove it/.test(what)) text = `${by} says prove it. Post a photo or a video link within 24 hours, or ${by} wins.`;
  else if (/^posted proof/.test(what)) text = `${by} posted proof. You have 24 hours to accept it or say why it doesn't hold up. After that, it counts.`;
  else if (/^accepted the proof/.test(what)) text = `${by} accepted the proof. Done and done.`;
  else if (/^conceded: /.test(what)) text = `${by} ${what}. Done and done.`;
  else if (objected) text = p.status === "referee"
    ? `${by} says your proof doesn't hold up. ${p.referee_name ?? "A referee"} is refereeing and has 24 hours to pick the winner.`
    : `${by} says your proof doesn't hold up, and there's no one to referee. It's Hopeless: no points move.`;
  else if (/^refereed: /.test(what)) text = `${by} refereed it: ${what.replace(/^refereed: /, "")}. Done and done.`;

  const sent = await deliver(admin, [...recipients], { title: p.title, body: text, tag: p.id });
  return reply(200, { sent: sent + refSent });
});

// Handshake Squares: the background job for Squares pools.
// Called every 5 minutes by the pg_cron job "handshake-squares". Deploy with "Verify JWT" OFF
// so the cron job can call it without a key. Each run:
//   1. draws the numbers for any open pool whose first game has kicked off
//      (unsold squares go to the originator) and tells everyone in the pool;
//   2. for games in progress, reads ESPN's public NFL scoreboard and records the score at the
//      end of each quarter (Q4 = final, overtime included) with the winning square;
//   3. notifies everyone in the pool of each new (or fixed) quarter result, once.
// The app also calls it with {"schedule": "YYYY-MM-DD"} (a Tuesday) to list that NFL week's games
// from ESPN for the Start a pool form; those are saved in nfl_schedule.
// It returns right away when no pool needs anything, so most runs make no outside calls.
// It also keeps NFL scores current for the Vegas tab and Pick 'em All!: while any game that has
// kicked off isn't final, it reads ESPN and saves the scores (save_vegas_scores), and when a game
// goes final it runs grade_pickem, so standings move within minutes of each game ending.
//
// Secrets: the same push secrets as notify (VAPID_PRIVATE_KEY, APNS_KEY_ID, APNS_TEAM_ID,
// APNS_PRIVATE_KEY). Supabase shares secrets across functions, so nothing new to add.
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
const APNS_HOST = "https://api.push.apple.com";
const ESPN_HOSTS = ["https://site.api.espn.com", "https://site.web.api.espn.com"];
const ESPN_PATH = "/apis/site/v2/sports/football/nfl/scoreboard";
const ESPN_HEADERS = { "User-Agent": "Mozilla/5.0 (compatible; Handshake/1.0)", Accept: "application/json" };
/** ESPN scoreboard events for a query; tries the second host if the first fails. Notes what happened in diag. */
async function espn(query: string, diag?: string[]): Promise<Ev[]> {
  for (const host of ESPN_HOSTS) {
    try {
      const r = await fetch(`${host}${ESPN_PATH}?${query}`, { headers: ESPN_HEADERS });
      if (!r.ok) { diag?.push(`${query} ${new URL(host).hostname} ${r.status}`); console.error("squares: ESPN", host, query, r.status); continue; }
      const evs = ((await r.json()).events ?? []) as Ev[];
      diag?.push(`${query} ${evs.length}`);
      return evs;
    } catch (e) { diag?.push(`${query} ${new URL(host).hostname} ${String(e).slice(0, 80)}`); console.error("squares: ESPN failed", host, query, e); }
  }
  return [];
}

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown, quiet = false) => {
  if (!quiet) console.log("squares:", status, JSON.stringify(body));
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
};
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

/* ---------- ESPN scores ---------- */
type Comp = { homeAway: string; score?: string; team: { displayName: string; shortDisplayName?: string; name?: string; abbreviation?: string }; linescores?: { value: number }[] };
type Ev = { id?: string; date?: string; competitions: { competitors: Comp[]; status: { period: number; type: { name: string; completed: boolean } } }[] };
const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9 ]/g, "").trim();
const nick = (s: string) => norm(s).split(" ").pop() ?? "";
const sameTeam = (ours: string, t: Comp["team"]) =>
  norm(ours) === norm(t.displayName) || nick(ours) === nick(t.displayName) || nick(ours) === norm(t.name ?? "");
const etDay = (iso: string) => new Date(iso).toLocaleDateString("en-CA", { timeZone: "America/New_York" }).replaceAll("-", "");
const short = (team: string) => team.split(" ").pop() ?? team;

/** Quarters that are over, with the cumulative score at the end of each (Q4 = final, OT included). */
export function quartersDone(ev: Ev, home: string, away: string, id?: string): { q: number; home: number; away: number }[] | null {
  const c = ev.competitions?.[0];
  if (!c) return null;
  const h = c.competitors.find((x) => x.homeAway === "home"), a = c.competitors.find((x) => x.homeAway === "away");
  if (!h || !a) return null;
  // new pools use ESPN's game id; older ones match on team names
  if (!(id && ev.id === id) && !(sameTeam(home, h.team) && sameTeam(away, a.team))) return null;
  const st = c.status, name = st.type.name;
  const over = st.type.completed;
  // a quarter is done once play has moved past it (or it's the break right after it)
  const doneThrough = over ? 4 : Math.min(3, (name === "STATUS_END_PERIOD" || name === "STATUS_HALFTIME") ? st.period : st.period - 1);
  const out: { q: number; home: number; away: number }[] = [];
  const sum = (x: Comp, n: number) => (x.linescores ?? []).slice(0, n).reduce((s, l) => s + (Number(l.value) || 0), 0);
  for (let q = 1; q <= doneThrough; q++) {
    if (q === 4) out.push({ q, home: Number(h.score) || 0, away: Number(a.score) || 0 });
    else {
      if ((h.linescores?.length ?? 0) < q || (a.linescores?.length ?? 0) < q) break;
      out.push({ q, home: sum(h, q), away: sum(a, q) });
    }
  }
  return out;
}

/* ---------- the week's schedule, for the Start a pool form ---------- */
async function schedule(admin: Admin, week: string) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(week)) return reply(400, { error: "Pick a week." });
  const t0 = Date.parse(week + "T12:00:00Z"), diag: string[] = [];
  const ymd = (t: number) => new Date(t).toISOString().slice(0, 10).replaceAll("-", "");
  const inRange = (ev: Ev) => !!ev.date && Date.parse(ev.date) >= t0 - 12 * 3600e3 && Date.parse(ev.date) < t0 + 7 * 86400e3;
  // 1) the whole Tuesday-Monday range in one call; 2) day by day; 3) by NFL week number
  let evs = (await espn(`dates=${ymd(t0)}-${ymd(t0 + 6 * 86400e3)}&limit=100`, diag)).filter(inRange);
  if (!evs.length) evs = (await Promise.all(Array.from({ length: 7 }, (_, i) => espn(`dates=${ymd(t0 + i * 86400e3)}`, diag)))).flat().filter(inRange);
  if (!evs.length) {
    // regular season week 1 starts the Tuesday after Labor Day (first Monday in September)
    const y = new Date(t0).getUTCMonth() < 6 ? new Date(t0).getUTCFullYear() - 1 : new Date(t0).getUTCFullYear();
    const sep1 = new Date(Date.UTC(y, 8, 1)).getUTCDay(), labor = Date.UTC(y, 8, 1 + ((8 - sep1) % 7)), w1 = labor + 86400e3;
    const n = Math.round((t0 - 12 * 3600e3 - w1) / (7 * 86400e3)) + 1;
    if (n >= 1 && n <= 18) evs = (await espn(`seasontype=2&week=${n}&dates=${y}`, diag)).filter(inRange);
    else if (n > 18) evs = (await espn(`seasontype=3&week=${n - 18}&dates=${y}`, diag)).filter(inRange);
  }
  const lists = [evs];
  const games = new Map<string, { id: string; starts_at: string; home: string; away: string }>();
  for (const ev of lists.flat()) {
    const c = ev.competitions?.[0], h = c?.competitors.find((x) => x.homeAway === "home"), a = c?.competitors.find((x) => x.homeAway === "away");
    if (!ev.id || !ev.date || !h || !a || /tbd/i.test(h.team.displayName + a.team.displayName)) continue;
    games.set(ev.id, { id: ev.id, starts_at: new Date(ev.date).toISOString(), home: h.team.displayName, away: a.team.displayName });
  }
  const rows = [...games.values()].sort((x, y) => Date.parse(x.starts_at) - Date.parse(y.starts_at));
  if (rows.length) {
    const { error } = await admin.from("nfl_schedule").upsert(rows.map((r) => ({ ...r, updated_at: new Date().toISOString() })));
    if (error) return reply(500, { error: error.message });
  }
  if (!rows.length) console.log("squares: schedule empty for", week, diag.join(" | "));
  return reply(200, { games: rows, diag }, true);
}

/* ---------- NFL scores for the Vegas tab and Pick 'em All! (ESPN, free) ---------- */
async function nflScores(admin: Admin) {
  const since = new Date(Date.now() - 3 * 86400e3).toISOString();
  const { data: live } = await admin.from("vegas_lines").select("id,home,away,starts_at").eq("completed", false)
    .lte("starts_at", new Date().toISOString()).gte("starts_at", since);
  if (!live?.length) return { live: 0, saved: 0, final: 0 };
  const byDay = new Map<string, Ev[]>();
  const rows: { id: string; home_score: number; away_score: number; completed: boolean }[] = [];
  for (const g of live) {
    const day = etDay(g.starts_at);
    if (!byDay.has(day)) byDay.set(day, await espn(`dates=${day}`));
    for (const ev of byDay.get(day)!) {
      const c = ev.competitions?.[0], h = c?.competitors.find((x) => x.homeAway === "home"), a = c?.competitors.find((x) => x.homeAway === "away");
      if (!c || !h || !a || !sameTeam(g.home, h.team) || !sameTeam(g.away, a.team)) continue;
      if (c.status.period >= 1 || c.status.type.completed) rows.push({ id: g.id, home_score: Number(h.score) || 0, away_score: Number(a.score) || 0, completed: !!c.status.type.completed });
      break;
    }
  }
  if (!rows.length) return { live: live.length, saved: 0, final: 0 };
  const { data: saved, error } = await admin.rpc("save_vegas_scores", { p_rows: rows });
  if (error) { console.error("squares: save scores", error.message); return { live: live.length, saved: 0, final: 0, error: error.message }; }
  const final = rows.filter((r) => r.completed).length;
  let graded = null;
  if (final) { const g = await admin.rpc("grade_pickem"); graded = g.error ? g.error.message : g.data; }
  return { live: live.length, saved, final, graded };
}

/* ---------- the run ---------- */
async function members(admin: Admin, pool: string, originator: string) {
  const inv = ((await admin.from("squares_invitees").select("uid").eq("pool_id", pool)).data ?? []).map((x: { uid: string }) => x.uid);
  const cl = ((await admin.from("squares_claims").select("uid").eq("pool_id", pool)).data ?? []).map((x: { uid: string }) => x.uid);
  return [...new Set([originator, ...inv, ...cl])] as string[];
}
const ptsText = (n: number) => `${n} pt${n === 1 ? "" : "s"}`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  let body: { schedule?: string } = {};
  try { body = (await req.json()) ?? {}; } catch (_) { /* cron sends {} */ }
  if (body.schedule) return await schedule(admin, String(body.schedule));
  const drawn = (await admin.rpc("squares_tick")).data ?? 0;
  const scores = await nflScores(admin).catch((e) => ({ error: String(e) }));

  // 1. scores for games in progress
  const { data: pending, error: pErr } = await admin.rpc("squares_pending_games");
  if (pErr) return reply(500, { error: pErr.message });
  let recorded = 0;
  const byDay = new Map<string, Ev[]>();
  for (const g of pending ?? []) {
    const day = etDay(g.starts_at);
    if (!byDay.has(day)) {
      byDay.set(day, await espn(`dates=${day}`));
    }
    for (const ev of byDay.get(day)!) {
      const qs = quartersDone(ev, g.home, g.away, g.game_id);
      if (!qs) continue;
      for (const r of qs) {
        if (r.q <= g.have) continue;
        const { data: ok } = await admin.rpc("squares_record_auto", { p_pool: g.pool_id, p_game: g.game_id, p_q: r.q, p_home: r.home, p_away: r.away });
        if (ok) recorded++;
      }
      break;
    }
  }

  // 2. "numbers are drawn" notes
  let sent = 0;
  const { data: newDraws } = await admin.from("squares_pools").select("id,title,originator").in("status", ["drawn", "done"]).is("draw_notified_at", null);
  for (const p of newDraws ?? []) {
    await admin.from("squares_pools").update({ draw_notified_at: new Date().toISOString() }).eq("id", p.id);
    const to = await members(admin, p.id, p.originator);
    sent += await deliver(admin, to, { title: `${p.title}: numbers are in`, body: "Squares are locked and the numbers are drawn. Open Squares to see yours.", tag: `squares-${p.id}` });
  }

  // 3. quarter results
  const { data: fresh } = await admin.from("squares_results").select("*").is("notified_at", null);
  for (const r of fresh ?? []) {
    await admin.from("squares_results").update({ notified_at: new Date().toISOString() }).eq("pool_id", r.pool_id).eq("game_id", r.game_id).eq("quarter", r.quarter);
    const { data: p } = await admin.from("squares_pools").select("id,title,originator").eq("id", r.pool_id).maybeSingle();
    const { data: g } = await admin.from("squares_games").select("home,away").eq("pool_id", r.pool_id).eq("game_id", r.game_id).maybeSingle();
    if (!p || !g) continue;
    const who = r.uid ? (((await admin.from("profiles").select("name:display_name").eq("id", r.uid).maybeSingle()).data?.name as string) || "Someone") : "Nobody";
    const when = r.quarter === 4 ? "Final" : `End of Q${r.quarter}`;
    const fixed = r.source === "manual" ? " (score fixed)" : "";
    const to = await members(admin, p.id, p.originator);
    sent += await deliver(admin, to, {
      title: `${p.title}: ${when}${fixed}`,
      body: `${short(g.away)} ${r.away}, ${short(g.home)} ${r.home}. Square ${r.square}: ${who} wins ${ptsText(r.points)}.`,
      tag: `squares-${p.id}-${r.game_id}-${r.quarter}`,
    });
  }
  return reply(200, { drawn, games: pending?.length ?? 0, recorded, sent, scores });
});

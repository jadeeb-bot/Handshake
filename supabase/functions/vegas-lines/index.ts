// Handshake Vegas lines: pulls NFL spreads and over/unders from The Odds API once a day and
// saves them to the vegas_lines table. The first line saved for each game is kept for good,
// so the app always shows the opening line we saw. It also pulls final scores while games
// are in progress and then grades Pick 'em All! (grade_pickem()).
//
// Called every hour by the pg_cron job "handshake-vegas-lines". Deploy with "Verify JWT" OFF
// so the cron job can call it without a key. Extra calls can't burn through the free plan:
//   * lines: at most once per Pacific day, after 6 AM (2 credits each)
//   * scores: only when a game kicked off in the last 3 days and isn't final yet, and at
//     most every 3 hours (2 credits each)
//
// Secrets (Supabase > Edge Functions > Secrets):
//   ODDS_API_KEY   your key from the-odds-api.com
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ODDS_API_KEY = Deno.env.get("ODDS_API_KEY") ?? "";
const API = "https://api.the-odds-api.com/v4/sports/americanfootball_nfl";
const SCORES_EVERY_HOURS = 3;
const BOOKS = ["draftkings", "fanduel", "betmgm", "caesars", "espnbet", "betrivers"];

const reply = (status: number, body: unknown) => {
  console.log("vegas-lines:", status, JSON.stringify(body));
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
};
const ptDay = (d: Date) => d.toLocaleDateString("en-CA", { timeZone: "America/Los_Angeles" });
const ptHour = (d: Date) => Number(d.toLocaleString("en-US", { timeZone: "America/Los_Angeles", hour: "numeric", hourCycle: "h23" }));

type Outcome = { name: string; price?: number; point?: number };
type Market = { key: string; outcomes: Outcome[] };
type Book = { key: string; title: string; markets: Market[] };
type Game = { id: string; commence_time: string; home_team: string; away_team: string; bookmakers: Book[] };
type ScoreGame = { id: string; completed: boolean; home_team: string; away_team: string; scores: { name: string; score: string }[] | null };
// deno-lint-ignore no-explicit-any
type DB = any;

// Prefer the big books in order; fall back to whichever book has the market.
function pickBook(g: Game, market: string): { book: Book; m: Market } | null {
  const has = g.bookmakers.filter((b) => b.markets.some((m) => m.key === market));
  if (!has.length) return null;
  has.sort((a, b) => (BOOKS.indexOf(a.key) + 1 || 99) - (BOOKS.indexOf(b.key) + 1 || 99));
  return { book: has[0], m: has[0].markets.find((m) => m.key === market)! };
}

async function lastPull(db: DB, kind: string): Promise<Date | null> {
  const { data, error } = await db.from("vegas_pulls").select("pulled_at").eq("kind", kind).order("pulled_at", { ascending: false }).limit(1);
  if (error) throw new Error("can't read vegas_pulls: " + error.message);
  return data?.length ? new Date(data[0].pulled_at) : null;
}

async function pullLines(db: DB) {
  const res = await fetch(`${API}/odds?regions=us&markets=spreads,totals&oddsFormat=american&apiKey=${ODDS_API_KEY}`);
  const left = Number(res.headers.get("x-requests-remaining")) || null;
  if (!res.ok) {
    const why = (await res.text()).slice(0, 300);
    await db.from("vegas_pulls").insert({ kind: "lines", games: 0, credits_left: left, note: "error " + res.status + ": " + why });
    return { error: "The Odds API said " + res.status, detail: why };
  }
  const games = (await res.json()) as Game[];
  const rows = games.map((g) => {
    const sp = pickBook(g, "spreads"), tot = pickBook(g, "totals");
    const home = sp?.m.outcomes.find((o) => o.name === g.home_team);
    const over = tot?.m.outcomes.find((o) => o.name === "Over");
    return {
      id: g.id, league: "nfl", starts_at: g.commence_time, home: g.home_team, away: g.away_team,
      home_spread: home?.point ?? null, total: over?.point ?? null, book: sp?.book.title ?? tot?.book.title ?? null,
    };
  });
  const { data: saved, error } = rows.length ? await db.rpc("save_vegas_lines", { p_rows: rows }) : { data: 0, error: null };
  await db.from("vegas_pulls").insert({ kind: "lines", games: rows.length, credits_left: left, note: error ? "save failed: " + error.message : null });
  return error ? { error: "save failed: " + error.message } : { games: rows.length, saved, credits_left: left };
}

async function pullScores(db: DB) {
  const res = await fetch(`${API}/scores?daysFrom=3&apiKey=${ODDS_API_KEY}`);
  const left = Number(res.headers.get("x-requests-remaining")) || null;
  if (!res.ok) {
    const why = (await res.text()).slice(0, 300);
    await db.from("vegas_pulls").insert({ kind: "scores", games: 0, credits_left: left, note: "error " + res.status + ": " + why });
    return { error: "The Odds API said " + res.status, detail: why };
  }
  const games = (await res.json()) as ScoreGame[];
  const pts = (g: ScoreGame, team: string) => { const s = g.scores?.find((x) => x.name === team)?.score; return s == null ? null : Number(s); };
  const rows = games.filter((g) => g.scores?.length).map((g) => ({
    id: g.id, home_score: pts(g, g.home_team), away_score: pts(g, g.away_team), completed: !!g.completed,
  }));
  const { data: saved, error } = rows.length ? await db.rpc("save_vegas_scores", { p_rows: rows }) : { data: 0, error: null };
  await db.from("vegas_pulls").insert({ kind: "scores", games: rows.length, credits_left: left, note: error ? "save failed: " + error.message : null });
  return error ? { error: "save failed: " + error.message } : { games: rows.length, final: rows.filter((r) => r.completed).length, saved, credits_left: left };
}

Deno.serve(async () => {
  if (!ODDS_API_KEY) return reply(500, { error: "ODDS_API_KEY secret is missing" });
  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const now = new Date(), out: Record<string, unknown> = {};
  try {
    // Lines: once per Pacific day, after 6 AM.
    const lastLines = await lastPull(db, "lines");
    if (ptHour(now) >= 6 && (!lastLines || ptDay(lastLines) !== ptDay(now))) out.lines = await pullLines(db);
    else out.lines = "skipped (already pulled today" + (lastLines ? " at " + lastLines.toISOString() : "") + ")";

    // Scores: only while a game that kicked off in the last 3 days isn't final.
    const { data: live } = await db.from("vegas_lines").select("id").eq("completed", false)
      .lte("starts_at", now.toISOString()).gte("starts_at", new Date(now.getTime() - 3 * 864e5).toISOString()).limit(1);
    const lastScores = await lastPull(db, "scores");
    if (!live?.length) out.scores = "skipped (no games in progress)";
    else if (lastScores && now.getTime() - lastScores.getTime() < SCORES_EVERY_HOURS * 3600e3) out.scores = "skipped (pulled at " + lastScores.toISOString() + ")";
    else out.scores = await pullScores(db);

    // Score any finished Pick 'em All! weeks.
    const { data: graded, error } = await db.rpc("grade_pickem");
    out.pickem_weeks_graded = error ? "not set up yet (" + error.message + ")" : graded;
  } catch (e) {
    return reply(500, { error: String((e as Error).message || e), ...out });
  }
  return reply(200, out);
});

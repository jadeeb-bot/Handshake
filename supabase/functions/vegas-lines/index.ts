// Handshake Vegas lines: pulls NFL spreads and over/unders from The Odds API once a day
// and saves them to the vegas_lines table. The first line saved for each game is kept for
// good, so the app always shows the opening line we saw.
//
// Runs every morning from the pg_cron job "handshake-vegas-lines" (update-vegas-lines.sql).
// Deploy with "Verify JWT" OFF so the cron job can call it without a key. It refuses to pull
// more than once every 20 hours, so calling it extra can't burn through the free plan
// (each pull costs 2 of the 500 free credits a month).
//
// Secrets (Supabase > Edge Functions > Secrets):
//   ODDS_API_KEY   your key from the-odds-api.com
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ODDS_API_KEY = Deno.env.get("ODDS_API_KEY") ?? "";
const MIN_HOURS = 20;
const BOOKS = ["draftkings", "fanduel", "betmgm", "caesars", "espnbet", "betrivers"];

const reply = (status: number, body: unknown) => {
  console.log("vegas-lines:", status, JSON.stringify(body));
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
};

type Outcome = { name: string; price?: number; point?: number };
type Market = { key: string; outcomes: Outcome[] };
type Book = { key: string; title: string; markets: Market[] };
type Game = { id: string; commence_time: string; home_team: string; away_team: string; bookmakers: Book[] };

// Prefer the big books in order; fall back to whichever book has the market.
function pickBook(g: Game, market: string): { book: Book; m: Market } | null {
  const has = g.bookmakers.filter((b) => b.markets.some((m) => m.key === market));
  if (!has.length) return null;
  has.sort((a, b) => (BOOKS.indexOf(a.key) + 1 || 99) - (BOOKS.indexOf(b.key) + 1 || 99));
  return { book: has[0], m: has[0].markets.find((m) => m.key === market)! };
}

Deno.serve(async () => {
  if (!ODDS_API_KEY) return reply(500, { error: "ODDS_API_KEY secret is missing" });
  const db = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

  const { data: last, error: lastErr } = await db.from("vegas_pulls").select("pulled_at").order("pulled_at", { ascending: false }).limit(1);
  if (lastErr) return reply(500, { error: "can't read vegas_pulls: " + lastErr.message });
  if (last?.length && Date.now() - Date.parse(last[0].pulled_at) < MIN_HOURS * 3600e3) {
    return reply(200, { skipped: "already pulled at " + last[0].pulled_at });
  }

  const url = "https://api.the-odds-api.com/v4/sports/americanfootball_nfl/odds?regions=us&markets=spreads,totals&oddsFormat=american&apiKey=" + ODDS_API_KEY;
  const res = await fetch(url);
  const left = Number(res.headers.get("x-requests-remaining")) || null;
  if (!res.ok) {
    const why = (await res.text()).slice(0, 300);
    await db.from("vegas_pulls").insert({ games: 0, credits_left: left, note: "error " + res.status + ": " + why });
    return reply(502, { error: "The Odds API said " + res.status, detail: why });
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
  await db.from("vegas_pulls").insert({ games: rows.length, credits_left: left, note: error ? "save failed: " + error.message : null });
  if (error) return reply(500, { error: "save failed: " + error.message });
  return reply(200, { games: rows.length, saved, credits_left: left });
});

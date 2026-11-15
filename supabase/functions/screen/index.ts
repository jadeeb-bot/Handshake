// Handshake "Keep it fun" check. The app sends text people typed (prediction titles, names,
// pool names, notes...) here before saving it. Each text is checked against Handshake's rule:
//   fun only: no profanity, sexual content, violence, hate, or politics.
// First the database word list, then Claude for everything a word list can't judge.
// Text that passes is remembered in screened_text (so it's only checked once), and the first
// time Claude answers, the database starts requiring checked text (moderation_settings).
// If Claude can't be reached, text that passed the word list is let through (marked "unchecked").
//
// Secrets (Supabase > Edge Functions > Secrets):
//   ANTHROPIC_API_KEY   from console.anthropic.com > API keys
//   SCREEN_MODEL        optional; defaults to claude-haiku-5-5
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase automatically.
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANTHROPIC_API_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
const MODEL = Deno.env.get("SCREEN_MODEL") ?? "claude-haiku-5-5";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const norm = (s: string) => s.replace(/\s+/g, " ").trim().toLowerCase();

const RULE = `You check short pieces of text that people type into Handshake, a friendly prediction app for a group of friends (sports picks, golf games, football squares pools, contests, party plans). Handshake is just for fun. Decide for each text whether it is allowed.

NOT allowed:
- Profanity or crude language, including masked or misspelled versions (f*ck, sh!t, a$$).
- Sexual content, innuendo or body-part jokes.
- Violence, threats, gore, weapons used against people, or self-harm. (Sports phrasing like "crush", "destroy", "kill it", "blowout" is fine.)
- Hate or harassment: slurs, insults about race, religion, gender, sexuality, disability or nationality, or bullying a person.
- Anything political, even neutral: politicians, parties, elections, government, laws or policy debates, political causes or culture-war topics.
- Illegal drugs.

Allowed: sports, games, food, drinks, travel, weather, TV and movies, everyday life, friendly trash talk, nicknames, people's names (unless the name is a politician or offensive), places, team names, dates, numbers.

Answer with only JSON, no other words: {"results":[{"i":<index>,"ok":true|false,"why":"<if not ok, 3-8 words, e.g. that's political>"}]}`;

async function askClaude(texts: string[]): Promise<{ i: number; ok: boolean; why?: string }[] | null> {
  if (!ANTHROPIC_API_KEY) { console.log("screen: ANTHROPIC_API_KEY missing, word list only"); return null; }
  try {
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODEL, max_tokens: 600, system: RULE,
        messages: [{ role: "user", content: "Texts:\n" + texts.map((t, i) => `${i}: ${JSON.stringify(t)}`).join("\n") }],
      }),
    });
    if (!res.ok) { console.error("screen: Claude", res.status, (await res.text()).slice(0, 300)); return null; }
    const j = await res.json();
    const text = (j.content ?? []).map((c: { text?: string }) => c.text ?? "").join("");
    const m = text.match(/\{[\s\S]*\}/);
    const out = m ? JSON.parse(m[0]).results : null;
    if (!Array.isArray(out)) { console.error("screen: unexpected answer", text.slice(0, 300)); return null; }
    return out;
  } catch (e) { console.error("screen: Claude failed", e); return null; }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "Use POST." });
  const admin = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: who } = await admin.auth.getUser(token);
  if (!who?.user) return reply(401, { error: "Sign in first." });

  let body: { texts?: unknown } = {};
  try { body = (await req.json()) ?? {}; } catch (_) { /* empty */ }
  const texts = [...new Set((Array.isArray(body.texts) ? body.texts : []).map((t) => String(t ?? "").slice(0, 500)).filter((t) => norm(t)))].slice(0, 40);
  if (!texts.length) return reply(200, { ok: true });

  // 1. the word list
  const { data: bad } = await admin.rpc("mod_word_check", { p_texts: texts });
  if (bad?.length) return reply(200, { ok: false, text: bad[0].t, message: `Keep it fun: "${bad[0].t}" isn't allowed on Handshake.` });

  // 2. skip text that already passed
  const { data: known } = await admin.from("screened_text").select("t").in("t", texts.map(norm));
  const seen = new Set((known ?? []).map((x: { t: string }) => x.t));
  const todo = texts.filter((t) => !seen.has(norm(t)));
  if (!todo.length) return reply(200, { ok: true });

  // 3. Claude
  const verdicts = await askClaude(todo);
  if (!verdicts) {
    await admin.rpc("screen_store", { p_texts: todo, p_source: "unchecked", p_turn_on: false });
    return reply(200, { ok: true, unchecked: true });
  }
  const no = verdicts.find((v) => v && v.ok === false && todo[v.i] !== undefined);
  if (no) {
    console.log("screen: blocked", JSON.stringify(todo[no.i]), no.why ?? "");
    const ok = todo.filter((_, i) => !verdicts.some((v) => v.i === i && v.ok === false));
    if (ok.length) await admin.rpc("screen_store", { p_texts: ok, p_source: "ai", p_turn_on: true });
    return reply(200, { ok: false, text: todo[no.i], message: `Keep it fun: "${todo[no.i]}" ${no.why ? `(${no.why}) ` : ""}isn't allowed on Handshake. No profanity, sexual, violent, hateful or political content.` });
  }
  await admin.rpc("screen_store", { p_texts: todo, p_source: "ai", p_turn_on: true });
  return reply(200, { ok: true });
});

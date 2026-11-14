const createClient = window.supabase?.createClient;

const $ = (s) => document.querySelector(s);
const esc = (s) => String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const DAY = 864e5;
const pad = (n) => String(n).padStart(2, "0");
const ymd = (d) => d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate());
const today = () => ymd(new Date());
const addDays = (n) => ymd(new Date(Date.now() + n * DAY));
const daysBetween = (a, b) => Math.round((new Date(b + "T12:00") - new Date(a + "T12:00")) / DAY);
const niceDate = (d) => new Date(d + "T12:00").toLocaleDateString("en-US", { month: "short", day: "numeric" });
const pts = (n) => (+n || 0).toLocaleString("en-US") + " pt" + (Math.abs(+n || 0) === 1 ? "" : "s");
const signed = (n) => (n > 0 ? "+" : n < 0 ? "−" : "") + Math.abs(n).toLocaleString("en-US");
const tone = (n) => (n > 0 ? "pos" : n < 0 ? "neg" : "");
const store = {
  get(k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
  set(k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
};
const IN_APP = !!window.Capacitor?.isNativePlatform?.();
/* Capacitor's plugin hookup: the app bundles capacitor.js; the website never needs it */
const capPlugin = (name) => { const reg = window.Capacitor?.registerPlugin || window.capacitorExports?.registerPlugin; return IN_APP && reg ? reg(name) : null; };
const PAGE_URL = IN_APP || !/^https?:$/.test(location.protocol)
  ? (window.HANDSHAKE_CONFIG?.siteUrl || "https://handshake-rho-ten.vercel.app/")
  : location.origin + location.pathname.replace(/index\.html$/, "");

/* ---------- setup ---------- */
const CFG = window.HANDSHAKE_CONFIG || {};
const configured = CFG.supabaseUrl && !CFG.supabaseUrl.includes("YOUR-PROJECT") && CFG.supabaseAnonKey && !CFG.supabaseAnonKey.includes("YOUR-");
const sb = configured && createClient ? createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, { auth: { persistSession: true, autoRefreshToken: true } }) : null;

const S = {
  me: null, myName: "", email: "", bets: [], people: [], loaded: false,
  tab: "board", filter: "all", sort: store.get("hs-sort") || "needs", feedFilter: "crash",
  picking: null, busy: new Set(), fresh: null, stakeKind: "points",
  pickedUid: null, pickedName: "", crashing: null, crashSide: null, crashDraft: {},
  phones: new Map(), refPhones: new Map(), proofUrls: new Map(), proving: null, proofDraft: {}, objecting: null, objDraft: "", notify: null, countering: null, counterDraft: {}, fixing: null, extending: null, settlements: [], settleReqs: [], settling: null, opps: [], groupInvite: null, lines: null, linesErr: "", pk: null, pkView: null, pkNaming: false, pkInviting: null, authMode: "phone", myInvites: new Set(), phone: "",
};

const LABEL = { proposed: "Waiting for a handshake", open: "Booked", reported: "Result pending", disputed: "Disputed", prove: "Prove it!", proved: "Proof posted", referee: "With the referee", settled: "Done and done", void: "Called off", hopeless: "Hopeless" };
const LIVE = ["proposed", "open", "reported", "disputed", "prove", "proved", "referee"];
/* an invite nobody shook on before its shake-by time */
const expired = (b) => b.status === "proposed" && !!b.shakeBy && Date.now() > b.shakeBy;
const isLive = (b) => LIVE.includes(b.status) && !expired(b);
/* "Tue, Nov 10 at 7:00 PM PST" in the reader's own time zone */
function deadlineText(ms) {
  const d = new Date(ms);
  const day = d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
  const time = d.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit", timeZoneName: "short" });
  return day + " at " + time;
}
function timeLeft(ms) {
  const m = Math.round((ms - Date.now()) / 60000);
  if (m <= 0) return "expired";
  if (m < 60) return m + " min left";
  const h = Math.round(m / 60); if (h < 48) return h + " hr left";
  return Math.round(h / 24) + " days left";
}

/* ---------- rows → slips ---------- */
function fromRow(r) {
  return {
    id: r.id, title: r.title, category: r.category, visibility: r.visibility || "all", stakeKind: r.stake_kind, points: r.points, stakeText: r.stake_text,
    due: r.due || "", terms: r.terms || "",
    a: { name: r.a_name, uid: r.a_uid },
    b: { name: r.b_name, uid: r.b_uid, invited: r.b_invited, proxy: r.b_proxy, signed: !!(r.b_uid || r.b_proxy) },
    status: r.status, report: r.report_winner ? { winner: r.report_winner, by: r.report_by } : null, winner: r.winner,
    disputeBy: r.dispute_by ? Date.parse(r.dispute_by) : null,
    stepBy: r.step_by ? Date.parse(r.step_by) : null,
    proof: r.proof_path || r.proof_link ? { path: r.proof_path, link: r.proof_link, at: r.proof_at ? Date.parse(r.proof_at) : null } : null,
    objection: r.objection || "", referee: r.referee_uid || r.referee_name ? { uid: r.referee_uid, name: r.referee_name || "the referee" } : null,
    parentId: r.parent_id, parentSide: r.parent_side, backsName: r.backs_name,
    counter: r.counter_by ? { by: r.counter_by, uid: r.counter_uid, kind: r.counter_kind, points: r.counter_points, text: r.counter_text } : null,
    shakeBy: r.shake_by ? Date.parse(r.shake_by) : null, pickem: r.pickem_group || null, wolf: r.wolf_round || null,
    createdAt: Date.parse(r.created_at), decidedAt: r.decided_at ? Date.parse(r.decided_at) : null, log: r.log || [],
  };
}

/* ---------- perspective ---------- */
const isOther = (b) => b.stakeKind === "other";
const stakeOf = (b) => (isOther(b) ? 0 : Math.max(0, Math.round(+b.points || 0)));
const stakeLabel = (b) => (isOther(b) ? b.stakeText || "Bragging rights" : pts(stakeOf(b)));
const side = (b) => (b.a?.uid && b.a.uid === S.me ? "a" : b.b?.uid && b.b.uid === S.me ? "b" : null);
const other = (s) => (s === "a" ? "b" : "a");
const nameOf = (b, s) => (b[s]?.name || "Someone").trim();
const shortNo = (id) => String(id).replace(/-/g, "").slice(-4).toUpperCase();
const scored = (b) => b.status === "settled" && b.winner;
/* Prove It!: the person who recorded the result, the one challenging it, and the referee */
const isRef = (b) => !!S.me && b.referee?.uid === S.me && b.status === "referee";
const poster = (b) => b.report?.by || null;
const challenger = (b) => (b.report?.by ? other(b.report.by) : null);
function needsMe(b) {
  if (b.status === "proposed" && b.counter?.by === "b" && b.a?.uid === S.me) return !expired(b);
  if (b.status === "referee") return isRef(b);
  const s = side(b); if (!s) return false;
  if (b.status === "open") return !b.parentId && !!b.due && b.due <= today();
  if (b.status === "reported") return b.report && b.report.by !== s;
  if (b.status === "disputed") return true;
  if (b.status === "prove") return s === poster(b);
  if (b.status === "proved") return s === challenger(b);
  return false;
}
const invitedMe = (b) => (b.b?.invited ? b.b.invited === S.me : S.myInvites.has(b.id));
const canSign = (b) => b.status === "proposed" && !!S.me && !b.b?.uid && b.a?.uid !== S.me && invitedMe(b) && b.counter?.by !== "b" && !expired(b);
const counterLabel = (c) => (c.kind === "other" ? c.text || "Bragging rights" : pts(c.points));
/* who I am while terms are still being worked out: the caller, or the invitee who's negotiating */
const negSide = (b) => side(b) || (b.status === "proposed" && S.me && (b.counter?.uid === S.me || invitedMe(b)) ? "b" : null);
const waitingOnMyCounter = (b) => b.status === "proposed" && !!b.counter && negSide(b) === b.counter.by;
const kids = (b) => S.bets.filter((x) => x.parentId === b.id);
const liveKids = (b) => kids(b).filter((x) => x.status !== "void");
const crashable = (b) => ["proposed", "open"].includes(b.status) && !expired(b) && !b.parentId && !!S.me && !side(b) && !invitedMe(b) && b.counter?.uid !== S.me && !liveKids(b).some((k) => k.a?.uid === S.me);
/* other one-on-ones from the same group call: same caller, call and deadline, made together */
const siblings = (b) => (b.parentId || !side(b) ? [] : S.bets.filter((x) => x.id !== b.id && !x.parentId && x.a.uid === b.a.uid && x.title === b.title
  && x.due === b.due && Math.abs((x.createdAt || 0) - (b.createdAt || 0)) < 10 * 60e3 && side(x) && ["open", "disputed"].includes(x.status) && !x.report));
const mineList = () => S.bets.filter((b) => side(b) || canSign(b) || negSide(b) || isRef(b));

/* ---------- scoring ---------- */
function mine() {
  let score = 0, w = 0, l = 0, t = 0, live = 0, atStake = 0;
  for (const b of S.bets) {
    const s = side(b); if (!s) continue;
    if (isLive(b)) { live++; atStake += stakeOf(b); }
    if (!scored(b)) continue;
    if (b.winner === "push") t++;
    else if (b.winner === s) { w++; score += stakeOf(b); }
    else { l++; score -= stakeOf(b); }
  }
  return { score, w, l, t, live, atStake };
}
/* Everyone sees the same standings: the server adds up every finished prediction (private ones
   too) and returns only the totals. Before update-standings.sql runs, fall back to adding up
   what this person can see. */
function standings() {
  if (S.serverStandings) {
    return S.serverStandings.map((r) => ({ name: r.name || "Someone", score: +r.score || 0, w: r.w || 0, l: r.l || 0, t: r.t || 0, me: !!S.me && r.uid === S.me }))
      .sort((a, b) => b.score - a.score || b.w - b.l - (a.w - a.l) || a.name.localeCompare(b.name));
  }
  const m = new Map();
  const key = (b, s) => b[s]?.uid || "name:" + nameOf(b, s).toLowerCase();
  const get = (b, s) => {
    const k = key(b, s);
    if (!m.has(k)) m.set(k, { name: personName(b[s]?.uid) || nameOf(b, s), score: 0, w: 0, l: 0, t: 0, me: b[s]?.uid === S.me });
    return m.get(k);
  };
  for (const b of S.bets) {
    if (!scored(b)) continue;
    const A = get(b, "a"), B = get(b, "b"), p = stakeOf(b);
    if (b.winner === "push") { A.t++; B.t++; continue; }
    const W = b.winner === "a" ? A : B, L = b.winner === "a" ? B : A;
    W.score += p; W.w++; L.score -= p; L.l++;
  }
  return [...m.values()].sort((a, b) => b.score - a.score || b.w - b.l - (a.w - a.l) || a.name.localeCompare(b.name));
}
function rivals() {
  const m = new Map();
  for (const b of S.bets) {
    const s = side(b); if (!s) continue;
    const o = other(s), k = b[o]?.uid || "name:" + nameOf(b, o).toLowerCase();
    if (!m.has(k)) m.set(k, { key: k, name: personName(b[o]?.uid) || nameOf(b, o), uid: b[o]?.uid || null, score: 0, w: 0, l: 0, t: 0, live: 0, last: 0 });
    const r = m.get(k); r.last = Math.max(r.last, b.createdAt || 0);
    if (isLive(b)) r.live++;
    if (!scored(b)) continue;
    if (b.winner === "push") r.t++;
    else if (b.winner === s) { r.w++; r.score += stakeOf(b); }
    else { r.l++; r.score -= stakeOf(b); }
  }
  for (const r of m.values()) {
    // what's been settled either way since the start; the current balance is what's left
    const mineSet = S.settlements.filter((x) => x.user_uid === S.me && (r.uid ? x.other_uid === r.uid : !x.other_uid && (x.other_name || "").toLowerCase() === r.name.toLowerCase()));
    const theirSet = r.uid ? S.settlements.filter((x) => x.user_uid === r.uid && x.other_uid === S.me) : [];
    r.current = r.score - mineSet.reduce((a, x) => a + x.points, 0) + theirSet.reduce((a, x) => a + x.points, 0);
    const lastSet = [...mineSet.map((x) => ({ ...x, byMe: true })), ...theirSet.map((x) => ({ ...x, byMe: false }))].sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at))[0];
    r.lastSettled = lastSet || null;
    const reqs = r.uid ? S.settleReqs.filter((q) => (q.requester_uid === S.me && q.creditor_uid === r.uid) || (q.requester_uid === r.uid && q.creditor_uid === S.me)) : [];
    r.pendingReq = reqs.find((q) => q.status === "pending") || null;
    const lastDisp = reqs.filter((q) => q.status === "disputed").sort((a, b) => Date.parse(b.resolved_at) - Date.parse(a.resolved_at))[0];
    r.disputedReq = lastDisp && (!lastSet || Date.parse(lastDisp.resolved_at) > Date.parse(lastSet.created_at)) ? lastDisp : null;
  }
  return [...m.values()].sort((a, b) => b.w + b.l + b.t + b.live - (a.w + a.l + a.t + a.live) || b.last - a.last);
}
const personName = (uid) => (uid ? S.people.find((p) => p.id === uid)?.name || "" : "");
const initials = (n) => n.split(/\s+/).map((x) => x[0]).join("").slice(0, 2).toUpperCase();

/* ---------- ledger ---------- */
function renderLedger() {
  const t = mine(), dec = t.w + t.l;
  const sc = $("#score"); sc.textContent = signed(t.score); sc.className = "big " + tone(t.score);
  const unsettled = S.settlements.length ? rivals().reduce((a, r) => a + r.current, 0) : null;
  $("#scoreSub").textContent = (dec || t.t ? "all-time, across " + (dec + t.t) + " prediction" + (dec + t.t === 1 ? "" : "s") : "No finished predictions yet")
    + (unsettled !== null && unsettled !== t.score ? " · " + signed(unsettled) + " unsettled" : "");
  $("#record").textContent = t.w + "–" + t.l + (t.t ? "–" + t.t : "");
  $("#recordSub").textContent = dec ? Math.round((t.w / dec) * 100) + "% right" + (t.t ? ", " + t.t + (t.t === 1 ? " tie" : " ties") : "") : "No decided calls yet";
  $("#inPlay").textContent = t.live;
  $("#inPlaySub").textContent = t.live ? pts(t.atStake) + " riding on them" : "Nothing open right now";
  const need = S.bets.filter((b) => needsMe(b) || canSign(b)).length;
  const nc = $("#needCount"); nc.hidden = !need; nc.textContent = need;
  const cc = S.bets.filter(crashable).length;
  const ce = $("#crashCount"); ce.hidden = !cc; ce.textContent = cc;
}

/* ---------- slips ---------- */
function dueText(b) {
  if (b.status === "proposed" && b.shakeBy && !expired(b)) {
    const soon = b.shakeBy - Date.now() < 6 * 3600e3;
    return `<span class="meta ${soon ? "late" : ""}">Shake by ${esc(deadlineText(b.shakeBy))} (${timeLeft(b.shakeBy)})</span>`;
  }
  if (!b.due) return "";
  const d = daysBetween(today(), b.due);
  if (b.status === "open" || b.status === "proposed") {
    if (d < 0) return `<span class="meta late">${-d} day${d === -1 ? "" : "s"} past due${b.parentId ? "" : ", record the result"}</span>`;
    if (d === 0) return `<span class="meta late">Decided today</span>`;
    if (d === 1) return `<span class="meta">Decided tomorrow</span>`;
    return `<span class="meta">Decided by ${niceDate(b.due)}</span>`;
  }
  return `<span class="meta">Due ${niceDate(b.due)}</span>`;
}
function statusChip(b) {
  if (needsMe(b)) {
    const t = { proposed: "Counter offer", open: "Record result", reported: "Confirm result", prove: "Post proof", proved: "Check the proof", referee: "Pick a winner" }[b.status] || "Sort it out";
    return `<span class="st need">${t}</span>`;
  }
  if (expired(b)) return `<span class="st done">Expired</span>`;
  if (canSign(b)) return `<span class="st need">${b.counter ? "Counter offer" : b.parentId ? "Crash offer" : "Shake on it!"}</span>`;
  if (waitingOnMyCounter(b)) return `<span class="st">You countered</span>`;
  return `<span class="st ${["settled", "void", "hopeless"].includes(b.status) ? "done" : ""}">${LABEL[b.status] || b.status}</span>`;
}
function sigLine(b, k) {
  const ok = k === "a" || b.b?.signed;
  const nm = nameOf(b, k);
  const label = k === "b" && b.b?.proxy && !b.b?.uid ? "in person" : b.parentId ? (k === "a" ? "crashed in" : "accepted") : k === "a" ? "called it" : "against";
  return `<div class="sig"><span class="hand ${ok ? "" : "blank"}">${ok ? esc(nm) : "no handshake yet"}</span><small>${label}</small></div>`;
}
function crashLine(b) {
  const ks = liveKids(b); if (!ks.length) return "";
  return `<div class="crashers">${ks.map((k) => `<span>${esc(nameOf(k, "a"))} crashed in backing ${esc(k.backsName || "")} · ${esc(stakeLabel(k))}${k.status === "proposed" ? " · waiting on " + esc(nameOf(k, "b")) : ""}</span>`).join("")}</div>`;
}
function notifyKind(b) {
  const s = negSide(b); if (!s) return null;
  if (expired(b)) return null;
  if (waitingOnMyCounter(b)) return "counter";
  if (b.status === "proposed" && s === "a") return "invite";
  if (b.status === "proposed") return null;
  if (b.status === "open") return "remind";
  if (b.status === "reported" && b.report?.by === s) return "confirm";
  if (b.status === "disputed") return "dispute";
  if (b.status === "prove") return s === challenger(b) ? "prove" : null;
  if (b.status === "proved") return s === poster(b) ? "proof" : null;
  if (b.status === "referee") return s === challenger(b) && b.referee ? "referee" : null;
  if (b.status === "settled") return "final";
  return null;
}
function notifyBtn(b) {
  const k = notifyKind(b); if (!k || S.notify?.id === b.id) return "";
  const who = k === "referee" ? b.referee.name : nameOf(b, other(negSide(b)));
  return `<button class="btn quiet" data-act="notify" data-id="${b.id}" data-k="${k}">${k === "referee" ? "Text " + esc(who) + " the link" : "Let " + esc(who) + " know"}</button>`;
}

/* ---------- Prove It! ---------- */
/* the recorded result, from the reader's point of view */
function claimText(b, s) {
  const w = b.report?.winner;
  if (w === "push") return "it's a tie";
  if (w === "void") return "it should be called off";
  return w && w === s ? "you won" : esc(nameOf(b, w || "a")) + " won";
}
const PROOF_MAX = 5 * 1024 * 1024;
/* the photo and video link, shown to the two sides and the referee */
function proofView(b) {
  if (!b.proof || !["proved", "referee", "settled", "hopeless"].includes(b.status)) return "";
  if (!side(b) && b.referee?.uid !== S.me) return "";
  let img = "";
  if (b.proof.path) {
    const url = S.proofUrls.get(b.proof.path);
    if (url === undefined) loadProofUrl(b.proof.path);
    img = url ? `<a href="${esc(url)}" target="_blank" rel="noopener"><img src="${esc(url)}" alt="Proof photo for ${esc(b.title)}" loading="lazy"></a>`
      : url === null ? `<span class="sub">The photo couldn't be loaded.</span>` : `<span class="sub">Loading the photo…</span>`;
  }
  let link = "";
  if (b.proof.link) {
    let host = ""; try { host = new URL(b.proof.link).hostname.replace(/^www\./, ""); } catch (e) {}
    link = `<a class="btn" href="${esc(b.proof.link)}" target="_blank" rel="noopener">Watch the video${host ? " · " + esc(host) : ""}</a>`;
  }
  const objection = b.objection && ["referee", "settled", "hopeless"].includes(b.status)
    ? `<p class="objection"><b>${esc(nameOf(b, challenger(b)))} says it doesn't hold up</b>${esc(b.objection)}</p>` : "";
  return `<div class="proof"><span class="lab">${esc(nameOf(b, poster(b)))}'s proof</span>${img}${link}${objection}</div>`;
}
async function loadProofUrl(path) {
  S.proofUrls.set(path, "");
  try {
    const { data, error } = await sb.storage.from("proof").createSignedUrl(path, 6 * 3600);
    S.proofUrls.set(path, error ? null : data.signedUrl);
  } catch (e) { S.proofUrls.set(path, null); }
  render();
}
function proofPanel(b) {
  const d = S.proofDraft;
  return `<div class="cpanel">
    <span class="lab">Post your proof</span>
    <div class="acts"><label class="btn" for="proofFile">${d.blob ? "Choose a different photo" : "Choose a photo"}</label>
      <input id="proofFile" type="file" accept="image/*" hidden>${d.blob ? `<button class="btn quiet" data-act="dropPhoto">Remove photo</button>` : ""}</div>
    ${d.busy ? `<span class="sub">Getting the photo ready…</span>` : ""}
    ${d.preview ? `<img class="proof-preview" src="${esc(d.preview)}" alt="Your proof photo">` : ""}
    <div class="field"><label for="proofLink">Video link <span class="hint">optional</span></label>
      <input id="proofLink" type="url" inputmode="url" autocomplete="off" placeholder="https://share.icloud.com/…" value="${esc(d.link || "")}"></div>
    <span class="sub">A photo (up to 5 MB), a video link, or both. For video, share it from Photos as an iCloud link, or paste a Google Photos, YouTube or Dropbox link. Anyone with a video link can open it.</span>
    <p class="err" id="proofErr" hidden></p>
    <div class="acts"><button class="btn primary" data-act="sendProof" data-id="${b.id}" ${d.busy || S.busy.has(b.id) ? "disabled" : ""}>Send proof</button><button class="btn ghost" data-act="unprove">Cancel</button></div>
  </div>`;
}
function objectPanel(b) {
  return `<div class="cpanel">
    <span class="lab">Why doesn't it hold up?</span>
    <div class="field"><label for="objText">Tell the referee</label><textarea id="objText" maxlength="280" placeholder="That photo is from last season.">${esc(S.objDraft)}</textarea></div>
    <span class="sub">Handshake picks a referee: the other person in the most recent finished prediction with either of you. They get 24 hours to pick the winner, or it's Hopeless.</span>
    <p class="err" id="objErr" hidden></p>
    <div class="acts"><button class="btn danger" data-act="sendObject" data-id="${b.id}" ${S.busy.has(b.id) ? "disabled" : ""}>Send it to a referee</button><button class="btn ghost" data-act="unobject">Cancel</button></div>
  </div>`;
}
/* Shrink a photo to JPEG, at most 2000 px on the long side, so almost every photo fits under 5 MB.
   This also turns iPhone HEIC photos into something every phone and browser can show. */
function loadImage(file) {
  return new Promise((ok, fail) => {
    const url = URL.createObjectURL(file), img = new Image();
    img.onload = () => { URL.revokeObjectURL(url); ok(img); };
    img.onerror = () => { URL.revokeObjectURL(url); fail(new Error("unreadable")); };
    img.src = url;
  });
}
async function shrinkPhoto(file) {
  let img;
  try { img = await loadImage(file); } catch (e) { return file.size <= PROOF_MAX && /^image\/(jpeg|png|webp|gif|heic|heif)$/.test(file.type) ? file : null; }
  for (const [side_, q] of [[2000, 0.82], [1600, 0.75], [1200, 0.7]]) {
    const k = Math.min(1, side_ / Math.max(img.naturalWidth, img.naturalHeight));
    const c = document.createElement("canvas");
    c.width = Math.max(1, Math.round(img.naturalWidth * k)); c.height = Math.max(1, Math.round(img.naturalHeight * k));
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const blob = await new Promise((r) => c.toBlob(r, "image/jpeg", q));
    if (blob && blob.size <= PROOF_MAX) return blob;
  }
  return null;
}
async function pickProofFile(input) {
  const file = input.files?.[0]; if (!file) return;
  if (S.proofDraft.preview) URL.revokeObjectURL(S.proofDraft.preview);
  S.proofDraft = { ...S.proofDraft, blob: null, preview: null, busy: true }; render();
  const blob = await shrinkPhoto(file);
  S.proofDraft.busy = false;
  if (!blob) { S.proofDraft.err = "That photo is too big or couldn't be read. Try a screenshot of it, or a different photo."; render(); showProofErr(); return; }
  S.proofDraft.blob = blob; S.proofDraft.preview = URL.createObjectURL(blob); S.proofDraft.err = ""; render();
}
function showProofErr(m) {
  const e = $("#proofErr"); const msg = m || S.proofDraft.err; if (e && msg) { e.textContent = msg; e.hidden = false; }
}
async function sendProof(b) {
  const d = S.proofDraft, link = ($("#proofLink")?.value ?? d.link ?? "").trim();
  if (!d.blob && !link) return showProofErr("Add a photo or a video link.");
  if (link) {
    let ok = false; try { const u = new URL(link); ok = /^https?:$/.test(u.protocol) && u.hostname.includes("."); } catch (e) {}
    if (!ok) return showProofErr("That video link doesn't look right. Paste the full link, starting with https://");
  }
  if (S.busy.has(b.id)) return;
  let path = null;
  if (d.blob) {
    S.busy.add(b.id); render();
    const type = d.blob.type || "image/jpeg", ext = { "image/png": "png", "image/webp": "webp", "image/gif": "gif", "image/heic": "heic", "image/heif": "heif" }[type] || "jpg";
    path = `${b.id}/${Date.now()}.${ext}`;
    const { error } = await sb.storage.from("proof").upload(path, d.blob, { contentType: type, upsert: false });
    S.busy.delete(b.id);
    if (error) { render(); return showProofErr(/size|large|exceed/i.test(error.message || "") ? "That photo is over 5 MB. Try a different one." : "The photo didn't upload. Check your connection and try again."); }
  }
  const ok = await call("submit_proof", { p_id: b.id, p_path: path, p_link: link || null }, "Proof posted. " + nameOf(b, challenger(b)) + " has 24 hours to answer.", b.id);
  if (ok) {
    if (d.preview) URL.revokeObjectURL(d.preview);
    S.proving = null; S.proofDraft = {}; S.notify = { id: b.id, kind: "proof" }; render();
  }
}
async function sendObject(b) {
  const why = ($("#objText")?.value ?? S.objDraft).trim();
  if (!why) { const e = $("#objErr"); if (e) { e.textContent = "Say why the proof doesn't hold up."; e.hidden = false; } return; }
  if (S.busy.has(b.id)) return;
  S.busy.add(b.id); render();
  try {
    const { data, error } = await sb.rpc("answer_proof", { p_id: b.id, p_accept: false, p_reason: why });
    if (error) throw error;
    announce(b.id);
    S.objecting = null; S.objDraft = "";
    await loadBets(); await loadPhones();
    const nb = byId(b.id);
    if (data === "referee" && nb?.referee) { toast(nb.referee.name + " is refereeing. Text them the link so they see it."); S.notify = { id: b.id, kind: "referee" }; }
    else toast("Hopeless. There's no one to referee this one, so no points move.");
  } catch (e) { toast(friendly(e)); }
  finally { S.busy.delete(b.id); render(); }
}

/* ---------- who can see it ---------- */
const VIS = {
  all: ["Full Monty", "Everyone on Handshake can see it and crash it."],
  circle: ["Circle of Trust", "Only the two of you and people either of you has played before can see it and crash it."],
  pair: ["Just the Two of Us", "Only the two of you can see it. Nobody can crash it."],
};
const visTag = (b) => (b.visibility && b.visibility !== "all" ? `<span class="tagv" title="${esc(VIS[b.visibility][1])}">${esc(VIS[b.visibility][0])}</span>` : "");
function setVis(v) {
  S.vis = VIS[v] ? v : "all";
  document.querySelectorAll('[data-act="setVis"]').forEach((x) => x.setAttribute("aria-pressed", x.dataset.v === S.vis));
  $("#visHelp").textContent = VIS[S.vis][1];
}

function slip(b) {
  const s = side(b), o = s ? other(s) : null, p = stakeOf(b);
  const them = s ? esc(nameOf(b, o)) : null;
  let stamp = "";
  if (b.status === "settled") {
    if (b.winner === "push") stamp = `<div class="stamp grey">TIE</div>`;
    else if (s) stamp = b.winner === s ? `<div class="stamp win">${isOther(b) ? "WON" : "+" + p}</div>` : `<div class="stamp">${isOther(b) ? "LOST" : "−" + p}</div>`;
    else stamp = `<div class="stamp grey">FINAL</div>`;
  } else if (b.status === "void") stamp = `<div class="stamp grey">CALLED OFF</div>`;
  else if (b.status === "hopeless") stamp = `<div class="stamp grey">HOPELESS</div>`;
  let note = "", acts = "";
  const busy = S.busy.has(b.id) ? "disabled" : "";
  const pick = S.picking === b.id;

  switch (b.status) {
    case "proposed":
      if (expired(b)) {
        note = `This invite expired on ${deadlineText(b.shakeBy)}. Nobody shook on it in time.`;
        if (s === "a" && !b.parentId) acts = S.extending === b.id ? "" : `<button class="btn primary" data-act="extend" data-id="${b.id}">Set a new shake-by time</button><button class="btn quiet danger" data-act="withdraw" data-id="${b.id}" ${busy}>Withdraw</button>`;
      } else if (b.counter) {
        const ns = negSide(b), c = esc(counterLabel(b.counter)), was = esc(stakeLabel(b));
        const caller = esc(nameOf(b, "a")), invitee = esc(nameOf(b, "b"));
        if (ns && ns !== b.counter.by) {
          const from = b.counter.by === "b" ? invitee : caller;
          note = `<b>${from}</b> ${b.counter.by === "b" ? "will take the other side" : "countered back"} for <b>${c}</b> instead of ${was}.`;
          acts = S.countering === b.id ? "" : `<button class="btn primary" data-act="acceptCounter" data-id="${b.id}" ${busy}>Accept ${c}</button><button class="btn" data-act="counter" data-id="${b.id}" ${busy}>Counter</button>`
            + (ns === "a" ? `<button class="btn quiet danger" data-act="withdraw" data-id="${b.id}" ${busy}>Call it off</button>` : `<button class="btn quiet danger" data-act="decline" data-id="${b.id}" ${busy}>Decline</button>`);
        } else if (ns) {
          note = `You offered <b>${c}</b> instead of ${was}. Waiting for <b>${ns === "a" ? invitee : caller}</b> to answer.`;
          acts = `${notifyBtn(b)}<button class="btn quiet" data-act="withdrawCounter" data-id="${b.id}" ${busy}>Take back counter</button>`;
        } else note = `${b.counter.by === "b" ? invitee : caller} offered different stakes. Waiting on the other side.`;
      } else if (b.parentId && s === "a") {
        note = `You're crashing No. ${shortNo(b.parentId)}, backing <b>${esc(b.backsName || "")}</b>. Waiting for <b>${them}</b> to accept.`;
        acts = `${notifyBtn(b)}<button class="btn quiet danger" data-act="withdraw" data-id="${b.id}" ${busy}>Withdraw offer</button>`;
      } else if (b.parentId && canSign(b)) {
        note = `<b>${esc(nameOf(b, "a"))}</b> wants in on No. ${shortNo(b.parentId)}, backing <b>${esc(b.backsName || "")}</b> against you. Accept and this rides on the same result.`;
        acts = S.countering === b.id ? "" : `<button class="btn primary" data-act="sign" data-id="${b.id}" ${busy}>Accept the crash</button><button class="btn" data-act="counter" data-id="${b.id}" ${busy}>Counter stakes</button><button class="btn quiet danger" data-act="decline" data-id="${b.id}" ${busy}>Decline</button>`;
      } else if (s === "a") {
        note = `Waiting for <b>${them}</b> to shake on it. Send them the link, or tap "We shook on it" if you agreed in person.`;
        acts = S.fixing === b.id ? "" : `<button class="btn" data-act="shook" data-id="${b.id}" ${busy}>We shook on it</button>${notifyBtn(b)}<button class="btn quiet" data-act="fix" data-id="${b.id}">Fix name or number</button><button class="btn quiet danger" data-act="withdraw" data-id="${b.id}" ${busy}>Withdraw</button>`;
      } else if (canSign(b)) {
        note = `<b>${esc(nameOf(b, "a"))}</b> made this call against <b>${esc(nameOf(b, "b"))}</b>. It's waiting on your handshake.`;
        acts = S.countering === b.id ? "" : `<button class="btn primary" data-act="sign" data-id="${b.id}" ${busy}>Shake on it!</button><button class="btn" data-act="counter" data-id="${b.id}" ${busy}>Counter stakes</button><button class="btn quiet danger" data-act="decline" data-id="${b.id}" ${busy}>Decline</button>`;
      }
      break;
    case "open":
      if (b.parentId) { note = `Rides on No. ${shortNo(b.parentId)}. It's done and done automatically when that one's result is confirmed.`; if (s) acts = notifyBtn(b); }
      else if (s && !pick) acts = `<button class="btn ${needsMe(b) ? "primary" : ""}" data-act="pick" data-id="${b.id}" ${busy}>Record result</button>${notifyBtn(b)}`;
      break;
    case "reported": {
      const r = b.report, by = esc(nameOf(b, r.by));
      const what = (w) => (w === "push" ? "it's a tie" : w === "void" ? "to call it off" : w === s ? "you won" : esc(nameOf(b, w)) + " won");
      if (s && r.by !== s) {
        const canProve = r.winner !== s;
        const window_ = b.disputeBy ? ` You have until <b>${esc(deadlineText(b.disputeBy))}</b> (${timeLeft(b.disputeBy)}) to ${canProve ? "confirm it or make them prove it" : "confirm it"}. After that, it counts.` : "";
        note = `<b>${by}</b> says ${r.winner === "void" ? "call it off" : what(r.winner)}.${window_}`;
        acts = `<button class="btn primary" data-act="confirm" data-id="${b.id}" ${busy}>Confirm</button>${canProve ? `<button class="btn danger" data-act="proveIt" data-id="${b.id}" ${busy}>Prove it!</button>` : ""}`;
      } else if (s) {
        note = `You said ${what(r.winner)}. Waiting for ${them} to confirm.${b.disputeBy ? ` If ${them} doesn't say prove it, it counts on ${esc(deadlineText(b.disputeBy))}.` : ""}`;
        acts = notifyBtn(b) + (!b[o]?.uid ? `<button class="btn" data-act="confirm" data-id="${b.id}" ${busy}>${them} agreed in person</button>` : "") + `<button class="btn quiet" data-act="pick" data-id="${b.id}">Change result</button>`;
      } else note = `${by} recorded a result. Waiting on the other side.`;
      if (pick) acts = "";
      break;
    }
    case "disputed":
      note = `<b>Disputed.</b> ${esc(nameOf(b, b.report?.by || "a"))}'s call wasn't accepted. Talk it out, then record the result again.`;
      if (s && !pick) acts = `${notifyBtn(b)}<button class="btn primary" data-act="pick" data-id="${b.id}" ${busy}>Record result again</button><button class="btn quiet" data-act="callOff" data-id="${b.id}" ${busy}>Call it off</button>`;
      break;
    case "prove": {
      const pz = esc(nameOf(b, poster(b))), cz = esc(nameOf(b, challenger(b)));
      const until = b.stepBy ? `<b>${esc(deadlineText(b.stepBy))}</b> (${timeLeft(b.stepBy)})` : "the deadline";
      if (s && s === poster(b)) {
        note = `<b>${cz}</b> says prove it. You said ${claimText(b, s)}. Post a photo or a video link by ${until}, or <b>${cz}</b> wins.`;
        if (S.proving !== b.id) acts = `<button class="btn primary" data-act="prove" data-id="${b.id}" ${busy}>Post proof</button>`;
      } else if (s) {
        note = `You said prove it. <b>${pz}</b> has until ${until} to post proof. If nothing comes in, you win.`;
        acts = notifyBtn(b);
      } else note = `${cz} said prove it. Waiting on ${pz}'s proof.`;
      break;
    }
    case "proved": {
      const pz = esc(nameOf(b, poster(b))), cz = esc(nameOf(b, challenger(b)));
      const until = b.stepBy ? `<b>${esc(deadlineText(b.stepBy))}</b> (${timeLeft(b.stepBy)})` : "the deadline";
      if (s && s === challenger(b)) {
        note = `<b>${pz}</b> posted proof that ${claimText(b, s)}. You have until ${until} to accept it or say why it doesn't hold up. After that, it counts.`;
        if (S.objecting !== b.id) acts = `<button class="btn primary" data-act="acceptProof" data-id="${b.id}" ${busy}>Accept the proof</button><button class="btn danger" data-act="object" data-id="${b.id}" ${busy}>It doesn't hold up</button>`;
      } else if (s) {
        note = `Proof posted. Waiting for <b>${cz}</b> to accept it. If ${cz} doesn't answer, it counts on ${until}.`;
        acts = notifyBtn(b);
      } else note = `${pz} posted proof. Waiting on ${cz}.`;
      break;
    }
    case "referee": {
      const pz = esc(nameOf(b, poster(b))), cz = esc(nameOf(b, challenger(b))), rz = esc(b.referee?.name || "The referee");
      const until = b.stepBy ? `<b>${esc(deadlineText(b.stepBy))}</b> (${timeLeft(b.stepBy)})` : "the deadline";
      if (isRef(b)) {
        note = `<b>You're the referee.</b> ${pz} says ${claimText(b, null)}. ${cz} says the proof doesn't hold up. Pick the winner by ${until}, or it's Hopeless.`;
        acts = `<button class="btn" data-act="refPick" data-w="a" data-id="${b.id}" ${busy}>${esc(nameOf(b, "a"))} won</button><button class="btn" data-act="refPick" data-w="b" data-id="${b.id}" ${busy}>${esc(nameOf(b, "b"))} won</button><button class="btn" data-act="refPick" data-w="push" data-id="${b.id}" ${busy}>Tie</button>`;
      } else if (s) {
        note = `<b>${rz}</b> is refereeing. ${rz} has until ${until} to pick the winner, or it's Hopeless.`;
        acts = notifyBtn(b);
      } else note = `${rz} is refereeing this one.`;
      break;
    }
    case "hopeless":
      note = b.referee ? `<b>Hopeless.</b> ${esc(b.referee.name)} didn't pick a winner in time. No points moved, and it doesn't count in anyone's record.`
        : `<b>Hopeless.</b> There was no one to referee. No points moved, and it doesn't count in anyone's record.`;
      break;
    case "settled":
      if (s) acts = notifyBtn(b);
      if (b.winner === "push") note = "Ended in a tie. No points moved.";
      else if (isOther(b)) {
        const wn = esc(nameOf(b, b.winner)), ln = esc(nameOf(b, other(b.winner)));
        note = s ? (b.winner === s ? `You were right. ${ln} owes you: <b>${esc(stakeLabel(b))}</b>` : `${wn} had it right. You owe: <b>${esc(stakeLabel(b))}</b>`) : `${wn} won. ${ln} owes: ${esc(stakeLabel(b))}`;
      } else if (s) note = b.winner === s ? `You were right. ${pts(p)} from ${them}.` : `${them} had it right. ${pts(p)} to ${them}.`;
      else note = `${esc(nameOf(b, b.winner))} took ${pts(p)} from ${esc(nameOf(b, other(b.winner)))}.`;
      break;
  }

  let picker = "";
  if (pick && s) {
    picker = `<div class="picker"><span class="lab">Who called it?</span><div class="acts">
      <button class="btn" data-act="report" data-w="${s}" data-id="${b.id}">I did</button>
      <button class="btn" data-act="report" data-w="${o}" data-id="${b.id}">${them}</button>
      <button class="btn" data-act="report" data-w="push" data-id="${b.id}">Tie</button>
      <button class="btn" data-act="report" data-w="void" data-id="${b.id}">Call it off</button></div>
      ${siblings(b).length ? `<label class="check"><input type="checkbox" id="allSibs" checked><span>Record the same result against ${esc(listNames(siblings(b).map((x) => nameOf(x, other(side(x))))))} too</span></label>` : ""}
      <span class="sub">${siblings(b).length ? "Each person" : them} confirms before any points move.</span>
      <div><button class="btn quiet" data-act="unpick">Cancel</button></div></div>`;
  }
  const cls = "slip" + (needsMe(b) || canSign(b) ? " attn" : "") + (stamp ? " has-stamp" : "") + (S.fresh === b.id ? " newly" : "");
  return `<article class="${cls}" id="bet-${b.id}">
    ${stamp}
    <div class="slip-top"><span class="no">No. ${esc(shortNo(b.id))}</span><span class="cat">${esc(b.category || "Other")}</span>${visTag(b)}${b.parentId ? `<span class="tagc">Crash on No. ${shortNo(b.parentId)}</span>` : ""}${statusChip(b)}</div>
    <h3>${esc(b.title)}</h3>${crashLine(b)}
    ${b.terms ? `<p class="terms">${esc(b.terms)}</p>` : ""}
    <div class="row">${b.counter && b.status === "proposed"
      ? `<span class="was">${esc(stakeLabel(b))}</span><span class="ctr">Counter</span><span class="stake ${b.counter.kind === "other" ? "text" : ""}">${esc(counterLabel(b.counter))}</span>`
      : isOther(b) ? `<span class="stake text">${esc(stakeLabel(b))}</span>` : `<span class="stake">${p} <small>pts on the line</small></span>`}${dueText(b)}</div>
    <div class="sigs">${sigLine(b, "a")}${sigLine(b, "b")}</div>
    ${note ? `<div class="note">${note}</div>` : ""}
    ${acts ? `<div class="acts">${acts}</div>` : ""}
    ${picker}
    ${S.countering === b.id ? counterPanel(b) : ""}
    ${S.fixing === b.id ? fixPanel(b) : ""}
    ${S.extending === b.id ? extendPanel(b) : ""}
    ${proofView(b)}
    ${S.proving === b.id && b.status === "prove" ? proofPanel(b) : ""}
    ${S.objecting === b.id && b.status === "proved" ? objectPanel(b) : ""}
    ${S.notify?.id === b.id && negSide(b) ? notifyPanel(b) : ""}
  </article>`;
}

function counterPanel(b) {
  const d = S.counterDraft;
  const kind = d.kind || (b.counter ? b.counter.kind : b.stakeKind) || "points";
  const ptsVal = d.pts ?? (b.counter?.kind === "points" ? b.counter.points : stakeOf(b) || 10);
  const txtVal = d.text ?? (b.counter?.kind === "other" ? b.counter.text : isOther(b) ? b.stakeText : "");
  return `<div class="cpanel">
    <span class="lab">Counter with different stakes</span>
    <span class="sub">On the table now: ${esc(b.counter ? counterLabel(b.counter) : stakeLabel(b))}</span>
    <div class="seg" role="group" aria-label="Stake type">
      <button type="button" aria-pressed="${kind === "points"}" data-act="cseg" data-v="points">Points</button>
      <button type="button" aria-pressed="${kind === "other"}" data-act="cseg" data-v="other">Other</button>
    </div>
    ${kind === "points"
      ? `<div class="field"><label for="cPts">Your points</label><input id="cPts" type="number" inputmode="numeric" min="1" max="1000" step="1" value="${esc(ptsVal)}"></div>`
      : `<div class="field"><label for="cText">What the loser owes</label><input id="cText" maxlength="60" placeholder="Loser buys the first round" value="${esc(txtVal)}" autocomplete="off"></div>`}
    <p class="err" id="counterErr" hidden></p>
    <div class="acts"><button class="btn primary" data-act="sendCounter" data-id="${b.id}">Send counter</button><button class="btn ghost" data-act="uncounter">Cancel</button></div>
  </div>`;
}
function extendPanel(b) {
  return `<div class="cpanel">
    <span class="lab">New shake-by time</span>
    <div class="field"><label for="xShakeBy">Shake by</label><input id="xShakeBy" type="datetime-local" value="${localInput(Date.now() + DAY)}"></div>
    <p class="err" id="extendErr" hidden></p>
    <div class="acts"><button class="btn primary" data-act="saveExtend" data-id="${b.id}">Save</button><button class="btn ghost" data-act="unextend">Cancel</button></div>
  </div>`;
}
/* value for a datetime-local input, in local time, rounded up to the next quarter hour */
function localInput(ms) {
  const d = new Date(Math.ceil(ms / 900000) * 900000);
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function readShakeBy(id) {
  const v = $(id)?.value; if (!v) return null;
  const ms = new Date(v).getTime(); return Number.isFinite(ms) ? ms : null;
}
async function saveExtend(b) {
  const err = (m) => { const e = $("#extendErr"); if (e) { e.textContent = m; e.hidden = false; } };
  const ms = readShakeBy("#xShakeBy");
  if (!ms || ms <= Date.now() + 60000) return err("Pick a time that hasn't passed yet.");
  const ok = await call("set_shake_by", { p_id: b.id, p_shake_by: new Date(ms).toISOString() }, "New deadline set. Send them a fresh invite.", b.id);
  if (ok) { S.extending = null; S.notify = { id: b.id, kind: "invite" }; render(); }
}
function fixPanel(b) {
  const num = store.get(phoneKey(nameOf(b, "b"))) || "";
  return `<div class="cpanel">
    <span class="lab">Fix who it's for</span>
    <div class="field"><label for="xName">Their name</label><input id="xName" maxlength="30" value="${esc(nameOf(b, "b"))}" autocomplete="off"></div>
    <div class="field"><label for="xPhone">Their mobile number</label><input id="xPhone" type="tel" inputmode="tel" autocomplete="off" placeholder="(555) 123-4567" value="${esc(num ? prettyPhone(num) : "")}"></div>
    <span class="sub">Only this number can shake on it. Send them a fresh invite after you save.</span>
    <p class="err" id="fixErr" hidden></p>
    <div class="acts"><button class="btn primary" data-act="saveFix" data-id="${b.id}">Save</button><button class="btn ghost" data-act="unfix">Cancel</button></div>
  </div>`;
}
async function saveFix(b) {
  const err = (m) => { const e = $("#fixErr"); if (e) { e.textContent = m; e.hidden = false; } };
  const name = $("#xName").value.trim(), phone = normPhone($("#xPhone").value);
  if (!name) return err("Add their name.");
  if (!phone) return err("Enter a 10-digit US number, or a + and country code for other countries.");
  const ok = await call("fix_invite", { p_id: b.id, p_name: name, p_phone: phone }, "Saved. Now send " + name + " the invite.", b.id);
  if (ok) { store.set(phoneKey(name), phone); S.fixing = null; S.notify = { id: b.id, kind: "invite" }; render(); }
}
async function sendCounter(b) {
  const err = (m) => { const e = $("#counterErr"); if (e) { e.textContent = m; e.hidden = false; } };
  const d = S.counterDraft;
  const kind = d.kind || (b.counter ? b.counter.kind : b.stakeKind) || "points";
  let p = 0, txt = "";
  if (kind === "points") {
    p = Math.round(parseFloat($("#cPts")?.value ?? d.pts));
    if (!(p >= 1 && p <= 1000)) return err("Put between 1 and 1,000 points on the line.");
  } else {
    txt = ($("#cText")?.value ?? d.text ?? "").trim();
    if (!txt) return err("Say what the loser owes, like “Loser buys the first round.”");
  }
  const them = nameOf(b, other(negSide(b) || "b"));
  const ok = await call("counter_offer", { p_id: b.id, p_kind: kind, p_points: p, p_text: txt }, "Counter sent. " + them + " answers next.", b.id);
  if (ok) { S.countering = null; S.counterDraft = {}; S.notify = { id: b.id, kind: "counter" }; render(); }
}

/* ---------- messages to friends ---------- */
function message(b, kind) {
  const s = negSide(b), o = other(s), them = nameOf(b, o), st = stakeLabel(b), t = `"${b.title}"`;
  const due = b.due ? `, decided by ${niceDate(b.due)}` : "";
  const claim = (w) => (w === "push" ? "it's a tie" : w === "void" ? "we call it off" : w === s ? "I called it" : "you called it");
  let subject, body;
  switch (kind) {
    case "invite":
      if (b.parentId) { subject = `Handshake: I want in on ${t}`; body = `${them}, I want in on ${t}. I'm backing ${b.backsName || "the other side"} against you for ${st}. Accept or decline on Handshake:`; }
      else {
        subject = `Handshake: shake on ${t}`;
        const newbie = !b.b?.invited && !b.b?.uid;
        const until = b.shakeBy ? ` You have until ${deadlineText(b.shakeBy)}.` : "";
        body = `${them}, I'm calling it: ${t} for ${st}${due}.${until} ${newbie ? "Sign up on Handshake with this phone number:" : "It's on Handshake:"} ${PAGE_URL} I'll be waiting for you to shake on it.`;
        return { subject, body, to: them };
      }
      break;
    case "counter":
      subject = `Handshake: counter offer on ${t}`;
      body = s === "b"
        ? `${them}, I'll take the other side of ${t}, but for ${counterLabel(b.counter)} instead of ${st}. Accept or counter on Handshake:`
        : `${them}, how about ${counterLabel(b.counter)} instead on ${t}? Accept or counter on Handshake:`;
      break;
    case "confirm": subject = `Handshake: confirm the result of ${t}`; body = `${them}, I recorded the result of ${t}: ${claim(b.report?.winner)}.${b.disputeBy ? ` You have until ${deadlineText(b.disputeBy)} to dispute it. After that, it counts.` : ""} Confirm or dispute it on Handshake:`; break;
    case "dispute": subject = `Handshake: ${t} is disputed`; body = `${them}, I disputed the result of ${t}. Let's sort it out, then one of us can record it again:`; break;
    case "prove": subject = `Handshake: prove it on ${t}`; body = `${them}, prove it. Post a photo or a video link for ${t} on Handshake${b.stepBy ? " by " + deadlineText(b.stepBy) : ""}, or I win:`; break;
    case "proof": subject = `Handshake: proof is up on ${t}`; body = `${them}, my proof for ${t} is up.${b.stepBy ? " You have until " + deadlineText(b.stepBy) + " to accept it or say why it doesn't hold up. After that, it counts." : ""} Take a look on Handshake:`; break;
    case "referee": {
      const ref = b.referee?.name || "Hey";
      subject = `Handshake: you're the referee on ${t}`;
      body = `${ref}, you've been picked to referee ${nameOf(b, "a")} vs ${nameOf(b, "b")} on ${t}. Look at the proof and pick the winner on Handshake${b.stepBy ? " by " + deadlineText(b.stepBy) : ""}. If no one's picked, it's Hopeless:`;
      return { subject, body: body + " " + PAGE_URL, to: ref };
    }
    case "final":
      subject = `Handshake: final on ${t}`;
      if (b.winner === "push") body = `Final on ${t}: it's a tie, nothing changes hands. Rematch?`;
      else if (b.winner === s) body = `Final on ${t}: I called it. ${isOther(b) ? "You owe me: " + st + "." : st + " to me."} Rematch?`;
      else body = `Final on ${t}: you called it. ${isOther(b) ? "I owe you: " + st + "." : st + " to you."} Well played.`;
      break;
    default: subject = `Handshake: ${t}`; body = `${them}, reminder: ${t} for ${st}${due}. It's on Handshake:`;
  }
  return { subject, body: body + " " + PAGE_URL, to: them };
}
const phoneKey = (n) => "hs-phone:" + n.toLowerCase();
function smsHref(num, body) {
  const ios = /iPad|iPhone|iPod|Macintosh/.test(navigator.userAgent);
  return "sms:" + encodeURIComponent(num || "").replace(/%2B/g, "+") + (ios ? "&" : "?") + "body=" + encodeURIComponent(body);
}
function notifyPanel(b) {
  const m = message(b, S.notify.kind);
  const num = (S.notify.kind === "referee" ? S.refPhones.get(b.id) : S.phones.get(b.id)) || store.get(phoneKey(m.to)) || "";
  const invite = S.notify.kind === "invite";
  return `<div class="npanel"><span class="lab">${invite ? "Invite " + esc(m.to) : "Let " + esc(m.to) + " know"}</span>
    <p class="msg" id="msgText">${esc(m.body)}</p>
    <div class="acts">
      <button class="btn primary" data-act="copyMsg" data-id="${b.id}">${invite ? "Copy invite" : "Copy message"}</button>
      <a class="btn" id="smsLink" href="${esc(smsHref(num, m.body))}">Open Messages</a>
      <button class="btn ghost" data-act="unnotify">Close</button>
    </div>
    <span class="sub">Copy it, then paste it into a text to ${esc(m.to)}${num ? " at " + esc(prettyPhone(num)) : ""}.</span></div>`;
}

/* ---------- board views ---------- */
const FILTERS = [["all", "All"], ["needs", "Needs you"], ["live", "In play"], ["done", "Done and done"], ["void", "Called off"]];
function inFilter(b, f) {
  if (f === "needs") return needsMe(b) || canSign(b);
  if (f === "live") return isLive(b);
  if (f === "done") return b.status === "settled";
  if (f === "void") return b.status === "void" || b.status === "hopeless" || expired(b);
  return true;
}
const rank = (b) => (needsMe(b) || canSign(b) ? 0 : isLive(b) ? 1 : 2);
function sorted(list) {
  const by = {
    newest: (a, b) => (b.createdAt || 0) - (a.createdAt || 0),
    due: (a, b) => (a.due || "9999").localeCompare(b.due || "9999"),
    stake: (a, b) => stakeOf(b) - stakeOf(a),
    needs: (a, b) => rank(a) - rank(b) || (b.createdAt || 0) - (a.createdAt || 0),
  }[S.sort] || (() => 0);
  return list.slice().sort(by);
}
function renderBoard() {
  const MINE = mineList();
  if (!MINE.length) {
    return `<div class="empty"><h3>No predictions yet</h3><p>Make the first call, or crash someone else's from the Everyone tab. Your predictions show here once they're made, ready for both sides to shake on.</p><button class="btn primary" data-act="new">Make a prediction</button></div>`;
  }
  const list = sorted(MINE.filter((b) => inFilter(b, S.filter)));
  const chips = FILTERS.map(([k, l]) => `<button class="chipbtn" aria-pressed="${S.filter === k}" data-act="filter" data-v="${k}">${l} <span class="mono">${MINE.filter((b) => inFilter(b, k)).length}</span></button>`).join("");
  const sel = `<select id="sortSel" aria-label="Sort predictions">${[["needs", "Needs you first"], ["newest", "Newest first"], ["due", "Due soonest"], ["stake", "Most points"]].map(([k, l]) => `<option value="${k}" ${S.sort === k ? "selected" : ""}>${l}</option>`).join("")}</select>`;
  return `<div style="display:flex;flex-direction:column;gap:14px">${groupInviteBox()}<div class="filters">${chips}${sel}</div>
    <div class="list">${list.length ? list.map(slip).join("") : `<div class="empty"><p>Nothing here right now.</p></div>`}</div></div>`;
}
function feedCard(b) {
  const p = stakeOf(b);
  const vs = b.parentId
    ? `<b>${esc(nameOf(b, "a"))}</b> crashed in backing ${esc(b.backsName || "")}, against <b>${esc(nameOf(b, "b"))}</b>`
    : `<b>${esc(nameOf(b, "a"))}</b> called it. <b>${esc(nameOf(b, "b"))}</b> took the other side.`;
  let tail = "";
  if (S.crashing === b.id && crashable(b)) tail = crashPanel(b);
  else if (crashable(b)) tail = `<div class="acts"><button class="btn primary" data-act="crash" data-id="${b.id}">Crash it</button><span class="sub">Back either side and get in on the action.</span></div>`;
  else if (["proposed", "open"].includes(b.status) && !b.parentId && side(b)) tail = `<span class="sub">You're in this one.</span>`;
  else if (["proposed", "open"].includes(b.status) && !b.parentId && liveKids(b).some((k) => k.a?.uid === S.me)) tail = `<span class="sub">You already crashed this one.</span>`;
  return `<article class="fcard ${b.parentId ? "crash" : ""}">
    <div class="slip-top"><span class="no">No. ${esc(shortNo(b.id))}</span><span class="cat">${esc(b.category || "Other")}</span>${visTag(b)}${b.parentId ? `<span class="tagc">Crash on No. ${shortNo(b.parentId)}</span>` : ""}${statusChip(b)}</div>
    <h3>${esc(b.title)}</h3>
    <div class="vs">${vs}</div>
    <div class="row">${isOther(b) ? `<span class="stake text">${esc(stakeLabel(b))}</span>` : `<span class="stake" style="font-size:16px">${p} <small>pts</small></span>`}${dueText(b)}</div>
    ${b.parentId ? "" : crashLine(b)}
    ${tail}
  </article>`;
}
function crashPanel(b) {
  const d = S.crashDraft, sd = S.crashSide;
  const names = { a: esc(nameOf(b, "a")), b: esc(nameOf(b, "b")) };
  return `<div class="cpanel">
    <span class="lab">Who are you backing?</span>
    <div class="seg" role="group" aria-label="Side to back">
      <button type="button" aria-pressed="${sd === "a"}" data-act="crashSide" data-v="a">${names.a}'s call</button>
      <button type="button" aria-pressed="${sd === "b"}" data-act="crashSide" data-v="b">${names.b}'s side</button>
    </div>
    ${sd ? `<span class="sub">You'd be up against ${sd === "a" ? names.b : names.a}. They accept before it's on.</span>` : ""}
    ${isOther(b) ? `<div class="field"><span class="lbl">Stakes</span><span class="stake text">${esc(stakeLabel(b))}</span></div>`
      : `<div class="field"><label for="crashPts">Your points</label><input id="crashPts" type="number" inputmode="numeric" min="1" max="1000" step="1" value="${esc(d.pts ?? stakeOf(b))}"></div>`}
    <p class="err" id="crashErr" hidden></p>
    <div class="acts"><button class="btn primary" data-act="sendCrash" data-id="${b.id}">Send crash offer</button><button class="btn ghost" data-act="uncrash">Cancel</button></div>
  </div>`;
}
const FEED_FILTERS = [["crash", "Open to crash"], ["live", "In play"], ["all", "Everything"]];
function renderFeed() {
  const bets = S.bets.filter((b) => !b.pickem && !b.wolf);
  if (!bets.length) return `<div style="display:flex;flex-direction:column;gap:22px">${pkSection()}<div class="empty"><h3>Nothing on the board yet</h3><p>Every Full Monty prediction shows up here, newest first, plus Circle of Trust ones from people you've played. Pending ones can be crashed.</p></div></div>`;
  const pass = (b, f) => (f === "crash" ? crashable(b) : f === "live" ? isLive(b) : true);
  const list = bets.filter((b) => pass(b, S.feedFilter)).sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  const chips = FEED_FILTERS.map(([k, l]) => `<button class="chipbtn" aria-pressed="${S.feedFilter === k}" data-act="feedFilter" data-v="${k}">${l} <span class="mono">${bets.filter((b) => pass(b, k)).length}</span></button>`).join("");
  const empty = S.feedFilter === "crash" ? `<div class="empty"><p>Nothing open to crash right now. Predictions you're already in, or have crashed, don't show here.</p></div>` : `<div class="empty"><p>Nothing here right now.</p></div>`;
  return `<div style="display:flex;flex-direction:column;gap:22px">${pkSection()}<div style="display:flex;flex-direction:column;gap:14px"><div class="secthead"><h2>Everyone's predictions</h2><span class="sub">Everything you're allowed to see, newest first</span></div>
    <div class="filters">${chips}</div><div class="feed">${list.length ? list.map(feedCard).join("") : empty}</div></div></div>`;
}
function rivalSentence(r) {
  const nm = esc(r.name);
  if (!r.w && !r.l && !r.t) return `No finished predictions with ${nm} yet. ${r.live} call${r.live === 1 ? "" : "s"} in play.`;
  if (r.current > 0) return `${nm} owes you ${pts(r.current)}.`;
  if (r.current < 0) return `You owe ${nm} ${pts(-r.current)}.`;
  return r.lastSettled ? `All square with ${nm}.` : `Dead even with ${nm} on points.`;
}
function settlePanel(r) {
  return `<div class="cpanel"><span class="lab">Settle up with ${esc(r.name)}</span>
    <span class="sub">Clears the ${pts(r.current)} ${esc(r.name)} owes you, so your current balance goes back to zero. Your all-time points and record stay.</span>
    <div class="acts"><button class="btn primary" data-act="confirmSettle" data-k="${esc(r.key)}">Settle ${pts(r.current)}</button><button class="btn ghost" data-act="unsettle">Cancel</button></div></div>`;
}
function requestPanel(r) {
  return `<div class="cpanel"><span class="lab">Tell ${esc(r.name)} you settled up</span>
    <span class="sub">${esc(r.name)} gets 24 hours to confirm or dispute that you've settled the ${pts(-r.current)} you owe. If ${esc(r.name)} doesn't answer, it counts and your balance goes back to zero. Your all-time points and record stay.</span>
    <div class="acts"><button class="btn primary" data-act="sendSettleReq" data-k="${esc(r.key)}">I settled up</button><button class="btn ghost" data-act="unsettle">Cancel</button></div></div>`;
}
function settleState(r) {
  const q = r.pendingReq, nm = esc(r.name);
  if (q && q.creditor_uid === S.me) {
    const by = Date.parse(q.respond_by);
    return `<div class="cpanel"><span class="lab">${nm} says you're settled up</span>
      <span class="sub">${nm} says the ${pts(q.points)} is settled. You have until <b>${esc(deadlineText(by))}</b> (${timeLeft(by)}) to confirm or dispute it. After that, it counts.</span>
      <div class="acts"><button class="btn primary" data-act="answerSettle" data-id="${esc(q.id)}" data-v="yes">Confirm</button><button class="btn" data-act="answerSettle" data-id="${esc(q.id)}" data-v="no">Dispute</button></div></div>`;
  }
  if (q) return `<div class="sub">You told ${nm} you settled up on ${pts(q.points)}. If ${nm} doesn't dispute it, it counts on <b>${esc(deadlineText(Date.parse(q.respond_by)))}</b>.</div>`;
  if (r.disputedReq) {
    const d = r.disputedReq, when = new Date(d.resolved_at).toLocaleDateString("en-US", { month: "short", day: "numeric" });
    return `<div class="sub">${d.requester_uid === S.me ? `${nm} disputed your settle-up on ${when}.` : `You disputed ${nm}'s settle-up on ${when}.`}</div>`;
  }
  return "";
}
function rivalActs(r) {
  if (S.settling === r.key) return r.current > 0 ? settlePanel(r) : requestPanel(r);
  const waitingOnMe = r.pendingReq && r.pendingReq.creditor_uid === S.me;
  const btn = r.current > 0 && !waitingOnMe ? `<button class="btn primary" data-act="settle" data-k="${esc(r.key)}">Settle up</button>`
    : r.current < 0 && r.uid && !r.pendingReq ? `<button class="btn primary" data-act="settle" data-k="${esc(r.key)}">I settled up</button>` : "";
  return `${settleState(r)}<div class="acts">${btn}<button class="btn" data-act="rematch" data-v="${esc(r.name)}" data-uid="${esc(r.uid || "")}">New call against ${esc(r.name)}</button></div>`;
}
function renderRivals() {
  const table = standings(), rs = rivals();
  if (!table.length && !rs.length) return `<div class="empty"><h3>No scores yet</h3><p>Once a prediction is confirmed, the winner gains its points, the other side loses them, and the standings show up here.</p></div>`;
  const rows = table.map((r, i) => `<tr class="${r.me ? "me" : ""}"><td class="pl"><span class="rk">${i + 1}</span><span>${esc(r.name)}${r.me ? ` <span class="you">you</span>` : ""}</span></td><td class="num ${tone(r.score)}">${signed(r.score)}</td><td class="num">${r.w}–${r.l}${r.t ? "–" + r.t : ""}</td></tr>`).join("");
  const cards = rs.map((r) => {
    const tot = r.w + r.l + r.t || 1;
    const settledLine = r.lastSettled ? `<div class="sub">Last settled ${new Date(r.lastSettled.created_at).toLocaleDateString("en-US", { month: "short", day: "numeric" })}: ${pts(r.lastSettled.points)} ${r.lastSettled.byMe ? "cleared by you" : "cleared by " + esc(r.name)}</div>` : "";
    return `<div class="card"><div class="rname"><span class="av">${esc(initials(r.name))}</span><h3>You vs ${esc(r.name)}</h3></div>
      <span class="lab">Current balance</span>
      <div class="score ${tone(r.current)}">${signed(r.current)}<small>pts</small></div>
      <div class="sub">All-time: <b class="mono ${tone(r.score)}">${signed(r.score)} pts</b> · ${r.w}–${r.l}${r.t ? "–" + r.t : ""}</div>
      ${settledLine}
      <div class="bars" aria-hidden="true"><i class="w" style="width:${(r.w / tot) * 100}%"></i><i class="p" style="width:${(r.t / tot) * 100}%"></i><i class="l" style="width:${(r.l / tot) * 100}%"></i></div>
      <div class="line">${rivalSentence(r)}</div>
      ${r.live ? `<div class="sub">${r.live} call${r.live === 1 ? "" : "s"} still in play</div>` : ""}
      ${rivalActs(r)}</div>`;
  }).join("");
  return `<div style="display:flex;flex-direction:column;gap:22px">
    ${table.length ? `<div style="display:flex;flex-direction:column;gap:10px"><div class="secthead"><h2>Standings</h2><span class="sub">Everyone playing, by total points, private predictions included</span></div>
      <div class="table"><table><thead><tr><th>Player</th><th class="num">Points</th><th class="num">W–L</th></tr></thead><tbody>${rows}</tbody></table></div></div>` : ""}
    ${rs.length ? `<div style="display:flex;flex-direction:column;gap:10px"><div class="secthead"><h2>Head to head</h2><span class="sub">Your points against each friend</span></div><div class="cards">${cards}</div></div>` : ""}
  </div>`;
}

/* ---------- Vegas (NFL opening lines) ---------- */
const nick = (team) => String(team || "").trim().split(/\s+/).pop();
const lineTxt = (n) => (n == null ? "" : +n === 0 ? "PK" : (n > 0 ? "+" : "−") + Math.abs(+n));
const kickoff = (g) => new Date(g.starts_at).toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" });
const gameDay = (g) => new Date(g.starts_at).toLocaleDateString("en-US", { weekday: "long", month: "short", day: "numeric" });
async function loadLines() {
  const { data, error } = await sb.from("vegas_lines").select("*").gt("starts_at", new Date().toISOString()).order("starts_at").limit(200);
  S.lines = error ? [] : data || [];
  S.linesErr = error ? (/vegas_lines|schema cache|does not exist/i.test(error.message) ? "Vegas lines aren't switched on yet." : friendly(error)) : "";
  if (S.tab === "vegas") render();
}
function vegasCard(g) {
  const hs = g.home_spread == null ? null : +g.home_spread;
  const btn = (pick, label) => `<button class="btn ghost vpick" data-act="vegasPick" data-id="${esc(g.id)}" data-v="${pick}">${label}</button>`;
  const spread = hs == null ? `<span class="sub">Spread not posted yet</span>`
    : `<div class="vrow">${btn("away", esc(nick(g.away)) + " <b class=\"mono\">" + lineTxt(-hs) + "</b>")}${btn("home", esc(nick(g.home)) + " <b class=\"mono\">" + lineTxt(hs) + "</b>")}</div>`;
  const total = g.total == null ? `<span class="sub">Over/under not posted yet</span>`
    : `<div class="vrow">${btn("over", "Over <b class=\"mono\">" + +g.total + "</b>")}${btn("under", "Under <b class=\"mono\">" + +g.total + "</b>")}</div>`;
  return `<article class="card vgame">
    <div class="slip-top"><span class="cat">NFL</span><span class="sub">${esc(kickoff(g))}${g.book ? " · " + esc(g.book) : ""}</span></div>
    <h3>${esc(g.away)} <span class="sub">at</span> ${esc(g.home)}</h3>
    <span class="lab">Spread</span>${spread}
    <span class="lab">Over/under</span>${total}
  </article>`;
}
function renderVegas() {
  if (S.lines === null) { loadLines(); return `<div class="empty"><h3>Calling Vegas…</h3><p>Pulling this week's NFL opening lines.</p></div>`; }
  if (S.linesErr) return `<div class="empty"><h3>No lines yet</h3><p>${esc(S.linesErr)}</p></div>`;
  const head = `<div class="secthead"><h2>Vegas lines</h2><span class="sub">NFL opening lines. Tap a side to call it against a friend.</span></div>`
    + (S.pk && !S.pk.off ? `<div class="pkbanner"><span><b>Pick 'em All!</b> Run a weekly pool with your group: every game against these spreads.</span><button class="btn" data-act="pkGo">Go</button></div>` : "");
  if (!S.lines.length) return `<div style="display:flex;flex-direction:column;gap:14px">${head}<div class="empty"><p>No upcoming games with lines yet. New lines come in every morning.</p></div></div>`;
  let day = "", out = "";
  for (const g of S.lines) {
    const d = gameDay(g);
    if (d !== day) { if (day) out += `</div>`; out += `<h3 class="vday">${esc(d)}</h3><div class="cards">`; day = d; }
    out += vegasCard(g);
  }
  return `<div style="display:flex;flex-direction:column;gap:14px">${head}${out}</div></div>`;
}
function vegasPick(id, pick) {
  const g = (S.lines || []).find((x) => x.id === id);
  if (!g) return;
  if (Date.parse(g.starts_at) <= Date.now() + 60000) { toast("That game has already started."); S.lines = null; render(); return; }
  const hs = +g.home_spread, away = nick(g.away), home = nick(g.home);
  const title = pick === "home" ? `${home} ${lineTxt(hs)} vs ${away}`
    : pick === "away" ? `${away} ${lineTxt(-hs)} vs ${home}`
    : `${away} at ${home}: ${pick === "over" ? "Over" : "Under"} ${+g.total} points`;
  const on = new Date(g.captured_at).toLocaleDateString("en-US", { month: "short", day: "numeric" });
  const terms = `Vegas opening line${g.book ? " (" + g.book + ", " + on + ")" : ""}. Final score per ESPN, overtime counts. Landing exactly on the number is a tie.`;
  openSheet(null, null, { title, terms, due: ymd(new Date(g.starts_at)), shakeBy: Date.parse(g.starts_at) });
}

/* ---------- Pick 'em All! (weekly NFL pools) ---------- */
const PK_TZ = "America/Los_Angeles";
const ptYmd = (d) => new Date(d).toLocaleDateString("en-CA", { timeZone: PK_TZ });
// the Tuesday (Pacific) that starts the NFL week a moment belongs to; matches nfl_week() in the database
function nflWeek(t) {
  const d = new Date(ptYmd(t) + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() - ((d.getUTCDay() + 5) % 7));
  return d.toISOString().slice(0, 10);
}
const weekShift = (wk, n) => { const d = new Date(wk + "T12:00:00Z"); d.setUTCDate(d.getUTCDate() + 7 * n); return d.toISOString().slice(0, 10); };
const weekLabel = (wk) => "Week of " + new Date(wk + "T12:00:00Z").toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
const pkGroup = (id) => S.pk.groups.find((g) => g.id === id);
const pkMembers = (id) => S.pk.members.filter((m) => m.group_id === id);
const pkIsMember = (id) => !!S.me && pkMembers(id).some((m) => m.uid === S.me);
const pkName = (uid) => personName(uid) || "Someone";

async function loadPickem() {
  const [g, m, r, w, c, led, car, req, sub] = await Promise.all([
    sb.from("pickem_groups").select("id,name,created_by,created_at").order("created_at"),
    sb.from("pickem_members").select("*"),
    sb.from("pickem_results").select("*"),
    sb.from("pickem_weeks").select("*").order("week", { ascending: false }),
    sb.rpc("my_pickem_codes"),
    sb.from("pickem_ledger").select("*"),
    sb.from("pickem_carry").select("*").is("paid_week", null),
    sb.from("pickem_crash_requests").select("*"),
    sb.from("pickem_submissions").select("*").eq("week", nflWeek(Date.now())),
  ]);
  if (g.error) { S.pk = { ...S.pk, off: true }; return; }
  // before update-pickem-2.sql runs, the ledger is missing: fall back to weekly results
  const ledger = led.error ? (r.data || []).filter((x) => x.points) : led.data || [];
  S.pk = { off: false, groups: g.data || [], members: m.data || [], results: r.data || [], weeks: w.data || [],
    codes: new Map((c.data || []).map((x) => [x.group_id, x.code])), ledger, carry: car.error ? [] : car.data || [],
    requests: req.error ? [] : req.data || [], v2: !led.error,
    subs: sub.error ? [] : sub.data || [], v3: !sub.error };
}
function pkTotals(gid) {
  const rows = new Map(pkMembers(gid).map((m) => [m.uid, { uid: m.uid, name: pkName(m.uid), points: 0, won: 0, weeks: 0 }]));
  const row = (uid) => { if (!rows.has(uid)) rows.set(uid, { uid, name: pkName(uid), points: 0, won: 0, weeks: 0 }); return rows.get(uid); };
  for (const r of S.pk.results.filter((x) => x.group_id === gid)) { row(r.uid).weeks++; if (r.won && r.points > 0) row(r.uid).won++; }
  for (const l of S.pk.ledger.filter((x) => x.group_id === gid)) row(l.uid).points += l.points;
  return [...rows.values()].sort((a, b) => b.points - a.points || b.won - a.won || a.name.localeCompare(b.name));
}
function pkInviteText(g) {
  const code = S.pk.codes.get(g.id);
  return `Join my Pick 'em All! group "${g.name}" on Handshake. Every week, pick every NFL game against the spread. The week's winner takes 5 pts from everyone else. Tap to join: ${PAGE_URL}?join=${code} (or enter code ${code} on the Everyone tab).`;
}
function pkCard(g) {
  const mine = pkIsMember(g.id), rows = pkTotals(g.id);
  const last = S.pk.weeks.find((w) => w.group_id === g.id);
  const lastWinners = last ? S.pk.results.filter((r) => r.group_id === g.id && r.week === last.week && r.won && r.points > 0) : [];
  const lastLine = !last ? "" : lastWinners.length
    ? `<div class="sub">${esc(weekLabel(last.week))}: ${esc(listNames(lastWinners.map((r) => pkName(r.uid))))} won, ${signed(lastWinners[0].points)} pts</div>`
    : last.rolled ? `<div class="sub">${esc(weekLabel(last.week))}: nobody got half right (best was ${last.best} of ${last.games}). The pot rolled over.</div>`
    : `<div class="sub">${esc(weekLabel(last.week))}: no points moved (${last.entries} entr${last.entries === 1 ? "y" : "ies"})</div>`;
  const rolled = S.pk.carry.filter((c) => c.group_id === g.id).length;
  const potLine = rolled ? `<div class="pkpot">💰 <b>${rolled * 5} pts rolled over</b> and waiting for this week's winner.</div>` : "";
  const reqs = g.created_by === S.me ? S.pk.requests.filter((q) => q.group_id === g.id && q.status === "pending") : [];
  const reqRows = reqs.map((q) => `<div class="pkreq"><span><b>${esc(pkName(q.uid))}</b> wants to crash.</span><span class="acts"><button class="btn primary" data-act="pkLetIn" data-id="${g.id}" data-v="${q.uid}">Let them in</button><button class="btn ghost" data-act="pkSayNo" data-id="${g.id}" data-v="${q.uid}">No thanks</button></span></div>`).join("");
  const subs = new Set(S.pk.subs.filter((x) => x.group_id === g.id).map((x) => x.uid));
  const inCol = S.pk.v3;
  const table = `<div class="table"><table><thead><tr><th>Player</th><th class="num">Points</th><th class="num">Wins</th>${inCol ? `<th class="num pkinh">Picks in</th>` : ""}</tr></thead><tbody>${rows.map((r, i) =>
    `<tr class="${r.uid === S.me ? "me" : ""}"><td class="pl"><span class="rk">${i + 1}</span><span>${esc(r.name)}${r.uid === S.me ? ` <span class="you">you</span>` : ""}</span></td><td class="num ${tone(r.points)}">${signed(r.points)}</td><td class="num">${r.won}</td>${inCol ? `<td class="num pkin">${subs.has(r.uid) ? "✓" : ""}</td>` : ""}</tr>`).join("")}</tbody></table></div>`
    + (inCol ? `<span class="sub">Picks in this week (${esc(weekLabel(nflWeek(Date.now())))}): ${rows.filter((r) => subs.has(r.uid)).length} of ${rows.length}</span>` : "");
  let acts;
  if (mine) acts = `<div class="acts"><button class="btn primary" data-act="pkOpen" data-id="${g.id}">Make your picks</button><button class="btn ghost" data-act="pkInvite" data-id="${g.id}">Invite friends</button></div>`;
  else {
    const mineReq = S.pk.requests.find((q) => q.group_id === g.id && q.uid === S.me);
    const ask = !S.pk.v2 ? `<span class="sub">Invite only. Ask ${esc(pkName(g.created_by))} for the link.</span>`
      : mineReq?.status === "pending" ? `<span class="sub">You asked to crash. Waiting on ${esc(pkName(g.created_by))}.</span>`
      : `<button class="btn primary" data-act="pkCrash" data-id="${g.id}">Can I crash?</button>${mineReq?.status === "declined" ? `<span class="sub">${esc(pkName(g.created_by))} said no last time.</span>` : ""}`;
    acts = `<div class="acts">${ask}<button class="btn ghost" data-act="pkOpen" data-id="${g.id}">See picks</button></div>`;
  }
  let invite = "";
  if (S.pkInviting === g.id && S.pk.codes.get(g.id)) {
    const text = pkInviteText(g);
    invite = `<div class="cpanel"><span class="lab">Invite code <b class="mono">${esc(S.pk.codes.get(g.id))}</b></span><p class="msg" id="pkInviteText">${esc(text)}</p>
      <div class="acts"><button class="btn primary" data-act="pkCopyInvite" data-id="${g.id}">Copy invite</button><a class="btn" href="${esc(smsHref("", text))}">Open Messages</a><button class="btn ghost" data-act="pkCloseInvite">Close</button></div></div>`;
  }
  return `<article class="card pkcard">
    <div class="slip-top"><span class="cat">Pick 'em All!</span><span class="sub">${rows.length} member${rows.length === 1 ? "" : "s"}</span></div>
    <h3>${esc(g.name)}</h3>${lastLine}${potLine}${reqRows}${table}${acts}${invite}</article>`;
}
function pkSection() {
  if (!S.pk || S.pk.off) return "";
  const groups = S.pk.groups.slice().sort((a, b) => pkIsMember(b.id) - pkIsMember(a.id) || Date.parse(b.created_at) - Date.parse(a.created_at));
  const create = S.pkNaming
    ? `<div class="card"><div class="field"><label for="pkName">Name your group</label><input id="pkName" maxlength="30" placeholder="Sunday Degenerates" autocomplete="off"></div>
        <p class="err" id="pkErr" hidden></p><div class="acts"><button class="btn primary" data-act="pkCreate">Start the group</button><button class="btn ghost" data-act="pkUnname">Cancel</button></div></div>`
    : "";
  const join = `<div class="pkjoin"><input id="pkCode" maxlength="6" placeholder="Invite code" autocomplete="off" autocapitalize="characters" aria-label="Invite code"><button class="btn" data-act="pkJoin">Join</button></div>`;
  return `<div style="display:flex;flex-direction:column;gap:10px">
    <div class="secthead"><h2>Pick 'em All!</h2>${S.pkNaming ? "" : `<button class="btn quiet" data-act="pkName">Start a group</button>`}</div>
    <span class="sub">Weekly NFL pools. Pick every game against the Vegas opening spread, plus the Monday night total as the tiebreaker. ${S.pk.v2 ? " Star one game as your bonus: it counts double." : ""} The week's winner gets 5 pts for every other entry; everyone else gives up 5.${S.pk.v2 ? " Win with at least half the games right, or the whole pot rolls over to next week." : ""}</span>
    ${create}${groups.length ? `<div class="cards">${groups.map(pkCard).join("")}</div>` : ""}${join}</div>`;
}

/* the picks screen for one group and week */
async function loadPkWeek() {
  const v = S.pkView; if (!v) return;
  const from = new Date(Date.parse(v.week + "T00:00:00Z") - DAY).toISOString(), to = new Date(Date.parse(v.week + "T00:00:00Z") + 8 * DAY).toISOString();
  const { data: games, error } = await sb.from("vegas_lines").select("*").gte("starts_at", from).lt("starts_at", to).order("starts_at");
  if (error) { v.err = friendly(error); v.games = []; render(); return; }
  v.games = (games || []).filter((g) => nflWeek(g.starts_at) === v.week);
  const ids = v.games.map((g) => g.id);
  const [p, t, b, s] = await Promise.all([
    ids.length ? sb.from("pickem_picks").select("*").eq("group_id", v.gid).in("game_id", ids) : { data: [] },
    sb.from("pickem_tiebreaks").select("*").eq("group_id", v.gid).eq("week", v.week),
    S.pk?.v2 ? sb.from("pickem_bonus").select("*").eq("group_id", v.gid).eq("week", v.week) : { data: [] },
    S.pk?.v3 ? sb.from("pickem_submissions").select("*").eq("group_id", v.gid).eq("week", v.week) : { data: [] },
  ]);
  v.picks = p.data || []; v.tbs = t.data || []; v.bonus = b.data || []; v.subs = s.data || []; v.err = "";
  render();
}
function pkOpen(gid, week) {
  S.pkView = { gid, week: week || nflWeek(Date.now()), games: null, picks: [], tbs: [], bonus: [], subs: [] }; S.pkInviting = null;
  render(); loadPkWeek(); window.scrollTo({ top: $("#view").offsetTop - 10, behavior: "smooth" });
}
const gameStarted = (g) => Date.parse(g.starts_at) <= Date.now();
// Picks lock at the week's first Sunday kickoff (games before Sunday lock at their own kickoff).
const ptWeekday = (t) => new Date(t).toLocaleDateString("en-US", { weekday: "short", timeZone: PK_TZ });
function pkWeekLock(games) {
  if (!S.pk?.v3) return null;
  const sun = (games || []).filter((x) => x.home_spread != null && ptWeekday(x.starts_at) === "Sun").map((x) => Date.parse(x.starts_at));
  return sun.length ? Math.min(...sun) : null;
}
const pkLockAt = (g, games) => { const k = Date.parse(g.starts_at), w = pkWeekLock(games); return w == null ? k : Math.min(k, w); };
const pkLocked = (g, games) => !!g?.starts_at && pkLockAt(g, games) <= Date.now();
const lockLabel = (ms) => new Date(ms).toLocaleString("en-US", { weekday: "short", hour: "numeric", minute: "2-digit" });
function coverSide(g) {  // which side covered the opening spread, or "push"
  if (!g.completed || g.home_spread == null) return null;
  const m = g.home_score - g.away_score + +g.home_spread;
  return m > 0 ? "home" : m < 0 ? "away" : "push";
}
function pkGameCard(g, v, tbId, mine) {
  const hs = g.home_spread == null ? null : +g.home_spread, my = v.picks.find((p) => p.game_id === g.id && p.uid === S.me)?.side;
  const locked = pkLocked(g, v.games), cov = coverSide(g);
  const mark = (s) => (my !== s || !cov ? "" : cov === "push" ? " · push" : cov === s ? " ✓" : " ✗");
  const btn = (s, label) => `<button class="btn ghost vpick ${my === s ? "on" : ""}" aria-pressed="${my === s}" data-act="pkPick" data-id="${esc(g.id)}" data-v="${s}" ${locked || !mine ? "disabled" : ""}>${label}${mark(s)}</button>`;
  const lineRow = hs == null ? `<span class="sub">No spread posted, so this game isn't in the pool.</span>`
    : `<div class="vrow">${btn("away", esc(nick(g.away)) + " <b class=\"mono\">" + lineTxt(-hs) + "</b>")}${btn("home", esc(nick(g.home)) + " <b class=\"mono\">" + lineTxt(hs) + "</b>")}</div>`;
  let who = "";
  if (locked && hs != null) {
    const by = (s) => v.picks.filter((p) => p.game_id === g.id && p.side === s).map((p) => pkName(p.uid));
    const a = by("away"), h = by("home");
    who = a.length || h.length ? `<span class="sub">${esc(nick(g.away))}: ${a.length ? esc(a.join(", ")) : "nobody"} · ${esc(nick(g.home))}: ${h.length ? esc(h.join(", ")) : "nobody"}</span>` : `<span class="sub">Nobody picked this game.</span>`;
  }
  const score = g.home_score != null ? `<span class="sub mono">${g.completed ? "Final" : "Latest"}: ${esc(nick(g.away))} ${g.away_score}, ${esc(nick(g.home))} ${g.home_score}${cov ? " · " + (cov === "push" ? "push on the spread" : esc(nick(cov === "home" ? g.home : g.away)) + " covered") : ""}</span>` : "";
  let tb = "";
  if (g.id === tbId) {
    const myTb = v.tbs.find((t) => t.uid === S.me)?.guess;
    if (!locked && mine) tb = `<div class="pktb"><label for="pkTb">Tiebreaker: total points in this game</label><div class="pkjoin"><input id="pkTb" type="number" inputmode="numeric" min="0" max="200" value="${myTb ?? ""}" placeholder="${g.total ?? ""}"><button class="btn" data-act="pkTb">${myTb != null ? "Update" : "Save"}</button></div>${myTb != null ? `<span class="sub">Saved: ${myTb}</span>` : ""}</div>`;
    else tb = `<div class="pktb"><span class="lab">Tiebreaker (total points)</span><span class="sub">${v.tbs.length ? esc(v.tbs.map((t) => pkName(t.uid) + " " + t.guess).join(" · ")) : locked ? "No guesses." : "Locks " + esc(lockLabel(pkLockAt(g, v.games))) + "."}${g.completed ? " · Actual: " + (g.home_score + g.away_score) : ""}</span></div>`;
  }
  let bonus = "";
  if (S.pk.v2 && hs != null) {
    const myBonus = v.bonus.find((x) => x.uid === S.me)?.game_id, isMine = myBonus === g.id;
    const bonusLocked = myBonus && myBonus !== g.id && pkLocked(v.games.find((x) => x.id === myBonus), v.games);
    if (mine && !locked && !bonusLocked) bonus = `<button class="btn quiet pkbonus ${isMine ? "on" : ""}" aria-pressed="${isMine}" data-act="pkBonus" data-id="${esc(g.id)}">${isMine ? "★ Bonus game: counts double" : "☆ Make this my bonus game"}</button>`;
    else if (isMine) bonus = `<span class="pkbonus on">★ Your bonus game: counts double</span>`;
    if (locked) {
      const others = v.bonus.filter((x) => x.game_id === g.id && x.uid !== S.me).map((x) => pkName(x.uid));
      if (others.length) bonus += `<span class="sub">★ Bonus game for ${esc(others.join(", "))}</span>`;
    }
  }
  return `<article class="card vgame ${locked ? "locked" : ""}">
    <div class="slip-top"><span class="cat">NFL</span><span class="sub">${esc(kickoff(g))}${locked ? " · locked" : pkLockAt(g, v.games) < Date.parse(g.starts_at) ? " · pick locks " + esc(lockLabel(pkLockAt(g, v.games))) : ""}${g.id === tbId ? " · tiebreaker" : ""}</span></div>
    <h3>${esc(g.away)} <span class="sub">at</span> ${esc(g.home)}</h3>${lineRow}${bonus}${score}${who}${tb}</article>`;
}
function renderPickem() {
  const v = S.pkView, g = pkGroup(v.gid);
  if (!g) { S.pkView = null; return renderFeed(); }
  const mine = pkIsMember(g.id), cur = nflWeek(Date.now());
  const nav = `<div class="filters"><button class="chipbtn" data-act="pkWeek" data-v="-1">‹ Earlier</button><span class="sub" style="font-weight:600">${esc(weekLabel(v.week))}${v.week === cur ? " (this week)" : ""}</span>${v.week < weekShift(cur, 1) ? `<button class="chipbtn" data-act="pkWeek" data-v="1">Later ›</button>` : ""}</div>`;
  const head = `<div class="secthead"><h2>${esc(g.name)}</h2><button class="btn quiet" data-act="pkBack">‹ All groups</button></div>${nav}`;
  if (v.games === null) return `<div style="display:flex;flex-direction:column;gap:14px">${head}<div class="empty"><p>Loading the week…</p></div></div>`;
  if (v.err) return `<div style="display:flex;flex-direction:column;gap:14px">${head}<div class="empty"><p>${esc(v.err)}</p></div></div>`;
  const pool = v.games.filter((x) => x.home_spread != null);
  if (!v.games.length) return `<div style="display:flex;flex-direction:column;gap:14px">${head}<div class="empty"><p>No games with lines for this week yet. New lines come in every morning.</p></div></div>`;
  const tbId = [...v.games].filter((x) => x.total != null).sort((a, b) => Date.parse(b.starts_at) - Date.parse(a.starts_at) || (a.id < b.id ? 1 : -1))[0]?.id;
  // this week's leaderboard: graded results if the week is done, otherwise right so far
  const graded = S.pk.weeks.some((w) => w.group_id === g.id && w.week === v.week);
  const entrants = new Set([...v.picks.map((p) => p.uid), ...v.tbs.map((t) => t.uid)]);
  let board;
  if (graded) {
    const rs = S.pk.results.filter((r) => r.group_id === g.id && r.week === v.week).sort((a, b) => b.points - a.points || b.correct - a.correct);
    const wk = S.pk.weeks.find((w) => w.group_id === g.id && w.week === v.week);
    board = rs.map((r) => `<tr class="${r.uid === S.me ? "me" : ""}"><td class="pl"><span>${esc(pkName(r.uid))}${r.won && r.points > 0 ? " 🏆" : ""}</span></td><td class="num">${r.correct}${r.bonus_right ? "+1★" : ""}</td><td class="num">${r.tb_diff ?? "–"}</td><td class="num ${tone(r.points)}">${signed(r.points)}</td></tr>`).join("");
    board = (wk?.rolled ? `<div class="pkpot">Nobody got half right (best was ${wk.best} of ${wk.games}), so the pot rolled over to next week.</div>` : "")
      + `<div class="table"><table><thead><tr><th>Final</th><th class="num">Right</th><th class="num">TB off</th><th class="num">Pts</th></tr></thead><tbody>${board}</tbody></table></div>`;
  } else {
    const rows = [...entrants].map((uid) => {
      const hits = v.picks.filter((p) => p.uid === uid && coverSide(v.games.find((x) => x.id === p.game_id) || {}) === p.side);
      const bonusHit = hits.some((p) => p.game_id === v.bonus.find((x) => x.uid === uid)?.game_id);
      return { uid, right: hits.length, bonusHit, score: hits.length + (bonusHit ? 1 : 0) };
    }).sort((a, b) => b.score - a.score);
    const decided = v.games.filter((x) => { const c = coverSide(x); return c && c !== "push"; }).length;
    board = rows.length ? `<div class="table"><table><thead><tr><th>So far</th><th class="num">Right</th></tr></thead><tbody>${rows.map((r) => `<tr class="${r.uid === S.me ? "me" : ""}"><td class="pl"><span>${esc(pkName(r.uid))}</span></td><td class="num">${r.right}${r.bonusHit ? "+1★" : ""}</td></tr>`).join("")}</tbody></table></div>`
      + (S.pk.v2 && decided ? `<span class="sub">${decided} game${decided === 1 ? "" : "s"} decided so far. The winner needs at least half of the week's games right.</span>` : "")
      : `<span class="sub">No entries yet this week.</span>`;
  }
  const myCount = v.picks.filter((p) => p.uid === S.me).length, open = pool.filter((x) => !pkLocked(x, v.games)).length;
  const wLock = pkWeekLock(v.games);
  const lockRule = wLock ? `Games before Sunday lock at their own kickoff; everything else (and the tiebreaker and bonus game) locks <b>${esc(lockLabel(wLock))}</b>, at the first Sunday kickoff.` : "Each game locks at kickoff.";
  const status = mine
    ? `<span class="sub">You've picked <b>${myCount} of ${pool.length}</b>${open ? ` · ${open} still open` : " · all locked"}. ${lockRule} An unpicked game counts as a miss. Tap a pick again to clear it.${S.pk.v2 ? ` Bonus game: ${v.bonus.some((x) => x.uid === S.me) ? "set" : "<b>not picked yet</b>"}.` : ""} Other people's picks show once they lock.</span>`
    : `<span class="sub">You're not in this group. Picks show once they lock.</span>`;
  // Submit
  let submit = "";
  if (mine && S.pk.v3) {
    const mySub = v.subs.find((x) => x.uid === S.me);
    const missingGames = pool.filter((x) => !pkLocked(x, v.games) && !v.picks.some((p) => p.uid === S.me && p.game_id === x.id));
    const tbGame = v.games.find((x) => x.id === tbId);
    const needTb = tbGame && !pkLocked(tbGame, v.games) && !v.tbs.some((t) => t.uid === S.me);
    const noBonus = S.pk.v2 && !v.bonus.some((x) => x.uid === S.me);
    const todo = [missingGames.length ? `${missingGames.length} game${missingGames.length === 1 ? "" : "s"} to pick` : "", needTb ? "your tiebreaker (on the last game)" : ""].filter(Boolean);
    if (!open) submit = mySub ? `<div class="pksubmit done"><div class="pkdone">Picks Submitted!</div><span>Everything's locked now. Good luck.</span></div>` : "";
    else if (mySub) submit = `<div class="pksubmit done"><div class="pkdone">Picks Submitted!</div><span>Sent ${esc(lockLabel(Date.parse(mySub.submitted_at)))}. You can still change them until they lock${wLock ? ", " + esc(lockLabel(wLock)) : ""}; changes save as you tap.${todo.length ? ` <b>Heads up:</b> still missing ${esc(todo.join(" and "))}.` : ""}</span></div>`;
    else submit = `<div class="pksubmit"><button class="btn primary" data-act="pkSubmit">Submit my picks</button>
      <span class="sub">${todo.length ? "Still to do: " + esc(todo.join(" and ")) + "." : "Everything's picked. Submit to let the group know you're in."}${noBonus ? " No bonus game yet (optional, but it counts double)." : ""}</span></div>`;
  }
  let day = "", out = "";
  for (const x of v.games) {
    const d = gameDay(x);
    if (d !== day) { if (day) out += `</div>`; out += `<h3 class="vday">${esc(d)}</h3><div class="cards">`; day = d; }
    out += pkGameCard(x, v, tbId, mine);
  }
  return `<div style="display:flex;flex-direction:column;gap:14px">${head}${status}${submit}${board}${out}</div>${submit}</div>`;
}
async function pkPick(gid, game, side) {
  const v = S.pkView; if (!v) return;
  const cur = v.picks.find((p) => p.game_id === game && p.uid === S.me);
  const next = cur?.side === side ? null : side;
  v.picks = v.picks.filter((p) => !(p.game_id === game && p.uid === S.me));
  if (next) v.picks.push({ group_id: gid, uid: S.me, game_id: game, side: next });
  render();
  const { error } = await sb.rpc("save_pickem_pick", { p_group: gid, p_game: game, p_side: next });
  if (error) { toast(friendly(error)); loadPkWeek(); }
}
async function pkSaveTb() {
  const v = S.pkView; if (!v) return;
  const raw = $("#pkTb")?.value.trim(), n = raw === "" ? null : Math.round(+raw);
  if (n != null && !(n >= 0 && n <= 200)) return toast("Guess a total between 0 and 200.");
  const { error } = await sb.rpc("save_pickem_tiebreak", { p_group: v.gid, p_week: v.week, p_guess: n });
  if (error) return toast(friendly(error));
  toast(n == null ? "Tiebreaker cleared" : "Tiebreaker saved: " + n); loadPkWeek();
}
async function pkSubmit() {
  const v = S.pkView; if (!v) return;
  const { error } = await sb.rpc("submit_pickem_week", { p_group: v.gid, p_week: v.week });
  if (error) return toast(friendly(error));
  toast("Your picks are in. You can still change them until they lock.");
  await Promise.all([loadPickem(), loadPkWeek()]);
}
async function pkBonus(game) {
  const v = S.pkView; if (!v) return;
  const cur = v.bonus.find((x) => x.uid === S.me)?.game_id, next = cur === game ? null : game;
  v.bonus = v.bonus.filter((x) => x.uid !== S.me);
  if (next) v.bonus.push({ group_id: v.gid, uid: S.me, week: v.week, game_id: next });
  render();
  const { error } = await sb.rpc("save_pickem_bonus", { p_group: v.gid, p_week: v.week, p_game: next });
  if (error) { toast(friendly(error)); loadPkWeek(); }
}
async function pkCrash(gid) {
  const { error } = await sb.rpc("request_pickem_crash", { p_group: gid });
  if (error) return toast(friendly(error));
  notifyQuiet({ pickem_group: gid });
  await loadPickem(); render();
  toast("Asked " + pkName(pkGroup(gid)?.created_by) + " if you can crash.");
}
async function pkAnswer(gid, uid, yes) {
  const { error } = await sb.rpc("answer_pickem_crash", { p_group: gid, p_uid: uid, p_accept: yes });
  if (error) return toast(friendly(error));
  notifyQuiet({ pickem_group: gid, uid });
  await loadPickem(); render();
  toast(yes ? pkName(uid) + " is in." : "Told " + pkName(uid) + " no.");
}
async function pkCreate() {
  const name = $("#pkName")?.value.trim(), err = (m) => { const e = $("#pkErr"); if (e) { e.textContent = m; e.hidden = false; } };
  if (!name) return err("Give the group a name.");
  const { data, error } = await sb.rpc("create_pickem_group", { p_name: name });
  if (error) return err(friendly(error));
  S.pkNaming = false; await loadPickem(); S.pkInviting = data; render();
  toast(name + " is ready. Send the invite to your group.");
}
async function pkJoin(code) {
  code = String(code || "").trim().toUpperCase();
  if (!code) return toast("Type the invite code first.");
  if (/^W[0-9A-F]{6}$/.test(code)) return wfJoin(code);
  const { data, error } = await sb.rpc("join_pickem_group", { p_code: code });
  if (error) return toast(friendly(error));
  await loadPickem(); S.tab = "feed";
  toast("You're in " + (pkGroup(data)?.name || "the group") + ". Make your picks!");
  pkOpen(data);
}
/* invite links: ?join=CODE, remembered through sign-up */
(() => {
  const code = new URLSearchParams(location.search).get("join");
  if (code) { store.set("hs-join", code.toUpperCase()); history.replaceState(null, "", location.pathname); }
})();
async function pkJoinPending() {
  const code = store.get("hs-join");
  if (!code || !S.me) return;
  store.set("hs-join", "");
  await pkJoin(code);
}
/* In the iPhone app, invite links (universal links) open the app instead of Safari. */
if (IN_APP) {
  const appPlugin = capPlugin("App");
  let lastLink = "";
  const fromLink = (url) => {
    let code = "";
    try { code = new URL(url).searchParams.get("join") || ""; } catch (e) {}
    if (!code || code === lastLink) return;
    lastLink = code;
    store.set("hs-join", code.toUpperCase());
    if (S.me) pkJoinPending();  // otherwise it joins right after sign-in
  };
  try {
    appPlugin?.addListener("appUrlOpen", (e) => fromLink(e?.url));
    appPlugin?.getLaunchUrl?.().then((r) => r?.url && fromLink(r.url)).catch(() => {});
  } catch (e) {}
}

/* ---------- Golf: Wolf ---------- */
const WF_BONUS = [["greenie", "Greenie"], ["birdie", "Birdie"], ["sandy", "Sandy"]];
async function loadWolf() {
  const { data, error } = await sb.from("wolf_rounds").select("*").order("created_at", { ascending: false }).limit(30);
  S.wolf = { ...(S.wolf || {}), off: !!error, rounds: data || [] };
}
const wfRound = (id) => (S.wolf?.rounds || []).find((r) => r.id === id);
const wfNames = (r) => r.players.map((p) => p.name);
async function loadWolfRound() {
  const v = S.wolf?.view; if (!v) return;
  const [b, h] = await Promise.all([sb.rpc("wolf_scoreboard", { p_round: v.id }), sb.from("wolf_holes").select("*").eq("round_id", v.id)]);
  if (b.error) { v.err = friendly(b.error); render(); return; }
  v.board = b.data || []; v.holes = h.data || []; v.err = "";
  if (!v.hole) { const done = v.board.filter((x) => x.complete).map((x) => x.hole); v.hole = Math.min(18, (done.length ? Math.max(...done) : 0) + 1); }
  wfDraftFor(v.hole);
  render();
}
function wfDraftFor(hole) {
  const v = S.wolf.view, h = v.holes.find((x) => x.hole === hole);
  v.hole = hole;
  v.draft = h ? { mode: h.mode, partner: h.partner, scores: [...h.scores], greenie: [...h.greenie], birdie: [...h.birdie], sandy: [...h.sandy], press: h.pressed_by }
    : { mode: null, partner: null, scores: [null, null, null, null], greenie: [], birdie: [], sandy: [], press: null };
}
function wfCapture() {  // keep typed scores when the screen re-draws
  const v = S.wolf?.view; if (!v?.draft) return;
  for (let i = 0; i < 4; i++) { const el = $("#wfS" + i); if (el) { const n = parseInt(el.value, 10); v.draft.scores[i] = Number.isFinite(n) ? n : null; } }
}
function wfTotals(board, beforeHole) {
  const t = [0, 0, 0, 0];
  for (const x of board) if (beforeHole == null || x.hole < beforeHole) { t[0] += x.d0; t[1] += x.d1; t[2] += x.d2; t[3] += x.d3; }
  return t;
}
function renderGolf() {
  if (!S.wolf) { loadWolf().then(render).catch(() => {}); return `<div class="empty"><p>Loading…</p></div>`; }
  if (S.wolf.off) return `<div class="empty"><h3>Golf isn't switched on yet</h3><p>Run update-wolf.sql in Supabase.</p></div>`;
  if (S.wolf.view) return renderWolfRound();
  let form = "";
  if (S.wolf.starting) {
    const opts = (sel) => [`<option value="">Pick a player…</option>`, ...S.people.map((p) => `<option value="${p.id}" ${sel === p.id ? "selected" : ""}>${esc(p.name)}${p.id === S.me ? " (you)" : ""}</option>`), `<option value="guest">Guest (not on Handshake)</option>`].join("");
    const holesFor = (i) => [1, 2, 3, 4, 5].map((k) => i + 1 + 4 * (k - 1)).filter((x) => x <= 18).join(", ");
    form = `<div class="card wfstart"><div class="field"><label for="wfCourse">Course (optional)</label><input id="wfCourse" maxlength="40" placeholder="Torrey Pines South" autocomplete="off"></div>
      <span class="lab">Tee order</span><span class="sub">The Wolf rotates in this order and keeps going on 17 and 18.</span>
      ${[0, 1, 2, 3].map((i) => `<div class="wfslot"><span class="rk">${i + 1}</span><div class="wfslotin"><select id="wfSel${i}" aria-label="Player ${i + 1}">${opts(i === 0 ? S.me : "")}</select>
        <input id="wfGuest${i}" maxlength="30" placeholder="Guest's name" hidden autocomplete="off"><span class="sub">Wolf on ${holesFor(i)}</span></div></div>`).join("")}
      <p class="err" id="wfErr" hidden></p>
      <div class="acts"><button class="btn primary" data-act="wfCreate">Tee it up</button><button class="btn ghost" data-act="wfCancel">Cancel</button></div></div>`;
  }
  const cl = S.wolf.claim;
  const claim = cl ? `<div class="card"><span class="lab">Join ${esc(cl.course || "this Wolf round")}</span><h3 style="margin:0">Which one are you?</h3>
    <div class="acts">${cl.guest_slots.map((i) => `<button class="btn primary" data-act="wfClaim" data-v="${i}">${esc(cl.names[i])}</button>`).join("")}<button class="btn ghost" data-act="wfClaimNo">Cancel</button></div>
    <span class="sub">You'll take that guest's spot and see the round live.</span></div>` : "";
  const rounds = S.wolf.rounds.map((r) => `<article class="card wfround" data-act="wfOpen" data-id="${r.id}">
      <div class="slip-top"><span class="cat">Wolf</span><span class="sub">${esc(new Date(r.created_at).toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" }))} · ${r.status === "finished" ? "Finished" : "<b>In progress</b>"}</span></div>
      <h3>${esc(r.course || "Wolf round")}</h3><span class="sub">${esc(wfNames(r).join(" · "))}</span></article>`).join("");
  return `<div style="display:flex;flex-direction:column;gap:14px">
    <div class="secthead"><h2>Golf</h2>${S.wolf.starting ? "" : `<button class="btn quiet" data-act="wfStart">Start a Wolf round</button>`}</div>
    <span class="sub">Wolf for a foursome: take a partner, go Lone Wolf (win 3 or pay 1 each) or Blind Wolf before anyone tees off (win 6 or pay 2 each). Ties roll a point over. Last place can press to double the stakes from there on. Greenies, Birdies and Sandies are 1 from each player. When you finish, points go into Standings and Rivals.</span>
    ${claim}${form}${rounds ? `<div class="cards">${rounds}</div>` : S.wolf.starting ? "" : `<div class="empty"><p>No rounds yet.</p></div>`}
    <div class="pkjoin"><input id="wfCode" maxlength="7" placeholder="Round code" autocomplete="off" autocapitalize="characters" aria-label="Round code"><button class="btn" data-act="wfJoinCode">Join round</button></div></div>`;
}
function wfInviteText(r) {
  return `Join my Wolf round${r.course ? " at " + r.course : ""} on Handshake so you can enter and follow scores live. Tap: ${PAGE_URL}?join=${r.code} (or enter code ${r.code} on the Golf tab).`;
}
function renderWolfRound() {
  const v = S.wolf.view, r = wfRound(v.id);
  if (!r) { S.wolf.view = null; return renderGolf(); }
  const names = wfNames(r), playing = r.status === "playing";
  const head = `<div class="secthead"><h2>${esc(r.course || "Wolf round")}</h2><button class="btn quiet" data-act="wfBack">‹ All rounds</button></div>`;
  if (!v.board) return `<div style="display:flex;flex-direction:column;gap:14px">${head}<div class="empty"><p>${v.err ? esc(v.err) : "Loading the round…"}</p></div></div>`;
  const tot = wfTotals(v.board), order = [0, 1, 2, 3].sort((a, b) => tot[b] - tot[a]);
  const last = v.board.filter((x) => x.complete).slice(-1)[0];
  const presses = v.board.length ? Math.max(...v.board.map((x) => x.presses)) : 0;
  const carry = (() => { let c = 0; for (const x of v.board) if (x.complete) c = x.result?.startsWith("Tied") ? c + 1 : 0; return c; })();
  const stakes = `<div class="wfstakes"><span>Stakes <b>${2 ** presses}x</b>${presses ? ` (${presses} press${presses > 1 ? "es" : ""})` : ""}</span><span>${carry ? `<b>${carry}</b> point${carry > 1 ? "s" : ""} rolling over` : "Nothing rolling over"}</span><span>Thru <b>${last ? last.hole : 0}</b></span></div>`;
  const table = `<div class="table"><table><thead><tr><th>Player</th><th class="num">Points</th></tr></thead><tbody>${order.map((i, k) =>
    `<tr class="${r.players[i].uid === S.me ? "me" : ""}"><td class="pl"><span class="rk">${k + 1}</span><span>${esc(names[i])}${r.players[i].uid ? "" : ` <span class="sub">guest</span>`}</span></td><td class="num ${tone(tot[i])}">${signed(tot[i])}</td></tr>`).join("")}</tbody></table></div>`;
  const chips = `<div class="wfholes">${Array.from({ length: 18 }, (_, k) => k + 1).map((n) => {
    const b = v.board.find((x) => x.hole === n);
    return `<button class="wfhole ${n === v.hole ? "on" : ""} ${b?.complete ? "done" : ""}" data-act="wfHole" data-v="${n}" aria-label="Hole ${n}">${n}</button>`; }).join("")}</div>`;
  // the hole being entered
  const d = v.draft, hn = v.hole, w = (hn - 1) % 4, saved = v.board.find((x) => x.hole === hn);
  const before = wfTotals(v.board, hn), low = Math.min(...before);
  const priorPresses = v.board.filter((x) => x.hole < hn).reduce((m, x) => Math.max(m, x.presses), 0);
  let priorCarry = 0; for (const x of v.board) if (x.hole < hn && x.complete) priorCarry = x.result?.startsWith("Tied") ? priorCarry + 1 : 0;
  const mult = d.mode === "blind" ? 2 : 1, pressNow = d.press != null ? 1 : 0;
  const unit = (1 + priorCarry) * mult * 2 ** (priorPresses + pressNow);
  const lock = !playing ? "disabled" : "";
  const modeBtns = [0, 1, 2, 3].filter((i) => i !== w).map((i) => `<button class="btn ghost vpick ${d.mode === "partner" && d.partner === i ? "on" : ""}" data-act="wfMode" data-v="p${i}" ${lock}>w/ ${esc(names[i])}</button>`).join("")
    + `<button class="btn ghost vpick ${d.mode === "lone" ? "on" : ""}" data-act="wfMode" data-v="lone" ${lock}>Lone Wolf</button>`
    + `<button class="btn ghost vpick ${d.mode === "blind" ? "on" : ""}" data-act="wfMode" data-v="blind" ${lock}>Blind Wolf</button>`;
  const worth = d.mode === "partner" ? `Each loser pays each winner <b>${unit}</b>.` : d.mode === "lone" ? `Lone Wolf wins <b>${unit}</b> from each player (${unit * 3}) or pays <b>${unit}</b> to each.`
    : d.mode === "blind" ? `Blind Wolf wins <b>${unit}</b> from each player (${unit * 3}) or pays <b>${unit}</b> to each.` : `Worth ${(1 + priorCarry) * 2 ** (priorPresses + pressNow)} a player${priorCarry ? ` (${priorCarry} rolled over)` : ""}. Blind Wolf doubles it.`;
  let press = "";
  if (d.press != null) press = `<div class="wfpress on"><span>⚡ <b>${esc(names[d.press])}</b> pressed: stakes double from this hole on.</span>${playing ? `<button class="btn quiet" data-act="wfPress" data-v="">Undo</button>` : ""}</div>`;
  else if (playing && !saved?.complete) press = `<div class="wfpress">${[0, 1, 2, 3].filter((i) => before[i] === low).map((i) => `<button class="btn ghost" data-act="wfPress" data-v="${i}">⚡ ${esc(names[i])} presses</button>`).join("")}<span class="sub">Last place can press before teeing off: stakes double from this hole to the end.</span></div>`;
  const rows = [0, 1, 2, 3].map((i) => `<div class="wfrow"><div class="wfname">${esc(names[i])}${i === w ? ` <span class="wftag">Wolf</span>` : ""}</div>
      <input id="wfS${i}" class="wfscore" type="number" inputmode="numeric" min="1" max="20" value="${d.scores[i] ?? ""}" placeholder="–" aria-label="${esc(names[i])} score" ${lock}>
      <div class="wfbon">${WF_BONUS.map(([k, l]) => `<button class="chipbtn" aria-pressed="${d[k].includes(i)}" data-act="wfBonus" data-v="${k}" data-i="${i}" ${lock}>${l}</button>`).join("")}</div></div>`).join("");
  const hole = `<article class="card wfcard">
    <div class="slip-top"><span class="cat">Hole ${hn}</span><span class="sub">Wolf: <b>${esc(names[w])}</b></span></div>
    <span class="lab">Wolf's call</span><div class="wfmodes">${modeBtns}</div><span class="sub">${worth}</span>
    ${press}
    <span class="lab">Scores and bonuses</span>${rows}
    ${saved?.complete ? `<div class="wfresult">${esc(saved.result)} · ${[0, 1, 2, 3].map((i) => esc(names[i]) + " " + signed(saved["d" + i])).join(", ")}</div>` : ""}
    ${playing ? `<div class="acts"><button class="btn primary" data-act="wfSave">Save hole ${hn}${hn < 18 ? " & next" : ""}</button></div>` : ""}
  </article>`;
  // scorecard
  const card = v.board.filter((x) => x.complete).map((x) => `<tr><td class="num">${x.hole}</td><td>${esc(names[x.wolf])}${x.mode === "lone" ? " (L)" : x.mode === "blind" ? " (B)" : ""}</td>${[0, 1, 2, 3].map((i) => `<td class="num ${tone(x["d" + i])}">${x["d" + i] ? signed(x["d" + i]) : "·"}</td>`).join("")}</tr>`).join("");
  const scorecard = card ? `<div class="table wfcardtbl"><table><thead><tr><th class="num">#</th><th>Wolf</th>${names.map((n) => `<th class="num">${esc(n.slice(0, 6))}</th>`).join("")}</tr></thead><tbody>${card}</tbody></table></div>` : "";
  let foot = "";
  if (playing) {
    foot = `<div class="acts">${S.wolf.confirm === "finish" ? `<button class="btn primary" data-act="wfFinish">Tap again to finish and book the points</button><button class="btn ghost" data-act="wfNo">Not yet</button>`
      : `<button class="btn" data-act="wfFinishAsk">Finish round</button>`}
      ${r.created_by === S.me ? (S.wolf.confirm === "delete" ? `<button class="btn ghost" data-act="wfDelete">Tap again to delete this round</button>` : `<button class="btn quiet" data-act="wfDeleteAsk">Delete round</button>`) : ""}</div>
      <span class="sub">Finishing books what each pair owes into Standings and Rivals. Any player can do it, and it can't be undone.</span>`;
  } else foot = `<div class="pksubmit done"><div class="pkdone">Round finished</div><span>Points are in Standings and Rivals.</span></div>`;
  const guests = r.players.filter((p) => !p.uid).map((p) => p.name);
  let invite = "";
  if (playing && r.code) {
    invite = `<div class="wfinvite"><span>${guests.length ? `<b>${esc(listNames(guests))}</b> ${guests.length === 1 ? "is a guest" : "are guests"}. Invite them to score on their own phones.` : "Everyone's on Handshake. Scores update live on all four phones."}</span><button class="btn ${guests.length ? "primary" : "ghost"}" data-act="wfInvite">${S.wolf.inviting ? "Hide invite" : "Invite players"}</button></div>`;
    if (S.wolf.inviting) {
      const text = wfInviteText(r);
      invite += `<div class="cpanel"><span class="lab">Round code <b class="mono">${esc(r.code)}</b></span><p class="msg">${esc(text)}</p>
        <div class="acts"><button class="btn primary" data-act="wfCopyInvite">Copy invite</button><a class="btn" href="${esc(smsHref("", text))}">Open Messages</a></div>
        <span class="sub">Opening the link puts them in a guest's spot. It opens the Handshake app if they have it.</span></div>`;
    }
  }
  return `<div style="display:flex;flex-direction:column;gap:14px">${head}${stakes}${table}${invite}${chips}${hole}${scorecard}${foot}</div>`;
}
function wfOpen(id) {
  wfUnsub();
  S.wolf.view = { id, hole: null, board: null, holes: [], draft: null, dirty: false }; S.wolf.confirm = null; S.wolf.inviting = false;
  render(); loadWolfRound(); wfSub(id);
}
/* live scoring: every player's screen refreshes when anyone saves */
let wfChan = null, wfLiveT = null;
function wfSub(id) {
  try {
    wfChan = sb.channel("wolf-" + id)
      .on("postgres_changes", { event: "*", schema: "public", table: "wolf_holes", filter: "round_id=eq." + id }, (e) => wfLive(e?.new?.hole ?? e?.old?.hole))
      .on("postgres_changes", { event: "*", schema: "public", table: "wolf_rounds", filter: "id=eq." + id }, () => wfLive(null))
      .subscribe();
  } catch (e) { wfChan = null; }
}
function wfUnsub() { if (wfChan) { try { sb.removeChannel(wfChan); } catch (e) {} wfChan = null; } }
function wfLive(hole) {
  clearTimeout(wfLiveT);
  wfLiveT = setTimeout(async () => {
    const v = S.wolf?.view; if (!v || S.tab !== "golf") return;
    wfCapture();
    const [b, h] = await Promise.all([sb.rpc("wolf_scoreboard", { p_round: v.id }), sb.from("wolf_holes").select("*").eq("round_id", v.id), loadWolf()]);
    if (b.error) return;
    v.board = b.data || v.board; v.holes = h.data || v.holes;
    if (!v.dirty) wfDraftFor(v.hole);
    else if (hole === v.hole) toast(`Someone else just saved hole ${hole}. Your changes are still here; save to keep them.`);
    render();
  }, 250);
}
async function wfJoin(code) {
  const { data, error } = await sb.rpc("wolf_round_preview", { p_code: code });
  const pv = data?.[0];
  if (error || !pv) return toast(error ? friendly(error) : "That round code doesn't match any round.");
  S.tab = "golf"; if (!S.wolf) await loadWolf();
  if (pv.is_player) { await loadWolf(); return wfOpen(pv.round_id); }
  if (pv.finished) return toast("That round is already finished.");
  if (!pv.guest_slots.length) return toast("All four spots in that round are taken.");
  if (pv.guest_slots.length === 1) return wfClaim(code, pv.guest_slots[0]);
  S.wolf.claim = { code, ...pv }; S.wolf.view = null; render();
}
async function wfClaim(code, slot) {
  const { data, error } = await sb.rpc("join_wolf_round", { p_code: code, p_slot: slot });
  if (error) return toast(friendly(error));
  S.wolf.claim = null; await loadWolf(); toast("You're in. Scores update live."); wfOpen(data);
}
async function wfCreate() {
  const err = (m) => { const e = $("#wfErr"); if (e) { e.textContent = m; e.hidden = false; } };
  const players = [];
  for (let i = 0; i < 4; i++) {
    const v = $("#wfSel" + i).value;
    if (!v) return err("Pick all four players.");
    if (v === "guest") { const n = $("#wfGuest" + i).value.trim(); if (!n) return err("Give every guest a name."); players.push({ name: n }); }
    else players.push({ uid: v });
  }
  const { data, error } = await sb.rpc("create_wolf_round", { p_course: $("#wfCourse").value.trim(), p_players: players });
  if (error) return err(friendly(error));
  S.wolf.starting = false; await loadWolf();
  if (players.some((p) => p.uid && p.uid !== S.me)) notifyQuiet({ wolf_round: data });
  wfOpen(data);
  if (players.some((p) => !p.uid)) S.wolf.inviting = true;
}
async function wfSave() {
  const v = S.wolf.view; wfCapture();
  const d = v.draft, hn = v.hole;
  if (d.mode === "partner" && d.partner == null) return toast("Pick the Wolf's partner.");
  const { error } = await sb.rpc("save_wolf_hole", { p_round: v.id, p_hole: hn, p_mode: d.mode, p_partner: d.partner, p_scores: d.scores,
    p_greenie: d.greenie, p_birdie: d.birdie, p_sandy: d.sandy, p_pressed_by: d.press });
  if (error) return toast(friendly(error));
  const complete = d.mode && d.scores.every((x) => x != null);
  toast(complete ? `Hole ${hn} saved` : `Hole ${hn} saved (not scored until the Wolf's call and all four scores are in)`);
  v.dirty = false;
  if (complete && hn < 18) v.hole = hn + 1;
  const [b, h] = await Promise.all([sb.rpc("wolf_scoreboard", { p_round: v.id }), sb.from("wolf_holes").select("*").eq("round_id", v.id)]);
  v.board = b.data || v.board; v.holes = h.data || v.holes;
  wfDraftFor(v.hole); render();
}
async function wfFinish() {
  const { data, error } = await sb.rpc("finish_wolf_round", { p_round: S.wolf.view.id });
  if (error) return toast(friendly(error));
  S.wolf.confirm = null; toast(`Round finished. ${data} result${data === 1 ? "" : "s"} booked.`);
  await Promise.all([loadWolf(), loadBets()]); loadWolfRound();
}
async function wfDelete() {
  const { error } = await sb.rpc("delete_wolf_round", { p_round: S.wolf.view.id });
  if (error) return toast(friendly(error));
  S.wolf.view = null; S.wolf.confirm = null; await loadWolf(); render(); toast("Round deleted.");
}

function render() {
  renderLedger(); renderBell();
  for (const t of ["board", "feed", "rivals", "vegas", "golf"]) $("#tab-" + t).setAttribute("aria-selected", S.tab === t);
  const v = $("#view");
  if (!S.loaded) { v.innerHTML = `<div class="empty"><h3>Opening the notebook…</h3><p>Pulling up every prediction on the board.</p></div>`; return; }
  v.innerHTML = S.tab === "golf" ? renderGolf() : S.tab === "feed" && S.pkView ? renderPickem() : S.tab === "vegas" ? renderVegas() : S.tab === "rivals" ? renderRivals() : S.tab === "feed" ? renderFeed() : renderBoard();
  const sel = $("#sortSel"); if (sel) sel.onchange = (e) => { S.sort = e.target.value; store.set("hs-sort", S.sort); render(); };
  S.fresh = null;
}

/* ---------- server calls ---------- */
function toast(msg) { const t = $("#toast"); t.textContent = msg; t.hidden = false; clearTimeout(toast.t); toast.t = setTimeout(() => (t.hidden = true), 2800); }
const friendly = (e) => {
  const m = String(e?.message || "");
  if (/fetch|network|Failed to/i.test(m)) return "Couldn't reach Handshake. Check your connection and try again.";
  if (/JWT|session/i.test(m)) return "Your sign-in expired. Reload the page and sign in again.";
  return m || "That didn't save. Try again.";
};
async function call(fn, args, okMsg, id) {
  if (id && S.busy.has(id)) return false;
  if (id) S.busy.add(id); render();
  try {
    const { data, error } = await sb.rpc(fn, args);
    if (error) throw error;
    S.picking = null;
    announce(typeof data === "string" && fn === "crash_prediction" ? data : args?.p_id);
    await loadBets();
    if (okMsg) toast(okMsg);
    return true;
  } catch (e) { toast(friendly(e)); return false; }
  finally { if (id) S.busy.delete(id); render(); }
}
/* copy the invite; if the clipboard is blocked, select the text so a long-press copy works */
async function copyFrom(text, b) {
  const them = b ? nameOf(b, other(negSide(b) || "a")) : "them";
  try { await navigator.clipboard.writeText(text); toast("Copied. Paste it into a text to " + them + "."); }
  catch (e) {
    const el = $("#msgText");
    if (el) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); }
    toast("Press and hold the highlighted message, then tap Copy.");
  }
}
async function copy(text, ok) {
  try { await navigator.clipboard.writeText(text); toast(ok || "Copied"); }
  catch (e) { toast("Copy didn't work here. Select the message and copy it."); }
}

const byId = (id) => S.bets.find((b) => b.id === id);
const ACT = {
  tab: (el) => { if (el.dataset.v !== "golf") wfUnsub(); else if (S.wolf?.view && !wfChan) wfSub(S.wolf.view.id); S.tab = el.dataset.v; S.picking = null; S.notify = null; S.pkView = null; if (S.tab === "feed") loadPickem().then(render).catch(() => {}); if (S.tab === "vegas" && S.lines && !S.linesErr) loadLines(); render(); },
  vegasPick: (el) => vegasPick(el.dataset.id, el.dataset.v),
  pkGo: () => { S.tab = "feed"; S.pkView = null; render(); window.scrollTo({ top: 0, behavior: "smooth" }); },
  pkName: () => { S.pkNaming = true; render(); setTimeout(() => $("#pkName")?.focus(), 30); },
  pkUnname: () => { S.pkNaming = false; render(); },
  pkCreate: () => pkCreate(),
  pkJoin: () => pkJoin($("#pkCode")?.value),
  pkInvite: (el) => { S.pkInviting = S.pkInviting === el.dataset.id ? null : el.dataset.id; render(); },
  pkCloseInvite: () => { S.pkInviting = null; render(); },
  pkCopyInvite: (el) => copy(pkInviteText(pkGroup(el.dataset.id)), "Invite copied. Paste it into your group text."),
  pkOpen: (el) => pkOpen(el.dataset.id),
  pkBack: () => { S.pkView = null; render(); },
  pkWeek: (el) => pkOpen(S.pkView.gid, weekShift(S.pkView.week, +el.dataset.v)),
  pkPick: (el) => pkPick(S.pkView.gid, el.dataset.id, el.dataset.v),
  pkTb: () => pkSaveTb(),
  wfStart: () => { S.wolf.starting = true; render(); },
  wfCancel: () => { S.wolf.starting = false; render(); },
  wfCreate: () => wfCreate(),
  wfOpen: (el) => wfOpen(el.dataset.id),
  wfBack: () => { wfUnsub(); S.wolf.view = null; S.wolf.confirm = null; loadWolf().then(render); render(); },
  wfInvite: () => { S.wolf.inviting = !S.wolf.inviting; render(); },
  wfCopyInvite: () => copy(wfInviteText(wfRound(S.wolf.view.id)), "Invite copied. Paste it into your group text."),
  wfJoinCode: () => wfJoin(($("#wfCode")?.value || "").trim().toUpperCase()),
  wfClaim: (el) => wfClaim(S.wolf.claim.code, +el.dataset.v),
  wfClaimNo: () => { S.wolf.claim = null; render(); },
  wfHole: (el) => { wfCapture(); S.wolf.view.dirty = false; wfDraftFor(+el.dataset.v); render(); },
  wfMode: (el) => { wfCapture(); S.wolf.view.dirty = true; const d = S.wolf.view.draft, x = el.dataset.v;
    if (x[0] === "p") { const p = +x.slice(1); if (d.mode === "partner" && d.partner === p) { d.mode = null; d.partner = null; } else { d.mode = "partner"; d.partner = p; } }
    else if (d.mode === x) d.mode = null; else { d.mode = x; d.partner = null; }
    render(); },
  wfBonus: (el) => { wfCapture(); S.wolf.view.dirty = true; const d = S.wolf.view.draft, k = el.dataset.v, i = +el.dataset.i; d[k] = d[k].includes(i) ? d[k].filter((x) => x !== i) : [...d[k], i]; render(); },
  wfPress: (el) => { wfCapture(); S.wolf.view.dirty = true; S.wolf.view.draft.press = el.dataset.v === "" ? null : +el.dataset.v; render(); },
  wfSave: () => wfSave(),
  wfFinishAsk: () => { S.wolf.confirm = "finish"; render(); },
  wfDeleteAsk: () => { S.wolf.confirm = "delete"; render(); },
  wfNo: () => { S.wolf.confirm = null; render(); },
  wfFinish: () => wfFinish(),
  wfDelete: () => wfDelete(),
  pkSubmit: () => pkSubmit(),
  pkBonus: (el) => pkBonus(el.dataset.id),
  pkCrash: (el) => pkCrash(el.dataset.id),
  pkLetIn: (el) => pkAnswer(el.dataset.id, el.dataset.v, true),
  pkSayNo: (el) => pkAnswer(el.dataset.id, el.dataset.v, false),
  filter: (el) => { S.filter = el.dataset.v; render(); },
  feedFilter: (el) => { S.feedFilter = el.dataset.v; S.crashing = null; render(); },
  new: () => openSheet(),
  rematch: (el) => openSheet(el.dataset.v, el.dataset.uid || null),
  cancel: () => { $("#sheet").hidden = true; },
  seg: (el) => setKind(el.dataset.v),
  quick: (el) => { $("#fPts").value = el.dataset.v; },
  pick: (el) => { S.picking = el.dataset.id; S.notify = null; render(); },
  unpick: () => { S.picking = null; render(); },
  export: () => exportCsv(),
  shook: (el) => call("mark_shook", { p_id: el.dataset.id }, "Booked for both of you", el.dataset.id),
  withdraw: (el) => call("withdraw_prediction", { p_id: el.dataset.id }, byId(el.dataset.id)?.parentId ? "Crash offer withdrawn" : "Prediction withdrawn", el.dataset.id),
  decline: (el) => call("decline_prediction", { p_id: el.dataset.id }, "Declined", el.dataset.id),
  sign: (el) => call("sign_prediction", { p_id: el.dataset.id }, byId(el.dataset.id)?.parentId ? "Crash accepted. Booked." : "You shook on it. Booked!", el.dataset.id),
  report: async (el) => {
    const b = byId(el.dataset.id), w = el.dataset.w, s = side(b);
    const sibs = $("#allSibs")?.checked ? siblings(b) : [];
    const ok = await call("report_result", { p_id: b.id, p_winner: w }, sibs.length ? null : "Result sent for confirmation", b.id);
    if (!ok || !sibs.length) return;
    let done = 0;
    for (const x of sibs) {
      const xs = side(x);
      const xw = w === "push" || w === "void" ? w : w === s ? xs : other(xs);
      const { error } = await sb.rpc("report_result", { p_id: x.id, p_winner: xw });
      if (!error) { done++; announce(x.id); }
    }
    await loadBets(); render();
    toast("Result sent to " + (done + 1) + " people for confirmation" + (done < sibs.length ? ". Some couldn't be updated; check those slips." : "."));
  },
  confirm: (el) => {
    const b = byId(el.dataset.id), w = b?.report?.winner;
    const msg = w === "void" ? "Called off" : w === "push" ? "Done and done. It's a tie, no points moved." : isOther(b) ? "Done and done. " + nameOf(b, w) + " wins: " + stakeLabel(b) : "Done and done. " + nameOf(b, w) + " takes " + pts(stakeOf(b));
    call("confirm_result", { p_id: el.dataset.id }, msg, el.dataset.id);
  },
  proveIt: async (el) => {
    const b = byId(el.dataset.id);
    const ok = await call("prove_it", { p_id: el.dataset.id }, (b ? nameOf(b, poster(b)) : "They") + " has 24 hours to post proof.", el.dataset.id);
    if (ok) { S.notify = { id: el.dataset.id, kind: "prove" }; render(); }
  },
  prove: (el) => { S.proving = el.dataset.id; S.proofDraft = {}; S.notify = null; render(); },
  unprove: () => { if (S.proofDraft.preview) URL.revokeObjectURL(S.proofDraft.preview); S.proving = null; S.proofDraft = {}; render(); },
  dropPhoto: () => { if (S.proofDraft.preview) URL.revokeObjectURL(S.proofDraft.preview); S.proofDraft = { link: S.proofDraft.link }; render(); },
  sendProof: (el) => sendProof(byId(el.dataset.id)),
  acceptProof: (el) => {
    const b = byId(el.dataset.id), w = b?.report?.winner;
    const msg = w === "void" ? "Called off" : w === "push" ? "Done and done. It's a tie, no points moved." : "Done and done. " + nameOf(b, w) + (isOther(b) ? " wins: " + stakeLabel(b) : " takes " + pts(stakeOf(b)));
    call("answer_proof", { p_id: el.dataset.id, p_accept: true, p_reason: null }, msg, el.dataset.id);
  },
  object: (el) => { S.objecting = el.dataset.id; S.objDraft = ""; S.notify = null; render(); setTimeout(() => $("#objText")?.focus(), 30); },
  unobject: () => { S.objecting = null; S.objDraft = ""; render(); },
  sendObject: (el) => sendObject(byId(el.dataset.id)),
  refPick: (el) => {
    const b = byId(el.dataset.id), w = el.dataset.w;
    call("referee_pick", { p_id: el.dataset.id, p_winner: w }, w === "push" ? "Called it a tie. Thanks, ref." : nameOf(b, w) + " wins. Thanks, ref.", el.dataset.id);
  },
  callOff: (el) => call("report_result", { p_id: el.dataset.id, p_winner: "void" }, "Asked to call it off", el.dataset.id),
  counter: (el) => { S.countering = el.dataset.id; S.counterDraft = {}; S.notify = null; render(); },
  uncounter: () => { S.countering = null; render(); },
  pickContact: () => pickContact(),
  bell: () => toggleBell(),
  pushOn: () => pushOn(),
  pushOff: () => pushOff(),
  goto: (el) => {
    if (!el.dataset.id) { toggleBell(); S.tab = "rivals"; render(); return; }
    const b = byId(el.dataset.id); toggleBell();
    S.tab = b && mineList().includes(b) ? "board" : "feed"; S.filter = "all"; S.feedFilter = "all"; render();
    setTimeout(() => document.getElementById("bet-" + el.dataset.id)?.scrollIntoView({ behavior: "smooth", block: "center" }), 60);
  },
  addOpp: () => {
    const err = (m) => { const p = $("#formErr"); p.textContent = m; p.hidden = false; };
    $("#formErr").hidden = true;
    const o = currentOpp();
    if (!o) return err("Type a name first, then add another person.");
    const bad = checkOpp(o, $("#fShook").checked); if (bad) return err(bad);
    S.opps.push(o); renderOpps(); clearOppInputs(); $("#fWith").focus();
  },
  removeOpp: (el) => { S.opps.splice(+el.dataset.i, 1); renderOpps(); },
  copyGroup: async () => {
    const text = groupMessage(S.groupInvite);
    try { await navigator.clipboard.writeText(text); toast("Copied. Paste it into your group text."); }
    catch (e) { const el = $("#groupText"); if (el) { const r = document.createRange(); r.selectNodeContents(el); const s = getSelection(); s.removeAllRanges(); s.addRange(r); } toast("Press and hold the highlighted message, then tap Copy."); }
  },
  closeGroup: () => { S.groupInvite = null; render(); },
  extend: (el) => { S.extending = el.dataset.id; S.notify = null; render(); },
  unextend: () => { S.extending = null; render(); },
  saveExtend: (el) => saveExtend(byId(el.dataset.id)),
  shakeIn: (el) => { $("#fShakeBy").value = localInput(Date.now() + Number(el.dataset.h) * 3600e3); },
  settle: (el) => { S.settling = el.dataset.k; render(); },
  unsettle: () => { S.settling = null; render(); },
  confirmSettle: async (el) => {
    const r = rivals().find((x) => x.key === el.dataset.k); if (!r) return;
    const { data, error } = await sb.rpc("settle_up", { p_other: r.uid, p_other_name: r.name });
    if (error) { toast(friendly(error)); return; }
    S.settling = null; await loadSettlements(); render();
    toast(`Settled. ${pts(data)} cleared with ${r.name}. Your all-time record stays.`);
    const mine = S.settlements.find((x) => x.user_uid === S.me && (r.uid ? x.other_uid === r.uid : false));
    if (mine) notifyQuiet({ settlement_id: mine.id });
  },
  sendSettleReq: async (el) => {
    const r = rivals().find((x) => x.key === el.dataset.k); if (!r || !r.uid) return;
    const { data, error } = await sb.rpc("request_settlement", { p_creditor: r.uid });
    if (error) { toast(friendly(error)); return; }
    S.settling = null; await loadSettlements(); render();
    toast(`Sent. ${r.name} has 24 hours to confirm or dispute it.`);
    notifyQuiet({ settlement_request_id: data });
  },
  answerSettle: async (el) => {
    const id = el.dataset.id, yes = el.dataset.v === "yes";
    const q = S.settleReqs.find((x) => x.id === id), who = q ? personName(q.requester_uid) || "them" : "them";
    const { error } = await sb.rpc("respond_settlement", { p_id: id, p_accept: yes });
    if (error) { toast(friendly(error)); await loadSettlements(); render(); return; }
    await loadSettlements(); render();
    toast(yes ? `Settled with ${who}. Your all-time record stays.` : `Disputed. ${who} still owes the points.`);
    notifyQuiet({ settlement_request_id: id });
  },
  fix: (el) => { S.fixing = el.dataset.id; S.notify = null; render(); },
  unfix: () => { S.fixing = null; render(); },
  saveFix: (el) => saveFix(byId(el.dataset.id)),
  cseg: (el) => { S.counterDraft.kind = el.dataset.v; render(); },
  sendCounter: (el) => sendCounter(byId(el.dataset.id)),
  acceptCounter: (el) => { const b = byId(el.dataset.id); call("accept_counter", { p_id: el.dataset.id }, "Deal. Booked for " + (b?.counter ? counterLabel(b.counter) : "the new stakes") + ".", el.dataset.id); },
  withdrawCounter: (el) => call("withdraw_counter", { p_id: el.dataset.id }, "Counter taken back", el.dataset.id),
  crash: (el) => { S.crashing = el.dataset.id; S.crashSide = null; S.crashDraft = {}; render(); },
  uncrash: () => { S.crashing = null; render(); },
  crashSide: (el) => { S.crashSide = el.dataset.v; render(); },
  sendCrash: (el) => sendCrash(byId(el.dataset.id)),
  notify: (el) => { S.notify = { id: el.dataset.id, kind: el.dataset.k }; S.picking = null; render(); },
  unnotify: () => { S.notify = null; render(); },
  copyMsg: (el) => copyFrom(message(byId(el.dataset.id), S.notify.kind).body, byId(el.dataset.id)),
  shareMsg: async (el) => {
    const m = message(byId(el.dataset.id), S.notify.kind);
    try { await navigator.share({ title: m.subject, text: m.body }); } catch (e) { if (e?.name !== "AbortError") copy(m.body, "Message copied instead"); }
  },
  pickPerson: (el) => pickPerson(el.dataset.id, el.dataset.name),
  restartAuth: () => {
    if (S.resetting) { S.resetting = false; $("#newPassField").hidden = true; $("#codeBtn").textContent = "Sign in"; setAuthNew(false); return showGate("phone"); }
    showGate(S.authMode);
  },
  authNew: () => setAuthNew(true),
  authBack: () => setAuthNew(false),
  showCode: () => { $("#codeForm").hidden = false; $("#gCode").focus(); },
  forgotPass: () => sendResetCode(),
  setVis: (el) => setVis(el.dataset.v),
  rename: () => { $("#gName").value = S.myName; showGate("name"); },
  signOut: async () => {
    try { const t = store.get("hs-app-push"); if (t) { await sb.from("app_push_devices").delete().eq("token", t); store.set("hs-app-push", ""); } } catch (e) {}
    try { const r = await navigator.serviceWorker?.getRegistration(); const s = r && (await r.pushManager.getSubscription());
      if (s) { await sb.from("push_subscriptions").delete().eq("endpoint", s.endpoint); await s.unsubscribe(); } } catch (e) {}
    await sb.auth.signOut(); location.reload();
  },
};
document.addEventListener("input", (e) => {
  if (/^wfS\d$/.test(e.target.id) && S.wolf?.view) S.wolf.view.dirty = true;
  if (e.target.id === "crashPts") S.crashDraft.pts = e.target.value;
  if (e.target.id === "cPts") S.counterDraft.pts = e.target.value;
  if (e.target.id === "cText") S.counterDraft.text = e.target.value;
  if (e.target.id === "proofLink") S.proofDraft.link = e.target.value;
  if (e.target.id === "objText") S.objDraft = e.target.value;
  if (e.target.id === "nPhone") {
    const n = e.target.value.replace(/[^\d+]/g, "");
    store.set(phoneKey(e.target.dataset.name), n);
    const b = byId(S.notify?.id), a = $("#smsLink");
    if (b && a) a.href = smsHref(n, message(b, S.notify.kind).body);
  }
});
document.addEventListener("change", (e) => {
  if (e.target.id === "proofFile") pickProofFile(e.target);
  if (/^wfSel\d$/.test(e.target.id)) { const g = $("#wfGuest" + e.target.id.slice(5)); if (g) { g.hidden = e.target.value !== "guest"; if (!g.hidden) g.focus(); } }
});
document.addEventListener("click", (e) => {
  const el = e.target.closest("[data-act]"); if (!el) return;
  const f = ACT[el.dataset.act]; if (f) { e.preventDefault(); f(el); }
});

async function sendCrash(b) {
  const err = (m) => { const e = $("#crashErr"); if (e) { e.textContent = m; e.hidden = false; } };
  if (!S.crashSide) return err("Pick a side to back.");
  let p = 0;
  if (!isOther(b)) { p = Math.round(parseFloat(S.crashDraft.pts ?? stakeOf(b))); if (!(p >= 1 && p <= 1000)) return err("Put between 1 and 1,000 points on the line."); }
  const Y = nameOf(b, other(S.crashSide));
  const ok = await call("crash_prediction", { p_id: b.id, p_side: S.crashSide, p_points: p }, "Crash offer sent. " + Y + " accepts next.", b.id);
  if (ok) { S.crashing = null; S.crashSide = null; S.crashDraft = {}; render(); }
}

/* ---------- new prediction ---------- */
$("#quick").innerHTML = [5, 10, 25, 50, 100].map((q) => `<button type="button" class="chipbtn" data-act="quick" data-v="${q}">${q}</button>`).join("");
$("#shakeQuick").innerHTML = [[1, "In 1 hour"], [3, "In 3 hours"], [24, "In 1 day"], [72, "In 3 days"]].map(([h, l]) => `<button type="button" class="chipbtn" data-act="shakeIn" data-h="${h}">${l}</button>`).join("");
$("#fShook").addEventListener("change", (e) => { $("#shakeByWrap").hidden = e.target.checked; });
function setKind(k) {
  S.stakeKind = k;
  $("#segPts").setAttribute("aria-pressed", k === "points"); $("#segOther").setAttribute("aria-pressed", k === "other");
  $("#ptsWrap").hidden = k !== "points"; $("#otherWrap").hidden = k !== "other";
}
/* Pick from contacts: the iPhone app uses the native picker; Android Chrome has a built-in one. */
const ContactsPlugin = capPlugin("Contacts");
const canPickContacts = !!ContactsPlugin || ("contacts" in navigator && "select" in (navigator.contacts || {}));
function bestNumber(list) {
  const nums = (list || []).filter((p) => p && (p.number || p.value));
  const mobile = nums.find((p) => /mobile|iphone|cell/i.test(p.label || p.type || ""));
  return (mobile || nums[0])?.number || (mobile || nums[0])?.value || "";
}
async function pickContact() {
  let name = "", phone = "";
  try {
    if (ContactsPlugin) {
      const res = await ContactsPlugin.pickContact({ projection: { name: true, phones: true } });
      const c = res?.contact || {};
      name = c.name?.given || c.name?.display || "";
      phone = bestNumber(c.phones);
    } else {
      const [c] = await navigator.contacts.select(["name", "tel"], { multiple: false });
      if (!c) return;
      name = (c.name?.[0] || "").split(" ")[0];
      phone = c.tel?.[0] || "";
    }
  } catch (e) {
    if (/denied|permission/i.test(String(e?.message || e))) toast("Handshake needs contacts access for this. Turn it on in Settings, under Handshake.");
    return;
  }
  if (!name && !phone) return;
  S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; $("#withPhoneWrap").hidden = false;
  $("#fWith").value = name; $("#fWithPhone").value = phone;
  if (!phone) toast("That contact has no phone number. Type theirs in.");
}
function pickPerson(uid, name) {
  $("#fWith").value = name; S.pickedUid = uid; S.pickedName = name; $("#peopleList").hidden = true; $("#withPhoneWrap").hidden = true;
  const pn = $("#pickNote"); pn.textContent = "Only " + name + " can shake on this one."; pn.hidden = false;
}
function searchPeople(q) {
  const box = $("#peopleList");
  const ql = q.toLowerCase();
  const hits = S.people.filter((p) => p.id !== S.me && (!ql || p.name.toLowerCase().includes(ql))).slice(0, 6);
  if (!hits.length || document.activeElement !== $("#fWith")) { box.hidden = true; return; }
  box.innerHTML = hits.map((h) => `<button type="button" data-act="pickPerson" data-id="${esc(h.id)}" data-name="${esc(h.name)}"><span class="av">${esc(initials(h.name))}</span><span>${esc(h.name)}</span></button>`).join("");
  box.hidden = false;
}
$("#fWith").addEventListener("focus", () => searchPeople($("#fWith").value.trim()));
$("#fWith").addEventListener("input", (e) => {
  const v = e.target.value;
  if (S.pickedUid && v !== S.pickedName) { S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; $("#withPhoneWrap").hidden = false; }
  searchPeople(v.trim());
});
$("#fWith").addEventListener("blur", () => setTimeout(() => { if (!$("#peopleList").contains(document.activeElement)) $("#peopleList").hidden = true; }, 200));
$("#peopleList").addEventListener("pointerdown", (e) => e.preventDefault()); // keep focus so the tap lands

/* People added to this call so far. Each one gets their own one-on-one prediction. */
function currentOpp() {
  const name = $("#fWith").value.trim();
  if (!name) return null;
  const picked = S.pickedUid && name === S.pickedName;
  return { name, uid: picked ? S.pickedUid : null, phone: picked ? null : normPhone($("#fWithPhone").value), rawPhone: $("#fWithPhone").value.trim() };
}
function checkOpp(o, shook) {
  if (!o.uid && o.name.toLowerCase() === S.myName.toLowerCase()) return "You can't predict against yourself. Check the name.";
  if (!o.uid && !shook && !o.phone) return "Add " + o.name + "'s mobile number so only they can shake on it, or pick them from the list if they're already on Handshake.";
  if (S.opps.some((x) => (o.uid && x.uid === o.uid) || (o.phone && x.phone === o.phone))) return o.name + " is already on this call.";
  return null;
}
function clearOppInputs() {
  $("#fWith").value = ""; $("#fWithPhone").value = "";
  S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; $("#withPhoneWrap").hidden = false;
}
function renderOpps() {
  const box = $("#oppList");
  box.hidden = !S.opps.length;
  box.innerHTML = S.opps.map((o, i) => `<span class="opp"><span>${esc(o.name)} <small>${o.uid ? "on Handshake" : o.phone ? esc(prettyPhone(o.phone)) : "in person"}</small></span><button type="button" aria-label="Remove ${esc(o.name)}" data-act="removeOpp" data-i="${i}">×</button></span>`).join("");
  $("#fWithLabel").textContent = S.opps.length ? "Add someone else (optional)" : "Who says you're wrong?";
}
const listNames = (ns) => (ns.length < 2 ? ns.join("") : ns.slice(0, -1).join(", ") + " and " + ns[ns.length - 1]);
function groupMessage(g) {
  const due = g.due ? `, decided by ${niceDate(g.due)}` : "";
  const allOn = g.opps.every((o) => o.uid), someOn = g.opps.some((o) => o.uid);
  const until = g.shakeBy ? ` You have until ${deadlineText(g.shakeBy)}.` : "";
  return `${listNames(g.opps.map((o) => o.name))}, I'm calling it: "${g.title}" for ${g.stake}${due}. That's me against each of you.${until} `
    + (allOn ? `It's on Handshake: ${PAGE_URL}` : `Sign ${someOn ? "in or sign up" : "up"} on Handshake with your own phone number: ${PAGE_URL}`)
    + ` I'll be waiting for you to shake on it.`;
}
function groupInviteBox() {
  const g = S.groupInvite; if (!g) return "";
  return `<div class="ginvite"><span class="lab">Group invite</span>
    <p class="msg" id="groupText">${esc(groupMessage(g))}</p>
    <div class="acts"><button class="btn primary" data-act="copyGroup">Copy invite</button><button class="btn ghost" data-act="closeGroup">Close</button></div>
    <span class="sub">Paste it into your group text. Each person signs up with their own number, and their prediction will be waiting.</span></div>`;
}
function exactInput(ms) {
  const d = new Date(ms);
  return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate()) + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes());
}
function openSheet(withName, uid, preset) {
  $("#pickContactBtn").hidden = !canPickContacts;
  $("#betForm").reset(); $("#formErr").hidden = true; setKind("points"); setVis("all"); S.opps = []; renderOpps();
  S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; $("#peopleList").hidden = true; $("#withPhoneWrap").hidden = false;
  $("#fDue").value = addDays(7); $("#fPts").value = 10; $("#fShakeBy").value = localInput(Date.now() + DAY); $("#shakeByWrap").hidden = false;
  if (withName) { if (uid) pickPerson(uid, withName); else $("#fWith").value = withName; }
  if (preset) {
    $("#fTitle").value = preset.title; $("#fTerms").value = preset.terms; $("#fCat").value = "Sports";
    if (preset.due) $("#fDue").value = preset.due;
    if (preset.shakeBy) $("#fShakeBy").value = exactInput(Math.min(preset.shakeBy, Date.now() + 14 * DAY));
  }
  $("#sheet").hidden = false; $("#sheet").scrollIntoView({ behavior: "smooth", block: "start" });
  setTimeout(() => (preset ? $("#fWith") : $("#fTitle")).focus({ preventScroll: true }), 250);
}
$("#betForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = (m) => { const p = $("#formErr"); p.textContent = m; p.hidden = false; };
  const title = $("#fTitle").value.trim();
  const p = Math.round(parseFloat($("#fPts").value)), otherText = $("#fOther").value.trim();
  if (!title) return err("Say what you're predicting, like “Lakers win tonight.”");
  if (S.stakeKind === "points" && !(p >= 1 && p <= 1000)) return err("Put between 1 and 1,000 points on the line.");
  if (S.stakeKind === "other" && !otherText) return err("Say what the loser owes, like “Loser buys the first round.”");
  const shook = $("#fShook").checked;
  const shakeBy = shook ? null : readShakeBy("#fShakeBy");
  if (!shook && !shakeBy) return err("Pick a shake-by time so they know how long they have.");
  if (!shook && shakeBy <= Date.now() + 60000) return err("Pick a shake-by time that hasn't passed yet.");
  const cur = currentOpp();
  if (cur) { const bad = checkOpp(cur, shook); if (bad) return err(bad); }
  const opps = cur ? [...S.opps, cur] : S.opps.slice();
  if (!opps.length) return err("Add who's taking the other side.");
  const btn = $("#saveBtn"); btn.disabled = true;
  const made = [];
  try {
    for (const o of opps) {
      const { data, error } = await sb.rpc("create_prediction", {
        p_title: title, p_with_name: o.name, p_invited: o.uid, p_invited_phone: o.phone,
        p_category: $("#fCat").value, p_stake_kind: S.stakeKind, p_points: S.stakeKind === "points" ? p : 0,
        p_stake_text: S.stakeKind === "other" ? otherText : "", p_due: $("#fDue").value || null, p_terms: $("#fTerms").value.trim(), p_shook: shook,
        p_shake_by: shakeBy ? new Date(shakeBy).toISOString() : null,
        ...(S.vis && S.vis !== "all" ? { p_visibility: S.vis } : {}),
      });
      if (error) throw Object.assign(error, { who: o.name });
      if (o.phone) store.set(phoneKey(o.name), o.phone);
      if (o.uid) announce(data);
      made.push({ ...o, id: data });
    }
  } catch (x) {
    btn.disabled = false;
    if (made.length) { S.opps = opps.filter((o) => !made.some((m) => m.name === o.name)); renderOpps(); clearOppInputs(); await loadBets(); render(); }
    return err((made.length ? "Added " + listNames(made.map((m) => m.name)) + ", but not " + x.who + ": " : "") + friendly(x));
  }
  btn.disabled = false;
  S.fresh = made[0]?.id; $("#sheet").hidden = true; S.tab = "board"; S.filter = "all"; S.opps = [];
  const stake = S.stakeKind === "points" ? pts(p) : otherText;
  if (!shook && made.length > 1) S.groupInvite = { title, stake, due: $("#fDue").value || "", shakeBy, opps: made };
  else if (!shook && made[0]) S.notify = { id: made[0].id, kind: "invite" };
  await loadBets(); render();
  if (shook) toast(made.length > 1 ? "Booked with " + listNames(made.map((m) => m.name)) + "." : "Booked for both of you");
  else if (made.length > 1) { toast("On the board with " + made.length + " people. Copy the group invite."); window.scrollTo({ top: $("#view").offsetTop - 10, behavior: "smooth" }); }
  else { toast("On the board. Let " + made[0].name + " know so they can shake on it."); document.getElementById("bet-" + made[0].id)?.scrollIntoView({ behavior: "smooth", block: "center" }); }
});

/* ---------- export ---------- */
function exportCsv() {
  if (!S.bets.length) return toast("No predictions to export yet");
  const cols = ["Slip", "Prediction", "Category", "Who can see it", "Called by", "Other side", "Stake", "Status", "Winner", "Decided by", "Terms", "Created"];
  const q = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const rows = S.bets.map((b) => [shortNo(b.id), b.title, b.category, VIS[b.visibility || "all"][0], nameOf(b, "a"), nameOf(b, "b"), stakeLabel(b), LABEL[b.status], b.winner === "push" ? "Tie" : b.winner ? nameOf(b, b.winner) : "", b.due, b.terms, b.createdAt ? new Date(b.createdAt).toISOString().slice(0, 10) : ""].map(q).join(","));
  const blob = new Blob([[cols.map(q).join(","), ...rows].join("\n")], { type: "text/csv" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "handshake-predictions.csv";
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

/* ---------- data loading ---------- */
/* the other side's number on each of my predictions, so Open Messages fills in the recipient */
async function loadPhones() {
  try {
    const { data, error } = await sb.rpc("rival_phones");
    if (!error && data) { S.phones = new Map(data.map((x) => [x.prediction_id, x.phone])); if (S.notify) render(); }
  } catch (e) {}
  try {
    const { data, error } = await sb.rpc("referee_phones");
    if (!error && data) { S.refPhones = new Map(data.map((x) => [x.prediction_id, x.phone])); if (S.notify) render(); }
  } catch (e) {}
}
async function loadBets() {
  loadPhones();
  try { await sb.rpc("settle_overdue"); } catch (e) {}  // results nobody disputed in 24 hours count now
  announceAutoResults();
  const { data, error } = await sb.from("predictions").select("*").order("created_at", { ascending: false }).limit(2000);
  if (error) throw error;
  S.bets = data.map(fromRow); S.loaded = true;
  loadTotals();
  const inv = await sb.rpc("my_invites");
  S.myInvites = new Set((inv.data || []).map((x) => (typeof x === "string" ? x : x.my_invites || Object.values(x)[0])));
}
/* standings for everyone, and the running total in the header */
async function loadTotals() {
  try {
    const { data, error } = await sb.rpc("standings");
    if (!error && Array.isArray(data)) { S.serverStandings = data; if (S.tab === "rivals") render(); }
  } catch (e) {}
  loadCount();
}
async function loadCount() {
  try {
    const { data, error } = await sb.rpc("prediction_count");
    const n = Number(data);
    if (error || !Number.isFinite(n) || n < 1) return;
    const el = $("#predCount");
    el.textContent = n.toLocaleString("en-US") + (n === 1 ? " Prediction" : " Predictions") + " and Counting!";
    el.hidden = false;
  } catch (e) {}
}
async function loadSettlements() {
  const { data, error } = await sb.from("settlements").select("*").order("created_at", { ascending: false }).limit(1000);
  if (!error && data) S.settlements = data;
  const r2 = await sb.from("settlement_requests").select("*").order("created_at", { ascending: false }).limit(500);
  if (!r2.error && r2.data) S.settleReqs = r2.data;
}
async function loadPeople() {
  const { data } = await sb.from("profiles").select("id,name").order("name");
  if (data) S.people = data;
}
let reloadT = null;
function liveUpdates() {
  sb.channel("board")
    .on("postgres_changes", { event: "*", schema: "public", table: "predictions" }, () => {
      clearTimeout(reloadT);
      reloadT = setTimeout(async () => { try { await loadBets(); await loadPeople(); render(); } catch (e) {} }, 250);
    })
    .on("postgres_changes", { event: "*", schema: "public", table: "settlements" }, () => { loadSettlements().then(render).catch(() => {}); })
    .on("postgres_changes", { event: "*", schema: "public", table: "settlement_requests" }, () => { loadSettlements().then(render).catch(() => {}); })
    .subscribe();
  document.addEventListener("visibilitychange", async () => { if (!document.hidden) { try { await loadBets(); await loadPeople(); await loadSettlements(); await loadPickem().catch(() => {}); if (S.pkView) loadPkWeek(); if (S.wolf?.view) loadWolfRound(); render(); } catch (e) {} } });
}

/* ---------- what's new: activity since your last look ---------- */
const seenKey = () => "hs-seen:" + S.me;
function lastSeen() {
  const v = Number(store.get(seenKey()) || 0);
  if (!v) { const start = Date.now() - 3 * DAY; store.set(seenKey(), String(start)); return start; }
  return v;
}
function involvesMe(b) { return !!(side(b) || negSide(b) || invitedMe(b) || b.a?.uid === S.me || b.counter?.uid === S.me || (S.me && b.referee?.uid === S.me)); }
function activity() {
  const items = [];
  for (const b of S.bets) {
    if (!involvesMe(b)) continue;
    for (const e of b.log || []) {
      const mine = e.uid ? e.uid === S.me : (e.by || "") === S.myName;
      if (mine || !e.t) continue;
      const auto = e.what || "updated";
      let text = e.by === "Handshake" ? (b.parentId ? "Your crash " + auto : auto[0].toUpperCase() + auto.slice(1)) : (e.by || "Someone") + " " + (e.what || "made a move");
      if (e.by === "Handshake" && /^picked .* to referee$/.test(auto) && b.referee?.uid === S.me) text = "You've been picked to referee";
      items.push({ t: Date.parse(e.t), text, title: b.title, id: b.id });
    }
  }
  const fromReq = (x) => S.settleReqs.some((q) => q.status === "confirmed" && q.requester_uid === S.me && q.creditor_uid === x.user_uid && Math.abs(Date.parse(q.resolved_at) - Date.parse(x.created_at)) < 10000);
  for (const q of S.settleReqs) {
    const other = q.requester_uid === S.me ? q.creditor_uid : q.requester_uid, who = personName(other) || "Someone";
    if (q.creditor_uid === S.me) items.push({ t: Date.parse(q.created_at), text: `${who} says you're settled up on ${pts(q.points)}`, title: "Confirm or dispute it within 24 hours. After that, it counts.", id: "", rivals: true });
    if (q.resolved_by === "auto") items.push({ t: Date.parse(q.resolved_at), text: `Settle-up with ${who} counted after 24 hours`, title: pts(q.points) + " cleared. Your all-time record stays.", id: "", rivals: true });
    else if (q.requester_uid === S.me && q.resolved_at && q.status !== "pending") items.push({ t: Date.parse(q.resolved_at), text: `${who} ${q.status === "disputed" ? "disputed" : "confirmed"} your settle-up`, title: q.status === "disputed" ? "The " + pts(q.points) + " still stands" : "Your balance with " + who + " is back to zero", id: "", rivals: true });
  }
  for (const x of S.settlements) {
    if (x.user_uid === S.me || fromReq(x)) continue;
    const who = personName(x.user_uid) || "Someone";
    items.push({ t: Date.parse(x.created_at), text: `${who} settled up: ${pts(x.points)} cleared`, title: "Your balance with " + who + " is back to zero", id: "", rivals: true });
  }
  return items.sort((x, y) => y.t - x.t).slice(0, 40);
}
function ago(t) {
  const m = Math.round((Date.now() - t) / 60000);
  if (m < 1) return "now"; if (m < 60) return m + "m"; const h = Math.round(m / 60); if (h < 24) return h + "h";
  return Math.round(h / 24) + "d";
}
function renderBell() {
  const btn = $("#bellBtn"); if (!S.me || !btn) return;
  const seen = lastSeen(), items = activity(), unread = items.filter((i) => i.t > seen).length;
  const c = $("#bellCount"); c.hidden = !unread; c.textContent = unread > 9 ? "9+" : unread;
  document.title = unread ? `(${unread}) Handshake` : "Handshake";
  if ($("#bellPanel").hidden) return;
  $("#activityList").innerHTML = items.length
    ? items.map((i) => `<button class="act-item ${i.t > S.bellSeenAt ? "unread" : ""}" data-act="goto" data-id="${i.id}"><span class="what">${esc(i.text)}<small>${esc(i.title)}</small></span><span class="when">${ago(i.t)}</span></button>`).join("")
    : `<p class="sub">Nothing yet. When someone shakes on, counters, declines or settles one of your predictions, it shows up here.</p>`;
  renderPushBox();
}
function toggleBell() {
  const p = $("#bellPanel");
  if (p.hidden) { S.bellSeenAt = lastSeen(); p.hidden = false; store.set(seenKey(), String(Date.now())); renderBell(); p.scrollIntoView({ behavior: "smooth", block: "start" }); }
  else { p.hidden = true; renderBell(); }
}

/* ---------- push notifications ---------- */
const VAPID = window.HANDSHAKE_CONFIG?.vapidPublicKey || "";
const isIOS = /iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
const standalone = () => window.matchMedia?.("(display-mode: standalone)").matches || navigator.standalone === true;
const pushSupported = () => !IN_APP && "serviceWorker" in navigator && "PushManager" in window && "Notification" in window && !!VAPID;
let swReg = null;
if (!IN_APP && "serviceWorker" in navigator && /^https?:$/.test(location.protocol)) {
  navigator.serviceWorker.register("sw.js").then((r) => { swReg = r; renderPushBox(); }).catch(() => {});
  navigator.serviceWorker.addEventListener?.("message", (e) => { if (e.data?.type === "refresh") loadBets().then(render).catch(() => {}); });
}
async function pushStatus() {
  if (IN_APP) {
    if (!AppPush) return "app-unsupported";
    try {
      const perm = (await AppPush.checkPermissions()).receive;
      if (perm === "granted") return store.get("hs-app-push") ? "on" : "app-off";
      if (perm === "denied") return "app-denied";
    } catch (e) { return "app-unsupported"; }
    return "app-off";
  }
  if (isIOS && !standalone()) return "ios-home";
  if (!pushSupported()) return "unsupported";
  if (Notification.permission === "denied") return "denied";
  try { const r = swReg || (await navigator.serviceWorker.getRegistration()); if (r && (await r.pushManager.getSubscription())) return "on"; } catch (e) {}
  return "off";
}
async function renderPushBox() {
  const box = $("#pushBox"); if (!box || $("#bellPanel").hidden) return;
  const st = await pushStatus();
  const html = {
    on: `<span>Notifications are on for this device.</span><button class="btn quiet" data-act="pushOff">Turn off</button>`,
    off: `<span>Get a notification when someone shakes on, counters or declines your predictions.</span><button class="btn primary" data-act="pushOn">Turn on notifications</button>`,
    "ios-home": `<span>On iPhone, notifications work once Handshake is on your Home Screen. In Safari, tap <b>Share</b>, then <b>Add to Home Screen</b>, open Handshake from there, and come back here.</span>`,
    denied: `<span>Notifications are blocked for this site. Allow them in your browser's site settings, then reload.</span>`,
    unsupported: `<span>This browser can't show notifications from websites.</span>`,
    "app-off": `<span>Get a notification when someone shakes on, counters, declines or settles your predictions.</span><button class="btn primary" data-act="pushOn">Turn on notifications</button>`,
    "app-denied": `<span>Notifications are off for Handshake. Turn them on in your iPhone's Settings, under Handshake, then Notifications.</span>`,
    "app-unsupported": ``,
  }[st];
  box.className = html ? "pushbox" : ""; box.innerHTML = html || "";
}
function keyBytes(b64) {
  const s = (b64 + "=".repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, "+").replace(/_/g, "/");
  return Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
}
/* ---------- notifications in the iPhone app (Apple push) ---------- */
const AppPush = capPlugin("PushNotifications");
let appPushReady = false;
async function saveAppToken(token) {
  if (!token || !S.me) return;
  const { error } = await sb.from("app_push_devices").upsert({ token, user_id: S.me, platform: "ios" });
  if (!error) { store.set("hs-app-push", token); renderPushBox(); }
}
/* the app icon's number counts notifications since the app was last opened; opening it clears it */
function clearBadge() { if (IN_APP && S.me && !document.hidden) sb.rpc("clear_badge").then(() => {}, () => {}); }
document.addEventListener("visibilitychange", clearBadge);
function setupAppPush() {
  if (!AppPush || appPushReady) return;
  appPushReady = true;
  AppPush.addListener("registration", (t) => { S.pendingAppToken = t.value; saveAppToken(t.value); });
  AppPush.addListener("registrationError", () => toast("Couldn't turn on notifications. Try again in a moment."));
  AppPush.addListener("pushNotificationReceived", () => loadBets().then(render).catch(() => {}));
  AppPush.addListener("pushNotificationActionPerformed", () => loadBets().then(render).catch(() => {}));
  // already allowed on this phone: refresh the device token, which Apple can change
  AppPush.checkPermissions().then((p) => { if (p.receive === "granted") AppPush.register(); }).catch(() => {});
}
async function appPushOn() {
  try {
    const p = await AppPush.requestPermissions();
    if (p.receive !== "granted") { toast("Notifications weren't allowed. You can turn them on in Settings, under Handshake."); return renderPushBox(); }
    await AppPush.register();
    toast("Notifications are on for this phone.");
  } catch (e) { toast("Couldn't turn on notifications: " + (e?.message || e)); }
}
async function appPushOff() {
  const t = store.get("hs-app-push");
  try { if (t) await sb.from("app_push_devices").delete().eq("token", t); await AppPush.unregister?.(); } catch (e) {}
  store.set("hs-app-push", ""); toast("Notifications are off for this phone."); renderPushBox();
}
/* results that counted after 24 hours: hand any unannounced ones to the notify function (it sends each once) */
let lastAutoCheck = 0;
async function announceAutoResults() {
  if (Date.now() - lastAutoCheck < 60000) return;
  lastAutoCheck = Date.now();
  try {
    const { data } = await sb.rpc("pending_auto_announcements");
    for (const row of data || []) {
      const id = typeof row === "string" ? row : row.pending_auto_announcements || Object.values(row)[0];
      sb.functions.invoke("notify", { body: { prediction_id: id, auto: true } }).catch(() => {});
    }
  } catch (e) {}
  try {
    const { data } = await sb.rpc("pending_settlement_announcements");
    for (const row of data || []) {
      const id = typeof row === "string" ? row : row.pending_settlement_announcements || Object.values(row)[0];
      notifyQuiet({ settlement_request_id: id, auto: true });
    }
  } catch (e) {}
}
function notifyQuiet(body) { try { sb.functions.invoke("notify", { body }).catch(() => {}); } catch (e) {} }
async function pushOn() {
  if (IN_APP) return appPushOn();
  try {
    const perm = await Notification.requestPermission();
    if (perm !== "granted") { toast("Notifications weren't allowed. You can change that in your browser's site settings."); return renderPushBox(); }
    const reg = swReg || (await navigator.serviceWorker.ready);
    const sub = (await reg.pushManager.getSubscription()) || (await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(VAPID) }));
    const j = sub.toJSON();
    const { error } = await sb.from("push_subscriptions").upsert({ endpoint: j.endpoint, user_id: S.me, p256dh: j.keys.p256dh, auth: j.keys.auth });
    if (error) throw error;
    toast("Notifications are on for this device.");
  } catch (e) { toast("Couldn't turn on notifications: " + (e?.message || e)); }
  renderPushBox();
}
async function pushOff() {
  if (IN_APP) return appPushOff();
  try {
    const reg = swReg || (await navigator.serviceWorker.getRegistration());
    const sub = reg && (await reg.pushManager.getSubscription());
    if (sub) { await sb.from("push_subscriptions").delete().eq("endpoint", sub.endpoint); await sub.unsubscribe(); }
    toast("Notifications are off for this device.");
  } catch (e) { toast("Couldn't turn off notifications. Try again."); }
  renderPushBox();
}
/* tell the other side about what just happened; never blocks or bothers the person acting */
function announce(predictionId) {
  if (!sb || !predictionId) return;
  sb.functions.invoke("notify", { body: { prediction_id: predictionId } }).catch(() => {});
}

/* ---------- sign-in ---------- */
function showGate(which) {
  $("#gatePhone").hidden = which !== "phone"; $("#gateCode").hidden = which !== "code"; $("#gateName").hidden = which !== "name";
  $("#app").hidden = !!which; $("#newBtn").hidden = !!which; $("#who").hidden = !!which; $("#bellBtn").hidden = !!which;
  if (which) $("#bellPanel").hidden = true;
  const f = which === "phone" ? "#gPhone" : which === "code" ? "#gCode" : which === "name" ? "#gName" : null;
  if (f) setTimeout(() => $(f).focus(), 50);
}
/* US numbers can be typed any way; anything else needs a leading + and country code */
function normPhone(v) {
  const t = v.trim(), d = t.replace(/\D/g, "");
  if (t.startsWith("+")) return d.length >= 8 && d.length <= 15 ? "+" + d : null;
  if (d.length === 10) return "+1" + d;
  if (d.length === 11 && d[0] === "1") return "+" + d;
  return null;
}
const prettyPhone = (p) => (p.startsWith("+1") && p.length === 12 ? `(${p.slice(2, 5)}) ${p.slice(5, 8)}-${p.slice(8)}` : p);
/* Phone number + password. No texts or emails are sent, so nothing outside Supabase can block sign-in. */
let authNew = store.get("hs-returning") !== "1";
function setAuthNew(v) {
  authNew = v;
  $("#modeNew").setAttribute("aria-pressed", v); $("#modeBack").setAttribute("aria-pressed", !v);
  $("#phoneHelp").textContent = v ? "Use your mobile number and pick a password. You'll stay signed in on this device." : "Sign in with your mobile number and password.";
  $("#passHint").hidden = !v; $("#gPass").autocomplete = v ? "new-password" : "current-password";
  $("#phoneBtn").textContent = v ? "Create my account" : "Sign in"; $("#phoneErr").hidden = true;
  $("#forgotBtn").hidden = v;
}
setAuthNew(authNew);
$("#phoneForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#phoneErr"); err.hidden = true;
  const fail = (m) => { err.textContent = m; err.hidden = false; };
  const phone = normPhone($("#gPhone").value), password = $("#gPass").value;
  if (!phone) return fail("Enter a 10-digit US number, or a + and country code for other countries.");
  if (password.length < 6) return fail(authNew ? "Pick a password with at least 6 characters." : "Enter your password.");
  const btn = $("#phoneBtn"); btn.disabled = true; btn.textContent = authNew ? "Creating…" : "Signing in…";
  const res = authNew ? await sb.auth.signUp({ phone, password }) : await sb.auth.signInWithPassword({ phone, password });
  btn.disabled = false; setAuthNew(authNew);
  if (res.error) {
    const m = res.error.message || "";
    if (/already registered|already exists/i.test(m)) { setAuthNew(false); return fail("That number already has an account. Enter its password to sign in."); }
    if (/invalid login credentials/i.test(m)) return fail("That number and password don't match. Check both, or tap Forgot your password? below.");
    if (/not confirmed/i.test(m)) return fail("This account is waiting on a text confirmation. Ask the organizer to switch off phone confirmations in Supabase.");
    if (/weak|password/i.test(m)) return fail(m);
    if (/rate limit|too many/i.test(m)) return fail("Too many tries just now. Wait a few minutes and try again.");
    return fail("Couldn't sign in: " + m);
  }
  if (!res.data?.session) return fail("Your account was created but needs a text confirmation first. The organizer needs to switch off phone confirmations in Supabase.");
  store.set("hs-returning", "1"); S.authMode = "phone";
  await enter();
});
/* Forgot password: Supabase texts a 6-digit code (through Twilio Verify), the code signs you in,
   and you pick a new password in the same step. Only works for numbers that already have an account. */
async function sendResetCode() {
  const err = $("#phoneErr"); err.hidden = true;
  const fail = (m) => { err.textContent = m; err.hidden = false; };
  const phone = normPhone($("#gPhone").value);
  if (!phone) return fail("Enter your mobile number above first, then tap Forgot your password? again.");
  const btn = $("#forgotBtn"); btn.disabled = true; btn.textContent = "Texting you a code…";
  const { error } = await sb.auth.signInWithOtp({ phone, options: { shouldCreateUser: false } });
  btn.disabled = false; btn.textContent = "Forgot your password?";
  if (error) {
    const m = error.message || "";
    if (/^unsupported phone provider|phone (provider|signups|logins)[^:]*(is )?disabled|sms provider (is )?not (configured|enabled)/i.test(m)) return fail("Password reset by text isn't switched on yet. Ask the organizer to reset your password.");
    if (/sending .*otp|twilio|verify/i.test(m)) return fail("The text couldn't be sent: " + m.replace(/^error sending [^:]*:\s*/i, ""));
    if (/signups? not allowed|not found|no user/i.test(m)) return fail("There's no account with that number. Check it, or tap I'm new.");
    if (/rate limit|too many|security purposes/i.test(m)) return fail("A code was just sent. Wait a minute, then try again.");
    return fail("Couldn't text a code: " + m);
  }
  S.phone = phone; S.authMode = "phone"; S.resetting = true;
  $("#codeTitle").textContent = "Reset your password";
  $("#codeSentTo").textContent = "We texted a 6-digit code to " + prettyPhone(phone) + ". It can take a minute to arrive.";
  $("#codeLinkHelp").hidden = true; $("#showCodeBtn").hidden = true;
  $("#restartBtn").textContent = "Back to sign in";
  $("#gCode").value = ""; $("#gNewPass").value = ""; $("#newPassField").hidden = false;
  $("#codeBtn").textContent = "Save new password and sign in";
  $("#codeErr").hidden = true; $("#codeForm").hidden = false; showGate("code");
}
$("#unusedOtpForm")?.addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#phoneErr"); err.hidden = true;
  const phone = normPhone($("#gPhone").value);
  if (!phone) { err.textContent = "Enter a 10-digit US number, or a + and country code for other countries."; err.hidden = false; return; }
  const btn = $("#phoneBtn"); btn.disabled = true; btn.textContent = "Sending…";
  const { error } = await sb.auth.signInWithOtp({ phone, options: { shouldCreateUser: true } });
  btn.disabled = false;
  if (error) {
    const m = error.message || "";
    err.textContent = /unsupported phone provider|phone (signups|logins|provider).*(disabled|not enabled)/i.test(m) ? "Text sign-in isn't switched on yet. Use email for now. (" + m + ")"
      : /rate limit|too many/i.test(m) ? "Too many texts sent just now. Wait a few minutes and try again."
      : "Couldn't send the text: " + m;
    err.hidden = false; return;
  }
  S.phone = phone; S.authMode = "phone"; store.set("hs-auth", "phone");
  $("#codeTitle").textContent = "Check your texts"; $("#codeSentTo").textContent = "We texted a 6-digit code to " + prettyPhone(phone) + ". It can take a minute to arrive.";
  $("#codeLinkHelp").hidden = true; $("#showCodeBtn").hidden = true; $("#restartBtn").textContent = "Use a different number";
  $("#gCode").value = ""; $("#codeForm").hidden = false; showGate("code");
});
$("#codeForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#codeErr"); err.hidden = true;
  const token = $("#gCode").value.replace(/\D/g, "");
  const viaText = S.authMode === "phone";
  if (token.length !== 6) { err.textContent = "Enter all 6 digits from the " + (viaText ? "text." : "email."); err.hidden = false; return; }
  const newPass = S.resetting ? $("#gNewPass").value : "";
  if (S.resetting && newPass.length < 6) { err.textContent = "Pick a new password with at least 6 characters."; err.hidden = false; return; }
  const btn = $("#codeBtn"); btn.disabled = true;
  const { error } = await sb.auth.verifyOtp(viaText ? { phone: S.phone, token, type: "sms" } : { email: S.email, token, type: "email" });
  if (error) { btn.disabled = false; err.textContent = "That code didn't work. Check the latest " + (viaText ? "text" : "email") + ", or go back and send a new code."; err.hidden = false; return; }
  if (S.resetting) {
    const { error: pe } = await sb.auth.updateUser({ password: newPass });
    btn.disabled = false;
    if (pe) { err.textContent = "You're signed in, but the new password didn't save: " + (pe.message || "try again") + ". Sign out and use Forgot your password? again."; err.hidden = false; setTimeout(() => enter(), 4000); return; }
    S.resetting = false; $("#newPassField").hidden = true; store.set("hs-returning", "1");
    toast("Password changed. You're signed in.");
  }
  btn.disabled = false;
  await enter();
});
$("#nameForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#nameErr"); err.hidden = true;
  const name = $("#gName").value.trim();
  if (!name) { err.textContent = "Add a name your friends will recognize."; err.hidden = false; return; }
  const btn = $("#nameBtn"); btn.disabled = true;
  const { error } = await sb.from("profiles").upsert({ id: S.me, name });
  btn.disabled = false;
  if (error) { err.textContent = friendly(error); err.hidden = false; return; }
  S.myName = name; $("#whoName").textContent = "Signed in as " + name;
  await enter();
});

let started = false, entering = null;
function enter() { if (!entering) entering = enterOnce().finally(() => { entering = null; }); return entering; }
async function enterOnce() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return showGate(S.authMode);
  S.me = session.user.id;
  const { data: prof } = await sb.from("profiles").select("name").eq("id", S.me).maybeSingle();
  if (!prof?.name) { $("#gName").value = ""; return showGate("name"); }
  S.myName = prof.name; $("#whoName").textContent = "Signed in as " + prof.name;
  showGate(null); render();
  try { await Promise.all([loadBets(), loadPeople(), loadSettlements(), loadPickem().catch(() => {})]); render(); }
  catch (e) { $("#view").innerHTML = `<div class="empty"><h3>Couldn't open the board</h3><p>${esc(friendly(e))}</p><button class="btn" onclick="location.reload()">Reload</button></div>`; return; }
  if (!started) { started = true; liveUpdates(); setupAppPush(); }
  clearBadge();
  pkJoinPending();
  if (S.pendingAppToken) saveAppToken(S.pendingAppToken);
}

if (!sb) {
  $("#gatePhone").hidden = false;
  $("#gatePhone").innerHTML = `<h2>Almost ready</h2><p>Handshake isn't connected to its database yet. Add your Supabase project URL and public key to <b>config.js</b>, then redeploy.</p>`;
} else {
  enter();
  loadCount();  // the running total shows on the sign-in screen too
  // Tapping the emailed link brings people back signed in; also catch it if this tab was left open.
  sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_IN" && !started) enter(); });
}

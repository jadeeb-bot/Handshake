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
const PAGE_URL = location.origin + location.pathname.replace(/index\.html$/, "");

/* ---------- setup ---------- */
const CFG = window.HANDSHAKE_CONFIG || {};
const configured = CFG.supabaseUrl && !CFG.supabaseUrl.includes("YOUR-PROJECT") && CFG.supabaseAnonKey && !CFG.supabaseAnonKey.includes("YOUR-");
const sb = configured && createClient ? createClient(CFG.supabaseUrl, CFG.supabaseAnonKey, { auth: { persistSession: true, autoRefreshToken: true } }) : null;

const S = {
  me: null, myName: "", email: "", bets: [], people: [], loaded: false,
  tab: "board", filter: "all", sort: store.get("hs-sort") || "needs", feedFilter: "crash",
  picking: null, busy: new Set(), fresh: null, stakeKind: "points",
  pickedUid: null, pickedName: "", crashing: null, crashSide: null, crashDraft: {},
  notify: null, countering: null, counterDraft: {}, authMode: store.get("hs-auth") === "email" ? "email" : "phone", phone: "",
};

const LABEL = { proposed: "Waiting to be signed", open: "Open", reported: "Result pending", disputed: "Disputed", settled: "Scored", void: "Called off" };
const LIVE = ["proposed", "open", "reported", "disputed"];

/* ---------- rows → slips ---------- */
function fromRow(r) {
  return {
    id: r.id, title: r.title, category: r.category, stakeKind: r.stake_kind, points: r.points, stakeText: r.stake_text,
    due: r.due || "", terms: r.terms || "",
    a: { name: r.a_name, uid: r.a_uid },
    b: { name: r.b_name, uid: r.b_uid, invited: r.b_invited, proxy: r.b_proxy, signed: !!(r.b_uid || r.b_proxy) },
    status: r.status, report: r.report_winner ? { winner: r.report_winner, by: r.report_by } : null, winner: r.winner,
    parentId: r.parent_id, parentSide: r.parent_side, backsName: r.backs_name,
    counter: r.counter_by ? { by: r.counter_by, uid: r.counter_uid, kind: r.counter_kind, points: r.counter_points, text: r.counter_text } : null,
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
function needsMe(b) {
  if (b.status === "proposed" && b.counter?.by === "b" && b.a?.uid === S.me) return true;
  const s = side(b); if (!s) return false;
  if (b.status === "open") return !b.parentId && !!b.due && b.due <= today();
  if (b.status === "reported") return b.report && b.report.by !== s;
  if (b.status === "disputed") return true;
  return false;
}
const canSign = (b) => b.status === "proposed" && !!S.me && !b.b?.uid && b.a?.uid !== S.me && (!b.b?.invited || b.b.invited === S.me) && b.counter?.by !== "b";
const counterLabel = (c) => (c.kind === "other" ? c.text || "Bragging rights" : pts(c.points));
/* who I am while terms are still being worked out: the caller, or the invitee who's negotiating */
const negSide = (b) => side(b) || (b.status === "proposed" && S.me && (b.counter?.uid === S.me || b.b?.invited === S.me) ? "b" : null);
const waitingOnMyCounter = (b) => b.status === "proposed" && !!b.counter && negSide(b) === b.counter.by;
const kids = (b) => S.bets.filter((x) => x.parentId === b.id);
const liveKids = (b) => kids(b).filter((x) => x.status !== "void");
const crashable = (b) => ["proposed", "open"].includes(b.status) && !b.parentId && !!S.me && !side(b) && b.b?.invited !== S.me && b.counter?.uid !== S.me && !liveKids(b).some((k) => k.a?.uid === S.me);
const mineList = () => S.bets.filter((b) => side(b) || canSign(b) || negSide(b));

/* ---------- scoring ---------- */
function mine() {
  let score = 0, w = 0, l = 0, t = 0, live = 0, atStake = 0;
  for (const b of S.bets) {
    const s = side(b); if (!s) continue;
    if (LIVE.includes(b.status)) { live++; atStake += stakeOf(b); }
    if (!scored(b)) continue;
    if (b.winner === "push") t++;
    else if (b.winner === s) { w++; score += stakeOf(b); }
    else { l++; score -= stakeOf(b); }
  }
  return { score, w, l, t, live, atStake };
}
function standings() {
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
    if (!m.has(k)) m.set(k, { name: personName(b[o]?.uid) || nameOf(b, o), uid: b[o]?.uid || null, score: 0, w: 0, l: 0, t: 0, live: 0, last: 0 });
    const r = m.get(k); r.last = Math.max(r.last, b.createdAt || 0);
    if (LIVE.includes(b.status)) r.live++;
    if (!scored(b)) continue;
    if (b.winner === "push") r.t++;
    else if (b.winner === s) { r.w++; r.score += stakeOf(b); }
    else { r.l++; r.score -= stakeOf(b); }
  }
  return [...m.values()].sort((a, b) => b.w + b.l + b.t + b.live - (a.w + a.l + a.t + a.live) || b.last - a.last);
}
const personName = (uid) => (uid ? S.people.find((p) => p.id === uid)?.name || "" : "");
const initials = (n) => n.split(/\s+/).map((x) => x[0]).join("").slice(0, 2).toUpperCase();

/* ---------- ledger ---------- */
function renderLedger() {
  const t = mine(), dec = t.w + t.l;
  const sc = $("#score"); sc.textContent = signed(t.score); sc.className = "big " + tone(t.score);
  $("#scoreSub").textContent = dec || t.t ? "points across " + (dec + t.t) + " scored call" + (dec + t.t === 1 ? "" : "s") : "Nothing scored yet";
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
    const t = b.status === "proposed" ? "Counter offer" : b.status === "open" ? "Record result" : b.status === "reported" ? "Confirm result" : "Sort it out";
    return `<span class="st need">${t}</span>`;
  }
  if (canSign(b)) return `<span class="st need">${b.counter ? "Counter offer" : b.parentId ? "Crash offer" : "Shake on it!"}</span>`;
  if (waitingOnMyCounter(b)) return `<span class="st">You countered</span>`;
  return `<span class="st ${["settled", "void"].includes(b.status) ? "done" : ""}">${LABEL[b.status] || b.status}</span>`;
}
function sigLine(b, k) {
  const ok = k === "a" || b.b?.signed;
  const nm = nameOf(b, k);
  const label = k === "b" && b.b?.proxy && !b.b?.uid ? "in person" : b.parentId ? (k === "a" ? "crashed in" : "accepted") : k === "a" ? "called it" : "against";
  return `<div class="sig"><span class="hand ${ok ? "" : "blank"}">${ok ? esc(nm) : "not signed yet"}</span><small>${label}</small></div>`;
}
function crashLine(b) {
  const ks = liveKids(b); if (!ks.length) return "";
  return `<div class="crashers">${ks.map((k) => `<span>${esc(nameOf(k, "a"))} crashed in backing ${esc(k.backsName || "")} · ${esc(stakeLabel(k))}${k.status === "proposed" ? " · waiting on " + esc(nameOf(k, "b")) : ""}</span>`).join("")}</div>`;
}
function notifyKind(b) {
  const s = negSide(b); if (!s) return null;
  if (waitingOnMyCounter(b)) return "counter";
  if (b.status === "proposed" && s === "a") return "invite";
  if (b.status === "proposed") return null;
  if (b.status === "open") return "remind";
  if (b.status === "reported" && b.report?.by === s) return "confirm";
  if (b.status === "disputed") return "dispute";
  if (b.status === "settled") return "final";
  return null;
}
function notifyBtn(b) {
  const k = notifyKind(b); if (!k || S.notify?.id === b.id) return "";
  return `<button class="btn quiet" data-act="notify" data-id="${b.id}" data-k="${k}">Let ${esc(nameOf(b, other(negSide(b))))} know</button>`;
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
  let note = "", acts = "";
  const busy = S.busy.has(b.id) ? "disabled" : "";
  const pick = S.picking === b.id;

  switch (b.status) {
    case "proposed":
      if (b.counter) {
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
        note = `Waiting for <b>${them}</b> to sign. Send them the link, or mark it shaken on if you agreed in person.`;
        acts = `<button class="btn" data-act="shook" data-id="${b.id}" ${busy}>We shook on it</button>${notifyBtn(b)}<button class="btn quiet danger" data-act="withdraw" data-id="${b.id}" ${busy}>Withdraw</button>`;
      } else if (canSign(b)) {
        note = `<b>${esc(nameOf(b, "a"))}</b> made this call against <b>${esc(nameOf(b, "b"))}</b>. ${b.b.invited ? "It's waiting on your signature." : "If that's you, sign to make it official."}`;
        acts = S.countering === b.id ? "" : `<button class="btn primary" data-act="sign" data-id="${b.id}" ${busy}>Shake on it!</button><button class="btn" data-act="counter" data-id="${b.id}" ${busy}>Counter stakes</button><button class="btn quiet danger" data-act="decline" data-id="${b.id}" ${busy}>Decline</button>`;
      }
      break;
    case "open":
      if (b.parentId) { note = `Rides on No. ${shortNo(b.parentId)}. It scores itself when that one's result is confirmed.`; if (s) acts = notifyBtn(b); }
      else if (s && !pick) acts = `<button class="btn ${needsMe(b) ? "primary" : ""}" data-act="pick" data-id="${b.id}" ${busy}>Record result</button>${notifyBtn(b)}`;
      break;
    case "reported": {
      const r = b.report, by = esc(nameOf(b, r.by));
      const what = (w) => (w === "push" ? "it's a tie" : w === "void" ? "to call it off" : w === s ? "you won" : esc(nameOf(b, w)) + " won");
      if (s && r.by !== s) {
        note = `<b>${by}</b> says ${r.winner === "void" ? "call it off" : what(r.winner)}. Agree?`;
        acts = `<button class="btn primary" data-act="confirm" data-id="${b.id}" ${busy}>Confirm</button><button class="btn danger" data-act="dispute" data-id="${b.id}" ${busy}>Dispute</button>`;
      } else if (s) {
        note = `You said ${what(r.winner)}. Waiting for ${them} to confirm.`;
        acts = notifyBtn(b) + (!b[o]?.uid ? `<button class="btn" data-act="confirm" data-id="${b.id}" ${busy}>${them} agreed in person</button>` : "") + `<button class="btn quiet" data-act="pick" data-id="${b.id}">Change result</button>`;
      } else note = `${by} recorded a result. Waiting on the other side.`;
      if (pick) acts = "";
      break;
    }
    case "disputed":
      note = `<b>Disputed.</b> ${esc(nameOf(b, b.report?.by || "a"))}'s call wasn't accepted. Talk it out, then record the result again.`;
      if (s && !pick) acts = `${notifyBtn(b)}<button class="btn primary" data-act="pick" data-id="${b.id}" ${busy}>Record result again</button><button class="btn quiet" data-act="callOff" data-id="${b.id}" ${busy}>Call it off</button>`;
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
      <span class="sub">${them} confirms before any points move.</span>
      <div><button class="btn quiet" data-act="unpick">Cancel</button></div></div>`;
  }
  const cls = "slip" + (needsMe(b) || canSign(b) ? " attn" : "") + (stamp ? " has-stamp" : "") + (S.fresh === b.id ? " newly" : "");
  return `<article class="${cls}" id="bet-${b.id}">
    ${stamp}
    <div class="slip-top"><span class="no">No. ${esc(shortNo(b.id))}</span><span class="cat">${esc(b.category || "Other")}</span>${b.parentId ? `<span class="tagc">Crash on No. ${shortNo(b.parentId)}</span>` : ""}${statusChip(b)}</div>
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
      else { subject = `Handshake: sign your side of ${t}`; body = `${them}, I'm calling it: ${t} for ${st}${due}. Sign your side on Handshake:`; }
      break;
    case "counter":
      subject = `Handshake: counter offer on ${t}`;
      body = s === "b"
        ? `${them}, I'll take the other side of ${t}, but for ${counterLabel(b.counter)} instead of ${st}. Accept or counter on Handshake:`
        : `${them}, how about ${counterLabel(b.counter)} instead on ${t}? Accept or counter on Handshake:`;
      break;
    case "confirm": subject = `Handshake: confirm the result of ${t}`; body = `${them}, I recorded the result of ${t}: ${claim(b.report?.winner)}. Confirm or dispute it on Handshake:`; break;
    case "dispute": subject = `Handshake: ${t} is disputed`; body = `${them}, I disputed the result of ${t}. Let's sort it out, then one of us can record it again:`; break;
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
  const num = store.get(phoneKey(m.to)) || "";
  const share = navigator.share ? `<button class="btn primary" data-act="shareMsg" data-id="${b.id}">Share…</button>` : "";
  return `<div class="npanel"><span class="lab">Let ${esc(m.to)} know</span>
    <p class="msg">${esc(m.body)}</p>
    <div class="field"><label for="nPhone">${esc(m.to)}'s number <span class="hint">optional, saved on this device only</span></label>
      <input id="nPhone" type="tel" inputmode="tel" autocomplete="off" placeholder="Leave blank to pick in Messages" value="${esc(num)}" data-name="${esc(m.to)}"></div>
    <div class="acts">
      <a class="btn ${share ? "" : "primary"}" id="smsLink" href="${esc(smsHref(num, m.body))}">Text it</a>
      ${share}
      <a class="btn" href="mailto:?subject=${encodeURIComponent(m.subject)}&body=${encodeURIComponent(m.body)}">Email it</a>
      <button class="btn" data-act="copyMsg" data-id="${b.id}">Copy</button>
      <button class="btn ghost" data-act="unnotify">Close</button>
    </div></div>`;
}

/* ---------- board views ---------- */
const FILTERS = [["all", "All"], ["needs", "Needs you"], ["live", "In play"], ["done", "Scored"], ["void", "Called off"]];
function inFilter(b, f) {
  if (f === "needs") return needsMe(b) || canSign(b);
  if (f === "live") return LIVE.includes(b.status);
  if (f === "done") return b.status === "settled";
  if (f === "void") return b.status === "void";
  return true;
}
const rank = (b) => (needsMe(b) || canSign(b) ? 0 : LIVE.includes(b.status) ? 1 : 2);
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
    return `<div class="empty"><h3>No predictions yet</h3><p>Make the first call, or crash someone else's from the Everyone tab. Your predictions show here with a line for each side to sign.</p><button class="btn primary" data-act="new">Make a prediction</button></div>`;
  }
  const list = sorted(MINE.filter((b) => inFilter(b, S.filter)));
  const chips = FILTERS.map(([k, l]) => `<button class="chipbtn" aria-pressed="${S.filter === k}" data-act="filter" data-v="${k}">${l} <span class="mono">${MINE.filter((b) => inFilter(b, k)).length}</span></button>`).join("");
  const sel = `<select id="sortSel" aria-label="Sort predictions">${[["needs", "Needs you first"], ["newest", "Newest first"], ["due", "Due soonest"], ["stake", "Most points"]].map(([k, l]) => `<option value="${k}" ${S.sort === k ? "selected" : ""}>${l}</option>`).join("")}</select>`;
  return `<div style="display:flex;flex-direction:column;gap:14px"><div class="filters">${chips}${sel}</div>
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
    <div class="slip-top"><span class="no">No. ${esc(shortNo(b.id))}</span><span class="cat">${esc(b.category || "Other")}</span>${b.parentId ? `<span class="tagc">Crash on No. ${shortNo(b.parentId)}</span>` : ""}${statusChip(b)}</div>
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
  if (!S.bets.length) return `<div class="empty"><h3>Nothing on the board yet</h3><p>Every prediction from everyone playing shows up here, newest first. Pending ones can be crashed.</p></div>`;
  const pass = (b, f) => (f === "crash" ? crashable(b) : f === "live" ? LIVE.includes(b.status) : true);
  const list = S.bets.filter((b) => pass(b, S.feedFilter)).sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
  const chips = FEED_FILTERS.map(([k, l]) => `<button class="chipbtn" aria-pressed="${S.feedFilter === k}" data-act="feedFilter" data-v="${k}">${l} <span class="mono">${S.bets.filter((b) => pass(b, k)).length}</span></button>`).join("");
  const empty = S.feedFilter === "crash" ? `<div class="empty"><p>Nothing open to crash right now. Predictions you're already in, or have crashed, don't show here.</p></div>` : `<div class="empty"><p>Nothing here right now.</p></div>`;
  return `<div style="display:flex;flex-direction:column;gap:14px"><div class="secthead"><h2>Everyone's predictions</h2><span class="sub">From everyone playing, newest first</span></div>
    <div class="filters">${chips}</div><div class="feed">${list.length ? list.map(feedCard).join("") : empty}</div></div>`;
}
function rivalSentence(r) {
  const nm = esc(r.name);
  if (!r.w && !r.l && !r.t) return `Nothing scored with ${nm} yet. ${r.live} call${r.live === 1 ? "" : "s"} in play.`;
  if (r.score > 0) return `You're up ${pts(r.score)} on ${nm}, ${r.w}–${r.l} in calls.`;
  if (r.score < 0) return `${nm} is up ${pts(-r.score)} on you, ${r.l}–${r.w} in calls. Time for a rematch.`;
  return `Dead even with ${nm} on points, ${r.w}–${r.l} in calls.`;
}
function renderRivals() {
  const table = standings(), rs = rivals();
  if (!table.length && !rs.length) return `<div class="empty"><h3>No scores yet</h3><p>Once a prediction is confirmed, the winner gains its points, the other side loses them, and the standings show up here.</p></div>`;
  const rows = table.map((r, i) => `<tr class="${r.me ? "me" : ""}"><td class="pl"><span class="rk">${i + 1}</span><span>${esc(r.name)}${r.me ? ` <span class="you">you</span>` : ""}</span></td><td class="num ${tone(r.score)}">${signed(r.score)}</td><td class="num">${r.w}–${r.l}${r.t ? "–" + r.t : ""}</td></tr>`).join("");
  const cards = rs.map((r) => {
    const tot = r.w + r.l + r.t || 1;
    return `<div class="card"><div class="rname"><span class="av">${esc(initials(r.name))}</span><h3>You vs ${esc(r.name)}</h3></div>
      <div class="score ${tone(r.score)}">${signed(r.score)}<small>pts</small></div>
      <div class="bars" aria-hidden="true"><i class="w" style="width:${(r.w / tot) * 100}%"></i><i class="p" style="width:${(r.t / tot) * 100}%"></i><i class="l" style="width:${(r.l / tot) * 100}%"></i></div>
      <div class="line">${rivalSentence(r)}</div>
      ${r.live ? `<div class="sub">${r.live} call${r.live === 1 ? "" : "s"} still in play</div>` : ""}
      <div><button class="btn" data-act="rematch" data-v="${esc(r.name)}" data-uid="${esc(r.uid || "")}">New call against ${esc(r.name)}</button></div></div>`;
  }).join("");
  return `<div style="display:flex;flex-direction:column;gap:22px">
    ${table.length ? `<div style="display:flex;flex-direction:column;gap:10px"><div class="secthead"><h2>Standings</h2><span class="sub">Everyone playing, by total points</span></div>
      <div class="table"><table><thead><tr><th>Player</th><th class="num">Points</th><th class="num">W–L</th></tr></thead><tbody>${rows}</tbody></table></div></div>` : ""}
    ${rs.length ? `<div style="display:flex;flex-direction:column;gap:10px"><div class="secthead"><h2>Head to head</h2><span class="sub">Your points against each friend</span></div><div class="cards">${cards}</div></div>` : ""}
  </div>`;
}

function render() {
  renderLedger();
  for (const t of ["board", "feed", "rivals"]) $("#tab-" + t).setAttribute("aria-selected", S.tab === t);
  const v = $("#view");
  if (!S.loaded) { v.innerHTML = `<div class="empty"><h3>Opening the notebook…</h3><p>Pulling up every prediction on the board.</p></div>`; return; }
  v.innerHTML = S.tab === "rivals" ? renderRivals() : S.tab === "feed" ? renderFeed() : renderBoard();
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
    const { error } = await sb.rpc(fn, args);
    if (error) throw error;
    S.picking = null;
    await loadBets();
    if (okMsg) toast(okMsg);
    return true;
  } catch (e) { toast(friendly(e)); return false; }
  finally { if (id) S.busy.delete(id); render(); }
}
async function copy(text, ok) {
  try { await navigator.clipboard.writeText(text); toast(ok || "Copied"); }
  catch (e) { toast("Copy didn't work here. Select the message and copy it."); }
}

const byId = (id) => S.bets.find((b) => b.id === id);
const ACT = {
  tab: (el) => { S.tab = el.dataset.v; S.picking = null; S.notify = null; render(); },
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
  shook: (el) => call("mark_shook", { p_id: el.dataset.id }, "Signed for both of you", el.dataset.id),
  withdraw: (el) => call("withdraw_prediction", { p_id: el.dataset.id }, byId(el.dataset.id)?.parentId ? "Crash offer withdrawn" : "Prediction withdrawn", el.dataset.id),
  decline: (el) => call("decline_prediction", { p_id: el.dataset.id }, "Declined", el.dataset.id),
  sign: (el) => call("sign_prediction", { p_id: el.dataset.id }, byId(el.dataset.id)?.parentId ? "Crash accepted. It's on." : "You shook on it. It's official.", el.dataset.id),
  report: (el) => call("report_result", { p_id: el.dataset.id, p_winner: el.dataset.w }, "Result sent for confirmation", el.dataset.id),
  confirm: (el) => {
    const b = byId(el.dataset.id), w = b?.report?.winner;
    const msg = w === "void" ? "Called off" : w === "push" ? "Tie confirmed. No points moved." : isOther(b) ? nameOf(b, w) + " wins: " + stakeLabel(b) : nameOf(b, w) + " takes " + pts(stakeOf(b));
    call("confirm_result", { p_id: el.dataset.id }, msg, el.dataset.id);
  },
  dispute: (el) => call("dispute_result", { p_id: el.dataset.id }, "Marked as disputed", el.dataset.id),
  callOff: (el) => call("report_result", { p_id: el.dataset.id, p_winner: "void" }, "Asked to call it off", el.dataset.id),
  counter: (el) => { S.countering = el.dataset.id; S.counterDraft = {}; S.notify = null; render(); },
  uncounter: () => { S.countering = null; render(); },
  cseg: (el) => { S.counterDraft.kind = el.dataset.v; render(); },
  sendCounter: (el) => sendCounter(byId(el.dataset.id)),
  acceptCounter: (el) => { const b = byId(el.dataset.id); call("accept_counter", { p_id: el.dataset.id }, "Deal. It's on for " + (b?.counter ? counterLabel(b.counter) : "the new stakes") + ".", el.dataset.id); },
  withdrawCounter: (el) => call("withdraw_counter", { p_id: el.dataset.id }, "Counter taken back", el.dataset.id),
  crash: (el) => { S.crashing = el.dataset.id; S.crashSide = null; S.crashDraft = {}; render(); },
  uncrash: () => { S.crashing = null; render(); },
  crashSide: (el) => { S.crashSide = el.dataset.v; render(); },
  sendCrash: (el) => sendCrash(byId(el.dataset.id)),
  notify: (el) => { S.notify = { id: el.dataset.id, kind: el.dataset.k }; S.picking = null; render(); },
  unnotify: () => { S.notify = null; render(); },
  copyMsg: (el) => copy(message(byId(el.dataset.id), S.notify.kind).body, "Message copied. Paste it into any chat."),
  shareMsg: async (el) => {
    const m = message(byId(el.dataset.id), S.notify.kind);
    try { await navigator.share({ title: m.subject, text: m.body }); } catch (e) { if (e?.name !== "AbortError") copy(m.body, "Message copied instead"); }
  },
  pickPerson: (el) => pickPerson(el.dataset.id, el.dataset.name),
  restartAuth: () => showGate(S.authMode),
  useEmail: () => { S.authMode = "email"; store.set("hs-auth", "email"); showGate("email"); },
  usePhone: () => { S.authMode = "phone"; store.set("hs-auth", "phone"); showGate("phone"); },
  showCode: () => { $("#codeForm").hidden = false; $("#gCode").focus(); },
  rename: () => { $("#gName").value = S.myName; showGate("name"); },
  signOut: async () => { await sb.auth.signOut(); location.reload(); },
};
document.addEventListener("input", (e) => {
  if (e.target.id === "crashPts") S.crashDraft.pts = e.target.value;
  if (e.target.id === "cPts") S.counterDraft.pts = e.target.value;
  if (e.target.id === "cText") S.counterDraft.text = e.target.value;
  if (e.target.id === "nPhone") {
    const n = e.target.value.replace(/[^\d+]/g, "");
    store.set(phoneKey(e.target.dataset.name), n);
    const b = byId(S.notify?.id), a = $("#smsLink");
    if (b && a) a.href = smsHref(n, message(b, S.notify.kind).body);
  }
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
function setKind(k) {
  S.stakeKind = k;
  $("#segPts").setAttribute("aria-pressed", k === "points"); $("#segOther").setAttribute("aria-pressed", k === "other");
  $("#ptsWrap").hidden = k !== "points"; $("#otherWrap").hidden = k !== "other";
}
function pickPerson(uid, name) {
  $("#fWith").value = name; S.pickedUid = uid; S.pickedName = name; $("#peopleList").hidden = true;
  const pn = $("#pickNote"); pn.textContent = "Only " + name + " can sign this one."; pn.hidden = false;
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
  if (S.pickedUid && v !== S.pickedName) { S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; }
  searchPeople(v.trim());
});
$("#fWith").addEventListener("blur", () => setTimeout(() => { if (!$("#peopleList").contains(document.activeElement)) $("#peopleList").hidden = true; }, 200));
$("#peopleList").addEventListener("pointerdown", (e) => e.preventDefault()); // keep focus so the tap lands

function openSheet(withName, uid) {
  $("#betForm").reset(); $("#formErr").hidden = true; setKind("points");
  S.pickedUid = null; S.pickedName = ""; $("#pickNote").hidden = true; $("#peopleList").hidden = true;
  $("#fDue").value = addDays(7); $("#fPts").value = 10;
  if (withName) { if (uid) pickPerson(uid, withName); else $("#fWith").value = withName; }
  $("#sheet").hidden = false; $("#sheet").scrollIntoView({ behavior: "smooth", block: "start" });
  setTimeout(() => $("#fTitle").focus({ preventScroll: true }), 250);
}
$("#betForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = (m) => { const p = $("#formErr"); p.textContent = m; p.hidden = false; };
  const title = $("#fTitle").value.trim(), withN = $("#fWith").value.trim();
  const p = Math.round(parseFloat($("#fPts").value)), otherText = $("#fOther").value.trim();
  if (!title) return err("Say what you're predicting, like “Lakers win tonight.”");
  if (!withN) return err("Add who's taking the other side.");
  if (withN.toLowerCase() === S.myName.toLowerCase() && !S.pickedUid) return err("You can't predict against yourself. Check the name.");
  if (S.stakeKind === "points" && !(p >= 1 && p <= 1000)) return err("Put between 1 and 1,000 points on the line.");
  if (S.stakeKind === "other" && !otherText) return err("Say what the loser owes, like “Loser buys the first round.”");
  const shook = $("#fShook").checked;
  const btn = $("#saveBtn"); btn.disabled = true;
  try {
    const { data, error } = await sb.rpc("create_prediction", {
      p_title: title, p_with_name: withN, p_invited: S.pickedUid && withN === S.pickedName ? S.pickedUid : null,
      p_category: $("#fCat").value, p_stake_kind: S.stakeKind, p_points: S.stakeKind === "points" ? p : 0,
      p_stake_text: S.stakeKind === "other" ? otherText : "", p_due: $("#fDue").value || null, p_terms: $("#fTerms").value.trim(), p_shook: shook,
    });
    if (error) throw error;
    S.fresh = data; $("#sheet").hidden = true; S.tab = "board"; S.filter = "all";
    await loadBets(); render();
    toast(shook ? "On the board, signed by both of you" : "On the board. Let " + withN + " know so they can sign.");
    if (!shook && data) { S.notify = { id: data, kind: "invite" }; render(); document.getElementById("bet-" + data)?.scrollIntoView({ behavior: "smooth", block: "center" }); }
  } catch (x) { err(friendly(x)); }
  finally { btn.disabled = false; }
});

/* ---------- export ---------- */
function exportCsv() {
  if (!S.bets.length) return toast("No predictions to export yet");
  const cols = ["Slip", "Prediction", "Category", "Called by", "Other side", "Stake", "Status", "Winner", "Decided by", "Terms", "Created"];
  const q = (v) => `"${String(v ?? "").replace(/"/g, '""')}"`;
  const rows = S.bets.map((b) => [shortNo(b.id), b.title, b.category, nameOf(b, "a"), nameOf(b, "b"), stakeLabel(b), LABEL[b.status], b.winner === "push" ? "Tie" : b.winner ? nameOf(b, b.winner) : "", b.due, b.terms, b.createdAt ? new Date(b.createdAt).toISOString().slice(0, 10) : ""].map(q).join(","));
  const blob = new Blob([[cols.map(q).join(","), ...rows].join("\n")], { type: "text/csv" });
  const a = document.createElement("a"); a.href = URL.createObjectURL(blob); a.download = "handshake-predictions.csv";
  document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
}

/* ---------- data loading ---------- */
async function loadBets() {
  const { data, error } = await sb.from("predictions").select("*").order("created_at", { ascending: false }).limit(2000);
  if (error) throw error;
  S.bets = data.map(fromRow); S.loaded = true;
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
    .subscribe();
  document.addEventListener("visibilitychange", async () => { if (!document.hidden) { try { await loadBets(); await loadPeople(); render(); } catch (e) {} } });
}

/* ---------- sign-in ---------- */
function showGate(which) {
  $("#gatePhone").hidden = which !== "phone"; $("#gateEmail").hidden = which !== "email"; $("#gateCode").hidden = which !== "code"; $("#gateName").hidden = which !== "name";
  $("#app").hidden = !!which; $("#newBtn").hidden = !!which; $("#who").hidden = !!which;
  const f = which === "phone" ? "#gPhone" : which === "email" ? "#gEmail" : which === "code" ? "#gCode" : which === "name" ? "#gName" : null;
  if (f) setTimeout(() => $(f).focus(), 50);
}
$("#emailForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#emailErr"); err.hidden = true;
  const email = $("#gEmail").value.trim();
  if (!/^\S+@\S+\.\S+$/.test(email)) { err.textContent = "Enter a full email address, like you@example.com."; err.hidden = false; return; }
  const btn = $("#emailBtn"); btn.disabled = true; btn.textContent = "Sending…";
  const { error } = await sb.auth.signInWithOtp({ email, options: { shouldCreateUser: true, emailRedirectTo: PAGE_URL } });
  btn.disabled = false; btn.textContent = "Email me a link";
  if (error) { err.textContent = /rate|limit/i.test(error.message) ? "Too many sign-in emails sent just now. Wait a few minutes and try again." : error.message; err.hidden = false; return; }
  S.email = email; S.authMode = "email";
  $("#codeTitle").textContent = "Check your email"; $("#codeSentTo").textContent = "We sent a sign-in link to " + email + ".";
  $("#codeLinkHelp").hidden = false; $("#showCodeBtn").hidden = false; $("#restartBtn").textContent = "Use a different email";
  $("#gCode").value = ""; $("#codeForm").hidden = true; showGate("code");
});
/* US numbers can be typed any way; anything else needs a leading + and country code */
function normPhone(v) {
  const t = v.trim(), d = t.replace(/\D/g, "");
  if (t.startsWith("+")) return d.length >= 8 && d.length <= 15 ? "+" + d : null;
  if (d.length === 10) return "+1" + d;
  if (d.length === 11 && d[0] === "1") return "+" + d;
  return null;
}
const prettyPhone = (p) => (p.startsWith("+1") && p.length === 12 ? `(${p.slice(2, 5)}) ${p.slice(5, 8)}-${p.slice(8)}` : p);
$("#phoneForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const err = $("#phoneErr"); err.hidden = true;
  const phone = normPhone($("#gPhone").value);
  if (!phone) { err.textContent = "Enter a 10-digit US number, or a + and country code for other countries."; err.hidden = false; return; }
  const btn = $("#phoneBtn"); btn.disabled = true; btn.textContent = "Sending…";
  const { error } = await sb.auth.signInWithOtp({ phone, options: { shouldCreateUser: true } });
  btn.disabled = false; btn.textContent = "Text me a code";
  if (error) {
    const m = error.message || "";
    err.textContent = /provider|unsupported|sms|twilio|not enabled|disabled/i.test(m) ? "Text sign-in isn't switched on yet. Use email for now."
      : /rate|limit|too many/i.test(m) ? "Too many texts sent just now. Wait a few minutes and try again."
      : /invalid/i.test(m) ? "That number didn't work. Check it and try again." : m;
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
  const btn = $("#codeBtn"); btn.disabled = true;
  const { error } = await sb.auth.verifyOtp(viaText ? { phone: S.phone, token, type: "sms" } : { email: S.email, token, type: "email" });
  btn.disabled = false;
  if (error) { err.textContent = "That code didn't work. Check the latest " + (viaText ? "text" : "email") + ", or send a new code."; err.hidden = false; return; }
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
  try { await Promise.all([loadBets(), loadPeople()]); render(); }
  catch (e) { $("#view").innerHTML = `<div class="empty"><h3>Couldn't open the board</h3><p>${esc(friendly(e))}</p><button class="btn" onclick="location.reload()">Reload</button></div>`; return; }
  if (!started) { started = true; liveUpdates(); }
}

if (!sb) {
  $("#gateEmail").hidden = false;
  $("#gateEmail").innerHTML = `<h2>Almost ready</h2><p>Handshake isn't connected to its database yet. Add your Supabase project URL and public key to <b>config.js</b>, then redeploy.</p>`;
} else {
  enter();
  // Tapping the emailed link brings people back signed in; also catch it if this tab was left open.
  sb.auth.onAuthStateChange((event) => { if (event === "SIGNED_IN" && !started) enter(); });
}

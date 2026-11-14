// Handshake: calendar file for a locked-down RSVP ("Add to Calendar").
// GET /api/ics?t=Title&l=Venue&d=2026-11-21&e=2026-11-23&h=19:00&n=Notes&u=<event id>
//   d = day (required), e = end day (trips, optional), h = start time (optional; 2-hour event).
//   No time = all-day event(s). Times are "floating" (the phone's own time zone).
// Everything comes from the link itself; nothing is looked up, so there's nothing private here.
const clean = (s, max) => String(s || "").replace(/[\r\n]+/g, " ").slice(0, max);
const esc = (s) => s.replace(/\\/g, "\\\\").replace(/;/g, "\;").replace(/,/g, "\\,");
const ymd = (s) => (/^\d{4}-\d{2}-\d{2}$/.test(s || "") ? s.replace(/-/g, "") : null);
function addDays(d8, n) {
  const t = new Date(Date.UTC(+d8.slice(0, 4), +d8.slice(4, 6) - 1, +d8.slice(6, 8)) + n * 864e5);
  return t.toISOString().slice(0, 10).replace(/-/g, "");
}
// Long lines must be folded at 75 bytes for some calendar apps.
const fold = (line) => line.match(/.{1,73}/g).join("\r\n ");

module.exports = (req, res) => {
  const q = req.query || {};
  const day = ymd(q.d);
  if (!day) { res.statusCode = 400; return res.end("Missing or bad date."); }
  const end = ymd(q.e) && ymd(q.e) >= day ? ymd(q.e) : day;
  const time = /^\d{2}:\d{2}$/.test(q.h || "") ? q.h.replace(":", "") : null;
  const title = clean(q.t, 80) || "Handshake plan", where = clean(q.l, 80), notes = clean(q.n, 240);
  const uid = clean(q.u, 60).replace(/[^\w-]/g, "") || day + (time || "");
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d+/, "");
  let when;
  if (time) {
    // 2 hours; a trip with an end day runs until the same time on the last day
    let h = +time.slice(0, 2) + 2, endDay = end === day ? day : end;
    if (end === day && h >= 24) { h -= 24; endDay = addDays(day, 1); }
    when = [`DTSTART:${day}T${time}00`, `DTEND:${endDay}T${String(h).padStart(2, "0")}${time.slice(2)}00`];
  } else {
    when = [`DTSTART;VALUE=DATE:${day}`, `DTEND;VALUE=DATE:${addDays(end, 1)}`];
  }
  const lines = [
    "BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Handshake//RSVP//EN", "CALSCALE:GREGORIAN", "METHOD:PUBLISH",
    "BEGIN:VEVENT", `UID:${uid}@handshake`, `DTSTAMP:${stamp}`, ...when,
    `SUMMARY:${esc(title)}`, ...(where ? [`LOCATION:${esc(where)}`] : []),
    `DESCRIPTION:${esc((notes ? notes + " · " : "") + "Planned on Handshake.")}`,
    "END:VEVENT", "END:VCALENDAR",
  ].map(fold);
  res.setHeader("Content-Type", "text/calendar; charset=utf-8");
  res.setHeader("Content-Disposition", `inline; filename="${title.replace(/[^\w -]/g, "").trim() || "event"}.ics"`);
  res.setHeader("Cache-Control", "no-store");
  res.end(lines.join("\r\n") + "\r\n");
};

// Copies the website files into www/ so the app ships with them built in, plus Capacitor's
// helper library, which lets the page use the phone's features (notifications, contacts).
const fs = require("fs");
const path = require("path");
const out = path.join(__dirname, "www");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);
for (const f of ["index.html", "app.js", "config.js", "supabase.js"]) {
  fs.copyFileSync(path.join(__dirname, "..", f), path.join(out, f));
}
fs.copyFileSync(require.resolve("@capacitor/core/dist/capacitor.js"), path.join(out, "capacitor.js"));
const page = path.join(out, "index.html");
const html = fs.readFileSync(page, "utf8");
const hook = '<script src="supabase.js"></script>';
if (!html.includes(hook)) throw new Error("index.html no longer loads supabase.js; update copy-web.js");
fs.writeFileSync(page, html.replace(hook, '<script src="capacitor.js"></script>\n' + hook));
console.log("Copied web files and Capacitor into www/");

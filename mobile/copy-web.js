// Copies the website files into www/ so the app ships with them built in.
const fs = require("fs");
const path = require("path");
const out = path.join(__dirname, "www");
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(out);
for (const f of ["index.html", "app.js", "config.js", "supabase.js"]) {
  fs.copyFileSync(path.join(__dirname, "..", f), path.join(out, f));
}
console.log("Copied web files into www/");

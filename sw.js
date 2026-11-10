// Handshake's background worker: shows push notifications and opens the site when one is tapped.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = { body: event.data ? event.data.text() : "" }; }
  const title = data.title || "Handshake";
  event.waitUntil(self.registration.showNotification(title, {
    body: data.body || "Something happened on one of your predictions.",
    icon: "icon-192.png",
    badge: "icon-192.png",
    tag: data.tag || undefined,
    data: { url: data.url || "./" },
  }));
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = new URL(event.notification.data?.url || "./", self.registration.scope).href;
  event.waitUntil((async () => {
    const wins = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    for (const w of wins) {
      if (w.url.startsWith(self.registration.scope)) { await w.focus(); w.postMessage({ type: "refresh" }); return; }
    }
    await self.clients.openWindow(url);
  })());
});

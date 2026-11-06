// The service worker: the app opens offline after one visit. Generated into
// dist/sw.js by vite.config.ts, which fills in the build's files.
//
// - Every file of the build is cached on install, under a name unique to the
//   build; activating a new build drops the old cache.
// - Pages are network-first (a new build shows up when online), falling back
//   to the cached app, which routes on the client.
// - Built files are cache-first: their names change when their content does.
// - /config.json is cached on install, then network-first with the cached
//   copy as the fallback.
// - Calls to the API are a different origin and pass through untouched.

const VERSION = "__VERSION__";
const ASSETS = __ASSETS__;
const CACHE = `qot-${VERSION}`;

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches
      .open(CACHE)
      // config.json too, or a first visit followed by an offline start would
      // have no server to sync with. It stays network-first afterwards.
      .then((cache) => cache.addAll([...ASSETS, "/config.json"]))
      .then(() => self.skipWaiting()),
  );
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== self.location.origin) return;

  if (request.mode === "navigate") {
    event.respondWith(networkFirst(request, "/"));
  } else if (url.pathname === "/config.json") {
    event.respondWith(networkFirst(request, "/config.json", true));
  } else {
    // ignoreVary: module scripts are requested with an Origin header, and a
    // server's `Vary: Origin` would otherwise make every cached copy miss.
    event.respondWith(caches.match(request, { ignoreVary: true }).then((hit) => hit ?? fetch(request)));
  }
});

async function networkFirst(request, fallback, store = false) {
  try {
    const response = await fetch(request);
    if (store && response.ok) {
      const cache = await caches.open(CACHE);
      await cache.put(fallback, response.clone());
    }
    return response;
  } catch (error) {
    const hit = await caches.match(fallback, { ignoreVary: true });
    if (hit) return hit;
    throw error;
  }
}

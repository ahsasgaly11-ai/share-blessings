/* أثر: يحفظ ملفات الموقع ليفتح دون اتصال. الخطوط تُحفظ عند أول تحميل لها. */
const CACHE = 'share-blessings-v34';
const SHELL = ['./', './manifest.webmanifest', './favicon.svg', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png', './config.js', './vendor/supabase.min.js'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
const keep = (req, r) => { if (r.ok && (r.type === 'basic' || r.type === 'cors' || r.type === 'opaque') && !r.redirected) { const copy = r.clone(); caches.open(CACHE).then(c => c.put(req, copy)); } return r; };
self.addEventListener('fetch', e => {
  const req = e.request, url = new URL(req.url);
  if (req.method !== 'GET') return;
  // pages: network first so updates arrive; a slow network (over 4 seconds) or none at all gets the saved copy
  if (req.mode === 'navigate') {
    const net = fetch(req).then(r => { if (r.ok && r.type === 'basic' && !r.redirected) { const copy = r.clone(); caches.open(CACHE).then(c => c.put('./', copy)); } return r; });
    const slow = new Promise(res => setTimeout(res, 4000)).then(() => caches.match('./')).then(hit => hit || net);
    e.respondWith(Promise.race([net, slow]).catch(() => caches.match('./')).then(r => r || net));
    return;
  }
  const own = url.origin === location.origin;
  // config: always try the network so a changed key takes effect
  if (own && url.pathname.endsWith('/config.js')) { e.respondWith(fetch(req).then(r => keep(req, r)).catch(() => caches.match(req))); return; }
  // translations and icons: answer from the cache at once, then refresh it, so a new version arrives on the next visit even without a new cache name
  if (own && /\/(i18n|icons)\//.test(url.pathname)) {
    e.respondWith(caches.match(req).then(hit => { const net = fetch(req).then(r => keep(req, r)); if (hit) { e.waitUntil(net.catch(() => {})); return hit; } return net; }));
    return;
  }
  // other own files and Google Fonts: cache first
  if (own || /fonts\.(googleapis|gstatic)\.com$/.test(url.hostname)) {
    e.respondWith(caches.match(req).then(hit => hit || fetch(req).then(r => keep(req, r))));
  }
  // everything else (the database, address lookup, maps) goes to the network as usual
});

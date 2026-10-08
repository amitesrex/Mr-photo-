/* MR Photo Pro — service worker: पूरा ऐप ऑफलाइन चलाने के लिए */
const CACHE = 'mrphoto-pro-v3';
const SHARE = 'mrphoto-share'; // फोन की स्कैन / Share से आई फोटो यहां रुकती हैं
const ASSETS = ['./', './index.html', './manifest.webmanifest',
  './icons/icon-192.png', './icons/icon-512.png', './icons/maskable-512.png', './icons/apple-touch-icon.png', './icons/favicon-32.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(CACHE).then(c => c.addAll(ASSETS)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE && k !== SHARE).map(k => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method === 'POST' && new URL(r.url).pathname.endsWith('/share-target')) { // दूसरी ऐप से "Share → MR Photo"
    e.respondWith((async () => {
      try {
        const files = (await r.formData()).getAll('photos').filter(f => f && f.size);
        const c = await caches.open(SHARE);
        for (const k of await c.keys()) await c.delete(k);
        let i = 0;
        for (const f of files) await c.put('./shared/' + (i++), new Response(f, { headers: { 'Content-Type': f.type || 'image/jpeg', 'X-Name': encodeURIComponent(f.name || 'shared.jpg') } }));
        return Response.redirect('./index.html?shared=' + files.length, 303);
      } catch (err) { return Response.redirect('./index.html', 303); }
    })());
    return;
  }
  if (r.method !== 'GET' || !r.url.startsWith(self.location.origin)) return;
  if (r.mode === 'navigate') { // पहले नेटवर्क (नया वर्ज़न), धीमा / ऑफलाइन हो तो कैश
    e.respondWith(
      Promise.race([fetch(r), new Promise((_, rej) => setTimeout(rej, 3500))])
        .then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put('./index.html', cp)); return res; })
        .catch(() => caches.match('./index.html'))
    );
    return;
  }
  e.respondWith(caches.match(r).then(hit => hit || fetch(r).then(res => { const cp = res.clone(); caches.open(CACHE).then(c => c.put(r, cp)); return res; })));
});

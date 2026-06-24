// Service worker: cachea el app shell. Los datos siempre van por red.
const CACHE = 'despachos-apl-v63';
const SHELL = [
  '.', 'index.html',
  'css/styles.css',
  'js/app.js', 'js/config.js',
  'manifest.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/logo.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // Nunca cachear llamadas a Supabase ni a la CDN de la librería
  if (url.hostname.endsWith('supabase.co') || url.hostname.endsWith('esm.sh')) return;
  if (e.request.method !== 'GET') return;

  // Estrategia "red primero": siempre trae lo más reciente; usa caché solo sin conexión
  e.respondWith(
    fetch(e.request).then((res) => {
      const copy = res.clone();
      caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
      return res;
    }).catch(() => caches.match(e.request))
  );
});

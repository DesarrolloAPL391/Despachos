// Service worker: cachea el app shell (para sin conexión). Los datos siempre van por red.
const CACHE = 'despachos-apl-v370';
const SHELL = [
  '.', 'index.html',
  'css/styles.css',
  'js/app.js', 'js/config.js', 'js/hoja-vida.js', 'js/cedula-lector.js', 'js/cedula-lugares.js', 'js/jsqr.min.js', 'js/qrcode.min.js',
  'vendor/leaflet/leaflet.js', 'vendor/leaflet/leaflet.css', 'vendor/supabase/supabase.js',
  'manifest.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/logo.png',
];

self.addEventListener('install', (e) => {
  // cache:'reload' evita que el shell se guarde desde la caché HTTP del navegador (archivos viejos)
  e.waitUntil(
    caches.open(CACHE)
      .then((c) => c.addAll(SHELL.map((u) => new Request(u, { cache: 'reload' }))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// Permite que la página fuerce la activación de un SW en espera
self.addEventListener('message', (e) => {
  if (e.data === 'SKIP_WAITING') self.skipWaiting();
});

self.addEventListener('fetch', (e) => {
  if (e.request.method !== 'GET') return;
  const url = new URL(e.request.url);
  // Solo los archivos de la app pasan por aquí. Lo de otros servidores (Supabase, cuadros del mapa, TomTom, esm.sh)
  // va directo: los cuadros del mapa los guarda la caché normal del navegador. Antes se copiaba cada cuadro aquí y,
  // como son respuestas "opacas", cada uno ocupaba varios MB de la cuota del navegador.
  if (url.origin !== self.location.origin) return;

  // Pide SIEMPRE la versión fresca, pero preguntando "¿cambió?": si no cambió, el servidor responde 304 y no se vuelve
  // a bajar (antes, con 'no-store', se bajaban otra vez los 1,8 MB de app.js en cada apertura). La caché del SW solo
  // se usa sin conexión.
  const req = new Request(e.request.url, { cache: 'no-cache' });
  e.respondWith(
    fetch(req).then((res) => {
      if (res.ok) {
        const copy = res.clone();
        caches.open(CACHE).then((c) => c.put(e.request, copy)).catch(() => {});
      }
      return res;
    }).catch(() => caches.match(e.request))
  );
});

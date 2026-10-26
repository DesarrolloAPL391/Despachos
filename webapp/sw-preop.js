// Service worker SOLO del preoperacional.
//
// Va aparte del de la aplicación (sw.js) por dos razones:
//   1) El conductor no tiene por qué descargar la app de administración completa en su celular.
//      Aquí se guarda únicamente lo que esa pantalla necesita.
//   2) Se registra con scope 'preoperacional.html', más estrecho que el de sw.js (toda la
//      carpeta). Dos service workers pueden convivir si sus ámbitos son distintos: para esa
//      página manda el más específico y la aplicación sigue con el suyo, intacta.
//
// Chrome exige manifiesto + service worker con manejador de fetch para ofrecer "Instalar"; sin
// esto decía "No se puede instalar esta app".
const CACHE = 'preop-apl-v1';
const SHELL = [
  'preoperacional.html',
  'css/styles.css',
  'js/config.js',
  'js/jsqr.min.js',
  'preoperacional.webmanifest',
  'icons/icon-192.png', 'icons/icon-512.png', 'icons/logo.png',
];

self.addEventListener('install', (e) => {
  e.waitUntil(
    caches.open(CACHE)
      // Si algún archivo falla, la instalación NO se cae entera: el conductor se queda sin
      // esa pieza, no sin la pantalla.
      .then((c) => Promise.all(SHELL.map((u) =>
        c.add(new Request(u, { cache: 'reload' })).catch(() => null))))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((ks) => Promise.all(ks.filter((k) => k.startsWith('preop-apl-') && k !== CACHE)
        .map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('message', (e) => { if (e.data === 'SKIP_WAITING') self.skipWaiting(); });

// Los DATOS siempre van por red: una inspección guardada en caché sería una inspección que
// nadie recibió. Solo se sirve de caché lo que es la pantalla en sí, y únicamente si la red
// falla (así una versión nueva entra sola en cuanto hay señal).
self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin !== self.location.origin) return;   // Supabase, esm.sh: siempre red

  e.respondWith(
    fetch(req)
      .then((res) => {
        if (res && res.ok) {
          const copia = res.clone();
          caches.open(CACHE).then((c) => c.put(req, copia)).catch(() => {});
        }
        return res;
      })
      .catch(() => caches.match(req, { ignoreSearch: true })
        .then((hit) => hit || caches.match('preoperacional.html')))
  );
});

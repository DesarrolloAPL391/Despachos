// 🪪 LECTOR DE LA CÉDULA por foto (sql/152). Lo usan los 3 links: actualizar-datos.html (general y
// enlace personal) y trabaja-con-nosotros.html; y la app con el escáner en vivo (escanearCedula), para
// registrar o verificar a alguien. Se lee el REVERSO, donde la cédula trae los datos escritos para máquinas:
//   * Cédula amarilla: el código de barras PDF417 → cédula, apellidos, nombres, sexo, fecha y lugar de
//     nacimiento y RH. En Android con Chrome lo lee el lector del propio teléfono (BarcodeDetector); en
//     los demás, ZXing (más flojo con fotos normales).
//   * Cédula digital: las 3 líneas tipo pasaporte (MRZ TD1) → cédula, apellidos, nombres, sexo y fecha
//     de nacimiento, con dígitos de control: si el OCR se equivoca, se nota y no se usa. No trae el RH.
// Ninguna trae la fecha ni el lugar de expedición. Todo corre en el celular (la foto no sale para
// leerse); lo leído es una AYUDA que la persona confirma. Las fotos se guardan como soporte.
// Formato del código de la amarilla: github.com/Eitol/colombian-cedula-reader (licencia MIT).

const ZXING = 'https://cdn.jsdelivr.net/npm/@zxing/library@0.21.3/umd/index.min.js';
const TESSERACT = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';

function cargarScript(src, global) {
  if (window[global]) return Promise.resolve();
  return new Promise((ok, mal) => {
    const s = document.createElement('script');
    s.src = src; s.async = true;
    s.onload = () => ok(); s.onerror = () => mal(new Error('No se pudo cargar el lector. Revisa el internet.'));
    document.head.appendChild(s);
  });
}

// ---------- Cédula amarilla: el texto del código de barras ----------
// 531 bytes con campos de largo fijo rellenos de NUL: ... huella(8) cédula(10) apellido1(23)
// apellido2(23) nombre1(23) nombre2(23) ?(1) sexo(1) nacimiento AAAAMMDD(8) lugar(2+3) ?(1) RH(2) ...
const FECHA_OK = (a, m, d) => {
  const f = new Date(Date.UTC(+a, +m - 1, +d));
  return f.getUTCFullYear() === +a && f.getUTCMonth() === +m - 1 && f.getUTCDate() === +d && f <= new Date();
};
export function leerCodigoCedula(texto) {
  // El lector del teléfono entrega los bytes como texto: la Ñ (latin-1) puede llegar como "�"
  const s = String(texto || '').replace(/(?<=[A-Z])�(?=[A-Z])/g, 'Ñ');
  if (!s.includes('PubDSK_')) return null;
  const NUL = /[\u0000�]+/;
  const g = /([MF])((?:19|20)\d{2})(\d{2})(\d{2})(\d{2})(\d{3})[\s\S]?((?:AB|A|B|O)[+-])/.exec(s);
  if (!g || !FECHA_OK(g[2], g[3], g[4])) return null;
  // La cédula: los 10 dígitos que van justo antes del primer apellido
  let m, ced = null;
  const re = /(\d{10})(?=[A-ZÑÁÉÍÓÚÜ])/g;
  while ((m = re.exec(s.slice(0, g.index)))) ced = m;
  if (!ced) return null;
  const base = ced.index + 10;
  const campo = (i, f) => s.slice(i, f).split(NUL)[0].trim();
  let partes;
  if (g.index === base + 93) {
    // Largos fijos intactos: cada nombre en su casilla (así se sabe cuál falta)
    partes = [campo(base, base + 23), campo(base + 23, base + 46), campo(base + 46, base + 69), campo(base + 69, base + 92)];
  } else {
    // El lector perdió el relleno: separar por los NUL que quedaron
    // (si no quedó ninguno, los nombres vienen pegados y no se pueden separar: se dejan vacíos)
    const p = s.slice(base, g.index).split(NUL).map((x) => x.trim().replace(/\d$/, '')).filter((x) => x && !/^\d$/.test(x));
    partes = p.length >= 4 ? p.slice(0, 4) : p.length === 3 ? [p[0], p[1], p[2], ''] : p.length === 2 ? [p[0], '', p[1], ''] : ['', '', '', ''];
  }
  const cedula = ced[1].replace(/^0+/, '');
  if (cedula.length < 5) return null;
  return {
    tipo: 'CODIGO', verificado: true, cedula,
    apellidos: [partes[0], partes[1]].filter(Boolean).join(' '),
    nombres: [partes[2], partes[3]].filter(Boolean).join(' '),
    sexo: g[1] === 'M' ? 'MASCULINO' : 'FEMENINO',
    fecha_nacimiento: `${g[2]}-${g[3]}-${g[4]}`,
    tipo_sangre: g[7],
    lugar_codigo: g[5] + g[6],
  };
}

// ---------- Cédula digital: las 3 líneas MRZ (TD1, 30 caracteres) ----------
const valorMrz = (c) => (c === '<' ? 0 : /\d/.test(c) ? +c : c.charCodeAt(0) - 55);
export const digitoMrz = (s) => String([...s].reduce((t, c, i) => t + valorMrz(c) * [7, 3, 1][i % 3], 0) % 10);
// Confusiones típicas del OCR, según lo que DEBE ir en cada posición
const A_NUM = { O: '0', Q: '0', D: '0', U: '0', I: '1', L: '1', T: '1', Z: '2', S: '5', G: '6', B: '8', A: '4' };
const A_LET = { 0: 'O', 1: 'I', 2: 'Z', 4: 'A', 5: 'S', 6: 'G', 8: 'B' };
const num = (s) => [...s].map((c) => A_NUM[c] || c).join('');
const numRelleno = (s) => [...s].map((c) => (c === 'K' || c === 'X' ? '<' : A_NUM[c] || c)).join('');
const letras = (s) => [...s].map((c) => A_LET[c] || c).join('');
const a30 = (l) => (l.length >= 30 ? l : l + '<'.repeat(30 - l.length));
// Dígitos que el OCR confunde entre sí (8↔6↔3↔0…): para corregir UN dígito de la fecha
const PARECIDOS = { 0: '689', 1: '7', 2: '7', 3: '8', 5: '6', 6: '058', 7: '12', 8: '0369', 9: '08' };
const variantes = (s) => {
  const v = [];
  for (let i = 0; i < s.length; i++) for (const c of PARECIDOS[s[i]] || '') v.push(s.slice(0, i) + c + s.slice(i + 1));
  return v;
};

// Ventanas de 30 caracteres de una línea que pueden ser la línea 2 (nacimiento, sexo, vencimiento,
// país, cédula). corregida = la fecha solo cuadró cambiando un dígito: se acepta si cuadra el compuesto.
function linea2(l) {
  const out = [];
  const s = a30(l);
  for (let o = 0; o + 30 <= s.length; o++) {
    const w = s.slice(o, o + 30);
    const nac7 = num(w.slice(0, 7)), sexo = letras(w[7]);
    const ven = num(w.slice(8, 14)), cv = num(w[14]), pais = letras(w.slice(15, 18));
    const opc = numRelleno(w.slice(18, 29)), cc = num(w[29]);
    if (!/^\d{7}$/.test(nac7)) continue;
    const puntos = (/^\d{6}$/.test(ven) && digitoMrz(ven) === cv ? 2 : 0) + (pais === 'COL' ? 1 : 0) + (/^[MF]$/.test(sexo) ? 1 : 0);
    if (puntos < 2) continue;
    const base = { puntos, sexo, ven, cv, opc, cc };
    if (digitoMrz(nac7.slice(0, 6)) === nac7[6]) out.push({ ...base, nac: nac7.slice(0, 6), cn: nac7[6], corregida: false });
    else for (const v of variantes(nac7)) if (digitoMrz(v.slice(0, 6)) === v[6]) out.push({ ...base, nac: v.slice(0, 6), cn: v[6], corregida: true });
  }
  return out.sort((a, b) => b.puntos - a.puntos);
}
export function leerMrzCedula(texto) {
  const lineas = String(texto || '').toUpperCase().split(/\n+/)
    .map((l) => l.replace(/[«‹(\[{]/g, '<').replace(/[^A-Z0-9<]/g, '')).filter((l) => l.length >= 20);
  for (let i = 0; i < lineas.length; i++) {
    // Dígito compuesto (línea 1 + línea 2): confirma también la cédula
    const l1 = i > 0 ? a30(lineas[i - 1]).slice(0, 30) : '';
    const c1 = l1 ? num(l1.slice(5, 15)) + numRelleno(l1.slice(15, 30)) : '';
    const compuesto = (x) => !!c1 && digitoMrz(c1 + x.nac + x.cn + x.ven + x.cv + x.opc) === x.cc;
    const l2 = linea2(lineas[i]).find((x) => (x.corregida ? compuesto(x) : true));
    if (!l2) continue;
    const yy = +l2.nac.slice(0, 2), siglo = 2000 + yy > new Date().getFullYear() ? 1900 : 2000;
    const [a, m, d] = [String(siglo + yy), l2.nac.slice(2, 4), l2.nac.slice(4, 6)];
    if (!FECHA_OK(a, m, d)) continue;
    const cedula = l2.opc.replace(/</g, '').replace(/^0+/, '');
    const verificado = compuesto(l2);
    let apellidos = '', nombres = '';
    if (lineas[i + 1]) {
      // El relleno final "<<<<" a veces sale como K o X: se quita desde el primer "<" del relleno
      const l3 = letras(lineas[i + 1]).replace(/<[KX<]*$/, '');
      const [ap, no] = l3.split(/<{2,}/);
      if (no !== undefined) { apellidos = ap.replace(/</g, ' ').trim(); nombres = no.replace(/</g, ' ').trim(); }
    }
    if (!/^\d{5,10}$/.test(cedula)) continue;
    return {
      tipo: 'MRZ', verificado, cedula, apellidos, nombres,
      sexo: l2.sexo === 'M' ? 'MASCULINO' : l2.sexo === 'F' ? 'FEMENINO' : '',
      fecha_nacimiento: `${a}-${m}-${d}`,
    };
  }
  return null;
}

// ---------- Imagen ----------
async function aImagen(file) {
  try { return await createImageBitmap(file, { imageOrientation: 'from-image' }); }
  catch {
    return await new Promise((ok, mal) => {
      const im = new Image();
      im.onload = () => ok(im); im.onerror = () => mal(new Error('No se pudo abrir la foto.'));
      im.src = URL.createObjectURL(file);
    });
  }
}
// Lienzo girado (cualquier ángulo: 90/180 para la orientación, unos grados para enderezar) y
// reducido a maxLado. img puede ser una foto o el <video> de la cámara; escala > 1 la agranda
// (ZXing lee mejor las barras finas de un cuadro de video agrandado), sin pasar de maxLado.
function lienzo(img, giro, maxLado, escala = 1) {
  const W = img.videoWidth || img.width, H = img.videoHeight || img.height;
  const k = Math.min(escala, maxLado / Math.max(W, H));
  const w = W * k, h = H * k, r = (giro * Math.PI) / 180;
  const c = document.createElement('canvas');
  c.width = Math.round(Math.abs(w * Math.cos(r)) + Math.abs(h * Math.sin(r)));
  c.height = Math.round(Math.abs(w * Math.sin(r)) + Math.abs(h * Math.cos(r)));
  const ctx = c.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, c.width, c.height);
  ctx.imageSmoothingQuality = 'high';
  ctx.translate(c.width / 2, c.height / 2);
  ctx.rotate(r);
  ctx.drawImage(img, -w / 2, -h / 2, w, h);
  return c;
}
// ¿Cédula amarilla? Color promedio del centro de la foto (solo decide qué se intenta primero)
function pareceAmarilla(img) {
  const c = document.createElement('canvas'); c.width = 48; c.height = 36;
  const ctx = c.getContext('2d');
  ctx.drawImage(img, img.width * 0.25, img.height * 0.25, img.width * 0.5, img.height * 0.5, 0, 0, 48, 36);
  const p = ctx.getImageData(0, 0, 48, 36).data;
  let r = 0, g = 0, b = 0;
  for (let i = 0; i < p.length; i += 4) { r += p[i]; g += p[i + 1]; b += p[i + 2]; }
  return (r + g) / 2 - b > 30 * (p.length / 4);
}
function grises(c) {
  const ctx = c.getContext('2d');
  const d = ctx.getImageData(0, 0, c.width, c.height);
  const p = d.data, lum = new Uint8ClampedArray(c.width * c.height);
  for (let i = 0, j = 0; i < p.length; i += 4, j++) {
    const y = 0.299 * p[i] + 0.587 * p[i + 1] + 0.114 * p[i + 2];
    p[i] = p[i + 1] = p[i + 2] = lum[j] = y;
  }
  ctx.putImageData(d, 0, 0);
  return lum;
}
// La foto que se guarda: reducida, sin recortar. El servidor acepta hasta 450.000 caracteres
// (sql/152): si una foto con mucho detalle se pasa, se baja la calidad y luego el tamaño.
export async function fotoCedula(file) {
  const img = await aImagen(file);
  let url = '';
  for (const [lado, q] of [[1280, 0.75], [1280, 0.6], [1024, 0.6], [900, 0.5]]) {
    url = lienzo(img, 0, lado).toDataURL('image/jpeg', q);
    if (url.length <= 430000) break;
  }
  return url;
}

// ---------- Lectores ----------
// El lector de códigos del teléfono (Android/Chrome, solo en https), o null si no hay
let _det;
async function detectorNativo() {
  if (_det !== undefined) return _det;
  _det = null;
  try {
    if ('BarcodeDetector' in window && (await window.BarcodeDetector.getSupportedFormats()).includes('pdf417')) {
      _det = new window.BarcodeDetector({ formats: ['pdf417'] });
    }
  } catch { /* sin lector nativo */ }
  return _det;
}
let _zx = null;
async function zxing() {
  if (_zx) return _zx;
  await cargarScript(ZXING, 'ZXing');
  const Z = window.ZXing;
  _zx = { Z, lector: new Z.PDF417Reader(),
    pistas: new Map([[Z.DecodeHintType.TRY_HARDER, true], [Z.DecodeHintType.POSSIBLE_FORMATS, [Z.BarcodeFormat.PDF_417]]]) };
  return _zx;
}
function codigoZxing(zx, c) {
  try {
    const fuente = new zx.Z.RGBLuminanceSource(grises(c), c.width, c.height);
    return leerCodigoCedula(zx.lector.decode(new zx.Z.BinaryBitmap(new zx.Z.HybridBinarizer(fuente)), zx.pistas).getText());
  } catch { return null; } // no lo encontró en este cuadro
}
async function conLugar(d) {
  if (d && d.tipo === 'CODIGO' && d.lugar_codigo && !d.lugar_nacimiento) {
    try { d.lugar_nacimiento = (await import('./cedula-lugares.js')).LUGARES[d.lugar_codigo] || ''; } catch { /* sin lugar */ }
  }
  return d;
}
// base = 0 si la foto está acostada (como se ve la cédula), 90 si está parada
async function leerBarras(img, base) {
  const det = await detectorNativo();
  if (det) {
    // El lector del teléfono (Android) es bueno: si él no lo encuentra, ZXing tampoco
    try { for (const r of await det.detect(img)) { const d = leerCodigoCedula(r.rawValue); if (d) return d; } } catch { /* nada */ }
    return null;
  }
  const zx = await zxing();
  // ZXing es exigente con el tamaño y la inclinación: se prueba enderezando unos grados (él solo
  // prueba también al revés, 180°)
  const intentos = [[0, 1200], [0, 1600], [3, 1200], [-3, 1200], [3, 1600], [-3, 1600], [6, 1600], [-6, 1600], [90, 1600]];
  for (const [giro, lado] of intentos) {
    const d = codigoZxing(zx, lienzo(img, base + giro, lado));
    if (d) return d;
    await new Promise((r) => setTimeout(r, 0)); // deja respirar la pantalla
  }
  return null;
}
// Modelo de Tesseract entrenado para las líneas MRZ (letra OCR-B): github.com/DoubangoTelecom/tesseractMRZ
// (BSD-3). La versión "fast" pesa 1,4 MB y queda en caché del navegador.
const MRZ_MODELO = 'https://cdn.jsdelivr.net/gh/DoubangoTelecom/tesseractMRZ@1e7adfecda5f3c9ae1fb12cf6b4b8c3958c63e46/tessdata_fast';
let _ocr = null;
async function lectorOcr(onProgreso) {
  if (_ocr) return _ocr;
  await cargarScript(TESSERACT, 'Tesseract');
  _ocr = await window.Tesseract.createWorker('mrz', 1, {
    langPath: MRZ_MODELO, gzip: false,
    logger: (m) => { if (onProgreso && m && typeof m.progress === 'number') onProgreso(m.status, m.progress); },
  });
  await _ocr.setParameters({ tessedit_char_whitelist: 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789<', tessedit_pageseg_mode: '6' });
  return _ocr;
}
async function leerMrz(img, base, onProgreso) {
  const w = await lectorOcr(onProgreso);
  // Derecha y al revés, a dos tamaños (el OCR acierta distinto según el tamaño de la letra)
  for (const [giro, lado] of [[0, 1200], [0, 1800], [180, 1200], [180, 1800]]) {
    const c = lienzo(img, base + giro, lado);
    // Las líneas van en el tercio de abajo del reverso: se lee la mitad inferior (más rápido y limpio)
    const y0 = Math.round(c.height * 0.45);
    const r = document.createElement('canvas'); r.width = c.width; r.height = c.height - y0;
    r.getContext('2d').drawImage(c, 0, y0, c.width, r.height, 0, 0, c.width, r.height);
    grises(r);
    const { data } = await w.recognize(r);
    const d = leerMrzCedula(data.text || '');
    if (d) return d;
  }
  return null;
}

// Lee el reverso. Devuelve los datos (con tipo CODIGO o MRZ) o null si no pudo.
export async function leerCedula(file, onProgreso) {
  const img = await aImagen(file);
  const base = img.height > img.width * 1.1 ? 90 : 0;
  const lectores = [() => leerBarras(img, base), () => leerMrz(img, base, onProgreso)];
  if (!pareceAmarilla(img)) lectores.reverse(); // la digital es blanca: primero sus líneas
  let d = null;
  for (const leer of lectores) { d = await leer(); if (d) break; }
  return conLugar(d);
}

// ---------- Escáner en vivo (cámara) ----------
// Para quien registra o verifica a alguien: se apunta al código de atrás y se lee solo, sin tomar
// foto. En Android/Chrome lo lee el teléfono (menos de un segundo); en el PC o el iPhone, ZXing cuadro
// a cuadro (más lento y exigente). La digital no trae código: "📸 Leer" toma el cuadro y lee sus líneas.
// Devuelve los datos de la cédula, o null si se canceló. Necesita https (o localhost) para la cámara.
const CSS_ESC = `
.ced-esc { position: fixed; inset: 0; z-index: 10000; background: #000; display: grid; grid-template-rows: 1fr auto auto; overflow: hidden; }
.ced-esc video { grid-area: 1 / 1; width: 100%; height: 100%; object-fit: contain; min-height: 0; background: #000; }
.ced-esc-marco { grid-area: 1 / 1; align-self: center; justify-self: center; width: min(86vw, 560px); aspect-ratio: 1.58;
  border: 3px dashed rgba(255,255,255,.95); border-radius: 14px; background: transparent;
  box-shadow: 0 0 0 2px rgba(0,0,0,.45), inset 0 0 0 2px rgba(0,0,0,.45); pointer-events: none; }
.ced-esc-txt { color: #fff; text-align: center; padding: 12px 16px; font: 15px/1.4 system-ui, sans-serif; }
.ced-esc-bot { display: flex; gap: 8px; justify-content: center; flex-wrap: wrap; padding: 0 16px calc(16px + env(safe-area-inset-bottom)); }
.ced-esc-bot button { border: 0; border-radius: 12px; padding: 12px 16px; font: 700 15px system-ui, sans-serif; background: #fff; color: #111; cursor: pointer; }
.ced-esc-bot button[data-x] { background: #4b5563; color: #fff; }
`;
let _cssEsc = false;
function pitido() {
  try {
    const a = new (window.AudioContext || window.webkitAudioContext)();
    const o = a.createOscillator(), g = a.createGain();
    o.frequency.value = 1400; g.gain.value = 0.12;
    o.connect(g).connect(a.destination);
    o.start(); o.stop(a.currentTime + 0.12);
    setTimeout(() => a.close(), 400);
  } catch { /* sin sonido */ }
  try { if (navigator.vibrate) navigator.vibrate(60); } catch { /* sin vibración */ }
}
export function escanearCedula() {
  if (!_cssEsc) { _cssEsc = true; const st = document.createElement('style'); st.textContent = CSS_ESC; document.head.appendChild(st); }
  return new Promise((fin) => {
    const ov = document.createElement('div');
    ov.className = 'ced-esc';
    ov.innerHTML = `<video playsinline muted></video><div class="ced-esc-marco"></div>
      <div class="ced-esc-txt">⏳ Abriendo la cámara…</div>
      <div class="ced-esc-bot"><button type="button" data-luz hidden>🔦 Linterna</button>
        <button type="button" data-foto>📸 Leer (cédula digital)</button><button type="button" data-x>Cancelar</button></div>`;
    document.body.appendChild(ov);
    const video = ov.querySelector('video'), txt = ov.querySelector('.ced-esc-txt');
    const GUIA = 'Apunta al <b>código de barras de atrás</b> de la cédula, de cerca y con buena luz: se lee solo.'
      + '<br><span style="font-size:13px;opacity:.85">¿Cédula digital (la nueva)? Que se vean las 3 líneas de abajo y toca 📸.</span>';
    let stream = null, vivo = true, ocupado = false;
    const cerrar = (d) => {
      if (!vivo) return;
      vivo = false;
      if (stream) stream.getTracks().forEach((t) => t.stop());
      ov.remove();
      fin(d || null);
    };
    const listo = async (d) => {
      ocupado = true; // que el bucle no la vuelva a leer mientras se cierra
      pitido(); txt.innerHTML = '✅ <b>¡Leída!</b>';
      await conLugar(d);
      setTimeout(() => cerrar(d), 250);
    };
    ov.querySelector('[data-x]').onclick = () => cerrar(null);
    ov.querySelector('[data-foto]').onclick = async () => {
      if (ocupado || !video.videoWidth) return;
      ocupado = true;
      txt.textContent = '⏳ Leyendo… no la muevas.';
      const foto = await new Promise((r) => lienzo(video, 0, 2400).toBlob(r, 'image/jpeg', 0.92));
      const d = await leerCedula(foto).catch(() => null);
      ocupado = false;
      if (!vivo) return;
      if (d) { listo(d); return; }
      txt.innerHTML = 'No se pudo leer. Acércala, sin reflejos y derecha, que se vea completa, y vuelve a tocar 📸.';
    };
    (async () => {
      try {
        stream = await navigator.mediaDevices.getUserMedia({ audio: false,
          video: { facingMode: { ideal: 'environment' }, width: { ideal: 1920 }, height: { ideal: 1080 } } });
      } catch {
        txt.innerHTML = '📷 No se pudo abrir la cámara. Dale permiso a la cámara en el navegador y vuelve a intentar.';
        return;
      }
      if (!vivo) { stream.getTracks().forEach((t) => t.stop()); return; }
      video.srcObject = stream;
      await video.play().catch(() => {});
      const pista = stream.getVideoTracks()[0];
      try {
        const cap = pista.getCapabilities ? pista.getCapabilities() : {};
        if (cap.focusMode && cap.focusMode.includes('continuous')) pista.applyConstraints({ advanced: [{ focusMode: 'continuous' }] }).catch(() => {});
        if (cap.torch) {
          const b = ov.querySelector('[data-luz]');
          let on = false;
          b.hidden = false;
          b.onclick = () => { on = !on; pista.applyConstraints({ advanced: [{ torch: on }] }).catch(() => {}); };
        }
      } catch { /* sin linterna ni enfoque */ }
      txt.innerHTML = GUIA;
      const det = await detectorNativo();
      const zx = det ? null : await zxing().catch(() => null);
      // Cuadro a cuadro: el del teléfono es rápido. ZXing tarda y es exigente: cada cuadro se le
      // pasa de una forma distinta (agrandado y enderezando unos grados), y se le da más aire.
      const FORMAS = [[0, 1.5], [3, 1.5], [-3, 1.5], [0, 1], [3, 1], [-3, 1], [6, 1.5], [-6, 1.5]];
      let n = 0;
      while (vivo) {
        await new Promise((r) => setTimeout(r, det ? 120 : 200));
        if (!vivo || ocupado || video.readyState < 2) continue;
        let d = null;
        try {
          if (det) { for (const r of await det.detect(video)) { d = leerCodigoCedula(r.rawValue); if (d) break; } }
          else if (zx) { const [giro, k] = FORMAS[n++ % FORMAS.length]; d = codigoZxing(zx, lienzo(video, giro, 2000, k)); }
        } catch { /* cuadro sin código */ }
        if (d && vivo && !ocupado) { await listo(d); return; }
      }
    })();
  });
}

// ---------- Componente: fotos del frente y el reverso + lectura ----------
// opts.validar(datos) → '' o un aviso (p. ej. "esta cédula no es la tuya"): con aviso no se ofrece usar.
// opts.onUsar(datos)  → la página pone los datos en sus campos.
const CSS = `
.ced { display: grid; gap: 12px; }
.ced-lados { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; }
.ced-lado { display: grid; gap: 6px; justify-items: center; }
.ced-marco { width: 100%; aspect-ratio: 1.58; border: 2px dashed #b9a9a9; border-radius: 12px; overflow: hidden; display: grid; place-items: center; background: #fbf8f8; text-align: center; }
.ced-marco img { width: 100%; height: 100%; object-fit: cover; }
.ced-marco span { font-size: 30px; opacity: .55; line-height: 1.1; }
.ced-marco small { display: block; font-size: 12px; font-weight: 700; opacity: 1; color: #6b6b6b; }
.ced-lado .hv-add { font-size: 13px; padding: 8px 10px; }
.ced-gal { font-size: 12px; color: #6b6b6b; text-decoration: underline; cursor: pointer; font-weight: 400; }
.ced-estado { border-radius: 12px; padding: 11px 13px; font-size: 14px; line-height: 1.45; }
.ced-estado.leyendo { background: #eff6ff; color: #1e3a8a; }
.ced-estado.ok { background: #f0fdf4; color: #14532d; border: 1px solid #bbf7d0; }
.ced-estado.mal { background: #fff7ed; color: #7c2d12; border: 1px solid #fed7aa; }
.ced-estado.alerta { background: #fee2e2; color: #991b1b; border: 1px solid #fecaca; }
.ced-estado table { width: 100%; border-collapse: collapse; margin: 6px 0; font-size: 13.5px; }
.ced-estado td { padding: 3px 0; vertical-align: top; }
.ced-estado td:first-child { color: #4b5563; width: 42%; padding-right: 8px; }
.ced-estado button { margin-top: 8px; border: 0; border-radius: 10px; padding: 10px 14px; font-size: 14px; font-weight: 700; cursor: pointer; background: #16a34a; color: #fff; }
.ced-estado .ced-usado { margin-top: 6px; font-weight: 700; }
.ced-estado .ced-pie { display: flex; flex-wrap: wrap; gap: 4px 12px; align-items: center; }
.ced-estado button.ced-no { background: none; color: #4b5563; text-decoration: underline; font-weight: 400; padding: 10px 2px; }
@media (max-width: 380px) { .ced-lados { grid-template-columns: 1fr; } }
`;
let _css = false;
const escH = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const fechaBonita = (f) => (f ? f.split('-').reverse().join('/') : '');

export function cedulaCaptura(contenedor, opts = {}) {
  if (!_css) { _css = true; const st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st); }
  contenedor.classList.add('ced');
  const lado = (k, t, ic) => `<div class="ced-lado" data-lado="${k}">
      <div class="ced-marco"><img alt="${t}" hidden><span>${ic}<small>${t}</small></span></div>
      <label class="hv-add"><span data-txt>📷 Foto ${k === 'frente' ? 'del frente' : 'de atrás'}</span><input type="file" accept="image/*" capture="environment" hidden></label>
      <label class="ced-gal">o de la galería<input type="file" accept="image/*" hidden></label>
    </div>`;
  contenedor.innerHTML = `<div class="ced-lados">${lado('frente', 'Frente (con tu foto)', '🪪')}${lado('reverso', 'Atrás (con el código)', '🔲')}</div>
    <div class="ced-estado" hidden></div>`;
  const estado = contenedor.querySelector('.ced-estado');
  const fotos = { frente: '', reverso: '' };
  let lectura = '', leidos = null, archivoReverso = null, turno = 0, decidio = false;
  const usar = () => {
    decidio = true;
    if (opts.onUsar) opts.onUsar(leidos);
    const pie = estado.querySelector('.ced-pie');
    if (pie) pie.outerHTML = '<div class="ced-usado">👍 Listo: los pusimos en el formulario. Revísalos en los siguientes pasos.</div>';
  };
  const pintar = (clase, html) => { estado.className = 'ced-estado ' + clase; estado.innerHTML = html; estado.hidden = false; };

  async function leer() {
    const yo = ++turno;
    leidos = null; lectura = ''; decidio = false;
    pintar('leyendo', '⏳ <b>Leyendo tu cédula…</b> <span data-p></span><br><span style="font-size:12.5px">La primera vez puede tardar un poco mientras se carga el lector.</span>');
    let d = null;
    try {
      d = await leerCedula(archivoReverso, (st, p) => {
        const el = estado.querySelector('[data-p]');
        if (!el || yo !== turno) return;
        if (st === 'recognizing text') el.textContent = Math.round(p * 100) + '%';
        else if (/loading language/.test(st)) el.textContent = `(cargando el lector ${Math.round(p * 100)}%)`;
      });
    } catch { d = null; }
    if (yo !== turno) return;
    if (!d) {
      lectura = 'NO';
      pintar('mal', `<b>No pudimos leer los datos de tu cédula.</b> No pasa nada: la foto queda guardada y tus datos los escribes tú.
        <br>Si quieres intentarlo otra vez: ponla sobre una mesa, con buena luz y sin reflejos, y toma la foto de cerca, que salga
        completa y derecha.`);
      return;
    }
    lectura = d.tipo;
    leidos = d;
    const aviso = opts.validar ? opts.validar(d) : '';
    const filas = [
      ['Cédula', d.cedula], ['Apellidos', d.apellidos], ['Nombres', d.nombres],
      ['Fecha de nacimiento', fechaBonita(d.fecha_nacimiento)], ['Lugar de nacimiento', d.lugar_nacimiento],
      ['Sexo', d.sexo], ['Grupo sanguíneo y RH', d.tipo_sangre],
    ].filter(([, v]) => v);
    const tabla = `<table>${filas.map(([k, v]) => `<tr><td>${k}</td><td><b>${escH(v)}</b></td></tr>`).join('')}</table>`;
    if (aviso) { pintar('alerta', `⚠️ <b>${escH(aviso)}</b>${tabla}`); return; }
    pintar('ok', `✅ <b>Leímos tu cédula.</b> ¿Están bien estos datos?${tabla}
      ${d.verificado ? '' : '<div style="font-size:12.5px">Revisa bien la cédula: la foto no se leyó del todo clara.</div>'}
      <div class="ced-pie"><button type="button" data-usar>Sí, usar estos datos</button>
        <button type="button" class="ced-no" data-no>No, los escribo yo</button></div>`);
    estado.querySelector('[data-usar]').onclick = usar;
    estado.querySelector('[data-no]').onclick = () => {
      decidio = true;
      estado.querySelector('.ced-pie').outerHTML = '<div class="ced-usado">Bien: no usamos estos datos. Escríbelos tú en los siguientes pasos.</div>';
    };
  }

  contenedor.addEventListener('change', async (e) => {
    const inp = e.target.closest('input[type="file"]');
    const f = inp && inp.files && inp.files[0];
    if (!f) return;
    inp.value = '';
    const box = inp.closest('[data-lado]'), k = box.dataset.lado;
    try {
      fotos[k] = await fotoCedula(f);
    } catch {
      pintar('mal', 'No se pudo abrir esa foto. Intenta de nuevo con la cámara.');
      return;
    }
    const img = box.querySelector('img');
    img.src = fotos[k]; img.hidden = false;
    box.querySelector('.ced-marco span').hidden = true;
    box.querySelector('[data-txt]').textContent = '📷 Tomar otra';
    if (opts.onCambio) opts.onCambio();
    if (k === 'reverso') { archivoReverso = f; leer(); }
  });

  const aArchivo = (url, nombre) => {
    const [cab, b64] = url.split(',');
    const bin = atob(b64), u8 = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) u8[i] = bin.charCodeAt(i);
    return new File([u8], nombre, { type: cab.slice(5, cab.indexOf(';')) });
  };
  return {
    falta: () => (!fotos.frente && !fotos.reverso ? 'ambos' : !fotos.frente ? 'frente' : !fotos.reverso ? 'reverso' : ''),
    frente: () => fotos.frente,
    reverso: () => fotos.reverso,
    lectura: () => lectura,
    leidos: () => leidos,
    // Aviso pendiente (la cédula leída no es la de la persona): bloquea seguir
    aviso: () => (leidos && opts.validar ? opts.validar(leidos) : ''),
    // Si leyó bien y la persona siguió sin responder "sí" o "no", se usan (los verá en el paso siguiente)
    usarSiNoDecidio: () => { if (leidos && !decidio && !(opts.validar && opts.validar(leidos))) usar(); },
    archivos: () => [fotos.frente && aArchivo(fotos.frente, 'cedula_frente.jpg'), fotos.reverso && aArchivo(fotos.reverso, 'cedula_reverso.jpg')].filter(Boolean),
  };
}

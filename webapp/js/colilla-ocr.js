// Lector de la colilla de consignación (sql/149).
//
// El OCR corre EN EL CELULAR con Tesseract.js: la foto no sale del teléfono para leerse, no hay
// que pagar un servicio y funciona igual en cualquier navegador. Lo que se lee es una AYUDA:
// el conductor ve los datos y puede corregir el valor (queda marcado). La prueba de que la plata
// entró la da el extracto del banco, no la foto.
//
// Una colilla del Banco de Bogotá trae: oficina, FECHA, REFERENCIA (la cédula del conductor,
// rellena de ceros), VALOR EFECTIVO / VALOR TOTAL y el número de comprobante.

const TESSERACT = 'https://cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js';
let _worker = null;

function cargarScript(src) {
  return new Promise((ok, mal) => {
    if (window.Tesseract) return ok();
    const s = document.createElement('script');
    s.src = src; s.async = true;
    s.onload = () => ok(); s.onerror = () => mal(new Error('No se pudo cargar el lector. Revisa el internet.'));
    document.head.appendChild(s);
  });
}

// El lector se carga una sola vez (pesa unos MB la primera vez; después queda en caché).
export async function prepararLector(onProgreso) {
  if (_worker) return _worker;
  await cargarScript(TESSERACT);
  _worker = await window.Tesseract.createWorker('spa', 1, {
    logger: (m) => { if (onProgreso && m && typeof m.progress === 'number') onProgreso(m.status, m.progress); },
  });
  return _worker;
}

// La foto a un lienzo en escala de grises y de un tamaño que el OCR lee bien. Respeta la
// orientación con que se tomó (las fotos del celular vienen "acostadas" por dentro).
async function aLienzo(file, maxLado) {
  let img;
  try { img = await createImageBitmap(file, { imageOrientation: 'from-image' }); }
  catch (e) {
    img = await new Promise((ok, mal) => {
      const im = new Image();
      im.onload = () => ok(im); im.onerror = () => mal(new Error('No se pudo abrir la foto.'));
      im.src = URL.createObjectURL(file);
    });
  }
  const w = img.width, h = img.height;
  const k = Math.min(1, maxLado / Math.max(w, h));
  const c = document.createElement('canvas');
  c.width = Math.round(w * k); c.height = Math.round(h * k);
  c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
  return c;
}

function grises(c) {
  const ctx = c.getContext('2d');
  const d = ctx.getImageData(0, 0, c.width, c.height);
  const p = d.data;
  for (let i = 0; i < p.length; i += 4) {
    const y = 0.299 * p[i] + 0.587 * p[i + 1] + 0.114 * p[i + 2];
    p[i] = p[i + 1] = p[i + 2] = y;
  }
  ctx.putImageData(d, 0, 0);
  return c;
}

// La foto que se guarda: reducida, para que no pese (≈150 KB).
export async function fotoParaGuardar(file) {
  const c = await aLienzo(file, 1280);
  return c.toDataURL('image/jpeg', 0.7);
}

export async function leerColilla(file, onProgreso) {
  const w = await prepararLector(onProgreso);
  const c = grises(await aLienzo(file, 1800));
  const { data } = await w.recognize(c);
  return { texto: data.text || '', confianza: Math.round(data.confidence || 0), ...extraerCampos(data.text || '') };
}

// ---------- Del texto a los datos ----------
const MESES = { ENE: 1, FEB: 2, MAR: 3, ABR: 4, MAY: 5, JUN: 6, JUL: 7, AGO: 8, SEP: 9, SET: 9, OCT: 10, NOV: 11, DIC: 12 };
const iso = (y, m, d) => {
  y = +y; m = +m; d = +d;
  if (y < 2020 || y > 2100 || m < 1 || m > 12 || d < 1) return '';
  const t = new Date(Date.UTC(y, m - 1, d));
  if (t.getUTCMonth() !== m - 1) return '';          // 31/11 no existe
  return t.toISOString().slice(0, 10);
};

// El OCR confunde algunos dígitos (en las pruebas leyó 10 como 19 y 30 como 38). Si la fecha
// leída no existe o cae lejos de hoy, se prueban esos cambios y se queda la más cercana a hoy.
const CONFUNDE = { 0: '869', 8: '036', 9: '04', 6: '05', 1: '7', 7: '1', 3: '8', 5: '6' };
function variantes(s) {
  const out = new Map([[s, 0]]);
  for (let i = 0; i < s.length; i++) {
    for (const c of CONFUNDE[s[i]] || '') { const v = s.slice(0, i) + c + s.slice(i + 1); if (!out.has(v)) out.set(v, 1); }
  }
  return [...out];   // [texto, cuántos dígitos se cambiaron]
}
function fechaCercana(y, m, d) {
  const hoy = Date.now(), dia = 864e5;
  let mejor = null;
  for (const [yy, cy] of variantes(String(y))) {
    for (const [mm, cm] of variantes(String(m))) {
      for (const [dd, cd] of variantes(String(d))) {
        const f = iso(yy, mm, dd);
        if (!f) continue;
        const lejos = (hoy - Date.parse(f)) / dia;     // días hacia atrás
        if (lejos < -2 || lejos > 60) continue;         // una colilla es de estos días
        const costo = cy + cm + cd;
        if (!mejor || costo < mejor.costo || (costo === mejor.costo && Math.abs(lejos) < mejor.lejos)) {
          mejor = { f, costo, lejos: Math.abs(lejos) };
        }
      }
    }
  }
  return mejor;
}

// "$ 98.800,00" · "98,800.00" · "98800" → 98800
export function aPesos(tok) {
  let s = String(tok || '').replace(/[$\s']/g, '');
  if (!/\d/.test(s)) return null;
  // Centavos al final (",00" o ".00") cuando el número tiene más de tres cifras antes.
  const m = /^(.*\d)[.,](\d{2})$/.exec(s);
  if (m && /\d{4,}|\d[.,]\d{3}/.test(m[1])) s = m[1];
  s = s.replace(/[.,]/g, '');
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export function extraerCampos(texto) {
  const T = String(texto || '').normalize('NFD').replace(/[̀-ͯ]/g, '').toUpperCase();
  const lineas = T.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);

  // Fecha: aaaa/mm/dd (así imprime el banco), dd/mm/aaaa o "15 OCT 2026". Se prefiere la de
  // la línea que dice FECHA.
  const fechas = [];
  const agregar = (pref, y, m, d) => { const x = fechaCercana(y, m, d); if (x) fechas.push({ pref, ...x }); };
  lineas.forEach((l) => {
    const pref = /FECHA/.test(l) ? 0 : 1;
    let r;
    const re1 = /(2\d{3})\s*[/.-]\s*(\d{1,2})\s*[/.-]\s*(\d{1,2})/g;
    while ((r = re1.exec(l))) agregar(pref, r[1], r[2], r[3]);
    const re2 = /\b(\d{1,2})\s*[/.-]\s*(\d{1,2})\s*[/.-]\s*(2\d{3})/g;
    while ((r = re2.exec(l))) agregar(pref, r[3], r[2], r[1]);
    const re3 = /\b(\d{1,2})\s*(?:DE\s+)?(ENE|FEB|MAR|ABR|MAY|JUN|JUL|AGO|SEP|SET|OCT|NOV|DIC)[A-Z]*\.?\s*(?:DE\s+)?(2\d{3})/g;
    while ((r = re3.exec(l))) agregar(pref, r[3], MESES[r[2]], r[1]);
  });
  fechas.sort((a, b) => a.pref - b.pref || a.costo - b.costo || a.lejos - b.lejos);
  const fecha = fechas.length ? fechas[0].f : '';
  // Si hubo que corregir dígitos, el conductor lo ve marcado para que confirme.
  const fechaDudosa = fechas.length ? fechas[0].costo > 0 : false;

  // Valor: en las líneas de VALOR / TOTAL / EFECTIVO; si hay varias, la de TOTAL y la mayor.
  // Se descartan los números que parecen cédula o referencia (largos y sin puntos).
  const tokRe = /(?:\$|\bS\s)?\s*(\d{1,3}(?:[.,']\s?\d{3})+(?:[.,]\d{1,2})?|\d{3,7}(?:[.,]\d{2})?)(?![\d])/g;
  const candidatos = [];
  lineas.forEach((l) => {
    const peso = /TOTAL/.test(l) ? 3 : /VALOR|EFECTIVO|MONTO|IMPORTE|CONSIGNA|\$/.test(l) ? 2 : 0;
    if (!peso || /FECHA|HORA|REF|COMPROBANTE|APROBACI|OFICINA|NIT|TEL/.test(l)) return;
    let r;
    while ((r = tokRe.exec(l))) {
      const n = aPesos(r[1]);
      if (n != null && n >= 1000 && n <= 10000000) candidatos.push({ n, peso });
    }
  });
  candidatos.sort((a, b) => b.peso - a.peso || b.n - a.n);
  const valor = candidatos.length ? candidatos[0].n : null;

  // Referencia: el número largo de la línea de REFERENCIA (la cédula con ceros adelante).
  const largos = [];
  lineas.forEach((l) => {
    const re = /\d[\d ]{4,}\d/g; let r;
    while ((r = re.exec(l))) {
      const dig = r[0].replace(/\s/g, '');
      if (dig.length >= 6) largos.push({ dig, sinCeros: dig.replace(/^0+/, ''), ref: /REF/.test(l) });
    }
  });
  const refL = largos.find((x) => x.ref) || null;
  const referencia = refL ? refL.dig : '';
  const numeros = [...new Set(largos.map((x) => x.sinCeros).filter((x) => x.length >= 5))];

  // Comprobante / número de aprobación.
  let comprobante = '';
  for (const l of lineas) {
    if (/COMPROBANTE|APROBACI|AUTORIZACI|CONSECUTIVO|SERIAL|NO\.?\s*TRX|TRANSACCION\s*(NO|#)/.test(l)) {
      const r = /(\d{4,})/.exec(l.replace(/(20\d{2})[/.-]\d{1,2}[/.-]\d{1,2}/g, ''));
      if (r) { comprobante = r[1]; break; }
    }
  }

  const banco = /BOGOTA/.test(T) ? 'Banco de Bogotá' : /BANCOLOMBIA/.test(T) ? 'Bancolombia'
    : /DAVIVIENDA/.test(T) ? 'Davivienda' : /BBVA/.test(T) ? 'BBVA' : /OCCIDENTE/.test(T) ? 'Banco de Occidente'
    : /POPULAR/.test(T) ? 'Banco Popular' : /AV ?VILLAS/.test(T) ? 'AV Villas' : '';

  return { fecha, fechaDudosa, valor, referencia, numeros, comprobante, banco };
}

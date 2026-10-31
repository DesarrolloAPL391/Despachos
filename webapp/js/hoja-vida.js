// 📋 HOJA DE VIDA FO-GH-03 (sql/150): piezas que comparten el link del colaborador
// (actualizar-datos.html), el de aspirantes (trabaja-con-nosotros.html) y la ficha de la app.
//   * listaEditor / leerLista: las listas del formato (estudios, familiares, empleos), una tarjeta
//     por fila, con "+ Agregar" y "✕ Quitar".
//   * firmaPad: la firma con el dedo (o el mouse) sobre un canvas; sale como PNG liviano.
// Los nombres de las llaves son los mismos de la base, así lo que se envía no se traduce.
import { HV_LISTAS } from './config.js';

const CSS = `
.hv-lista { display: grid; gap: 10px; }
.hv-fila { border: 1px solid var(--borde, var(--border, #e6dada)); border-radius: 12px; padding: 10px 12px; background: #fff; }
.hv-fila.mal { border-color: #ef4444; box-shadow: 0 0 0 2px rgba(239,68,68,.15); }
.hv-fila-h { display: flex; align-items: center; justify-content: space-between; gap: 8px; margin-bottom: 8px; font-size: 13px; font-weight: 700; color: var(--rojo, var(--primary, #ED1C24)); }
.hv-fila-h button { border: 0; background: none; color: #b91c1c; font-size: 13px; font-weight: 700; cursor: pointer; padding: 4px 6px; }
.hv-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 10px; }
.hv-grid .hv-full { grid-column: 1 / -1; }
@media (max-width: 520px) { .hv-grid { grid-template-columns: 1fr; } }
.hv-grid label { display: block; font-size: 12px; font-weight: 600; color: #444; }
.hv-grid input, .hv-grid select, .hv-grid textarea { display: block; width: 100%; margin-top: 4px; box-sizing: border-box; font: inherit; font-size: 15px;
  padding: 9px 10px; border: 1px solid var(--borde, var(--border, #e6dada)); border-radius: 9px; background: #fff; color: inherit; }
.hv-grid textarea { min-height: 64px; resize: vertical; }
.hv-req { color: var(--rojo, #ED1C24); }
.hv-add { justify-self: start; border: 1px dashed var(--rojo, var(--primary, #ED1C24)); color: var(--rojo, var(--primary, #ED1C24)); background: #fff;
  border-radius: 10px; padding: 9px 14px; font-size: 14px; font-weight: 700; cursor: pointer; }
.hv-vacia { font-size: 13px; color: #6b6b6b; margin: 0; }
.hv-firma { display: grid; gap: 8px; }
.hv-firma canvas { width: 100%; height: 170px; border: 1px dashed #b9a9a9; border-radius: 12px; background: #fff; touch-action: none; cursor: crosshair; }
.hv-firma .hv-firma-pie { display: flex; justify-content: space-between; align-items: center; font-size: 12px; color: #6b6b6b; }
.hv-firma button { border: 0; background: none; color: #b91c1c; font-weight: 700; cursor: pointer; font-size: 13px; }
.hv-foto { display: grid; justify-items: center; gap: 10px; }
.hv-foto-marco { width: 168px; height: 224px; border: 2px dashed #b9a9a9; border-radius: 14px; overflow: hidden; display: grid; place-items: center; background: #fbf8f8; }
.hv-foto-marco img { width: 100%; height: 100%; object-fit: cover; }
.hv-foto-marco span { font-size: 54px; opacity: .45; }
.hv-foto-bot { display: grid; justify-items: center; gap: 6px; }
.hv-foto-btn { display: inline-block; text-align: center; }
.hv-foto-gal { font-size: 13px; color: #6b6b6b; text-decoration: underline; cursor: pointer; font-weight: 400; }
.hv-foto-err { color: #b91c1c; font-size: 13px; }
`;
let _css = false;
function ponerCss() {
  if (_css) return;
  _css = true;
  const st = document.createElement('style');
  st.textContent = CSS;
  document.head.appendChild(st);
}
const escH = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

function controlHtml(c, v) {
  const val = v == null ? '' : String(v);
  if (c.t === 'enum') {
    const ops = [...c.o];
    if (val && !ops.includes(val)) ops.unshift(val); // conserva un valor viejo que ya no está en la lista
    return `<select data-hk="${c.k}"><option value="">Selecciona…</option>${ops.map((o) =>
      `<option value="${escH(o)}"${o === val ? ' selected' : ''}>${escH(o)}</option>`).join('')}</select>`;
  }
  if (c.t === 'textarea') return `<textarea data-hk="${c.k}" maxlength="600">${escH(val)}</textarea>`;
  const tipo = c.t === 'date' ? 'date' : c.t === 'number' ? 'number' : c.t === 'tel' ? 'tel' : 'text';
  const extra = c.t === 'number' ? ' inputmode="numeric" min="0" max="120"' : c.t === 'tel' ? ' inputmode="tel" maxlength="15"' : ' maxlength="200"';
  return `<input type="${tipo}" data-hk="${c.k}" value="${escH(val)}"${extra} />`;
}

function filaHtml(def, n, fila) {
  return `<div class="hv-fila">
    <div class="hv-fila-h"><span>${escH(def.uno[0].toUpperCase() + def.uno.slice(1))} ${n}</span><button type="button" data-hv-quitar>✕ Quitar</button></div>
    <div class="hv-grid">${def.campos.map((c) => `<label class="${c.t === 'textarea' ? 'hv-full' : ''}">${escH(c.l)}${c.req ? ' <span class="hv-req">*</span>' : ''}
      ${controlHtml(c, fila[c.k])}</label>`).join('')}</div>
  </div>`;
}

// Arma el editor de una lista con sus filas actuales. Devuelve el contenedor (div.hv-lista).
// opts.minFilas: filas vacías para empezar (ej. 1, para que se vea qué llenar).
export function listaEditor(lista, valores, opts = {}) {
  ponerCss();
  const def = HV_LISTAS[lista];
  const box = document.createElement('div');
  box.className = 'hv-lista';
  box.dataset.hvLista = lista;
  const filas = (Array.isArray(valores) ? valores : []).slice(0, def.max);
  while (filas.length < (opts.minFilas || 0)) filas.push({});
  const pintar = (datos) => {
    box.innerHTML = datos.map((f, i) => filaHtml(def, i + 1, f)).join('')
      + (datos.length ? '' : `<p class="hv-vacia">${escH(opts.vacio || `Sin ${def.label.toLowerCase()} registrados.`)}</p>`)
      + (datos.length < def.max ? `<button type="button" class="hv-add" data-hv-add>+ Agregar ${escH(def.uno)}</button>` : '');
  };
  pintar(filas);
  box.addEventListener('click', (e) => {
    const quitar = e.target.closest('[data-hv-quitar]');
    const add = e.target.closest('[data-hv-add]');
    if (!quitar && !add) return;
    const datos = leerFilas(box, def).map((x) => x.datos);
    if (quitar) datos.splice([...box.querySelectorAll('.hv-fila')].indexOf(quitar.closest('.hv-fila')), 1);
    if (add) datos.push({});
    pintar(datos);
    if (add) box.querySelectorAll('.hv-fila')[datos.length - 1]?.querySelector('input, select, textarea')?.focus();
  });
  return box;
}

function leerFilas(box, def) {
  return [...box.querySelectorAll('.hv-fila')].map((el) => {
    const datos = {};
    for (const c of def.campos) {
      const inp = el.querySelector(`[data-hk="${c.k}"]`);
      let v = String(inp?.value ?? '').trim();
      if (v && (!c.t || c.t === 'textarea') && c.k !== 'contacto') v = v.toUpperCase();
      if (v && c.t === 'tel') v = v.replace(/\D/g, '');
      if (v) datos[c.k] = v;
    }
    return { el, datos };
  });
}

// Lee la lista: filas vacías se ignoran; si a una fila le falta un dato obligatorio, devuelve
// el error y marca la fila. { filas: [...], error: '' | 'Falta …', el: fila con el problema }
export function leerLista(box) {
  const def = HV_LISTAS[box.dataset.hvLista];
  const out = [];
  for (const [i, { el, datos }] of leerFilas(box, def).entries()) {
    el.classList.remove('mal');
    if (!Object.keys(datos).length) continue;
    const falta = def.campos.find((c) => c.req && !datos[c.k]);
    if (falta) {
      el.classList.add('mal');
      return { filas: out, error: `Falta "${falta.l}" en ${def.uno} ${i + 1}.`, el };
    }
    if (datos.fecha_ingreso && datos.fecha_retiro && datos.fecha_retiro < datos.fecha_ingreso) {
      el.classList.add('mal');
      return { filas: out, error: `En ${def.uno} ${i + 1} la fecha de retiro es anterior a la de ingreso.`, el };
    }
    out.push(datos);
  }
  return { filas: out, error: '', el: null };
}

// Foto tipo documento con la cámara del celular (o de la galería). Se recorta centrada a 3:4 y
// sale en JPEG de 480×640 (unos 40-80 KB). Devuelve { vacia(), dataUrl() }.
export function fotoCaptura(contenedor) {
  ponerCss();
  contenedor.classList.add('hv-foto');
  contenedor.innerHTML = `<div class="hv-foto-marco"><img alt="Tu foto" hidden><span>👤</span></div>
    <div class="hv-foto-bot">
      <label class="hv-add hv-foto-btn"><span data-txt>📷 Tomarme la foto</span><input type="file" accept="image/*" capture="user" hidden></label>
      <label class="hv-foto-gal">o elegir una foto de la galería<input type="file" accept="image/*" hidden></label>
    </div>
    <div class="hv-foto-err" hidden></div>`;
  const img = contenedor.querySelector('img');
  const err = contenedor.querySelector('.hv-foto-err');
  let url = '';
  contenedor.addEventListener('change', async (e) => {
    const f = e.target.files && e.target.files[0];
    e.target.value = '';
    if (!f) return;
    err.hidden = true;
    try {
      url = await recortarFoto(f);
      img.src = url; img.hidden = false;
      contenedor.querySelector('.hv-foto-marco span').hidden = true;
      contenedor.querySelector('[data-txt]').textContent = '📷 Tomar otra';
    } catch {
      err.textContent = 'No se pudo leer esa foto. Intenta de nuevo con la cámara.'; err.hidden = false;
    }
  });
  return { vacia: () => !url, dataUrl: () => url };
}
function recortarFoto(file) {
  return new Promise((res, rej) => {
    const src = URL.createObjectURL(file);
    const im = new Image();
    im.onload = () => {
      URL.revokeObjectURL(src);
      const W = 480, H = 640;
      let sw = im.naturalWidth, sh = im.naturalHeight, sx = 0, sy = 0;
      if (sw / sh > W / H) { sw = sh * W / H; sx = (im.naturalWidth - sw) / 2; } else { sh = sw * H / W; sy = (im.naturalHeight - sh) * 0.35; }
      const c = document.createElement('canvas'); c.width = W; c.height = H;
      c.getContext('2d').drawImage(im, sx, sy, sw, sh, 0, 0, W, H);
      res(c.toDataURL('image/jpeg', 0.82));
    };
    im.onerror = () => { URL.revokeObjectURL(src); rej(new Error('foto')); };
    im.src = src;
  });
}

// Firma con el dedo. Devuelve { vacia(), limpiar(), dataUrl() }. La imagen sale en PNG, en
// trazo negro sobre fondo transparente y a lo sumo 600 px de ancho (unos pocos KB).
export function firmaPad(contenedor) {
  ponerCss();
  contenedor.classList.add('hv-firma');
  contenedor.innerHTML = `<canvas></canvas>
    <div class="hv-firma-pie"><span>Firma aquí con el dedo</span><button type="button" data-borrar>Borrar firma</button></div>`;
  const cv = contenedor.querySelector('canvas');
  const ctx = cv.getContext('2d');
  let trazos = 0, dibujando = false, ultimo = null;
  const ajustar = () => {
    const r = cv.getBoundingClientRect();
    if (!r.width) return;
    const k = Math.min(600 / r.width, 2);
    cv.width = Math.round(r.width * k); cv.height = Math.round(r.height * k);
    ctx.setTransform(k, 0, 0, k, 0, 0);
    ctx.lineWidth = 2.4; ctx.lineCap = 'round'; ctx.lineJoin = 'round'; ctx.strokeStyle = '#111';
    trazos = 0;
  };
  const punto = (e) => { const r = cv.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top }; };
  cv.addEventListener('pointerdown', (e) => {
    if (!cv.width) ajustar();
    dibujando = true; ultimo = punto(e); cv.setPointerCapture(e.pointerId);
    ctx.beginPath(); ctx.arc(ultimo.x, ultimo.y, 1.1, 0, Math.PI * 2); ctx.fillStyle = '#111'; ctx.fill();
  });
  cv.addEventListener('pointermove', (e) => {
    if (!dibujando) return;
    const p = punto(e);
    ctx.beginPath(); ctx.moveTo(ultimo.x, ultimo.y); ctx.lineTo(p.x, p.y); ctx.stroke();
    ultimo = p; trazos++;
  });
  const fin = () => { dibujando = false; };
  cv.addEventListener('pointerup', fin); cv.addEventListener('pointercancel', fin);
  contenedor.querySelector('[data-borrar]').onclick = () => { ctx.clearRect(0, 0, cv.width, cv.height); trazos = 0; };
  // El canvas se mide cuando ya se ve (el paso puede estar oculto al crearlo)
  new ResizeObserver(() => { if (!trazos) ajustar(); }).observe(cv);
  return {
    vacia: () => trazos < 8,  // un punto o un rayón no es una firma
    limpiar: () => { ctx.clearRect(0, 0, cv.width, cv.height); trazos = 0; },
    dataUrl: () => cv.toDataURL('image/png'),
  };
}

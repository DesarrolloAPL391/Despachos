import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY, TABLES, TABLE_ORDER, PAGE_SIZE, APP_VERSION, configTablaPuesto } from './config.js';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);

// Estado
let current = null;     // nombre de la tabla actual
let page = 0;
let term = '';
let filters = {};       // filtros dinámicos activos { columna: valor }
let editing = null;     // fila en edición (null = nuevo)
const fkCache = {};     // cache de opciones de FK por tabla
let CTX = null;         // contexto del usuario { rol, nombre, puesto, rutas[], ids[], despachador_id }


let puestoTables = []; // tablas de puesto descubiertas (laureles, etc.)

// Descubre las tablas de despacho desde `tablas_despacho` y registra su config en caliente
async function registerPuestoTables() {
  puestoTables = [];
  const { data, error } = await sb.from('tablas_despacho').select('tabla, label, puesto').eq('activo', true).order('label');
  if (error) return;
  for (const t of (data || [])) {
    if (!t.tabla) continue;
    if (!TABLES[t.tabla]) TABLES[t.tabla] = configTablaPuesto(t.label);
    if (!puestoTables.includes(t.tabla)) puestoTables.push(t.tabla);
  }
}
// Orden del menú con las tablas de puesto insertadas tras "despachos"
function menuOrder() {
  const base = [...TABLE_ORDER];
  const i = base.indexOf('despachos');
  base.splice(i < 0 ? base.length : i + 1, 0, ...puestoTables.filter((t) => !base.includes(t)));
  return base;
}

// ---------- roles ----------
function isAdmin() { return CTX?.rol === 'admin'; }
function normRuta(s) { return String(s || '').toLowerCase().replace(/\s+/g, '').trim(); }
function allowedRutaSet() { return new Set((CTX?.rutas || []).map(normRuta)); }
// Tablas visibles según el rol:
//  - admin: todas
//  - despachador con tabla de puesto propia (ej. laureles): solo esa
//  - despachador sin tabla propia: las marcadas con despachador:true (despachos, filtrado por rutas)
function visibleTables() {
  if (isAdmin()) return menuOrder();
  // despachador: todas las tablas de su puesto (puede tener varias)
  const mine = (CTX?.tablas || []).map((t) => t.tabla).filter((t) => TABLES[t]);
  if (mine.length) {
    // Si además tiene rutas que se despachan en la vista general, agrega "Despachos"
    if (CTX?.verDespachos && !mine.includes('despachos')) mine.push('despachos');
    // Tablas generales para despachadores (Resumen, Conductores SONAR, …)
    for (const n of TABLE_ORDER) {
      if (n !== 'despachos' && TABLES[n].despachador && !mine.includes(n)) mine.push(n);
    }
    return mine;
  }
  return TABLE_ORDER.filter((n) => TABLES[n].despachador); // sin tablas propias → despachos por ruta + generales
}

// ---------- utilidades ----------
function toast(msg, kind = '') {
  const t = $('toast');
  t.textContent = msg; t.className = 'toast ' + kind; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), 2600);
}
function getPath(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? o : o[k]), obj);
}
// Modal de confirmación reutilizable → devuelve Promise<boolean>
let _confirmResolve = null;
function confirmAction({ title = 'Confirmar', lead = '', message = '', okLabel = 'Confirmar', danger = false } = {}) {
  return new Promise((resolve) => {
    _confirmResolve = resolve;
    $('confirm-title').textContent = title;
    $('confirm-lead').textContent = lead;
    $('confirm-lead').hidden = !lead;
    $('confirm-body').textContent = message;
    $('confirm-body').hidden = !message;
    const yes = $('confirm-yes');
    yes.textContent = okLabel;
    yes.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
    $('confirm-modal').hidden = false;
  });
}
// Capa de carga que bloquea TODA la pantalla (evita doble click y que el usuario toque algo)
function showBusy(msg = 'Procesando…') {
  let el = document.getElementById('busy-overlay');
  if (!el) {
    el = document.createElement('div');
    el.id = 'busy-overlay'; el.className = 'busy-overlay';
    el.innerHTML = '<div class="busy-box"><div class="busy-spin"></div><div class="busy-msg"></div></div>';
    document.body.appendChild(el);
  }
  el.querySelector('.busy-msg').textContent = msg;
  el.hidden = false;
}
function hideBusy() { const el = document.getElementById('busy-overlay'); if (el) el.hidden = true; }
function _confirmClose(val) {
  $('confirm-modal').hidden = true;
  const r = _confirmResolve; _confirmResolve = null;
  if (r) r(val);
}
$('confirm-yes').addEventListener('click', () => _confirmClose(true));
$('confirm-no').addEventListener('click', () => _confirmClose(false));
$('confirm-x').addEventListener('click', () => _confirmClose(false));
function fmt(v) {
  if (v === null || v === undefined) return '';
  if (v === true) return 'Sí';
  if (v === false) return 'No';
  // Quitar los segundos a las horas (HH:MM:SS -> HH:MM), tanto en horas sueltas como en fechas+hora
  return String(v).replace(/(\b\d{1,2}:\d{2}):\d{2}(\.\d+)?/g, '$1');
}
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function chipClass(v) {
  const s = String(v || '').toUpperCase().trim();
  if (s === 'TABLA') return 'chip chip-indigo';
  if (s === 'LIBRE') return 'chip chip-violet';
  if (s === 'DESPACHADO' || s === 'ENABLED' || s === 'CERRADO' || s === 'ENCENDIDO' || s === 'SÍ' || s === 'SI') return 'chip chip-green';
  if (s === 'APAGADO') return 'chip chip-gray';
  if (s === 'NO REALIZA EL VIAJE' || s === 'DISABLED' || s === 'CANCELADO' || s === 'NO') return 'chip chip-red';
  if (s === 'ABIERTO') return 'chip chip-amber';
  if (['PESCA', 'TALLER', 'CAMBIO DE TABLA', 'ADELANTADO', 'CONDUCTOR EN OTRA RUTA'].includes(s)) return 'chip chip-amber';
  return 'chip chip-gray';
}

// ---------- autenticación ----------
let bootedFor = null; // email para el que ya se inicializó la app (evita reinicios en refresh de token)
async function init() {
  const { data } = await sb.auth.getSession();
  if (data.session) { bootedFor = data.session.user.email; await showApp(data.session.user); }
  else showLogin();

  sb.auth.onAuthStateChange((_e, session) => {
    if (!session) {
      bootedFor = null; sessionUser = null;
      if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
      showLogin(); return;
    }
    if (session.user.email === bootedFor) return; // mismo usuario (refresh de token): no reiniciar
    bootedFor = session.user.email;
    showApp(session.user);
  });
}

function showLogin() {
  $('app').hidden = true;
  $('login-screen').hidden = false;
}

// ---------- sesión única por dispositivo (despachadores) ----------
let sessionUser = null, sessTimer = null;
function getDeviceId() {
  let d = localStorage.getItem('apl_device_id');
  if (!d) { d = (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2) + Date.now()); localStorage.setItem('apl_device_id', d); }
  return d;
}
async function registrarDispositivo(user) {
  await sb.from('dispositivos').upsert(
    { user_id: user.id, device_id: getDeviceId(), nombre: navigator.userAgent.slice(0, 120), actualizado: new Date().toISOString() },
    { onConflict: 'user_id' },
  );
}
async function verificarDispositivo() {
  if (!sessionUser) return;
  const { data, error } = await sb.from('dispositivos').select('device_id').eq('user_id', sessionUser.id).maybeSingle();
  if (error || !data) return;
  if (data.device_id && data.device_id !== getDeviceId()) {
    if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
    sessionUser = null;
    alert('Tu cuenta se abrió en otro dispositivo. Se cerrará esta sesión aquí.');
    await sb.auth.signOut();
  }
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) { verificarDispositivo(); refreshContext(); } });

// Firma del contexto para detectar si el admin cambió el puesto/tablas/rutas
function ctxSig(c) {
  return c ? (c.puesto || '') + '|' + JSON.stringify((c.tablas || []).map((t) => t.tabla)) + '|' + (c.ids || []).join(',') : '';
}
// Recarga el contexto del despachador y, si cambió, reconstruye el menú al vuelo
async function refreshContext() {
  if (!sessionUser || CTX?.rol !== 'despachador') return;
  let nuevo;
  try { const { data } = await sb.rpc('mi_contexto'); nuevo = data; } catch { return; }
  if (!nuevo || ctxSig(nuevo) === ctxSig(CTX)) return; // sin cambios
  CTX = nuevo;
  for (const t of (CTX.tablas || [])) { if (t.tabla && !TABLES[t.tabla]) TABLES[t.tabla] = configTablaPuesto(t.label); }
  await registerPuestoTables();
  CTX.verDespachos = false;
  if ((CTX.tablas || []).length && (CTX.ids || []).length) {
    try { const { count } = await sb.from('despachos').select('id', { count: 'exact', head: true }); CTX.verDespachos = (count || 0) > 0; } catch { /* */ }
  }
  $('user-email').textContent = etiquetaUsuario(sessionUser);
  buildSidebar();
  const vis = visibleTables();
  if (!vis.includes(current)) { current = null; selectTable(vis[0] || 'despachos'); }
  toast('Tu puesto/tablas se actualizaron', 'ok');
}

async function showApp(user) {
  $('login-screen').hidden = true;
  $('app').hidden = false;
  // Cargar contexto/rol del usuario
  try { const { data } = await sb.rpc('mi_contexto'); CTX = data || null; }
  catch { CTX = null; }
  // Registrar configs de las tablas de despacho del despachador (por si la lectura general falla)
  for (const t of (CTX?.tablas || [])) { if (t.tabla && !TABLES[t.tabla]) TABLES[t.tabla] = configTablaPuesto(t.label); }
  await registerPuestoTables();
  // ¿El despachador (con tablas propias) además tiene rutas que se despachan en "Despachos"?
  // Se muestra el tab "Despachos" solo si hay filas visibles para sus rutas (evita tabs vacíos).
  CTX && (CTX.verDespachos = false);
  if (CTX?.rol === 'despachador' && (CTX.tablas || []).length && (CTX.ids || []).length) {
    try {
      const { count } = await sb.from('despachos').select('id', { count: 'exact', head: true });
      CTX.verDespachos = (count || 0) > 0;
    } catch { /* si falla, no se muestra */ }
  }
  // Mostrar nombre + rol/puesto del usuario
  $('user-email').textContent = etiquetaUsuario(user);
  updateGpsStatus();
  // Sesión única por dispositivo (solo despachadores): este equipo pasa a ser el activo
  if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
  sessionUser = null;
  if (CTX?.rol === 'despachador') {
    await registrarDispositivo(user);
    sessionUser = user;
    sessTimer = setInterval(() => { verificarDispositivo(); refreshContext(); }, 45000);
  }
  buildSidebar();
  current = null;
  selectTable(visibleTables()[0] || 'despachos');
  updateNet();
  processQueue();
}

$('login-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const btn = $('login-btn'); const err = $('login-error');
  err.hidden = true; btn.disabled = true; btn.textContent = 'Ingresando…';
  const { error } = await sb.auth.signInWithPassword({
    email: $('email').value.trim(), password: $('password').value,
  });
  btn.disabled = false; btn.textContent = 'Iniciar sesión';
  if (error) { err.textContent = 'Correo o contraseña incorrectos.'; err.hidden = false; }
});

$('logout-btn').addEventListener('click', async () => { await sb.auth.signOut(); });

// ---------- navegación ----------
function buildSidebar() {
  const nav = $('sidebar'); nav.innerHTML = '';
  for (const name of visibleTables()) {
    const cfg = TABLES[name];
    const b = document.createElement('button');
    b.innerHTML = `<span>${cfg.icon || '•'}</span> ${cfg.label}`;
    b.classList.toggle('active', name === current);
    b.onclick = () => { selectTable(name); closeMenu(); };
    nav.appendChild(b);
  }
  // acciones especiales (no son tablas)
  addNavAction(nav, '🗺️', 'Mapa', showMapView, 'nav-mapa');
  if (isAdmin()) addNavAction(nav, '📌', 'Asignar puesto', openAsignarPuesto, 'nav-puesto');
  if (isAdmin()) addNavAction(nav, '📡', 'Despachos SONAR', openDsonar, 'nav-dsonar');
  const am = $('nav-mapa'); if (am) am.classList.toggle('active', currentView === 'mapa');
}
function addNavAction(nav, icon, label, fn, id) {
  const b = document.createElement('button');
  b.className = 'nav-action'; if (id) b.id = id;
  b.innerHTML = `<span>${icon}</span> ${label}`;
  b.onclick = () => { fn(); closeMenu(); };
  nav.appendChild(b);
}
function setMenu(open) {
  $('sidebar').classList.toggle('open', open);
  const s = $('scrim'); if (s) s.hidden = !open;
}
function closeMenu() { setMenu(false); }
$('menu-toggle').addEventListener('click', () => setMenu(!$('sidebar').classList.contains('open')));
$('scrim').addEventListener('click', closeMenu);
$('app-ver').textContent = APP_VERSION;

function selectTable(name) {
  // salir de la vista de mapa si estaba activa
  currentView = 'tabla';
  $('map-view').hidden = true;
  $('table-view').hidden = false;
  if (mapTimer) { clearInterval(mapTimer); mapTimer = null; }
  current = name; page = 0; term = ''; filters = {}; $('search').value = '';
  $('table-title').textContent = TABLES[name].label;
  // "Despachar" de la barra: oculto en todas partes. El despacho se hace con el botón
  // verde de cada fila, o con "+ Nuevo" (despacho manual) en Despachos.
  $('dispatch-btn').hidden = true;
  $('count-btn').hidden = !TABLES[name].dispatchable;                  // Contador: en tablas de despacho
  $('dsonar-btn').hidden = true;   // "Despachos SONAR" (consulta puntual): oculto por ahora (sin utilidad práctica)
  $('syncfleet-btn').hidden = name !== 'vehiculosgps' || !isAdmin(); // sincronizar flota: solo admin
  $('import-btn').hidden = !TABLES[name].import || !isAdmin();   // Importar: solo admin
  $('perfil-new-btn').hidden = name !== 'perfiles' || !isAdmin(); // crear acceso: solo admin en Perfiles
  $('perfil-pass-btn').hidden = name !== 'perfiles' || !isAdmin();
  $('new-btn').hidden = !!TABLES[name].readonly || !!TABLES[name].noCreate; // sin "+ Nuevo" donde no aplica
  buildSidebar();
  renderFilters();
  loadData();
}

function renderFilters() {
  const cont = $('filters'); cont.innerHTML = '';
  Object.keys(_checkOptsCache).forEach((k) => delete _checkOptsCache[k]); // refresca opciones por si cambió el puesto
  const defs = TABLES[current].filters || [];
  for (const f of defs) {
    if (f.type === 'daterange') {
      const wrap = document.createElement('span');
      wrap.className = 'filter-date';
      const mk = (op, ph) => {
        const i = document.createElement('input');
        i.type = 'date'; i.title = `${f.label} ${ph}`; i.setAttribute('aria-label', `${f.label} ${ph}`);
        i.value = filters[`${f.col}::${op}`] || '';
        i.addEventListener('change', () => {
          if (i.value) filters[`${f.col}::${op}`] = i.value; else delete filters[`${f.col}::${op}`];
          page = 0; loadData();
        });
        return i;
      };
      wrap.append(Object.assign(document.createElement('span'), { className: 'filter-lbl', textContent: f.label }),
        mk('gte', 'desde'), Object.assign(document.createElement('span'), { textContent: 'a' }), mk('lte', 'hasta'));
      cont.appendChild(wrap);
      continue;
    }
    if (f.type === 'checklist') {
      cont.appendChild(buildChecklistFilter(f));
      continue;
    }
    const sel = document.createElement('select');
    sel.innerHTML = `<option value="">${f.label}: todos</option>` +
      f.options.map((o) => `<option value="${o}">${f.label}: ${o}</option>`).join('');
    sel.value = filters[f.col] || '';
    sel.addEventListener('change', () => {
      if (sel.value) filters[f.col] = sel.value; else delete filters[f.col];
      page = 0; loadData();
    });
    cont.appendChild(sel);
  }
}

// Cache de opciones para filtros checklist (p.ej. rutas), restringido por rol
const _checkOptsCache = {};
async function loadCheckOptions(source) {
  if (_checkOptsCache[source]) return _checkOptsCache[source];
  let qy = sb.from(source).select('id,nombre').order('nombre');
  const r = await qy;
  let opts = (r.data || []).map((x) => [x.id, x.nombre]);
  // Despachador: solo ve sus rutas permitidas (en despachos y tablas por puesto)
  if (source === 'rutas' && !isAdmin() && Array.isArray(CTX?.ids) && CTX.ids.length) {
    const allow = new Set(CTX.ids.map(Number));
    opts = opts.filter(([id]) => allow.has(Number(id)));
  }
  _checkOptsCache[source] = opts;
  return opts;
}

// Filtro de selección múltiple con casillas (dropdown). Guarda filters['col::in'] = [ids]
function buildChecklistFilter(f) {
  const key = `${f.col}::in`;
  const wrap = document.createElement('span');
  wrap.className = 'filter-check';
  const btn = document.createElement('button');
  btn.type = 'button'; btn.className = 'filter-check-btn';
  const panel = document.createElement('div');
  panel.className = 'filter-check-panel'; panel.hidden = true;
  wrap.append(btn, panel);

  const selected = () => (Array.isArray(filters[key]) ? filters[key] : []);
  const refreshBtn = () => {
    const n = selected().length;
    btn.textContent = `${f.label}: ${n ? n + ' ▾' : 'todas ▾'}`;
    btn.classList.toggle('active', n > 0);
  };
  refreshBtn();

  let built = false;
  const buildPanel = async () => {
    const opts = await loadCheckOptions(f.source);
    panel.innerHTML = '';
    const head = document.createElement('div'); head.className = 'fc-head';
    const clr = document.createElement('button'); clr.type = 'button'; clr.className = 'link-btn'; clr.textContent = 'Limpiar';
    clr.addEventListener('click', () => {
      delete filters[key];
      panel.querySelectorAll('input').forEach((c) => { c.checked = false; });
      refreshBtn(); page = 0; loadData();
    });
    head.appendChild(clr); panel.appendChild(head);
    const sel = new Set(selected().map(String));
    opts.forEach(([id, nombre]) => {
      const lbl = document.createElement('label'); lbl.className = 'check-item';
      const cb = document.createElement('input'); cb.type = 'checkbox'; cb.value = String(id);
      cb.checked = sel.has(String(id));
      cb.addEventListener('change', () => {
        const cur = new Set(selected().map(String));
        if (cb.checked) cur.add(cb.value); else cur.delete(cb.value);
        const arr = Array.from(cur).map(Number);
        if (arr.length) filters[key] = arr; else delete filters[key];
        refreshBtn(); page = 0; loadData();
      });
      const span = document.createElement('span'); span.textContent = nombre;
      lbl.append(cb, span); panel.appendChild(lbl);
    });
    built = true;
  };

  btn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const open = panel.hidden;
    document.querySelectorAll('.filter-check-panel').forEach((p) => { p.hidden = true; });
    if (open) { if (!built) await buildPanel(); panel.hidden = false; }
  });
  panel.addEventListener('click', (e) => e.stopPropagation());
  return wrap;
}
// Cierra los paneles de checklist al hacer clic fuera
document.addEventListener('click', () => {
  document.querySelectorAll('.filter-check-panel').forEach((p) => { p.hidden = true; });
});

// Aplica búsqueda + filtros activos + restricción por rol a una consulta (reutilizable)
function applyQueryFilters(qy) {
  const cfg = TABLES[current];
  if (term && cfg.searchCols?.length) {
    qy = qy.or(cfg.searchCols.map((c) => `${c}.ilike.%${term}%`).join(','));
  }
  for (const [key, val] of Object.entries(filters)) { // eq, rango de fecha (::gte/::lte) o lista (::in)
    if (key.endsWith('::gte')) {
      qy = qy.gte(key.slice(0, -5), val);
    } else if (key.endsWith('::lte')) {
      qy = qy.lte(key.slice(0, -5), val);
    } else if (key.endsWith('::in')) {
      const arr = Array.isArray(val) ? val : String(val).split(',');
      if (arr.length) qy = qy.in(key.slice(0, -4), arr);
    } else {
      qy = qy.eq(key, val);
    }
  }
  // Despachador: solo despachos de sus rutas permitidas (refuerzo en UI; RLS lo garantiza en BD)
  if (current === 'despachos' && !isAdmin()) {
    const ids = CTX?.ids || [];
    qy = qy.in('ruta_id', ids.length ? ids : [-1]);
  }
  return qy;
}

// ---------- Contador de despachos por carro (según filtros) ----------
async function openContador() {
  $('cnt-results').innerHTML = '<div class="loading">Calculando…</div>';
  const partes = [];
  if (filters['fecha::gte']) partes.push('desde ' + filters['fecha::gte']);
  if (filters['fecha::lte']) partes.push('hasta ' + filters['fecha::lte']);
  if (filters['tipo']) partes.push('tipo ' + filters['tipo']);
  if (filters['estado_despacho']) partes.push(filters['estado_despacho']);
  if (filters['estado']) partes.push(filters['estado']);
  if (Array.isArray(filters['ruta_id::in']) && filters['ruta_id::in'].length) partes.push(filters['ruta_id::in'].length + ' ruta(s)');
  if (term) partes.push('"' + term + '"');
  $('cnt-sub').textContent = TABLES[current].label + (partes.length ? ' · ' + partes.join(' · ') : ' · sin filtros (todo)');
  $('cnt-modal').hidden = false;

  let qy = sb.from(current).select('estado_despacho, veh:vehiculo_id(numero), desp:despachador_id(nombre)').limit(10000);
  qy = applyQueryFilters(qy);
  const { data, error } = await qy;
  if (error) { $('cnt-results').innerHTML = '<div class="empty">Error: ' + esc(error.message) + '</div>'; return; }

  const map = new Map(); let total = 0;
  for (const r of (data || [])) {
    if (String(r.estado_despacho || '').toUpperCase() !== 'DESPACHADO') continue; // solo realizados
    total++;
    const movil = r.veh?.numero ?? '—';
    if (!map.has(movil)) map.set(movil, { count: 0, desp: new Set() });
    const e = map.get(movil); e.count++; if (r.desp?.nombre) e.desp.add(r.desp.nombre);
  }
  const filas = [...map.entries()].map(([movil, e]) => ({ movil, count: e.count, desp: [...e.desp] }))
    .sort((a, b) => b.count - a.count || String(a.movil).localeCompare(String(b.movil)));

  if (!filas.length) { $('cnt-results').innerHTML = '<div class="empty">No hay despachos realizados con esos filtros.</div>'; return; }

  const head = `<div class="cnt-total">Total despachados: <b>${total}</b> · Carros distintos: <b>${filas.length}</b></div>`;
  const body = '<table class="ds-table"><thead><tr><th>Móvil</th><th>Despachos</th><th>Despachadores</th></tr></thead><tbody>'
    + filas.map((f) => `<tr><td><b>${esc(f.movil)}</b></td><td>${f.count}</td><td>${esc(f.desp.join(', ') || '—')}</td></tr>`).join('')
    + '</tbody></table>';
  $('cnt-results').innerHTML = head + body;
}
function closeContador() { $('cnt-modal').hidden = true; }
$('count-btn').addEventListener('click', openContador);
$('cnt-close').addEventListener('click', closeContador);
$('cnt-cancel').addEventListener('click', closeContador);

// ---------- Asignar puesto (admin): varios despachadores y rango de fechas ----------
async function openAsignarPuesto() {
  $('pst-error').hidden = true;
  const r = $('pst-result'); r.hidden = true; r.textContent = '';
  $('pst-info').hidden = true;
  const hoy = hoyLocal();
  $('pst-desde').value = hoy; $('pst-hasta').value = hoy;
  const [dp, pp] = await Promise.all([
    sb.from('perfiles').select('email,nombre').eq('rol', 'despachador').eq('activo', true).order('nombre'),
    sb.from('puestos').select('nombre').eq('activo', true).order('nombre'),
  ]);
  const list = $('pst-desp-list'); list.innerHTML = '';
  (dp.data || []).forEach((d) => {
    const lbl = document.createElement('label'); lbl.className = 'check-item';
    const cb = document.createElement('input'); cb.type = 'checkbox'; cb.value = d.email; cb.className = 'pst-cb';
    cb.addEventListener('change', updatePstInfo);
    const span = document.createElement('span'); span.textContent = `${d.nombre || d.email} · ${d.email}`;
    lbl.append(cb, span); list.appendChild(lbl);
  });
  fillSelect($('pst-puesto'), (pp.data || []).map((p) => [p.nombre, p.nombre]), 'Selecciona puesto');
  enhanceById('pst-puesto');
  await updatePstInfo();
  $('pst-modal').hidden = false;
}
function pstSeleccionados() {
  return Array.from(document.querySelectorAll('#pst-desp-list .pst-cb:checked')).map((c) => c.value);
}
function pstDiasRango() {
  const d = $('pst-desde').value, h = $('pst-hasta').value;
  if (!d || !h || h < d) return 0;
  return Math.round((new Date(h) - new Date(d)) / 86400000) + 1;
}
async function updatePstInfo() {
  const emails = pstSeleccionados();
  const dias = pstDiasRango();
  const info = $('pst-info');
  if (!emails.length || !dias) { info.hidden = true; return; }
  info.hidden = false; info.className = 'field full sonar-info';
  info.textContent = `Se aplicará a ${emails.length} despachador(es) × ${dias} día(s) = ${emails.length * dias} asignación(es).`;
}
function closeAsignarPuesto() { $('pst-modal').hidden = true; }
$('pst-close').addEventListener('click', closeAsignarPuesto);
$('pst-cancel').addEventListener('click', closeAsignarPuesto);
$('pst-desde').addEventListener('change', updatePstInfo);
$('pst-hasta').addEventListener('change', updatePstInfo);
$('pst-all').addEventListener('click', () => {
  const cbs = Array.from(document.querySelectorAll('#pst-desp-list .pst-cb'));
  const allOn = cbs.every((c) => c.checked);
  cbs.forEach((c) => { c.checked = !allOn; });
  $('pst-all').textContent = allOn ? 'Seleccionar todos' : 'Quitar selección';
  updatePstInfo();
});
$('pst-save').addEventListener('click', async () => {
  const btn = $('pst-save'); if (btn.dataset.busy === '1') return;
  const err = $('pst-error'); err.hidden = true;
  const emails = pstSeleccionados();
  const desde = $('pst-desde').value, hasta = $('pst-hasta').value, puesto = $('pst-puesto').value;
  if (!emails.length || !desde || !hasta || !puesto) {
    err.textContent = 'Selecciona al menos un despachador, el rango de fechas y el puesto.'; err.hidden = false; return;
  }
  if (hasta < desde) { err.textContent = 'La fecha "Hasta" no puede ser anterior a "Desde".'; err.hidden = false; return; }
  const dias = pstDiasRango();
  const rango = desde === hasta ? `el ${desde}` : `del ${desde} al ${hasta} (${dias} días)`;
  const ok = await confirmAction({
    title: '¿Asignar puesto?',
    lead: `Se asignará el puesto ${rango}:`,
    message: `Despachadores: ${emails.length}\nPuesto:        ${puesto}\nTotal:         ${emails.length * dias} asignación(es)`,
    okLabel: 'Asignar',
  });
  if (!ok) return;
  btn.dataset.busy = '1'; btn.disabled = true;
  let res;
  try { res = await sb.rpc('admin_asignar_puesto_rango', { p_emails: emails, p_desde: desde, p_hasta: hasta, p_puesto: puesto }); }
  finally { btn.dataset.busy = '0'; btn.disabled = false; }
  if (res.error) { err.textContent = res.error.message; err.hidden = false; return; }
  const r = $('pst-result'); r.hidden = false; r.className = 'sonar-result ok';
  r.textContent = `✅ ${res.data} asignación(es) guardada(s). Los despachadores lo verán en menos de 1 minuto (o al volver a la app).`;
  toast('Puesto asignado', 'ok');
  if (current === 'horarios') loadData();
});

// ---------- carga de datos ----------
let searchTimer;
$('search').addEventListener('input', (e) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { term = e.target.value.trim(); page = 0; loadData(); }, 300);
});
$('refresh-btn').addEventListener('click', loadData);
$('prev-btn').addEventListener('click', () => { if (page > 0) { page--; loadData(); } });
$('next-btn').addEventListener('click', () => { page++; loadData(); });

async function loadData() {
  const cfg = TABLES[current];
  $('loading').hidden = false; $('empty').hidden = true;
  const from = page * PAGE_SIZE, to = from + PAGE_SIZE - 1;

  let qy = sb.from(current).select(cfg.select, { count: 'exact' })
    .order(cfg.defaultOrder.col, { ascending: cfg.defaultOrder.asc, nullsFirst: false })
    .range(from, to);

  qy = applyQueryFilters(qy);

  const { data, error, count } = await qy;
  $('loading').hidden = true;
  if (error) { toast('Error al cargar: ' + error.message, 'err'); return; }
  renderTable(cfg, data || [], count || 0);
}

// Íconos SVG (se ven iguales en Android/escritorio, sin depender de emojis)
const ICON = {
  send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22 11 13 2 9z"/></svg>',
  ban: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6 18.4 18.4"/></svg>',
  edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M6 6l1 14h10l1-14"/></svg>',
};

function renderTable(cfg, rows, count) {
  const head = $('thead-row'); head.innerHTML = '';
  // En móvil solo se muestran las columnas marcadas con m:true (si la tabla define alguna)
  const hasMobile = cfg.columns.some((c) => c.m);
  cfg.columns.forEach((c) => {
    const th = document.createElement('th');
    th.textContent = c.label;
    if (hasMobile && !c.m) th.className = 'col-hide';
    head.appendChild(th);
  });
  if (!cfg.readonly) head.appendChild(Object.assign(document.createElement('th'), { textContent: 'Acciones', className: 'col-act' }));

  const body = $('tbody'); body.innerHTML = '';
  $('empty').hidden = rows.length > 0;

  for (const row of rows) {
    const tr = document.createElement('tr');
    for (const c of cfg.columns) {
      const td = document.createElement('td');
      td.dataset.label = c.label;
      if (hasMobile && !c.m) td.className = 'col-hide';
      const val = c.path ? getPath(row, c.path) : row[c.key];
      if (c.maps && val && /-?\d+\.\d+/.test(String(val))) {
        td.innerHTML = `<a href="https://www.google.com/maps?q=${encodeURIComponent(String(val))}" target="_blank" rel="noopener" class="maps-link" title="${esc(String(val))}">📍 Ver</a>`;
      } else if (c.badge && val != null && String(val).trim() !== '') {
        td.innerHTML = `<span class="${chipClass(val)}">${esc(fmt(val))}</span>`;
      } else {
        td.textContent = fmt(val);
      }
      tr.appendChild(td);
    }
    if (!cfg.readonly) {
      const act = document.createElement('td');
      act.className = 'row-actions';
      act.dataset.label = 'Acciones';
      const locked = cfg.rowLocked && cfg.rowLocked(row);
      // La fecha es clave: no se puede despachar ni editar un viaje de un día anterior a hoy
      const esPasada = !!(cfg.dispatchable && row.fecha && String(row.fecha).slice(0, 10) < hoyLocal());
      if (locked) {
        act.appendChild(Object.assign(document.createElement('span'), {
          className: 'lock-badge', textContent: '🔒', title: cfg.lockedHint || 'Bloqueado',
        }));
      } else {
        if (cfg.dispatchable) {
          const dsp = Object.assign(document.createElement('button'), { className: 'act act-go', innerHTML: ICON.send });
          if (row.sonar_regid) {
            dsp.title = 'Ya despachado (regId ' + row.sonar_regid + ')';
            dsp.disabled = true;
          } else if (esPasada) {
            dsp.title = 'Fecha ya pasada: no se puede despachar';
            dsp.disabled = true;
          } else {
            dsp.title = 'Despachar en SONAR';
            dsp.onclick = () => openSonar(row);
          }
          act.appendChild(dsp);
          const can = Object.assign(document.createElement('button'), { className: 'act act-stop', innerHTML: ICON.ban });
          if (!row.sonar_regid) {
            can.title = 'Sin regId: no se puede cancelar';
            can.disabled = true;
          } else if (esPasada) {
            can.title = 'Fecha ya pasada: no se puede cancelar';
            can.disabled = true;
          } else {
            can.title = 'Cancelar en SONAR';
            can.onclick = () => openCancelar(row);
          }
          act.appendChild(can);
        }
        // Editar/eliminar: solo admin. El despachador solo despacha/cancela.
        if (isAdmin()) {
          const ed = Object.assign(document.createElement('button'), { className: 'act act-edit', innerHTML: ICON.edit });
          if (esPasada) {
            ed.title = 'Fecha ya pasada: no se puede editar';
            ed.disabled = true;
          } else {
            ed.title = 'Editar';
            ed.onclick = () => openEditor(row);
          }
          act.appendChild(ed);
          if (!cfg.noDelete) {
            const del = Object.assign(document.createElement('button'), { className: 'act act-del', innerHTML: ICON.trash, title: 'Eliminar' });
            del.onclick = () => deleteRow(row);
            act.appendChild(del);
          }
        }
      }
      tr.appendChild(act);
    }
    body.appendChild(tr);
  }

  const total = count;
  const start = total === 0 ? 0 : page * PAGE_SIZE + 1;
  const end = Math.min((page + 1) * PAGE_SIZE, total);
  $('page-info').textContent = `${start}–${end} de ${total}`;
  $('prev-btn').disabled = page === 0;
  $('next-btn').disabled = end >= total;
}

// ---------- editor ----------
async function loadFkOptions(fk) {
  if (fkCache[fk.table]) return fkCache[fk.table];
  const { data, error } = await sb.from(fk.table).select(fk.sel).order(fk.order, { ascending: true }).limit(2000);
  if (error) { toast('Error opciones ' + fk.table, 'err'); return []; }
  let opts = (data || []).map((r) => ({
    value: r.id,
    label: typeof fk.label === 'function' ? fk.label(r) : r[fk.label],
  }));
  // Filtro de seguridad: el despachador solo ve sus rutas permitidas
  if (!isAdmin() && fk.table === 'rutas') {
    const ids = new Set((CTX?.ids || []).map(String));
    const allow = allowedRutaSet();
    if (ids.size || allow.size) {
      opts = opts.filter((o) => ids.has(String(o.value)) || allow.has(normRuta(o.label)));
    }
  }
  fkCache[fk.table] = opts;
  return opts;
}

// Opciones de TEXTO para listas desplegables (ej. nombres de perfiles, puestos)
const _textOptsCache = {};
async function loadTextOptions(src) {
  if (!src || !src.table || !src.col) return [];
  const ck = JSON.stringify(src);
  if (_textOptsCache[ck]) return _textOptsCache[ck].slice();
  let qy = sb.from(src.table).select(src.col);
  if (src.where) qy = qy.eq(src.where[0], src.where[1]);
  const { data } = await qy.order(src.col, { ascending: true }).limit(3000);
  const vals = [...new Set((data || []).map((r) => r[src.col]).filter((x) => x != null && String(x).trim() !== '').map(String))];
  _textOptsCache[ck] = vals;
  return vals.slice();
}

// Carros (ids de vehículo) que operan una ruta, mirando despachos + tablas de puesto.
// RLS ya limita las filas a lo que el usuario puede ver.
const _carrosRutaCache = {};
async function carrosDeRuta(rutaId) {
  if (!rutaId) return null;
  if (_carrosRutaCache[rutaId]) return _carrosRutaCache[rutaId];
  const tablas = ['despachos', ...puestoTables];
  const set = new Set();
  await Promise.all(tablas.map(async (t) => {
    const { data } = await sb.from(t)
      .select('vehiculo_id, vehiculo_programado_id')
      .or(`ruta_id.eq.${rutaId},ruta_programada_id.eq.${rutaId}`)
      .limit(3000);
    (data || []).forEach((r) => {
      if (r.vehiculo_id != null) set.add(String(r.vehiculo_id));
      if (r.vehiculo_programado_id != null) set.add(String(r.vehiculo_programado_id));
    });
  }));
  _carrosRutaCache[rutaId] = set;
  return set;
}

// Conductor registrado para un vehículo: primero busca en RESUMEN (lo que el
// despachador registró), y si no hay, en despachos/tablas. (opcional: filtra por fecha)
async function conductorDeVehiculo(vehId, fecha) {
  if (!vehId) return null;
  // 1) Prioridad: el conductor que quedó en RESUMEN para ese móvil (lo más reciente)
  try {
    let rq = sb.from('resumen').select('conductor_id, fecha').eq('vehiculo_id', vehId).not('conductor_id', 'is', null);
    if (fecha) rq = rq.eq('fecha', fecha);
    let { data } = await rq.order('fecha', { ascending: false }).limit(1);
    if ((!data || !data.length) && fecha) { // si no hay para esa fecha, toma el más reciente
      ({ data } = await sb.from('resumen').select('conductor_id, fecha').eq('vehiculo_id', vehId)
        .not('conductor_id', 'is', null).order('fecha', { ascending: false }).limit(1));
    }
    if (data && data[0]?.conductor_id != null) return data[0].conductor_id;
  } catch (e) { /* sigue con despachos */ }
  // 2) Respaldo: el conductor en despachos / tablas de puesto
  const tablas = ['despachos', ...puestoTables];
  let best = null; // { fecha, hora, cond }
  await Promise.all(tablas.map(async (t) => {
    let qy = sb.from(t).select('conductor_id, fecha, hora').eq('vehiculo_id', vehId).not('conductor_id', 'is', null);
    if (fecha) qy = qy.eq('fecha', fecha);
    const { data } = await qy.order('fecha', { ascending: false }).order('hora', { ascending: false }).limit(1);
    const r = (data || [])[0];
    if (r && (!best || String(r.fecha) > String(best.fecha) || (r.fecha === best.fecha && String(r.hora) > String(best.hora)))) {
      best = { fecha: r.fecha, hora: r.hora, cond: r.conductor_id };
    }
  }));
  return best?.cond ?? null;
}

// Al elegir ruta, deja en el select de Móvil solo los carros que operan esa ruta.
// Al elegir Móvil, trae automáticamente el conductor registrado en despachos.
async function setupVehByRoute(form, conf) {
  const routeSel = form.querySelector(`[data-key="${conf.route}"]`);
  const vehSel = form.querySelector(`[data-key="${conf.veh}"]`);
  if (!routeSel || !vehSel) return;
  const allOpts = [...vehSel.options].map((o) => ({ value: o.value, text: o.textContent }));
  async function apply() {
    const rid = routeSel.value;
    const keep = vehSel.value;
    // El admin puede registrar cualquier móvil (no se filtra). Al despachador sí se le
    // filtra a los carros de la ruta (ayuda y seguridad).
    const set = (rid && !isAdmin()) ? await carrosDeRuta(rid) : null;
    vehSel.innerHTML = '';
    for (const o of allOpts) {
      if (set && set.size && o.value && !set.has(String(o.value))) continue; // solo los carros de la ruta
      vehSel.appendChild(Object.assign(document.createElement('option'), { value: o.value, textContent: o.text }));
    }
    if ([...vehSel.options].some((o) => o.value === keep)) vehSel.value = keep;
    vehSel._comboSync && vehSel._comboSync();
  }
  routeSel.addEventListener('change', apply);
  await apply();

  // Traer el conductor registrado para el móvil elegido
  if (conf.cond) {
    const condSel = form.querySelector(`[data-key="${conf.cond}"]`);
    const fechaEl = conf.fecha ? form.querySelector(`[data-key="${conf.fecha}"]`) : null;
    if (condSel) {
      vehSel.addEventListener('change', async () => {
        if (!vehSel.value) return;
        // El conductor es de SONAR (valor = nombre): se trae por nombre
        const nombre = await nombreConductorDeVehiculo(vehSel.value, fechaEl ? fechaEl.value : null);
        if (!nombre) return;
        const op = [...condSel.options].find((o) => (o.value || '').toLowerCase() === nombre.toLowerCase());
        if (op) {
          condSel.value = op.value;
          condSel._comboSync && condSel._comboSync();
          toast('Conductor traído automáticamente', 'ok');
        }
      });
    }
  }
}

// Convierte un <select> en un buscador (combobox con filtro). El <select> queda
// oculto pero conserva el valor (lo lee el guardado). Funciona en móvil y escritorio.
function enhanceSelect(sel) {
  if (sel._enhanced || sel.disabled) return;
  sel._enhanced = true;
  const combo = document.createElement('div');
  combo.className = 'combo';
  sel.parentNode.insertBefore(combo, sel);
  combo.appendChild(sel);
  sel.classList.add('combo-native');

  const input = document.createElement('input');
  input.type = 'text'; input.className = 'combo-input'; input.autocomplete = 'off';
  // El texto de la opción vacía (ej. "Selecciona móvil") se usa como placeholder gris,
  // no como valor escrito (antes se veía como texto seleccionado en azul, feo).
  const emptyOpt = [...sel.options].find((x) => x.value === '');
  input.placeholder = emptyOpt ? emptyOpt.textContent : '🔍 Buscar…';
  const list = document.createElement('div');
  list.className = 'combo-list'; list.hidden = true;
  combo.append(input, list);

  const labelFor = (val) => { const o = [...sel.options].find((x) => x.value === val); return o ? o.textContent : ''; };
  const sync = () => { input.value = sel.value ? labelFor(sel.value) : ''; }; // vacío → placeholder
  sel._comboSync = sync;
  sync();

  function render(filter = '') {
    const f = filter.trim().toLowerCase();
    list.innerHTML = '';
    const opts = [...sel.options].filter((o) => o.value !== '' && (o.textContent || '').toLowerCase().includes(f));
    for (const o of opts.slice(0, 80)) {
      const item = document.createElement('div');
      item.className = 'combo-item' + (o.value === sel.value ? ' sel' : '');
      item.textContent = o.textContent || '—';
      item.addEventListener('mousedown', (e) => { // mousedown gana al blur
        e.preventDefault();
        sel.value = o.value;
        input.value = o.textContent;
        list.hidden = true;
        sel.dispatchEvent(new Event('change', { bubbles: true }));
      });
      list.appendChild(item);
    }
    list.hidden = opts.length === 0;
  }
  input.addEventListener('focus', () => { input.select(); render(''); });
  input.addEventListener('input', () => render(input.value));
  input.addEventListener('blur', () => setTimeout(() => { list.hidden = true; sync(); }, 160));
}
function enhanceById(...ids) {
  for (const id of ids) { const el = $(id); if (el) { enhanceSelect(el); el._comboSync && el._comboSync(); } }
}

function toggleEmptySections(form) {
  const kids = [...form.children];
  for (let i = 0; i < kids.length; i++) {
    const el = kids[i];
    if (!el.classList.contains('section-title')) continue;
    let anyVisible = false;
    for (let j = i + 1; j < kids.length; j++) {
      if (kids[j].classList.contains('section-title')) break;
      if (kids[j].classList.contains('field') && !kids[j].classList.contains('hidden-field')) { anyVisible = true; break; }
    }
    el.classList.toggle('hidden-field', !anyVisible);
  }
}

async function openEditor(row) {
  const cfg = TABLES[current];
  if (row && cfg.rowLocked && cfg.rowLocked(row)) { toast(cfg.lockedHint || 'Registro bloqueado', 'err'); return; }
  // La fecha es clave: no se edita un viaje de un día anterior a hoy (tablas y despachos)
  if (row && cfg.dispatchable && row.fecha && String(row.fecha).slice(0, 10) < hoyLocal()) {
    toast('No se puede editar: la fecha del viaje ya pasó.', 'err'); return;
  }
  editing = row || null;
  $('modal-title').textContent = (row ? 'Editar' : 'Nuevo') + ' · ' + cfg.label;
  $('modal-error').hidden = true;
  const form = $('edit-form'); form.innerHTML = '';

  let lastSection = null;
  const controls = []; // campos con visibilidad condicional

  // Un despacho ya realizado (TABLA o LIBRE) no se modifica: solo se permiten
  // observaciones y los demás ítems de seguimiento (postDispatch).
  const isDispatched = !!(cfg.dispatchable && row &&
    (String(row.estado_despacho || '').toUpperCase() === 'DESPACHADO' || row.sonar_regid));
  if (isDispatched) {
    const note = document.createElement('div');
    note.className = 'sonar-info';
    note.textContent = '🔒 Despacho ya realizado: solo puedes editar observaciones y los ítems de seguimiento.';
    form.appendChild(note);
  }

  for (const f of cfg.fields) {
    // formHide: el campo nunca se muestra en el formulario (ej. KEY, regId, despachador, ubicación en tablas)
    if (f.formHide) continue;
    // editOnly: solo se muestra al EDITAR un registro existente (no al crear)
    if (f.editOnly && !editing) continue;
    // encabezado de sección
    if (f.section && f.section !== lastSection) {
      lastSection = f.section;
      const h = document.createElement('div');
      h.className = 'section-title'; h.textContent = f.section;
      form.appendChild(h);
    }

    const wrap = document.createElement('label');
    wrap.className = 'field' + (f.type === 'textarea' ? ' full' : '');
    wrap.dataset.fieldKey = f.key;
    // Valor inicial: del registro; al crear, opcionalmente del contexto (ej. puesto del usuario)
    let val = row ? row[f.key] : (f.default ?? null);
    if (!row && f.ctxValue && CTX && CTX[f.ctxValue]) val = CTX[f.ctxValue];

    if (f.type === 'boolean') {
      wrap.className = 'field check';
      wrap.dataset.fieldKey = f.key;
      const cb = document.createElement('input');
      cb.type = 'checkbox'; cb.dataset.key = f.key; cb.dataset.type = 'boolean'; cb.checked = val === true;
      if (f.readOnly || (isDispatched && !f.postDispatch)) cb.disabled = true;
      wrap.append(cb, document.createTextNode(' ' + f.label));
    } else {
      wrap.appendChild(Object.assign(document.createElement('span'), { textContent: f.label + (f.required ? ' *' : '') }));
      let input;
      if (f.type === 'fk') {
        input = document.createElement('select');
        input.innerHTML = '<option value="">— ninguno —</option>';
        const opts = await loadFkOptions(f.fk);
        for (const o of opts) {
          const op = document.createElement('option');
          op.value = o.value; op.textContent = o.label;
          if (val != null && String(val) === String(o.value)) op.selected = true;
          input.appendChild(op);
        }
      } else if (f.type === 'sonardrv') {
        // Conductor desde SONAR (conductores_sonar). El valor es el NOMBRE; al guardar
        // se mapea a la tabla conductores. Se preselecciona por el nombre del registro.
        input = document.createElement('select');
        input.innerHTML = '<option value="">— ninguno —</option>';
        const drs = await loadDrivers();
        const curName = f.nameFrom ? getPath(row || {}, f.nameFrom) : null;
        for (const d of drs) {
          const nm = d.nombre || '';
          const op = document.createElement('option');
          op.value = nm; op.textContent = nm + (d.codigo ? ' · ' + d.codigo : '');
          if (curName && nm.toLowerCase() === String(curName).toLowerCase()) op.selected = true;
          input.appendChild(op);
        }
      } else if (f.type === 'textsel') {
        // Lista desplegable de valores de TEXTO tomados de una tabla (ej. nombres, puestos)
        input = document.createElement('select');
        input.innerHTML = '<option value="">— ninguno —</option>';
        const opts = await loadTextOptions(f.optionsFrom);
        if (val != null && String(val) !== '' && !opts.includes(String(val))) opts.unshift(String(val)); // conserva el valor actual
        for (const o of opts) {
          const op = document.createElement('option');
          op.value = o; op.textContent = o;
          if (val != null && String(val) === String(o)) op.selected = true;
          input.appendChild(op);
        }
      } else if (f.type === 'enum') {
        input = document.createElement('select');
        if (!f.required) input.innerHTML = '<option value="">— ninguno —</option>';
        for (const o of f.options) {
          const op = document.createElement('option');
          op.value = o; op.textContent = o;
          if ((val ?? '') === o) op.selected = true;
          input.appendChild(op);
        }
      } else if (f.type === 'textarea') {
        input = document.createElement('textarea');
        input.value = val ?? '';
      } else {
        input = document.createElement('input');
        input.type = f.type === 'number' ? 'number' : f.type === 'date' ? 'date'
          : f.type === 'time' ? 'time' : f.type === 'datetime' ? 'datetime-local' : 'text';
        // datetime-local necesita "YYYY-MM-DDTHH:MM" (recorta segundos/zona)
        input.value = f.type === 'datetime' && val ? String(val).replace(' ', 'T').slice(0, 16) : (val ?? '');
        if (f.type === 'number' && f.min != null) { input.min = f.min; input.step = f.step ?? 1; }
      }
      input.dataset.key = f.key; input.dataset.type = f.type;
      if (f.key === cfg.pk && row && !cfg.pkEditable) input.disabled = true;
      if (f.key === cfg.pk && row && cfg.pkEditable) input.readOnly = true; // no cambiar PK al editar
      if (f.readOnly || (isDispatched && !f.postDispatch)) input.disabled = true; // solo lectura / ya despachado
      // Solo lectura "suave" para el despachador: no lo puede cambiar pero SÍ se guarda (ej. puesto)
      if (f.softReadOnlyDispatcher && !isAdmin()) input.readOnly = true;
      wrap.appendChild(input);
      if (f.hint) wrap.appendChild(Object.assign(document.createElement('span'), { className: 'field-hint', textContent: f.hint }));
    }
    form.appendChild(wrap);
    if (f.showWhen) controls.push(f);
  }

  // visibilidad condicional (ej. campos "Programado" solo cuando tipo = TABLA)
  function applyVisibility() {
    for (const f of controls) {
      const wrap = form.querySelector(`[data-field-key="${f.key}"]`);
      const ctrlEl = form.querySelector(`[data-key="${f.showWhen.field}"]`);
      // Para casillas (boolean) se compara con el estado marcado; para selects con su valor
      const cur = ctrlEl ? (ctrlEl.type === 'checkbox' ? ctrlEl.checked : ctrlEl.value) : '';
      wrap.classList.toggle('hidden-field', !f.showWhen.in.includes(cur));
    }
    toggleEmptySections(form);
  }
  for (const k of [...new Set(controls.map((f) => f.showWhen.field))]) {
    const el = form.querySelector(`[data-key="${k}"]`);
    if (el) el.addEventListener('change', applyVisibility);
  }
  applyVisibility();

  if (cfg.vehByRoute) await setupVehByRoute(form, cfg.vehByRoute);

  // Buscadores en las listas largas (conductor, vehículo, ruta, etc.)
  form.querySelectorAll('select[data-type="fk"]:not(:disabled), select[data-type="sonardrv"]:not(:disabled), select[data-type="textsel"]:not(:disabled)').forEach(enhanceSelect);

  $('modal').hidden = false;
}

function closeModal() { $('modal').hidden = true; editing = null; }
$('modal-close').addEventListener('click', closeModal);
$('modal-cancel').addEventListener('click', closeModal);
$('new-btn').addEventListener('click', () => {
  if (current === 'despachos') openNuevoDespacho(); else openEditor(null);
});

$('modal-save').addEventListener('click', async () => {
  if ($('modal-save').dataset.busy === '1') return; // evita doble click
  const cfg = TABLES[current];
  const err = $('modal-error'); err.hidden = true;
  const payload = {};

  const sonarDrvKeys = []; // conductores elegidos de SONAR (valor = nombre) a mapear → id
  for (const el of $('edit-form').querySelectorAll('[data-key]')) {
    if (el.disabled) continue; // campo bloqueado (ej. ya despachado) → no se modifica
    const key = el.dataset.key, type = el.dataset.type;
    const wrap = el.closest('.field');
    if (wrap && wrap.classList.contains('hidden-field')) { payload[key] = null; continue; } // campo oculto -> vacío
    if (type === 'boolean') { payload[key] = el.checked; continue; }
    let v = el.value;
    if (typeof v === 'string') v = v.trim();
    if (v === '') { payload[key] = null; continue; }
    if (type === 'sonardrv') { payload[key] = v; sonarDrvKeys.push(key); continue; } // v = nombre del conductor SONAR
    if (type === 'fk' || type === 'number') payload[key] = Number(v);
    else payload[key] = v;
  }

  // El conductor viene de SONAR (por nombre): se registra/ubica en la tabla conductores y se guarda su id
  for (const key of sonarDrvKeys) {
    const { data, error: e } = await sb.from('conductores').upsert({ nombre: payload[key] }, { onConflict: 'nombre' }).select('id').single();
    if (e) { err.textContent = 'No se pudo registrar el conductor: ' + e.message; err.hidden = false; return; }
    payload[key] = data.id;
  }

  // Validar requeridos y mínimos (omitiendo los campos bloqueados/ocultos)
  for (const f of cfg.fields) {
    const el = $('edit-form').querySelector(`[data-key="${f.key}"]`);
    if (el && el.disabled) continue; // bloqueado → no se valida
    if (f.required && (payload[f.key] === null || payload[f.key] === undefined || payload[f.key] === '')) {
      err.textContent = `El campo "${f.label}" es obligatorio.`; err.hidden = false; return;
    }
    if (f.type === 'number' && f.min != null && payload[f.key] != null && payload[f.key] < f.min) {
      err.textContent = `"${f.label}" debe ser ${f.min === 0 ? 'un número positivo' : 'mayor o igual a ' + f.min}.`; err.hidden = false; return;
    }
  }

  // Hora de cierre automática (momento de guardado)
  if (cfg.autoStamp) payload[cfg.autoStamp] = ahoraLocal();

  // Estado: 'Abierto' al crear; al editar, si están todos los campos requeridos → 'Cerrado' (bloqueado)
  let cerrado = false;
  if (cfg.stateField) {
    if (!editing) {
      payload[cfg.stateField] = 'Abierto';
    } else {
      const req = [...(cfg.closeRequired || [])];
      if (cfg.closeRequiredDoble && payload.doble_turno) req.push(...cfg.closeRequiredDoble);
      const completo = req.every((k) => payload[k] !== null && payload[k] !== undefined && payload[k] !== '');
      if (completo) { payload[cfg.stateField] = 'Cerrado'; cerrado = true; }
    }
  }

  // Confirmación antes de guardar una modificación importante
  if (cfg.confirmSave) {
    const ok = await confirmAction({
      title: editing ? '¿Guardar cambios?' : '¿Crear registro?',
      lead: `${editing ? 'Se guardarán los cambios' : 'Se creará el registro'} en ${cfg.label}.`,
      message: cerrado ? '⚠️ Quedará CERRADO y ya no se podrá modificar.' : '',
      okLabel: 'Guardar',
      danger: !!cerrado,
    });
    if (!ok) return;
  }

  const saveBtn = $('modal-save');
  saveBtn.dataset.busy = '1'; saveBtn.disabled = true;
  let res;
  try {
    if (editing) {
      const id = editing[cfg.pk];
      delete payload[cfg.pk]; // nunca actualizamos la PK
      res = await sb.from(current).update(payload).eq(cfg.pk, id);
    } else {
      if (cfg.genKey) payload[cfg.pk] = cfg.genKey(payload); // KEY generada automáticamente
      else if (!cfg.pkEditable) delete payload[cfg.pk]; // PK autogenerada por la BD
      res = await sb.from(current).insert(payload);
    }
  } finally {
    saveBtn.dataset.busy = '0'; saveBtn.disabled = false;
  }

  if (res.error) { err.textContent = res.error.message; err.hidden = false; return; }
  closeModal();
  toast(cerrado ? 'Registro completo: cerrado y bloqueado' : (editing ? 'Registro actualizado' : 'Registro creado'), 'ok');
  loadData();
});

async function deleteRow(row) {
  const cfg = TABLES[current];
  if (cfg.noDelete) { toast('Esta tabla no permite eliminar registros', 'err'); return; }
  if (cfg.rowLocked && cfg.rowLocked(row)) { toast(cfg.lockedHint || 'Registro bloqueado', 'err'); return; }
  const ok = await confirmAction({
    title: '¿Eliminar registro?',
    lead: `Se eliminará este registro de ${cfg.label}.`,
    message: 'Esta acción no se puede deshacer.',
    okLabel: 'Eliminar', danger: true,
  });
  if (!ok) return;
  const { error } = await sb.from(current).delete().eq(cfg.pk, row[cfg.pk]);
  if (error) { toast('No se pudo eliminar: ' + error.message, 'err'); return; }
  toast('Registro eliminado', 'ok');
  loadData();
}

// ---------- Importar despachos por tabla (CSV/Excel) ----------
function normH(h) {
  return String(h || '').toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '') // quitar acentos
    .replace(/\s+/g, ' ').replace(/\?/g, '').trim();
}
async function parseImportFile(file, map, keyField = 'key') {
  const XLSX = await import('https://esm.sh/xlsx@0.18.5');
  const buf = await file.arrayBuffer();
  const wb = XLSX.read(new Uint8Array(buf), { type: 'array' });
  const ws = wb.Sheets[wb.SheetNames[0]];
  const aoa = XLSX.utils.sheet_to_json(ws, { header: 1, raw: false, defval: '' });
  if (!aoa.length) return [];
  const headers = aoa[0].map(normH);
  const rows = [];
  for (let i = 1; i < aoa.length; i++) {
    const r = aoa[i];
    if (!r || r.every((c) => String(c).trim() === '')) continue;
    const o = {};
    headers.forEach((h, idx) => { const k = map[h]; if (k) o[k] = r[idx] != null ? String(r[idx]) : ''; });
    if (o[keyField] && String(o[keyField]).trim() !== '') rows.push(o);
  }
  return rows;
}

function openImport() {
  $('imp-error').hidden = true;
  const res = $('imp-result'); res.hidden = true; res.textContent = '';
  $('imp-file').value = '';
  $('imp-modal').hidden = false;
}
function closeImport() { $('imp-modal').hidden = true; }
$('import-btn').addEventListener('click', openImport);
$('imp-close').addEventListener('click', closeImport);
$('imp-cancel').addEventListener('click', closeImport);

$('imp-run').addEventListener('click', async () => {
  const err = $('imp-error'); err.hidden = true;
  const res = $('imp-result');
  const f = $('imp-file').files[0];
  if (!f) { err.textContent = 'Selecciona un archivo CSV o Excel.'; err.hidden = false; return; }

  const impCfg = TABLES[current].import;
  if (!impCfg) { err.textContent = 'Esta tabla no admite importación.'; err.hidden = false; return; }

  const btn = $('imp-run'); btn.disabled = true; btn.textContent = 'Importando…';
  res.hidden = false; res.className = 'sonar-result'; res.textContent = 'Leyendo archivo…';
  try {
    const rows = await parseImportFile(f, impCfg.map, impCfg.keyField || 'key');
    if (!rows.length) throw new Error('No se encontraron filas válidas en el archivo. Revisa los encabezados de las columnas.');
    let insertados = 0, kept = 0;
    const B = 200;
    for (let i = 0; i < rows.length; i += B) {
      const batch = rows.slice(i, i + B);
      const { data, error } = await sb.rpc(impCfg.rpc, { p_rows: batch });
      if (error) throw error;
      insertados += data.insertados || 0; kept += data[impCfg.kept] || 0;
      res.textContent = `Procesando… ${Math.min(i + B, rows.length)} / ${rows.length}`;
    }
    res.className = 'sonar-result ok';
    res.textContent = `✅ Importación terminada\n\nFilas leídas: ${rows.length}\nNuevos insertados: ${insertados}\n${impCfg.keptLabel}: ${kept}`;
    toast('Importación completada', 'ok');
    loadData();
  } catch (e) {
    res.hidden = true; err.textContent = 'Error: ' + (e.message || e); err.hidden = false;
  } finally {
    btn.disabled = false; btn.textContent = 'Importar';
  }
});

// ---------- Nuevo despacho (simplificado + SONAR) ----------
let vehList = null, despList = null;
async function loadVehiculos() {
  if (!vehList) { const { data } = await sb.from('vehiculos').select('id,numero,placa').order('numero').limit(3000); vehList = data || []; }
  return vehList;
}
async function loadDespachadores() {
  if (!despList) { const { data } = await sb.from('despachadores').select('id,nombre').order('nombre').limit(2000); despList = data || []; }
  return despList;
}
function fillSelect(sel, pairs, placeholder = '— selecciona —') {
  sel.innerHTML = `<option value="">${placeholder}</option>` +
    pairs.map(([v, l]) => `<option value="${v}">${l}</option>`).join('');
}
function hoyLocal() {
  const d = new Date();
  return new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 10);
}
// Texto del usuario en la barra superior: nombre + rol/puesto
function etiquetaUsuario(user) {
  const nombre = CTX?.nombre || user?.email || '';
  if (CTX?.rol === 'admin') return `👤 ${nombre} · Administrador`;
  if (CTX?.rol === 'despachador') return `👤 ${nombre} · 📌 ${CTX.puesto || 'sin turno hoy'}`;
  return `👤 ${nombre}`;
}
// Indicador de GPS en la barra: verde permitido, ámbar pendiente, rojo bloqueado
async function updateGpsStatus() {
  const el = $('gps-status'); if (!el) return;
  if (!navigator.geolocation) { el.textContent = '🛰️ sin GPS'; el.className = 'gps-status off'; el.title = 'Este dispositivo no tiene GPS disponible'; return; }
  let estado = 'prompt';
  try { const p = await navigator.permissions.query({ name: 'geolocation' }); estado = p.state; p.onchange = () => updateGpsStatus(); } catch (e) { /* sin API de permisos */ }
  if (estado === 'granted') { el.textContent = '🛰️ GPS'; el.className = 'gps-status on'; el.title = 'Ubicación activada'; }
  else if (estado === 'denied') { el.textContent = '🛰️ GPS ✖'; el.className = 'gps-status off'; el.title = 'Permiso de ubicación BLOQUEADO: actívalo en Ajustes'; }
  else { el.textContent = '🛰️ GPS ?'; el.className = 'gps-status pend'; el.title = 'Se pedirá permiso de ubicación al despachar'; }
}
function ahoraLocal() {
  const d = new Date(); const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
}

async function openNuevoDespacho() {
  $('nd-error').hidden = true;
  const r = $('nd-result'); r.hidden = true; r.textContent = '';
  $('nd-tipo').value = 'LIBRE'; // el despacho manual siempre es LIBRE (TABLA solo viene de importación)
  // La fecha del despacho es SIEMPRE hoy y NADIE la puede tocar (ni admin ni despachador) → evita trampas
  $('nd-fecha').value = hoyLocal();
  $('nd-fecha').min = hoyLocal();
  $('nd-fecha').disabled = true;
  $('nd-hora').value = ''; $('nd-com').value = '';

  const [its, veh, drs] = await Promise.all([
    loadItinerarios(), loadVehiculos(), loadDrivers(),
  ]);
  // Despachador: solo itinerarios de sus rutas permitidas
  let itList = its;
  if (!isAdmin()) {
    const allow = [...allowedRutaSet()].filter(Boolean);
    itList = its.filter((i) => {
      const n = normRuta(i.nombre);
      return allow.some((a) => n === a || n.startsWith(a) || a.startsWith(n) || n.includes(a));
    });
  }
  fillSelect($('nd-ruta'), itList.map((i) => [i.itid, i.nombre])); // solo el nombre (ej. 130, 132A) para no confundir
  fillSelect($('nd-movil'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  fillSelect($('nd-cond'), drs.map((d) => [d.dr_id, `${d.nombre || ''}${d.codigo ? ' · ' + d.codigo : ''}`]));
  // El despachador NO se puede cambiar: es el del login (solo se muestra)
  $('nd-desp').value = CTX?.despachador_id ? String(CTX.despachador_id) : '';
  $('nd-desp-name').value = CTX?.nombre || sessionUser?.email || '';
  enhanceById('nd-ruta', 'nd-movil', 'nd-cond');
  await updateNdInfo();
  $('nd-modal').hidden = false;
}
async function updateNdInfo() {
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('nd-movil').value);
  const info = $('nd-info');
  if (!vr) { info.hidden = true; return; }
  const g = await gpsInfoFor(vr.numero);
  if (g) {
    info.hidden = false; info.className = 'field full sonar-info';
    info.innerHTML = `🛰️ <b>SONAR</b> · mId <b>${g.tracker_id || '—'}</b> · Placa ${g.placa || '—'}`;
  } else {
    info.hidden = false; info.className = 'field full sonar-info warn';
    info.textContent = '⚠️ Este móvil no tiene Id GPS en SONAR.';
  }
}
// Nombre del conductor registrado para un móvil: Resumen primero, luego despachos/tablas
async function nombreConductorDeVehiculo(vehId, fecha) {
  if (!vehId) return null;
  try {
    let rq = sb.from('resumen').select('fecha, cond:conductor_id(nombre)').eq('vehiculo_id', vehId).not('conductor_id', 'is', null);
    if (fecha) rq = rq.eq('fecha', fecha);
    let { data } = await rq.order('fecha', { ascending: false }).limit(1);
    if ((!data || !data.length) && fecha) {
      ({ data } = await sb.from('resumen').select('fecha, cond:conductor_id(nombre)').eq('vehiculo_id', vehId)
        .not('conductor_id', 'is', null).order('fecha', { ascending: false }).limit(1));
    }
    if (data && data[0]?.cond?.nombre) return data[0].cond.nombre;
  } catch (e) { /* sigue */ }
  const tablas = ['despachos', ...puestoTables];
  let best = null;
  await Promise.all(tablas.map(async (t) => {
    let qy = sb.from(t).select('fecha, hora, cond:conductor_id(nombre)').eq('vehiculo_id', vehId).not('conductor_id', 'is', null);
    if (fecha) qy = qy.eq('fecha', fecha);
    const { data } = await qy.order('fecha', { ascending: false }).order('hora', { ascending: false }).limit(1);
    const r = (data || [])[0];
    if (r?.cond?.nombre && (!best || String(r.fecha) > String(best.fecha))) best = { fecha: r.fecha, nombre: r.cond.nombre };
  }));
  return best?.nombre || null;
}
// Al elegir el móvil en Nuevo despacho, trae el conductor (mapeando por NOMBRE al conductor SONAR)
async function traerConductorND() {
  const vehId = $('nd-movil').value;
  if (!vehId) return;
  const nombre = await nombreConductorDeVehiculo(vehId, $('nd-fecha').value || null);
  if (!nombre) return;
  const sel = $('nd-cond');
  const drs = await loadDrivers();
  const dm = drs.find((d) => (d.nombre || '').trim().toLowerCase() === nombre.trim().toLowerCase());
  if (dm && [...sel.options].some((o) => o.value === String(dm.dr_id))) {
    sel.value = String(dm.dr_id);
    sel._comboSync && sel._comboSync();
    toast('Conductor traído automáticamente', 'ok');
  }
}
function closeND() { $('nd-modal').hidden = true; }
$('nd-close').addEventListener('click', closeND);
$('nd-cancel').addEventListener('click', closeND);
$('nd-movil').addEventListener('change', () => { updateNdInfo(); traerConductorND(); });

// Captura el GPS del celular para llenar "ubicacion". Nunca bloquea el despacho:
// si no hay permiso, no hay señal o tarda demasiado, resuelve a null y se sigue.
function capturarGps(timeoutMs = 8000) {
  return new Promise((resolve) => {
    if (!navigator.geolocation) { resolve(null); return; }
    let done = false;
    const finish = (v) => { if (!done) { done = true; resolve(v); } };
    const t = setTimeout(() => finish(null), timeoutMs);
    navigator.geolocation.getCurrentPosition(
      (pos) => { clearTimeout(t); finish(`${pos.coords.latitude.toFixed(6)}, ${pos.coords.longitude.toFixed(6)}`); },
      () => { clearTimeout(t); finish(null); },
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 30000 },
    );
  });
}

// Exige la ubicación para poder despachar. Reintenta (re-muestra el permiso del
// navegador mientras no esté bloqueado) hasta obtenerla. Devuelve "lat, lng" o
// null SOLO si el usuario decide cancelar el despacho.
async function requerirGps() {
  while (true) {
    const pos = await capturarGps(12000);
    if (pos) return pos;
    let estado = '';
    try { estado = (await navigator.permissions.query({ name: 'geolocation' })).state; } catch (e) { /* sin API de permisos */ }
    const bloqueado = estado === 'denied';
    const reintentar = await confirmAction({
      title: '📍 Activa la ubicación (GPS)',
      lead: 'No se puede despachar sin la ubicación del celular.',
      message: bloqueado
        ? 'El permiso de ubicación está BLOQUEADO. Actívalo en:\nAjustes → Apps → esta app → Permisos → Ubicación → Permitir.\nLuego toca Reintentar.'
        : 'Enciende el GPS del celular y acepta el permiso de ubicación cuando aparezca.\nLuego toca Reintentar.',
      okLabel: 'Reintentar',
      danger: true,
    });
    if (!reintentar) return null; // el usuario cancela el despacho
  }
}

// Ejecuta un despacho completo (BD + SONAR) a partir de un "intent". Lanza si hay error de red.
async function doDispatch(intent) {
  let ruta_id = null;
  if (intent.itinNombre) {
    const { data, error } = await sb.from('rutas').upsert({ nombre: intent.itinNombre }, { onConflict: 'nombre' }).select('id').single();
    if (error) throw error; ruta_id = data.id;
  }
  let conductor_id = null;
  if (intent.drvNombre) {
    const { data, error } = await sb.from('conductores').upsert({ nombre: intent.drvNombre }, { onConflict: 'nombre' }).select('id').single();
    if (error) throw error; conductor_id = data.id;
  }
  const payload = {
    id: intent.id, tipo: intent.tipo, fecha: intent.fecha, hora: intent.hora, ruta_id,
    vehiculo_id: intent.vehId, conductor_id, codigo: intent.drvCodigo || null,
    despachador_id: intent.despId, estado_despacho: 'DESPACHADO', observacion: intent.com || null,
    realizo_programado: true, // despacho manual (LIBRE): el carro hizo el viaje
    despachado_en: new Date().toISOString(),
    ubicacion: intent.ubicacion || null, // GPS del celular capturado al despachar
  };
  const ins = await sb.from('despachos').upsert(payload, { onConflict: 'id' });
  if (ins.error) throw ins.error;
  const { data: sd, error: se } = await sb.rpc('despachar_sonar', {
    p_mid: intent.mId || '', p_itinerary: intent.itid, p_drvid: intent.drvId, p_utc: '', p_comments: intent.com || ('Despacho ' + intent.id),
  });
  if (se) throw se;
  if (sd && sd.ok && sd.regid) await sb.from('despachos').update({ sonar_regid: String(sd.regid) }).eq('id', intent.id);
  return sd;
}

$('nd-save').addEventListener('click', async () => {
  if ($('nd-save').dataset.busy === '1') return; // evita doble click / doble despacho
  const err = $('nd-error'); err.hidden = true;
  const itid = $('nd-ruta').value;
  const vehVal = $('nd-movil').value;
  const drvId = $('nd-cond').value;
  if (!itid || !vehVal || !drvId) {
    err.textContent = 'Ruta, Móvil y Conductor son obligatorios.'; err.hidden = false; return;
  }
  const its = await loadItinerarios(), veh = await loadVehiculos(), drs = await loadDrivers();
  const itin = its.find((i) => i.itid === itid);
  const vrow = veh.find((v) => String(v.id) === vehVal);
  const drow = drs.find((d) => d.dr_id === drvId);

  const intent = {
    id: 'APL' + Date.now().toString(36).slice(-3).toUpperCase() + Math.random().toString(36).slice(2, 5).toUpperCase(),
    // Nadie puede alterar la fecha del despacho: siempre es hoy
    tipo: 'LIBRE', fecha: hoyLocal(), hora: $('nd-hora').value || null,
    itid, itinNombre: itin?.nombre || null,
    vehId: Number(vehVal), mId: vrow?.numero ? (await gpsIdFor(vrow.numero)) : null,
    drvId, drvNombre: drow?.nombre || null, drvCodigo: drow?.codigo || null,
    despId: Number($('nd-desp').value) || null, com: $('nd-com').value.trim(),
  };

  // Aviso de doble despacho por tiempo (< 20 min)
  const minDesde = await minutosUltimoDespacho(Number(vehVal));
  if (minDesde !== null && minDesde < 20) {
    const seguir = await confirmAction({
      title: '⚠️ Móvil despachado hace poco',
      lead: `El móvil ${vrow?.numero || ''} fue despachado hace ${minDesde} min.`,
      message: '¿Desea despachar nuevamente?',
      okLabel: 'Despachar de nuevo', danger: true,
    });
    if (!seguir) return;
  }

  // Confirmación antes de crear/despachar
  const ok = await confirmAction({
    title: '¿Crear y despachar?',
    lead: 'Se creará un despacho LIBRE y se enviará a SONAR:',
    message: `Móvil:    ${vrow?.numero || '—'}\nRuta:     ${itin?.nombre || '—'}\nConductor:${drow?.nombre ? ' ' + drow.nombre : ' —'}`
      + (intent.com ? `\nComent.:  ${intent.com}` : ''),
    okLabel: 'Despachar',
  });
  if (!ok) return;

  // Bloquea el botón YA (antes del GPS) para que no se pueda hacer doble click
  const btn = $('nd-save'); btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = 'Procesando…';
  const liberar = () => { btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = 'Crear y despachar'; };

  // GPS OBLIGATORIO: sin ubicación no se despacha (reintenta / vuelve a pedir permiso)
  intent.ubicacion = await requerirGps();
  if (!intent.ubicacion) {
    liberar();
    err.textContent = 'Despacho cancelado: se requiere la ubicación (GPS) para despachar.'; err.hidden = false;
    return;
  }

  // Sin internet → guardar offline y salir
  if (!navigator.onLine) {
    liberar();
    enqueueDispatch(intent);
    toast('Sin conexión: despacho guardado, se enviará al reconectar', 'ok');
    closeND(); if (current === 'despachos') loadData();
    return;
  }

  showBusy('Despachando en SONAR…'); // capa que bloquea la pantalla mientras responde SONAR
  try {
    const sd = await doDispatch(intent);
    const res = $('nd-result'); res.hidden = false;
    if (sd && sd.ok) {
      res.className = 'sonar-result ok';
      res.textContent = '✅ Despacho creado y enviado a SONAR (HTTP ' + (sd.status ?? '') + ')'
        + (sd.regid ? '\nregId: ' + sd.regid : '')
        + '\n📍 Ubicación registrada: ' + intent.ubicacion
        + '\n\n' + (sd.response || '').slice(0, 800);
      toast('Despacho creado y despachado', 'ok');
    } else {
      res.className = 'sonar-result err';
      res.textContent = '✅ Despacho creado. ⚠️ SONAR respondió: ' + (sd?.error || ('HTTP ' + (sd?.status ?? '?'))) + '\n\n' + ((sd?.response || '').slice(0, 800));
    }
    if (current === 'despachos') loadData();
  } catch (e) {
    if (isNetworkErr(e)) {
      enqueueDispatch(intent);
      toast('Conexión perdida: despacho guardado, se enviará al reconectar', 'ok');
      closeND(); if (current === 'despachos') loadData();
    } else {
      err.textContent = 'Error: ' + (e.message || e); err.hidden = false;
    }
  } finally {
    hideBusy();
    btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = 'Crear y despachar';
  }
});

// ---------- Despachar en SONAR ----------
let gpsMap = null;
async function gpsInfoFor(movil) {
  if (!gpsMap) {
    gpsMap = {};
    const { data } = await sb.from('vehiculosgps').select('movil,gps_vehiculo_id,placa,tracker_id').limit(3000);
    (data || []).forEach((r) => { if (r.movil) gpsMap[r.movil] = r; });
  }
  return gpsMap[movil];
}
async function gpsIdFor(movil) { const r = await gpsInfoFor(movil); return r?.tracker_id; }

// Minutos desde el último despacho de un móvil (mirando despachos + tablas de puesto).
// Devuelve null si no tiene despacho reciente registrado.
async function minutosUltimoDespacho(vehId) {
  if (!vehId) return null;
  let masReciente = null;
  // Anti-doble-despacho GLOBAL (para todos): la función mira 'despachos' y TODAS
  // las tablas de puesto sin importar RLS, así detecta despachos hechos en
  // cualquier puesto/despachador.
  const { data: ts, error } = await sb.rpc('ultimo_despacho_vehiculo', { p_veh: vehId });
  if (!error) {
    if (!ts) return null;
    masReciente = new Date(ts).getTime();
  } else {
    // Respaldo: consulta directa a las tablas accesibles (por si la función no existe)
    const tablas = ['despachos', ...puestoTables];
    await Promise.all(tablas.map(async (t) => {
      const { data } = await sb.from(t).select('despachado_en')
        .eq('vehiculo_id', vehId).eq('estado_despacho', 'DESPACHADO')
        .not('despachado_en', 'is', null)
        .order('despachado_en', { ascending: false }).limit(1);
      const r = (data || [])[0];
      if (r?.despachado_en) {
        const ms = new Date(r.despachado_en).getTime();
        if (!masReciente || ms > masReciente) masReciente = ms;
      }
    }));
    if (!masReciente) return null;
  }
  return Math.floor((Date.now() - masReciente) / 60000);
}

let itinList = null;
async function loadItinerarios() {
  if (!itinList) {
    const { data } = await sb.from('itinerarios').select('itid,grupo,nombre').order('nombre').limit(2000);
    itinList = data || [];
  }
  return itinList;
}

let drvList = null;
async function loadDrivers() {
  if (!drvList) {
    const { data } = await sb.from('conductores_sonar')
      .select('dr_id,nombre,codigo').eq('status', 'ENABLED').order('nombre').limit(3000);
    drvList = data || [];
  }
  return drvList;
}

async function updateSonarInfo() {
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('s-mov').value);
  const info = $('s-info');
  if (!vr) { info.hidden = true; return; }
  const g = await gpsInfoFor(vr.numero);
  if (g) {
    info.hidden = false; info.className = 'field full sonar-info';
    info.innerHTML = `🛰️ <b>SONAR</b> · mId <b>${g.tracker_id || '—'}</b> · Placa ${g.placa || '—'}`;
  } else {
    info.hidden = false; info.className = 'field full sonar-info warn';
    info.textContent = '⚠️ Este móvil no tiene Id GPS en SONAR (revisa Vehículos GPS).';
  }
}

let sonarRow = null, sonarTable = 'despachos';
async function openSonar(row) {
  // La fecha es clave: no se despacha un viaje de un día anterior a hoy
  if (row && row.fecha && String(row.fecha).slice(0, 10) < hoyLocal()) {
    toast('No se puede despachar: la fecha del viaje ya pasó.', 'err'); return;
  }
  sonarRow = row || null;
  sonarTable = TABLES[current]?.dispatchable ? current : 'despachos';
  $('sonar-error').hidden = true;
  const sbtn = $('sonar-send'); sbtn.disabled = false; sbtn.textContent = 'Despachar'; // reset por si quedó deshabilitado
  const res = $('sonar-result'); res.hidden = true; res.textContent = '';
  $('s-com').value = '';

  const [veh, its, drs] = await Promise.all([loadVehiculos(), loadItinerarios(), loadDrivers()]);
  fillSelect($('s-mov'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  fillSelect($('s-itin'), its.map((i) => [i.itid, i.nombre])); // solo el nombre (ej. 130, 132A) para no confundir
  fillSelect($('s-drv'), drs.map((d) => [d.dr_id, `${d.nombre || ''}${d.codigo ? ' · ' + d.codigo : ''}`]));

  if (row) {
    const movil = row.veh?.numero || row.vehp?.numero; // real, o el programado (TABLA importada)
    if (movil) { const vr = veh.find((v) => String(v.numero) === String(movil)); if (vr) $('s-mov').value = vr.id; }
    const ruta = (row.ruta?.nombre || row.rutap?.nombre || '').toLowerCase();
    if (ruta) { const m = its.find((i) => (i.nombre || '').toLowerCase() === ruta); if (m) $('s-itin').value = m.itid; }
    const cod = row.codigo, nom = (row.cond?.nombre || '').toLowerCase();
    let dm = cod ? drs.find((d) => d.codigo === cod) : null;
    if (!dm && nom) dm = drs.find((d) => (d.nombre || '').toLowerCase() === nom);
    if (dm) $('s-drv').value = dm.dr_id;
    $('s-com').value = 'Despacho ' + (row.id || '');
  }
  enhanceById('s-mov', 's-itin', 's-drv');
  $('s-desp-name').value = CTX?.nombre || ''; // despachador = usuario en sesión (no editable)
  if (!$('s-drv').value) await traerConductorSonar(); // si la fila no trae conductor, lo busca en Resumen
  await updateSonarInfo();
  $('sonar-modal').hidden = false;
}
// Trae el conductor registrado en Resumen para el móvil elegido (mapeado a conductor SONAR)
async function traerConductorSonar() {
  const vehId = $('s-mov').value;
  if (!vehId) return;
  const nombre = await nombreConductorDeVehiculo(vehId, hoyLocal());
  if (!nombre) return;
  const sel = $('s-drv');
  const drs = await loadDrivers();
  const dm = drs.find((d) => (d.nombre || '').trim().toLowerCase() === nombre.trim().toLowerCase());
  if (dm && [...sel.options].some((o) => o.value === String(dm.dr_id))) {
    sel.value = String(dm.dr_id);
    sel._comboSync && sel._comboSync();
    toast('Conductor traído de Resumen', 'ok');
  }
}
function closeSonar() { $('sonar-modal').hidden = true; }
$('sonar-close').addEventListener('click', closeSonar);
$('sonar-cancel').addEventListener('click', closeSonar);
$('dispatch-btn').addEventListener('click', () => openSonar(null));
$('s-mov').addEventListener('change', () => { updateSonarInfo(); traerConductorSonar(); });

$('sonar-send').addEventListener('click', async () => {
  const btn = $('sonar-send');
  if (btn.dataset.busy === '1') return; // evita doble click / doble despacho
  const err = $('sonar-error'); err.hidden = true;
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('s-mov').value);
  const itin = $('s-itin').value, drv = $('s-drv').value, com = $('s-com').value.trim();
  // Campos obligatorios para despachar
  if (!vr) { err.textContent = 'Selecciona un móvil.'; err.hidden = false; return; }
  if (!itin) { err.textContent = 'Selecciona un itinerario / ruta.'; err.hidden = false; return; }
  if (!drv) { err.textContent = 'Selecciona un conductor.'; err.hidden = false; return; }
  const g = await gpsInfoFor(vr.numero); const mId = g?.tracker_id;
  if (!mId) { err.textContent = 'Ese móvil no tiene Id GPS en SONAR.'; err.hidden = false; return; }

  // Aviso de DOBLE DESPACHO por tiempo: si el móvil fue despachado hace menos de 20 min
  const minDesde = await minutosUltimoDespacho(vr.id);
  if (minDesde !== null && minDesde < 20) {
    const seguir = await confirmAction({
      title: '⚠️ Móvil despachado hace poco',
      lead: `El móvil ${vr.numero} fue despachado hace ${minDesde} min.`,
      message: '¿Desea despachar nuevamente?',
      okLabel: 'Despachar de nuevo', danger: true,
    });
    if (!seguir) return;
  }

  // Confirmación antes de despachar
  const itinLabel = $('s-itin').selectedOptions[0]?.textContent || itin;
  const drvLabel = $('s-drv').selectedOptions[0]?.textContent || '—';
  // ¿Es un reemplazo? (el móvil seleccionado es distinto al programado)
  const progId = sonarRow ? (sonarRow.vehiculo_programado_id || sonarRow.vehiculo_id || null) : null;
  const esReemplazo = progId && Number(progId) !== Number(vr.id);
  const movProg = esReemplazo ? (veh.find((v) => Number(v.id) === Number(progId))?.numero || progId) : null;
  const ok = await confirmAction({
    title: '¿Despachar en SONAR?',
    lead: 'Se enviará este despacho a SONAR:',
    message: `Móvil:     ${vr.numero}  (mId ${mId})\nItinerario:${' ' + itinLabel}\nConductor: ${drvLabel}`
      + (com ? `\nComent.:   ${com}` : '')
      + (esReemplazo ? `\n\n⚠️ Reemplazo: el móvil programado ${movProg} quedará como NO realizó el viaje.` : ''),
    okLabel: 'Despachar',
  });
  if (!ok) return;

  // Bloquea el botón YA (antes del GPS) para que no se pueda hacer doble click
  btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = 'Procesando…';

  // GPS OBLIGATORIO: sin ubicación no se despacha (reintenta / vuelve a pedir permiso)
  const ubicGps = await requerirGps();
  if (!ubicGps) {
    btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = 'Despachar';
    err.textContent = 'Despacho cancelado: se requiere la ubicación (GPS) para despachar.'; err.hidden = false;
    return;
  }

  btn.textContent = 'Enviando…';
  showBusy('Despachando en SONAR…'); // capa que bloquea la pantalla mientras responde SONAR
  let data, error;
  try {
    ({ data, error } = await sb.rpc('despachar_sonar', {
      p_mid: String(mId), p_itinerary: itin, p_drvid: drv, p_utc: '', p_comments: com,
    }));
  } finally {
    hideBusy();
    btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = 'Despachar';
  }

  const res = $('sonar-result'); res.hidden = false;
  if (error) { res.className = 'sonar-result err'; res.textContent = 'Error: ' + error.message; return; }
  if (data && data.ok) {
    // Marcar como DESPACHADO y registrar el móvil REAL despachado.
    // El vehículo PROGRAMADO (el de la importación) se conserva siempre.
    if (sonarRow?.id) {
      const newVehId = Number($('s-mov').value) || sonarRow.vehiculo_id || null;
      const progId = sonarRow.vehiculo_programado_id || sonarRow.vehiculo_id || null;
      const patch = {
        estado_despacho: 'DESPACHADO',
        vehiculo_id: newVehId,
        // si no había programado, se fija con el original de la fila (no se pierde)
        vehiculo_programado_id: progId || newVehId,
        // Si despacharon con OTRO carro (reemplazo), el carro programado NO realizó el viaje
        realizo_programado: !(progId && newVehId && Number(progId) !== Number(newVehId)),
        despachado_en: new Date().toISOString(), // hora del despacho (para el aviso de 20 min)
      };
      // Queda registrado quién despachó (el usuario que tiene la sesión)
      if (CTX?.despachador_id) patch.despachador_id = CTX.despachador_id;
      if (ubicGps) patch.ubicacion = ubicGps; // GPS del celular al despachar
      if (data.regid) patch.sonar_regid = String(data.regid);
      await sb.from(sonarTable).update(patch).eq('id', sonarRow.id);
      if (current === sonarTable) loadData();
    }
    res.className = 'sonar-result ok';
    res.textContent = '✅ Despachado (HTTP ' + (data.status ?? '') + ')'
      + (data.regid ? '\nregId: ' + data.regid : '')
      + '\n📍 Ubicación registrada: ' + ubicGps
      + '\n\n' + (data.response || '').slice(0, 1200);
    toast('Despachado en SONAR', 'ok');
    // Ya quedó despachado: no permitir despachar de nuevo en este modal
    sonarRow = null;
    btn.disabled = true; btn.textContent = 'Despachado ✓';
  } else {
    res.className = 'sonar-result err';
    res.textContent = '⚠️ ' + (data?.error || ('Respuesta HTTP ' + (data?.status ?? '?'))) + '\n\n' + ((data?.response || '').slice(0, 1200));
  }
});

// ---------- Cancelar despacho en SONAR ----------
let cancelRow = null, cancelTable = 'despachos';
async function updateCancelInfo() {
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('c-mov').value);
  const info = $('c-info');
  if (!vr) { info.hidden = true; return; }
  const g = await gpsInfoFor(vr.numero);
  if (g) {
    info.hidden = false; info.className = 'field full sonar-info';
    info.innerHTML = `🛰️ <b>SONAR</b> · mId <b>${g.tracker_id || '—'}</b> · Placa ${g.placa || '—'}`;
  } else {
    info.hidden = false; info.className = 'field full sonar-info warn';
    info.textContent = '⚠️ Este móvil no tiene Id GPS en SONAR.';
  }
}
// Regla general: un despacho solo se cancela si lleva 50 min o menos despachado
const MAX_MIN_CANCELAR = 50;
function minsDesde(ts) { return ts ? Math.floor((Date.now() - new Date(ts).getTime()) / 60000) : null; }

async function openCancelar(row) {
  if (row && !row.sonar_regid) { toast('Este despacho no tiene regId: no se puede cancelar.', 'err'); return; }
  // La fecha es clave: no se cancela un despacho de un día anterior a hoy
  if (row && row.fecha && String(row.fecha).slice(0, 10) < hoyLocal()) {
    toast('No se puede cancelar: el despacho es de una fecha anterior a hoy.', 'err'); return;
  }
  // Regla: no se puede cancelar si el viaje ya superó los 50 minutos
  const mins = minsDesde(row?.despachado_en);
  if (mins !== null && mins > MAX_MIN_CANCELAR) {
    toast(`No se puede cancelar: el viaje ya supera los ${MAX_MIN_CANCELAR} min (lleva ${mins} min).`, 'err');
    return;
  }
  cancelRow = row || null;
  cancelTable = TABLES[current]?.dispatchable ? current : 'despachos';
  $('cancel-error').hidden = true;
  const cbtn = $('cancel-send'); cbtn.disabled = false; cbtn.textContent = 'Cancelar despacho'; // reset por si quedó deshabilitado
  const res = $('cancel-result'); res.hidden = true; res.textContent = '';
  $('c-regid').value = row?.sonar_regid || '';
  $('c-com').value = 'Cancelación ' + (row?.id || '');

  const veh = await loadVehiculos();
  fillSelect($('c-mov'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  if (row) {
    const movil = row.veh?.numero;
    if (movil) { const vr = veh.find((v) => String(v.numero) === String(movil)); if (vr) $('c-mov').value = vr.id; }
  }
  enhanceById('c-mov');
  // Despachador: quien despachó el viaje (si se conoce) o el usuario en sesión
  $('c-desp-name').value = row?.desp?.nombre || CTX?.nombre || '';
  await updateCancelInfo();
  $('cancel-modal').hidden = false;
}
function closeCancel() { $('cancel-modal').hidden = true; cancelRow = null; }
$('cancel-close').addEventListener('click', closeCancel);
$('cancel-cancel').addEventListener('click', closeCancel);
$('c-mov').addEventListener('change', updateCancelInfo);

$('cancel-send').addEventListener('click', async () => {
  const btn = $('cancel-send');
  if (btn.dataset.busy === '1') return; // evita doble click
  const err = $('cancel-error'); err.hidden = true;
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('c-mov').value);
  if (!vr) { err.textContent = 'Selecciona un móvil.'; err.hidden = false; return; }
  const g = await gpsInfoFor(vr.numero); const mId = g?.tracker_id;
  if (!mId) { err.textContent = 'Ese móvil no tiene Id GPS en SONAR.'; err.hidden = false; return; }
  const regId = $('c-regid').value.trim();
  const com = $('c-com').value.trim();
  if (!regId) { err.textContent = 'No hay regId: no se puede cancelar este despacho.'; err.hidden = false; return; }
  // Revalida la regla de 50 min con la hora real de la BD
  if (cancelRow?.id) {
    const { data: cur } = await sb.from(cancelTable).select('despachado_en').eq('id', cancelRow.id).maybeSingle();
    const mins = minsDesde(cur?.despachado_en);
    if (mins !== null && mins > MAX_MIN_CANCELAR) {
      err.textContent = `No se puede cancelar: el viaje ya supera los ${MAX_MIN_CANCELAR} min (lleva ${mins} min).`;
      err.hidden = false; return;
    }
  }
  const ok = await confirmAction({
    title: '¿Cancelar despacho?',
    lead: 'Se cancelará el despacho activo en SONAR:',
    message: `Móvil:  ${vr.numero}  (mId ${mId})\nregId:  ${regId}`,
    okLabel: 'Cancelar despacho',
    danger: true,
  });
  if (!ok) return;

  btn.dataset.busy = '1'; btn.disabled = true; btn.textContent = 'Cancelando…';
  showBusy('Cancelando en SONAR…'); // capa que bloquea la pantalla mientras responde SONAR
  let data, error;
  try {
    ({ data, error } = await sb.rpc('cancelar_sonar', { p_mid: String(mId), p_regid: regId, p_comments: com }));
  } finally {
    hideBusy();
    btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = 'Cancelar despacho';
  }

  const res = $('cancel-result'); res.hidden = false;
  if (error) { res.className = 'sonar-result err'; res.textContent = 'Error: ' + error.message; return; }
  if (data && data.ok) {
    // Marcar el despacho como cancelado y limpiar el regId usado
    if (cancelRow?.id) {
      await sb.from(cancelTable).update({ estado_despacho: 'CANCELADO', sonar_regid: null }).eq('id', cancelRow.id);
      if (current === cancelTable) loadData();
    }
    res.className = 'sonar-result ok';
    res.textContent = '✅ Cancelado en SONAR (HTTP ' + (data.status ?? '') + ')\n\n' + (data.response || '').slice(0, 1200);
    toast('Despacho cancelado en SONAR', 'ok');
    // Ya quedó cancelado: no permitir cancelar de nuevo en este modal
    cancelRow = null;
    $('c-regid').value = '';
    btn.disabled = true; btn.textContent = 'Cancelado ✓';
  } else {
    res.className = 'sonar-result err';
    res.textContent = '⚠️ ' + (data?.error || ('Respuesta HTTP ' + (data?.status ?? '?'))) + '\n\n' + ((data?.response || '').slice(0, 1200));
  }
});

// ---------- Consultar despachos de SONAR por móvil ----------
async function openDsonar() {
  $('ds-error').hidden = true;
  $('ds-results').innerHTML = '';
  $('ds-info').hidden = true;
  $('ds-fecha').value = hoyLocal();
  const veh = await loadVehiculos();
  fillSelect($('ds-mov'), veh.map((v) => [v.numero, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]), 'Selecciona móvil');
  enhanceById('ds-mov');
  $('ds-modal').hidden = false;
}
function closeDsonar() { $('ds-modal').hidden = true; }
$('dsonar-btn').addEventListener('click', openDsonar);
$('ds-close').addEventListener('click', closeDsonar);
$('ds-cancel').addEventListener('click', closeDsonar);

$('ds-run').addEventListener('click', async () => {
  const err = $('ds-error'); err.hidden = true;
  const movil = $('ds-mov').value;
  const fecha = $('ds-fecha').value;
  if (!movil) { err.textContent = 'Selecciona un móvil.'; err.hidden = false; return; }
  if (!fecha) { err.textContent = 'Selecciona una fecha.'; err.hidden = false; return; }
  const g = await gpsInfoFor(movil);
  const mId = g?.tracker_id;
  if (!mId) { err.textContent = 'Ese móvil no tiene Tracker (mId) en SONAR.'; err.hidden = false; return; }

  const btn = $('ds-run'); btn.disabled = true; btn.textContent = 'Consultando…';
  $('ds-results').innerHTML = '<div class="empty">Consultando SONAR…</div>';
  try {
    const { data, error } = await sb.rpc('despachos_sonar', {
      p_mid: String(mId), p_ini: `${fecha} 00:00:00`, p_fin: `${fecha} 23:59:59`,
    });
    if (error) throw error;
    if (!data || !data.ok) throw new Error(data?.error || 'SONAR no respondió');
    renderDsonar(data.items || []);
  } catch (e) {
    $('ds-results').innerHTML = '';
    err.textContent = 'Error: ' + (e.message || e); err.hidden = false;
  } finally {
    btn.disabled = false; btn.textContent = 'Consultar';
  }
});

function dsEstado(d) {
  if (String(d.corriendo) === 'true') return ['En curso', 'chip-green'];
  if (String(d.cancelado) === 'true') return ['Cancelado', 'chip-red'];
  if (String(d.cerrado) === 'true') return ['Cerrado', 'chip-gray'];
  return ['—', 'chip-gray'];
}
function renderDsonar(items) {
  if (!items.length) { $('ds-results').innerHTML = '<div class="empty">Sin despachos para ese móvil y fecha.</div>'; return; }
  const filas = items.map((d) => {
    const [txt, cls] = dsEstado(d);
    return `<tr>
      <td>${esc(d.hora || '')}</td>
      <td>${esc(d.ruta || '')}</td>
      <td>${esc(d.conductor || '')}</td>
      <td style="text-align:right">${d.minutos ?? ''}</td>
      <td><span class="chip ${cls}">${txt}</span></td>
    </tr>`;
  }).join('');
  $('ds-results').innerHTML = `<table class="ds-table"><thead><tr>
    <th>Hora</th><th>Ruta</th><th>Conductor</th><th>Min</th><th>Estado</th>
    </tr></thead><tbody>${filas}</tbody></table>`;
}

// ---------- Mapa de la flota (Leaflet + OpenStreetMap) ----------
let flotaMap = null, flotaLayer = null, mapTimer = null, currentView = 'tabla';
// Clasifica el estado de un móvil: 'off' apagado · 'mov' en movimiento · 'idle' encendido detenido
function clasificar(r) {
  if (r.motor === 'Apagado') return 'off';
  return (r.speed || 0) > 0 ? 'mov' : 'idle';
}
const ESTADO_TXT = { off: 'Apagado', mov: 'En movimiento', idle: 'Detenido (encendido)' };
function mapPopup(r) {
  const fila = (k, v) => (v != null && String(v).trim() !== '')
    ? `<div class="pi-row"><span>${k}</span><b>${esc(String(v))}</b></div>` : '';
  const g = `https://www.google.com/maps?q=${r.latitude},${r.longitude}`;
  const cls = clasificar(r);
  return `<div class="map-popup">
    <div class="pi-title">🚌 Móvil ${esc(r.movil || '—')}
      <span class="pi-state ${cls}">${ESTADO_TXT[cls]}</span></div>
    ${fila('Placa', r.placa)}
    <div class="pi-row"><span>Ruta actual (SONAR)</span><b id="cur-ruta">⏳…</b></div>
    ${fila('Ruta (despacho)', r.ruta)}
    ${fila('Conductor', r.driver_name || 'Sin conductor')}
    ${fila('Velocidad', (r.speed ?? 0) + ' km/h')}
    ${fila('Rumbo', r.heading != null ? r.heading + '°' : '')}
    ${fila('Motor', r.motor)}
    ${fila('Último evento', r.evento)}
    ${fila('Dirección', r.address)}
    ${fila('Hora GPS', r.gps_gmt)}
    ${fila('Sincronizado', r.actualizado)}
    ${fila('Coordenadas', `${r.latitude}, ${r.longitude}`)}
    <a class="pi-link" href="${g}" target="_blank" rel="noopener">📍 Ver en Google Maps</a>
  </div>`;
}
// Panel inferior deslizable con la info del móvil (estilo apps de mapas)
async function openVehSheet(r) {
  const sheet = $('veh-sheet'), body = $('veh-sheet-body');
  body.innerHTML = mapPopup(r);
  // Acciones directas sobre el móvil (solo admin: despachar/consultar SONAR)
  if (isAdmin()) {
    const acts = document.createElement('div');
    acts.className = 'veh-sheet-acts';
    const bDsp = Object.assign(document.createElement('button'), { className: 'btn btn-primary', textContent: '🛰️ Despachar' });
    bDsp.onclick = () => despacharDesdeMapa(r.movil);
    const bCon = Object.assign(document.createElement('button'), { className: 'btn', textContent: '📡 Consultar SONAR' });
    bCon.onclick = () => consultarDesdeMapa(r.movil);
    acts.append(bDsp, bCon);
    body.appendChild(acts);
  }
  sheet.hidden = false;
  requestAnimationFrame(() => sheet.classList.add('open'));
  // Ruta actual en SONAR (1 llamada)
  const cur = body.querySelector('#cur-ruta');
  if (cur) {
    cur.textContent = '⏳…';
    const { data, error } = await sb.rpc('ruta_actual_sonar', { p_mid: r.mid });
    const c2 = body.querySelector('#cur-ruta');
    if (c2) c2.textContent = (error || !data || !data.ok) ? (r.ruta ? `${r.ruta} (despacho)` : '—') : (data.ruta || '—');
  }
}
function closeVehSheet() {
  const sheet = $('veh-sheet');
  if (!sheet || sheet.hidden) return;
  sheet.style.transform = '';
  sheet.classList.remove('open');
  setTimeout(() => { sheet.hidden = true; }, 250);
}
// Despachar el móvil del panel: abre el modal SONAR con ese móvil preseleccionado
async function despacharDesdeMapa(movil) {
  closeVehSheet();
  await openSonar(null);
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.numero) === String(movil));
  if (vr) { $('s-mov').value = String(vr.id); $('s-mov')._comboSync && $('s-mov')._comboSync(); await updateSonarInfo(); }
}
// Consultar en SONAR el móvil del panel
async function consultarDesdeMapa(movil) {
  closeVehSheet();
  await openDsonar();
  $('ds-mov').value = String(movil); $('ds-mov')._comboSync && $('ds-mov')._comboSync();
}
$('veh-sheet-close')?.addEventListener('click', closeVehSheet);

// Deslizar hacia abajo (en la barra superior del panel) para cerrar
(() => {
  const sheet = $('veh-sheet'), head = $('veh-sheet-head');
  if (!sheet || !head) return;
  let y0 = null, drag = false;
  head.addEventListener('touchstart', (e) => { y0 = e.touches[0].clientY; drag = true; sheet.style.transition = 'none'; }, { passive: true });
  head.addEventListener('touchmove', (e) => { if (!drag) return; const dy = e.touches[0].clientY - y0; if (dy > 0) sheet.style.transform = `translateY(${dy}px)`; }, { passive: true });
  head.addEventListener('touchend', (e) => {
    if (!drag) return; drag = false; sheet.style.transition = '';
    const dy = e.changedTouches[0].clientY - y0;
    sheet.style.transform = '';
    if (dy > 90) closeVehSheet();
  });
  // En escritorio: clic en la barra (no en la ✕) también cierra
  head.addEventListener('click', (e) => { if (e.target.id !== 'veh-sheet-close') closeVehSheet(); });
})();

let lastUbic = [], mapFilter = 'todos', routeFilter = '', vehSearch = [];
function fillRutaSelect() {
  const sel = $('map-ruta'); if (!sel) return;
  const prev = sel.value;
  const rutas = [...new Set(lastUbic.map((r) => r.ruta).filter(Boolean))]
    .sort((a, b) => a.localeCompare(b, 'es', { numeric: true }));
  sel.innerHTML = `<option value="">Todas las rutas (${rutas.length})</option>`
    + rutas.map((rt) => `<option value="${esc(rt)}">${esc(rt)}</option>`).join('');
  if (rutas.includes(prev)) sel.value = prev; else routeFilter = '';
}
function renderMarkers(fit) {
  if (!flotaLayer) return;
  flotaLayer.clearLayers();
  const pts = [];
  for (const r of lastUbic) {
    if (r.latitude == null || r.longitude == null) continue;
    const cls = clasificar(r);
    if (mapFilter !== 'todos' && cls !== mapFilter) continue;
    if (routeFilter && (r.ruta || '') !== routeFilter) continue;
    if (vehSearch.length) {
      const m = String(r.movil || '').toLowerCase(), p = String(r.placa || '').toLowerCase();
      if (!vehSearch.some((q) => m.includes(q) || p.includes(q))) continue;
    }
    const ruta = r.ruta ? ` <small>${esc(r.ruta)}</small>` : '';
    const icon = L.divIcon({
      className: 'bus-marker',
      html: `<div class="bus-pin ${cls}"><span>🚌</span>${esc(r.movil || '—')}${ruta}</div>`,
      iconSize: null, iconAnchor: [26, 24], popupAnchor: [0, -22],
    });
    const m = L.marker([r.latitude, r.longitude], { icon, title: `Móvil ${r.movil || ''}` });
    m._row = r;
    m.on('click', () => openVehSheet(r)); // abre el panel inferior (mejor en celular)
    flotaLayer.addLayer(m);
    pts.push([r.latitude, r.longitude]);
  }
  const filtrando = mapFilter !== 'todos' || routeFilter;
  $('map-count').textContent = filtrando ? `${pts.length} de ${lastUbic.length}` : `${pts.length} móviles`;
  if (fit && pts.length) flotaMap.fitBounds(pts, { padding: [30, 30] });
}
async function refreshMapa(fit) {
  const { data, error } = await sb.from('ubicaciones').select('*').not('latitude', 'is', null);
  if (error) { toast('Error al cargar ubicaciones: ' + error.message, 'err'); return; }
  let rows = data || [];
  // Despachador: solo móviles de sus rutas (la RLS ya limita, esto es por si acaso)
  if (!isAdmin()) { const allow = allowedRutaSet(); rows = rows.filter((r) => allow.has(normRuta(r.ruta))); }
  lastUbic = rows;
  fillRutaSelect();
  renderMarkers(fit);
}
async function showMapView() {
  if (typeof L === 'undefined') { toast('No se pudo cargar el mapa (revisa tu conexión a internet)', 'err'); return; }
  currentView = 'mapa';
  $('table-view').hidden = true;
  $('map-view').hidden = false;
  closeVehSheet();
  // resaltar la opción del menú
  document.querySelectorAll('#sidebar button').forEach((b) => b.classList.remove('active'));
  $('nav-mapa')?.classList.add('active');
  if (!flotaMap) {
    flotaMap = L.map('map').setView([6.244, -75.58], 12); // Medellín
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© OpenStreetMap',
    }).addTo(flotaMap);
    flotaLayer = L.layerGroup().addTo(flotaMap);
    flotaMap.on('click', closeVehSheet); // tocar el mapa cierra el panel
  }
  setTimeout(() => flotaMap.invalidateSize(), 120); // el contenedor estaba oculto
  await refreshMapa(true);
  if (mapTimer) clearInterval(mapTimer);
  mapTimer = setInterval(() => refreshMapa(false), 60000); // refresco automático cada 60s
}
$('map-refresh').addEventListener('click', () => refreshMapa(true));
document.querySelectorAll('#map-filters .mf').forEach((b) => {
  b.addEventListener('click', () => {
    mapFilter = b.dataset.f;
    document.querySelectorAll('#map-filters .mf').forEach((x) => x.classList.toggle('active', x === b));
    renderMarkers(true);
  });
});
$('map-ruta').addEventListener('change', (e) => { routeFilter = e.target.value; renderMarkers(true); });
$('map-search').addEventListener('input', (e) => {
  vehSearch = e.target.value.toLowerCase().split(/[\s,]+/).map((s) => s.trim()).filter(Boolean);
  renderMarkers(true);
});

// ---------- Conectividad y cola offline de despachos ----------
const QKEY = 'apl_pending_despachos';
function getQueue() { try { return JSON.parse(localStorage.getItem(QKEY) || '[]'); } catch { return []; } }
function setQueue(q) { localStorage.setItem(QKEY, JSON.stringify(q)); }
function enqueueDispatch(intent) { const q = getQueue(); q.push(intent); setQueue(q); updateNet(); }
function isNetworkErr(e) {
  const m = String(e?.message || e || '').toLowerCase();
  return !navigator.onLine || e instanceof TypeError
    || m.includes('failed to fetch') || m.includes('networkerror') || m.includes('load failed') || m.includes('fetch');
}
function updateNet() {
  const el = $('net-status'); if (!el) return;
  const n = getQueue().length;
  if (!navigator.onLine) {
    el.className = 'net-status off';
    el.textContent = n ? `🔴 Sin conexión · ${n} pendiente${n > 1 ? 's' : ''}` : '🔴 Sin conexión';
  } else if (n) {
    el.className = 'net-status pend';
    el.textContent = `🟡 ${n} pendiente${n > 1 ? 's' : ''}`;
  } else {
    el.className = 'net-status on';
    el.textContent = '🟢 En línea';
  }
}
let processing = false;
async function processQueue() {
  if (processing || !navigator.onLine) return;
  const q = getQueue(); if (!q.length) return;
  processing = true;
  const rest = []; let enviados = 0;
  for (const it of q) {
    try { await doDispatch(it); enviados++; }
    catch (e) { if (isNetworkErr(e)) rest.push(it); } // error lógico: ya quedó en BD, no se reintenta
  }
  setQueue(rest); processing = false; updateNet();
  if (enviados) { toast(`${enviados} despacho(s) pendiente(s) enviado(s)`, 'ok'); if (current === 'despachos') loadData(); }
}
window.addEventListener('online', () => { updateNet(); processQueue(); });
window.addEventListener('offline', updateNet);

// Sincronizar flota desde SONAR (botón en Vehículos GPS)
$('syncfleet-btn').addEventListener('click', async () => {
  const btn = $('syncfleet-btn'); const t = btn.textContent; btn.disabled = true; btn.textContent = 'Sincronizando…';
  const { data, error } = await sb.rpc('sync_moviles');
  btn.disabled = false; btn.textContent = t;
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data && data.ok) { gpsMap = null; toast(`Flota sincronizada: ${data.moviles} móviles`, 'ok'); if (current === 'vehiculosgps') loadData(); }
  else toast('No se pudo: ' + (data?.error || '?'), 'err');
});

// ---------- Administración de accesos (solo admin) ----------
$('perfil-new-btn').addEventListener('click', async () => {
  const email = (prompt('Correo del despachador:') || '').trim();
  if (!email) return;
  const nombre = (prompt('Nombre del despachador:') || '').trim();
  const pass = (prompt('Contraseña temporal (mín. 6 caracteres):', 'APL2026*PL') || '').trim();
  if (pass.length < 6) { toast('La contraseña debe tener al menos 6 caracteres', 'err'); return; }
  const { data, error } = await sb.rpc('admin_crear_despachador', { p_email: email, p_nombre: nombre, p_pass: pass });
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data?.ok) { toast('Acceso creado para ' + email, 'ok'); if (current === 'perfiles') loadData(); }
  else toast('No se pudo: ' + (data?.error || '?'), 'err');
});
$('perfil-pass-btn').addEventListener('click', async () => {
  const email = (prompt('Correo del usuario a restablecer:') || '').trim();
  if (!email) return;
  const pass = (prompt('Nueva contraseña (mín. 6 caracteres):', 'APL2026*PL') || '').trim();
  if (pass.length < 6) { toast('La contraseña debe tener al menos 6 caracteres', 'err'); return; }
  const { data, error } = await sb.rpc('admin_reset_pass', { p_email: email, p_pass: pass });
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data?.ok) toast('Contraseña restablecida para ' + email, 'ok');
  else toast('No se pudo: ' + (data?.error || '?'), 'err');
});

init();

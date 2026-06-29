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
function isAuditor() { return CTX?.rol === 'auditor'; }
function normRuta(s) { return String(s || '').toLowerCase().replace(/\s+/g, '').trim(); }
function allowedRutaSet() { return new Set((CTX?.rutas || []).map(normRuta)); }
// Tablas visibles según el rol:
//  - admin: todas
//  - despachador con tabla de puesto propia (ej. laureles): solo esa
//  - despachador sin tabla propia: las marcadas con despachador:true (despachos, filtrado por rutas)
function visibleTables() {
  if (isAdmin()) return menuOrder();
  // Auditor: solo la pantalla de Despachos (ahí audita el control de los despachos)
  if (isAuditor()) return ['despachos'];
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
// Convierte "YYYY-MM-DD" → "DD/MM/AAAA" (para mostrar la fecha del filtro)
function fechaLegible(v) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : String(v || '');
}
// Formatea un timestamp (ISO) a fecha+hora local colombiana: "DD/MM/AAAA, HH:MM"
function fmtFechaHora(v) {
  const d = new Date(v);
  if (isNaN(d)) return fmt(v);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()}, ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function chipClass(v) {
  const s = String(v || '').toUpperCase().trim();
  if (s === 'TABLA') return 'chip chip-indigo';
  if (s === 'LIBRE') return 'chip chip-violet';
  if (s === 'DESPACHADO' || s === 'ENABLED' || s === 'CERRADO' || s === 'ENCENDIDO' || s === 'SÍ' || s === 'SI' || s === 'INGRESO') return 'chip chip-green';
  if (s === 'APAGADO') return 'chip chip-gray';
  if (s === 'NO REALIZA EL VIAJE' || s === 'DISABLED' || s === 'CANCELADO' || s === 'NO') return 'chip chip-red';
  if (s === 'SALIDA') return 'chip chip-amber';
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
document.addEventListener('visibilitychange', () => { if (!document.hidden) { verificarDispositivo(); refreshContext(); checkAsistenciaPendiente(); } });

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
  await refrescarFechaServidor(); // fecha de hoy del servidor (autoridad para los despachos)
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
    sessTimer = setInterval(() => { verificarDispositivo(); refreshContext(); checkAsistenciaPendiente(); }, 45000);
  }
  buildSidebar();
  current = null;
  selectTable(visibleTables()[0] || 'despachos');
  updateNet();
  processQueue();
  checkAsistenciaPendiente(); // avisar si falta marcar el ingreso de hoy
  refrescarAlertasDocs();     // avisar de documentos vencidos / por vencer
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
  if (isAdmin() || CTX?.rol === 'despachador') addNavNotif(nav);
  addNavAction(nav, '🗺️', 'Mapa', showMapView, 'nav-mapa');
  if (isAdmin()) addNavAction(nav, '📌', 'Asignar puesto', openAsignarPuesto, 'nav-puesto');
  if (isAdmin()) addNavAction(nav, '🗂️', 'Puestos hoy', openTablero, 'nav-tablero');
  if (isAdmin()) addNavAction(nav, '📡', 'Despachos SONAR', openDsonar, 'nav-dsonar');
  const am = $('nav-mapa'); if (am) am.classList.toggle('active', currentView === 'mapa');
  buildBottomNav();
}

// Etiqueta corta para la barra inferior (espacio reducido)
function bnLabel(label) {
  const map = {
    'Inicio y fin de labores': 'Labores', 'Parque automotor': 'Parque',
    'Horarios usuarios': 'Horarios', 'Conductores SONAR': 'Conductores',
    'Vehículos GPS': 'GPS', 'Ubicaciones': 'Ubic.',
  };
  if (map[label]) return map[label];
  return label.length > 9 ? label.split(' ')[0] : label;
}

// Barra inferior (celular): los accesos más usados + 🔔 + ☰ Más (abre el cajón completo)
function buildBottomNav() {
  const bn = $('bottomnav'); if (!bn) return;
  bn.innerHTML = '';
  const vis = visibleTables();
  const showNotif = isAdmin() || CTX?.rol === 'despachador';
  const pref = CTX?.rol === 'despachador'
    ? ['asistencia', 'resumen', 'despachos']
    : ['despachos', 'resumen', 'asistencia'];
  const picked = [];
  if (CTX?.rol === 'despachador') {
    // solo la primera tabla del puesto, para dejar espacio a Labores y Resumen
    const firstOwn = (CTX.tablas || []).map((t) => t.tabla).find((t) => TABLES[t] && vis.includes(t));
    if (firstOwn) picked.push(firstOwn);
  }
  for (const k of pref) { if (vis.includes(k) && !picked.includes(k)) picked.push(k); }
  for (const k of vis) { if (!picked.includes(k)) picked.push(k); }
  const slots = picked.slice(0, showNotif ? 3 : 4);
  for (const name of slots) {
    const cfg = TABLES[name];
    const b = document.createElement('button');
    b.className = 'bn-item' + (name === current && currentView !== 'mapa' ? ' active' : '');
    b.innerHTML = `<span class="bn-ic">${cfg.icon || '•'}</span><span class="bn-lb">${esc(bnLabel(cfg.label))}</span>`;
    b.onclick = () => { selectTable(name); closeMenu(); };
    bn.appendChild(b);
  }
  if (showNotif) {
    const n = (typeof DOC_ALERTAS !== 'undefined' && DOC_ALERTAS) ? DOC_ALERTAS.length : 0;
    const b = document.createElement('button');
    b.className = 'bn-item';
    b.innerHTML = `<span class="bn-ic">🔔${n ? `<span class="bn-badge">${n}</span>` : ''}</span><span class="bn-lb">Avisos</span>`;
    b.onclick = () => { openDocPanel(); closeMenu(); };
    bn.appendChild(b);
  }
  const more = document.createElement('button');
  more.className = 'bn-item bn-more' + ($('sidebar').classList.contains('open') ? ' active' : '');
  more.innerHTML = '<span class="bn-ic">☰</span><span class="bn-lb">Más</span>';
  more.onclick = () => setMenu(!$('sidebar').classList.contains('open'));
  bn.appendChild(more);
}
function addNavAction(nav, icon, label, fn, id) {
  const b = document.createElement('button');
  b.className = 'nav-action'; if (id) b.id = id;
  b.innerHTML = `<span>${icon}</span> ${label}`;
  b.onclick = () => { fn(); closeMenu(); };
  nav.appendChild(b);
}
// Centro de notificaciones (alertas de documentos), con contador
function addNavNotif(nav) {
  const b = document.createElement('button');
  b.className = 'nav-action'; b.id = 'nav-notif';
  const n = (typeof DOC_ALERTAS !== 'undefined' && DOC_ALERTAS) ? DOC_ALERTAS.length : 0;
  b.innerHTML = `<span>🔔</span> Notificaciones${n ? ` <span class="nav-badge">${n}</span>` : ''}`;
  b.onclick = () => { openDocPanel(); closeMenu(); };
  nav.appendChild(b);
}
function setMenu(open) {
  $('sidebar').classList.toggle('open', open);
  document.getElementById('app').classList.toggle('menu-open', open);
  const s = $('scrim'); if (s) s.hidden = !open;
}
function closeMenu() { setMenu(false); }
// Cierra paneles emergentes (avisos / documentos) al cambiar de pantalla
function cerrarPanelesFlotantes() {
  const dp = $('docp-modal'); if (dp) dp.hidden = true;
  const dm = $('doc-modal'); if (dm) dm.hidden = true;
}
$('menu-toggle').addEventListener('click', () => setMenu(!$('sidebar').classList.contains('open')));
$('scrim').addEventListener('click', closeMenu);
$('app-ver').textContent = APP_VERSION;

function selectTable(name) {
  // salir de la vista de mapa si estaba activa
  currentView = 'tabla';
  document.getElementById('app').classList.remove('view-map');
  cerrarPanelesFlotantes();
  $('map-view').hidden = true;
  $('table-view').hidden = false;
  if (mapTimer) { clearInterval(mapTimer); mapTimer = null; }
  current = name; page = 0; term = ''; filters = {}; $('search').value = '';
  // Si la tabla tiene filtro de fecha (calendario), arranca mostrando el DÍA ACTUAL
  // (no "todas las fechas"): así se ve el día completo y nunca topa el límite de filas.
  const fDate = (TABLES[name].filters || []).find((f) => f.type === 'date');
  if (fDate) filters[fDate.col] = hoyServidor();
  const fMulti = (TABLES[name].filters || []).find((f) => f.type === 'multidate');
  if (fMulti) filters[`${fMulti.col}::in`] = [hoyServidor()];
  $('table-title').textContent = TABLES[name].label;
  // "Despachar" de la barra: oculto en todas partes. El despacho se hace con el botón
  // verde de cada fila, o con "+ Nuevo" (despacho manual) en Despachos.
  $('dispatch-btn').hidden = true;
  $('count-btn').hidden = !TABLES[name].dispatchable;                  // Contador: en tablas de despacho
  // Asistencia: los botones de marcación los maneja la tarjeta dinámica (abajo), no la barra
  $('marcar-in-btn').hidden = true;
  $('marcar-out-btn').hidden = true;
  actualizarEstadoAsistencia();
  $('dsonar-btn').hidden = true;   // "Despachos SONAR" (consulta puntual): oculto por ahora (sin utilidad práctica)
  $('syncfleet-btn').hidden = name !== 'vehiculosgps' || !isAdmin(); // sincronizar flota: solo admin
  $('synccond-btn').hidden = name !== 'conductores_sonar' || !isAdmin(); // sincronizar conductores: solo admin
  $('import-btn').hidden = !TABLES[name].import || !isAdmin();   // Importar: solo admin
  // Borrar día: solo admin, en las tablas por puesto (programación), no en Despachos
  $('del-day-btn').hidden = !(isAdmin() && TABLES[name].dispatchable && name !== 'despachos');
  $('perfil-new-btn').hidden = name !== 'perfiles' || !isAdmin(); // crear acceso: solo admin en Perfiles
  $('perfil-pass-btn').hidden = name !== 'perfiles' || !isAdmin();
  $('new-btn').hidden = !!TABLES[name].readonly || !!TABLES[name].noCreate || isAuditor(); // sin "+ Nuevo" donde no aplica (el auditor no crea)
  buildSidebar();
  renderFilters();
  loadData();
}

function renderFilters() {
  const cont = $('filters'); cont.innerHTML = '';
  Object.keys(_checkOptsCache).forEach((k) => delete _checkOptsCache[k]); // refresca opciones por si cambió el puesto
  const defs = TABLES[current].filters || [];
  for (const f of defs) {
    if (f.type === 'date') { // calendario propio: sombrea los días con programación cargada
      cont.appendChild(buildDateCalendar(f));
      continue;
    }
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
    if (f.type === 'multidate') {
      cont.appendChild(buildMultiDateFilter(f));
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

// Filtro de VARIAS FECHAS sueltas. Guarda filters['col::in'] = ['YYYY-MM-DD', ...]
function buildMultiDateFilter(f) {
  const key = `${f.col}::in`;
  const wrap = document.createElement('span');
  wrap.className = 'filter-md';
  const lbl = Object.assign(document.createElement('span'), { className: 'filter-lbl', textContent: f.label });
  const add = document.createElement('input');
  add.type = 'date'; add.className = 'md-add'; add.title = `Agregar fecha a ${f.label}`;
  const chips = document.createElement('span'); chips.className = 'md-chips';
  const clr = Object.assign(document.createElement('button'), { type: 'button', className: 'link-btn md-clear', textContent: 'Limpiar' });
  wrap.append(lbl, add, chips, clr);

  const sel = () => (Array.isArray(filters[key]) ? filters[key] : []);
  const render = () => {
    const arr = sel().slice().sort();
    chips.innerHTML = '';
    arr.forEach((d) => {
      const c = document.createElement('span'); c.className = 'md-chip';
      c.innerHTML = `${esc(fechaLegible(d))} <b class="md-x" data-d="${d}">✕</b>`;
      chips.appendChild(c);
    });
    clr.style.display = arr.length ? '' : 'none';
    chips.querySelectorAll('.md-x').forEach((x) => x.addEventListener('click', () => {
      filters[key] = sel().filter((d) => d !== x.dataset.d);
      if (!filters[key].length) delete filters[key];
      render(); page = 0; loadData();
    }));
  };
  add.addEventListener('change', () => {
    const d = add.value; add.value = '';
    if (!d) return;
    const arr = sel();
    if (!arr.includes(d)) { filters[key] = arr.concat(d); render(); page = 0; loadData(); }
    else render();
  });
  clr.addEventListener('click', () => { delete filters[key]; render(); page = 0; loadData(); });
  render();
  return wrap;
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
// Cierra los paneles de checklist y el calendario al hacer clic fuera
document.addEventListener('click', () => {
  document.querySelectorAll('.filter-check-panel, .cal-panel').forEach((p) => { p.hidden = true; });
});

// Calendario propio para el filtro de fecha: sombrea los días que tienen programación cargada
function buildDateCalendar(f) {
  const wrap = document.createElement('span');
  wrap.className = 'filter-cal';
  const btn = document.createElement('button');
  btn.type = 'button'; btn.className = 'cal-btn';
  const panel = document.createElement('div');
  panel.className = 'cal-panel'; panel.hidden = true;
  wrap.append(Object.assign(document.createElement('span'), { className: 'filter-lbl', textContent: f.label }), btn, panel);

  const MES = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const DOW = ['Lu', 'Ma', 'Mi', 'Ju', 'Vi', 'Sá', 'Do'];
  const pad = (n) => String(n).padStart(2, '0');
  let dias = new Set(); let cargado = false; let view = null;
  const sel = () => filters[f.col] || '';
  const refreshBtn = () => { btn.textContent = sel() ? '📅 ' + fechaLegible(sel()) : '📅 todas las fechas'; btn.classList.toggle('active', !!sel()); };
  refreshBtn();

  function initView() {
    const s = sel() || hoyServidor();
    const [y, m] = s.split('-').map(Number);
    view = { y, m: m - 1 };
  }
  async function cargarDias() {
    try { const { data } = await sb.rpc('dias_con_datos', { p_tabla: current }); dias = new Set((data || []).map((d) => d.fecha)); }
    catch (e) { dias = new Set(); }
    cargado = true;
  }
  function render() {
    panel.innerHTML = '';
    const head = document.createElement('div'); head.className = 'cal-head';
    const prev = Object.assign(document.createElement('button'), { className: 'cal-nav', textContent: '‹', type: 'button' });
    const title = Object.assign(document.createElement('span'), { className: 'cal-title', textContent: `${MES[view.m]} ${view.y}` });
    const next = Object.assign(document.createElement('button'), { className: 'cal-nav', textContent: '›', type: 'button' });
    prev.onclick = () => { view.m--; if (view.m < 0) { view.m = 11; view.y--; } render(); };
    next.onclick = () => { view.m++; if (view.m > 11) { view.m = 0; view.y++; } render(); };
    head.append(prev, title, next); panel.appendChild(head);

    const grid = document.createElement('div'); grid.className = 'cal-grid';
    DOW.forEach((d) => grid.appendChild(Object.assign(document.createElement('div'), { className: 'cal-dow', textContent: d })));
    let start = new Date(view.y, view.m, 1).getDay(); start = (start === 0) ? 6 : start - 1; // Lun=0 … Dom=6
    const ndays = new Date(view.y, view.m + 1, 0).getDate();
    for (let i = 0; i < start; i++) grid.appendChild(Object.assign(document.createElement('div'), { className: 'cal-day cal-empty' }));
    const hoy = hoyServidor();
    for (let d = 1; d <= ndays; d++) {
      const iso = `${view.y}-${pad(view.m + 1)}-${pad(d)}`;
      const cell = Object.assign(document.createElement('button'), { className: 'cal-day', textContent: d, type: 'button' });
      if (dias.has(iso)) cell.classList.add('cal-has-data');
      if (iso === hoy) cell.classList.add('cal-today');
      if (iso === sel()) cell.classList.add('cal-sel');
      cell.onclick = () => { filters[f.col] = iso; refreshBtn(); panel.hidden = true; page = 0; loadData(); };
      grid.appendChild(cell);
    }
    panel.appendChild(grid);

    const foot = document.createElement('div'); foot.className = 'cal-foot';
    const leg = document.createElement('span'); leg.className = 'cal-legend'; leg.innerHTML = '<i></i> con programación';
    const clr = Object.assign(document.createElement('button'), { className: 'link-btn', textContent: 'Todas las fechas', type: 'button' });
    clr.onclick = () => { delete filters[f.col]; refreshBtn(); panel.hidden = true; page = 0; loadData(); };
    foot.append(leg, clr); panel.appendChild(foot);
  }

  btn.addEventListener('click', async (e) => {
    e.stopPropagation();
    const open = panel.hidden;
    document.querySelectorAll('.filter-check-panel, .cal-panel').forEach((p) => { p.hidden = true; });
    if (open) {
      initView();
      if (!cargado) { btn.textContent = '📅 …'; await cargarDias(); refreshBtn(); }
      render();
      panel.hidden = false;
    }
  });
  panel.addEventListener('click', (e) => e.stopPropagation());
  return wrap;
}

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
  // Despachador y auditor: solo despachos de SUS rutas (refuerzo en UI; RLS lo garantiza en BD).
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
  if (filters['fecha']) partes.push('fecha ' + filters['fecha']);
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

// ---------- Asistencia: marcar ingreso/salida (foto obligatoria NO guardada + GPS obligatorio) ----------
// Abre la cámara y exige tomar una foto. La foto NO se guarda; solo es requisito del momento.
// ---- Foto de marcación: cámara EN VIVO (sirve en PC y celular sobre HTTPS/localhost) ----
let _fotoStream = null, _fotoResolve = null, _fotoFacing = 'user';

function _fotoStop() {
  if (_fotoStream) { _fotoStream.getTracks().forEach((t) => t.stop()); _fotoStream = null; }
  const v = $('foto-video'); if (v) v.srcObject = null;
}
function _fotoFinish(ok) {
  _fotoStop();
  const m = $('foto-modal'); if (m) m.hidden = true;
  const r = _fotoResolve; _fotoResolve = null;
  if (r) r(!!ok);
}
function _fotoSetCaptured(yes) {
  const v = $('foto-video'), pv = $('foto-preview');
  $('foto-shot').hidden = yes; $('foto-flip').hidden = yes;
  $('foto-retake').hidden = !yes; $('foto-ok').hidden = !yes;
  if (v) v.hidden = yes;
  if (pv) pv.hidden = !yes;
}
async function _fotoStart() {
  const video = $('foto-video'), status = $('foto-status');
  _fotoStop();
  status.className = 'qr-status'; status.textContent = 'Iniciando cámara…';
  try {
    _fotoStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: _fotoFacing } }, audio: false });
  } catch (e) {
    status.className = 'qr-status err';
    status.textContent = 'No se pudo abrir la cámara. Concede el permiso (candado de la barra de direcciones) e inténtalo otra vez.';
    return false;
  }
  video.srcObject = _fotoStream;
  try { await video.play(); } catch {}
  status.className = 'qr-status'; status.textContent = 'Mira a la cámara y pulsa “Capturar”.';
  return true;
}
function _fotoCapturar() {
  const v = $('foto-video'), pv = $('foto-preview');
  if (!v || !v.videoWidth) return;
  pv.width = v.videoWidth; pv.height = v.videoHeight;
  pv.getContext('2d').drawImage(v, 0, 0, pv.width, pv.height);
  _fotoSetCaptured(true);
  const status = $('foto-status'); status.className = 'qr-status'; status.textContent = '¿Se ve bien? Pulsa “Usar foto”.';
}

// Respaldo: si el navegador no tiene cámara/getUserMedia, usa el selector de archivos.
function tomarFotoArchivo() {
  return new Promise((resolve) => {
    const inp = document.createElement('input');
    inp.type = 'file'; inp.accept = 'image/*'; inp.capture = 'user'; inp.style.display = 'none';
    document.body.appendChild(inp);
    let done = false;
    const finish = (ok) => { if (done) return; done = true; try { inp.remove(); } catch (e) {} resolve(ok); };
    inp.addEventListener('change', () => finish(!!(inp.files && inp.files.length)));
    inp.click();
    window.addEventListener('focus', function onF() {
      window.removeEventListener('focus', onF);
      setTimeout(() => finish(false), 1500);
    }, { once: true });
  });
}

// Abre la cámara en vivo y obliga a capturar una foto. Resuelve true si capturó, false si canceló.
function tomarFoto() {
  const modal = $('foto-modal');
  if (!modal || !navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return tomarFotoArchivo();
  return new Promise((resolve) => {
    _fotoResolve = resolve;
    _fotoFacing = 'user';
    _fotoSetCaptured(false);
    modal.hidden = false;
    _fotoStart();
  });
}

(function wireFotoModal() {
  const x = $('foto-x'), c = $('foto-cancel'), shot = $('foto-shot'),
        re = $('foto-retake'), ok = $('foto-ok'), flip = $('foto-flip');
  if (x) x.addEventListener('click', () => _fotoFinish(false));
  if (c) c.addEventListener('click', () => _fotoFinish(false));
  if (shot) shot.addEventListener('click', _fotoCapturar);
  if (re) re.addEventListener('click', () => { _fotoSetCaptured(false); const s = $('foto-status'); s.className = 'qr-status'; s.textContent = 'Mira a la cámara y pulsa “Capturar”.'; });
  if (ok) ok.addEventListener('click', () => _fotoFinish(true));
  if (flip) flip.addEventListener('click', () => { _fotoFacing = _fotoFacing === 'user' ? 'environment' : 'user'; _fotoStart(); });
})();

function miCorreo() { return (sessionUser?.email || CTX?.email || '').toLowerCase(); }

// Calcula horas laboradas entre dos instantes (decimales, 2 cifras). Maneja cruce de medianoche.
function calcHoras(ingresoEn, salidaEn) {
  const a = new Date(ingresoEn), b = new Date(salidaEn);
  const ms = b - a;
  if (!(ms >= 0)) return null;
  return Math.round((ms / 3600000) * 100) / 100;
}

// Pasos comunes a toda marcación: foto obligatoria (no se guarda) + GPS obligatorio + confirmación.
async function pasosMarcacion(titulo, resumen, okLabel, danger) {
  const hayFoto = await tomarFoto();
  if (!hayFoto) { toast('Debes tomar la foto para continuar.', 'err'); return null; }
  const ubic = await requerirGps();
  if (!ubic) { toast('Se requiere la ubicación (GPS) para marcar.', 'err'); return null; }
  const ok = await confirmAction({ title: titulo, lead: 'Se registrará tu marcación:', message: resumen + `\nUbicación:   ${ubic}`, okLabel, danger });
  if (!ok) return null;
  return ubic;
}

// MARCAR INGRESO: crea una nueva jornada (una fila). Bloquea si ya hay una jornada abierta hoy.
async function marcarIngreso() {
  const b = $('marcar-in-btn'); if (b.dataset.busy === '1') return;
  b.dataset.busy = '1'; b.disabled = true;
  try {
    const email = miCorreo();
    await refrescarFechaServidor();
    // ¿Ya hay una jornada de hoy sin salida?
    const { data: abiertas } = await sb.from('asistencia').select('id').eq('email', email).eq('fecha', hoyServidor()).is('hora_salida', null).limit(1);
    if (abiertas && abiertas.length) { toast('Ya tienes un ingreso sin salida. Marca la salida primero.', 'err'); return; }
    const ubic = await pasosMarcacion('¿Marcar INGRESO?', `Despachador: ${CTX?.nombre || email}\nTipo:        INGRESO`, 'Marcar ingreso', false);
    if (!ubic) return;
    showBusy('Registrando ingreso…');
    const ahora = new Date();
    let res;
    try {
      res = await sb.from('asistencia').insert({
        email, nombre: CTX?.nombre || null, fecha: hoyServidor(),
        hora_ingreso: ahoraLocal().slice(11, 19), ubic_ingreso: ubic, ingreso_en: ahora.toISOString(),
      });
    } finally { hideBusy(); }
    if (res.error) { toast('Error al marcar ingreso: ' + res.error.message, 'err'); return; }
    toast('✅ Ingreso registrado', 'ok');
    const bn = $('asis-banner'); if (bn) bn.hidden = true; // ya marcó: quitar el aviso
    if (current === 'asistencia') loadData();
    actualizarEstadoAsistencia();
  } finally { b.dataset.busy = '0'; b.disabled = false; }
}

// MARCAR SALIDA de una jornada concreta (fila). Calcula y guarda las horas laboradas.
async function marcarSalida(row, btn) {
  if (btn && btn.dataset.busy === '1') return;
  if (btn) { btn.dataset.busy = '1'; btn.disabled = true; }
  try {
    if (row.hora_salida) { toast('Esta jornada ya tiene salida.', 'err'); return; }
    const ubic = await pasosMarcacion('¿Marcar SALIDA?', `Despachador: ${row.nombre || row.email}\nIngreso:     ${fmt(row.hora_ingreso) || '—'}\nTipo:        SALIDA`, 'Marcar salida', true);
    if (!ubic) return;
    showBusy('Registrando salida…');
    const ahora = new Date();
    const horas = row.ingreso_en ? calcHoras(row.ingreso_en, ahora.toISOString()) : null;
    let res;
    try {
      res = await sb.from('asistencia').update({
        hora_salida: ahoraLocal().slice(11, 19), ubic_salida: ubic, salida_en: ahora.toISOString(), horas,
      }).eq('id', row.id);
    } finally { hideBusy(); }
    if (res.error) { toast('Error al marcar salida: ' + res.error.message, 'err'); return; }
    toast(horas != null ? `✅ Salida registrada · ${horas} h` : '✅ Salida registrada', 'ok');
    if (current === 'asistencia') loadData();
    actualizarEstadoAsistencia();
  } finally { if (btn) { btn.dataset.busy = '0'; btn.disabled = false; } }
}

// Botón de la barra "Marcar salida": busca la jornada abierta de hoy y la cierra.
async function marcarSalidaBarra() {
  const b = $('marcar-out-btn'); if (b.dataset.busy === '1') return;
  b.dataset.busy = '1'; b.disabled = true;
  try {
    const { data } = await sb.from('asistencia').select('*').eq('email', miCorreo()).is('hora_salida', null)
      .order('fecha', { ascending: false }).limit(1);
    const row = (data || [])[0];
    if (!row) { toast('No tienes un ingreso pendiente de salida.', 'err'); return; }
    await marcarSalida(row, null);
  } finally { b.dataset.busy = '0'; b.disabled = false; }
}

$('marcar-in-btn').addEventListener('click', marcarIngreso);
$('marcar-out-btn').addEventListener('click', marcarSalidaBarra);

// ---- Tarjeta dinámica de asistencia: le dice al despachador qué hacer ahora ----
let _asisTimer = null;
function _pad2(n) { return String(n).padStart(2, '0'); }
function transcurrido(desdeISO) {
  const ms = Date.now() - new Date(desdeISO).getTime();
  if (!(ms >= 0)) return '0 min';
  const h = Math.floor(ms / 3600000), m = Math.floor((ms % 3600000) / 60000);
  return h ? `${h} h ${_pad2(m)} min` : `${m} min`;
}
async function actualizarEstadoAsistencia() {
  const box = $('asis-estado'); if (!box) return;
  if (_asisTimer) { clearInterval(_asisTimer); _asisTimer = null; }
  if (current !== 'asistencia' || !(CTX?.rol === 'despachador' || CTX?.rol === 'admin')) { box.hidden = true; box.innerHTML = ''; return; }
  box.hidden = false;
  box.innerHTML = '<div class="asis-card asis-todo"><div class="asis-main"><div class="asis-sub">Cargando tu jornada…</div></div></div>';
  try {
    await refrescarFechaServidor();
    const email = miCorreo();
    const { data: ab } = await sb.from('asistencia').select('*').eq('email', email).is('hora_salida', null)
      .order('ingreso_en', { ascending: false }).limit(1);
    const abierta = (ab || [])[0];
    const { data: hoyRows } = await sb.from('asistencia').select('*').eq('email', email).eq('fecha', hoyServidor())
      .order('ingreso_en', { ascending: false });
    const completas = (hoyRows || []).filter((r) => r.hora_salida);
    renderAsisCard(box, abierta, completas);
  } catch { box.innerHTML = '<div class="asis-card asis-todo"><div class="asis-main"><div class="asis-sub">No se pudo cargar tu jornada. Reintenta con ↻.</div></div></div>'; }
}
// Línea con el horario asignado de HOY (solo despachadores; viene de mi_contexto).
function horarioHoyChip() {
  if (CTX?.rol !== 'despachador') return '';
  const ini = CTX?.hora_inicio, fin = CTX?.hora_fin, pst = CTX?.puesto;
  if (ini || fin) {
    const rango = `${ini || '—'}${fin ? ' – ' + fin : ''}`;
    return `<div class="asis-horario">🕒 Horario de hoy: <b>${esc(rango)}</b>${pst ? ' · 📌 ' + esc(pst) : ''}</div>`;
  }
  if (pst) return `<div class="asis-horario">📌 Puesto de hoy: <b>${esc(pst)}</b></div>`;
  return `<div class="asis-horario asis-horario-none">🕒 Hoy no tienes un horario asignado.</div>`;
}
function renderAsisCard(box, abierta, completas) {
  const nombre = CTX?.nombre || miCorreo();
  const hor = horarioHoyChip();
  if (abierta) {
    const hi = fmt(abierta.hora_ingreso) || '—';
    box.innerHTML = `<div class="asis-card asis-en">
      <div class="asis-ic">🟢</div>
      <div class="asis-main">
        <div class="asis-title">En jornada desde las ${esc(hi)}</div>
        <div class="asis-sub">Llevas <b id="asis-trans">${transcurrido(abierta.ingreso_en)}</b> · cuando termines, marca tu <b>salida</b>.</div>
        ${hor}
      </div>
      <button class="btn btn-danger asis-big" id="asis-out">🔴 Marcar salida</button>
    </div>`;
    $('asis-out').onclick = () => marcarSalidaBarra();
    if (abierta.ingreso_en) {
      _asisTimer = setInterval(() => {
        const t = $('asis-trans');
        if (t) t.textContent = transcurrido(abierta.ingreso_en);
        else if (_asisTimer) { clearInterval(_asisTimer); _asisTimer = null; }
      }, 30000);
    }
  } else if (completas.length) {
    const ult = completas[0];
    const tot = Math.round(completas.reduce((s, r) => s + (r.horas || 0), 0) * 100) / 100;
    box.innerHTML = `<div class="asis-card asis-done">
      <div class="asis-ic">✅</div>
      <div class="asis-main">
        <div class="asis-title">¡Jornada completada!</div>
        <div class="asis-sub">Hoy: ${completas.length} jornada(s) · total <b>${tot} h</b> · última salida ${esc(fmt(ult.hora_salida) || '')}.</div>
        ${hor}
      </div>
      <button class="btn asis-big" id="asis-in2">🟢 Iniciar otra jornada</button>
    </div>`;
    $('asis-in2').onclick = () => marcarIngreso();
  } else {
    box.innerHTML = `<div class="asis-card asis-todo">
      <div class="asis-ic">👋</div>
      <div class="asis-main">
        <div class="asis-title">Hola, ${esc(nombre)}</div>
        <div class="asis-sub">Aún no has marcado tu <b>inicio de labores</b> de hoy.</div>
        ${hor}
      </div>
      <button class="btn btn-primary asis-big" id="asis-in">🟢 Marcar ingreso</button>
    </div>`;
    $('asis-in').onclick = () => marcarIngreso();
  }
}

// Aviso visual (no bloqueante): si el despachador no ha marcado su INGRESO de hoy, muestra el banner.
async function checkAsistenciaPendiente() {
  const banner = $('asis-banner'); if (!banner) return;
  if (CTX?.rol !== 'despachador') { banner.hidden = true; return; } // solo despachadores
  try {
    const { data } = await sb.from('asistencia').select('id').eq('email', miCorreo()).eq('fecha', hoyServidor()).limit(1);
    banner.hidden = !!(data && data.length); // si ya marcó hoy → ocultar; si no → mostrar
  } catch { /* si falla la consulta, no estorbar */ }
}
$('asis-banner-btn').addEventListener('click', async () => {
  const b = $('asis-banner-btn'); if (b.dataset.busy === '1') return;
  b.dataset.busy = '1';
  try { await marcarIngreso(); } finally { b.dataset.busy = '0'; }
  checkAsistenciaPendiente();
});

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
  $('pst-tipo').value = 'rango';
  aplicarModoAsig();
  await updatePstInfo();
  $('pst-modal').hidden = false;
}
const PST_HELP = {
  rango: 'Asigna el puesto solo en el rango de fechas indicado.',
  fijo: 'El despachador queda en este puesto de lunes a sábado, sin recargar. Deja el puesto vacío para quitarlo.',
  domingo: 'El despachador queda en este puesto los domingos y los festivos de Colombia. Deja el puesto vacío para quitarlo.',
};
// Modo de asignación: las fechas solo aplican al modo "rango"
function aplicarModoAsig() {
  const tipo = $('pst-tipo').value;
  const usaFechas = tipo === 'rango';
  $('pst-desde').disabled = !usaFechas;
  $('pst-hasta').disabled = !usaFechas;
  $('pst-desde').closest('.field').classList.toggle('field-off', !usaFechas);
  $('pst-hasta').closest('.field').classList.toggle('field-off', !usaFechas);
  $('pst-tipo-help').textContent = PST_HELP[tipo] || '';
  $('pst-save').textContent = usaFechas ? 'Asignar' : 'Guardar';
}
$('pst-tipo').addEventListener('change', () => { aplicarModoAsig(); updatePstInfo(); });
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
  const info = $('pst-info');
  const tipo = $('pst-tipo').value;
  if (!emails.length) { info.hidden = true; return; }
  if (tipo === 'fijo' || tipo === 'domingo') {
    const cuando = tipo === 'fijo' ? 'de lunes a sábado' : 'los domingos y festivos';
    info.hidden = false; info.className = 'field full sonar-info';
    info.textContent = `Quedará para ${emails.length} despachador(es) ${cuando} (sin recargar). Deja el puesto vacío para quitarlo.`;
    return;
  }
  const dias = pstDiasRango();
  if (!dias) { info.hidden = true; return; }
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
  const puesto = $('pst-puesto').value;
  const tipo = $('pst-tipo').value;

  // ----- Modo recurrente: fijo entre semana o fijo domingos/festivos (no usa fechas) -----
  if (tipo === 'fijo' || tipo === 'domingo') {
    if (!emails.length) { err.textContent = 'Selecciona al menos un despachador.'; err.hidden = false; return; }
    const quitar = !puesto;
    const cuando = tipo === 'fijo' ? 'de lunes a sábado' : 'los domingos y festivos';
    const ok = await confirmAction({
      title: quitar ? '¿Quitar puesto recurrente?' : '¿Guardar puesto recurrente?',
      lead: quitar ? `Estos despachadores dejarán de tener puesto ${cuando}:` : `Estos despachadores quedarán en este puesto ${cuando}:`,
      message: `Despachadores: ${emails.length}\nPuesto:        ${puesto || '— (sin asignar) —'}\nAplica:        ${cuando}`,
      okLabel: quitar ? 'Quitar' : 'Guardar',
    });
    if (!ok) return;
    btn.dataset.busy = '1'; btn.disabled = true;
    let res;
    try { res = await sb.rpc('admin_set_puesto_recurrente', { p_emails: emails, p_puesto: puesto || null, p_tipo: tipo }); }
    finally { btn.dataset.busy = '0'; btn.disabled = false; }
    if (res.error) { err.textContent = res.error.message; err.hidden = false; return; }
    const r = $('pst-result'); r.hidden = false; r.className = 'sonar-result ok';
    r.textContent = quitar
      ? `✅ Puesto ${cuando} quitado a ${res.data} despachador(es).`
      : `✅ "${puesto}" para ${res.data} despachador(es) ${cuando} (sin recargar).`;
    toast('Asignación guardada', 'ok');
    if (current === 'horarios') loadData();
    return;
  }

  // ----- Modo por fechas (rango) -----
  const desde = $('pst-desde').value, hasta = $('pst-hasta').value;
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

// ---------- Tablero: quién está en cada puesto ----------
async function openTablero() {
  $('tab-fecha').value = hoyServidor();
  $('tab-modal').hidden = false;
  await renderTablero();
}
function closeTablero() { $('tab-modal').hidden = true; }
$('tab-close').addEventListener('click', closeTablero);
$('tab-cancel').addEventListener('click', closeTablero);
$('tab-refresh').addEventListener('click', renderTablero);
$('tab-fecha').addEventListener('change', renderTablero);

async function renderTablero() {
  const body = $('tab-body');
  const fecha = $('tab-fecha').value || hoyServidor();
  body.innerHTML = '<p class="tab-load">Cargando…</p>';
  const [pf, hr, pp, td] = await Promise.all([
    sb.from('perfiles').select('email,nombre,puesto_fijo,puesto_domingo').eq('rol', 'despachador').eq('activo', true).order('nombre'),
    sb.from('horarios').select('email,nombre,observacion').eq('fecha', fecha),
    sb.from('puestos').select('nombre').eq('activo', true).order('nombre'),
    sb.rpc('tipo_dia', { d: fecha }),
  ]);
  if (pf.error || hr.error || pp.error) {
    body.innerHTML = `<p class="error">${(pf.error || hr.error || pp.error).message}</p>`; return;
  }
  const tipoDia = td.data || 'habil';       // 'habil' | 'domingo' | 'festivo'
  const esDomFest = tipoDia !== 'habil';
  // horario del día por correo
  const diaPorEmail = {};
  for (const h of (hr.data || [])) {
    const k = (h.email || '').toLowerCase();
    if ((h.observacion || '').trim()) diaPorEmail[k] = h.observacion.trim();
  }
  // resolver puesto de cada despachador: horario del día > recurrente (domingo/festivo o entre semana)
  const porPuesto = {}; // lowerNombrePuesto -> { puesto, items:[{nombre, fuente}] }
  const sinPuesto = [];
  for (const d of (pf.data || [])) {
    const k = (d.email || '').toLowerCase();
    const dia = diaPorEmail[k];
    const recurrente = esDomFest ? (d.puesto_domingo || '').trim() : (d.puesto_fijo || '').trim();
    const puesto = dia || recurrente;
    const nombre = d.nombre || d.email;
    if (!puesto) { sinPuesto.push(nombre); continue; }
    const fuente = dia ? 'día' : (esDomFest ? 'dom/fest' : 'fijo');
    const pk = puesto.toLowerCase();
    (porPuesto[pk] = porPuesto[pk] || { puesto, items: [] }).items.push({ nombre, fuente });
  }
  // tarjetas: primero los puestos activos (aunque estén vacíos), luego puestos usados que no están activos
  const activos = (pp.data || []).map((p) => p.nombre);
  const usados = new Set(Object.keys(porPuesto));
  const cards = [];
  let cubiertos = 0;
  for (const nom of activos) {
    const pk = nom.toLowerCase();
    const grp = porPuesto[pk];
    usados.delete(pk);
    if (grp && grp.items.length) cubiertos++;
    cards.push(cardPuesto(nom, grp ? grp.items : [], false));
  }
  for (const pk of usados) { // puestos asignados pero no activos / sin catálogo
    cards.push(cardPuesto(porPuesto[pk].puesto, porPuesto[pk].items, true));
  }

  const aviso = esDomFest
    ? `<div class="tab-domfest">${tipoDia === 'festivo' ? '🎉 Festivo' : '🟡 Domingo'} · servicio dominical (se usa el puesto de domingos y festivos)</div>`
    : '';
  const resumen = aviso + `<div class="tab-resumen">📅 ${fechaLegible(fecha)} · ${cubiertos}/${activos.length} puestos con gente`
    + ` · ${sinPuesto.length} despachador(es) sin puesto</div>`;
  const sinHtml = sinPuesto.length
    ? `<div class="tab-card tab-sin"><div class="tab-card-h">⚠️ Sin puesto (${sinPuesto.length})</div>`
      + `<div class="tab-card-b">${sinPuesto.map((n) => `<span class="tab-chip">${esc(n)}</span>`).join('')}</div></div>`
    : '';
  body.innerHTML = resumen + '<div class="tab-grid">' + cards.join('') + '</div>' + sinHtml;
}
function cardPuesto(nombre, items, fueraCatalogo) {
  const vacio = !items.length;
  const cuerpo = vacio
    ? '<span class="tab-nadie">— nadie —</span>'
    : items.map((it) => {
      const cls = it.fuente === 'fijo' ? 'fijo' : it.fuente === 'dom/fest' ? 'domfest' : 'dia';
      return `<span class="tab-chip">${esc(it.nombre)}<i class="tab-src tab-src-${cls}">${it.fuente}</i></span>`;
    }).join('');
  return `<div class="tab-card${vacio ? ' tab-empty' : ''}${fueraCatalogo ? ' tab-extra' : ''}">`
    + `<div class="tab-card-h">📌 ${esc(nombre)}${fueraCatalogo ? ' <em>(no activo)</em>' : ''} <b>${items.length}</b></div>`
    + `<div class="tab-card-b">${cuerpo}</div></div>`;
}

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
  refrescarFechaServidor(); // mantiene al día la fecha del servidor (sin bloquear el render)
  $('loading').hidden = false; $('empty').hidden = true;
  // Día completo: si hay un día seleccionado en el calendario, se muestra TODA la
  // programación de ese día sin paginar.
  const diaSel = !!filters['fecha'] && (cfg.filters || []).some((f) => f.col === 'fecha' && f.type === 'date');
  const from = page * PAGE_SIZE, to = from + PAGE_SIZE - 1;

  let qy = sb.from(current).select(cfg.select, { count: 'exact' })
    .order(cfg.defaultOrder.col, { ascending: cfg.defaultOrder.asc, nullsFirst: false });
  if (cfg.defaultOrder.then) { // orden secundario (ej. desempatar por hora dentro del mismo día)
    qy = qy.order(cfg.defaultOrder.then.col, { ascending: cfg.defaultOrder.then.asc, nullsFirst: false });
  }
  qy = diaSel ? qy.range(0, 4999) : qy.range(from, to); // día completo trae todo; si no, paginado

  qy = applyQueryFilters(qy);

  const { data, error, count } = await qy;
  $('loading').hidden = true;
  if (error) { toast('Error al cargar: ' + error.message, 'err'); return; }
  // Si la tabla tiene columna de QR, asegura el generador antes de pintar
  if ((cfg.columns || []).some((c) => c.qr)) { try { await ensureQRGen(); await ensureLogo(); } catch { /* */ } }
  renderTable(cfg, data || [], count || 0, diaSel);
}

// Íconos SVG (se ven iguales en Android/escritorio, sin depender de emojis)
const ICON = {
  send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22 11 13 2 9z"/></svg>',
  ban: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6 18.4 18.4"/></svg>',
  edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M6 6l1 14h10l1-14"/></svg>',
};

function renderTable(cfg, rows, count, diaSel = false) {
  const head = $('thead-row'); head.innerHTML = '';
  // Columnas de auditoría (auditCol): solo las ven el admin y el auditor; al despachador le sobran
  const cols = cfg.columns.filter((c) => !(c.auditCol && !isAdmin() && !isAuditor()));
  // En móvil solo se muestran las columnas marcadas con m:true (si la tabla define alguna)
  const hasMobile = cols.some((c) => c.m);
  cols.forEach((c) => {
    const th = document.createElement('th');
    th.textContent = c.label;
    if (hasMobile && !c.m) th.className = 'col-hide';
    head.appendChild(th);
  });
  if (!cfg.readonly || cfg.asistenciaMarcar) head.appendChild(Object.assign(document.createElement('th'), { textContent: 'Acciones', className: 'col-act' }));

  const body = $('tbody'); body.innerHTML = '';
  $('empty').hidden = rows.length > 0;

  for (const row of rows) {
    const tr = document.createElement('tr');
    for (const c of cols) {
      const td = document.createElement('td');
      td.dataset.label = c.label;
      if (hasMobile && !c.m) td.className = 'col-hide';
      // Columna de QR: dibuja el QR del campo indicado (ej. la placa) y al tocarlo lo amplía
      if (c.qr) {
        const code = row[c.qr];
        if (code && window.qrcode) {
          const cv = qrCanvas(code, 2, 1);
          cv.className = 'qr-cell';
          cv.title = 'Ver / imprimir QR · ' + code;
          cv.addEventListener('click', () => openQrVehiculo(code));
          td.appendChild(cv);
        } else {
          td.textContent = code ? '—' : '';
        }
        tr.appendChild(td);
        continue;
      }
      // Columna de gestión de documentos (solo admin): botón que abre el gestor del vehículo
      if (c.docsbtn) {
        if (isAdmin()) {
          const b = Object.assign(document.createElement('button'), {
            className: 'act act-edit', innerHTML: '📄', title: 'Documentos / vencimientos',
          });
          b.onclick = () => openDocsVehiculo(row);
          td.appendChild(b);
        }
        tr.appendChild(td);
        continue;
      }
      const val = c.path ? getPath(row, c.path) : row[c.key];
      if (c.maps && val && /-?\d+\.\d+/.test(String(val))) {
        td.innerHTML = `<a href="https://www.google.com/maps?q=${encodeURIComponent(String(val))}" target="_blank" rel="noopener" class="maps-link" title="${esc(String(val))}">📍 Ver</a>`;
      } else if (c.dt && val) {
        td.textContent = fmtFechaHora(val); // fecha+hora local legible (ej. auditado el)
      } else if (c.band) {
        const b = docBand(val);
        td.innerHTML = `<span class="doc-chip ${b.cls}" title="${b.dias == null ? 'Sin dato' : b.dias < 0 ? 'Vencido hace ' + (-b.dias) + ' día(s)' : 'Vence en ' + b.dias + ' día(s)'}">${esc(b.txt)}</span>`;
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
      // La fecha es clave: solo se opera el día actual. No se despacha/cancela/edita un viaje
      // de un día anterior (pasada) NI de un día futuro (adelantada).
      const frow = row.fecha ? String(row.fecha).slice(0, 10) : '';
      const esPasada = !!(cfg.dispatchable && frow && frow < hoyServidor());
      const esFutura = !!(cfg.dispatchable && frow && frow > hoyServidor());
      if (locked) {
        act.appendChild(Object.assign(document.createElement('span'), {
          className: 'lock-badge', textContent: '🔒', title: cfg.lockedHint || 'Bloqueado',
        }));
      } else {
        if (cfg.dispatchable && !isAuditor()) { // el auditor no despacha ni cancela: solo audita
          const dsp = Object.assign(document.createElement('button'), { className: 'act act-go', innerHTML: ICON.send });
          if (row.sonar_regid) {
            dsp.title = 'Ya despachado (regId ' + row.sonar_regid + ')';
            dsp.disabled = true;
          } else if (esPasada) {
            dsp.title = 'Fecha ya pasada: no se puede despachar';
            dsp.disabled = true;
          } else if (esFutura) {
            dsp.title = 'Fecha adelantada: solo se despacha el día actual';
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
          } else if (esFutura) {
            can.title = 'Fecha adelantada: solo se cancela el día actual';
            can.disabled = true;
          } else {
            can.title = 'Cancelar en SONAR';
            can.onclick = () => openCancelar(row);
          }
          act.appendChild(can);
        }
        // Editar: el admin siempre; el auditor también (para auditar, incluso fechas pasadas).
        // El despachador solo despacha/cancela.
        if (isAdmin() || isAuditor()) {
          const ed = Object.assign(document.createElement('button'), { className: 'act act-edit', innerHTML: ICON.edit });
          // No se edita una fecha adelantada (futura). El auditor sí audita días anteriores.
          if (esFutura) {
            ed.title = 'Fecha adelantada: aún no se puede editar';
            ed.disabled = true;
          } else if (esPasada && !isAuditor()) {
            ed.title = 'Fecha ya pasada: no se puede editar';
            ed.disabled = true;
          } else {
            ed.title = isAuditor() ? 'Auditar despacho' : 'Editar';
            ed.onclick = () => openEditor(row);
          }
          act.appendChild(ed);
          // Eliminar: solo admin (el auditor no elimina)
          if (isAdmin() && !cfg.noDelete) {
            const del = Object.assign(document.createElement('button'), { className: 'act act-del', innerHTML: ICON.trash, title: 'Eliminar' });
            del.onclick = () => deleteRow(row);
            act.appendChild(del);
          }
        }
      }
      tr.appendChild(act);
    } else if (cfg.asistenciaMarcar) {
      // Asistencia: botón por fila para marcar la SALIDA de una jornada abierta (sin salida aún)
      const act = document.createElement('td');
      act.className = 'row-actions'; act.dataset.label = 'Acciones';
      if (!row.hora_salida) {
        const out = Object.assign(document.createElement('button'), { className: 'btn btn-sm btn-danger', textContent: '🔴 Marcar salida' });
        out.onclick = () => marcarSalida(row, out);
        act.appendChild(out);
      } else {
        act.appendChild(Object.assign(document.createElement('span'), { className: 'chip chip-green', textContent: 'Jornada cerrada' }));
      }
      tr.appendChild(act);
    }
    body.appendChild(tr);
  }

  const total = count;
  if (diaSel) { // día completo: sin paginación, se ve toda la programación del día
    $('page-info').textContent = `${total} programados (día completo)`;
    $('prev-btn').disabled = true; $('next-btn').disabled = true;
    $('prev-btn').hidden = true; $('next-btn').hidden = true;
  } else {
    $('prev-btn').hidden = false; $('next-btn').hidden = false;
    const start = total === 0 ? 0 : page * PAGE_SIZE + 1;
    const end = Math.min((page + 1) * PAGE_SIZE, total);
    $('page-info').textContent = `${start}–${end} de ${total}`;
    $('prev-btn').disabled = page === 0;
    $('next-btn').disabled = end >= total;
  }
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

/* ===== Lector de QR del carnet del conductor (campos sonardrv con qr:true) ===== */
// Pone un botón "📷 Escanear QR", un visor bloqueado para lo escaneado y un check
// "Elegir de la lista (sin QR)" que SOLO el usuario marca para escoger a mano.
// Escaneado  = check DESMARCADO + conductor bloqueado (no editable).
// Manual     = check MARCADO + lista desplegable editable.
function attachQrScanner(sel) {
  const row = document.createElement('div');
  row.className = 'drv-row';
  sel.parentNode.insertBefore(row, sel);
  row.appendChild(sel); // enhanceSelect envolverá el select en .combo dentro de esta fila

  const btn = document.createElement('button');
  btn.type = 'button'; btn.className = 'qr-btn'; btn.innerHTML = '📷 Escanear QR';
  btn.title = 'Escanear el carnet del conductor';
  btn.addEventListener('click', () => scanConductorToSelect(sel));
  row.appendChild(btn);

  // Visor de solo lectura: muestra el conductor escaneado, bloqueado.
  const locked = document.createElement('div');
  locked.className = 'qr-locked';
  const lockedName = document.createElement('span'); lockedName.className = 'qr-locked-name';
  const rescan = document.createElement('button');
  rescan.type = 'button'; rescan.className = 'qr-rescan'; rescan.textContent = '↻ Reescanear';
  rescan.addEventListener('click', () => scanConductorToSelect(sel));
  locked.append(Object.assign(document.createElement('span'), { className: 'qr-lock-ico', textContent: '🔒' }), lockedName, rescan);
  row.appendChild(locked);

  // Check para escoger manualmente (sin QR). Arranca DESMARCADO siempre.
  const toggle = document.createElement('label');
  toggle.className = 'qr-toggle';
  const cb = document.createElement('input'); cb.type = 'checkbox';
  toggle.append(cb, document.createTextNode(' Elegir de la lista (sin QR)'));
  row.parentNode.insertBefore(toggle, row);

  const apply = () => {
    const manual = cb.checked;
    const hasVal = !!sel.value;
    const combo = row.querySelector('.combo') || sel;
    combo.classList.toggle('hidden-field', !manual);        // lista: solo en modo manual
    btn.classList.toggle('hidden-field', manual || hasVal); // botón QR: solo si manual=off y aún sin conductor
    locked.classList.toggle('hidden-field', manual || !hasVal); // visor bloqueado: escaneado y sin manual
    if (hasVal && !manual) lockedName.textContent = sel.selectedOptions[0]?.textContent || sel.value;
  };
  cb.addEventListener('change', apply);
  setTimeout(apply, 0); // tras enhanceSelect (ya existe el .combo)
  sel._qrApply = apply;
}

// Normaliza nombres para comparar (sin tildes, minúsculas, espacios colapsados).
function normNombre(s) {
  return String(s || '').normalize('NFD').replace(/[̀-ͯ]/g, '')
    .toLowerCase().replace(/\s+/g, ' ').trim();
}

// Escanea el QR (que trae el NOMBRE) y selecciona el conductor que coincida.
async function scanConductorToSelect(sel) {
  const text = await openQrScanner();
  if (!text) return; // cancelado o sin lectura
  const target = normNombre(text);
  const opts = [...sel.options].filter((o) => o.value);
  let match = opts.find((o) => normNombre(o.value) === target);
  if (!match) match = opts.find((o) => normNombre(o.value).includes(target) || target.includes(normNombre(o.value)));
  if (!match) { toast('No encontré "' + text + '" en Conductores SONAR.', 'err'); return; }
  sel.value = match.value;
  sel.dispatchEvent(new Event('change', { bubbles: true }));
  if (sel._comboSync) sel._comboSync();
  if (sel._qrApply) sel._qrApply(); // muestra el conductor escaneado, bloqueado
  toast('Conductor: ' + match.value, 'ok');
}

let qrStream = null, qrRAF = null, qrDetector = null, qrResolve = null;

function ensureJsQR() {
  if (window.jsQR) return Promise.resolve();
  return new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = 'js/jsqr.min.js'; s.onload = res; s.onerror = rej;
    document.head.appendChild(s);
  });
}

function stopQr() {
  if (qrRAF) { cancelAnimationFrame(qrRAF); qrRAF = null; }
  if (qrStream) { qrStream.getTracks().forEach((t) => t.stop()); qrStream = null; }
  const v = $('qr-video'); if (v) v.srcObject = null;
}

function finishQr(text) {
  stopQr();
  $('qr-modal').hidden = true;
  const r = qrResolve; qrResolve = null;
  if (r) r(text || null);
}

// Abre la cámara, lee un QR y resuelve con su texto (o null si se cancela).
function openQrScanner() {
  const modal = $('qr-modal'), video = $('qr-video'), status = $('qr-status');
  status.className = 'qr-status'; status.textContent = 'Iniciando cámara…';
  modal.hidden = false;
  return new Promise((resolve) => {
    qrResolve = resolve;
    (async () => {
      try {
        qrStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { ideal: 'environment' } } });
      } catch (e) {
        status.className = 'qr-status err';
        status.textContent = 'No se pudo abrir la cámara. Concede el permiso e inténtalo de nuevo.';
        return; // el usuario cierra con Cancelar
      }
      video.srcObject = qrStream;
      try { await video.play(); } catch {}
      status.className = 'qr-status'; status.textContent = 'Apunta la cámara al QR del carnet…';

      // Decodificador: BarcodeDetector nativo (Android) o jsQR como respaldo.
      let useNative = false;
      if ('BarcodeDetector' in window) {
        try {
          const fmts = await window.BarcodeDetector.getSupportedFormats();
          if (fmts.includes('qr_code')) { qrDetector = new window.BarcodeDetector({ formats: ['qr_code'] }); useNative = true; }
        } catch {}
      }
      if (!useNative) {
        try { await ensureJsQR(); } catch {
          status.className = 'qr-status err'; status.textContent = 'No se pudo cargar el lector. Revisa la conexión.'; return;
        }
      }

      const canvas = document.createElement('canvas');
      const ctx = canvas.getContext('2d', { willReadFrequently: true });
      const tick = async () => {
        if (modal.hidden || !qrStream) return;
        if (video.readyState >= 2 && video.videoWidth) {
          let text = null;
          try {
            if (useNative) {
              const codes = await qrDetector.detect(video);
              if (codes && codes.length) text = codes[0].rawValue;
            } else if (window.jsQR) {
              canvas.width = video.videoWidth; canvas.height = video.videoHeight;
              ctx.drawImage(video, 0, 0, canvas.width, canvas.height);
              const img = ctx.getImageData(0, 0, canvas.width, canvas.height);
              const r = window.jsQR(img.data, img.width, img.height, { inversionAttempts: 'dontInvert' });
              if (r) text = r.data;
            }
          } catch {}
          if (text && text.trim()) { finishQr(text.trim()); return; }
        }
        qrRAF = requestAnimationFrame(tick);
      };
      qrRAF = requestAnimationFrame(tick);
    })();
  });
}

(function wireQrModal() {
  const x = $('qr-x'), c = $('qr-cancel');
  if (x) x.addEventListener('click', () => finishQr(null));
  if (c) c.addEventListener('click', () => finishQr(null));
})();

/* ===== Generador de QR (qrcode-generator) para los vehículos ===== */
function ensureQRGen() {
  if (window.qrcode) return Promise.resolve();
  return new Promise((res, rej) => {
    const s = document.createElement('script');
    s.src = 'js/qrcode.min.js'; s.onload = res; s.onerror = rej;
    document.head.appendChild(s);
  });
}
// Logo del centro (precargado una vez)
let _logoImg = null, _logoTried = false;
function ensureLogo() {
  if (_logoImg || _logoTried) return Promise.resolve(_logoImg);
  return new Promise((res) => {
    const img = new Image();
    img.onload = () => { _logoImg = img; res(img); };
    img.onerror = () => { _logoTried = true; res(null); };
    img.src = 'icons/logo.png';
  });
}
function _roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}
// Dibuja el QR del texto en un <canvas> (corrección H) con el logo al centro.
function qrCanvas(text, scale = 4, margin = 2, withLogo = true) {
  const qr = window.qrcode(0, 'H'); // alta corrección: tolera el logo en el centro
  qr.addData(String(text)); qr.make();
  const n = qr.getModuleCount();
  const px = (n + margin * 2) * scale;
  const cv = document.createElement('canvas'); cv.width = cv.height = px;
  const ctx = cv.getContext('2d');
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, px, px);
  ctx.fillStyle = '#111';
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) {
    if (qr.isDark(r, c)) ctx.fillRect((c + margin) * scale, (r + margin) * scale, scale, scale);
  }
  if (withLogo && _logoImg) {
    const ls = Math.round(px * 0.24);              // tamaño del logo (~24%)
    const pad = Math.max(2, Math.round(ls * 0.16)); // margen blanco alrededor
    const x = Math.round((px - ls) / 2), y = Math.round((px - ls) / 2);
    ctx.fillStyle = '#fff';
    _roundRect(ctx, x - pad, y - pad, ls + pad * 2, ls + pad * 2, Math.round(ls * 0.22));
    ctx.fill();
    ctx.drawImage(_logoImg, x, y, ls, ls);
  }
  return cv;
}
// Modal: QR ampliado del vehículo (la placa), con imprimir y descargar.
function openQrVehiculo(placa) {
  if (!placa) return;
  const cont = $('qrv-img'); cont.innerHTML = '';
  cont.appendChild(qrCanvas(placa, 8, 2));
  $('qrv-placa').textContent = placa;
  $('qrv-modal').dataset.placa = placa;
  $('qrv-modal').hidden = false;
}
function closeQrVehiculo() { $('qrv-modal').hidden = true; }
$('qrv-x').addEventListener('click', closeQrVehiculo);
$('qrv-cerrar').addEventListener('click', closeQrVehiculo);
$('qrv-descargar').addEventListener('click', () => {
  const placa = $('qrv-modal').dataset.placa; if (!placa) return;
  const a = document.createElement('a');
  a.href = qrCanvas(placa, 12, 3).toDataURL('image/png');
  a.download = `QR-${placa}.png`; a.click();
});
$('qrv-imprimir').addEventListener('click', () => {
  const placa = $('qrv-modal').dataset.placa; if (!placa) return;
  const url = qrCanvas(placa, 12, 3).toDataURL('image/png');
  const w = window.open('', '_blank');
  if (!w) { toast('Permite las ventanas emergentes para imprimir.', 'err'); return; }
  w.document.write(`<!doctype html><html><head><title>QR ${placa}</title></head>`
    + `<body style="margin:0;height:100vh;display:flex;flex-direction:column;align-items:center;justify-content:center;font-family:sans-serif">`
    + `<img src="${url}" style="width:280px;height:280px"><div style="font-size:26px;font-weight:800;margin-top:10px">${placa}</div>`
    + `<script>window.onload=function(){window.print()}<\/script></body></html>`);
  w.document.close();
});

/* ===== Vencimientos de documentos (SOAT, tecnomecánica, tarjeta de operación) ===== */
const DOC_TIPOS = [
  { key: 'soat', label: 'SOAT', col: 'vence_soat', num: 'num_soat' },
  { key: 'tecnomecanica', label: 'Tecnomecánica', col: 'vence_tecnomecanica', num: 'num_tecnomecanica' },
  { key: 'tarjeta_operacion', label: 'Tarjeta de operación', col: 'vence_tarjeta_operacion', num: 'num_tarjeta_operacion' },
];
// Franja/semáforo según los días que faltan: vencido / ≤10 / ≤15 / ≤30 (mes) / vigente
function docBand(fecha) {
  if (!fecha) return { cls: 'doc-sin', txt: '—', nivel: 9, dias: null };
  const f = String(fecha).slice(0, 10);
  const dias = Math.round((new Date(f + 'T00:00:00') - new Date(hoyServidor() + 'T00:00:00')) / 86400000);
  if (dias < 0) return { cls: 'doc-venc', txt: fechaLegible(f), nivel: 0, dias };
  if (dias <= 10) return { cls: 'doc-p10', txt: fechaLegible(f), nivel: 1, dias };
  if (dias <= 15) return { cls: 'doc-p15', txt: fechaLegible(f), nivel: 2, dias };
  if (dias <= 30) return { cls: 'doc-p30', txt: fechaLegible(f), nivel: 3, dias };
  return { cls: 'doc-ok', txt: fechaLegible(f), nivel: 4, dias };
}
const nivelEsAlerta = (n) => n <= 3; // vencido o por vencer (≤30)
function fechaMenosDias(n) { const d = new Date(hoyServidor() + 'T00:00:00'); d.setDate(d.getDate() - n); return d.toISOString().slice(0, 10); }

// ---- Gestor de documentos del vehículo (admin): editar fechas, adjuntar PDF/foto, historial ----
let DOC_VEH = null;
// Llena el selector de tipo. Si soloKeys viene, limita a esos documentos (los de alerta).
function setDocTipoOpciones(soloKeys) {
  const sel = $('doc-tipo');
  const allow = (soloKeys && soloKeys.length) ? DOC_TIPOS.filter((t) => soloKeys.includes(t.key)) : DOC_TIPOS;
  sel.innerHTML = allow.map((t) => `<option value="${t.key}">${esc(t.label)}</option>`).join('');
}
// soloKeys (opcional): restringe la edición a los documentos vencidos/por vencer (desde Avisos).
async function openDocsVehiculo(row, soloKeys) {
  DOC_VEH = row;
  $('doc-veh').textContent = `${row.numero_interno || ''} · ${row.placa || ''}`;
  $('doc-err').hidden = true;
  setDocTipoOpciones(soloKeys);
  $('doc-obs').value = ''; $('doc-file').value = '';
  prefillDoc();
  renderDocEstados(row, soloKeys);
  $('doc-modal').hidden = false;
  await loadDocHist(row.id);
}
function prefillDoc() {
  const t = DOC_TIPOS.find((x) => x.key === $('doc-tipo').value);
  $('doc-fecha').value = DOC_VEH && DOC_VEH[t.col] ? String(DOC_VEH[t.col]).slice(0, 10) : '';
  $('doc-num').value = (DOC_VEH && DOC_VEH[t.num]) || '';
}
$('doc-tipo').addEventListener('change', prefillDoc);
function renderDocEstados(row, soloKeys) {
  const cont = $('doc-estado'); cont.innerHTML = '';
  const tipos = (soloKeys && soloKeys.length) ? DOC_TIPOS.filter((t) => soloKeys.includes(t.key)) : DOC_TIPOS;
  for (const t of tipos) {
    const b = docBand(row[t.col]);
    const d = document.createElement('div'); d.className = 'doc-est-item';
    d.innerHTML = `<span class="doc-est-lbl">${t.label}</span><span class="doc-chip ${b.cls}">${esc(b.txt)}</span>`;
    cont.appendChild(d);
  }
}
function closeDocs() { $('doc-modal').hidden = true; DOC_VEH = null; }
$('doc-x').addEventListener('click', closeDocs);
$('doc-cancel').addEventListener('click', closeDocs);
async function loadDocHist(vehId) {
  const cont = $('doc-hist'); cont.innerHTML = '<p class="tab-load">Cargando…</p>';
  const { data, error } = await sb.from('vehiculo_documentos').select('*').eq('vehiculo_id', vehId)
    .order('creado_en', { ascending: false }).limit(100);
  if (error) { cont.innerHTML = `<p class="error">${error.message}</p>`; return; }
  if (!data.length) { cont.innerHTML = '<p class="doc-empty">Sin historial todavía.</p>'; return; }
  const lbl = { soat: 'SOAT', tecnomecanica: 'Tecnomecánica', tarjeta_operacion: 'T. operación' };
  cont.innerHTML = '';
  for (const h of data) {
    const div = document.createElement('div'); div.className = 'doc-hrow';
    const arch = h.archivo_path ? `<button class="link-btn" data-path="${esc(h.archivo_path)}">📎 ${esc(h.archivo_nombre || 'archivo')}</button>` : '';
    const cambio = (h.fecha_anterior && String(h.fecha_anterior) !== String(h.fecha_vencimiento))
      ? ` <span class="doc-cambio">(antes: ${fechaLegible(h.fecha_anterior)})</span>` : '';
    div.innerHTML = `<div class="doc-hmain"><b>${lbl[h.tipo] || h.tipo}</b> · vence <b>${h.fecha_vencimiento ? fechaLegible(h.fecha_vencimiento) : '—'}</b>${cambio}${h.numero ? (' · N° ' + esc(h.numero)) : ''}</div>`
      + `<div class="doc-hmeta">👤 ${esc(h.creado_por || '—')} · 🕒 ${fmtFechaHora(h.creado_en)} ${arch}</div>`
      + (h.observacion ? `<div class="doc-hobs">${esc(h.observacion)}</div>` : '');
    cont.appendChild(div);
  }
  cont.querySelectorAll('button[data-path]').forEach((b) => b.addEventListener('click', () => verDocArchivo(b.dataset.path)));
}
async function verDocArchivo(path) {
  const { data, error } = await sb.storage.from('docs-vehiculos').createSignedUrl(path, 3600);
  if (error) { toast('No se pudo abrir el archivo: ' + error.message, 'err'); return; }
  window.open(data.signedUrl, '_blank');
}
$('doc-save').addEventListener('click', async () => {
  const btn = $('doc-save'); if (btn.dataset.busy === '1') return;
  const err = $('doc-err'); err.hidden = true;
  if (!DOC_VEH) return;
  const tipo = $('doc-tipo').value, fecha = $('doc-fecha').value || null;
  const num = $('doc-num').value.trim() || null, obs = $('doc-obs').value.trim() || null;
  const file = $('doc-file').files[0];
  if (!fecha && !file) { err.textContent = 'Indica la nueva fecha de vencimiento o adjunta el documento.'; err.hidden = false; return; }
  // Validación de la fecha (manejo de errores)
  if (fecha) {
    const y = +String(fecha).slice(0, 4);
    if (isNaN(Date.parse(fecha + 'T00:00:00')) || y < 2000 || y > 2100) {
      err.textContent = 'La fecha de vencimiento no es válida.'; err.hidden = false; return;
    }
    // Regla estricta: la nueva fecha debe ser de hoy en adelante y nunca anterior a la registrada
    const hoy = hoyServidor();
    const td = DOC_TIPOS.find((x) => x.key === tipo);
    const ant = (DOC_VEH && DOC_VEH[td.col]) ? String(DOC_VEH[td.col]).slice(0, 10) : null;
    if (fecha < hoy) {
      err.textContent = `La nueva fecha de vencimiento debe ser de hoy (${fechaLegible(hoy)}) en adelante.`;
      err.hidden = false; return;
    }
    if (ant && fecha < ant) {
      err.textContent = `La nueva fecha no puede ser anterior a la registrada (${fechaLegible(ant)}).`;
      err.hidden = false; return;
    }
  }
  if (file && file.size > 15 * 1024 * 1024) { err.textContent = 'El archivo supera 15 MB.'; err.hidden = false; return; }
  // Confirmación con auditoría a la vista (cambio + responsable)
  const tdef = DOC_TIPOS.find((x) => x.key === tipo);
  const anterior = DOC_VEH[tdef.col] ? fechaLegible(DOC_VEH[tdef.col]) : '— (sin fecha)';
  const nueva = fecha ? fechaLegible(fecha) : anterior;
  const ok = await confirmAction({
    title: '¿Guardar cambio?',
    lead: `${tdef.label} · móvil ${DOC_VEH.numero_interno || ''} (${DOC_VEH.placa || ''})`,
    message: `Vence:        ${anterior}  →  ${nueva}` + (file ? `\nArchivo:      ${file.name}` : '') + `\nResponsable:  ${miCorreo()}`,
    okLabel: 'Guardar',
  });
  if (!ok) return;
  btn.dataset.busy = '1'; btn.disabled = true; const old = btn.textContent; btn.textContent = 'Guardando…';
  try {
    let path = null, nombre = null;
    if (file) {
      if (file.size > 15 * 1024 * 1024) throw new Error('El archivo supera 15 MB.');
      const safe = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
      path = `${DOC_VEH.id}/${tipo}/${Date.now()}_${safe}`;
      const up = await sb.storage.from('docs-vehiculos').upload(path, file, { upsert: false, contentType: file.type || undefined });
      if (up.error) throw up.error;
      nombre = file.name;
    }
    const { error } = await sb.rpc('admin_guardar_doc_vehiculo', {
      p_vehiculo_id: DOC_VEH.id, p_tipo: tipo, p_fecha: fecha, p_numero: num,
      p_archivo_path: path, p_archivo_nombre: nombre, p_observacion: obs,
    });
    if (error) throw error;
    const t = DOC_TIPOS.find((x) => x.key === tipo);
    DOC_VEH[t.col] = fecha; if (num) DOC_VEH[t.num] = num;
    renderDocEstados(DOC_VEH);
    $('doc-file').value = ''; $('doc-obs').value = '';
    await loadDocHist(DOC_VEH.id);
    toast('Documento guardado', 'ok');
    if (current === 'parque_automotor') loadData();
  } catch (e) { err.textContent = e.message || String(e); err.hidden = false; }
  finally { btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = old; }
});

// ---- Alertas de vencimiento para el despachador (solo sus móviles) / admin (toda la flota) ----
let DOC_ALERTAS = [];
// Móviles que el despachador realmente programa (de Despachos + sus tablas de puesto), últimos 45 días
async function misMovilesProg() {
  const set = new Set();
  const desde = fechaMenosDias(45);
  const tablas = ['despachos', ...((CTX?.tablas || []).map((t) => t.tabla))].filter((t) => TABLES[t]);
  for (const t of tablas) {
    const { data } = await sb.from(t).select('vehiculo').gte('fecha', desde).not('vehiculo', 'is', null).limit(5000);
    (data || []).forEach((r) => { if (r.vehiculo != null) set.add(String(r.vehiculo).trim()); });
  }
  return set;
}
async function cargarAlertasDocumentos() {
  const { data, error } = await sb.from('parque_automotor')
    .select('id,numero_interno,placa,ruta,estado,vence_soat,vence_tecnomecanica,vence_tarjeta_operacion,num_soat,num_tecnomecanica,num_tarjeta_operacion')
    .eq('estado', 'Activo').limit(5000);
  if (error || !data) return [];
  let permitido = null; // null = todos (admin)
  if (!isAdmin()) { permitido = await misMovilesProg(); }
  const out = [];
  for (const v of data) {
    if (permitido && !permitido.has(String(v.numero_interno).trim())) continue;
    const items = [];
    for (const t of DOC_TIPOS) { const b = docBand(v[t.col]); if (nivelEsAlerta(b.nivel)) items.push({ key: t.key, label: t.label, b }); }
    if (items.length) out.push({ ...v, items, peor: Math.min(...items.map((i) => i.b.nivel)) });
  }
  out.sort((a, b) => a.peor - b.peor || String(a.numero_interno).localeCompare(String(b.numero_interno)));
  return out;
}
async function refrescarAlertasDocs() {
  try { DOC_ALERTAS = await cargarAlertasDocumentos(); } catch { DOC_ALERTAS = []; }
  buildSidebar(); // refresca el contador 🔔 del menú
  const banner = $('doc-banner');
  if (!banner) return;
  if (!DOC_ALERTAS.length || banner.dataset.dismiss === '1') { banner.hidden = true; return; }
  const venc = DOC_ALERTAS.filter((a) => a.peor === 0).length;
  $('doc-banner-txt').innerHTML = `⚠️ <b>${DOC_ALERTAS.length}</b> vehículo(s) con documentos por vencer`
    + (venc ? ` · <b>${venc}</b> ya vencido(s)` : '');
  banner.hidden = false;
}
$('doc-banner-ver') && $('doc-banner-ver').addEventListener('click', openDocPanel);
$('doc-banner-x') && $('doc-banner-x').addEventListener('click', () => { $('doc-banner').dataset.dismiss = '1'; $('doc-banner').hidden = true; });

function openDocPanel() {
  const body = $('docp-body');
  if (!DOC_ALERTAS.length) { body.innerHTML = '<p class="doc-empty">Sin alertas de documentos. 👍</p>'; }
  else {
    body.innerHTML = DOC_ALERTAS.map((a) => {
      const chips = a.items.map((it) => `<span class="doc-chip ${it.b.cls}">${esc(it.label)}: ${esc(it.b.txt)}</span>`).join(' ');
      const adminBtn = isAdmin() ? `<button class="btn btn-sm docp-edit" data-id="${a.id}">📄 Gestionar</button>` : '';
      return `<div class="docp-item"><div class="docp-h"><b>${esc(a.numero_interno || '')}</b> · ${esc(a.placa || '')}`
        + ` <span class="docp-ruta">${esc(a.ruta || '')}</span> ${adminBtn}</div><div class="docp-chips">${chips}</div></div>`;
    }).join('');
  }
  $('docp-modal').hidden = false;
  body.querySelectorAll('.docp-edit').forEach((b) => b.addEventListener('click', () => {
    const a = DOC_ALERTAS.find((x) => String(x.id) === b.dataset.id);
    if (a) { $('docp-modal').hidden = true; openDocsVehiculo(a, (a.items || []).map((i) => i.key)); }
  }));
}
$('docp-x') && $('docp-x').addEventListener('click', () => { $('docp-modal').hidden = true; });
$('docp-cerrar') && $('docp-cerrar').addEventListener('click', () => { $('docp-modal').hidden = true; });

// ---- Aviso al despachar: si el móvil tiene documentos vencidos / por vencer ----
async function avisarDocsMovil(numero) {
  const box = $('s-docwarn'); if (!box) return;
  box.hidden = true; box.innerHTML = '';
  if (!numero) return;
  const { data } = await sb.from('parque_automotor')
    .select('vence_soat,vence_tecnomecanica,vence_tarjeta_operacion')
    .eq('numero_interno', String(numero).trim()).limit(1);
  const v = data && data[0]; if (!v) return;
  const items = [];
  for (const t of DOC_TIPOS) { const b = docBand(v[t.col]); if (nivelEsAlerta(b.nivel)) items.push({ label: t.label, b }); }
  if (!items.length) return;
  const peor = Math.min(...items.map((i) => i.b.nivel));
  box.className = 'sonar-info ' + (peor === 0 ? 'docwarn-venc' : 'docwarn-prox');
  box.innerHTML = (peor === 0 ? '⛔ <b>Documentos vencidos</b> de este móvil: ' : '⚠️ <b>Documentos por vencer</b> de este móvil: ')
    + items.map((it) => `${esc(it.label)} (${it.b.dias < 0 ? 'vencido' : 'en ' + it.b.dias + ' días'})`).join(' · ');
  box.hidden = false;
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
  // La fecha es clave: solo se opera el día actual.
  if (row && cfg.dispatchable && row.fecha) {
    const f = String(row.fecha).slice(0, 10);
    if (f > hoyServidor()) { toast('No se puede editar: la fecha aún no llega (adelantada).', 'err'); return; }
    // Excepción: el auditor SÍ audita despachos de días anteriores.
    if (f < hoyServidor() && !isAuditor()) { toast('No se puede editar: la fecha del viaje ya pasó.', 'err'); return; }
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
  const soyAuditor = isAuditor();
  if (isDispatched && !soyAuditor) {
    const note = document.createElement('div');
    note.className = 'sonar-info';
    note.textContent = '🔒 Despacho ya realizado: solo puedes editar observaciones y los ítems de seguimiento.';
    form.appendChild(note);
  }
  if (soyAuditor) {
    const note = document.createElement('div');
    note.className = 'sonar-info';
    note.textContent = '🔎 Modo auditoría: edita el control y los indicadores. Al guardar quedará registrado como auditado por ti.';
    form.appendChild(note);
  }

  for (const f of cfg.fields) {
    // formHide: el campo nunca se muestra en el formulario (ej. KEY, regId, despachador, ubicación en tablas)
    if (f.formHide) continue;
    // editOnly: solo se muestra al EDITAR un registro existente (no al crear)
    if (f.editOnly && !editing) continue;
    // auditOnly: campos de control que solo ven el auditor y el admin (el despachador no)
    if (f.auditOnly && !isAdmin() && !soyAuditor) continue;
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
      // Un campo de auditoría (audit) se comporta como postDispatch: editable aun ya despachado
      if (f.readOnly || (isDispatched && !f.postDispatch && !f.audit)) cb.disabled = true;
      // El auditor solo edita los campos de auditoría; el resto queda de solo lectura
      if (soyAuditor && !f.audit) cb.disabled = true;
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
      // Un campo de auditoría (audit) se comporta como postDispatch: editable aun ya despachado
      if (f.readOnly || (isDispatched && !f.postDispatch && !f.audit)) input.disabled = true; // solo lectura / ya despachado
      // El auditor solo edita los campos de auditoría; el resto queda de solo lectura
      if (soyAuditor && !f.audit) input.disabled = true;
      // Solo lectura "suave" para el despachador: no lo puede cambiar pero SÍ se guarda (ej. puesto)
      if (f.softReadOnlyDispatcher && !isAdmin()) input.readOnly = true;
      wrap.appendChild(input);
      if (f.hint) wrap.appendChild(Object.assign(document.createElement('span'), { className: 'field-hint', textContent: f.hint }));
      // Lector de QR del carnet junto al campo Conductor (solo donde se marca f.qr, ej. Resumen)
      if (f.type === 'sonardrv' && f.qr && !input.disabled) attachQrScanner(input);
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

  // Auditoría: al guardar un despacho, el auditor (y la fecha/hora) quedan registrados solos
  if (current === 'despachos' && isAuditor()) {
    if (CTX?.auditor_id != null) payload.auditor_id = CTX.auditor_id;
    payload.fecha_hora_auditoria = new Date().toISOString();
  }

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

// Borrar toda la programación de una tabla por puesto para una fecha (admin). Útil para
// reimportar un día corregido sin que queden duplicados.
$('del-day-btn').addEventListener('click', async () => {
  const btn = $('del-day-btn'); if (btn.dataset.busy === '1') return;
  const label = TABLES[current]?.label || current;
  const sugerida = filters['fecha'] || hoyServidor();
  const fecha = (prompt(`Borrar la programación de la tabla "${label}" para la fecha (AAAA-MM-DD):`, sugerida) || '').trim();
  if (!fecha) return;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(fecha)) { toast('Fecha inválida. Usa el formato AAAA-MM-DD.', 'err'); return; }
  // Contar primero para mostrar cuántos se borrarán
  const { count, error: ce } = await sb.from(current).select('id', { count: 'exact', head: true }).eq('fecha', fecha);
  if (ce) { toast('Error al consultar: ' + ce.message, 'err'); return; }
  if (!count) { toast(`No hay registros del ${fechaLegible(fecha)} en ${label}.`, 'err'); return; }
  const ok = await confirmAction({
    title: '¿Borrar el día?',
    lead: `Se borrará TODA la programación de ${label} del ${fechaLegible(fecha)}.`,
    message: `Registros a borrar: ${count}\n\n⚠️ Esta acción no se puede deshacer.`,
    okLabel: 'Borrar día', danger: true,
  });
  if (!ok) return;
  btn.dataset.busy = '1'; btn.disabled = true;
  let res;
  try { res = await sb.rpc('borrar_tabla_dia', { p_tabla: current, p_fecha: fecha }); }
  finally { btn.dataset.busy = '0'; btn.disabled = false; }
  if (res.error) { toast('Error al borrar: ' + res.error.message, 'err'); return; }
  toast(`🗑️ ${res.data?.borrados ?? 0} registros borrados del ${fechaLegible(fecha)}`, 'ok');
  loadData();
});

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
    // Validación de orden: la columna "hora" debe traer horas (no móviles). Detecta archivos con columnas corridas.
    const esHora = (v) => !v || /^\d{1,2}:\d{2}/.test(String(v).trim());
    const malHora = rows.find((r) => !esHora(r.hora) || !esHora(r.hora_prog));
    if (malHora) {
      const ej = !esHora(malHora.hora) ? malHora.hora : malHora.hora_prog;
      throw new Error(`La columna de hora trae un valor que no es una hora ("${ej}"). Revisa que los encabezados estén en el orden correcto (fecha; vehiculo; hora; ruta; …).`);
    }
    // Validación de tabla destino: el archivo debe corresponder a la tabla seleccionada
    if (impCfg.tablaParam) {
      const objetivo = normH(TABLES[current].label);
      const malTabla = rows.find((r) => r.tabla_destino && normH(r.tabla_destino) !== objetivo);
      if (malTabla) {
        throw new Error(`Este archivo es de la tabla "${malTabla.tabla_destino}", pero lo estás importando en "${TABLES[current].label}". Abre la tabla correcta o corrige la columna "tabla".`);
      }
    }
    let insertados = 0, kept = 0;
    const B = 200;
    for (let i = 0; i < rows.length; i += B) {
      const batch = rows.slice(i, i + B);
      // Las tablas por puesto importan a SU propia tabla → pasan el nombre (p_tabla)
      const params = impCfg.tablaParam ? { p_tabla: current, p_rows: batch } : { p_rows: batch };
      const { data, error } = await sb.rpc(impCfg.rpc, params);
      if (error) throw error;
      insertados += data.insertados || 0; kept += data[impCfg.kept] || 0;
      res.textContent = `Procesando… ${Math.min(i + B, rows.length)} / ${rows.length}`;
    }
    res.className = 'sonar-result ok';
    res.textContent = `✅ Importación terminada\n\nFilas leídas: ${rows.length}\nNuevos insertados: ${insertados}\n${impCfg.keptLabel}: ${kept}`;
    toast(`✅ ${insertados} importados`, 'ok');
    loadData(); // refresca la tabla detrás
    setTimeout(closeImport, 1600); // cierra solo para mostrar directamente lo importado
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
// Fecha de HOY tomada del SERVIDOR (Supabase, zona Colombia). Evita que cambien la fecha
// del celular para hacer trampa con los despachos. Se refresca al cargar y periódicamente.
let SRV_HOY = null;
async function refrescarFechaServidor() {
  try { const { data, error } = await sb.rpc('hoy_servidor'); if (!error && data) SRV_HOY = String(data).slice(0, 10); }
  catch (e) { /* sin red: se usará la fecha local como respaldo */ }
}
function hoyServidor() { return SRV_HOY || hoyLocal(); } // respaldo a local solo si aún no cargó
// Texto del usuario en la barra superior: nombre + rol/puesto
function etiquetaUsuario(user) {
  const nombre = CTX?.nombre || user?.email || '';
  if (CTX?.rol === 'admin') return `👤 ${nombre} · Administrador`;
  if (CTX?.rol === 'auditor') return `👤 ${nombre} · 🔎 Auditor`;
  if (CTX?.rol === 'despachador') {
    const hor = (CTX.hora_inicio || CTX.hora_fin) ? ` · 🕒 ${CTX.hora_inicio || '—'}${CTX.hora_fin ? '–' + CTX.hora_fin : ''}` : '';
    return `👤 ${nombre} · 📌 ${CTX.puesto || 'sin turno hoy'}${hor}`;
  }
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
  // La fecha del despacho es SIEMPRE hoy (del servidor) y NADIE la puede tocar → evita trampas
  await refrescarFechaServidor();
  $('nd-fecha').value = hoyServidor();
  $('nd-fecha').min = hoyServidor();
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
// Conductor para un móvil: SOLO desde Resumen y SOLO de la fecha indicada.
// Si no hay registro en Resumen para ese móvil en esa fecha, no autocompleta (devuelve null).
async function nombreConductorDeVehiculo(vehId, fecha) {
  if (!vehId || !fecha) return null; // sin fecha exacta no se adivina (evita traer datos de otro día)
  try {
    const { data } = await sb.from('resumen')
      .select('cond:conductor_id(nombre)')
      .eq('vehiculo_id', vehId).eq('fecha', fecha)
      .not('conductor_id', 'is', null)
      .order('hora_cierre', { ascending: false }).limit(1);
    if (data && data[0]?.cond?.nombre) return data[0].cond.nombre;
  } catch (e) { /* sin resultado → null */ }
  return null;
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
    // Nadie puede alterar la fecha del despacho: siempre es hoy (del servidor)
    tipo: 'LIBRE', fecha: hoyServidor(), hora: $('nd-hora').value || null,
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
  if (!vr) { info.hidden = true; const w = $('s-docwarn'); if (w) w.hidden = true; return; }
  avisarDocsMovil(vr.numero); // aviso de documentos vencidos / por vencer de este móvil
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
  // La fecha es clave: solo se despacha el día actual (fecha del servidor, no del celular)
  if (row && row.fecha) {
    const f = String(row.fecha).slice(0, 10);
    if (f < hoyServidor()) { toast('No se puede despachar: la fecha del viaje ya pasó.', 'err'); return; }
    if (f > hoyServidor()) { toast('No se puede despachar: la fecha aún no llega (adelantada).', 'err'); return; }
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
    // El conductor NO se toma de la programación de la tabla (puede estar desactualizada);
    // se trae de Resumen para la fecha del despacho (abajo). Si no hay, queda vacío.
    $('s-com').value = 'Despacho ' + (row.id || '');
  }
  enhanceById('s-mov', 's-itin', 's-drv');
  $('s-desp-name').value = CTX?.nombre || ''; // despachador = usuario en sesión (no editable)
  await traerConductorSonar(); // conductor desde Resumen, según la fecha del despacho
  await updateSonarInfo();
  $('sonar-modal').hidden = false;
}
// Trae el conductor registrado en Resumen para el móvil elegido (mapeado a conductor SONAR)
async function traerConductorSonar() {
  const vehId = $('s-mov').value;
  if (!vehId) return;
  // Conductor de Resumen para la fecha del despacho (la del viaje, no la del celular)
  const fechaDesp = sonarRow?.fecha ? String(sonarRow.fecha).slice(0, 10) : hoyServidor();
  const nombre = await nombreConductorDeVehiculo(vehId, fechaDesp);
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
  // La fecha es clave: solo se cancela el día actual (fecha del servidor, no del celular)
  if (row && row.fecha) {
    const f = String(row.fecha).slice(0, 10);
    if (f < hoyServidor()) { toast('No se puede cancelar: el despacho es de una fecha anterior a hoy.', 'err'); return; }
    if (f > hoyServidor()) { toast('No se puede cancelar: la fecha aún no llega (adelantada).', 'err'); return; }
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
// ===== Recorrido del bus (SONAR GET_TrackerEventsHistory) =====
let recLayer = null;   // capa Leaflet con el recorrido dibujado
let _recVeh = null;    // { mid, movil, ruta } del móvil elegido
let _recDesp = [];     // despachos cargados del móvil (para el selector)
// "HH:MM" (24h) -> "h:MM a.m./p.m." (formato colombiano)
function _hora12(hhmm) {
  if (!hhmm) return '';
  const [h, m] = String(hhmm).split(':').map(Number);
  const ap = h < 12 ? 'a.m.' : 'p.m.';
  const h12 = (h % 12) || 12;
  return `${h12}:${_pad2(m)} ${ap}`;
}
// Suma minutos a una hora local (fecha+hh:mm); devuelve {fecha, hhmm} (maneja cruce de día)
function _finConMinutos(fecha, hhmm, minutos) {
  const [h, m] = hhmm.split(':').map(Number);
  const d = new Date(fecha + 'T00:00:00'); d.setMinutes(h * 60 + m + (minutos || 0));
  const f = `${d.getFullYear()}-${_pad2(d.getMonth() + 1)}-${_pad2(d.getDate())}`;
  return { fecha: f, hhmm: `${_pad2(d.getHours())}:${_pad2(d.getMinutes())}` };
}
// CONDICIÓN: el recorrido solo se muestra del despacho de HOY, consultado EN VIVO a SONAR.
async function abrirRecorrido(r) {
  _recVeh = { mid: r.mid, movil: r.movil, ruta: r.ruta };
  _recDesp = [];
  $('rec-movil').textContent = `${r.movil || ''}${r.ruta ? ' · ' + r.ruta : ''}`;
  $('rec-msg').textContent = '';
  const sel = $('rec-despacho'); sel.innerHTML = '<option value="">Consultando despachos de hoy…</option>';
  $('rec-ver').disabled = true;
  $('rec-modal').hidden = false;
  if (!r.mid) { sel.innerHTML = '<option value="">—</option>'; $('rec-msg').textContent = 'Este móvil no tiene Id GPS en SONAR.'; return; }
  // Despachos de HOY en vivo desde SONAR (rango del día Bogotá expresado en UTC)
  const hoy = hoyServidor();
  const pIni = `${hoy} 05:00:00`; // 00:00 Bogotá → UTC
  const pFin = new Date().toISOString().slice(0, 19).replace('T', ' '); // ahora en UTC
  const { data, error } = await sb.rpc('despachos_sonar', { p_mid: r.mid, p_ini: pIni, p_fin: pFin });
  if (error) { sel.innerHTML = '<option value="">—</option>'; $('rec-msg').textContent = 'Error: ' + error.message; return; }
  if (!data || !data.ok) { sel.innerHTML = '<option value="">—</option>'; $('rec-msg').textContent = 'No se pudo consultar SONAR: ' + (data?.error || '?'); return; }
  // solo HOY, sin cancelados, descartando placeholders con duración absurda (>24 h)
  const items = (data.items || []).filter((d) => d.fecha === hoy && d.cancelado !== 'true' && (d.minutos || 0) > 0 && (d.minutos || 0) <= 1440);
  _recDesp = items.map((d) => {
    const ini = (d.hora || '').slice(0, 5);
    const f = _finConMinutos(d.fecha, ini, d.minutos || 0);
    return { fecha: d.fecha, ini, fin: f.hhmm, finFecha: f.fecha, ruta: d.ruta || '', estado: d.corriendo === 'true' ? 'en curso' : 'finalizado' };
  }).filter((d) => d.ini);
  if (!_recDesp.length) {
    sel.innerHTML = '<option value="">—</option>';
    $('rec-msg').textContent = '🚫 Este vehículo no tiene despacho hoy. El recorrido solo se muestra del despacho de hoy.';
    return;
  }
  sel.innerHTML = _recDesp.map((d, i) => `<option value="${i}">${esc(_hora12(d.ini))}–${esc(_hora12(d.fin))}${d.ruta ? ' · ' + esc(d.ruta) : ''} · ${esc(d.estado)}</option>`).join('');
  $('rec-ver').disabled = false;
}
async function verRecorrido() {
  if (!_recVeh) return;
  const sel = $('rec-despacho'); const msg = $('rec-msg');
  const d = _recDesp[+sel.value];
  if (!d) { msg.textContent = 'Elige un despacho. El recorrido solo se muestra para vehículos despachados.'; return; }
  const btn = $('rec-ver'); const t = btn.textContent; btn.disabled = true; btn.textContent = 'Cargando…';
  msg.textContent = 'Consultando SONAR…';
  try {
    const { data, error } = await sb.rpc('sonar_recorrido', { p_mid: _recVeh.mid, p_desde: `${d.fecha} ${d.ini}`, p_hasta: `${d.finFecha} ${d.fin}` });
    if (error) { msg.textContent = 'Error: ' + error.message; return; }
    if (!data || !data.ok) { msg.textContent = 'No se pudo: ' + (data?.error || '?'); return; }
    const pts = (data.puntos || []).filter((p) => p.lat != null && p.lon != null);
    if (!pts.length) { msg.textContent = 'El despacho no tiene reportes GPS en ese rango.'; return; }
    dibujarRecorrido(pts, _recVeh.movil);
    $('rec-modal').hidden = true;
    closeVehSheet();
    toast(`Recorrido de ${_recVeh.movil}: ${pts.length} puntos · ${_hora12(pts[0].t)}–${_hora12(pts[pts.length - 1].t)}`, 'ok');
  } catch (e) { msg.textContent = e.message || String(e); }
  finally { btn.disabled = false; btn.textContent = t; }
}
let _recMarkers = [];  // marcadores por punto (para enlazar con la lista)
function limpiarRecorrido() {
  if (recLayer && flotaMap) { flotaMap.removeLayer(recLayer); recLayer = null; }
  _recMarkers = [];
  const b = $('rec-clear'); if (b) b.hidden = true;
  const pn = $('rec-panel'); if (pn) pn.hidden = true;
}
function dibujarRecorrido(pts, movil) {
  if (!flotaMap) return;
  limpiarRecorrido();
  recLayer = L.layerGroup().addTo(flotaMap);
  const latlngs = pts.map((p) => [p.lat, p.lon]);
  L.polyline(latlngs, { color: '#ED1C24', weight: 4, opacity: 0.85 }).addTo(recLayer);
  _recMarkers = pts.map((p, i) => {
    const ini = i === 0, fin = i === pts.length - 1, ext = ini || fin;
    const col = ini ? '#137a2b' : (fin ? '#0b5cad' : '#ED1C24');
    const m = L.circleMarker([p.lat, p.lon], {
      radius: ext ? 7 : 3.5, color: col, fillColor: col, fillOpacity: 0.9, weight: ext ? 2 : 1,
    });
    const eti = ini ? '🟢 Inicio · ' : (fin ? '🔵 Fin · ' : '');
    m.bindPopup(`<b>${esc(movil || '')}</b> · ${eti}${esc(_hora12(p.t))}<br>🚗 ${p.vel ?? 0} km/h<br>${esc(p.dir || '')}`);
    m.addTo(recLayer);
    return m;
  });
  flotaMap.fitBounds(latlngs, { padding: [40, 40] });
  const b = $('rec-clear'); if (b) b.hidden = false;
  renderRecPanel(pts, movil);
}
// Lista deslizable del recorrido: cada punto centra el mapa y abre su detalle
function renderRecPanel(pts, movil) {
  const pn = $('rec-panel'); if (!pn) return;
  $('rec-panel-title').textContent = `🛣️ ${movil || ''}`;
  $('rec-panel-sub').textContent = `${pts.length} puntos · ${_hora12(pts[0].t)}–${_hora12(pts[pts.length - 1].t)}`;
  const list = $('rec-panel-list');
  list.innerHTML = pts.map((p, i) => {
    const tag = i === 0 ? '🟢' : (i === pts.length - 1 ? '🔵' : '•');
    const det = (p.vel ?? 0) === 0 ? '<span class="rec-pt-stop">detenido</span>' : `${p.vel} km/h`;
    return `<button type="button" class="rec-pt" data-i="${i}">
      <span class="rec-pt-t">${tag} ${esc(_hora12(p.t))}</span>
      <span class="rec-pt-v">${det}</span>
      <span class="rec-pt-d">${esc(p.dir || '—')}</span>
    </button>`;
  }).join('');
  list.querySelectorAll('.rec-pt').forEach((b) => b.addEventListener('click', () => {
    const i = +b.dataset.i; const p = pts[i]; const m = _recMarkers[i];
    if (!p) return;
    flotaMap.setView([p.lat, p.lon], 16, { animate: true });
    if (m) m.openPopup();
    list.querySelectorAll('.rec-pt.sel').forEach((x) => x.classList.remove('sel'));
    b.classList.add('sel');
  }));
  pn.hidden = false;
}
$('rec-panel-x') && $('rec-panel-x').addEventListener('click', () => { const p = $('rec-panel'); if (p) p.hidden = true; });
$('rec-x') && $('rec-x').addEventListener('click', () => { $('rec-modal').hidden = true; });
$('rec-cancel') && $('rec-cancel').addEventListener('click', () => { $('rec-modal').hidden = true; });
$('rec-ver') && $('rec-ver').addEventListener('click', verRecorrido);
$('rec-clear') && $('rec-clear').addEventListener('click', limpiarRecorrido);

async function openVehSheet(r) {
  const sheet = $('veh-sheet'), body = $('veh-sheet-body');
  body.innerHTML = mapPopup(r);
  // Acciones del móvil: recorrido (todos) + despachar/consultar SONAR (solo admin)
  const acts = document.createElement('div');
  acts.className = 'veh-sheet-acts';
  const bRec = Object.assign(document.createElement('button'), { className: 'btn', textContent: '🛣️ Recorrido' });
  bRec.onclick = () => abrirRecorrido(r);
  acts.appendChild(bRec);
  if (isAdmin()) {
    const bDsp = Object.assign(document.createElement('button'), { className: 'btn btn-primary', textContent: '🛰️ Despachar' });
    bDsp.onclick = () => despacharDesdeMapa(r.movil);
    const bCon = Object.assign(document.createElement('button'), { className: 'btn', textContent: '📡 Consultar SONAR' });
    bCon.onclick = () => consultarDesdeMapa(r.movil);
    acts.append(bDsp, bCon);
  }
  body.appendChild(acts);
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
  document.getElementById('app').classList.add('view-map');
  cerrarPanelesFlotantes();
  $('table-view').hidden = true;
  $('map-view').hidden = false;
  closeVehSheet();
  limpiarRecorrido(); // entra al mapa sin recorrido previo dibujado
  // resaltar la opción del menú
  document.querySelectorAll('#sidebar button').forEach((b) => b.classList.remove('active'));
  $('nav-mapa')?.classList.add('active');
  buildBottomNav(); // quita el resaltado de la barra inferior (el mapa no está allí)
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

$('synccond-btn').addEventListener('click', async () => {
  const btn = $('synccond-btn'); const t = btn.textContent; btn.disabled = true; btn.textContent = 'Sincronizando…';
  const { data, error } = await sb.rpc('sync_conductores');
  btn.disabled = false; btn.textContent = t;
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data && data.ok) { toast(`Conductores sincronizados: ${data.conductores}`, 'ok'); if (current === 'conductores_sonar') loadData(); }
  else toast('No se pudo: ' + (data?.error || '?'), 'err');
});

// ---------- Administración de accesos (solo admin) ----------
$('perfil-new-btn').addEventListener('click', async () => {
  const rolIn = (prompt('Rol del acceso (despachador / auditor / admin):', 'despachador') || '').trim().toLowerCase();
  if (!rolIn) return;
  if (!['despachador', 'auditor', 'admin'].includes(rolIn)) { toast('Rol inválido. Usa despachador, auditor o admin.', 'err'); return; }
  const email = (prompt(`Correo del ${rolIn}:`) || '').trim();
  if (!email) return;
  const nombre = (prompt(`Nombre del ${rolIn}:`) || '').trim();
  const pass = (prompt('Contraseña temporal (mín. 6 caracteres):', 'APL2026*PL') || '').trim();
  if (pass.length < 6) { toast('La contraseña debe tener al menos 6 caracteres', 'err'); return; }
  const { data, error } = await sb.rpc('admin_crear_usuario', { p_email: email, p_nombre: nombre, p_pass: pass, p_rol: rolIn });
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data?.ok) { toast(`Acceso de ${rolIn} creado para ${email}`, 'ok'); if (current === 'perfiles') loadData(); }
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

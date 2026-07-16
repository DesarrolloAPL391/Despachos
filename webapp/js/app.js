import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY, TABLES, TABLE_ORDER, PAGE_SIZE, APP_VERSION, configTablaPuesto } from './config.js';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);

// Estado
let current = null;     // nombre de la tabla actual
let page = 0;
let term = '';
let soloPendientes = false; // en tablas de despacho: mostrar solo los viajes que faltan por despachar
const estadoMoviles = new Map(); // movil -> 'mov'|'idle'|'off' (estado GPS de SONAR vía tabla `ubicaciones`)
let _estadoMovilesTs = 0;        // marca de tiempo del último cargue (para cachear ~30s)
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
    // Se (re)construye según el rol actual. El auditor y el admin la ven CON las columnas de
    // control (el auditor para auditar; el admin para supervisar y para la "vista como auditor").
    // Al despachador se le ocultan. Reconstruir siempre evita configs desactualizadas.
    TABLES[t.tabla] = configTablaPuesto(t.label, t.puesto, { auditor: isAuditor() || isAdmin() });
    if (!puestoTables.includes(t.tabla)) puestoTables.push(t.tabla);
  }
}
// Auditor: tablas de puesto donde tiene despachos de SUS rutas (RLS filtra en el servidor).
// Solo esas se muestran en el menú, para no llenarlo de tablas vacías.
async function tablasAuditablesDePuesto() {
  const encontradas = new Set();
  await Promise.all(puestoTables.map(async (t) => {
    try {
      const { count } = await sb.from(t).select('id', { count: 'exact', head: true });
      if ((count || 0) > 0) encontradas.add(t);
    } catch { /* sin acceso o vacía → no se muestra */ }
  }));
  return puestoTables.filter((t) => encontradas.has(t)); // conserva el orden
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
// Vista previa "como despachador" (solo admin): simula el filtrado de un puesto sin cambiar de cuenta.
// PREVIEW = { email, nombre, puesto, dia_tipo, rutas:Set(normRuta), rutasRaw:[], grupos:Set,
//   ids:[ruta_id], tablas:[{tabla,label}], verDespachos } o null. Se arma con el contexto REAL
//   del despachador (RPC preview_contexto_despachador) para que la simulación sea fiel.
let PREVIEW = null;
function filtraComoDespachador() { return !!PREVIEW || !isAdmin(); }
// Rol EFECTIVO para las affordances de UI (columnas de control, botones por fila): en vista
// previa refleja el rol simulado, no el del admin real, para que "Ver como…" sea fiel.
// (No es control de acceso —el actor sigue siendo admin y la RLS manda—, solo fidelidad visual.)
function efIsAdmin() { return PREVIEW ? false : isAdmin(); }
function efIsAuditor() { return PREVIEW ? PREVIEW.rol === 'auditor' : isAuditor(); }
// Puesto actual: el simulado en vista previa, o el del despachador logueado (admin normal = ninguno)
function puestoActual() { return PREVIEW ? (PREVIEW.puesto || '') : (CTX?.puesto || ''); }
// Muestra "📌 Puesto" junto al título de la tabla (identifica en qué puesto estamos)
function actualizarPuestoBadge() {
  const el = document.getElementById('table-puesto'); if (!el) return;
  const p = puestoActual();
  el.textContent = p ? '📌 ' + p : '';
  el.hidden = !p;
}
function allowedRutaSet() { return PREVIEW ? PREVIEW.rutas : new Set((CTX?.rutas || []).map(normRuta)); }
// Grupos del parque habilitados: admin = todos (null); despachador/preview = su set
function allowedGrupoSet() { if (PREVIEW) return PREVIEW.grupos; return isAdmin() ? null : new Set(CTX?.grupos || []); }
// Empareja el nombre de una ruta de la tabla con un itinerario de SONAR. Tolera el
// prefijo "RUTA " del itinerario (313 ↔ RUTA 313) y sufijos de variante de la ruta
// (ej. "135 CENTRO" → 135, "130i MADRUGADA" → 130i). Devuelve el itinerario o null.
function matchItinerario(its, rutaNombre) {
  const r = normRuta(rutaNombre); if (!r) return null;
  // 1) coincidencia exacta (preferida: ej. ruta "190" → itinerario "190", no "190 CENTRO")
  let m = its.find((i) => normRuta(i.nombre) === r); if (m) return m;
  // 2) tolerando el prefijo "RUTA " del itinerario (313 ↔ RUTA 313)
  const sinRuta = (s) => normRuta(s).replace(/^ruta/, '');
  m = its.find((i) => sinRuta(i.nombre) === sinRuta(r)); if (m) return m;
  // 3) forma canónica: sin prefijo RUTA y sin sufijo de variante en ambos lados
  const canon = (s) => sinRuta(s).replace(/(madrugada|centro|sabado|sábado|domingo|festivo)$/, '');
  const rc = canon(r); if (!rc) return null;
  return its.find((i) => canon(i.nombre) === rc) || null;
}
// Tablas visibles según el rol:
//  - admin: todas
//  - despachador con tabla de puesto propia (ej. laureles): solo esa
//  - despachador sin tabla propia: las marcadas con despachador:true (despachos, filtrado por rutas)
function visibleTables() {
  // Vista previa (admin simulando): el menú se reduce como el del usuario simulado
  if (PREVIEW) {
    if (PREVIEW.rol === 'auditor') return ['despachos', 'despachos_sonar', ...(PREVIEW.auditTables || [])];
    return tablasDeDespachador(PREVIEW.tablas, PREVIEW.verDespachos);
  }
  if (isAdmin()) return menuOrder();
  // Auditor: la pantalla Despachos + "Auditoría SONAR" (los viajes REALES que trae SONAR,
  // donde revisa los incompletos) + las tablas de puesto donde tiene despachos de sus rutas
  // (así audita TODO lo suyo, esté en la vista general o en cualquier tabla de puesto).
  if (isAuditor()) return ['despachos', 'despachos_sonar', ...(CTX?.auditTables || [])];
  // despachador: todas las tablas de su puesto (puede tener varias)
  return tablasDeDespachador(CTX?.tablas, CTX?.verDespachos);
}
// Tablas visibles para un despachador dado su conjunto de tablas de puesto + si ve "Despachos"
function tablasDeDespachador(tablas, verDespachos) {
  const mine = (tablas || []).map((t) => t.tabla).filter((t) => TABLES[t]);
  if (mine.length) {
    // Si además tiene rutas que se despachan en la vista general, agrega "Despachos"
    if (verDespachos && !mine.includes('despachos')) mine.push('despachos');
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
function confirmAction({ title = 'Confirmar', lead = '', message = '', okLabel = 'Confirmar', danger = false, noCancel = false } = {}) {
  return new Promise((resolve) => {
    // Si ya había una confirmación esperando respuesta, se le responde "no" ANTES de
    // reemplazarla. Sin esto su promesa quedaba colgada para siempre: el flujo que la
    // esperaba nunca seguía ni liberaba su botón (quedaba muerto sin avisar).
    if (_confirmResolve) { const previa = _confirmResolve; _confirmResolve = null; previa(false); }
    _confirmResolve = resolve;
    $('confirm-title').textContent = title;
    $('confirm-lead').textContent = lead;
    $('confirm-lead').hidden = !lead;
    $('confirm-body').textContent = message;
    $('confirm-body').hidden = !message;
    const yes = $('confirm-yes');
    yes.textContent = okLabel;
    yes.className = 'btn ' + (danger ? 'btn-danger' : 'btn-primary');
    $('confirm-no').hidden = !!noCancel; // aviso de solo aceptar (sin Cancelar)
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
  if (Array.isArray(v)) return v.join(', ');
  if (v === true) return 'Sí';
  if (v === false) return 'No';
  // Quitar los segundos a las horas (HH:MM:SS -> HH:MM), tanto en horas sueltas como en fechas+hora
  return String(v).replace(/(\b\d{1,2}:\d{2}):\d{2}(\.\d+)?/g, '$1');
}
// Escapa también las comillas: esc() se usa dentro de atributos (title="...", href="..."),
// y sin escaparlas un dato guardado podía cerrar el atributo e inyectar código.
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
// Convierte "YYYY-MM-DD" → "DD/MM/AAAA" (para mostrar la fecha del filtro)
function fechaLegible(v) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(v || ''));
  return m ? `${m[3]}/${m[2]}/${m[1]}` : String(v || '');
}
// Safari/iOS NO parsea "YYYY-MM-DD HH:MM:SS" (con espacio) → "Invalid Date".
// Normaliza el timestamp de Postgres a ISO (con "T") antes de crear el Date.
function toDate(v) {
  if (v instanceof Date) return v;
  if (v == null) return new Date(NaN);
  let s = String(v).trim();
  if (/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}/.test(s)) s = s.replace(' ', 'T');
  return new Date(s);
}
// Formatea un timestamp (ISO) a fecha+hora local colombiana: "DD/MM/AAAA, HH:MM"
function fmtFechaHora(v) {
  const d = toDate(v);
  if (isNaN(d)) return fmt(v);
  const p = (n) => String(n).padStart(2, '0');
  return `${p(d.getDate())}/${p(d.getMonth() + 1)}/${d.getFullYear()}, ${p(d.getHours())}:${p(d.getMinutes())}`;
}
function chipClass(v) {
  const s = String(v || '').toUpperCase().trim();
  if (s === 'TABLA') return 'chip chip-indigo';
  if (s === 'LIBRE') return 'chip chip-violet';
  if (s === 'DESPACHADO' || s === 'ENABLED' || s === 'CERRADO' || s === 'ENCENDIDO' || s === 'SÍ' || s === 'SI' || s === 'INGRESO'
      || s === 'COMPLETO') return 'chip chip-green';
  if (s === 'APAGADO') return 'chip chip-gray';
  // Auditoría SONAR: "Incompleto" es lo que el auditor tiene que revisar → ámbar (no es un error, es trabajo)
  if (s === 'INCOMPLETO') return 'chip chip-amber';
  if (s === 'EN PROGRESO') return 'chip chip-indigo';
  if (s === 'NO REALIZA EL VIAJE' || s === 'DISABLED' || s === 'CANCELADO' || s === 'NO') return 'chip chip-red';
  if (s === 'PENDIENTE SONAR') return 'chip chip-amber';
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

// ---------- sesión única por usuario (todos los roles) ----------
// El enforcement REAL vive en la base de datos: una política RLS exige que el
// session_id del JWT actual sea el registrado como activo para el usuario (ver
// sql/03_sesion_unica.sql). Aquí solo (a) registramos esta sesión al hacer login
// y (b) avisamos y sacamos al usuario si su sesión fue reemplazada en otro equipo.
let sessionUser = null, sessTimer = null, pendingRegister = false;
async function cerrarSesionCon(msg) {
  if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
  sessionUser = null;
  alert(msg);
  // scope:'local' => cierra SOLO este dispositivo. Sin esto, signOut() por defecto
  // es GLOBAL y revoca TODAS las sesiones del usuario, incluida la sesión buena
  // (la que sí está trabajando): provocaba destrucción mutua y expulsiones en bucle.
  await sb.auth.signOut({ scope: 'local' });
}
// Chequeo proactivo: verifica vigencia + horario Y marca actividad (para "conectados").
// heartbeat() devuelve {estado: 'ok'|'reemplazada'|'fuera_horario'} (o boolean en versiones previas).
// Devuelve true si la sesión sigue viva; false si se cerró (para usarla como guardia).
// El servidor es la autoridad: solo cierra si dice 'reemplazada'/'fuera_horario', así que
// se puede llamar de forma reactiva (p.ej. al recibir datos vacíos) sin riesgo de falsos cierres.
async function verificarSesionVigente() {
  if (!sessionUser) return false;
  const { data, error } = await sb.rpc('heartbeat');
  if (error) return true;         // error de red: no expulsar (se reintenta luego)
  const estado = (typeof data === 'boolean') ? (data ? 'ok' : 'reemplazada') : (data?.estado || 'ok');
  if (estado === 'reemplazada') { await cerrarSesionCon('Tu sesión se cerró: tu cuenta se abrió en otro dispositivo.'); return false; }
  if (estado === 'fuera_horario') { await cerrarSesionCon('Tu turno terminó (o aún no comienza). La sesión se cerró por horario.'); return false; }
  return true;
}
document.addEventListener('visibilitychange', () => { if (!document.hidden) { verificarSesionVigente(); refreshContext(); checkAsistenciaPendiente(); } });

// Firma del contexto para detectar si el admin cambió el puesto/tablas/rutas
function ctxSig(c) {
  if (!c) return '';
  // Incluye grupos y horario: en domingo/festivo el admin puede cambiar los grupos del día
  // sin tocar puesto/tablas/ids, y el filtrado de móviles debe refrescarse igual.
  return [
    c.puesto || '',
    JSON.stringify((c.tablas || []).map((t) => t.tabla)),
    (c.ids || []).join(','),
    (c.grupos || []).join(','),
    c.hora_inicio || '', c.hora_fin || '',
  ].join('|');
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
  // Sesión única por usuario: si venimos de un login NUEVO, registrar esta sesión
  // como la activa ANTES de cualquier consulta sujeta a RLS. (mi_contexto es
  // SECURITY DEFINER y no se ve afectada.) En recargas no se re-registra, así el
  // dispositivo que hizo login conserva la sesión a través de refresh de token.
  if (pendingRegister) {
    pendingRegister = false;
    const gps = await capturarGps(5000); // best-effort: si el usuario no da permiso, queda null (no bloquea)
    try { await sb.rpc('registrar_sesion', { p_gps: gps }); } catch { /* lo revisa el timer */ }
  }
  // Control de acceso por horario (despachadores): si está fuera de su turno, no ingresa.
  try {
    const acc = await sb.rpc('mi_acceso_horario');
    if (acc.data && acc.data.permitido === false) {
      const d = acc.data;
      const msg = d.tiene_turno
        ? `Fuera de tu horario. Tu turno de hoy es ${d.hora_inicio || '—'}–${d.hora_fin || '—'}.\nNo puedes ingresar ahora.`
        : 'No tienes turno asignado para hoy.\nPide al administrador que te asigne el horario.';
      sessionUser = null;
      alert(msg);
      await sb.auth.signOut({ scope: 'local' });
      return;
    }
  } catch { /* si la RPC aún no existe, no bloquea el ingreso */ }
  // Registrar configs de las tablas de despacho del despachador (por si la lectura general falla)
  for (const t of (CTX?.tablas || [])) { if (t.tabla && !TABLES[t.tabla]) TABLES[t.tabla] = configTablaPuesto(t.label); }
  await registerPuestoTables();
  // Auditor: descubre en qué tablas de puesto tiene despachos de sus rutas (para el menú)
  if (CTX?.rol === 'auditor') { try { CTX.auditTables = await tablasAuditablesDePuesto(); } catch { CTX.auditTables = []; } }
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
  // Sesión única por usuario (TODOS los roles): vigilar que esta siga siendo la
  // sesión vigente; si otro equipo inicia sesión con la misma cuenta, aquí se cierra.
  if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
  sessionUser = user;
  sessTimer = setInterval(() => { verificarSesionVigente(); refreshContext(); checkAsistenciaPendiente(); }, 12000);
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
  if (error) {
    err.textContent = 'Correo o contraseña incorrectos.'; err.hidden = false;
    // Auditoría: registrar el intento fallido (correo probado + dispositivo)
    try { await sb.rpc('registrar_intento_fallido', { p_email: $('email').value.trim(), p_user_agent: navigator.userAgent }); } catch { /* no bloquea */ }
  } else { pendingRegister = true; } // login nuevo: showApp registrará esta sesión como la activa
});

// Ojo para mostrar/ocultar la contraseña en el login
$('toggle-pass')?.addEventListener('click', () => {
  const inp = $('password'), btn = $('toggle-pass');
  const ver = inp.type === 'password';
  inp.type = ver ? 'text' : 'password';
  btn.textContent = ver ? '🙈' : '👁️';
  btn.classList.toggle('on', ver);
  btn.setAttribute('aria-pressed', ver ? 'true' : 'false');
  const txt = ver ? 'Ocultar contraseña' : 'Mostrar contraseña';
  btn.setAttribute('aria-label', txt); btn.title = txt;
  inp.focus();
});

$('logout-btn').addEventListener('click', async () => {
  try { await sb.rpc('registrar_cierre'); } catch { /* auditoría no bloquea el logout */ }
  await sb.auth.signOut({ scope: 'local' }); // solo este dispositivo (no revocar otras sesiones del usuario)
});

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
  const prevDesp = PREVIEW && PREVIEW.rol !== 'auditor';
  const prevAud = PREVIEW && PREVIEW.rol === 'auditor';
  if (isAdmin()) addNavAction(nav, '👁️', prevDesp ? `Viendo: ${PREVIEW.nombre}` : 'Ver como despachador', openPreviewDespachador, 'nav-preview');
  if (isAdmin()) addNavAction(nav, '🔎', prevAud ? `Viendo: ${PREVIEW.nombre}` : 'Ver como auditor', openPreviewAuditor, 'nav-preview-aud');
  if (isAdmin()) addNavAction(nav, '📌', 'Asignar puesto', openAsignarPuesto, 'nav-puesto');
  if (isAdmin()) addNavAction(nav, '🗂️', 'Puestos hoy', openTablero, 'nav-tablero');
  if (isAdmin()) addNavAction(nav, '📡', 'Despachos SONAR', openDsonar, 'nav-dsonar');
  if (isAdmin()) addNavAction(nav, '👥', 'Conectados', openConectados, 'nav-conectados');
  if (isAdmin()) addNavAction(nav, '🔐', 'Auditoría de accesos', openAuditoria, 'nav-auditoria');
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
  // Si el mapa está flotante, NO lo ocultamos: debe seguir visible mientras se despacha
  if (!mapaFlotante) { $('map-view').hidden = true; if (mapTimer) { clearInterval(mapTimer); mapTimer = null; } }
  $('table-view').hidden = false;
  clearTimeout(searchTimer); // cancela una búsqueda con debounce pendiente de la tabla anterior
  current = name; page = 0; term = ''; filters = {}; $('search').value = '';
  // Si la tabla tiene filtro de fecha (calendario), arranca mostrando el DÍA ACTUAL
  // (no "todas las fechas"): así se ve el día completo y nunca topa el límite de filas.
  const fDate = (TABLES[name].filters || []).find((f) => f.type === 'date');
  if (fDate) filters[fDate.col] = hoyServidor();
  const fMulti = (TABLES[name].filters || []).find((f) => f.type === 'multidate');
  if (fMulti) filters[`${fMulti.col}::in`] = [hoyServidor()];
  $('table-title').textContent = TABLES[name].label;
  actualizarPuestoBadge(); // muestra "📌 Puesto" para identificar en qué puesto estamos
  // "Despachar" de la barra: oculto en todas partes. El despacho se hace con el botón
  // verde de cada fila, o con "+ Nuevo" (despacho manual) en Despachos.
  $('dispatch-btn').hidden = true;
  $('count-btn').hidden = !TABLES[name].dispatchable;                  // Contador: en tablas de despacho
  soloPendientes = false;                                              // al cambiar de tabla, ver todas
  $('pend-btn').hidden = !TABLES[name].dispatchable;                   // "Solo pendientes": en tablas de despacho
  $('pend-btn').classList.remove('on'); $('pend-btn').textContent = '⏳ Solo pendientes';
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
  $('perfil-kick-btn').hidden = name !== 'perfiles' || !isAdmin(); // expulsar sesión: solo admin en Perfiles
  // sin "+ Nuevo" donde no aplica (el auditor no crea; tampoco en la vista previa "como auditor")
  $('new-btn').hidden = !!TABLES[name].readonly || !!TABLES[name].noCreate || isAuditor() || (PREVIEW && PREVIEW.rol === 'auditor');
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
  const cfg = TABLES[current];
  // En una tabla de puesto, el filtro de Ruta solo muestra las rutas que EXISTEN en esa tabla
  const esTablaPuesto = source === 'rutas' && !!cfg?.puesto;
  // El scope separa el caché por vista previa: admin normal ve todas; en vista previa, solo las del puesto simulado
  const scope = source === 'rutas' && PREVIEW ? '::prev:' + PREVIEW.email : '';
  const ckey = source + (esTablaPuesto ? '::' + current : '') + scope;
  if (_checkOptsCache[ckey]) return _checkOptsCache[ckey];
  const r = await sb.from(source).select('id,nombre').order('nombre');
  let opts = (r.data || []).map((x) => [x.id, x.nombre]);
  if (source === 'rutas') {
    if (esTablaPuesto) {
      // Solo las rutas presentes en ESTA tabla (RLS ya limita las filas del despachador)
      const { data } = await sb.from(current).select('ruta_id').not('ruta_id', 'is', null).limit(5000);
      const ids = new Set((data || []).map((x) => Number(x.ruta_id)));
      opts = opts.filter(([id]) => ids.has(Number(id)));
    } else if (filtraComoDespachador()) {
      // Despachos general: el despachador (o admin en vista previa) solo ve sus rutas permitidas
      const permIds = PREVIEW ? PREVIEW.ids : (CTX?.ids || []);
      const allow = new Set((permIds || []).map(Number));
      opts = opts.filter(([id]) => allow.has(Number(id)));
    }
  }
  _checkOptsCache[ckey] = opts;
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
function applyQueryFilters(qy, opts = {}) {
  const cfg = TABLES[current];
  // Filtro base fijo de la tabla (ej. ocultar vehículos desvinculados del parque)
  (cfg.baseFilter || []).forEach((bf) => {
    if (bf.op === 'neq') qy = qy.neq(bf.col, bf.val);
    else if (bf.op === 'eq') qy = qy.eq(bf.col, bf.val);
  });
  if (!opts.skipSearch && term && cfg.searchCols?.length) {
    // En la sintaxis de PostgREST or(...), los caracteres , ( ) " \ rompen el filtro
    // (la coma separa condiciones, los paréntesis agrupan). Se sustituyen por espacio;
    // un término de búsqueda no los necesita.
    const safe = term.replace(/[,()"\\]/g, ' ').trim();
    if (safe) qy = qy.or(cfg.searchCols.map((c) => `${c}.ilike.%${safe}%`).join(','));
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
// Alterna entre ver TODA la programación del día y ver solo lo que falta por despachar
$('pend-btn').addEventListener('click', () => {
  soloPendientes = !soloPendientes;
  const b = $('pend-btn');
  b.classList.toggle('on', soloPendientes);
  b.textContent = soloPendientes ? '📋 Ver todas' : '⏳ Solo pendientes';
  page = 0;
  loadData();
});
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
  const a = toDate(ingresoEn), b = toDate(salidaEn);
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
  const ms = Date.now() - toDate(desdeISO).getTime();
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
$('refresh-btn').addEventListener('click', () => { _estadoMovilesTs = 0; loadData(); }); // refresca datos + estado GPS
$('prev-btn').addEventListener('click', () => { if (page > 0) { page--; loadData(); } });
$('next-btn').addEventListener('click', () => { page++; loadData(); });

// ¿La fila coincide con el texto buscado? Mira las columnas visibles (móvil, ruta,
// conductor, etc., incluidas las relaciones) + searchCols + placas. Búsqueda en cliente.
function rowMatchesTerm(cfg, row, t) {
  const q = String(t || '').toLowerCase();
  const vals = [];
  for (const c of (cfg.columns || [])) vals.push(c.path ? getPath(row, c.path) : row[c.key]);
  for (const k of (cfg.searchCols || [])) vals.push(row[k]);
  vals.push(getPath(row, 'veh.placa'), getPath(row, 'vehp.placa'));
  return vals.some((v) => v != null && String(v).toLowerCase().includes(q));
}
async function loadData() {
  const cfg = TABLES[current];
  const reqTabla = current, reqPage = page; // firma de la petición: si cambia durante el await, se descarta
  refrescarFechaServidor(); // mantiene al día la fecha del servidor (sin bloquear el render)
  $('tbody').innerHTML = ''; $('loading').hidden = false; $('empty').hidden = true; // limpia YA (evita ver la tabla anterior "congelada")
  // Día completo: si hay un día seleccionado en el calendario, se muestra TODA la
  // programación de ese día sin paginar.
  const diaSel = !!filters['fecha'] && (cfg.filters || []).some((f) => f.col === 'fecha' && f.type === 'date');
  // Con el día completo cargado, la búsqueda se hace en el cliente (así busca por
  // móvil, ruta, conductor, placa… que son relaciones y no se pueden filtrar en el servidor).
  const useClientSearch = diaSel && !!term;
  const from = page * PAGE_SIZE, to = from + PAGE_SIZE - 1;

  let qy = sb.from(current).select(cfg.select, { count: 'exact' })
    .order(cfg.defaultOrder.col, { ascending: cfg.defaultOrder.asc, nullsFirst: false });
  if (cfg.defaultOrder.then) { // orden secundario (ej. desempatar por hora dentro del mismo día)
    qy = qy.order(cfg.defaultOrder.then.col, { ascending: cfg.defaultOrder.then.asc, nullsFirst: false });
  }
  qy = diaSel ? qy.range(0, 4999) : qy.range(from, to); // día completo trae todo; si no, paginado

  qy = applyQueryFilters(qy, { skipSearch: useClientSearch });

  // Vista previa (admin simulando): se filtran las tablas a las rutas del usuario simulado.
  // Sin rutas → no ve nada. Despachador: Despachos + Resumen. Auditor: Despachos + tablas de puesto.
  if (PREVIEW) {
    const ids = PREVIEW.ids || [];
    const filtrarPrev = PREVIEW.rol === 'auditor'
      ? (current === 'despachos' || puestoTables.includes(current))
      : (current === 'despachos' || current === 'resumen');
    if (filtrarPrev) qy = ids.length ? qy.in('ruta_id', ids) : qy.eq('ruta_id', -1);
  }

  // Parque automotor: el despachador (y el admin en vista previa) solo ve los carros de SU(S)
  // grupo(s) del parque (derivados de sus rutas vía ruta_grupos). La columna 'ruta' del parque
  // es el nombre del grupo (ej. "Laureles"). El admin sin vista previa los ve todos.
  if (current === 'parque_automotor' && filtraComoDespachador()) {
    const grupos = [...gruposDeMisRutas(await loadRutaGrupos())];
    if (grupos.length) qy = qy.in('ruta', grupos);
  }

  const { data, error, count } = await qy;
  // El usuario cambió de tabla o de página mientras respondía esta consulta: descartar
  // la respuesta vieja para no pintar datos de otra vista sobre la actual.
  if (reqTabla !== current || reqPage !== page) return;
  $('loading').hidden = true;
  if (error) { toast('Error al cargar: ' + error.message, 'err'); verificarSesionVigente(); return; }
  let rows = data || [];
  let total = count || 0;
  if (useClientSearch) { rows = rows.filter((r) => rowMatchesTerm(cfg, r, term)); total = rows.length; }
  // "Solo pendientes": deja solo los viajes de hoy que faltan por despachar (ordenados por hora).
  // Requiere el día completo cargado (diaSel); si no, no tendría sentido paginar pendientes.
  if (soloPendientes && cfg.dispatchable && diaSel) {
    rows = rows.filter((r) => esPendienteDespacho(cfg, r));
    total = rows.length;
  } else if (cfg.dispatchable && diaSel) {
    // AUTOMÁTICO: sube los SIN DESPACHO al comienzo (por hora) para que el despachador
    // vea de una lo próximo por despachar; lo ya resuelto queda debajo, también por hora.
    rows = rows.slice().sort((a, b) => {
      const pa = esPendienteDespacho(cfg, a) ? 0 : 1;
      const pb = esPendienteDespacho(cfg, b) ? 0 : 1;
      if (pa !== pb) return pa - pb;
      return String(a.hora || '').localeCompare(String(b.hora || ''));
    });
  }
  // Si la tabla tiene columna de QR, asegura el generador antes de pintar
  if ((cfg.columns || []).some((c) => c.qr)) { try { await ensureQRGen(); await ensureLogo(); } catch { /* */ } }
  // Estado GPS de los móviles (color junto al número), igual que en el mapa
  if (cfg.dispatchable) { try { await cargarEstadoMoviles(cfg); } catch { /* */ } }
  renderTable(cfg, rows, total, diaSel);
}

// Íconos SVG (se ven iguales en Android/escritorio, sin depender de emojis)
const ICON = {
  send: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M22 2 11 13"/><path d="M22 2 15 22 11 13 2 9z"/></svg>',
  ban: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><circle cx="12" cy="12" r="9"/><path d="M5.6 5.6 18.4 18.4"/></svg>',
  edit: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 20h9"/><path d="M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z"/></svg>',
  trash: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 6h18"/><path d="M8 6V4h8v2"/><path d="M6 6l1 14h10l1-14"/></svg>',
};

// Estados en los que un viaje AÚN falta por despachar (SIN DESPACHO o intento fallido a SONAR).
// Todo lo demás (SI, DESPACHADO, NO REALIZA, CANCELADO…) ya tiene decisión y NO es pendiente.
const PENDIENTE_DESP = new Set(['', 'SIN DESPACHO', 'PENDIENTE SONAR']);
// Un viaje está PENDIENTE por despachar si es de hoy, aún no tiene regId de SONAR
// y su estado de despacho sigue "sin despacho".
function esPendienteDespacho(cfg, row) {
  if (!cfg || !cfg.dispatchable) return false;
  const frow = row.fecha ? String(row.fecha).slice(0, 10) : '';
  if (frow !== hoyServidor()) return false;   // solo el día de HOY
  if (row.sonar_regid) return false;          // ya despachado en SONAR
  const est = String(row.estado_despacho || '').trim().toUpperCase();
  return PENDIENTE_DESP.has(est);
}

// Carga el estado GPS de cada móvil (encendido/movimiento/apagado) desde `ubicaciones`,
// la misma tabla que alimenta el mapa. Se cachea ~30s para no recargar en cada filtro.
async function cargarEstadoMoviles(cfg) {
  if (!cfg || !cfg.dispatchable) return;
  if (Date.now() - _estadoMovilesTs < 30000 && estadoMoviles.size) return;
  const { data, error } = await sb.from('ubicaciones').select('movil, speed, motor').not('movil', 'is', null);
  if (error) return;
  estadoMoviles.clear();
  (data || []).forEach((r) => { if (r.movil != null) estadoMoviles.set(String(r.movil).trim(), clasificar(r)); });
  _estadoMovilesTs = Date.now();
}

// Actualiza la barra "próximo por despachar": cuántos faltan, cuál sigue y cuántos
// van atrasados. `pend` = [{ tr, hora, row }] de las filas pendientes ya pintadas.
function actualizarProximoBar(cfg, pend, diaSel) {
  const bar = $('proximo-bar');
  if (!bar) return;
  const fSel = filters['fecha'] ? String(filters['fecha']).slice(0, 10) : '';
  const aplica = !!cfg.dispatchable && diaSel && fSel === hoyServidor();
  if (!aplica) { bar.hidden = true; return; }

  if (!pend.length) { // no queda nada por despachar hoy
    bar.hidden = false;
    bar.className = 'proximo-bar ok';
    bar.innerHTML = '<span class="pb-ico">✅</span> Todos los viajes de hoy están despachados';
    return;
  }

  const now = new Date();
  const nowHM = String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0');
  const orden = pend.slice().sort((a, b) => a.hora.localeCompare(b.hora));
  let atrasados = 0;
  for (const p of orden) {
    if (p.hora && p.hora < nowHM) { atrasados++; p.tr.classList.add('tr-late'); }
  }
  const sigue = orden[0];               // el próximo por despachar (hora más temprana)
  sigue.tr.classList.add('tr-next');
  const r = sigue.row;
  const movil = getPath(r, 'vehp.numero') || getPath(r, 'veh.numero') || '—';
  const ruta = getPath(r, 'ruta.nombre') || '';
  const sigTxt = `Sigue: <b>${esc(sigue.hora || '')}</b> · Móvil <b>${esc(String(movil))}</b>${ruta ? ' · ' + esc(String(ruta)) : ''}`;
  const faltan = `Faltan <b>${pend.length}</b> por despachar`;
  const atr = atrasados ? `<span class="pb-late">⏰ ${atrasados} atrasado${atrasados > 1 ? 's' : ''}</span> · ` : '';
  bar.hidden = false;
  bar.className = 'proximo-bar' + (atrasados ? ' late' : '');
  bar.innerHTML = `<span class="pb-ico">🚌</span> ${atr}${faltan} · ${sigTxt} <span class="pb-hint">(toca para ir)</span>`;
  bar.onclick = () => { sigue.tr.scrollIntoView({ behavior: 'smooth', block: 'center' }); sigue.tr.classList.add('tr-flash'); setTimeout(() => sigue.tr.classList.remove('tr-flash'), 1200); };
}

function renderTable(cfg, rows, count, diaSel = false) {
  const head = $('thead-row'); head.innerHTML = '';
  // Columnas de auditoría (auditCol) y sensibles (despHide, ej. cédula/código del conductor):
  // solo las ven el admin y el auditor; al despachador se le ocultan.
  const cols = cfg.columns.filter((c) =>
    !(c.auditCol && !efIsAdmin() && !efIsAuditor()) &&
    !(c.despHide && !efIsAdmin() && !efIsAuditor()));
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
  const pend = []; // filas pendientes por despachar (para la barra "próximo")

  // Conteo de viajes DESPACHADOS por móvil (se calcula en el frontend sobre las filas ya
  // cargadas del día; se muestra junto al número de móvil). No consulta a la base.
  const despByMovil = {};
  if (cfg.dispatchable) {
    for (const r of rows) {
      const est = String(r.estado_despacho || '').toUpperCase();
      const mv = r.veh && r.veh.numero;
      if (mv != null && String(mv).trim() !== '' && (est === 'DESPACHADO' || est === 'SI' || r.sonar_regid)) {
        const k = String(mv).trim();
        despByMovil[k] = (despByMovil[k] || 0) + 1;
      }
    }
  }

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
      // Columna de gestión de documentos (admin y despachador): botón que abre el gestor del vehículo
      if (c.docsbtn) {
        if (isAdmin() || CTX?.rol === 'despachador') {
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
      } else if (cfg.dispatchable && (c.path === 'veh.numero' || c.path === 'vehp.numero') && val != null && String(val).trim() !== '') {
        // Punto de estado GPS junto al número de móvil (verde=movimiento, ámbar=detenido, gris=apagado)
        const est = estadoMoviles.get(String(val).trim());
        const t = est ? ESTADO_TXT[est] : 'Sin señal GPS';
        let html = `<span class="gps-dot ${est || 'none'}" title="${esc(t)}"></span>${esc(fmt(val))}`;
        // Conteo de viajes despachados hoy por este móvil (solo en la columna "Móvil" real)
        if (c.path === 'veh.numero') {
          const n = despByMovil[String(val).trim()];
          if (n) html += ` <span class="movil-count" title="${n} viaje(s) despachado(s) hoy por el móvil ${esc(String(val))}">${n}</span>`;
        }
        td.innerHTML = html;
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
        if (cfg.dispatchable && !efIsAuditor()) { // el auditor no despacha ni cancela: solo audita
          const dsp = Object.assign(document.createElement('button'), { className: 'act act-go', innerHTML: ICON.send });
          if (row.sonar_regid) {
            dsp.title = 'Ya despachado (regId ' + row.sonar_regid + ')';
            dsp.onclick = () => toast('Ya despachado en SONAR (regId ' + row.sonar_regid + ').', 'ok');
          } else if (esPasada) {
            dsp.title = 'Fecha ya pasada: no se puede despachar';
            dsp.onclick = () => toast('No se puede despachar: la fecha del viaje ya pasó.', 'err');
          } else if (esFutura) {
            dsp.title = 'Fecha adelantada: solo se despacha el día actual';
            dsp.onclick = () => toast('Solo se despacha el día de HOY. Esta fila es de otra fecha (' + frow + ').', 'err');
          } else {
            dsp.title = 'Despachar en SONAR';
            dsp.onclick = () => openSonar(row);
          }
          act.appendChild(dsp);
          // Cancelar SOLO tiene sentido si el viaje YA se despachó (tiene regId de SONAR).
          // Un viaje SIN DESPACHO no se cancela: no se muestra el botón.
          if (row.sonar_regid) {
            const can = Object.assign(document.createElement('button'), { className: 'act act-stop', innerHTML: ICON.ban });
            if (esPasada) {
              can.title = 'Fecha ya pasada: no se puede cancelar';
              can.onclick = () => toast('No se puede cancelar: la fecha del viaje ya pasó.', 'err');
            } else if (esFutura) {
              can.title = 'Fecha adelantada: solo se cancela el día actual';
              can.onclick = () => toast('Solo se cancela el día de HOY. Esta fila es de otra fecha (' + frow + ').', 'err');
            } else {
              can.title = 'Cancelar en SONAR';
              can.onclick = () => openCancelar(row);
            }
            act.appendChild(can);
          }
        }
        // Eventos del bus en SONAR: herramienta de AUDITORÍA (velocidad contra el límite de la
        // vía, pasos por las geocercas de control, puertas abiertas en marcha, retrasos).
        // Igual que las columnas de control: la ven el auditor y el admin, el despachador NO.
        if (cfg.eventosSonar && (efIsAdmin() || efIsAuditor())) {
          const ev = Object.assign(document.createElement('button'),
            { className: 'act act-evt', innerHTML: '🔎', title: 'Eventos del bus en SONAR (auditoría)' });
          ev.onclick = () => abrirEventosAuditor(row);
          act.appendChild(ev);
        }
        // Editar: el admin y el auditor siempre; el despachador TAMBIÉN en su tabla de puesto
        // (la RLS lo limita a sus propias filas y a su horario). Antes solo admin/auditor
        // tenían el lápiz; el despachador ahora puede editar los campos del viaje, no solo despachar.
        if (efIsAdmin() || efIsAuditor() || filtraComoDespachador()) {
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
    // Marca las filas que aún faltan por despachar (solo el día de hoy)
    if (esPendienteDespacho(cfg, row)) {
      tr.classList.add('tr-pend');
      pend.push({ tr, hora: String(row.hora || '').slice(0, 5), row });
    }
    body.appendChild(tr);
  }

  actualizarProximoBar(cfg, pend, diaSel);

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
  // La caché se separa por vista previa: si el admin simula a un despachador, sus
  // rutas filtradas NO deben quedar cacheadas para el admin (ni al revés).
  // La clave incluye las rutas del contexto: si el admin reasigna las rutas del despachador
  // (cambia CTX.ids), la caché no debe devolver las rutas viejas del desplegable.
  const ctxIds = fk.table === 'rutas' ? (PREVIEW ? PREVIEW.ids : (CTX?.ids || [])).join(',') : '';
  const ck = fk.table + (fk.table === 'rutas' && PREVIEW ? '::prev:' + PREVIEW.email : '') + (ctxIds ? '::ids:' + ctxIds : '');
  if (fkCache[ck]) return fkCache[ck];
  const { data, error } = await sb.from(fk.table).select(fk.sel).order(fk.order, { ascending: true }).limit(2000);
  if (error) { toast('Error opciones ' + fk.table, 'err'); return []; }
  let opts = (data || []).map((r) => ({
    value: r.id,
    label: typeof fk.label === 'function' ? fk.label(r) : r[fk.label],
  }));
  // Misma filosofía que en las tablas y en Nuevo despacho: el despachador (o el admin
  // en vista previa) solo ve SUS rutas habilitadas. Sin rutas permitidas → ninguna.
  if (filtraComoDespachador() && fk.table === 'rutas') {
    const ids = new Set((PREVIEW ? PREVIEW.ids : (CTX?.ids || [])).map(String));
    const allow = allowedRutaSet();
    if (ids.size || allow.size) {
      opts = opts.filter((o) => ids.has(String(o.value)) || allow.has(normRuta(o.label)));
    }
  }
  fkCache[ck] = opts;
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
    // El valor se fija por código (no dispara 'change'): hay que refrescar a mano el visor
    // del QR, o al cambiar de ruta seguiría mostrando un móvil que ya no está en la lista.
    vehSel._qrApply && vehSel._qrApply();
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

// En una tabla de puesto, limita el campo "Ruta" a las rutas de ese puesto (puestos.rutas).
// Aplica a todos (incluido el admin); conserva la ruta ya guardada en la fila.
const _puestoRutasCache = {};
async function loadPuestoRutas(puesto) {
  const k = String(puesto).toLowerCase();
  if (_puestoRutasCache[k]) return _puestoRutasCache[k];
  const { data } = await sb.from('puestos').select('rutas').ilike('nombre', puesto).limit(1);
  const txt = (data && data[0]?.rutas) || '';
  const set = new Set(txt.split(',').map((s) => normRuta(s)).filter(Boolean));
  _puestoRutasCache[k] = set;
  return set;
}
async function setupRouteByPuesto(form, fieldKey, puesto) {
  const sel = form.querySelector(`[data-key="${fieldKey}"]`);
  if (!sel) return;
  const permitidas = await loadPuestoRutas(puesto);
  if (!permitidas.size) return; // si el puesto no tiene rutas definidas, no se filtra
  const keep = sel.value;
  for (const o of [...sel.options]) {
    if (o.value && o.value !== keep && !permitidas.has(normRuta(o.textContent))) o.remove();
  }
  if ([...sel.options].some((o) => o.value === keep)) sel.value = keep;
  sel._comboSync && sel._comboSync();
}

// Grupos del parque que corresponden a las rutas de un despachador (vía ruta_grupos).
// En día hábil allowedGrupoSet() suele venir vacío, así que los derivamos de sus rutas.
function gruposDeMisRutas(gmap) {
  const rutasRaw = PREVIEW ? (PREVIEW.rutasRaw || []) : (CTX?.rutas || []);
  const s = new Set();
  for (const rn of rutasRaw) { const g = _grupoDeRuta(gmap, rn); if (g) s.add(g); }
  return s;
}
// Igual que setupVehByRoute pero usando el GRUPO del parque (ruta_grupos + parque_automotor).
// Misma filosofía que Nuevo despacho:
//   • Si hay ruta elegida → móviles del GRUPO de esa ruta (+ pool Integradas si es integrada).
//   • Si aún NO hay ruta → el despachador (o el admin en vista previa) ve los móviles de TODOS
//     sus grupos (derivados de sus rutas); el admin sin vista previa los ve todos.
// Conserva el móvil ya guardado en la fila y nunca deja la lista vacía (salvaguarda).
async function setupVehByGroup(form, conf) {
  const routeSel = form.querySelector(`[data-key="${conf.route}"]`);
  const vehSel = form.querySelector(`[data-key="${conf.veh}"]`);
  if (!routeSel || !vehSel) return;
  const allOpts = [...vehSel.options].map((o) => ({ value: o.value, text: o.textContent }));
  const [gmap, rmap, veh] = await Promise.all([loadRutaGrupos(), loadParqueRutas(), loadVehiculos()]);
  const numById = new Map(veh.map((v) => [String(v.id), String(v.numero).trim()]));
  const esDesp = filtraComoDespachador();
  const misGrupos = esDesp ? gruposDeMisRutas(gmap) : null; // null = admin (sin restricción)
  async function apply() {
    const keep = vehSel.value;
    const rname = (routeSel.selectedOptions[0]?.textContent || '').trim();
    const grupoRuta = _grupoDeRuta(gmap, rname);
    // Objetivo de grupos: ruta elegida > (si no) todos los grupos del despachador > (admin) sin filtro
    let objetivo = null; // null = no filtrar
    if (grupoRuta) {
      objetivo = new Set([grupoRuta]);
      if (misGrupos && misGrupos.size) objetivo = new Set([...objetivo].filter((g) => misGrupos.has(g)));
    } else if (misGrupos && misGrupos.size) {
      objetivo = new Set(misGrupos); // sin ruta: los carros de TODOS sus grupos
    }
    // Pool Integradas: si algún grupo objetivo es integrado (I/II), suma los móviles del pool
    if (objetivo && [...objetivo].some(esGrupoIntegrada)) objetivo.add(GRUPO_INTEGRADAS);
    const construir = (filtra) => {
      vehSel.innerHTML = '';
      let n = 0;
      for (const o of allOpts) {
        if (filtra && objetivo) {
          const pg = rmap.get(numById.get(String(o.value)));
          const dentro = o.value && objetivo.has(pg);
          if (!dentro && o.value !== keep) continue; // conserva el móvil ya guardado
        }
        vehSel.appendChild(Object.assign(document.createElement('option'), { value: o.value, textContent: o.text }));
        if (o.value) n++;
      }
      return n;
    };
    // Salvaguarda: si el filtro deja la lista vacía (grupo sin móviles en parque), muestra todos
    if (construir(true) === 0) construir(false);
    if ([...vehSel.options].some((o) => o.value === keep)) vehSel.value = keep;
    vehSel._comboSync && vehSel._comboSync();
    // El valor se fija por código (no dispara 'change'): hay que refrescar a mano el visor
    // del QR, o al cambiar de ruta seguiría mostrando un móvil que ya no está en la lista.
    vehSel._qrApply && vehSel._qrApply();
  }
  routeSel.addEventListener('change', apply);
  await apply();

  // Al elegir el móvil, traer el conductor (SONAR) registrado para ese carro (igual que en Despachos)
  if (conf.cond) {
    const condSel = form.querySelector(`[data-key="${conf.cond}"]`);
    const fechaEl = conf.fecha ? form.querySelector(`[data-key="${conf.fecha}"]`) : null;
    if (condSel && !condSel.disabled) {
      // Nota visible bajo el campo: deja claro que el conductor salió del Resumen
      const nota = document.createElement('div');
      nota.className = 'field-hint cond-src'; nota.hidden = true;
      (condSel.closest('.field') || condSel.parentNode).appendChild(nota);
      const traer = async () => {
        if (!vehSel.value) return;
        const nombre = await nombreConductorDeVehiculo(vehSel.value, fechaEl ? fechaEl.value : null);
        if (!nombre) return;
        const op = [...condSel.options].find((o) => (o.value || '').toLowerCase() === nombre.toLowerCase());
        if (op) {
          condSel.value = op.value;
          condSel._comboSync && condSel._comboSync();
          nota.textContent = `✓ Conductor traído del Resumen: ${op.value}`;
          nota.hidden = false;
          toast(`Conductor traído del Resumen: ${op.value}`, 'ok');
        }
      };
      vehSel.addEventListener('change', () => { nota.hidden = true; traer(); });
      condSel.addEventListener('change', () => { nota.hidden = true; }); // si lo cambian a mano, se oculta la nota
      // Al ABRIR el formulario: si el móvil ya está puesto y aún no hay conductor, tráelo del Resumen (y avisa)
      if (!condSel.value) await traer();
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

/* ===== Lector de QR: carnet del conductor y QR del bus (campos con qr:true) ===== */
// Pone un botón "📷 Escanear QR", un visor bloqueado para lo escaneado y un check
// "Elegir de la lista (sin QR)" que SOLO el usuario marca para escoger a mano.
// Escaneado  = check DESMARCADO + valor bloqueado (no editable).
// Manual     = check MARCADO + lista desplegable editable.
// El tipo decide qué se escanea; el resto del comportamiento es idéntico.
const QR_TIPOS = {
  conductor: { boton: '📷 Escanear QR', titulo: 'Escanear el carnet del conductor', scan: (s) => scanConductorToSelect(s) },
  vehiculo: { boton: '📷 Escanear QR del bus', titulo: 'Escanear el QR del bus', scan: (s) => scanVehiculoToSelect(s) },
};
function attachQrScanner(sel, tipo = 'conductor') {
  const qcfg = QR_TIPOS[tipo] || QR_TIPOS.conductor;
  const row = document.createElement('div');
  row.className = 'drv-row';
  sel.parentNode.insertBefore(row, sel);
  row.appendChild(sel); // enhanceSelect envolverá el select en .combo dentro de esta fila

  const btn = document.createElement('button');
  btn.type = 'button'; btn.className = 'qr-btn'; btn.innerHTML = qcfg.boton;
  btn.title = qcfg.titulo;
  btn.addEventListener('click', () => qcfg.scan(sel));
  row.appendChild(btn);

  // Visor de solo lectura: muestra el conductor escaneado, bloqueado.
  const locked = document.createElement('div');
  locked.className = 'qr-locked';
  const lockedName = document.createElement('span'); lockedName.className = 'qr-locked-name';
  const rescan = document.createElement('button');
  rescan.type = 'button'; rescan.className = 'qr-rescan'; rescan.textContent = '↻ Reescanear';
  rescan.addEventListener('click', () => qcfg.scan(sel));
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
  // El móvil se puede repoblar solo al cambiar la ruta (vehByGroup): así el visor
  // bloqueado no queda mostrando un carro que ya no está en la lista.
  sel.addEventListener('change', apply);
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

// Normaliza placas/números para comparar: solo letras y números, en mayúscula
// ("ABC-123", "abc 123" y "ABC123" son la misma placa).
function normPlaca(s) {
  return String(s || '').toUpperCase().replace(/[^A-Z0-9]/g, '');
}
// Escanea el QR del bus y selecciona el móvil que coincida.
// No se depende de un formato fijo del sticker: se acepta el número de móvil ("130"),
// la placa ("ABC123"), o una URL/JSON que traiga cualquiera de los dos. Si no coincide
// con ningún móvil de la lista, se avisa MOSTRANDO lo leído (para poder ajustarlo) y el
// despachador siempre puede seguir con "Elegir de la lista (sin QR)".
async function scanVehiculoToSelect(sel) {
  const text = await openQrScanner('Apunta la cámara al QR del bus…');
  if (!text) return; // cancelado o sin lectura
  const bruto = String(text).trim();
  let candidatos = [bruto];
  try { // si el QR trae JSON, se miran las claves usuales
    const j = JSON.parse(bruto);
    if (j && typeof j === 'object') {
      const c = [j.movil, j.numero, j.numero_interno, j.placa, j.plate, j.bus].filter((x) => x != null).map(String);
      if (c.length) candidatos = c;
    }
  } catch { /* no era JSON: se usa el texto tal cual */ }

  const opts = [...sel.options].filter((o) => o.value);
  // Cada opción es "130 · ABC123" (labelVeh)
  const datos = (o) => {
    const p = String(o.textContent).split('·');
    return { num: (p[0] || '').trim(), pla: (p[1] || '').trim() };
  };
  let match = null;
  for (const c of candidatos) {
    const t = normPlaca(c);
    if (!t) continue;
    match = opts.find((o) => { const p = normPlaca(datos(o).pla); return p && p === t; })            // placa exacta
      || opts.find((o) => { const n = normPlaca(datos(o).num); return n && n === t; })               // número exacto
      // el QR puede ser una URL o traer texto alrededor: se busca la placa dentro
      || opts.find((o) => { const p = normPlaca(datos(o).pla); return p.length >= 5 && t.includes(p); });
    if (match) break;
  }
  if (!match) {
    toast(`QR no reconocido: "${bruto.slice(0, 40)}". Si el bus está en la lista, marca "Elegir de la lista (sin QR)".`, 'err');
    return;
  }
  sel.value = match.value;
  sel.dispatchEvent(new Event('change', { bubbles: true })); // igual que elegirlo a mano (trae el conductor)
  if (sel._comboSync) sel._comboSync();
  if (sel._qrApply) sel._qrApply(); // muestra el móvil escaneado, bloqueado
  toast('Móvil: ' + match.textContent, 'ok');
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
function openQrScanner(pista = 'Apunta la cámara al QR del carnet…') {
  const modal = $('qr-modal'), video = $('qr-video'), status = $('qr-status');
  stopQr(); // sana cualquier cámara que hubiera quedado abierta de una apertura anterior
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
      // Si el usuario canceló mientras la cámara arrancaba, el modal ya está oculto:
      // detener el stream recién obtenido para no dejar la cámara encendida.
      if (modal.hidden) { qrStream.getTracks().forEach((t) => t.stop()); qrStream = null; return; }
      video.srcObject = qrStream;
      try { await video.play(); } catch {}
      status.className = 'qr-status'; status.textContent = pista;

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
  showBusy('Guardando documento…');
  let intentoNotif = false, notificado = false, resumenOk = '';
  try {
    let path = null, nombre = null;
    if (file) {
      if (file.size > 15 * 1024 * 1024) throw new Error('El archivo supera 15 MB.');
      const safe = file.name.replace(/[^a-zA-Z0-9._-]/g, '_');
      path = `${DOC_VEH.id}/${tipo}/${Date.now()}_${safe}`;
      showBusy('Subiendo archivo…');
      const up = await sb.storage.from('docs-vehiculos').upload(path, file, { upsert: false, contentType: file.type || undefined });
      if (up.error) throw up.error;
      nombre = file.name;
    }
    showBusy('Guardando documento…');
    const { error } = await sb.rpc('admin_guardar_doc_vehiculo', {
      p_vehiculo_id: DOC_VEH.id, p_tipo: tipo, p_fecha: fecha, p_numero: num,
      p_archivo_path: path, p_archivo_nombre: nombre, p_observacion: obs,
    });
    if (error) throw error;
    const t = DOC_TIPOS.find((x) => x.key === tipo);
    const vencAnterior = (DOC_VEH && DOC_VEH[t.col]) || null; // vencimiento que tenía ANTES de actualizar
    DOC_VEH[t.col] = fecha; if (num) DOC_VEH[t.num] = num;
    renderDocEstados(DOC_VEH);
    $('doc-file').value = ''; $('doc-obs').value = '';
    await loadDocHist(DOC_VEH.id);
    // Aviso por webhook (Pabbly → correo): SIEMPRE que se adjunte el archivo del documento,
    // sin importar el vencimiento. Manda una URL firmada temporal (7 días) para que Pabbly
    // adjunte el PDF/foto al correo.
    const bAnt = docBand(fecha || vencAnterior);
    if (path) {
      intentoNotif = true;
      showBusy('Enviando actualización a operaciones…');
      try {
        const estadoDoc = bAnt.nivel === 0 ? `Vencido (hace ${Math.abs(bAnt.dias)} días)`
          : (bAnt.nivel <= 3 ? `Próximo a vencer (${bAnt.dias} días)`
            : (bAnt.nivel === 4 ? 'Vigente' : 'Sin fecha'));
        let archivoUrl = null;
        try {
          const su = await sb.storage.from('docs-vehiculos').createSignedUrl(path, 604800);
          archivoUrl = su?.data?.signedUrl || null;
        } catch (_) { /* si no se puede firmar, va sin enlace */ }
        const { error: ne } = await sb.rpc('notificar_doc_vehiculo', { p_payload: {
          vehiculo_id: DOC_VEH.id,
          movil: DOC_VEH.numero_interno || '',
          placa: DOC_VEH.placa || '',
          ruta: DOC_VEH.ruta || '',
          tipo: t.label || tipo,
          numero: num || '',
          vence: fecha ? fechaLegible(fecha) : (vencAnterior ? fechaLegible(vencAnterior) : ''),
          vencimiento_anterior: vencAnterior ? fechaLegible(vencAnterior) : '',
          estado_doc: estadoDoc,
          archivo_nombre: nombre || '',
          archivo_path: path,
          archivo_url: archivoUrl,
          actualizado_por: miCorreo(),
          observacion: obs || '',
        } });
        if (!ne) notificado = true;
      } catch (_) { /* el webhook nunca bloquea el guardado */ }
    }
    if (current === 'parque_automotor') loadData();
    resumenOk = `${t.label} · móvil ${DOC_VEH.numero_interno || ''} (${DOC_VEH.placa || ''})\n`
      + `Vence: ${fecha ? fechaLegible(fecha) : (vencAnterior ? fechaLegible(vencAnterior) : '—')}`;
  } catch (e) { err.textContent = e.message || String(e); err.hidden = false; }
  finally { hideBusy(); btn.dataset.busy = '0'; btn.disabled = false; btn.textContent = old; }
  // Aviso final (fuera del try, ya sin overlay) para que el usuario sepa qué pasó.
  if (err.hidden) {
    let msg = resumenOk;
    if (intentoNotif) {
      msg += notificado
        ? '\n\n📧 Actualización enviada a operaciones.'
        : '\n\n⚠️ Se guardó, pero no se pudo avisar a operaciones. Revisa la conexión e inténtalo de nuevo.';
    }
    await confirmAction({ title: '✅ Documento guardado', message: msg, okLabel: 'Listo', noCancel: true });
  }
});

// ---- Alertas de vencimiento: despachador (móviles de sus rutas) / admin (toda la flota) ----
let DOC_ALERTAS = [];
async function cargarAlertasDocumentos() {
  const { data, error } = await sb.from('parque_automotor')
    .select('id,numero_interno,placa,ruta,estado,vence_soat,vence_tecnomecanica,vence_tarjeta_operacion,num_soat,num_tecnomecanica,num_tarjeta_operacion')
    .eq('estado', 'Activo').limit(5000);
  if (error || !data) return [];
  // admin: toda la flota. despachador (o admin en vista previa): solo móviles de los GRUPOS
  // de sus rutas (rutas SONAR → grupo del parque vía ruta_grupos; parque_automotor.ruta = grupo).
  let permitido = null; // null = todos (admin)
  if (filtraComoDespachador()) {
    const gmap = await loadRutaGrupos();
    permitido = new Set();
    const rutasSrc = PREVIEW ? (PREVIEW.rutasRaw || []) : (CTX?.rutas || []);
    const gruposSrc = PREVIEW ? PREVIEW.grupos : (CTX?.grupos || []);
    for (const rn of rutasSrc) { const g = _grupoDeRuta(gmap, rn); if (g) permitido.add(String(g).trim()); }
    for (const g of gruposSrc) { if (g) permitido.add(String(g).trim()); } // respaldo: grupos del horario de hoy
  }
  const out = [];
  for (const v of data) {
    if (permitido && !permitido.has(String(v.ruta || '').trim())) continue;
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
async function avisarDocsMovil(numero, boxId = 's-docwarn') {
  const box = $(boxId); if (!box) return;
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

// Campos (hermanos) que pertenecen a un título de sección: van hasta el siguiente título
function _camposDeSeccion(title) {
  const out = [];
  let el = title.nextElementSibling;
  while (el && !el.classList.contains('section-title')) { out.push(el); el = el.nextElementSibling; }
  return out;
}
// Convierte las secciones del formulario en acordeón (clic en el título = plegar/desplegar).
// Al EDITAR un despacho deja abiertas solo las secciones clave; el resto arranca plegado.
function setupCollapsibleSections(form, cfg) {
  const titles = [...form.querySelectorAll('.section-title')];
  if (titles.length <= 1) return; // sin varias secciones no hay nada que plegar
  const setCollapsed = (title, collapsed) => {
    title.classList.toggle('collapsed', collapsed);
    _camposDeSeccion(title).forEach((el) => el.classList.toggle('sec-hidden', collapsed));
  };
  const abiertas = new Set(['General', 'Real']); // lo que el despachador realmente usa
  if (isAuditor()) { abiertas.add('Indicadores'); abiertas.add('Control / Auditoría'); } // el auditor edita esas
  const plegarPorDefecto = !!cfg.dispatchable && !!editing;
  for (const t of titles) {
    if (plegarPorDefecto) setCollapsed(t, !abiertas.has(t.dataset.section || ''));
    t.addEventListener('click', () => setCollapsed(t, !t.classList.contains('collapsed')));
  }
}
// Abre todas las secciones (se usa al mostrar un error de validación para no ocultar el campo)
function expandarTodasSecciones(form) {
  form.querySelectorAll('.section-title.collapsed').forEach((t) => {
    t.classList.remove('collapsed');
    _camposDeSeccion(t).forEach((el) => el.classList.remove('sec-hidden'));
  });
}

// "Cambio (automático)" en vivo: al elegir un vehículo distinto al programado, muestra
// "programado → despachado"; si es el mismo, queda vacío. El valor se guarda al Guardar.
function setupCambioAuto(form, cfg) {
  if (!cfg.dispatchable) return;
  const selVeh = form.querySelector('[data-key="vehiculo_id"]');
  const cambioEl = form.querySelector('[data-key="cambio"]');
  if (!selVeh || !cambioEl) return;
  const progSel = form.querySelector('[data-key="vehiculo_programado_id"]');
  const numDe = (sel) => {
    if (!sel) return '';
    const o = [...sel.options].find((x) => x.value === sel.value);
    return o ? String(o.textContent || '').split('·')[0].trim() : ''; // "8174 · SMT953" → "8174"
  };
  const progNum = () => {
    const n = numDe(progSel);
    if (n) return n;
    const v = editing ? getPath(editing, 'vehp.numero') : null; // respaldo del registro
    return v != null ? String(v) : '';
  };
  const recompute = () => {
    const pn = progNum(), nn = numDe(selVeh);
    cambioEl.value = (pn && nn && pn !== nn) ? `${pn} → ${nn}` : '';
  };
  selVeh.addEventListener('change', recompute);
  recompute(); // deja el valor coherente al abrir
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

// Misma guarda que en openSonar: el formulario carga listas (conductores, móviles, rutas)
// con varios await, así que dos clics seguidos en ✏️ mezclaban los campos de una fila con
// los de otra y se podía guardar el dato equivocado sobre el viaje equivocado.
let _editorAbriendo = false;
async function openEditor(row) {
  if (_editorAbriendo) return;
  _editorAbriendo = true;
  showBusy('Abriendo…');
  try { await _openEditorInterno(row); }
  finally { _editorAbriendo = false; hideBusy(); }
}
async function _openEditorInterno(row) {
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
  // "Ya realizado": DESPACHADO, importado como "SI" (operado), o con regId de SONAR.
  // En esos casos el móvil/ruta/conductor quedan bloqueados; solo se editan observaciones y seguimiento.
  const _ed = String(row?.estado_despacho || '').toUpperCase();
  const isDispatched = !!(cfg.dispatchable && row && (_ed === 'DESPACHADO' || _ed === 'SI' || row.sonar_regid));
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

  // Agrupa los campos por sección (conservando el orden de aparición). Así, aunque un
  // campo se mueva de sección en la config, el título de esa sección no se repite.
  const _secOrden = [];
  cfg.fields.forEach((f) => { const s = f.section || ''; if (!_secOrden.includes(s)) _secOrden.push(s); });
  const camposForm = _secOrden.flatMap((s) => cfg.fields.filter((f) => (f.section || '') === s));

  for (const f of camposForm) {
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
      h.className = 'section-title'; h.dataset.section = f.section;
      h.innerHTML = `<span class="sec-caret">▾</span><span class="sec-name">${esc(f.section)}</span>`;
      form.appendChild(h);
    }

    const wrap = document.createElement(f.type === 'multisel' ? 'div' : 'label');
    wrap.className = 'field' + (f.type === 'textarea' || f.type === 'multisel' ? ' full' : '');
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
      } else if (f.type === 'multisel') {
        // Multi-selección de valores de texto (ej. grupos de ruta) → se guarda como arreglo
        input = document.createElement('div');
        input.className = 'multisel';
        const opts = await loadTextOptions(f.optionsFrom);
        const cur = new Set(Array.isArray(val) ? val.map(String) : (val != null && val !== '' ? [String(val)] : []));
        for (const o of opts) {
          const chip = document.createElement('label');
          chip.className = 'multisel-chip' + (cur.has(String(o)) ? ' on' : '');
          const cb = document.createElement('input');
          cb.type = 'checkbox'; cb.value = o; cb.checked = cur.has(String(o));
          cb.addEventListener('change', () => chip.classList.toggle('on', cb.checked));
          chip.append(cb, document.createTextNode(' ' + o));
          input.appendChild(chip);
        }
      } else if (f.type === 'enum') {
        input = document.createElement('select');
        if (!f.required) input.innerHTML = '<option value="">— ninguno —</option>';
        // Si el valor actual no está entre las opciones (ej. un DESPACHADO/PENDIENTE puesto por
        // el sistema), se agrega para no perderlo al guardar.
        const opciones = [...f.options];
        if (val != null && String(val) !== '' && !opciones.includes(String(val))) opciones.unshift(String(val));
        for (const o of opciones) {
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
      // "Cambio" es de solo lectura pero DEBE guardarse (lo calcula el sistema al cambiar el
      // móvil). Por eso va como readonly (se incluye al guardar), no como disabled. Si el
      // despacho ya se hizo, se congela (disabled) para no tocar el registro.
      if (f.autoCambio && !(isDispatched && !soyAuditor)) input.readOnly = true;
      // Un campo de auditoría (audit) se comporta como postDispatch: editable aun ya despachado
      else if (f.readOnly || (isDispatched && !f.postDispatch && !f.audit)) input.disabled = true; // solo lectura / ya despachado
      // El auditor solo edita los campos de auditoría; el resto queda de solo lectura
      if (soyAuditor && !f.audit) input.disabled = true;
      // Solo lectura "suave" para el despachador: no lo puede cambiar pero SÍ se guarda (ej. puesto)
      if (f.softReadOnlyDispatcher && !isAdmin()) input.readOnly = true;
      wrap.appendChild(input);
      if (f.hint) wrap.appendChild(Object.assign(document.createElement('span'), { className: 'field-hint', textContent: f.hint }));
      // Lector de QR junto al campo (solo donde se marca f.qr en la config):
      // carnet en el Conductor, y QR del bus en el Móvil (todas las tablas de despacho).
      if (f.qr && !input.disabled) {
        if (f.type === 'sonardrv') attachQrScanner(input, 'conductor');
        else if (f.type === 'fk') attachQrScanner(input, 'vehiculo');
      }
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
  if (cfg.routeByPuesto && cfg.puesto) await setupRouteByPuesto(form, cfg.routeByPuesto, cfg.puesto);
  if (cfg.vehByGroup) await setupVehByGroup(form, cfg.vehByGroup);

  // Buscadores en las listas largas (conductor, vehículo, ruta, etc.)
  form.querySelectorAll('select[data-type="fk"]:not(:disabled), select[data-type="sonardrv"]:not(:disabled), select[data-type="textsel"]:not(:disabled)').forEach(enhanceSelect);

  // Secciones plegables: al editar un despacho, solo General y Real quedan abiertas
  setupCollapsibleSections(form, cfg);
  // "Cambio" se recalcula solo al elegir un móvil distinto al programado
  setupCambioAuto(form, cfg);

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
    if (type === 'multisel') {
      const arr = [...el.querySelectorAll('input:checked')].map((i) => i.value);
      payload[key] = arr.length ? arr : null; continue;
    }
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
    // required fijo, o condicional (requiredWhen: obligatorio solo si otro campo tiene cierto valor,
    // ej. la novedad es obligatoria cuando el viaje NO se realizó)
    const obligatorio = f.required
      || (f.requiredWhen && f.requiredWhen.in.includes(payload[f.requiredWhen.field]));
    if (obligatorio && (payload[f.key] === null || payload[f.key] === undefined || payload[f.key] === '')) {
      expandarTodasSecciones($('edit-form')); // que no quede oculto en una sección plegada
      const motivo = f.requiredWhen ? ` (obligatoria porque el viaje no se realizó)` : '';
      err.textContent = `El campo "${f.label}" es obligatorio${motivo}.`; err.hidden = false; return;
    }
    if (f.type === 'number' && f.min != null && payload[f.key] != null && payload[f.key] < f.min) {
      err.textContent = `"${f.label}" debe ser ${f.min === 0 ? 'un número positivo' : 'mayor o igual a ' + f.min}.`; err.hidden = false; return;
    }
  }

  // Hora de cierre automática (momento de guardado)
  if (cfg.autoStamp) payload[cfg.autoStamp] = ahoraLocal();

  // Auditoría: al guardar (en Despachos o en cualquier tabla de puesto), el auditor y la
  // fecha/hora quedan registrados solos.
  if (isAuditor() && (current === 'despachos' || puestoTables.includes(current))) {
    if (CTX?.auditor_id != null) payload.auditor_id = CTX.auditor_id;
    payload.fecha_hora_auditoria = new Date().toISOString();
  }

  // Control del despachador: si marcó una DECISIÓN del viaje (SI / NO realiza…), queda
  // registrado quién y cuándo, para que el auditor sepa quién lo reportó. (El botón ✈️
  // que sí manda a SONAR ya sella esto por su cuenta; aquí es la marca manual.)
  if (cfg.dispatchable && !isAuditor()) {
    const est = String(payload.estado_despacho || '').toUpperCase();
    const decidido = est === 'SI' || est.startsWith('NO REALIZA') || est.startsWith('NO SE REALIZA');
    if (decidido) {
      if (CTX?.despachador_id != null && !payload.despachador_id) payload.despachador_id = CTX.despachador_id;
      if (!payload.despachado_en) payload.despachado_en = new Date().toISOString();
    }
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

  // Guardia de sesión: si esta sesión fue desplazada por otro equipo, sale al login con
  // aviso claro ANTES de intentar guardar (evita el "guardado" silencioso que no cambia nada).
  if (!(await verificarSesionVigente())) return;

  const saveBtn = $('modal-save');
  saveBtn.dataset.busy = '1'; saveBtn.disabled = true;
  showBusy('Guardando…'); // capa que bloquea la pantalla (evita doble clic mientras guarda)
  let res;
  try {
    if (editing) {
      const id = editing[cfg.pk];
      delete payload[cfg.pk]; // nunca actualizamos la PK
      res = await sb.from(current).update(payload).eq(cfg.pk, id).select(); // .select() => saber cuántas filas se afectaron
    } else {
      if (cfg.genKey) payload[cfg.pk] = cfg.genKey(payload); // KEY generada automáticamente
      else if (!cfg.pkEditable) delete payload[cfg.pk]; // PK autogenerada por la BD
      res = await sb.from(current).insert(payload);
    }
  } finally {
    hideBusy();
    saveBtn.dataset.busy = '0'; saveBtn.disabled = false;
  }

  if (res.error) { err.textContent = res.error.message; err.hidden = false; return; }
  // Update que no afectó ninguna fila: casi siempre la sesión fue desplazada (RLS devolvió
  // vacío). Verificar: si está muerta, ya salió al login; si no, avisar sin dejarlo en silencio.
  if (editing && (res.data || []).length === 0) {
    if (!(await verificarSesionVigente())) return;
    err.textContent = 'No se pudo guardar el cambio (sesión o permisos). Actualiza la página e inténtalo de nuevo.';
    err.hidden = false; return;
  }
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
// Separa una línea de CSV respetando comillas (soporta , o ; como delimitador)
function _splitCsvLine(line, delim) {
  const out = []; let cur = ''; let q = false;
  for (let i = 0; i < line.length; i++) {
    const c = line[i];
    if (q) {
      if (c === '"') { if (line[i + 1] === '"') { cur += '"'; i++; } else q = false; }
      else cur += c;
    } else if (c === '"') q = true;
    else if (c === delim) { out.push(cur); cur = ''; }
    else cur += c;
  }
  out.push(cur);
  return out;
}
async function parseImportFile(file, map, keyField = 'key') {
  const name = (file.name || '').toLowerCase();
  const isCsv = name.endsWith('.csv') || name.endsWith('.txt');
  let aoa;
  if (isCsv) {
    // CSV → leer como TEXTO PLANO. NO usar XLSX aquí: reinterpreta "5/07/2026" como fecha
    // de Excel/US y la daña (mes base-0, año a 2 dígitos → quedaba 0026-06-05).
    let text = await file.text();
    text = text.replace(/^﻿/, ''); // quitar BOM
    const lines = text.split(/\r\n|\r|\n/);
    const firstLine = lines.find((l) => l.trim() !== '') || '';
    const delim = (firstLine.split(';').length > firstLine.split(',').length) ? ';' : ','; // ; o ,
    aoa = lines.map((l) => _splitCsvLine(l, delim));
  } else {
    const XLSX = await import('https://esm.sh/xlsx@0.18.5');
    const buf = await file.arrayBuffer();
    const wb = XLSX.read(new Uint8Array(buf), { type: 'array', cellDates: true });
    const ws = wb.Sheets[wb.SheetNames[0]];
    aoa = XLSX.utils.sheet_to_json(ws, { header: 1, raw: true, defval: '' });
  }
  if (!aoa.length) return [];
  const headers = aoa[0].map(normH);
  const rows = [];
  for (let i = 1; i < aoa.length; i++) {
    const r = aoa[i];
    if (!r || r.every((c) => String(c == null ? '' : c).trim() === '')) continue;
    const o = {};
    headers.forEach((h, idx) => {
      const k = map[h]; if (!k) return;
      let v = r[idx];
      // Fecha real de Excel → formatearla como DD/MM/AAAA usando UTC (evita corrimiento de 1 día)
      if (v instanceof Date && !isNaN(v)) {
        v = `${String(v.getUTCDate()).padStart(2, '0')}/${String(v.getUTCMonth() + 1).padStart(2, '0')}/${v.getUTCFullYear()}`;
      }
      o[k] = v != null ? String(v) : '';
    });
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
  // No cachear vacío: si una carga falla por un parpadeo de red, se reintenta la próxima vez
  if (!vehList || !vehList.length) { const { data } = await sb.from('vehiculos').select('id,numero,placa').order('numero').limit(3000); vehList = data || []; }
  return vehList;
}
async function loadDespachadores() {
  if (!despList || !despList.length) { const { data } = await sb.from('despachadores').select('id,nombre').order('nombre').limit(2000); despList = data || []; }
  return despList;
}
function fillSelect(sel, pairs, placeholder = '— selecciona —') {
  // Se escapan value y etiqueta: aunque los datos son semi-controlados (SONAR/parque), un
  // valor con <, " o & rompería el <option> o su atributo value.
  sel.innerHTML = `<option value="">${esc(placeholder)}</option>` +
    pairs.map(([v, l]) => `<option value="${esc(v)}">${esc(l)}</option>`).join('');
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
  // Restricción: el despachador (o el admin en vista previa) sin rutas asignadas no puede despachar
  if (filtraComoDespachador() && !allowedRutaSet().size) {
    toast(PREVIEW ? `El puesto "${PREVIEW.puesto}" no tiene rutas definidas.` : 'No tienes grupos asignados hoy: no puedes despachar.', 'err');
    return;
  }
  // Reset y ABRE el modal de una vez (en iOS así siempre se ve, aunque la carga tarde o falle)
  $('nd-error').hidden = true;
  const r = $('nd-result'); r.hidden = true; r.textContent = '';
  $('nd-tipo').value = 'LIBRE'; // el despacho manual siempre es LIBRE (TABLA solo viene de importación)
  const ahora = new Date();
  $('nd-hora').value = `${_pad2(ahora.getHours())}:${_pad2(ahora.getMinutes())}`; // hora actual por defecto
  $('nd-com').value = '';
  // Muestra el puesto en el que estamos, para identificar (despachador o vista previa)
  const nip = $('nd-puesto-info'); if (nip) { const p = puestoActual(); nip.textContent = p ? '📌 Puesto: ' + p : ''; nip.hidden = !p; }
  $('nd-modal').hidden = false; // ← abre el modal YA, antes de cargar los datos
  try {
    // La fecha del despacho es SIEMPRE hoy (del servidor) y NADIE la puede tocar → evita trampas
    await refrescarFechaServidor();
    $('nd-fecha').value = hoyServidor();
    $('nd-fecha').min = hoyServidor();
    $('nd-fecha').disabled = true;

    const [its, veh, drs] = await Promise.all([
      loadItinerarios(), loadVehiculos(), loadDrivers(),
    ]);
    // Despachador (o admin en vista previa): solo itinerarios de sus rutas permitidas.
    // Coincidencia EXACTA por nombre normalizado (igual que el filtrado de las tablas): así
    // "130I" no arrastra la ruta base "130", ni "132I" arrastra "132II".
    let itList = its;
    if (filtraComoDespachador()) {
      const allow = allowedRutaSet();
      itList = its.filter((i) => allow.has(normRuta(i.nombre)));
    }
    fillSelect($('nd-ruta'), itList.map((i) => [i.itid, i.nombre])); // solo el nombre (ej. 130, 132A) para no confundir
    fillSelect($('nd-movil'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
    fillSelect($('nd-cond'), drs.map((d) => [d.dr_id, `${d.nombre || ''}${d.codigo ? ' · ' + d.codigo : ''}`]));
    // El despachador NO se puede cambiar: es el del login (solo se muestra)
    $('nd-desp').value = CTX?.despachador_id ? String(CTX.despachador_id) : '';
    $('nd-desp-name').value = CTX?.nombre || sessionUser?.email || '';
    enhanceById('nd-ruta', 'nd-movil', 'nd-cond');
    if ($('nd-estacion')) $('nd-estacion').checked = false;
    if ($('nd-estacion-wrap')) $('nd-estacion-wrap').hidden = true;
    if ($('nd-puesto-todos')) $('nd-puesto-todos').checked = false;
    if ($('nd-puesto-wrap')) $('nd-puesto-wrap').hidden = true;
    await updateNdInfo();
  } catch (e) {
    const err = $('nd-error');
    if (err) { err.textContent = 'No se pudo cargar todo el despacho: ' + (e.message || e); err.hidden = false; }
    toast('Error cargando el despacho: ' + (e.message || e), 'err');
  }
}
async function updateNdInfo() {
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('nd-movil').value);
  const info = $('nd-info');
  if (!vr) { info.hidden = true; const w = $('nd-docwarn'); if (w) w.hidden = true; return; }
  avisarDocsMovil(vr.numero, 'nd-docwarn'); // aviso de documentos vencidos / por vencer
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
    toast(`Conductor traído del Resumen: ${dm.nombre || nombre}`, 'ok');
  }
}
function closeND() { $('nd-modal').hidden = true; }
$('nd-close').addEventListener('click', closeND);
$('nd-cancel').addEventListener('click', closeND);
$('nd-movil').addEventListener('change', () => { updateNdInfo(); traerConductorND(); });

// ---- Al elegir la ruta, cargar solo los móviles de esa ruta (parque_automotor.ruta) ----
let _parqueRutas = null; // Map numero_interno -> ruta (grupo del parque)
async function loadParqueRutas() {
  if (_parqueRutas && _parqueRutas.size) return _parqueRutas; // no cachear vacío
  const { data } = await sb.from('parque_automotor').select('numero_interno,ruta').neq('estado', 'Desvinculado').limit(5000);
  _parqueRutas = new Map((data || []).map((r) => [String(r.numero_interno).trim(), String(r.ruta || '').trim()]));
  return _parqueRutas;
}
let _rutaGrupos = null; // Map ruta_sonar(minúscula) -> grupo del parque
async function loadRutaGrupos() {
  if (_rutaGrupos && _rutaGrupos.size) return _rutaGrupos; // no cachear vacío
  const { data } = await sb.from('ruta_grupos').select('ruta_sonar,grupo').limit(5000);
  _rutaGrupos = new Map((data || []).map((r) => [String(r.ruta_sonar).trim().toLowerCase(), String(r.grupo || '').trim()]));
  return _rutaGrupos;
}
// Grupo del parque al que pertenece un itinerario de SONAR (según tabla ruta_grupos)
function _grupoDeRuta(map, itinNombre) { return map.get(String(itinNombre || '').trim().toLowerCase()) || null; }
// Pool "Integradas": los móviles del grupo 'Integradas' se pueden despachar en CUALQUIER ruta
// integrada (alimentadora del metro). Un grupo es integrado si su nombre lleva un número
// seguido de I/II (ej. 130I, 132II, 136IA, 136IIA, 193I-193II).
const GRUPO_INTEGRADAS = 'Integradas';
function esGrupoIntegrada(g) { return /\d\s*i/i.test(String(g || '')); }

// ----- Vista previa "como despachador" (solo admin): simula el filtrado de un puesto -----
let previewMode = 'despachador'; // 'despachador' | 'auditor' — qué se está simulando
async function openPreviewDespachador() {
  if (!isAdmin()) return;
  previewMode = 'despachador';
  $('preview-title').textContent = '👁️ Ver como despachador';
  $('preview-label').firstChild.textContent = 'Despachador a simular';
  $('preview-hint').innerHTML = 'Verás la app <b>tal cual la vería ese despachador</b> hoy: el <b>menú</b> se reduce a sus tablas y las tablas <b>Despachos</b> y <b>Resumen</b> muestran solo sus rutas. No cambia permisos ni datos.';
  const sel = $('preview-puesto');
  sel.innerHTML = '<option value="">Cargando…</option>';
  $('preview-modal').hidden = false;
  try {
    const { data, error } = await sb.rpc('preview_listar_despachadores');
    if (error) throw error;
    const list = data || [];
    if (!list.length) { sel.innerHTML = '<option value="">(sin despachadores)</option>'; return; }
    sel.innerHTML = list.map((d) => `<option value="${esc(d.email)}">${esc(d.nombre)}${d.puesto ? ' — ' + esc(d.puesto) : ' — (sin turno hoy)'}</option>`).join('');
    if (PREVIEW?.email && previewMode === 'despachador') sel.value = PREVIEW.email;
  } catch (e) {
    sel.innerHTML = '<option value="">Error al cargar</option>';
    toast('No se pudo cargar la lista de despachadores: ' + (e.message || e), 'err');
  }
}
async function openPreviewAuditor() {
  if (!isAdmin()) return;
  previewMode = 'auditor';
  $('preview-title').textContent = '🔎 Ver como auditor';
  $('preview-label').firstChild.textContent = 'Auditor a simular';
  $('preview-hint').innerHTML = 'Verás la app <b>tal cual la vería ese auditor</b>: el <b>menú</b> muestra <b>Despachos</b> y las <b>tablas de puesto</b> donde tiene despachos de sus rutas, con las columnas de control. Filtra por sus rutas. No cambia permisos ni datos.';
  const sel = $('preview-puesto');
  sel.innerHTML = '<option value="">Cargando…</option>';
  $('preview-modal').hidden = false;
  try {
    const { data, error } = await sb.rpc('preview_listar_auditores');
    if (error) throw error;
    const list = data || [];
    if (!list.length) { sel.innerHTML = '<option value="">(sin auditores)</option>'; return; }
    sel.innerHTML = list.map((a) => `<option value="${esc(a.email)}">${esc(a.nombre)}${a.rutas ? ' — ' + esc(a.rutas) : ''}</option>`).join('');
    if (PREVIEW?.email && previewMode === 'auditor') sel.value = PREVIEW.email;
  } catch (e) {
    sel.innerHTML = '<option value="">Error al cargar</option>';
    toast('No se pudo cargar la lista de auditores: ' + (e.message || e), 'err');
  }
}
async function activarPreview(email) {
  let ctx;
  try {
    const { data, error } = await sb.rpc('preview_contexto_despachador', { p_email: email });
    if (error) throw error;
    ctx = data;
  } catch (e) { toast('No se pudo activar la vista previa: ' + (e.message || e), 'err'); return; }
  if (!ctx || ctx.rol === 'sin_acceso') { toast('Ese despachador no tiene acceso activo.', 'err'); return; }
  const rutasArr = ctx.rutas || [];
  PREVIEW = {
    email, nombre: ctx.nombre || email, puesto: ctx.puesto || '(sin turno hoy)', dia_tipo: ctx.dia_tipo || '',
    rutas: new Set(rutasArr.map(normRuta)), rutasRaw: rutasArr,
    grupos: new Set(ctx.grupos || []),
    ids: (ctx.ids || []).map(Number).filter((n) => !isNaN(n)),
    tablas: ctx.tablas || [], verDespachos: false,
  };
  // ¿Mostrar la pestaña general "Despachos"? solo si hay filas para sus rutas (evita tab vacío)
  if (PREVIEW.tablas.length && PREVIEW.ids.length) {
    try {
      const { count } = await sb.from('despachos').select('id', { count: 'exact', head: true }).in('ruta_id', PREVIEW.ids);
      PREVIEW.verDespachos = (count || 0) > 0;
    } catch { /* si falla, no se muestra */ }
  }
  $('preview-modal').hidden = true;
  const nr = PREVIEW.rutasRaw.length, ng = PREVIEW.grupos.size, nt = PREVIEW.tablas.length;
  const esDomFest = ['domingo', 'festivo'].includes(PREVIEW.dia_tipo);
  $('preview-banner-txt').textContent =
    `👁️ Viendo como: ${PREVIEW.nombre} · ${PREVIEW.puesto} · ${nt} tabla(s) · ${nr} ruta(s)${esDomFest ? ' · ' + ng + ' grupo(s)' : ''}`;
  $('preview-banner').hidden = false;
  buildSidebar();
  // Alertas de documentos: ahora reflejan lo que vería ese despachador (sus grupos)
  refrescarAlertasDocs();
  // Si la tabla actual no la ve ese despachador, salta a la primera que sí; si la ve, recarga con el filtro
  const vis = visibleTables();
  if (!vis.includes(current)) { current = null; selectTable(vis[0] || 'despachos'); }
  else { renderFilters(); loadData(); } // renderFilters: refresca el filtro de rutas a las del puesto
  actualizarPuestoBadge();
  toast(`Vista previa: ${PREVIEW.nombre}`, 'ok');
}
// Tablas de puesto donde el auditor simulado tiene despachos de sus rutas (el admin ve todo,
// así que filtramos por ids en el cliente, no por RLS).
async function previewAuditTables(ids) {
  if (!ids || !ids.length) return [];
  const found = new Set();
  await Promise.all(puestoTables.map(async (t) => {
    try {
      const { count } = await sb.from(t).select('id', { count: 'exact', head: true }).in('ruta_id', ids);
      if ((count || 0) > 0) found.add(t);
    } catch { /* */ }
  }));
  return puestoTables.filter((t) => found.has(t));
}
async function activarPreviewAuditor(email) {
  let ctx;
  try {
    const { data, error } = await sb.rpc('preview_contexto_auditor', { p_email: email });
    if (error) throw error;
    ctx = data;
  } catch (e) { toast('No se pudo activar la vista previa: ' + (e.message || e), 'err'); return; }
  if (!ctx || ctx.rol === 'sin_acceso') { toast('Ese auditor no tiene rutas asignadas.', 'err'); return; }
  const rutasArr = ctx.rutas || [];
  const ids = (ctx.ids || []).map(Number).filter((n) => !isNaN(n));
  PREVIEW = {
    rol: 'auditor', email, nombre: ctx.nombre || email, puesto: '', dia_tipo: '',
    rutas: new Set(rutasArr.map(normRuta)), rutasRaw: rutasArr,
    grupos: new Set(), ids, tablas: [], verDespachos: false,
    auditTables: await previewAuditTables(ids),
  };
  $('preview-modal').hidden = true;
  $('preview-banner-txt').textContent =
    `🔎 Viendo como auditor: ${PREVIEW.nombre} · ${rutasArr.length} ruta(s) · ${PREVIEW.auditTables.length} tabla(s) de puesto`;
  $('preview-banner').hidden = false;
  buildSidebar();
  refrescarAlertasDocs();
  const vis = visibleTables();
  if (!vis.includes(current)) { current = null; selectTable(vis[0] || 'despachos'); }
  else { renderFilters(); loadData(); }
  actualizarPuestoBadge();
  toast(`Vista previa auditor: ${PREVIEW.nombre}`, 'ok');
}
function salirPreview() {
  PREVIEW = null;
  $('preview-banner').hidden = true;
  buildSidebar();
  refrescarAlertasDocs(); // vuelve a mostrar las alertas de toda la flota (admin)
  const vis = visibleTables();
  if (!vis.includes(current)) { current = null; selectTable(vis[0] || 'despachos'); }
  else { renderFilters(); loadData(); } // renderFilters: vuelve a mostrar todas las rutas (admin)
  actualizarPuestoBadge();
  toast('Vista previa desactivada', 'ok');
}
$('preview-x')?.addEventListener('click', () => { $('preview-modal').hidden = true; });
$('preview-cancel')?.addEventListener('click', () => { $('preview-modal').hidden = true; });
$('preview-ok')?.addEventListener('click', () => {
  const e = $('preview-puesto').value; if (!e) return;
  if (previewMode === 'auditor') activarPreviewAuditor(e); else activarPreview(e);
});
$('preview-exit')?.addEventListener('click', salirPreview);
async function filtrarMovilesPorRuta() {
  const sel = $('nd-movil'); if (!sel) return;
  const its = await loadItinerarios();
  const itid = $('nd-ruta').value;
  const itin = its.find((i) => String(i.itid) === String(itid));
  const veh = await loadVehiculos();
  const estChk = $('nd-estacion'), estWrap = $('nd-estacion-wrap');
  const puestoChk = $('nd-puesto-todos'), puestoWrap = $('nd-puesto-wrap');
  let lista = veh; let placeholder = '— selecciona móvil —';
  if (itin) {
    const [gmap, rmap] = await Promise.all([loadRutaGrupos(), loadParqueRutas()]);
    // El despachador solo ve móviles de SUS grupos (admin = todos)
    const allowG = allowedGrupoSet();
    // Casilla "todos los móviles de mi puesto": solo para despachador/vista previa con grupos.
    // Deja despachar CUALQUIER carro del puesto en cualquiera de sus rutas.
    const aplicaPuesto = filtraComoDespachador() && allowG && allowG.size > 0;
    const nombrePuesto = PREVIEW ? PREVIEW.puesto : (CTX?.puesto || '');
    if (puestoWrap) {
      puestoWrap.hidden = !aplicaPuesto;
      const sp2 = puestoWrap.querySelector('span');
      if (sp2 && aplicaPuesto) sp2.textContent = `Mostrar todos los móviles de mi puesto${nombrePuesto ? ' (' + nombrePuesto + ')' : ''}`;
    }
    if (!aplicaPuesto && puestoChk) puestoChk.checked = false;
    const usarPuesto = aplicaPuesto && puestoChk && puestoChk.checked;
    // Grupos del parque de la ESTACIÓN (itinerarios.grupo): todas las rutas que comparten estación
    const estacion = itin.grupo;
    const gruposEstacion = new Set(
      its.filter((i) => i.grupo === estacion).map((i) => _grupoDeRuta(gmap, i.nombre)).filter(Boolean)
    );
    const grupoRuta = _grupoDeRuta(gmap, itin.nombre);
    // El check de estación solo aparece si la estación abarca más de un grupo (y no está activo "todo el puesto")
    const aplicaEstacion = gruposEstacion.size > 1 && !usarPuesto;
    if (estWrap) {
      estWrap.hidden = !aplicaEstacion;
      const sp = estWrap.querySelector('span');
      if (sp && aplicaEstacion) sp.textContent = `Mostrar móviles de toda la estación ${estacion} (${[...gruposEstacion].join(', ')})`;
    }
    if (!aplicaEstacion && estChk) estChk.checked = false;
    const usarEstacion = aplicaEstacion && estChk && estChk.checked;
    // Objetivo de grupos: todo el puesto > toda la estación > solo el grupo de la ruta
    let objetivo;
    if (usarPuesto) {
      objetivo = new Set(allowG); // todos los grupos del puesto del despachador
    } else {
      objetivo = usarEstacion ? gruposEstacion : new Set(grupoRuta ? [grupoRuta] : []);
      // Solo intersectar cuando allowG trae grupos (domingo/festivo). En día hábil allowG
      // viene vacío pero truthy; sin la guarda .size el objetivo quedaría vacío y se
      // mostrarían TODOS los móviles de la flota (salvaguarda), anulando el filtro por grupo.
      if (allowG && allowG.size) objetivo = new Set([...objetivo].filter((g) => allowG.has(g)));
    }
    // Pool Integradas: si algún grupo objetivo es integrado (I/II), suma los móviles del pool "Integradas"
    if ([...objetivo].some(esGrupoIntegrada)) objetivo.add(GRUPO_INTEGRADAS);
    const match = veh.filter((v) => objetivo.has(rmap.get(String(v.numero).trim())));
    if (match.length) {
      lista = match;
      placeholder = usarPuesto
        ? `— ${match.length} móvil(es) del puesto${nombrePuesto ? ' ' + nombrePuesto : ''} —`
        : usarEstacion
          ? `— ${match.length} móvil(es) de la estación ${estacion} —`
          : `— ${match.length} móvil(es) de ${grupoRuta} —`;
    } else { placeholder = '— sin móviles asignados a esa ruta; se muestran todos —'; }
  } else { if (estWrap) { estWrap.hidden = true; if (estChk) estChk.checked = false; } if (puestoWrap) puestoWrap.hidden = true; }
  // Salvaguarda: la lista de móviles NUNCA debe quedar vacía. Si quedó vacía (caché sin datos),
  // recarga los vehículos y muéstralos todos para no bloquear el despacho.
  if (!lista.length) { vehList = null; lista = await loadVehiculos(); placeholder = '— selecciona móvil —'; }
  fillSelect(sel, lista.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]), placeholder);
  sel.value = ''; sel._comboSync && sel._comboSync();
  const c = $('nd-cond'); if (c) { c.value = ''; c._comboSync && c._comboSync(); }
  updateNdInfo();
}
$('nd-ruta').addEventListener('change', filtrarMovilesPorRuta);
$('nd-puesto-todos')?.addEventListener('change', filtrarMovilesPorRuta);
$('nd-estacion').addEventListener('change', filtrarMovilesPorRuta);

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

// SONAR confirmó el despacho SOLO si trae un regId real (≠ "0"). OJO: SONAR responde
// HTTP 200 ok:true con regId:"0" cuando en realidad falló (cuerpo <status>ERROR</status>).
function sonarOK(sd) { return !!(sd && sd.ok && sd.regid && String(sd.regid).trim() !== '0'); }
// Extrae el <description> del XML de SONAR para usarlo como motivo legible.
function sonarDescripcion(resp) { const m = /<description>([^<]*)<\/description>/i.exec(String(resp || '')); return m ? m[1].trim() : null; }

// SONAR falló (estando en línea): marca el despacho como PENDIENTE SONAR y avisa al webhook.
// Nunca lanza: el aviso no debe romper el flujo. Devuelve siempre.
async function reportarFalloSonar(tabla, id, motivo, extra) {
  try { if (tabla && id) await sb.from(tabla).update({ estado_despacho: 'PENDIENTE SONAR' }).eq('id', id); } catch (e) { /* */ }
  try {
    await sb.rpc('notificar_error_despacho', {
      p_payload: Object.assign({
        evento: 'despacho_sonar_fallido', tabla, despacho_id: id, motivo: String(motivo || ''),
        despachador: CTX?.nombre || sessionUser?.email || null,
      }, extra || {}),
    });
  } catch (e) { /* el webhook nunca bloquea */ }
}

// Ejecuta un despacho completo (BD + SONAR) a partir de un "intent". Lanza si hay error de red.
async function doDispatch(intent) {
  // Idempotencia: si este intent ya fue confirmado por SONAR (reintento desde la cola offline
  // tras perder la red después de despachar), NO lo reenviamos para evitar un doble despacho.
  // Se consulta solo en línea; sin conexión no bloquea el flujo offline.
  if (navigator.onLine) {
    const { data: prev, error: preErr } = await sb.from('despachos').select('sonar_regid').eq('id', intent.id).maybeSingle();
    if (preErr && isNetworkErr(preErr)) throw preErr; // sin red: se reintenta luego
    if (prev?.sonar_regid) return { ok: true, regid: prev.sonar_regid, status: 200, response: '', yaDespachado: true };
  }
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
  const datosFallo = { movil: intent.movilNum ?? null, ruta: intent.itinNombre ?? null, conductor: intent.drvNombre ?? null, fecha: intent.fecha ?? null, hora: intent.hora ?? null };
  if (se) {
    if (isNetworkErr(se)) throw se; // error de RED: a la cola, se reintenta al reconectar
    // SONAR/función falló estando en línea → queda PENDIENTE y se avisa al webhook
    await reportarFalloSonar('despachos', intent.id, se.message, datosFallo);
    return { ok: false, error: se.message };
  }
  if (sonarOK(sd)) {
    // SONAR confirmó con regId real → DESPACHADO pleno
    await sb.from('despachos').update({ sonar_regid: String(sd.regid) }).eq('id', intent.id);
  } else {
    // Respondió pero NO confirmó (ok=false, o regId "0" con <status>ERROR</status>) → PENDIENTE + webhook
    const motivo = sd?.error || sonarDescripcion(sd?.response) || 'SONAR no confirmó el despacho';
    await reportarFalloSonar('despachos', intent.id, motivo, Object.assign(datosFallo, { http_status: sd?.status ?? null, regid: sd?.regid ?? null, respuesta: (sd?.response || '').slice(0, 1000) }));
  }
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
    vehId: Number(vehVal), movilNum: vrow?.numero || null, mId: vrow?.numero ? (await gpsIdFor(vrow.numero)) : null,
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
    if (sonarOK(sd)) {
      res.className = 'sonar-result ok';
      res.textContent = '✅ Despacho creado y enviado a SONAR (HTTP ' + (sd.status ?? '') + ')'
        + '\nregId: ' + sd.regid
        + '\n📍 Ubicación registrada: ' + intent.ubicacion
        + '\n\n' + (sd.response || '').slice(0, 800);
      toast('Despacho creado y despachado', 'ok');
    } else {
      res.className = 'sonar-result err';
      res.textContent = '✅ Despacho creado, pero ⚠️ SONAR no lo confirmó: ' + (sd?.error || sonarDescripcion(sd?.response) || ('HTTP ' + (sd?.status ?? '?')))
        + '\n→ Quedó como PENDIENTE SONAR. Reenvíalo con el botón ▶ de la lista cuando SONAR responda.'
        + '\n\n' + ((sd?.response || '').slice(0, 800));
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
    masReciente = toDate(ts).getTime();
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
        const ms = toDate(r.despachado_en).getTime();
        if (!masReciente || ms > masReciente) masReciente = ms;
      }
    }));
    if (!masReciente) return null;
  }
  return Math.floor((Date.now() - masReciente) / 60000);
}

let itinList = null;
async function loadItinerarios() {
  if (!itinList || !itinList.length) { // no cachear vacío
    const { data } = await sb.from('itinerarios').select('itid,grupo,nombre').order('nombre').limit(2000);
    itinList = data || [];
  }
  return itinList;
}

let drvList = null;
async function loadDrivers() {
  if (!drvList || !drvList.length) {
    const { data } = await sb.from('conductores_sonar')
      .select('dr_id,nombre,codigo').eq('status', 'ENABLED').order('nombre').limit(3000);
    drvList = data || [];
  }
  return drvList;
}

// Muestra qué móvil/ruta están PROGRAMADOS en la fila y avisa si se va a despachar otro (cambio)
function updateSonarProg() {
  const box = $('s-prog'); if (!box) return;
  const row = sonarRow;
  const progNum = row ? (row.vehp?.numero ?? row.veh?.numero ?? null) : null;
  const progRuta = row ? (row.rutap?.nombre ?? row.ruta?.nombre ?? '') : '';
  if (progNum == null && !progRuta) { box.hidden = true; return; }
  const selTxt = $('s-mov').selectedOptions?.[0]?.textContent || '';
  const curNum = selTxt.split('·')[0].trim();
  const distinto = progNum != null && curNum && String(curNum) !== String(progNum);
  box.hidden = false;
  box.className = 'field full sonar-info' + (distinto ? ' warn' : '');
  let html = `📋 <b>Programado:</b> Móvil <b>${esc(String(progNum ?? '—'))}</b>${progRuta ? ' · Ruta ' + esc(String(progRuta)) : ''}`;
  if (distinto) html += `<br>⚠️ Vas a despachar el <b>${esc(curNum)}</b> (distinto al programado) → se registrará como <b>CAMBIO</b>.`;
  box.innerHTML = html;
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
// Guarda anti-reentrada: abrir el despacho hace varias consultas (móviles, itinerarios,
// conductores, conductor del Resumen). Si se tocaba ✈️ en una fila y enseguida en otra, las
// dos cargas se pisaban y el modal podía quedar con el viaje de una y el móvil de la otra
// → se despachaba el carro equivocado. El segundo clic se ignora hasta que termine el primero.
let _sonarAbriendo = false;
// Devuelve false si se ignoró el clic (ya había una apertura en curso), para que quien
// preselecciona campos después (ej. despacharDesdeMapa) no escriba sobre un modal a medio cargar.
async function openSonar(row) {
  if (_sonarAbriendo) return false;
  _sonarAbriendo = true;
  showBusy('Abriendo despacho…');
  try { await _openSonarInterno(row); return true; }
  finally { _sonarAbriendo = false; hideBusy(); }
}
async function _openSonarInterno(row) {
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
  // El despachador solo ve los móviles de SU(S) grupo(s) del parque (igual que el mapa y el
  // formulario de editar), para no despachar carros de otro puesto. El admin (sin vista previa)
  // los ve todos. Misma lógica que setupVehByGroup: ruta elegida > todos sus grupos.
  let vehMov = veh;
  if (filtraComoDespachador()) {
    const [gmap, rmap] = await Promise.all([loadRutaGrupos(), loadParqueRutas()]);
    const rname = (row?.ruta?.nombre || row?.rutap?.nombre || '').trim();
    const grupoRuta = _grupoDeRuta(gmap, rname);
    const misGrupos = gruposDeMisRutas(gmap);
    let objetivo = null;
    if (grupoRuta) { objetivo = new Set([grupoRuta]); if (misGrupos.size) objetivo = new Set([...objetivo].filter((g) => misGrupos.has(g))); }
    else if (misGrupos.size) objetivo = new Set(misGrupos);
    if (objetivo && [...objetivo].some(esGrupoIntegrada)) objetivo.add(GRUPO_INTEGRADAS);
    if (objetivo && objetivo.size) {
      const progNum = String(row?.veh?.numero || row?.vehp?.numero || '').trim(); // conservar el móvil programado
      const f = veh.filter((v) => objetivo.has(rmap.get(String(v.numero).trim())) || String(v.numero).trim() === progNum);
      if (f.length) vehMov = f; // salvaguarda: si el filtro quedara vacío, deja todos
    }
  }
  fillSelect($('s-mov'), vehMov.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  fillSelect($('s-itin'), its.map((i) => [i.itid, i.nombre])); // solo el nombre (ej. 130, 132A) para no confundir
  fillSelect($('s-drv'), drs.map((d) => [d.dr_id, `${d.nombre || ''}${d.codigo ? ' · ' + d.codigo : ''}`]));

  if (row) {
    const movil = row.veh?.numero || row.vehp?.numero; // real, o el programado (TABLA importada)
    if (movil) { const vr = veh.find((v) => String(v.numero) === String(movil)); if (vr) $('s-mov').value = vr.id; }
    const m = matchItinerario(its, row.ruta?.nombre || row.rutap?.nombre);
    if (m) $('s-itin').value = m.itid;
    // El conductor NO se toma de la programación de la tabla (puede estar desactualizada);
    // se trae de Resumen para la fecha del despacho (abajo). Si no hay, queda vacío.
    $('s-com').value = 'Despacho ' + (row.id || '');
  }
  enhanceById('s-mov', 's-itin', 's-drv');
  $('s-desp-name').value = CTX?.nombre || ''; // despachador = usuario en sesión (no editable)
  // "¿Se realizó el viaje?": por defecto SÍ (despachar). Solo tiene sentido sobre una fila
  // existente; en "Nuevo despacho" (sin fila) se oculta y se fuerza SÍ.
  const novOpts = (TABLES[current]?.fields || TABLES.despachos.fields).find((f) => f.key === 'estado')?.options || [];
  fillSelect($('s-novedad'), novOpts.map((o) => [o, o]));
  $('s-realizo').value = 'SI';
  $('s-realizo').closest('.field').classList.toggle('hidden-field', !row);
  aplicarSonarRealizo();
  await traerConductorSonar(); // conductor desde Resumen, según la fecha del despacho
  await updateSonarInfo();
  updateSonarProg();           // muestra el móvil programado y avisa si hay cambio
  $('sonar-modal').hidden = false;
}
// Trae el conductor registrado en Resumen para el móvil elegido (mapeado a conductor SONAR)
async function traerConductorSonar() {
  const note = $('s-cond-note');
  const setNote = (cls, txt) => { if (note) { note.hidden = false; note.className = 'field full ' + cls; note.textContent = txt; } };
  const vehId = $('s-mov').value;
  if (!vehId) { if (note) note.hidden = true; return; }
  // Conductor de Resumen para la fecha del despacho (la del viaje, no la del celular)
  const fechaDesp = sonarRow?.fecha ? String(sonarRow.fecha).slice(0, 10) : hoyServidor();
  const nombre = await nombreConductorDeVehiculo(vehId, fechaDesp);
  const sel = $('s-drv');
  if (!nombre) { // no hay resumen para ese móvil/fecha
    setNote('sonar-info warn', '⚠️ No hay conductor en el Resumen para este móvil/fecha. Selecciónalo (obligatorio).');
    return;
  }
  const drs = await loadDrivers();
  const dm = drs.find((d) => (d.nombre || '').trim().toLowerCase() === nombre.trim().toLowerCase());
  if (dm && [...sel.options].some((o) => o.value === String(dm.dr_id))) {
    sel.value = String(dm.dr_id);
    sel._comboSync && sel._comboSync();
    setNote('sonar-info ok', `✓ Conductor traído del Resumen: ${dm.nombre || nombre}`);
    toast(`Conductor traído del Resumen: ${dm.nombre || nombre}`, 'ok');
  } else { // el conductor del resumen no está en la lista SONAR
    setNote('sonar-info warn', `⚠️ El conductor del Resumen (${nombre}) no está en la lista de SONAR. Selecciónalo manualmente.`);
  }
}
function closeSonar() { $('sonar-modal').hidden = true; }
$('sonar-close').addEventListener('click', closeSonar);
$('sonar-cancel').addEventListener('click', closeSonar);
$('dispatch-btn').addEventListener('click', () => openSonar(null));
$('s-mov').addEventListener('change', () => { updateSonarInfo(); updateSonarProg(); traerConductorSonar(); });

// Alterna el modal según "¿Se realizó el viaje?": SÍ = despacho normal a SONAR;
// NO = solo se pide la novedad (obligatoria) y se marca la fila, sin llamar a SONAR.
function aplicarSonarRealizo() {
  const esNo = $('s-realizo').value !== 'SI';
  ['s-mov', 's-itin', 's-drv', 's-com'].forEach((id) => {
    const w = $(id)?.closest('.field'); if (w) w.classList.toggle('hidden-field', esNo);
  });
  if (esNo) ['s-cond-note', 's-info', 's-docwarn', 's-prog'].forEach((id) => { const e = $(id); if (e) e.hidden = true; });
  $('s-nov-wrap').hidden = !esNo;
  $('sonar-send').textContent = esNo ? 'Guardar novedad' : 'Despachar';
  if (!esNo) updateSonarProg(); // vuelve a mostrar el programado al regresar a SÍ
}
$('s-realizo').addEventListener('change', aplicarSonarRealizo);

// Marca la fila como NO realizada (con novedad obligatoria). No toca SONAR.
async function marcarNoRealiza() {
  const btn = $('sonar-send'); const err = $('sonar-error'); err.hidden = true;
  const modo = $('s-realizo').value;         // 'NO REALIZA EL VIAJE' | 'NO SE REALIZA POR OTRO MOTIVO'
  const nov = $('s-novedad').value;
  if (!sonarRow?.id) { err.textContent = 'No hay un viaje seleccionado para marcar.'; err.hidden = false; return; }
  if (!nov) { err.textContent = 'La novedad es obligatoria cuando el viaje no se realizó.'; err.hidden = false; return; }
  if (!(await verificarSesionVigente())) return; // el turno pudo terminar
  btn.dataset.busy = '1'; btn.disabled = true; showBusy('Guardando…');
  const patch = { estado_despacho: modo, estado: nov, despachado_en: new Date().toISOString() };
  if (CTX?.despachador_id != null) patch.despachador_id = CTX.despachador_id;
  try {
    const { data, error } = await sb.from(sonarTable).update(patch).eq('id', sonarRow.id).select();
    if (error) { err.textContent = 'No se pudo guardar: ' + error.message; err.hidden = false; return; }
    if (!data || !data.length) { err.textContent = 'No se guardó: tu turno terminó o el registro no es editable.'; err.hidden = false; return; }
    toast('Marcado: ' + modo, 'ok');
    closeSonar();
    if (current === sonarTable) loadData();
  } finally {
    hideBusy(); btn.dataset.busy = '0'; btn.disabled = false; aplicarSonarRealizo();
  }
}
// Si el usuario elige el conductor a mano, se oculta el aviso del Resumen
$('s-drv').addEventListener('change', () => { const n = $('s-cond-note'); if (n) n.hidden = true; });

$('sonar-send').addEventListener('click', async () => {
  const btn = $('sonar-send');
  if (btn.dataset.busy === '1') return; // evita doble click / doble despacho
  // Si el despachador marcó que el viaje NO se realizó, no se despacha a SONAR:
  // se guarda la novedad y punto.
  if ($('s-realizo').value !== 'SI') { await marcarNoRealiza(); return; }
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

  const infoFallo = {
    movil: $('s-mov')?.selectedOptions?.[0]?.textContent || null,
    ruta: sonarRow?.ruta?.nombre || sonarRow?.rutap?.nombre || null,
    fecha: sonarRow?.fecha || null, hora: sonarRow?.hora || null, mid: String(mId), itinerario: itin,
  };
  const res = $('sonar-result'); res.hidden = false;
  if (error) {
    res.className = 'sonar-result err'; res.textContent = 'Error: ' + error.message;
    if (!isNetworkErr(error)) await reportarFalloSonar(sonarTable, sonarRow?.id, error.message, infoFallo);
    return;
  }
  if (sonarOK(data)) {
    // Marcar como DESPACHADO y registrar el móvil REAL despachado.
    // El vehículo PROGRAMADO (el de la importación) se conserva siempre.
    if (sonarRow?.id) {
      const newVehId = Number($('s-mov').value) || sonarRow.vehiculo_id || null;
      const progId = sonarRow.vehiculo_programado_id || sonarRow.vehiculo_id || null;
      const huboCambio = !!(progId && newVehId && Number(progId) !== Number(newVehId));
      // Registro automático del CAMBIO de móvil (programado → despachado). No editable: lo pone el sistema.
      const numDe = (id) => { const v = veh.find((x) => Number(x.id) === Number(id)); return v ? v.numero : id; };
      const patch = {
        estado_despacho: 'DESPACHADO',
        vehiculo_id: newVehId,
        // si no había programado, se fija con el original de la fila (no se pierde)
        vehiculo_programado_id: progId || newVehId,
        // Si despacharon con OTRO carro (reemplazo), el carro programado NO realizó el viaje
        realizo_programado: !huboCambio,
        // Deja constancia del cambio (o lo limpia si se despachó el programado)
        cambio: huboCambio ? `${numDe(progId)} → ${numDe(newVehId)}` : null,
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
    res.textContent = '⚠️ SONAR no confirmó: ' + (data?.error || sonarDescripcion(data?.response) || ('Respuesta HTTP ' + (data?.status ?? '?')))
      + '\n→ Quedó como PENDIENTE SONAR. Reenvíalo con el botón ▶ cuando SONAR responda.'
      + '\n\n' + ((data?.response || '').slice(0, 1200));
    await reportarFalloSonar(sonarTable, sonarRow?.id, data?.error || sonarDescripcion(data?.response) || 'SONAR no confirmó el despacho',
      Object.assign({}, infoFallo, { http_status: data?.status ?? null, regid: data?.regid ?? null, respuesta: (data?.response || '').slice(0, 1000) }));
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
function minsDesde(ts) { return ts ? Math.floor((Date.now() - toDate(ts).getTime()) / 60000) : null; }

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

// ---------- Auditoría de accesos (admin) ----------
let AUD_ROWS = [];
async function openAuditoria() {
  if (!isAdmin()) return;
  $('aud-error').hidden = true;
  $('aud-modal').hidden = false;
  await cargarAuditoria();
}
function closeAuditoria() { $('aud-modal').hidden = true; }
async function cargarAuditoria() {
  $('aud-error').hidden = true;
  $('aud-results').innerHTML = '<div class="loading">Cargando…</div>';
  const { data, error } = await sb.rpc('listar_auditoria', { p_limit: 300 });
  if (error) {
    $('aud-results').innerHTML = '';
    $('aud-error').textContent = 'Error: ' + error.message; $('aud-error').hidden = false; return;
  }
  AUD_ROWS = data || [];
  renderAuditoria();
}
function audBadge(e) {
  const m = {
    ingreso: ['Ingreso', 'chip-green'],
    sesion_reemplazada: ['Reemplazó sesión', 'chip-red'],
    expulsado_por_admin: ['Expulsado por admin', 'chip-red'],
    intento_fallido: ['Intento fallido', 'chip-gray'],
    cierre: ['Cierre', 'chip-gray'],
  };
  const [t, c] = m[e] || [e, 'chip-gray'];
  return `<span class="chip ${c}">${esc(t)}</span>`;
}
function renderAuditoria() {
  const ev = $('aud-evento').value;
  const q = ($('aud-buscar').value || '').trim().toLowerCase();
  let rows = AUD_ROWS;
  if (ev) rows = rows.filter((r) => r.evento === ev);
  if (q) rows = rows.filter((r) => (r.email || '').toLowerCase().includes(q) || (r.nombre || '').toLowerCase().includes(q));
  if (!rows.length) { $('aud-results').innerHTML = '<div class="empty">Sin eventos con ese filtro.</div>'; return; }
  const filas = rows.map((r) => {
    const f = new Date(r.creado_en);
    const cuando = isNaN(f.getTime()) ? esc(String(r.creado_en || '')) : esc(f.toLocaleString('es-CO'));
    const disp = esc((r.user_agent || '').slice(0, 60));
    const gps = r.gps
      ? `<a href="https://maps.google.com/?q=${encodeURIComponent(r.gps)}" target="_blank" rel="noopener" title="${esc(r.gps)}">📍 ver</a>`
      : '—';
    return `<tr>
      <td>${cuando}</td>
      <td>${audBadge(r.evento)}</td>
      <td>${esc(r.nombre || '')}<br><span class="muted">${esc(r.email || '')}</span></td>
      <td>${esc(r.ip || '—')}</td>
      <td>${gps}</td>
      <td class="muted" title="${esc(r.user_agent || '')}">${disp}</td>
    </tr>`;
  }).join('');
  $('aud-results').innerHTML = `<table class="ds-table"><thead><tr>
    <th>Cuándo</th><th>Evento</th><th>Usuario</th><th>IP</th><th>GPS</th><th>Dispositivo</th>
    </tr></thead><tbody>${filas}</tbody></table>`;
}
$('aud-close').addEventListener('click', closeAuditoria);
$('aud-cancel').addEventListener('click', closeAuditoria);
$('aud-reload').addEventListener('click', cargarAuditoria);
$('aud-evento').addEventListener('change', renderAuditoria);
$('aud-buscar').addEventListener('input', renderAuditoria);

// ---------- Usuarios conectados (admin) ----------
// "hace X" a partir de una fecha
function tiempoRelativo(d) {
  const s = Math.max(0, Math.floor((Date.now() - d.getTime()) / 1000));
  if (s < 60) return 'hace instantes';
  const m = Math.floor(s / 60); if (m < 60) return `hace ${m} min`;
  const h = Math.floor(m / 60); if (h < 24) return `hace ${h} h`;
  const dd = Math.floor(h / 24); return dd === 1 ? 'ayer' : `hace ${dd} días`;
}
// color estable del avatar según el nombre
function avatarColor(str) {
  let h = 0; for (let i = 0; i < str.length; i++) h = (h * 31 + str.charCodeAt(i)) % 360;
  return `hsl(${h}, 55%, 45%)`;
}
function rolChipCls(rol) {
  const r = String(rol || '').toLowerCase();
  if (r === 'admin') return 'chip-red';
  if (r === 'auditor') return 'chip-violet';
  return 'chip-indigo';
}
let conTimer = null;
async function openConectados() {
  if (!isAdmin()) return;
  $('con-error').hidden = true;
  $('con-modal').hidden = false;
  await cargarConectados();
  if (conTimer) clearInterval(conTimer);
  conTimer = setInterval(cargarConectados, 15000); // auto-refresco mientras la pantalla está abierta
}
function closeConectados() {
  $('con-modal').hidden = true;
  if (conTimer) { clearInterval(conTimer); conTimer = null; }
}
async function cargarConectados() {
  $('con-error').hidden = true;
  $('con-results').innerHTML = '<div class="loading">Cargando…</div>';
  const { data, error } = await sb.rpc('listar_conectados', { p_minutos: 2 });
  if (error) {
    $('con-results').innerHTML = '';
    $('con-error').textContent = 'Error: ' + error.message; $('con-error').hidden = false; return;
  }
  const rows = data || [];
  if (!rows.length) { $('con-results').innerHTML = '<div class="empty">Nadie ha iniciado sesión aún.</div>'; return; }
  const online = rows.filter((r) => r.en_linea);
  const offline = rows.filter((r) => !r.en_linea);
  const card = (r) => {
    const nombre = (r.nombre || r.email || '—').trim();
    const inicial = esc(nombre[0] || '?');
    const f = new Date(r.ultimo);
    const cuando = isNaN(f.getTime()) ? '' : tiempoRelativo(f);
    const meta = r.en_linea
      ? '<span class="con-live"><span class="dot"></span>En línea</span>'
      : `<span class="con-when">${esc(cuando)}</span>`;
    const info = [];
    if (r.ruta) info.push(`📍 ${esc(r.ruta)}`);
    if (r.hora_inicio) info.push(`🕒 ${esc(r.hora_inicio)}${r.hora_fin ? '–' + esc(r.hora_fin) : ''}`);
    const infoLine = info.length ? `<div class="con-info">${info.join(' · ')}</div>` : '';
    return `<div class="con-card ${r.en_linea ? '' : 'off'}">
      <div class="con-av" style="background:${avatarColor(nombre)}">${inicial}</div>
      <div class="con-main">
        <div class="con-name">${esc(nombre)}<span class="con-chip ${rolChipCls(r.rol)}">${esc(r.rol || '—')}</span></div>
        <div class="con-mail">${esc(r.email || '')}</div>
        ${infoLine}
      </div>
      <div class="con-meta">
        ${meta}
        <button class="con-kick" data-kick="${esc(r.email)}" title="Cerrar su sesión">🚪</button>
      </div>
    </div>`;
  };
  let html = `<div class="con-head">
      <div class="con-stat on"><div class="n">${online.length}</div><div class="l">🟢 En línea ahora</div></div>
      <div class="con-stat total"><div class="n">${rows.length}</div><div class="l">Con sesión abierta</div></div>
    </div>`;
  if (online.length) html += `<div class="con-sec">En línea (${online.length})</div><div class="con-list">${online.map(card).join('')}</div>`;
  if (offline.length) html += `<div class="con-sec">Inactivos (${offline.length})</div><div class="con-list">${offline.map(card).join('')}</div>`;
  $('con-results').innerHTML = html;
  $('con-results').querySelectorAll('button[data-kick]').forEach((b) => {
    b.addEventListener('click', async () => {
      const email = b.dataset.kick;
      const ok = await confirmAction({
        title: '🚪 Cerrar sesión', lead: `Se cerrará la sesión de:\n${email}`,
        message: 'El usuario saldrá al login de inmediato.\n¿Continuar?', okLabel: 'Cerrar sesión', danger: true,
      });
      if (!ok) return;
      const res = await sb.rpc('admin_expulsar_usuario', { p_email: email });
      if (res.error) { toast('Error: ' + res.error.message, 'err'); return; }
      if (res.data?.ok) { toast('Sesión cerrada para ' + email, 'ok'); cargarConectados(); }
      else toast('No se pudo: ' + (res.data?.error || '?'), 'err');
    });
  });
}
$('con-close').addEventListener('click', closeConectados);
$('con-cancel').addEventListener('click', closeConectados);
$('con-reload').addEventListener('click', cargarConectados);

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
let mapaFlotante = false, floatTimer = null, mapViewHome = null; // ventana flotante del mapa
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
// ===== Eventos del bus en SONAR (SOLO AUDITORES) =====
// Una sola llamada (GET_TrackerEventsHistoryV2) trae lo que el auditor necesita:
// pasos por las geocercas de control ("Ingreso a CONTROL EL PALO"), excesos de
// velocidad (con el límite de la vía), puertas abiertas en marcha y avisos de retraso.
let _evtRow = null, _evtItems = [], _evtFiltro = 'todo';
// Clasifica cada evento por su texto (SONAR los manda en español, ya legibles).
function _evtTipo(e) {
  const t = String(e.evento || '').toLowerCase();
  if (/^ingreso a |^salida de /.test(t)) return 'geo';
  if (/puerta/.test(t)) return 'puerta';
  if (/retraso|ruta|itinerario/.test(t)) return 'ruta';
  if (/exceso/.test(t)) return 'exceso';
  return 'otro';
}
// Exceso REAL: la velocidad del bus supera el límite de esa vía (RoadSpeed).
function _evtExceso(e) {
  return e.velocidad != null && e.limite != null && Number(e.limite) > 0 && Number(e.velocidad) > Number(e.limite);
}
function _evtLocal(fecha, hhmm) { // 'YYYY-MM-DD' + 'HH:MM' -> valor de datetime-local
  return `${fecha}T${(hhmm || '00:00').slice(0, 5)}`;
}
// El móvil/ruta/hora vienen distinto según la tabla: en Despachos son objetos embebidos
// (veh.numero, ruta.nombre) y en Auditoría SONAR son texto plano (movil, ruta, hora_inicio).
function _evtMovil(row) { return row.veh?.numero || row.vehp?.numero || row.movil || ''; }
function _evtRuta(row) { return row.ruta?.nombre || row.rutap?.nombre || (typeof row.ruta === 'string' ? row.ruta : '') || ''; }
function _evtHora(row) { return String(row.hora || row.hora_inicio || '00:00').slice(0, 5); }
async function abrirEventosAuditor(row) {
  _evtRow = row; _evtItems = []; _evtFiltro = 'todo';
  const movil = _evtMovil(row);
  const rt = _evtRuta(row);
  $('evt-movil').textContent = `${movil}${rt ? ' · ' + rt : ''}`;
  $('evt-lista').innerHTML = ''; $('evt-resumen').textContent = '';
  $('evt-msg').textContent = '';
  document.querySelectorAll('#evt-modal .evt-chip').forEach((c) => c.classList.toggle('evt-on', c.dataset.f === 'todo'));
  // Ventana por defecto: desde la hora del viaje hasta 3 h después (un viaje típico).
  const f = String(row.fecha || hoyServidor()).slice(0, 10);
  const ini = _evtHora(row);
  const fin = new Date(`${f}T${ini}:00`); fin.setHours(fin.getHours() + 3);
  $('evt-desde').value = _evtLocal(f, ini);
  $('evt-hasta').value = `${fin.getFullYear()}-${_pad2(fin.getMonth() + 1)}-${_pad2(fin.getDate())}T${_pad2(fin.getHours())}:${_pad2(fin.getMinutes())}`;
  $('evt-modal').hidden = false;
  if (!movil) { $('evt-msg').textContent = 'Este viaje no tiene móvil asignado.'; return; }
  await verEventosAuditor();
}
async function verEventosAuditor() {
  if (!_evtRow) return;
  const movil = _evtMovil(_evtRow);
  // Auditoría SONAR ya trae el tracker (mid); en Despachos hay que buscarlo por el móvil.
  const mid = _evtRow.mid || await gpsIdFor(movil);
  const msg = $('evt-msg');
  if (!mid) { msg.textContent = '🚫 El móvil ' + movil + ' no tiene Id GPS en SONAR.'; return; }
  const desde = ($('evt-desde').value || '').replace('T', ' ');
  const hasta = ($('evt-hasta').value || '').replace('T', ' ');
  if (!desde || !hasta) { msg.textContent = 'Elige el rango de horas.'; return; }
  const btn = $('evt-ver'); btn.disabled = true; btn.textContent = 'Consultando…';
  msg.textContent = 'Consultando SONAR…'; $('evt-lista').innerHTML = '';
  try {
    const { data, error } = await sb.rpc('sonar_eventos_auditor', { p_mid: mid, p_desde: desde, p_hasta: hasta });
    if (error) { msg.textContent = 'No se pudo consultar SONAR: ' + error.message; return; }
    if (!data || !data.ok) { msg.textContent = data?.error || 'SONAR no respondió.'; return; }
    _evtItems = data.items || [];
    msg.textContent = '';
    pintarEventosAuditor();
  } finally {
    btn.disabled = false; btn.textContent = '🔎 Consultar';
  }
}
function pintarEventosAuditor() {
  const cont = $('evt-lista');
  const geo = _evtItems.filter((e) => _evtTipo(e) === 'geo').length;
  const exc = _evtItems.filter(_evtExceso).length;
  const pue = _evtItems.filter((e) => /puerta abierta/i.test(e.evento || '')).length;
  $('evt-resumen').textContent = `${_evtItems.length} eventos · ${geo} pasos por control · ${exc} excesos · ${pue} con puerta abierta`;
  const lista = _evtItems.filter((e) => {
    if (_evtFiltro === 'todo') return true;
    if (_evtFiltro === 'exceso') return _evtExceso(e) || _evtTipo(e) === 'exceso';
    return _evtTipo(e) === _evtFiltro;
  });
  if (!lista.length) { cont.innerHTML = '<div class="empty">Sin eventos de ese tipo en el rango.</div>'; return; }
  cont.innerHTML = lista.map((e) => {
    const t = _evtTipo(e);
    const ex = _evtExceso(e);
    const ico = ex ? '🚨' : t === 'geo' ? '📍' : t === 'puerta' ? '🚪' : t === 'ruta' ? '🛣️' : '•';
    const vel = (e.velocidad != null)
      ? `<span class="evt-vel ${ex ? 'evt-mal' : ''}">${esc(String(e.velocidad))}${e.limite ? ' / ' + esc(String(e.limite)) : ''} km/h</span>` : '';
    const hora = String(e.hora || '').slice(11, 16);
    return `<div class="evt-it ${ex ? 'evt-it-mal' : ''}">
      <span class="evt-h">${esc(hora)}</span>
      <span class="evt-ico">${ico}</span>
      <span class="evt-tx">${esc(e.evento || '')}${e.direccion ? `<i class="evt-dir">${esc(e.direccion)}</i>` : ''}</span>
      ${vel}
    </div>`;
  }).join('');
}
function cerrarEventos() { $('evt-modal').hidden = true; _evtRow = null; _evtItems = []; }
$('evt-x').addEventListener('click', cerrarEventos);
$('evt-cerrar').addEventListener('click', cerrarEventos);
$('evt-ver').addEventListener('click', verEventosAuditor);
document.querySelectorAll('#evt-modal .evt-chip').forEach((c) => {
  c.addEventListener('click', () => {
    _evtFiltro = c.dataset.f;
    document.querySelectorAll('#evt-modal .evt-chip').forEach((o) => o.classList.toggle('evt-on', o === c));
    pintarEventosAuditor();
  });
});

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
let _recPts = [];      // puntos del recorrido actual
let _recCursor = null; // marcador que avanza con el slider
function limpiarRecorrido() {
  if (recLayer && flotaMap) { flotaMap.removeLayer(recLayer); recLayer = null; }
  // restaura los demás vehículos al quitar el recorrido
  if (flotaLayer && flotaMap && !flotaMap.hasLayer(flotaLayer)) flotaLayer.addTo(flotaMap);
  _recPts = []; _recCursor = null;
  const b = $('rec-clear'); if (b) b.hidden = true;
  const pn = $('rec-panel'); if (pn) pn.hidden = true;
}
function dibujarRecorrido(pts, movil) {
  if (!flotaMap) return;
  limpiarRecorrido();
  // oculta la flota para ver mejor el recorrido (se restaura al quitarlo)
  if (flotaLayer && flotaMap.hasLayer(flotaLayer)) flotaMap.removeLayer(flotaLayer);
  _recPts = pts;
  recLayer = L.layerGroup().addTo(flotaMap);
  const latlngs = pts.map((p) => [p.lat, p.lon]);
  L.polyline(latlngs, { color: '#ED1C24', weight: 4, opacity: 0.85 }).addTo(recLayer);
  // puntos pequeños del trayecto (inicio verde, fin azul); sin popups (el detalle va en el panel)
  pts.forEach((p, i) => {
    const ini = i === 0, fin = i === pts.length - 1, ext = ini || fin;
    const col = ini ? '#137a2b' : (fin ? '#0b5cad' : '#ED1C24');
    L.circleMarker([p.lat, p.lon], { radius: ext ? 6 : 3, color: col, fillColor: col, fillOpacity: 0.9, weight: ext ? 2 : 1, interactive: false }).addTo(recLayer);
  });
  // cursor móvil (lo controla el slider / la lista)
  _recCursor = L.circleMarker([pts[0].lat, pts[0].lon], { radius: 9, color: '#fff', weight: 3, fillColor: '#ED1C24', fillOpacity: 1 }).addTo(recLayer);
  flotaMap.fitBounds(latlngs, { padding: [40, 40] });
  const b = $('rec-clear'); if (b) b.hidden = false;
  renderRecPanel(pts, movil);
}
// Mueve el cursor al punto i: marcador + mapa + info + slider + lista (todo sincronizado)
function recGoto(i) {
  const p = _recPts[i]; if (!p || !flotaMap) return;
  if (_recCursor) _recCursor.setLatLng([p.lat, p.lon]);
  flotaMap.panTo([p.lat, p.lon], { animate: false });
  const det = (p.vel ?? 0) === 0 ? 'detenido' : `${p.vel} km/h`;
  const info = $('rec-scrub-info'); if (info) info.innerHTML = `<b>${esc(_hora12(p.t))}</b> · ${esc(det)} · ${esc(p.dir || '')}`;
  const sl = $('rec-slider'); if (sl && +sl.value !== i) sl.value = i;
  const list = $('rec-panel-list');
  list.querySelectorAll('.rec-pt.sel').forEach((x) => x.classList.remove('sel'));
  const it = list.querySelector(`.rec-pt[data-i="${i}"]`);
  if (it) { it.classList.add('sel'); it.scrollIntoView({ block: 'nearest' }); }
}
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
  list.querySelectorAll('.rec-pt').forEach((b) => b.addEventListener('click', () => recGoto(+b.dataset.i)));
  const sl = $('rec-slider'); if (sl) { sl.min = 0; sl.max = pts.length - 1; sl.value = 0; sl.oninput = () => recGoto(+sl.value); }
  // En celular arranca con la lista oculta (mapa visible); en PC, con la lista abierta
  pn.classList.toggle('list-open', window.innerWidth > 760);
  pn.hidden = false;
  recGoto(0);
}
$('rec-panel-toggle') && $('rec-panel-toggle').addEventListener('click', () => { const p = $('rec-panel'); if (p) p.classList.toggle('list-open'); });
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
  // Seguir / dejar de seguir este móvil (para vigilar varios a la vez)
  const bSeg = Object.assign(document.createElement('button'), { className: 'btn' });
  const pintarSeg = () => {
    const on = seguidos.has(_mk(r.movil));
    bSeg.textContent = on ? '✓ Siguiendo' : '🎯 Seguir';
    bSeg.classList.toggle('btn-primary', on);
  };
  pintarSeg();
  bSeg.onclick = () => { toggleSeguir(r.movil); pintarSeg(); };
  acts.appendChild(bSeg);
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
  if (!(await openSonar(null))) return; // otra apertura en curso: no pisar sus campos
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
// Marcadores reutilizables: movil -> { marker, pos, icon }. Evita reconstruir toda la
// flota en cada refresco/filtro; solo mueve los que cambiaron de sitio y reconstruye el
// ícono si cambió su estado. Así el mapa va fluido aunque haya cientos de móviles.
let markerMap = new Map();
// Seguimiento: móviles seleccionados para vigilar. soloSeguidos = mostrar únicamente esos.
let seguidos = new Set(), soloSeguidos = false;
const _mk = (m) => String(m ?? '').trim();
const _movKey = (r) => _mk(r.movil) || (r.mid != null ? '#' + r.mid : '@' + r.latitude + ',' + r.longitude);
function toggleSeguir(movil) {
  const k = _mk(movil); if (!k) return;
  if (seguidos.has(k)) seguidos.delete(k); else seguidos.add(k);
  if (!seguidos.size) soloSeguidos = false;
  renderSeguidosBar(); renderMarkers(false);
}
function quitarSeguido(movil) {
  seguidos.delete(_mk(movil)); if (!seguidos.size) soloSeguidos = false;
  renderSeguidosBar(); renderMarkers(false);
}
function limpiarSeguidos() { seguidos.clear(); soloSeguidos = false; renderSeguidosBar(); renderMarkers(false); }
// Barra de seguidos: aparece solo cuando hay móviles seleccionados.
function renderSeguidosBar() {
  syncListaSel();
  const bar = $('map-seguidos'); if (!bar) return;
  if (!seguidos.size) { bar.hidden = true; bar.innerHTML = ''; return; }
  bar.hidden = false;
  const chips = [...seguidos].sort((a, b) => a.localeCompare(b, 'es', { numeric: true }))
    .map((m) => `<span class="seg-chip" data-m="${esc(m)}" title="Quitar">${esc(m)} <b>✕</b></span>`).join('');
  bar.innerHTML = `<span class="seg-lbl">🎯 Siguiendo (${seguidos.size}):</span>${chips}`
    + `<button class="btn seg-btn ${soloSeguidos ? 'btn-primary' : ''}" id="seg-ver">${soloSeguidos ? '🎯 Siguiendo en vivo' : '👁️ Ver en pantalla'}</button>`
    + `<button class="btn seg-btn" id="seg-clear">Limpiar</button>`;
  bar.querySelectorAll('.seg-chip').forEach((c) => c.addEventListener('click', () => quitarSeguido(c.dataset.m)));
  // "Ver en pantalla": alterna mostrar solo los seguidos y los encuadra en el mapa
  $('seg-ver').addEventListener('click', () => { soloSeguidos = !soloSeguidos; renderSeguidosBar(); renderMarkers(true); });
  $('seg-clear').addEventListener('click', limpiarSeguidos);
}
// Refleja en la lista qué móviles están seleccionados (sin reconstruirla).
function syncListaSel() {
  const box = $('ml-items'); if (!box) return;
  box.querySelectorAll('.ml-item').forEach((el) => {
    const on = seguidos.has(_mk(el.dataset.m));
    el.classList.toggle('sel', on);
    const chk = el.querySelector('.ml-check'); if (chk) chk.textContent = on ? '✓' : '';
  });
  const c = $('ml-count');
  if (c) c.textContent = seguidos.size ? `🎯 ${seguidos.size} seleccionado(s)` : 'Toca un móvil para seguirlo';
}
function fillRutaSelect() {
  const sel = $('map-ruta'); if (!sel) return;
  const prev = sel.value;
  const rutas = [...new Set(lastUbic.map((r) => r.ruta).filter(Boolean))]
    .sort((a, b) => a.localeCompare(b, 'es', { numeric: true }));
  sel.innerHTML = `<option value="">Todas las rutas (${rutas.length})</option>`
    + rutas.map((rt) => `<option value="${esc(rt)}">${esc(rt)}</option>`).join('');
  if (rutas.includes(prev)) sel.value = prev; else routeFilter = '';
}
function _buildBusIcon(r, cls, seg) {
  const ruta = r.ruta ? ` <small>${esc(r.ruta)}</small>` : '';
  return L.divIcon({
    className: 'bus-marker',
    html: `<div class="bus-pin ${cls}${seg ? ' seg' : ''}"><span>🚌</span>${esc(r.movil || '—')}${ruta}</div>`,
    iconSize: null, iconAnchor: [26, 24], popupAnchor: [0, -22],
  });
}
// Dibuja/actualiza la flota REUTILIZANDO marcadores: mueve el que cambió de sitio y
// rehace el ícono solo si cambió su estado. Nada de borrar y recrear todo en cada refresco.
function renderMarkers(fit) {
  if (!flotaLayer) return;
  const pts = [], vivos = new Set();
  for (const r of lastUbic) {
    if (r.latitude == null || r.longitude == null) continue;
    const cls = clasificar(r);
    if (mapFilter !== 'todos' && cls !== mapFilter) continue;
    if (routeFilter && (r.ruta || '') !== routeFilter) continue;
    if (vehSearch.length) {
      const m = String(r.movil || '').toLowerCase(), p = String(r.placa || '').toLowerCase();
      if (!vehSearch.some((q) => m.includes(q) || p.includes(q))) continue;
    }
    const seg = seguidos.has(_mk(r.movil));
    if (soloSeguidos && !seg) continue; // modo "ver seguidos": oculta los demás
    const key = _movKey(r);
    vivos.add(key);
    const posSig = r.latitude + ',' + r.longitude;
    const iconSig = cls + '|' + (seg ? 1 : 0) + '|' + (r.movil || '') + '|' + (r.ruta || '');
    const ex = markerMap.get(key);
    if (ex) {
      if (ex.pos !== posSig) { ex.marker.setLatLng([r.latitude, r.longitude]); ex.pos = posSig; }
      if (ex.icon !== iconSig) { ex.marker.setIcon(_buildBusIcon(r, cls, seg)); ex.icon = iconSig; }
      ex.marker._row = r;
    } else {
      const m = L.marker([r.latitude, r.longitude], { icon: _buildBusIcon(r, cls, seg), title: `Móvil ${r.movil || ''}` });
      m._row = r;
      // Un clic hace ZOOM al carro y abre su panel (usa la fila viva del marcador)
      m.on('click', () => { zoomAlMovil(m._row); openVehSheet(m._row); });
      flotaLayer.addLayer(m);
      markerMap.set(key, { marker: m, pos: posSig, icon: iconSig });
    }
    pts.push([r.latitude, r.longitude]);
  }
  // Quita los marcadores que ya no aplican (fuera del filtro o desaparecidos)
  for (const [key, ent] of markerMap) {
    if (!vivos.has(key)) { flotaLayer.removeLayer(ent.marker); markerMap.delete(key); }
  }
  const filtrando = mapFilter !== 'todos' || routeFilter || soloSeguidos || vehSearch.length;
  $('map-count').textContent = filtrando ? `${pts.length} de ${lastUbic.length}` : `${pts.length} móviles`;
  if (fit && pts.length) encuadrar(pts);
}
// Encuadra el mapa a unos puntos. Con un solo carro recentra SIN cambiarte el zoom
// (para seguirlo de cerca); con varios, ajusta la vista para verlos a todos.
function encuadrar(pts) {
  if (!flotaMap || !pts.length) return;
  if (pts.length === 1) flotaMap.setView(pts[0], Math.max(flotaMap.getZoom(), 15), { animate: true });
  else flotaMap.fitBounds(pts, { padding: [30, 30], maxZoom: 16 });
}
// Acerca el mapa a un móvil (sin alejar si ya estás más cerca).
function zoomAlMovil(r) {
  if (!flotaMap || r.latitude == null || r.longitude == null) return;
  flotaMap.flyTo([r.latitude, r.longitude], Math.max(flotaMap.getZoom(), 16), { duration: 0.6 });
}
async function refreshMapa(fit) {
  const { data, error } = await sb.from('ubicaciones').select('*').not('latitude', 'is', null);
  if (error) { toast('Error al cargar ubicaciones: ' + error.message, 'err'); verificarSesionVigente(); return; }
  // Si a un despachador le llegan 0 ubicaciones, casi siempre es que su sesión fue
  // desplazada (la RLS devuelve vacío). Verificar de una: si está muerta, sale al login
  // con el aviso; si está viva, sigue normal (no hay falso cierre: decide el servidor).
  if (!efIsAdmin() && (data || []).length === 0) { if (!(await verificarSesionVigente())) return; }
  let rows = data || [];
  // Despachador: móviles de sus RUTAS o de sus GRUPOS del parque. En 'ubicaciones'
  // muchos vehículos vienen etiquetados con el nombre del GRUPO (ej. "Laureles"),
  // no con el número de ruta (190, 191…). Sin incluir el grupo, el mapa salía en
  // "0 móviles" para puestos como Laureles. La RLS ya limita; esto ajusta la vista.
  if (!efIsAdmin()) {
    const allowR = allowedRutaSet();
    const grupos = allowedGrupoSet();
    const allowG = grupos ? new Set([...grupos].map(normRuta)) : null;
    rows = rows.filter((r) => {
      const nr = normRuta(r.ruta);
      return allowR.has(nr) || (allowG && allowG.has(nr));
    });
  }
  lastUbic = rows;
  fillRutaSelect();
  // En modo "Ver seleccionados" el mapa PERSIGUE a los carros vigilados: re-encuadra en
  // cada refresco (aunque sea el automático de 60 s) para no perderles el rastro al moverse.
  renderMarkers(fit || (soloSeguidos && seguidos.size > 0));
}
// Crea el mapa Leaflet una sola vez (lo reusan la vista completa y la ventana flotante)
function ensureFlotaMap() {
  if (flotaMap) return;
  flotaMap = L.map('map').setView([6.244, -75.58], 12); // Medellín
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19, attribution: '© OpenStreetMap',
  }).addTo(flotaMap);
  flotaLayer = L.layerGroup().addTo(flotaMap);
  flotaMap.on('click', closeVehSheet); // tocar el mapa cierra el panel
}
async function showMapView() {
  if (typeof L === 'undefined') { toast('No se pudo cargar el mapa (revisa tu conexión a internet)', 'err'); return; }
  if (mapaFlotante) cerrarMapaFlotante(); // si estaba flotante, devolver el mapa a su lugar
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
  ensureFlotaMap();
  setTimeout(() => flotaMap.invalidateSize(), 120); // el contenedor estaba oculto
  await refreshMapa(true);
  if (mapTimer) clearInterval(mapTimer);
  mapTimer = setInterval(() => refreshMapa(false), 60000); // refresco automático cada 60s
}
// ----- Mapa flotante: mueve TODO el #map-view a una ventana arrastrable -----
async function abrirMapaFlotante() {
  if (typeof L === 'undefined') { toast('No se pudo cargar el mapa (revisa tu conexión a internet)', 'err'); return; }
  const mv = $('map-view');
  if (!mapViewHome) mapViewHome = { parent: mv.parentNode, next: mv.nextSibling };
  document.getElementById('app').classList.remove('view-map');
  if (currentView === 'mapa') { currentView = 'tabla'; $('table-view').hidden = false; buildBottomNav(); }
  $('map-float-body').appendChild(mv);
  mv.hidden = false;
  $('map-float').hidden = false;
  $('map-fab').classList.add('activo');
  mapaFlotante = true;
  ensureFlotaMap();
  setTimeout(() => flotaMap.invalidateSize(), 150);
  await refreshMapa(true);
  if (floatTimer) clearInterval(floatTimer);
  floatTimer = setInterval(() => { if (mapaFlotante) refreshMapa(false); }, 60000);
}
function cerrarMapaFlotante() {
  const mv = $('map-view');
  if (mapViewHome) mapViewHome.parent.insertBefore(mv, mapViewHome.next); // devolver a su lugar
  mv.hidden = true;
  $('map-float').hidden = true;
  $('map-fab').classList.remove('activo');
  mapaFlotante = false;
  if (floatTimer) { clearInterval(floatTimer); floatTimer = null; }
}
function toggleMapaFlotante() { mapaFlotante ? cerrarMapaFlotante() : abrirMapaFlotante(); }
$('map-fab')?.addEventListener('click', toggleMapaFlotante);
$('map-float-close')?.addEventListener('click', cerrarMapaFlotante);
$('map-float-full')?.addEventListener('click', () => { cerrarMapaFlotante(); showMapView(); });
// Ocultar/mostrar los filtros del flotante para darle todo el espacio al mapa
$('map-float-controls')?.addEventListener('click', () => {
  const p = $('map-float'); if (!p) return;
  const oculto = p.classList.toggle('controls-off');
  const b = $('map-float-controls');
  if (b) { b.classList.toggle('btn-primary', oculto); b.title = oculto ? 'Mostrar filtros' : 'Ocultar filtros'; }
  if (oculto) toggleListaMoviles(false); // si estaba abierta la lista, ciérrala
  setTimeout(() => flotaMap && flotaMap.invalidateSize(), 60); // el mapa recupera el espacio
});
// Arrastrar la ventana por la barra superior y redimensionar por la esquina (mouse + touch)
(function () {
  const panel = $('map-float'), head = $('map-float-head'), rz = $('map-float-resize');
  if (!panel || !head || !rz) return;
  let sx, sy, ox, oy, drag = false;
  head.addEventListener('pointerdown', (e) => {
    if (e.target.closest('.mf-btn')) return; // no arrastrar al tocar los botones
    drag = true; head.setPointerCapture(e.pointerId);
    const r = panel.getBoundingClientRect(); ox = r.left; oy = r.top; sx = e.clientX; sy = e.clientY;
    panel.style.right = 'auto';
  });
  head.addEventListener('pointermove', (e) => {
    if (!drag) return;
    let nx = ox + (e.clientX - sx), ny = oy + (e.clientY - sy);
    nx = Math.max(0, Math.min(nx, window.innerWidth - 80));
    ny = Math.max(0, Math.min(ny, window.innerHeight - 44));
    panel.style.left = nx + 'px'; panel.style.top = ny + 'px';
  });
  const endDrag = () => { drag = false; };
  head.addEventListener('pointerup', endDrag);
  head.addEventListener('pointercancel', endDrag);
  let rw, rh, rx, ry, res = false;
  rz.addEventListener('pointerdown', (e) => {
    res = true; rz.setPointerCapture(e.pointerId);
    const r = panel.getBoundingClientRect(); rw = r.width; rh = r.height; rx = e.clientX; ry = e.clientY;
    e.preventDefault();
  });
  rz.addEventListener('pointermove', (e) => {
    if (!res) return;
    panel.style.width = Math.max(240, rw + (e.clientX - rx)) + 'px';
    panel.style.height = Math.max(200, rh + (e.clientY - ry)) + 'px';
    if (flotaMap) flotaMap.invalidateSize();
  });
  const endRes = () => { res = false; if (flotaMap) flotaMap.invalidateSize(); };
  rz.addEventListener('pointerup', endRes);
  rz.addEventListener('pointercancel', endRes);
})();
$('map-refresh').addEventListener('click', () => refreshMapa(true));
document.querySelectorAll('#map-filters .mf').forEach((b) => {
  b.addEventListener('click', () => {
    mapFilter = b.dataset.f;
    document.querySelectorAll('#map-filters .mf').forEach((x) => x.classList.toggle('active', x === b));
    renderMarkers(true);
  });
});
$('map-ruta').addEventListener('change', (e) => { routeFilter = e.target.value; renderMarkers(true); });
// Buscador del mapa con "debounce": no redibuja en cada tecla, sino ~200 ms después de
// dejar de escribir. Con cientos de móviles esto quita el tironeo al teclear.
let _searchTimer = null;
$('map-search').addEventListener('input', (e) => {
  const v = e.target.value.toLowerCase();
  clearTimeout(_searchTimer);
  _searchTimer = setTimeout(() => {
    vehSearch = v.split(/[\s,]+/).map((s) => s.trim()).filter(Boolean);
    renderMarkers(true);
  }, 200);
});

// ----- Lista buscable de móviles: marcar varios para seguirlos -----
let listaFiltro = '';
function toggleListaMoviles(forzar) {
  const p = $('map-lista'); if (!p) return;
  const abrir = forzar != null ? forzar : p.hidden;
  p.hidden = !abrir;
  $('map-lista-btn')?.classList.toggle('btn-primary', abrir);
  if (abrir) { renderListaItems(); setTimeout(() => $('ml-search')?.focus(), 30); }
}
function renderListaItems() {
  const box = $('ml-items'); if (!box) return;
  const q = listaFiltro.trim().toLowerCase();
  const filas = lastUbic
    .filter((r) => {
      if (!q) return true;
      return String(r.movil || '').toLowerCase().includes(q)
        || String(r.placa || '').toLowerCase().includes(q)
        || String(r.ruta || '').toLowerCase().includes(q);
    })
    .sort((a, b) => String(a.movil || '').localeCompare(String(b.movil || ''), 'es', { numeric: true }));
  if (!filas.length) { box.innerHTML = `<div class="ml-empty">Sin móviles${q ? ' para “' + esc(q) + '”' : ''}.</div>`; syncListaSel(); return; }
  box.innerHTML = filas.map((r) => {
    const cls = clasificar(r);
    const sel = seguidos.has(_mk(r.movil));
    const sub = [r.ruta, r.placa, ESTADO_TXT[cls]].filter(Boolean).join(' · ');
    return `<div class="ml-item ${sel ? 'sel' : ''}" data-m="${esc(r.movil || '')}">
      <span class="ml-check">${sel ? '✓' : ''}</span>
      <span class="ml-dot ${cls}"></span>
      <span class="ml-main"><span class="ml-mov">${esc(r.movil || '—')}</span><span class="ml-sub">${esc(sub)}</span></span>
      <button class="ml-zoom" title="Ver en el mapa">🔍</button>
    </div>`;
  }).join('');
  // Clic en la fila => seguir/dejar de seguir. Clic en 🔍 => centrar el mapa en ese móvil.
  box.querySelectorAll('.ml-item').forEach((el) => {
    const movil = el.dataset.m;
    el.querySelector('.ml-zoom').addEventListener('click', (ev) => {
      ev.stopPropagation();
      const r = lastUbic.find((x) => _mk(x.movil) === _mk(movil));
      if (r) { zoomAlMovil(r); openVehSheet(r); }
    });
    el.addEventListener('click', () => toggleSeguir(movil));
  });
  syncListaSel();
}
$('map-lista-btn')?.addEventListener('click', () => toggleListaMoviles());
$('ml-close')?.addEventListener('click', () => toggleListaMoviles(false));
$('ml-clear')?.addEventListener('click', limpiarSeguidos);
$('ml-ver')?.addEventListener('click', () => {
  if (!seguidos.size) { toast('Marca al menos un móvil en la lista', 'err'); return; }
  soloSeguidos = true; renderSeguidosBar(); renderMarkers(true); toggleListaMoviles(false);
});
$('ml-search')?.addEventListener('input', (e) => { listaFiltro = e.target.value; renderListaItems(); });

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
  if (data && data.ok) { gpsMap = null; vehList = null; toast(`Flota sincronizada: ${data.moviles} móviles`, 'ok'); if (current === 'vehiculosgps') loadData(); }
  else toast('No se pudo: ' + (data?.error || '?'), 'err');
});

$('synccond-btn').addEventListener('click', async () => {
  const btn = $('synccond-btn'); const t = btn.textContent; btn.disabled = true; btn.textContent = 'Sincronizando…';
  const { data, error } = await sb.rpc('sync_conductores');
  btn.disabled = false; btn.textContent = t;
  if (error) { toast('Error: ' + error.message, 'err'); return; }
  if (data && data.ok) { drvList = null; toast(`Conductores sincronizados: ${data.conductores}`, 'ok'); if (current === 'conductores_sonar') loadData(); }
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
// Bloquear cuenta = combo: cierra la sesión AHORA + cambia la contraseña (para que no vuelva a entrar).
$('perfil-kick-btn').addEventListener('click', async () => {
  const email = (prompt('Correo de la cuenta a BLOQUEAR (se cierra su sesión y se cambia su clave):') || '').trim();
  if (!email) return;
  const sugerida = 'Apl' + Math.random().toString(36).slice(2, 6) + '*'; // clave nueva sugerida
  const pass = (prompt('Nueva contraseña para la cuenta (mín. 6 caracteres):', sugerida) || '').trim();
  if (pass.length < 6) { toast('La contraseña debe tener al menos 6 caracteres', 'err'); return; }
  const ok = await confirmAction({
    title: '🚫 Bloquear cuenta',
    lead: `Se hará dos cosas con la cuenta:\n${email}`,
    message: `1) Se cierra su sesión de inmediato (sale al login).\n2) Su contraseña cambia a:  ${pass}\n\nAnota o comunica la nueva clave al dueño legítimo.\n¿Continuar?`,
    okLabel: 'Bloquear', danger: true,
  });
  if (!ok) return;
  // 1) Expulsar la sesión activa
  const kick = await sb.rpc('admin_expulsar_usuario', { p_email: email });
  if (kick.error) { toast('Error al cerrar sesión: ' + kick.error.message, 'err'); return; }
  if (!kick.data?.ok) { toast('No se pudo: ' + (kick.data?.error || '?'), 'err'); return; }
  // 2) Cambiar la contraseña
  const rp = await sb.rpc('admin_reset_pass', { p_email: email, p_pass: pass });
  if (rp.error) { toast('Sesión cerrada, pero falló el cambio de clave: ' + rp.error.message, 'err'); return; }
  if (rp.data?.ok) toast(`Cuenta bloqueada: sesión cerrada y clave nueva → ${pass}`, 'ok');
  else toast('Sesión cerrada, pero no se pudo cambiar la clave: ' + (rp.data?.error || '?'), 'err');
});

init();

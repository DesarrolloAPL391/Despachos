import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { SUPABASE_URL, SUPABASE_ANON_KEY, TABLES, TABLE_ORDER, PAGE_SIZE } from './config.js';

const sb = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
const $ = (id) => document.getElementById(id);

// Estado
let current = null;     // nombre de la tabla actual
let page = 0;
let term = '';
let filters = {};       // filtros dinámicos activos { columna: valor }
let editing = null;     // fila en edición (null = nuevo)
const fkCache = {};     // cache de opciones de FK por tabla
let CTX = null;         // contexto del usuario { rol, nombre, puesto, rutas[], ids[] }

// ---------- roles ----------
function isAdmin() { return CTX?.rol === 'admin'; }
function normRuta(s) { return String(s || '').toLowerCase().replace(/\s+/g, '').trim(); }
function allowedRutaSet() { return new Set((CTX?.rutas || []).map(normRuta)); }
// Tablas visibles según el rol (admin: todas; despachador: solo las marcadas con despachador:true)
function visibleTables() { return TABLE_ORDER.filter((n) => isAdmin() || TABLES[n].despachador); }

// ---------- utilidades ----------
function toast(msg, kind = '') {
  const t = $('toast');
  t.textContent = msg; t.className = 'toast ' + kind; t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), 2600);
}
function getPath(obj, path) {
  return path.split('.').reduce((o, k) => (o == null ? o : o[k]), obj);
}
function fmt(v) {
  if (v === null || v === undefined) return '';
  if (v === true) return 'Sí';
  if (v === false) return 'No';
  return String(v);
}
function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function chipClass(v) {
  const s = String(v || '').toUpperCase().trim();
  if (s === 'TABLA') return 'chip chip-indigo';
  if (s === 'LIBRE') return 'chip chip-violet';
  if (s === 'DESPACHADO' || s === 'ENABLED' || s === 'CERRADO' || s === 'ENCENDIDO') return 'chip chip-green';
  if (s === 'APAGADO') return 'chip chip-gray';
  if (s === 'NO REALIZA EL VIAJE' || s === 'DISABLED' || s === 'CANCELADO') return 'chip chip-red';
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
document.addEventListener('visibilitychange', () => { if (!document.hidden) verificarDispositivo(); });
async function showApp(user) {
  $('login-screen').hidden = true;
  $('app').hidden = false;
  // Cargar contexto/rol del usuario
  try { const { data } = await sb.rpc('mi_contexto'); CTX = data || null; }
  catch { CTX = null; }
  // Mostrar correo + (para despachador) su puesto del día
  const suf = CTX?.rol === 'despachador' ? ' · 📌 ' + (CTX.puesto || 'sin turno hoy') : '';
  $('user-email').textContent = (user.email || '') + suf;
  // Sesión única por dispositivo (solo despachadores): este equipo pasa a ser el activo
  if (sessTimer) { clearInterval(sessTimer); sessTimer = null; }
  sessionUser = null;
  if (CTX?.rol === 'despachador') {
    await registrarDispositivo(user);
    sessionUser = user;
    sessTimer = setInterval(verificarDispositivo, 45000);
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
    b.onclick = () => { selectTable(name); nav.classList.remove('open'); };
    nav.appendChild(b);
  }
  // acciones especiales (no son tablas)
  addNavAction(nav, '🗺️', 'Mapa', showMapView, 'nav-mapa');
  if (isAdmin()) addNavAction(nav, '📡', 'Despachos SONAR', openDsonar, 'nav-dsonar');
  const am = $('nav-mapa'); if (am) am.classList.toggle('active', currentView === 'mapa');
}
function addNavAction(nav, icon, label, fn, id) {
  const b = document.createElement('button');
  b.className = 'nav-action'; if (id) b.id = id;
  b.innerHTML = `<span>${icon}</span> ${label}`;
  b.onclick = () => { fn(); nav.classList.remove('open'); };
  nav.appendChild(b);
}
$('menu-toggle').addEventListener('click', () => $('sidebar').classList.toggle('open'));

function selectTable(name) {
  // salir de la vista de mapa si estaba activa
  currentView = 'tabla';
  $('map-view').hidden = true;
  $('table-view').hidden = false;
  if (mapTimer) { clearInterval(mapTimer); mapTimer = null; }
  current = name; page = 0; term = ''; filters = {}; $('search').value = '';
  $('table-title').textContent = TABLES[name].label;
  $('dispatch-btn').hidden = name !== 'despachos' || !isAdmin(); // Despachar libre: solo admin
  $('dsonar-btn').hidden = name !== 'despachos' || !isAdmin();   // Consultar SONAR: solo admin
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
  const defs = TABLES[current].filters || [];
  for (const f of defs) {
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

  if (term && cfg.searchCols?.length) {
    qy = qy.or(cfg.searchCols.map((c) => `${c}.ilike.%${term}%`).join(','));
  }
  for (const [col, val] of Object.entries(filters)) qy = qy.eq(col, val); // filtros dinámicos

  // Despachador: solo despachos de sus rutas permitidas (refuerzo en UI; RLS lo garantiza en BD)
  if (current === 'despachos' && !isAdmin()) {
    const ids = CTX?.ids || [];
    qy = qy.in('ruta_id', ids.length ? ids : [-1]);
  }

  const { data, error, count } = await qy;
  $('loading').hidden = true;
  if (error) { toast('Error al cargar: ' + error.message, 'err'); return; }
  renderTable(cfg, data || [], count || 0);
}

function renderTable(cfg, rows, count) {
  const head = $('thead-row'); head.innerHTML = '';
  cfg.columns.forEach((c) => { const th = document.createElement('th'); th.textContent = c.label; head.appendChild(th); });
  if (!cfg.readonly) head.appendChild(Object.assign(document.createElement('th'), { textContent: 'Acciones' }));

  const body = $('tbody'); body.innerHTML = '';
  $('empty').hidden = rows.length > 0;

  for (const row of rows) {
    const tr = document.createElement('tr');
    for (const c of cfg.columns) {
      const td = document.createElement('td');
      const val = c.path ? getPath(row, c.path) : row[c.key];
      if (c.badge && val != null && String(val).trim() !== '') {
        td.innerHTML = `<span class="${chipClass(val)}">${esc(fmt(val))}</span>`;
      } else {
        td.textContent = fmt(val);
      }
      tr.appendChild(td);
    }
    if (!cfg.readonly) {
      const act = document.createElement('td');
      act.className = 'row-actions';
      const locked = cfg.rowLocked && cfg.rowLocked(row);
      if (locked) {
        act.appendChild(Object.assign(document.createElement('span'), {
          className: 'lock-badge', textContent: '🔒', title: cfg.lockedHint || 'Bloqueado',
        }));
      } else {
        if (current === 'despachos') {
          const dsp = Object.assign(document.createElement('button'), { textContent: '🛰️', title: 'Despachar en SONAR' });
          dsp.onclick = () => openSonar(row);
          act.appendChild(dsp);
          const can = Object.assign(document.createElement('button'), { textContent: '🛑' });
          if (row.sonar_regid) {
            can.title = 'Cancelar en SONAR';
            can.onclick = () => openCancelar(row);
          } else {
            can.title = 'Sin regId: no se puede cancelar';
            can.disabled = true;
            can.style.opacity = '0.35';
          }
          act.appendChild(can);
        }
        // Editar/eliminar: solo admin. El despachador solo despacha/cancela.
        if (isAdmin()) {
          const ed = Object.assign(document.createElement('button'), { textContent: '✏️', title: 'Editar' });
          ed.onclick = () => openEditor(row);
          const del = Object.assign(document.createElement('button'), { textContent: '🗑️', title: 'Eliminar' });
          del.className = 'btn-danger'; del.onclick = () => deleteRow(row);
          act.append(ed, del);
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
  const opts = (data || []).map((r) => ({
    value: r.id,
    label: typeof fk.label === 'function' ? fk.label(r) : r[fk.label],
  }));
  fkCache[fk.table] = opts;
  return opts;
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
  editing = row || null;
  $('modal-title').textContent = (row ? 'Editar' : 'Nuevo') + ' · ' + cfg.label;
  $('modal-error').hidden = true;
  const form = $('edit-form'); form.innerHTML = '';

  let lastSection = null;
  const controls = []; // campos con visibilidad condicional

  for (const f of cfg.fields) {
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
    const val = row ? row[f.key] : (f.default ?? null);

    if (f.type === 'boolean') {
      wrap.className = 'field check';
      wrap.dataset.fieldKey = f.key;
      const cb = document.createElement('input');
      cb.type = 'checkbox'; cb.dataset.key = f.key; cb.dataset.type = 'boolean'; cb.checked = val === true;
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
      }
      input.dataset.key = f.key; input.dataset.type = f.type;
      if (f.key === cfg.pk && row && !cfg.pkEditable) input.disabled = true;
      if (f.key === cfg.pk && row && cfg.pkEditable) input.readOnly = true; // no cambiar PK al editar
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
      const cur = ctrlEl ? ctrlEl.value : '';
      wrap.classList.toggle('hidden-field', !f.showWhen.in.includes(cur));
    }
    toggleEmptySections(form);
  }
  for (const k of [...new Set(controls.map((f) => f.showWhen.field))]) {
    const el = form.querySelector(`[data-key="${k}"]`);
    if (el) el.addEventListener('change', applyVisibility);
  }
  applyVisibility();

  $('modal').hidden = false;
}

function closeModal() { $('modal').hidden = true; editing = null; }
$('modal-close').addEventListener('click', closeModal);
$('modal-cancel').addEventListener('click', closeModal);
$('new-btn').addEventListener('click', () => {
  if (current === 'despachos') openNuevoDespacho(); else openEditor(null);
});

$('modal-save').addEventListener('click', async () => {
  const cfg = TABLES[current];
  const err = $('modal-error'); err.hidden = true;
  const payload = {};

  for (const el of $('edit-form').querySelectorAll('[data-key]')) {
    const key = el.dataset.key, type = el.dataset.type;
    const wrap = el.closest('.field');
    if (wrap && wrap.classList.contains('hidden-field')) { payload[key] = null; continue; } // campo oculto -> vacío
    if (type === 'boolean') { payload[key] = el.checked; continue; }
    let v = el.value;
    if (typeof v === 'string') v = v.trim();
    if (v === '') { payload[key] = null; continue; }
    if (type === 'fk' || type === 'number') payload[key] = Number(v);
    else payload[key] = v;
  }

  // Validar requeridos
  for (const f of cfg.fields) {
    if (f.required && (payload[f.key] === null || payload[f.key] === undefined || payload[f.key] === '')) {
      err.textContent = `El campo "${f.label}" es obligatorio.`; err.hidden = false; return;
    }
  }

  $('modal-save').disabled = true;
  let res;
  if (editing) {
    const id = editing[cfg.pk];
    delete payload[cfg.pk]; // nunca actualizamos la PK
    res = await sb.from(current).update(payload).eq(cfg.pk, id);
  } else {
    if (!cfg.pkEditable) delete payload[cfg.pk]; // PK autogenerada
    res = await sb.from(current).insert(payload);
  }
  $('modal-save').disabled = false;

  if (res.error) { err.textContent = res.error.message; err.hidden = false; return; }
  closeModal();
  toast(editing ? 'Registro actualizado' : 'Registro creado', 'ok');
  loadData();
});

async function deleteRow(row) {
  const cfg = TABLES[current];
  if (cfg.rowLocked && cfg.rowLocked(row)) { toast(cfg.lockedHint || 'Registro bloqueado', 'err'); return; }
  if (!confirm('¿Eliminar este registro? Esta acción no se puede deshacer.')) return;
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

async function openNuevoDespacho() {
  $('nd-error').hidden = true;
  const r = $('nd-result'); r.hidden = true; r.textContent = '';
  $('nd-tipo').value = 'LIBRE'; // el despacho manual siempre es LIBRE (TABLA solo viene de importación)
  $('nd-fecha').value = hoyLocal();
  $('nd-hora').value = ''; $('nd-com').value = '';

  const [its, veh, drs, desp] = await Promise.all([
    loadItinerarios(), loadVehiculos(), loadDrivers(), loadDespachadores(),
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
  fillSelect($('nd-ruta'), itList.map((i) => [i.itid, `${i.nombre}${i.grupo ? ' · ' + i.grupo : ''}`]));
  fillSelect($('nd-movil'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  fillSelect($('nd-cond'), drs.map((d) => [d.dr_id, `${d.nombre || ''}${d.codigo ? ' · ' + d.codigo : ''}`]));
  fillSelect($('nd-desp'), desp.map((d) => [d.id, d.nombre]));
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
function closeND() { $('nd-modal').hidden = true; }
$('nd-close').addEventListener('click', closeND);
$('nd-cancel').addEventListener('click', closeND);
$('nd-movil').addEventListener('change', updateNdInfo);

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
    tipo: 'LIBRE', fecha: $('nd-fecha').value || null, hora: $('nd-hora').value || null,
    itid, itinNombre: itin?.nombre || null,
    vehId: Number(vehVal), mId: vrow?.numero ? (await gpsIdFor(vrow.numero)) : null,
    drvId, drvNombre: drow?.nombre || null, drvCodigo: drow?.codigo || null,
    despId: Number($('nd-desp').value) || null, com: $('nd-com').value.trim(),
  };

  // Sin internet → guardar offline y salir
  if (!navigator.onLine) {
    enqueueDispatch(intent);
    toast('Sin conexión: despacho guardado, se enviará al reconectar', 'ok');
    closeND(); if (current === 'despachos') loadData();
    return;
  }

  const btn = $('nd-save'); btn.disabled = true; btn.textContent = 'Procesando…';
  try {
    const sd = await doDispatch(intent);
    const res = $('nd-result'); res.hidden = false;
    if (sd && sd.ok) {
      res.className = 'sonar-result ok';
      res.textContent = '✅ Despacho creado y enviado a SONAR (HTTP ' + (sd.status ?? '') + ')'
        + (sd.regid ? '\nregId: ' + sd.regid : '') + '\n\n' + (sd.response || '').slice(0, 800);
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
    btn.disabled = false; btn.textContent = 'Crear y despachar';
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

let sonarRow = null;
async function openSonar(row) {
  sonarRow = row || null;
  $('sonar-error').hidden = true;
  const res = $('sonar-result'); res.hidden = true; res.textContent = '';
  $('s-com').value = '';

  const [veh, its, drs] = await Promise.all([loadVehiculos(), loadItinerarios(), loadDrivers()]);
  fillSelect($('s-mov'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  fillSelect($('s-itin'), its.map((i) => [i.itid, `${i.nombre}${i.grupo ? ' · ' + i.grupo : ''}`]));
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
  await updateSonarInfo();
  $('sonar-modal').hidden = false;
}
function closeSonar() { $('sonar-modal').hidden = true; }
$('sonar-close').addEventListener('click', closeSonar);
$('sonar-cancel').addEventListener('click', closeSonar);
$('dispatch-btn').addEventListener('click', () => openSonar(null));
$('s-mov').addEventListener('change', updateSonarInfo);

$('sonar-send').addEventListener('click', async () => {
  const err = $('sonar-error'); err.hidden = true;
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('s-mov').value);
  const itin = $('s-itin').value, drv = $('s-drv').value, com = $('s-com').value.trim();
  if (!vr) { err.textContent = 'Selecciona un móvil.'; err.hidden = false; return; }
  if (!itin) { err.textContent = 'Selecciona un itinerario.'; err.hidden = false; return; }
  const g = await gpsInfoFor(vr.numero); const mId = g?.tracker_id;
  if (!mId) { err.textContent = 'Ese móvil no tiene Id GPS en SONAR.'; err.hidden = false; return; }

  const btn = $('sonar-send'); btn.disabled = true; btn.textContent = 'Enviando…';
  const { data, error } = await sb.rpc('despachar_sonar', {
    p_mid: String(mId), p_itinerary: itin, p_drvid: drv, p_utc: '', p_comments: com,
  });
  btn.disabled = false; btn.textContent = 'Despachar';

  const res = $('sonar-result'); res.hidden = false;
  if (error) { res.className = 'sonar-result err'; res.textContent = 'Error: ' + error.message; return; }
  if (data && data.ok) {
    // Guardar el regId en el despacho de origen (para poder cancelarlo luego)
    if (data.regid && sonarRow?.id) {
      await sb.from('despachos').update({ sonar_regid: String(data.regid) }).eq('id', sonarRow.id);
      if (current === 'despachos') loadData();
    }
    res.className = 'sonar-result ok';
    res.textContent = '✅ Despachado (HTTP ' + (data.status ?? '') + ')'
      + (data.regid ? '\nregId: ' + data.regid : '') + '\n\n' + (data.response || '').slice(0, 1200);
    toast('Despachado en SONAR', 'ok');
  } else {
    res.className = 'sonar-result err';
    res.textContent = '⚠️ ' + (data?.error || ('Respuesta HTTP ' + (data?.status ?? '?'))) + '\n\n' + ((data?.response || '').slice(0, 1200));
  }
});

// ---------- Cancelar despacho en SONAR ----------
let cancelRow = null;
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
async function openCancelar(row) {
  if (row && !row.sonar_regid) { toast('Este despacho no tiene regId: no se puede cancelar.', 'err'); return; }
  cancelRow = row || null;
  $('cancel-error').hidden = true;
  const res = $('cancel-result'); res.hidden = true; res.textContent = '';
  $('c-regid').value = row?.sonar_regid || '';
  $('c-com').value = 'Cancelación ' + (row?.id || '');

  const veh = await loadVehiculos();
  fillSelect($('c-mov'), veh.map((v) => [v.id, `${v.numero}${v.placa ? ' · ' + v.placa : ''}`]));
  if (row) {
    const movil = row.veh?.numero;
    if (movil) { const vr = veh.find((v) => String(v.numero) === String(movil)); if (vr) $('c-mov').value = vr.id; }
  }
  await updateCancelInfo();
  $('cancel-modal').hidden = false;
}
function closeCancel() { $('cancel-modal').hidden = true; cancelRow = null; }
$('cancel-close').addEventListener('click', closeCancel);
$('cancel-cancel').addEventListener('click', closeCancel);
$('c-mov').addEventListener('change', updateCancelInfo);

$('cancel-send').addEventListener('click', async () => {
  const err = $('cancel-error'); err.hidden = true;
  const veh = await loadVehiculos();
  const vr = veh.find((v) => String(v.id) === $('c-mov').value);
  if (!vr) { err.textContent = 'Selecciona un móvil.'; err.hidden = false; return; }
  const g = await gpsInfoFor(vr.numero); const mId = g?.tracker_id;
  if (!mId) { err.textContent = 'Ese móvil no tiene Id GPS en SONAR.'; err.hidden = false; return; }
  const regId = $('c-regid').value.trim();
  const com = $('c-com').value.trim();
  if (!regId) { err.textContent = 'No hay regId: no se puede cancelar este despacho.'; err.hidden = false; return; }
  if (!confirm('¿Cancelar el despacho activo de este móvil en SONAR?')) return;

  const btn = $('cancel-send'); btn.disabled = true; btn.textContent = 'Cancelando…';
  const { data, error } = await sb.rpc('cancelar_sonar', { p_mid: String(mId), p_regid: regId, p_comments: com });
  btn.disabled = false; btn.textContent = 'Cancelar despacho';

  const res = $('cancel-result'); res.hidden = false;
  if (error) { res.className = 'sonar-result err'; res.textContent = 'Error: ' + error.message; return; }
  if (data && data.ok) {
    // Marcar el despacho como cancelado y limpiar el regId usado
    if (cancelRow?.id) {
      await sb.from('despachos').update({ estado_despacho: 'CANCELADO', sonar_regid: null }).eq('id', cancelRow.id);
      if (current === 'despachos') loadData();
    }
    res.className = 'sonar-result ok';
    res.textContent = '✅ Cancelado en SONAR (HTTP ' + (data.status ?? '') + ')\n\n' + (data.response || '').slice(0, 1200);
    toast('Despacho cancelado en SONAR', 'ok');
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
    m.bindPopup(mapPopup(r), { maxWidth: 320 });
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
  // resaltar la opción del menú
  document.querySelectorAll('#sidebar button').forEach((b) => b.classList.remove('active'));
  $('nav-mapa')?.classList.add('active');
  if (!flotaMap) {
    flotaMap = L.map('map').setView([6.244, -75.58], 12); // Medellín
    L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19, attribution: '© OpenStreetMap',
    }).addTo(flotaMap);
    flotaLayer = L.layerGroup().addTo(flotaMap);
    // Al abrir el globo de un bus, consulta su ruta real actual en SONAR (1 llamada)
    flotaMap.on('popupopen', async (e) => {
      const r = e.popup._source && e.popup._source._row;
      const el = document.getElementById('cur-ruta');
      if (!r || !el) return;
      el.textContent = '⏳…';
      const { data, error } = await sb.rpc('ruta_actual_sonar', { p_mid: r.mid });
      const cur = document.getElementById('cur-ruta'); // el popup sigue abierto
      if (!cur) return;
      if (error || !data || !data.ok) cur.textContent = r.ruta ? `${r.ruta} (despacho)` : '—';
      else cur.textContent = data.ruta || '—';
    });
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

// Configuración de conexión a Supabase (la anon key es pública por diseño)
export const SUPABASE_URL = 'https://ggbyeftqatnahlpunqek.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnYnllZnRxYXRuYWhscHVucWVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2MzU5NzksImV4cCI6MjA5NzIxMTk3OX0.VnJ24ahyhBeWqh38uZoeWFLxQkp_s8Ji9I8HQsYRW60';

export const PAGE_SIZE = 50;

// Versión visible del aplicativo (mantener igual al número de caché en sw.js)
export const APP_VERSION = 'v139';

// Etiqueta para opciones de un FK (string = columna, función = formato libre)
const labelVeh = (r) => `${r.numero ?? ''}${r.placa ? ' · ' + r.placa : ''}`;

// Novedades operativas (tomadas de los datos reales de despachos y tablas)
const NOVEDADES = [
  'PESCA', 'TALLER', 'SIN INFORMACION', 'SIN CONDUCTOR', 'CAMBIO DE TABLA', 'SUSPENDIDO',
  'REQUERIMIENTO EMPRESA', 'VACACIONES', 'CONDUCTOR EN OTRA RUTA', 'CONDUCTOR EN OTRO VEHICULO',
  'INCAPACIDAD EPS', 'CITA MEDICA EPS', 'RESTRICCION MEDICA', 'CDA', 'ADELANTADO', 'ABANDONA EL SERVICIO', 'CONGESTION HEVICULAR',
];

export const TABLE_ORDER = [
  'despachos', 'despachos_sonar', 'resumen', 'asistencia', 'horarios', 'puestos', 'perfiles', 'ubicaciones', 'vehiculosgps',
  'conductores_sonar', 'parque_automotor', 'itinerarios',
];
// Las tablas por puesto (laureles, etc.) se descubren solas desde la tabla `puestos`
// y se registran en tiempo de ejecución (ver app.js). No hay que editar config por cada una.

// Mapa de encabezados (normalizados) -> campo, para la importación de horarios de usuarios
const IMPORT_MAP_HORARIOS = {
  'usuarios': 'email', 'usuario': 'email', 'email': 'email', 'correo': 'email', 'id': 'email',
  'nombre': 'nombre', 'hora de inicio': 'hora_inicio', 'hora finalizacion labor': 'hora_fin',
  'observacion': 'observacion', 'fecha': 'fecha',
};

// Mapa de encabezados (normalizados) -> campo, para la importación de despachos
const IMPORT_MAP_DESPACHOS = {
  'key': 'key', 'fecha': 'fecha', 'vehiculo': 'vehiculo', 'hora': 'hora', 'ruta': 'ruta',
  'despachado': 'despachado', 'codigo': 'codigo', 'conductor': 'conductor', 'viajes': 'viajes',
  'despachador': 'despachador', 'ubicacion': 'ubicacion', 'vehiculo programado': 'veh_prog',
  'hora programada': 'hora_prog', 'ruta programada': 'ruta_prog', 'cambio': 'cambio',
  'hora real despacho': 'hora_real', 'hora de finalizacion': 'hora_fin', 'duracion viaje': 'duracion',
  'completo si/no': 'completo', 'perdida deliberada de tiempo si/no': 'perdida',
  'abandono de ruta si/no': 'abandono', 'hora abandono de ruta 1': 'h_ab1',
  'hora abandono de ruta 2': 'h_ab2', 'hora abandono de ruta 3': 'h_ab3',
  'direccion abandono de ruta 1': 'd_ab1', 'direccion abandono de ruta 2': 'd_ab2',
  'direccion abandono de ruta 3': 'd_ab3', 'novedades': 'novedades', 'observacion': 'observacion',
  'auditador': 'auditador', 'fecha y hora auditoria': 'fecha_aud', 'control interno': 'control_interno',
  'hora llegada control': 'h_lleg_control', 'hora de salida control': 'h_sal_control',
  'estado': 'estado', 'hora de llegada': 'hora_llegada',
};

// Mapa de encabezados -> campo para importar TABLAS por puesto (acepta los encabezados
// propios de las tablas: "viaje programado", "nombre de conductor", etc.)
const IMPORT_MAP_TABLAS = {
  ...IMPORT_MAP_DESPACHOS,
  'tabla': 'tabla_destino', 'tabla destino': 'tabla_destino', // recordatorio/validación de a qué tabla va
  'viaje programado': 'ruta_prog',
  'hora de salida programada': 'hora_prog', 'hora de salida programado': 'hora_prog', 'hora de despacho programada': 'hora_prog',
  'nombre de conductor': 'conductor', 'nombre conductor': 'conductor',
  'codigo de conductor': 'codigo',
};

// Mapa de encabezados (normalizados) -> campo, para la importación de resumen
const IMPORT_MAP_RESUMEN = {
  'keys': 'key', 'key': 'key', 'fecha': 'fecha', 'ruta': 'ruta', 'codigo': 'codigo',
  'viajes': 'viajes', 'total de pasajeros': 'total_pasajeros', 'nombre de conductor': 'conductor',
  'conductor': 'conductor', 'vehiculo': 'vehiculo', 'puesto': 'puesto', 'despachador': 'despachador',
  'ubicacion': 'ubicacion', 'hora de cerrada de vehiculo': 'hora_cierre', 'estado': 'estado',
};

export const TABLES = {
  despachos: {
    label: 'Despachos',
    icon: '🚍',
    pk: 'id',
    dispatchable: true, // permite despachar/cancelar a SONAR desde las filas
    eventosSonar: true, // botón 🔎 de eventos del bus (auditor/admin). Lo heredan las tablas de puesto
    noDelete: true, // un despacho no se elimina (ni TABLA ni LIBRE)
    confirmSave: true, // pide confirmación antes de guardar cambios
    despachador: true, // visible para despachadores (filtrado por sus rutas)
    // Al elegir/cambiar la ruta, el "Móvil (real)" se limita a los carros del GRUPO de esa ruta
    // (vía ruta_grupos + parque_automotor). Evita despachar carros que no son de la tabla.
    // Al elegir el móvil, trae el conductor (SONAR) registrado, igual que en Despachos.
    vehByGroup: { route: 'ruta_id', veh: 'vehiculo_id', cond: 'conductor_id', fecha: 'fecha' },
    pkEditable: true, // el KEY lo escribe el usuario al crear
    // keyField:'fecha' → NO se exige KEY por fila; si falta, la función lo genera del contenido (como en las tablas de puesto)
    import: { rpc: 'importar_despachos', map: IMPORT_MAP_DESPACHOS, keyField: 'fecha', kept: 'duplicados_omitidos', keptLabel: 'Ya existían (omitidos)' },
    select: '*, ruta:ruta_id(nombre), rutap:ruta_programada_id(nombre), veh:vehiculo_id(numero,placa), vehp:vehiculo_programado_id(numero,placa), cond:conductor_id(nombre), desp:despachador_id(nombre), aud:auditor_id(nombre)',
    searchCols: ['id', 'estado_despacho', 'estado'],
    defaultOrder: { col: 'fecha', asc: false, then: { col: 'hora', asc: true } },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'date' },
      { col: 'ruta_id', label: 'Ruta', type: 'checklist', source: 'rutas' },
      { col: 'tipo', label: 'Tipo', options: ['TABLA', 'LIBRE'] },
      { col: 'estado_despacho', label: 'Despacho', options: ['SIN DESPACHO', 'SI', 'DESPACHADO', 'PENDIENTE SONAR', 'NO REALIZA EL VIAJE', 'NO SE REALIZA POR OTRO MOTIVO', 'CANCELADO'] },
      { col: 'estado', label: 'Novedad', options: NOVEDADES },
    ],
    columns: [
      { key: 'tipo', label: 'Tipo', badge: true },
      { key: 'fecha', label: 'Fecha' },
      { key: 'hora', label: 'Hora', m: true },
      { path: 'ruta.nombre', label: 'Ruta', m: true },
      { path: 'vehp.numero', label: 'Móvil prog.' },
      { path: 'veh.numero', label: 'Móvil', m: true },
      { key: 'cambio', label: 'Cambio' },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'estado_despacho', label: 'Despacho', badge: true, m: true },
      { key: 'realizo_programado', label: 'Prog. realizó', badge: true },
      { key: 'estado', label: 'Novedad', badge: true },
      { key: 'ubicacion', label: 'Ubicación', maps: true },
      // ----- Control / Auditoría ----- (auditCol: solo las ven el admin y el auditor)
      { key: 'control_interno', label: 'Control interno', auditCol: true },
      { key: 'hora_llegada_control', label: 'Lleg. control', auditCol: true },
      { key: 'hora_salida_control', label: 'Sal. control', auditCol: true },
      { path: 'aud.nombre', label: 'Auditor', auditCol: true },
      { key: 'fecha_hora_auditoria', label: 'Auditado el', dt: true, auditCol: true },
      // Placa y regId SONAR quedan solo en el detalle.
    ],
    fields: [
      // ----- General -----
      { key: 'tipo', label: 'Tipo de despacho', type: 'enum', options: ['TABLA', 'LIBRE'], required: true, default: 'TABLA', section: 'General' },
      { key: 'id', label: 'KEY (id único)', type: 'text', required: true, section: 'General' },
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General' },
      { key: 'hora', label: 'Hora', type: 'time', section: 'General' },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General' },
      // Control del despachador: marca si el viaje se realizó (SI) o no (NO REALIZA EL VIAJE).
      // Es lo que el auditor luego contrasta contra lo que dice SONAR (Auditoría SONAR).
      { key: 'estado_despacho', label: '¿Se realizó el viaje?', type: 'enum',
        options: ['SIN DESPACHO', 'SI', 'NO REALIZA EL VIAJE', 'NO SE REALIZA POR OTRO MOTIVO'], section: 'General' },
      { key: 'sonar_regid', label: 'regId SONAR', type: 'text', section: 'General' },
      { key: 'codigo', label: 'Código (turno)', type: 'text', section: 'General', formHide: true },
      { key: 'cambio', label: 'Cambio (automático)', type: 'text', section: 'General', readOnly: true, autoCambio: true, hint: 'Se registra solo al elegir un móvil distinto al programado.' },

      // ----- Programado (solo TABLA) -----
      { key: 'vehiculo_programado_id', label: 'Móvil programado', type: 'fk', fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Programado en tabla', showWhen: { field: 'tipo', in: ['TABLA'] } },
      { key: 'hora_programada', label: 'Hora programada', type: 'time', section: 'Programado en tabla', showWhen: { field: 'tipo', in: ['TABLA'] } },
      { key: 'ruta_programada_id', label: 'Ruta programada', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Programado en tabla', showWhen: { field: 'tipo', in: ['TABLA'] } },

      // ----- Real -----
      // qr: el bus se identifica escaneando su QR (número o placa). Las tablas de puesto
      // heredan este campo vía configTablaPuesto → el lector queda en todas sin tocar nada más.
      { key: 'vehiculo_id', label: 'Vehículo despachado', type: 'fk', qr: true, fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'General' },
      { key: 'conductor_id', label: 'Conductor (SONAR)', type: 'sonardrv', nameFrom: 'cond.nombre', section: 'General', required: true },
      { key: 'despachador_id', label: 'Despachador', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General', readOnly: true },
      // Horas de seguimiento: ocultas en el formulario en TODAS las tablas (se registran aparte)
      { key: 'hora_real_despacho', label: 'Hora real de despacho', type: 'time', section: 'General', postDispatch: true, formHide: true },
      { key: 'hora_finalizacion', label: 'Hora finalización', type: 'time', section: 'General', postDispatch: true, formHide: true },
      { key: 'hora_llegada', label: 'Hora de llegada', type: 'time', section: 'General', postDispatch: true, formHide: true },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'General', postDispatch: true, readOnly: true },
      // Si el viaje NO se realizó, la novedad (el motivo) es obligatoria.
      { key: 'estado', label: 'Novedad operativa', type: 'enum', options: NOVEDADES, section: 'General', postDispatch: true,
        requiredWhen: { field: 'estado_despacho', in: ['NO REALIZA EL VIAJE', 'NO SE REALIZA POR OTRO MOTIVO'] } },
      { key: 'realizo_programado', label: '¿El carro programado realizó el viaje?', type: 'boolean', section: 'General', postDispatch: true, audit: true },

      // ----- Indicadores ----- (editables después de despachar y por el auditor)
      { key: 'completo', label: '¿Completo?', type: 'boolean', section: 'Indicadores', postDispatch: true, audit: true },
      { key: 'perdida_deliberada_tiempo', label: '¿Pérdida deliberada de tiempo?', type: 'boolean', section: 'Indicadores', postDispatch: true, audit: true },
      { key: 'abandono_ruta', label: '¿Abandono de ruta?', type: 'boolean', section: 'Indicadores', postDispatch: true, audit: true },

      // ----- Notas ----- (editables después de despachar y por el auditor)
      { key: 'novedades', label: 'Novedades', type: 'textarea', section: 'Notas', postDispatch: true, audit: true },
      { key: 'observacion', label: 'Observación', type: 'textarea', section: 'Notas', postDispatch: true, audit: true },

      // ----- Control / Auditoría ----- (solo auditor/admin; auditor sí los edita)
      // audit:true → el auditor puede editarlos; auditOnly:true → el despachador no los ve
      { key: 'control_interno', label: 'Control interno', type: 'textarea', section: 'Control / Auditoría', audit: true, auditOnly: true },
      { key: 'hora_llegada_control', label: 'Hora de llegada a control', type: 'time', section: 'Control / Auditoría', audit: true, auditOnly: true },
      { key: 'hora_salida_control', label: 'Hora de salida de control', type: 'time', section: 'Control / Auditoría', audit: true, auditOnly: true },
    ],
  },

  // Despachos REALES traídos de SONAR (los trae sync_despachos_sonar, nadie los escribe a mano).
  // El auditor solo ve los de SUS rutas (RLS) y su trabajo es revisar los INCOMPLETOS.
  // El estado lo calcula la base con la regla oficial (lclose + lcanceled), no se edita.
  despachos_sonar: {
    label: 'Auditoría SONAR',
    icon: '🧾',
    pk: 'itl_id',
    pkEditable: false,
    noDelete: true,
    eventosSonar: true, // 🔎 en cada fila: ver el recorrido y saber POR QUÉ quedó incompleto
    select: '*',
    searchCols: ['movil', 'placa', 'ruta', 'conductor'],
    defaultOrder: { col: 'fecha', asc: false, then: { col: 'hora_inicio', asc: true } },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'date' },
      { col: 'estado', label: 'Estado', options: ['Completo', 'Incompleto', 'Cancelado', 'En progreso'] },
      { col: 'auditado', label: 'Auditado', options: [true, false] },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha' },
      { key: 'hora_inicio', label: 'Hora', m: true },
      { key: 'ruta', label: 'Ruta', m: true },
      { key: 'movil', label: 'Móvil', m: true },
      { key: 'placa', label: 'Placa' },
      { key: 'conductor', label: 'Conductor' },
      { key: 'estado', label: 'Estado', badge: true, m: true },
      { key: 'auditado', label: 'Auditado', badge: true },
      { key: 'auditor_email', label: 'Auditor' },
      { key: 'observacion', label: 'Observación' },
    ],
    // Lo único editable es el trabajo del auditor; lo que vino de SONAR es de solo lectura.
    fields: [
      { key: 'ruta', label: 'Ruta', type: 'text', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'movil', label: 'Móvil', type: 'text', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'placa', label: 'Placa', type: 'text', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'conductor', label: 'Conductor', type: 'text', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'hora_inicio', label: 'Hora de inicio', type: 'time', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'estado', label: 'Estado (lo calcula SONAR)', type: 'text', readOnly: true, section: 'Lo que dice SONAR' },
      { key: 'auditado', label: '¿Auditado?', type: 'boolean', section: 'Auditoría' },
      { key: 'observacion', label: 'Observación del auditor', type: 'textarea', section: 'Auditoría' },
    ],
  },

  resumen: {
    label: 'Resumen',
    icon: '📊',
    despachador: true, // visible para los despachadores
    pk: 'id',
    pkEditable: true,
    // Si el vehículo ya está "Cerrado", la fila queda bloqueada (no se edita ni elimina)
    rowLocked: (row) => String(row.estado || '').trim().toUpperCase() === 'CERRADO',
    lockedHint: 'Cerrado: no editable',
    // El KEY se genera solo (no se escribe a mano)
    genKey: () => 'R' + Date.now().toString(36).toUpperCase() + Math.random().toString(36).slice(2, 6).toUpperCase(),
    confirmSave: true, // pide confirmación antes de guardar/cerrar
    // Al elegir ruta → filtra Móvil por el GRUPO del parque de esa ruta (ruta_grupos +
    // parque_automotor), misma filosofía que Nuevo despacho y las tablas de puesto (incluye
    // el pool "Integradas" cuando la ruta es integrada). En Resumen el conductor se elige a mano.
    vehByGroup: { route: 'ruta_id', veh: 'vehiculo_id' },
    // La hora de cierre se llena sola con el momento de guardado
    autoStamp: 'hora_cierre',
    // Estado: 'Abierto' al crear; 'Cerrado' (y bloqueado) cuando al editar estén todos los campos
    stateField: 'estado',
    closeRequired: ['fecha', 'ruta_id', 'vehiculo_id', 'conductor_id', 'viajes'],
    closeRequiredDoble: ['jornada1_inicio', 'jornada1_fin', 'conductor2_id', 'jornada2_inicio', 'jornada2_fin'],
    // (Resumen NO permite importar archivos: el resumen se genera/edita en la app, no por importación.)
    select: '*, ruta:ruta_id(nombre), cond:conductor_id(nombre), cond2:conductor2_id(nombre), veh:vehiculo_id(numero,placa), desp:despachador_id(nombre)',
    searchCols: ['id', 'codigo', 'puesto', 'estado'],
    defaultOrder: { col: 'hora_cierre', asc: false },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'daterange' },
      { col: 'ruta_id', label: 'Ruta', type: 'checklist', source: 'rutas' },
      { col: 'estado', label: 'Estado', options: ['Cerrado', 'Abierto'] },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha', m: true },
      { path: 'ruta.nombre', label: 'Ruta', m: true },
      { path: 'veh.numero', label: 'Móvil', m: true },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'viajes', label: 'Viajes' },
      { key: 'puesto', label: 'Puesto' },
      { path: 'desp.nombre', label: 'Despachador' },
      { key: 'hora_cierre', label: 'Cierre' },
      { key: 'estado', label: 'Estado', badge: true, m: true },
    ],
    fields: [
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General', required: true },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General', required: true },
      { key: 'codigo', label: 'Código (turno)', type: 'text', section: 'General', formHide: true },
      // Puesto: se llena solo con el puesto del usuario logueado; el despachador no lo edita
      { key: 'puesto', label: 'Puesto', type: 'text', section: 'General', ctxValue: 'puesto', softReadOnlyDispatcher: true },

      { key: 'vehiculo_id', label: 'Móvil', type: 'fk', qr: true, fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Operación' },
      { key: 'despachador_id', label: 'Despachador', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Operación' },
      // Viajes: solo aparece al EDITAR el registro, y siempre positivo
      { key: 'viajes', label: 'Viajes', type: 'number', min: 0, editOnly: true, section: 'Operación' },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Operación', readOnly: true },
      // Estado y Total de pasajeros: ocultos. Hora de cierre: automática (momento de guardado).

      // ----- Conductor -----
      { key: 'conductor_id', label: 'Conductor (SONAR)', type: 'sonardrv', nameFrom: 'cond.nombre', section: 'Conductor', qr: true },
      { key: 'doble_turno', label: '¿Doble turno? (otro conductor en otra jornada)', type: 'boolean', section: 'Conductor' },
      // Las jornadas y el 2.º conductor solo aparecen si es doble turno
      { key: 'jornada1_inicio', label: 'Jornada 1 · inicia', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada1_fin', label: 'Jornada 1 · termina', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'conductor2_id', label: 'Conductor jornada 2 (SONAR)', type: 'sonardrv', nameFrom: 'cond2.nombre', section: 'Conductor', qr: true, showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada2_inicio', label: 'Jornada 2 · inicia', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada2_fin', label: 'Jornada 2 · termina', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
    ],
  },

  // Asistencia: marcación de ingreso/salida (con foto que NO se guarda + GPS obligatorio)
  asistencia: {
    label: 'Inicio y fin de labores',
    icon: '🕘',
    despachador: true, // visible para los despachadores (ven solo lo suyo por RLS)
    asistenciaMarcar: true, // muestra los botones "Marcar ingreso/salida"
    readonly: true, // no se edita a mano; el ingreso/salida se marcan con los botones
    pk: 'id', pkEditable: false,
    select: '*',
    searchCols: ['email', 'nombre'],
    defaultOrder: { col: 'fecha', asc: false, then: { col: 'ingreso_en', asc: false } },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'daterange' },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha', m: true },
      { key: 'hora_ingreso', label: 'Ingreso', m: true },
      { key: 'hora_salida', label: 'Salida', m: true },
      { key: 'horas', label: 'Horas', m: true },
      { key: 'nombre', label: 'Despachador', m: true },
      { key: 'email', label: 'Correo' },
      { key: 'ubic_ingreso', label: 'Ubic. ingreso', maps: true },
      { key: 'ubic_salida', label: 'Ubic. salida', maps: true },
    ],
    fields: [],
  },

  horarios: {
    label: 'Horarios usuarios',
    icon: '🕒',
    pk: 'id',
    pkEditable: false,
    import: { rpc: 'importar_horarios', map: IMPORT_MAP_HORARIOS, keyField: 'email', kept: 'actualizados', keptLabel: 'Actualizados' },
    select: '*',
    searchCols: ['email', 'nombre', 'observacion'],
    defaultOrder: { col: 'fecha', asc: false },
    filters: [{ type: 'multidate', col: 'fecha', label: 'Fechas' }],
    columns: [
      { key: 'fecha', label: 'Fecha' },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'email', label: 'Usuario' },
      { key: 'hora_inicio', label: 'Inicio', m: true },
      { key: 'hora_fin', label: 'Fin', m: true },
      { key: 'grupos', label: 'Grupos', m: true },
      { key: 'observacion', label: 'Puesto / Observación' },
    ],
    fields: [
      { key: 'fecha', label: 'Fecha', type: 'date', required: true },
      { key: 'email', label: 'Usuario (correo)', type: 'text', required: true },
      { key: 'nombre', label: 'Nombre', type: 'textsel', optionsFrom: { table: 'perfiles', col: 'nombre', where: ['activo', true] } },
      { key: 'hora_inicio', label: 'Hora de inicio', type: 'time' },
      { key: 'hora_fin', label: 'Hora finalización labor', type: 'time' },
      { key: 'grupos', label: 'Grupos de ruta', type: 'multisel', optionsFrom: { table: 'parque_automotor', col: 'ruta' } },
      { key: 'observacion', label: 'Puesto / Observación', type: 'textsel', optionsFrom: { table: 'puestos', col: 'nombre', where: ['activo', true] } },
    ],
  },

  puestos: {
    label: 'Puestos',
    icon: '📌',
    pk: 'id',
    pkEditable: false,
    select: '*',
    searchCols: ['nombre', 'rutas'],
    defaultOrder: { col: 'nombre', asc: true },
    columns: [
      { key: 'nombre', label: 'Puesto', m: true },
      { key: 'rutas', label: 'Rutas que cubre', m: true },
      { key: 'activo', label: 'Activo', badge: true, m: true },
    ],
    fields: [
      { key: 'nombre', label: 'Nombre del puesto', type: 'text', required: true },
      { key: 'rutas', label: 'Rutas que cubre (separadas por coma)', type: 'textarea', hint: 'Ej.: 133-133D, 132i, 132ii  — deben coincidir con la tabla Rutas' },
      { key: 'activo', label: '¿Activo?', type: 'boolean', default: true },
    ],
  },

  perfiles: {
    label: 'Perfiles / Accesos',
    icon: '🔐',
    pk: 'id',
    pkEditable: false,
    noCreate: true, // los accesos se crean junto con el login, no como fila suelta
    select: '*',
    searchCols: ['email', 'nombre', 'rol'],
    defaultOrder: { col: 'email', asc: true },
    filters: [
      { col: 'rol', label: 'Rol', options: ['admin', 'despachador'] },
    ],
    columns: [
      { key: 'email', label: 'Correo', m: true },
      { key: 'nombre', label: 'Nombre' },
      { key: 'rol', label: 'Rol', badge: true, m: true },
      { key: 'activo', label: 'Activo', badge: true, m: true },
    ],
    fields: [
      { key: 'email', label: 'Correo', type: 'text' },
      { key: 'nombre', label: 'Nombre', type: 'text' },
      { key: 'rol', label: 'Rol', type: 'enum', options: ['admin', 'despachador'], required: true },
      { key: 'activo', label: '¿Acceso activo?', type: 'boolean', default: true, hint: 'Desactívalo para bloquear el ingreso de ese usuario.' },
    ],
  },

  ubicaciones: {
    label: 'Ubicaciones',
    icon: '📍',
    readonly: true,
    pk: 'mid',
    pkEditable: false,
    select: '*',
    searchCols: ['movil', 'placa', 'driver_name', 'address', 'ruta'],
    defaultOrder: { col: 'movil', asc: true },
    filters: [
      { col: 'motor', label: 'Motor', options: ['Encendido', 'Apagado'] },
    ],
    columns: [
      { key: 'movil', label: 'Móvil', m: true },
      { key: 'placa', label: 'Placa' },
      { key: 'ruta', label: 'Última ruta', m: true },
      { key: 'motor', label: 'Motor', badge: true, m: true },
      { key: 'driver_name', label: 'Conductor', m: true },
      { key: 'speed', label: 'Vel. (km/h)' },
      { key: 'address', label: 'Dirección' },
      { key: 'gps_gmt', label: 'Hora GPS' },
      { key: 'actualizado', label: 'Actualizado' },
    ],
    fields: [
      { key: 'movil', label: 'Móvil', type: 'text' },
      { key: 'placa', label: 'Placa', type: 'text' },
      { key: 'latitude', label: 'Latitud', type: 'number' },
      { key: 'longitude', label: 'Longitud', type: 'number' },
      { key: 'speed', label: 'Velocidad', type: 'number' },
      { key: 'address', label: 'Dirección', type: 'text' },
      { key: 'driver_name', label: 'Conductor', type: 'text' },
      { key: 'gps_gmt', label: 'Hora GPS', type: 'datetime' },
    ],
  },

  vehiculos: {
    label: 'Vehículos',
    icon: '🚐',
    pk: 'id',
    pkEditable: false,
    select: '*, prop:propietario_id(nombre)',
    searchCols: ['numero', 'placa'],
    defaultOrder: { col: 'numero', asc: true },
    columns: [
      { key: 'numero', label: 'Móvil', m: true },
      { key: 'placa', label: 'Placa', m: true },
      { path: 'prop.nombre', label: 'Propietario', m: true },
    ],
    fields: [
      { key: 'numero', label: 'Móvil', type: 'text', required: true },
      { key: 'placa', label: 'Placa', type: 'text' },
      { key: 'propietario_id', label: 'Propietario', type: 'fk', fk: { table: 'propietarios', sel: 'id,nombre', label: 'nombre', order: 'nombre' } },
    ],
  },

  vehiculosgps: {
    label: 'Vehículos GPS',
    icon: '📍',
    readonly: true,
    pk: 'id',
    pkEditable: false,
    select: '*',
    searchCols: ['movil', 'placa', 'tracker_id'],
    defaultOrder: { col: 'movil', asc: true },
    columns: [
      { key: 'tracker_id', label: 'Tracker', m: true },
      { key: 'gps_vehiculo_id', label: 'ID GPS' },
      { key: 'placa', label: 'Placa', m: true },
      { key: 'movil', label: 'Móvil', m: true },
    ],
    fields: [
      { key: 'tracker_id', label: 'Tracker', type: 'text' },
      { key: 'gps_vehiculo_id', label: 'ID GPS', type: 'text' },
      { key: 'placa', label: 'Placa', type: 'text' },
      { key: 'movil', label: 'Móvil', type: 'text' },
    ],
  },

  parque_automotor: {
    label: 'Parque automotor',
    icon: '🚍',
    readonly: true,        // solo consulta
    despachador: true,     // visible para despachadores y admin
    pk: 'id',
    pkEditable: false,
    select: '*',
    searchCols: ['numero_interno', 'placa', 'ruta', 'propietario', 'marca'],
    defaultOrder: { col: 'numero_interno', asc: true },
    baseFilter: [{ col: 'estado', op: 'neq', val: 'Desvinculado' }], // ocultar desvinculados
    filters: [
      { col: 'estado', label: 'Estado', options: ['Activo', 'Inactivo'] },
    ],
    columns: [
      { key: 'numero_interno', label: 'Móvil', m: true },
      { key: 'placa', label: 'Placa', m: true },
      { label: 'QR', qr: 'placa' },
      { key: 'ruta', label: 'Ruta', m: true },
      { key: 'vence_soat', label: 'SOAT', band: true, m: true },
      { key: 'vence_tecnomecanica', label: 'Tecnomec.', band: true, m: true },
      { key: 'vence_tarjeta_operacion', label: 'T. operación', band: true },
      { key: 'estado', label: 'Estado', badge: true },
      { label: 'Docs', docsbtn: true, m: true },
    ],
    fields: [
      { key: 'numero_interno', label: 'Móvil (N° interno)', type: 'text', section: 'General' },
      { key: 'placa', label: 'Placa', type: 'text', section: 'General' },
      { key: 'estado', label: 'Estado', type: 'text', section: 'General' },
      { key: 'centro_costos', label: 'Centro de costos', type: 'text', section: 'General' },
      { key: 'sistema_ruta', label: 'Sistema de ruta', type: 'text', section: 'General' },
      { key: 'ruta', label: 'Ruta', type: 'text', section: 'General' },
      { key: 'marca', label: 'Marca', type: 'text', section: 'Técnico' },
      { key: 'modelo', label: 'Modelo (año)', type: 'number', section: 'Técnico' },
      { key: 'linea', label: 'Línea', type: 'text', section: 'Técnico' },
      { key: 'cilindraje', label: 'Cilindraje', type: 'text', section: 'Técnico' },
      { key: 'combustible', label: 'Combustible', type: 'text', section: 'Técnico' },
      { key: 'tecnologia_emision', label: 'Tecnología emisión', type: 'text', section: 'Técnico' },
      { key: 'clase_vehiculo', label: 'Clase', type: 'text', section: 'Técnico' },
      { key: 'tipo_carroceria', label: 'Carrocería', type: 'text', section: 'Técnico' },
      { key: 'color', label: 'Color', type: 'text', section: 'Técnico' },
      { key: 'cap_sentados', label: 'Cap. sentados', type: 'number', section: 'Técnico' },
      { key: 'cap_pie', label: 'Cap. de pie', type: 'number', section: 'Técnico' },
      { key: 'capacidad_to', label: 'Capacidad T.O.', type: 'number', section: 'Técnico' },
      { key: 'propietario', label: 'Propietario', type: 'text', section: 'Propietario' },
      { key: 'identificacion', label: 'Identificación', type: 'text', section: 'Propietario' },
      { key: 'direccion', label: 'Dirección', type: 'text', section: 'Propietario' },
      { key: 'telefono', label: 'Teléfono', type: 'text', section: 'Propietario' },
      { key: 'correo', label: 'Correo', type: 'text', section: 'Propietario' },
      { key: 'administrador', label: 'Administrador', type: 'text', section: 'Propietario' },
      { key: 'correo_admin', label: 'Correo administrador', type: 'text', section: 'Propietario' },
      { key: 'fecha_matricula', label: 'Fecha matrícula', type: 'date', section: 'Documentos' },
      { key: 'num_matricula', label: 'N° matrícula', type: 'text', section: 'Documentos' },
      { key: 'num_tarjeta_operacion', label: 'N° tarjeta operación', type: 'text', section: 'Documentos' },
      { key: 'vence_tarjeta_operacion', label: 'Vence tarjeta operación', type: 'date', section: 'Documentos' },
      { key: 'num_soat', label: 'N° SOAT', type: 'text', section: 'Documentos' },
      { key: 'vence_soat', label: 'Vence SOAT', type: 'date', section: 'Documentos' },
      { key: 'aseguradora_soat', label: 'Aseguradora SOAT', type: 'text', section: 'Documentos' },
      { key: 'num_tecnomecanica', label: 'N° tecnomecánica', type: 'text', section: 'Documentos' },
      { key: 'vence_tecnomecanica', label: 'Vence tecnomecánica', type: 'date', section: 'Documentos' },
    ],
  },

  conductores: {
    label: 'Conductores', icon: '👤', pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre'], defaultOrder: { col: 'nombre', asc: true },
    columns: [{ key: 'nombre', label: 'Nombre', m: true }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
  conductores_sonar: {
    label: 'Conductores SONAR', icon: '🪪', readonly: true, despachador: true, pk: 'id', pkEditable: false, select: '*',
    baseFilter: [{ col: 'status', op: 'eq', val: 'ENABLED' }], // solo conductores habilitados (ocultar DISABLED)
    searchCols: ['nombre', 'cedula', 'codigo'], defaultOrder: { col: 'nombre', asc: true },
    columns: [
      { key: 'dr_id', label: 'DrvId' },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'cedula', label: 'Cédula', despHide: true }, // dato sensible: oculto al despachador
      { key: 'codigo', label: 'Código', m: true, despHide: true }, // oculto al despachador
      { key: 'cellphone', label: 'Celular' },
      { key: 'status', label: 'Estado', badge: true, m: true },
    ],
    fields: [
      { key: 'dr_id', label: 'DrvId (SONAR)', type: 'text' },
      { key: 'nombre', label: 'Nombre', type: 'text' },
      { key: 'cedula', label: 'Cédula', type: 'text' },
      { key: 'codigo', label: 'Código', type: 'text' },
      { key: 'cellphone', label: 'Celular', type: 'text' },
      { key: 'email', label: 'Email', type: 'text' },
      { key: 'mid', label: 'mId', type: 'text' },
      { key: 'status', label: 'Estado', type: 'text' },
    ],
  },
  itinerarios: {
    label: 'Itinerarios SONAR', icon: '🧭', readonly: true, pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre', 'grupo', 'itid'], defaultOrder: { col: 'nombre', asc: true },
    columns: [
      { key: 'itid', label: 'ItId' },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'grupo', label: 'Grupo', m: true },
    ],
    fields: [
      { key: 'itid', label: 'ItId (SONAR)', type: 'text' },
      { key: 'nombre', label: 'Nombre', type: 'text' },
      { key: 'grupo', label: 'Grupo', type: 'text' },
    ],
  },
  rutas: {
    label: 'Rutas', icon: '🛣️', pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre'], defaultOrder: { col: 'nombre', asc: true },
    columns: [{ key: 'nombre', label: 'Nombre', m: true }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
  despachadores: {
    label: 'Despachadores', icon: '🧑‍💼', pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre'], defaultOrder: { col: 'nombre', asc: true },
    columns: [{ key: 'nombre', label: 'Nombre', m: true }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
};

// Construye la config de una tabla de puesto (misma función que Despachos, su propia tabla).
// En las tablas los viajes los programa el administrador: el formulario es muy restringido.
export function configTablaPuesto(label, puesto, opts = {}) {
  // Cuando el que mira es AUDITOR, la tabla de puesto conserva las columnas/campos de control
  // (control interno, horas de control, banderas, quién auditó) para que pueda auditar aquí
  // igual que en Despachos. Para el despachador se ocultan (a él no le aplican).
  const forAudit = !!opts.auditor;
  // No se muestran en el formulario (se ponen solos al despachar o no aplican en una tabla)
  const OCULTOS = new Set(['tipo', 'id', 'sonar_regid', 'despachador_id', 'hora_finalizacion', 'hora_real_despacho', 'hora_llegada']);
  // Se muestran pero NO se pueden modificar (programación del admin o capturado al despachar, ej. ubicación GPS)
  // estado_despacho NO va aquí: el despachador debe poder marcar SI / NO REALIZA EL VIAJE (control)
  const SOLO_LECTURA = new Set(['fecha', 'vehiculo_programado_id', 'hora_programada', 'ruta_programada_id', 'ubicacion']);
  // En las tablas de puesto, "Real" (lo que se despacha) va dentro de "General"
  const REUBICAR = { Real: 'General' };
  let fields = TABLES.despachos.fields
    // Los campos de auditoría/control se ocultan al despachador; el auditor SÍ los ve/edita
    .filter((f) => !OCULTOS.has(f.key) && (forAudit || !f.auditOnly))
    .map((f) => {
      let nf = f;
      if (SOLO_LECTURA.has(f.key)) nf = { ...nf, readOnly: true };
      // como en una tabla el tipo siempre es TABLA, los campos "Programado" se ven siempre (sin showWhen de tipo)
      if (nf.showWhen && nf.showWhen.field === 'tipo') { nf = { ...nf }; delete nf.showWhen; }
      if (REUBICAR[nf.section]) nf = { ...nf, section: REUBICAR[nf.section] };
      return nf;
    });
  // Reagrupa por sección (conservando el orden original dentro de cada una) para que no
  // se repita el título "General" tras haber movido allí los campos de "Real".
  const ORDEN_SECC = ['General', 'Programado en tabla', 'Indicadores', 'Control / Auditoría', 'Notas'];
  const _pres = [];
  fields.forEach((f) => { const s = f.section || ''; if (!_pres.includes(s)) _pres.push(s); });
  const _rank = (s) => { const i = ORDEN_SECC.indexOf(s); return i < 0 ? 100 + _pres.indexOf(s) : i; };
  fields = _pres.slice().sort((a, b) => _rank(a) - _rank(b))
    .flatMap((s) => fields.filter((f) => (f.section || '') === s));
  // Las columnas de control (auditCol) se ocultan al despachador; el auditor sí las ve
  const columns = forAudit ? TABLES.despachos.columns.slice() : TABLES.despachos.columns.filter((c) => !c.auditCol);
  // Filtro de fecha: una sola fecha (no rango). Se quita el filtro "Tipo" (en una tabla
  // de puesto todo es TABLA; el despacho LIBRE solo existe en Despachos).
  const filters = TABLES.despachos.filters
    .filter((f) => f.col !== 'tipo')
    .map((f) => (f.col === 'fecha' && f.type === 'daterange') ? { col: 'fecha', label: 'Fecha', type: 'date' } : f);
  // Orden: por día (más reciente primero) y dentro del día por HORA ascendente
  const defaultOrder = { col: 'fecha', asc: false, then: { col: 'hora', asc: true } };
  // El embed con `auditores` (quién auditó) solo se conserva para el auditor; al despachador se le quita
  const select = forAudit ? TABLES.despachos.select : TABLES.despachos.select.replace(', aud:auditor_id(nombre)', '');
  // Importación propia de la tabla por puesto (inserta en SU tabla, no en despachos)
  const importar = { rpc: 'importar_tabla_puesto', map: IMPORT_MAP_TABLAS, keyField: 'fecha', tablaParam: true, kept: 'duplicados_omitidos', keptLabel: 'Ya existían (omitidos)' };
  // La tabla pertenece a un puesto: el campo "Ruta" se limita a las rutas de ese puesto (puestos.rutas)
  return { ...TABLES.despachos, fields, columns, filters, defaultOrder, select, label, icon: '🛣️', import: importar, noCreate: true, despachador: false, puesto, routeByPuesto: 'ruta_id' };
}

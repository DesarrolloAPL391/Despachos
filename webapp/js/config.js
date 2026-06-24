// Configuración de conexión a Supabase (la anon key es pública por diseño)
export const SUPABASE_URL = 'https://ggbyeftqatnahlpunqek.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnYnllZnRxYXRuYWhscHVucWVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2MzU5NzksImV4cCI6MjA5NzIxMTk3OX0.VnJ24ahyhBeWqh38uZoeWFLxQkp_s8Ji9I8HQsYRW60';

export const PAGE_SIZE = 50;

// Versión visible del aplicativo (mantener igual al número de caché en sw.js)
export const APP_VERSION = 'v65';

// Etiqueta para opciones de un FK (string = columna, función = formato libre)
const labelVeh = (r) => `${r.numero ?? ''}${r.placa ? ' · ' + r.placa : ''}`;

// Novedades operativas (tomadas de los datos reales de despachos y tablas)
const NOVEDADES = [
  'PESCA', 'TALLER', 'SIN INFORMACION', 'SIN CONDUCTOR', 'CAMBIO DE TABLA', 'SUSPENDIDO',
  'REQUERIMIENTO EMPRESA', 'VACACIONES', 'CONDUCTOR EN OTRA RUTA', 'CONDUCTOR EN OTRO VEHICULO',
  'INCAPACIDAD EPS', 'CITA MEDICA EPS', 'RESTRICCION MEDICA', 'CDA', 'ADELANTADO', 'ABANDONA EL SERVICIO',
];

export const TABLE_ORDER = [
  'despachos', 'resumen', 'horarios', 'puestos', 'perfiles', 'ubicaciones', 'vehiculosgps',
  'conductores_sonar', 'itinerarios',
];
// Las tablas por puesto (laureles, etc.) se descubren solas desde la tabla `puestos`
// y se registran en tiempo de ejecución (ver app.js). No hay que editar config por cada una.

// Mapa de encabezados (normalizados) -> campo, para la importación de horarios de usuarios
const IMPORT_MAP_HORARIOS = {
  'usuarios': 'email', 'usuario': 'email', 'email': 'email', 'correo': 'email',
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
    noDelete: true, // un despacho no se elimina (ni TABLA ni LIBRE)
    confirmSave: true, // pide confirmación antes de guardar cambios
    despachador: true, // visible para despachadores (filtrado por sus rutas)
    pkEditable: true, // el KEY lo escribe el usuario al crear
    import: { rpc: 'importar_despachos', map: IMPORT_MAP_DESPACHOS, kept: 'duplicados_omitidos', keptLabel: 'Ya existían (omitidos)' },
    select: '*, ruta:ruta_id(nombre), rutap:ruta_programada_id(nombre), veh:vehiculo_id(numero,placa), vehp:vehiculo_programado_id(numero,placa), cond:conductor_id(nombre), desp:despachador_id(nombre)',
    searchCols: ['id', 'estado_despacho', 'estado'],
    defaultOrder: { col: 'fecha', asc: false },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'daterange' },
      { col: 'tipo', label: 'Tipo', options: ['TABLA', 'LIBRE'] },
      { col: 'estado_despacho', label: 'Despacho', options: ['DESPACHADO', 'NO REALIZA EL VIAJE', 'CANCELADO'] },
      { col: 'estado', label: 'Novedad', options: NOVEDADES },
    ],
    columns: [
      { key: 'tipo', label: 'Tipo', badge: true },
      { key: 'fecha', label: 'Fecha' },
      { key: 'hora', label: 'Hora', m: true },
      { path: 'ruta.nombre', label: 'Ruta', m: true },
      { path: 'vehp.numero', label: 'Móvil prog.' },
      { path: 'veh.numero', label: 'Móvil', m: true },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'estado_despacho', label: 'Despacho', badge: true, m: true },
      { key: 'realizo_programado', label: 'Prog. realizó', badge: true },
      { key: 'estado', label: 'Novedad', badge: true },
      // Placa y regId SONAR quedan solo en el detalle.
    ],
    fields: [
      // ----- General -----
      { key: 'tipo', label: 'Tipo de despacho', type: 'enum', options: ['TABLA', 'LIBRE'], required: true, default: 'TABLA', section: 'General' },
      { key: 'id', label: 'KEY (id único)', type: 'text', required: true, section: 'General' },
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General' },
      { key: 'hora', label: 'Hora', type: 'time', section: 'General' },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General' },
      { key: 'estado_despacho', label: 'Estado del despacho', type: 'text', section: 'General' },
      { key: 'sonar_regid', label: 'regId SONAR', type: 'text', section: 'General' },
      { key: 'codigo', label: 'Código (turno)', type: 'text', section: 'General' },
      { key: 'cambio', label: 'Cambio', type: 'text', section: 'General' },

      // ----- Programado (solo TABLA) -----
      { key: 'vehiculo_programado_id', label: 'Móvil programado', type: 'fk', fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Programado', showWhen: { field: 'tipo', in: ['TABLA'] } },
      { key: 'hora_programada', label: 'Hora programada', type: 'time', section: 'Programado', showWhen: { field: 'tipo', in: ['TABLA'] } },
      { key: 'ruta_programada_id', label: 'Ruta programada', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Programado', showWhen: { field: 'tipo', in: ['TABLA'] } },

      // ----- Real -----
      { key: 'vehiculo_id', label: 'Móvil (real)', type: 'fk', fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Real' },
      { key: 'conductor_id', label: 'Conductor', type: 'fk', fk: { table: 'conductores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Real' },
      { key: 'despachador_id', label: 'Despachador', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Real' },
      // Estos campos de seguimiento SÍ se pueden editar después de despachar (postDispatch)
      { key: 'hora_real_despacho', label: 'Hora real de despacho', type: 'time', section: 'Real', postDispatch: true },
      { key: 'hora_finalizacion', label: 'Hora finalización', type: 'time', section: 'Real', postDispatch: true },
      { key: 'hora_llegada', label: 'Hora de llegada', type: 'time', section: 'Real', postDispatch: true },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Real', postDispatch: true },
      { key: 'estado', label: 'Novedad operativa', type: 'enum', options: NOVEDADES, section: 'Real', postDispatch: true },
      { key: 'realizo_programado', label: '¿El carro programado realizó el viaje?', type: 'boolean', section: 'Real', postDispatch: true },

      // ----- Indicadores ----- (editables después de despachar)
      { key: 'completo', label: '¿Completo?', type: 'boolean', section: 'Indicadores', postDispatch: true },
      { key: 'perdida_deliberada_tiempo', label: '¿Pérdida deliberada de tiempo?', type: 'boolean', section: 'Indicadores', postDispatch: true },
      { key: 'abandono_ruta', label: '¿Abandono de ruta?', type: 'boolean', section: 'Indicadores', postDispatch: true },

      // ----- Notas ----- (editables después de despachar)
      { key: 'novedades', label: 'Novedades', type: 'textarea', section: 'Notas', postDispatch: true },
      { key: 'observacion', label: 'Observación', type: 'textarea', section: 'Notas', postDispatch: true },
    ],
  },

  resumen: {
    label: 'Resumen',
    icon: '📊',
    pk: 'id',
    pkEditable: true,
    // Si el vehículo ya está "Cerrado", la fila queda bloqueada (no se edita ni elimina)
    rowLocked: (row) => String(row.estado || '').trim().toUpperCase() === 'CERRADO',
    lockedHint: 'Cerrado: no editable',
    // El KEY se genera solo (no se escribe a mano)
    genKey: () => 'R' + Date.now().toString(36).toUpperCase() + Math.random().toString(36).slice(2, 6).toUpperCase(),
    confirmSave: true, // pide confirmación antes de guardar/cerrar
    // Al elegir ruta → filtra Móvil a los carros de esa ruta; al elegir Móvil → trae el conductor registrado en despachos
    vehByRoute: { route: 'ruta_id', veh: 'vehiculo_id', cond: 'conductor_id', fecha: 'fecha' },
    // La hora de cierre se llena sola con el momento de guardado
    autoStamp: 'hora_cierre',
    // Estado: 'Abierto' al crear; 'Cerrado' (y bloqueado) cuando al editar estén todos los campos
    stateField: 'estado',
    closeRequired: ['fecha', 'ruta_id', 'vehiculo_id', 'conductor_id', 'viajes'],
    closeRequiredDoble: ['jornada1_inicio', 'jornada1_fin', 'conductor2_id', 'jornada2_inicio', 'jornada2_fin'],
    import: { rpc: 'importar_resumen', map: IMPORT_MAP_RESUMEN, kept: 'actualizados', keptLabel: 'Actualizados' },
    select: '*, ruta:ruta_id(nombre), cond:conductor_id(nombre), veh:vehiculo_id(numero,placa), desp:despachador_id(nombre)',
    searchCols: ['id', 'codigo', 'puesto', 'estado'],
    defaultOrder: { col: 'hora_cierre', asc: false },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'daterange' },
      { col: 'estado', label: 'Estado', options: ['Cerrado', 'Abierto'] },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha', m: true },
      { path: 'ruta.nombre', label: 'Ruta', m: true },
      { key: 'codigo', label: 'Código' },
      { path: 'veh.numero', label: 'Móvil', m: true },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'viajes', label: 'Viajes' },
      { key: 'puesto', label: 'Puesto' },
      { path: 'desp.nombre', label: 'Despachador' },
      { key: 'hora_cierre', label: 'Cierre' },
      { key: 'estado', label: 'Estado', badge: true, m: true },
    ],
    fields: [
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General' },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General' },
      { key: 'codigo', label: 'Código (turno)', type: 'text', section: 'General' },
      { key: 'puesto', label: 'Puesto', type: 'text', section: 'General' },

      { key: 'vehiculo_id', label: 'Móvil', type: 'fk', fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Operación' },
      { key: 'despachador_id', label: 'Despachador', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Operación' },
      // Viajes: solo aparece al EDITAR el registro, y siempre positivo
      { key: 'viajes', label: 'Viajes', type: 'number', min: 0, editOnly: true, section: 'Operación' },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Operación' },
      // Estado y Total de pasajeros: ocultos. Hora de cierre: automática (momento de guardado).

      // ----- Conductor -----
      { key: 'conductor_id', label: 'Conductor', type: 'fk', fk: { table: 'conductores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Conductor' },
      { key: 'doble_turno', label: '¿Doble turno? (otro conductor en otra jornada)', type: 'boolean', section: 'Conductor' },
      // Las jornadas y el 2.º conductor solo aparecen si es doble turno
      { key: 'jornada1_inicio', label: 'Jornada 1 · inicia', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada1_fin', label: 'Jornada 1 · termina', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'conductor2_id', label: 'Conductor (jornada 2)', type: 'fk', fk: { table: 'conductores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada2_inicio', label: 'Jornada 2 · inicia', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
      { key: 'jornada2_fin', label: 'Jornada 2 · termina', type: 'time', section: 'Conductor', showWhen: { field: 'doble_turno', in: [true] } },
    ],
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
    columns: [
      { key: 'fecha', label: 'Fecha' },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'email', label: 'Usuario' },
      { key: 'hora_inicio', label: 'Inicio', m: true },
      { key: 'hora_fin', label: 'Fin', m: true },
      { key: 'observacion', label: 'Puesto / Observación', m: true },
    ],
    fields: [
      { key: 'fecha', label: 'Fecha', type: 'date', required: true },
      { key: 'email', label: 'Usuario (correo)', type: 'text', required: true },
      { key: 'nombre', label: 'Nombre', type: 'text' },
      { key: 'hora_inicio', label: 'Hora de inicio', type: 'time' },
      { key: 'hora_fin', label: 'Hora finalización labor', type: 'time' },
      { key: 'observacion', label: 'Puesto / Observación', type: 'text' },
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

  conductores: {
    label: 'Conductores', icon: '👤', pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre'], defaultOrder: { col: 'nombre', asc: true },
    columns: [{ key: 'nombre', label: 'Nombre', m: true }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
  conductores_sonar: {
    label: 'Conductores SONAR', icon: '🪪', readonly: true, pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre', 'cedula', 'codigo'], defaultOrder: { col: 'nombre', asc: true },
    columns: [
      { key: 'dr_id', label: 'DrvId' },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'cedula', label: 'Cédula' },
      { key: 'codigo', label: 'Código', m: true },
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
export function configTablaPuesto(label) {
  return { ...TABLES.despachos, label, icon: '🛣️', import: undefined, noCreate: true, despachador: false };
}

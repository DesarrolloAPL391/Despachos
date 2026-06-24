// Configuración de conexión a Supabase (la anon key es pública por diseño)
export const SUPABASE_URL = 'https://ggbyeftqatnahlpunqek.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnYnllZnRxYXRuYWhscHVucWVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2MzU5NzksImV4cCI6MjA5NzIxMTk3OX0.VnJ24ahyhBeWqh38uZoeWFLxQkp_s8Ji9I8HQsYRW60';

export const PAGE_SIZE = 50;

// Etiqueta para opciones de un FK (string = columna, función = formato libre)
const labelVeh = (r) => `${r.numero ?? ''}${r.placa ? ' · ' + r.placa : ''}`;

export const TABLE_ORDER = [
  'despachos', 'laureles', 'resumen', 'horarios', 'puestos', 'perfiles', 'ubicaciones', 'vehiculosgps',
  'conductores_sonar', 'itinerarios',
];

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
    despachador: true, // visible para despachadores (filtrado por sus rutas)
    pkEditable: true, // el KEY lo escribe el usuario al crear
    import: { rpc: 'importar_despachos', map: IMPORT_MAP_DESPACHOS, kept: 'duplicados_omitidos', keptLabel: 'Ya existían (omitidos)' },
    select: '*, ruta:ruta_id(nombre), rutap:ruta_programada_id(nombre), veh:vehiculo_id(numero,placa), vehp:vehiculo_programado_id(numero,placa), cond:conductor_id(nombre), desp:despachador_id(nombre)',
    searchCols: ['id', 'estado_despacho', 'estado'],
    defaultOrder: { col: 'fecha', asc: false },
    filters: [
      { col: 'tipo', label: 'Tipo', options: ['TABLA', 'LIBRE'] },
      { col: 'estado_despacho', label: 'Despacho', options: ['DESPACHADO', 'NO REALIZA EL VIAJE', 'CANCELADO'] },
    ],
    columns: [
      { key: 'tipo', label: 'Tipo', badge: true },
      { key: 'fecha', label: 'Fecha' },
      { key: 'hora', label: 'Hora' },
      { path: 'ruta.nombre', label: 'Ruta' },
      { path: 'vehp.numero', label: 'Móvil prog.' },
      { path: 'veh.numero', label: 'Móvil' },
      { path: 'veh.placa', label: 'Placa' },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'estado_despacho', label: 'Despacho', badge: true },
      { key: 'estado', label: 'Estado', badge: true },
      { key: 'sonar_regid', label: 'regId SONAR' },
    ],
    fields: [
      // ----- General -----
      { key: 'tipo', label: 'Tipo de despacho', type: 'enum', options: ['TABLA', 'LIBRE'], required: true, default: 'TABLA', section: 'General' },
      { key: 'id', label: 'KEY (id único)', type: 'text', required: true, section: 'General' },
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General' },
      { key: 'hora', label: 'Hora', type: 'time', section: 'General' },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General' },
      { key: 'estado_despacho', label: 'Estado del despacho', type: 'text', section: 'General' },
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
      { key: 'hora_real_despacho', label: 'Hora real de despacho', type: 'time', section: 'Real' },
      { key: 'hora_finalizacion', label: 'Hora finalización', type: 'time', section: 'Real' },
      { key: 'hora_llegada', label: 'Hora de llegada', type: 'time', section: 'Real' },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Real' },
      { key: 'estado', label: 'Estado (clasificación)', type: 'text', section: 'Real' },

      // ----- Indicadores -----
      { key: 'completo', label: '¿Completo?', type: 'boolean', section: 'Indicadores' },
      { key: 'perdida_deliberada_tiempo', label: '¿Pérdida deliberada de tiempo?', type: 'boolean', section: 'Indicadores' },
      { key: 'abandono_ruta', label: '¿Abandono de ruta?', type: 'boolean', section: 'Indicadores' },

      // ----- Notas -----
      { key: 'novedades', label: 'Novedades', type: 'textarea', section: 'Notas' },
      { key: 'observacion', label: 'Observación', type: 'textarea', section: 'Notas' },
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
    import: { rpc: 'importar_resumen', map: IMPORT_MAP_RESUMEN, kept: 'actualizados', keptLabel: 'Actualizados' },
    select: '*, ruta:ruta_id(nombre), cond:conductor_id(nombre), veh:vehiculo_id(numero,placa), desp:despachador_id(nombre)',
    searchCols: ['id', 'codigo', 'puesto', 'estado'],
    defaultOrder: { col: 'hora_cierre', asc: false },
    filters: [
      { col: 'estado', label: 'Estado', options: ['Cerrado', 'Abierto'] },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha' },
      { path: 'ruta.nombre', label: 'Ruta' },
      { key: 'codigo', label: 'Código' },
      { path: 'veh.numero', label: 'Móvil' },
      { path: 'cond.nombre', label: 'Conductor' },
      { key: 'viajes', label: 'Viajes' },
      { key: 'total_pasajeros', label: 'Pasajeros' },
      { key: 'puesto', label: 'Puesto' },
      { path: 'desp.nombre', label: 'Despachador' },
      { key: 'hora_cierre', label: 'Cierre' },
      { key: 'estado', label: 'Estado', badge: true },
    ],
    fields: [
      { key: 'id', label: 'KEY (id único)', type: 'text', required: true, section: 'General' },
      { key: 'fecha', label: 'Fecha', type: 'date', section: 'General' },
      { key: 'ruta_id', label: 'Ruta', type: 'fk', fk: { table: 'rutas', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'General' },
      { key: 'codigo', label: 'Código (turno)', type: 'text', section: 'General' },
      { key: 'puesto', label: 'Puesto', type: 'text', section: 'General' },
      { key: 'estado', label: 'Estado', type: 'text', section: 'General' },

      { key: 'vehiculo_id', label: 'Móvil', type: 'fk', fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Operación' },
      { key: 'conductor_id', label: 'Conductor', type: 'fk', fk: { table: 'conductores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Operación' },
      { key: 'despachador_id', label: 'Despachador', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Operación' },
      { key: 'viajes', label: 'Viajes', type: 'number', section: 'Operación' },
      { key: 'total_pasajeros', label: 'Total de pasajeros', type: 'number', section: 'Operación' },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Operación' },
      { key: 'hora_cierre', label: 'Hora de cierre del vehículo', type: 'datetime', section: 'Operación' },
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
      { key: 'nombre', label: 'Nombre' },
      { key: 'email', label: 'Usuario' },
      { key: 'hora_inicio', label: 'Inicio' },
      { key: 'hora_fin', label: 'Fin' },
      { key: 'observacion', label: 'Puesto / Observación' },
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
      { key: 'nombre', label: 'Puesto' },
      { key: 'rutas', label: 'Rutas que cubre' },
      { key: 'activo', label: 'Activo', badge: true },
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
      { key: 'email', label: 'Correo' },
      { key: 'nombre', label: 'Nombre' },
      { key: 'rol', label: 'Rol', badge: true },
      { key: 'activo', label: 'Activo', badge: true },
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
      { key: 'movil', label: 'Móvil' },
      { key: 'placa', label: 'Placa' },
      { key: 'ruta', label: 'Última ruta' },
      { key: 'motor', label: 'Motor', badge: true },
      { key: 'driver_name', label: 'Conductor' },
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
      { key: 'numero', label: 'Móvil' },
      { key: 'placa', label: 'Placa' },
      { path: 'prop.nombre', label: 'Propietario' },
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
      { key: 'tracker_id', label: 'Tracker' },
      { key: 'gps_vehiculo_id', label: 'ID GPS' },
      { key: 'placa', label: 'Placa' },
      { key: 'movil', label: 'Móvil' },
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
    columns: [{ key: 'nombre', label: 'Nombre' }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
  conductores_sonar: {
    label: 'Conductores SONAR', icon: '🪪', readonly: true, pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre', 'cedula', 'codigo'], defaultOrder: { col: 'nombre', asc: true },
    columns: [
      { key: 'dr_id', label: 'DrvId' },
      { key: 'nombre', label: 'Nombre' },
      { key: 'cedula', label: 'Cédula' },
      { key: 'codigo', label: 'Código' },
      { key: 'cellphone', label: 'Celular' },
      { key: 'status', label: 'Estado', badge: true },
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
      { key: 'nombre', label: 'Nombre' },
      { key: 'grupo', label: 'Grupo' },
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
    columns: [{ key: 'nombre', label: 'Nombre' }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
  despachadores: {
    label: 'Despachadores', icon: '🧑‍💼', pk: 'id', pkEditable: false, select: '*',
    searchCols: ['nombre'], defaultOrder: { col: 'nombre', asc: true },
    columns: [{ key: 'nombre', label: 'Nombre' }],
    fields: [{ key: 'nombre', label: 'Nombre', type: 'text', required: true }],
  },
};

// Tabla de puesto "Laureles": misma estructura y función que Despachos (despachar/cancelar a SONAR),
// pero es su propia tabla en la base de datos. No se importa aquí ni se crean filas sueltas.
TABLES.laureles = {
  ...TABLES.despachos,
  label: 'Laureles',
  icon: '🛣️',
  import: undefined,
  noCreate: true,
  despachador: false, // por ahora visible solo para admin
};

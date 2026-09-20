// Configuración de conexión a Supabase (la anon key es pública por diseño)
export const SUPABASE_URL = 'https://ggbyeftqatnahlpunqek.supabase.co';
export const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdnYnllZnRxYXRuYWhscHVucWVrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODE2MzU5NzksImV4cCI6MjA5NzIxMTk3OX0.VnJ24ahyhBeWqh38uZoeWFLxQkp_s8Ji9I8HQsYRW60';

// Clave de TomTom para la CAPA DE TRÁFICO del mapa (gratuita: developer.tomtom.com).
// Es una clave pública de cliente, como la anon de Supabase. Déjala vacía para desactivar
// el tráfico. En producción conviene restringirla por dominio en el panel de TomTom.
export const TOMTOM_KEY = '465FQuidHJ1iGwmTWyGQJOkuXO1JF9MU';

export const PAGE_SIZE = 50;

// Versión visible del aplicativo (mantener igual al número de caché en sw.js)
export const APP_VERSION = 'v266';

// Etiqueta para opciones de un FK (string = columna, función = formato libre)
const labelVeh = (r) => `${r.numero ?? ''}${r.placa ? ' · ' + r.placa : ''}`;

// Novedades operativas (tomadas de los datos reales de despachos y tablas)
const NOVEDADES = [
  'PESCA', 'TALLER', 'NO MADRUGA', 'SIN INFORMACION', 'REEMPLAZA OTRO VEHICULO', 'SIN CONDUCTOR', 'SIN ORDEN DE DESPACHO','ERROR DESPACHADOR', 'CAMBIO DE TABLA', 'CAMBIO DE RUTA', 'SUSPENDIDO',
  'REQUERIMIENTO EMPRESA', 'VACACIONES', 'PERMISO', 'CONDUCTOR EN OTRA RUTA', 'CONDUCTOR EN OTRO VEHICULO',
  'INCAPACIDAD EPS', 'CITA MEDICA EPS', 'RESTRICCION MEDICA', 'RESTRICCION OPERACIONAL', 'SINIESTRO VIAL', 'CDA', 'ADELANTADO', 'ABANDONA EL SERVICIO', 'CONGESTION VEHICULAR',
];

export const TABLE_ORDER = [
  'despachos', 'despachos_sonar', 'resumen', 'asistencia', 'horarios', 'puestos', 'perfiles', 'tablas_despacho', 'ubicaciones', 'vehiculosgps',
  'conductores_sonar', 'parque_automotor', 'restricciones_rutas', 'itinerarios', 'perfilsociodemografico', 'perfil_vinculaciones',
  'siniestros',
];

// Listas unificadas del PERFIL SOCIODEMOGRÁFICO. Las usan el formulario del admin y el link público
// de actualización de datos (actualizar-datos.html), para que los datos no se vuelvan a desordenar.
export const PERFIL_LISTAS = {
  tipo: ['CONDUCTOR', 'ADMINISTRATIVO'],
  estado: ['ACTIVO', 'INACTIVO'],
  tipo_ingreso: ['NUEVO', 'REINGRESO', 'PROVEEDOR'],
  tipo_contrato: ['INDEFINIDO', 'FIJO', 'APRENDIZAJE', 'OBRA O LABOR', 'PRESTACIÓN DE SERVICIOS'],
  area: ['OPERATIVA', 'ADMINISTRATIVA', 'CONTROL', 'RUTAS', 'CONTABILIDAD', 'TALLER', 'RECURSO HUMANO', 'GERENCIA',
    'SEGURIDAD VIAL', 'OPERACIONES', 'GESTION DE FLOTAS', 'APRENDIZ'],
  eps: ['SURA', 'SALUD TOTAL', 'NUEVA EPS', 'SAVIA SALUD', 'SANITAS', 'COOSALUD', 'COOMEVA', 'MEDIMÁS', 'COMPENSAR',
    'FAMISANAR', 'CAJACOPI', 'SANIDAD MILITAR', 'FAMILIAR DE COLOMBIA'],
  afp: ['PROTECCIÓN', 'PORVENIR', 'COLPENSIONES', 'COLFONDOS', 'SKANDIA', 'NO APLICA'],
  sexo: ['MASCULINO', 'FEMENINO'],
  tipo_sangre: ['O+', 'O-', 'A+', 'A-', 'B+', 'B-', 'AB+', 'AB-'],
  estado_civil: ['SOLTERO(A)', 'UNIÓN LIBRE', 'CASADO(A)', 'SEPARADO(A)', 'DIVORCIADO(A)', 'VIUDO(A)'],
  si_no: ['SI', 'NO'],
  tipo_vivienda: ['ARRENDADA', 'FAMILIAR', 'PROPIA', 'COMPARTIDA'],
  estrato: ['1', '2', '3', '4', '5', '6'],
  departamento: ['ANTIOQUIA', 'AMAZONAS', 'ARAUCA', 'ATLÁNTICO', 'BOGOTÁ D.C.', 'BOLÍVAR', 'BOYACÁ', 'CALDAS', 'CAQUETÁ',
    'CASANARE', 'CAUCA', 'CESAR', 'CHOCÓ', 'CÓRDOBA', 'CUNDINAMARCA', 'GUAINÍA', 'GUAVIARE', 'HUILA', 'LA GUAJIRA',
    'MAGDALENA', 'META', 'NARIÑO', 'NORTE DE SANTANDER', 'PUTUMAYO', 'QUINDÍO', 'RISARALDA', 'SAN ANDRÉS', 'SANTANDER',
    'SUCRE', 'TOLIMA', 'VALLE DEL CAUCA', 'VAUPÉS', 'VICHADA', 'VENEZUELA'],
  ciudad: ['MEDELLÍN', 'BELLO', 'ITAGÜÍ', 'ENVIGADO', 'SABANETA', 'CALDAS', 'LA ESTRELLA', 'COPACABANA', 'GIRARDOTA',
    'BARBOSA', 'SAN ANTONIO DE PRADO', 'MARINILLA', 'RIONEGRO', 'GUARNE'],
  escolaridad: ['PRIMARIA INCOMPLETA', 'PRIMARIA', 'SECUNDARIA INCOMPLETA', 'BACHILLER', 'TÉCNICO', 'TECNÓLOGO',
    'PROFESIONAL', 'POSGRADO'],
  personas_a_cargo: ['NINGUNA', '1 A 3 PERSONAS', '4 A 6 PERSONAS', 'MÁS DE 6 PERSONAS'],
  parentesco: ['CÓNYUGE/PAREJA', 'MADRE', 'PADRE', 'HERMANO(A)', 'HIJO(A)', 'NOVIO(A)', 'TÍO(A)', 'PRIMO(A)',
    'ABUELO(A)', 'SUEGRO(A)', 'CUÑADO(A)', 'SOBRINO(A)', 'OTRO FAMILIAR', 'AMIGO(A)'],
  categoria_licencia: ['A1', 'A2', 'B1', 'B2', 'B3', 'C1', 'C2', 'C3'],
  estado_restriccion: ['SIN RESTRICCION', 'RESTRINGIDO'],
};
const PL = PERFIL_LISTAS;

// ---- 🧑‍✈️ PROCESO DE ASPIRANTES A CONDUCTOR (sql/77) ----
// Lo usan el link público (trabaja-con-nosotros.html) y la pantalla del admin.
export const ASPIRANTE_LISTAS = {
  vehiculos: ['BUS', 'BUSETA', 'MICROBÚS', 'CAMIÓN', 'TAXI', 'CAMIONETA'],
  como_se_entero: ['REFERIDO POR UN CONDUCTOR O EMPLEADO', 'REDES SOCIALES', 'PORTAL DE EMPLEO', 'AVISO EN LA EMPRESA', 'OTRO'],
  disponibilidad: ['INMEDIATA', 'EN 15 DÍAS', 'EN 1 MES O MÁS'],
  // Documentos que sube el aspirante (máx. 15 archivos en total, lo controla el servidor)
  documentos: [
    { key: 'cedula', label: 'Cédula (ambas caras)', req: true, max: 2 },
    { key: 'licencia', label: 'Licencia de conducción (ambas caras)', req: true, max: 2 },
    { key: 'hoja_vida', label: 'Hoja de vida', max: 2 },
    { key: 'certificados', label: 'Certificados laborales', max: 3 },
    { key: 'antecedentes', label: 'Antecedentes (Policía, Procuraduría, Contraloría, SIMIT)', max: 4 },
    { key: 'otros', label: 'Otros documentos', max: 2 },
  ],
  // Documentos que agrega el admin durante el proceso (resultados de pruebas, exámenes, contrato)
  documentos_admin: [
    { key: 'antecedentes', label: 'Antecedentes consultados' },
    { key: 'psicotecnicas', label: 'Resultado psicotécnicas' },
    { key: 'prueba_manejo', label: 'Formato prueba de manejo' },
    { key: 'examen_medico', label: 'Examen médico de ingreso' },
    { key: 'visita_domiciliaria', label: 'Visita domiciliaria' },
    { key: 'contrato', label: 'Contrato firmado' },
    { key: 'otros', label: 'Otros documentos' },
  ],
  motivos_descarte: ['DOCUMENTOS INCOMPLETOS O NO VÁLIDOS', 'LICENCIA NO VÁLIDA O VENCIDA', 'ANTECEDENTES', 'MULTAS O COMPARENDOS PENDIENTES',
    'NO APROBÓ ENTREVISTA O PSICOTÉCNICAS', 'NO APROBÓ LA PRUEBA DE MANEJO', 'NO APTO EN EXAMEN MÉDICO', 'VISITA DOMICILIARIA NO FAVORABLE',
    'NO ASISTIÓ O NO RESPONDE', 'DESISTIÓ', 'OTRO'],
};
// Etapas en orden, con su lista de chequeo (cada ítem: ✅ cumple / ❌ no cumple / N/A) y datos extra
export const ASPIRANTE_ETAPAS = [
  { key: 'DOCUMENTOS', icon: '📄', label: 'Documentos y antecedentes', corto: 'Documentos',
    checks: [['hoja_vida', 'Hoja de vida'], ['cedula', 'Cédula'], ['licencia', 'Licencia C2/C3 vigente (verificada en RUNT)'],
      ['policia', 'Antecedentes Policía Nacional'], ['procuraduria', 'Antecedentes Procuraduría'], ['contraloria', 'Antecedentes Contraloría'],
      ['simit', 'SIMIT sin multas pendientes'], ['referencias', 'Certificados y referencias laborales verificadas']] },
  { key: 'ENTREVISTA', icon: '🗣️', label: 'Entrevista y psicotécnicas', corto: 'Entrevista',
    checks: [['entrevista', 'Entrevista con Gestión Humana'], ['psicotecnica', 'Prueba psicotécnica'], ['psicosensometrica', 'Prueba psicosensométrica']],
    campos: [{ key: 'entrevistador', label: 'Entrevistó', type: 'text' }, { key: 'concepto', label: 'Concepto / puntaje', type: 'text' }] },
  { key: 'MANEJO', icon: '🚌', label: 'Prueba de manejo', corto: 'Manejo',
    checks: [['conduccion', 'Conducción en ruta'], ['maniobras', 'Maniobras, reversa y parqueo'], ['normas', 'Normas de tránsito y trato al pasajero']],
    campos: [{ key: 'instructor', label: 'Instructor', type: 'text' }, { key: 'movil', label: 'Móvil usado', type: 'text' },
      { key: 'calificacion', label: 'Calificación (0 a 100)', type: 'number' }] },
  { key: 'MEDICOS', icon: '🩺', label: 'Médicos y visita domiciliaria', corto: 'Médicos',
    checks: [['examen_medico', 'Examen médico de ingreso'], ['visita', 'Visita domiciliaria'], ['estudio_seguridad', 'Estudio de seguridad']],
    campos: [{ key: 'concepto_medico', label: 'Concepto médico', type: 'enum', options: ['APTO', 'APTO CON RESTRICCIONES', 'NO APTO'] }] },
];
// Datos de la inscripción, en el orden en que se muestran y se exportan
export const ASPIRANTE_CAMPOS = [
  { grupo: 'Contacto y vivienda', campos: [['celular', 'Celular'], ['telefono', 'Otro teléfono'], ['correo', 'Correo'], ['direccion', 'Dirección'],
    ['barrio', 'Barrio'], ['ciudad', 'Municipio'], ['departamento', 'Departamento'], ['estrato', 'Estrato'], ['tipo_vivienda', 'Tipo de vivienda']] },
  { grupo: 'Licencia y experiencia', campos: [['categoria_licencia', 'Categoría de licencia'], ['numero_licencia', 'Número de licencia'],
    ['licencia_expedicion', 'Expedición de la licencia'], ['licencia_vencimiento', 'Vencimiento de la licencia'], ['restricciones_licencia', 'Restricciones de la licencia'],
    ['experiencia_anios', 'Años de experiencia (servicio público)'], ['vehiculos_conducidos', 'Vehículos que ha conducido'],
    ['comparendos_pendientes', '¿Tiene comparendos pendientes?'], ['trabajo_antes_apl', '¿Trabajó antes en APL?'], ['disponibilidad', 'Disponibilidad'],
    ['como_se_entero', '¿Cómo se enteró?'], ['referido_por', 'Referido por']] },
  { grupo: 'Datos personales', campos: [['sexo', 'Sexo'], ['tipo_sangre', 'Tipo de sangre'], ['estado_civil', 'Estado civil'], ['uso_lentes', '¿Usa lentes?'],
    ['eps', 'EPS'], ['afp', 'Fondo de pensiones'], ['escolaridad', 'Escolaridad'], ['escolaridad_detalle', 'Último grado o título'],
    ['institucion_educativa', 'Institución educativa']] },
  { grupo: 'Núcleo familiar', campos: [['personas_a_cargo', 'Personas a cargo'], ['convive_pareja', '¿Tiene pareja?'], ['nombre_pareja', 'Nombre de la pareja'],
    ['edad_pareja', 'Edad de la pareja'], ['tiene_hijos', '¿Tiene hijos?'], ['edades_hijos', 'Edades de los hijos'], ['edades_hijas', 'Edades de las hijas'],
    ['otros_a_cargo', 'Otras personas a cargo'], ['edades_otros', 'Edades de otras personas a cargo']] },
  { grupo: 'Contacto de emergencia', campos: [['emergencia_nombre', 'Nombre'], ['emergencia_parentesco', 'Parentesco'],
    ['emergencia_telefono1', 'Teléfono 1'], ['emergencia_telefono2', 'Teléfono 2'], ['emergencia_direccion', 'Dirección']] },
  { grupo: 'Referencias', campos: [['ref_empresa', 'Última empresa'], ['ref_cargo', 'Cargo'], ['ref_nombre_jefe', 'Jefe inmediato'],
    ['ref_telefono_jefe', 'Teléfono del jefe'], ['ref_fecha_ingreso', 'Fecha de ingreso'], ['ref_fecha_retiro', 'Fecha de retiro'],
    ['ref_motivo_retiro', 'Motivo de retiro'], ['refp_nombre', 'Referencia personal'], ['refp_parentesco', 'Relación'], ['refp_telefono', 'Teléfono referencia personal']] },
];

// Años cumplidos entre una fecha (YYYY-MM-DD) y otra (por defecto hoy)
function aniosEntre(desde, hasta) {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(desde || '')); if (!m) return '';
  const h = hasta ? new Date(String(hasta).slice(0, 10) + 'T12:00:00') : new Date();
  let a = h.getFullYear() - Number(m[1]);
  if (h.getMonth() + 1 < Number(m[2]) || (h.getMonth() + 1 === Number(m[2]) && h.getDate() < Number(m[3]))) a--;
  return a >= 0 && a < 120 ? a : '';
}
export const edadPerfil = (r) => aniosEntre(r.fecha_nacimiento);
export const antiguedadPerfil = (r) => aniosEntre(r.fecha_ingreso, r.fecha_retiro);
// Campos de la ficha del empleado (se reutilizan para exportar TODO a Excel)
const PERFIL_FIELDS = [
  { key: 'cedula', label: 'Cédula', type: 'text', required: true, section: 'Identificación', hint: 'Solo números. Es la llave de la persona: no se repite.' },
  { key: 'nombre', label: 'Apellidos y nombre', type: 'text', required: true, section: 'Identificación' },
  { key: 'tipo', label: 'Tipo de empleado', type: 'enum', options: PL.tipo, required: true, section: 'Identificación' },
  { key: 'estado', label: 'Estado', type: 'enum', options: PL.estado, required: true, section: 'Identificación', hint: 'Al retirar a alguien: INACTIVO + fecha de retiro. Al reintegrarlo: ACTIVO + la nueva fecha de ingreso (queda en el historial).' },
  { key: 'codigo', label: 'Código', type: 'text', section: 'Identificación' },
  { key: 'correo', label: 'Correo electrónico', type: 'text', section: 'Identificación' },
  { key: 'celular', label: 'Celular', type: 'text', section: 'Identificación' },
  { key: 'telefono', label: 'Teléfono fijo', type: 'text', section: 'Identificación' },
  { key: 'fecha_ingreso', label: 'Fecha de ingreso', type: 'date', required: true, section: 'Laboral' },
  { key: 'fecha_retiro', label: 'Fecha de retiro', type: 'date', section: 'Laboral' },
  { key: 'tipo_ingreso', label: 'Tipo de ingreso', type: 'enum', options: PL.tipo_ingreso, section: 'Laboral' },
  { key: 'tipo_contrato', label: 'Tipo de contrato', type: 'enum', options: PL.tipo_contrato, section: 'Laboral' },
  { key: 'cargo', label: 'Cargo', type: 'text', required: true, section: 'Laboral' },
  { key: 'area', label: 'Área', type: 'enum', options: PL.area, section: 'Laboral' },
  { key: 'salario', label: 'Salario', type: 'number', min: 0, section: 'Laboral' },
  { key: 'centro_costos', label: 'Centro de costos', type: 'text', section: 'Laboral' },
  { key: 'nombre_propietario', label: 'Nombre propietario (vehículo / empleador)', type: 'text', section: 'Laboral' },
  { key: 'placa', label: 'Placa', type: 'text', section: 'Laboral' },
  { key: 'novedad_retiro', label: 'Novedad de retiro', type: 'text', section: 'Laboral' },
  { key: 'eps', label: 'EPS', type: 'enum', options: PL.eps, section: 'Seguridad social' },
  { key: 'afp', label: 'Fondo de pensiones (AFP)', type: 'enum', options: PL.afp, section: 'Seguridad social' },
  { key: 'arl', label: 'ARL', type: 'text', section: 'Seguridad social' },
  { key: 'categoria_licencia', label: 'Categoría de licencia', type: 'enum', options: PL.categoria_licencia, section: 'Licencia y restricción', hint: 'Aplica a conductores.' },
  { key: 'numero_licencia', label: 'Número de licencia', type: 'text', section: 'Licencia y restricción' },
  { key: 'licencia_expedicion', label: 'Expedición de la licencia', type: 'date', section: 'Licencia y restricción' },
  { key: 'licencia_vencimiento', label: 'Vencimiento de la licencia', type: 'date', section: 'Licencia y restricción' },
  { key: 'restricciones_licencia', label: 'Restricciones de la licencia', type: 'text', section: 'Licencia y restricción' },
  { key: 'estado_restriccion', label: 'Estado de restricción', type: 'enum', options: PL.estado_restriccion, section: 'Licencia y restricción' },
  { key: 'motivo_restriccion', label: 'Motivo de la restricción', type: 'textarea', section: 'Licencia y restricción' },
  { key: 'sexo', label: 'Sexo', type: 'enum', options: PL.sexo, section: 'Datos personales' },
  { key: 'fecha_nacimiento', label: 'Fecha de nacimiento', type: 'date', section: 'Datos personales' },
  { key: 'tipo_sangre', label: 'Tipo de sangre', type: 'enum', options: PL.tipo_sangre, section: 'Datos personales' },
  { key: 'estado_civil', label: 'Estado civil', type: 'enum', options: PL.estado_civil, section: 'Datos personales' },
  { key: 'uso_lentes', label: '¿Usa lentes?', type: 'enum', options: PL.si_no, section: 'Datos personales' },
  { key: 'direccion', label: 'Dirección', type: 'text', section: 'Vivienda' },
  { key: 'barrio', label: 'Barrio', type: 'text', section: 'Vivienda' },
  { key: 'ciudad', label: 'Ciudad / municipio', type: 'text', section: 'Vivienda' },
  { key: 'departamento', label: 'Departamento', type: 'enum', options: PL.departamento, section: 'Vivienda' },
  { key: 'estrato', label: 'Estrato', type: 'number', min: 0, section: 'Vivienda' },
  { key: 'tipo_vivienda', label: 'Tipo de vivienda', type: 'enum', options: PL.tipo_vivienda, section: 'Vivienda' },
  { key: 'escolaridad', label: 'Escolaridad', type: 'enum', options: PL.escolaridad, section: 'Educación' },
  { key: 'escolaridad_detalle', label: 'Detalle de escolaridad', type: 'text', section: 'Educación', hint: 'Último grado o título (ej. OCTAVO, TÉCNICO EN MECÁNICA).' },
  { key: 'institucion_educativa', label: 'Institución educativa', type: 'text', section: 'Educación' },
  { key: 'fecha_ultimo_grado', label: 'Fecha del último grado', type: 'date', section: 'Educación' },
  { key: 'ciudad_estudio', label: 'Ciudad donde estudió', type: 'text', section: 'Educación' },
  { key: 'departamento_estudio', label: 'Departamento donde estudió', type: 'enum', options: PL.departamento, section: 'Educación' },
  { key: 'personas_a_cargo', label: 'Personas a cargo', type: 'enum', options: PL.personas_a_cargo, section: 'Núcleo familiar' },
  { key: 'convive_pareja', label: '¿Tiene esposo(a) / pareja?', type: 'enum', options: PL.si_no, section: 'Núcleo familiar' },
  { key: 'nombre_pareja', label: 'Nombre de la pareja', type: 'text', section: 'Núcleo familiar' },
  { key: 'edad_pareja', label: 'Edad de la pareja', type: 'text', section: 'Núcleo familiar' },
  { key: 'tiene_hijos', label: '¿Tiene hijos?', type: 'enum', options: PL.si_no, section: 'Núcleo familiar' },
  { key: 'edades_hijos', label: 'Edades de los hijos', type: 'text', section: 'Núcleo familiar' },
  { key: 'edades_hijas', label: 'Edades de las hijas', type: 'text', section: 'Núcleo familiar' },
  { key: 'otros_a_cargo', label: 'Otras personas a cargo', type: 'text', section: 'Núcleo familiar' },
  { key: 'edades_otros', label: 'Edades de otras personas a cargo', type: 'text', section: 'Núcleo familiar' },
  { key: 'emergencia_nombre', label: 'Contacto de emergencia', type: 'text', section: 'Contacto de emergencia' },
  { key: 'emergencia_parentesco', label: 'Parentesco', type: 'enum', options: PL.parentesco, section: 'Contacto de emergencia' },
  { key: 'emergencia_telefono1', label: 'Teléfono 1', type: 'text', section: 'Contacto de emergencia' },
  { key: 'emergencia_telefono2', label: 'Teléfono 2', type: 'text', section: 'Contacto de emergencia' },
  { key: 'emergencia_direccion', label: 'Dirección del contacto', type: 'text', section: 'Contacto de emergencia' },
  { key: 'ref_empresa', label: 'Empresa (referencia laboral)', type: 'text', section: 'Referencia laboral' },
  { key: 'ref_cargo', label: 'Cargo desempeñado', type: 'text', section: 'Referencia laboral' },
  { key: 'ref_telefono_jefe', label: 'Teléfono del jefe inmediato', type: 'text', section: 'Referencia laboral' },
  { key: 'ref_fecha_ingreso', label: 'Fecha de ingreso (referencia)', type: 'date', section: 'Referencia laboral' },
  { key: 'ref_fecha_retiro', label: 'Fecha de retiro (referencia)', type: 'date', section: 'Referencia laboral' },
  { key: 'por_corregir', label: 'Campos por corregir', type: 'text', readOnly: true, section: 'Control de datos', hint: 'Vinieron dañados o incoherentes del archivo de origen. Cada campo sale de esta lista solo, al corregirlo y guardar.' },
  { key: 'origen', label: 'Origen del registro', type: 'text', readOnly: true, section: 'Control de datos' },
  { key: 'actualizado_por', label: 'Última actualización por', type: 'text', readOnly: true, section: 'Control de datos' },
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
  'hora de salida': 'hora', // en las tablas la salida real = hora del viaje
  'estado': 'despachado',   // en las tablas "estado" es el estado del despacho (SIN DESPACHO / DESPACHADO)
};

// Mapa de encabezados (normalizados) -> campo, para la importación de resumen
const IMPORT_MAP_RESUMEN = {
  'keys': 'key', 'key': 'key', 'fecha': 'fecha', 'ruta': 'ruta', 'codigo': 'codigo',
  'viajes': 'viajes', 'total de pasajeros': 'total_pasajeros', 'nombre de conductor': 'conductor',
  'conductor': 'conductor', 'vehiculo': 'vehiculo', 'puesto': 'puesto', 'despachador': 'despachador',
  'ubicacion': 'ubicacion', 'hora de cerrada de vehiculo': 'hora_cierre', 'estado': 'estado',
};

// Claves de las tablas de puesto (para condicionar los campos de Restricciones de rutas).
// 'despachos' es la vista general (restricción por vehículo + conductor + franja).
const PUESTO_TABLE_KEYS = ['laureles', 't_130', 't_132a', 't_133_133d', 't_135_sab', 't_193', 't_287', 't_313'];

export const TABLES = {
  despachos: {
    label: 'Despachos',
    icon: '🚍',
    pk: 'id',
    dispatchable: true, // permite despachar/cancelar a SONAR desde las filas
    eventosSonar: true, // botón 🔎 de eventos del bus (auditor/admin). Lo heredan las tablas de puesto
    // El ADMIN sí puede eliminar un despacho fila por fila (botón 🗑️; solo admin, RLS es_admin()).
    // Lo heredan las tablas de puesto. Ojo: si el viaje ya tiene regId de SONAR, borrarlo aquí NO
    // lo cancela en SONAR (se avisa al confirmar). Para borrar todo el día está "🗑️ Borrar día".
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
      // Hora REAL a la que el despachador despachó (despachado_en), con la diferencia en minutos
      // frente a la hora enviada. Solo auditor/admin (para detectar que despacharon antes/después).
      { key: 'despachado_en', label: 'Hora real', horaReal: true, auditCol: true },
      { path: 'ruta.nombre', label: 'Ruta', m: true },
      // Cambio de RUTA: ruta programada → ruta despachada (cuando difieren). Solo auditor/admin.
      { label: 'Cambio ruta', cambioRuta: true, auditCol: true },
      { path: 'vehp.numero', label: 'Móvil prog.' },
      { path: 'veh.numero', label: 'Móvil', m: true },
      { key: 'cambio', label: 'Cambio móvil' },
      { path: 'cond.nombre', label: 'Conductor' },
      { path: 'desp.nombre', label: 'Despachador' },
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
    // Una vez AUDITADO, la fila queda bloqueada: no se puede volver a auditar ni editar.
    rowLocked: (row) => row.auditado === true,
    lockedHint: 'Ya auditado — no se puede volver a auditar',
    eventosSonar: true, // 🔎 en cada fila: ver el recorrido y saber POR QUÉ quedó incompleto
    select: '*',
    // La descarga del auditor sale COMPLETA: incluye quién auditó, cuándo y el comentario.
    exportCols: [
      { key: 'fecha', label: 'Fecha' },
      { key: 'hora_inicio', label: 'Hora' },
      { key: 'ruta', label: 'Ruta' },
      { key: 'movil', label: 'Móvil' },
      { key: 'placa', label: 'Placa' },
      { key: 'conductor', label: 'Conductor' },
      { key: 'estado', label: 'Estado' },
      { key: 'comentario', label: 'Comentario SONAR' },
      { key: 'auditado', label: 'Auditado' },
      { key: 'auditor_email', label: 'Auditor' },
      { key: 'auditado_en', label: 'Fecha auditoría' },
      { key: 'observacion', label: 'Observación del auditor' },
    ],
    searchCols: ['movil', 'placa', 'ruta', 'conductor'],
    defaultOrder: { col: 'fecha', asc: false, then: { col: 'hora_inicio', asc: true } },
    filters: [
      { col: 'fecha', label: 'Fecha', type: 'date' },
      { col: 'estado', label: 'Estado', options: ['Completo', 'Incompleto', 'Cancelado', 'En progreso'] },
      { col: 'auditado', label: 'Auditoría', options: [{ value: true, label: 'Auditados' }, { value: false, label: 'Pendientes por auditar' }] },
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
    adminBypassLock: true, // el ADMIN sí puede editar/borrar filas "Cerrado" (el candado solo aplica a no-admin)
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

      // Móvil y Conductor: obligatorios para ABRIR el carro (apertura).
      { key: 'vehiculo_id', label: 'Móvil', type: 'fk', qr: true, fk: { table: 'vehiculos', sel: 'id,numero,placa', label: labelVeh, order: 'numero' }, section: 'Operación', required: true },
      // Despachador: quien ABRE. Se autocompleta con el usuario logueado (ctxValue) y no lo edita el
      // despachador (softReadOnly); el handler lo fija a la sesión SOLO al crear (no se sobrescribe cuando
      // otro despachador del turno de la tarde cierra). Obligatorio (el admin sí lo elige a mano).
      { key: 'despachador_id', label: 'Despachador (abre)', type: 'fk', fk: { table: 'despachadores', sel: 'id,nombre', label: 'nombre', order: 'nombre' }, section: 'Operación', required: true, ctxValue: 'despachador_id', softReadOnlyDispatcher: true },
      // Viajes: dato de CIERRE (lo llena el 2º despachador al terminar). Solo aparece al EDITAR,
      // no al abrir. No obligatorio para abrir; el registro queda 'Cerrado' cuando se llena (closeRequired).
      { key: 'viajes', label: 'Viajes', type: 'number', min: 0, editOnly: true, section: 'Operación' },
      { key: 'ubicacion', label: 'Ubicación (GPS lat, lng)', type: 'text', section: 'Operación', readOnly: true },
      // Estado y Total de pasajeros: ocultos. Hora de cierre: automática (momento de guardado).

      // ----- Conductor -----
      { key: 'conductor_id', label: 'Conductor (SONAR)', type: 'sonardrv', nameFrom: 'cond.nombre', section: 'Conductor', qr: true, required: true },
      { key: 'doble_turno', label: '¿Doble turno? (otro conductor en otra jornada)', type: 'boolean', section: 'Conductor' },
      // Las jornadas y el 2.º conductor solo aparecen si es doble turno. Son datos de CIERRE:
      // se exigen para cerrar (closeRequiredDoble), no para abrir el carro.
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
      { key: 'observacion', label: 'Puesto(s)' },
    ],
    fields: [
      { key: 'fecha', label: 'Fecha', type: 'date', required: true },
      { key: 'email', label: 'Usuario (correo)', type: 'text', required: true },
      { key: 'nombre', label: 'Nombre', type: 'textsel', optionsFrom: { table: 'perfiles', col: 'nombre', where: ['activo', true] } },
      { key: 'hora_inicio', label: 'Hora de inicio', type: 'time' },
      { key: 'hora_fin', label: 'Hora finalización labor', type: 'time' },
      { key: 'grupos', label: 'Grupos de ruta (opcional)', type: 'multisel', optionsFrom: { table: 'parque_automotor', col: 'ruta' }, hint: 'Opcional: agrega grupos extra además de los del puesto.' },
      { key: 'observacion', label: 'Puesto(s)', type: 'multisel', csv: true, optionsFrom: { table: 'puestos', col: 'nombre', where: ['activo', true] }, hint: 'Marca uno o varios puestos. El despachador verá y despachará las rutas de todos.' },
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
      { key: 'rutas', label: 'Rutas que cubre', type: 'multisel', csv: true, optionsFrom: { table: 'rutas', col: 'nombre' }, hint: 'Marca las rutas de este puesto (usa el buscador). Se guardan separadas por coma.' },
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

  // Administración de las TABLAS DE DESPACHO por puesto (las que se descubren en caliente).
  // La tabla física se crea por SQL (setup_tabla_puesto); aquí el admin la ENCIENDE/APAGA en el
  // menú (activo) y ajusta su nombre visible / puesto. Solo el admin la ve (menuOrder). Escribe
  // con la sesión del propio admin (RLS td_all + en_horario()=true para admin).
  tablas_despacho: {
    label: 'Tablas de despacho',
    icon: '🚌',
    pk: 'tabla',
    pkEditable: false,
    noCreate: true, // las tablas físicas se crean por SQL (setup_tabla_puesto), no como fila suelta
    noDelete: true, // quitar la fila la saca del menú de TODOS; se hace por SQL a conciencia
    select: '*',
    searchCols: ['label', 'tabla', 'puesto'],
    defaultOrder: { col: 'label', asc: true },
    columns: [
      { key: 'label', label: 'Nombre', m: true },
      { key: 'tabla', label: 'Tabla (BD)' },
      { key: 'puesto', label: 'Puesto', m: true },
      { key: 'activo', label: 'Activa', badge: true, m: true },
      { key: 'sin_sonar', label: 'Sin SONAR', badge: true },
    ],
    fields: [
      { key: 'tabla', label: 'Tabla (BD)', type: 'text', hint: 'Nombre físico en la base. No se edita: se define al crearla por SQL.' },
      { key: 'label', label: 'Nombre visible', type: 'text', required: true, hint: 'Como aparece en el menú (ej. 136II).' },
      { key: 'puesto', label: 'Puesto', type: 'textsel', optionsFrom: { table: 'puestos', col: 'nombre' }, hint: 'Debe coincidir con el puesto: define quién (qué despachador) la ve.' },
      { key: 'activo', label: '¿Activa? (aparece en el menú)', type: 'boolean', default: false, hint: 'Enciéndela para que la tabla salga en el submenú 🚌 Despachos. Apágala para ocultarla.' },
      { key: 'sin_sonar', label: '¿Registra sin enviar a SONAR?', type: 'boolean', default: false, hint: 'Si está activo, al despachar solo se guarda el registro local (quién despachó, móvil, conductor, hora, GPS) y NO se envía a SONAR.' },
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
  restricciones_rutas: {
    label: 'Restricciones de rutas',
    icon: '🚫',
    despachador: true,     // el despachador la ve (solo lectura); el AUDITOR las crea/edita
    pk: 'id',
    pkEditable: false,
    select: '*',
    searchCols: ['vehiculo', 'conductor', 'ruta', 'novedad', 'propietario'],
    defaultOrder: { col: 'fecha_novedad', asc: false },
    filters: [
      { col: 'estado', label: 'Estado', options: ['VIGENTE', 'CANCELADA'] },
    ],
    columns: [
      { key: 'fecha_novedad', label: 'F. novedad', m: true },
      { key: 'vehiculo', label: 'Móvil', m: true },
      { key: 'tabla', label: 'Tabla' },
      { key: 'ruta_restringida', label: 'Ruta restr.', m: true },
      { key: 'modo', label: 'Tipo' },
      { key: 'fecha_restriccion', label: 'F. restricción', m: true },
      { key: 'viajes_hora', label: 'Detalle' },
      { key: 'novedad', label: 'Novedad' },
      { key: 'estado', label: 'Estado', badge: true, m: true },
    ],
    fields: [
      { key: 'fecha_novedad', label: 'Fecha novedad', type: 'date', section: 'General' },
      { key: 'ruta', label: 'Ruta infracción', type: 'textsel', optionsFrom: { table: 'itinerarios', col: 'nombre' }, section: 'General', hint: 'Ruta donde ocurrió la infracción (informativo). Elígela de la lista.' },
      { key: 'vehiculo', label: 'Móvil (N° interno)', type: 'textsel', optionsFrom: { table: 'vehiculos', col: 'numero' }, section: 'General', requiredWhen: { field: 'tabla', in: PUESTO_TABLE_KEYS }, hint: 'En tablas de puesto el bloqueo es por móvil (obligatorio ahí). En Despachos es opcional (ahí bloquea el conductor). Elígelo de la lista para que coincida con el despacho.' },
      { key: 'conductor', label: 'Conductor', type: 'textsel', optionsFrom: { table: 'conductores_sonar', col: 'nombre', where: ['status', 'ENABLED'] }, section: 'General', requiredWhen: { field: 'tabla', in: ['despachos'] }, hint: 'En Despachos el bloqueo sigue al CONDUCTOR en cualquier móvil (obligatorio ahí). Elígelo de la lista para que coincida EXACTO con el despacho.' },
      { key: 'novedad', label: 'Novedad (qué incumplió)', type: 'text', section: 'General' },
      { key: 'tabla', label: 'Tabla / puesto donde aplica', type: 'enum', options: [...PUESTO_TABLE_KEYS, 'despachos'], required: true, section: 'Restricción', hint: 'Una tabla de puesto (laureles, t_130, …) = bloquea por MÓVIL + RUTA. "despachos" (vista general) = bloquea por CONDUCTOR (cualquier móvil) + franja horaria.' },
      { key: 'fecha_restriccion', label: 'Fecha en que se cumple la restricción', type: 'date', required: true, section: 'Restricción', hint: 'Día en que el móvil queda restringido (se usa para bloquear el despacho).' },
      { key: 'ruta_restringida', label: 'Ruta a restringir', type: 'textsel', optionsFrom: { table: 'itinerarios', col: 'nombre' }, section: 'Restricción', showWhen: { field: 'tabla', in: PUESTO_TABLE_KEYS }, requiredWhen: { field: 'tabla', in: PUESTO_TABLE_KEYS }, hint: 'Ruta del viaje castigado (p. ej. 192). Elígela de la lista. Solo para tablas de puesto.' },
      { key: 'modo', label: 'Tipo de restricción', type: 'enum', options: ['VIAJE', 'HORA'], section: 'Restricción', showWhen: { field: 'tabla', in: PUESTO_TABLE_KEYS }, requiredWhen: { field: 'tabla', in: PUESTO_TABLE_KEYS }, hint: 'VIAJE = un viaje puntual (ruta + hora de salida). HORA = una franja. Solo para tablas de puesto.' },
      { key: 'hora_viaje', label: 'Hora del viaje a restringir', type: 'time', section: 'Restricción', showWhen: { field: 'modo', in: ['VIAJE'] }, hint: 'Hora de salida del viaje castigado. Se bloquea ±30 min alrededor.' },
      { key: 'hora_inicial', label: 'Hora inicial (franja)', type: 'time', section: 'Restricción', hint: 'Franja bloqueada: para tipo HORA (puesto) o para Despachos.' },
      { key: 'hora_finalizacion', label: 'Hora finalización (franja)', type: 'time', section: 'Restricción' },
      { key: 'viajes_hora', label: 'Detalle (texto libre)', type: 'text', section: 'Restricción', hint: 'Opcional, p. ej. "se restringe viaje 10:45 ruta 192".' },
      { key: 'estado', label: 'Estado', type: 'enum', options: ['VIGENTE', 'CANCELADA'], required: true, section: 'Restricción' },
      { key: 'observaciones', label: 'Observaciones', type: 'text', section: 'Restricción' },
      { key: 'propietario', label: 'Propietario', type: 'text', section: 'Propietario' },
      { key: 'correo_propietario', label: 'Correo propietario', type: 'text', section: 'Propietario' },
      { key: 'celular_propietario', label: 'Celular propietario', type: 'text', section: 'Propietario' },
      { key: 'despachador_am', label: 'Despachador AM', type: 'text', section: 'Despacho' },
      { key: 'numero_am', label: 'Número AM', type: 'text', section: 'Despacho' },
      { key: 'despachador_pm', label: 'Despachador PM', type: 'text', section: 'Despacho' },
      { key: 'numero_pm', label: 'Número PM', type: 'text', section: 'Despacho' },
      { key: 'key_origen', label: 'KEY (origen)', type: 'text', section: 'Meta', readOnly: true },
      { key: 'usuario', label: 'Usuario', type: 'text', section: 'Meta' },
      { key: 'accion_usuario', label: 'Acción usuario', type: 'text', section: 'Meta' },
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

  // PERFIL SOCIODEMOGRÁFICO (solo admin; RLS perfil_admin, sql/75): 1 fila por persona, conductores y
  // administrativos, activos e inactivos. "+ Nuevo" = empleado nuevo (crea su vinculación en el historial).
  perfilsociodemografico: {
    label: 'Perfil sociodemográfico',
    icon: '👥',
    pk: 'id',
    pkEditable: false,
    noDelete: true, // una persona no se borra: se pasa a INACTIVO (borrarla también borraría su historial)
    select: '*',
    searchCols: ['nombre', 'cedula', 'codigo', 'placa', 'cargo', 'celular'],
    defaultOrder: { col: 'nombre', asc: true },
    filters: [
      { col: 'estado', label: 'Estado', options: PL.estado, chips: true },
      { col: 'tipo', label: 'Tipo', options: PL.tipo, chips: true },
      { col: 'calidad', label: 'Datos', options: ['POR CORREGIR', 'OK'], chips: true },
    ],
    columns: [
      { key: 'cedula', label: 'Cédula', m: true },
      { key: 'nombre', label: 'Nombre', m: true },
      { key: 'tipo', label: 'Tipo', badge: true, m: true },
      { key: 'estado', label: 'Estado', badge: true, m: true },
      { key: 'cargo', label: 'Cargo' },
      { key: 'celular', label: 'Celular' },
      { label: 'Edad', calc: edadPerfil },
      { label: 'Años en APL', calc: antiguedadPerfil },
      { key: 'eps', label: 'EPS' },
      { key: 'calidad', label: 'Datos', badge: true },
    ],
    // Excel: TODA la ficha (cada campo) + edad y antigüedad calculadas
    exportCols: [
      ...PERFIL_FIELDS.map((f) => ({ key: f.key, label: f.label })),
      { label: 'Edad', calc: edadPerfil },
      { label: 'Años en APL', calc: antiguedadPerfil },
      { key: 'calidad', label: 'Calidad de datos' },
      { key: 'habeas_data_aceptado_en', label: 'Autorizó tratamiento de datos' },
      { key: 'actualizado_en', label: 'Actualizado en' },
      { key: 'key_appsheet', label: 'KEY AppSheet' },
      { key: 'adjuntos', label: 'Adjuntos AppSheet (rutas)' },
    ],
    fields: PERFIL_FIELDS,
  },
  // Siniestros de vehículos (sql/79). Vienen de AppSheet -> hoja de Google; la app los trae
  // con el botón "🔄 Traer siniestros". Aquí no se editan: se consultan, filtran y descargan.
  siniestros: {
    label: 'Siniestros',
    icon: '🚨',
    readonly: true,
    fichaDetalle: true,   // no se edita, pero cada fila abre el reporte completo (ojito 👁️)
    pk: 'key',
    pkEditable: false,
    select: '*',
    searchCols: ['placa', 'numero_interno', 'conductor_nombre', 'conductor_codigo', 'conductor_cedula',
      'tercero_nombre', 'tercero_placa', 'ruta', 'afiliado', 'lugar'],
    defaultOrder: { col: 'fecha', asc: false },
    filters: [
      { col: 'gravedad', label: 'Gravedad', options: ['SOLO DAÑOS', 'HERIDO'], chips: true },
      { col: 'responsabilidad', label: 'Responsable', options: ['SI', 'NO', 'POR DEFINIR'], chips: true },
      { col: 'categorizacion', label: 'Categoría', options: ['LEVE', 'MODERADO', 'GRAVE'], chips: true },
      { col: 'estado', label: 'Estado', options: ['ABIERTO', 'CERRADO'], chips: true },
      { col: 'fecha', label: 'Fecha', type: 'daterange' },
    ],
    columns: [
      { key: 'fecha', label: 'Fecha', m: true },
      { key: 'numero_interno', label: 'Móvil', m: true },
      { key: 'placa', label: 'Placa', m: true },
      { key: 'ruta', label: 'Ruta' },
      { key: 'conductor_nombre', label: 'Conductor', m: true },
      { key: 'gravedad', label: 'Gravedad', badge: true, m: true },
      { key: 'responsabilidad', label: 'Responsable', badge: true },
      { key: 'categorizacion', label: 'Categoría', badge: true },
      { key: 'tipo_lesion', label: 'Tipo de lesión' },
      { key: 'estado', label: 'Estado', badge: true },
      { key: 'monto', label: 'Monto' },
    ],
    exportCols: [
      { key: 'key', label: 'KEY' }, { key: 'fecha', label: 'Fecha del siniestro' },
      { key: 'mes_reporte', label: 'Mes del reporte' }, { key: 'numero_interno', label: 'Móvil' },
      { key: 'placa', label: 'Placa' }, { key: 'ruta', label: 'Ruta' }, { key: 'afiliado', label: 'Afiliado' },
      { key: 'conductor_codigo', label: 'Código conductor' }, { key: 'conductor_cedula', label: 'Cédula conductor' },
      { key: 'conductor_nombre', label: 'Conductor' }, { key: 'conductor_celular', label: 'Celular conductor' },
      { key: 'conductor_fecha_ingreso', label: 'Ingreso del conductor' },
      { key: 'gravedad', label: 'Gravedad' }, { key: 'responsabilidad', label: 'Responsabilidad del conductor' },
      { key: 'categorizacion', label: 'Categorización' }, { key: 'tipo_lesion', label: 'Tipo de lesión' },
      { key: 'tipo_conciliacion', label: 'Tipo de conciliación' }, { key: 'monto', label: 'Monto' },
      { key: 'monto_texto', label: 'Monto en texto' }, { key: 'estado', label: 'Estado administrativo' },
      { key: 'estado_inicio', label: 'Estado inicio' }, { key: 'causa', label: 'Causa probable' },
      { key: 'norma', label: 'Norma' }, { key: 'hipotesis', label: 'Hipótesis' }, { key: 'factor', label: 'Factor' },
      { key: 'lugar', label: 'Lugar reportado' }, { key: 'coordenadas', label: 'Coordenadas' },
      { key: 'observaciones', label: 'Observaciones' }, { key: 'danos_empresa', label: 'Daños de la empresa' },
      { key: 'lesiones', label: 'Descripción de lesiones' },
      { key: 'tercero_nombre', label: 'Tercero afectado' }, { key: 'tercero_placa', label: 'Placa del tercero' },
      { key: 'tercero_cedula', label: 'Cédula del tercero' }, { key: 'tercero_telefono', label: 'Teléfono del tercero' },
      { key: 'tercero_correo', label: 'Correo del tercero' }, { key: 'tercero_aseguradora', label: 'Aseguradora del tercero' },
      { key: 'tercero_danos', label: 'Daños del tercero' },
      { key: 'usuario_app', label: 'Reportó (app)' }, { key: 'usuario_logistica', label: 'Usuario logística' },
      { key: 'autorizacion_datos', label: 'Autorización de datos' },
      { key: 'reportado_en', label: 'Reportado el', dt: true },
    ],
    fields: [],
  },
  // Historial de vinculaciones (ingresos / retiros / reingresos) de cada persona. Solo lectura: se
  // alimenta solo al crear, retirar o reintegrar desde el Perfil. `datos_origen` = fila original del CSV.
  perfil_vinculaciones: {
    label: 'Historial de vinculaciones',
    icon: '🗂️',
    readonly: true,
    pk: 'id',
    pkEditable: false,
    select: '*, per:perfilsociodemografico(nombre)',
    searchCols: ['cedula', 'cargo', 'placa', 'key_appsheet'],
    defaultOrder: { col: 'fecha_ingreso', asc: false },
    filters: [
      { col: 'estado', label: 'Estado', options: PL.estado, chips: true },
      { col: 'tipo', label: 'Tipo', options: PL.tipo, chips: true },
      { col: 'tipo_ingreso', label: 'Ingreso', options: PL.tipo_ingreso, chips: true },
    ],
    columns: [
      { key: 'cedula', label: 'Cédula', m: true },
      { path: 'per.nombre', label: 'Nombre', m: true },
      { key: 'tipo', label: 'Tipo', badge: true },
      { key: 'tipo_ingreso', label: 'Ingreso', badge: true, m: true },
      { key: 'fecha_ingreso', label: 'F. ingreso', m: true },
      { key: 'fecha_retiro', label: 'F. retiro', m: true },
      { key: 'estado', label: 'Estado', badge: true },
      { key: 'cargo', label: 'Cargo' },
      { key: 'origen', label: 'Origen' },
    ],
    exportCols: [
      { key: 'cedula', label: 'Cédula' }, { path: 'per.nombre', label: 'Nombre' }, { key: 'tipo', label: 'Tipo' },
      { key: 'tipo_ingreso', label: 'Tipo de ingreso' }, { key: 'fecha_ingreso', label: 'Fecha ingreso' },
      { key: 'fecha_retiro', label: 'Fecha retiro' }, { key: 'estado', label: 'Estado' },
      { key: 'tipo_contrato', label: 'Tipo de contrato' }, { key: 'cargo', label: 'Cargo' }, { key: 'area', label: 'Área' },
      { key: 'salario', label: 'Salario' }, { key: 'centro_costos', label: 'Centro de costos' }, { key: 'placa', label: 'Placa' },
      { key: 'nombre_propietario', label: 'Propietario' }, { key: 'novedad_retiro', label: 'Novedad de retiro' },
      { key: 'origen', label: 'Origen' }, { key: 'key_appsheet', label: 'KEY AppSheet' },
      { key: 'datos_origen', label: 'Fila original completa (CSV)' },
    ],
    fields: [
      { key: 'cedula', label: 'Cédula', type: 'text' },
      { key: 'tipo', label: 'Tipo', type: 'text' },
      { key: 'tipo_ingreso', label: 'Tipo de ingreso', type: 'text' },
      { key: 'fecha_ingreso', label: 'Fecha de ingreso', type: 'date' },
      { key: 'fecha_retiro', label: 'Fecha de retiro', type: 'date' },
      { key: 'estado', label: 'Estado', type: 'text' },
      { key: 'tipo_contrato', label: 'Tipo de contrato', type: 'text' },
      { key: 'cargo', label: 'Cargo', type: 'text' },
      { key: 'area', label: 'Área', type: 'text' },
      { key: 'salario', label: 'Salario', type: 'number' },
      { key: 'centro_costos', label: 'Centro de costos', type: 'text' },
      { key: 'placa', label: 'Placa', type: 'text' },
      { key: 'nombre_propietario', label: 'Propietario', type: 'text' },
      { key: 'novedad_retiro', label: 'Novedad de retiro', type: 'text' },
      { key: 'origen', label: 'Origen', type: 'text' },
      { key: 'key_appsheet', label: 'KEY AppSheet', type: 'text' },
    ],
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
  return { ...TABLES.despachos, fields, columns, filters, defaultOrder, select, label, icon: '🛣️', import: importar, noCreate: true, despachador: false, puesto, routeByPuesto: 'ruta_id', sinSonar: !!opts.sinSonar };
}

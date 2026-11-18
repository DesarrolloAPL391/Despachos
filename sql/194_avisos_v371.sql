-- 194: avisos de obligatoria respuesta (sql/109) por la v371 (17/11/2026), aprobados por el usuario:
--   MONITORES-2026-11: los monitores ahora cancelan viajes y ven la columna 🚨 Vigilante (sql/191-193).
--   CANCELAR-2026-11:  los despachadores ya no cancelan; se lo piden al monitor.
-- Reejecutar no duplica ni borra los acuses (on conflict por codigo).
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'MONITORES-2026-11',
  '🆕',
  'Nuevo para monitores: cancelar viajes y el 🚨 Vigilante en las tablas',
  'Desde hoy, en Despachos y en las tablas de puesto (Laureles y las demás), tienen dos herramientas nuevas.'
  || chr(10) || chr(10)
  || '🚫 CANCELAR VIAJES ahora lo hacen ustedes. Los despachadores ya no pueden cancelar: si un viaje hay que '
  || 'cancelarlo en SONAR, se lo piden a ustedes. El botón 🚫 sale en los viajes despachados de sus rutas, solo los '
  || 'de hoy y con 50 minutos o menos desde el despacho. La fila queda en CANCELADO con su nombre.'
  || chr(10) || chr(10)
  || '🚨 COLUMNA VIGILANTE: en los viajes donde el vigilante de ruta vio algo raro aparece qué pasó: 🔀 un bus pasó '
  || 'a otro, 🔌 estuvo apagado en ruta o 🧭 se salió del recorrido. Cada caso trae una etiqueta:',
  jsonb_build_array(
    '📝 Por revisar: empiecen por estos.',
    '👍 No hace falta verificar: el viaje terminó completo en SONAR y sin llegar tarde.',
    'Probable ruido: casi seguro no es una falta (en la salida, en un sitio de espera o cuando ya había terminado).',
    '🔴 Pasando ahora: está ocurriendo en este momento.',
    'Toquen el caso para ver el mapa, dónde pasó y auditarlo: Confirmado, Justificado o Falsa alarma. Al confirmar, el despacho se marca solo.'
  ),
  'Leí las novedades: sé cancelar viajes y revisar la columna 🚨 Vigilante.',
  'Entendido',
  array['auditor'],
  date '2026-11-17',
  date '2026-11-30',
  'sql/194'
)
on conflict (codigo) do update
  set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      desde = excluded.desde, hasta = excluded.hasta, activo = true;

insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'CANCELAR-2026-11',
  '🚫',
  'Cancelar viajes ahora lo hace el monitor',
  'Desde hoy los despachadores ya no cancelan viajes en SONAR. Si un viaje despachado hay que cancelarlo, '
  || 'avísele al monitor de la ruta: él lo cancela desde la tabla.'
  || chr(10) || chr(10)
  || 'Todo lo demás sigue igual: despachar, marcar si el viaje se realizó y las novedades.',
  jsonb_build_array(
    'El botón 🚫 ya no aparece en la tabla.',
    'Para cancelar un viaje: avísele al monitor.'
  ),
  'Entendí que para cancelar un viaje debo avisarle al monitor.',
  'Entendido',
  array['despachador'],
  date '2026-11-17',
  date '2026-11-30',
  'sql/194'
)
on conflict (codigo) do update
  set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      desde = excluded.desde, hasta = excluded.hasta, activo = true;

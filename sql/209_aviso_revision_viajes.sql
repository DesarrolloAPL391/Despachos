-- 209: aviso de obligatoria respuesta (sql/109) para los monitores (rol auditor) por la v379 (25/11/2026):
--   ✅ Revisión de viajes (sql/206-208): qué deben revisar, cómo se hace y qué no hacer.
-- Pedido del usuario: "muéstrale un modal a los auditores que tienen la sesión de que deben de revisar y cómo hacer y
-- qué no, eso es importante". Les sale al abrir la app (la v379 recarga sola las sesiones abiertas); al confirmarlo,
-- la app abre ✅ Revisión de viajes (AVISO_ACCION en app.js). Se aplica DESPUÉS de que la v379 esté publicada.
-- Reejecutar no duplica ni borra los acuses (on conflict por codigo).
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'REVISION-VIAJES-2026-11',
  '✅',
  'Obligatorio: revisar los viajes que no terminaron bien',
  'Desde hoy cada viaje despachado se revisa. Los que terminaron COMPLETOS en SONAR y sin novedad del vigilante se '
  || 'revisan solos: quedan con ✅ Listo y no hay que tocarlos. Los demás quedan en 📝 POR REVISAR y los tienen que '
  || 'responder ustedes: los INCOMPLETOS o CANCELADOS en SONAR, los que SONAR no cerró y los que marcó el 🚨 vigilante.'
  || chr(10) || chr(10)
  || 'CÓMO SE HACE:' || chr(10)
  || '1. En Despachos o en su tabla de puesto, arriba de la tabla toquen «📝 Por revisar».' || chr(10)
  || '2. En la columna ✅ Revisión toquen el viaje: ahí ven lo que dijo SONAR (qué puntos marcó y cuáles no) y lo que '
  || 'vio el vigilante. Verifiquen con 🔎 Eventos del bus y el mapa.' || chr(10)
  || '3. Elijan qué pasó, digan si es falta del conductor (🔴 Sí · 🟦 Pasó, pero se justifica · ⚪ No pasó) y escriban en '
  || 'la nota qué verificaron y con quién hablaron. Guarden.' || chr(10)
  || 'La misma respuesta cierra los casos del vigilante de ese viaje. También pueden revisar en 🚌 Despachos → '
  || '✅ Revisión de viajes, con «Guardar y seguir».'
  || chr(10) || chr(10)
  || 'QUÉ NO HACER:',
  jsonb_build_array(
    'No dejen viajes acumulados: revisen todos los días lo del día anterior y lo de hoy que ya terminó. Los días atrasados salen arriba en «Días con viajes por revisar».',
    'No marquen «No pasó» sin verificar en SONAR: miren los eventos del bus y el mapa.',
    'No escriban notas de relleno («ok», «revisado», «listo»): digan qué pasó y qué verificaron.',
    'Lo que guardan queda a su nombre y no se puede cambiar: si se equivocan, avísenle a administración.'
  ),
  'Entendí: debo revisar todos los días los viajes «Por revisar» de mis rutas, sé cómo hacerlo y qué no hacer.',
  'Entendido, ir a revisar',
  array['auditor'],
  date '2026-11-25',
  date '2026-12-09',
  'sql/209'
)
on conflict (codigo) do update
  set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo, puntos = excluded.puntos,
      confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
      desde = excluded.desde, hasta = excluded.hasta, activo = true;

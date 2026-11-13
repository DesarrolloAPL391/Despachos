-- 188: ARRANQUE DEL QR DEL BUS OBLIGATORIO DEL 3.er VIAJE EN ADELANTE (12/11/2026), después de publicar la v368 (sql/185-187).
--
-- Decisiones del usuario (12/11): prenderlo "ya mismo" y poner un aviso de obligatoria respuesta a los despachadores.
-- El aviso del 2.º viaje (QR-2DO-VIAJE-2026-11) dice "Del 3.er viaje en adelante: normal, sin QR", que ya no es cierto:
-- se retira y el nuevo explica los tres casos (1.er, 2.º y 3.er viaje en adelante).
-- Para volver al QR opcional del 3.er viaje: update public.despacho_qr_config set rapido_desde = null, actualizado_en = now() where id = 1;

-- 1) la regla: del 3.er viaje en adelante, QR del bus o motivo para poder despachar
update public.despacho_qr_config
   set rapido_desde = now(), actualizado_en = now(), actualizado_por = 'sql/188'
 where id = 1;

-- 2) el aviso de obligatoria respuesta (sql/109) para los despachadores
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'QR-3ER-VIAJE-2026-11',
  '⚡',
  'Desde ahora: del 3.er viaje en adelante, el QR del bus',
  'Desde ahora, del 3.er viaje del día en adelante cada bus se despacha leyendo SOLO el QR del bus. '
  || 'El conductor lo pone la app: es el mismo del 2.º viaje (el del carnet o el que se eligió de la lista). '
  || 'No hay que volver a leer el carnet.',
  jsonb_build_array(
    '1.er viaje del bus en el día: despachas normal, sin QR.',
    '2.º viaje: como hasta ahora: QR del bus, foto del bus y QR del carnet del conductor.',
    '3.er viaje en adelante: toca "📷 Leer el QR del bus". La app trae sola el conductor del 2.º viaje.',
    'Si el conductor cambió, elígelo en la lista. Queda marcado como cambio de conductor para control.',
    'Si el QR del bus no se puede leer, toca "No se puede leer el QR del bus" y elige el motivo. Se despacha igual y queda para revisión de control.',
    'Sin el QR del bus o sin el motivo no deja despachar.',
    'Vale en ✈️ Despachar de las tablas y en Nuevo despacho.'
  ),
  'Entendí: del 3.er viaje en adelante leo el QR del bus y, si no se puede leer, elijo el motivo.',
  'Entendido',
  array['despachador'],
  date '2026-11-12',
  date '2026-11-26',
  'sql/188'
)
on conflict (codigo) do update set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo,
  puntos = excluded.puntos, confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
  desde = excluded.desde, hasta = excluded.hasta, activo = true;

-- 3) se retira el aviso del 2.º viaje: decía que del 3.er viaje en adelante era sin QR
update public.avisos set activo = false where codigo = 'QR-2DO-VIAJE-2026-11';

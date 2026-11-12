-- 183: ARRANQUE DE LA REGLA DEL 2.º VIAJE (12/11/2026), después de publicar la v366 (sql/182).
--
-- Decisiones del usuario (12/11): ponerlo en marcha ya, con aviso nuevo a los despachadores, y retirar el aviso
-- anterior (QR-DESPACHO-2026-11), que dice "en cada despacho".
-- Para volver al QR en todos los viajes: update public.despacho_qr_config set solo_viaje = null, actualizado_en = now() where id = 1;

-- 1) la regla: QR + foto + carnet solo en el 2.º viaje del día de cada carro
update public.despacho_qr_config
   set solo_viaje = 2, solo_viaje_desde = now(), actualizado_en = now(), actualizado_por = 'sql/183'
 where id = 1;

-- 2) el aviso de obligatoria respuesta (sql/109) para los despachadores
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'QR-2DO-VIAJE-2026-11',
  '🚌',
  'Desde hoy: el QR solo en el 2.º viaje de cada bus',
  'Desde hoy, jueves 12 de noviembre, el QR del bus, la foto del bus y el carnet del conductor se piden SOLO en el '
  || 'segundo viaje del día de cada bus. Los demás viajes se despachan como antes.',
  jsonb_build_array(
    '1.er viaje del bus en el día: despachas normal. Eliges el bus de la lista y el conductor sale del Resumen.',
    '2.º viaje: te sale el recuadro 📷 como hasta ahora: QR del bus, foto del bus y QR del carnet del conductor.',
    'Del 3.er viaje en adelante: normal, sin QR.',
    'No tienes que llevar la cuenta: al abrir ✈️ (o al elegir el bus en Nuevo despacho) la app revisa qué viaje lleva ese bus hoy, en todas las tablas, y te dice si toca QR.',
    'Si en el 2.º viaje el sticker o el carnet no se pueden leer, toca "No se puede leer" y elige el motivo, como hasta ahora. Queda para revisión de control.',
    'Ya no se puede poner "SI" editando la fila: usa siempre ✈️ Despachar.'
  ),
  'Entendí: el QR, la foto y el carnet van solo en el 2.º viaje del día de cada bus.',
  'Entendido',
  array['despachador'],
  date '2026-11-12',
  date '2026-11-26',
  'sql/183'
)
on conflict (codigo) do update set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo,
  puntos = excluded.puntos, confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
  desde = excluded.desde, hasta = excluded.hasta, activo = true;

-- 3) se retira el aviso anterior ("en cada despacho"): ya no aplica
update public.avisos set activo = false where codigo = 'QR-DESPACHO-2026-11';

-- 180: ARRANQUE DEL DESPACHO CON QR + FOTO + CARNET (11/11/2026).
--
-- Pedido: "publicar, pero poner un tiempo para que se despliegue: a las 10:30 arranca el despacho por
-- código QR, y explicar dentro de ese tiempo de gracia qué debe hacer el despachador".
-- Decisiones del usuario (11/11): arranca HOY 11/11 a las 10:30; durante la gracia el despachador ve un
-- aviso de obligatoria respuesta (sql/109) y el recuadro del QR como PRÁCTICA (no bloquea); el carnet
-- del conductor arranca obligatorio al mismo tiempo.
--
-- La hora vive en la BASE, no en el código: se puede correr o apagar sin volver a publicar.
--   * obligatorio_desde = null  → apagado (la app no pide nada)
--   * antes de esa hora         → práctica (el recuadro sale, no bloquea)
--   * desde esa hora            → obligatorio
-- La app compara con la hora del SERVIDOR (no la del celular, que se puede cambiar).
--
-- Para correr la hora:   update public.despacho_qr_config set obligatorio_desde = '2026-11-12 10:30-05', actualizado_en = now() where id = 1;
-- Para apagarlo ya:      update public.despacho_qr_config set obligatorio_desde = null, actualizado_en = now() where id = 1;
-- Para quitar el carnet: update public.despacho_qr_config set carnet = false, actualizado_en = now() where id = 1;
-- (la app lo toma en máximo 5 minutos, o al recargar)

create table if not exists public.despacho_qr_config (
  id                smallint primary key default 1 check (id = 1),
  obligatorio_desde timestamptz,
  carnet            boolean not null default true,
  actualizado_en    timestamptz not null default now(),
  actualizado_por   text
);
alter table public.despacho_qr_config enable row level security;
revoke all on public.despacho_qr_config from anon, authenticated;
drop policy if exists sin_vigilante on public.despacho_qr_config;
create policy sin_vigilante on public.despacho_qr_config as restrictive for all to authenticated
  using (not (select public.es_vigilante())) with check (not (select public.es_vigilante()));

insert into public.despacho_qr_config (id, obligatorio_desde, carnet, actualizado_por)
values (1, '2026-11-11 10:30:00-05', true, 'sql/180')
on conflict (id) do update set obligatorio_desde = excluded.obligatorio_desde, carnet = excluded.carnet,
  actualizado_en = now(), actualizado_por = excluded.actualizado_por;

-- Lo que la app necesita saber (cualquier cuenta con sesión): desde cuándo, si va el carnet, y la hora del servidor
create or replace function public.despacho_qr_reglas()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select coalesce(
    (select jsonb_build_object('ok', true, 'desde', c.obligatorio_desde, 'carnet', c.carnet, 'ahora', now())
       from public.despacho_qr_config c where c.id = 1),
    jsonb_build_object('ok', true, 'desde', null, 'carnet', true, 'ahora', now()));
$$;
revoke all on function public.despacho_qr_reglas() from public, anon;
grant execute on function public.despacho_qr_reglas() to authenticated;

-- El aviso de obligatoria respuesta para los despachadores (sql/109): no se cierra sin confirmar y
-- administración ve quién falta por leerlo.
insert into public.avisos (codigo, icono, titulo, cuerpo, puntos, confirmacion, boton, roles, desde, hasta, creado_por)
values (
  'QR-DESPACHO-2026-11',
  '📷',
  'Desde hoy a las 10:30: QR del bus, foto y carnet en cada despacho',
  'A partir de hoy, miércoles 11 de noviembre, a las 10:30 a. m., para despachar cualquier viaje (✈️ en la tabla, '
  || 'Nuevo despacho o desde el mapa) la app te pide tres cosas, en una sola pasada de la cámara: el QR del bus, '
  || 'una foto del bus y el QR del carnet del conductor.' || E'\n\n'
  || 'Antes de las 10:30 puedes practicar: el recuadro ya te sale en cada despacho y no te bloquea. '
  || 'Desde las 10:30 no se puede despachar sin hacerlo.',
  jsonb_build_array(
    '1. Toca "📷 Empezar" y apunta al QR (sticker) del bus. En una fila de tabla tiene que ser el bus de esa fila: si sale otro bus, primero edita la fila y cambia el móvil.',
    '2. 📸 Aléjate y toma la foto del bus completo, con el número a la vista. La foto queda guardada con la hora y la ubicación; no se pueden usar fotos guardadas en el celular.',
    '3. 🪪 Apunta al QR del carnet del conductor. El conductor del despacho queda el del carnet.',
    'Si el sticker o el carnet no se puede leer, toca "No se puede leer" y elige el motivo. La foto del bus igual es obligatoria. Queda marcado para revisión.',
    'Si el viaje NO se realizó, no se pide nada.',
    'Ya no se puede poner "SI" editando la fila: usa siempre ✈️ Despachar.',
    'Cuando el celular pida permiso de cámara y de ubicación, acéptalo.'
  ),
  'Entendí: desde las 10:30 cada despacho lleva QR del bus, foto del bus y carnet del conductor.',
  'Entendido',
  array['despachador'],
  date '2026-11-11',
  date '2026-11-25',
  'sql/180'
)
on conflict (codigo) do update set icono = excluded.icono, titulo = excluded.titulo, cuerpo = excluded.cuerpo,
  puntos = excluded.puntos, confirmacion = excluded.confirmacion, boton = excluded.boton, roles = excluded.roles,
  desde = excluded.desde, hasta = excluded.hasta, activo = true;

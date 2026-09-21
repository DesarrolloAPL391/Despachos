-- ============================================================================================
-- 99) novedades_estado() — el estado de PUESTA EN MARCHA de los módulos nuevos
--
-- QUÉ RESUELVE: se publicaron cuatro módulos (PQRSF, certificado laboral, permisos y el Control
-- Av. Oriental) y varios no funcionan completos hasta que alguien de administración haga algo
-- por fuera del código: subir las firmas escaneadas, poner el auxilio de transporte del año,
-- registrar las cuentas de Gerencia que aprueban, nombrar el puesto de la Oriental. Esa lista
-- vivía en un chat. Aquí se calcula, y la app la muestra en ✨ Novedades marcando lo que ya
-- quedó y lo que falta, con el botón que lleva a hacerlo.
--
-- DEVUELVE SOLO CONTEOS Y BANDERAS: ni un nombre, ni una cédula, ni un correo, ni un valor.
-- Sirve para saber SI falta algo, no para enterarse de nada de nadie.
--
-- Se aplica sobre sql/92 (bandeja PQRSF), sql/93+94 (certificado), sql/97 (permisos) y sql/98
-- (Control Av. Oriental).
-- ============================================================================================

create or replace function public.novedades_estado()
returns jsonb
language sql
stable
security definer
set search_path to 'public'
as $$
  with c as (select * from public.certificado_config where id = 1),
       g as (select * from public.certificado_firmantes where rol = 'GERENTE' and vigente_hasta is null),
       h as (select * from public.certificado_firmantes where rol = 'GESTION_HUMANA' and vigente_hasta is null),
       hoy as (select (now() at time zone 'America/Bogota')::date as d)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      -- ✍️ Certificado laboral: qué falta para que el documento salga completo -------------------
      'cert', jsonb_build_object(
        'titular1',  coalesce((select nombre from g), (select firmante1_nombre from c), '') <> '',
        'titular2',  coalesce((select nombre from h), (select firmante2_nombre from c), '') <> '',
        'firma1',    coalesce((select firma from g), (select firmante1_firma from c), '') <> '',
        'firma2',    coalesce((select firma from h), (select firmante2_firma from c), '') <> '',
        'telefono',  coalesce((select telefono from c), '') <> '',
        'smmlv',     coalesce((select smmlv from c), 0) > 0,
        'auxilio',   coalesce((select auxilio_transporte from c), 0) > 0,
        'anio',      (select anio_valores from c),
        'anio_hoy',  extract(year from (select d from hoy))::int,
        'expedidos', (select count(1) from public.certificados_expedidos)),
      -- 📝 Permisos y licencias: quién aprueba y quién puede radicar -----------------------------
      'permisos', jsonb_build_object(
        'gerencia_n',  (select count(1) from public.permiso_gerencia),
        'total',       (select count(1) from public.permisos),
        'pendientes',  (select count(1) from public.permisos where estado in ('PENDIENTE', 'EN TRAMITE')),
        -- sin fecha de nacimiento = no puede identificarse en el link público (no puede radicar)
        'sin_fecha_nac', (select count(1) from public.perfilsociodemografico
                           where coalesce(estado, '') = 'ACTIVO' and fecha_nacimiento is null)),
      -- 📣 PQRSF: las dos listas de la bandeja ---------------------------------------------------
      'pqrsf', jsonb_build_object(
        'sin_responder', (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is null),
        'falta_cerrar',  (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                             and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      -- 🛂 Control Av. Oriental: el puesto tiene que llamarse con "oriental" ----------------------
      -- (esDespachadorOriental mira el nombre del puesto del horario del día; si no dice
      --  "oriental", la cuenta del controlador no ve el tablero)
      'oriental', jsonb_build_object(
        'puestos',   (select count(1) from public.puestos
                       where nombre ilike '%oriental%' and coalesce(activo, true)),
        'turno_hoy', (select count(1) from public.horarios
                       where fecha = (select d from hoy) and observacion ilike '%oriental%'),
        'checkins',  (select count(1) from public.oriental_checkin
                       where fecha = (select d from hoy))))
  end;
$$;

comment on function public.novedades_estado() is
  'Estado de puesta en marcha de los modulos nuevos (que falta configurar). Solo conteos y banderas, sin datos de personas.';

revoke all on function public.novedades_estado() from public, anon;
grant execute on function public.novedades_estado() to authenticated;

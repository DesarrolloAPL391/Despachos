-- ============================================================================================
-- 101) novedades_estado() + Intervenciones
--
-- Redefine la función de sql/99 para que ✨ Novedades también diga lo que falta del módulo de
-- intervenciones (sql/100): si ya se cargó el histórico y si hay citas que nadie cerró.
-- Es la misma función, con un bloque más. Se aplica DESPUÉS de sql/99 y sql/100.
-- Sigue devolviendo solo conteos y banderas: ni un nombre, ni una cédula, ni un valor.
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
      -- ✍️ Certificado laboral -------------------------------------------------------------------
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
      -- 📝 Permisos y licencias -------------------------------------------------------------------
      'permisos', jsonb_build_object(
        'gerencia_n',  (select count(1) from public.permiso_gerencia),
        'total',       (select count(1) from public.permisos),
        'pendientes',  (select count(1) from public.permisos where estado in ('PENDIENTE', 'EN TRAMITE')),
        'sin_fecha_nac', (select count(1) from public.perfilsociodemografico
                           where coalesce(estado, '') = 'ACTIVO' and fecha_nacimiento is null)),
      -- 📣 PQRSF ----------------------------------------------------------------------------------
      'pqrsf', jsonb_build_object(
        'sin_responder', (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is null),
        'falta_cerrar',  (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                             and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      -- 🛂 Control Av. Oriental --------------------------------------------------------------------
      'oriental', jsonb_build_object(
        'puestos',   (select count(1) from public.puestos
                       where nombre ilike '%oriental%' and coalesce(activo, true)),
        'turno_hoy', (select count(1) from public.horarios
                       where fecha = (select d from hoy) and observacion ilike '%oriental%'),
        'checkins',  (select count(1) from public.oriental_checkin
                       where fecha = (select d from hoy))),
      -- 🛠️ Intervenciones (sql/100) ----------------------------------------------------------------
      'interv', jsonb_build_object(
        'total',      (select count(1) from public.intervenciones),
        'historico',  (select count(1) from public.intervenciones where origen = 'CARGA'),
        'por_cerrar', (select count(1) from public.intervenciones
                        where estado = 'PROGRAMADA' and fecha < (select d from hoy)),
        'revisar',    (select count(1) from public.intervenciones where revisar)))
  end;
$$;

comment on function public.novedades_estado() is
  'Estado de puesta en marcha de los modulos nuevos (que falta configurar). Solo conteos y banderas, sin datos de personas.';

revoke all on function public.novedades_estado() from public, anon;
grant execute on function public.novedades_estado() to authenticated;

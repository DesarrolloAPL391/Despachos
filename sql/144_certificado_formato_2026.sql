-- ============================================================================================
-- 144 · CERTIFICADO LABORAL — formato 2026 (reemplaza la redacción de sql/93)
--
-- Talento Humano entregó el formato nuevo (membrete con dirección/correo/web/WhatsApp, fecha
-- arriba, "El suscrito <cargo> … CERTIFICA QUE", el periodo en dos líneas y una sola firma).
-- La estructura del documento vive en la app; aquí solo entran los datos que NO pueden estar
-- en el código, porque el repositorio es público: dirección, correos, teléfonos y quién firma.
--
-- Nada se borra: `smmlv` y `auxilio_transporte` siguen en la tabla (son historia del año), pero
-- el formato nuevo no los imprime, así que dejan de pedirse como "falta configurar".
--
-- Se aplica sobre sql/93 (certificado) y sql/94 (firmantes).
-- ============================================================================================

-- 1) Lo que el membrete y el pie necesitan ------------------------------------------------------
alter table public.certificado_config
  add column if not exists empresa_direccion text,   -- va bajo el NIT, en el membrete
  add column if not exists empresa_correo    text,   -- correo general de la empresa
  add column if not exists empresa_web       text,
  add column if not exists empresa_whatsapp  text,
  add column if not exists suscrito_cargo    text,   -- "El suscrito <esto> de la compañía…"
  add column if not exists telefono_ext      text,   -- extensiones del teléfono del pie
  add column if not exists correo_contacto   text,   -- a quién escribirle para verificar
  -- Cuál de los dos firmantes de sql/94 firma el certificado. El formato nuevo lo firma
  -- Talento Humano, no la Gerencia; si eso cambia, se cambia aquí y no en el código.
  add column if not exists firma_rol         text not null default 'GESTION_HUMANA';

do $$ begin
  alter table public.certificado_config
    add constraint certificado_config_firma_rol_chk
    check (firma_rol in ('GERENTE', 'GESTION_HUMANA'));
exception when duplicate_object then null; end $$;

comment on column public.certificado_config.suscrito_cargo is
  'Cargo de quien suscribe, tal como aparece en el encabezado del certificado.';
comment on column public.certificado_config.smmlv is
  'Salario minimo del ano. El formato 2026 no lo imprime; se conserva como dato del ano.';

-- 2) Leer: agrega los campos nuevos y ajusta qué se considera "falta" ---------------------------
-- Parte de la versión de sql/94 (los firmantes salen de `certificado_firmantes`, con su
-- vigencia, y solo caen a `certificado_config` si todavía no hay ninguno cargado).
-- La lista `falta` es la que la app muestra como aviso: ahora pide lo que el formato nuevo
-- necesita de verdad para salir completo, y ya no el salario mínimo ni el auxilio.
create or replace function public.certificado_config_leer()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  with c as (select * from public.certificado_config where id = 1),
       g as (select * from public.certificado_firmantes where rol = 'GERENTE' and vigente_hasta is null),
       h as (select * from public.certificado_firmantes where rol = 'GESTION_HUMANA' and vigente_hasta is null)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else (select jsonb_build_object(
      'ok', true,
      'empresa_nombre', c.empresa_nombre, 'empresa_nit', c.empresa_nit,
      'empresa_direccion', c.empresa_direccion, 'empresa_correo', c.empresa_correo,
      'empresa_web', c.empresa_web, 'empresa_whatsapp', c.empresa_whatsapp,
      'ciudad', c.ciudad, 'telefono', c.telefono, 'telefono_ext', c.telefono_ext,
      'correo_contacto', c.correo_contacto, 'suscrito_cargo', c.suscrito_cargo,
      'firma_rol', c.firma_rol,
      'firmante1_nombre', coalesce((select nombre from g), c.firmante1_nombre),
      'firmante1_cargo',  coalesce((select cargo  from g), c.firmante1_cargo),
      'firmante1_firma',  coalesce((select firma  from g), c.firmante1_firma),
      'firmante1_alto',   coalesce((select firma_alto from g), 58),
      'firmante1_dx',     coalesce((select firma_dx from g), 0),
      'firmante1_dy',     coalesce((select firma_dy from g), 0),
      'firmante2_nombre', coalesce((select nombre from h), c.firmante2_nombre),
      'firmante2_cargo',  coalesce((select cargo  from h), c.firmante2_cargo),
      'firmante2_firma',  coalesce((select firma  from h), c.firmante2_firma),
      'firmante2_alto',   coalesce((select firma_alto from h), 58),
      'firmante2_dx',     coalesce((select firma_dx from h), 0),
      'firmante2_dy',     coalesce((select firma_dy from h), 0),
      'smmlv', c.smmlv, 'auxilio_transporte', c.auxilio_transporte, 'anio_valores', c.anio_valores,
      'nota_pie', c.nota_pie,
      -- Solo se reclama el firmante que de verdad va a salir impreso.
      'falta', (select coalesce(jsonb_agg(f), '[]'::jsonb) from (
                  select 'firmante1_nombre' as f
                   where c.firma_rol = 'GERENTE'
                     and coalesce((select nombre from g), c.firmante1_nombre, '') = ''
                  union all select 'firmante2_nombre'
                   where c.firma_rol = 'GESTION_HUMANA'
                     and coalesce((select nombre from h), c.firmante2_nombre, '') = ''
                  union all select 'suscrito_cargo'    where coalesce(c.suscrito_cargo, '') = ''
                  union all select 'telefono'          where coalesce(c.telefono, '') = ''
                  union all select 'correo_contacto'   where coalesce(c.correo_contacto, '') = ''
                  union all select 'empresa_direccion' where coalesce(c.empresa_direccion, '') = ''
                ) s))
      from c)
  end;
$$;
revoke all on function public.certificado_config_leer() from public, anon;
grant execute on function public.certificado_config_leer() to authenticated;

-- 3) Guardar: los campos nuevos, con la misma regla de siempre ----------------------------------
-- `nullif(trim(...), '')` deja intacto lo que no venga en el payload: la pantalla manda solo lo
-- que se escribió, y un campo que no se tocó no se borra por accidente.
create or replace function public.certificado_config_guardar(p jsonb)
returns jsonb
language plpgsql security definer set search_path to 'public'
as $$
declare v_yo text := lower(coalesce(auth.email(), ''));
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'Solo administracion cambia los datos del certificado.');
  end if;
  update public.certificado_config set
    ciudad             = coalesce(nullif(trim(p->>'ciudad'), ''), ciudad),
    telefono           = coalesce(nullif(trim(p->>'telefono'), ''), telefono),
    telefono_ext       = coalesce(nullif(trim(p->>'telefono_ext'), ''), telefono_ext),
    correo_contacto    = coalesce(nullif(trim(p->>'correo_contacto'), ''), correo_contacto),
    empresa_direccion  = coalesce(nullif(trim(p->>'empresa_direccion'), ''), empresa_direccion),
    empresa_correo     = coalesce(nullif(trim(p->>'empresa_correo'), ''), empresa_correo),
    empresa_web        = coalesce(nullif(trim(p->>'empresa_web'), ''), empresa_web),
    empresa_whatsapp   = coalesce(nullif(trim(p->>'empresa_whatsapp'), ''), empresa_whatsapp),
    suscrito_cargo     = coalesce(nullif(trim(p->>'suscrito_cargo'), ''), suscrito_cargo),
    firma_rol          = coalesce(nullif(trim(p->>'firma_rol'), ''), firma_rol),
    firmante1_nombre   = coalesce(nullif(trim(p->>'firmante1_nombre'), ''), firmante1_nombre),
    firmante1_cargo    = coalesce(nullif(trim(p->>'firmante1_cargo'), ''), firmante1_cargo),
    firmante1_firma    = coalesce(nullif(trim(p->>'firmante1_firma'), ''), firmante1_firma),
    firmante2_nombre   = coalesce(nullif(trim(p->>'firmante2_nombre'), ''), firmante2_nombre),
    firmante2_cargo    = coalesce(nullif(trim(p->>'firmante2_cargo'), ''), firmante2_cargo),
    firmante2_firma    = coalesce(nullif(trim(p->>'firmante2_firma'), ''), firmante2_firma),
    smmlv              = coalesce((p->>'smmlv')::numeric, smmlv),
    auxilio_transporte = coalesce((p->>'auxilio_transporte')::numeric, auxilio_transporte),
    anio_valores       = coalesce((p->>'anio_valores')::int, anio_valores),
    nota_pie           = coalesce(p->>'nota_pie', nota_pie),
    actualizado_en     = now(), actualizado_por = v_yo
  where id = 1;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.certificado_config_guardar(jsonb) from public, anon;
grant execute on function public.certificado_config_guardar(jsonb) to authenticated;

-- 4) Los valores reales NO van aquí -------------------------------------------------------------
-- Dirección, correos, teléfonos y el nombre de quien firma se cargan una sola vez desde la
-- base (o desde la pantalla ✍️ Firmas del certificado), nunca en un archivo del repositorio:
--
--   update certificado_config set
--     empresa_direccion = '...', empresa_correo = '...', empresa_web = '...',
--     empresa_whatsapp = '...', suscrito_cargo = '...', telefono = '...',
--     telefono_ext = '...', correo_contacto = '...',
--     firmante1_nombre = '...', firmante1_cargo = '...'
--   where id = 1;

-- 5) El tablero de novedades deja de pedir lo que el formato nuevo no imprime ----------------
-- Copia de la funcion de sql/102 cambiando UNICAMENTE el bloque 'cert': ya no reclama el
-- salario minimo ni el auxilio (no salen en la carta) y si reclama el membrete, el cargo de
-- quien suscribe y el correo de verificacion, que son los que la dejan incompleta.
create or replace function public.novedades_estado()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  with c as (select * from public.certificado_config where id = 1),
       g as (select * from public.certificado_firmantes where rol = 'GERENTE' and vigente_hasta is null),
       h as (select * from public.certificado_firmantes where rol = 'GESTION_HUMANA' and vigente_hasta is null),
       hoy as (select (now() at time zone 'America/Bogota')::date as d)
  select case when not public.es_talento_humano() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'cert', jsonb_build_object(
        'firma_rol', (select firma_rol from c),
        'titular1',  coalesce((select nombre from g), (select firmante1_nombre from c), '') <> '',
        'titular2',  coalesce((select nombre from h), (select firmante2_nombre from c), '') <> '',
        'firma1',    coalesce((select firma from g), (select firmante1_firma from c), '') <> '',
        'firma2',    coalesce((select firma from h), (select firmante2_firma from c), '') <> '',
        'suscrito',  coalesce((select suscrito_cargo from c), '') <> '',
        'telefono',  coalesce((select telefono from c), '') <> '',
        'correo',    coalesce((select correo_contacto from c), '') <> '',
        'membrete',  coalesce((select empresa_direccion from c), '') <> ''
                       and coalesce((select empresa_correo from c), '') <> '',
        'expedidos', (select count(1) from public.certificados_expedidos)),
      'permisos', jsonb_build_object(
        'gerencia_n',  (select count(1) from public.permiso_gerencia),
        'total',       (select count(1) from public.permisos),
        'pendientes',  (select count(1) from public.permisos where estado in ('PENDIENTE', 'EN TRAMITE')),
        'sin_fecha_nac', (select count(1) from public.perfilsociodemografico
                           where coalesce(estado, '') = 'ACTIVO' and fecha_nacimiento is null)),
      'pqrsf', jsonb_build_object(
        'sin_responder', (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is null),
        'falta_cerrar',  (select count(1) from public.pqrsf p
                           where coalesce(p.fecha_respuesta, p.respondido_el) is not null
                             and p.estado = 'ABIERTA' and coalesce(p.estado_app, '') <> 'CERRADA')),
      'oriental', jsonb_build_object(
        'puestos',   (select count(1) from public.puestos
                       where nombre ilike '%oriental%' and coalesce(activo, true)),
        'turno_hoy', (select count(1) from public.horarios
                       where fecha = (select d from hoy) and observacion ilike '%oriental%'),
        'checkins',  (select count(1) from public.oriental_checkin
                       where fecha = (select d from hoy))),
      'interv', jsonb_build_object(
        'total',      (select count(1) from public.intervenciones),
        'historico',  (select count(1) from public.intervenciones where origen = 'CARGA'),
        'por_cerrar', (select count(1) from public.intervenciones
                        where estado = 'PROGRAMADA' and fecha < (select d from hoy)),
        'revisar',    (select count(1) from public.intervenciones where revisar)),
      'disc', jsonb_build_object(
        'total',      (select count(1) from public.disciplinarios),
        'enlace',     coalesce((select url from public.disciplinarios_fuente where id = 1), '') <> '',
        'ultima_carga', (select ultima_carga from public.disciplinarios_fuente where id = 1),
        'abiertos',   (select count(1) from public.disciplinarios
                        where etapa in ('POR CITAR', 'CITADO', 'POR DECIDIR', 'REPROGRAMAR')),
        'viejos',     (select count(1) from public.disciplinarios
                        where etapa in ('POR CITAR', 'CITADO', 'POR DECIDIR', 'REPROGRAMAR')
                          and fecha_suceso < (select d from hoy) - 60)))
  end;
$$;
revoke all on function public.novedades_estado() from public, anon;
grant execute on function public.novedades_estado() to authenticated;

-- 157: Seguridad vial maneja su módulo completo: siniestros, conducción y preoperacional.
--
-- sql/156 dejó a seguridad vial con los mismos permisos que operaciones. Además de eso, el área
-- se encarga de TODO lo que es riesgo en la vía, y eso estaba solo para el admin, Gestión Humana
-- y los auditores:
--   * 🚨 Siniestros: la tabla, traerlos de la hoja de AppSheet y sus estadísticas.
--   * 🚦🚪 Conducción (eventos_bus): excesos de velocidad y puertas abiertas, el resumen, las
--     series y el mapa de riesgo. El umbral y "traer un día a mano" siguen siendo del admin.
--   * 🧰 Preoperacional: la tabla con la ficha, marcar ATENDIDO la novedad del taller, el
--     control del día (preop_panel) y el envío del enlace a los conductores.
--
-- Cuentas de seguridad vial = rol despachador cuyo correo contiene 'seguridadvial' (las mismas
-- de sql/156). El patrón vive en _correo_seguridad_vial; en la app es CORREO_SEGURIDAD_VIAL
-- (app.js): cambiar los dos juntos. Operaciones NO recibe este módulo: es lo que separa las áreas.
--
-- El perfil sociodemográfico NO se abre: trae salario, salud y familia. Las estadísticas de
-- siniestros y el envío del enlace solo necesitan saber quién es el conductor, si sigue activo y
-- su celular; para eso está vial_conductores(), que devuelve SOLO esas columnas y SOLO conductores.
--
-- Las funciones que se recrean abajo son copia exacta de las que hay en la base (04/11/2026);
-- solo cambia la condición del permiso.

create or replace function public._correo_seguridad_vial(p_email text)
returns boolean
language sql immutable
set search_path to 'public'
as $function$ select lower(coalesce(p_email, '')) ~ 'seguridadvial' $function$;
revoke all on function public._correo_seguridad_vial(text) from public, anon, authenticated;

-- Admin o cuenta de seguridad vial. La usan políticas de tablas que también evalúa anon (sin
-- cuenta da falso), por eso lleva el mismo grant que es_operaciones().
create or replace function public.es_seguridad_vial()
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select public.es_admin()
      or ( public.es_despachador()
           and public._correo_seguridad_vial(auth.email()) );
$function$;
revoke all on function public.es_seguridad_vial() from public;
grant execute on function public.es_seguridad_vial() to anon, authenticated;

-- ---------- Tablas ----------
-- Siniestros: seguridad vial LEE (la carga va por siniestros_cargar, que es security definer).
drop policy if exists siniestros_vial_sel on public.siniestros;
create policy siniestros_vial_sel on public.siniestros for select to authenticated
  using ((select public.es_seguridad_vial()));

-- Conducción: lee los eventos y la configuración (el umbral lo sigue cambiando solo el admin).
alter policy eventos_bus_vial on public.eventos_bus
  using ((select public.es_talento_humano()) or (select public.es_auditor()) or (select public.es_seguridad_vial()));
alter policy eventos_bus_config_admin on public.eventos_bus_config
  using ((select public.es_admin()) or (select public.es_auditor()) or (select public.es_seguridad_vial()));

-- Preoperacional: lee todo y puede ACTUALIZAR (marcar atendida la novedad); no crea ni borra.
alter policy preop_sel on public.preoperacionales using ((select public.es_seguridad_vial()));
alter policy preop_items_sel on public.preoperacional_items using ((select public.es_seguridad_vial()));
alter policy preop_preg_sel on public.preoperacional_preguntas using ((select public.es_seguridad_vial()));
drop policy if exists preop_vial_upd on public.preoperacionales;
create policy preop_vial_upd on public.preoperacionales for update to authenticated
  using ((select public.es_seguridad_vial())) with check ((select public.es_seguridad_vial()));

-- ---------- Conductores para seguridad vial (sin abrir el perfil) ----------
create or replace function public.vial_conductores()
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  select case when not (public.es_talento_humano() or public.es_seguridad_vial()) then '[]'::jsonb
    else coalesce((
      select jsonb_agg(jsonb_build_object(
               'cedula', p.cedula, 'nombre', p.nombre, 'codigo', p.codigo, 'celular', p.celular,
               'tipo', p.tipo, 'estado', p.estado, 'cargo', p.cargo, 'area', p.area,
               'fecha_ingreso', p.fecha_ingreso, 'fecha_retiro', p.fecha_retiro) order by p.nombre)
        from public.perfilsociodemografico p
       where p.tipo = 'CONDUCTOR' or p.cargo = 'CONDUCTOR'), '[]'::jsonb) end;
$function$;
revoke all on function public.vial_conductores() from public, anon;
grant execute on function public.vial_conductores() to authenticated;

-- ---------- Funciones del módulo: misma definición, el permiso suma seguridad vial ----------

CREATE OR REPLACE FUNCTION public.siniestros_cargar(p_filas jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_nuevos int := 0; v_upd int := 0; v_key text; v_existe boolean;
begin
  if not (public.es_talento_humano() or public.es_seguridad_vial()) then
    raise exception 'Solo un administrador, Gestion Humana o seguridad vial puede cargar los siniestros.';
  end if;
  if p_filas is null or jsonb_typeof(p_filas) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'Se esperaba una lista de filas');
  end if;

  for v_key in select f ->> 'key' from jsonb_array_elements(p_filas) f loop
    if coalesce(trim(v_key), '') = '' then continue; end if;
    select exists(select 1 from public.siniestros where key = v_key) into v_existe;
    if v_existe then v_upd := v_upd + 1; else v_nuevos := v_nuevos + 1; end if;
  end loop;

  insert into public.siniestros as s (
    key, mes_reporte, placa, numero_interno, fecha, ruta, afiliado,
    conductor_cedula, conductor_codigo, conductor_nombre, conductor_celular, conductor_fecha_ingreso,
    gravedad, responsabilidad, tipo_conciliacion, tipo_lesion, monto, monto_texto, usuario_app,
    fotos, video, observaciones, coordenadas, reportado_en,
    tercero_placa, tercero_nombre, tercero_tipo_id, tercero_ciudad_cedula, tercero_cedula,
    tercero_telefono, tercero_telefono2, tercero_correo, tercero_aseguradora, tercero_danos, tercero_firma,
    lesiones, danos_empresa, firma_conductor, estado_inicio, usuario_logistica, categorizacion,
    autorizacion_datos, doc_cara1, doc_cara2, audio_conductor, audio_tercero, audio_asistente,
    lugar, observaciones_asistencia, estado, causa, norma, hipotesis, factor,
    correo_asistente, correo_afiliado, telefono_afiliado, datos_origen)
  select
    f ->> 'key', f ->> 'mes_reporte', f ->> 'placa', f ->> 'numero_interno',
    nullif(f ->> 'fecha', '')::date, f ->> 'ruta', f ->> 'afiliado',
    f ->> 'conductor_cedula', f ->> 'conductor_codigo', f ->> 'conductor_nombre', f ->> 'conductor_celular',
    nullif(f ->> 'conductor_fecha_ingreso', '')::date,
    f ->> 'gravedad', f ->> 'responsabilidad', f ->> 'tipo_conciliacion', f ->> 'tipo_lesion',
    nullif(f ->> 'monto', '')::numeric, f ->> 'monto_texto', f ->> 'usuario_app',
    coalesce(f -> 'fotos', '[]'::jsonb), f ->> 'video', f ->> 'observaciones', f ->> 'coordenadas',
    nullif(f ->> 'reportado_en', '')::timestamptz,
    f ->> 'tercero_placa', f ->> 'tercero_nombre', f ->> 'tercero_tipo_id', f ->> 'tercero_ciudad_cedula',
    f ->> 'tercero_cedula', f ->> 'tercero_telefono', f ->> 'tercero_telefono2', f ->> 'tercero_correo',
    f ->> 'tercero_aseguradora', f ->> 'tercero_danos', f ->> 'tercero_firma',
    f ->> 'lesiones', f ->> 'danos_empresa', f ->> 'firma_conductor', f ->> 'estado_inicio',
    f ->> 'usuario_logistica', f ->> 'categorizacion', f ->> 'autorizacion_datos',
    f ->> 'doc_cara1', f ->> 'doc_cara2', f ->> 'audio_conductor', f ->> 'audio_tercero', f ->> 'audio_asistente',
    f ->> 'lugar', f ->> 'observaciones_asistencia', f ->> 'estado', f ->> 'causa', f ->> 'norma',
    f ->> 'hipotesis', f ->> 'factor', f ->> 'correo_asistente', f ->> 'correo_afiliado', f ->> 'telefono_afiliado',
    f -> 'datos_origen'
  from jsonb_array_elements(p_filas) f
  where coalesce(trim(f ->> 'key'), '') <> ''
  on conflict (key) do update set
    mes_reporte = excluded.mes_reporte, placa = excluded.placa, numero_interno = excluded.numero_interno,
    fecha = excluded.fecha, ruta = excluded.ruta, afiliado = excluded.afiliado,
    conductor_cedula = excluded.conductor_cedula, conductor_codigo = excluded.conductor_codigo,
    conductor_nombre = excluded.conductor_nombre, conductor_celular = excluded.conductor_celular,
    conductor_fecha_ingreso = excluded.conductor_fecha_ingreso,
    gravedad = excluded.gravedad, responsabilidad = excluded.responsabilidad,
    tipo_conciliacion = excluded.tipo_conciliacion, tipo_lesion = excluded.tipo_lesion,
    monto = excluded.monto, monto_texto = excluded.monto_texto, usuario_app = excluded.usuario_app,
    fotos = excluded.fotos, video = excluded.video, observaciones = excluded.observaciones,
    coordenadas = excluded.coordenadas, reportado_en = excluded.reportado_en,
    tercero_placa = excluded.tercero_placa, tercero_nombre = excluded.tercero_nombre,
    tercero_tipo_id = excluded.tercero_tipo_id, tercero_ciudad_cedula = excluded.tercero_ciudad_cedula,
    tercero_cedula = excluded.tercero_cedula, tercero_telefono = excluded.tercero_telefono,
    tercero_telefono2 = excluded.tercero_telefono2, tercero_correo = excluded.tercero_correo,
    tercero_aseguradora = excluded.tercero_aseguradora, tercero_danos = excluded.tercero_danos,
    tercero_firma = excluded.tercero_firma, lesiones = excluded.lesiones,
    danos_empresa = excluded.danos_empresa, firma_conductor = excluded.firma_conductor,
    estado_inicio = excluded.estado_inicio, usuario_logistica = excluded.usuario_logistica,
    categorizacion = excluded.categorizacion, autorizacion_datos = excluded.autorizacion_datos,
    doc_cara1 = excluded.doc_cara1, doc_cara2 = excluded.doc_cara2,
    audio_conductor = excluded.audio_conductor, audio_tercero = excluded.audio_tercero,
    audio_asistente = excluded.audio_asistente, lugar = excluded.lugar,
    observaciones_asistencia = excluded.observaciones_asistencia, estado = excluded.estado,
    causa = excluded.causa, norma = excluded.norma, hipotesis = excluded.hipotesis, factor = excluded.factor,
    correo_asistente = excluded.correo_asistente, correo_afiliado = excluded.correo_afiliado,
    telefono_afiliado = excluded.telefono_afiliado, datos_origen = excluded.datos_origen,
    actualizado_en = now();

  update public.siniestros_fuente
     set ultima_carga = now(),
         ultimo_total = (select count(1) from public.siniestros),
         actualizado_en = now()
   where id = 1;

  return jsonb_build_object('ok', true, 'nuevos', v_nuevos, 'actualizados', v_upd,
                            'total', (select count(1) from public.siniestros));
end $function$;


CREATE OR REPLACE FUNCTION public.siniestros_estado()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not (public.es_talento_humano() or public.es_seguridad_vial()) then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total', (select count(1) from public.siniestros),
      'desde', (select min(fecha) from public.siniestros),
      'hasta', (select max(fecha) from public.siniestros),
      'ultima_carga', (select ultima_carga from public.siniestros_fuente where id = 1),
      'url', (select url from public.siniestros_fuente where id = 1))
  end;
$function$;


CREATE OR REPLACE FUNCTION public.eventos_bus_estado()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select case when not (public.es_talento_humano() or public.es_auditor() or public.es_seguridad_vial()) then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total',        (select count(1) from public.eventos_bus),
      'desde',        (select min(fecha) from public.eventos_bus),
      'hasta',        (select max(fecha) from public.eventos_bus),
      'ultima_carga', (select max(sincronizado_en) from public.eventos_bus_sync),
      'dias',         (select count(distinct fecha) from public.eventos_bus_sync where ok),
      'umbral_kmh', (select umbral_kmh from public.eventos_bus_config where id = 1),
      'carros',     (select count(1) from public.eventos_bus_trackers()),
      'revisados_ayer', (select count(1) from public.eventos_bus_sync s
                          where s.fecha = (now() at time zone 'America/Bogota')::date - 1 and s.ok),
      'pendientes_ayer', (select count(1) from public.eventos_bus_trackers() k
                           where not exists (select 1 from public.eventos_bus_sync s
                                             where s.fecha = (now() at time zone 'America/Bogota')::date - 1
                                               and s.mid = k.mid and s.ok)))
  end;
$function$;


CREATE OR REPLACE FUNCTION public.eventos_bus_resumen(p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_items jsonb; v_dias int; v_umbral numeric;
begin
  if not (public.es_talento_humano() or public.es_auditor() or public.es_seguridad_vial()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  select coalesce(jsonb_agg(x order by n_rap desc, n_exc desc, n_pue desc), '[]'::jsonb) into v_items
  from (
    select
      coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0)    as n_rap,
      coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0) as n_exc,
      coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0) as n_pue,
      jsonb_build_object(
        'conductor', coalesce(b.conductor, '(sin viaje asociado)'),
        'cedula',    b.conductor_cedula,
        'codigo',    b.conductor_codigo,
        'excesos',   coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0),
        'rapidos',   coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0),
        'puertas',   coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0),
        'lecturas',  count(1),
        'peor_exceso', max(b.exceso_kmh) filter (where b.tipo = 'exceso'),
        'vel_max',   max(b.velocidad),
        'dias',      count(distinct b.fecha),
        'moviles',   count(distinct b.movil),
        'ultimo',    to_char(max(b.fecha), 'YYYY-MM-DD')
      ) as x
    from (
      select e.*,
        (coalesce(extract(epoch from (e.ocurrido_en
           - lag(e.ocurrido_en) over (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en))),
          1e9) > 300)::int as inicio
      from public.eventos_bus e
      where e.fecha between p_desde and p_hasta
    ) b
    group by b.conductor, b.conductor_cedula, b.conductor_codigo
  ) s;

  select count(distinct fecha) into v_dias from public.eventos_bus where fecha between p_desde and p_hasta;
  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
                            'dias_con_datos', v_dias, 'items', v_items, 'umbral_kmh', v_umbral,
                            'por_episodios', true);
end $function$;


CREATE OR REPLACE FUNCTION public.eventos_bus_series(p_desde date, p_hasta date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_res jsonb; v_umbral numeric;
begin
  if not (public.es_talento_humano() or public.es_auditor() or public.es_seguridad_vial()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  with marcado as (
    select e.mid, e.tipo, e.categoria, e.conductor, e.movil, e.ruta, e.ocurrido_en,
           e.velocidad, e.limite, e.sobre_umbral,
           (coalesce(extract(epoch from (e.ocurrido_en - lag(e.ocurrido_en) over w)), 1e9) > 300)::int as inicio
    from public.eventos_bus e
    where e.fecha between p_desde and p_hasta
    window w as (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en)
  ),
  epis as (
    select m.*, sum(m.inicio) over (partition by m.mid, m.tipo, m.conductor
                                    order by m.ocurrido_en rows unbounded preceding) as epi
    from marcado m
  ),
  -- Un renglón por episodio: cuándo empezó, en qué ruta, y lo más rápido que llegó a ir
  ep as materialized (
    select
      min(x.ocurrido_en)                         as inicio_en,
      mode() within group (order by x.categoria) as categoria,
      mode() within group (order by x.ruta)      as ruta,
      max(x.velocidad)                           as vel
    from epis x
    group by x.mid, x.tipo, x.conductor, x.epi
  ),
  hora as (
    select extract(hour from (inicio_en at time zone 'America/Bogota'))::int as k,
           count(1) as n,
           count(1) filter (where categoria = 'VELOCIDAD')      as vel,
           count(1) filter (where categoria = 'PUERTA ABIERTA') as pue
    from ep group by 1
  ),
  dia as (
    select extract(dow from (inicio_en at time zone 'America/Bogota'))::int as k,
           count(1) as n,
           count(1) filter (where categoria = 'VELOCIDAD')      as vel,
           count(1) filter (where categoria = 'PUERTA ABIERTA') as pue
    from ep group by 1
  ),
  mes as (
    select to_char(inicio_en at time zone 'America/Bogota', 'YYYY-MM') as k,
           count(1) as n,
           count(1) filter (where categoria = 'VELOCIDAD')      as vel,
           count(1) filter (where categoria = 'PUERTA ABIERTA') as pue
    from ep group by 1
  ),
  ruta as (
    select coalesce(nullif(trim(ruta), ''), '(sin ruta)') as k,
           count(1) as n,
           count(1) filter (where categoria = 'VELOCIDAD')      as vel,
           count(1) filter (where categoria = 'PUERTA ABIERTA') as pue
    from ep group by 1 order by count(1) desc limit 15
  ),
  tramo as (
    select
      case when vel <  v_umbral      then 'Hasta ' || v_umbral::int || ' km/h'
           when vel <  v_umbral + 10 then (v_umbral::int)      || ' a ' || (v_umbral::int + 9)  || ' km/h'
           when vel <  v_umbral + 20 then (v_umbral::int + 10) || ' a ' || (v_umbral::int + 19) || ' km/h'
           when vel <  v_umbral + 30 then (v_umbral::int + 20) || ' a ' || (v_umbral::int + 29) || ' km/h'
           else 'Más de ' || (v_umbral::int + 29) || ' km/h' end as k,
      case when vel <  v_umbral      then 0
           when vel <  v_umbral + 10 then 1
           when vel <  v_umbral + 20 then 2
           when vel <  v_umbral + 30 then 3
           else 4 end as orden,
      count(1) as n
    from ep
    where categoria = 'VELOCIDAD' and vel is not null
    group by 1, 2
  )
  select jsonb_build_object(
    'ok', true, 'desde', p_desde, 'hasta', p_hasta,
    'umbral_kmh', v_umbral,
    'episodios', (select count(1) from ep),
    'por_hora', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'vel', vel, 'pue', pue)
                                           order by k), '[]'::jsonb) from hora),
    'por_dia',  (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'vel', vel, 'pue', pue)
                                           order by k), '[]'::jsonb) from dia),
    'por_mes',  (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'vel', vel, 'pue', pue)
                                           order by k), '[]'::jsonb) from mes),
    'por_ruta', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n, 'vel', vel, 'pue', pue)
                                           order by n desc), '[]'::jsonb) from ruta),
    'por_velocidad', (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n)
                                                order by orden), '[]'::jsonb) from tramo)
  ) into v_res;

  return v_res;
end $function$;


CREATE OR REPLACE FUNCTION public.eventos_bus_mapa(p_desde date, p_hasta date, p_categoria text DEFAULT NULL::text, p_limite integer DEFAULT 600)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_items jsonb; v_con int; v_sin int; v_umbral numeric; v_lim int;
begin
  if not (public.es_talento_humano() or public.es_auditor() or public.es_seguridad_vial()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  v_lim := greatest(least(coalesce(p_limite, 600), 3000), 1);
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  -- Cuántos eventos del periodo tienen punto y cuántos no (el GPS a veces manda el evento sin
  -- coordenada). La pantalla lo dice, para que nadie crea que el mapa está completo si no lo está.
  select count(1) filter (where e.lat is not null and e.lon is not null),
         count(1) filter (where e.lat is null or e.lon is null)
    into v_con, v_sin
  from public.eventos_bus e
  where e.fecha between p_desde and p_hasta
    and (p_categoria is null or e.categoria = p_categoria);

  with marcado as (
    select e.mid, e.tipo, e.categoria, e.conductor, e.conductor_cedula, e.movil, e.ruta,
           e.fecha, e.ocurrido_en, e.velocidad, e.limite, e.direccion, e.lat, e.lon,
           (coalesce(extract(epoch from (e.ocurrido_en - lag(e.ocurrido_en) over w)), 1e9) > 300)::int as inicio
    from public.eventos_bus e
    where e.fecha between p_desde and p_hasta
      and e.lat is not null and e.lon is not null
      and (p_categoria is null or e.categoria = p_categoria)
    window w as (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en)
  ),
  epis as (
    select m.*,
           sum(m.inicio) over (partition by m.mid, m.tipo, m.conductor
                               order by m.ocurrido_en rows unbounded preceding) as epi
    from marcado m
  ),
  celdas as (
    select
      round(x.lat, 3)::float8 as lat,
      round(x.lon, 3)::float8 as lon,
      x.categoria,
      count(distinct (x.mid || '|' || x.tipo || '|' || coalesce(x.conductor, '') || '|' || x.epi::text)) as veces,
      count(1)                                as lecturas,
      max(x.velocidad)                        as vel_max,
      round(avg(x.velocidad), 1)              as vel_prom,
      max(x.velocidad - x.limite) filter (where x.limite > 0) as sobre_max,
      count(distinct coalesce(x.conductor_cedula, x.conductor)) as conductores,
      count(distinct x.movil)                 as moviles,
      count(distinct x.fecha)                 as dias,
      mode() within group (order by x.direccion) as direccion,
      mode() within group (order by x.ruta)      as ruta,
      mode() within group (order by x.conductor) as conductor_top,
      to_char(max(x.fecha), 'YYYY-MM-DD')     as ultimo
    from epis x
    group by 1, 2, 3
  )
  select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) into v_items
  from (select * from celdas order by veces desc, lecturas desc limit v_lim) c;

  return jsonb_build_object(
    'ok', true, 'desde', p_desde, 'hasta', p_hasta, 'categoria', p_categoria,
    'umbral_kmh', v_umbral, 'con_punto', coalesce(v_con, 0), 'sin_punto', coalesce(v_sin, 0),
    'celda_m', 110, 'limite', v_lim, 'items', v_items);
end $function$;


CREATE OR REPLACE FUNCTION public.preop_panel(p_fecha date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_f date := coalesce(p_fecha, (now() at time zone 'America/Bogota')::date);
  v_out jsonb;
begin
  -- El admin y seguridad vial (igual que la tabla, sql/127 + sql/157)
  if not (select public.es_seguridad_vial()) then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador y seguridad vial ven este panel.');
  end if;

  with sal as ( -- los vehiculos que REALMENTE salieron ese dia, con su conductor
    select btrim(v.numero) as movil,
           max(btrim(coalesce(v.placa, ''))) as placa,
           (array_agg(c.nombre order by c.nombre))[1] as conductor,
           count(*)::int as viajes
      from public.despachos d
      join public.vehiculos v on v.id = d.vehiculo_id
      left join public.conductores c on c.id = d.conductor_id
     where d.fecha = v_f and btrim(coalesce(v.numero, '')) <> ''
     group by btrim(v.numero)
  ),
  hec as ( select * from public.preoperacionales where fecha = v_f )
  select jsonb_build_object(
    'ok', true,
    'fecha', v_f,
    'resumen', jsonb_build_object(
      'salieron',         (select count(*) from sal),
      'hechas',           (select count(*) from hec),
      'faltan',           (select count(*) from sal s
                            where not exists (select 1 from hec h where h.movil = s.movil)),
      'con_novedad',      (select count(*) from hec where novedades > 0),
      'pendientes_atras', (select count(*) from public.preoperacionales
                            where estado = 'PENDIENTE' and fecha < v_f)),

    -- Las que SI se hicieron
    'hechas', (select coalesce(jsonb_agg(jsonb_build_object(
                 'id', h.id, 'movil', h.movil, 'placa', h.placa, 'conductor', h.nombre,
                 'hora', to_char(h.creado_en at time zone 'America/Bogota', 'HH24:MI'),
                 'estado', h.estado, 'novedades', h.novedades, 'lat', h.lat, 'lon', h.lon,
                 'salio', exists (select 1 from sal s where s.movil = h.movil)
               ) order by h.creado_en), '[]'::jsonb) from hec h),

    -- Los que salieron y NO la hicieron
    'faltan', (select coalesce(jsonb_agg(jsonb_build_object(
                 'movil', s.movil, 'placa', s.placa, 'conductor', s.conductor, 'viajes', s.viajes
               ) order by lpad(s.movil, 6, '0')), '[]'::jsonb)
                 from sal s
                where not exists (select 1 from hec h where h.movil = s.movil)),

    -- Las incidencias del dia: que punto salio mal y que dijo el conductor
    'incidencias', (select coalesce(jsonb_agg(jsonb_build_object(
                      'id', h.id, 'movil', h.movil, 'placa', h.placa, 'conductor', h.nombre,
                      'estado', h.estado, 'novedades', h.novedades,
                      'puntos', (select jsonb_agg(jsonb_build_object(
                                          'pregunta', i.pregunta, 'comentario', i.comentario)
                                        order by i.orden)
                                   from public.preoperacional_items i
                                  where i.preop_id = h.id and i.respuesta = 'MAL')
                    ) order by h.creado_en), '[]'::jsonb)
                      from hec h where h.novedades > 0)
  ) into v_out;

  return v_out;
end $function$;

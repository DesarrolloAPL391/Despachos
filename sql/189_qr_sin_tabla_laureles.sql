-- 189: QR del despacho APAGADO en una tabla de puesto. Pedido del usuario (13/11/2026): "desactivar el despacho por QR solo a
-- laureles la tabla". Las demás tablas, Despachos (domingos y festivos) y Nuevo despacho siguen igual: 2.º viaje con QR + foto
-- + carnet y del 3.er viaje en adelante el QR del bus.
-- Sin publicar la app: la app le pregunta a despacho_viajes_bus qué viaje es el bus; para una tabla sin QR la base contesta
-- viaje = null ("no se sabe") y la app despacha como antes, sin QR (es el mismo camino de "sin señal").
-- Los viajes de esa tabla SIGUEN contando para el número de viaje del bus en las demás tablas.
-- Los tableros de control no cuentan esos despachos como "sin pasar por el QR" mientras la tabla esté sin QR.
-- Volver a pedir el QR en Laureles (sin publicar):
--   update public.despacho_qr_sin_tabla set hasta = now() where tabla = 'laureles' and hasta is null;
set lock_timeout = '5s';

create table if not exists public.despacho_qr_sin_tabla (
  id bigint generated always as identity primary key,
  tabla text not null,
  desde timestamptz not null default now(),
  hasta timestamptz,
  nota text,
  creado_en timestamptz not null default now(),
  check (hasta is null or hasta > desde));
alter table public.despacho_qr_sin_tabla enable row level security;   -- sin políticas: solo la leen las funciones de abajo
revoke all on public.despacho_qr_sin_tabla from public, anon, authenticated;

-- ¿Esa tabla está sin QR en ese momento?
create or replace function public._qr_tabla_libre(p_tabla text, p_cuando timestamptz default now())
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.despacho_qr_sin_tabla s
                  where s.tabla = p_tabla and p_cuando >= s.desde and (s.hasta is null or p_cuando < s.hasta));
$$;
-- Las tablas sin QR ahora (para despacho_qr_reglas)
create or replace function public._qr_tablas_libres()
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(distinct s.tabla), '[]'::jsonb) from public.despacho_qr_sin_tabla s
   where s.desde <= now() and (s.hasta is null or now() < s.hasta);
$$;
revoke all on function public._qr_tabla_libre(text, timestamptz) from public, anon, authenticated;
revoke all on function public._qr_tablas_libres() from public, anon, authenticated;
CREATE OR REPLACE FUNCTION public.despacho_viajes_bus(p_vehiculo_id bigint, p_fecha date, p_tabla text DEFAULT NULL::text, p_fila_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare t record; n bigint; v_total bigint := 0;
begin
  if auth.uid() is null or not (public.es_admin() or public.es_despachador()) then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if p_vehiculo_id is null or p_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el bus o la fecha.');
  end if;
  -- 189: en una tabla con el QR apagado no se dice el viaje: la app no pide QR (ni el del 2.º viaje ni el rápido)
  if p_tabla is not null and public._qr_tabla_libre(p_tabla) then
    return jsonb_build_object('ok', true, 'previos', null, 'viaje', null, 'sin_qr', true);
  end if;
  for t in select 'despachos' tabla union all select tabla from public.tablas_despacho where activo loop
    execute format($q$select count(*) from public.%I x
                       where x.fecha = $1 and x.vehiculo_id = $2
                         and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR', 'REALIZADO')
                         and not (%L = coalesce($3, '') and x.id::text = coalesce($4, ''))$q$, t.tabla, t.tabla)
      into n using p_fecha, p_vehiculo_id, p_tabla, p_fila_id;
    v_total := v_total + n;
  end loop;
  return jsonb_build_object('ok', true, 'previos', v_total, 'viaje', v_total + 1);
end $function$;

CREATE OR REPLACE FUNCTION public.despacho_qr_reglas()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select coalesce(
    (select jsonb_build_object('ok', true, 'desde', c.obligatorio_desde, 'carnet', c.carnet, 'solo_viaje', c.solo_viaje,
                               'rapido_desde', c.rapido_desde, 'ahora', now(), 'sin_tablas', public._qr_tablas_libres())
       from public.despacho_qr_config c where c.id = 1),
    jsonb_build_object('ok', true, 'desde', null, 'carnet', true, 'solo_viaje', null, 'rapido_desde', null, 'ahora', now(), 'sin_tablas', public._qr_tablas_libres()));
$function$;

CREATE OR REPLACE FUNCTION public.despacho_qr_auditoria(p_desde date, p_hasta date, p_rutas bigint[] DEFAULT NULL::bigint[], p_ruta bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin boolean := public.es_admin();
  v_scope bigint[];
  v_inicio timestamp;
  v_solo int;
  v_solo_desde timestamp;
  v_union text;
  v_res jsonb;
begin
  if not (v_admin or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y control.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 31 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de hasta un mes.');
  end if;
  -- las rutas que puede ver: el monitor, las suyas; administración, todas (o las que pida: "Ver como auditor")
  if v_admin then
    v_scope := case when cardinality(p_rutas) > 0 then p_rutas end;      -- null = todas
  else
    v_scope := public.rutas_auditor();
    if coalesce(cardinality(v_scope), 0) = 0 then
      return jsonb_build_object('ok', true, 'sin_rutas', true, 'desde', p_desde, 'hasta', p_hasta);
    end if;
  end if;
  -- se cuenta desde que el QR es obligatorio (sql/180): antes de esa hora nadie tenía que leerlo
  select c.obligatorio_desde at time zone 'America/Bogota' into v_inicio from public.despacho_qr_config c where c.id = 1;
  v_inicio := coalesce(v_inicio, '-infinity'::timestamp);
  -- la regla del viaje (sql/182): solo_viaje = 2 → solo el 2.º viaje del día de cada carro pide QR
  select c.solo_viaje, c.solo_viaje_desde at time zone 'America/Bogota' into v_solo, v_solo_desde from public.despacho_qr_config c where c.id = 1;
  -- los despachos HECHOS de todas las tablas (Despachos + tablas de puesto activas)
  select string_agg(format(
    $f$select %L::text tabla, %L::text tabla_label, x.id::text fila_id, x.fecha, coalesce(x.hora_real_despacho, x.hora) hora,
              x.ruta_id, x.vehiculo_id veh_fila
         from public.%I x
        where x.fecha between $1 and $2
          and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR', 'REALIZADO')$f$, t.tabla, t.label, t.tabla), ' union all ')
    into v_union
    from (select 'despachos' tabla, 'Despachos' label union all
          select tabla, label from public.tablas_despacho where activo) t;

  execute format($m$
    with todas as (%s),
    libre as (   -- 189: tablas con el QR apagado (despacho_qr_sin_tabla), en hora Colombia
      select s.tabla, s.desde at time zone 'America/Bogota' d,
             coalesce(s.hasta at time zone 'America/Bogota', 'infinity'::timestamp) h
        from public.despacho_qr_sin_tabla s),
    rk as (   -- el número de viaje del carro ese día (todas las rutas y tablas), por hora real de despacho
      select t.*, row_number() over (partition by t.fecha, t.veh_fila order by t.hora nulls last, t.tabla, t.fila_id) viaje_n from todas t),
    q as (   -- la última lectura de cada fila
      select distinct on (q.tabla, q.fila_id) q.*
        from public.despacho_qr q
       where q.fecha between $1 - 1 and $2 + 1
       order by q.tabla, q.fila_id, q.creado_en desc),
    filas as (   -- los despachos que pedían QR: desde el arranque; con la regla del viaje, solo ese viaje del carro (o si tiene lectura igual)
      select rk.* from rk
       where ($3::bigint[] is null or rk.ruta_id = any ($3))
         and rk.fecha + coalesce(rk.hora, time '23:59') >= $5
         and ($6::int is null or rk.fecha + coalesce(rk.hora, time '23:59') < $7 or rk.viaje_n = $6
              or exists (select 1 from q where q.tabla = rk.tabla and q.fila_id = rk.fila_id))
         and (not exists (select 1 from libre l where l.tabla = rk.tabla
                             and rk.fecha + coalesce(rk.hora, time '23:59') >= l.d and rk.fecha + coalesce(rk.hora, time '23:59') < l.h)
              or exists (select 1 from q where q.tabla = rk.tabla and q.fila_id = rk.fila_id))),
    bus_ok as (   -- el QR de ese bus SÍ se leyó (cuándo, la última vez)
      select vehiculo_id, max(creado_en) en from public.despacho_qr
       where fecha between $1 - 7 and $2 + 7 and estado = 'LEIDO' and coincide is not false group by 1),
    car_ok as (   -- el carnet de ese conductor SÍ se leyó
      select cond_dr_id, max(creado_en) en from public.despacho_qr
       where fecha between $1 - 7 and $2 + 7 and cond_estado = 'LEIDO' and cond_coincide is not false and cond_dr_id is not null group by 1),
    xd as (
      select f.tabla, f.tabla_label, f.fila_id, f.fecha, f.ruta_id, coalesce(r.nombre, '(sin ruta)') ruta,
             q.id qid, q.creado_en, coalesce(to_char(q.creado_en at time zone 'America/Bogota', 'HH24:MI'), to_char(f.hora, 'HH24:MI')) hora,
             q.estado, q.coincide, q.motivo, q.qr_texto, q.foto_estado, q.foto_path, q.gps_estado, q.distancia_m,
             q.cond_estado, q.cond_coincide, q.cond_motivo, q.cond_nombre,
             coalesce(q.movil, btrim(v.numero)) movil,
             coalesce(d.nombre, p.nombre, case when q.id is not null then 'Cuenta sin nombre' end) despachador,
             case when q.estado = 'SIN_QR' and q.motivo in ('El bus no tiene sticker', 'Sticker dañado o ilegible') then bo.en end bus_leido_en,
             case when q.cond_estado = 'SIN_QR' and q.cond_motivo in ('El conductor no tiene el carnet', 'Carnet dañado o ilegible') then co.en end carnet_leido_en
        from filas f
        left join q on q.tabla = f.tabla and q.fila_id = f.fila_id
        left join public.rutas r on r.id = f.ruta_id
        left join public.vehiculos v on v.id = coalesce(q.vehiculo_id, f.veh_fila)
        left join public.despachadores d on d.id = q.despachador_id
        left join public.perfiles p on p.id = q.uid
        left join bus_ok bo on bo.vehiculo_id = q.vehiculo_id
        left join car_ok co on co.cond_dr_id = q.cond_dr_id),
    xf as (select * from xd where $4::bigint is null or ruta_id = $4),
    prob as (
      select * from xf
       where qid is null or estado = 'SIN_QR' or coincide is false or foto_estado = 'FALTA' or gps_estado in ('LEJOS', 'TARDE')
          or cond_estado = 'SIN_QR' or cond_coincide is false)
    select jsonb_build_object('ok', true, 'desde', $1, 'hasta', $2, 'ruta', $4,
      'obligatorio_desde', case when $5 > '-infinity'::timestamp then to_char($5, 'DD/MM/YYYY HH24:MI') end,
      'solo_viaje', $6, 'solo_viaje_desde', case when $7 is not null then to_char($7, 'DD/MM/YYYY HH24:MI') end,
      'mis_rutas', (select string_agg(nombre, ', ' order by nombre) from public.rutas where $3::bigint[] is not null and id = any ($3)),
      'resumen', (select jsonb_build_object(
          'despachos', count(*), 'con_lectura', count(qid), 'sin_lectura', count(*) filter (where qid is null),
          'qr_bus', count(*) filter (where estado = 'LEIDO' and coincide is not false),
          'qr_otro_bus', count(*) filter (where estado = 'LEIDO' and coincide is false),
          'sin_qr', count(*) filter (where estado = 'SIN_QR'),
          'carnet', count(*) filter (where cond_estado = 'LEIDO' and cond_coincide is not false),
          'carnet_otro', count(*) filter (where cond_estado = 'LEIDO' and cond_coincide is false),
          'sin_carnet', count(*) filter (where cond_estado = 'SIN_QR'),
          'con_foto', count(*) filter (where foto_estado = 'CON_FOTO'),
          'sin_foto', count(*) filter (where foto_estado = 'FALTA'),
          'lejos', count(*) filter (where gps_estado = 'LEJOS'),
          'tarde', count(*) filter (where gps_estado = 'TARDE'),
          'bus_sin_gps', count(*) filter (where gps_estado = 'BUS_SIN_GPS'),
          'cel_sin_gps', count(*) filter (where gps_estado = 'CEL_SIN_GPS'),
          'sticker_si_leido', count(*) filter (where bus_leido_en is not null),
          'carnet_si_leido', count(*) filter (where carnet_leido_en is not null),
          'por_motivo', (select coalesce(jsonb_object_agg(motivo, n), '{}'::jsonb) from (
                           select motivo, count(*) n from xf where estado = 'SIN_QR' group by 1) m),
          'por_motivo_carnet', (select coalesce(jsonb_object_agg(cond_motivo, n), '{}'::jsonb) from (
                           select cond_motivo, count(*) n from xf where cond_estado = 'SIN_QR' group by 1) m)) from xf),
      -- por ruta: SIEMPRE todas las rutas que puede ver (el filtro de ruta solo acota lo demás); la peor primero
      'por_ruta', (select coalesce(jsonb_agg(r order by r.pct_qr, r.despachos desc), '[]'::jsonb) from (
          select ruta_id, ruta, count(*) despachos, count(*) filter (where qid is null) sin_lectura,
                 count(*) filter (where estado = 'LEIDO' and coincide is not false) qr_bus,
                 count(*) filter (where estado = 'SIN_QR') sin_qr,
                 count(*) filter (where motivo = 'El bus no tiene sticker') sin_sticker,
                 count(*) filter (where motivo = 'Sticker dañado o ilegible') sticker_danado,
                 count(*) filter (where motivo = 'La cámara no abre o no enfoca') camara,
                 count(*) filter (where cond_estado = 'LEIDO' and cond_coincide is not false) carnet,
                 count(*) filter (where cond_estado = 'SIN_QR') sin_carnet,
                 count(*) filter (where foto_estado = 'CON_FOTO') con_foto,
                 count(*) filter (where foto_estado = 'FALTA') sin_foto,
                 count(*) filter (where gps_estado = 'LEJOS') lejos,
                 count(*) filter (where bus_leido_en is not null) sticker_si_leido,
                 count(*) filter (where carnet_leido_en is not null) carnet_si_leido,
                 round(100.0 * count(*) filter (where estado = 'LEIDO' and coincide is not false) / count(*), 1) pct_qr
            from xd group by 1, 2) r),
      'por_despachador', (select coalesce(jsonb_agg(x order by x.pct_qr, x.total desc), '[]'::jsonb) from (
          select despachador, count(*) total,
                 count(*) filter (where estado = 'LEIDO' and coincide is not false) qr_bus,
                 count(*) filter (where estado = 'SIN_QR') sin_qr,
                 count(*) filter (where coincide is false) qr_otro_bus,
                 count(*) filter (where foto_estado = 'FALTA') sin_foto,
                 count(*) filter (where gps_estado = 'LEJOS') lejos,
                 count(*) filter (where cond_estado = 'SIN_QR') sin_carnet,
                 count(*) filter (where bus_leido_en is not null or carnet_leido_en is not null) desmentidos,
                 string_agg(distinct ruta, ', ') rutas,
                 round(100.0 * count(*) filter (where estado = 'LEIDO' and coincide is not false) / count(*), 1) pct_qr
            from xf where qid is not null group by 1) x),
      'revisar_total', (select count(*) from prob),
      'revisar', (select coalesce(jsonb_agg(jsonb_build_object(
            'id', p.qid, 'fecha', p.fecha, 'hora', p.hora, 'ruta', p.ruta, 'tabla', p.tabla_label, 'movil', p.movil,
            'sin_lectura', p.qid is null, 'estado', p.estado, 'motivo', p.motivo, 'qr_texto', left(p.qr_texto, 30), 'coincide', p.coincide,
            'foto_path', p.foto_path, 'foto_estado', p.foto_estado, 'distancia_m', p.distancia_m, 'gps_estado', p.gps_estado,
            'cond_estado', p.cond_estado, 'cond_nombre', p.cond_nombre, 'cond_coincide', p.cond_coincide, 'cond_motivo', p.cond_motivo,
            'despachador', p.despachador,
            'bus_leido_en', to_char(p.bus_leido_en at time zone 'America/Bogota', 'DD/MM HH24:MI'),
            'carnet_leido_en', to_char(p.carnet_leido_en at time zone 'America/Bogota', 'DD/MM HH24:MI'))
            order by p.fecha desc, p.hora desc), '[]'::jsonb)
          from (select * from prob order by fecha desc, hora desc limit 400) p),
      -- una muestra de las fotos buenas, para revisarlas a ojo de vez en cuando
      'muestra', (select coalesce(jsonb_agg(jsonb_build_object('id', x.qid, 'hora', to_char(x.creado_en at time zone 'America/Bogota', 'DD/MM HH24:MI'),
                     'movil', x.movil, 'ruta', x.ruta, 'foto_path', x.foto_path, 'distancia_m', x.distancia_m, 'despachador', x.despachador)), '[]'::jsonb)
          from (select * from xf where foto_estado = 'CON_FOTO' and gps_estado = 'CERCA' order by random() limit 12) x))
  $m$, v_union)
  into v_res using p_desde, p_hasta, v_scope, p_ruta, v_inicio, v_solo, v_solo_desde;
  return v_res;
end $function$;

CREATE OR REPLACE FUNCTION public.despacho_qr_rapido_resumen(p_desde date, p_hasta date, p_rutas bigint[] DEFAULT NULL::bigint[], p_ruta bigint DEFAULT NULL::bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_admin boolean := public.es_admin();
  v_scope bigint[];
  v_solo int; v_desde timestamptz; v_inicio timestamp; v_rapido timestamptz; v_rinicio timestamp;
  v_union text; v_res jsonb;
begin
  if not (v_admin or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y control.');
  end if;
  if p_desde is null or p_hasta is null or p_hasta < p_desde or p_hasta - p_desde > 31 then
    return jsonb_build_object('ok', false, 'error', 'Elige un rango de hasta un mes.');
  end if;
  if v_admin then
    v_scope := case when cardinality(p_rutas) > 0 then p_rutas end;      -- null = todas
  else
    v_scope := public.rutas_auditor();
    if coalesce(cardinality(v_scope), 0) = 0 then
      return jsonb_build_object('ok', true, 'sin_rutas', true);
    end if;
  end if;
  select c.solo_viaje, c.solo_viaje_desde, c.rapido_desde into v_solo, v_desde, v_rapido from public.despacho_qr_config c where c.id = 1;
  if v_solo is null then
    return jsonb_build_object('ok', true, 'sin_regla', true);
  end if;
  v_desde := coalesce(v_desde, '-infinity'::timestamptz);
  v_inicio := case when v_desde = '-infinity'::timestamptz then '-infinity'::timestamp else v_desde at time zone 'America/Bogota' end;
  -- desde cuándo el QR del bus es OBLIGATORIO del viaje siguiente en adelante (sql/187); antes era opcional
  v_rinicio := coalesce(v_rapido at time zone 'America/Bogota', 'infinity'::timestamp);
  -- los despachos HECHOS de todas las tablas (Despachos + tablas de puesto activas)
  select string_agg(format(
    $f$select %L::text tabla, %L::text tabla_label, x.id::text fila_id, x.fecha, coalesce(x.hora_real_despacho, x.hora) hora,
              x.ruta_id, x.vehiculo_id veh, x.conductor_id, x.despachador_id
         from public.%I x
        where x.fecha between $1 and $2 and x.vehiculo_id is not null
          and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR', 'REALIZADO')$f$, t.tabla, t.label, t.tabla), ' union all ')
    into v_union
    from (select 'despachos' tabla, 'Despachos' label union all
          select tabla, label from public.tablas_despacho where activo) t;

  execute format($m$
    with todas as (%s),
    libre as (   -- 189: tablas con el QR apagado (despacho_qr_sin_tabla), en hora Colombia
      select s.tabla, s.desde at time zone 'America/Bogota' d,
             coalesce(s.hasta at time zone 'America/Bogota', 'infinity'::timestamp) h
        from public.despacho_qr_sin_tabla s),
    rk as (   -- el número de viaje del carro ese día (todas las rutas y tablas), por hora real de despacho
      select t.*, row_number() over (partition by t.fecha, t.veh order by t.hora nulls last, t.tabla, t.fila_id) n from todas t),
    cs as (   -- los conductores de SONAR: código y nombre de hoy, y la llave para buscar por nombre
      select s.dr_id, btrim(s.nombre) nombre, public._norm_alnum(s.nombre) k, (upper(coalesce(s.status, '')) = 'ENABLED') activo, s.id
        from public.conductores_sonar s where s.dr_id is not null),
    csk as (select distinct on (k) k, dr_id from cs where k <> '' order by k, activo desc, id),
    lq as (   -- la última lectura con conductor de cada fila
      select distinct on (q.tabla, q.fila_id) q.tabla, q.fila_id, q.cond_dr_id, q.cond_nombre, q.cond_estado, coalesce(q.leido_en, q.creado_en) en
        from public.despacho_qr q
       where q.fecha between $1 - 1 and $2 + 1 and q.cond_dr_id is not null
       order by q.tabla, q.fila_id, q.creado_en desc),
    ld as (   -- la lectura del viaje del QR de cada bus y día (desde que rige la regla, solo ese viaje registra lectura)
      select distinct on (q.fecha, q.vehiculo_id) q.fecha, q.vehiculo_id veh, q.cond_dr_id, q.cond_nombre, q.cond_estado, coalesce(q.leido_en, q.creado_en) en
        from public.despacho_qr q
       where q.fecha between $1 and $2 and q.cond_dr_id is not null and q.creado_en >= $6
       order by q.fecha, q.vehiculo_id, q.creado_en desc),
    lr as (   -- el último registro del QR del bus (o su motivo) de cada fila, del viaje siguiente al del QR en adelante
      select distinct on (q.tabla, q.fila_id) q.tabla, q.fila_id, q.estado, q.motivo, q.coincide
        from public.despacho_qr_rapido q
       where q.fecha between $1 - 1 and $2 + 1
       order by q.tabla, q.fila_id, q.creado_en desc),
    v2 as (   -- el conductor del 2.º viaje de cada bus y día (código de SONAR y nombre de hoy)
      select k.fecha, k.veh,
             coalesce(ld.cond_dr_id, lq.cond_dr_id, ck.dr_id) dr_id,
             coalesce(ld.cond_nombre, lq.cond_nombre, btrim(c.nombre)) nombre_guardado,
             case when ld.veh is not null then case when ld.cond_estado = 'LEIDO' then 'CARNET' else 'LISTA' end
                  when lq.fila_id is not null then case when lq.cond_estado = 'LEIDO' then 'CARNET' else 'LISTA' end
                  when c.nombre is not null then 'DESPACHO' end origen,
             coalesce(to_char(coalesce(ld.en, lq.en) at time zone 'America/Bogota', 'HH24:MI'), to_char(k.hora, 'HH24:MI')) hora
        from rk k
        left join ld on ld.fecha = k.fecha and ld.veh = k.veh
        left join lq on lq.tabla = k.tabla and lq.fila_id = k.fila_id
        left join public.conductores c on c.id = k.conductor_id
        left join csk ck on ck.k = public._norm_alnum(c.nombre)
       where k.n = $5),
    xs as (   -- los viajes después del del QR, desde que rige la regla, en las rutas que puede ver
      select k.*, coalesce(r.nombre, '(sin ruta)') ruta, btrim(v.numero) movil, btrim(c.nombre) cond_nombre, ck.dr_id cond_dr_id,
             coalesce(n2.nombre, v2.nombre_guardado) v2_nombre, v2.dr_id v2_dr_id, v2.origen v2_origen, v2.hora v2_hora,
             lr.estado r_estado, lr.motivo r_motivo, lr.coincide r_coincide,
             (k.fecha + coalesce(k.hora, time '23:59') >= $8
              and not exists (select 1 from libre l where l.tabla = k.tabla
                                 and k.fecha + coalesce(k.hora, time '23:59') >= l.d and k.fecha + coalesce(k.hora, time '23:59') < l.h)) obligatorio,
             coalesce(d.nombre, 'Sin despachador') despachador
        from rk k
        left join v2 on v2.fecha = k.fecha and v2.veh = k.veh
        left join lr on lr.tabla = k.tabla and lr.fila_id = k.fila_id
        left join lateral (select x.nombre from cs x where x.dr_id = v2.dr_id order by x.activo desc, x.id limit 1) n2 on true
        left join public.conductores c on c.id = k.conductor_id
        left join csk ck on ck.k = public._norm_alnum(c.nombre)
        left join public.rutas r on r.id = k.ruta_id
        left join public.vehiculos v on v.id = k.veh
        left join public.despachadores d on d.id = k.despachador_id
       where k.n > $5
         and k.fecha + coalesce(k.hora, time '23:59') >= $7
         and ($3::bigint[] is null or k.ruta_id = any ($3))
         and ($4::bigint is null or k.ruta_id = $4)),
    xc as (   -- cómo se despachó, y ¿cambió? (el nombre sin tildes ni espacios es otro Y el código de SONAR también, o falta)
      select xs.*,
             case when r_estado = 'LEIDO' then 'QR' when r_estado = 'SIN_QR' then 'SIN_QR'
                  when obligatorio then 'SIN_LECTURA' else 'LISTA' end metodo,
             (v2_nombre is not null and cond_nombre is not null
                    and public._norm_alnum(v2_nombre) <> public._norm_alnum(cond_nombre)
                    and (v2_dr_id is null or cond_dr_id is null or v2_dr_id <> cond_dr_id)) cambio
        from xs)
    select jsonb_build_object('ok', true, 'solo_viaje', $5,
      'desde_regla', case when $7 > '-infinity'::timestamp then to_char($7, 'DD/MM/YYYY HH24:MI') end,
      'obligatorio_desde', case when $8 < 'infinity'::timestamp then to_char($8, 'DD/MM/YYYY HH24:MI') end,
      'total', count(*),
      'con_qr', count(*) filter (where metodo = 'QR'),
      'sin_qr', count(*) filter (where metodo = 'SIN_QR'),
      'sin_lectura', count(*) filter (where metodo = 'SIN_LECTURA'),
      'con_lista', count(*) filter (where metodo = 'LISTA'),
      'por_motivo', (select coalesce(jsonb_object_agg(r_motivo, c), '{}'::jsonb) from (
          select r_motivo, count(*) c from xc where metodo = 'SIN_QR' group by 1) z),
      'qr_otro_bus', count(*) filter (where metodo = 'QR' and r_coincide is false),
      'con_v2', count(*) filter (where v2_nombre is not null),
      'sin_v2', count(*) filter (where v2_nombre is null),
      'sin_conductor', count(*) filter (where cond_nombre is null),
      'cambios', count(*) filter (where cambio),
      'cambios_con_qr', count(*) filter (where cambio and metodo = 'QR'),
      'cambios_sin_qr', count(*) filter (where cambio and metodo <> 'QR'),
      'por_despachador', (select coalesce(jsonb_agg(z order by z.pct_qr, z.viajes desc), '[]'::jsonb) from (
          select despachador, count(*) viajes, count(*) filter (where metodo = 'QR') con_qr, count(*) filter (where metodo = 'SIN_QR') sin_qr,
                 count(*) filter (where metodo = 'SIN_LECTURA') sin_lectura, count(*) filter (where cambio) cambios,
                 round(100.0 * count(*) filter (where metodo = 'QR') / count(*), 1) pct_qr
            from xc group by 1) z),
      'revisar_total', count(*) filter (where cambio or metodo in ('SIN_QR', 'SIN_LECTURA') or (metodo = 'QR' and r_coincide is false)),
      'revisar', (select coalesce(jsonb_agg(jsonb_build_object(
            'fecha', y.fecha, 'hora', to_char(y.hora, 'HH24:MI'), 'ruta', y.ruta, 'tabla', y.tabla_label, 'movil', y.movil, 'viaje', y.n,
            'metodo', y.metodo, 'motivo', y.r_motivo, 'qr_otro_bus', (y.metodo = 'QR' and y.r_coincide is false), 'cambio', y.cambio,
            'v2_nombre', y.v2_nombre, 'v2_origen', y.v2_origen, 'v2_hora', y.v2_hora, 'cond_nombre', y.cond_nombre,
            'despachador', y.despachador) order by y.fecha desc, y.hora desc), '[]'::jsonb)
          from (select * from xc where cambio or metodo in ('SIN_QR', 'SIN_LECTURA') or (metodo = 'QR' and r_coincide is false)
                 order by fecha desc, hora desc limit 400) y))
      from xc
  $m$, v_union)
  into v_res using p_desde, p_hasta, v_scope, p_ruta, v_solo, v_desde, v_inicio, v_rinicio;
  return v_res;
end $function$;

-- El interruptor: Laureles sin QR desde ya (lo despachado antes de hoy a esta hora queda como estaba en los tableros)
insert into public.despacho_qr_sin_tabla (tabla, nota)
select 'laureles', 'Pedido del usuario 13/11/2026: sin QR en la tabla de Laureles'
 where not exists (select 1 from public.despacho_qr_sin_tabla where tabla = 'laureles' and hasta is null);

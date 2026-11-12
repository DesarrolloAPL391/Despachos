-- 182: EL QR SOLO EN EL 2.º VIAJE DE CADA CARRO (12/11/2026).
--
-- Pedido: "a partir de este momento solo se escaneará el segundo viaje de todos los carros de la forma como lo
-- tenemos en este momento; el 1.er viaje se puede seleccionar normal con la lista y desde Resumen hacer el proceso
-- normal; a partir del 3.er viaje sigue normal sin pedir el QR".
--   * despacho_qr_config.solo_viaje: null = el QR en todos los viajes (como desde el 11/11); 2 = solo en el 2.º viaje
--     del día de cada carro. solo_viaje_desde: desde cuándo rige (el tablero de control cuenta con eso).
--   * despacho_viajes_bus: cuántos viajes YA hizo hoy ese carro en TODAS las tablas (Despachos + tablas de puesto),
--     sin importar la ruta ni lo que alcance a ver el despachador. El que se va a despachar es el viaje previos + 1.
--   * despacho_qr_reglas devuelve solo_viaje (la app lo toma en máximo 5 minutos, o al recargar).
--   * despacho_qr_auditoria (sql/181): con la regla, cuentan solo los despachos que pedían QR (el viaje N.º solo_viaje
--     del carro ese día, por hora real de despacho) y los que tienen lectura igual.
-- Se aplica con solo_viaje = null (la app publicada sigue igual) y se PRENDE después de publicar la v366:
--   update public.despacho_qr_config set solo_viaje = 2, solo_viaje_desde = now(), actualizado_en = now(), actualizado_por = 'sql/182' where id = 1;
-- Para volver al QR en todos los viajes: update public.despacho_qr_config set solo_viaje = null, actualizado_en = now() where id = 1;
-- Al aplicar: una petición, con lock_timeout (despacho_qr_config la lee la app cada 5 minutos).

-- ---------------------------------------------------------------- 1) la regla
alter table public.despacho_qr_config add column if not exists solo_viaje smallint check (solo_viaje between 1 and 30);
alter table public.despacho_qr_config add column if not exists solo_viaje_desde timestamptz;

-- lo que la app necesita saber: desde cuándo, si va el carnet, en qué viaje (null = todos) y la hora del servidor
create or replace function public.despacho_qr_reglas()
returns jsonb language sql stable security definer set search_path to 'public'
as $$
  select coalesce(
    (select jsonb_build_object('ok', true, 'desde', c.obligatorio_desde, 'carnet', c.carnet, 'solo_viaje', c.solo_viaje, 'ahora', now())
       from public.despacho_qr_config c where c.id = 1),
    jsonb_build_object('ok', true, 'desde', null, 'carnet', true, 'solo_viaje', null, 'ahora', now()));
$$;
revoke all on function public.despacho_qr_reglas() from public, anon;
grant execute on function public.despacho_qr_reglas() to authenticated;

-- ---------------------------------------------------------------- 2) ¿qué viaje es este bus hoy?
-- Cuenta los viajes ya hechos (SI, DESPACHADO, PENDIENTE SONAR, REALIZADO) del carro ese día en todas las tablas,
-- sin contar la fila que se está despachando (si se reintenta un PENDIENTE SONAR, no se cuenta a sí misma).
create or replace function public.despacho_viajes_bus(p_vehiculo_id bigint, p_fecha date, p_tabla text default null, p_fila_id text default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare t record; n bigint; v_total bigint := 0;
begin
  if auth.uid() is null or not (public.es_admin() or public.es_despachador()) then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if p_vehiculo_id is null or p_fecha is null then
    return jsonb_build_object('ok', false, 'error', 'Falta el bus o la fecha.');
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
end $$;
revoke all on function public.despacho_viajes_bus(bigint, date, text, text) from public, anon;
grant execute on function public.despacho_viajes_bus(bigint, date, text, text) to authenticated;

-- ---------------------------------------------------------------- 3) el tablero de control (reemplaza el de sql/181)
create or replace function public.despacho_qr_auditoria(p_desde date, p_hasta date, p_rutas bigint[] default null, p_ruta bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
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
end $$;
revoke all on function public.despacho_qr_auditoria(date, date, bigint[], bigint) from public, anon;
grant execute on function public.despacho_qr_auditoria(date, date, bigint[], bigint) to authenticated;

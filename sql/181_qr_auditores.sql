-- 181: LOS AUDITORES (monitores de control) VEN LAS LECTURAS DEL QR DE SUS RUTAS (12/11/2026).
--
-- Pedido: "los auditores de control podrían ver cómo van esos escaneos desde su aplicativo, eso es
-- importante, recuerda que ellos son los que auditan". Decisiones del usuario (12/11):
--   * Cada monitor ve SOLO SUS RUTAS (rutas_auditor(), igual que en Despachos). Administración ve todas.
--   * El monitor puede abrir las FOTOS del bus de sus rutas (hasta hoy, solo administración).
--   * Se hace en LOCAL primero; se publica cuando el usuario dé el OK.
--
-- Lo que trae (despacho_qr_auditoria):
--   * por ruta: despachos hechos, cuántos con el QR del bus, el carnet y la foto, y por qué no;
--   * por despachador, y la lista "para revisar" (sin QR, sin carnet, sin foto, lejos del bus, QR o
--     carnet que no era, despachado sin pasar por el QR);
--   * la prueba de que el "sin sticker" o el "sin carnet" no era cierto: el QR de ESE bus (o el carnet
--     de ESE conductor) sí se leyó en otro despacho, ±7 días.
-- No escribe nada. Las 10 tablas de despacho no se tocan.
--
-- Al aplicar: una petición por parte (las funciones; el índice; la política de storage), cada una con
-- lock_timeout, porque despacho_qr y storage.objects se usan en cada despacho (ver sql/179).

-- ---------------------------------------------------------------- 1) el tablero
create or replace function public.despacho_qr_auditoria(p_desde date, p_hasta date, p_rutas bigint[] default null, p_ruta bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_admin boolean := public.es_admin();
  v_scope bigint[];
  v_inicio timestamp;
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
  -- los despachos HECHOS de todas las tablas (Despachos + tablas de puesto activas)
  select string_agg(format(
    $f$select %L::text tabla, %L::text tabla_label, x.id::text fila_id, x.fecha, coalesce(x.hora_real_despacho, x.hora) hora,
              x.ruta_id, x.vehiculo_id veh_fila
         from public.%I x
        where x.fecha between $1 and $2
          and upper(coalesce(x.estado_despacho, '')) in ('SI', 'DESPACHADO', 'PENDIENTE SONAR', 'REALIZADO')
          and ($3::bigint[] is null or x.ruta_id = any ($3))
          and x.fecha + coalesce(x.hora_real_despacho, x.hora, time '23:59') >= $5$f$, t.tabla, t.label, t.tabla), ' union all ')
    into v_union
    from (select 'despachos' tabla, 'Despachos' label union all
          select tabla, label from public.tablas_despacho where activo) t;

  execute format($m$
    with filas as (%s),
    q as (   -- la última lectura de cada fila
      select distinct on (q.tabla, q.fila_id) q.*
        from public.despacho_qr q
       where q.fecha between $1 - 1 and $2 + 1
       order by q.tabla, q.fila_id, q.creado_en desc),
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
  into v_res using p_desde, p_hasta, v_scope, p_ruta, v_inicio;
  return v_res;
end $$;
revoke all on function public.despacho_qr_auditoria(date, date, bigint[], bigint) from public, anon;
grant execute on function public.despacho_qr_auditoria(date, date, bigint[], bigint) to authenticated;

-- ---------------------------------------------------------------- 2) ¿puede ver esta foto?
-- Administración, todas; el monitor, solo las de despachos de SUS rutas. La usa la política de storage.
create or replace function public.qr_foto_visible(p_name text)
returns boolean language plpgsql stable security definer set search_path to 'public'
as $$
declare v_tabla text; v_fila text; v_ruta bigint;
begin
  if public.es_admin() then return true; end if;
  if not public.es_auditor() then return false; end if;
  select q.tabla, q.fila_id into v_tabla, v_fila from public.despacho_qr q where q.foto_path = p_name order by q.id desc limit 1;
  if v_tabla is null or v_fila is null then return false; end if;
  if not (v_tabla = 'despachos' or exists (select 1 from public.tablas_despacho where tabla = v_tabla)) then return false; end if;
  execute format('select ruta_id from public.%I where id::text = $1', v_tabla) into v_ruta using v_fila;
  return v_ruta is not null and v_ruta = any (public.rutas_auditor());
end $$;
revoke all on function public.qr_foto_visible(text) from public, anon;
grant execute on function public.qr_foto_visible(text) to authenticated;

-- ---------------------------------------------------------------- 3) índice para buscar la foto (aparte, con lock_timeout)
-- set lock_timeout = '3s';
create index if not exists despacho_qr_foto on public.despacho_qr (foto_path) where foto_path is not null;

-- ---------------------------------------------------------------- 4) el monitor abre las fotos de sus rutas (aparte, con lock_timeout)
-- set lock_timeout = '3s';
drop policy if exists despacho_fotos_sel_aud on storage.objects;
create policy despacho_fotos_sel_aud on storage.objects for select to authenticated
  using (bucket_id = 'despacho-fotos' and (select public.es_auditor()) and public.qr_foto_visible(name));

-- 186: CAMBIO DE CONDUCTOR EN TODOS LOS VIAJES DEL 3.º EN ADELANTE (12/11/2026).
--
-- Pedido: "hagamos la comparación, porque se tiene que hacer que con la lectura correcta del carro se despache, eso es vital;
-- entre más fácil, mejor". La sql/185 solo marcaba el cambio de conductor en los despachos hechos leyendo el QR del bus;
-- ahora la BASE compara TODOS los viajes después del del QR (hechos con el QR o con la lista) contra el conductor del 2.º
-- viaje de ese bus ese día, y cuenta cuántos se despacharon leyendo el QR del bus.
--   * El conductor del 2.º viaje: la lectura del viaje del QR de ese bus ese día (el carnet, o el que eligieron de la lista
--     porque no tenía); si no hay, la lectura de la fila N.º solo_viaje (por hora de despacho); si no, el que quedó en esa fila.
--   * Con quién salió: el conductor que quedó en la fila despachada (la fila guarda el NOMBRE; se busca su código en SONAR).
--   * Es cambio si el NOMBRE es otro (sin tildes ni espacios) Y el CÓDIGO de SONAR (dr_id) también es otro (o falta). Así no
--     cuentan: la misma persona a la que SONAR le corrigió el nombre (pasó el 12/11 con 4 viajes: mismo código), ni la que
--     está dos veces en SONAR con el mismo nombre (pasó con 1: mismo nombre, otro código). Igual en el despacho rápido (185).
--   * "Con el QR del bus": la fila tiene un despacho rápido registrado (despacho_qr_rapido).
--   * Cuenta desde que rige la regla del viaje (despacho_qr_config.solo_viaje_desde); sin la regla no devuelve nada.
-- Reemplaza despacho_qr_rapido_resumen (misma firma; solo la usa la pantalla LOCAL, la app publicada no la llama).

create or replace function public.despacho_qr_rapido_resumen(p_desde date, p_hasta date, p_rutas bigint[] default null, p_ruta bigint default null)
returns jsonb language plpgsql stable security definer set search_path to 'public'
as $$
declare
  v_admin boolean := public.es_admin();
  v_scope bigint[];
  v_solo int; v_desde timestamptz; v_inicio timestamp;
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
  select c.solo_viaje, c.solo_viaje_desde into v_solo, v_desde from public.despacho_qr_config c where c.id = 1;
  if v_solo is null then
    return jsonb_build_object('ok', true, 'sin_regla', true);
  end if;
  v_desde := coalesce(v_desde, '-infinity'::timestamptz);
  v_inicio := case when v_desde = '-infinity'::timestamptz then '-infinity'::timestamp else v_desde at time zone 'America/Bogota' end;
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
             exists (select 1 from public.despacho_qr_rapido qr where qr.tabla = k.tabla and qr.fila_id = k.fila_id) con_qr,
             coalesce(d.nombre, 'Sin despachador') despachador
        from rk k
        left join v2 on v2.fecha = k.fecha and v2.veh = k.veh
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
    xc as (   -- ¿cambió? el nombre (sin tildes ni espacios) es otro Y el código de SONAR también (o falta)
      select xs.*, (v2_nombre is not null and cond_nombre is not null
                    and public._norm_alnum(v2_nombre) <> public._norm_alnum(cond_nombre)
                    and (v2_dr_id is null or cond_dr_id is null or v2_dr_id <> cond_dr_id)) cambio
        from xs)
    select jsonb_build_object('ok', true, 'solo_viaje', $5,
      'desde_regla', case when $7 > '-infinity'::timestamp then to_char($7, 'DD/MM/YYYY HH24:MI') end,
      'total', count(*),
      'con_qr', count(*) filter (where con_qr),
      'con_lista', count(*) filter (where not con_qr),
      'con_v2', count(*) filter (where v2_nombre is not null),
      'sin_v2', count(*) filter (where v2_nombre is null),
      'sin_conductor', count(*) filter (where cond_nombre is null),
      'cambios', count(*) filter (where cambio),
      'cambios_con_qr', count(*) filter (where cambio and con_qr),
      'cambios_sin_qr', count(*) filter (where cambio and not con_qr),
      'qr_otro_bus', (select count(*) from public.despacho_qr_rapido q join xs on xs.tabla = q.tabla and xs.fila_id = q.fila_id where q.coincide is false),
      'por_despachador', (select coalesce(jsonb_agg(z order by z.pct_qr, z.viajes desc), '[]'::jsonb) from (
          select despachador, count(*) viajes, count(*) filter (where con_qr) con_qr, count(*) filter (where cambio) cambios,
                 round(100.0 * count(*) filter (where con_qr) / count(*), 1) pct_qr
            from xc group by 1) z),
      'cambios_lista', (select coalesce(jsonb_agg(jsonb_build_object(
            'fecha', y.fecha, 'hora', to_char(y.hora, 'HH24:MI'), 'ruta', y.ruta, 'tabla', y.tabla_label, 'movil', y.movil, 'viaje', y.n,
            'v2_nombre', y.v2_nombre, 'v2_origen', y.v2_origen, 'v2_hora', y.v2_hora, 'cond_nombre', y.cond_nombre,
            'con_qr', y.con_qr, 'despachador', y.despachador) order by y.fecha desc, y.hora desc), '[]'::jsonb)
          from (select * from xc where cambio order by fecha desc, hora desc limit 400) y))
      from xc
  $m$, v_union)
  into v_res using p_desde, p_hasta, v_scope, p_ruta, v_solo, v_desde, v_inicio;
  return v_res;
end $$;
revoke all on function public.despacho_qr_rapido_resumen(date, date, bigint[], bigint) from public, anon;
grant execute on function public.despacho_qr_rapido_resumen(date, date, bigint[], bigint) to authenticated;

-- ---------------------------------------------------------------- el despacho rápido decide el cambio igual (reemplaza la de sql/185)
create or replace function public.despacho_qr_rapido_registrar(
  p_tabla text, p_fila_id text, p_vehiculo_id bigint, p_qr_texto text, p_leido_en timestamptz,
  p_viaje integer, p_cond_dr_id text, p_resultado text, p_regid text default null)
returns jsonb language plpgsql volatile security definer set search_path to 'public'
as $$
declare
  v_uid uuid := auth.uid();
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_hoy date := (now() at time zone 'America/Bogota')::date;
  v_movil text; v_existe boolean; v_ruta bigint; v_desp bigint; v_v2 jsonb; v_cond_nombre text; v_cambio boolean; v_id bigint;
begin
  if v_uid is null or not (public.es_admin() or public.es_despachador()) or not public.es_sesion_vigente() then
    return jsonb_build_object('ok', false, 'error', 'Esta cuenta no despacha.');
  end if;
  if coalesce(btrim(p_qr_texto), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Falta el texto del QR.');
  end if;
  if p_viaje is not null and (p_viaje < 1 or p_viaje > 60) then
    return jsonb_build_object('ok', false, 'error', 'Número de viaje inválido.');
  end if;
  -- la tabla: 'despachos', una tabla de despacho registrada, o 'mapa' (despacho sin fila)
  if p_tabla = 'mapa' then
    if p_fila_id is not null then return jsonb_build_object('ok', false, 'error', 'Un despacho del mapa no tiene fila.'); end if;
  elsif p_tabla = 'despachos' or exists (select 1 from public.tablas_despacho where tabla = p_tabla) then
    execute format('select true, x.ruta_id from public.%I x where x.id::text = $1', p_tabla) into v_existe, v_ruta using p_fila_id;
    if not coalesce(v_existe, false) then return jsonb_build_object('ok', false, 'error', 'No existe esa fila.'); end if;
  else
    return jsonb_build_object('ok', false, 'error', 'Tabla inválida.');
  end if;
  select btrim(numero) into v_movil from public.vehiculos where id = p_vehiculo_id;
  if v_movil is null then return jsonb_build_object('ok', false, 'error', 'Bus inválido.'); end if;
  select d.id into v_desp from public.despachadores d join public.perfiles p on lower(btrim(d.nombre)) = lower(btrim(p.nombre))
   where p.id = v_uid limit 1;
  if p_cond_dr_id is not null then
    select btrim(nombre) into v_cond_nombre from public.conductores_sonar where dr_id = p_cond_dr_id limit 1;
  end if;
  -- el conductor del 2.º viaje lo busca la base otra vez, y ella decide si cambió
  v_v2 := public._conductor_viaje2(p_vehiculo_id, v_hoy);
  -- es cambio si el nombre es otro Y el código de SONAR también (o falta): ni el nombre corregido ni el conductor repetido en SONAR
  v_cambio := coalesce((v_v2 ->> 'encontrado')::boolean, false) and p_cond_dr_id is not null
    and public._norm_alnum(v_cond_nombre) is distinct from public._norm_alnum(v_v2 ->> 'nombre')
    and ((v_v2 ->> 'dr_id') is null or p_cond_dr_id is distinct from (v_v2 ->> 'dr_id'));
  insert into public.despacho_qr_rapido (fecha, tabla, fila_id, ruta_id, vehiculo_id, movil, viaje, qr_texto, coincide, leido_en,
                                         v2_origen, v2_dr_id, v2_nombre, v2_hora, cond_dr_id, cond_nombre, cambio_conductor,
                                         resultado, sonar_regid, despachador_id, email, uid)
  values (v_hoy, p_tabla, p_fila_id, v_ruta, p_vehiculo_id, v_movil, p_viaje, left(btrim(p_qr_texto), 300),
          public._qr_es_del_bus(p_qr_texto, p_vehiculo_id), coalesce(p_leido_en, now()),
          case when coalesce((v_v2 ->> 'encontrado')::boolean, false) then v_v2 ->> 'origen' end,
          v_v2 ->> 'dr_id', v_v2 ->> 'nombre', v_v2 ->> 'hora', p_cond_dr_id, v_cond_nombre, coalesce(v_cambio, false),
          left(p_resultado, 40), p_regid, v_desp, v_email, v_uid)
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'cambio_conductor', coalesce(v_cambio, false));
end $$;
revoke all on function public.despacho_qr_rapido_registrar(text, text, bigint, text, timestamptz, integer, text, text, text) from public, anon;
grant execute on function public.despacho_qr_rapido_registrar(text, text, bigint, text, timestamptz, integer, text, text, text) to authenticated;

-- 159: Seguridad vial NO ve "📈 Cumplimiento y análisis".
--
-- Seguridad vial tiene los permisos de operaciones (sql/156) y su módulo propio (sql/157-158),
-- pero el usuario pidió (04/11/2026): "quítale toda la parte de análisis y cumplimiento a
-- seguridad vial, ellos no deben de ver eso". En la app se quita del menú; aquí se cierra en la
-- base, para que tampoco se pueda pedir el dato por fuera del menú.
--
-- es_operaciones_analisis() = es_operaciones() menos las cuentas de seguridad vial. Reemplaza a
-- es_operaciones() SOLO en lo que alimenta ese grupo del menú: frecuencia por franja,
-- productividad por carro, top de movilización (carro y ruta), pasajeros (y los viajes del
-- carro que la acompañan), el control en vía de la Av. Oriental (control_vivo_traer) y la tabla
-- pasajeros_dia. Lo demás de operaciones (usuarios, parque, desbloqueos, licencias, taller,
-- restricciones, Resumen) sigue igual para seguridad vial.
-- En la app el mismo criterio es isOperacionesAnalisis() (app.js): cambiar los dos juntos.
-- Las funciones de abajo son copia exacta de las que hay en la base (04/11/2026), salvo esa llamada.

create or replace function public.es_operaciones_analisis()
 returns boolean language sql stable security definer set search_path to 'public'
as $function$
  select public.es_operaciones()
     and not ( public.es_despachador()
               and public._correo_seguridad_vial(auth.email()) );
$function$;
revoke all on function public.es_operaciones_analisis() from public;
grant execute on function public.es_operaciones_analisis() to anon, authenticated;

-- Misma regla de siempre con es_operaciones_analisis(); las funciones van envueltas en (select …)
-- para que se evalúen una vez y no por cada fila (ver sql/56: sin eso, el afiliado se cortaba).
alter policy pax_dia_sel on public.pasajeros_dia
  using ((select public.es_admin()) or (select public.es_operaciones_analisis())
         or ((select public.es_afiliado()) and trim(both from movil) = any ((select public.mis_moviles_afiliado())::text[])));

CREATE OR REPLACE FUNCTION public.frecuencia_ruta_franja(p_ruta_id bigint, p_desde date, p_hasta date, p_dia_tipo text DEFAULT 'habil'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_dias int := 0; v_total int := 0; v_res jsonb;
begin
  if not (public.es_admin() or public.es_auditor() or public.es_afiliado() or public.es_operaciones_analisis()) then
    raise exception 'No autorizado.'; end if;
  if p_ruta_id is null then return jsonb_build_object('ok', false, 'error', 'Falta la ruta.'); end if;
  if p_desde is null or p_hasta is null then return jsonb_build_object('ok', false, 'error', 'Falta el rango de fechas.'); end if;

  with dias as (
    select distinct d.fecha
    from public.despachos d
    where d.ruta_id = p_ruta_id and d.fecha between p_desde and p_hasta and d.hora is not null
      and case p_dia_tipo
            when 'sabado'  then (extract(isodow from d.fecha) = 6 and not public.es_festivo(d.fecha))
            when 'domingo' then (extract(isodow from d.fecha) = 7 or public.es_festivo(d.fecha))
            else                (extract(isodow from d.fecha) between 1 and 5 and not public.es_festivo(d.fecha))
          end
  ),
  base as (
    select d.hora, vp.numero as movil,
           (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null) as realizado
    from public.despachos d join dias on dias.fecha = d.fecha
    left join public.vehiculos vp on vp.id = d.vehiculo_programado_id
    where d.ruta_id = p_ruta_id and d.hora is not null
  ),
  -- móviles despachados en cada franja (cuántas veces y cuántas realizó)
  franja_movil as (
    select (extract(hour from hora)::int * 60 + extract(minute from hora)::int) / 20 as b,
           coalesce(movil, '(sin carro)') as movil,
           count(*) as veces, count(*) filter (where realizado) as realiz
    from base group by 1, 2
  ),
  franjas as (
    select b, sum(veces)::int as c,
           jsonb_agg(jsonb_build_object('movil', movil, 'veces', veces, 'realiz', realiz)
                     order by veces desc, movil) as carros
    from franja_movil group by b
  )
  select
    (select count(*) from dias),
    (select coalesce(sum(veces), 0)::int from franja_movil),
    (select coalesce(jsonb_agg(jsonb_build_object(
        'franja', to_char(make_time((b * 20) / 60, (b * 20) % 60, 0), 'HH24:MI'),
        'ini_min', b * 20,
        'despachos_total', c,
        'despachos_prom', round(c::numeric / nullif((select count(*) from dias), 0), 2),
        'headway_min', round(20.0 * (select count(*) from dias) / nullif(c, 0), 1),
        'carros', carros
      ) order by b), '[]'::jsonb) from franjas)
  into v_dias, v_total, v_res;

  if v_dias = 0 then
    return jsonb_build_object('ok', true, 'ruta_id', p_ruta_id, 'dia_tipo', p_dia_tipo,
      'desde', p_desde, 'hasta', p_hasta, 'dias', 0, 'franjas', '[]'::jsonb,
      'nota', 'No hay despachos programados de esta ruta para ese día-tipo en el rango elegido.');
  end if;

  return jsonb_build_object('ok', true, 'ruta_id', p_ruta_id, 'dia_tipo', p_dia_tipo,
    'desde', p_desde, 'hasta', p_hasta, 'dias', v_dias,
    'despachos_prom_dia', round(v_total::numeric / v_dias, 1),
    'total_despachos', v_total,
    'franjas', v_res);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

CREATE OR REPLACE FUNCTION public.productividad_carro(p_ruta_id bigint, p_desde date, p_hasta date, p_dia_tipo text DEFAULT 'habil'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_res     jsonb;
  -- 🔧 Fuera justificado: el carro/conductor no podía operar (reportado).
  v_justif  text[] := array['TALLER','CDA','INCAPACIDAD EPS','CITA MEDICA EPS',
                            'RESTRICCION MEDICA','RESTRICCION OPERACIONAL','VACACIONES',
                            'SUSPENDIDO','REQUERIMIENTO EMPRESA'];
  -- 🔁 Reasignado: la capacidad se movió a otro lado, no se perdió.
  v_reasig  text[] := array['CAMBIO DE TABLA','CAMBIO DE RUTA','REEMPLAZA OTRO VEHICULO',
                            'CONDUCTOR EN OTRA RUTA','CONDUCTOR EN OTRO VEHICULO','ADELANTADO'];
  -- 🌧️ Externo: no imputable a la operación.
  v_externo text[] := array['CONGESTION VEHICULAR'];
  -- Rendimiento: el alcance por vehículo del afiliado se calcula UNA sola vez (no fila
  -- por fila). v_ids = null → admin/auditor (ven todo); v_ids = sus vehículos → afiliado.
  v_ids     bigint[];
begin
  if not (public.es_admin() or public.es_auditor() or public.es_afiliado() or public.es_operaciones_analisis()) then
    raise exception 'No autorizado.';
  end if;
  v_ids := case when (public.es_admin() or public.es_auditor() or public.es_operaciones_analisis()) then null
                else public.mis_vehiculo_ids_afiliado() end;

  with base as (
    select d.fecha, d.hora, d.estado,
           vp.numero as movil,
           (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null) as realizado,
           upper(btrim(coalesce(d.estado,''))) as nov,
           (extract(hour from d.hora)::int * 60 + extract(minute from d.hora)::int) / 20 as fbin
    from public.despachos d
    join public.vehiculos vp on vp.id = d.vehiculo_programado_id
    where (p_ruta_id is null or d.ruta_id = p_ruta_id)
      and d.fecha between p_desde and p_hasta
      and d.hora is not null
      and d.vehiculo_programado_id is not null
      and coalesce(upper(btrim(d.tipo)), '') <> 'LIBRE'   -- solo TABLA (turno fijo); LIBRE va aparte
      and (v_ids is null or d.vehiculo_programado_id = any(v_ids))  -- afiliado: solo sus carros (filtro sobre la columna, sin llamar la función por fila)
      and case p_dia_tipo
            when 'sabado'  then (extract(isodow from d.fecha) = 6 and not public.es_festivo(d.fecha))
            when 'domingo' then (extract(isodow from d.fecha) = 7 or public.es_festivo(d.fecha))
            else                (extract(isodow from d.fecha) between 1 and 5 and not public.es_festivo(d.fecha))
          end
  ),
  -- Refuerzos LIBRE (despacho libre): sin carro programado, se asignan a demanda.
  -- El carro real es vehiculo_id. Solo cuentan los realizados.
  libre_base as (
    select vr.numero as movil,
           (extract(hour from d.hora)::int * 60 + extract(minute from d.hora)::int) / 20 as fbin
    from public.despachos d
    join public.vehiculos vr on vr.id = d.vehiculo_id
    where (p_ruta_id is null or d.ruta_id = p_ruta_id)
      and d.fecha between p_desde and p_hasta
      and d.hora is not null
      and upper(btrim(d.tipo)) = 'LIBRE'
      and (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null)
      and (v_ids is null or d.vehiculo_id = any(v_ids))  -- afiliado: solo sus carros (usa idx_despachos_vehiculo)
      and case p_dia_tipo
            when 'sabado'  then (extract(isodow from d.fecha) = 6 and not public.es_festivo(d.fecha))
            when 'domingo' then (extract(isodow from d.fecha) = 7 or public.es_festivo(d.fecha))
            else                (extract(isodow from d.fecha) between 1 and 5 and not public.es_festivo(d.fecha))
          end
  ),
  libre_franja as (select fbin, count(*) as libre from libre_base group by fbin),
  libre_carro  as (select movil, count(*) as refuerzos from libre_base group by movil),
  -- ¿El carro (físico) laboró ese día en ALGO (tabla o libre, en cualquier ruta)?
  -- Si sí y saltó un turno de tabla → no se enturnó; si no hizo nada → no laboró.
  dia_laboro as (
    select distinct vr.numero as movil, d.fecha
    from public.despachos d
    join public.vehiculos vr on vr.id = d.vehiculo_id
    where d.fecha between p_desde and p_hasta
      and (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null)
      and (v_ids is null or d.vehiculo_id = any(v_ids))  -- afiliado: solo sus carros (usa idx_despachos_vehiculo)
      and case p_dia_tipo
            when 'sabado'  then (extract(isodow from d.fecha) = 6 and not public.es_festivo(d.fecha))
            when 'domingo' then (extract(isodow from d.fecha) = 7 or public.es_festivo(d.fecha))
            else                (extract(isodow from d.fecha) between 1 and 5 and not public.es_festivo(d.fecha))
          end
  ),
  withday as (
    select b.*,
           (dl.movil is not null) as laboro_dia
    from base b
    left join dia_laboro dl on dl.movil = b.movil and dl.fecha = b.fecha
  ),
  clasif as (
    select w.*,
      case
        when w.realizado           then 'cumplio'
        when w.nov = any(v_justif)  then 'justificado'
        when w.nov = any(v_reasig)  then 'reasignado'
        when w.nov = any(v_externo) then 'externo'
        when not w.laboro_dia       then 'no_laboro'   -- no hizo NADA ese día (ni libre)
        else                             'no_enturno'  -- laboró (tabla/libre) pero saltó este turno
      end as categoria
    from withday w
  ),
  -- Conteos por (carro, franja)
  pcf as (
    select movil, fbin,
      count(*)                                          as prog,
      count(*) filter (where categoria = 'cumplio')     as realiz,
      count(*) filter (where categoria in ('justificado','reasignado','externo')) as justif,
      count(*) filter (where categoria = 'no_laboro')   as no_laboro,
      count(*) filter (where categoria = 'no_enturno')  as no_enturno
    from clasif
    group by movil, fbin
  ),
  franjas_carro as (
    select movil, jsonb_agg(jsonb_build_object(
        'ini_min', fbin * 20,
        'franja',  to_char(make_time(((fbin*20)/60)::int, ((fbin*20)%60)::int, 0), 'HH24:MI'),
        'prog', prog, 'realiz', realiz, 'justif', justif,
        'no_laboro', no_laboro, 'no_enturno', no_enturno) order by fbin) as fr
    from pcf group by movil
  ),
  -- Resumen por carro
  porcarro as (
    select movil,
      count(*)                                          as programados,
      count(*) filter (where categoria = 'cumplio')     as realizados,
      count(*) filter (where categoria = 'justificado') as justificado,
      count(*) filter (where categoria = 'reasignado')  as reasignado,
      count(*) filter (where categoria = 'externo')     as externo,
      count(*) filter (where categoria = 'no_laboro')   as no_laboro,
      count(*) filter (where categoria = 'no_enturno')  as no_enturno,
      count(distinct fecha)                             as dias_prog,
      count(distinct fecha) filter (where not laboro_dia) as dias_no_laboro,
      case when p_ruta_id is not null then
        coalesce(jsonb_agg(jsonb_build_object(
            'fecha', fecha, 'hora', to_char(hora, 'HH24:MI'),
            'novedad', nullif(estado, ''), 'categoria', categoria)
            order by fecha, hora) filter (where categoria <> 'cumplio'), '[]'::jsonb)
      else '[]'::jsonb end as faltantes
    from clasif
    group by movil
  ),
  carros as (
    select
      p.movil, p.programados, p.realizados, p.justificado, p.reasignado, p.externo,
      p.no_laboro, p.no_enturno, p.dias_prog, p.dias_no_laboro, p.faltantes,
      coalesce(fc.fr, '[]'::jsonb) as franjas,
      coalesce(lc.refuerzos, 0) as refuerzos,
      case when p.no_enturno > 0 then 'no_enturno'
           when p.no_laboro  > 0 then 'no_laboro'
           when p.realizados = 0 then 'fuera'
           else 'cumplio' end as estado
    from porcarro p
    left join franjas_carro fc on fc.movil = p.movil
    left join libre_carro   lc on lc.movil = p.movil
  ),
  -- Resumen por franja para toda la ruta (tabla) + refuerzos LIBRE
  franjas_ruta_pre as (
    select fbin, sum(prog) as prog, sum(realiz) as realiz,
           sum(no_laboro) as no_laboro, sum(no_enturno) as no_enturno
    from pcf group by fbin
  ),
  franja_bins as (
    select fbin from franjas_ruta_pre
    union
    select fbin from libre_franja
  ),
  franjas_ruta as (
    select jsonb_agg(jsonb_build_object(
        'ini_min', b.fbin * 20,
        'franja',  to_char(make_time(((b.fbin*20)/60)::int, ((b.fbin*20)%60)::int, 0), 'HH24:MI'),
        'prog', coalesce(t.prog, 0), 'realiz', coalesce(t.realiz, 0),
        'no_laboro', coalesce(t.no_laboro, 0), 'no_enturno', coalesce(t.no_enturno, 0),
        'libre', coalesce(l.libre, 0)) order by b.fbin) as fr
    from franja_bins b
    left join franjas_ruta_pre t on t.fbin = b.fbin
    left join libre_franja     l on l.fbin = b.fbin
  )
  select jsonb_build_object(
    'ok',       true,
    'ruta_id',  p_ruta_id,
    'dia_tipo', p_dia_tipo,
    'desde',    p_desde,
    'hasta',    p_hasta,
    'resumen', (select jsonb_build_object(
        'carros',           count(*),
        'viajes_prog',      coalesce(sum(programados), 0),
        'viajes_realiz',    coalesce(sum(realizados), 0),
        'viajes_justif',    coalesce(sum(justificado), 0),
        'viajes_reasig',    coalesce(sum(reasignado), 0),
        'viajes_externo',   coalesce(sum(externo), 0),
        'viajes_no_laboro', coalesce(sum(no_laboro), 0),
        'viajes_no_enturno',coalesce(sum(no_enturno), 0),
        'carros_no_laboro', count(*) filter (where no_laboro  > 0 and no_enturno = 0),
        'carros_no_enturno',count(*) filter (where no_enturno > 0),
        'viajes_libre',     (select coalesce(sum(libre), 0) from libre_franja)) from carros),
    'franjas_ruta', (select coalesce(fr, '[]'::jsonb) from franjas_ruta),
    'carros', (select coalesce(jsonb_agg(jsonb_build_object(
        'movil', movil, 'programados', programados, 'realizados', realizados,
        'pct', round(100.0 * realizados / nullif(programados, 0), 0),
        'justificado', justificado, 'reasignado', reasignado, 'externo', externo,
        'no_laboro', no_laboro, 'no_enturno', no_enturno, 'refuerzos', refuerzos,
        'dias_prog', dias_prog, 'dias_no_laboro', dias_no_laboro,
        'estado', estado, 'franjas', franjas, 'faltantes', faltantes)
        order by (realizados + refuerzos) asc, no_enturno desc, no_laboro desc, programados desc), '[]'::jsonb)
      from carros)
  )
  into v_res;

  return v_res;
end;
$function$;

CREATE OR REPLACE FUNCTION public.top_movilizacion(p_periodo text DEFAULT 'mes'::text, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_per text; v_desde date; v_hasta date; v_afil boolean; v_ids text[];
begin
  if not (public.es_admin() or public.es_afiliado() or public.es_operaciones_analisis()) then
    raise exception 'No autorizado.';
  end if;
  v_per := lower(coalesce(p_periodo, 'mes'));
  if v_per = 'rango' and p_desde is not null and p_hasta is not null then
    v_desde := p_desde;
    v_hasta := least(p_hasta, current_date - 1);
    if v_desde > v_hasta then v_desde := v_hasta; end if;
    if v_hasta - v_desde > 92 then v_desde := v_hasta - 92; end if;
  elsif v_per = 'dia' then
    v_hasta := current_date - 1; v_desde := current_date - 1;
  elsif v_per = 'semana' then
    v_hasta := current_date - 1; v_desde := current_date - 7;
  else
    v_per := 'mes'; v_hasta := current_date - 1; v_desde := current_date - 30;
  end if;
  v_afil := public.es_afiliado() and not public.es_admin();
  v_ids  := case when v_afil then public.mis_moviles_afiliado() else null end;

  return (
    with base as (  -- pasajeros por carro en el periodo (afiliado: solo sus móviles)
      select trim(pd.movil) as movil,
             sum(pd.subidas)::int as subidas, sum(pd.bajadas)::int as bajadas,
             count(distinct pd.fecha)::int as dias
      from public.pasajeros_dia pd
      where pd.fecha between v_desde and v_hasta
        and (v_ids is null or trim(pd.movil) = any(v_ids))
      group by trim(pd.movil)
    ),
    vc as (  -- viajes realizados por carro en el periodo (todas las rutas/fuentes)
      select dr.movil, count(*)::int as viajes
      from public._despachos_realizados(v_desde, v_hasta) dr
      group by dr.movil
    )
    select jsonb_build_object(
      'ok', true, 'periodo', v_per, 'desde', v_desde, 'hasta', v_hasta,
      'resumen', jsonb_build_object(
        'moviles',        (select count(*) from base),
        'subidas_total',  (select coalesce(sum(subidas), 0) from base),
        'viajes_total',   (select coalesce(sum(vc.viajes), 0) from vc where vc.movil in (select movil from base)),
        'dias_con_datos', (select count(distinct fecha) from public.pasajeros_dia
                            where fecha between v_desde and v_hasta
                              and (v_ids is null or trim(movil) = any(v_ids)))),
      'carros', (
        select coalesce(jsonb_agg(x order by x.subidas desc), '[]'::jsonb) from (
          select b.movil,
                 (select v.placa from public.vehiculos v where trim(v.numero) = b.movil limit 1) as placa,
                 b.subidas, b.bajadas, b.dias,
                 round(b.subidas::numeric / nullif(b.dias,0), 0) as prom_dia,
                 coalesce(vc.viajes, 0) as viajes
          from base b
          left join vc on vc.movil = b.movil
        ) x)
    )
  );
end $function$;

CREATE OR REPLACE FUNCTION public.top_ruta(p_periodo text DEFAULT 'mes'::text, p_desde date DEFAULT NULL::date, p_hasta date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_per text; v_desde date; v_hasta date;
begin
  if not (public.es_admin() or public.es_afiliado() or public.es_operaciones_analisis()) then
    raise exception 'No autorizado.';
  end if;
  v_per := lower(coalesce(p_periodo, 'mes'));
  if v_per = 'rango' and p_desde is not null and p_hasta is not null then
    v_desde := p_desde;
    v_hasta := least(p_hasta, current_date - 1);           -- hoy queda incompleto
    if v_desde > v_hasta then v_desde := v_hasta; end if;
    if v_hasta - v_desde > 92 then v_desde := v_hasta - 92; end if;   -- tope 3 meses
  elsif v_per = 'dia' then
    v_hasta := current_date - 1; v_desde := current_date - 1;         -- ayer
  elsif v_per = 'semana' then
    v_hasta := current_date - 1; v_desde := current_date - 7;         -- compat
  else
    v_per := 'mes'; v_hasta := current_date - 1; v_desde := current_date - 30;
  end if;

  return (
    with pax as (  -- pasajeros por carro/día en el periodo (toda la flota)
      select trim(pd.movil) as movil, pd.fecha, pd.subidas, pd.bajadas
      from public.pasajeros_dia pd
      where pd.fecha between v_desde and v_hasta
    ),
    disp as (      -- viajes realizados por (carro, día, ruta) de TODAS las fuentes (incluye TABLAS)
      select dr.movil, dr.fecha, dr.ruta, count(*)::numeric as viajes
      from public._despachos_realizados(v_desde, v_hasta) dr
      group by dr.movil, dr.fecha, dr.ruta
    ),
    tot as (       -- total de viajes del carro en el día (denominador del reparto)
      select movil, fecha, sum(viajes) as viajes_dia
      from disp group by movil, fecha
    ),
    attrib as (    -- pasajeros del carro-día repartidos a cada ruta por su cuota de viajes
      select disp.ruta, pax.movil, pax.fecha,
             pax.subidas * (disp.viajes / tot.viajes_dia) as sub_attr,
             pax.bajadas * (disp.viajes / tot.viajes_dia) as baj_attr
      from pax
      join disp on disp.movil = pax.movil and disp.fecha = pax.fecha
      join tot  on tot.movil  = pax.movil and tot.fecha  = pax.fecha
    ),
    agg_carro as ( -- pasajeros atribuidos por (ruta, carro) — el desglose de cada ruta
      select ruta, movil,
             round(sum(sub_attr))::int  as subidas,
             round(sum(baj_attr))::int  as bajadas,
             count(distinct fecha)::int as dias
      from attrib group by ruta, movil
    ),
    viajes_ruta as (  -- viajes realizados totales por ruta (todas las fuentes, todos los carros)
      select ruta, sum(viajes)::int as viajes from disp group by ruta
    ),
    viajes_carro as ( -- viajes por (ruta, carro)
      select ruta, movil, sum(viajes)::int as viajes from disp group by ruta, movil
    ),
    ruta_dias as (    -- días con datos por ruta
      select ruta, count(distinct fecha)::int as dias from attrib group by ruta
    ),
    agg as (          -- total de ruta = suma de sus carros (cuadra con el desglose)
      select ac.ruta, sum(ac.subidas)::int as subidas, sum(ac.bajadas)::int as bajadas,
             count(*)::int as moviles
      from agg_carro ac group by ac.ruta
    )
    select jsonb_build_object(
      'ok', true, 'periodo', v_per, 'desde', v_desde, 'hasta', v_hasta,
      'resumen', jsonb_build_object(
        'rutas',          (select count(*) from agg),
        'subidas_total',  (select coalesce(sum(subidas), 0) from agg),
        'viajes_total',   (select coalesce(sum(vr.viajes), 0) from viajes_ruta vr
                            where vr.ruta in (select ruta from agg)),
        'dias_con_datos', (select count(distinct fecha) from attrib)),
      'rutas', (
        select coalesce(jsonb_agg(x order by x.subidas desc), '[]'::jsonb) from (
          select ag.ruta, ag.subidas, ag.bajadas, ag.moviles, rd.dias,
                 coalesce(vr.viajes, 0) as viajes,
                 round(ag.subidas::numeric / nullif(rd.dias,0), 0) as prom_dia,
                 (select coalesce(jsonb_agg(c order by c.subidas desc), '[]'::jsonb) from (
                    select ac.subidas, ac.bajadas, ac.dias, coalesce(vc.viajes, 0) as viajes
                    from agg_carro ac
                    left join viajes_carro vc on vc.ruta = ac.ruta and vc.movil = ac.movil
                    where ac.ruta = ag.ruta
                  ) c) as carros
          from agg ag
          join ruta_dias rd on rd.ruta = ag.ruta
          left join viajes_ruta vr on vr.ruta = ag.ruta
        ) x)
    )
  );
end $function$;

CREATE OR REPLACE FUNCTION public.pasajeros_movil(p_movil text, p_fecha date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_user text; v_pass text; v_url text; v_ns text; v_action text;
  v_mid text; v_ini text; v_fin text; v_resp extensions.http_response; v_resp2 extensions.http_response; v_doc xml;
  v_status text; v_sub int; v_baj int; v_blq int; v_n int; v_ntrk int := 0;
  v_porhora jsonb; v_porpuerta jsonb; v_paradas jsonb;
begin
  if not (public.es_admin() or public.es_operaciones_analisis() or public.es_auditor() or (public.es_afiliado() and trim(p_movil) = any(public.mis_moviles_afiliado()))) then
    raise exception 'No autorizado para consultar este móvil.'; end if;
  if nullif(trim(p_movil),'') is null then return jsonb_build_object('ok', false, 'error', 'Móvil vacío.'); end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Fecha vacía.'); end if;

  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'El móvil '||trim(p_movil)||' no tiene Id GPS en SONAR.'); end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');
  v_action := rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter';

  -- Día Colombia [00:00, 23:59:59] en UTC (+5h): [fecha 05:00, fecha+1 04:59:59]. Mismo rango para la traza.
  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');

  -- 3.5 s por llamada: 2 llamadas caben en el statement_timeout de 8 s del rol authenticated.
  perform set_config('http.timeout_msec','3500',true);

  -- 1) Conteo de pasajeros
  select * into v_resp from extensions.http((
    'POST', rtrim(v_url,'/')||'/',
    array[extensions.http_header('SOAPAction', v_action)],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    ||'<GET_PassengersCounter xmlns="'||v_ns||'">'
    ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
    ||'<mId>'||public._xmlesc(v_mid)||'</mId>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_PassengersCounter></soap:Body></soap:Envelope>'
  )::extensions.http_request);
  if v_resp.status <> 200 then return jsonb_build_object('ok', false, 'error', 'SONAR HTTP '||v_resp.status); end if;

  v_doc := xmlparse(document v_resp.content);
  v_status := (regexp_match(v_resp.content, '(?i)<status>([^<]*)</status>'))[1];

  -- Detalle por puerta + hora UTC + hora Colombia + dirección (p_station por regex del label).
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, coalesce(dblock,0) dblock, door,
         to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') ts_utc,
         (to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') - interval '5 hours') ts_co,
         nullif((regexp_match(station, '"label"\s*:\s*"([^"]*)"'))[1], '') estacion
  from xmltable(
    xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing v_doc
    columns
      door    int  path 'n:Door',
      din     int  path 'n:DoorIn',
      dout    int  path 'n:DoorOut',
      dblock  int  path 'n:DoorBlocking',
      gps     text path '../../n:gps_UTC',
      station text path '../../n:p_station'
  );

  select count(*), coalesce(sum(din),0), coalesce(sum(dout),0), coalesce(sum(dblock),0)
    into v_n, v_sub, v_baj, v_blq from _dd;

  select jsonb_agg(jsonb_build_object('hora', h, 'subidas', s, 'bajadas', b) order by h)
    into v_porhora
    from (select extract(hour from ts_co)::int h, sum(din) s, sum(dout) b
          from _dd where ts_co is not null group by 1) t;

  -- Por puerta: subidas (DoorIn) y bajadas (DoorOut) de CADA puerta.
  select jsonb_object_agg(door::text, jsonb_build_object('subidas', s, 'bajadas', b))
    into v_porpuerta
    from (select door, sum(din) s, sum(dout) b from _dd where door is not null group by door) t;

  -- 2) Traza GPS real del bus (best-effort: si falla, se geocodifica en el cliente).
  create temp table _trk (ts timestamp, lat float, lon float) on commit drop;
  begin
    select * into v_resp2 from extensions.http((
      'POST', v_url,
      array[extensions.http_header('SOAPAction', '"'||rtrim(v_ns,'/')||'/ServiceSoap/GET_TrackerEventsHistory"')],
      'text/xml; charset=utf-8',
      '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
      ||'<GET_TrackerEventsHistory xmlns="'||v_ns||'">'
      ||'<User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
      ||'<mId>'||public._xmlesc(v_mid)||'</mId><eventID></eventID>'
      ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
      ||'</GET_TrackerEventsHistory></soap:Body></soap:Envelope>'
    )::extensions.http_request);
    if v_resp2.status = 200 then
      insert into _trk (ts, lat, lon)
      select g::timestamp, lat, lon
      from xmltable(
        xmlnamespaces('http://sonaravl.com/webservices/' as n),
        '//n:TrackerEvent' passing xmlparse(document v_resp2.content)
        columns lat float path 'n:Latitude', lon float path 'n:Longitude', g text path 'n:GpsGMT')
      where lat is not null and lon is not null and not (lat = 0 and lon = 0);
    end if;
  exception when others then
    null; -- sin traza: paradas quedan sin coord -> el cliente geocodifica (TomTom + geo_cache)
  end;
  select count(*) into v_ntrk from _trk;

  -- Paradas: agrupadas por dirección; coord = promedio de los puntos GPS reales de sus eventos
  -- (el más cercano en el tiempo, <=180 s). Respaldo: geo_cache. 'real' = vino del GPS.
  select jsonb_agg(x order by (x->>'subidas')::int desc)
    into v_paradas
    from (
      select jsonb_build_object(
        'parada', d.estacion, 'subidas', sum(d.din), 'bajadas', sum(d.dout),
        'lat', coalesce(round(avg(m.lat)::numeric, 6), g.lat),
        'lon', coalesce(round(avg(m.lon)::numeric, 6), g.lon),
        'real', (count(m.lat) > 0)
      ) x
      from _dd d
      left join lateral (
        select t.lat, t.lon
        from _trk t
        where abs(extract(epoch from (t.ts - d.ts_utc))) <= 180
        order by abs(extract(epoch from (t.ts - d.ts_utc)))
        limit 1
      ) m on true
      left join public.geo_cache g on g.direccion = d.estacion
      where d.estacion is not null
      group by d.estacion, g.lat, g.lon
      order by sum(d.din) desc
      limit 40
    ) q;

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'mid', v_mid, 'fecha', p_fecha,
    'status', coalesce(v_status,'OK'), 'registros', v_n, 'con_gps', v_ntrk,
    'subidas', v_sub, 'bajadas', v_baj, 'bloqueos', v_blq,
    'por_hora', coalesce(v_porhora, '[]'::jsonb),
    'por_puerta', coalesce(v_porpuerta, '{}'::jsonb),
    'paradas', coalesce(v_paradas, '[]'::jsonb)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

CREATE OR REPLACE FUNCTION public.viajes_movil(p_movil text, p_fecha date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'vault'
AS $function$
declare
  v_user text; v_pass text; v_url text; v_ns text;
  v_mid text; v_itid bigint; v_ruta text; v_ini text; v_fin text;
  v_resp extensions.http_response; v_resp2 extensions.http_response;
  v_viajes jsonb; v_tot_sub int := 0; v_tot_baj int := 0; v_asig_sub int := 0; v_asig_baj int := 0;
  v_cands bigint[]; v_c bigint; v_t0 timestamptz;
begin
  if not (public.es_admin() or public.es_operaciones_analisis() or public.es_auditor() or (public.es_afiliado() and trim(p_movil) = any(public.mis_moviles_afiliado()))) then
    raise exception 'No autorizado para consultar este móvil.'; end if;
  if nullif(trim(p_movil),'') is null then return jsonb_build_object('ok', false, 'error', 'Móvil vacío.'); end if;
  if p_fecha is null then return jsonb_build_object('ok', false, 'error', 'Fecha vacía.'); end if;

  select tracker_id into v_mid from public.vehiculosgps where movil = trim(p_movil) limit 1;
  if v_mid is null then return jsonb_build_object('ok', false, 'error', 'El móvil '||trim(p_movil)||' no tiene Id GPS en SONAR.'); end if;

  -- Ruta/itinerario del móvil: primero lo que la app ya conoce (moviles_operacion), luego por ruta del parque.
  select it_id, ruta into v_itid, v_ruta
    from public.moviles_operacion where mid = v_mid and it_id is not null
    order by prog_actualizado desc nulls last limit 1;
  if v_ruta is null then
    select ir.ruta, ir.it_id into v_ruta, v_itid
      from public.parque_automotor pa
      join public.itinerario_rutas ir on position(lower(ir.ruta) in lower(coalesce(pa.ruta,''))) > 0
      where pa.numero_interno = trim(p_movil)
      order by length(ir.ruta) desc limit 1;
  end if;
  if v_ruta is null and v_itid is null then
    return jsonb_build_object('ok', true, 'movil', trim(p_movil), 'fecha', p_fecha,
      'viajes', '[]'::jsonb, 'nota', 'No se conoce el itinerario de este móvil (no está operando ni tiene ruta mapeada).');
  end if;

  -- Un móvil suele alternar itinerarios de su ruta (ej. "134" ida y "134Y" vuelta). Candidatos =
  -- itinerarios cuyo NOMBRE EXACTO sea uno de los tokens de la ruta del parque ("134-134Y" -> 134, 134Y),
  -- de la ruta de moviles_operacion, o el número base; más el it_id ya conocido. Tope 4.
  select array_agg(distinct ir.it_id) into v_cands
  from public.itinerario_rutas ir
  where lower(trim(ir.ruta)) = any (
    select distinct lower(trim(tok)) from (
      select unnest(regexp_split_to_array(
        coalesce((select ruta from public.parque_automotor where numero_interno = trim(p_movil) limit 1), ''),
        '[^0-9A-Za-z]+')) tok
      union all select v_ruta
      union all select substring(coalesce(v_ruta, '') from '^\d+')
    ) t where nullif(trim(tok), '') is not null
  )
  or ir.it_id = v_itid;
  if array_length(v_cands,1) is null then v_cands := array[v_itid]; end if;
  if array_length(v_cands,1) > 4 then v_cands := v_cands[1:4]; end if;

  select decrypted_secret into v_user from vault.decrypted_secrets where name='SONAR_USER';
  select decrypted_secret into v_pass from vault.decrypted_secrets where name='SONAR_PASSWORD';
  select decrypted_secret into v_url  from vault.decrypted_secrets where name='SONAR_URL';
  select decrypted_secret into v_ns   from vault.decrypted_secrets where name='SONAR_NAMESPACE';
  if v_url is null then return jsonb_build_object('ok', false, 'error', 'Falta SONAR_URL en el Vault'); end if;
  v_ns := coalesce(v_ns, 'http://sonaravl.com/webservices/');

  v_ini := to_char(p_fecha::timestamp + interval '5 hours', 'YYYY-MM-DD HH24:MI:SS');
  v_fin := to_char(p_fecha::timestamp + interval '1 day 5 hours' - interval '1 second', 'YYYY-MM-DD HH24:MI:SS');
  perform set_config('http.timeout_msec','3500',true);

  -- 1) Conteo de pasajeros (para cruzar por viaje) -> _dd (din, dout, hora UTC)
  select * into v_resp from extensions.http((
    'POST', rtrim(v_url,'/')||'/',
    array[extensions.http_header('SOAPAction', rtrim(v_ns,'/')||'/ServiceSoap/GET_PassengersCounter')],
    'text/xml; charset=utf-8',
    '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
    ||'<GET_PassengersCounter xmlns="'||v_ns||'"><User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
    ||'<mId>'||public._xmlesc(v_mid)||'</mId>'
    ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
    ||'</GET_PassengersCounter></soap:Body></soap:Envelope>'
  )::extensions.http_request);
  create temp table _dd on commit drop as
  select coalesce(din,0) din, coalesce(dout,0) dout, coalesce(dblock,0) dblock, door,
         to_timestamp(gps,'MM/DD/YYYY HH24:MI:SS') ts_utc
  from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n),
    '//n:DoorDetails' passing xmlparse(document v_resp.content)
    columns din int path 'n:DoorIn', dout int path 'n:DoorOut', dblock int path 'n:DoorBlocking',
            door int path 'n:Door', gps text path '../../n:gps_UTC');
  select coalesce(sum(din),0), coalesce(sum(dout),0) into v_tot_sub, v_tot_baj from _dd;

  -- 2) Historial de CADA itinerario candidato (best-effort, con tope de tiempo) -> _trips
  create temp table _trips (regid text, ruta text, ini_ts timestamptz, fin_ts timestamptz,
                            corriendo bool, cerrado bool, cancelado bool) on commit drop;
  perform set_config('http.timeout_msec','2200',true);
  v_t0 := clock_timestamp();
  foreach v_c in array v_cands loop
    exit when extract(epoch from (clock_timestamp() - v_t0)) > 4.5;  -- no arriesgar el statement_timeout de 8s
    begin
      select * into v_resp2 from extensions.http((
        'POST', rtrim(v_url,'/')||'/',
        array[extensions.http_header('SOAPAction', rtrim(v_ns,'/')||'/ServiceSoap/GET_ItinerariesHistory_v2')],
        'text/xml; charset=utf-8',
        '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/"><soap:Body>'
        ||'<GET_ItinerariesHistory_v2 xmlns="'||v_ns||'"><User>'||public._xmlesc(v_user)||'</User><Password>'||public._xmlesc(v_pass)||'</Password>'
        ||'<mId>'||public._xmlesc(v_mid)||'</mId><Itinerary>'||v_c||'</Itinerary>'
        ||'<UTC_datetime_init>'||v_ini||'</UTC_datetime_init><UTC_datetime_end>'||v_fin||'</UTC_datetime_end>'
        ||'</GET_ItinerariesHistory_v2></soap:Body></soap:Envelope>'
      )::extensions.http_request);
      if v_resp2.status = 200 then
        insert into _trips (regid, ruta, ini_ts, fin_ts, corriendo, cerrado, cancelado)
        select regid, (select ir.ruta from public.itinerario_rutas ir where ir.it_id = v_c limit 1),
               public._utc_ts(ini), public._utc_ts(fin), (run='Y'), (cls='Y'), (can='Y')
        from xmltable(xmlnamespaces('http://sonaravl.com/webservices/' as n),
          '//n:ItLog' passing xmlparse(document v_resp2.content)
          columns regid text path 'n:regId', ini text path 'n:inittime', fin text path 'n:endtime',
            run text path 'n:running', cls text path 'n:close', can text path 'n:canceled')
        where public._utc_ts(ini) is not null;
      end if;
    exception when others then null;  -- un itinerario que falle no descarta los demás
    end;
  end loop;

  -- 3) Cruce: subidas/bajadas dentro de la ventana [inicio, fin] de cada viaje.
  --    Estado segun la regla OFICIAL de SONAR (memoria despachos-regla-estados): lo que separa
  --    "Cancelado" de "Incompleto" es si el viaje CERRO. Un viaje cerrado y ademas marcado como
  --    cancelado SI corrio y SI movilizo pasajeros -> es "Incompleto" (no "Cancelado"). Solo los
  --    "Cancelado" (marcado y sin cerrar) llevan 0 pasajeros.
  select jsonb_agg(x order by (x->>'ini_ord'))
    into v_viajes
    from (
      select jsonb_build_object(
        'reg', t.regid,
        'ruta', coalesce(t.ruta, v_ruta),
        'ini', to_char(t.ini_ts at time zone 'America/Bogota','HH24:MI'),
        'fin', case when t.fin_ts is not null then to_char(t.fin_ts at time zone 'America/Bogota','HH24:MI') else null end,
        'ini_ord', to_char(t.ini_ts,'YYYY-MM-DD HH24:MI:SS'),
        'dur_min', case when t.fin_ts is not null and t.fin_ts > t.ini_ts
                        then round(extract(epoch from (t.fin_ts - t.ini_ts))/60.0)::int else null end,
        'estado', est.estado,
        'subidas', case when est.estado = 'Cancelado' then 0 else coalesce(pax.s,0) end,
        'bajadas', case when est.estado = 'Cancelado' then 0 else coalesce(pax.b,0) end,
        -- Desglose POR PUERTA del viaje: {puerta, subidas(DoorIn), bajadas(DoorOut), bloqueos}
        'puertas', case when est.estado = 'Cancelado' then '[]'::jsonb else coalesce(pu.j,'[]'::jsonb) end,
        -- Desglose de pasajeros del viaje en franjas de 15 min (para el detalle al hacer clic)
        'franjas', case when est.estado = 'Cancelado' then '[]'::jsonb else coalesce(fr.j,'[]'::jsonb) end
      ) x
      from _trips t
      cross join lateral (select case
          when t.corriendo            then 'En curso'
          when t.cerrado and t.cancelado then 'Incompleto'
          when t.cerrado              then 'Completo'
          when t.cancelado            then 'Cancelado'
          else 'Incompleto' end as estado) est
      cross join lateral (
        select coalesce(sum(d.din),0) s, coalesce(sum(d.dout),0) b
        from _dd d where d.ts_utc >= t.ini_ts and d.ts_utc <= coalesce(t.fin_ts, now())
      ) pax
      cross join lateral (
        -- Por puerta dentro de la ventana del viaje
        select jsonb_agg(jsonb_build_object('puerta', z.door, 'subidas', z.s, 'bajadas', z.b, 'bloqueos', z.blq) order by z.door) j
        from (
          select d.door, sum(d.din) s, sum(d.dout) b, sum(d.dblock) blq
          from _dd d
          where d.ts_utc >= t.ini_ts and d.ts_utc <= coalesce(t.fin_ts, now()) and d.door is not null
          group by d.door
        ) z
      ) pu
      cross join lateral (
        select jsonb_agg(jsonb_build_object(
                 't', to_char(g.bucket at time zone 'America/Bogota','HH24:MI'),
                 's', g.s, 'b', g.b) order by g.bucket) j
        from (
          select date_trunc('hour', d.ts_utc)
                   + floor(extract(minute from d.ts_utc)/15) * interval '15 min' as bucket,
                 sum(d.din) s, sum(d.dout) b
          from _dd d
          where d.ts_utc >= t.ini_ts and d.ts_utc <= coalesce(t.fin_ts, now())
          group by 1
        ) g
      ) fr
    ) q;

  select coalesce(sum((x->>'subidas')::int),0), coalesce(sum((x->>'bajadas')::int),0)
    into v_asig_sub, v_asig_baj
    from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x;

  return jsonb_build_object(
    'ok', true, 'movil', trim(p_movil), 'fecha', p_fecha, 'ruta', v_ruta, 'itid', v_itid,
    'viajes', coalesce(v_viajes,'[]'::jsonb),
    'n_viajes',      coalesce(jsonb_array_length(v_viajes), 0),
    'n_completos',   (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Completo'),
    'n_incompletos', (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Incompleto'),
    'n_cancelados',  (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'Cancelado'),
    'n_encurso',     (select count(*) from jsonb_array_elements(coalesce(v_viajes,'[]'::jsonb)) x where x->>'estado' = 'En curso'),
    'total_subidas', v_tot_sub, 'total_bajadas', v_tot_baj,
    'sin_viaje_subidas', greatest(v_tot_sub - v_asig_sub, 0),
    'sin_viaje_bajadas', greatest(v_tot_baj - v_asig_baj, 0)
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

CREATE OR REPLACE FUNCTION public.control_vivo_traer(p_punto text, p_fecha date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'extensions'
AS $function$
begin
  if not ( (select public.es_admin()) or (select public.es_auditor())
        or (select public.es_operaciones_analisis()) or (select public.es_consola()) ) then
    return jsonb_build_object('ok', false, 'error', 'Solo administración y auditoría.');
  end if;
  -- 50 s: por encima de lo que tarda el barrido, por debajo del corte de la pasarela.
  perform set_config('statement_timeout', '50000', true);
  return public.control_vivo_refrescar(p_punto, p_fecha);
end $function$;

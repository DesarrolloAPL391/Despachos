-- Productividad y fugas de capacidad por carro, con desglose por franja de 20 min.
-- Por ruta (o toda la flota) + rango + día-tipo: ranking de móviles del que menos
-- viajes hizo al que más, con programados vs. realizados y el "por qué" de cada
-- viaje caído.
--
-- Regla de realizado: estado_despacho in (DESPACHADO, SI) o sonar_regid presente.
-- Clasificación de un viaje NO realizado (columna despachos.estado = novedad):
--   justificado / reasignado / externo  → por la novedad
--   no_laboro   → sin novedad válida Y el carro NO hizo ningún viaje ese día
--   no_enturno  → sin novedad válida PERO el carro SÍ operó ese día (saltó el turno)

create or replace function public.productividad_carro(
  p_ruta_id  bigint,
  p_desde    date,
  p_hasta    date,
  p_dia_tipo text default 'habil')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
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
  if not (public.es_admin() or public.es_auditor() or public.es_afiliado()) then
    raise exception 'No autorizado.';
  end if;
  v_ids := case when (public.es_admin() or public.es_auditor()) then null
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
$$;

grant execute on function public.productividad_carro(bigint, date, date, text) to authenticated, service_role;

notify pgrst, 'reload schema';

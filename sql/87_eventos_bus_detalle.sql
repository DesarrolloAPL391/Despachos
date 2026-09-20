-- ============================================================================================
-- 87) SEGURIDAD VIAL: el top de vehículos y el detalle de cada número
--
-- Faltaban dos cosas en las pantallas:
--   1) el ranking por VEHÍCULO (ya estaba el de conductores): con qué carros se anda pasando
--      de lo reglamentario, que es lo que se lleva a mantenimiento y a la charla del afiliado;
--   2) poder abrir CUALQUIER número y ver los eventos que hay detrás (en el mapa, al tocar un
--      punto; en el top, al tocar un vehículo). Sin eso los tableros no se pueden sustentar.
--
-- "Pasarse de lo reglamentario" se mide comparando la velocidad contra el LÍMITE DE LA VÍA que
-- manda SONAR (RoadSpeed), no contra el texto del evento: SONAR marca "Exceso de velocidad" con
-- el umbral configurado en la plataforma, que a veces es MENOR que el límite real de la vía (por
-- eso se ven eventos de 52 km/h en vía de 60). Aparte se cuenta el umbral propio de la empresa
-- (eventos_bus_config.umbral_kmh = 60), que es la regla interna.
--
-- Las dos funciones cuentan EPISODIOS igual que sql/83 y sql/86: lecturas del mismo móvil, tipo
-- y conductor separadas por menos de 5 minutos son UN hecho.
--
-- Se aplica sobre sql/81..86.
-- ============================================================================================

-- 1) Top de vehículos ------------------------------------------------------------------------
create or replace function public.eventos_bus_vehiculos(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_umbral numeric;
begin
  if not (public.es_talento_humano() or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  with marcado as (
    select e.mid, e.movil, e.tipo, e.categoria, e.conductor, e.conductor_cedula, e.ruta,
           e.fecha, e.ocurrido_en, e.velocidad, e.limite, e.sobre_umbral,
           (e.velocidad is not null and e.limite > 0 and e.velocidad > e.limite) as sobre_via,
           (coalesce(extract(epoch from (e.ocurrido_en - lag(e.ocurrido_en) over w)), 1e9) > 300)::int as inicio
    from public.eventos_bus e
    where e.fecha between p_desde and p_hasta
    window w as (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en)
  ),
  epis as (
    select m.*,
           sum(m.inicio) over (partition by m.mid, m.tipo, m.conductor
                               order by m.ocurrido_en rows unbounded preceding) as epi
    from marcado m
  ),
  x as (
    select
      coalesce(e.movil, '(sin móvil)') as movil,
      count(distinct (e.mid || '|' || e.tipo || '|' || coalesce(e.conductor, '') || '|' || e.epi::text))
        filter (where e.sobre_via)     as sobre_via,
      count(distinct (e.mid || '|' || e.tipo || '|' || coalesce(e.conductor, '') || '|' || e.epi::text))
        filter (where e.sobre_umbral)  as sobre_umbral,
      count(distinct (e.mid || '|' || e.tipo || '|' || coalesce(e.conductor, '') || '|' || e.epi::text))
        filter (where e.tipo = 'puerta') as puertas,
      max(e.velocidad)                                   as vel_max,
      max(e.velocidad - e.limite) filter (where e.limite > 0) as sobre_max,
      count(distinct e.fecha)                            as dias,
      count(distinct coalesce(e.conductor_cedula, e.conductor)) as conductores,
      mode() within group (order by e.conductor)         as conductor_top,
      mode() within group (order by e.ruta)              as ruta,
      to_char(max(e.fecha), 'YYYY-MM-DD')                as ultimo
    from epis e
    group by 1
  )
  select coalesce(jsonb_agg(to_jsonb(x) order by x.sobre_via desc, x.sobre_umbral desc, x.vel_max desc), '[]'::jsonb)
    into v_items
  from x
  where x.sobre_via > 0 or x.sobre_umbral > 0 or x.puertas > 0;

  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
                            'umbral_kmh', v_umbral, 'items', v_items);
end $$;
revoke all on function public.eventos_bus_vehiculos(date, date) from public, anon;
grant execute on function public.eventos_bus_vehiculos(date, date) to authenticated;

-- 2) El detalle que hay detrás de cada número --------------------------------------------------
--    Sirve para el punto del mapa (p_lat/p_lon, redondeados igual que en sql/86), para un
--    vehículo (p_movil) y para un conductor (p_cedula). Devuelve las lecturas tal como están
--    guardadas, de la más reciente a la más vieja, con tope para no traer un año entero.
create or replace function public.eventos_bus_detalle(
  p_desde     date,
  p_hasta     date,
  p_categoria text    default null,
  p_lat       numeric default null,
  p_lon       numeric default null,
  p_movil     text    default null,
  p_cedula    text    default null,
  p_limite    int     default 300
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_total int; v_lim int;
begin
  if not (public.es_talento_humano() or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  v_lim := greatest(least(coalesce(p_limite, 300), 1000), 1);

  select count(1) into v_total
  from public.eventos_bus e
  where e.fecha between p_desde and p_hasta
    and (p_categoria is null or e.categoria = p_categoria)
    and (p_movil     is null or e.movil     = p_movil)
    and (p_cedula    is null or e.conductor_cedula = p_cedula)
    and (p_lat is null or p_lon is null
         or (round(e.lat, 3) = round(p_lat, 3) and round(e.lon, 3) = round(p_lon, 3)));

  select coalesce(jsonb_agg(to_jsonb(d)), '[]'::jsonb) into v_items
  from (
    select
      to_char(e.ocurrido_en at time zone 'America/Bogota', 'YYYY-MM-DD HH24:MI:SS') as cuando,
      e.movil, e.ruta, e.conductor, e.conductor_cedula, e.evento, e.categoria, e.tipo,
      e.velocidad, e.limite,
      case when e.velocidad is not null and e.limite > 0 and e.velocidad > e.limite
           then e.velocidad - e.limite end as sobre_via,
      e.sobre_umbral, e.direccion, e.lat::float8 as lat, e.lon::float8 as lon
    from public.eventos_bus e
    where e.fecha between p_desde and p_hasta
      and (p_categoria is null or e.categoria = p_categoria)
      and (p_movil     is null or e.movil     = p_movil)
      and (p_cedula    is null or e.conductor_cedula = p_cedula)
      and (p_lat is null or p_lon is null
           or (round(e.lat, 3) = round(p_lat, 3) and round(e.lon, 3) = round(p_lon, 3)))
    order by e.ocurrido_en desc
    limit v_lim
  ) d;

  return jsonb_build_object('ok', true, 'total', coalesce(v_total, 0),
                            'mostrados', jsonb_array_length(v_items), 'limite', v_lim,
                            'items', v_items);
end $$;
revoke all on function public.eventos_bus_detalle(date, date, text, numeric, numeric, text, text, int) from public, anon;
grant execute on function public.eventos_bus_detalle(date, date, text, numeric, numeric, text, text, int) to authenticated;

-- Índices para los dos cortes nuevos del detalle
create index if not exists eventos_bus_movil_idx    on public.eventos_bus (movil, fecha desc);
create index if not exists eventos_bus_cedula_idx   on public.eventos_bus (conductor_cedula, fecha desc);

-- Comprobación (devuelve ok:false en el SQL Editor por el guard de rol; se ve desde la app):
-- select public.eventos_bus_vehiculos(current_date - 30, current_date);
--
-- Esta sí corre en el SQL Editor — cuántos eventos superan el límite de la vía y cuántos los 60:
-- select count(1) filter (where velocidad > limite and limite > 0) as sobre_la_via,
--        count(1) filter (where sobre_umbral)                      as sobre_60,
--        count(1)                                                  as total
--   from public.eventos_bus;

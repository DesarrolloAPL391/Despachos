-- ============================================================================================
-- 86) SEGURIDAD VIAL: dónde ocurre — los puntos del mapa
--
-- Cada evento trae la coordenada que manda el GPS (lat/lon) y la dirección. Con eso se puede
-- mostrar en un mapa DÓNDE se corre y dónde se rueda con la puerta abierta, que es lo que sirve
-- para sensibilizar: "en el túnel de la 33 se pasan de 60 todos los días".
--
-- El mapa NO baja los eventos al navegador: un año de histórico son millones de filas. Esta
-- función los agrupa en el servidor por celdas de ~110 m (redondear la coordenada a 3 decimales)
-- y devuelve, como máximo, las p_limite celdas con más veces. Así la pantalla pesa igual con
-- 300 eventos que con 3 millones.
--
-- Cuenta EPISODIOS, no lecturas — igual que eventos_bus_resumen (sql/83): tres minutos a 65 km/h
-- son varias lecturas seguidas del mismo hecho. Un episodio son las lecturas del mismo móvil,
-- tipo y conductor separadas por menos de 5 minutos, y se cuenta en CADA celda por la que pasa
-- (así el mapa muestra el tramo donde se corrió, no solo el punto donde empezó).
--
-- Se aplica sobre sql/81..85.
-- ============================================================================================

create or replace function public.eventos_bus_mapa(
  p_desde     date,
  p_hasta     date,
  p_categoria text default null,   -- 'VELOCIDAD' | 'PUERTA ABIERTA' | null = las dos
  p_limite    int  default 600
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_con int; v_sin int; v_umbral numeric; v_lim int;
begin
  if not (public.es_talento_humano() or public.es_auditor()) then
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
end $$;
revoke all on function public.eventos_bus_mapa(date, date, text, int) from public, anon;
grant execute on function public.eventos_bus_mapa(date, date, text, int) to authenticated;

-- Índice para el recorte por fecha + categoría del mapa (el de sql/85 ya cubre categoria+fecha).
create index if not exists eventos_bus_punto_idx
  on public.eventos_bus (fecha) where lat is not null and lon is not null;

-- Comprobación rápida (admin, en el SQL Editor no devuelve datos por el guard de rol):
-- select public.eventos_bus_mapa(current_date - 30, current_date, null, 20);
--
-- Cobertura de coordenadas sobre lo ya guardado (esta sí corre en el SQL Editor):
-- select count(1) as total,
--        count(lat) as con_punto,
--        count(1) - count(lat) as sin_punto
--   from public.eventos_bus;

-- ============================================================================================
-- 88) SEGURIDAD VIAL: las series para las gráficas
--
-- Las tablas dicen QUIÉN y DÓNDE. Para la charla de sensibilización falta el CUÁNDO y el CUÁNTO:
--   · a qué hora del día se corre (la madrugada no se parece a la tarde),
--   · qué día de la semana,
--   · cómo viene el mes contra los anteriores (¿estamos mejorando?),
--   · en qué rutas se concentra,
--   · y qué tan rápido van cuando se pasan.
--
-- Todo se agrega en el servidor y se devuelve ya resumido: la pantalla dibuja barras con unas
-- pocas decenas de filas, no con el histórico entero.
--
-- Cuenta EPISODIOS igual que sql/83, 86 y 87. Cada episodio se cuenta UNA vez, en la hora, el
-- día y el mes en que EMPEZÓ, y con la velocidad más alta que alcanzó. Así un exceso de tres
-- minutos no aparece repartido en dos horas ni inflando el conteo.
--
-- Todo sale de UNA sola consulta: la lista de episodios se arma una vez (CTE materializada) y
-- las cinco series se sacan de ahí. Nada de tablas temporales, que en una función `stable`
-- Postgres no permite.
--
-- Se aplica sobre sql/81..87.
-- ============================================================================================

create or replace function public.eventos_bus_series(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_res jsonb; v_umbral numeric;
begin
  if not (public.es_talento_humano() or public.es_auditor()) then
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
end $$;
revoke all on function public.eventos_bus_series(date, date) from public, anon;
grant execute on function public.eventos_bus_series(date, date) to authenticated;

-- Comprobación (en el SQL Editor devuelve ok:false por el guard de rol; se ve desde la app):
-- select public.eventos_bus_series(current_date - 30, current_date);

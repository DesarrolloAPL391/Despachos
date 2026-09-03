-- 54_top_ruta.sql
-- "Top de movilización POR RUTA": rendimiento (pasajeros) agregado por ruta.
--
-- SONAR cuenta pasajeros por VEHÍCULO/día (GET_PassengersCounter), no por viaje, así que
-- pasajeros_dia guarda el total del carro en el día. Para llevarlo a ruta atribuimos los
-- pasajeros del carro-día a las rutas que ese carro DESPACHÓ ese día (desde _despachos_realizados,
-- que UNE despachos + tablas de puesto), repartidos en proporción al número de viajes por ruta.
-- Estimación (asume viajes comparables); exacto si el carro corrió una sola ruta el día.
--
-- Periodo: 'dia' (ayer), 'mes' (últimos 30), o 'rango' con p_desde/p_hasta. Devuelve también
-- el número de VIAJES realizados (por ruta y por carro). Admin y afiliado ven toda la operación.

drop function if exists public.top_ruta(text);

create or replace function public.top_ruta(p_periodo text default 'mes', p_desde date default null, p_hasta date default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_per text; v_desde date; v_hasta date;
begin
  if not (public.es_admin() or public.es_afiliado()) then
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

revoke all on function public.top_ruta(text,date,date) from public;
grant execute on function public.top_ruta(text,date,date) to authenticated;

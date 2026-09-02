-- 54_top_ruta.sql
-- "Top de movilización POR RUTA": rendimiento (pasajeros) agregado por ruta.
--
-- SONAR cuenta pasajeros por VEHÍCULO/día (GET_PassengersCounter), no por viaje,
-- así que pasajeros_dia guarda el total del carro en el día. Para llevarlo a ruta
-- atribuimos los pasajeros del carro-día a las rutas que ese carro DESPACHÓ ese día,
-- repartidos en proporción al número de viajes realizados por ruta. Es una estimación
-- (asume viajes comparables); cuando el carro corrió una sola ruta el día, es exacta.
-- No requiere nuevas llamadas a SONAR: reutiliza pasajeros_dia + despachos.

create or replace function public.top_ruta(p_periodo text default 'semana')
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_dias int; v_desde date; v_hasta date;
begin
  if not (public.es_admin() or public.es_afiliado()) then
    raise exception 'No autorizado.';
  end if;
  v_dias  := case when lower(coalesce(p_periodo,'')) = 'mes' then 30 else 7 end;
  v_hasta := current_date - 1;               -- hasta ayer (día completo)
  v_desde := current_date - v_dias;
  -- Vista de RUTA: todos ven todas las rutas y todos los carros (admin y afiliado por igual).

  return (
    with pax as (  -- pasajeros por carro/día en el periodo (toda la flota)
      select trim(pd.movil) as movil, pd.fecha, pd.subidas, pd.bajadas
      from public.pasajeros_dia pd
      where pd.fecha between v_desde and v_hasta
    ),
    disp as (      -- viajes realizados por (carro, día, ruta) de TODAS las fuentes (incluye TABLAS de puesto)
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
    agg_carro as (  -- pasajeros atribuidos por (ruta, carro) — el desglose de cada ruta
      select ruta, movil,
             round(sum(sub_attr))::int  as subidas,
             round(sum(baj_attr))::int  as bajadas,
             count(distinct fecha)::int as dias
      from attrib
      group by ruta, movil
    ),
    ruta_dias as (  -- días con datos por ruta (distintas fechas, no suma por carro)
      select ruta, count(distinct fecha)::int as dias
      from attrib group by ruta
    ),
    agg as (        -- total de ruta = suma de sus carros (cuadra con el desglose)
      select ac.ruta,
             sum(ac.subidas)::int as subidas,
             sum(ac.bajadas)::int as bajadas,
             count(*)::int        as moviles
      from agg_carro ac
      group by ac.ruta
    )
    select jsonb_build_object(
      'ok', true, 'periodo', case when v_dias = 30 then 'mes' else 'semana' end,
      'desde', v_desde, 'hasta', v_hasta,
      'resumen', jsonb_build_object(
        'rutas',          (select count(*) from agg),
        'subidas_total',  (select coalesce(sum(subidas), 0) from agg),
        'dias_con_datos', (select count(distinct fecha) from attrib)),
      'rutas', (
        select coalesce(jsonb_agg(x order by x.subidas desc), '[]'::jsonb) from (
          select ag.ruta, ag.subidas, ag.bajadas, ag.moviles, rd.dias,
                 round(ag.subidas::numeric / nullif(rd.dias,0), 0) as prom_dia,
                 (select coalesce(jsonb_agg(c order by c.subidas desc), '[]'::jsonb) from (
                    select ac.movil,
                           (select v.placa from public.vehiculos v where trim(v.numero) = trim(ac.movil) limit 1) as placa,
                           ac.subidas, ac.bajadas, ac.dias
                    from agg_carro ac where ac.ruta = ag.ruta
                  ) c) as carros
          from agg ag
          join ruta_dias rd on rd.ruta = ag.ruta
        ) x)
    )
  );
end $function$;

revoke all on function public.top_ruta(text) from public;
grant execute on function public.top_ruta(text) to authenticated;

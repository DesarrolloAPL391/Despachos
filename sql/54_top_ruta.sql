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
  v_dias int; v_desde date; v_hasta date; v_afil boolean; v_ids text[];
begin
  if not (public.es_admin() or public.es_afiliado()) then
    raise exception 'No autorizado.';
  end if;
  v_dias  := case when lower(coalesce(p_periodo,'')) = 'mes' then 30 else 7 end;
  v_hasta := current_date - 1;               -- hasta ayer (día completo)
  v_desde := current_date - v_dias;
  v_afil  := public.es_afiliado() and not public.es_admin();
  v_ids   := case when v_afil then public.mis_moviles_afiliado() else null end;

  return (
    with pax as (  -- pasajeros por carro/día en el periodo (afiliado: solo sus móviles)
      select trim(pd.movil) as movil, pd.fecha, pd.subidas, pd.bajadas
      from public.pasajeros_dia pd
      where pd.fecha between v_desde and v_hasta
        and (v_ids is null or trim(pd.movil) = any(v_ids))
    ),
    disp as (      -- viajes realizados por (carro, día, ruta)
      select trim(v.numero) as movil, d.fecha,
             coalesce(rr.nombre, rp.nombre) as ruta,
             count(*)::numeric as viajes
      from public.despachos d
      join public.vehiculos v on v.id = d.vehiculo_id
      left join public.rutas rr on rr.id = d.ruta_id
      left join public.rutas rp on rp.id = d.ruta_programada_id
      where d.fecha between v_desde and v_hasta
        and (d.estado_despacho in ('DESPACHADO','SI') or d.sonar_regid is not null)
        and coalesce(rr.nombre, rp.nombre) is not null
      group by trim(v.numero), d.fecha, coalesce(rr.nombre, rp.nombre)
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
    agg as (
      select ruta,
             round(sum(sub_attr))::int  as subidas,
             round(sum(baj_attr))::int  as bajadas,
             count(distinct movil)::int as moviles,
             count(distinct fecha)::int as dias
      from attrib
      group by ruta
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
          select ruta, subidas, bajadas, moviles, dias,
                 round(subidas::numeric / nullif(dias,0), 0) as prom_dia
          from agg
        ) x)
    )
  );
end $function$;

revoke all on function public.top_ruta(text) from public;
grant execute on function public.top_ruta(text) to authenticated;

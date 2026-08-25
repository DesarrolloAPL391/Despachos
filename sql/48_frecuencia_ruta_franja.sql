-- 48: Frecuencia de OFERTA programada por ruta y franja de 20 minutos (Fase 1).
-- Mide "cada cuánto se despacha" una ruta por franja horaria, a partir del horario PROGRAMADO
-- (despachos.hora, tipo time). Promedia sobre los días del rango que apliquen al día-tipo
-- (habil / sabado / domingo-festivo), para no depender de un día suelto. Solo lectura (admin/auditor).
--   headway_min = 20 * (nº de días) / (nº de despachos en la franja)  -> minutos entre despachos.
create or replace function public.frecuencia_ruta_franja(
  p_ruta_id bigint, p_desde date, p_hasta date, p_dia_tipo text default 'habil')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_dias int := 0; v_total int := 0; v_res jsonb;
begin
  if not (public.es_admin() or public.es_auditor() or public.es_afiliado()) then
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
end $$;
grant execute on function public.frecuencia_ruta_franja(bigint, date, date, text) to authenticated;

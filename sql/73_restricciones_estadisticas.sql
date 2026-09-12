-- 73: Estadística de restricciones para el DASHBOARD de auditores.
--   Una sola función que agrega restricciones_rutas y devuelve todo el tablero en un jsonb:
--   totales, top conductores / rutas / propietarios / móviles, por tabla, por modo y tendencia mensual.
--   Filtros: rango de fechas (sobre fecha_novedad, o fecha_restriccion si falta) y estado opcional.
--   Guard: solo admin / auditor / operaciones (es una vista de control).

create or replace function public.restricciones_estadisticas(
  p_desde date default null, p_hasta date default null, p_estado text default null)
returns jsonb
language plpgsql stable security definer set search_path to 'public'
as $$
declare v_out jsonb;
begin
  if not (public.es_admin() or public.es_auditor() or public.es_operaciones()) then
    raise exception 'No autorizado';
  end if;

  with f as (
    select
      nullif(trim(conductor),'')                                              as conductor,
      nullif(trim(vehiculo),'')                                               as vehiculo,
      nullif(trim(propietario),'')                                            as propietario,
      coalesce(nullif(trim(ruta_restringida),''), nullif(trim(ruta),''))      as ruta,
      lower(nullif(trim(tabla),''))                                           as tabla,
      nullif(trim(modo),'')                                                   as modo,
      estado,
      coalesce(fecha_novedad, fecha_restriccion)                              as fecha
    from public.restricciones_rutas
    where ( p_estado is null or estado = p_estado )
      and ( p_desde is null or coalesce(fecha_novedad, fecha_restriccion) >= p_desde )
      and ( p_hasta is null or coalesce(fecha_novedad, fecha_restriccion) <= p_hasta )
  )
  select jsonb_build_object(
    'total',          (select count(*) from f),
    'vigentes',       (select count(*) from f where estado='VIGENTE'),
    'canceladas',     (select count(*) from f where estado='CANCELADA'),
    'n_conductores',  (select count(distinct conductor) from f where conductor is not null),
    'n_moviles',      (select count(distinct vehiculo) from f where vehiculo is not null),
    'n_propietarios', (select count(distinct propietario) from f where propietario is not null),
    'top_conductores', (select coalesce(jsonb_agg(jsonb_build_object('k',k,'n',n) order by n desc, k),'[]'::jsonb)
        from (select conductor k, count(*) n from f where conductor is not null group by conductor order by count(*) desc, conductor limit 12) x),
    'top_rutas', (select coalesce(jsonb_agg(jsonb_build_object('k',k,'n',n) order by n desc, k),'[]'::jsonb)
        from (select ruta k, count(*) n from f where ruta is not null group by ruta order by count(*) desc, ruta limit 12) x),
    'top_propietarios', (select coalesce(jsonb_agg(jsonb_build_object('k',k,'n',n) order by n desc, k),'[]'::jsonb)
        from (select propietario k, count(*) n from f where propietario is not null group by propietario order by count(*) desc, propietario limit 12) x),
    'top_moviles', (select coalesce(jsonb_agg(jsonb_build_object('k',k,'n',n) order by n desc, k),'[]'::jsonb)
        from (select vehiculo k, count(*) n from f where vehiculo is not null group by vehiculo order by count(*) desc, vehiculo limit 12) x),
    'por_tabla', (select coalesce(jsonb_agg(jsonb_build_object('k',coalesce(k,'(sin tabla)'),'n',n) order by n desc),'[]'::jsonb)
        from (select tabla k, count(*) n from f group by tabla) x),
    'por_modo', (select coalesce(jsonb_agg(jsonb_build_object('k',coalesce(k,'(sin tipo)'),'n',n) order by n desc),'[]'::jsonb)
        from (select modo k, count(*) n from f group by modo) x),
    'por_mes', (select coalesce(jsonb_agg(jsonb_build_object('k',k,'n',n) order by k),'[]'::jsonb)
        from (select to_char(date_trunc('month', fecha),'YYYY-MM') k, count(*) n from f where fecha is not null group by 1) x),
    'rango', jsonb_build_object('desde', p_desde, 'hasta', p_hasta, 'estado', p_estado)
  ) into v_out;

  return v_out;
end $$;
revoke all on function public.restricciones_estadisticas(date,date,text) from public;
grant execute on function public.restricciones_estadisticas(date,date,text) to authenticated;

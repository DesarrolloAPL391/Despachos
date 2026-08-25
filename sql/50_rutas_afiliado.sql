-- 50_rutas_afiliado.sql
-- Rutas donde el AFILIADO tiene vehículos operando (para no mostrarle toda la empresa
-- en los combos de Frecuencia y Productividad). Se deriva de los despachos recientes
-- (últimos 60 días) de sus vehículos. SECURITY DEFINER: salta RLS por dentro, pero
-- solo devuelve algo si quien llama es afiliado y usa SU propia lista de vehículos.
create or replace function public.rutas_afiliado()
returns table(id bigint, nombre text)
language sql
security definer
set search_path to public
as $$
  with ids as (select public.mis_vehiculo_ids_afiliado() as arr)
  select distinct r.id, r.nombre
  from public.despachos d
  join public.rutas r on r.id = d.ruta_id
  cross join ids
  where public.es_afiliado()
    and d.fecha >= current_date - 60
    and (d.vehiculo_id = any(ids.arr) or d.vehiculo_programado_id = any(ids.arr))
  order by r.nombre;
$$;

revoke all on function public.rutas_afiliado() from public;
grant execute on function public.rutas_afiliado() to authenticated;

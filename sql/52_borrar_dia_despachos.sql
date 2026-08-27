-- 52_borrar_dia_despachos.sql
-- Habilita "🗑️ Borrar día" también en la tabla general "despachos" (antes solo tablas de
-- puesto). Misma función: borra TODA la programación de la tabla para una fecha (admin),
-- útil para reimportar un día corregido sin duplicados. La tabla general no está en
-- tablas_despacho, así que se agrega como excepción explícita a la lista blanca.
create or replace function public.borrar_tabla_dia(p_tabla text, p_fecha date)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_del int;
begin
  if not public.es_admin() then raise exception 'No autorizado'; end if;
  if p_tabla <> 'despachos'
     and not exists (select 1 from public.tablas_despacho where tabla = p_tabla) then
    raise exception 'Tabla no permitida: %', p_tabla;
  end if;
  execute format('with d as (delete from %I where fecha = $1 returning 1) select count(*) from d', p_tabla)
    into v_del using p_fecha;
  return jsonb_build_object('borrados', coalesce(v_del,0));
end
$function$;

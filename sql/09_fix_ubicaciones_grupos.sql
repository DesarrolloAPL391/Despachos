-- ============================================================================
-- 09_fix_ubicaciones_grupos.sql
-- ----------------------------------------------------------------------------
-- Bug: en el MAPA el despachador veía "0 móviles". La política RLS
-- `ubicaciones_select` deja leer solo las filas cuya `ruta` esté en
-- mis_ruta_nombres() (los NOMBRES de ruta: 190,191,192,193…). Pero en
-- `ubicaciones` muchos vehículos vienen etiquetados con el nombre del GRUPO
-- del parque (ej. "Laureles"), no con el número de ruta. Resultado: la RLS
-- devolvía 0 filas al despachador (con admin sí funciona: ve todo).
--
-- Fix: mis_ruta_nombres() ahora incluye también los GRUPOS a los que mapean
-- sus rutas (vía ruta_grupos). Esta función SOLO la usa ubicaciones_select,
-- así que el cambio no afecta otras tablas. Idempotente.
-- ============================================================================

create or replace function public.mis_ruta_nombres()
returns text[]
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_ids bigint[]; v_names text[]; v_grupos text[];
begin
  if public.es_admin() then return null; end if;
  v_ids := public.mis_ruta_ids();
  if v_ids is null or array_length(v_ids,1) is null then return array[]::text[]; end if;
  select array_agg(lower(trim(nombre))) into v_names
    from public.rutas where id = any(v_ids);
  -- Grupos del parque a los que mapean esas rutas (ruta_grupos.ruta_sonar -> grupo).
  -- 'ubicaciones' etiqueta muchos móviles con el nombre del grupo (ej. "laureles").
  select array_agg(distinct lower(trim(rg.grupo))) into v_grupos
    from public.rutas r
    join public.ruta_grupos rg on lower(trim(rg.ruta_sonar)) = lower(trim(r.nombre))
    where r.id = any(v_ids);
  return coalesce(v_names, array[]::text[]) || coalesce(v_grupos, array[]::text[]);
end $function$;

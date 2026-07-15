-- ============================================================================
-- 14_fix_mapa_auditor.sql  (v130)
-- BUG: el AUDITOR veía "0 móviles" en el mapa (probado con Aldair, aux7control).
--
-- Causa: la política `ubicaciones_select` filtra con mis_ruta_nombres(), que a su
-- vez usa mis_ruta_ids(). Y mis_ruta_ids() solo sabe de DESPACHADORES: busca el
-- puesto del día en `horarios` y de ahí saca las rutas del puesto. Un auditor NO
-- tiene turno en `horarios` (no trabaja por puesto), así que devolvía un arreglo
-- vacío → `lower(ruta) = ANY('{}')` es falso para todo → 0 de 340 ubicaciones.
--
-- Los despachos SÍ le funcionaban porque `despachos_select` tiene una rama aparte
-- para el auditor: (es_auditor() and ruta_id = any(rutas_auditor())). Al mapa le
-- faltaba esa misma rama.
--
-- Arreglo: mis_ruta_nombres() usa rutas_auditor() cuando el usuario es auditor.
-- NO se toca mis_ruta_ids() (la usan despachos y dias_con_datos): el despachador
-- sigue exactamente igual.
-- ============================================================================

create or replace function public.mis_ruta_nombres()
returns text[]
language plpgsql
stable security definer
set search_path to 'public'
as $function$
declare v_ids bigint[]; v_names text[]; v_grupos text[];
begin
  if public.es_admin() then return null; end if;

  -- De dónde salen las rutas de cada rol:
  --   auditor      -> tabla `auditores` (rutas_auditor())      ← faltaba
  --   despachador  -> horarios de hoy → puesto → puestos.rutas (mis_ruta_ids())
  if public.es_auditor() then
    v_ids := public.rutas_auditor();
  else
    v_ids := public.mis_ruta_ids();
  end if;

  if v_ids is null or array_length(v_ids, 1) is null then return array[]::text[]; end if;

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

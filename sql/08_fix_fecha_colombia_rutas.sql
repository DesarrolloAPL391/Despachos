-- ============================================================================
-- 08_fix_fecha_colombia_rutas.sql
-- ----------------------------------------------------------------------------
-- Bug: mis_ruta_ids() y mi_puesto() (usadas por la RLS de los despachadores)
-- buscaban el horario del día con `current_date` (UTC). En las noches (después
-- de las 19:00 en Colombia = medianoche UTC) leían el horario del día siguiente;
-- si ese día aún no estaba cargado, el despachador quedaba SIN rutas y no veía
-- ni podía editar sus despachos. Se alinea con mi_contexto usando la fecha de
-- Colombia (America/Bogota).
-- Aplicar en Management API / SQL Editor. Idempotente.
-- ============================================================================

create or replace function public.mi_puesto()
returns text
language sql
stable
security definer
set search_path to 'public'
as $function$
  select trim(observacion) from public.horarios
  where lower(email)=lower(auth.email())
    and fecha = (now() at time zone 'America/Bogota')::date
  order by hora_inicio asc nulls last limit 1
$function$;

create or replace function public.mis_ruta_ids()
returns bigint[]
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare v_email text := auth.email(); v_puesto text; v_txt text; v_ids bigint[];
begin
  if public.es_admin() then return null; end if;
  select trim(observacion) into v_puesto from public.horarios
    where lower(email)=lower(v_email)
      and fecha = (now() at time zone 'America/Bogota')::date
    order by hora_inicio asc nulls last limit 1;
  if v_puesto is null then return array[]::bigint[]; end if;
  select rutas into v_txt from public.puestos where lower(nombre)=lower(v_puesto) and activo;
  if v_txt is null then return array[]::bigint[]; end if;
  select array_agg(distinct r.id) into v_ids
    from unnest(string_to_array(v_txt,',')) s(name)
    join public.rutas r on lower(trim(r.nombre))=lower(trim(s.name));
  return coalesce(v_ids, array[]::bigint[]);
end $function$;

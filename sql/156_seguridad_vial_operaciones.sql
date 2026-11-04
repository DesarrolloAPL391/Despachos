-- =============================================================================================
-- 156 · SEGURIDAD VIAL con los mismos permisos y módulos que OPERACIONES (04/11/2026)
--
-- El área de operaciones no es un rol: son cuentas de rol `despachador` que se reconocen por el
-- correo. Ese patrón ('operaciones') estaba escrito a mano en tres funciones (es_operaciones,
-- en_horario y mi_acceso_horario). Ahora vive en UNA sola, _correo_operaciones(), y además de
-- 'operaciones' reconoce 'seguridadvial' (las cuentas del coordinador y del analista de
-- seguridad vial).
--
-- Todo lo demás ya pregunta por es_operaciones() / es_subadmin() (≈35 funciones y 14 políticas
-- RLS: taller, licencias, desbloqueos, preventivas, parque, usuarios, análisis, combustible,
-- intervenciones…) y lo hereda sin tocarlo. Seguridad vial también queda, como operaciones,
-- sin control de horario (entra sin turno del día).
--
-- En la app, isOperaciones() (webapp/js/app.js) lleva el MISMO patrón: cambiar los dos juntos.
-- =============================================================================================

-- 1) El patrón, en un solo lugar
create or replace function public._correo_operaciones(p_email text)
returns boolean
language sql immutable
set search_path to 'public'
as $function$ select lower(coalesce(p_email, '')) ~ '(operaciones|seguridadvial)' $function$;
revoke all on function public._correo_operaciones(text) from public, anon, authenticated;

-- 2) es_operaciones(): admin, o despachador con correo de operaciones / seguridad vial
create or replace function public.es_operaciones()
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select public.es_admin()
      or ( public.es_despachador()
           and public._correo_operaciones(auth.email()) );
$function$;

-- 3) en_horario(): operaciones y seguridad vial entran sin turno del día
create or replace function public.en_horario()
 returns boolean
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_rol text; v_now time := (now() at time zone 'America/Bogota')::time;
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_email text := auth.jwt() ->> 'email'; r record;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin','auditor','afiliado','gestion_humana') then return true; end if;
  -- operaciones y seguridad vial (gestión): entran sin turno del día
  if v_rol = 'despachador' and public._correo_operaciones(v_email) then return true; end if;
  for r in select hora_inicio, hora_fin from public.horarios
           where lower(email)=lower(v_email) and fecha=v_today loop
    if r.hora_inicio is null or r.hora_fin is null then continue; end if;
    if r.hora_fin >= r.hora_inicio then
      if v_now between r.hora_inicio and r.hora_fin then return true; end if;
    else
      if v_now >= r.hora_inicio or v_now <= r.hora_fin then return true; end if;
    end if;
  end loop;
  return false;
end; $function$;

-- 4) mi_acceso_horario(): la puerta de entrada, con la misma excepción
create or replace function public.mi_acceso_horario()
 returns jsonb
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_rol text; v_email text := auth.jwt() ->> 'email';
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_hi text; v_hf text; v_c int;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin','auditor','gestion_humana')
     or (v_rol = 'despachador' and public._correo_operaciones(v_email)) then
    return jsonb_build_object('permitido', true, 'rol', v_rol);
  end if;
  select to_char(min(hora_inicio),'HH24:MI'), to_char(max(hora_fin),'HH24:MI'), count(*)
    into v_hi, v_hf, v_c
  from public.horarios where lower(email)=lower(v_email) and fecha=v_today;
  return jsonb_build_object('permitido', public.en_horario(),
    'tiene_turno', coalesce(v_c,0) > 0, 'hora_inicio', v_hi, 'hora_fin', v_hf);
end; $function$;

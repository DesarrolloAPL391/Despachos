-- ============================================================================
-- 07_control_horario.sql  —  Acceso solo dentro del turno del día (despachadores)
-- ----------------------------------------------------------------------------
-- Un despachador solo puede tener sesión durante su turno (horarios.hora_inicio
-- a hora_fin, fecha de HOY en zona Colombia). Fuera de turno: no entra y, si ya
-- estaba dentro, se le cierra la sesión sola (heartbeat) + bloqueo por RLS.
-- Estricto (sin margen). Sin turno cargado hoy => no entra.
-- Admin y auditores NO se ven afectados (siempre entran).
--
-- La ACTIVACIÓN del bloqueo por RLS está al pie (aplicar_control_horario_a_tablas).
-- Aplicar en Management API / SQL Editor. Idempotente.
-- ============================================================================

-- ¿El usuario actual está dentro de su turno? (admin/auditor siempre true)
create or replace function public.en_horario()
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rol   text;
  v_now   time := (now() at time zone 'America/Bogota')::time;
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_email text := auth.jwt() ->> 'email';
  r record;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin', 'auditor') then
    return true;
  end if;
  -- Despachador: debe existir un turno de hoy que contenga la hora actual
  for r in
    select hora_inicio, hora_fin from public.horarios
    where lower(email) = lower(v_email) and fecha = v_today
  loop
    if r.hora_inicio is null or r.hora_fin is null then continue; end if;
    if r.hora_fin >= r.hora_inicio then
      if v_now between r.hora_inicio and r.hora_fin then return true; end if;
    else
      -- turno que cruza la medianoche
      if v_now >= r.hora_inicio or v_now <= r.hora_fin then return true; end if;
    end if;
  end loop;
  return false;   -- sin turno hoy, o fuera del rango
end;
$$;

-- Estado de acceso para el login del cliente (mensaje claro con el turno)
create or replace function public.mi_acceso_horario()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_rol   text;
  v_email text := auth.jwt() ->> 'email';
  v_today date := (now() at time zone 'America/Bogota')::date;
  v_hi text; v_hf text; v_c int;
begin
  select rol into v_rol from public.perfiles where id = auth.uid();
  if v_rol in ('admin', 'auditor') then
    return jsonb_build_object('permitido', true, 'rol', v_rol);
  end if;
  select to_char(min(hora_inicio), 'HH24:MI'), to_char(max(hora_fin), 'HH24:MI'), count(*)
    into v_hi, v_hf, v_c
  from public.horarios where lower(email) = lower(v_email) and fecha = v_today;
  return jsonb_build_object(
    'permitido', public.en_horario(),
    'tiene_turno', coalesce(v_c, 0) > 0,
    'hora_inicio', v_hi,
    'hora_fin', v_hf
  );
end;
$$;

-- heartbeat(): ahora devuelve el estado ('ok' | 'reemplazada' | 'fuera_horario').
-- Refresca la actividad y sirve para el auto-cierre por sesión única y por horario.
-- Se elimina la versión previa (devolvía boolean) para poder cambiar el tipo de retorno.
drop function if exists public.heartbeat();
create or replace function public.heartbeat()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_vig boolean;
begin
  update public.sesion_activa
     set updated_at = now()
   where user_id = auth.uid()
     and session_id = (auth.jwt() ->> 'session_id')::uuid;
  v_vig := found;
  if not v_vig then return jsonb_build_object('estado', 'reemplazada'); end if;
  if not public.en_horario() then return jsonb_build_object('estado', 'fuera_horario'); end if;
  return jsonb_build_object('estado', 'ok');
end;
$$;

grant execute on function public.en_horario()         to authenticated;
grant execute on function public.mi_acceso_horario()  to authenticated;
grant execute on function public.heartbeat()          to authenticated;

-- ----------------------------------------------------------------------------
-- Aplica la política RESTRICTIVE de horario a las tablas de negocio con RLS.
-- Se combina con AND sobre las demás (sesión única, permisivas de rol).
-- ----------------------------------------------------------------------------
create or replace function public.aplicar_control_horario_a_tablas()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare t text;
begin
  for t in
    select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
      and c.relname not in ('sesion_activa', 'auditoria_accesos')
  loop
    execute format('drop policy if exists require_en_horario on public.%I;', t);
    execute format(
      'create policy require_en_horario on public.%I
         as restrictive for all to authenticated
         using (public.en_horario()) with check (public.en_horario());', t);
  end loop;
end;
$$;

-- >>> ACTIVAR EL BLOQUEO POR HORARIO <<<
select public.aplicar_control_horario_a_tablas();

-- Para DESACTIVAR (revertir) el control por horario:
--   do $$ declare t text; begin
--     for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
--       where n.nspname='public' and c.relkind='r' and c.relrowsecurity loop
--       execute format('drop policy if exists require_en_horario on public.%I;', t);
--     end loop; end $$;

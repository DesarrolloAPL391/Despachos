-- ============================================================================
-- 06_conectados.sql  —  "Quién está conectado" (heartbeat + lista para admin)
-- ----------------------------------------------------------------------------
-- heartbeat(): el cliente lo llama cada 30 s. Refresca la última actividad
--   (sesion_activa.updated_at) y devuelve si la sesión sigue siendo la vigente
--   (reemplaza a mi_sesion_vigente en el timer del cliente: verifica + marca vivo).
-- listar_conectados(): solo admin. Lista los usuarios con su última actividad y
--   marca "en línea" a quienes estuvieron activos en los últimos N minutos.
-- Aplicar en SQL Editor / Management API. Idempotente.
-- ============================================================================

create or replace function public.heartbeat()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare v_ok boolean;
begin
  update public.sesion_activa
     set updated_at = now()
   where user_id = auth.uid()
     and session_id = (auth.jwt() ->> 'session_id')::uuid;
  v_ok := found;           -- true = esta sesión es la vigente (y quedó marcada como viva)
  return coalesce(v_ok, false);
end;
$$;

create or replace function public.listar_conectados(p_minutos int default 3)
returns table (email text, nombre text, rol text, ultimo timestamptz, en_linea boolean)
language sql
stable
security definer
set search_path = public
as $$
  select u.email,
         coalesce(p.nombre, ''),
         coalesce(p.rol, ''),
         sa.updated_at,
         sa.updated_at > now() - make_interval(mins => greatest(1, coalesce(p_minutos, 3)))
  from public.sesion_activa sa
  join auth.users u on u.id = sa.user_id
  left join public.perfiles p on p.id = sa.user_id
  where public.es_admin()
  order by sa.updated_at desc;
$$;

grant execute on function public.heartbeat()          to authenticated;
grant execute on function public.listar_conectados(int) to authenticated;

-- ============================================================================
-- 10_fix_conectados_reales.sql
-- ----------------------------------------------------------------------------
-- Bug del panel "Usuarios conectados": el contador "Con sesión abierta" salía
-- inflado (ej. 19) porque listar_conectados() devolvía TODAS las filas de
-- sesion_activa, y esa tabla conserva una fila por usuario aunque ya se haya
-- salido (solo se sobrescribe en el siguiente login o se borra al expulsar).
-- Aparecía gente que entró hace días.
--
-- Fix: solo listar usuarios con una sesión de Auth REAL (existe en
-- auth.sessions). Así "Con sesión abierta" = sesiones vivas y "En línea" =
-- heartbeat reciente. Idempotente.
-- ============================================================================

create or replace function public.listar_conectados(p_minutos integer default 3)
returns table(email text, nombre text, rol text, ultimo timestamptz,
              en_linea boolean, ruta text, hora_inicio text, hora_fin text)
language sql
stable
security definer
set search_path to 'public'
as $function$
  select u.email,
         coalesce(p.nombre, ''),
         coalesce(p.rol, ''),
         sa.updated_at,
         sa.updated_at > now() - make_interval(mins => greatest(1, coalesce(p_minutos, 3))),
         h.ruta,
         h.hora_inicio,
         h.hora_fin
  from public.sesion_activa sa
  join auth.users u on u.id = sa.user_id
  left join public.perfiles p on p.id = sa.user_id
  left join lateral (
    select ho.observacion as ruta,
           to_char(ho.hora_inicio, 'HH24:MI') as hora_inicio,
           to_char(ho.hora_fin,    'HH24:MI') as hora_fin
    from public.horarios ho
    where lower(ho.email) = lower(u.email)
      and ho.fecha = (now() at time zone 'America/Bogota')::date
    order by ho.updated_at desc nulls last
    limit 1
  ) h on true
  where public.es_admin()
    -- Solo usuarios con sesión de Auth VIVA (evita filas viejas de sesion_activa).
    and exists (select 1 from auth.sessions s where s.user_id = sa.user_id)
  order by sa.updated_at desc;
$function$;

-- ============================================================================
-- 27_monitor_usuarios.sql  (v174)
-- Monitoreo de usuarios para el admin: cada heartbeat (cada ~12s) guarda la
-- LATENCIA que mide el propio cliente (round-trip a Supabase) y la VERSIÓN de la
-- app que está corriendo. "Conectados" muestra ambas con semáforo, para ver de un
-- vistazo quién va lento o quién quedó en una versión vieja (causa común de fallos).
-- Se apoya en lo que YA existe (sesion_activa.updated_at); solo agrega 2 columnas.
-- ============================================================================

alter table public.sesion_activa
  add column if not exists latencia_ms int,
  add column if not exists app_version text;

-- heartbeat ahora acepta (y guarda) la latencia y la versión reportadas por el cliente.
-- Params con DEFAULT NULL → los clientes viejos que llaman heartbeat() sin argumentos
-- siguen funcionando (no se sobreescribe lo guardado con null).
drop function if exists public.heartbeat();
create or replace function public.heartbeat(p_latencia_ms int default null, p_version text default null)
returns jsonb
language plpgsql security definer set search_path = public as $fn$
declare v_vig boolean;
begin
  update public.sesion_activa
     set updated_at  = now(),
         latencia_ms = coalesce(p_latencia_ms, latencia_ms),
         app_version = coalesce(nullif(trim(p_version), ''), app_version)
   where user_id = auth.uid()
     and session_id = (auth.jwt() ->> 'session_id')::uuid;
  v_vig := found;
  if not v_vig then return jsonb_build_object('estado', 'reemplazada'); end if;
  if not public.en_horario() then return jsonb_build_object('estado', 'fuera_horario'); end if;
  return jsonb_build_object('estado', 'ok');
end $fn$;
revoke all on function public.heartbeat(int, text) from public, anon;
grant execute on function public.heartbeat(int, text) to authenticated;

-- listar_conectados devuelve además latencia_ms y app_version.
drop function if exists public.listar_conectados(integer);
create or replace function public.listar_conectados(p_minutos integer default 3)
returns table(email text, nombre text, rol text, ultimo timestamptz, en_linea boolean,
              ruta text, hora_inicio text, hora_fin text, latencia_ms int, app_version text)
language sql stable security definer set search_path = public as $fn$
  select u.email,
         coalesce(p.nombre, ''),
         coalesce(p.rol, ''),
         sa.updated_at,
         sa.updated_at > now() - make_interval(mins => greatest(1, coalesce(p_minutos, 3))),
         h.ruta, h.hora_inicio, h.hora_fin,
         sa.latencia_ms, sa.app_version
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
    and exists (select 1 from auth.sessions s where s.user_id = sa.user_id)
  order by sa.updated_at desc;
$fn$;
revoke all on function public.listar_conectados(integer) from public, anon;
grant execute on function public.listar_conectados(integer) to authenticated;

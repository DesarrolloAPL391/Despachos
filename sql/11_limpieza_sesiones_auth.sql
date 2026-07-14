-- ============================================================================
-- 11_limpieza_sesiones_auth.sql
-- ----------------------------------------------------------------------------
-- Las sesiones de auth.sessions se acumulaban por usuario (una cuenta llegó a
-- 10) porque al iniciar sesión NO se borraban las anteriores. No es hueco de
-- seguridad (la RLS de sesión única solo deja pasar el session_id vigente),
-- pero es desorden y ensucia los conteos.
--
-- Este script:
--  1) registrar_sesion(): además de lo que ya hacía (auditoría + sesion_activa),
--     elimina las DEMÁS sesiones de Auth del usuario (deja solo la actual).
--     Así cada login futuro limpia lo viejo y refuerza la sesión única a nivel
--     Auth (el dispositivo anterior pierde su refresh token de inmediato).
--  2) Limpieza única: deja por usuario solo la sesión vigente (la de
--     sesion_activa); borra el resto. No cierra a los usuarios activos porque
--     su sesión vigente es justo la que se conserva.
-- Idempotente.
-- ============================================================================

-- 1) registrar_sesion con limpieza de sesiones viejas del propio usuario
create or replace function public.registrar_sesion(p_gps text default null)
returns void
language plpgsql
security definer
set search_path to 'public', 'auth'
as $function$
declare
  v_uid   uuid := auth.uid();
  v_sid   uuid := (auth.jwt() ->> 'session_id')::uuid;
  v_email text := auth.jwt() ->> 'email';
  v_ip    text;
  v_ua    text;
  v_prev  uuid;
begin
  select host(ip), user_agent into v_ip, v_ua from auth.sessions where id = v_sid;

  select session_id into v_prev from public.sesion_activa where user_id = v_uid;
  if v_prev is not null and v_prev <> v_sid then
    insert into public.auditoria_accesos (user_id, email, evento, ip, user_agent, gps, session_id, detalle)
    values (v_uid, v_email, 'sesion_reemplazada', v_ip, v_ua, p_gps, v_sid,
            jsonb_build_object('sesion_desplazada', v_prev));
  end if;

  insert into public.auditoria_accesos (user_id, email, evento, ip, user_agent, gps, session_id)
  values (v_uid, v_email, 'ingreso', v_ip, v_ua, p_gps, v_sid);

  insert into public.sesion_activa (user_id, session_id, updated_at)
  values (v_uid, v_sid, now())
  on conflict (user_id) do update
    set session_id = excluded.session_id, updated_at = now();

  -- Sesión única a nivel Auth: borra las demás sesiones de este usuario (deja solo la actual).
  delete from auth.refresh_tokens
    where session_id in (select id from auth.sessions where user_id = v_uid and id <> v_sid);
  delete from auth.sessions
    where user_id = v_uid and id <> v_sid;
end;
$function$;

-- 2) Limpieza única de lo acumulado: conservar solo la sesión vigente por usuario.
delete from auth.refresh_tokens
  where session_id in (
    select s.id from auth.sessions s
    where not exists (
      select 1 from public.sesion_activa sa
      where sa.user_id = s.user_id and sa.session_id = s.id
    )
  );

delete from auth.sessions s
  where not exists (
    select 1 from public.sesion_activa sa
    where sa.user_id = s.user_id and sa.session_id = s.id
  );

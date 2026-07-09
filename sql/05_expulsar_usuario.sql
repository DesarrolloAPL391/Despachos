-- ============================================================================
-- 05_expulsar_usuario.sql  —  Expulsar la sesión de un usuario (solo admin)
-- ----------------------------------------------------------------------------
-- Con un clic, un admin saca a un usuario de la sesión AHORA MISMO:
--   1) Revoca sus sesiones en auth.sessions (invalida el refresh token).
--   2) Invalida su sesión activa -> la política RLS lo bloquea de datos al
--      instante (su access token, aunque siga vivo, no puede leer/escribir).
--   3) Su app lo saca al login en <=30 s (chequeo proactivo mi_sesion_vigente).
--   4) Queda registrado en la auditoría ('expulsado_por_admin', por quién).
--
-- Aplicar en SQL Editor / Management API. Idempotente.
-- ============================================================================
create or replace function public.admin_expulsar_usuario(p_email text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_uid   uuid;
  v_actor text := auth.jwt() ->> 'email';
begin
  if not public.es_admin() then
    return jsonb_build_object('ok', false, 'error', 'No autorizado');
  end if;

  select id into v_uid from auth.users where lower(email) = lower(trim(p_email));
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'No existe un usuario con ese correo');
  end if;
  if v_uid = auth.uid() then
    return jsonb_build_object('ok', false, 'error', 'No puedes expulsarte a ti mismo');
  end if;

  -- 1) Revocar sesiones reales (corta el refresh token)
  delete from auth.sessions where user_id = v_uid;

  -- 2) Invalidar la sesión activa -> bloqueo RLS inmediato del access token vivo
  insert into public.sesion_activa (user_id, session_id, updated_at)
  values (v_uid, gen_random_uuid(), now())
  on conflict (user_id) do update
    set session_id = gen_random_uuid(), updated_at = now();

  -- 3) Auditoría
  insert into public.auditoria_accesos (user_id, email, evento, detalle)
  values (v_uid, lower(trim(p_email)), 'expulsado_por_admin',
          jsonb_build_object('por', v_actor));

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.admin_expulsar_usuario(text) to authenticated;

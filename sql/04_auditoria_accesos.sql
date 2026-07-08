-- ============================================================================
-- 04_auditoria_accesos.sql  —  Auditoría de accesos (quién entra, intenta y es sacado)
-- ----------------------------------------------------------------------------
-- Registra: ingresos exitosos, intentos fallidos, sesiones reemplazadas
-- (expulsiones) y cierres de sesión. La IP y el dispositivo de los INGRESOS y
-- EXPULSIONES se leen de auth.sessions (los pobla Supabase, no el cliente →
-- infalseables). El GPS es opcional (best-effort desde el navegador).
-- Solo el admin puede consultar la auditoría (RPC listar_auditoria).
--
-- Aplicar pegando en el SQL Editor / Management API. Idempotente.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Tabla de eventos de acceso
-- ----------------------------------------------------------------------------
create table if not exists public.auditoria_accesos (
  id         bigint generated always as identity primary key,
  user_id    uuid,
  email      text,
  evento     text not null,   -- ingreso | intento_fallido | sesion_reemplazada | cierre
  ip         text,
  user_agent text,
  gps        text,            -- "lat,lng" si el navegador lo concedió
  session_id uuid,
  detalle    jsonb,
  creado_en  timestamptz not null default now()
);
create index if not exists auditoria_accesos_creado_idx on public.auditoria_accesos (creado_en desc);
create index if not exists auditoria_accesos_email_idx   on public.auditoria_accesos (email, creado_en desc);

-- RLS activa y sin políticas permisivas: la tabla solo se escribe/lee vía las
-- funciones SECURITY DEFINER de abajo (el cliente nunca la toca directo).
alter table public.auditoria_accesos enable row level security;

-- ----------------------------------------------------------------------------
-- registrar_sesion(p_gps): reemplaza la versión previa. Además de fijar la
-- sesión activa, registra el INGRESO y, si desplazó otra sesión, la EXPULSIÓN.
-- Lee ip/user_agent de auth.sessions (fuente de verdad del servidor).
-- ----------------------------------------------------------------------------
-- Se elimina la versión sin parámetros (v110) para dejar una sola firma. El
-- cliente que llama `registrar_sesion` sin argumentos sigue funcionando gracias
-- al DEFAULT de p_gps (PostgREST resuelve la función con sus valores por defecto).
drop function if exists public.registrar_sesion();

create or replace function public.registrar_sesion(p_gps text default null)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
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
    -- Se está desplazando una sesión anterior: queda registrada la expulsión.
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
end;
$$;

-- ----------------------------------------------------------------------------
-- registrar_intento_fallido: lo llama el cliente cuando el login falla (aún NO
-- autenticado), por eso es accesible a anon. Sin IP confiable (el cliente no la
-- conoce); guarda el correo intentado y el dispositivo.
-- ----------------------------------------------------------------------------
create or replace function public.registrar_intento_fallido(p_email text, p_user_agent text default null)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.auditoria_accesos (email, evento, user_agent, detalle)
  values (lower(coalesce(p_email, '')), 'intento_fallido', p_user_agent,
          jsonb_build_object('origen', 'login'));
$$;

-- ----------------------------------------------------------------------------
-- registrar_cierre: logout manual (el cliente lo llama antes de signOut).
-- ----------------------------------------------------------------------------
create or replace function public.registrar_cierre()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_sid uuid := (auth.jwt() ->> 'session_id')::uuid;
  v_ip  text; v_ua text;
begin
  select host(ip), user_agent into v_ip, v_ua from auth.sessions where id = v_sid;
  insert into public.auditoria_accesos (user_id, email, evento, ip, user_agent, session_id)
  values (auth.uid(), auth.jwt() ->> 'email', 'cierre', v_ip, v_ua, v_sid);
end;
$$;

-- ----------------------------------------------------------------------------
-- listar_auditoria: SOLO admin. Devuelve el log con el nombre del usuario.
-- ----------------------------------------------------------------------------
create or replace function public.listar_auditoria(p_limit int default 200)
returns table (creado_en timestamptz, evento text, email text, nombre text,
               ip text, user_agent text, gps text, detalle jsonb)
language sql
stable
security definer
set search_path = public
as $$
  select a.creado_en, a.evento, a.email, coalesce(p.nombre, ''),
         a.ip, a.user_agent, a.gps, a.detalle
  from public.auditoria_accesos a
  left join public.perfiles p on p.email = a.email
  where public.es_admin()
  order by a.creado_en desc
  limit greatest(1, least(coalesce(p_limit, 200), 1000));
$$;

grant execute on function public.registrar_sesion(text)                 to authenticated;
grant execute on function public.registrar_intento_fallido(text, text)  to anon, authenticated;
grant execute on function public.registrar_cierre()                     to authenticated;
grant execute on function public.listar_auditoria(int)                  to authenticated;

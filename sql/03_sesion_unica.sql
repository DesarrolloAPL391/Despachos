-- ============================================================================
-- 03_sesion_unica.sql  —  Sesión única REAL por usuario, forzada por el servidor
-- ----------------------------------------------------------------------------
-- Objetivo: cada usuario (admin, auditor, despachador) puede tener UNA sola
-- sesión activa a la vez. El control es infalsificable porque se apoya en el
-- claim `session_id` firmado dentro del JWT de Supabase y se valida vía RLS.
--
-- Cómo funciona:
--   1) `sesion_activa` guarda el session_id vigente de cada usuario.
--   2) Al iniciar sesión, el cliente llama `registrar_sesion()`, que registra
--      SU propio session_id (leído del JWT, no de un parámetro) como el activo.
--   3) Una política RESTRICTIVE en todas las tablas de negocio exige que el
--      session_id del JWT actual == el registrado. El dispositivo viejo queda
--      bloqueado (ni lee ni escribe) en su siguiente operación, de inmediato.
--
-- Aplicar pegando TODO este archivo en el SQL Editor de Supabase y ejecutando.
-- Es idempotente: se puede volver a correr sin problema.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- a) Tabla fuente de verdad
-- ----------------------------------------------------------------------------
create table if not exists public.sesion_activa (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  session_id uuid not null,
  updated_at timestamptz not null default now()
);

-- RLS activa y SIN políticas: la tabla solo se toca desde funciones SECURITY
-- DEFINER (registrar_sesion / es_sesion_vigente), nunca directo desde el cliente.
alter table public.sesion_activa enable row level security;

-- ----------------------------------------------------------------------------
-- b) Registrar la sesión propia como la activa (se llama al hacer login)
--    No recibe parámetros: toma el session_id del JWT del que llama, por lo que
--    un cliente no puede registrar la sesión de otro ni un id inventado.
-- ----------------------------------------------------------------------------
create or replace function public.registrar_sesion()
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.sesion_activa (user_id, session_id, updated_at)
  values (auth.uid(), (auth.jwt() ->> 'session_id')::uuid, now())
  on conflict (user_id) do update
    set session_id = excluded.session_id,
        updated_at = now();
$$;

-- ----------------------------------------------------------------------------
-- c) ¿La sesión del JWT actual es la vigente? (usada por las políticas RLS)
--    STABLE: se evalúa una vez por consulta. Lee por PK -> costo despreciable.
-- ----------------------------------------------------------------------------
create or replace function public.es_sesion_vigente()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.sesion_activa s
    where s.user_id = auth.uid()
      and s.session_id = (auth.jwt() ->> 'session_id')::uuid
  );
$$;

-- ----------------------------------------------------------------------------
-- d) RPC para el chequeo proactivo del cliente (muestra "sesión cerrada")
-- ----------------------------------------------------------------------------
create or replace function public.mi_sesion_vigente()
returns boolean
language sql
security definer
set search_path = public
as $$
  select public.es_sesion_vigente();
$$;

grant execute on function public.registrar_sesion()  to authenticated;
grant execute on function public.mi_sesion_vigente()  to authenticated;

-- ----------------------------------------------------------------------------
-- e) Aplicar la política RESTRICTIVE a TODAS las tablas de negocio con RLS.
--    Una política RESTRICTIVE se combina con AND sobre las permisivas que ya
--    existen, así que NO hay que reescribir ninguna política actual.
--    Se excluye `sesion_activa` (la gestionan las funciones SECURITY DEFINER).
--
--    Reejecutable: si en el futuro se crea una tabla de puesto nueva, volver a
--    correr este bloque (o todo el archivo) para que también quede protegida.
-- ----------------------------------------------------------------------------
create or replace function public.aplicar_sesion_unica_a_tablas()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare t text;
begin
  for t in
    select c.relname
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relkind = 'r'
      and c.relrowsecurity
      and c.relname <> 'sesion_activa'
  loop
    execute format('drop policy if exists require_sesion_vigente on public.%I;', t);
    execute format(
      'create policy require_sesion_vigente on public.%I
         as restrictive for all to authenticated
         using (public.es_sesion_vigente())
         with check (public.es_sesion_vigente());', t);
  end loop;
end;
$$;

-- >>> ACTIVACIÓN DEL BLOQUEO (FASE 2) <<<
-- La siguiente línea ENCIENDE el enforcement por RLS. Déjala COMENTADA en la
-- fase de prueba (Fase 1): así se crean tabla y funciones y se puede probar
-- `mi_sesion_vigente()` SIN bloquear a nadie ni a la app vieja aún publicada.
-- Descoméntala y ejecútala SOLO cuando publiques el cliente nuevo (que llama a
-- `registrar_sesion`), idealmente en horario de bajo tráfico.
--
--     select public.aplicar_sesion_unica_a_tablas();
--
-- Para APAGAR el bloqueo si hiciera falta revertir:
--     do $$ declare t text; begin
--       for t in select c.relname from pg_class c join pg_namespace n on n.oid=c.relnamespace
--         where n.nspname='public' and c.relkind='r' and c.relrowsecurity loop
--         execute format('drop policy if exists require_sesion_vigente on public.%I;', t);
--       end loop; end $$;

-- ----------------------------------------------------------------------------
-- f) Semilla de transición: registra como activa la sesión MÁS RECIENTE de cada
--    usuario ya logueado, para no expulsar a todos al desplegar. Los usuarios
--    con varias sesiones abiertas conservan solo la más reciente (las demás
--    quedan bloqueadas), que es justamente el comportamiento buscado.
-- ----------------------------------------------------------------------------
insert into public.sesion_activa (user_id, session_id, updated_at)
select distinct on (s.user_id) s.user_id, s.id, coalesce(s.refreshed_at, s.created_at)
from auth.sessions s
order by s.user_id, coalesce(s.refreshed_at, s.created_at) desc
on conflict (user_id) do update
  set session_id = excluded.session_id,
      updated_at = excluded.updated_at;

-- ============================================================================
-- Verificación rápida (opcional, ejecutar por separado):
--   select * from public.sesion_activa;
--   select polname, polrelid::regclass, polpermissive
--   from pg_policy where polname = 'require_sesion_vigente' order by 2;
-- ============================================================================

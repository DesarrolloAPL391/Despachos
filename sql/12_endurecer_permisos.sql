-- ============================================================================
-- 12_endurecer_permisos.sql  (v127)
-- Cierra 3 huecos de seguridad encontrados en la auditoría del 2026-07-14.
-- El 4º hueco (XSS) se corrige en el cliente: esc() ahora escapa comillas.
--
-- NO cambia el funcionamiento normal:
--   * Las lecturas quedan EXACTAMENTE igual que hoy.
--   * `horarios` y `puestos` no salen en el menú del despachador (no tienen
--     `despachador: true` en config.js), así que restringir su ESCRITURA al
--     admin no le quita nada a nadie.
--   * `stg_despachos` no la usa nada: ni el cliente, ni funciones, ni vistas.
--   * Las funciones `aplicar_*` solo se llaman desde el SQL Editor (postgres,
--     que es el dueño y siempre puede ejecutarlas).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1) horarios: cualquier despachador podía escribirla (política ALL true/true).
--    Probado en vivo: podía extender su turno, CAMBIARSE DE PUESTO y modificar
--    los turnos de otras 33 personas → se saltaba el control de horario y el
--    aislamiento por puesto. Ahora solo el admin escribe.
-- ---------------------------------------------------------------------------
drop policy if exists horarios_auth_all on public.horarios;

create policy horarios_select on public.horarios
  for select to authenticated using (true);
create policy horarios_insert_admin on public.horarios
  for insert to authenticated with check (public.es_admin());
create policy horarios_update_admin on public.horarios
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy horarios_delete_admin on public.horarios
  for delete to authenticated using (public.es_admin());

-- ---------------------------------------------------------------------------
-- 2) puestos: mismo hueco (política ALL true/true). Es el catálogo del que
--    depende la asignación de puesto → solo el admin lo escribe.
-- ---------------------------------------------------------------------------
drop policy if exists puestos_all on public.puestos;

create policy puestos_select on public.puestos
  for select to authenticated using (true);
create policy puestos_insert_admin on public.puestos
  for insert to authenticated with check (public.es_admin());
create policy puestos_update_admin on public.puestos
  for update to authenticated using (public.es_admin()) with check (public.es_admin());
create policy puestos_delete_admin on public.puestos
  for delete to authenticated using (public.es_admin());

-- ---------------------------------------------------------------------------
-- 3) stg_despachos: sin RLS y con SELECT+DELETE para `anon` → 599 filas
--    (placa, conductor, código, ubicación, propietario) legibles y BORRABLES
--    sin iniciar sesión. Es una tabla de staging que hoy no usa nadie.
--    Se activa RLS sin políticas: solo la alcanzan service_role y las
--    funciones SECURITY DEFINER. Los datos se conservan.
-- ---------------------------------------------------------------------------
alter table public.stg_despachos enable row level security;
revoke all on public.stg_despachos from anon, authenticated;

-- ---------------------------------------------------------------------------
-- 4) Funciones que aplican DDL (recrean políticas en las 31 tablas):
--    estaban abiertas a `anon` → cualquiera sin cuenta podía dispararlas y
--    bloquear la base. Solo el dueño (postgres / SQL Editor) debe ejecutarlas.
-- ---------------------------------------------------------------------------
revoke all on function public.aplicar_control_horario_a_tablas() from public, anon, authenticated;
revoke all on function public.aplicar_sesion_unica_a_tablas()   from public, anon, authenticated;

-- OJO: `registrar_intento_fallido` SÍ debe seguir abierta a `anon`: el cliente
-- la llama cuando la contraseña falla, y ahí el usuario todavía no tiene
-- sesión. Revocarla apagaría la auditoría de intentos fallidos. En su lugar se
-- recorta el user_agent para que nadie pueda inflar la tabla de auditoría.
create or replace function public.registrar_intento_fallido(p_email text, p_user_agent text default null)
returns void language sql security definer set search_path to 'public' as $function$
  insert into public.auditoria_accesos (email, evento, user_agent, detalle)
  values (lower(left(coalesce(p_email, ''), 200)), 'intento_fallido', left(p_user_agent, 300),
          jsonb_build_object('origen', 'login'));
$function$;

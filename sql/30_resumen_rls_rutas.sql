-- ============================================================================
-- 30_resumen_rls_rutas.sql  (v179)
-- Resumen deja de ser "todos ven todo": el DESPACHADOR ve SOLO los carros de su(s)
-- ruta(s), igual que en Despachos. admin = todo; auditor = sus rutas asignadas.
--
-- Antes: una sola política permisiva `resumen_auth_all [ALL] using (true)` → cualquier
-- despachador veía TODOS los resúmenes de TODAS las rutas. Se reemplaza por políticas
-- por comando que copian el patrón ya probado de `despachos`:
--   SELECT/UPDATE/DELETE: es_admin() OR (es_auditor() y su ruta) OR (ruta de mi puesto)
--   INSERT: with check (true)  (la UI limita la ruta; igual que despachos_insert)
-- Las RESTRICTIVE existentes (require_sesion_vigente, require_en_horario) se conservan.
-- ============================================================================
set search_path = public, extensions;

alter table public.resumen enable row level security;

drop policy if exists resumen_auth_all on public.resumen;
drop policy if exists resumen_select  on public.resumen;
drop policy if exists resumen_insert  on public.resumen;
drop policy if exists resumen_update  on public.resumen;
drop policy if exists resumen_delete  on public.resumen;

-- Ver: admin todo; auditor sus rutas; el resto (despachador) solo las rutas de su puesto.
create policy resumen_select on public.resumen
  for select to authenticated
  using (
    es_admin()
    or (es_auditor() and ruta_id = any(rutas_auditor()))
    or (ruta_id = any(mis_ruta_ids()))
  );

-- Crear: permitido (la UI ya limita la ruta a la del despachador), igual que despachos.
create policy resumen_insert on public.resumen
  for insert to authenticated
  with check (true);

-- Editar: solo filas de su alcance (no puede tocar lo que no ve).
create policy resumen_update on public.resumen
  for update to authenticated
  using (
    es_admin()
    or (es_auditor() and ruta_id = any(rutas_auditor()))
    or (ruta_id = any(mis_ruta_ids()))
  )
  with check (true);

-- Borrar: el admin cualquiera; el despachador solo las de su ruta (para poder quitar
-- un registro mal creado de su propio puesto). El auditor no borra resúmenes.
create policy resumen_delete on public.resumen
  for delete to authenticated
  using ( es_admin() or (ruta_id = any(mis_ruta_ids())) );

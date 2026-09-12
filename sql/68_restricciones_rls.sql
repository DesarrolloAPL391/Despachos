-- 68: RLS de restricciones_rutas por rol.
-- AUDITOR (y admin) las CREAN/editan. DESPACHADOR las ve (todas). AFILIADO ve las de SUS carros.
-- (operaciones queda con lectura por control; se puede ajustar).

drop policy if exists restricciones_sel   on public.restricciones_rutas;
drop policy if exists restricciones_write on public.restricciones_rutas;

create policy restricciones_sel on public.restricciones_rutas
  for select to authenticated
  using (
        (select public.es_admin())
     or (select public.es_auditor())
     or (select public.es_operaciones())
     or (select public.es_despachador())
     or ( (select public.es_afiliado())
          and vehiculo = any((select public.mis_moviles_afiliado())::text[]) )
  );

-- Escritura (insert/update/delete): solo admin y auditor.
create policy restricciones_write on public.restricciones_rutas
  for all to authenticated
  using ( (select public.es_admin()) or (select public.es_auditor()) )
  with check ( (select public.es_admin()) or (select public.es_auditor()) );

-- 42: Los monitores (rol auditor / control) ven TODAS las tablas de puesto completas.
-- Antes: pp_sel_aud = es_auditor() AND ruta_id = ANY(rutas_auditor())  -> cada monitor solo veía
-- las tablas de SUS rutas, y 4 de 8 no veían ninguna (sus rutas no tienen tabla de puesto).
-- Ahora: pp_sel_aud = es_auditor()  -> cualquier monitor ve todas las filas (como el admin).
-- La EDICIÓN (pp_upd_aud) se deja acotada a sus rutas a propósito (ver solo amplía lectura).
-- Siguen aplicando las políticas RESTRICTIVAS require_sesion_vigente y require_en_horario
-- (en_horario() ya devuelve true para admin/auditor, así que no los bloquea).

do $$
declare
  t text;
  tabs text[] := array['t_130','t_132a','t_133_133d','t_135_sab','t_193','t_287','t_313','laureles'];
begin
  foreach t in array tabs loop
    if to_regclass('public.'||t) is null then continue; end if;
    if exists (select 1 from pg_policies where schemaname='public' and tablename=t and policyname='pp_sel_aud') then
      execute format('drop policy pp_sel_aud on public.%I', t);
      execute format('create policy pp_sel_aud on public.%I for select to public using (public.es_auditor())', t);
    end if;
  end loop;
end $$;

-- Verificación: deja ver las políticas de lectura de auditor resultantes.
select tablename, policyname, qual
from pg_policies
where schemaname='public' and policyname='pp_sel_aud'
order by tablename;

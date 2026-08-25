-- 51_afiliado_ve_todos_despachos.sql
-- El afiliado ahora ve TODOS los despachos en las tablas (todos los vehículos), como
-- vista EN VIVO de la operación, en SOLO LECTURA. Antes la política pp_sel_afil lo
-- limitaba a sus propios vehículos; ahora solo exige ser afiliado.
--
-- Sigue siendo solo lectura: los afiliados no tienen políticas de INSERT/UPDATE/DELETE,
-- y las RESTRICTIVE (en_horario / sesion_vigente) se mantienen. El mapa (ubicaciones) y
-- Pasajeros NO cambian: siguen mostrando solo sus móviles.
do $$
declare r record;
begin
  for r in
    select schemaname, tablename
    from pg_policies
    where schemaname = 'public' and policyname = 'pp_sel_afil' and cmd = 'SELECT'
  loop
    execute format('alter policy pp_sel_afil on %I.%I using (public.es_afiliado())',
                   r.schemaname, r.tablename);
  end loop;
end $$;

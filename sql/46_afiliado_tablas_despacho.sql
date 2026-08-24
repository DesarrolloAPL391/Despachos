-- 46: El AFILIADO ve, en SOLO LECTURA, las tablas de despacho donde están SUS carros.
--
-- - mis_vehiculo_ids_afiliado(): ids de vehiculo del afiliado logueado (por su correo).
-- - Política RLS de SELECT `pp_sel_afil` en `despachos` + cada tabla de puesto: limita las
--   filas visibles a esos vehiculos (por vehiculo real O programado). Es PERMISIVA y va con
--   guarda es_afiliado(), así no afecta a admin/despachador/auditor (que no la cumplen).
--   La RLS RESTRICTIVE existente (sesión vigente + en_horario) se sigue aplicando; en_horario()
--   ya devuelve true para el afiliado (sql/43).
-- - NO se crean políticas de INSERT/UPDATE/DELETE para el afiliado: queda solo lectura.
-- Idempotente y auto-derivado de tablas_despacho (una tabla de puesto nueva → re-correr esto).

create or replace function public.mis_vehiculo_ids_afiliado()
returns bigint[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct av.vehiculo_id), array[]::bigint[])
  from public.afiliado_vehiculos av
  where lower(trim(av.afiliado_email)) = lower(trim(auth.email()));
$$;
grant execute on function public.mis_vehiculo_ids_afiliado() to authenticated;

do $$
declare
  t text; has_prog boolean; cond text;
begin
  for t in
    select x.tabla
    from (select 'despachos' tabla union all select tabla from public.tablas_despacho where activo) x
    where exists (select 1 from information_schema.columns c
                  where c.table_schema = 'public' and c.table_name = x.tabla and c.column_name = 'vehiculo_id')
  loop
    has_prog := exists (select 1 from information_schema.columns c
                        where c.table_schema = 'public' and c.table_name = t and c.column_name = 'vehiculo_programado_id');
    cond := 'vehiculo_id = any(public.mis_vehiculo_ids_afiliado())';
    if has_prog then
      cond := cond || ' or vehiculo_programado_id = any(public.mis_vehiculo_ids_afiliado())';
    end if;
    execute format('drop policy if exists pp_sel_afil on public.%I', t);
    execute format('create policy pp_sel_afil on public.%I for select to authenticated using (public.es_afiliado() and (%s))', t, cond);
  end loop;
end $$;

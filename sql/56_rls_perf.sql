-- 56_rls_perf.sql
-- FIX de rendimiento RLS: "canceling statement due to statement timeout" al cargar Resumen.
--
-- Causa: las políticas RLS llamaban a en_horario()/es_sesion_vigente()/mis_ruta_ids()
-- SIN envolver → aunque son STABLE, en un filtro se evalúan FILA POR FILA. En `resumen`
-- (5.5k filas) eso son ~16k llamadas a funciones que consultan perfiles/horarios/sesion_activa
-- → EXPLAIN mostró 4,75s y 343k buffers; con la base cargada pasa los 8s del rol → timeout.
--
-- Fix (patrón oficial Supabase): envolver cada función en (select fn()) para que se evalúe
-- UNA sola vez (InitPlan), no por fila. Semánticamente idéntico; solo cambia el rendimiento.

-- 1) Índices que a `resumen` le faltaban (solo tenía la PK). Ayudan al filtro por ruta,
--    el orden por hora_cierre y los filtros por fecha.
create index if not exists resumen_ruta_id_idx    on public.resumen (ruta_id);
create index if not exists resumen_hora_cierre_idx on public.resumen (hora_cierre desc);
create index if not exists resumen_fecha_idx       on public.resumen (fecha);

-- 2) Políticas de `resumen`: envolver las funciones en (select ...).
-- Nota: mis_ruta_ids()/rutas_auditor() devuelven bigint[]; el cast ::bigint[] fuerza
-- "= ANY(array)" (no subconsulta-ANY) manteniendo el InitPlan (se evalúa una sola vez).
alter policy resumen_select on public.resumen
  using ((select public.es_admin())
         or ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
         or (ruta_id = any((select public.mis_ruta_ids())::bigint[])));
alter policy resumen_update on public.resumen
  using ((select public.es_admin())
         or ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
         or (ruta_id = any((select public.mis_ruta_ids())::bigint[])))
  with check (true);
alter policy resumen_delete on public.resumen
  using ((select public.es_admin()) or (ruta_id = any((select public.mis_ruta_ids())::bigint[])));

-- 2b) `despachos` (28k filas) tiene el mismo patrón por-fila (despachos_select/update).
alter policy despachos_select on public.despachos
  using ((select public.es_admin())
         or ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
         or (ruta_id = any((select public.mis_ruta_ids())::bigint[])));
alter policy despachos_update on public.despachos
  using ((select public.es_admin())
         or ((select public.es_auditor()) and ruta_id = any((select public.rutas_auditor())::bigint[]))
         or (ruta_id = any((select public.mis_ruta_ids())::bigint[])))
  with check (true);

-- 2c) Tablas de PUESTO (laureles, t_130, ...): sus políticas pp_* usan es_admin/es_afiliado/
--     es_auditor/mis_puestos/rutas_auditor sin envolver, y algunas traen el nombre de puesto
--     incrustado (ej. lower('Laureles')). Se envuelve por regexp preservando la estructura.
do $$
declare t text; p record; v_using text; v_check text;
  wrap text[] := array[
    'es_admin()','(select public.es_admin())',
    'es_auditor()','(select public.es_auditor())',
    'es_afiliado()','(select public.es_afiliado())',
    'mis_puestos()','(select public.mis_puestos())::text[]',
    'mis_ruta_ids()','(select public.mis_ruta_ids())::bigint[]',
    'rutas_auditor()','(select public.rutas_auditor())::bigint[]'
  ];
  i int;
begin
  for t in select tabla from public.tablas_despacho loop
    for p in select policyname, qual, with_check from pg_policies
             where schemaname='public' and tablename=t
               and policyname not in ('require_en_horario','require_sesion_vigente')
               and coalesce(qual,'')||coalesce(with_check,'') ~ '(es_admin|es_auditor|es_afiliado|mis_puestos|mis_ruta_ids|rutas_auditor)\(\)'
               -- idempotencia: NO tocar las que ya están envueltas (contienen 'select')
               and coalesce(qual,'')||coalesce(with_check,'') !~* 'select' loop
      v_using := p.qual; v_check := p.with_check;
      i := 1;
      while i <= array_length(wrap,1) loop
        if v_using is not null then v_using := replace(v_using, wrap[i], wrap[i+1]); end if;
        if v_check is not null then v_check := replace(v_check, wrap[i], wrap[i+1]); end if;
        i := i + 2;
      end loop;
      if v_using is not null and v_check is not null then
        execute format('alter policy %I on public.%I using (%s) with check (%s)', p.policyname, t, v_using, v_check);
      elsif v_using is not null then
        execute format('alter policy %I on public.%I using (%s)', p.policyname, t, v_using);
      elsif v_check is not null then
        execute format('alter policy %I on public.%I with check (%s)', p.policyname, t, v_check);
      end if;
    end loop;
  end loop;
end $$;

-- 3) Las DOS políticas universales (en TODAS las tablas que las tengan): envolver en (select ...).
--    Son idénticas en todas las tablas (ALL restrictivas), así que se pueden alterar en lote.
do $$
declare r record;
begin
  for r in select tablename from pg_policies
           where schemaname='public' and policyname='require_en_horario' loop
    execute format(
      'alter policy require_en_horario on public.%I using ((select public.en_horario())) with check ((select public.en_horario()))',
      r.tablename);
  end loop;
  for r in select tablename from pg_policies
           where schemaname='public' and policyname='require_sesion_vigente' loop
    execute format(
      'alter policy require_sesion_vigente on public.%I using ((select public.es_sesion_vigente())) with check ((select public.es_sesion_vigente()))',
      r.tablename);
  end loop;
end $$;

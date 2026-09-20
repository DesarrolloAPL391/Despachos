-- ============================================================================================
-- 85) SEGURIDAD VIAL: que Gestión Humana también vea la conducción
--
-- El menú "Seguridad vial" junta tres cosas: los siniestros, los excesos de velocidad y las
-- puertas abiertas. Los siniestros ya los ve Gestión Humana (sql/80), pero los eventos del GPS
-- seguían reservados a administración y auditoría, así que con esa cuenta el menú aparecía a
-- medias. Como las alertas de sensibilización a los conductores las arma Gestión Humana, se
-- amplía el permiso de lectura igual que con los siniestros: es_talento_humano() = admin +
-- Gestión Humana, y se conserva el auditor.
--
-- Lo que NO se amplía:
--   * eventos_bus_config  → el umbral (60 km/h) lo cambia solo el administrador.
--   * eventos_bus_cargar  → traer un día a mano desde SONAR sigue siendo del administrador.
--
-- Incluye la columna `categoria` de sql/84 (con "if not exists"), para que baste con ejecutar
-- este archivo si aquel quedó pendiente. Se aplica sobre sql/81, 82 y 83.
-- ============================================================================================

-- 0) La categoría que usan las entradas del menú (de sql/84, repetida sin efecto si ya está) ---
alter table public.eventos_bus
  add column if not exists categoria text
  generated always as (case when tipo = 'puerta' then 'PUERTA ABIERTA' else 'VELOCIDAD' end) stored;

create index if not exists eventos_bus_categoria_idx on public.eventos_bus (categoria, fecha desc);

comment on column public.eventos_bus.categoria is
  'VELOCIDAD (exceso o más de 60) | PUERTA ABIERTA. Calculada desde `tipo`, para el menú Seguridad vial.';

-- 1) Lectura de los eventos y de la bitácora de carga -----------------------------------------
drop policy if exists eventos_bus_ver      on public.eventos_bus;
drop policy if exists eventos_bus_vial     on public.eventos_bus;
create policy eventos_bus_vial on public.eventos_bus
  for select to authenticated
  using ((select public.es_talento_humano()) or (select public.es_auditor()));

drop policy if exists eventos_bus_sync_ver  on public.eventos_bus_sync;
drop policy if exists eventos_bus_sync_vial on public.eventos_bus_sync;
create policy eventos_bus_sync_vial on public.eventos_bus_sync
  for select to authenticated
  using ((select public.es_talento_humano()) or (select public.es_auditor()));

-- 2) Resumen por conductor (cuenta episodios, igual que en sql/83; solo cambia quién puede) ----
create or replace function public.eventos_bus_resumen(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare v_items jsonb; v_dias int; v_umbral numeric;
begin
  if not (public.es_talento_humano() or public.es_auditor()) then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver los eventos de conducción.');
  end if;
  select umbral_kmh into v_umbral from public.eventos_bus_config where id = 1;

  select coalesce(jsonb_agg(x order by n_rap desc, n_exc desc, n_pue desc), '[]'::jsonb) into v_items
  from (
    select
      coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0)    as n_rap,
      coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0) as n_exc,
      coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0) as n_pue,
      jsonb_build_object(
        'conductor', coalesce(b.conductor, '(sin viaje asociado)'),
        'cedula',    b.conductor_cedula,
        'codigo',    b.conductor_codigo,
        'excesos',   coalesce(sum(b.inicio) filter (where b.tipo = 'exceso'), 0),
        'rapidos',   coalesce(sum(b.inicio) filter (where b.sobre_umbral), 0),
        'puertas',   coalesce(sum(b.inicio) filter (where b.tipo = 'puerta'), 0),
        'lecturas',  count(1),
        'peor_exceso', max(b.exceso_kmh) filter (where b.tipo = 'exceso'),
        'vel_max',   max(b.velocidad),
        'dias',      count(distinct b.fecha),
        'moviles',   count(distinct b.movil),
        'ultimo',    to_char(max(b.fecha), 'YYYY-MM-DD')
      ) as x
    from (
      select e.*,
        (coalesce(extract(epoch from (e.ocurrido_en
           - lag(e.ocurrido_en) over (partition by e.mid, e.tipo, e.conductor order by e.ocurrido_en))),
          1e9) > 300)::int as inicio
      from public.eventos_bus e
      where e.fecha between p_desde and p_hasta
    ) b
    group by b.conductor, b.conductor_cedula, b.conductor_codigo
  ) s;

  select count(distinct fecha) into v_dias from public.eventos_bus where fecha between p_desde and p_hasta;
  return jsonb_build_object('ok', true, 'desde', p_desde, 'hasta', p_hasta,
                            'dias_con_datos', v_dias, 'items', v_items, 'umbral_kmh', v_umbral,
                            'por_episodios', true);
end $$;
revoke all on function public.eventos_bus_resumen(date, date) from public, anon;
grant execute on function public.eventos_bus_resumen(date, date) to authenticated;

-- 3) Estado de la carga (hasta qué día hay histórico y cuántos carros faltan) ------------------
create or replace function public.eventos_bus_estado()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select case when not (public.es_talento_humano() or public.es_auditor()) then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'total',        (select count(1) from public.eventos_bus),
      'desde',        (select min(fecha) from public.eventos_bus),
      'hasta',        (select max(fecha) from public.eventos_bus),
      'ultima_carga', (select max(sincronizado_en) from public.eventos_bus_sync),
      'dias',         (select count(distinct fecha) from public.eventos_bus_sync where ok),
      'umbral_kmh', (select umbral_kmh from public.eventos_bus_config where id = 1),
      'carros',     (select count(1) from public.eventos_bus_trackers()),
      'revisados_ayer', (select count(1) from public.eventos_bus_sync s
                          where s.fecha = (now() at time zone 'America/Bogota')::date - 1 and s.ok),
      'pendientes_ayer', (select count(1) from public.eventos_bus_trackers() k
                           where not exists (select 1 from public.eventos_bus_sync s
                                             where s.fecha = (now() at time zone 'America/Bogota')::date - 1
                                               and s.mid = k.mid and s.ok)))
  end;
$$;
revoke all on function public.eventos_bus_estado() from public, anon;
grant execute on function public.eventos_bus_estado() to authenticated;

-- 4) Comprobación: debe listar eventos_bus_vial y eventos_bus_sync_vial con es_talento_humano()
-- select tablename, policyname, qual from pg_policies
--  where tablename in ('eventos_bus','eventos_bus_sync') order by tablename;

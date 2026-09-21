-- ============================================================================================
-- 90) PQRSF: el resumen que alimenta las estadísticas y la bandeja de pendientes
--
-- Dos funciones:
--   · pqrsf_resumen(desde, hasta)  → todo lo que dibujan las pantallas, ya agregado en el
--     servidor: indicadores, cumplimiento mes a mes, tiempos de respuesta, motivos, tipos,
--     rutas, vehículos, medios, áreas y días de la semana.
--   · pqrsf_pendientes()           → lo que falta por responder, de lo más vencido a lo menos.
--
-- El cumplimiento SIEMPRE sale de las fechas (columna calculada de sql/89), no de la columna
-- "CUMPLIMIENTO" de la hoja, que se contradice consigo misma.
--
-- "Pendiente" es lo que no tiene fecha de respuesta, o lo que sigue marcado ABIERTA. Los días
-- de atraso se cuentan contra la fecha límite del área responsable.
-- ============================================================================================

create or replace function public.pqrsf_resumen(p_desde date, p_hasta date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_res jsonb;
begin
  if not public.es_pqrsf() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver las PQRSF.');
  end if;

  with base as materialized (
    select * from public.pqrsf
    where (p_desde is null or fecha_radicado >= p_desde)
      and (p_hasta is null or fecha_radicado <= p_hasta)
  ),
  mes as (
    select to_char(fecha_radicado, 'YYYY-MM') as k, count(1) as n,
           count(1) filter (where cumplimiento = 'A TIEMPO')      as a_tiempo,
           count(1) filter (where cumplimiento = 'FUERA DE PLAZO') as tarde,
           count(1) filter (where cumplimiento = 'SIN RESPUESTA')  as sin_resp
    from base where fecha_radicado is not null group by 1
  ),
  tipo as (
    select coalesce(tipo, '(sin tipo)') as k, count(1) as n from base group by 1 order by 2 desc
  ),
  motivo as (
    select coalesce(motivo, '(sin motivo)') as k, count(1) as n from base group by 1 order by 2 desc limit 20
  ),
  ruta as (
    select coalesce(nullif(trim(ruta), ''), '(sin ruta)') as k, count(1) as n
    from base group by 1 order by 2 desc limit 20
  ),
  movil as (
    select numero_interno as k, count(1) as n,
           count(1) filter (where tipo = 'QUEJA')  as quejas,
           count(1) filter (where requiere_proceso) as con_proceso,
           max(fecha_radicado)::text               as ultimo
    from base where coalesce(nullif(trim(numero_interno), ''), '') <> ''
    group by 1 order by 2 desc limit 25
  ),
  medio as (
    select coalesce(medio_recibido, '(sin dato)') as k, count(1) as n from base group by 1 order by 2 desc
  ),
  area as (
    select coalesce(responsable_destino, '(sin asignar)') as k, count(1) as n,
           count(1) filter (where cumplimiento = 'A TIEMPO')       as a_tiempo,
           count(1) filter (where cumplimiento = 'FUERA DE PLAZO') as tarde,
           count(1) filter (where cumplimiento = 'SIN RESPUESTA')  as sin_resp,
           round(avg(dias_respuesta) filter (where dias_respuesta >= 0 and dias_respuesta <= 400), 1) as dias_prom
    from base group by 1 order by 2 desc
  ),
  dia as (
    select extract(dow from fecha_radicado)::int as k, count(1) as n
    from base where fecha_radicado is not null group by 1
  ),
  demora as (
    select case when dias_respuesta <= 3  then 'Hasta 3 dias'
                when dias_respuesta <= 7  then 'De 4 a 7 dias'
                when dias_respuesta <= 15 then 'De 8 a 15 dias'
                when dias_respuesta <= 30 then 'De 16 a 30 dias'
                else 'Mas de 30 dias' end as k,
           case when dias_respuesta <= 3 then 0 when dias_respuesta <= 7 then 1
                when dias_respuesta <= 15 then 2 when dias_respuesta <= 30 then 3 else 4 end as orden,
           count(1) as n
    from base where dias_respuesta is not null and dias_respuesta between 0 and 400
    group by 1, 2
  ),
  kpi as (
    select
      count(1)                                                      as total,
      count(1) filter (where estado = 'ABIERTA')                    as abiertas,
      count(1) filter (where cumplimiento = 'A TIEMPO')             as a_tiempo,
      count(1) filter (where cumplimiento = 'FUERA DE PLAZO')       as tarde,
      count(1) filter (where cumplimiento = 'SIN RESPUESTA')        as sin_resp,
      count(1) filter (where tipo = 'QUEJA')                        as quejas,
      count(1) filter (where tipo in ('FELICITACION', 'FELICITACIONES')) as felicitaciones,
      count(1) filter (where requiere_proceso)                      as con_proceso,
      count(distinct numero_interno) filter (where coalesce(nullif(trim(numero_interno), ''), '') <> '') as moviles,
      round(avg(dias_respuesta) filter (where dias_respuesta between 0 and 400), 1) as dias_prom,
      percentile_disc(0.5) within group (order by dias_respuesta)
        filter (where dias_respuesta between 0 and 400)             as dias_medio,
      min(fecha_radicado)::text                                     as desde,
      max(fecha_radicado)::text                                     as hasta
    from base
  )
  select jsonb_build_object(
    'ok', true, 'desde', p_desde, 'hasta', p_hasta,
    'kpi', (select to_jsonb(k) from kpi k),
    'por_mes',    (select coalesce(jsonb_agg(to_jsonb(m) order by m.k), '[]'::jsonb) from mes m),
    'por_tipo',   (select coalesce(jsonb_agg(to_jsonb(t) order by t.n desc), '[]'::jsonb) from tipo t),
    'por_motivo', (select coalesce(jsonb_agg(to_jsonb(x) order by x.n desc), '[]'::jsonb) from motivo x),
    'por_ruta',   (select coalesce(jsonb_agg(to_jsonb(r) order by r.n desc), '[]'::jsonb) from ruta r),
    'por_movil',  (select coalesce(jsonb_agg(to_jsonb(v) order by v.n desc), '[]'::jsonb) from movil v),
    'por_medio',  (select coalesce(jsonb_agg(to_jsonb(e) order by e.n desc), '[]'::jsonb) from medio e),
    'por_area',   (select coalesce(jsonb_agg(to_jsonb(a) order by a.n desc), '[]'::jsonb) from area a),
    'por_dia',    (select coalesce(jsonb_agg(to_jsonb(d) order by d.k), '[]'::jsonb) from dia d),
    'demora',     (select coalesce(jsonb_agg(jsonb_build_object('k', k, 'n', n) order by orden), '[]'::jsonb) from demora)
  ) into v_res;

  return v_res;
end $$;
revoke all on function public.pqrsf_resumen(date, date) from public, anon;
grant execute on function public.pqrsf_resumen(date, date) to authenticated;

-- 2) Lo que falta por responder ----------------------------------------------------------------
--    Pendiente = sin fecha de respuesta, o marcada ABIERTA. Se ordena por lo más vencido.
create or replace function public.pqrsf_pendientes(p_limite int default 500)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public'
as $$
declare v_items jsonb; v_hoy date := (now() at time zone 'America/Bogota')::date; v_lim int;
begin
  if not public.es_pqrsf() then
    return jsonb_build_object('ok', false, 'error', 'No tienes permiso para ver las PQRSF.');
  end if;
  v_lim := greatest(least(coalesce(p_limite, 500), 2000), 1);

  select coalesce(jsonb_agg(to_jsonb(x) order by x.atraso desc nulls last, x.fecha_radicado), '[]'::jsonb)
    into v_items
  from (
    select p.key, p.radicado, p.fecha_radicado, p.fecha_limite, p.tipo, p.motivo, p.urgencia,
           p.numero_interno, p.ruta, p.responsable_destino, p.estado, p.medio_recibido,
           p.usuario_nombre,
           (v_hoy - p.fecha_limite) as atraso,          -- positivo = días vencida
           (v_hoy - p.fecha_radicado) as edad
    from public.pqrsf p
    where p.fecha_respuesta is null or p.estado = 'ABIERTA'
    order by (v_hoy - p.fecha_limite) desc nulls last, p.fecha_radicado
    limit v_lim
  ) x;

  return jsonb_build_object(
    'ok', true, 'hoy', v_hoy,
    'total',    (select count(1) from public.pqrsf where fecha_respuesta is null or estado = 'ABIERTA'),
    'vencidas', (select count(1) from public.pqrsf
                  where (fecha_respuesta is null or estado = 'ABIERTA')
                    and fecha_limite is not null and fecha_limite < v_hoy),
    'items', v_items);
end $$;
revoke all on function public.pqrsf_pendientes(int) from public, anon;
grant execute on function public.pqrsf_pendientes(int) to authenticated;

-- Comprobación (en el SQL Editor da ok:false por el guard de rol; se ve desde la app):
-- select public.pqrsf_resumen(null, null);
--
-- Estas sí corren en el SQL Editor:
-- select cumplimiento, count(1) from public.pqrsf group by 1 order by 2 desc;
-- select count(1) as pendientes from public.pqrsf where fecha_respuesta is null or estado = 'ABIERTA';

-- 3) El estado gana dos cifras: cuántas faltan por responder y cuántas ya están vencidas -------
--    (reemplaza la versión de sql/89; el menú las usa para el aviso)
create or replace function public.pqrsf_estado()
returns jsonb
language sql stable security definer set search_path to 'public'
as $$
  select case when not public.es_pqrsf() then jsonb_build_object('ok', false)
    else jsonb_build_object(
      'ok', true,
      'puede_cargar', public.es_pqrsf_editor(),
      'url',          (select url from public.pqrsf_fuente where id = 1),
      'ultima_carga', (select ultima_carga from public.pqrsf_fuente where id = 1),
      'total',        (select count(1) from public.pqrsf),
      'desde',        (select min(fecha_radicado) from public.pqrsf),
      'hasta',        (select max(fecha_radicado) from public.pqrsf),
      'abiertas',     (select count(1) from public.pqrsf where estado = 'ABIERTA'),
      'sin_respuesta',(select count(1) from public.pqrsf where cumplimiento = 'SIN RESPUESTA'),
      'fuera_plazo',  (select count(1) from public.pqrsf where cumplimiento = 'FUERA DE PLAZO'),
      'pendientes',   (select count(1) from public.pqrsf
                        where fecha_respuesta is null or estado = 'ABIERTA'),
      'vencidas',     (select count(1) from public.pqrsf
                        where (fecha_respuesta is null or estado = 'ABIERTA')
                          and fecha_limite is not null
                          and fecha_limite < (now() at time zone 'America/Bogota')::date))
  end;
$$;
revoke all on function public.pqrsf_estado() from public, anon;
grant execute on function public.pqrsf_estado() to authenticated;

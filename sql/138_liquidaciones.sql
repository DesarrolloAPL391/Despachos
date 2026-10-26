-- 138_liquidaciones.sql
-- "quiero integrar esta base de datos que son unas liquidaciones de unos vehiculos, esta todo
--  el historial, lo quiero paginar y quiero crear la base de datos" +
-- "en la liquidacion debe de quedar que conductor es con cedula" (24/10/2026).
--
-- QUE TRAE LA HOJA: 29.237 lineas, 13 columnas, del 01/01/2025 al 22/10/2026. Una fila por
-- VEHICULO + FECHA + RUTA, con los pasajeros de la civica y la plata a liquidar.
-- 28.919 filas con datos (318 vienen vacias al final de la hoja), 58 vehiculos, 149 conductores,
-- 1 propietario. Total del historial: $2.454.992.000.
--
-- LO QUE SE MIDIO ANTES DE DISENAR (no son supuestos):
--   * TOTAL A LIQUIDAR = UNIDADES - PASAJEROS A DESCONTAR -> se cumple en 28.917 de 28.918.
--     La que no cuadra: key 6f76d074, 26/04/2025, movil 8258 (147-8 deberia dar 139, dice 129).
--   * PASAJEROS A DESCONTAR = VIAJES DEL VEHICULO -> se cumple en el 100%.
--   * DINERO = LIQUIDAR x tarifa, y la tarifa cambia por periodo: $3.200 (primeros dias de
--     2025), $3.400 (resto de 2025) y $3.800 (desde enero de 2026).
--   * LIQUIDAR no sale de una formula fija de la hoja: es la decision de cuanto se paga. Por eso
--     se guarda tal cual viene y no se recalcula aqui.
--
-- EL PARSEO ES DIRECTO, NO con csv_a_json (sql/133): se comprobo que TODAS las lineas traen
-- exactamente 12 comas y que en todo el archivo hay solo 2 comillas (en la cabecera). Sin comas
-- dentro de los campos, partir por coma es seguro -- y sobre todo es por conjuntos y no fila por
-- fila: con 29.000 filas el parser de sql/133 no cabria en el tope de 120 s de los crons.
--
-- LA CEDULA DEL CONDUCTOR se resuelve cruzando el nombre con `perfilsociodemografico`,
-- normalizado (mayusculas, sin tildes, espacios colapsados). Cruzan **147 de 149 conductores,
-- sin un solo caso ambiguo**. Los 2 que no cruzan (47 filas de 28.919) quedan con cedula nula y
-- salen listados en la pantalla para corregirlos en la hoja.
--
-- LA URL DE LA HOJA VA EN LA TABLA `liquidaciones_fuente`, con RLS de administrador, NUNCA en
-- el codigo: el repositorio es publico y la hoja lleva nombres de personas.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

-- ---------------------------------------------------------------------------
-- 1) De donde se lee (el enlace no se escribe en el repositorio)
-- ---------------------------------------------------------------------------
create table if not exists public.liquidaciones_fuente (
  id            int primary key default 1 check (id = 1),
  url           text,
  actualizado_en timestamptz default now()
);
alter table public.liquidaciones_fuente enable row level security;

drop policy if exists liq_fuente_admin on public.liquidaciones_fuente;
create policy liq_fuente_admin on public.liquidaciones_fuente
  for all to authenticated
  using ((select public.es_admin())) with check ((select public.es_admin()));

insert into public.liquidaciones_fuente (id, url) values (1, null) on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 2) La tabla
-- ---------------------------------------------------------------------------
create table if not exists public.liquidaciones (
  key              text primary key,
  fecha            date not null,
  ruta             text,
  viajes           int,
  movil            text,
  conductor        text,
  conductor_cedula text,
  unidades         int,
  descontar        int,
  total_liquidar   int,
  liquidar         int,
  dinero           bigint,
  punto            text,
  propietario      text,
  -- Para no tener que recalcularlo en cada consulta: deja ver de una si la hoja cuadra.
  cuadra           boolean generated always as
                     (unidades is not null and descontar is not null
                      and total_liquidar is not null
                      and unidades - descontar = total_liquidar) stored,
  creado_en        timestamptz not null default now(),
  actualizado_en   timestamptz not null default now()
);

comment on table  public.liquidaciones is 'Liquidacion por vehiculo, fecha y ruta. Se lee de la hoja de Google (sql/138).';
comment on column public.liquidaciones.liquidar is 'Unidades que se pagan. Es una decision, no una formula: se guarda como viene en la hoja.';
comment on column public.liquidaciones.cuadra is 'false = la propia hoja no cuadra (unidades - descontar <> total).';

create index if not exists liq_fecha_idx     on public.liquidaciones (fecha desc);
create index if not exists liq_movil_idx     on public.liquidaciones (movil, fecha desc);
create index if not exists liq_cedula_idx    on public.liquidaciones (conductor_cedula);
create index if not exists liq_ruta_idx      on public.liquidaciones (ruta);
create index if not exists liq_punto_idx     on public.liquidaciones (punto);

alter table public.liquidaciones enable row level security;
-- Solo administracion, y solo de lectura: lo que entra, entra por la sincronizacion.
drop policy if exists liq_admin_lee on public.liquidaciones;
create policy liq_admin_lee on public.liquidaciones
  for select to authenticated using ((select public.es_admin()));

-- ---------------------------------------------------------------------------
-- 3) Normalizar un nombre para cruzarlo (mayusculas, sin tildes, un solo espacio)
-- ---------------------------------------------------------------------------
create or replace function public._nom_cmp(v text)
returns text language sql immutable as $function$
  select regexp_replace(
           btrim(translate(upper(coalesce(v, '')),
                           'ÁÉÍÓÚÜÑáéíóúüñ', 'AEIOUUNAEIOUUN')),
           '\s+', ' ', 'g');
$function$;

-- ---------------------------------------------------------------------------
-- 4) La sincronizacion
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_sync(p_aplicar boolean default false)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions'
as $function$
declare
  v_url text; v_resp extensions.http_response; v_txt text;
  v_leidas int := 0; v_nuevas int := 0; v_cambios int := 0; v_malas int := 0;
  v_antes int; v_desde date; v_hasta date;
begin
  if not (select public.es_admin()) and current_user not in ('postgres', 'supabase_admin') then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  select url into v_url from public.liquidaciones_fuente where id = 1;
  if coalesce(btrim(v_url), '') = '' then
    return jsonb_build_object('ok', false, 'error',
      'Falta configurar el enlace de la hoja en liquidaciones_fuente.');
  end if;

  perform set_config('http.timeout_msec', '90000', true);
  select * into v_resp from extensions.http_get(v_url);
  if v_resp.status <> 200 then
    return jsonb_build_object('ok', false, 'error', 'La hoja respondio HTTP ' || v_resp.status);
  end if;
  v_txt := v_resp.content;

  -- Partir por conjuntos: una pasada por el texto, sin bucle fila por fila.
  drop table if exists _liq;
  create temp table _liq on commit drop as
  with lineas as (
    select row_number() over () as nro, btrim(l, E'\r') as l
      from regexp_split_to_table(coalesce(v_txt, ''), E'\n') as l
  ),
  campos as (
    select string_to_array(l, ',') as c
      from lineas
     where nro > 1 and btrim(l) <> ''
  )
  select btrim(c[1])                                   as key,
         public._f_cl(btrim(c[2]))                     as fecha,
         upper(btrim(c[3]))                            as ruta,   -- la hoja mezcla 133I y 133i
         nullif(btrim(c[4]), '')::int                  as viajes,
         btrim(c[5])                                   as movil,
         btrim(c[6])                                   as conductor,
         nullif(btrim(c[7]), '')::int                  as unidades,
         nullif(btrim(c[8]), '')::int                  as descontar,
         nullif(btrim(c[9]), '')::int                  as total_liquidar,
         nullif(btrim(c[10]), '')::int                 as liquidar,
         nullif(btrim(c[11]), '')::bigint              as dinero,
         btrim(coalesce(c[12], ''))                    as punto,
         btrim(coalesce(c[13], ''))                    as propietario
    from campos
   where coalesce(btrim(c[1]), '') <> ''
     and array_length(c, 1) >= 11;

  select count(*) into v_leidas from _liq;
  select count(*) into v_malas  from _liq where fecha is null;

  -- La hoja trae 1 KEY repetida: con el duplicado dentro, el "on conflict" falla entero.
  delete from _liq a using _liq b
   where a.key = b.key and a.ctid < b.ctid;

  select min(fecha), max(fecha) into v_desde, v_hasta from _liq where fecha is not null;

  if not p_aplicar then
    return jsonb_build_object('ok', true, 'simulacion', true,
      'leidas', v_leidas, 'sin_fecha', v_malas, 'desde', v_desde, 'hasta', v_hasta,
      'ya_en_base', (select count(*) from public.liquidaciones),
      'nuevas', (select count(*) from _liq t
                  where t.fecha is not null
                    and not exists (select 1 from public.liquidaciones l where l.key = t.key)));
  end if;

  select count(*) into v_antes from public.liquidaciones;

  -- Cada conductor una sola vez: se comprobo que no hay nombres ambiguos, pero si manana
  -- aparece uno, se prefiere el activo y no se multiplican las filas.
  with per as (
    select distinct on (public._nom_cmp(nombre))
           public._nom_cmp(nombre) as k, cedula
      from public.perfilsociodemografico
     where coalesce(btrim(nombre), '') <> ''
     order by public._nom_cmp(nombre), (estado = 'ACTIVO') desc, cedula
  ),
  up as (
    insert into public.liquidaciones as l
      (key, fecha, ruta, viajes, movil, conductor, conductor_cedula,
       unidades, descontar, total_liquidar, liquidar, dinero, punto, propietario)
    select t.key, t.fecha, t.ruta, t.viajes, t.movil, t.conductor, p.cedula,
           t.unidades, t.descontar, t.total_liquidar, t.liquidar, t.dinero,
           nullif(t.punto, ''), nullif(t.propietario, '')
      from _liq t
      left join per p on p.k = public._nom_cmp(t.conductor)
     where t.fecha is not null
    on conflict (key) do update set
      fecha = excluded.fecha, ruta = excluded.ruta, viajes = excluded.viajes,
      movil = excluded.movil, conductor = excluded.conductor,
      conductor_cedula = excluded.conductor_cedula,
      unidades = excluded.unidades, descontar = excluded.descontar,
      total_liquidar = excluded.total_liquidar, liquidar = excluded.liquidar,
      dinero = excluded.dinero, punto = excluded.punto, propietario = excluded.propietario,
      actualizado_en = now()
    where l.fecha is distinct from excluded.fecha
       or l.ruta is distinct from excluded.ruta
       or l.viajes is distinct from excluded.viajes
       or l.movil is distinct from excluded.movil
       or l.conductor is distinct from excluded.conductor
       or l.conductor_cedula is distinct from excluded.conductor_cedula
       or l.unidades is distinct from excluded.unidades
       or l.descontar is distinct from excluded.descontar
       or l.total_liquidar is distinct from excluded.total_liquidar
       or l.liquidar is distinct from excluded.liquidar
       or l.dinero is distinct from excluded.dinero
       or l.punto is distinct from excluded.punto
    returning 1
  ) select count(*) into v_cambios from up;

  v_nuevas := (select count(*) from public.liquidaciones) - v_antes;

  return jsonb_build_object('ok', true,
    'leidas', v_leidas, 'sin_fecha', v_malas,
    'nuevas', v_nuevas, 'actualizadas', greatest(0, v_cambios - v_nuevas),
    'desde', v_desde, 'hasta', v_hasta,
    'total', (select count(*) from public.liquidaciones),
    'sin_cedula', (select count(*) from public.liquidaciones where conductor_cedula is null));
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

revoke all on function public.liquidaciones_sync(boolean) from public, anon;
grant execute on function public.liquidaciones_sync(boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) Todos los dias a las 5:40 a.m. de Colombia (10:40 UTC), antes de la jornada.
--    La hoja se alimenta a diario; la sincronizacion es idempotente (vuelve a leer todo y
--    solo toca lo que cambio).
-- ---------------------------------------------------------------------------
select cron.unschedule('sync-liquidaciones')
 where exists (select 1 from cron.job where jobname = 'sync-liquidaciones');
select cron.schedule('sync-liquidaciones', '40 10 * * *',
                     $cron$select public.liquidaciones_sync(true)$cron$);

-- Comprobacion (solo lectura; la carga se hace llamando liquidaciones_sync(true) aparte)
select 'tabla liquidaciones creada' as dato,
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from information_schema.tables
         where table_schema = 'public' and table_name = 'liquidaciones') as valor
union all
select 'enlace de la hoja configurado',
       (select case when coalesce(btrim(url), '') = '' then 'FALTA' else 'si' end
          from public.liquidaciones_fuente where id = 1)
union all
select 'cron sync-liquidaciones activo',
       (select case when count(*) > 0 then 'si' else 'NO' end::text
          from cron.job where jobname = 'sync-liquidaciones' and active)
union all
select 'filas ya cargadas',
       (select count(*)::text from public.liquidaciones);

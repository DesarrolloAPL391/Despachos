-- 139_liquidaciones_descarga.sql
-- La descarga de la hoja de liquidaciones en DOS TIEMPOS, porque la de un solo tiempo no sirve.
--
-- QUE PASO (medido el 24/10/2026): `liquidaciones_sync` (sql/138) usaba extensions.http_get,
-- que es SINCRONO: la consulta se queda esperando a Google. Con esta hoja -- 3,85 MB, casi 30
-- veces la del personal -- nunca termina: a los 90 s devuelve "Operation timed out with 0 bytes
-- received", y con mas tiempo el servidor corta la consulta entera ("HTTP request cancelled").
--
-- LO QUE SI FUNCIONA: `pg_net`, que descarga en segundo plano. La misma URL devolvio HTTP 200
-- con los 3.854.868 bytes completos, sin expirar. Y el parseo, una vez el texto esta en la
-- base, tarda **1 segundo** para las 28.919 filas (va por conjuntos, no fila por fila). O sea:
-- el problema nunca fue el volumen de datos, era esperar a Google dentro de la consulta.
--
-- POR ESO SON DOS PASOS:
--   1) `liquidaciones_pedir()`    -> lanza la descarga y se va. Guarda el numero de peticion.
--   2) `liquidaciones_procesar()` -> cuando la respuesta ya esta, la parsea y actualiza.
-- Si al procesar la respuesta todavia no llego, no hace nada y lo dice: el siguiente intento
-- la encuentra. Asi ninguna de las dos se acerca al tope de 120 s de los crons.
--
-- NOTA: las comprobaciones del final son de SOLO LECTURA a proposito (ver sql/131).

alter table public.liquidaciones_fuente
  add column if not exists request_id   bigint,
  add column if not exists pedido_en    timestamptz,
  add column if not exists procesado_id bigint,
  add column if not exists procesado_en timestamptz,
  add column if not exists resultado    jsonb;

comment on column public.liquidaciones_fuente.request_id is 'Numero de la peticion de pg_net que esta en curso.';
comment on column public.liquidaciones_fuente.procesado_id is 'Ultima peticion ya procesada: evita volver a cargar lo mismo.';

-- ---------------------------------------------------------------------------
-- Paso 1: pedir la hoja (no espera a que llegue)
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_pedir()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare v_url text; v_id bigint;
begin
  if not (select public.es_admin()) and current_user not in ('postgres', 'supabase_admin') then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  select url into v_url from public.liquidaciones_fuente where id = 1;
  if coalesce(btrim(v_url), '') = '' then
    return jsonb_build_object('ok', false, 'error',
      'Falta configurar el enlace de la hoja en liquidaciones_fuente.');
  end if;

  -- 280 s, no 120: Google tarda MAS DE DOS MINUTOS en generar este CSV y es irregular
  -- (una peticion trajo los 3,85 MB y la siguiente expiro a los 120 s). Como pg_net es
  -- asincrono, esperar de mas no bloquea nada: el que espera es el descargador, no la base.
  select net.http_get(v_url, timeout_milliseconds => 280000) into v_id;
  update public.liquidaciones_fuente
     set request_id = v_id, pedido_en = now()
   where id = 1;

  return jsonb_build_object('ok', true, 'peticion', v_id,
                            'nota', 'La hoja se esta descargando. Procesar en unos segundos.');
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

revoke all on function public.liquidaciones_pedir() from public, anon;
grant execute on function public.liquidaciones_pedir() to authenticated;

-- ---------------------------------------------------------------------------
-- Paso 2: procesar lo que llego
-- ---------------------------------------------------------------------------
create or replace function public.liquidaciones_procesar()
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'net'
as $function$
declare
  v_req bigint; v_hecho bigint; v_st int; v_err text; v_txt text;
  v_leidas int := 0; v_malas int := 0; v_antes int; v_toc int := 0; v_nuevas int;
  v_desde date; v_hasta date; v_out jsonb;
begin
  if not (select public.es_admin()) and current_user not in ('postgres', 'supabase_admin') then
    return jsonb_build_object('ok', false, 'error', 'Solo el administrador.');
  end if;

  select request_id, procesado_id into v_req, v_hecho
    from public.liquidaciones_fuente where id = 1;

  if v_req is null then
    return jsonb_build_object('ok', false, 'error', 'No hay ninguna descarga pedida.');
  end if;
  if v_req is not distinct from v_hecho then
    return jsonb_build_object('ok', true, 'sin_cambios', true,
                              'nota', 'Esa descarga ya se habia procesado.');
  end if;

  select status_code, error_msg, content into v_st, v_err, v_txt
    from net._http_response where id = v_req;

  if not found then
    return jsonb_build_object('ok', true, 'esperando', true,
                              'nota', 'La hoja todavia se esta descargando.');
  end if;
  if coalesce(v_st, 0) <> 200 then
    return jsonb_build_object('ok', false,
      'error', 'La hoja respondio ' || coalesce(v_st::text, 'sin codigo') ||
               coalesce(' - ' || v_err, ''));
  end if;

  -- Parseo por conjuntos: 1 segundo para 29.000 filas. Se comprobo que todas las lineas traen
  -- 12 comas y que no hay comas dentro de los campos, por eso partir por coma es seguro.
  drop table if exists _liq;
  create temp table _liq on commit drop as
  with lineas as (
    select row_number() over () as nro, btrim(l, E'\r') as l
      from regexp_split_to_table(coalesce(v_txt, ''), E'\n') as l
  ),
  campos as (
    select string_to_array(l, ',') as c from lineas where nro > 1 and btrim(l) <> ''
  )
  select btrim(c[1])                      as key,
         public._f_cl(btrim(c[2]))        as fecha,
         upper(btrim(c[3]))               as ruta,     -- la hoja mezcla 133I y 133i
         nullif(btrim(c[4]), '')::int     as viajes,
         btrim(c[5])                      as movil,
         btrim(c[6])                      as conductor,
         nullif(btrim(c[7]), '')::int     as unidades,
         nullif(btrim(c[8]), '')::int     as descontar,
         nullif(btrim(c[9]), '')::int     as total_liquidar,
         nullif(btrim(c[10]), '')::int    as liquidar,
         nullif(btrim(c[11]), '')::bigint as dinero,
         btrim(coalesce(c[12], ''))       as punto,
         btrim(coalesce(c[13], ''))       as propietario
    from campos
   where coalesce(btrim(c[1]), '') <> ''
     and array_length(c, 1) >= 11;

  select count(*) into v_leidas from _liq;
  select count(*) into v_malas  from _liq where fecha is null;

  -- La hoja trae 1 KEY repetida: con el duplicado dentro, el "on conflict" falla entero.
  delete from _liq a using _liq b where a.key = b.key and a.ctid < b.ctid;

  select min(fecha), max(fecha) into v_desde, v_hasta from _liq where fecha is not null;
  select count(*) into v_antes from public.liquidaciones;

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
  ) select count(*) into v_toc from up;

  v_nuevas := (select count(*) from public.liquidaciones) - v_antes;

  v_out := jsonb_build_object('ok', true,
    'leidas', v_leidas, 'sin_fecha', v_malas,
    'nuevas', v_nuevas, 'actualizadas', greatest(0, v_toc - v_nuevas),
    'desde', v_desde, 'hasta', v_hasta,
    'total', (select count(*) from public.liquidaciones),
    'sin_cedula', (select count(*) from public.liquidaciones where conductor_cedula is null),
    'no_cuadran', (select count(*) from public.liquidaciones where cuadra is false));

  update public.liquidaciones_fuente
     set procesado_id = v_req, procesado_en = now(), resultado = v_out
   where id = 1;

  return v_out;
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end $function$;

revoke all on function public.liquidaciones_procesar() from public, anon;
grant execute on function public.liquidaciones_procesar() to authenticated;

-- La de un solo paso ya no sirve para esta hoja: se quita para que nadie la llame por error.
drop function if exists public.liquidaciones_sync(boolean);

-- ---------------------------------------------------------------------------
-- Crons: pedir a las 5:40 de Colombia (10:40 UTC) y procesar a los 5, 10 y 15 minutos.
-- Tres intentos porque la descarga tarda; el que la encuentra la procesa y los otros dos
-- responden "ya se habia procesado" sin hacer nada.
-- ---------------------------------------------------------------------------
select cron.unschedule('sync-liquidaciones')
 where exists (select 1 from cron.job where jobname = 'sync-liquidaciones');
select cron.unschedule('liq-pedir')
 where exists (select 1 from cron.job where jobname = 'liq-pedir');
select cron.unschedule('liq-procesar')
 where exists (select 1 from cron.job where jobname = 'liq-procesar');

select cron.unschedule('liq-pedir-2')
 where exists (select 1 from cron.job where jobname = 'liq-pedir-2');

-- Se pide DOS veces (5:40 y 6:10 de Colombia) porque la descarga a veces expira; la segunda
-- es la red de seguridad. Procesar corre cada 5 minutos durante esas dos horas: el intento que
-- encuentra la respuesta la carga y los demas salen de una con "ya se habia procesado".
select cron.schedule('liq-pedir',    '40 10 * * *',  $cron$select public.liquidaciones_pedir()$cron$);
select cron.schedule('liq-pedir-2',  '10 11 * * *',  $cron$select public.liquidaciones_pedir()$cron$);
select cron.schedule('liq-procesar', '*/5 10-11 * * *', $cron$select public.liquidaciones_procesar()$cron$);

-- Comprobacion (solo lectura)
select 'funciones pedir/procesar' as dato,
       (select count(*)::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('liquidaciones_pedir', 'liquidaciones_procesar')) || ' de 2' as valor
union all
select 'la de un solo paso ya no existe',
       (select case when count(*) = 0 then 'si' else 'TODAVIA EXISTE' end::text
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.proname = 'liquidaciones_sync')
union all
select 'crons de liquidaciones activos',
       (select count(*)::text from cron.job
         where jobname in ('liq-pedir', 'liq-pedir-2', 'liq-procesar') and active) || ' de 3'
union all
select 'filas cargadas hasta ahora',
       (select count(*)::text from public.liquidaciones);
